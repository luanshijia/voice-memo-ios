import Combine
import LiveKit
import XCTest
@testable import VoiceMemo

@MainActor final class HeatOptimizationTests: XCTestCase {
    private func connectedBridge() -> CB08SDKBridge {
        let bridge = CB08SDKBridge()
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        return bridge
    }

    func testRepeatedTelemetryNeverInvalidatesBusinessObservers() {
        let bridge = connectedBridge()
        var business = 0, details = 0
        let a = bridge.objectWillChange.sink { business += 1 }
        let b = bridge.telemetry.objectWillChange.sink { details += 1 }
        let event = #"{"cmd":6,"state":0,"data":{"cbc":70}}"#
        bridge.receiveEvent(event)
        let first = details
        for _ in 0..<100 { bridge.receiveEvent(event) }
        XCTAssertEqual(bridge.battery, 70)
        XCTAssertEqual(business, 0)
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(details, first)
        withExtendedLifetime([a, b]) {}
    }

    func testUnknownAndUnrelatedScanEventsDoNotInvalidateAnyObserver() {
        let bridge = CB08SDKBridge()
        var notices = 0
        let a = bridge.objectWillChange.sink { notices += 1 }
        let b = bridge.telemetry.objectWillChange.sink { notices += 1 }
        bridge.receiveEvent(#"{"cmd":99,"state":0,"data":{}}"#)
        bridge.receiveEvent(#"{"cmd":1,"state":0,"data":{"name":"Other","address":"test"}}"#)
        XCTAssertEqual(notices, 0)
        withExtendedLifetime([a, b]) {}
    }

    func testRepeatedConnectionCallbackPreservesConnectionIdentity() {
        let bridge = connectedBridge()
        let identity = bridge.connectionID
        var notices = 0
        let subscription = bridge.objectWillChange.sink { notices += 1 }
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        XCTAssertEqual(identity, bridge.connectionID)
        XCTAssertEqual(notices, 0)
        withExtendedLifetime(subscription) {}
    }

    func testFilterNeverDropsRepeatedActionQueryOrHardwareAcknowledgements() throws {
        let filter = CB08EventFilter()
        for cmd in [2, 3, 8, 9] {
            let raw = "{\"cmd\":\(cmd),\"state\":0,\"data\":{}}"
            let event = try XCTUnwrap(CB08SDKEvent.parse(raw))
            XCTAssertTrue(filter.accept(event, raw: raw))
            XCTAssertTrue(filter.accept(event, raw: raw))
        }
    }

    func testTelemetryFilterResetsAcrossConnections() throws {
        let filter = CB08EventFilter()
        let raw = #"{"cmd":6,"state":0,"data":{"cbc":70}}"#
        let event = try XCTUnwrap(CB08SDKEvent.parse(raw))
        XCTAssertTrue(filter.accept(event, raw: raw))
        XCTAssertFalse(filter.accept(event, raw: raw))
        filter.reset()
        XCTAssertTrue(filter.accept(event, raw: raw))
    }

    func testBackgroundAndPhoneSelectionStopScanning() {
        let input = InputWorker()
        input.serverAvailable = { true }
        input.device.scan()
        XCTAssertTrue(input.device.isScanning)
        input.device.appState(foreground: false)
        XCTAssertFalse(input.device.isScanning)
        input.device.scan()
        input.adopt(.phone)
        XCTAssertFalse(input.device.isScanning)
    }

    func testIdleFreshnessIsExplicitAndActiveDeadlineRemainsTwelveSeconds() throws {
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        let object = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
        let view = try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
        let now = Date()
        let active = MeetingContext(capture: view, observedAt: now)
        let idle = MeetingContext(capture: view, observedAt: now, freshFor: 45)
        XCTAssertFalse(active.isFresh(now: now.addingTimeInterval(13)))
        XCTAssertTrue(idle.isFresh(now: now.addingTimeInterval(30)))
        XCTAssertFalse(idle.isFresh(now: now.addingTimeInterval(46)))
    }
    func testIdlePollingDoesNotApplyToRecoveryOrPendingControl() {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let assistant = f.assistant
        XCTAssertTrue(assistant.usesIdlePolling)
        f.meeting.setActionPending(true)
        XCTAssertFalse(assistant.usesIdlePolling)
        f.meeting.setActionPending(false)
        f.meeting.capturePreparing()
        XCTAssertFalse(assistant.usesIdlePolling)
    }

}

final class TranscriptRowsTests: XCTestCase {
    private func line(_ text: String) -> TranscriptLine {
        TranscriptLine(who: "speaker", source: "cb08", text: text)
    }
    func testMiddleCatchUpRefreshesRowsWhenLastIdentityDoesNotChange() {
        let first = line("一"), middle = line("二"), last = line("三")
        var builder = TranscriptRows()
        builder.update([first, last])
        XCTAssertEqual(builder.rows.map(\.text).joined(), "一三")
        builder.update([first, middle, last])
        XCTAssertEqual(builder.rows.map(\.text).joined(), "一二三")
    }
    func testAppendKeepsRowIdentityAndClearRemovesHistory() {
        let first = line("一"), last = line("二")
        var builder = TranscriptRows()
        builder.update([first])
        let identity = builder.rows.first?.id
        builder.update([first, last])
        XCTAssertEqual(builder.rows.first?.id, identity)
        XCTAssertEqual(builder.rows.first?.text, "一二")
        builder.update([])
        XCTAssertTrue(builder.rows.isEmpty)
    }
    func testLongSingleSpeakerIsSplitWithoutDroppingText() {
        let lines = (0..<20).map { _ in line(String(repeating: "字", count: 200)) }
        var builder = TranscriptRows()
        builder.update(lines)
        XCTAssertGreaterThan(builder.rows.count, 1)
        XCTAssertEqual(builder.rows.map(\.text).joined(), lines.map(\.text).joined())
    }
    func testEmptyAndDuplicateCatchUpDoNotChangeStore() {
        let epoch = UUID().uuidString
        let entry = TranscriptStore.Entry(seq: 1, who: "speaker", source: "cb08", text: "一", gap: nil, ts: 1)
        var store = TranscriptStore()
        XCTAssertTrue(store.merge([entry], epoch: epoch))
        let identity = store.entries.first?.id
        XCTAssertFalse(store.merge([], epoch: epoch))
        XCTAssertFalse(store.merge([entry], epoch: epoch))
        XCTAssertEqual(store.entries.first?.id, identity)
    }
}
