import Foundation
import XCTest
@testable import VoiceMemo

final class CB08AudioSessionTests: XCTestCase {
    final class Decoder: OpusDecoding {
        let gate: DispatchSemaphore?
        init(gate: DispatchSemaphore? = nil) { self.gate = gate }
        func decode(packet: Data) throws -> (pcm: Data, metrics: OpusPacketMetrics) {
            XCTAssertFalse(Thread.isMainThread)
            gate?.wait()
            return (packet, OpusPacketMetrics(packetBytes: packet.count, decodedSamples: 320))
        }
    }
    final class Publisher: PCMSubmitting, @unchecked Sendable {
        let lock = NSLock()
        private var packets: [Data] = []
        let done: XCTestExpectation?
        init(done: XCTestExpectation? = nil) { self.done = done }
        func submit(_ data: Data) throws {
            XCTAssertFalse(Thread.isMainThread)
            lock.lock(); packets.append(data); lock.unlock()
            done?.fulfill()
        }
        var values: [Data] { lock.lock(); defer { lock.unlock() }; return packets }
    }
    @MainActor func testDecodeAndPublicationStayOffMainAndPreserveOrder() async {
        let done = expectation(description: "published"); done.expectedFulfillmentCount = 8
        let publisher = Publisher(done: done)
        let session = CB08AudioSession(decoder: Decoder(), publisher: publisher) { result in
            if case .failure = result { XCTFail("unexpected failure") }
        }
        for value in 0..<8 { XCTAssertTrue(session.submit(Data([UInt8(value)]))) }
        await fulfillment(of: [done], timeout: 3)
        let statistics = session.cancel()
        XCTAssertEqual(publisher.values, (0..<8).map { Data([UInt8($0)]) })
        XCTAssertEqual(statistics.packets, 8)
        XCTAssertEqual(statistics.samples, 2560)
        XCTAssertFalse(session.submit(Data([9])))
    }
    @MainActor func testCancelDuringDecodePreventsPublicationToOldEpoch() async {
        let gate = DispatchSemaphore(value: 0)
        let publisher = Publisher()
        let session = CB08AudioSession(decoder: Decoder(gate: gate), publisher: publisher) { _ in
            XCTFail("cancelled epoch reported")
        }
        XCTAssertTrue(session.submit(Data([1])))
        session.cancel(); gate.signal()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(publisher.values.isEmpty)
    }
    @MainActor func testOverflowReportsFailureAndStopsAccepting() async {
        let gate = DispatchSemaphore(value: 0)
        let failure = expectation(description: "overflow visible")
        let publisher = Publisher()
        let session = CB08AudioSession(decoder: Decoder(gate: gate), publisher: publisher) { result in
            if case .failure = result { failure.fulfill() }
        }
        for _ in 0..<8 { XCTAssertTrue(session.submit(Data([1]))) }
        XCTAssertFalse(session.submit(Data([9])))
        gate.signal()
        await fulfillment(of: [failure], timeout: 3)
        session.cancel()
        XCTAssertTrue(publisher.values.isEmpty)
    }
}
