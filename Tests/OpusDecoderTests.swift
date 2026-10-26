import XCTest
@testable import VoiceMemo

final class OpusDecoderTests: XCTestCase {
    func testMetricsKeepCallbackPacketBoundary() {
        let metrics = OpusPacketMetrics(packetBytes: 73, decodedSamples: 320)
        XCTAssertEqual(metrics.packetBytes, 73)
        XCTAssertEqual(metrics.decodedSamples, 320)
    }

    func testEmptyPacketIsRejected() throws {
        let decoder: OpusDecoder
        do { decoder = try OpusDecoder() }
        catch OpusDecoderError.decoderUnavailable { throw XCTSkip("Simulator has no Opus converter; device check remains required") }
        XCTAssertThrowsError(try decoder.decode(packet: Data()))
    }
}
