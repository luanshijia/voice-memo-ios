import XCTest
@testable import VoiceMemo

final class AppStorageMigrationTests: XCTestCase {
    func testLegacySettingsCopyOnceAndPreserveExistingPrivateValues() throws {
        let targetName = "vm.target." + UUID().uuidString
        let sourceName = "vm.source." + UUID().uuidString
        let target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceName))
        defer {
            target.removePersistentDomain(forName: targetName)
            source.removePersistentDomain(forName: sourceName)
        }
        source.set("wss://legacy.example", forKey: "lk.url")
        source.set("old-phone", forKey: "lk.device")
        source.set("legacy-user", forKey: "lk.user")
        source.set("credential", forKey: "vm.deviceToken")
        target.set("wss://new.example", forKey: "lk.url")

        AppStorage.migrateLegacySettings(from: [source], into: target)

        XCTAssertEqual(target.string(forKey: "lk.url"), "wss://new.example")
        XCTAssertEqual(target.string(forKey: "lk.device"), "old-phone")
        XCTAssertEqual(target.string(forKey: "lk.user"), "legacy-user")
        XCTAssertEqual(target.string(forKey: "vm.deviceToken"), "credential")
        XCTAssertNil(source.object(forKey: "vm.deviceToken"))
        AppStorage.migrateLegacySettings(from: [source], into: target)
        XCTAssertEqual(target.string(forKey: "vm.deviceToken"), "credential")
    }
}
