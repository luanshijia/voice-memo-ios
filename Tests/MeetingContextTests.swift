import XCTest
@testable import VoiceMemo

final class MeetingContextTests: XCTestCase {
    private func context(_ status: String) throws -> MeetingContext {
        let body = """
        {"state_revision":1,"meeting":{"meeting_id":"7d444840-9dc0-11d1-b245-5ffdce74fad2",
        "status":"\(status)","channels":{"mic":{"status":"stopped","generation":1}}},"pending_reports":[]}
        """
        return MeetingContext(view: try JSONDecoder().decode(DeviceMeetingView.self, from: Data(body.utf8)))
    }

    func testFinishingAllowsNewCaptureButCannotRecoverOldMeeting() throws {
        let meeting = try context("finishing")
        XCTAssertTrue(meeting.hasOpenMeeting)
        XCTAssertTrue(meeting.canStartNew())
        XCTAssertFalse(meeting.meetingAcceptsRecovery)
        let action = SessionPresentation(isRecording: false, wantsToContinue: true,
            networkOK: true, terminating: false, meeting: meeting).primaryAction
        XCTAssertEqual(action.title, "开启")
        XCTAssertTrue(action.enabled)
    }

    func testActiveMeetingJoinsExistingCapture() throws {
        let meeting = try context("active")
        XCTAssertFalse(meeting.canStartNew())
        XCTAssertTrue(meeting.meetingAcceptsRecovery)
    }

    func testUnknownMeetingStateDoesNotInventRecoveryPermission() throws {
        XCTAssertFalse(try context("future_state").meetingAcceptsRecovery)
    }

    func testTerminationDisablesPrimaryAndRepeatedTermination() throws {
        let state = SessionPresentation(isRecording: false, wantsToContinue: true,
            networkOK: true, terminating: true, meeting: try context("active"))
        XCTAssertFalse(state.primaryAction.enabled)
        XCTAssertFalse(state.terminateAction.enabled)
    }
}
