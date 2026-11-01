import XCTest
@testable import VoiceMemo

@MainActor final class AudioReceiptTests: XCTestCase {
    func testReceiptCannotBeReusedAcrossSegmentOrGeneration() throws {
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        var object = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
        let view = try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
        let receipt = CaptureAudioReceipt(meetingID: view.meetingID, segmentID: view.segmentID,
            generation: view.generation, channel: view.channel, sampleRate: 16000,
            receivedSamples: 1280, lastReceivedAt: 100)
        XCTAssertTrue(receipt.matches(view))
        object["generation"] = view.generation + 1
        let next = try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(receipt.matches(next))
        object["generation"] = view.generation
        object["segment_id"] = UUID().uuidString.lowercased()
        let segment = try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(receipt.matches(segment))
    }
    func testOlderServerWithoutReceiptStillDecodes() throws {
        let view = try JSONDecoder().decode(CaptureDeviceView.self,
            from: Data("{\"meeting\":null,\"pending_reports\":[]}".utf8))
        XCTAssertNil(view.audioReceipt)
    }
    private func receipt(samples: Int = 16000, age: Double? = nil,
                         segment: String = "segment", generation: Int = 1) -> CaptureAudioReceipt {
        CaptureAudioReceipt(meetingID: "meeting", segmentID: segment, generation: generation,
            channel: "mic", sampleRate: 16000, receivedSamples: samples,
            lastReceivedAt: samples == 0 ? 0 : 100, lastReceivedAgeSeconds: age)
    }
    func testZeroSamplesAndOldServerAgeCannotProtectCapture() {
        var freshness = AudioReceiptFreshness()
        freshness.update(receipt(samples: 0, age: 0), now: 100)
        XCTAssertFalse(freshness.isFresh(now: 100))
        freshness.update(receipt(age: 20), now: 100)
        XCTAssertFalse(freshness.isFresh(now: 100))
    }
    func testRepeatedHTTPResponseDoesNotRenewAudioDeadline() {
        var freshness = AudioReceiptFreshness()
        freshness.update(receipt(age: 2), now: 100)
        XCTAssertEqual(freshness.remaining(now: 100), 13)
        freshness.update(receipt(age: 2), now: 110)
        XCTAssertEqual(freshness.remaining(now: 110), 3)
        XCTAssertFalse(freshness.isFresh(now: 114))
        freshness.update(receipt(samples: 32000, age: 0), now: 115)
        XCTAssertTrue(freshness.isFresh(now: 115))
    }
    func testLegacyServerRequiresProgressAndCannotReuseOtherSegment() {
        var freshness = AudioReceiptFreshness()
        freshness.update(receipt(), now: 100)
        XCTAssertFalse(freshness.isFresh(now: 100))
        freshness.update(receipt(samples: 32000), now: 105)
        XCTAssertTrue(freshness.isFresh(now: 105))
        freshness.update(receipt(samples: 32000), now: 119)
        XCTAssertFalse(freshness.isFresh(now: 121))
        freshness.update(receipt(samples: 48000, segment: "new"), now: 122)
        XCTAssertFalse(freshness.isFresh(now: 122))
        freshness.update(receipt(samples: 64000, segment: "new"), now: 123)
        XCTAssertTrue(freshness.isFresh(now: 123))
        freshness.update(receipt(samples: 80000, segment: "new", generation: 2), now: 124)
        XCTAssertFalse(freshness.isFresh(now: 124))
    }
    func testMissingReceiptClearsFreshness() {
        var freshness = AudioReceiptFreshness()
        freshness.update(receipt(age: 0), now: 100)
        freshness.update(nil, now: 101)
        XCTAssertFalse(freshness.isFresh(now: 101))
    }
}
