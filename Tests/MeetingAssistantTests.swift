import XCTest
@testable import VoiceMemo

@MainActor final class MeetingAssistantTests: XCTestCase {
    func testDuplicateStartAndEndDoNotToggleCaptureBackOn() {
        let port = TestSessionPort()
        let assistant = MeetingAssistant(port: port)
        XCTAssertEqual(assistant.accept(.start), .submitted)
        _ = assistant.accept(.start)
        XCTAssertEqual(port.starts, 1)
        XCTAssertEqual(assistant.accept(.end), .submitted)
        _ = assistant.accept(.end)
        XCTAssertEqual(port.stops, 1)
        XCTAssertEqual(port.starts, 1)
        XCTAssertFalse(port.isRecording)
    }

    func testUnsupportedPauseCannotStopOrEndMeeting() {
        let port = TestSessionPort()
        let assistant = MeetingAssistant(port: port)
        assistant.accept(.start)
        for action in [CaptureAction.pause, .resume] {
            if case .rejected = assistant.accept(action) {} else { XCTFail("unsupported action accepted") }
        }
        XCTAssertTrue(port.isRecording)
        XCTAssertEqual(port.stops, 0)
        XCTAssertEqual(port.ends, 0)
    }

    func testInvalidConfigurationFailsBeforeAnyCaptureCommand() {
        let port = TestSessionPort()
        port.configuration = ConfigSnapshot(serverURL: "http://example.test", deviceID: "phone",
            userID: "user", revision: 2, hasCredential: false)
        let assistant = MeetingAssistant(port: port)
        if case .rejected = assistant.accept(.start) {} else { XCTFail("invalid config accepted") }
        XCTAssertEqual(port.starts, 0)
    }

    func testLateLegacyObservationProjectsWithoutAnotherStart() {
        let port = TestSessionPort()
        let assistant = MeetingAssistant(port: port, changes: port.objectWillChange)
        assistant.accept(.start)
        port.isRecording = false // SDK disconnect keeps the user's recording intent.
        XCTAssertTrue(assistant.meeting.wantsCapture)
        XCTAssertFalse(assistant.meeting.isRecording)
        XCTAssertEqual(port.starts, 1)
    }

    func testRecoveryCannotCreateMeetingWhenNoOriginalMeetingExists() {
        let port = TestSessionPort()
        let assistant = MeetingAssistant(port: port)
        if case .rejected = assistant.accept(.recover) {} else { XCTFail("recovery created meeting") }
        XCTAssertEqual(port.starts, 0)
    }
}
