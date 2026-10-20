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
    @Published var recordedSeconds: Double = 0     // 本地推流时长
    @Published var serverSeconds: Double = 0       // 家里已识别到的音频秒数(agent 回传,按来源分开记)

    // ---- 状态面板(规范见 notes/规范-状态显示.md;站 1 = App Group / 链路探测 / LiveKit)----
    /// 系统直播那一路的事实:扩展写过「=== 扩展启动」且没写「结束」。
    @Published var broadcastAlive = false
    /// 五列面板。**唯一写入点 = `syncBoard()` 与 `refreshNet()`**。
    @Published var board = StatusBoard()
    /// 兼容现有视图的派生读取口；状态事实只保存在 board，不再维护第二份布尔值。
    var netOK: Bool? {
        switch board.probe.observed {
        case .connected: return true
        case .disconnected: return false
        case .notStarted, .connecting, .reconnecting, .unknown: return nil
        }
    }
    var micIsWide: Bool { board.micMode.observed == .wide }
    /// 这一代被动结束的原因码(主动停 = nil)。只由 VoiceRoom 的 onEndReason 写入。
    private var livekEndReason: LinkReason?
    /// 影子对照去重(同一组合只记一次),`start()` 时清空。
    private var noteSignatures = Set<String>()
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
    @Published private(set) var finalReportText = ""
    @Published private(set) var finalReportMeetingID = ""
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
    var deviceID: String {
        get { cfg.device }
        set { cfg.device = newValue; cfg.save(); objectWillChange.send() }
    }
    var userID: String {
        get { cfg.userID }
        set { cfg.userID = newValue; cfg.save(); objectWillChange.send() }
    }
    var deviceToken: String {
        get { MeetingControlClient.sharedDefaults()?.string(forKey: "vm.deviceToken") ?? "" }
        set {
            MeetingControlClient.sharedDefaults()?.set(newValue, forKey: "vm.deviceToken")
            objectWillChange.send()
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
        
        guard allowed else {
            micModeText = "未授权"
            board.micMode = Status(desired: LinkDesired.wanted, observed: MicModeObserved.unknownState,
                                   reason: nil, lastSeen: Date(), generation: generation)
            return
        }
        let m = AVCaptureDevice.preferredMicrophoneMode
        let observedMode: MicModeObserved = m == .wideSpectrum ? .wide : .other
        switch m {
        case .standard:       micModeText = "标准"
        case .voiceIsolation: micModeText = "语音突显"
        case .wideSpectrum:   micModeText = "宽谱"
        default:              micModeText = "自动"
        }
        board.micMode = Status(desired: LinkDesired.wanted,
                               observed: observedMode,
                               reason: nil, lastSeen: Date(), generation: generation)
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
        cfg = LiveKitConfig(url: LiveKitConfig.defaultURL, device: LiveKitConfig.defaultDevice,
                            userID: MeetingControlClient.defaultUserID)
        cfg.save()
        objectWillChange.send()
    }

    private var cfg = LiveKitConfig.load()
    private let room = VoiceRoom()
    private let observerRoom = VoiceRoom()
    private var observerConnection: Room?
    private var timer: Timer?
    /// 上一次「停止」的断开动作。实测踩过:点停止后立刻再点开始,新旧两条连接同身份并存,
    /// 服务端按 DUPLICATE_IDENTITY 把旧的那条踢掉(01:44:33 就是这么发生的)。
    /// 所以下次连接前必须先等它落地。
    private var pendingDisconnect: Task<Void, Never>?
    /// 连接世代号:每次 start/stop 都 +1。在飞的连接 Task 完成前先核对自己是不是最新一代,
    /// 不是就自己断开、不回写任何 UI —— 否则"连接中点停止再点开始"会让旧 Task 把状态翻回失败。
    private var connectionGeneration = 0
    private var serverGeneration = 0
    /// 这一代真正连上的 Room 实例。断开时只断它 —— 旧任务迟到完成不许碰新会话。
    private var connection: Room?
    /// 正在取卡/连接的那一次(此时 connection 还是 nil)。stop() 必须等它收尾,
    /// 否则它会带着同一身份连上来,把刚重开的那条挤掉。
    private var connecting: Task<Void, Never>?
    /// 计时的真实起点。以前每 0.5 秒 +0.5,滚动列表时定时器停摆、丢掉的 tick 永远不补。
    private var timerStartedAt: Date?

    init() {
        // 连接态的文字由 board 的 observed 承载(底栏 LivK/RepK + 设置页派生行),不再存一份旧文案。
        room.onState = { [weak self] _ in self?.syncBoard() }
        room.onNote = { [weak self] s in self?.note(s) }
        room.onEndReason = { [weak self] r in self?.livekEndReason = r }
        room.onProtocolIssue = { [weak self] kind in self?.noteProtocolIssue(kind) }
        room.onEnded = { [weak self] s in
            guard let self else { return }
            self.note("连接结束:\(s)")
            self.stopTimer()
            self.isRecording = false
            self.connection = nil        // SDK 已经断了,别再重复断一次
            self.syncBoard()
        }
        room.onTranscript = { [weak self] type, who, audioS, text, gap, ts, raw in
            guard let self else { return }
            // 契约 §三.5 / §五:v2 必须按场次过滤 —— 本机没有当前场次,或场次不符,一律丢弃。
            let incomingSession = (raw["session_id"] as? String) ?? ""
            let incomingVersion = WireContract.strictInteger(raw["schema_version"]) ?? 0
            let dropBySession = incomingVersion >= WireContract.sessionIDRequiredFromVersion
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
        observerRoom.onTranscript = room.onTranscript
        observerRoom.onNote = { [weak self] s in self?.note(s) }
        observerRoom.onState = { [weak self] _ in self?.syncBoard() }
        observerRoom.onEnded = { [weak self] s in
            self?.observerConnection = nil
            self?.note("会议查看连接结束:\(s)")
            self?.syncBoard()
        }
        observerRoom.onProtocolIssue = { [weak self] kind in self?.noteProtocolIssue(kind) }
        // 从 Bundle 读真实版本(以前写死成 v0.2.0(build 11),截图里会误导人)
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        note("App 启动,v\(ver)(build \(build), LiveKit)")
        syncConfigStatus()
        syncProtocolStatus()
        cfg.save() // 扩展独立启动时也能从 App Group 读取登记信息
        loadSavedReport()
        Task { [weak self] in await self?.observeDesktop() }
    }

    private func observeDesktop() async {
        while !Task.isCancelled {
            // ReplayKit may have exited before its stop request completed.
            try? await MeetingControlClient.flushPendingBroadcastStop()
            try? await MeetingControlClient.flushPendingMicStop()
            if !isRecording {
                do {
                    let state = try await MeetingControlClient.deviceView(
                        serverURL: cfg.url, deviceID: cfg.device)
                    if !isRecording {
                        let systemActive = state.meeting?.channels["system_audio"]?.status == "active"
                        if systemActive, let receiver = state.view,
                           receiver.meetingID == state.meeting?.meetingID {
                            if observerConnection == nil || sessionID != receiver.meetingID {
                                if let old = observerConnection { await observerRoom.disconnect(old) }
                                sessionID = receiver.meetingID
                                do {
                                    observerConnection = try await observerRoom.connect(
                                        url: receiver.url, token: receiver.token,
                                        identity: receiver.identity, publishMic: false)
                                } catch {
                                    note("会议查看连接失败: \(error.localizedDescription)")
                                }
                                syncBoard()
                            }
                        } else if let old = observerConnection {
                            observerConnection = nil
                            await observerRoom.disconnect(old)
                            if !isRecording { sessionID = "" }
                            syncBoard()
                        }
                        for pending in state.pendingReports {
                            do {
                                let artifact = try await MeetingControlClient.fetchArtifact(
                                    serverURL: cfg.url, meetingID: pending.meetingID,
                                    deviceID: cfg.device)
                                guard artifact.sha256 == pending.sha256 else { continue }
                                try storeReport(artifact.data, meetingID: pending.meetingID)
                                try await MeetingControlClient.acknowledgeArtifact(
                                    serverURL: cfg.url, meetingID: pending.meetingID,
                                    deviceID: cfg.device, sha256: artifact.sha256)
                                note("会后报告已保存并回执电脑端")
                            } catch {
                                // Report generation may still be running; retry on the next poll.
                            }
                        }
                    }
                } catch {
                    // Keep the last known meeting visible during a temporary network loss.
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func loadSavedReport() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let latest = files.filter { $0.lastPathComponent.hasPrefix("meeting-") &&
            $0.lastPathComponent.hasSuffix("-report.json") }.max { first, second in
            let a = (try? first.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? second.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a < b
        }
        guard let latest, let data = try? Data(contentsOf: latest) else { return }
        let name = latest.lastPathComponent
        let meetingID = String(name.dropFirst("meeting-".count).dropLast("-report.json".count))
        guard UUID(uuidString: meetingID) != nil else { return }
        try? storeReport(data, meetingID: meetingID, persist: false)
    }

    private func storeReport(_ data: Data, meetingID: String, persist: Bool = true) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["meeting_id"] as? String == meetingID,
              let report = object["report"] as? [String: Any],
              let meta = report["meta"] as? [String: Any],
              let summary = report["summary"] as? [String: Any],
              let segments = report["segments"] as? [[String: Any]] else {
            throw NSError(domain: "VoiceMemo.Report", code: 1)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let target = documents.appendingPathComponent("meeting-\(meetingID)-report.json")
        if persist { try data.write(to: target, options: .atomic) }
        var lines: [String] = [summary["title"] as? String ?? "会后纪要"]
        if meta["summary_status"] as? String == "failed" {
            lines += ["纪要生成待补；以下逐字稿已保存。"]
        }
        for (heading, key) in [("已定事项", "decisions"), ("待沟通", "open_questions"),
                               ("其它", "notes"), ("待核实", "unverified")] {
            let items = summary[key] as? [String] ?? []
            if !items.isEmpty {
                lines += ["", heading] + items.map { "• " + $0 }
            }
        }
        if let todos = summary["todos"] as? [[String: Any]], !todos.isEmpty {
            lines += ["", "待办"]
            lines += todos.map { item in
                "• \(item["task"] as? String ?? "")  负责人：\(item["owner"] as? String ?? "—")"
            }
        }
        lines += ["", "精转逐字稿"]
        lines += segments.compactMap { item in
            guard let text = item["text"] as? String else { return nil }
            return "\(item["clock"] as? String ?? "") \(item["speaker"] as? String ?? "")  \(text)"
        }
        finalReportText = lines.joined(separator: "\n")
        finalReportMeetingID = meetingID
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
        isRecording = true
        intent = .wanted
        sessionID = ""                               // 会议号由电脑总管创建并在授权回包中返回
        serverGeneration = 0
        livekEndReason = nil           // 新一代:上一代"被动结束"的原因作废
        noteSignatures = []
        syncBoard()
        syncProtocolStatus()
        let cfg = self.cfg
        connecting = Task {
            // 先取走再等:await 期间用户可能又点了一次停止,stop() 会写入"新的一条" pendingDisconnect,
            // 这里若无条件置 nil 就把它的引用抹掉了(同身份双连就是在那个窗口发生的,2026-10-18 审计)。
            let prev = pendingDisconnect
            pendingDisconnect = nil
            if let prev { await prev.value }
            if let observing = observerConnection {
                observerConnection = nil
                await observerRoom.disconnect(observing)
            }
            var grantedMeetingID: String?
            var grantedServerGeneration = 0
            do {
                try await MeetingControlClient.flushPendingMicStop()
                let card = try await cfg.requestToken(identity: cfg.identity,
                                                      channel: SessionControlContract.mic)
                grantedMeetingID = card.meetingID
                grantedServerGeneration = card.generation
                let live = try await room.connect(url: card.url, token: card.token, identity: cfg.identity)
                guard generation == self.connectionGeneration else {   // 这一轮已被停止/重开取代
                    await self.room.disconnect(live)                   // 只断自己这条,不碰新会话
                    do {
                        try MeetingControlClient.queueMicStop(serverURL: cfg.url,
                                                              meetingID: card.meetingID,
                                                              deviceID: cfg.device,
                                                              generation: card.generation)
                        try await MeetingControlClient.flushPendingMicStop()
                    } catch {
                        self.note("迟到的会议授权停止待同步: \(error.localizedDescription)")
                    }
                    return
                }
                self.sessionID = card.meetingID
                self.serverGeneration = card.generation
                self.connection = live
                do {
                    try await MeetingControlClient.reportObservation(
                        serverURL: cfg.url, meetingID: card.meetingID,
                        deviceID: cfg.device, channel: SessionControlContract.mic,
                        generation: card.generation, observed: "publishing")
                } catch {
                    self.note("手机采集状态待同步: \(error.localizedDescription)")
                }
                await room.send(self.summodePayload(self.sumMode))   // 让家里跟上本机档位
                self.startTimer()
                self.syncBoard()
            } catch {
                // VoiceRoom.connect 失败时已自行断开这条连接,这里只回写 UI
                if let grantedMeetingID {
                    do {
                        try MeetingControlClient.queueMicStop(serverURL: cfg.url,
                                                              meetingID: grantedMeetingID,
                                                              deviceID: cfg.device,
                                                              generation: grantedServerGeneration)
                        try await MeetingControlClient.flushPendingMicStop()
                    } catch {
                        self.note("连接失败后的会议停止待同步: \(error.localizedDescription)")
                    }
                }
                guard generation == self.connectionGeneration else { return }
                self.note("连接异常:\(error.localizedDescription)")
                self.note("连接失败:\(error.localizedDescription)")
                self.isRecording = false
                self.syncBoard()
            }
        }
    }

    private func stop() {
        let stoppedMeetingID = sessionID
        let stopConfig = cfg
        let stoppedGeneration = serverGeneration
        if !stoppedMeetingID.isEmpty {
            do {
                try MeetingControlClient.queueMicStop(serverURL: stopConfig.url,
                                                      meetingID: stoppedMeetingID,
                                                      deviceID: stopConfig.device,
                                                      generation: stoppedGeneration)
            } catch {
                note("停止意图保存失败: \(error.localizedDescription)")
            }
        }
        connectionGeneration += 1     // 在飞的连接尝试作废,不许它稍后回写状态
        stopTimer()
        isRecording = false
        intent = .notWanted             // 只有用户按停止才清期望
        sessionID = ""                  // 契约:停止即换场,下一场重新生成
        serverGeneration = 0
        partials = []                 // 在飞的部分字幕属于上一场,停止后不该再挂在屏幕上
        syncBoard()
        note("用户停止:推流 \(Int(recordedSeconds))s / 家里识别 \(Int(serverSeconds))s")
        // 只断开"我这一代"的那条连接:旧任务迟到时不会再拿新会话开刀
        let live = connection
        connection = nil
        let inflight = connecting          // 还没连成的那一次:它自己有世代校验,连成后会作废并断开
        connecting = nil
        pendingDisconnect = Task { [weak self] in
            await inflight?.value          // 等它彻底收尾,否则同身份双连会把新会话挤掉
            if let live { await self?.room.disconnect(live) }
            // 先结束媒体传输，再让电脑端封住该通道；否则 stop 请求可能先到，截掉尾部音频。
            if !stoppedMeetingID.isEmpty {
                do {
                    try await MeetingControlClient.flushPendingMicStop()
                } catch {
                    self?.note("电脑端会议停止状态同步失败: \(error.localizedDescription)")
                }
            }
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
        if let state = (isRecording ? room.connectionState : observerRoom.connectionState) {
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
        let receiveIntent: LinkDesired = observerConnection == nil ? intent : .wanted
        board.livekit = Status(desired: receiveIntent, observed: observed, reason: reason,
                               lastSeen: Date(), generation: generation)

        let groupOK = BroadcastProbe.containerURL() != nil
        board.appGroup = Status(desired: LinkDesired.wanted,
                                observed: groupOK ? CapObserved.yes : CapObserved.no,
                                reason: groupOK ? nil : CapReason.appGroupUnavailable,
                                lastSeen: Date(), generation: generation)

                    }

    /// 「网络」那一项的采集入口:TCP 探一次,只更新状态板事实；视图从 board 派生显示。
    func refreshNet() async {
        guard let hp = NetProbe.hostPort(from: serverURL) else {
            board.probe = Status(desired: LinkDesired.wanted, observed: LinkObserved.disconnected,
                                 reason: LinkReason.probeTimeout,
                                 lastSeen: Date(), generation: connectionGeneration)
            return
        }
        let ok = await NetProbe.check(host: hp.host, port: hp.port)
        let reason: LinkReason? = ok ? nil : .probeTimeout
        board.probe = Status(desired: LinkDesired.wanted,
                             observed: ok ? LinkObserved.connected : LinkObserved.disconnected,
                             reason: reason,
                             lastSeen: Date(), generation: connectionGeneration)
    }

    /// 系统直播那一路的采集入口:读一次扩展日志,写事实(`broadcastAlive`)
    /// 与面板(`replaykit` / `extensionEmbedded`)。
    /// `desired` 取自扩展日志里的「=== 扩展启动 / 结束」标记 —— 那是**用户动作的记录**,
    /// 不是从失败结果倒推;所以这里既不猜也不越权。
    func refreshExt() async {
        let status = await BroadcastProbe.status()
        broadcastAlive = status.isActive

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

                    }

    /// 「派生值变了」才记一行 —— 数值项没有旧显示值可对照,走这条。
    private func conditionNote(_ item: String, _ condition: Condition, detail: @autoclosure () -> String) {
        let signature = "\(item)|\(condition.debugName)|派生"
        guard noteSignatures.insert(signature).inserted else { return }
        note("[派生] \(item) \(condition.debugName) · \(detail())")
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
    private var loggedUnknownFields = Set<String>()

    private func noteUnknownFields(type: String, raw: [String: Any]) {
        guard let known = WireContract.knownFields[type] else { return }
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

    /// 底栏用:两路链路状态的统一词表 —— 未连 / 连中 / 已连 / 异常 / 未知(用户定稿 2026-10-19)。
    /// 五词而不是四词,因为 `unknown` 承载两件事:"正在连"(observed=connecting/reconnecting)
    /// 与"看不见"(心跳过期、读不到日志)。把后者说成"连中"正是这套规范最反对的糊弄。
    var livekWord: String {
        Self.linkWord(board.livekitCondition(currentGeneration: connectionGeneration),
                      observed: board.livekit.observed, desired: board.livekit.desired)
    }
    var repkWord: String {
        Self.linkWord(board.replaykitCondition(currentGeneration: connectionGeneration),
                      observed: board.replaykit.observed, desired: board.replaykit.desired)
    }
    private static func linkWord(_ c: Condition, observed: LinkObserved, desired: LinkDesired) -> String {
        if desired == .notWanted { return "未连" }
        switch c {
        case .ok: return "已连"
        case .failed: return "异常"
        case .unknown:
            switch observed {
            case .connecting, .reconnecting: return "连中"
            default: return "未知"          // 观测不到 ≠ 正在连
            }
        }
    }

    /// 底栏右组:两个可分路的数(收/句)按 LivK|RepK 给出;`录` 不可分,不在这里。
    var serverSecondsByWay: (livk: Double, repk: Double) {
        var livk = 0.0, repk = 0.0
        for (src, sec) in serverBySource {
            if src.hasSuffix("-replaykit") { repk += sec } else { livk += sec }
        }
        return (livk, repk)
    }
    var linesByWay: (livk: Int, repk: Int) {
        var livk = 0, repk = 0
        for line in lines {
            if line.source.hasSuffix("-replaykit") { repk += 1 } else { livk += 1 }
        }
        return (livk, repk)
    }

    /// 契约 §三.5:`summode` 必须带 `schema_version` 与当前 `session_id`。
    /// 上行也取 2 —— 与下行一致,这样电脑端会按当前场次比对,上一场残留的切档会被 session_mismatch 挡掉。
    private func summodePayload(_ mode: String) -> [String: Any] {
        ["type": "summode", "schema_version": WireContract.currentSchemaVersion,
         "session_id": sessionID, "mode": mode]
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
