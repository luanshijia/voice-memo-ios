import Foundation
import Darwin

/// All participants lock the same file; no network await occurs in a transaction.
/// Each record is atomically replaced before its request can be sent.
struct PendingRequestStore {
    let root: URL
    var legacy: UserDefaults? = nil
    var legacyRoots: [URL] = []

    func transaction<T>(_ key: String, _ update: (Data?) throws -> (Data?, T)) throws -> T {
        guard key.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "VoiceMemo.PendingRequest", code: 1)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = Darwin.open(root.appendingPathComponent("requests.lock").path,
                             O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        // Darwin exports both a `flock` function and a `flock` struct; in call
        // position the compiler picks the function, while `Darwin.flock` resolves
        // to the struct type. Keep the call unqualified.
        guard flock(fd, LOCK_EX) == 0 else { throw posixError() }
        defer { _ = flock(fd, LOCK_UN) }
        let file = root.appendingPathComponent(key + ".json")
        let exists = FileManager.default.fileExists(atPath: file.path)
        let current: Data?
        let legacyFile = legacyRoots.map { $0.appendingPathComponent(key + ".json") }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        if exists { current = try Data(contentsOf: file) }
        else if let legacyFile { current = try Data(contentsOf: legacyFile) }
        else { current = legacy?.data(forKey: key) }
        let (next, result) = try update(current)
        if let next {
            if !exists || next != current {
                try next.write(to: file, options: .atomic)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.synchronize()
            }
        } else if exists {
            try FileManager.default.removeItem(at: file)
        }
        // Migration is complete only after the replacement was saved.
        if let legacyFile { try? FileManager.default.removeItem(at: legacyFile) }
        if legacy?.object(forKey: key) != nil { legacy?.removeObject(forKey: key) }
        return result
    }

    func read(_ key: String) throws -> Data? {
        guard key.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "VoiceMemo.PendingRequest", code: 1)
        }
        let file = root.appendingPathComponent(key + ".json")
        // Writers use atomic replacement: readers see a complete old or new snapshot.
        // Only a legacy value requires migration under the existing exclusive lock.
        let needsMigration = legacy?.data(forKey: key) != nil || legacyRoots.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(key + ".json").path)
        }
        if needsMigration { return try transaction(key) { ($0, $0) } }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil // A concurrent acknowledgement may have removed this snapshot.
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
