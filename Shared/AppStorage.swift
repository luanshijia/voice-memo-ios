import Foundation

/// S2 delegates existing stores. No move, deletion, or second request queue.
enum AppStorage {
    static var configurationRevision: Int { UserDefaults.standard.integer(forKey: "vm.configRevision") }
    static func configurationChanged() {
        UserDefaults.standard.set(configurationRevision + 1, forKey: "vm.configRevision")
    }

    static func hasPendingControl() -> Bool {
        let keys = ["vm.pendingMicStart", "vm.pendingMicStop",
                    "vm.pendingSystemAudioStart", "vm.pendingSystemAudioStop"]
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
