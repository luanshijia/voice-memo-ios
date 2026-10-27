import XCTest
@testable import VoiceMemo

final class PendingRequestStoreTests: XCTestCase {
    func testEmptyReadCreatesNoDirectoryOrLockFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(try PendingRequestStore(root: root).read("pending"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testOldReceiptCannotDeleteAReplacedStop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingRequestStore(root: root)
        let old = Data("old".utf8), new = Data("new".utf8)
        try store.transaction("stop") { _ in (old, ()) }
        let sent = try store.read("stop")
        try store.transaction("stop") { _ in (new, ()) }
        try store.transaction("stop") { current in (current == sent ? nil : current, ()) }
        XCTAssertEqual(try store.read("stop"), new)
    }

    func testConcurrentWritersDoNotLoseUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingRequestStore(root: root)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            do {
                try store.transaction("counter") { data in
                    let count = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
                    return (Data(String(count + 1).utf8), ())
                }
            } catch { XCTFail("transaction failed: \(error)") }
        }
        XCTAssertEqual(try store.read("counter"), Data("40".utf8))
    }

    func testLegacyPendingRequestIsMigratedBeforeRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "vm.test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let old = Data("pending".utf8)
        defaults.set(old, forKey: "stop")
        let store = PendingRequestStore(root: root, legacy: defaults)
        XCTAssertEqual(try store.read("stop"), old)
        XCTAssertNil(defaults.data(forKey: "stop"))
        XCTAssertEqual(try PendingRequestStore(root: root).read("stop"), old)
    }

    func testLegacyAppGroupRequestFileIsMovedOnlyAfterPrivateCopyExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: oldRoot)
        }
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let oldFile = oldRoot.appendingPathComponent("start.json")
        let old = Data("{\"request_id\":\"preserve-me\"}".utf8)
        try old.write(to: oldFile)
        let store = PendingRequestStore(root: root, legacyRoots: [oldRoot])
        XCTAssertEqual(try store.read("start"), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("start.json")), old)
    }
}
