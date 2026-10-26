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
    private let provider: PhoneInputProvider
    var configurationLocked: () -> Bool = { false }

    init(provider: PhoneInputProvider? = nil) { self.provider = provider ?? PhoneInputProvider() }
    var isAvailable: Bool { binding.kind == .phone }
    var permission: CapObserved { permissionStatus.observed }
    @discardableResult func select(_ kind: InputKind) -> CaptureActionResult {
        guard kind == .phone else { return .rejected("外设正式通路尚未接入") }
        guard !configurationLocked() else { return .rejected("请先完成当前会议或待确认动作") }
        binding = .phone
        return .submitted
    }
    func bind(_ room: Room) { provider.bind(room) }
    func start(context: ExecutionContext) async throws {
        try await provider.start(context: context)
        isCapturing = true
    }
    func stop() async { await provider.stop(); isCapturing = false }
    func interrupted() { provider.bind(nil); isCapturing = false }

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
