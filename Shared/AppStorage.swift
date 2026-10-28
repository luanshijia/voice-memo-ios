import Foundation

/// S2 delegates existing stores. No move, deletion, or second request queue.
enum AppStorage {
    private static let legacySettingKeys = ["lk.url", "lk.device", "lk.user", "vm.deviceToken"]

    static func pendingRequestDirectory() throws -> URL {
        try ControlStorageLocations.directory()
    }

    /// Copy legacy App Group settings to the app-private store before SessionModel loads.
    /// The copy is durable before old values are removed, so an interrupted migration retries safely.
    static func migrateLegacySettings() {
        let sources = ControlStorageLocations.legacy().defaults
        migrateLegacySettings(from: sources, into: .standard)
    }

    static func migrateLegacySettings(from sources: [UserDefaults], into target: UserDefaults) {
        for source in sources {
            for key in legacySettingKeys {
                guard let value = source.object(forKey: key) else { continue }
                if target.object(forKey: key) == nil { target.set(value, forKey: key) }
            }
        }
        guard target.synchronize() else { return }
        for source in sources {
            for key in legacySettingKeys { source.removeObject(forKey: key) }
            source.synchronize()
        }
    }

    static var configurationRevision: Int { UserDefaults.standard.integer(forKey: "vm.configRevision") }
    static func configurationChanged() {
        UserDefaults.standard.set(configurationRevision + 1, forKey: "vm.configRevision")
    }

    static func hasPendingControl() -> Bool {
        let keys = ["vm.pendingMicStart", "vm.pendingMicStop",
                    "vm.pendingSystemAudioStart", "vm.pendingSystemAudioStop"]
        if let root = try? pendingRequestDirectory(), keys.contains(where: {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0 + ".json").path)
        }) { return true }
        let locations = ControlStorageLocations.legacy()
        if locations.defaults.contains(where: { defaults in keys.contains { defaults.data(forKey: $0) != nil } }) { return true }
        for directory in locations.roots {
            if keys.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".json").path) }) { return true }
        }
        return false
    }
}
