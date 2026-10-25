import XCTest
@testable import VoiceMemo

final class SessionOperationTests: XCTestCase {
    func testStopAndRegistrationChangesInvalidateLateResults() {
        let config = LiveKitConfig(url: "wss://home", device: "phone", userID: "owner")
        let operation = SessionOperation(generation: 3, config: config)
        XCTAssertTrue(operation.isCurrent(generation: 3, config: config))
        XCTAssertFalse(operation.isCurrent(generation: 4, config: config))
        XCTAssertFalse(operation.isCurrent(generation: 3,
            config: LiveKitConfig(url: "wss://other", device: "phone", userID: "owner")))
        XCTAssertFalse(operation.isCurrent(generation: 3,
            config: LiveKitConfig(url: "wss://home", device: "other", userID: "owner")))
    }
}
