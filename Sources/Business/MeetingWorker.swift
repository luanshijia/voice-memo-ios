import Combine
import Foundation
import LiveKit

@MainActor
final class MeetingWorker: ObservableObject {
    @Published private(set) var lines: [TranscriptLine] = []
    private var transcriptStore = TranscriptStore()
    @Published private(set) var transcriptGapText = ""
    private var lastCatchUpAt = Date.distantPast
    private var catchUpRunning = false
    /// 每个音源各自保留第一遍流式字幕，避免一路定稿清空另一路内容。
    @Published private(set) var partials: [TranscriptPartial] = []
    @Published private(set) var isRecording = false
    /// 「主动终止」正在跑(查账 → 停两路 → 清本机)。防重复点击与重复请求。
    @Published private(set) var terminating = false
    /// 用户意图:**只有 `start()` / `stop()` 能改**。
    /// SDK 被动断开时不许清它 —— 否则"掉线"会被当成"用户不想录",状态层就把故障判成正常
    /// (Codex 2026-10-18 评审第 1 条)。
    @Published private(set) var intent: LinkDesired = .notWanted
    /// 本场次标识(契约 §五):开始录音时生成、停止时清空、断线重连沿用。
    /// 它与服务端台账编号是两件事,也替代本地 `transport.generation` 用于丢弃上一场的迟到消息。
    @Published private(set) var sessionID = ""
    @Published private(set) var recordedSeconds: Double = 0     // 本地推流时长
    @Published private(set) var serverSeconds: Double = 0       // 家里已识别到的音频秒数(agent 回传,按来源分开记)

    // ---- 状态面板(规范见 notes/规范-状态显示.md;站 1 = App Group / 链路探测 / LiveKit)----
    /// 电脑端总管状态的本机镜像(管家助手)。底栏的会议状态、连接状态与「主动终止」
    /// 的可用性都读它;没查到时保持上一次的值,断网不会把会议从屏幕上抹掉。
    @Published private(set) var meetingContext = MeetingContext.empty
    /// Meeting-owned metrics; device and transport facts are composed from their owners on read.
    @Published private var meetingFacts = StatusBoard()
    var board: StatusBoard {
        var result = meetingFacts
        result.livekit = transport.status(desired: intent)
        result.probe = transport.probe
        result.micPermission = input.permissionStatus
        result.micMode = input.modeStatus
        let configured = NetProbe.hostPort(from: settings.config.url) != nil
        result.config = Status(desired: .wanted, observed: configured ? .yes : .no,
                               reason: configured ? nil : .configInvalid,
                               lastSeen: Date(), generation: transport.generation)
        return result
    }
    /// 兼容现有视图的派生读取口；状态事实只保存在 board，不再维护第二份布尔值。
    var netOK: Bool? {
        switch board.probe.observed {
        case .connected: return true
        case .disconnected: return false
        case .notStarted, .connecting, .reconnecting, .unknown: return nil
        }
    }
    var micIsWide: Bool { board.micMode.observed == .wide }
    var presentation: SessionPresentation {
        SessionPresentation(isRecording: isRecording,
                           wantsToContinue: intent == .wanted,
                           networkOK: netOK,
                           terminating: terminating,
                           meeting: meetingContext)
    }
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
    /// Throttles repeated retry diagnostics while pending reports are polled.
    private var artifactDeliveryFailureAt: [String: Date] = [:]
    private var artifactDeliveryTask: Task<Void, Never>?
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
    @Published private(set) var summaries: [SummaryItem] = []
    @Published private(set) var finalReportText = ""
    @Published private(set) var finalReportMeetingID = ""
    @Published private(set) var sumMode = "auto"                // auto=自动 5 分钟 / manual=手动 10 分钟
    @Published private(set) var sumState = "等待提要…"           // 状态区文案:由家里推来的 sumstatus 驱动
    @Published private(set) var sumCode = "wait_period"         // 家里给的判定码:no_session/short/quality/busy_*/go
    let settings: SettingsWorker
    let input: InputWorker
    let transport: ConnectionWorker
    private var subscriptions = Set<AnyCancellable>()
    private var cfg: LiveKitConfig { settings.config }
    var serverURL: String { cfg.url }
    var identity: String { cfg.identity }
    var configurationLocked: Bool { settings.isLocked }
    var projection: MeetingContext { meetingContext }
    var wantsCapture: Bool { intent == .wanted }
    var micModeText: String { input.micModeText }
    func refreshMicMode() { input.refreshMicMode(generation: transport.generation) }

    func note(_ s: String) {
        notes.append("\(Self.stamp()) \(s)")
        if notes.count > 30 { notes.removeFirst() }
        CrashLog.step(s)          // 同步进黑匣子(崩溃时能看到最后几步)
    }
    @Published private(set) var notes: [String] = []
    var notesText: String { notes.joined(separator: "\n") }

    private var timer: Timer?
    private var timerStartedAt: Date?
    private var serverGeneration = 0

    init(settings: SettingsWorker, input: InputWorker, transport: ConnectionWorker,
         startObserving: Bool = true) {
        self.settings = settings
        self.input = input
        self.transport = transport
        settings.lockedByMeeting = { [weak self] in
            guard let self else { return false }
            return self.isRecording || self.intent == .wanted || self.terminating ||
                self.meetingContext.meetingAcceptsRecovery
        }
        input.configurationLocked = { [weak settings] in settings?.isLocked ?? true }
        transport.controlObservation = { [weak self] in self?.meetingContext ?? .empty }
        transport.recognitionProgress = { [weak self] in self?.board.received.observed.value ?? 0 }
        for changes in [settings.objectWillChange, input.objectWillChange, transport.objectWillChange] {
            changes.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        // 连接态的文字由 board 的 observed 承载(底栏 LivK/RepK + 设置页派生行),不再存一份旧文案。
        transport.onNote = { [weak self] s in self?.note(s) }
        transport.onProtocolIssue = { [weak self] kind in self?.noteProtocolIssue(kind) }
        transport.onEnded = { [weak self] s in
            guard let self else { return }
            self.note("连接结束:\(s)")
            self.captureInterrupted()
        }
        transport.onTranscript = { [weak self] type, who, audioS, text, gap, ts, raw in
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
                self.meetingFacts.summary = Status(desired: LinkDesired.wanted,
                                            observed: MetricValue(value: Double(self.summaries.count), unit: "轮"),
                                            reason: Self.summaryReason(code: self.sumCode),
                                            lastSeen: Date(), generation: self.transport.generation)
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
                    Task { await self.transport.send(self.summodePayload(self.sumMode)) }
                    self.note("已补发当前档位 \(self.sumMode)(本场首条定稿后)")
                }
                if !text.isEmpty || raw["seq"] != nil {
                    if let seq = WireContract.strictInteger(raw["seq"]) {
                        self.transcriptStore.merge([
                            .init(seq: seq, who: who, source: raw["source"] as? String ?? "",
                                  text: text, gap: gap, ts: ts)
                        ], epoch: raw["transcript_epoch"] as? String)
                        self.syncTranscript()
                    } else {
                        self.lines.append(TranscriptLine(who: who, source: raw["source"] as? String ?? "",
                                                         text: text, gap: gap, ts: ts))
                        if self.lines.count > 4000 { self.lines.removeFirst(self.lines.count - 4000) }
                    }
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
        if startObserving {
            loadSavedReport()
            Task { [weak self] in await self?.observeDesktop() }
        }
    }

    /// Foreground probes follow the root view's SwiftUI task lifetime.
    func refreshForegroundStateLoop() async {
        await refreshNet()
        refreshMicMode()
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            refreshMicMode()
            tick += 1
            if tick % 2 == 0 { await refreshNet() }
        }
    }

    private func observeDesktop() async {
        while !Task.isCancelled {
            // Retry a stop queued by an older build before starting new work.
            try? await MeetingClient.flushPendingBroadcastStop()
            try? await MeetingClient.flushPendingMicStop()
            do {
                let pollGeneration = transport.generation
                let pollConfig = cfg
                let state = try await MeetingClient.deviceView(
                    serverURL: pollConfig.url, deviceID: pollConfig.device)
                guard pollConfig.url == cfg.url, pollConfig.device == cfg.device,
                      pollGeneration == transport.generation else { continue }
                // 管家助手:总管那边这场会现在算什么状态。录着的时候也要查 ——
                // 底栏的会议状态与两个对接按钮都靠它,不查就永远显示"无会议"。
                meetingContext = MeetingContext(view: state)
                // Reports are independent of the current recording. The control
                // contract includes earlier unacknowledged reports while a newer
                // meeting is active, so always deliver them after the device view.
                if artifactDeliveryTask == nil, !state.pendingReports.isEmpty {
                    let deliveryConfig = cfg
                    artifactDeliveryTask = Task { [weak self] in
                        guard let self else { return }
                        defer { self.artifactDeliveryTask = nil }
                        await self.deliverPendingReports(state.pendingReports, config: deliveryConfig)
                    }
                }
            } catch {
                // Keep the last known meeting visible during a temporary network loss.
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func deliverPendingReports(_ pendingReports: [DeviceMeetingView.PendingReport],
                                       config: LiveKitConfig) async {
        for pending in pendingReports {
            do {
                let artifact = try await MeetingClient.fetchArtifact(
                    serverURL: config.url, meetingID: pending.meetingID,
                    deviceID: config.device)
                guard artifact.sha256 == pending.sha256 else {
                    noteArtifactDeliveryFailure(
                        meetingID: pending.meetingID, message: "电脑端报告摘要与待送达清单不一致")
                    continue
                }
                // Persist the exact verified bytes before acknowledging delivery.
                try storeReport(artifact.data, meetingID: pending.meetingID)
                try await MeetingClient.acknowledgeArtifact(
                    serverURL: config.url, meetingID: pending.meetingID,
                    deviceID: config.device, sha256: artifact.sha256)
                artifactDeliveryFailureAt.removeValue(forKey: pending.meetingID)
                note("会后报告已保存并回执电脑端")
            } catch {
                noteArtifactDeliveryFailure(
                    meetingID: pending.meetingID,
                    message: "\(error.localizedDescription)，将自动重试")
            }
        }
    }

    private func noteArtifactDeliveryFailure(meetingID: String, message: String) {
        let now = Date()
        if let previous = artifactDeliveryFailureAt[meetingID],
           now.timeIntervalSince(previous) < 60 {
            return
        }
        artifactDeliveryFailureAt[meetingID] = now
        note("会后报告暂未送达(\(meetingID)): \(message)")
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

    func startCapture() {
        guard !isRecording, !terminating else { return }
        start()
    }
    func stopCapture() {
        guard isRecording || intent == .wanted else { return }
        stop()
    }
    /// Explicit local observations preserve user intent across passive disconnects.
    func capturePreparing() { isRecording = true; intent = .wanted }
    func captureInterrupted() {
        stopTimer()
        isRecording = false
        input.interrupted()
        transport.interrupted()
        syncBoard()
    }
    func captureStopped() { isRecording = false; intent = .notWanted }

    /// 「主动终止」:结束这场会,并清掉本机这一轮的会议身份。
    ///
    /// 语义(用户 2026-10-24 定,固定不变):**不想要这个 room 号了、会议清盘结束,
    /// 但录音和后续纪要照常要**。所以对电脑端来说这就是一次正常的用户停止
    /// (`finishing_reason=user_stop`)——它照常核验、封场、出纪要;本机清号,
    /// 下一次点顶部「开启」不带号,电脑端自会新建一场(新 UUID / 新 room)。
    ///
    /// 为什么必须先查电脑端:用户可能刚在控制中心停过录屏,本地缓存不是权威。
    /// 为什么要替系统声补一次 stop:扩展退出后没人给它发停止,电脑端会一直认为
    /// 那一路在采;少停一路,会议就进不了收尾,下一次开启又会被并回旧会。
    func terminateMeeting() {
        guard !terminating else { return }
        terminating = true
        transport.invalidate()
        let generation = transport.generation
        let terminationConfig = cfg
        let operation = SessionOperation(generation: generation, config: terminationConfig)
        Task { @MainActor in
            defer { terminating = false }
            do {
                let view = try await MeetingClient.deviceView(serverURL: terminationConfig.url,
                                                               deviceID: terminationConfig.device)
                guard operation.isCurrent(generation: transport.generation, config: cfg) else { return }
                let fresh = MeetingContext(view: view)
                meetingContext = fresh
                guard let meetingID = fresh.meetingID, fresh.hasOpenMeeting else {
                    note("没有需要终止的会议")
                    return
                }
                if fresh.isChannelOpen(fresh.systemAudio) {
                    // Retire a channel left open by an older ReplayKit build.
                    try await MeetingClient.stopChannel(
                        serverURL: terminationConfig.url, meetingID: meetingID, deviceID: terminationConfig.device,
                        channel: SessionControlContract.systemAudio,
                        generation: fresh.systemAudioGeneration)
                    guard operation.isCurrent(generation: transport.generation, config: cfg) else { return }
                }
                if fresh.isChannelOpen(fresh.mic) {
                    try await MeetingClient.stopChannel(
                        serverURL: terminationConfig.url, meetingID: meetingID, deviceID: terminationConfig.device,
                        channel: SessionControlContract.mic,
                        generation: fresh.micGeneration)
                    guard operation.isCurrent(generation: transport.generation, config: cfg) else { return }
                }
                // 两路都已在电脑端停干净:先清本机会议号,`stop()` 见号为空就只做
                // 断连接与清屏,不会再去打扰电脑端(否则会拿旧代次重发一次多余请求)。
                sessionID = ""
                stop()
                resetCurrentMeetingData()
                syncBoard()
                syncProtocolStatus()
                note("已主动终止:旧会议交给电脑端照常收尾出纪要;下次「开启」会开新会")
            } catch {
                // 失败即停在本机:两路没停干净就清号,下次开启会被并回旧会,
                // 界面会显示"开了新会"而实际没有——宁可报错让用户重试。
                // 断网时按钮本来就是亮的(断联正是它的使用场景),此刻点它拿到
                // 的多半是连接错误:要说清是"连不上",不是"停不掉"。
                let offline = (error as NSError).domain == NSURLErrorDomain
                note(offline ? "电脑端暂时连不上,等网络恢复再点主动终止"
                             : "主动终止失败:\(error.localizedDescription)")
            }
        }
    }

    /// 取麦克风授权。带号恢复被电脑端明确拒绝(旧会已封场、或号已不存在)时,
    /// 丢掉那条待确认申请,再以不带号重发一次。
    /// 为什么必须清 pending:同一个通道会复用原请求号与原请求体(MeetingClient.pendingStart),
    /// 不清就会把同一个带号请求原样重放,永远拿不到新会。
    private func requestMicToken(config: LiveKitConfig, operation: SessionOperation, recoveryMeetingID: String?) async throws -> MeetingGrant {
        do {
            return try await config.requestToken(identity: config.identity,
                                              channel: SessionControlContract.mic,
                                              meetingID: recoveryMeetingID)
        } catch {
            guard operation.isCurrent(generation: transport.generation, config: cfg) else { throw CancellationError() }
            guard recoveryMeetingID != nil,
                  MeetingClient.isClosedMeetingRefusal(error) else { throw error }
            try MeetingClient.discardPendingStart(channel: SessionControlContract.mic,
                                              deviceID: config.device)
            note("原会议已结束,改为新开一场")
            return try await config.requestToken(identity: config.identity,
                                              channel: SessionControlContract.mic,
                                              meetingID: nil)
        }
    }

    /// 会中提要档位:自动 5 分钟 / 手动 10 分钟(手动更长 —— 在外面要等久一点才抓得到要点)。
    /// 切档 ≠ 立刻出一段:只是把下一次检查的周期换掉。
    /// 状态行不在这里写"已切到…":按钮的选中色已经表达了档位(用户 2026-10-16 指出重复),
    /// 真正的状态由家里每 60 秒推来的 sumstatus 决定。
    func setSumMode(_ m: String) {
        guard m != sumMode else { return }
        sumMode = m
        note("会中提要档位 → \(m == "auto" ? "自动" : "手动")")
        guard !sessionID.isEmpty else { return }   // 未在录音:只在本机切档,不发(契约要求 v2 带场次号)
        Task { await transport.send(summodePayload(m)) }
    }

    /// Clear device-owned, in-memory data for the current meeting while keeping
    /// saved reports and the coordinator's authoritative lifecycle projection.
    private func resetCurrentMeetingData() {
        lines = []
        partials = []
        transcriptStore = TranscriptStore()
        transcriptGapText = ""
        lastCatchUpAt = .distantPast
        recordedSeconds = 0
        serverSeconds = 0
        serverBySource = [:]
        progressSeenAt = [:]
        unknownTypes = []
        protocolIssues = [:]
        loggedUnknownFields = []
        sessionDrops = 0
        didResyncSumMode = false
        summaries = []
        sumState = "等待提要…"
        sumCode = "wait_period"
        sessionID = ""
        serverGeneration = 0
        transport.resetEndReason()
        noteSignatures = []

        let now = Date()
        meetingFacts.recorded = Status(desired: .wanted,
                                observed: MetricValue(value: 0, unit: "秒"),
                                reason: nil, lastSeen: now, generation: transport.generation)
        meetingFacts.received = Status(desired: .wanted,
                                observed: MetricValue(value: 0, unit: "秒"),
                                reason: nil, lastSeen: now, generation: transport.generation)
        meetingFacts.summary = Status(desired: .wanted,
                               observed: MetricValue(value: 0, unit: "轮"),
                               reason: nil, lastSeen: now, generation: transport.generation)
    }

    private func start() {
        guard !terminating else { return }
        let recoveryMeetingID = meetingContext.isFresh() && meetingContext.canStartNew()
            ? nil : (sessionID.isEmpty ? nil : sessionID)
        transport.invalidate()
        let generation = transport.generation
        resetCurrentMeetingData()
        capturePreparing()
        syncBoard()
        syncProtocolStatus()
        let cfg = self.cfg
        let operation = SessionOperation(generation: generation, config: cfg)
        transport.beginConnection { [self] in
            var grantedMeetingID: String?
            var grantedServerGeneration = 0
            do {
                try await MeetingClient.flushPendingMicStop()
                guard operation.isCurrent(generation: self.transport.generation, config: self.cfg) else { return }
                if recoveryMeetingID == nil, self.meetingContext.isFresh(), self.meetingContext.canStartNew(),
                   let closedID = self.meetingContext.meetingID {
                    try MeetingClient.retireClosedStart(channel: SessionControlContract.mic,
                                                        deviceID: cfg.device, meetingID: closedID)
                }
                let card = try await self.requestMicToken(config: cfg, operation: operation, recoveryMeetingID: recoveryMeetingID)
                grantedMeetingID = card.meetingID
                grantedServerGeneration = card.generation
                guard operation.isCurrent(generation: self.transport.generation, config: self.cfg) else { throw CancellationError() }
                let live = try await transport.connect(url: card.url, token: card.token, identity: cfg.identity)
                input.bind(live)
                do {
                    try await input.start(context: ExecutionContext(
                        configurationRevision: settings.snapshot.revision, operationID: UUID(),
                        meetingID: card.meetingID, channel: SessionControlContract.mic,
                        generation: card.generation, segmentID: nil))
                } catch {
                    await input.stop()
                    await transport.disconnect(live)
                    throw error
                }
                guard operation.isCurrent(generation: self.transport.generation, config: self.cfg) else {   // 这一轮已被停止/重开取代
                    await input.stop()
                    await self.transport.disconnect(live)                   // 只断自己这条,不碰新会话
                    do {
                        try MeetingClient.queueMicStop(serverURL: cfg.url,
                                                              meetingID: card.meetingID,
                                                              deviceID: cfg.device,
                                                              generation: card.generation)
                        try await MeetingClient.flushPendingMicStop()
                    } catch {
                        self.note("迟到的会议授权停止待同步: \(error.localizedDescription)")
                    }
                    return
                }
                self.sessionID = card.meetingID
                self.serverGeneration = card.generation
                self.transport.connected(live)
                do {
                    try await MeetingClient.reportObservation(
                        serverURL: cfg.url, meetingID: card.meetingID,
                        deviceID: cfg.device, channel: SessionControlContract.mic,
                        generation: card.generation, observed: "publishing", requestID: card.requestID)
                } catch {
                    self.note("手机采集状态待同步: \(error.localizedDescription)")
                }
                guard operation.isCurrent(generation: self.transport.generation, config: self.cfg) else { return }
                await transport.send(self.summodePayload(self.sumMode))   // 让家里跟上本机档位
                guard operation.isCurrent(generation: self.transport.generation, config: self.cfg) else { return }
                self.startTimer()
                self.syncBoard()
            } catch {
                // VoiceRoom.connect 失败时已自行断开这条连接,这里只回写 UI
                if let grantedMeetingID {
                    do {
                        try MeetingClient.queueMicStop(serverURL: cfg.url,
                                                              meetingID: grantedMeetingID,
                                                              deviceID: cfg.device,
                                                              generation: grantedServerGeneration)
                        try await MeetingClient.flushPendingMicStop()
                    } catch {
                        self.note("连接失败后的会议停止待同步: \(error.localizedDescription)")
                    }
                }
                guard operation.isCurrent(generation: self.transport.generation, config: self.cfg) else { return }
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
                try MeetingClient.queueMicStop(serverURL: stopConfig.url,
                                                      meetingID: stoppedMeetingID,
                                                      deviceID: stopConfig.device,
                                                      generation: stoppedGeneration)
            } catch {
                note("停止意图保存失败: \(error.localizedDescription)")
            }
        }
        transport.invalidate()     // 在飞的连接尝试作废,不许它稍后回写状态
        stopTimer()
        captureStopped()             // 只有用户按停止才清期望
        sessionID = ""                  // 契约:停止即换场,下一场重新生成
        serverGeneration = 0
        partials = []                 // 在飞的部分字幕属于上一场,停止后不该再挂在屏幕上
        syncBoard()
        note("用户停止:推流 \(Int(recordedSeconds))s / 家里识别 \(Int(serverSeconds))s")
        // 只断开"我这一代"的那条连接:旧任务迟到时不会再拿新会话开刀
        transport.enqueueDisconnect(beforeDisconnect: { [input] in await input.stop() }) { [weak self] in
            // 先结束媒体传输，再让电脑端封住该通道；否则 stop 请求可能先到，截掉尾部音频。
            if !stoppedMeetingID.isEmpty {
                do {
                    try await MeetingClient.flushPendingMicStop()
                    // 契约里 phone_observed 有 stopped:只发 publishing 的话总管永远等不到
                    // "这台手机说它不采了",只能靠停止请求猜。这里补上,失败只记一行。
                    try await MeetingClient.reportObservation(
                        serverURL: stopConfig.url, meetingID: stoppedMeetingID,
                        deviceID: stopConfig.device, channel: SessionControlContract.mic,
                        generation: stoppedGeneration, observed: "stopped")
                } catch {
                    self?.note("电脑端会议停止状态同步失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 补取本场已确认、但没收到(或断线期间漏掉)的定稿。
    /// 实时和补取共用连续游标与去重入口。
    func catchUpNow() async {
        guard !sessionID.isEmpty, !catchUpRunning else { return }
        catchUpRunning = true
        defer { catchUpRunning = false }
        let meeting = sessionID
        let cursor = transcriptStore.cursor
        let requestedEpoch = transcriptStore.epoch
        let generation = transport.generation
        do {
            let page = try await MeetingClient.fetchTranscript(
                serverURL: cfg.url, meetingID: meeting, deviceID: cfg.device,
                after: cursor, epoch: requestedEpoch)
            guard meeting == sessionID, generation == transport.generation else { return }
            // Realtime may establish a newer epoch while the HTTP page is in flight.
            guard transcriptStore.epoch == requestedEpoch || page.epoch == transcriptStore.epoch else { return }
            transcriptStore.merge(page.items.map {
                .init(seq: $0.seq, who: $0.who, source: $0.source, text: $0.text, gap: $0.gapS, ts: $0.ts)
            }, epoch: page.epoch, oldest: page.oldest, truncated: page.truncated == true)
            syncTranscript()
            lastCatchUpAt = Date()
        } catch {
            // 断线、家里重启失败都是常态:一行记录即可,不刷屏、不影响推流
            lastCatchUpAt = Date()
            note("补取失败:\(error.localizedDescription)")
        }
    }

    private func syncTranscript() {
        lines = transcriptStore.entries.filter { !$0.text.isEmpty }.map {
            TranscriptLine(id: $0.id, who: $0.who, source: $0.source, text: $0.text, gap: $0.gap, ts: $0.ts)
        }
        if transcriptGapText != transcriptStore.gapMessage {
            transcriptGapText = transcriptStore.gapMessage
            if !transcriptGapText.isEmpty { note(transcriptGapText) }
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
                self.meetingFacts.recorded = Status(desired: LinkDesired.wanted,
                                             observed: MetricValue(value: self.recordedSeconds, unit: "秒"),
                                             reason: nil, lastSeen: Date(),
                                             generation: self.transport.generation)
                self.conditionNote("Metric.Recorded", .ok, detail: "录=\(Int(self.recordedSeconds))秒(墙钟)")
                self.conditionNote("Metric.Progress",
                                   self.board.receivedCondition(currentGeneration: self.transport.generation),
                                   detail: "收=\(Int(self.serverSeconds))秒")
                // 每 10 秒补一次:实时消息漏掉的那些(断线、切后台、家里推送失败)在这里补齐。
                if Date().timeIntervalSince(self.lastCatchUpAt) >= 10 {
                    Task { await self.catchUpNow() }
                }
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
    func syncBoard() { objectWillChange.send() }

    func refreshNet() async { await transport.preflightControl() }

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
        meetingFacts.protocolLag = Status(desired: LinkDesired.wanted,
                                   observed: lag ? CapObserved.no : CapObserved.yes,
                                   reason: lag ? CapReason.protocolLag : nil,
                                   lastSeen: Date(), generation: transport.generation)
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
        Self.linkWord(board.livekitCondition(currentGeneration: transport.generation),
                      observed: board.livekit.observed, desired: board.livekit.desired)
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
        meetingFacts.received = Status(desired: LinkDesired.wanted,
                                observed: MetricValue(value: serverSeconds, unit: "秒"),
                                reason: nil, lastSeen: now, generation: transport.generation)
        conditionNote("Metric.Progress", board.receivedCondition(currentGeneration: transport.generation),
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
