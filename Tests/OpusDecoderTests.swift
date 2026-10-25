import XCTest
@testable import VoiceMemo

final class OpusDecoderTests: XCTestCase {
    func testMetricsKeepCallbackPacketBoundary() {
        let metrics = OpusPacketMetrics(packetBytes: 73, decodedSamples: 320)
        XCTAssertEqual(metrics.packetBytes, 73)
        XCTAssertEqual(metrics.decodedSamples, 320)
    }

    func testEmptyPacketIsRejected() throws {
        #if CB08_PROBE
        let decoder = try OpusDecoder()
        XCTAssertThrowsError(try decoder.decode(packet: Data()))
        #else
        throw XCTSkip("The runtime decoder check runs only in a CB08 probe build")
        #endif
    }
}
