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
        let session = SessionModel()
        model = session
        assistant = MeetingAssistant(port: LegacySessionAdapter(model: session), changes: session.objectWillChange)
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
    private let port: LegacySessionPort
    private var subscription: AnyCancellable?
    private var checking = false

    init(port: LegacySessionPort, changes: ObservableObjectPublisher? = nil) {
        self.port = port
        settings = SettingsWorker(port: port)
        input = InputWorker(port: port)
        connection = ConnectionWorker(port: port)
        meeting = MeetingWorker(port: port)
        subscription = changes?.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var readiness: ReadinessSnapshot {
        ReadinessSnapshot(configuration: settings.snapshot, input: input.binding,
                          inputAvailable: input.isAvailable, configurationLocked: settings.isLocked)
    }

    @discardableResult func accept(_ action: CaptureAction) -> CaptureActionResult {
        let result: CaptureActionResult
        switch action {
        case .start, .recover:
            if meeting.terminating { result = .rejected("会议正在结束") }
            else if meeting.wantsCapture && action == .start { result = .rejected("已有采集意图，请在连接页恢复") }
            else if meeting.isRecording { result = .rejected("采集已经开始或正在准备") }
            else if action == .recover && !meeting.projection.canReconnect(
                wantsToContinue: meeting.wantsCapture, recording: meeting.isRecording,
                networkOK: connection.network == .connected) { result = .rejected("当前没有可恢复的会议授权") }
            else if let problem = readiness.problems.first { result = .rejected(problem) }
            else { port.startCapture(); result = .submitted }
        case .end, .cancelStart:
            if meeting.terminating { result = .rejected("结束动作正在执行") }
            else if meeting.isRecording || meeting.wantsCapture {
                // S2 preserves the existing phone-channel stop. Full meeting
                // pause/end semantics are implemented by S4, never simulated here.
                port.stopCapture(); result = .submitted
            } else if meeting.presentation.terminateAction.enabled {
                port.endMeeting(); result = .submitted
            } else { result = .rejected("当前没有可停止的手机采集") }
        case .pause, .resume:
            result = .rejected("暂停和继续尚待会控 v2 接入")
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
