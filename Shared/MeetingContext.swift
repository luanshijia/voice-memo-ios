import Foundation

/// 管家助手:电脑端总管状态在本机的只读镜像。
///
/// 它只做两件事 —— 把总管回的枚举翻成本机可读的词,和对一次账(会议还在不在、
/// 哪一路还活着)。它**不发明状态、不下命令**:按钮能不能点由这里的结论决定,
/// 但动作仍由用户发起。词表与总管同名,来自 `AppSharedContract`,不另写一份。
struct MeetingContext: Equatable {
    let meetingID: String?
    let meeting: AppSharedContract.MeetingState?
    let mic: AppSharedContract.ChannelState?
    let micGeneration: Int?
    let systemAudio: AppSharedContract.ChannelState?
    let systemAudioGeneration: Int?
    /// 电脑端给的接回截止时刻；nil = 还没开始计时（或旧版电脑端不发这个字段）。
    let recoveryDeadline: Date?
    /// 这份投影是什么时候从电脑端拿到的（`device_view` 成功那一刻）。
    /// 断网后没人再更新它 —— 底栏要据此判「我把不知道当成了知道」。
    let lastSeen: Date
    let pendingReports: Int
    let revision: Int
    let freshFor: TimeInterval

    /// 投影多久算过期。`observeDesktop` 每 5 秒探一轮，12 秒 = 容两轮抖动
    /// （断网后最迟 12 秒底栏就该说「未知」、按钮就该不可点）。
    static let staleAfter: TimeInterval = 12

    static let empty = MeetingContext(meetingID: nil, meeting: nil, mic: nil,
                                      micGeneration: nil, systemAudio: nil,
                                      systemAudioGeneration: nil, recoveryDeadline: nil,
                                      lastSeen: .distantPast,
                                      pendingReports: 0, revision: 0)

    private init(meetingID: String?, meeting: AppSharedContract.MeetingState?,
                 mic: AppSharedContract.ChannelState?, micGeneration: Int?,
                 systemAudio: AppSharedContract.ChannelState?,
                 systemAudioGeneration: Int?, recoveryDeadline: Date?, lastSeen: Date,
                 pendingReports: Int, revision: Int, freshFor: TimeInterval = MeetingContext.staleAfter) {
        self.meetingID = meetingID
        self.meeting = meeting
        self.mic = mic
        self.micGeneration = micGeneration
        self.systemAudio = systemAudio
        self.systemAudioGeneration = systemAudioGeneration
        self.recoveryDeadline = recoveryDeadline
        self.lastSeen = lastSeen
        self.pendingReports = pendingReports
        self.revision = revision
        self.freshFor = freshFor
    }

    init(view: DeviceMeetingView) {
        let meeting = view.meeting
        self.meetingID = meeting?.meetingID
        self.meeting = meeting.flatMap { AppSharedContract.meetingState($0.status) }
        self.mic = (meeting?.channels["mic"]?.status).flatMap { AppSharedContract.channelState($0) }
        self.micGeneration = meeting?.channels["mic"].map { $0.generation ?? 0 }
        self.systemAudio = (meeting?.channels["system_audio"]?.status)
            .flatMap { AppSharedContract.channelState($0) }
        // A channel without a generation is malformed V2 evidence: 0 forces
        // the probe comparison to stay unknown instead of trusting an old line.
        self.systemAudioGeneration = meeting?.channels["system_audio"].map { $0.generation ?? 0 }
        self.pendingReports = view.pendingReports.count
        self.revision = view.stateRevision
        self.freshFor = Self.staleAfter
        self.recoveryDeadline = meeting?.recoveryDeadline
        self.lastSeen = Date()
    }

    init(capture: CaptureView, pendingReports: Int = 0, observedAt: Date = Date(), freshFor: TimeInterval = MeetingContext.staleAfter) {
        self.init(meetingID: capture.meetingID,
                  meeting: AppSharedContract.meetingState(capture.status),
                  mic: capture.channel == "mic" && capture.desiredState == "active" ? .active : nil,
                  micGeneration: capture.channel == "mic" ? capture.generation : nil,
                  systemAudio: nil, systemAudioGeneration: nil, recoveryDeadline: nil,
                  lastSeen: observedAt, pendingReports: pendingReports, revision: capture.stateRevision, freshFor: freshFor)
    }

    func hasSameProjection(as other: MeetingContext) -> Bool {
        meetingID == other.meetingID && meeting == other.meeting && mic == other.mic &&
        micGeneration == other.micGeneration && systemAudio == other.systemAudio &&
        systemAudioGeneration == other.systemAudioGeneration && recoveryDeadline == other.recoveryDeadline &&
        pendingReports == other.pendingReports && revision == other.revision && freshFor == other.freshFor
    }

    // MARK: - 底栏要显示的两个词

    /// 这份投影还新不新。不动它就会把断网前的「已激活」一直挂在底栏上。
    func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) < freshFor
    }

    var meetingAlias: String {
        guard let meeting else { return "无会议" }
        // 拿不到新投影 = 不知道电脑端现在怎么看，不许沿用旧词。
        guard isFresh() else { return "未知" }
        return AppSharedContract.meetingAlias(meeting.rawValue)
    }

    func channelAlias(_ channel: AppSharedContract.ChannelState?) -> String {
        guard let channel else { return "无通道" }
        guard isFresh() else { return "未知" }
        return AppSharedContract.channelAlias(channel.rawValue)
    }

    // MARK: - 对账:两个按钮能不能点

    /// 总管眼里仍有未完成的工作，包含 finishing。
    /// finishing 只表示旧会正在收尾，不阻止新采集；恢复资格与新会投影
    /// 均以 meetingAcceptsRecovery 为准，不能用本字段作新会禁令。
    var hasOpenMeeting: Bool {
        guard let meeting else { return false }
        return [.preparing, .active, .interruptedPending, .finishing].contains(meeting)
    }

    /// 电脑端认为这一路还开着 —— starting / active / interrupted_pending。
    /// 用 rawValue 判断而不是枚举成员:这里只关心契约里"尚未收干净"的三个值,
    /// 词表将来增删别名不该改变这个含义。
    func isChannelOpen(_ channel: AppSharedContract.ChannelState?) -> Bool {
        guard let channel else { return false }
        return ["starting", "active", "interrupted_pending"].contains(channel.rawValue)
    }

    // MARK: - 对本机事实的账(与右列的总管状态并列,不合并)

    /// 本机此刻「想继续、但没在采或网络不通」= 断线/连接失败后的真实处位。
    /// 这不是总管状态:总管那边可能还记着 `active`(要等观察宽限才转待确认)。
    /// 两个来源分列,差集本身就是要显示的信号 —— 合并成一个值就永远判不出来。
    /// `recording` 只在 SDK 报 `.disconnected` 才翻转,而 SDK 断网后会长时间停在
    /// `.reconnecting` 重试、不判死 —— 只读它,断网几分钟按钮都进不了岔路(真机实测)。
    /// 所以直接收本机探测的 `networkOK`(每 6 秒一次):不通就是断联,不必等 SDK。
    static func isDetached(wantsToContinue: Bool, recording: Bool, networkOK: Bool?) -> Bool {
        wantsToContinue && (networkOK == false || !recording)
    }

    /// 总管允许带号恢复的三格。`finishing` 不在内:总管回 `recovery_meeting_closed`。
    var meetingAcceptsRecovery: Bool {
        guard let meeting else { return false }
        return SessionControlContract.recoveryEligibleMeetingStates.contains(meeting.rawValue)
    }

    /// 「重连」:断线后,总管那格还肯接回,**而且此刻发得出去**。
    /// 截止线取电脑端给的 `recovery_deadline`:没有截止线(还没开始计时)= 肯接回。
    /// `networkOK` 是本机事实(探测结果);nil = 没测过/不知道 —— 按「发不出去」处理,
    /// 因为可点必须等于「点下去能成」,不是「这个动作有意义」。
    func canReconnect(wantsToContinue: Bool, recording: Bool, networkOK: Bool?) -> Bool {
        guard Self.isDetached(wantsToContinue: wantsToContinue, recording: recording, networkOK: networkOK),
              meetingAcceptsRecovery, isFresh(), networkOK == true else { return false }
        guard let deadline = recoveryDeadline else { return true }
        return Date() < deadline
    }

    /// 「另开」点下去,总管会新建一场**而不是**并回旧会 —— 这是投影,不是许可。
    /// 裁决规则在 `coordinator.start()`:只有 preparing/active/interrupted_pending
    /// 会被并回,其余(含 finishing)一律新建。顶部「开启」永远可点,裁决权在总管。
    func canStartNew() -> Bool {
        !meetingAcceptsRecovery
    }

    /// 此刻是否走在「断联岔路」上(想继续、本机没在采或网络不通、总管还记着这场会)。
    /// 它只决定界面上这个动作**是否属于当前这条路**,不决定能不能点。
    func isDetachedBranch(wantsToContinue: Bool, recording: Bool, networkOK: Bool?) -> Bool {
        hasOpenMeeting && Self.isDetached(wantsToContinue: wantsToContinue, recording: recording, networkOK: networkOK)
    }

    /// 「主动终止」:只在断线岔路上成立,而且必须**发得出去**才能点。
    /// 发不出去时它仍显示(半透明蓝),因为这条路只剩它;但点不动。
    func canTerminate(wantsToContinue: Bool, recording: Bool, networkOK: Bool?) -> Bool {
        isDetachedBranch(wantsToContinue: wantsToContinue, recording: recording, networkOK: networkOK)
            && networkOK == true
    }

    /// 点了不能点的按钮时,给一句人话说明为什么。
    /// 电脑端只做事后拒绝(409 + 错误码),没有事前原因;这里只把
    /// 「本机事实 + 总管状态」翻成人话,不发明新结论。
    func blockReason(wantsToContinue: Bool, recording: Bool, networkOK: Bool?) -> String? {
        guard hasOpenMeeting else { return nil }
        if isDetachedBranch(wantsToContinue: wantsToContinue, recording: recording, networkOK: networkOK),
           networkOK != true {
            return "现在连不上电脑端,等网络恢复再点"
        }
        if let deadline = recoveryDeadline, Date() >= deadline, meetingAcceptsRecovery {
            return "断线太久,这场已在收尾,再点开启就是新会"
        }
        if systemAudio == .active { return "系统声音直播还在,先在控制中心停止录屏" }
        if recording { return "正在录音,先停止再另开" }
        return "这场会议尚未封场,请等电脑端完成收尾"
    }
}
