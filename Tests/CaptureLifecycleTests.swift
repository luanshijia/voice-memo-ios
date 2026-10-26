import Foundation
import LiveKit
import XCTest
@testable import VoiceMemo

@MainActor private final class CaptureGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@MainActor private final class CaptureLifecycleFixture {
    final class Publisher: AudioPublishing {
        var microphone: [Bool] = []
        var failStart = false
        func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws {
            microphone.append(enabled)
            if enabled && failStart { throw URLError(.cannotConnectToHost) }
        }
    }
    let suite: String
    let defaults: UserDefaults
    let publisher: Publisher
    let settings: SettingsWorker
    let input: InputWorker
    var connection: ConnectionWorker!
    var meeting: MeetingWorker!
    var view: CaptureView
    var pending = false
    var flushes = 0
    var disconnects = 0
    var observations: [String] = []
    var failPublishing = false
    var viewHandler: (@MainActor () async throws -> CaptureDeviceView)?

    init() throws {
        let suite = "VoiceMemo.CaptureLifecycle." + UUID().uuidString
        self.suite = suite
        let defaults = UserDefaults(suiteName: suite)!
        self.defaults = defaults
        defaults.set("wss://example.test", forKey: "lk.url")
        defaults.set("phone", forKey: "lk.device")
        defaults.set("user", forKey: "lk.user")
        defaults.set("test-only", forKey: "vm.deviceToken")
        let publisher = Publisher()
        self.publisher = publisher
        settings = SettingsWorker(defaults: defaults, checksPendingRequests: false)
        input = InputWorker(provider: PhoneInputProvider(publisher: publisher))
        view = try Self.projection()
        let control = CaptureControlOperations(
            queueStart: { [unowned self] _, _, _, _ in pending = true },
            queueAction: { _, _, _, _ in },
            flush: { [unowned self] in
                flushes += 1
                guard pending else { return nil }
                pending = false
                return view
            },
            view: { [unowned self] _ in
                if let viewHandler { return try await viewHandler() }
                return CaptureDeviceView(meeting: view, pendingReports: [])
            },
            observe: { [unowned self] _, _, observed in
                observations.append(observed)
                if observed == "publishing" && failPublishing { throw URLError(.timedOut) }
            }, hasPending: { [unowned self] in pending })
        connection = ConnectionWorker(settings: settings, captureControl: control,
            connectRoom: { _, _, _ in Room() },
            disconnectRoom: { [unowned self] _ in disconnects += 1 })
        meeting = MeetingWorker(settings: settings, input: input, transport: connection, startObserving: false)
    }
    static func projection(_ changes: [String: Any] = [:]) throws -> CaptureView {
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        var object = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
        object["media"] = ["url": "wss://example.test", "token": "test-only", "identity": "phone-livekit"]
        changes.forEach { object[$0.key] = $0.value }
        return try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func start() async {
        meeting.startCapture()
        await connection.connecting?.value
    }
    func cleanUp() async throws {
        // Exercise the same desktop-ended cleanup, including timer shutdown.
        meeting.applyCapture(try Self.projection(["desired_state": "ended", "state_revision": 100]))
        await connection.pendingDisconnect?.value
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor final class CaptureLifecycleTests: XCTestCase {
    func testPollCannotConsumeStartWhileItWaitsForPreviousDisconnect() async throws {
        let f = try CaptureLifecycleFixture()
        let gate = CaptureGate()
        f.connection.enqueueDisconnect(beforeDisconnect: { await gate.wait() }) {}
        f.meeting.startCapture()
        let start = f.connection.connecting
        try await f.meeting.reconcileDesktopOnce()
        XCTAssertEqual(f.flushes, 0)
        XCTAssertTrue(f.pending)
        gate.open()
        await start?.value
        XCTAssertTrue(f.meeting.isRecording)
        XCTAssertTrue(f.input.isCapturing)
        XCTAssertEqual(f.flushes, 1)
        XCTAssertNil(f.connection.connecting)
        try await f.cleanUp()
    }

    func testPublishingTimeoutKeepsRealCaptureAndPollRetriesWithoutRestart() async throws {
        let f = try CaptureLifecycleFixture()
        f.failPublishing = true
        await f.start()
        XCTAssertTrue(f.meeting.isRecording)
        XCTAssertTrue(f.input.isCapturing)
        XCTAssertNotNil(f.connection.live)
        XCTAssertEqual(f.publisher.microphone, [true])
        XCTAssertEqual(f.observations, ["publishing"])
        f.failPublishing = false
        try await f.meeting.reconcileDesktopOnce()
        XCTAssertEqual(f.observations, ["publishing", "publishing"])
        try await f.meeting.reconcileDesktopOnce()
        XCTAssertEqual(f.observations.count, 2)
        XCTAssertEqual(f.publisher.microphone, [true])
        try await f.cleanUp()
    }

    func testDesktopPauseAndEndActuallyStopInputAndAcknowledgeAfterCleanup() async throws {
        for desired in ["paused", "ended"] {
            let f = try CaptureLifecycleFixture()
            await f.start()
            f.view = try CaptureLifecycleFixture.projection([
                "desired_state": desired, "state_revision": 2, "observed_state": "pending"])
            try await f.meeting.reconcileDesktopOnce()
            XCTAssertFalse(f.meeting.isRecording)
            XCTAssertFalse(f.input.isCapturing)
            await f.connection.pendingDisconnect?.value
            XCTAssertEqual(f.publisher.microphone, [true, false])
            XCTAssertEqual(f.disconnects, 1)
            XCTAssertNil(f.connection.live)
            XCTAssertNil(f.connection.pendingDisconnect)
            try await f.meeting.reconcileDesktopOnce()
            XCTAssertEqual(f.observations.last, "stopped")
            XCTAssertEqual(f.publisher.microphone, [true, false])
            XCTAssertEqual(f.meeting.wantsCapture, desired == "paused")
            try await f.cleanUp()
        }
    }

    func testDelayedOldPollCannotStopNewLocalStart() async throws {
        let f = try CaptureLifecycleFixture()
        let gate = CaptureGate()
        let entered = expectation(description: "poll awaiting its old response")
        let old = try CaptureLifecycleFixture.projection(["desired_state": "ended"])
        f.viewHandler = {
            entered.fulfill()
            await gate.wait()
            return CaptureDeviceView(meeting: old, pendingReports: [])
        }
        let poll = Task { try await f.meeting.reconcileDesktopOnce() }
        await fulfillment(of: [entered], timeout: 2)
        await f.start()
        gate.open()
        try await poll.value
        XCTAssertTrue(f.meeting.isRecording)
        XCTAssertTrue(f.input.isCapturing)
        XCTAssertEqual(f.meeting.capture?.desiredState, "active")
        try await f.cleanUp()
    }

    func testConfirmedDesktopPauseCannotResumeOrSwitchUntilLocalCleanupFinishes() async throws {
        let f = try CaptureLifecycleFixture()
        await f.start()
        let gate = CaptureGate()
        // Hold an earlier cleanup task so that the new stop cannot complete yet.
        f.connection.enqueueDisconnect(beforeDisconnect: { await gate.wait() }) {}
        var resumes = 0
        let assistant = MeetingAssistant(meeting: f.meeting, commands: MeetingCommands(
            start: {}, end: {}, pause: {}, resume: { resumes += 1 }))
        f.meeting.applyCapture(try CaptureLifecycleFixture.projection([
            "desired_state": "paused", "observed_state": "paused", "state_revision": 2]))
        XCTAssertFalse(assistant.canSelectInput)
        if case .rejected = assistant.accept(.resume) {} else { XCTFail("resume overtook input cleanup") }
        XCTAssertEqual(resumes, 0)
        gate.open()
        await f.connection.pendingDisconnect?.value
        XCTAssertTrue(assistant.canSelectInput)
        XCTAssertEqual(assistant.accept(.resume), .submitted)
        XCTAssertEqual(resumes, 1)
        try await f.cleanUp()
    }

    func testActualInputStartFailureCleansUpTransport() async throws {
        let f = try CaptureLifecycleFixture()
        f.publisher.failStart = true
        await f.start()
        XCTAssertFalse(f.meeting.isRecording)
        XCTAssertFalse(f.input.isCapturing)
        XCTAssertNil(f.connection.live)
        XCTAssertEqual(f.disconnects, 1)
        XCTAssertEqual(f.publisher.microphone, [true, false])
        try await f.cleanUp()
    }

    func testEndDuringNewStartKeepsRequestBoundToNewGrantInsteadOfOldMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingRequestStore(root: root)
        let config = LiveKitConfig(url: "wss://example.test", device: "phone", userID: "user")
        let old = try CaptureLifecycleFixture.projection(["desired_state": "ended"])
        try MeetingClient.queueCaptureStart(config: config, revision: 1, input: .phone, meetingID: nil, store: store)
        let key = "vm.pendingCaptureV2"
        let before = try XCTUnwrap(try store.read(key))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        try MeetingClient.queueCaptureAction(config: config, view: old, action: "end", store: store)
        // A subsequent pause cannot weaken the durable end intent.
        try MeetingClient.queueCaptureAction(config: config, view: old, action: "pause", store: store)
        let after = try XCTUnwrap(try store.read(key))
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
        XCTAssertEqual(pending["requestID"] as? String, original["requestID"] as? String)
        XCTAssertEqual(pending["action"] as? String, "start")
        XCTAssertEqual(pending["afterGrant"] as? String, "end")
        XCTAssertEqual(pending["path"] as? String, SessionControlV2Contract.startPath)
        XCTAssertEqual(pending["body"] as? String, original["body"] as? String)
    }
}
