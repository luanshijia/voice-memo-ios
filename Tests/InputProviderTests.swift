import LiveKit
import XCTest
@testable import VoiceMemo

@MainActor final class InputProviderTests: XCTestCase {
    private final class Publisher: AudioPublishing {
        var states: [Bool] = []
        var onEnable: (@MainActor () async -> Void)?
        func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws {
            states.append(enabled)
            if enabled { await onEnable?() }
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

    func testInterruptionKeepsOldRoomUntilExplicitStopCompletes() async throws {
        let publisher = Publisher()
        let provider = PhoneInputProvider(publisher: publisher)
        provider.bind(Room())
        let context = ExecutionContext(configurationRevision: 1, operationID: UUID(),
            meetingID: UUID().uuidString, channel: "mic", generation: 1, segmentID: nil)
        try await provider.start(context: context)
        let cleanup = provider.detachForInterruption()
        await cleanup()
        XCTAssertEqual(publisher.states, [true, false])
        provider.bind(Room())
        try await provider.start(context: context)
        XCTAssertEqual(publisher.states, [true, false, true])
        await provider.stop()
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

    func testLateMicrophoneEnableCannotSurviveAnEarlierStop() async throws {
        let publisher = Publisher()
        let provider = PhoneInputProvider(publisher: publisher)
        provider.bind(Room())
        let entered = expectation(description: "enable awaiting completion")
        var release: CheckedContinuation<Void, Never>?
        publisher.onEnable = {
            entered.fulfill()
            await withCheckedContinuation { release = $0 }
        }
        let context = ExecutionContext(configurationRevision: 1, operationID: UUID(),
            meetingID: UUID().uuidString, channel: "mic", generation: 1, segmentID: nil)
        let start = Task { try await provider.start(context: context) }
        await fulfillment(of: [entered], timeout: 2)
        await provider.stop()
        XCTAssertEqual(publisher.states, [true, false])
        release?.resume()
        do { try await start.value; XCTFail("late enable remained active") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(publisher.states, [true, false, false])
    }
}
