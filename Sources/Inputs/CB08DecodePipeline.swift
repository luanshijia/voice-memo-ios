import Foundation

/// One serial decoder per capture epoch. The bound includes results awaiting the main actor.
final class CB08DecodePipeline: @unchecked Sendable {
    typealias Output = (pcm: Data, metrics: OpusPacketMetrics)
    private let queue = DispatchQueue(label: "VoiceMemo.CB08.decode", qos: .userInitiated)
    private let decoder: OpusDecoding
    private let lock = NSLock()
    private var active = true
    private var pending = 0
    init(decoder: OpusDecoding) { self.decoder = decoder }
    func cancel() { lock.lock(); active = false; lock.unlock() }
    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    private func release() { lock.lock(); pending -= 1; lock.unlock() }
    @discardableResult func submit(_ data: Data,
        completion: @escaping @MainActor (Result<Output, Error>) -> Void) -> Bool {
        lock.lock()
        guard active, pending < 8 else { lock.unlock(); return false }
        pending += 1; lock.unlock()
        queue.async { [self] in
            guard isActive else { release(); return }
            let result = Result { try decoder.decode(packet: data) }
            DispatchQueue.main.async { [self] in
                defer { release() }
                guard isActive else { return }
                completion(result)
            }
        }
        return true
    }
}
