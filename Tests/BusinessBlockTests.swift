import Combine
import XCTest
@testable import VoiceMemo

@MainActor final class TestSessionPort: LegacySessionPort, ObservableObject {
    @Published var isRecording = false
    var wantsCapture = false
    var terminating = false
    var configurationLocked = false
    var configuration = ConfigSnapshot(serverURL: "wss://example.test:7443", deviceID: "test-phone",
                                       userID: "test-user", revision: 1, hasCredential: true)
    var meeting = MeetingContext.empty
    var board = StatusBoard()
    var starts = 0
    var stops = 0
    var ends = 0
    var checks = 0
    var writes = 0
    var presentation: SessionPresentation {
        SessionPresentation(isRecording: isRecording, wantsToContinue: wantsCapture,
                            networkOK: true, terminating: terminating, meeting: meeting)
    }
    func updateConfiguration(_ field: ConfigurationField, value: String) { writes += 1 }
    func resetConfiguration() { writes += 1 }
    func startCapture() { starts += 1; wantsCapture = true; isRecording = true }
    func stopCapture() { stops += 1; wantsCapture = false; isRecording = false }
    func endMeeting() { ends += 1 }
    func checkConnection() async { checks += 1 }
}

@MainActor final class BusinessBlockTests: XCTestCase {
    func testPreparationDoesNotActivateCapture() async {
        let port = TestSessionPort()
        let assistant = MeetingAssistant(port: port)
        assistant.selectInput(.phone)
        _ = assistant.settings.snapshot
        _ = assistant.readiness
        await assistant.checkConnection()
        XCTAssertEqual(port.checks, 1)
        XCTAssertEqual(port.starts, 0)
        XCTAssertEqual(port.stops, 0)
        XCTAssertEqual(port.ends, 0)
    }

    func testLockedConfigurationRejectsAllEditsAndReset() async {
        let port = TestSessionPort()
        let settings = SettingsWorker(port: port)
        port.configurationLocked = true
        for field in [ConfigurationField.serverURL, .deviceID, .userID, .credential] {
            XCTAssertFalse(settings.update(field, value: "changed"))
        }
        settings.reset()
        XCTAssertEqual(port.writes, 0)
        port.configurationLocked = false
        XCTAssertTrue(settings.update(.deviceID, value: "changed"))
        XCTAssertEqual(port.writes, 1)
    }

    func testExternalSelectionIsHonestAndPreservesPhoneBinding() async {
        let port = TestSessionPort()
        let assistant = MeetingAssistant(port: port)
        assistant.selectInput(.external)
        XCTAssertEqual(assistant.input.binding, .phone)
        XCTAssertNotNil(assistant.message)
        XCTAssertEqual(port.starts, 0)
    }

    func testConnectionProjectionCannotInventRawAudioReceipt() async {
        let port = TestSessionPort()
        let worker = ConnectionWorker(port: port)
        port.board.received.observed = MetricValue(value: 120, unit: "秒")
        XCTAssertEqual(worker.recognitionSeconds, 120)
        XCTAssertEqual(worker.desktopAudioEvidence, "尚无按分段统计的实际样本证据")
    }
}
