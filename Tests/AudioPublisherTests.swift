import LiveKit
import XCTest
@testable import VoiceMemo

@MainActor final class AudioPublisherTests: XCTestCase {
    enum Failure: Error { case injected }
    func testManualExitFailureBlocksOverlapAndRecoversBeforeNativeStart() async throws {
        var manual = false
        var failExit = false
        var notes: [String] = []
        let publisher = AudioPublisher(engine: AudioEngineControl(microphone: { _, _ in },
            manualMode: { enabled in
                if !enabled && failExit { throw Failure.injected }
                manual = enabled
            }, isManual: { manual }))
        publisher.onFailure = { notes.append($0) }
        let room = Room()
        try await publisher.startPCM(in: room)
        failExit = true
        await publisher.stopPCM(in: room)
        XCTAssertEqual(publisher.state, .cleanupFailed)
        do { try await publisher.setNativeMicrophone(true, in: room); XCTFail("overlapping start") } catch {}
        XCTAssertTrue(manual)
        XCTAssertFalse(notes.isEmpty)
        failExit = false
        try await publisher.setNativeMicrophone(true, in: room)
        XCTAssertFalse(manual)
        XCTAssertEqual(publisher.state, .native)
        try await publisher.setNativeMicrophone(false, in: room)
    }
    func testClosedPCMGateRejectsSubmissionBeforeAsyncCleanup() async throws {
        var manual = false
        let publisher = AudioPublisher(engine: AudioEngineControl(microphone: { _, _ in },
            manualMode: { manual = $0 }, isManual: { manual }))
        let room = Room()
        try await publisher.startPCM(in: room)
        publisher.closePCMGate()
        XCTAssertThrowsError(try publisher.submitPCM(Data(repeating: 0, count: 640)))
        await publisher.stopPCM(in: room)
        XCTAssertEqual(publisher.state, .idle)
    }
    func testFailedMicrophoneStopIsRetriedBeforeNewCapture() async throws {
        var failStop = false
        var actions: [Bool] = []
        let publisher = AudioPublisher(engine: AudioEngineControl(microphone: { _, enabled in
            actions.append(enabled)
            if !enabled && failStop { throw Failure.injected }
        }, manualMode: { _ in }, isManual: { false }))
        let room = Room()
        try await publisher.setNativeMicrophone(true, in: room)
        failStop = true
        do { try await publisher.setNativeMicrophone(false, in: room); XCTFail("stop failure hidden") } catch {}
        XCTAssertEqual(publisher.state, .cleanupFailed)
        failStop = false
        try await publisher.setNativeMicrophone(true, in: room)
        XCTAssertEqual(actions, [true, false, false, true])
    }
    func testExternalStartupFailureRollsBackManualMode() async {
        var manual = false
        let publisher = AudioPublisher(engine: AudioEngineControl(microphone: { _, enabled in
            if enabled { throw Failure.injected }
        }, manualMode: { manual = $0 }, isManual: { manual }))
        do { try await publisher.startPCM(in: Room()); XCTFail("startup failure hidden") } catch {}
        XCTAssertFalse(manual)
        XCTAssertEqual(publisher.state, .idle)
    }
    func testFailedCleanupCanRetryWhileIdleWithoutStartingAudio() async throws {
        var manual = false, failExit = false
        var actions: [Bool] = []
        let publisher = AudioPublisher(engine: AudioEngineControl(microphone: { _, enabled in actions.append(enabled) },
            manualMode: { enabled in
                if !enabled && failExit { throw Failure.injected }
                manual = enabled
            }, isManual: { manual }))
        let room = Room()
        try await publisher.startPCM(in: room)
        failExit = true
        await publisher.stopPCM(in: room)
        XCTAssertNotNil(publisher.cleanupProblem)
        failExit = false
        await publisher.retryCleanup()
        XCTAssertNil(publisher.cleanupProblem)
        XCTAssertEqual(publisher.state, .idle)
        XCTAssertEqual(actions, [true, false, false])
    }

}
