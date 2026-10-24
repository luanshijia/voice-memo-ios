import XCTest
@testable import VoiceMemo

final class TranscriptStoreTests: XCTestCase {
    private let epoch = "7d444840-9dc0-11d1-b245-5ffdce74fad2"
    private func entry(_ seq: Int) -> TranscriptStore.Entry {
        .init(seq: seq, who: "speaker", source: "phone-livekit", text: "line \(seq)", gap: nil, ts: 1)
    }

    func testRealtimeDuringCatchUpDoesNotSkipHoles() {
        var store = TranscriptStore()
        store.merge((1...10).map(entry), epoch: epoch)
        store.merge([entry(13)], epoch: epoch)
        XCTAssertEqual(store.cursor, 10)
        store.merge([entry(11), entry(12)], epoch: epoch)
        XCTAssertEqual(store.cursor, 13)
        XCTAssertEqual(store.entries.map(\.seq), Array(1...13))
    }

    func testDuplicateRealtimeAndCatchUpMergeOnce() {
        var store = TranscriptStore()
        store.merge([entry(2), entry(1)], epoch: epoch)
        store.merge([entry(1), entry(2)], epoch: epoch)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.cursor, 2)
    }

    func testRestartPreservesVisibleHistoryAndRejectsLateOldPage() {
        var store = TranscriptStore()
        store.merge([entry(1)], epoch: epoch)
        let next = "e2444840-9dc0-41d1-b245-5ffdce74fad2"
        store.merge([entry(1)], epoch: next)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(store.gapMessage.isEmpty)
        XCTAssertFalse(store.merge([entry(2)], epoch: epoch))
        XCTAssertEqual(store.epoch, next)
        XCTAssertEqual(store.cursor, 1)
    }

    func testTruncatedHistoryExplicitlyAdvancesLostPrefix() {
        var store = TranscriptStore()
        store.merge([entry(13)], epoch: epoch)
        store.merge([entry(11), entry(12), entry(13)], epoch: epoch, oldest: 11, truncated: true)
        XCTAssertEqual(store.cursor, 13)
        XCTAssertFalse(store.gapMessage.isEmpty)
    }

    func testNewMeetingHasIndependentCursor() {
        var store = TranscriptStore()
        store.merge([entry(1)], epoch: epoch)
        store = TranscriptStore()
        XCTAssertEqual(store.cursor, 0)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.gapMessage.isEmpty)
    }
}
