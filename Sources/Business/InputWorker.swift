import AVFoundation
import Combine
import Foundation
import LiveKit

/// Owns input selection, the native provider, and device capture observations.
@MainActor final class InputWorker: ObservableObject {
    @Published private(set) var binding = InputBinding.phone
    @Published private(set) var isCapturing = false
    @Published private(set) var cleanupProblem: String?
    private var haltedByPause = false
    private(set) var micModeText = "读取中"
    private(set) var permissionStatus = Status<LinkDesired, CapObserved, CapReason>(
        desired: .wanted, observed: .unknownState)
    private(set) var modeStatus = Status<LinkDesired, MicModeObserved, CapReason>(
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
        publisher.onFailure = { [weak device] message in device?.noteDevice(message) }
        external = CB08InputProvider(device: device, publisher: publisher)
        external.onFlow = { [weak self] in
            self?.isCapturing = true
            self?.device.noteDevice("首个有效PCM已提交媒体发布链")
        }
        external.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        device.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    var isAvailable: Bool { binding.kind == .phone || external.isAvailable }
    var permission: CapObserved { permissionStatus.observed }
    var displayName: String {
        binding.kind == .phone ? "手机" : "CB08"
    }
    @discardableResult func select(_ kind: InputKind, tag: SourceTag = .face2face) -> CaptureActionResult {
        guard !configurationLocked() else { return .rejected("请先暂停并等待确认") }
        adopt(InputBinding(kind: kind, capturePort: kind == .phone ? .nativeMicrophone : .pcmFeed,
                           sourceTag: kind == .phone ? .face2face : tag))
        return .submitted
    }
    func adopt(_ value: InputBinding) {
        if binding != value { binding = value }
        if value.kind == .external { device.activate() } else { device.stopScan() }
    }
    func bind(_ room: Room) {
        if binding.kind == .phone { provider.bind(room) } else { external.bind(room) }
    }
    func start(context: ExecutionContext) async throws {
        await provider.waitForCleanup()
        guard cleanupProblem == nil else { throw AudioPublishError.cleanupFailed }
        guard context.channel == binding.channel else { throw CB08InputError.invalidContext }
        if binding.kind == .phone { try await provider.start(context: context); isCapturing = true }
        else { try await external.start(context: context) }
    }
    func requestHalt(pausing: Bool) {
        haltedByPause = pausing
        isCapturing = false
        // SDK commands are local BLE writes: do not wait for network/room cleanup.
        external.requestHalt(pausing ? .pause : .stop)
    }
    func pause() async {
        haltedByPause = true
        isCapturing = false
        await provider.stop()
        await external.pause()
        updateCleanupProblem()
    }
    func stop() async {
        haltedByPause = false
        isCapturing = false
        await provider.stop()
        await external.stop()
        updateCleanupProblem()
    }
    func finish() async {
        haltedByPause = false
        isCapturing = false
        await provider.stop()
        await external.stop()
        updateCleanupProblem()
    }
    private func updateCleanupProblem() {
        let problem = provider.cleanupProblem ?? external.cleanupProblem
        if cleanupProblem != problem { cleanupProblem = problem }
    }
    func retryCleanup() async {
        guard cleanupProblem != nil else { return }
        await provider.stop()
        if haltedByPause { await external.pause() } else { await external.stop() }
        updateCleanupProblem()
    }
    func interrupted() {
        let cleanup = provider.detachForInterruption()
        external.interrupted(); isCapturing = false
        Task { [weak self] in await cleanup(); self?.updateCleanupProblem() }
    }

    func refreshMicMode(generation: Int) {
        let previousPermission = permissionStatus
        let previousMode = modeStatus
        let previousText = micModeText
        defer {
            if previousPermission.observed != permissionStatus.observed || previousPermission.reason?.code != permissionStatus.reason?.code ||
               previousPermission.generation != permissionStatus.generation || previousMode.observed != modeStatus.observed ||
               previousMode.generation != modeStatus.generation || previousText != micModeText { objectWillChange.send() }
        }
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
