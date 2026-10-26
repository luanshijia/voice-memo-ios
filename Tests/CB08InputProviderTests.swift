import Foundation
import LiveKit
import XCTest
@testable import VoiceMemo

@MainActor final class CB08InputProviderTests: XCTestCase {
    final class Device: CB08DeviceControlling {
        var connected = true
        var recordState: Int? = 0
        var onPacket: ((Data) -> Void)?
        var onLoss: (() -> Void)?
        var commands: [CB08RecordAction] = []
        func command(_ action: CB08RecordAction) {
            commands.append(action)
            switch action { case .start, .resume: recordState = 1; case .pause: recordState = 2; case .stop: recordState = 0 }
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
    func context(channel: String = "external_audio") -> ExecutionContext {
        ExecutionContext(configurationRevision: 1, operationID: UUID(), meetingID: UUID().uuidString,
                         channel: channel, generation: 1, segmentID: UUID().uuidString)
    }
    func testPauseClosesGateAndResumeUsesNewAuthorizedContext() async throws {
        let device = Device(); let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room()); try await provider.start(context: context())
        device.onPacket?(Data(repeating: 0, count: 160))
        XCTAssertEqual(provider.submittedSamples, 320)
        provider.closeGate()
        device.onPacket?(Data(repeating: 0, count: 160))
        XCTAssertEqual(publisher.packets, 1)
        await provider.pause()
        provider.bind(Room()); try await provider.start(context: context())
        XCTAssertEqual(device.commands, [.start, .pause, .resume])
        await provider.stop()
        device.onPacket?(Data([1]))
        XCTAssertEqual(publisher.packets, 1)
        XCTAssertEqual(publisher.stops, 2)
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
        decoder.fail = true; device.onPacket?(Data([0])); decoder.fail = false
        device.onPacket?(Data([0]))
        XCTAssertEqual(faults, 1); XCTAssertEqual(publisher.packets, 0)
        XCTAssertEqual(device.commands, [.start]); XCTAssertEqual(provider.decodeFailures, 1)
        await provider.stop()
    }
    func testUnrelatedCardRecordingIsNotAdopted() async {
        let device = Device(); device.recordState = 1
        let publisher = Publisher()
        let provider = CB08InputProvider(device: device, publisher: publisher, makeDecoder: { Decoder() })
        provider.bind(Room())
        do { try await provider.start(context: context()); XCTFail("unrelated recording adopted") } catch {}
        await provider.stop()
        XCTAssertTrue(device.commands.isEmpty); XCTAssertEqual(publisher.starts, 0)
    }
    func testHardwareButtonsCannotHijackPhoneCapture() async {
        let f = BusinessFixture(); defer { f.cleanUp() }
        f.assistant.accept(.start)
        for event in [CB08RecordAction.start, .pause, .resume, .stop] { XCTAssertFalse(f.assistant.hardware(event)) }
        XCTAssertEqual(f.starts, 1); XCTAssertEqual(f.ends, 0)
    }
    func testSDKStateCasingAndUnknownStateStayDistinct() {
        let bridge = CB08SDKBridge()
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{"recordState":"2"}}"#)
        XCTAssertEqual(bridge.recordState, 2)
        bridge.receiveEvent(#"{"cmd":3,"state":0,"data":{"record_state":0}}"#)
        XCTAssertEqual(bridge.recordState, 0)
        bridge.receiveEvent(#"{"cmd":9,"state":0,"data":{}}"#)
        XCTAssertNil(bridge.recordState)
    }
}
