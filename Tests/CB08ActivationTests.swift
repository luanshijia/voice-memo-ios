import XCTest
@testable import VoiceMemo

@MainActor final class CB08ActivationTests: XCTestCase {
    func testDefaultPhoneWorkspaceDoesNotInitializeBluetooth() {
        let input = InputWorker()
        XCTAssertFalse(input.device.isSDKInitialized)
        _ = input.isAvailable
        input.device.appState(foreground: true)
        XCTAssertFalse(input.device.isSDKInitialized)
    }
    func testExternalSelectionActivatesSDKOnlyOnce() {
        let input = InputWorker()
        _ = input.select(.external)
        XCTAssertTrue(input.device.isSDKInitialized)
        input.device.activate()
        XCTAssertTrue(input.device.isSDKInitialized)
    }
}
