import Combine
import XCTest
@testable import VoiceMemo

@MainActor final class IdleWorkTests: XCTestCase {
    private func projection() throws -> CaptureView {
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        let object = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
        return try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testRepeatedCaptureRefreshKeepsFreshnessWithoutPublishingIdenticalContent() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let view = try projection()
        f.meeting.applyCapture(view)
        let previous = f.meeting.meetingContext.lastSeen
        var notices = 0
        let subscription = f.meeting.objectWillChange.sink { notices += 1 }
        f.meeting.applyCapture(view)
        f.meeting.reconcilePendingAction(false)
        XCTAssertEqual(notices, 0)
        XCTAssertGreaterThanOrEqual(f.meeting.meetingContext.lastSeen, previous)
        XCTAssertTrue(f.meeting.meetingContext.isFresh())
        withExtendedLifetime(subscription) {}
    }
    func testNewReportCountStillPublishesAndFreshnessDeadlineIsPreserved() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let view = try projection()
        f.meeting.applyCapture(view)
        var notices = 0
        let subscription = f.meeting.objectWillChange.sink { notices += 1 }
        f.meeting.applyCapture(view, pendingReports: 1)
        XCTAssertGreaterThan(notices, 0)
        XCTAssertEqual(f.meeting.meetingContext.pendingReports, 1)
        let context = f.meeting.meetingContext
        XCTAssertFalse(context.isFresh(now: context.lastSeen.addingTimeInterval(MeetingContext.staleAfter + 0.1)))
        withExtendedLifetime(subscription) {}
    }
    func testUnconfirmedProjectionBecomesFreshOnlyAfterSuccessfulQuery() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let view = try projection()
        f.meeting.applyCapture(view, confirmed: false)
        XCTAssertFalse(f.meeting.meetingContext.isFresh())
        var notices = 0
        let subscription = f.meeting.objectWillChange.sink { notices += 1 }
        f.meeting.applyCapture(view)
        XCTAssertGreaterThan(notices, 0)
        XCTAssertTrue(f.meeting.meetingContext.isFresh())
        withExtendedLifetime(subscription) {}
    }
    func testRepeatedMicObservationDoesNotPublishIdenticalValues() {
        let input = InputWorker()
        input.refreshMicMode(generation: 0)
        let previous = input.permissionStatus.lastSeen
        var notices = 0
        let subscription = input.objectWillChange.sink { notices += 1 }
        input.refreshMicMode(generation: 0)
        XCTAssertEqual(notices, 0)
        XCTAssertGreaterThanOrEqual(input.permissionStatus.lastSeen, previous)
        input.refreshMicMode(generation: 1)
        XCTAssertGreaterThan(notices, 0)
        withExtendedLifetime(subscription) {}
    }
    func testRepeatedNetworkProbeUpdatesObservationWithoutNotification() async {
        let settings = SettingsWorker(checksPendingRequests: false)
        let connection = ConnectionWorker(settings: settings, probeHost: { _, _ in true })
        await connection.preflightControl()
        var notices = 0
        let subscription = connection.objectWillChange.sink { notices += 1 }
        await connection.preflightControl()
        XCTAssertEqual(notices, 0)
        XCTAssertEqual(connection.network, .connected)
        withExtendedLifetime(subscription) {}
    }
    func testRepeatedUnknownReceiptIsNotPublished() {
        let settings = SettingsWorker(checksPendingRequests: false)
        let connection = ConnectionWorker(settings: settings)
        var notices = 0
        let subscription = connection.objectWillChange.sink { notices += 1 }
        connection.updateAudioReceipt(CaptureDeviceView(meeting: nil, pendingReports: []))
        connection.updateAudioReceipt(CaptureDeviceView(meeting: nil, pendingReports: []))
        XCTAssertEqual(notices, 0)
        XCTAssertEqual(connection.desktopAudioEvidence, "尚无当前分段的实收证据")
        withExtendedLifetime(subscription) {}
    }
    func testConfigurationWriteRechecksPendingRequestsDespiteCachedUnlockedUI() {
        let suite = "VoiceMemo.IdleSettings." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var pending = false
        let settings = SettingsWorker(defaults: defaults, pendingRequests: { pending })
        let original = settings.config.url
        XCTAssertFalse(settings.isLocked)
        pending = true
        XCTAssertFalse(settings.update(.serverURL, value: "wss://other.example:7443"))
        XCTAssertEqual(settings.config.url, original)
        XCTAssertTrue(settings.isLocked)
        pending = false
        settings.refreshPendingControls()
        XCTAssertFalse(settings.isLocked)
    }
    func testLegacyDiscoveryIsCachedAndForegroundRefreshInvalidatesIt() {
        ControlStorageLocations.refresh()
        let before = RuntimeActivity.snapshot()[.legacyLookup, default: 0]
        _ = ControlStorageLocations.legacy()
        let first = RuntimeActivity.snapshot()[.legacyLookup, default: 0]
        XCTAssertEqual(first - before, MeetingClient.appGroupCandidates.count)
        _ = ControlStorageLocations.legacy()
        XCTAssertEqual(RuntimeActivity.snapshot()[.legacyLookup, default: 0], first)
        ControlStorageLocations.refresh()
        _ = ControlStorageLocations.legacy()
        XCTAssertEqual(RuntimeActivity.snapshot()[.legacyLookup, default: 0] - first, MeetingClient.appGroupCandidates.count)
    }
    func testSettingsLockGetterDoesNotDiscoverLegacyContainers() {
        let settings = SettingsWorker()
        let before = RuntimeActivity.snapshot()[.legacyLookup, default: 0]
        for _ in 0..<20 { _ = settings.isLocked; _ = settings.lockReason }
        XCTAssertEqual(RuntimeActivity.snapshot()[.legacyLookup, default: 0], before)
    }
}

final class RuntimeUsageSampleTests: XCTestCase {
    func testPhaseTransitionDiscardsMixedCPUWindow() {
        var time = 0.0, cpu = 0.0
        var sample = RuntimeUsageSample(clock: { time }, cpuTime: { cpu })
        XCTAssertNil(sample.report(context: "capturing", foreground: true))
        for _ in 0..<10 { time += 5; cpu += 1; XCTAssertNil(sample.report(context: "capturing", foreground: true)) }
        time = 55; cpu = 11
        XCTAssertNil(sample.report(context: "idle", foreground: true))
        for _ in 0..<11 { time += 5; XCTAssertNil(sample.report(context: "idle", foreground: true)) }
        time += 5
        let report = sample.report(context: "idle", foreground: true)
        XCTAssertTrue(report?.contains("CPU 0.0%") == true)
        XCTAssertTrue(report?.contains("完整窗口 60秒") == true)
    }
    func testSuspensionGapCannotBeReportedAsLowForegroundCPU() {
        var time = 0.0
        var sample = RuntimeUsageSample(clock: { time }, cpuTime: { 0 })
        XCTAssertNil(sample.report(context: "idle", foreground: true))
        time = 253
        XCTAssertNil(sample.report(context: "idle", foreground: true))
        time += 5
        XCTAssertNil(sample.report(context: "idle", foreground: false))
    }
    func testActivityDeltasAreResetAtWindowBoundary() {
        var time = 0.0
        var sample = RuntimeUsageSample(clock: { time }, cpuTime: { 0 })
        _ = sample.report(context: "idle", foreground: true)
        RuntimeActivity.add(.controlHTTP, 3)
        for _ in 0..<11 { time += 5; XCTAssertNil(sample.report(context: "idle", foreground: true)) }
        time += 5
        XCTAssertTrue(sample.report(context: "idle", foreground: true)?.contains("controlHTTP=3") == true)
        for _ in 0..<11 { time += 5; _ = sample.report(context: "idle", foreground: true) }
        time += 5
        XCTAssertTrue(sample.report(context: "idle", foreground: true)?.contains("controlHTTP=0") == true)
    }
}
