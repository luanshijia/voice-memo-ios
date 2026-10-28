import Foundation

/// Discover compatibility locations once per foreground epoch, outside View getters.
enum ControlStorageLocations {
    struct Legacy {
        let roots: [URL]
        let defaults: [UserDefaults]
    }
    private static let lock = NSLock()
    private static var cachedLegacy: Legacy?
    private static var cachedDirectory: URL?
    static func legacy() -> Legacy {
        lock.lock(); defer { lock.unlock() }
        if let cachedLegacy { return cachedLegacy }
        let containers = MeetingClient.appGroupCandidates.compactMap { group -> (URL, UserDefaults?)? in
            RuntimeActivity.add(.legacyLookup)
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
            return (url, UserDefaults(suiteName: group))
        }
        let value = Legacy(roots: containers.map { $0.0.appendingPathComponent("pending-control", isDirectory: true) },
                           defaults: containers.compactMap { $0.1 })
        cachedLegacy = value
        return value
    }
    static func directory() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let cachedDirectory { return cachedDirectory }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let value = support.appendingPathComponent("VoiceMemo", isDirectory: true)
            .appendingPathComponent("pending-control", isDirectory: true)
        cachedDirectory = value
        return value
    }
    static func refresh() {
        lock.lock(); cachedLegacy = nil; cachedDirectory = nil; lock.unlock()
    }
}
