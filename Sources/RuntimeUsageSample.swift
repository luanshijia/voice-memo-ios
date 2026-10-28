import Foundation
import Darwin

/// Only complete, continuously observed foreground windows are comparable.
struct RuntimeUsageSample {
    private let clock: () -> Double
    private let cpuTime: () -> Double
    private var uptime: Double
    private var cpu: Double
    private var lastObservation: Double
    private var context: String?
    private var counts = RuntimeActivity.snapshot()
    private var commands = RuntimeActivity.commandSnapshot()
    init(clock: (() -> Double)? = nil, cpuTime: (() -> Double)? = nil) {
        let clock = clock ?? { ProcessInfo.processInfo.systemUptime }
        let cpuTime = cpuTime ?? { RuntimeUsageSample.cpuSeconds() }
        self.clock = clock; self.cpuTime = cpuTime
        uptime = clock(); lastObservation = uptime; cpu = cpuTime()
    }
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private mutating func reset(context: String, now: Double, cpu: Double) {
        self.context = context; uptime = now; lastObservation = now
        self.cpu = cpu; counts = RuntimeActivity.snapshot(); commands = RuntimeActivity.commandSnapshot()
    }
    mutating func report(context: String, foreground: Bool) -> String? {
        let now = clock(), current = cpuTime()
        // The five-second observer missed two rounds: discard rather than label a suspension as low CPU.
        if self.context != context || !foreground || now - lastObservation > 15 {
            reset(context: context, now: now, cpu: current)
            return nil
        }
        lastObservation = now
        let elapsed = now - uptime
        guard elapsed >= 60 else { return nil }
        let latest = RuntimeActivity.snapshot()
        let deltas = RuntimeActivity.Item.allCases.map { item in
            "\(item.rawValue)=\(max(0, latest[item, default: 0] - counts[item, default: 0]))"
        }.joined(separator: " ")
        let commandCounts = RuntimeActivity.commandSnapshot()
        let events = commandCounts.keys.sorted().compactMap { command -> String? in
            let count = commandCounts[command, default: 0] - commands[command, default: 0]
            return count > 0 ? "cmd\(command)=\(count)" : nil
        }.joined(separator: " ")
        let message = String(format: "[功耗观察] %@ · 完整窗口 %.0f秒 · CPU %.1f%%（单核口径）· 热状态 %ld · %@",
            context, elapsed, max(0, current - cpu) / elapsed * 100,
            ProcessInfo.processInfo.thermalState.rawValue, deltas + " " + events)
        reset(context: context, now: now, cpu: current)
        return message
    }
}
