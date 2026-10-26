import Foundation

/// S2 delegates existing stores. No move, deletion, or second request queue.
enum AppStorage {
    private static let legacySettingKeys = ["lk.url", "lk.device", "lk.user", "vm.deviceToken"]

    static func pendingRequestDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        return support.appendingPathComponent("VoiceMemo", isDirectory: true)
            .appendingPathComponent("pending-control", isDirectory: true)
    }

    /// Copy legacy App Group settings to the app-private store before SessionModel loads.
    /// The copy is durable before old values are removed, so an interrupted migration retries safely.
    static func migrateLegacySettings() {
        let sources = MeetingClient.appGroupCandidates.compactMap { group in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
                .flatMap { _ in UserDefaults(suiteName: group) }
        }
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
        if let legacy = MeetingClient.sharedDefaults(), keys.contains(where: { legacy.data(forKey: $0) != nil }) {
            return true
        }
        for group in MeetingClient.appGroupCandidates {
            guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { continue }
            let directory = root.appendingPathComponent("pending-control")
            if keys.contains(where: {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".json").path)
            }) { return true }
        }
        return false
    }
}
