import XCTest
@testable import VoiceMemo

@MainActor final class CB08DeviceManagementTests: XCTestCase {
    final class Device: CB08DeviceControlling {
        var connected = true
        var connectionID: UUID? = UUID()
        var recordState: CB08RecordingState? = .recording
        var onPacket: ((Data) -> Void)?
        var onLoss: (() -> Void)?
        var commands: [CB08RecordAction] = []
        var confirms = true
        var afterAction: (() -> Void)?
        var queryResult: CB08RecordingState?
        func refreshRecordState(timeout: Duration) async -> CB08RecordingState? { queryResult ?? recordState }
        func command(_ action: CB08RecordAction) { commands.append(action) }
        func waitForRecordAction(timeout: Duration) async -> Bool {
            if confirms { recordState = .stopped }
            afterAction?()
            return confirms
        }
        func discardQueuedPackets() {}
    }
    func testIndependentStopWaitsForCleanupAndQueriesResult() async throws {
        let device = Device(); let manager = CB08DeviceManager(device: device)
        var cleaned = false
        let operation = try XCTUnwrap(manager.stopIndependent {
            XCTAssertTrue(device.commands.isEmpty)
            cleaned = true; return true
        })
        XCTAssertTrue(manager.busy)
        XCTAssertNil(manager.stopIndependent { true })
        let result = await operation.value
        XCTAssertTrue(result); XCTAssertTrue(cleaned)
        XCTAssertEqual(device.commands, [.stop]); XCTAssertFalse(manager.busy)
        XCTAssertNil(manager.problem)
    }
    func testFailedCleanupNeverSendsDeviceCommand() async throws {
        let device = Device(); let manager = CB08DeviceManager(device: device)
        let operation = try XCTUnwrap(manager.stopIndependent { false })
        let result = await operation.value
        XCTAssertFalse(result); XCTAssertTrue(device.commands.isEmpty)
        XCTAssertNotNil(manager.problem)
    }
    func testMissingStopAckRemainsUnconfirmedAndCanRetry() async throws {
        let device = Device(); device.confirms = false
        let manager = CB08DeviceManager(device: device)
        let first = try XCTUnwrap(manager.stopIndependent { true })
        let failed = await first.value
        XCTAssertFalse(failed); XCTAssertNotNil(manager.problem)
        device.confirms = true
        let second = try XCTUnwrap(manager.stopIndependent { true })
        let confirmed = await second.value
        XCTAssertTrue(confirmed); XCTAssertNil(manager.problem)
        XCTAssertEqual(device.commands, [.stop, .stop])
    }
    func testChangedConnectionCannotConfirmOriginalStop() async throws {
        let device = Device(); let manager = CB08DeviceManager(device: device)
        device.afterAction = { device.connectionID = UUID() }
        let operation = try XCTUnwrap(manager.stopIndependent { true })
        let result = await operation.value
        XCTAssertFalse(result); XCTAssertEqual(device.commands, [.stop])
    }
    func testRecordingQueryCannotOverrideMissingStopAckOrContradictoryResult() async throws {
        let device = Device(); device.queryResult = .recording
        let manager = CB08DeviceManager(device: device)
        let operation = try XCTUnwrap(manager.stopIndependent { true })
        let result = await operation.value
        XCTAssertFalse(result); XCTAssertNotNil(manager.problem)
    }
    func testCapturePreflightRejectsIndependentRecordingWithoutCommands() async {
        let device = Device(); let manager = CB08DeviceManager(device: device)
        do { try await manager.checkForCapture(canResume: false); XCTFail("adopted independent recording") }
        catch CB08InputError.alreadyRecording(_) {} catch { XCTFail("\(error)") }
        XCTAssertTrue(device.commands.isEmpty); XCTAssertFalse(manager.busy)
    }
    func testCapturePreflightAllowsOnlyOwnedPause() async throws {
        let device = Device(); device.recordState = .paused
        let manager = CB08DeviceManager(device: device)
        do { try await manager.checkForCapture(canResume: false); XCTFail("unowned pause resumed") }
        catch CB08InputError.pausedRecordingNotOwned {} catch { XCTFail("\(error)") }
        try await manager.checkForCapture(canResume: true)
        XCTAssertTrue(device.commands.isEmpty)
    }
    private func connect(_ bridge: CB08SDKBridge) {
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
    }
    func testIndependentRecordingIsRedWarningAndOnlyStopIsAvailable() {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.input.adopt(InputBinding(kind: .external, capturePort: .pcmFeed, sourceTag: .face2face))
        connect(f.input.device)
        f.input.device.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":1}}"#)
        XCTAssertTrue(f.assistant.deviceIndependentWarning)
        XCTAssertFalse(f.assistant.deviceCanStart); XCTAssertFalse(f.assistant.deviceCanPause)
        XCTAssertTrue(f.assistant.deviceCanStop)
        XCTAssertTrue(f.assistant.requestDeviceStop())
        XCTAssertTrue(f.assistant.deviceStopMessage.contains("不会创建或结束App会议"))
        XCTAssertFalse(f.assistant.deviceCanStop)
        f.assistant.cancelDeviceStop()
        XCTAssertEqual(f.starts, 0); XCTAssertEqual(f.ends, 0)
    }
    func testReconnectInvalidatesStopConfirmationAndClearsKeySummary() {
        let f = BusinessFixture(); defer { f.cleanUp() }
        connect(f.input.device)
        f.input.device.receiveEvent(#"{"cmd":8,"state":0,"data":{"event":3}}"#)
        XCTAssertTrue(f.input.device.hardwareSummary.contains("event=3"))
        XCTAssertTrue(f.assistant.requestDeviceStop())
        f.input.device.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":0}}"#)
        connect(f.input.device)
        XCTAssertEqual(f.input.device.hardwareSummary, "本次连接尚无实体键请求")
        f.assistant.confirmDeviceStop()
        XCTAssertNotNil(f.assistant.message)
        XCTAssertFalse(f.input.deviceManagement.busy)
    }
    func testConsoleStopUsesMeetingEndCommandAndExplainsScope() {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.input.adopt(InputBinding(kind: .external, capturePort: .pcmFeed, sourceTag: .face2face))
        connect(f.input.device)
        f.meeting.capturePreparing()
        XCTAssertTrue(f.assistant.requestDeviceStop())
        XCTAssertTrue(f.assistant.deviceStopMessage.contains("结束本次会议"))
        f.assistant.confirmDeviceStop()
        XCTAssertEqual(f.ends, 1)
        XCTAssertEqual(f.starts, 0)
    }
    func testPauseAndResumeKeyRequestsAreRecordedBeforeBusinessRejection() {
        let f = BusinessFixture(); defer { f.cleanUp() }
        connect(f.input.device)
        for key in [5, 7] {
            f.input.device.receiveEvent("{\"cmd\":8,\"state\":0,\"data\":{\"event\":\(key)}}")
            XCTAssertEqual(f.input.device.hardwareButtonEvents[key], 1)
            XCTAssertTrue(f.input.device.hardwareSummary.contains("event=\(key)"))
        }
        XCTAssertEqual(f.starts, 0); XCTAssertEqual(f.ends, 0)
    }
    func testIndependentStateQueryIsNotReportedAsConfirmedStop() {
        let f = BusinessFixture(); defer { f.cleanUp() }
        connect(f.input.device)
        f.input.device.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":2}}"#)
        XCTAssertEqual(f.input.device.recordState, .inactive)
        XCTAssertTrue(f.assistant.deviceCanStop)
        XCTAssertTrue(f.assistant.deviceControlStatus.contains("停止或暂停待确认"))
    }
    func testEndedDisplayStaysEmptyForLateMessagesAndResetRestoresIt() {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.connection.onTranscript?("final", "speaker", 0, "before", nil, 1, [:])
        XCTAssertEqual(f.meeting.lines.count, 1)
        f.meeting.clearMeetingDisplay()
        f.connection.onTranscript?("final", "speaker", 0, "late", nil, 2, [:])
        f.connection.onTranscript?("partial", "speaker", 0, "late", nil, 2, [:])
        f.connection.onTranscript?("summary", "speaker", 0, "late", nil, 2, [:])
        XCTAssertTrue(f.meeting.lines.isEmpty); XCTAssertTrue(f.meeting.partials.isEmpty)
        XCTAssertTrue(f.meeting.summaries.isEmpty)
        f.meeting.resetCurrentMeetingData()
        f.connection.onTranscript?("final", "speaker", 0, "new", nil, 3, [:])
        XCTAssertEqual(f.meeting.lines.map(\.text), ["new"])
    }
}
