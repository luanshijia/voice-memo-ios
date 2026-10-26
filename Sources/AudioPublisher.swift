import LiveKit

/// The only owner of audio engine/session configuration and native track activation.
@MainActor protocol AudioPublishing: AnyObject {
    func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws
}

@MainActor final class AudioPublisher: AudioPublishing {
    static func configureAudioSession() {
        // Preserve the existing stop-tone behavior while keeping AVAudioSession setup centralized.
        AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = false
    }

    func setNativeMicrophone(_ enabled: Bool, in room: Room) async throws {
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }
}
