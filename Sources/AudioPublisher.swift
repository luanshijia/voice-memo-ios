import AVFoundation
import LiveKit

@MainActor protocol AudioPublishing: AnyObject {
    func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws
}

@MainActor protocol PCMAudioPublishing: AnyObject {
    func startPCM(in room: Room) async throws
    func submitPCM(_ data: Data) throws
    func stopPCM(in room: Room) async
}

/// One shared owner serializes native microphone and external memory-only capture.
@MainActor final class AudioPublisher: AudioPublishing, PCMAudioPublishing {
    private var manual = false
    static func configureAudioSession() {
        AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = false
    }
    func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws {
        guard !manual, !AudioManager.shared.isManualRenderingMode else { throw AudioPublishError.engineInUse }
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }
    func startPCM(in room: Room) async throws {
        guard !manual, !AudioManager.shared.isManualRenderingMode else { throw AudioPublishError.engineInUse }
        // No audio I/O on the handset: preserve the call's AVAudioSession route.
        try AudioManager.shared.setManualRenderingMode(true)
        manual = true
        do { try await room.localParticipant.setMicrophone(enabled: true) }
        catch {
            do { try AudioManager.shared.setManualRenderingMode(false); manual = false }
            catch { manual = true }
            throw error
        }
    }
    func submitPCM(_ data: Data) throws {
        guard manual, !data.isEmpty, data.count % 2 == 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.int16ChannelData?.pointee else { throw AudioPublishError.invalidPCM }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { UnsafeMutableRawPointer(samples).copyMemory(from: base, byteCount: data.count) }
        }
        AudioManager.shared.mixer.capture(appAudio: buffer)
    }
    func stopPCM(in room: Room) async {
        try? await room.localParticipant.setMicrophone(enabled: false)
        do { try AudioManager.shared.setManualRenderingMode(false); manual = false }
        catch { manual = true }
    }
}
enum AudioPublishError: Error { case engineInUse, invalidPCM }
