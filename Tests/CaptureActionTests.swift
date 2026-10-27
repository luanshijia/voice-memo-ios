import XCTest
@testable import VoiceMemo

@MainActor final class CaptureActionTests: XCTestCase {
    func projection(_ changes: [String: Any] = [:]) throws -> CaptureView {
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        var object = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
        changes.forEach { object[$0.key] = $0.value }
        return try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testSharedV2FixturesRejectInvalidResponses() throws {
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        for item in fixture["valid"] as? [[String: Any]] ?? [] { XCTAssertNil(SessionControlV2Contract.responseProblem("capture", object: item)) }
        for item in fixture["invalid"] as? [[String: Any]] ?? [] { XCTAssertNotNil(SessionControlV2Contract.responseProblem("capture", object: item)) }
    }
    func testResumeRequiresConfirmedPauseAndRecoverDoesNotResumeIt() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        var resumes = 0
        let assistant = MeetingAssistant(meeting: f.meeting, commands: MeetingCommands(
            start: {}, end: {}, pause: {}, resume: { resumes += 1 }))
        f.meeting.applyCapture(try projection(["desired_state":"paused","observed_state":"pending"]))
        if case .rejected = assistant.accept(.resume) {} else { XCTFail("unconfirmed pause resumed") }
        if case .rejected = assistant.accept(.recover) {} else { XCTFail("recover resumed paused input") }
        f.meeting.applyCapture(try projection(["desired_state":"paused","observed_state":"paused"]))
        XCTAssertEqual(assistant.accept(.resume), .submitted)
        XCTAssertEqual(resumes,1)
    }
    func testInterruptedPhoneCaptureCanStillRequestPause() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        var pauses = 0
        let assistant = MeetingAssistant(meeting: f.meeting, commands: MeetingCommands(
            start: {}, end: {}, pause: { pauses += 1 }))
        f.meeting.applyCapture(try projection())
        f.meeting.capturePreparing()
        f.meeting.captureInterrupted()
        XCTAssertFalse(f.meeting.isRecording)
        XCTAssertTrue(f.meeting.wantsCapture)
        XCTAssertEqual(assistant.accept(.pause), .submitted)
        XCTAssertEqual(pauses, 1)
    }

    func testOlderActionRevisionCannotOverwriteCurrentProjection() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.meeting.applyCapture(try projection(["state_revision":3,"desired_state":"ended"]))
        f.meeting.applyCapture(try projection(["state_revision":2,"desired_state":"active"]))
        XCTAssertEqual(f.meeting.capture?.desiredState,"ended")
    }
    func testSavedProjectionDoesNotPretendFreshComputerEvidence() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.meeting.applyCapture(try projection(["desired_state":"paused"]), confirmed: false)
        XCTAssertFalse(f.meeting.projection.isFresh())
        XCTAssertEqual(f.meeting.captureStatusText,"会议状态待对账")
    }
}
