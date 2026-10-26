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
            } else { result = .rejected("当前没有可停止的手机采集") }
        case .pause:
            if meeting.isRecording, !meeting.terminating, let pause = commands.pause {
                pause(); result = .submitted
            } else { result = .rejected("当前无法暂停采集") }
        case .resume:
            if meeting.isPaused, !meeting.isRecording, !meeting.actionPending, meeting.capture?.observedState == "paused",
               let resume = commands.resume {
                resume(); result = .submitted
            } else { result = .rejected("请等待暂停确认后再继续") }
        }
        if case .rejected(let reason) = result { message = reason } else { message = nil }
        return result
    }

    func selectInput(_ kind: InputKind) {
        let result = input.select(kind)
        if case .rejected(let reason) = result { message = reason } else { message = nil }
        objectWillChange.send()
    }

    func checkConnection() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await connection.preflightControl()
    }
}
