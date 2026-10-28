import Foundation

/// Process-local counters; no payloads, identities or credentials are recorded.
enum RuntimeActivity {
    enum Item: String, CaseIterable { case sdkPacket, pcmSamples, controlHTTP, tcpProbe, legacyLookup, uiNotice }
    private static let lock = NSLock()
    private static var values: [Item: Int] = [:]
    static func add(_ item: Item, _ count: Int = 1) {
        lock.lock(); values[item, default: 0] += count; lock.unlock()
    }
    static func snapshot() -> [Item: Int] { lock.lock(); defer { lock.unlock() }; return values }
}
