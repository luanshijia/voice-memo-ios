import AVFoundation
import Combine
import Foundation
import LiveKit

/// Owns input selection, the native provider, and device capture observations.
@MainActor final class InputWorker: ObservableObject {
    @Published private(set) var binding = InputBinding.phone
    @Published private(set) var isCapturing = false
    @Published private(set) var micModeText = "读取中"
    @Published private(set) var permissionStatus = Status<LinkDesired, CapObserved, CapReason>(
        desired: .wanted, observed: .unknownState)
    @Published private(set) var modeStatus = Status<LinkDesired, MicModeObserved, CapReason>(
        desired: .wanted, observed: .unknownState)
    let device: CB08SDKBridge
    let external: CB08InputProvider
    private var subscriptions = Set<AnyCancellable>()
    private let provider: PhoneInputProvider
    var configurationLocked: () -> Bool = { false }

    init(provider: PhoneInputProvider? = nil) {
        let publisher = AudioPublisher()
        self.provider = provider ?? PhoneInputProvider(publisher: publisher)
        let device = CB08SDKBridge()
        self.device = device
        external = CB08InputProvider(device: device, publisher: publisher)
        external.onFlow = { [weak self] in self?.isCapturing = true }
        external.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        device.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    var isAvailable: Bool { binding.kind == .phone || external.isAvailable }
    var permission: CapObserved { permissionStatus.observed }
    var displayName: String {
        binding.kind == .phone ? "手机 · 面对面" : "CB08 · \(binding.sourceTag == .call ? "通话" : "面对面")"
    }
    @discardableResult func select(_ kind: InputKind, tag: SourceTag = .face2face) -> CaptureActionResult {
        guard !configurationLocked() else { return .rejected("请先暂停并等待确认") }
        adopt(InputBinding(kind: kind, capturePort: kind == .phone ? .nativeMicrophone : .pcmFeed,
                           sourceTag: kind == .phone ? .face2face : tag))
        return .submitted
    }
    func adopt(_ value: InputBinding) { binding = value }
    func bind(_ room: Room) {
        if binding.kind == .phone { provider.bind(room) } else { external.bind(room) }
    }
    func start(context: ExecutionContext) async throws {
        guard context.channel == binding.channel else { throw CB08InputError.invalidContext }
        if binding.kind == .phone { try await provider.start(context: context); isCapturing = true }
        else { try await external.start(context: context) }
    }
    func requestHalt(pausing: Bool) {
        isCapturing = false
        // SDK commands are local BLE writes: do not wait for network/room cleanup.
        external.requestHalt(pausing ? .pause : .stop)
    }
    func pause() async {
        isCapturing = false
        if binding.kind == .phone { await provider.stop() } else { await external.pause() }
    }
    func stop() async {
        isCapturing = false
        await provider.stop()
        await external.stop()
    }
    func finish() async {
        isCapturing = false
        await provider.stop()
        await external.stop()
    }
    func interrupted() {
        provider.bind(nil); external.interrupted(); isCapturing = false
    }

    func refreshMicMode(generation: Int) {
        let allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        permissionStatus = Status(desired: .wanted, observed: allowed ? .yes : .no,
                                  reason: allowed ? nil : .permissionDenied,
                                  lastSeen: Date(), generation: generation)
        guard allowed else {
            micModeText = "未授权"
            modeStatus = Status(desired: .wanted, observed: .unknownState,
                                reason: nil, lastSeen: Date(), generation: generation)
            return
        }
        let mode = AVCaptureDevice.preferredMicrophoneMode
        switch mode {
        case .standard: micModeText = "标准"
        case .voiceIsolation: micModeText = "语音突显"
        case .wideSpectrum: micModeText = "宽谱"
        default: micModeText = "自动"
        }
        modeStatus = Status(desired: .wanted, observed: mode == .wideSpectrum ? .wide : .other,
                            reason: nil, lastSeen: Date(), generation: generation)
    }
}
