import Foundation

struct CB08AudioStatistics: Sendable {
    var packets = 0
    var bytes = 0
    var frames = 0
    var samples = 0
    var sizes: [Int: Int] = [:]
    var lastPCMAt: Date?
}

/// Immutable epoch-owned route: SDK -> serial decode -> PCM feed, without per-packet main hops.
final class CB08AudioSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VoiceMemo.CB08.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var pending = 0
    private let decoder: OpusDecoding
    private let publisher: any PCMSubmitting
    private let report: @MainActor (Result<CB08AudioStatistics, Error>) -> Void
    private var statistics = CB08AudioStatistics()
    private var nextReport: TimeInterval = 0
    private var reportPending = false
    init(decoder: OpusDecoding, publisher: any PCMSubmitting,
         report: @escaping @MainActor (Result<CB08AudioStatistics, Error>) -> Void) {
        self.decoder = decoder; self.publisher = publisher; self.report = report
    }
    @discardableResult func cancel() -> CB08AudioStatistics {
        lock.lock(); defer { lock.unlock() }
        active = false; return statistics
    }
    @discardableResult func submit(_ data: Data) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        guard pending < 8 else {
            active = false; lock.unlock()
            DispatchQueue.main.async { [report] in report(.failure(AudioPublishError.queueFull)) }
            return false
        }
        pending += 1; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            lock.lock(); let allowed = active; lock.unlock()
            guard allowed else { return }
            do {
                let output = try decoder.decode(packet: data)
                lock.lock()
                guard active else { lock.unlock(); return }
                do { try publisher.submit(output.pcm) }
                catch { lock.unlock(); throw error }
                RuntimeActivity.add(.pcmSamples, output.metrics.decodedSamples)
                statistics.packets += 1; statistics.bytes += data.count
                statistics.frames += output.metrics.frameCount; statistics.samples += output.metrics.decodedSamples
                statistics.sizes[data.count, default: 0] += 1; statistics.lastPCMAt = Date()
                let now = ProcessInfo.processInfo.systemUptime
                if !reportPending && (statistics.packets == 1 || now >= nextReport) {
                    reportPending = true
                    nextReport = now + 0.5
                    DispatchQueue.main.async { [self] in
                        lock.lock()
                        let snapshot = statistics, allowed = active
                        reportPending = false; lock.unlock()
                        if allowed { report(.success(snapshot)) }
                    }
                }
                lock.unlock()
            } catch {
                lock.lock(); let wasActive = active; active = false; lock.unlock()
                if wasActive { DispatchQueue.main.async { [report] in report(.failure(error)) } }
            }
        }
        return true
    }
}

/// The SDK delegate is nonisolated; installation and removal are atomic with submission.
final class CB08AudioRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CB08AudioSession?
    func install(_ next: CB08AudioSession?) {
        lock.lock(); defer { lock.unlock() }
        session?.cancel(); session = next
    }
    func receive(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return false }
        session.submit(data)
        return true
    }
}

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
