import XCTest
@testable import VoiceMemo

final class ServerAvailabilityTests: XCTestCase {
    func testSuccessExpiresAndCannotAuthorizeChangedRegistration() {
        var state = ServerAvailability(); let now = Date()
        XCTAssertEqual(state.phase(revision: 1, now: now), .checking)
        state.record(success: true, revision: 1, now: now)
        XCTAssertEqual(state.phase(revision: 1, now: now), .ready)
        XCTAssertEqual(state.phase(revision: 2, now: now), .checking)
        XCTAssertEqual(state.phase(revision: 1, now: now.addingTimeInterval(46)), .checking)
    }
    func testOneFailureBlocksNewStartsButOnlyRepeatedFailureConfirmsUnavailable() {
        var state = ServerAvailability(); let now = Date()
        state.record(success: true, revision: 1, now: now)
        state.record(success: false, revision: 1, now: now)
        XCTAssertEqual(state.phase(revision: 1, now: now), .checking)
        state.record(success: false, revision: 1, now: now)
        XCTAssertEqual(state.phase(revision: 1, now: now), .unavailable)
    }
    func testFailureBackoffIsBoundedAndSuccessfulRetryRestoresReadiness() {
        var state = ServerAvailability(); let now = Date()
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            state.record(success: false, revision: 1, now: now)
            delays.append(state.retryAt.timeIntervalSince(now))
        }
        XCTAssertEqual(delays, [5, 15, 30, 60, 60, 60])
        state.record(success: true, revision: 1, now: now)
        XCTAssertEqual(state.phase(revision: 1, now: now), .ready)
        XCTAssertEqual(state.failures, 0)
    }
}

@MainActor final class ServerGateTests: XCTestCase {
    private func operations(view: @escaping @MainActor (LiveKitConfig) async throws -> CaptureDeviceView) -> CaptureControlOperations {
        CaptureControlOperations(queueStart: { _, _, _, _ in }, queueAction: { _, _, _, _ in },
            flush: { nil }, view: view, observe: { _, _, _ in }, hasPending: { false })
    }
    func testTCPReachabilityAloneDoesNotOpenGate() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let connection = ConnectionWorker(settings: f.settings, probeHost: { _, _ in true })
        await connection.preflightControl()
        XCTAssertEqual(connection.network, .connected)
        XCTAssertFalse(connection.serverReady)
    }
    func testAuthenticatedEmptyMeetingResponseOpensGate() async throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let connection = ConnectionWorker(settings: f.settings,
            captureControl: operations { _ in CaptureDeviceView(meeting: nil, pendingReports: []) })
        _ = try await connection.captureView(config: f.settings.config)
        XCTAssertTrue(connection.serverReady)
        XCTAssertEqual(connection.network, .connected)
    }
    func testOldRegistrationResponseCannotOpenGateAfterSettingsChange() async throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let connection = ConnectionWorker(settings: f.settings, captureControl: operations { _ in
            XCTAssertTrue(f.settings.update(.serverURL, value: "wss://changed.example.test"))
            return CaptureDeviceView(meeting: nil, pendingReports: [])
        })
        _ = try await connection.captureView(config: f.settings.config)
        XCTAssertFalse(connection.serverReady)
    }
    func testUnavailableServerBlocksAllBluetoothActivationPaths() {
        let input = InputWorker()
        if case .rejected = input.select(.external) {} else { XCTFail("offline selection permitted") }
        input.adopt(InputBinding(kind: .external, capturePort: .pcmFeed, sourceTag: .face2face))
        input.device.activate(); input.device.scan()
        input.device.connect(CB08Device(name: "CB08", address: "test", productType: "test"))
        XCTAssertFalse(input.device.isSDKInitialized)
        XCTAssertFalse(input.device.isScanning)
        XCTAssertFalse(input.device.connected)
        XCTAssertEqual(input.device.connectionPhase, .disconnected)
    }
    func testSharedGateBlocksScreenAndHardwareStart() {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.connection.recordServerOutcome(success: false, revision: f.settings.snapshot.revision)
        XCTAssertFalse(f.assistant.canSelectInput)
        if case .rejected = f.assistant.accept(.start) {} else { XCTFail("offline start permitted") }
        f.input.adopt(InputBinding(kind: .external, capturePort: .pcmFeed, sourceTag: .face2face))
        XCTAssertFalse(f.assistant.hardware(.start))
        XCTAssertEqual(f.starts, 0)
        XCTAssertFalse(f.input.device.isSDKInitialized)
    }
    func testIdleServerLossDisconnectsWithoutCommandingIndependentRecording() async throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.input.adopt(InputBinding(kind: .external, capturePort: .pcmFeed, sourceTag: .face2face))
        f.input.device.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        f.input.device.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":1}}"#)
        f.connection.recordServerOutcome(success: false, revision: f.settings.snapshot.revision)
        XCTAssertTrue(f.input.device.connected)
        f.connection.recordServerOutcome(success: false, revision: f.settings.snapshot.revision)
        for _ in 0..<100 {
            if !f.input.device.connected { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(f.input.device.connected)
        XCTAssertEqual(f.input.device.actionSummary, "尚无录音动作")
        XCTAssertEqual(f.starts, 0); XCTAssertEqual(f.ends, 0)
    }
}
