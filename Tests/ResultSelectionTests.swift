import XCTest
@testable import VoiceMemo

@MainActor final class ResultSelectionTests: XCTestCase {
    private func projection(id: String, purpose: String, time: String) throws -> CaptureView {
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        var object = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
        object["meeting_id"] = id
        object["purpose"] = purpose
        object["created_at"] = time
        object["desired_state"] = "ended"
        object["observed_state"] = "stopped"
        return try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testOlderMeetingCannotReplaceLatestMemoSelection() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let old = try projection(id: "00000000-0000-4000-8000-000000000001", purpose: "meeting", time: "2026-11-02T14:00:00.000Z")
        let memo = try projection(id: "00000000-0000-4000-8000-000000000002", purpose: "memo", time: "2026-11-02T15:00:00.000Z")
        f.meeting.applyCapture(old)
        f.meeting.applyCapture(memo)
        f.meeting.applyCapture(old)
        XCTAssertEqual(f.meeting.latestResultOperation?.id, memo.meetingID)
        XCTAssertNil(f.meeting.latestResultText)
        XCTAssertNil(f.meeting.latestMemoReport)
        XCTAssertEqual(f.meeting.latestResultStatus, "待办生成中")
    }

    func testNewMeetingReplacesMemoAndShowsRecordingStatus() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let memo = try projection(id: "00000000-0000-4000-8000-000000000001", purpose: "memo", time: "2026-11-02T14:00:00.000Z")
        let meeting = try projection(id: "00000000-0000-4000-8000-000000000002", purpose: "meeting", time: "2026-11-02T15:00:00.000Z")
        f.meeting.applyCapture(memo)
        f.meeting.applyCapture(meeting)
        f.meeting.capturePreparing()
        XCTAssertEqual(f.meeting.latestResultOperation?.purpose, "meeting")
        XCTAssertEqual(f.meeting.latestResultStatus, "会议录音中")
    }

    func testSelectionRoundTripAndLegacyFallback() throws {
        let operation = ResultOperation(id: "latest", purpose: "memo", createdAt: "2026-11-02T15:00:00.000Z")
        let restored = try JSONDecoder().decode(ResultOperation.self, from: JSONEncoder().encode(operation))
        XCTAssertEqual(restored, operation)
        XCTAssertFalse(operation.isNewer(than: restored))
        XCTAssertTrue(operation.isNewer(than: ResultOperation(id: "legacy", purpose: "meeting", createdAt: "")))
        XCTAssertFalse(ResultOperation(id: "legacy", purpose: "meeting", createdAt: "").isNewer(than: operation))
        XCTAssertEqual(ResultOperation(id: "legacy", purpose: "memo", createdAt: "").label, "待办 · 时间未知")
        XCTAssertTrue(operation.isNewer(than: ResultOperation(id: operation.id, purpose: "memo", createdAt: "")))
    }

    private func report(id: String, purpose: String, text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["meeting_id": id, "report": [
            "meta": ["purpose": purpose], "summary": ["title": text], "segments": []]])
    }

    func testLateReportCannotReplaceSelectedOperationOrShowOldTextWhileWaiting() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let oldID = "00000000-0000-4000-8000-000000000001"
        let newID = "00000000-0000-4000-8000-000000000002"
        f.meeting.applyCapture(try projection(id: oldID, purpose: "meeting", time: "2026-11-02T14:00:00.000Z"))
        try f.meeting.storeReport(report(id: oldID, purpose: "meeting", text: "旧会议"), meetingID: oldID, persist: false)
        f.meeting.applyCapture(try projection(id: newID, purpose: "memo", time: "2026-11-02T15:00:00.000Z"))
        XCTAssertNil(f.meeting.latestResultText)
        try f.meeting.storeReport(report(id: oldID, purpose: "meeting", text: "迟到旧会议"), meetingID: oldID, persist: false)
        XCTAssertNil(f.meeting.latestResultText)
        try f.meeting.storeReport(report(id: newID, purpose: "memo", text: "最新待办"), meetingID: newID, persist: false)
        XCTAssertTrue(f.meeting.latestResultText?.contains("最新待办") == true)
        XCTAssertEqual(f.meeting.latestMemoReport?.id, newID)
        XCTAssertEqual(f.meeting.finalReportMeetingID, oldID)
    }
}
