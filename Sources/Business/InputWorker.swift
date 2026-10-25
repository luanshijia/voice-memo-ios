import Foundation

@MainActor final class InputWorker {
    private let port: LegacySessionPort
    private(set) var binding = InputBinding.phone
    init(port: LegacySessionPort) { self.port = port }
    var isAvailable: Bool { binding.kind == .phone }
    var permission: CapObserved { port.board.micPermission.observed }

    @discardableResult func select(_ kind: InputKind) -> CaptureActionResult {
        guard kind == .phone else { return .rejected("外设正式通路尚未接入") }
        guard !port.configurationLocked else { return .rejected("请先完成当前会议或待确认动作") }
        binding = .phone
        return .submitted
    }
}
