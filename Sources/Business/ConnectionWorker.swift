import Foundation

@MainActor final class ConnectionWorker {
    private let port: LegacySessionPort
    init(port: LegacySessionPort) { self.port = port }
    var network: LinkObserved {
        Date().timeIntervalSince(port.board.probe.lastSeen) <= StatusBoard.probeStaleAfter
            ? port.board.probe.observed : .unknown
    }
    var media: LinkObserved { port.board.livekit.observed }
    var controlIsFresh: Bool { port.meeting.isFresh() }
    var recognitionSeconds: Double { port.board.received.observed.value }
    // The old server progress is recognition progress, not raw PCM receipt.
    var desktopAudioEvidence: String { "尚无按分段统计的实际样本证据" }
    func preflightControl() async { await port.checkConnection() }
}
