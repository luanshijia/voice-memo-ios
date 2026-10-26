import XCTest
@testable import VoiceMemo

@MainActor final class MeetingAssistantTests: XCTestCase {
    func testDuplicateStartAndEndDoNotToggleCaptureBackOn() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        XCTAssertEqual(f.assistant.accept(.start), .submitted)
        _ = f.assistant.accept(.start)
        XCTAssertEqual(f.starts, 1)
        XCTAssertEqual(f.assistant.accept(.end), .submitted)
        _ = f.assistant.accept(.end)
        XCTAssertEqual(f.ends, 1)
        XCTAssertEqual(f.starts, 1)
        XCTAssertFalse(f.meeting.isRecording)
    }
    func testUnsupportedPauseCannotStopOrEndMeeting() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.assistant.accept(.start)
        for action in [CaptureAction.pause, .resume] {
            if case .rejected = f.assistant.accept(action) {} else { XCTFail("unsupported action accepted") }
        }
        XCTAssertTrue(f.meeting.isRecording)
        XCTAssertEqual(f.ends, 0)
    }
    func testInvalidConfigurationFailsBeforeAnyCaptureCommand() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.settings.update(.serverURL, value: "http://example.test")
        f.settings.update(.credential, value: "")
        if case .rejected = f.assistant.accept(.start) {} else { XCTFail("invalid config accepted") }
        XCTAssertEqual(f.starts, 0)
    }
    func testPassiveDisconnectPreservesIntentWithoutAnotherStart() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.assistant.accept(.start)
        f.meeting.captureInterrupted()
        XCTAssertTrue(f.assistant.meeting.wantsCapture)
        XCTAssertFalse(f.assistant.meeting.isRecording)
        XCTAssertEqual(f.starts, 1)
    }
    func testRecoveryCannotCreateMeetingWhenNoOriginalMeetingExists() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        if case .rejected = f.assistant.accept(.recover) {} else { XCTFail("recovery created meeting") }
        XCTAssertEqual(f.starts, 0)
    }
}
