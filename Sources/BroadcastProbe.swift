import SwiftUI
import ReplayKit

/// 广播扩展状态读回与系统启动入口；读 App Group 状态日志，不参与音频传输。
enum BroadcastProbe {
    static let groupID = "group.com.luanshijia.voicememo"
    static let extensionBundleID = "com.luanshijia.voicememo.broadcast"
    static let fileName = "broadcast-probe.log"

    /// nil = entitlement 没被签进去(App Group 不可用),这是探针要抓的第一种失败
    /// 同时试几个候选名:免费自签下 SideStore 可能把团队号后缀注进去(实测见过
    /// group.com.SideStore.SideStore.458RP2552K 这种写法),我们把两种都试一遍,并显示命中的是哪个。
    static let groupCandidates = ["group.com.luanshijia.voicememo",
                                  "group.com.luanshijia.voicememo.458RP2552K"]
    static private(set) var matchedGroup: String?

    static func containerURL() -> URL? {
        if let matchedGroup,
           let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: matchedGroup) {
            return u
        }
        for id in groupCandidates {
            if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                matchedGroup = id
                return u
            }
        }
        return nil
    }

    static func groupStatus() -> String {
        guard containerURL() != nil else {
            return "不可用(试过 \(groupCandidates.count) 个候选名,都没命中)"
        }
        // 显示【命中的组名】而不是容器 UUID —— UUID 看不出 SideStore 到底注进了哪个名字,
        // 而那个名字决定了扩展要试哪个(上一版两边名字不一致,就是 App 绿、扩展打不开的原因)。
        return "可用 → \(matchedGroup ?? "?")"
    }

    /// 设置页那一行只显示【组名】:「可用 → 」三个字删掉(用户实测反馈:太占地方),
    /// 可用性交给颜色表达 —— 绿 = 可用,红 = 不可用。
    static func groupName() -> String {
        guard containerURL() != nil else {
            return "不可用(候选名都没命中)"
        }
        return matchedGroup ?? "?"
    }

    /// 读探针日志:**容错解码**(第 4 条,2026-10-17)。
    /// 原来用 `String(contentsOf:encoding:.utf8)` 做整份严格解码 —— 文件里只要有一处非法字节
    /// (扩展写到一半被读、或扩展被系统回收时留下半个汉字)就 `try?` 失败、静默返回 "",
    /// 设置页整块变空白,而且和「压根没有日志」长得一模一样,查不出是哪一种。
    /// 现在与 `tailText` 走同一条路:`String(decoding:as:UTF8.self)`,坏字节变替换符,不再整份丢弃;
    /// 同时把诊断值(字节数 / 行数 / 替换符个数)一并返回,让「读了但内容坏」在界面上看得见。
    static func logSnapshot(maxLines: Int = 60) -> (text: String, bytes: Int, lines: Int, badChars: Int) {
        guard let url = containerURL()?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else {
            return ("", 0, 0, 0)       // 没日志 / App Group 不可用:四值全零,界面据此说明是哪一种
        }
        let text = String(decoding: data, as: UTF8.self)
        let badChars = text.reduce(0) { $1 == "\u{FFFD}" ? $0 + 1 : $0 }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return (all.suffix(maxLines).joined(separator: "\n"), data.count, all.count, badChars)
    }

    static func clearLog() {
        guard let url = containerURL()?.appendingPathComponent(fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 注意:是否在直播只认扩展显式写的标记行(`=== 扩展启动` / `=== 扩展结束`),
    /// 不做"N 秒没写入就算停"的猜测 —— 静音期间扩展会按设计断开那条传输连接但仍在直播,
    /// 超时猜测会把静音时段误判成已停止(实测踩过,别再改回去)。
    enum Phase { case stopped, waiting, receiving, error }
    struct Status { let phase: Phase; let isActive: Bool; let appFrames: Int }

    /// audioApp 计数的增量基线。整场累计值涨不动,才说明那一路真的停了 ——
    /// 用累计值判活(旧写法)会把"中途死掉的系统声轨"一直显示成在收。
    private static let sampleLock = NSLock()
    private static var lastAppFrames = 0
    private static var lastAppFramesAt = Date.distantPast

    private static func noteAppFrames(_ frames: Int) -> Bool {
        sampleLock.lock(); defer { sampleLock.unlock() }
        if frames != lastAppFrames {          // 涨了或新一轮从 0 重数,都算"还活着"
            lastAppFrames = frames
            lastAppFramesAt = Date()
            return true
        }
        return false
    }

    /// 仅解读最近一次广播生命周期，避免旧日志计数把新一轮状态染绿。
    /// 必须看到 LiveKit 已连接且本轮 audioApp 帧数大于零，才报告“正在收声”。
    static func status() async -> Status {
        guard let url = containerURL()?.appendingPathComponent(fileName) else {
            return Status(phase: .stopped, isActive: false, appFrames: 0)
        }
        // 读+解析最多 512KB,而调用方每 3 秒一轮、且跑在主线程:放后台做(2026-10-18 审计)。
        let lines = await Task.detached(priority: .utility) {
            Self.tailText(url: url, bytes: 512_000).split(separator: "\n").map(String.init)
        }.value
        guard let start = lines.lastIndex(where: { $0.contains("=== 扩展启动") }) else {
            return Status(phase: .stopped, isActive: false, appFrames: 0)
        }
        let current = lines[start...]
        guard !current.contains(where: { $0.contains("=== 扩展结束") }) else {
            return Status(phase: .stopped, isActive: false, appFrames: 0)
        }
        let failed = current.contains { line in
            ["连接或发布失败", "配置缺失或无效", "身份不符合", "无法建立", "不支持 ReplayKit", "复制 ReplayKit PCM 失败", "ReplayKit PCM 转换失败", "LiveKit 连接断开"]
                .contains { line.contains($0) }
        }
        var frames = 0
        for line in current where line.contains("计数 回调") {
            guard let marker = line.range(of: "audioApp=") else { continue }
            let digits = line[marker.upperBound...].prefix { $0.isNumber }
            if let value = Int(digits) { frames = value }
        }
        let connected = current.contains { $0.contains("LiveKit 已连接并发布音频轨") }
        let sentAudio = current.contains { $0.contains("LiveKit 已送入系统声音") }
        let paused = current.last(where: { $0.contains("扩展暂停") || $0.contains("扩展恢复") })?
            .contains("扩展暂停") ?? false
        let heartbeatIndex = current.lastIndex(where: { $0.contains("计数 回调") })
        let lifecycleIndex = current.lastIndex(where: {
            $0.contains("=== 扩展启动") || $0.contains("扩展暂停") || $0.contains("扩展恢复")
        })
        let referenceIndex = max(heartbeatIndex ?? start, lifecycleIndex ?? start)
        let referenceLine = current[referenceIndex]
        let timestamp = referenceLine.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let formatter = ISO8601DateFormatter()
        let heartbeatAge = formatter.date(from: timestamp).map { Date().timeIntervalSince($0) } ?? .infinity
        // 15 秒太紧:静止画面时 ReplayKit 给帧稀疏,静音会议会被判成"扩展死了"→ 圆点变橙、按钮"未开播"。
        // 30 秒没有新计数行才算进程真的没了。
        let stale = !paused && heartbeatAge > 30
        // 第二重判活:screen 帧一直在跳(所以 heartbeat 新鲜),但 audioApp 计数 12 秒没涨 = 系统声那一路死了。
        let audioFresh = Self.noteAppFrames(frames)
        // 静音会议里 audioApp 本来就不涨(对方没说话/视频静音),12 秒判死必然误报。
        // 改成 40 秒,并要求进程还活着(心跳 10 秒内):真死的是心跳,假死的是音频。
        let stalled = connected && frames > 0 && !paused && !audioFresh
            && heartbeatAge < 10
            && Date().timeIntervalSince(Self.lastAppFramesAt) > 40
        let phase: Phase = failed || stale || stalled ? .error
            : (connected && sentAudio && frames > 0 && !paused ? .receiving : .waiting)
        // isActive 必须由 phase 推导:stale/failed 时主 App 要重新补写广播 token,并把按钮显示成未开播。
        // 以前恒为 true,日志里残留一条"扩展启动"就会让主 App 永远不再补写 token,下一次开播直接"配置缺失"。
        return Status(phase: phase, isActive: phase != .error, appFrames: frames)
    }

    /// 整份探针日志(设置页「复制排错信息」用),带上限免得把大文件全读进内存
    /// 第 4 条(2026-10-17):这里原来也是严格解码 —— 日志一坏,连排错路径一起哑,故与 readLog 一并改成容错。
    static func fullLogText(limit: Int = 200_000) -> String {
        guard let url = containerURL()?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > limit ? String(text.suffix(limit)) : text
    }

    /// 只读文件末尾若干字节,避免直播久了(每 3 秒一行)把整份文件读进内存。
    private static func tailText(url: URL, bytes: UInt64) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > bytes ? size - bytes : 0)
        let data = (try? fh.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 系统的广播启动器:点它 → 系统弹选择器 → 选「VoiceMemo 广播」→ 开始共享。
/// 注意:广播【必须】由用户手动启动,App 不能自动触发(这是 iOS 的硬规则)。
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = BroadcastProbe.extensionBundleID
        picker.showsMicrophoneButton = true
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct AppGroupRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("App Group")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(BroadcastProbe.groupName())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(BroadcastProbe.containerURL() == nil ? Color.red : Color.green)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        }
    }
}

/// 扩展那一行:显示 appex 的 bundle id,字体与颜色跟上一行 App Group 完全一致(用户口径)
struct ExtensionRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("扩展")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(BroadcastProbe.extensionBundleID)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(BroadcastProbe.containerURL() == nil ? Color.red : Color.green)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        }
    }
}

/// 扩展日志(会长/要滚 → 按用户口径放在设置页下方)。没日志时整块不显示
/// (以前那句「还没有探针日志:扩展从未启动过,或 App Group 不可用」已失效,按要求删掉)
struct ExtLogSection: View {
    @State private var logText = ""
    @State private var logStatus = ""
    @State private var statusWarn = false
    @State private var refreshedAt = ""

    var body: some View {
        Section {
            if !logText.isEmpty {
                ScrollView {
                    Text(logText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 240)
            }
            HStack(spacing: 12) {
                Button("刷新") { load() }
                Spacer()
                Button("清空") { BroadcastProbe.clearLog(); load() }
                    .foregroundStyle(.red)
            }
            // 第 4 条(2026-10-17):读完必须说清「读到什么」——
            // 以前读失败与没有日志都表现为这块整块不显示,分不清是哪种,只能靠猜。
            if !logStatus.isEmpty {
                Text(logStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(statusWarn ? Color.orange : Color.secondary)
            }
            if !refreshedAt.isEmpty {
                Text(refreshedAt).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } header: {
            Text("扩展日志")
        } footer: {
            Text("扩展记录 LiveKit 连接、audioApp 格式与发送计数。主界面「扩展」按钮按系统声音是否到达显示状态。")
        }
        .onAppear { load() }
    }

    private func load() {
        let snap = BroadcastProbe.logSnapshot()
        logText = snap.text
        if snap.bytes == 0 {
            logStatus = "未读到日志(文件不存在,或 App Group 不可用)"
            statusWarn = true
        } else if snap.badChars > 0 {
            logStatus = "已读 \(snap.lines) 行 · \(snap.bytes) 字节 · \(snap.badChars) 处坏字节(已按替换符显示)"
            statusWarn = true
        } else {
            logStatus = "已读 \(snap.lines) 行 · \(snap.bytes) 字节"
            statusWarn = false
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        refreshedAt = "读取于 \(f.string(from: Date()))"
    }
}
