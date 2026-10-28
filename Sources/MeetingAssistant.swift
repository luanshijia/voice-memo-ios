import Combine
import Foundation

/// StateObject's deferred initializer constructs this graph once. Do not create
/// SessionModel in a View initializer: SwiftUI can recreate value views freely.
@MainActor final class MeetingWorkspace: ObservableObject {
    let model: SessionModel
    let assistant: MeetingAssistant
    private var subscription: AnyCancellable?
    init() {
        AppStorage.migrateLegacySettings()
        let settings = SettingsWorker()
        let input = InputWorker()
        let connection = ConnectionWorker(settings: settings)
        let meeting = MeetingWorker(settings: settings, input: input, transport: connection)
        model = SessionModel(meeting: meeting)
        assistant = MeetingAssistant(meeting: meeting)
        subscription = assistant.objectWillChange.sink { [weak self] _ in
            RuntimeActivity.add(.uiNotice); self?.objectWillChange.send()
        }
    }
}

/// One root dispatcher. Navigation changes never invoke an IO port.
@MainActor final class MeetingAssistant: ObservableObject {
    @Published var page: WorkspacePage = .meeting
    @Published private(set) var message: String?
    @Published var showingDeviceStop = false
    private var deviceStopTarget: (connection: UUID, meeting: String?, endsMeeting: Bool)?
    let settings: SettingsWorker
    let input: InputWorker
    let connection: ConnectionWorker
    let meeting: MeetingWorker
    private var commands = MeetingCommands(start: { .rejected("动作未配置") }, end: { .rejected("动作未配置") })
    private var subscription: AnyCancellable?
    private var checking = false
    private var serverCleanupTask: Task<Void, Never>?
    private var serverMessage: String?
    /// Local start/halt tasks own pending execution until their cleanup completes.
    private var localControlExecutions = 0
    private var desktopReconciliationRunning = false
    private var usageSample = RuntimeUsageSample()
    private var runtimeForeground = true
    var runtimeContext: String {
        "\(runtimeForeground ? "前台" : "后台") \(input.isCapturing ? "采集中" : "空闲") \(input.displayName) SDK=\(input.device.isSDKInitialized) BLE=\(input.device.connected) 媒体=\(connection.media)"
    }
    func setRuntimeForeground(_ foreground: Bool) {
        runtimeForeground = foreground
        meeting.runtimeForeground = foreground
        if foreground { nextDesktopPoll = .distantPast }
        observeRuntimePhase()
    }
    func observeRuntimePhase() {
        if let sample = usageSample.report(context: runtimeContext, foreground: runtimeForeground) { meeting.note(sample) }
    }
    private var cleanupMessage: String?
    private var nextDesktopPoll = Date.distantPast
    var usesIdlePolling: Bool {
        !meeting.isRecording && !meeting.wantsCapture && !meeting.actionPending && !meeting.terminating &&
        localControlExecutions == 0 && unsavedHalt == nil && !connection.hasPendingCapture &&
        !AppStorage.hasPendingControl() && meeting.meetingContext.pendingReports == 0 &&
        !meeting.meetingContext.hasOpenMeeting && input.cleanupProblem == nil
    }
    private var observationTask: Task<Void, Never>?
    private var pendingPublishing: CaptureView?
    private var unsavedHalt: (action: String, config: LiveKitConfig, view: CaptureView?)?

    init(meeting: MeetingWorker, commands: MeetingCommands? = nil) {
        self.meeting = meeting
        settings = meeting.settings
        input = meeting.input
        connection = meeting.transport
        self.commands = commands ?? MeetingCommands(
            start: { [weak self] in self?.startCapture() ?? .rejected("助手已关闭") },
            end: { [weak self] in self?.terminateMeeting() ?? .rejected("助手已关闭") },
            pause: { [weak self] in self?.pauseCapture() ?? .rejected("助手已关闭") },
            resume: { [weak self] in self?.resumeCapture() ?? .rejected("助手已关闭") })
        connection.onEnded = { [weak self] reason in
            self?.meeting.note("连接结束:\(reason)")
            self?.captureInterrupted()
        }
        input.serverAvailable = { [weak self] in self?.canStartCapture ?? false }
        connection.onServerUnavailable = { [weak self] in self?.enforceServerUnavailable() }
        connection.onServerAvailable = { [weak self] in self?.clearRecoveredServerMessage() }
        meeting.onCaptureProjection = { [weak self] view, confirmed in
            guard let self else { return }
            if self.unsavedHalt == nil && !self.connection.hasPendingCapture { self.meeting.clearConfirmedCaptureIntent() }
            if !self.meeting.isRecording, view.desiredState != "ended" {
                let kind: InputKind = view.input.channel == "external_audio" ? .external : .phone
                self.input.adopt(InputBinding(kind: kind, capturePort: kind == .phone ? .nativeMicrophone : .pcmFeed,
                    sourceTag: SourceTag(rawValue: view.sourceTag) ?? .face2face))
            }
            let desired = self.meeting.localCaptureDesired ?? view.desiredState
            if confirmed, desired != "active", self.meeting.isRecording || self.input.isCapturing || self.connection.live != nil {
                self.haltLocalCapture(pausing: desired == "paused")
            }
        }
        input.device.onHardware = { [weak self] event in self?.hardware(event) ?? false }
        input.device.onRecordingObservation = { [weak self] state in
            guard let self, self.input.binding.kind == .external,
                  (self.meeting.isRecording || self.meeting.isPaused), !self.meeting.actionPending,
                  self.localControlExecutions == 0, !self.input.deviceManagement.busy,
                  (self.meeting.isPaused ? state == .recording : state != .recording) else { return }
            self.input.external.observeUnexpectedState(state)
            self.meeting.note("卡端状态变化为\(state.rawValue)，协调会议暂停")
            self.pauseCapture()
        }
        input.device.onDiagnostic = { [weak meeting] event in meeting?.note("[CB08] \(event)") }
        input.external.onFault = { [weak self] in
            guard let self, self.input.binding.kind == .external, self.meeting.isRecording else { return }
            self.pauseCapture()
        }
        connection.currentCapture = { [weak meeting] in meeting?.capture }
        subscription = meeting.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if meeting.observesDesktop {
            if let saved = MeetingClient.savedCapture() { meeting.applyCapture(saved, confirmed: false) }
            meeting.setActionPending(connection.hasPendingCapture)
            startDesktopObservation()
        }
    }

    var readiness: ReadinessSnapshot {
        ReadinessSnapshot(configuration: settings.snapshot, input: input.binding,
                          inputAvailable: input.isAvailable, configurationLocked: settings.isLocked,
                          serverReady: canStartCapture)
    }
    var canStartCapture: Bool { connection.serverReady && serverCleanupTask == nil }

    @discardableResult func accept(_ action: CaptureAction) -> CaptureActionResult {
        if input.deviceManagement.busy || showingDeviceStop {
            message = "请先完成设备动作确认"
            return .rejected("请先完成设备动作确认")
        }
        let result: CaptureActionResult
        switch action {
        case .start, .recover:
            if meeting.actionPending { result = .rejected("请先等待当前会控动作确认") }
            else if meeting.isPaused { result = .rejected("会议已暂停，请使用继续") }
            else if meeting.terminating { result = .rejected("会议正在结束") }
            else if meeting.wantsCapture && action == .start { result = .rejected("已有采集意图，请在连接页恢复") }
            else if meeting.isRecording { result = .rejected("采集已经开始或正在准备") }
            else if action == .recover && !meeting.projection.canReconnect(
                wantsToContinue: meeting.wantsCapture, recording: meeting.isRecording,
                networkOK: connection.network == .connected) { result = .rejected("当前没有可恢复的会议授权") }
            else if let problem = readiness.problems.first { result = .rejected(problem) }
            else { result = commands.start() }
        case .end, .cancelStart:
            if meeting.terminating { result = .rejected("结束动作正在执行") }
            else if meeting.isRecording || meeting.wantsCapture {
                result = commands.end()
            } else if meeting.presentation.terminateAction.enabled {
                result = commands.end()
            } else { result = .rejected("当前没有可结束的采集") }
        case .pause:
            if (meeting.isRecording || meeting.wantsCapture), !meeting.isPaused, !meeting.terminating, let pause = commands.pause {
                result = pause()
            } else { result = .rejected("当前无法暂停采集") }
        case .resume:
            if meeting.isPaused, !meeting.isRecording, !meeting.actionPending,
               connection.pendingDisconnect == nil, readiness.problems.isEmpty, meeting.capture?.observedState == "paused",
               let resume = commands.resume {
                result = resume()
            } else { result = .rejected("请等待暂停确认后再继续") }
        }
        if case .rejected(let reason) = result { message = reason } else { message = nil }
        return result
    }

    var canSelectInput: Bool {
        connection.serverReady && serverCleanupTask == nil && !input.deviceManagement.busy && !showingDeviceStop && input.cleanupProblem == nil && !meeting.actionPending && !meeting.terminating && !meeting.isRecording && connection.pendingDisconnect == nil &&
        ((!meeting.wantsCapture && !settings.isLocked) ||
         (meeting.isPaused && meeting.capture?.observedState == "paused"))
    }
    func selectInput(_ kind: InputKind, tag: SourceTag = .face2face) {
        guard canSelectInput else { message = "请先暂停并等待确认"; return }
        let binding = InputBinding(kind: kind, capturePort: kind == .phone ? .nativeMicrophone : .pcmFeed,
                                   sourceTag: kind == .phone ? .face2face : tag)
        let result = meeting.isPaused ? selectPausedInput(binding) : input.select(kind, tag: tag)
        if case .rejected(let reason) = result { message = reason } else { message = nil }
        objectWillChange.send()
    }
    /// No key event can claim another source's active meeting.
    func hardware(_ event: CB08RecordAction) -> Bool {
        guard input.binding.kind == .external, !meeting.actionPending,
              !input.deviceManagement.busy, !showingDeviceStop else { return false }
        if event == .stop {
            guard deviceCanStop, let connection = input.device.connectionID else { return false }
            return executeDeviceStop(connection: connection, meetingID: hasExternalMeeting ? meeting.capture?.meetingID : nil,
                                     endsMeeting: hasExternalMeeting, fromHardware: true)
        }
        let action: CaptureAction
        switch event {
        case .start: action = .start
        case .stop: action = .end
        case .pause: action = .pause
        case .resume: action = .resume
        }
        return accept(action) == .submitted
    }

    private var hasExternalMeeting: Bool {
        input.binding.kind == .external && (meeting.wantsCapture || meeting.isRecording || meeting.presentation.terminateAction.enabled)
    }
    private var deviceControlsBusy: Bool {
        serverCleanupTask != nil || input.deviceManagement.busy || showingDeviceStop || meeting.actionPending || meeting.terminating ||
        localControlExecutions > 0 || desktopReconciliationRunning || connection.pendingDisconnect != nil || input.cleanupProblem != nil
    }
    var deviceConnectionLocked: Bool { !connection.serverReady || serverCleanupTask != nil || deviceControlsBusy || meeting.isRecording || meeting.wantsCapture }
    var deviceStartTitle: String { meeting.isPaused ? "继续" : meeting.wantsCapture ? "恢复" : "开始" }
    var deviceCanStart: Bool {
        guard input.device.connected, input.binding.kind == .external, !deviceControlsBusy,
              !meeting.isRecording, readiness.problems.isEmpty, input.deviceManagement.problem == nil else { return false }
        let state = input.device.recordState
        if meeting.isPaused {
            return meeting.capture?.observedState == "paused" &&
                (state == .stopped || state == .inactive || (state == .paused && input.external.canResumeOwnedRecording))
        }
        return state == .stopped || state == .inactive
    }
    var deviceCanPause: Bool {
        input.device.connected && !deviceControlsBusy && input.binding.kind == .external &&
        meeting.isRecording && !meeting.isPaused && input.device.recordState == .recording
    }
    var deviceCanStop: Bool {
        guard input.device.connected, !deviceControlsBusy else { return false }
        if hasExternalMeeting { return true }
        guard !meeting.wantsCapture, !meeting.isRecording, !meeting.meetingContext.hasOpenMeeting else { return false }
        return input.device.recordState != .stopped || input.deviceManagement.problem != nil
    }
    var deviceIndependentWarning: Bool {
        input.device.connected && !hasExternalMeeting &&
        (input.device.recordState == .recording || input.device.recordState == .paused)
    }
    var deviceControlStatus: String {
        guard input.device.connected else { return "CB08未连接" }
        if input.deviceManagement.busy { return "设备准备中 · 等待确认" }
        if let problem = input.deviceManagement.problem ?? input.cleanupProblem { return problem }
        if deviceIndependentWarning { return "CB08：\(input.device.recordState!.rawValue) · App未采集此录音" }
        if hasExternalMeeting { return "CB08：\(input.device.recordState?.rawValue ?? "未知") · \(meeting.captureStatusText)" }
        if let state = input.device.recordState {
            return state == .stopped || state == .inactive ? "CB08：\(state.rawValue) · 可开始新采集" : "CB08：\(state.rawValue)"
        }
        return "CB08状态未确认 · 请刷新"
    }
    func startFromDeviceConsole() {
        guard deviceCanStart else { return }
        accept(meeting.isPaused ? .resume : meeting.wantsCapture ? .recover : .start)
    }
    @discardableResult func requestDeviceStop() -> Bool {
        guard deviceCanStop, let connection = input.device.connectionID else { return false }
        deviceStopTarget = (connection, hasExternalMeeting ? meeting.capture?.meetingID : nil, hasExternalMeeting)
        showingDeviceStop = true
        return true
    }
    var deviceStopMessage: String {
        if deviceStopTarget?.endsMeeting == true {
            return "将停止CB08录音并结束本次会议，已有内容保留。与会议页“结束会议”执行相同操作。"
        }
        return "将停止并保存CB08卡端当前录音。App没有采集此录音，本操作不会创建或结束App会议。"
    }
    func cancelDeviceStop() {
        showingDeviceStop = false; deviceStopTarget = nil
        input.device.cancelHardwareIntent()
    }
    func confirmDeviceStop() {
        showingDeviceStop = false
        guard let target = deviceStopTarget else { return }
        deviceStopTarget = nil
        _ = executeDeviceStop(connection: target.connection, meetingID: target.meeting,
                              endsMeeting: target.endsMeeting, fromHardware: false)
    }
    private func executeDeviceStop(connection: UUID, meetingID: String?, endsMeeting: Bool, fromHardware: Bool) -> Bool {
        guard input.device.connectionID == connection, deviceCanStop, endsMeeting == hasExternalMeeting,
              meetingID == (hasExternalMeeting ? meeting.capture?.meetingID : nil) else {
            input.device.cancelHardwareIntent(); message = "设备或会议已变化，请重新确认"; return false
        }
        if !fromHardware { input.device.cancelHardwareIntent() }
        if hasExternalMeeting { return accept(.end) == .submitted }
        guard let stop = input.deviceManagement.stopIndependent(cleanup: { [input] in
            await input.stop()
            return input.cleanupProblem == nil
        }) else { return false }
        Task { [weak self] in
            guard let self else { return }
            let stopped = await stop.value
            self.input.device.cancelHardwareIntent()
            self.message = stopped ? nil : self.input.deviceManagement.problem
        }
        return true
    }

    func checkConnection() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await connection.checkServer()
        nextDesktopPoll = .distantPast
    }

    private func enforceServerUnavailable(mediaFailed: Bool = false) {
        guard serverCleanupTask == nil else { return }
        // A brief control failure must not tear down a media path with fresh desktop receipt evidence.
        if !mediaFailed && meeting.isRecording && connection.media == .connected && connection.hasFreshAudioReceipt { return }
        input.device.stopScan()
        if showingDeviceStop { cancelDeviceStop() }
        let hadCapture = meeting.isRecording || input.isCapturing || meeting.wantsCapture
        if (meeting.isRecording || (meeting.wantsCapture && !meeting.isPaused)), !meeting.terminating {
            _ = pauseCapture()
        }
        let oldConnection = input.device.connectionID
        serverCleanupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.objectWillChange.send(); self.serverCleanupTask = nil
                self.clearRecoveredServerMessage()
            }
            while self.input.deviceManagement.busy, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            await self.connection.pendingDisconnect?.value
            // Close every local audio resource before BLE teardown; independent card recordings are not commanded.
            if !self.meeting.isRecording && !self.input.isCapturing {
                if self.meeting.isPaused { await self.input.pause() } else { await self.input.stop() }
            }
            guard !self.connection.serverReady, self.input.device.connectionID == oldConnection else { return }
            self.input.device.stopScan()
            if self.input.device.connected { self.input.device.disconnect() }
            let text = self.input.cleanupProblem ?? (hadCapture
                ? "服务器不可用，采集已暂停，蓝牙已关闭；恢复连接后请手动继续"
                : "服务器不可用，蓝牙和采集启动已停用")
            self.serverMessage = text
            if self.message != text { self.message = text }
        }
    }
    private func clearRecoveredServerMessage() {
        guard canStartCapture, input.cleanupProblem == nil, let serverMessage else { return }
        if message == serverMessage { message = nil }
        self.serverMessage = nil
    }

    deinit { observationTask?.cancel(); serverCleanupTask?.cancel() }
    func startDesktopObservation() {
        guard meeting.observesDesktop else { return }
        if let observationTask, !observationTask.isCancelled { return }
        let previous = observationTask
        observationTask = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                await self?.observeDesktopOnce()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func stopDesktopObservation() { observationTask?.cancel() }
    private func observeDesktopOnce() async {
        observeRuntimePhase()
        settings.refreshPendingControls()
        let idle = usesIdlePolling
        if !runtimeForeground && idle { return }
        if Date() < nextDesktopPoll { return }
        defer {
            let ordinary = Date().addingTimeInterval(idle ? 15 : 5)
            nextDesktopPoll = connection.serverReady ? ordinary : max(Date().addingTimeInterval(5), connection.serverAvailability.retryAt)
        }
        if !connection.serverReady {
            guard await connection.checkServer() else { return }
        }
        try? await MeetingClient.flushPendingBroadcastStop()
        guard !Task.isCancelled else { return }
        try? await MeetingClient.flushPendingMicStop()
        guard !Task.isCancelled else { return }
        try? await reconcileDesktopOnce()
    }

    /// Polling may settle abandoned requests after relaunch, but never consume
    /// the grant belonging to a running local start/halt operation.
    func reconcileDesktopOnce() async throws {
        guard localControlExecutions == 0, !desktopReconciliationRunning,
              !input.deviceManagement.busy, !showingDeviceStop else { return }
        desktopReconciliationRunning = true
        defer { desktopReconciliationRunning = false }
        await input.retryCleanup()
        if let problem = input.cleanupProblem {
            cleanupMessage = problem
            if message != problem { message = problem }
        } else if let cleanupMessage, message == cleanupMessage {
            message = nil; self.cleanupMessage = nil
        }
        try persistUnsavedHalt()
        let pollGeneration = connection.generation
        let pollConfig = settings.config
        if !connection.serverReady {
            _ = try await connection.captureView(config: pollConfig)
            guard connection.serverReady, pollGeneration == connection.generation, localControlExecutions == 0 else { return }
        }
        if let reconciled = try await connection.flushCapture() {
            guard pollGeneration == connection.generation, localControlExecutions == 0 else { return }
            meeting.applyCapture(reconciled)
        }
        guard pollGeneration == connection.generation, localControlExecutions == 0 else { return }
        let state = try await connection.captureView(config: pollConfig)
        guard pollGeneration == connection.generation, localControlExecutions == 0,
              pollConfig.url == settings.config.url, pollConfig.device == settings.config.device else { return }
        connection.updateAudioReceipt(state)
        if let view = state.meeting {
            meeting.applyCapture(view, pendingReports: state.pendingReports.count)
            // A relaunch has no active publisher. Complete a pause/end observation
            // even when the app previously exited after the durable action ack.
            if view.desiredState != "active", !meeting.isRecording, !input.isCapturing,
               connection.connecting == nil, connection.pendingDisconnect == nil, input.cleanupProblem == nil,
               view.observedState == "pending" {
                try await connection.observeCapture(config: pollConfig, view: view, observed: "stopped")
            }
            if let pending = pendingPublishing, meeting.isRecording,
               view.desiredState == "active", pending.meetingID == view.meetingID,
               pending.segmentID == view.segmentID {
                try await connection.observeCapture(config: pollConfig, view: pending, observed: "publishing")
                if pollGeneration == connection.generation { pendingPublishing = nil }
            }
        }
        guard pollGeneration == connection.generation else { return }
        meeting.reconcilePendingAction(connection.hasPendingCapture)
        meeting.receivePendingReports(state.pendingReports, config: pollConfig)
        settings.refreshPendingControls()
    }

    @discardableResult func startCapture() -> CaptureActionResult {
        guard !meeting.isRecording, !meeting.terminating else { return .rejected("采集已经开始或正在结束") }
        return beginCapture(resuming: false)
    }
    func captureInterrupted() {
        if connection.serverPhase == .unavailable { enforceServerUnavailable(mediaFailed: true); return }
        if input.binding.kind == .external, meeting.wantsCapture, !meeting.isPaused, !meeting.terminating {
            // A lost connection must not leave the card recording indefinitely.
            pauseCapture()
            return
        }
        input.interrupted()
        connection.interrupted()
        meeting.captureInterrupted()
    }
    @discardableResult func selectPausedInput(_ binding: InputBinding) -> CaptureActionResult {
        guard meeting.isPaused, !meeting.actionPending, meeting.capture?.observedState == "paused", let view = meeting.capture else {
            return .rejected("请先暂停并等待电脑确认")
        }
        do { try connection.queueCaptureAction(config: settings.config, view: view, action: "select_input", input: binding) }
        catch { return .rejected("输入选择未保存：\(error.localizedDescription)") }
        meeting.setActionPending(true)
        localControlExecutions += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.localControlExecutions -= 1 }
            do {
                if let result = try await self.connection.flushCapture() { self.meeting.applyCapture(result) }
                self.meeting.setActionPending(self.connection.hasPendingCapture)
            } catch { self.meeting.note("输入切换待确认：\(error.localizedDescription)") }
        }
        return .submitted
    }

    @discardableResult func pauseCapture() -> CaptureActionResult { controlCapture("pause") }
    @discardableResult func resumeCapture() -> CaptureActionResult { beginCapture(resuming: true) }
    @discardableResult func terminateMeeting() -> CaptureActionResult { controlCapture("end") }

    /// Close the audio gate immediately; disconnect only after any in-flight
    /// start has returned. Both local commands and desktop observations use it.
    @discardableResult private func haltLocalCapture(pausing: Bool) -> Int {
        pendingPublishing = nil
        let generation = connection.invalidate()
        meeting.captureHalted(pausing: pausing)
        if !pausing { meeting.clearMeetingDisplay() }
        input.device.cancelHardwareIntent(unless: pausing ? .pause : .stop)
        input.requestHalt(pausing: pausing)
        connection.enqueueDisconnect(beforeDisconnect: { [input] in
            if pausing { await input.pause() } else { await input.finish() }
        }) {}
        return generation
    }

    private func persistUnsavedHalt() throws {
        guard let halt = unsavedHalt else { return }
        try connection.queueCaptureAction(config: halt.config, view: halt.view, action: halt.action)
        unsavedHalt = nil
        message = nil
    }

    private func controlCapture(_ action: String) -> CaptureActionResult {
        let config = settings.config
        unsavedHalt = (action, config, meeting.capture)
        var result = CaptureActionResult.submitted
        do { try persistUnsavedHalt() }
        catch {
            let reason = "本地已停止，会控动作未保存，将重试：\(error.localizedDescription)"
            meeting.note(reason)
            message = reason
            result = .rejected(reason)
        }
        meeting.setCaptureAction(desired: action == "pause" ? "paused" : "ended")
        localControlExecutions += 1
        let generation = haltLocalCapture(pausing: action == "pause")
        meeting.setTerminating(action == "end")
        let disconnect = connection.pendingDisconnect
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.localControlExecutions -= 1
                if generation == self.connection.generation { self.meeting.setTerminating(false) }
            }
            await disconnect?.value
            guard generation == self.connection.generation else { return }
            do {
                try self.persistUnsavedHalt()
                guard self.connection.serverReady else {
                    self.meeting.note("本地已停止，电脑动作等待服务器恢复后确认")
                    return
                }
                if let result = try await self.connection.flushCapture() { self.meeting.applyCapture(result) }
                if let problem = self.input.cleanupProblem {
                    self.cleanupMessage = problem
                    if self.message != problem { self.message = problem }
                    self.meeting.note(problem)
                }
                if self.input.cleanupProblem == nil, let view = self.meeting.capture {
                    try await self.connection.observeCapture(config: config, view: view, observed: "stopped")
                    if let fresh = try await self.connection.captureView(config: config).meeting { self.meeting.applyCapture(fresh) }
                }
                guard generation == self.connection.generation else { return }
                self.meeting.reconcilePendingAction(self.connection.hasPendingCapture)
            } catch { self.meeting.note("本地已停止，电脑动作待确认：\(error.localizedDescription)") }
        }
        return result
    }

    private func beginCapture(resuming: Bool) -> CaptureActionResult {
        guard connection.serverReady, serverCleanupTask == nil else { return .rejected("服务器未就绪，采集暂不可用") }
        guard !meeting.actionPending, connection.connecting == nil else { return .rejected("请等待当前动作确认") }
        guard !meeting.terminating else { return .rejected("会议正在结束") }
        if let problem = input.cleanupProblem { return .rejected(problem) }
        if input.binding.kind == .external, let problem = input.deviceManagement.problem { return .rejected(problem) }
        meeting.refreshForegroundObservations()
        nextDesktopPoll = .distantPast
        let config = settings.config
        let previousID = meeting.capture?.meetingID
        let previouslyWanted = meeting.wantsCapture
        let binding = input.binding
        let deviceConnection = input.device.connectionID
        let revision = settings.snapshot.revision
        let generation = connection.invalidate()
        let operation = SessionOperation(generation: generation, config: config)
        meeting.setActionPending(true)
        localControlExecutions += 1
        meeting.capturePreparing()
        connection.beginConnection { [self] in
            defer { localControlExecutions -= 1 }
            var queued = false
            do {
                _ = try await connection.captureView(config: config)
                if binding.kind == .external {
                    try await input.deviceManagement.checkForCapture(canResume: input.external.canResumeOwnedRecording)
                }
                guard connection.serverReady, operation.isCurrent(generation: connection.generation, config: settings.config),
                      revision == settings.snapshot.revision, binding == input.binding,
                      binding.kind != .external || deviceConnection == input.device.connectionID else { throw CancellationError() }
                if resuming {
                    guard let view = meeting.capture, view.desiredState == "paused" else { throw CancellationError() }
                    try connection.queueCaptureAction(config: config, view: view, action: "resume")
                } else {
                    let recoveryID = meeting.capture.flatMap { $0.canRecover ? $0.meetingID : nil }
                    try connection.queueCaptureStart(config: config, input: binding, meetingID: recoveryID)
                }
                queued = true
                meeting.setCaptureAction(desired: "active")
                try await MeetingClient.flushPendingMicStop()
                try await MeetingClient.flushPendingBroadcastStop()
                guard let grant = try await connection.flushCapture() else { throw CancellationError() }
                if previousID != grant.meetingID { meeting.resetCurrentMeetingData() }
                meeting.applyCapture(grant)
                guard operation.isCurrent(generation: connection.generation, config: settings.config),
                      grant.desiredState == "active", let media = grant.media else { return }
                let live = try await connection.connect(url: media.url, token: media.token, identity: media.identity)
                guard operation.isCurrent(generation: connection.generation, config: settings.config) else {
                    await connection.disconnect(live); return
                }
                input.bind(live)
                do {
                    try await input.start(context: ExecutionContext(configurationRevision: settings.snapshot.revision,
                        operationID: UUID(), meetingID: grant.meetingID, channel: grant.channel,
                        generation: grant.generation, segmentID: grant.segmentID))
                } catch {
                    if input.binding.kind == .external { input.external.reportStartupFailure(error.localizedDescription) }
                    await input.stop(); await connection.disconnect(live); throw error
                }
                guard operation.isCurrent(generation: connection.generation, config: settings.config) else {
                    await input.stop(); await connection.disconnect(live); return
                }
                connection.connected(live)
                pendingPublishing = grant
                do {
                    try await connection.observeCapture(config: config, view: grant, observed: "publishing")
                    if operation.isCurrent(generation: connection.generation, config: settings.config) { pendingPublishing = nil }
                } catch {
                    // The input is already running. Keep its real state visible
                    // and retry observation through the regular desktop poll.
                    meeting.note("采集已启动，发布状态等待电脑确认：\(error.localizedDescription)")
                }
                guard operation.isCurrent(generation: connection.generation, config: settings.config) else { return }
                meeting.reconcilePendingAction(connection.hasPendingCapture)
                await meeting.sendSummaryMode()
                guard operation.isCurrent(generation: connection.generation, config: settings.config), meeting.isRecording else { return }
                meeting.startTimer()
                meeting.syncBoard()
            } catch {
                guard operation.isCurrent(generation: connection.generation, config: settings.config) else { return }
                if !queued {
                    input.device.cancelHardwareIntent()
                    meeting.captureHalted(pausing: previouslyWanted)
                    meeting.setActionPending(connection.hasPendingCapture)
                    message = "采集前检查未通过：\(error.localizedDescription)"
                    return
                }
                pendingPublishing = nil
                await input.stop()
                if let live = connection.live { await connection.disconnect(live) }
                guard operation.isCurrent(generation: connection.generation, config: settings.config) else { return }
                connection.interrupted()
                meeting.captureInterrupted()
                input.device.cancelHardwareIntent()
                meeting.setActionPending(connection.hasPendingCapture)
                meeting.note("采集未完成，请在连接页对账：\(error.localizedDescription)")
            }
        }
        return .submitted
    }

}
