import Foundation
import Darwin

/// One sample per minute, no timer of its own and no audio/Bluetooth initialization.
struct RuntimeUsageSample {
    private var uptime = ProcessInfo.processInfo.systemUptime
    private var cpu = RuntimeUsageSample.cpuSeconds()
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    mutating func report(capturing: Bool) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - uptime
        guard elapsed >= 60 else { return nil }
        let current = Self.cpuSeconds()
        defer { uptime = now; cpu = current }
        return String(format: "[功耗观察] %@ · %.0f秒 · CPU %.1f%%（单核口径）· 热状态 %ld",
                      capturing ? "采集中" : "空闲", elapsed,
                      max(0, current - cpu) / elapsed * 100, ProcessInfo.processInfo.thermalState.rawValue)
    }
}
