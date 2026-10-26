import AVFoundation
import AudioToolbox

struct OpusPacketMetrics: Equatable {
    let packetBytes: Int
    let decodedSamples: Int
}

enum OpusDecoderError: Error, LocalizedError {
    case emptyPacket
    case decoderUnavailable
    case conversion(String)
    case noPCM

    var errorDescription: String? {
        switch self {
        case .emptyPacket: return "收到空 Opus 回调"
        case .decoderUnavailable: return "AudioToolbox 未创建 16 kHz Opus 解码器"
        case .conversion(let reason): return "AudioToolbox 解码失败：\(reason)"
        case .noPCM: return "解码器未产出 PCM"
        }
    }
}

/// Callback-preserving candidate decoder. Each SDK callback is tested as one opaque codec packet;
/// no fixed byte count or packet splitting is inferred from the manual.
protocol OpusDecoding: AnyObject {
    func decode(packet: Data) throws -> (pcm: Data, metrics: OpusPacketMetrics)
}

final class OpusDecoder: OpusDecoding {
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
        return (pcm, OpusPacketMetrics(packetBytes: packet.count, decodedSamples: sampleCount))
    }
}
