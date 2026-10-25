#if CB08_PROBE
import Foundation
import Combine

@MainActor
final class CB08Probe: ObservableObject {
    @Published private(set) var decoderStatus = "未探测"
    @Published private(set) var decodeSuccess = 0
    @Published private(set) var decodeFailure = 0
    @Published private(set) var decodedSamples = 0

    let device = CB08SDKBridge()
    private var decoder: OpusDecoder?
    private var cancellables = Set<AnyCancellable>()

    init() {
        device.$latestPacket
            .compactMap { $0 }
            .sink { [weak self] packet in self?.decode(packet) }
            .store(in: &cancellables)
    }

    func probeDecoder() {
        do {
            decoder = try OpusDecoder()
            decoderStatus = "AudioToolbox 解码器已创建；等待真实 CB08 回调验证"
        } catch {
            decoder = nil
            decoderStatus = error.localizedDescription
        }
    }

    private func decode(_ packet: Data) {
        guard let decoder else { return }
        do {
            let result = try decoder.decode(packet: packet)
            decodeSuccess += 1
            decodedSamples += result.metrics.decodedSamples
            decoderStatus = "最近回调 \(result.metrics.packetBytes) B → \(result.metrics.decodedSamples) PCM 样本"
        } catch {
            decodeFailure += 1
            decoderStatus = error.localizedDescription
        }
    }
}
#endif
