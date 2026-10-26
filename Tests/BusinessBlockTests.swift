import Combine
import XCTest
@testable import VoiceMemo

/// Real state owners with only IO commands substituted; no duplicate session model.
@MainActor final class BusinessFixture {
    let defaults: UserDefaults
    let suite: String
    let settings: SettingsWorker
    let input: InputWorker
    let connection: ConnectionWorker
    let meeting: MeetingWorker
    var starts = 0
    var ends = 0
    var checks = 0
    var forcedLock = false
    lazy var assistant = MeetingAssistant(meeting: meeting, commands: MeetingCommands(
        start: { [unowned self] in starts += 1; meeting.capturePreparing() },
        end: { [unowned self] in ends += 1; meeting.captureStopped() }))

    init() {
        suite = "VoiceMemo.BusinessTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.set("wss://example.test:7443", forKey: "lk.url")
        defaults.set("test-phone", forKey: "lk.device")
        defaults.set("test-user", forKey: "lk.user")
        defaults.set("test-only", forKey: "vm.deviceToken")
        settings = SettingsWorker(defaults: defaults, checksPendingRequests: false)
        input = InputWorker()
        var probeCalls: (() -> Void)?
        connection = ConnectionWorker(settings: settings, probeHost: { _, _ in probeCalls?(); return true })
        meeting = MeetingWorker(settings: settings, input: input, transport: connection, startObserving: false)
        probeCalls = { [weak self] in self?.checks += 1 }
        settings.lockedByMeeting = { [weak self] in
            guard let self else { return false }
            return forcedLock || meeting.isRecording || meeting.wantsCapture || meeting.terminating
        }
    }
    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor final class BusinessBlockTests: XCTestCase {
    func testPreparationDoesNotActivateCapture() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.assistant.selectInput(.phone)
        _ = f.assistant.settings.snapshot
        _ = f.assistant.readiness
        await f.assistant.checkConnection()
        XCTAssertEqual(f.checks, 1)
        XCTAssertEqual(f.starts, 0)
        XCTAssertEqual(f.ends, 0)
    }
    func testLockedConfigurationRejectsAllEditsAndReset() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let original = f.settings.snapshot
        f.forcedLock = true
        for field in [ConfigurationField.serverURL, .deviceID, .userID, .credential] {
            XCTAssertFalse(f.settings.update(field, value: "changed"))
        }
        f.settings.reset()
        XCTAssertEqual(f.settings.snapshot, original)
        f.forcedLock = false
        XCTAssertTrue(f.settings.update(.deviceID, value: "changed"))
        XCTAssertEqual(f.settings.snapshot.revision, original.revision + 1)
        XCTAssertEqual(f.settings.config.device, "changed")
        XCTAssertEqual(LiveKitConfig.load(defaults: f.defaults).device, "changed")
    }
    func testExternalSelectionDoesNotStartDisconnectedDevice() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.assistant.selectInput(.external)
        XCTAssertEqual(f.input.binding.channel, "external_audio")
        XCTAssertFalse(f.input.isAvailable)
        if case .rejected = f.assistant.accept(.start) {} else { XCTFail("disconnected external started") }
        XCTAssertEqual(f.starts, 0)
    }
    func testConnectionProjectionCannotInventRawAudioReceipt() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.connection.recognitionProgress = { 120 }
        XCTAssertEqual(f.connection.recognitionSeconds, 120)
        XCTAssertEqual(f.connection.desktopAudioEvidence, "尚无按分段统计的实际样本证据")
    }
    func testProjectionUsesOwnersWithoutCreatingSecondState() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let model = SessionModel(meeting: f.meeting)
        f.assistant.accept(.start)
        XCTAssertTrue(model.isRecording)
        XCTAssertTrue(f.settings.isLocked)
        f.meeting.captureInterrupted()
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(model.intent, .wanted)
        XCTAssertTrue(f.settings.isLocked)
        await f.connection.preflightControl()
        XCTAssertEqual(f.meeting.board.probe.observed, f.connection.network)
        f.assistant.accept(.end)
        XCTAssertEqual(model.intent, .notWanted)
        XCTAssertFalse(f.settings.isLocked)
    }
    func testImmediateStopWaitsForOnlyItsOriginalConnectionAttempt() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        var events: [String] = []
        f.connection.beginConnection { events.append("attempt") }
        f.connection.enqueueDisconnect(beforeDisconnect: { events.append("input-stop") }) {
            events.append("reported-stop")
        }
        let stopped = f.connection.pendingDisconnect
        f.connection.beginConnection { events.append("next-attempt") }
        await f.connection.connecting?.value
        await stopped?.value
        XCTAssertEqual(events, ["attempt", "input-stop", "reported-stop", "next-attempt"])
    }
    func testOldProbeCannotOverwriteNewConfiguration() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let worker = ConnectionWorker(settings: f.settings, probeHost: { _, _ in
            f.settings.update(.serverURL, value: "wss://new.example.test")
            return true
        })
        await worker.preflightControl()
        XCTAssertEqual(worker.network, .notStarted)
    }
}
