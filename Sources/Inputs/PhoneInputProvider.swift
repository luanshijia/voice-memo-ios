import LiveKit

/// The phone provider reuses LiveKit's native microphone capture; it creates no second engine.
@MainActor final class PhoneInputProvider: InputProvider {
    let binding = InputBinding.phone
    var isAvailable: Bool { true }

    private let publisher: AudioPublishing
    private var room: Room?
    private var epoch = 0

    init(publisher: AudioPublishing? = nil) {
        self.publisher = publisher ?? AudioPublisher()
    }

    func prepare() async throws {}

    func bind(_ room: Room?) { epoch += 1; self.room = room }

    func start(context: ExecutionContext) async throws {
        guard let room else { throw PhoneInputError.noActiveRoom }
        let attempt = epoch
        try await publisher.setNativeMicrophone(true, in: room)
        guard attempt == epoch else {
            try? await publisher.setNativeMicrophone(false, in: room)
            throw CancellationError()
        }
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
        epoch += 1
        guard let room else { return }
        self.room = nil
        try? await publisher.setNativeMicrophone(false, in: room)
    }
}

enum PhoneInputError: Error { case noActiveRoom }
