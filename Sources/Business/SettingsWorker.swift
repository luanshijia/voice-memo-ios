import Foundation

@MainActor final class SettingsWorker {
    private let port: LegacySessionPort
    init(port: LegacySessionPort) { self.port = port }
    var snapshot: ConfigSnapshot { port.configuration }
    var isLocked: Bool { port.configurationLocked }
    var lockReason: String? { isLocked ? "当前会议或待确认动作仍绑定这份配置，请先完成对账。" : nil }
    @discardableResult func update(_ field: ConfigurationField, value: String) -> Bool {
        guard !isLocked else { return false }
        port.updateConfiguration(field, value: value)
        return true
    }
    func reset() { guard !isLocked else { return }; port.resetConfiguration() }
}
