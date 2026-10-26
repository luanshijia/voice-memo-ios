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
    private let commands: MeetingCommands
    private var subscription: AnyCancellable?
    private var checking = false

    init(meeting: MeetingWorker, commands: MeetingCommands? = nil) {
        self.meeting = meeting
        settings = meeting.settings
        input = meeting.input
        connection = meeting.transport
        self.commands = commands ?? MeetingCommands(
            start: { meeting.startCapture() },
            end: { meeting.terminateMeeting() },
            pause: { meeting.pauseCapture() }, resume: { meeting.resumeCapture() })
        input.device.onHardware = { [weak self] event in self?.hardware(event) ?? false }
        input.external.onFault = { [weak self] in
            guard let self, self.input.binding.kind == .external, self.meeting.isRecording else { return }
            self.meeting.pauseCapture()
        }
        subscription = meeting.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var readiness: ReadinessSnapshot {
        ReadinessSnapshot(configuration: settings.snapshot, input: input.binding,
                          inputAvailable: input.isAvailable, configurationLocked: settings.isLocked)
    }

    @discardableResult func accept(_ action: CaptureAction) -> CaptureActionResult {
        let result: CaptureActionResult
        switch action {
        case .start, .recover:
            if meeting.isPaused { result = .rejected("会议已暂停，请使用继续") }
            else if meeting.terminating { result = .rejected("会议正在结束") }
            else if meeting.wantsCapture && action == .start { result = .rejected("已有采集意图，请在连接页恢复") }
            else if meeting.isRecording { result = .rejected("采集已经开始或正在准备") }
            else if action == .recover && !meeting.projection.canReconnect(
                wantsToContinue: meeting.wantsCapture, recording: meeting.isRecording,
                networkOK: connection.network == .connected) { result = .rejected("当前没有可恢复的会议授权") }
            else if let problem = readiness.problems.first { result = .rejected(problem) }
            else { commands.start(); result = .submitted }
        case .end, .cancelStart:
            if meeting.terminating { result = .rejected("结束动作正在执行") }
            else if meeting.isRecording || meeting.wantsCapture {
                commands.end(); result = .submitted
            } else if meeting.presentation.terminateAction.enabled {
                commands.end(); result = .submitted
            } else { result = .rejected("当前没有可结束的采集") }
        case .pause:
            if meeting.isRecording, !meeting.terminating, let pause = commands.pause {
                pause(); result = .submitted
            } else { result = .rejected("当前无法暂停采集") }
        case .resume:
            if meeting.isPaused, !meeting.isRecording, !meeting.actionPending, readiness.problems.isEmpty, meeting.capture?.observedState == "paused",
               let resume = commands.resume {
                resume(); result = .submitted
            } else { result = .rejected("请等待暂停确认后再继续") }
        }
        if case .rejected(let reason) = result { message = reason } else { message = nil }
        return result
    }

    var canSelectInput: Bool {
        !meeting.actionPending && !meeting.terminating && !meeting.isRecording &&
        ((!meeting.wantsCapture && !settings.isLocked) ||
         (meeting.isPaused && meeting.capture?.observedState == "paused"))
    }
    func selectInput(_ kind: InputKind, tag: SourceTag = .face2face) {
        guard canSelectInput else { message = "请先暂停并等待确认"; return }
        let binding = InputBinding(kind: kind, capturePort: kind == .phone ? .nativeMicrophone : .pcmFeed,
                                   sourceTag: kind == .phone ? .face2face : tag)
        let result = meeting.isPaused ? meeting.selectInput(binding) : input.select(kind, tag: tag)
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
}
