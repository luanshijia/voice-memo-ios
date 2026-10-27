import AVFoundation
import AudioToolbox

struct OpusPacketMetrics: Equatable {
    let packetBytes: Int
    let decodedSamples: Int
    var frameCount: Int = 1
}

enum OpusDecoderError: Error, LocalizedError {
    case invalidFrameLength(Int)
    case emptyPacket
    case decoderUnavailable
    case conversion(String)
    case noPCM

    var errorDescription: String? {
        switch self {
        case .invalidFrameLength(let count): return "CB08 Opus 回调长度不符合 40 字节帧格式：\(count) 字节"
        case .emptyPacket: return "收到空 Opus 回调"
        case .decoderUnavailable: return "AudioToolbox 未创建 16 kHz Opus 解码器"
        case .conversion(let reason): return "AudioToolbox 解码失败：\(reason)"
        case .noPCM: return "解码器未产出 PCM"
        }
    }
}

/// CB08 A-model realtime profile: 16 kHz mono, 40 bytes / 20 ms.
/// Vendor provider_record_pen.dart splits a 160-byte callback into four codec packets.
/// This is a device profile, not a generic Opus fixed-size assumption.
enum CB08OpusFraming {
    static let frameBytes = 40
    static let samplesPerFrame = 320
    static func frames(in callback: Data) throws -> [Data] {
        guard !callback.isEmpty else { throw OpusDecoderError.emptyPacket }
        guard callback.count % frameBytes == 0 else {
            throw OpusDecoderError.invalidFrameLength(callback.count)
        }
        let bytes = Data(callback)
        return stride(from: 0, to: bytes.count, by: frameBytes).map {
            bytes.subdata(in: $0..<($0 + frameBytes))
        }
    }
}

/// Permit at most one codec frame of converter startup latency, never a growing deficit.
struct CB08PCMContinuity {
    private(set) var expected = 0
    private(set) var decoded = 0
    mutating func accept(frames: Int, samples: Int) throws {
        expected += frames * CB08OpusFraming.samplesPerFrame
        decoded += samples
        guard samples > 0, decoded <= expected,
              expected - decoded <= CB08OpusFraming.samplesPerFrame else {
            throw OpusDecoderError.conversion("PCM 时长不连续：应有 \(expected)，实际 \(decoded) 样本")
        }
    }
}

protocol OpusDecoding: AnyObject {
    func decode(packet: Data) throws -> (pcm: Data, metrics: OpusPacketMetrics)
}

final class OpusDecoder: OpusDecoding {
    private var continuity = CB08PCMContinuity()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init() throws {
        var input = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let source = AVAudioFormat(streamDescription: &input),
              let destination = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16_000,
                                              channels: 1,
                                              interleaved: true),
              let converter = AVAudioConverter(from: source, to: destination) else {
            throw OpusDecoderError.decoderUnavailable
        }
        inputFormat = source
        outputFormat = destination
        self.converter = converter
    }

    func decode(packet: Data) throws -> (pcm: Data, metrics: OpusPacketMetrics) {
        let frames = try CB08OpusFraming.frames(in: packet)
        var pcm = Data()
        for frame in frames { pcm.append(try decodeFrame(frame)) }
        let samples = pcm.count / MemoryLayout<Int16>.size
        try continuity.accept(frames: frames.count, samples: samples)
        return (pcm, OpusPacketMetrics(packetBytes: packet.count, decodedSamples: samples,
                                       frameCount: frames.count))
    }

    private func decodeFrame(_ packet: Data) throws -> Data {
        guard !packet.isEmpty else { throw OpusDecoderError.emptyPacket }
        guard packet.count <= Int(UInt32.max) else { throw OpusDecoderError.conversion("packet too large") }

        let compressed = AVAudioCompressedBuffer(format: inputFormat,
                                                  packetCapacity: 1,
                                                  maximumPacketSize: packet.count)
        packet.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                compressed.data.copyMemory(from: baseAddress, byteCount: packet.count)
            }
        }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        if let descriptions = compressed.packetDescriptions {
            descriptions[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(packet.count))
        }

        let capacity: AVAudioFrameCount = 5_760
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw OpusDecoderError.conversion("cannot allocate PCM output")
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return compressed
        }
        if let conversionError { throw OpusDecoderError.conversion(conversionError.localizedDescription) }
        guard status != .error, output.frameLength > 0,
              let samples = output.int16ChannelData?.pointee else {
            throw OpusDecoderError.noPCM
        }
        let sampleCount = Int(output.frameLength)
        let pcm = Data(bytes: samples, count: sampleCount * MemoryLayout<Int16>.size)
        return pcm
    }
}
