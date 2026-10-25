import Foundation

@MainActor final class MeetingWorker {
    private let port: LegacySessionPort
    init(port: LegacySessionPort) { self.port = port }
    var projection: MeetingContext { port.meeting }
    var isRecording: Bool { port.isRecording }
    var wantsCapture: Bool { port.wantsCapture }
    var terminating: Bool { port.terminating }
    var presentation: SessionPresentation { port.presentation }
}
