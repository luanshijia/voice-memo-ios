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
    /// 点「停止」那一刻的验收数字(推流秒数 / 家里已识别秒数)。
    /// 单独一个字段:status 会被 delegate 的「已断开(主动停止)」覆盖,那个总结行只能闪现一瞬(2026-10-18 审计)。
    @Published var lastSummary = ""
    @Published var lines: [TranscriptLine] = []
    /// 每个音源各自保留第一遍流式字幕，避免一路定稿清空另一路内容。
    @Published var partials: [TranscriptPartial] = []
    @Published var isRecording = false
    /// 用户意图:**只有 `start()` / `stop()` 能改**。
    /// SDK 被动断开时不许清它 —— 否则"掉线"会被当成"用户不想录",状态层就把故障判成正常
    /// (Codex 2026-10-18 评审第 1 条)。
    @Published private(set) var intent: LinkDesired = .notWanted
    /// 本场次标识(契约 §五):开始录音时生成、停止时清空、断线重连沿用。
    /// 它与服务端台账编号是两件事,也替代本地 `connectionGeneration` 用于丢弃上一场的迟到消息。
    @Published private(set) var sessionID = ""
    /// 当前麦克风模式(只读 —— iOS 不给 App 设置接口;界面只用来看「是不是宽谱」)
    @Published var micModeText = "读取中"
    @Published var micIsWide = false
    @Published var recordedSeconds: Double = 0     // 本地推流时长
    @Published var serverSeconds: Double = 0       // 家里已识别到的音频秒数(agent 回传,按来源分开记)

    // ---- 状态面板(规范见 notes/规范-状态显示.md;站 1 = App Group / 链路探测 / LiveKit)----
    /// 「网络」那一项的事实:nil = 还没探过(未知)。显示层只读它。
    @Published var netOK: Bool? = nil
    /// 系统直播那一路的事实:扩展写过「=== 扩展启动」且没写「结束」。
    @Published var broadcastAlive = false
    /// 扩展日志解析出来的四态(判据与阈值都在 `BroadcastProbe` 里)。
    @Published var broadcastPhase: BroadcastProbe.Phase = .stopped
    /// 五列面板。**唯一写入点 = `syncBoard()` 与 `refreshNet()`**。
    @Published var board = StatusBoard()
    /// 这一代被动结束的原因码(主动停 = nil)。只由 VoiceRoom 的 onEndReason 写入。
    private var livekEndReason: LinkReason?
    /// 影子对照去重(同一组合只记一次),`start()` 时清空。
    private var shadowSignatures = Set<String>()
    /// 各来源已识别的秒数。audio_s 是"单条音轨自创建以来"的秒数,
    /// 直接把任一路的值赋给「收」会让新开的播放轨(回传 5 秒)把麦克风那路(300 秒)压成 5 秒。
    private var serverBySource: [String: Double] = [:]
    /// 每一路上报的墙钟时间:判断它是不是"已经很久没更新",用来区分「乱序小值」和「重连后从 0 重计」
    private var progressSeenAt: [String: Date] = [:]
    /// 见过的未知消息类型:每种只提示一次,不刷屏
    private var unknownTypes = Set<String>()
    /// 收包层结构性问题计数(`parse` / `missing_type` / `topic:x` / `version:x`)
    private var protocolIssues: [String: Int] = [:]
    /// 本场是否已补发过档位(每场只补一次,见 final 分支)。
    private var didResyncSumMode = false
    /// 上一场迟到消息的丢弃条数。**正常业务事件**,不参与 `Cap.Protocol` 结论 ——
    /// 否则每换一次场它就亮红,变成噪音(2026-10-19 真机联调发现)。
    private var sessionDrops = 0

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
        get { cfg.url }
        set {
            cfg.url = newValue
            cfg.save()
            syncConfigStatus()
        }
    }
    var identity: String { cfg.identity }

    /// 读一次当前麦克风模式。未授权时不碰这个 API(iOS 17 起未授权访问有风险)。
    /// 官方口径:iOS 会按 App 记住用户选过的模式(Apple 支持文档 101993)→ 用户选一次宽谱
    /// 就等于给它定了默认;App 只能读、只能请系统弹面板,不能替用户选。
    func refreshMicMode() {
        let generation = connectionGeneration
        let allowed = (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        board.micPermission = Status(desired: LinkDesired.wanted,
                                     observed: allowed ? CapObserved.yes : CapObserved.no,
                                     reason: allowed ? nil : CapReason.permissionDenied,
                                     lastSeen: Date(), generation: generation)
        shadow("Cap.MicPermission", fresh: board.micPermissionCondition(),
               legacy: allowed ? .ok : .failed, detail: allowed ? "已授权" : "未授权")

        guard allowed else {
            micModeText = "未授权"; micIsWide = false
            board.micMode = Status(desired: LinkDesired.wanted, observed: MicModeObserved.unknownState,
                                   reason: nil, lastSeen: Date(), generation: generation)
            shadow("Cap.MicMode", fresh: board.micModeCondition(),
                   legacy: .unknown, detail: "未授权,读不到模式")
            return
        }
        let m = AVCaptureDevice.preferredMicrophoneMode
        micIsWide = (m == .wideSpectrum)
        switch m {
        case .standard:       micModeText = "标准"
        case .voiceIsolation: micModeText = "语音突显"
        case .wideSpectrum:   micModeText = "宽谱"
        default:              micModeText = "自动"
        }
        board.micMode = Status(desired: LinkDesired.wanted,
                               observed: micIsWide ? MicModeObserved.wide : MicModeObserved.other,
                               reason: nil, lastSeen: Date(), generation: generation)
        shadow("Cap.MicMode", fresh: board.micModeCondition(), legacy: .ok, detail: micModeText)
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
        // 扩展到点就把 token 文件读走删掉,所以这里要反复补;取卡本身有 12 分钟节流。
        // 但刷新循环是 3 秒一轮、取卡超时 8 秒 ⇒ 上一轮还没回来就会再叠一个 Task:
        // 并发向家里签多张卡、并发覆盖写同一个 broadcast 文件(先发后到的旧卡可能最后落盘)。
        // 用 in-flight 去重(2026-10-18 审计)。
        if broadcastTokenTask != nil { return true }
        broadcastTokenTask = Task { [weak self] in
            guard let self else { return }
            defer { self.broadcastTokenTask = nil }
            do {
                if try await self.cfg.prepareBroadcastToken(session: self.sessionID.isEmpty ? nil : self.sessionID) {
                    self.note("已为 \(self.cfg.broadcastIdentity) 取到发布用门禁卡")
                }
            } catch {
                let now = Date()
                if now.timeIntervalSince(self.lastBroadcastNote) > 60 {   // 网络断了别每 3 秒刷一条
                    self.lastBroadcastNote = now
                    self.note("广播 token 预取失败:\(error.localizedDescription)")
                }
            }
            self.syncTokenStatus()
        }
        return true
    }

    private var broadcastTokenTask: Task<Void, Never>?

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
        room.onState = { [weak self] s in
            self?.status = s
            self?.syncBoard()
        }
        room.onNote = { [weak self] s in self?.note(s) }
        room.onEndReason = { [weak self] r in self?.livekEndReason = r }
        room.onProtocolIssue = { [weak self] kind in self?.noteProtocolIssue(kind) }
        room.onEnded = { [weak self] s in
            guard let self else { return }
            self.status = s
            self.stopTimer()
            self.isRecording = false
            self.connection = nil        // SDK 已经断了,别再重复断一次
            self.syncBoard()
        }
        room.onTranscript = { [weak self] type, who, audioS, text, gap, ts, raw in
            guard let self else { return }
            // 契约 §三.5 / §五:v2 必须按场次过滤 —— 本机没有当前场次,或场次不符,一律丢弃。
            let incomingSession = (raw["session_id"] as? String) ?? ""
            let incomingVersion = (raw["schema_version"] as? Int)
                ?? (raw["schema_version"] as? NSNumber)?.intValue ?? 0
            let dropBySession = incomingVersion >= 2
                ? (self.sessionID.isEmpty || incomingSession != self.sessionID)
                : (!incomingSession.isEmpty && !self.sessionID.isEmpty && incomingSession != self.sessionID)
            if dropBySession {
                self.noteProtocolIssue("session_mismatch")
                return
            }
            self.noteUnknownFields(type: type, raw: raw)
            switch type {
            case "summary":
                // 会中提要:只追加,不顶走上面的定稿;每条都带手机本地时间(家里的 clock 不一定对得上)
                // 时间口径(Codex 2026-10-18 评审第 6 条):优先服务端 clock(HH:MM:SS),
                // 其次家里的 ts(epoch 秒),最后才退回手机本地钟 —— 手机钟与家里钟不是一回事。
                let clockText: String
                if let c = raw["clock"] as? String, !c.isEmpty {
                    clockText = String(c.prefix(5))
                } else if let t = raw["ts"] as? Double, t > 0 {
                    clockText = Self.clockFromEpoch(t)
                } else {
                    clockText = String(Self.stamp().prefix(5))
                }
                self.summaries.append(SummaryItem(clock: clockText, text: text))
                if self.summaries.count > 60 { self.summaries.removeFirst(self.summaries.count - 60) }
            case "sumstatus":
                // 状态区:家里每 60 秒推一次(哪怕这轮不出提要)—— 显示的是"为什么没出"
                self.sumState = text
                if let m = raw["mode"] as? String, !m.isEmpty { self.sumMode = m }
                if let c = raw["code"] as? String, !c.isEmpty { self.sumCode = c }
                self.board.summary = Status(desired: LinkDesired.wanted,
                                            observed: MetricValue(value: Double(self.summaries.count), unit: "轮"),
                                            reason: Self.summaryReason(code: self.sumCode),
                                            lastSeen: Date(), generation: self.connectionGeneration)
                self.conditionNote("Metric.SummaryFresh", self.board.summaryFreshCondition(),
                                   detail: "码=\(self.sumCode) 轮=\(self.summaries.count)")
                self.conditionNote("Metric.SummaryRound", self.board.summaryRoundCondition(),
                                   detail: "码=\(self.sumCode)")
            case "final":
                self.noteProgress(source: raw["source"] as? String ?? "", seconds: audioS)
                // 电脑端在还没有场次时会拒收 summode(stage=no_session),导致重连后家里退回默认档位。
                // 因此收到**本场首条有效 final** 后补发一次当前档位:每场只一次,带 v2 + 当前 session_id。
                if !self.didResyncSumMode, !self.sessionID.isEmpty {
                    self.didResyncSumMode = true
                    Task { await self.room.send(self.summodePayload(self.sumMode)) }
                    self.note("已补发当前档位 \(self.sumMode)(本场首条定稿后)")
                }
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
                self.syncProtocolStatus()
            }
        }
        // 从 Bundle 读真实版本(以前写死成 v0.2.0(build 11),截图里会误导人)
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        note("App 启动,v\(ver)(build \(build), LiveKit)")
        syncConfigStatus()
        syncProtocolStatus()
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
        guard !sessionID.isEmpty else { return }   // 未在录音:只在本机切档,不发(契约要求 v2 带场次号)
        Task { await room.send(summodePayload(m)) }
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
        protocolIssues = [:]
        loggedUnknownFields = []
        sessionDrops = 0
        didResyncSumMode = false
        summaries = []                      // 新一场:提要列表与状态区都从零开始
        sumState = "等待提要…"
        sumCode = "wait_period"
        lastSummary = ""
        status = "连接中…"
        isRecording = true
        intent = .wanted
        sessionID = UUID().uuidString.lowercased()   // 新一场:场次号换新
        livekEndReason = nil           // 新一代:上一代"被动结束"的原因作废
        shadowSignatures = []
        syncBoard()
        syncProtocolStatus()
        let cfg = self.cfg
        connecting = Task {
            // 先取走再等:await 期间用户可能又点了一次停止,stop() 会写入"新的一条" pendingDisconnect,
            // 这里若无条件置 nil 就把它的引用抹掉了(同身份双连就是在那个窗口发生的,2026-10-18 审计)。
            let prev = pendingDisconnect
            pendingDisconnect = nil
            if let prev { await prev.value }
            do {
                let card = try await cfg.requestToken(identity: cfg.identity,
                                                      session: self.sessionID.isEmpty ? nil : self.sessionID)
                let live = try await room.connect(url: card.url, token: card.token, identity: cfg.identity)
                guard generation == self.connectionGeneration else {   // 这一轮已被停止/重开取代
                    await self.room.disconnect(live)                   // 只断自己这条,不碰新会话
                    return
                }
                self.connection = live
                await room.send(self.summodePayload(self.sumMode))   // 让家里跟上本机档位
                self.startTimer()
                self.syncBoard()
            } catch {
                // VoiceRoom.connect 失败时已自行断开这条连接,这里只回写 UI
                guard generation == self.connectionGeneration else { return }
                self.note("连接异常:\(error.localizedDescription)")
                self.status = "连接失败:\(error.localizedDescription)"
                self.isRecording = false
                self.syncBoard()
            }
        }
    }

    private func stop() {
        connectionGeneration += 1     // 在飞的连接尝试作废,不许它稍后回写状态
        stopTimer()
        isRecording = false
        intent = .notWanted             // 只有用户按停止才清期望
        sessionID = ""                  // 契约:停止即换场,下一场重新生成
        partials = []                 // 在飞的部分字幕属于上一场,停止后不该再挂在屏幕上
        lastSummary = "已停止:本地推流 \(Int(recordedSeconds)) 秒,家里已识别 \(Int(serverSeconds)) 秒"
        status = "已停止"
        syncBoard()
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
                self.board.recorded = Status(desired: LinkDesired.wanted,
                                             observed: MetricValue(value: self.recordedSeconds, unit: "秒"),
                                             reason: nil, lastSeen: Date(),
                                             generation: self.connectionGeneration)
                self.conditionNote("Metric.Recorded", .ok, detail: "录=\(Int(self.recordedSeconds))秒(墙钟)")
                self.conditionNote("Metric.Progress",
                                   self.board.receivedCondition(currentGeneration: self.connectionGeneration),
                                   detail: "收=\(Int(self.serverSeconds))秒")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil; timerStartedAt = nil }

    // MARK: - 状态面板(站 1:App Group / 链路探测 / LiveKit)
    // 规范见 `notes/规范-状态显示.md`。这一节只做两件事:把事实写进五列面板、把影子对照写进 notes。
    // **不驱动任何界面** —— 站 1 的验收靠 notes,不靠画面。

    /// 把「此刻的事实」写进面板 —— LiveKit 与 App Group 两项的**唯一写入点**。
    /// 只读事实(SDK 连接态 / 是否在录 / 被动结束原因),不读任何旧文案。
    func syncBoard() {
        let generation = connectionGeneration
        var observed: LinkObserved = .notStarted
        if let state = room.connectionState {
            switch state {
            case .connected: observed = .connected
            case .connecting: observed = .connecting
            case .reconnecting: observed = .reconnecting
            case .disconnected: observed = .disconnected
            // SDK 新增了本版不认识的态:宁可 unknown,也不许当成"断开=失败"
            default: observed = .unknown
            }
        } else if intent == .wanted && connecting != nil {
            // 已发起连接、Room 对象还没建出来的那一小段:如实说"正在连",而不是"没开始"
            observed = .connecting
        }
        let reason: LinkReason? = (observed == .disconnected) ? (livekEndReason ?? .disconnected) : nil
        board.livekit = Status(desired: intent, observed: observed, reason: reason,
                               lastSeen: Date(), generation: generation)

        let groupOK = BroadcastProbe.containerURL() != nil
        board.appGroup = Status(desired: LinkDesired.wanted,
                                observed: groupOK ? CapObserved.yes : CapObserved.no,
                                reason: groupOK ? nil : CapReason.appGroupUnavailable,
                                lastSeen: Date(), generation: generation)

        shadow("Link.LiveKit",
               fresh: board.livekitCondition(currentGeneration: generation),
               legacy: legacyLiveKitCondition(),
               detail: "status=\(status) 观测=\(observed) 码=\(reason?.code ?? "-")")
        shadow("Cap.AppGroup", fresh: board.appGroupCondition(),
               legacy: groupOK ? .ok : .failed, detail: BroadcastProbe.groupName())
    }

    /// 「网络」那一项的采集入口:TCP 探一次,结果写进事实(`netOK`)与面板(`probe`)。
    func refreshNet() async {
        guard let hp = NetProbe.hostPort(from: serverURL) else {
            netOK = false
            board.probe = Status(desired: LinkDesired.wanted, observed: LinkObserved.disconnected,
                                 reason: LinkReason.probeTimeout,
                                 lastSeen: Date(), generation: connectionGeneration)
            shadowProbe()
            return
        }
        let ok = await NetProbe.check(host: hp.host, port: hp.port)
        netOK = ok
        let reason: LinkReason? = ok ? nil : .probeTimeout
        board.probe = Status(desired: LinkDesired.wanted,
                             observed: ok ? LinkObserved.connected : LinkObserved.disconnected,
                             reason: reason,
                             lastSeen: Date(), generation: connectionGeneration)
        shadowProbe()
    }

    /// 系统直播那一路的采集入口:读一次扩展日志,写事实(`broadcastAlive` / `broadcastPhase`)
    /// 与面板(`replaykit` / `extensionEmbedded`)。
    /// `desired` 取自扩展日志里的「=== 扩展启动 / 结束」标记 —— 那是**用户动作的记录**,
    /// 不是从失败结果倒推;所以这里既不猜也不越权。
    func refreshExt() async {
        let status = await BroadcastProbe.status()
        broadcastAlive = status.isActive
        broadcastPhase = status.phase

        let generation = connectionGeneration
        let observed: LinkObserved
        switch status.phase {
        case .stopped:   observed = .notStarted
        case .waiting:   observed = .connecting
        case .receiving: observed = .connected
        case .error:     observed = .disconnected
        }
        // 没启动过 = 期望"不要"(condition 判 ok);启动了就别用 isActive 当期望,
        // 否则 error 态会被算成"用户没要求" → 误判为正常。
        let desired: LinkDesired = (status.phase == .stopped) ? .notWanted : .wanted
        board.replaykit = Status(desired: desired, observed: observed, reason: status.reason,
                                 lastSeen: Date(), generation: generation)

        let embedded = BroadcastProbe.isExtensionEmbedded
        board.extensionEmbedded = Status(desired: LinkDesired.wanted,
                                         observed: embedded ? CapObserved.yes : CapObserved.no,
                                         reason: embedded ? nil : CapReason.extensionMissing,
                                         lastSeen: Date(), generation: generation)

        shadow("Link.ReplayKit", fresh: board.replaykitCondition(currentGeneration: generation),
               legacy: legacyReplayKitCondition(status),
               detail: "phase=\(status.phase) 码=\(status.reason?.code ?? "-")")
        shadow("Cap.Extension", fresh: board.extensionCondition(),
               legacy: embedded ? .ok : .failed, detail: embedded ? "包内有 appex" : "包内无 appex")
    }

    /// 「派生值变了」才记一行 —— 数值项没有旧显示值可对照,走这条。
    private func conditionNote(_ item: String, _ condition: Condition, detail: @autoclosure () -> String) {
        let signature = "\(item)|\(condition.debugName)|派生"
        guard shadowSignatures.insert(signature).inserted else { return }
        note("[派生] \(item) \(condition.debugName) · \(detail())")
    }

    /// 广播卡时效四态:没有卡 / 读不到 / 有效 / 临期 / 过期。
    /// 剩余时间按卡里记的**服务端 ttl** 算(老卡缺 ttl 才退回 900 秒);"读不到"不再是"已过期"。
    func syncTokenStatus() {
        var observed = TtlValue(remaining: 0, present: false)
        var reason: TtlReason? = nil
        var detail = ""
        switch cfg.broadcastCardState() {
        case .missing:
            reason = .fetchFailed
            detail = "还没有卡"
        case .unreadable:
            reason = .fetchFailed
            detail = "卡文件读不出来"
        case .valid(let remaining):
            observed = TtlValue(remaining: remaining, present: true)
            if remaining <= 0 {
                reason = .expired
                detail = "卡已过期"
            } else if remaining <= StatusBoard.broadcastTokenRefreshAt {
                reason = .expiring
                detail = "临期,剩余\(Int(remaining))秒"
            } else {
                detail = "剩余\(Int(remaining))秒"
            }
        }
        board.broadcastToken = Status(desired: LinkDesired.wanted, observed: observed,
                                      reason: reason, lastSeen: Date(), generation: connectionGeneration)
        conditionNote("Ttl.BroadcastToken", board.ttlCondition(), detail: detail)
    }

    /// 配置是否可用(能力项 `Cap.Config`):URL 能解析、端口在合法范围。
    /// 这一项存在的理由:端口写错时,旧代码只表现为"连接失败",根因要人倒推。
    func syncConfigStatus() {
        let url = serverURL
        let ok = (NetProbe.hostPort(from: url) != nil)
        board.config = Status(desired: LinkDesired.wanted,
                              observed: ok ? CapObserved.yes : CapObserved.no,
                              reason: ok ? nil : CapReason.configInvalid,
                              lastSeen: Date(), generation: connectionGeneration)
        conditionNote("Cap.Config", board.configCondition(), detail: url)
    }

    /// 协议项:分清「未知消息类型」与「结构性问题」(坏 JSON / 缺 type / topic 不符 / 版本不认)。
    /// 注意:**家里多发了可选字段不算我们落后** —— 额外字段我们根本不看,所以这里不会因此报警。
    func syncProtocolStatus() {
        var problems = protocolIssues.keys.sorted()
        if !unknownTypes.isEmpty {
            problems.append("未知 type:\(unknownTypes.sorted().joined(separator: ","))")
        }
        let lag = !problems.isEmpty
        board.protocolLag = Status(desired: LinkDesired.wanted,
                                   observed: lag ? CapObserved.no : CapObserved.yes,
                                   reason: lag ? CapReason.protocolLag : nil,
                                   lastSeen: Date(), generation: connectionGeneration)
        var detail = lag ? problems.joined(separator: " / ") : "无未知 type、无格式错误"
        if sessionDrops > 0 { detail += " · 已丢上一场 \(sessionDrops) 条" }
        conditionNote("Cap.Protocol", board.protocolCondition(), detail: detail)
    }

    /// 契约 §二:每种消息的“已知字段”。白名单外的字段**只记一条日志、不算协议错误**
    /// —— 允许服务端先加可选字段,不能因此把整块判成“客户端落后”。
    private static let knownFields: [String: Set<String>] = [
        "partial": ["type", "schema_version", "session_id", "who", "source", "text", "audio_s", "ts"],
        "final": ["type", "schema_version", "session_id", "who", "source", "text", "audio_s", "gap_s", "ts"],
        "summary": ["type", "schema_version", "session_id", "text", "clock", "ts", "unsupported"],
        "sumstatus": ["type", "schema_version", "session_id", "mode", "code", "text", "chars", "next_in", "ts"],
    ]
    private var loggedUnknownFields = Set<String>()

    private func noteUnknownFields(type: String, raw: [String: Any]) {
        guard let known = Self.knownFields[type] else { return }
        for key in raw.keys where !known.contains(key) && !key.hasPrefix("_") {
            if loggedUnknownFields.insert("\(type).\(key)").inserted {
                note("收到未知可选字段 \(type).\(key)(已忽略)")
            }
        }
    }

    /// 收包层结构性问题:计数 + 立刻刷新协议项。
    func noteProtocolIssue(_ kind: String) {
        if kind == "session_mismatch" {
            // 场次不符 = 上一场的迟到件,丢弃才是正确行为 ⇒ 只记条数,不改结论
            sessionDrops += 1
            note("已丢弃上一场迟到消息(累计 \(sessionDrops) 条)")
            syncProtocolStatus()
            return
        }
        protocolIssues[kind, default: 0] += 1
        note("收包异常:\(kind)(累计 \(protocolIssues[kind] ?? 0) 次)")
        syncProtocolStatus()
    }

    /// 底栏用:两路链路状态的统一词表 —— 未连 / 连中 / 已连 / 异常(用户定稿 2026-10-18)。
    /// 派生自 board 的 condition,不在视图里做字符串前缀匹配。
    var livekWord: String {
        Self.linkWord(board.livekitCondition(currentGeneration: connectionGeneration), desired: board.livekit.desired)
    }
    var repkWord: String {
        Self.linkWord(board.replaykitCondition(currentGeneration: connectionGeneration), desired: board.replaykit.desired)
    }
    private static func linkWord(_ c: Condition, desired: LinkDesired) -> String {
        if desired == .notWanted { return "未连" }
        switch c {
        case .ok: return "已连"
        case .failed: return "异常"
        case .unknown: return "连中"
        }
    }

    /// 契约 §三.5:`summode` 必须带 `schema_version` 与当前 `session_id`。
    /// 上行也取 2 —— 与下行一致,这样电脑端会按当前场次比对,上一场残留的切档会被 session_mismatch 挡掉。
    private func summodePayload(_ mode: String) -> [String: Any] {
        ["type": "summode", "schema_version": 2, "session_id": sessionID, "mode": mode]
    }

    /// 家里给的 epoch 秒 → HH:mm(只给提要标时用)。
    private static func clockFromEpoch(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    /// 家里给的提要判定码 → 原因码(码表:规范第七节)。
    private static func summaryReason(code: String) -> MetricReason? {
        switch code {
        case "no_session": return .noSession
        case "short":      return .insufficient
        case "quality":    return .quality
        case "go":         return nil
        default:           return code.hasPrefix("busy") ? .busy : nil
        }
    }

    private func shadowProbe() {
        let legacy: Condition = netOK == nil ? .unknown : ((netOK == true) ? .ok : .failed)
        shadow("Link.Probe",
               fresh: board.probeCondition(currentGeneration: connectionGeneration),
               legacy: legacy,
               detail: "netOK=\(netOK.map { $0 ? "通" : "断" } ?? "未测")")
    }

    /// 影子对照:新派生值与旧显示值都记一行,同一组合只记一次(`start()` 清空)。
    private func shadow(_ item: String, fresh: Condition, legacy: Condition,
                        detail: @autoclosure () -> String) {
        let signature = "\(item)|\(fresh.debugName)|\(legacy.debugName)"
        guard shadowSignatures.insert(signature).inserted else { return }
        let mark = fresh == legacy ? "一致" : "不一致"
        note("[影子] \(item) \(mark) 新=\(fresh.debugName) 旧=\(legacy.debugName) · \(detail())")
    }

    /// 旧口径的 ReplayKit 判据 —— 只为对照:灰(没开播)=ok、蓝(等声)=unknown、红(在收)=ok、橙(错)=failed。
    private func legacyReplayKitCondition(_ status: BroadcastProbe.Status) -> Condition {
        switch status.phase {
        case .stopped:   return .ok
        case .waiting:   return .unknown
        case .receiving: return .ok
        case .error:     return .failed
        }
    }

    /// 旧口径的 LiveKit 判据 —— 只为对照保留。它读文案,正是这次要消灭的做法。
    private func legacyLiveKitCondition() -> Condition {
        if !isRecording { return .ok }
        if status.contains("已连上") || status.contains("连接状态:已连接") { return .ok }
        if status.contains("失败") || status.contains("已断开") { return .failed }
        return .unknown
    }

    /// 记录某一路的进度并重算「收」:优先麦克风那一路(与手机「录」同一个时钟),没有才取所有来源最大值。
    /// 口径(Codex 2026-10-18 评审第 6 条):`seconds` 是**该音轨自身**的累计秒数,不是整场统一进度;
    /// `source` 是"设备+采集者"全名,与 `speaker`(识别结果)不是一回事,不能互相替代。
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
        board.received = Status(desired: LinkDesired.wanted,
                                observed: MetricValue(value: serverSeconds, unit: "秒"),
                                reason: nil, lastSeen: now, generation: connectionGeneration)
        conditionNote("Metric.Progress", board.receivedCondition(currentGeneration: connectionGeneration),
                      detail: "收=\(Int(serverSeconds))秒 来源=\(key)")
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
