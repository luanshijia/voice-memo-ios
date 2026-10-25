import XCTest
@testable import VoiceMemo

@MainActor final class NavigationStateTests: XCTestCase {
    func testRepeatedNavigationKeepsCaptureAndDoesNoIO() async {
        let port = TestSessionPort()
        let assistant = MeetingAssistant(port: port)
        assistant.accept(.start)
        for _ in 0..<5 {
            for page in WorkspacePage.allCases {
                assistant.page = page
                _ = assistant.meeting.projection
                _ = assistant.connection.media
                _ = assistant.settings.snapshot
                _ = assistant.input.binding
            }
        }
        XCTAssertTrue(port.isRecording)
        XCTAssertEqual(port.starts, 1)
        XCTAssertEqual(port.stops, 0)
        XCTAssertEqual(port.checks, 0)
        XCTAssertEqual(port.writes, 0)
    }
}
