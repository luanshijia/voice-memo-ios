import XCTest
@testable import VoiceMemo

@MainActor final class NavigationStateTests: XCTestCase {
    func testRepeatedNavigationKeepsCaptureAndDoesNoIO() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.assistant.accept(.start)
        for _ in 0..<5 {
            for page in WorkspacePage.allCases {
                f.assistant.page = page
                _ = f.assistant.meeting.projection
                _ = f.assistant.connection.media
                _ = f.assistant.settings.snapshot
                _ = f.assistant.input.binding
            }
        }
        XCTAssertTrue(f.meeting.isRecording)
        XCTAssertEqual(f.starts, 1)
        XCTAssertEqual(f.checks, 0)
        XCTAssertEqual(f.settings.snapshot.revision, 0)
    }
}
