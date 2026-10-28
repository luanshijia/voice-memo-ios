import Foundation

/// Authenticated read evidence, scoped to the registration revision. TCP alone cannot open the gate.
struct ServerAvailability {
    enum Phase: String { case checking = "检测中", ready = "已就绪", unavailable = "不可用" }
    static let freshness: TimeInterval = 45
    private(set) var revision: Int?
    private(set) var lastSuccess: Date?
    private(set) var failures = 0
    private(set) var retryAt = Date.distantPast

    func phase(revision: Int, now: Date = Date()) -> Phase {
        guard self.revision == revision else { return .checking }
        if failures >= 2 { return .unavailable }
        guard failures == 0, let lastSuccess, now.timeIntervalSince(lastSuccess) < Self.freshness else { return .checking }
        return .ready
    }
    mutating func record(success: Bool, revision: Int, now: Date = Date()) {
        if self.revision != revision { self = Self(); self.revision = revision }
        if success { lastSuccess = now; failures = 0; retryAt = now; return }
        failures = min(failures + 1, 5)
        let delays: [TimeInterval] = [5, 15, 30, 60, 60]
        retryAt = now.addingTimeInterval(delays[failures - 1])
    }
}
