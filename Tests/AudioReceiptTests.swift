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
}
