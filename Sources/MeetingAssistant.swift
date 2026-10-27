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
        subscription = assistant.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// One root dispatcher. Navigation changes never invoke an IO port.
@MainActor final class MeetingAssistant: ObservableObject {
    @Published var page: WorkspacePage = .meeting
    @Published private(set) var message: String?
    let settings: SettingsWorker
    let input: InputWorker
    let connection: ConnectionWorker
    let meeting: MeetingWorker
    private var commands = MeetingCommands(start: { .rejected("动作未配置") }, end: { .rejected("动作未配置") })
    private var subscription: AnyCancellable?
    private var checking = false
    /// Local start/halt tasks own pending execution until their cleanup completes.
    private var localControlExecutions = 0
    private var desktopReconciliationRunning = false
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
        input.external.onFault = { [weak self] in
            guard let self, self.input.binding.kind == .external, self.meeting.isRecording else { return }
            self.pauseCapture()
        }
        subscription = meeting.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if meeting.observesDesktop {
            if let saved = MeetingClient.savedCapture() { meeting.applyCapture(saved, confirmed: false) }
            meeting.setActionPending(connection.hasPendingCapture)
            Task { [weak self] in await self?.observeDesktop() }
        }
    }

    var readiness: ReadinessSnapshot {
        ReadinessSnapshot(configuration: settings.snapshot, input: input.binding,
                          inputAvailable: input.isAvailable, configurationLocked: settings.isLocked)
    }

    @discardableResult func accept(_ action: CaptureAction) -> CaptureActionResult {
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
        !meeting.actionPending && !meeting.terminating && !meeting.isRecording && connection.pendingDisconnect == nil &&
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
        guard input.binding.kind == .external, !meeting.actionPending else { return false }
        let action: CaptureAction
        switch event {
        case .start: action = .start
        case .stop: action = .end
        case .pause: action = .pause
        case .resume: action = .resume
        }
        return accept(action) == .submitted
    }

    func checkConnection() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await connection.preflightControl()
    }

    private func observeDesktop() async {
        while !Task.isCancelled {
            try? await MeetingClient.flushPendingBroadcastStop()
            try? await MeetingClient.flushPendingMicStop()
            try? await reconcileDesktopOnce()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Polling may settle abandoned requests after relaunch, but never consume
    /// the grant belonging to a running local start/halt operation.
    func reconcileDesktopOnce() async throws {
        guard localControlExecutions == 0, !desktopReconciliationRunning else { return }
        desktopReconciliationRunning = true
        defer { desktopReconciliationRunning = false }
        try persistUnsavedHalt()
        let pollGeneration = connection.generation
        let pollConfig = settings.config
        if let reconciled = try await connection.flushCapture() {
            guard pollGeneration == connection.generation, localControlExecutions == 0 else { return }
            meeting.applyCapture(reconciled)
        }
        guard pollGeneration == connection.generation, localControlExecutions == 0 else { return }
        let state = try await connection.captureView(config: pollConfig)
        guard pollGeneration == connection.generation, localControlExecutions == 0,
              pollConfig.url == settings.config.url, pollConfig.device == settings.config.device else { return }
        if let view = state.meeting {
            meeting.applyCapture(view, pendingReports: state.pendingReports.count)
            // A relaunch has no active publisher. Complete a pause/end observation
            // even when the app previously exited after the durable action ack.
            if view.desiredState != "active", !meeting.isRecording, !input.isCapturing,
               connection.connecting == nil, connection.pendingDisconnect == nil,
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
    }

    @discardableResult func startCapture() -> CaptureActionResult {
        guard !meeting.isRecording, !meeting.terminating else { return .rejected("采集已经开始或正在结束") }
        return beginCapture(resuming: false)
    }
    func captureInterrupted() {
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
                if let result = try await self.connection.flushCapture() { self.meeting.applyCapture(result) }
                if let view = self.meeting.capture {
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
        guard !meeting.terminating else { return .rejected("会议正在结束") }
        let config = settings.config
        let previousID = meeting.capture?.meetingID
        do {
            if resuming {
                guard let view = meeting.capture, view.desiredState == "paused" else { return .rejected("会议尚未暂停") }
                try connection.queueCaptureAction(config: config, view: view, action: "resume")
            } else {
                let recoveryID = meeting.capture.flatMap { $0.canRecover ? $0.meetingID : nil }
                try connection.queueCaptureStart(config: config, input: input.binding, meetingID: recoveryID)
            }
        } catch {
            input.device.cancelHardwareIntent()
            let reason = "开始意图未保存：\(error.localizedDescription)"
            meeting.note(reason)
            return .rejected(reason)
        }
        let generation = connection.invalidate()
        let operation = SessionOperation(generation: generation, config: config)
        meeting.setCaptureAction(desired: "active")
        localControlExecutions += 1
        meeting.capturePreparing()
        connection.beginConnection { [self] in
            defer { localControlExecutions -= 1 }
            do {
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
                } catch { await input.stop(); await connection.disconnect(live); throw error }
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
