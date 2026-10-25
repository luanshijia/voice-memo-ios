import Foundation
import Darwin

/// All participants lock the same file; no network await occurs in a transaction.
/// Each record is atomically replaced before its request can be sent.
struct PendingRequestStore {
    let root: URL
    var legacy: UserDefaults? = nil

    func transaction<T>(_ key: String, _ update: (Data?) throws -> (Data?, T)) throws -> T {
        guard key.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "VoiceMemo.PendingRequest", code: 1)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = Darwin.open(root.appendingPathComponent("requests.lock").path,
                             O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        // Darwin also imports a struct named flock. An explicit function type
        // selects the POSIX function instead of the struct initializer.
        let fileLock: (Int32, Int32) -> Int32 = Darwin.flock
        guard fileLock(fd, LOCK_EX) == 0 else { throw posixError() }
        defer { _ = fileLock(fd, LOCK_UN) }
        let file = root.appendingPathComponent(key + ".json")
        let exists = FileManager.default.fileExists(atPath: file.path)
        legacy?.synchronize()
        let current: Data?
        if exists { current = try Data(contentsOf: file) }
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
        legacy?.removeObject(forKey: key)
        legacy?.synchronize()
        return result
    }

    func read(_ key: String) throws -> Data? {
        try transaction(key) { ($0, $0) }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
