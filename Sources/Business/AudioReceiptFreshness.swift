import Foundation

/// Query success is independent of PCM progress. All local deadlines use uptime.
struct AudioReceiptFreshness {
    static let lifetime: TimeInterval = 15
    private var previous: CaptureAudioReceipt?
    private var expiresAt: TimeInterval = 0

    func remaining(now: TimeInterval) -> TimeInterval { max(0, expiresAt - now) }
    func isFresh(now: TimeInterval) -> Bool { remaining(now: now) > 0 }

    mutating func update(_ receipt: CaptureAudioReceipt?, now: TimeInterval) {
        guard let receipt, receipt.receivedSamples > 0, receipt.lastReceivedAt > 0 else {
            previous = nil; expiresAt = 0; return
        }
        let sameSegment = previous.map {
            $0.meetingID == receipt.meetingID && $0.segmentID == receipt.segmentID &&
            $0.generation == receipt.generation && $0.channel == receipt.channel
        } ?? false
        let progressed = sameSegment && previous.map {
            receipt.receivedSamples > $0.receivedSamples || receipt.lastReceivedAt > $0.lastReceivedAt
        } == true
        if let age = receipt.lastReceivedAgeSeconds, age.isFinite, age >= 0 {
            let deadline = now + max(0, Self.lifetime - age)
            expiresAt = sameSegment && !progressed ? min(expiresAt, deadline) : deadline
        } else if progressed {
            expiresAt = now + Self.lifetime
        } else if !sameSegment {
            // Legacy servers provide no age: establish a baseline before trusting progress.
            expiresAt = 0
        }
        previous = receipt
    }
}
