import AVFoundation
import Foundation
import LiveKit

/// 一句话转写结果(带说话人 —— agent 是按音轨分轨识别后带上 identity 发回来的)。
struct TranscriptLine: Identifiable {
    let id = UUID()
    let who: String
    let source: String
    let text: String
    /// 这句话开始前,同一路音频静了多久(秒)。nil = 服务端没测出来(刚重连的第一句)
    var gap: Double? = nil
    /// 服务端定稿的绝对时间(epoch 秒)。0 = 老服务端没给
    var ts: Double = 0
}

struct TranscriptPartial: Identifiable {
    var id: String { source.isEmpty ? "unknown-\(who)" : source }
    var who: String
    var source: String
    var text: String
}

@MainActor
final class SessionModel: ObservableObject {
    @Published var status = "未连接"
    @Published var lines: [TranscriptLine] = []
    /// 每个音源各自保留第一遍流式字幕，避免一路定稿清空另一路内容。
    @Published var partials: [TranscriptPartial] = []
    @Published var isRecording = false
    /// 当前麦克风模式(只读 —— iOS 不给 App 设置接口;界面只用来看「是不是宽谱」)
    @Published var micModeText = "读取中"
    @Published var micIsWide = false
    @Published var recordedSeconds: Double = 0     // 本地推流时长
    @Published var serverSeconds: Double = 0       // 家里已识别到的音频秒数(agent 回传,按来源分开记)
    /// 各来源已识别的秒数。audio_s 是"单条音轨自创建以来"的秒数,
    /// 直接把任一路的值赋给「收」会让新开的播放轨(回传 5 秒)把麦克风那路(300 秒)压成 5 秒。
    private var serverBySource: [String: Double] = [:]
    /// 每一路上报的墙钟时间:判断它是不是"已经很久没更新",用来区分「乱序小值」和「重连后从 0 重计」
    private var progressSeenAt: [String: Date] = [:]
    /// 见过的未知消息类型:每种只提示一次,不刷屏
    private var unknownTypes = Set<String>()

    // ---- 会中滚动提要(方案 v3,2026-10-15)----
    /// 一轮提要 = 一行时间 + 1~3 条短要点(家里只对"新增"出要点,不重写整段)
    struct SummaryItem: Identifiable {
        let id = UUID()
        let clock: String
        let text: String
    }
    @Published var summaries: [SummaryItem] = []
    @Published var sumMode = "auto"                // auto=自动 5 分钟 / manual=手动 10 分钟
    @Published var sumState = "等待提要…"           // 状态区文案:由家里推来的 sumstatus 驱动
    @Published var sumCode = "wait_period"         // 家里给的判定码:no_session/short/quality/busy_*/go
    var serverURL: String {
        get { cfg.url } set { cfg.url = newValue; cfg.save() }
    }
    var identity: String { cfg.identity }

    /// 读一次当前麦克风模式。未授权时不碰这个 API(iOS 17 起未授权访问有风险)。
    /// 官方口径:iOS 会按 App 记住用户选过的模式(Apple 支持文档 101993)→ 用户选一次宽谱
    /// 就等于给它定了默认;App 只能读、只能请系统弹面板,不能替用户选。
    func refreshMicMode() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            micModeText = "未授权"; micIsWide = false; return
        }
        let m = AVCaptureDevice.preferredMicrophoneMode
        micIsWide = (m == .wideSpectrum)
        switch m {
        case .standard:       micModeText = "标准"
        case .voiceIsolation: micModeText = "语音突显"
        case .wideSpectrum:   micModeText = "宽谱"
        default:              micModeText = "自动"
        }
    }

    /// 「宽谱」按钮:请系统把麦克风模式选择面板弹出来(选还是用户自己选)。
    /// 面板关掉后再刷一次,按钮颜色立刻跟上。
    func presentMicModePicker() {
        note("点了「宽谱」→ 请系统弹麦克风模式面板")
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            refreshMicMode()
        }
    }

    func note(_ s: String) {
        notes.append("\(Self.stamp()) \(s)")
        if notes.count > 30 { notes.removeFirst() }
        CrashLog.step(s)          // 同步进黑匣子(崩溃时能看到最后几步)
    }
    @Published var notes: [String] = []
    var notesText: String { notes.joined(separator: "\n") }

    func resetToDefaults() {
        cfg = LiveKitConfig(url: LiveKitConfig.defaultURL, device: LiveKitConfig.defaultDevice)
        cfg.save()
        objectWillChange.send()
    }

    @discardableResult
    func prepareBroadcast() -> Bool {
        // 扩展到点就把 token 文件读走删掉,所以这里要反复补;取卡本身有 12 分钟节流,
        // 3 秒一次的循环不会真的每轮去要卡。
        Task { [weak self] in
            guard let self else { return }
            do {
                if try await self.cfg.prepareBroadcastToken() {
                    self.note("已为 \(self.cfg.broadcastIdentity) 取到发布用门禁卡")
                }
            } catch {
                let now = Date()
                if now.timeIntervalSince(self.lastBroadcastNote) > 60 {   // 网络断了别每 3 秒刷一条
                    self.lastBroadcastNote = now
                    self.note("广播 token 预取失败:\(error.localizedDescription)")
                }
            }
        }
        return true
    }

    private var cfg = LiveKitConfig.load()
    /// 广播卡取卡失败提示的节流时间(免得离线时每 3 秒刷一条状态)
    private var lastBroadcastNote = Date.distantPast
    private let room = VoiceRoom()
    private var timer: Timer?
    /// 上一次「停止」的断开动作。实测踩过:点停止后立刻再点开始,新旧两条连接同身份并存,
    /// 服务端按 DUPLICATE_IDENTITY 把旧的那条踢掉(01:44:33 就是这么发生的)。
    /// 所以下次连接前必须先等它落地。
    private var pendingDisconnect: Task<Void, Never>?
    /// 连接世代号:每次 start/stop 都 +1。在飞的连接 Task 完成前先核对自己是不是最新一代,
    /// 不是就自己断开、不回写任何 UI —— 否则"连接中点停止再点开始"会让旧 Task 把状态翻回失败。
    private var connectionGeneration = 0
    /// 这一代真正连上的 Room 实例。断开时只断它 —— 旧任务迟到完成不许碰新会话。
    private var connection: Room?
    /// 正在取卡/连接的那一次(此时 connection 还是 nil)。stop() 必须等它收尾,
    /// 否则它会带着同一身份连上来,把刚重开的那条挤掉。
    private var connecting: Task<Void, Never>?
    /// 计时的真实起点。以前每 0.5 秒 +0.5,滚动列表时定时器停摆、丢掉的 tick 永远不补。
    private var timerStartedAt: Date?

    init() {
        room.onState = { [weak self] s in self?.status = s }
        room.onNote = { [weak self] s in self?.note(s) }
        room.onEnded = { [weak self] s in
            guard let self else { return }
            self.status = s
            self.stopTimer()
            self.isRecording = false
            self.connection = nil        // SDK 已经断了,别再重复断一次
        }
        room.onTranscript = { [weak self] type, who, audioS, text, gap, ts, raw in
            guard let self else { return }
            switch type {
            case "summary":
                // 会中提要:只追加,不顶走上面的定稿;每条都带手机本地时间(家里的 clock 不一定对得上)
                self.summaries.append(SummaryItem(clock: Self.stamp().prefix(5).description, text: text))
                if self.summaries.count > 60 { self.summaries.removeFirst(self.summaries.count - 60) }
            case "sumstatus":
                // 状态区:家里每 60 秒推一次(哪怕这轮不出提要)—— 显示的是"为什么没出"
                self.sumState = text
                if let m = raw["mode"] as? String, !m.isEmpty { self.sumMode = m }
                if let c = raw["code"] as? String, !c.isEmpty { self.sumCode = c }
            case "final":
                self.noteProgress(source: raw["source"] as? String ?? "", seconds: audioS)
                if !text.isEmpty {
                    self.lines.append(TranscriptLine(who: who, source: raw["source"] as? String ?? "",
                                                     text: text, gap: gap, ts: ts))
                    if self.lines.count > 4000 { self.lines.removeFirst(self.lines.count - 4000) }
                }
                self.clearPartial(source: raw["source"] as? String ?? "", who: who)
            case "partial":
                self.noteProgress(source: raw["source"] as? String ?? "", seconds: audioS)
                self.updatePartial(source: raw["source"] as? String ?? "", who: who, text: text)
            default:
                // 未知 type 不许当流式字幕:以前 default 兜底 + 空文本会把 partial 清空。
                // 新协议字段先记一行提示(每种一次),等 App 更新后再认。
                if self.unknownTypes.insert(type).inserted {
                    self.note("收到未知消息 type=\(type),已忽略")
                }
            }
        }
        // 从 Bundle 读真实版本(以前写死成 v0.2.0(build 11),截图里会误导人)
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        note("App 启动,v\(ver)(build \(build), LiveKit)")
        _ = prepareBroadcast() // 预先刷新短期 token，保证系统原生选择器可直接启动扩展
    }

    func toggle() { isRecording ? stop() : start() }

    /// 会中提要档位:自动 5 分钟 / 手动 10 分钟(手动更长 —— 在外面要等久一点才抓得到要点)。
    /// 切档 ≠ 立刻出一段:只是把下一次检查的周期换掉。
    /// 状态行不在这里写"已切到…":按钮的选中色已经表达了档位(用户 2026-10-16 指出重复),
    /// 真正的状态由家里每 60 秒推来的 sumstatus 决定。
    func setSumMode(_ m: String) {
        guard m != sumMode else { return }
        sumMode = m
        note("会中提要档位 → \(m == "auto" ? "自动" : "手动")")
        Task { await room.send(["type": "summode", "mode": m]) }
    }

    private func start() {
        connectionGeneration += 1
        let generation = connectionGeneration
        lines = []
        partials = []
        recordedSeconds = 0
        serverSeconds = 0
        serverBySource = [:]
        progressSeenAt = [:]                // 新一场:进度墙钟与未知 type 提示都重置
        unknownTypes = []
        summaries = []                      // 新一场:提要列表与状态区都从零开始
        sumState = "等待提要…"
        sumCode = "wait_period"
        status = "连接中…"
        isRecording = true
        let cfg = self.cfg
        connecting = Task {
            if let d = pendingDisconnect { await d.value }   // 等上一次断开落地,避免同身份双连
            pendingDisconnect = nil
            do {
                let card = try await cfg.requestToken(identity: cfg.identity)   // 向家里要 15 分钟门禁卡
                let live = try await room.connect(url: card.url, token: card.token, identity: cfg.identity)
                guard generation == self.connectionGeneration else {   // 这一轮已被停止/重开取代
                    await self.room.disconnect(live)                   // 只断自己这条,不碰新会话
                    return
                }
                self.connection = live
                await room.send(["type": "summode", "mode": self.sumMode])   // 让家里跟上本机档位
                self.startTimer()
            } catch {
                // VoiceRoom.connect 失败时已自行断开这条连接,这里只回写 UI
                guard generation == self.connectionGeneration else { return }
                self.note("连接异常:\(error.localizedDescription)")
                self.status = "连接失败:\(error.localizedDescription)"
                self.isRecording = false
            }
        }
    }

    private func stop() {
        connectionGeneration += 1     // 在飞的连接尝试作废,不许它稍后回写状态
        stopTimer()
        isRecording = false
        partials = []                 // 在飞的部分字幕属于上一场,停止后不该再挂在屏幕上
        status = "已停止:本地推流 \(Int(recordedSeconds)) 秒,家里已识别 \(Int(serverSeconds)) 秒"
        note("用户停止:推流 \(Int(recordedSeconds))s / 家里识别 \(Int(serverSeconds))s")
        // 只断开"我这一代"的那条连接:旧任务迟到时不会再拿新会话开刀
        let live = connection
        connection = nil
        let inflight = connecting          // 还没连成的那一次:它自己有世代校验,连成后会作废并断开
        connecting = nil
        pendingDisconnect = Task { [weak self] in
            guard let self else { return }
            await inflight?.value          // 等它彻底收尾,否则同身份双连会把新会话挤掉
            if let live { await self.room.disconnect(live) }
        }
    }

    private func startTimer() {
        stopTimer()
        recordedSeconds = 0
        timerStartedAt = Date()
        // .common 模式:滚动字幕时定时器不停;publish 的秒数按真实时间差算,漏掉的 tick 自动补回来
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.timerStartedAt else { return }
                self.recordedSeconds = Date().timeIntervalSince(start)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil; timerStartedAt = nil }

    /// 记录某一路的进度并重算「收」:优先麦克风那一路(与手机「录」同一个时钟),没有才取所有来源最大值。
    private func noteProgress(source: String, seconds: Double) {
        let key = source.isEmpty ? "unknown" : source
        let now = Date()
        let previous = serverBySource[key] ?? 0
        // 重连/换轨后服务端 audio_s 从 0 重计:以前一律 max(),「收」就卡在旧高水位,
        // "落后 >5 秒变红"永远不响。判据:这一路 10 秒没上报=旧值已不可信,允许回退。
        let stale = now.timeIntervalSince(progressSeenAt[key] ?? .distantPast) > 10
        // 同一轨内 audio_s 单调递增:一次回退 >5 秒只可能是换轨/重连。
        // 只看时间阈值会漏掉"快速重连(<10 秒)"——那时「收」还卡在旧高水位,落后变红永远不响。
        let rewind = seconds + 5 < previous
        serverBySource[key] = (seconds < previous && !stale && !rewind) ? previous : seconds
        progressSeenAt[key] = now
        let mic = serverBySource.filter { $0.key.hasSuffix("-livekit") }.values.max()
        serverSeconds = mic ?? serverBySource.values.max() ?? 0
    }

    private func updatePartial(source: String, who: String, text: String) {
        let key = source.isEmpty ? "unknown-\(who)" : source
        if text.isEmpty {
            partials.removeAll { $0.id == key }
            return
        }
        if let index = partials.firstIndex(where: { $0.id == key }) {
            partials[index].who = who
            partials[index].source = source
            partials[index].text = text
        } else {
            partials.append(TranscriptPartial(who: who, source: source, text: text))
        }
    }

    private func clearPartial(source: String, who: String) {
        // 两把 key 都清:partial 侧 source 为空时会退化成 unknown-<who>,
        // 而 final 侧的 source 有值时 key 是 source —— 只清一种就会把已定稿的旧话永久留在第一遍区。
        let keys: Set<String> = [source.isEmpty ? "unknown-\(who)" : source, "unknown-\(who)"]
        partials.removeAll { keys.contains($0.id) }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }
}
