import Foundation

// 信号处理里不能用 UserDefaults(不是异步信号安全的),所以用全局 fd 和一块字符缓冲
private var gLogFD: Int32 = -1
private var gStepBuf: UnsafeMutablePointer<CChar>?
private var gLastLine = ""

/// 黑匣子 v2:除了崩溃原因,还保留最近 30 步流水,便于还原"崩之前发生了什么"。
enum CrashLog {
    private static let failureKey = "mv.lastFailure"
    private static let stepsKey = "mv.steps"
    private static let runKey = "mv.runStartedAt"
    private static let countersKey = "mv.counters"
    private static let previousKey = "mv.previousRunEvidence"
    private static let maxSteps = 30

    private(set) static var previousRunStartedAt: String?
    private(set) static var previousCrashFile: String?
    private(set) static var previousSteps: String?
    private(set) static var previousFailure: String?

    static var lastFailure: String? { UserDefaults.standard.string(forKey: failureKey) }
    static var counters: String? { UserDefaults.standard.string(forKey: countersKey) }

    private static var steps: [String] = []

    static func clear() {
        [failureKey, stepsKey, runKey, countersKey, previousKey].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        steps.removeAll()
        previousCrashFile = nil
        previousFailure = nil
        previousSteps = nil
        previousRunStartedAt = nil
        if gLogFD >= 0 { ftruncate(gLogFD, 0) }
    }

    /// 记一步进度(环形缓冲,只留最近 30 步)
    static func step(_ text: String) {
        let line = "\(stamp()) \(text)"
        steps.append(line)
        if steps.count > maxSteps { steps.removeFirst(steps.count - maxSteps) }
        UserDefaults.standard.set(steps.joined(separator: "\n"), forKey: stepsKey)
        // 同步到信号处理能读的那块内存(最后一行)
        if let buf = gStepBuf {
            line.withCString { cs in
                let n = min(strlen(cs), 500)
                memcpy(buf, cs, n)
                buf[n] = 0
            }
        }
    }

    static func counters(received: Int, sent: Int, partials: Int, frames: Int) {
        UserDefaults.standard.set("收 \(received) 条 / 文本 \(partials) 条 / 发出 \(sent) 帧 / 采集 \(frames) 块",
                                  forKey: countersKey)
    }

    static func markRunStart() {
        UserDefaults.standard.set(stamp(), forKey: runKey)
        steps.removeAll()
        UserDefaults.standard.removeObject(forKey: stepsKey)
    }

    static func markRunEnd() { UserDefaults.standard.removeObject(forKey: runKey) }

    /// 启动时最先调用:读上一轮留下的痕迹(必须在 install() 清空文件之前)
    static func readPreviousRun() {
        previousRunStartedAt = UserDefaults.standard.string(forKey: runKey)
        previousSteps = UserDefaults.standard.string(forKey: stepsKey)
        previousFailure = UserDefaults.standard.string(forKey: failureKey)
        if let s = try? String(contentsOf: logFileURL, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previousCrashFile = s
        }
        // Keep the crash and its matching steps through subsequent launches.
        let defaults = UserDefaults.standard
        let saved = defaults.dictionary(forKey: previousKey) as? [String: String]
        if let evidence = retainedEvidence(crash: previousCrashFile, steps: previousSteps,
                                           failure: previousFailure, saved: saved) {
            defaults.set(evidence, forKey: previousKey)
            previousCrashFile = evidence["crash"]
            previousSteps = evidence["steps"]
            previousFailure = evidence["failure"]
        }
    }

    static func retainedEvidence(crash: String?, steps: String?, failure: String?,
                                 saved: [String: String]?) -> [String: String]? {
        guard crash != nil || (failure != nil && failure != saved?["failure"]) else { return saved }
        var evidence: [String: String] = [:]
        evidence["crash"] = crash
        evidence["steps"] = steps
        evidence["failure"] = failure
        return evidence
    }

    static func install() {
        let fd = open(logFileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 { gLogFD = fd }
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
        buf.initialize(repeating: 0, count: 512)
        gStepBuf = buf

        // C 函数指针里不能访问静态成员(会被算成"捕获上下文"),所以这里只用字面量和局部变量
        NSSetUncaughtExceptionHandler { exc in
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm:ss"
            let info = fmt.string(from: Date()) + " NSException \(exc.name.rawValue)\n原因: "
                + (exc.reason ?? "-") + "\n"
                + exc.callStackSymbols.prefix(20).joined(separator: "\n")
            UserDefaults.standard.set(info, forKey: "mv.lastFailure")
            UserDefaults.standard.synchronize()
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                if gLogFD >= 0 {
                    let a = "\n=== 收到信号 \(s) ===\n最后一步: "
                    a.withCString { _ = write(gLogFD, $0, strlen($0)) }
                    if let b = gStepBuf { _ = write(gLogFD, b, strlen(b)) }
                    let c = "\n"
                    c.withCString { _ = write(gLogFD, $0, strlen($0)) }
                    fsync(gLogFD)
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last-crash.txt")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
