import Foundation
import XCTest
@testable import VoiceMemo

final class CB08DecodePipelineTests: XCTestCase {
    final class Decoder: OpusDecoding {
        let gate: DispatchSemaphore?
        init(gate: DispatchSemaphore? = nil) { self.gate = gate }
        func decode(packet: Data) throws -> (pcm: Data, metrics: OpusPacketMetrics) {
            XCTAssertFalse(Thread.isMainThread)
            gate?.wait()
            return (packet, OpusPacketMetrics(packetBytes: packet.count, decodedSamples: 320))
        }
    }
    @MainActor func testDecodeIsSerialOffMainAndResultsStayOrdered() async {
        let pipeline = CB08DecodePipeline(decoder: Decoder())
        let done = expectation(description: "all packets"); done.expectedFulfillmentCount = 8
        var received: [UInt8] = []
        for value in 0..<8 {
            XCTAssertTrue(pipeline.submit(Data([UInt8(value)])) { result in
                if case .success(let output) = result { received.append(output.pcm.first!) }
                else { XCTFail("unexpected decode failure") }
                done.fulfill()
            })
        }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(received, Array(0..<8).map(UInt8.init))
    }
    @MainActor func testBacklogIsBoundedAndCancellationDropsOldResults() async {
        let gate = DispatchSemaphore(value: 0)
        let pipeline = CB08DecodePipeline(decoder: Decoder(gate: gate))
        for _ in 0..<8 { XCTAssertTrue(pipeline.submit(Data([1])) { _ in XCTFail("cancelled result published") }) }
        XCTAssertFalse(pipeline.submit(Data([9])) { _ in XCTFail("overflow result published") })
        pipeline.cancel(); gate.signal()
        XCTAssertFalse(pipeline.submit(Data([10])) { _ in XCTFail("new packet accepted after stop") })
        // A later main-actor turn cannot publish results from the cancelled epoch.
        try? await Task.sleep(for: .milliseconds(100))
    }
}
