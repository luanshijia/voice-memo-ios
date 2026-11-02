import Foundation
import XCTest
@testable import VoiceMemo

@MainActor final class SummaryControlsTests: XCTestCase {
    private func projection(purpose: String = "meeting") throws -> CaptureView {
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        var object = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
        object["purpose"] = purpose
        return try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func status(_ f: BusinessFixture, mode: String, code: String, requestID: String? = nil) {
        var raw: [String: Any] = ["schema_version": 2, "session_id": f.meeting.sessionID,
            "mode": mode, "code": code]
        if let requestID { raw["request_id"] = requestID }
        f.connection.onTranscript?("sumstatus", "", 0, code, nil, 1, raw)
    }

    func testModeColorWaitsForConfirmationAndAutoStillAllowsModeSelection() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.meeting.applyCapture(try projection())
        f.meeting.setSumMode("manual")
        XCTAssertEqual(f.meeting.sumMode, "auto")
        XCTAssertEqual(f.meeting.pendingSumMode, "manual")
        status(f, mode: "auto", code: "wait_period")
        XCTAssertEqual(f.meeting.pendingSumMode, "manual")
        status(f, mode: "manual", code: "wait_manual")
        XCTAssertEqual(f.meeting.sumMode, "manual")
        XCTAssertNil(f.meeting.pendingSumMode)
        f.meeting.setSumMode("auto")
        status(f, mode: "auto", code: "wait_period")
        XCTAssertEqual(f.meeting.sumMode, "auto")
    }

    func testAutoShortPressDoesNothingAndManualRequestsAreDeduplicated() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.meeting.applyCapture(try projection())
        f.meeting.capturePreparing()
        f.meeting.requestSummary()
        XCTAssertFalse(f.meeting.summaryRequestPending)
        f.meeting.setSumMode("manual")
        status(f, mode: "manual", code: "wait_manual")
        f.meeting.requestSummary()
        XCTAssertTrue(f.meeting.summaryRequestPending)
        f.meeting.requestSummary()
        XCTAssertTrue(f.meeting.summaryRequestPending)
        status(f, mode: "manual", code: "wait_manual")
        XCTAssertTrue(f.meeting.summaryRequestPending, "Unrelated periodic status must not settle a click")
        f.meeting.clearMeetingDisplay()
        XCTAssertFalse(f.meeting.summaryRequestPending)
    }

    func testMemoCaptureBlocksMeetingSummaryAndNormalMeetingBlocksMemo() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.meeting.setSumMode("manual")
        f.meeting.applyCapture(try projection(purpose: "memo"))
        f.meeting.capturePreparing()
        XCTAssertTrue(f.assistant.memoActive)
        f.meeting.requestSummary()
        XCTAssertFalse(f.meeting.summaryRequestPending)
        let g = BusinessFixture(); defer { g.cleanUp() }
        g.meeting.applyCapture(try projection())
        g.meeting.capturePreparing()
        XCTAssertFalse(g.assistant.memoButtonEnabled)
    }

    func testMemoPurposeIsPersistedInTheDurableStartRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingRequestStore(root: root)
        let config = LiveKitConfig(url: "wss://example.test", device: "phone", userID: "user")
        try MeetingClient.queueCaptureStart(config: config, revision: 1, input: .phone,
            meetingID: nil, purpose: "memo", store: store)
        let saved = try XCTUnwrap(try store.read("vm.pendingCaptureV2"))
        struct StoredStart: Decodable { let body: Data }
        let pending = try JSONDecoder().decode(StoredStart.self, from: saved)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: pending.body) as? [String: Any])
        XCTAssertEqual(body["purpose"] as? String, "memo")
        XCTAssertThrowsError(try MeetingClient.queueCaptureStart(config: config, revision: 1, input: .phone,
            meetingID: nil, purpose: "meeting", store: store))
        XCTAssertEqual(try store.read("vm.pendingCaptureV2"), saved)
    }
}
