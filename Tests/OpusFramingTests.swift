import Foundation
import XCTest
@testable import VoiceMemo

final class OpusFramingTests: XCTestCase {
    func testAudioToolboxDecodesEveryFrameAcrossRepeatedCallbacks() throws {
        // 20 ms mono CELT silence (F8 FF FE), padded to 40 bytes using RFC 6716 code 3.
        // No microphone audio, private recordings or downloaded fixture is used.
        var frame = Data([0xFB, 0x41, 35, 0xFF, 0xFE])
        frame.append(Data(repeating: 0, count: 35))
        let callback = (0..<4).reduce(into: Data()) { data, _ in data.append(frame) }
        let decoder: OpusDecoder
        do { decoder = try OpusDecoder() }
        catch OpusDecoderError.decoderUnavailable {
            throw XCTSkip("Simulator has no Opus converter; real-device duration validation remains required")
        }
        var samples = 0
        for _ in 0..<50 {
            let result = try decoder.decode(packet: callback)
            XCTAssertEqual(result.metrics.frameCount, 4)
            XCTAssertEqual(result.pcm.count, result.metrics.decodedSamples * 2)
            samples += result.metrics.decodedSamples
        }
        XCTAssertGreaterThanOrEqual(samples, 64_000 - 320)
        XCTAssertLessThanOrEqual(samples, 64_000)
    }
    func test160ByteCallbackPreservesAllFourFramesInOrder() throws {
        let frames = (1...4).map { Data(repeating: UInt8($0), count: 40) }
        let callback = frames.reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(try CB08OpusFraming.frames(in: callback), frames)
    }
    func testIncompleteFrameIsRejectedWithoutSilentlyDiscardingTail() {
        for length in [1, 39, 41, 159, 161, 400 + 1] {
            XCTAssertThrowsError(try CB08OpusFraming.frames(in: Data(repeating: 0, count: length)))
        }
        XCTAssertThrowsError(try CB08OpusFraming.frames(in: Data()))
    }
    func testSingleFrameAndRepeatedCallbacksPreserveDuration() throws {
        XCTAssertEqual(try CB08OpusFraming.frames(in: Data(repeating: 0, count: 40)).count, 1)
        var continuity = CB08PCMContinuity()
        for _ in 0..<1091 { try continuity.accept(frames: 4, samples: 1280) }
        XCTAssertEqual(continuity.expected, 1_396_480)
        XCTAssertEqual(continuity.decoded, 1_396_480)
    }
    func testFormerQuarterDurationBugFailsImmediately() {
        var continuity = CB08PCMContinuity()
        XCTAssertThrowsError(try continuity.accept(frames: 4, samples: 320))
    }
    func testStartupLatencyDoesNotAccumulateAcrossCallbacks() throws {
        var continuity = CB08PCMContinuity()
        try continuity.accept(frames: 4, samples: 1240)
        for _ in 0..<100 { try continuity.accept(frames: 4, samples: 1280) }
        XCTAssertEqual(continuity.expected - continuity.decoded, 40)
        XCTAssertThrowsError(try continuity.accept(frames: 4, samples: 640))
    }
}
