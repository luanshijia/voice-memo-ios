import LiveKit
import XCTest
@testable import VoiceMemo

@MainActor final class InputProviderTests: XCTestCase {
    private final class Publisher: AudioPublishing {
        var states: [Bool] = []
        func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws {
            states.append(enabled)
        }
    }

    func testPhoneProviderUsesExplicitTrackActionsAndNoEngineCopy() async throws {
        let publisher = Publisher()
        let provider = PhoneInputProvider(publisher: publisher)
        provider.bind(Room())
        let context = ExecutionContext(configurationRevision: 1, operationID: UUID(),
            meetingID: UUID().uuidString, channel: "mic", generation: 1, segmentID: nil)

        try await provider.prepare()
        try await provider.start(context: context)
        try await provider.pause()
        try await provider.resume(context: context)
        await provider.stop()

        XCTAssertEqual(publisher.states, [true, false, true, false])
        XCTAssertTrue(provider.isAvailable)
    }

    func testPhoneProviderRejectsCaptureWithoutRoom() async {
        let provider = PhoneInputProvider(publisher: Publisher())
        let context = ExecutionContext(configurationRevision: 1, operationID: UUID(),
            meetingID: nil, channel: "mic", generation: nil, segmentID: nil)
        do {
            try await provider.start(context: context)
            XCTFail("capture started without a LiveKit room")
        } catch is PhoneInputError {
            // Expected: capture cannot be activated before transport is ready.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
