import AVFoundation
import LiveKit

@MainActor protocol AudioPublishing: AnyObject {
    var cleanupProblem: String? { get }
    func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws
}
@MainActor protocol PCMAudioPublishing: AnyObject {
    var cleanupProblem: String? { get }
    func retryCleanup() async
    func startPCM(in room: Room) async throws
    func submitPCM(_ data: Data) throws
    func stopPCM(in room: Room) async
    func closePCMGate()
}

extension AudioPublishing { var cleanupProblem: String? { nil } }

extension PCMAudioPublishing {
    var cleanupProblem: String? { nil }
    func retryCleanup() async {}
    func closePCMGate() {}
}

@MainActor struct AudioEngineControl {
    var microphone: (Room, Bool) async throws -> Void
    var manualMode: (Bool) throws -> Void
    var isManual: () -> Bool
    static var live: Self {
        Self(microphone: { room, enabled in _ = try await room.localParticipant.setMicrophone(enabled: enabled) },
             manualMode: { try AudioManager.shared.setManualRenderingMode($0) },
             isManual: { AudioManager.shared.isManualRenderingMode })
    }
}

/// LiveKit converts and schedules on one queue. Cancellation excludes an in-flight capture call.
private final class PCMFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VoiceMemo.CB08.publish", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var pending = 0
    func cancel() { lock.lock(); active = false; lock.unlock() }
    func submit(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        guard active, pending < 8 else { lock.unlock(); throw AudioPublishError.queueFull }
        pending += 1; lock.unlock()
        queue.async { [self] in
            lock.lock()
            defer { pending -= 1; lock.unlock() }
            guard active else { return }
            AudioManager.shared.mixer.capture(appAudio: buffer)
        }
    }
}

/// Shared ownership prevents native capture and external PCM from overlapping.
@MainActor final class AudioPublisher: AudioPublishing, PCMAudioPublishing {
    enum State: Equatable { case idle, native, external, cleanupFailed }
    private(set) var state: State = .idle
    var cleanupProblem: String? { state == .cleanupFailed ? "音频资源清理尚未完成" : nil }
    func retryCleanup() async {
        if state == .cleanupFailed, let recoveryRoom { await cleanup(recoveryRoom) }
    }
    private var feed: PCMFeed?
    private let usesLiveEngine: Bool
    private let engine: AudioEngineControl
    private var recoveryRoom: Room?
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                      channels: 1, interleaved: true)
    var onFailure: ((String) -> Void)?
    init(engine: AudioEngineControl? = nil) { self.engine = engine ?? .live; usesLiveEngine = engine == nil }
    private func recover() async throws {
        guard state == .cleanupFailed, let recoveryRoom else { return }
        await cleanup(recoveryRoom)
        guard state == .idle else { throw AudioPublishError.cleanupFailed }
    }
    private func configureAudioSession() {
        // Let LiveKit release its session after audio stops; never initialize it at App launch.
        if usesLiveEngine { AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = true }
    }
    func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws {
        if enabled { try await recover() }
        guard state != .external, !engine.isManual() else { throw AudioPublishError.engineInUse }
        if enabled { configureAudioSession() }
        recoveryRoom = room
        do {
            try await engine.microphone(room, enabled)
            state = enabled ? .native : .idle
            if !enabled { recoveryRoom = nil }
        } catch {
            state = .cleanupFailed
            onFailure?("手机音频动作失败：\(error.localizedDescription)")
            throw error
        }
    }
    func startPCM(in room: Room) async throws {
        try await recover()
        guard state == .idle, !engine.isManual() else { throw AudioPublishError.engineInUse }
        configureAudioSession()
        recoveryRoom = room
        do {
            try engine.manualMode(true)
            state = .external
            try await engine.microphone(room, true)
            feed = PCMFeed()
        } catch {
            let startError = error
            await cleanup(room)
            throw startError
        }
    }
    func submitPCM(_ data: Data) throws {
        guard state == .external, !data.isEmpty, data.count % 2 == 0, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.int16ChannelData?.pointee else { throw AudioPublishError.invalidPCM }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { UnsafeMutableRawPointer(samples).copyMemory(from: base, byteCount: data.count) }
        }
        // LiveKit schedules this buffer asynchronously: do not reuse its backing memory.
        guard let feed else { throw AudioPublishError.invalidPCM }
        try feed.submit(buffer)
    }
    private func cleanup(_ room: Room) async {
        feed?.cancel(); feed = nil
        var errors: [String] = []
        do { try await engine.microphone(room, false) }
        catch { errors.append("关闭音轨：\(error.localizedDescription)") }
        do { if engine.isManual() { try engine.manualMode(false) } }
        catch { errors.append("退出手动模式：\(error.localizedDescription)") }
        if errors.isEmpty && !engine.isManual() { state = .idle; recoveryRoom = nil }
        else {
            state = .cleanupFailed; recoveryRoom = room
            onFailure?("音频清理未完成，后续启动前将重试：" + errors.joined(separator: "；"))
        }
    }
    func closePCMGate() { feed?.cancel() }
    func stopPCM(in room: Room) async { await cleanup(room) }
}

enum AudioPublishError: Error { case engineInUse, invalidPCM, cleanupFailed, queueFull }
