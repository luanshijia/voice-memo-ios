import Combine
import Foundation

/// 一句话转写结果(带说话人 —— agent 是按音轨分轨识别后带上 identity 发回来的)。
struct TranscriptLine: Identifiable {
    var id = UUID()
    let who: String
    let source: String
    let text: String
    /// 这句话开始前,同一路音频静了多久(秒)。nil = 服务端没测出来(刚重连的第一句)
    var gap: Double? = nil
    /// 服务端定稿的绝对时间(epoch 秒)。0 = 老服务端没给
    var ts: Double = 0
}

struct TranscriptPartial: Identifiable {
    var id: String { source.isEmpty ? "unknown-\(who)" : source }
    var who: String
    var source: String
    var text: String
}

/// Compatibility projection for the existing views. No writable business state or IO ownership.
@MainActor final class SessionModel: ObservableObject {
    private let meeting: MeetingWorker
    private var subscription: AnyCancellable?
    init(meeting: MeetingWorker) {
        self.meeting = meeting
        subscription = meeting.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var metrics: DeviceTelemetry { meeting.metrics }
    var transcriptRevision: Int { meeting.transcriptRevision }
    var lines: [TranscriptLine] { meeting.lines }
    var partials: [TranscriptPartial] { meeting.partials }
    var transcriptGapText: String { meeting.transcriptGapText }
    var captureStatusText: String { meeting.captureStatusText }
    var isPaused: Bool { meeting.isPaused }
    var isRecording: Bool { meeting.isRecording }
    var intent: LinkDesired { meeting.intent }
    var meetingContext: MeetingContext { meeting.meetingContext }
    var finalReportText: String { meeting.finalReportText }
    var identity: String { meeting.identity }
    var summaries: [MeetingWorker.SummaryItem] { meeting.summaries }
    var sumMode: String { meeting.sumMode }
    var sumState: String { meeting.sumState }
    var sumCode: String { meeting.sumCode }
    var serverURL: String { meeting.settings.config.url }
    var deviceID: String { meeting.settings.config.device }
    var userID: String { meeting.settings.config.userID }
    var deviceToken: String { meeting.settings.credential }
    var livekWord: String { meeting.livekWord }
    var recordedSeconds: Double { meeting.recordedSeconds }
    var serverSeconds: Double { meeting.serverSeconds }
    var micModeText: String { meeting.input.micModeText }
    var micIsWide: Bool { meeting.input.modeStatus.observed == .wide }
    var notes: [String] { meeting.notes }
    var notesText: String { meeting.notesText }
    func setSumMode(_ mode: String) { meeting.setSumMode(mode) }
    func refreshForegroundStateLoop() async { await meeting.refreshForegroundStateLoop() }
    func refreshNet() async { await meeting.transport.preflightControl() }
    func catchUpNow() async { await meeting.catchUpNow() }
}
