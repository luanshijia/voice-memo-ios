import Foundation

/// Process-local counters; no payloads, identities or credentials are recorded.
enum RuntimeActivity {
    enum Item: String, CaseIterable { case sdkEvent, sdkPacket, pcmSamples, controlHTTP, tcpProbe, legacyLookup, uiNotice }
    private static let lock = NSLock()
    private static var values: [Item: Int] = [:]
    static func add(_ item: Item, _ count: Int = 1) {
        lock.lock(); values[item, default: 0] += count; lock.unlock()
    }
    private static var sdkCommands: [Int: Int] = [:]
    static func recordSDKCommand(_ command: Int) {
        lock.lock(); sdkCommands[command, default: 0] += 1; lock.unlock()
    }
    static func commandSnapshot() -> [Int: Int] {
        lock.lock(); defer { lock.unlock() }; return sdkCommands
    }
    static func snapshot() -> [Item: Int] { lock.lock(); defer { lock.unlock() }; return values }
}
