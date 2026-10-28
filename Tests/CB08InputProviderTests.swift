import Foundation
import LiveKit
import XCTest
@testable import VoiceMemo

@MainActor final class CB08InputProviderTests: XCTestCase {
    final class Device: CB08DeviceControlling {
        var connected = true
        var connectionID: UUID? = UUID()
        var recordState: CB08RecordingState? = .stopped
        var onPacket: ((Data) -> Void)?
        var onLoss: (() -> Void)?
        var commands: [CB08RecordAction] = []
        var discarded = 0
        var stateQueries = 0
        var queriedState: (() async -> CB08RecordingState?)?
        var acknowledgesActions = true
        var automaticFirstPacket = true
        func refreshRecordState(timeout: Duration) async -> CB08RecordingState? {
            stateQueries += 1
            if let queriedState { return await queriedState() }
            return recordState
        }
        func discardQueuedPackets() { discarded += 1 }
        func command(_ action: CB08RecordAction) {
            commands.append(action)
            if acknowledgesActions {
                switch action { case .start, .resume: recordState = .recording
                case .pause: recordState = .paused; case .stop: recordState = .stopped }
            }
        }
        func waitForRecordAction(timeout: Duration) async -> Bool {
            if acknowledgesActions && automaticFirstPacket && recordState == .recording {
                onPacket?(Data(repeating: 0, count: 160))
            }
            return acknowledgesActions
        }
    }
    final class Publisher: PCMAudioPublishing {
        var starts = 0; var stops = 0; var packets = 0
        func startPCM(in room: Room) async throws { starts += 1 }
        func submitPCM(_ data: Data) throws { packets += 1 }
        func stopPCM(in room: Room) async { stops += 1 }
    }
    final class Decoder: OpusDecoding {
        var fail = false
        func decode(packet: Data) throws -> (pcm: Data, metrics: OpusPacketMetrics) {
            if fail { throw OpusDecoderError.emptyPacket }
            return (Data(repeating: 1, count: 640), OpusPacketMetrics(packetBytes: packet.count, decodedSamples: 320))
        }
    }
    func context(channel: String = "external_audio", meetingID: String = UUID().uuidString) -> ExecutionContext {
        ExecutionContext(configurationRevision: 1, operationID: UUID(), meetingID: meetingID,
                         channel: channel, generation: 1, segmentID: UUID().uuidString)
    }
    func testPauseClosesGateAndResumeUsesNewAuthorizedContext() async throws {
        let device = Device(); let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        let meetingID = UUID().uuidString
        provider.bind(Room()); try await provider.start(context: context(meetingID: meetingID))
        XCTAssertEqual(provider.submittedSamples, 320)
        provider.closeGate()
        device.onPacket?(Data(repeating: 0, count: 160))
        XCTAssertEqual(publisher.packets, 1)
        await provider.pause()
        provider.bind(Room()); try await provider.start(context: context(meetingID: meetingID))
        XCTAssertEqual(device.commands, [.start, .pause, .resume])
        await provider.stop()
        device.onPacket?(Data([1]))
        XCTAssertEqual(publisher.packets, 2)
        XCTAssertEqual(publisher.stops, 2)
        XCTAssertGreaterThanOrEqual(device.discarded, 4)
    }
    func testPhoneContextCannotPublishExternalAudio() async {
        let device = Device(); let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room())
        do { try await provider.start(context: context(channel: "mic")); XCTFail("wrong source accepted") } catch {}
        XCTAssertEqual(publisher.starts, 0); XCTAssertTrue(device.commands.isEmpty)
    }
    func testLossAndDecoderFailureCloseGateWithoutAutomaticResume() async throws {
        let device = Device(); let publisher = Publisher(); let decoder = Decoder()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { decoder })
        var faults = 0; provider.onFault = { faults += 1 }
        provider.bind(Room()); try await provider.start(context: context())
        decoder.fail = true; device.onPacket?(Data([0]))
        await provider.waitForPendingAudio()
        decoder.fail = false
        device.onPacket?(Data([0]))
        XCTAssertEqual(faults, 1); XCTAssertEqual(publisher.packets, 1)
        XCTAssertEqual(device.commands, [.start]); XCTAssertEqual(provider.decodeFailures, 1)
        await provider.stop()
    }
    func testUnrelatedCardRecordingIsNotAdopted() async {
        let device = Device(); device.recordState = .recording
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room())
        do { try await provider.start(context: context()); XCTFail("unrelated recording adopted") }
        catch CB08InputError.alreadyRecording(let state) { XCTAssertEqual(state, .recording) }
        catch { XCTFail("unexpected error: \(error)") }
        await provider.stop()
        XCTAssertTrue(device.commands.isEmpty); XCTAssertEqual(publisher.starts, 0)
    }
    func testUnknownRecordStateIsRefreshedAndWaitsForSDKReply() async throws {
        let device = Device(); device.recordState = nil
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        device.queriedState = {
            try? await Task.sleep(for: .milliseconds(30))
            device.recordState = .stopped
            return .stopped
        }
        provider.bind(Room())
        try await provider.start(context: context())
        XCTAssertEqual(device.stateQueries, 1)
        XCTAssertEqual(device.commands, [.start])
        XCTAssertEqual(publisher.starts, 1)
        await provider.stop()
    }
    func testUnknownRecordStateFailsClearlyWithoutPublishingOrStartingDevice() async {
        let device = Device(); device.recordState = nil; device.queriedState = { nil }
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room())
        do { try await provider.start(context: context()); XCTFail("unknown device state accepted") }
        catch CB08InputError.recordStateUnknown {}
        catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(device.stateQueries, 1)
        XCTAssertTrue(device.commands.isEmpty)
        XCTAssertEqual(publisher.starts, 0)
    }
    func testHaltDuringRecordStateWaitInvalidatesLateStart() async {
        let device = Device(); device.recordState = nil
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        device.queriedState = {
            try? await Task.sleep(for: .milliseconds(50))
            device.recordState = .stopped
            return .stopped
        }
        provider.bind(Room())
        let start = Task { try await provider.start(context: context()) }
        try? await Task.sleep(for: .milliseconds(10))
        provider.requestHalt(.stop)
        do { try await start.value; XCTFail("late start survived halt") }
        catch CB08InputError.unavailable {}
        catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(publisher.starts, 0)
        XCTAssertTrue(device.commands.isEmpty)
    }
    func testFreshStartDoesNotAdoptUnknownPausedRecording() async {
        let device = Device(); device.recordState = .paused
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room())
        // A phone meeting's pause must not confer ownership of this card.
        provider.requestHalt(.pause)
        do { try await provider.start(context: context()); XCTFail("unrelated paused recording adopted") } catch {}
        XCTAssertEqual(publisher.starts, 0); XCTAssertTrue(device.commands.isEmpty)
    }
    func testRejectedStartCannotStopIndependentCardRecording() async {
        let device = Device(); device.recordState = .recording
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room())
        do { try await provider.start(context: context()); XCTFail("independent recording adopted") } catch {}
        provider.requestHalt(.stop)
        await provider.stop()
        XCTAssertEqual(device.recordState, .recording)
        XCTAssertTrue(device.commands.isEmpty)
    }
    func testPausedRecordingCannotTransferToAnotherMeetingOrConnection() async throws {
        for replaceConnection in [false, true] {
            let device = Device(); let publisher = Publisher()
            let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
            let meetingID = UUID().uuidString
            provider.bind(Room()); try await provider.start(context: context(meetingID: meetingID))
            await provider.pause()
            if replaceConnection { device.connectionID = UUID() }
            provider.bind(Room())
            do {
                try await provider.start(context: context(meetingID: replaceConnection ? meetingID : UUID().uuidString))
                XCTFail("paused recording ownership transferred")
            } catch CB08InputError.pausedRecordingNotOwned {} catch { XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(device.commands, [.start, .pause])
            XCTAssertEqual(publisher.starts, 1)
            if replaceConnection {
                await provider.stop()
                XCTAssertEqual(device.commands, [.start, .pause])
            } else { await provider.stop() }
        }
    }

    func testSDKReconnectInvalidatesRecordingOwnershipIdentity() throws {
        let bridge = CB08SDKBridge()
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        let first = try XCTUnwrap(bridge.connectionID)
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        XCTAssertEqual(bridge.connectionID, first)
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":0}}"#)
        XCTAssertNil(bridge.connectionID)
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        XCTAssertNotEqual(bridge.connectionID, first)
    }

    func testConfirmedPausedSelectionUsesNextInputRatherThanClosedSegmentChannel() throws {
        let f = BusinessFixture(); defer { f.cleanUp() }
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SessionControlV2Contract.fixturesJSON.utf8)) as? [String: Any])
        var object = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
        object["desired_state"] = "paused"; object["observed_state"] = "paused"
        object["channel"] = "mic"; object["source_tag"] = "call"
        object["input"] = ["channel":"external_audio", "input_ref":"cb08"]
        let selected = try JSONDecoder().decode(CaptureView.self, from: JSONSerialization.data(withJSONObject: object))
        f.meeting.applyCapture(selected)
        XCTAssertEqual(f.input.binding.channel, "external_audio")
        XCTAssertEqual(f.input.binding.sourceTag, .call)
        XCTAssertFalse(f.meeting.isRecording)
    }
    func testHardwareButtonsCannotHijackPhoneCapture() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.assistant.accept(.start)
        for event in [CB08RecordAction.start, .pause, .resume, .stop] { XCTAssertFalse(f.assistant.hardware(event)) }
        XCTAssertEqual(f.starts, 1); XCTAssertEqual(f.ends, 0)
    }
    func testSDKStateCasingAndUnknownStateStayDistinct() {
        let bridge = CB08SDKBridge()
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":"2"}}"#)
        XCTAssertEqual(bridge.recordState, .inactive)
        bridge.receiveEvent(#"{"cmd":3,"state":0,"data":{"record_state":0}}"#)
        XCTAssertEqual(bridge.recordState, .stopped)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{}}"#)
        XCTAssertNil(bridge.recordState)
    }
    func testInactiveQueryPreservesConfirmedPauseWithoutInventingPause() {
        let bridge = CB08SDKBridge()
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":2}}"#)
        XCTAssertEqual(bridge.recordState, .inactive)
        bridge.receiveEvent(#"{"cmd":3,"state":0,"data":{"record_state":2,"fileName":"test"}}"#)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":2}}"#)
        XCTAssertEqual(bridge.recordState, .paused)
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        XCTAssertEqual(bridge.recordState, .paused)
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":0}}"#)
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":2}}"#)
        XCTAssertEqual(bridge.recordState, .inactive)
    }
    func testInactiveQueryStartsNewRecordingRatherThanContinuingUnownedFile() async throws {
        let device = Device(); device.recordState = .inactive
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room()); try await provider.start(context: context())
        XCTAssertEqual(device.commands, [.start])
        XCTAssertEqual(provider.submittedSamples, 320)
        await provider.stop()
    }
    func testDeviceActionWithoutAcknowledgementCannotReportPublishing() async {
        let device = Device(); device.acknowledgesActions = false
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher,
            startupTimeout: .milliseconds(50), makeDecoder: { Decoder() })
        provider.bind(Room())
        do { try await provider.start(context: context()); XCTFail("unconfirmed action accepted") }
        catch CB08InputError.actionNotConfirmed {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertFalse(provider.flowing)
        XCTAssertEqual(provider.submittedSamples, 0)
        await provider.stop()
        XCTAssertEqual(device.commands, [.start, .stop])
        XCTAssertEqual(publisher.stops, 1)
    }
    func testRecordingAcknowledgementWithoutAudioFailsAndClosesGateOnCleanup() async {
        let device = Device(); device.automaticFirstPacket = false
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher,
            startupTimeout: .milliseconds(50), makeDecoder: { Decoder() })
        provider.bind(Room())
        do { try await provider.start(context: context()); XCTFail("zero audio accepted") }
        catch CB08InputError.noRealtimeAudio {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertFalse(provider.flowing)
        await provider.stop()
        device.onPacket?(Data([1]))
        XCTAssertEqual(publisher.packets, 0)
        XCTAssertEqual(device.commands, [.start, .stop])
        XCTAssertNotNil(provider.failure)
    }
    func testHardwareRequestAndActionReplyRemainVisibleAfterStatusQuery() async {
        let bridge = CB08SDKBridge()
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        bridge.onHardware = { _ in true }
        bridge.receiveEvent(#"{"cmd":8,"state":0,"data":{"event":1}}"#)
        bridge.command(.start)
        bridge.receiveEvent(#"{"cmd":3,"state":0,"data":{"record_state":1}}"#)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":1}}"#)
        let confirmed = await bridge.waitForRecordAction(timeout: .milliseconds(10))
        XCTAssertTrue(confirmed)
        XCTAssertTrue(bridge.hardwareSummary.contains("event=1"))
        XCTAssertTrue(bridge.actionSummary.contains("record_state=1"))
        XCTAssertTrue(bridge.querySummary.contains("recordState=1"))
        XCTAssertTrue(bridge.diagnostics.contains { $0.contains("实体键确认") })
    }
    func testScanFiltersOtherDevicesAndRetainsDistinctCB08Choices() {
        let bridge = CB08SDKBridge(); bridge.scan()
        bridge.receiveEvent(#"{"cmd":1,"state":0,"data":{"name":"Headphones","address":"a"}}"#)
        bridge.receiveEvent(#"{"cmd":1,"state":0,"data":{"name":"CB08","address":"b"}}"#)
        bridge.receiveEvent(#"{"cmd":1,"state":0,"data":{"name":"CB08","address":"c"}}"#)
        bridge.receiveEvent(#"{"cmd":1,"state":0,"data":{"name":"CB08","address":"b"}}"#)
        XCTAssertEqual(bridge.devices.count, 2)
        XCTAssertEqual(bridge.selectedDeviceID, "b")
        bridge.stopScan(); XCTAssertFalse(bridge.isScanning)
    }
    func testStatusQueryCannotConfirmAnOutstandingRecordingAction() async {
        let bridge = CB08SDKBridge()
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        bridge.command(.start)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":1}}"#)
        let queryOnly = await bridge.waitForRecordAction(timeout: .milliseconds(1))
        XCTAssertFalse(queryOnly)
        bridge.receiveEvent(#"{"cmd":3,"state":0,"data":{"record_state":1}}"#)
        let actionConfirmed = await bridge.waitForRecordAction(timeout: .milliseconds(1))
        XCTAssertTrue(actionConfirmed)
    }
    func testFreshQueryWaitsForCommand9RatherThanReusingAnActionReply() async {
        let bridge = CB08SDKBridge()
        bridge.receiveEvent(#"{"cmd":2,"state":0,"data":{"connect_state":1}}"#)
        var completed = false
        let query = Task { let result = await bridge.refreshRecordState(timeout: .milliseconds(500)); completed = true; return result }
        try? await Task.sleep(for: .milliseconds(10))
        bridge.receiveEvent(#"{"cmd":3,"state":0,"data":{"record_state":0}}"#)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(completed)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":2}}"#)
        let result = await query.value
        XCTAssertEqual(result, .stopped)
    }
    func testMissingStopAckRetainsOwnershipAndRetriesOnlySameConnection() async throws {
        let device = Device(), publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room()); try await provider.start(context: context())
        device.acknowledgesActions = false
        await provider.stop()
        XCTAssertNotNil(provider.cleanupProblem)
        XCTAssertFalse(provider.flowing)
        XCTAssertEqual(device.commands, [.start, .stop])
        device.acknowledgesActions = true
        await provider.stop()
        XCTAssertNil(provider.cleanupProblem)
        XCTAssertEqual(device.commands, [.start, .stop, .stop])
        await provider.stop()
        XCTAssertEqual(device.commands, [.start, .stop, .stop])
    }
    func testLostStopAckNeverStopsRecordingOnAnotherConnection() async throws {
        let device = Device(), publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room()); try await provider.start(context: context())
        device.acknowledgesActions = false
        await provider.stop()
        device.connectionID = UUID(); device.recordState = .recording
        await provider.stop()
        XCTAssertEqual(device.commands, [.start, .stop])
        XCTAssertEqual(device.recordState, .recording)
    }
    func testPauseWithoutAckCannotBeUsedAsConfirmedResumeOwnership() async throws {
        let device = Device(), publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        let capture = context()
        provider.bind(Room()); try await provider.start(context: capture)
        device.acknowledgesActions = false
        await provider.pause()
        XCTAssertNotNil(provider.cleanupProblem)
        provider.bind(Room())
        do { try await provider.start(context: capture); XCTFail("unconfirmed pause resumed") } catch {}
        XCTAssertEqual(device.commands, [.start, .pause])
        device.acknowledgesActions = true
        await provider.pause()
        XCTAssertNil(provider.cleanupProblem)
    }

}
