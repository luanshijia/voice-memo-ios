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

    /// 扩展是否真的嵌在包里(能力项 `Cap.Extension` 的采集入口)。
    /// 只查包内 `PlugIns/` 有没有 `.appex` —— 这与"App Group 可用"不是同一件事:
    /// 组能用只说明容器通了,不代表扩展被签进包里(2026-10-18 调研发现的缺口)。
    static var isExtensionEmbedded: Bool {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: nil)
        else { return false }
        return items.contains { $0.pathExtension == "appex" }
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
    struct Status { let phase: Phase; let isActive: Bool; let appFrames: Int
                    /// 这一轮判定为 error 时的原因码(只发码,句子在显示层)。
                    let reason: LinkReason? }

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

    /// 原因码只发码;码表在 `StatusBoard.LinkReason`。未认识的码按 bridgeFailed 报,不静默吞掉。
    private static func linkReason(_ code: String?) -> LinkReason? {
        switch code {
        case nil, "stopped_by_user": return nil
        case "grant_failed": return .tokenRejected
        case "connect_failed": return .connectFailed
        case "disconnected": return .disconnected
        case "identity_mismatch", "pcm_unavailable", "conversion_failed": return .bridgeFailed
        default: return .bridgeFailed
        }
    }

    /// 只解读最新一条结构化观测。
    static func status() async -> Status {
        guard let url = containerURL()?.appendingPathComponent(fileName) else {
            return Status(phase: .stopped, isActive: false, appFrames: 0, reason: nil)
        }
        // 读+解析最多 512KB,而调用方每 3 秒一轮、且跑在主线程:放后台做(2026-10-18 审计)。
        let lines = await Task.detached(priority: .utility) {
            Self.tailText(url: url, bytes: 512_000).split(separator: "\n")
        }.value
        guard let latest = lines.last(where: { $0.contains(" obs ") }),
              let observation = SharedObservation.parse(latest) else {
            // 没有结构化观测:旧格式日志,或扩展从未启动。不猜,按未开播处理。
            return Status(phase: .stopped, isActive: false, appFrames: 0, reason: nil)
        }
        let heartbeatAge = Date().timeIntervalSince(observation.at)
        let audioFresh = Self.noteAppFrames(observation.audioApp)
        // 心跳新鲜但 audioApp 计数 40 秒不涨 = 系统声那一路死了(视频还在出帧时才会走到这里)。
        let stalled = observation.state == .active && observation.audioApp > 0 && !audioFresh
            && heartbeatAge < 10
            && Date().timeIntervalSince(Self.lastAppFramesAt) > 40
        var reason: LinkReason?
        let phase: Phase
        switch observation.state {
        case .stopped:
            phase = .stopped
        case .interrupted:
            phase = .error
            reason = Self.linkReason(observation.reason)
        case .interruptedPending:
            phase = .waiting          // 用户主动暂停:不报错,也不能判成进程死亡
        case .starting:
            phase = .waiting
        case .active:
            if heartbeatAge > 30 {
                phase = .error
                reason = .heartbeatStale
            } else if observation.audioApp > 0 && audioFresh {
                phase = .receiving
            } else if stalled {
                phase = .error
                reason = .noAudioFrames
            } else {
                phase = .waiting
            }
        }
        return Status(phase: phase, isActive: phase != .error && phase != .stopped,
                      appFrames: observation.audioApp, reason: reason)
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
        BroadcastPickerTrigger.picker = picker       // 交给 BroadcastPickerTrigger 程序触发
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// 程序化打开系统直播选择器(2026-08-09 build 23 真机定下的做法,2026-10-19 复原)。
/// 系统只给 RPSystemBroadcastPickerView 这个「自带外观的按钮」,外观不可改:
/// 把它透明盖在自己画的按钮上会「点不动」(build 22 实测),所以反过来 ——
/// 它藏在最底层(1% 透明,仅作触发器),我们自己的按钮调 open() 去点它内部真正的 UIButton。
enum BroadcastPickerTrigger {
    static weak var picker: RPSystemBroadcastPickerView?
    static func open() {
        guard let picker else { return }
        for sub in picker.subviews {
            if let button = sub as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
    }
}

struct AppGroupRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("容器")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(BroadcastProbe.groupName())
                .font(.system(size: 11, design: .monospaced))
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(BroadcastProbe.extensionBundleID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BroadcastProbe.containerURL() == nil ? Color.red : Color.green)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
        }
    }
}

/// 扩展日志(会长/要滚 → 按用户口径放在设置页下方)。没日志时整块不显示
/// (以前那句「还没有探针日志:扩展从未启动过,或 App Group 不可用」已失效,按要求删掉)
struct ExtLogBody: View {
    @State private var logText = ""
    @State private var logStatus = ""
    @State private var statusWarn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        }
        .onAppear { load() }
    }

    private func load() {
        let snap = BroadcastProbe.logSnapshot()
        logText = snap.text
        // 用户口径 2026-10-19:成功态不报"已读 N 行 / X 字节",也不报"读取于";
        // 只在真出问题时给一句(读不到 / 有坏字节),否则整块保持安静。
        if snap.bytes == 0 {
            logStatus = "未读到日志(文件不存在,或 App Group 不可用)"
            statusWarn = true
        } else if snap.badChars > 0 {
            logStatus = "\(snap.badChars) 处坏字节(已按替换符显示)"
            statusWarn = true
        } else {
            logStatus = ""
            statusWarn = false
        }
    }
}
