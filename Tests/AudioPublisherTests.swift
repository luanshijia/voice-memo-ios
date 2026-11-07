import AVFoundation
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
            stopRecording: {},
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
            stopRecording: {},
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
        }, stopRecording: {}, manualMode: { _ in }, isManual: { false }))
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
        }, stopRecording: {}, manualMode: { manual = $0 }, isManual: { manual }))
        do { try await publisher.startPCM(in: Room()); XCTFail("startup failure hidden") } catch {}
        XCTAssertFalse(manual)
        XCTAssertEqual(publisher.state, .idle)
    }
    func testFailedCleanupCanRetryWhileIdleWithoutStartingAudio() async throws {
        var manual = false, failExit = false
        var actions: [Bool] = []
        let publisher = AudioPublisher(engine: AudioEngineControl(microphone: { _, enabled in actions.append(enabled) },
            stopRecording: {},
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

    func testExternalCleanupStopsRecordingBeforeRestoringDeviceModeWithoutPermission() async throws {
        var manual = false, recording = false
        var actions: [String] = []
        let publisher = AudioPublisher(engine: AudioEngineControl(microphone: { _, enabled in
            actions.append(enabled ? "publish" : "mute")
            if enabled { recording = true } // Muting leaves the recording engine running.
        }, stopRecording: {
            actions.append("stopRecording"); recording = false
        }, manualMode: { enabled in
            if !enabled && recording { throw Failure.injected } // No phone microphone permission.
            actions.append(enabled ? "manual" : "device"); manual = enabled
        }, isManual: { manual }))
        let room = Room()
        for _ in 0..<2 {
            try await publisher.startPCM(in: room)
            await publisher.stopPCM(in: room)
            XCTAssertEqual(publisher.state, .idle)
            XCTAssertNil(publisher.cleanupProblem)
            XCTAssertFalse(recording); XCTAssertFalse(manual)
        }
        XCTAssertEqual(actions, ["manual", "publish", "mute", "stopRecording", "device",
                                 "manual", "publish", "mute", "stopRecording", "device"])
    }
    func testRecordingStopFailureKeepsManualModeAndBlocksNewCaptureUntilRecovery() async throws {
        var manual = false, failStop = true, exits = 0, starts = 0
        var failures: [String] = []
        let publisher = AudioPublisher(engine: AudioEngineControl(microphone: { _, enabled in
            if enabled { starts += 1 }
        }, stopRecording: {
            if failStop { throw Failure.injected }
        }, manualMode: { enabled in
            if !enabled { exits += 1 }; manual = enabled
        }, isManual: { manual }))
        publisher.onFailure = { failures.append($0) }
        let room = Room()
        try await publisher.startPCM(in: room)
        await publisher.stopPCM(in: room)
        XCTAssertEqual(publisher.state, .cleanupFailed)
        XCTAssertTrue(manual); XCTAssertEqual(exits, 0)
        XCTAssertTrue(failures.last?.contains("停止录音引擎") == true)
        do { try await publisher.startPCM(in: room); XCTFail("started before cleanup") } catch {}
        do { try await publisher.setNativeMicrophone(true, in: room); XCTFail("native overlap") } catch {}
        XCTAssertEqual(starts, 1); XCTAssertEqual(exits, 0)
        failStop = false
        await publisher.retryCleanup()
        XCTAssertEqual(publisher.state, .idle); XCTAssertFalse(manual)
        XCTAssertEqual(exits, 1)
        try await publisher.startPCM(in: room)
        await publisher.stopPCM(in: room)
        XCTAssertEqual(starts, 2); XCTAssertEqual(publisher.state, .idle)
    }
    func testSDKManualModeWithoutMicPermissionRequiresRecordingStopBeforeExit() throws {
        guard AVAudioApplication.shared.recordPermission != .granted else {
            throw XCTSkip("Requires a simulator without phone microphone permission")
        }
        let audio = AudioManager.shared
        XCTAssertFalse(audio.isManualRenderingMode)
        defer {
            try? audio.stopLocalRecording()
            try? audio.setManualRenderingMode(false)
        }
        try audio.setManualRenderingMode(true)
        try audio.startLocalRecording()
        // This is the old cleanup path: still-recording input tries to use a device mic.
        XCTAssertThrowsError(try audio.setManualRenderingMode(false)) { error in
            XCTAssertEqual((error as? LiveKitError)?.type, .deviceAccessDenied)
        }
        XCTAssertTrue(audio.isManualRenderingMode)
        try AudioEngineControl.live.stopRecording()
        try audio.setManualRenderingMode(false)
        XCTAssertFalse(audio.isManualRenderingMode)
        XCTAssertFalse(audio.isEngineRunning)
    }
}
