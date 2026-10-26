import LiveKit

/// The phone provider reuses LiveKit's native microphone capture; it creates no second engine.
@MainActor final class PhoneInputProvider: InputProvider {
    let binding = InputBinding.phone
    var isAvailable: Bool { true }

    private let publisher: AudioPublishing
    private var room: Room?

    init(publisher: AudioPublishing? = nil) {
        self.publisher = publisher ?? AudioPublisher()
    }

    func prepare() async throws {}

    func bind(_ room: Room?) { self.room = room }

    func start(context: ExecutionContext) async throws {
        guard let room else { throw PhoneInputError.noActiveRoom }
        try await publisher.setNativeMicrophone(true, in: room)
    }

    func pause() async throws {
        guard let room else { throw PhoneInputError.noActiveRoom }
        try await publisher.setNativeMicrophone(false, in: room)
    }

    func resume(context: ExecutionContext) async throws {
        guard let room else { throw PhoneInputError.noActiveRoom }
        try await publisher.setNativeMicrophone(true, in: room)
    }

    func stop() async {
        guard let room else { return }
        self.room = nil
        try? await publisher.setNativeMicrophone(false, in: room)
    }
}

enum PhoneInputError: Error { case noActiveRoom }
