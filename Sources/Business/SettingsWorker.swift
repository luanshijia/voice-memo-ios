import Combine
import Foundation

/// Owns registration configuration and its persisted revision.
@MainActor final class SettingsWorker: ObservableObject {
    @Published private(set) var config: LiveKitConfig
    private let defaults: UserDefaults
    var lockedByMeeting: () -> Bool = { false }
    private let checksPendingRequests: Bool
    private let pendingRequests: () -> Bool
    @Published private var pendingControl = false

    init(defaults: UserDefaults = .standard, checksPendingRequests: Bool = true,
         pendingRequests: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.checksPendingRequests = checksPendingRequests
        self.pendingRequests = pendingRequests ?? { AppStorage.hasPendingControl() || MeetingClient.hasPendingCapture() }
        config = LiveKitConfig.load(defaults: defaults)
        config.save(defaults: defaults)
        refreshPendingControls()
    }

    var credential: String { defaults.string(forKey: "vm.deviceToken") ?? "" }
    var snapshot: ConfigSnapshot {
        ConfigSnapshot(serverURL: config.url, deviceID: config.device, userID: config.userID,
                       revision: defaults.integer(forKey: "vm.configRevision"),
                       hasCredential: !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    func refreshPendingControls() {
        guard checksPendingRequests else { return }
        let pending = pendingRequests()
        if pending != pendingControl { pendingControl = pending }
    }
    var isLocked: Bool { lockedByMeeting() || pendingControl }
    var lockReason: String? { isLocked ? "当前会议或待确认动作仍绑定这份配置，请先完成对账。" : nil }

    @discardableResult func update(_ field: ConfigurationField, value: String) -> Bool {
        refreshPendingControls()
        guard !isLocked else { return false }
        objectWillChange.send()
        switch field {
        case .serverURL: config.url = value
        case .deviceID: config.device = value
        case .userID: config.userID = value
        case .credential: defaults.set(value, forKey: "vm.deviceToken")
        }
        persistChange()
        return true
    }
    func reset() {
        refreshPendingControls()
        guard !isLocked else { return }
        config = LiveKitConfig(url: LiveKitConfig.defaultURL, device: LiveKitConfig.defaultDevice,
                               userID: MeetingClient.defaultUserID)
        persistChange()
    }
    private func persistChange() {
        config.save(defaults: defaults)
        defaults.set(snapshot.revision + 1, forKey: "vm.configRevision")
        objectWillChange.send()
    }
}
