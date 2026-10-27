import LiveKit

/// The phone provider reuses LiveKit's native microphone capture; it creates no second engine.
@MainActor final class PhoneInputProvider: InputProvider {
    let binding = InputBinding.phone
    var isAvailable: Bool { true }

    private let publisher: AudioPublishing
    private var room: Room?
    private var epoch = 0
    private var cleanupTask: Task<Void, Never>?

    init(publisher: AudioPublishing? = nil) {
        self.publisher = publisher ?? AudioPublisher()
    }

    func prepare() async throws {}

    func bind(_ room: Room?) { epoch += 1; self.room = room }

    func start(context: ExecutionContext) async throws {
        guard let room else { throw PhoneInputError.noActiveRoom }
        let attempt = epoch
        await waitForCleanup()
        guard attempt == epoch else { throw CancellationError() }
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

    /// Invalidate immediately but keep the old room inside the cleanup closure.
    func detachForInterruption() -> @MainActor () async -> Void {
        epoch += 1
        let oldRoom = room
        room = nil
        let previous = cleanupTask
        let task = Task { [publisher] in
            await previous?.value
            guard let oldRoom else { return }
            do { try await publisher.setNativeMicrophone(false, in: oldRoom) }
            catch { /* Publisher records the failure and retains recovery ownership. */ }
        }
        cleanupTask = task
        return { await task.value }
    }
    func waitForCleanup() async { await cleanupTask?.value }
    func stop() async { let cleanup = detachForInterruption(); await cleanup() }

}

enum PhoneInputError: Error { case noActiveRoom }
