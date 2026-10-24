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
    let pendingReports: Int
    let revision: Int

    static let empty = MeetingContext(meetingID: nil, meeting: nil, mic: nil,
                                      micGeneration: nil, systemAudio: nil,
                                      systemAudioGeneration: nil, recoveryDeadline: nil,
                                      pendingReports: 0, revision: 0)

    private init(meetingID: String?, meeting: AppSharedContract.MeetingState?,
                 mic: AppSharedContract.ChannelState?, micGeneration: Int?,
                 systemAudio: AppSharedContract.ChannelState?,
                 systemAudioGeneration: Int?, recoveryDeadline: Date?,
                 pendingReports: Int, revision: Int) {
        self.meetingID = meetingID
        self.meeting = meeting
        self.mic = mic
        self.micGeneration = micGeneration
        self.systemAudio = systemAudio
        self.systemAudioGeneration = systemAudioGeneration
        self.recoveryDeadline = recoveryDeadline
        self.pendingReports = pendingReports
        self.revision = revision
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
        self.recoveryDeadline = meeting?.recoveryDeadline
    }

    // MARK: - 底栏要显示的两个词

    var meetingAlias: String {
        guard let meeting else { return "无会议" }
        return AppSharedContract.meetingAlias(meeting.rawValue)
    }

    func channelAlias(_ channel: AppSharedContract.ChannelState?) -> String {
        guard let channel else { return "无通道" }
        return AppSharedContract.channelAlias(channel.rawValue)
    }

    // MARK: - 对账:两个按钮能不能点

    /// 总管眼里这场会还没结束(可以回去,也不该另起一场)。
    /// 注意它含 `finishing`:正在收尾的会**还在这张账上**(所以不该另起一场),
    /// 但总管已经拒绝对它带号恢复 —— 「该不该另起」和「能不能接回」是两件事,
    /// 分别看这个字段和 `meetingAcceptsRecovery`。
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

    /// 本机此刻「想继续、但没在采」= 断线/连接失败后的真实处位。
    /// 这不是总管状态:总管那边可能还记着 `active`(要等观察宽限才转待确认)。
    /// 两个来源分列,差集本身就是要显示的信号 —— 合并成一个值就永远判不出来。
    static func isDetached(wantsToContinue: Bool, recording: Bool) -> Bool {
        wantsToContinue && !recording
    }

    /// 总管允许带号恢复的三格。`finishing` 不在内:总管回 `recovery_meeting_closed`。
    var meetingAcceptsRecovery: Bool {
        guard let meeting else { return false }
        return [.preparing, .active, .interruptedPending].contains(meeting)
    }

    /// 「重连」:断线后,总管那格还肯接回。
    /// 截止线取电脑端给的 `recovery_deadline`:没有截止线(还没开始计时)= 肯接回。
    func canReconnect(wantsToContinue: Bool, recording: Bool) -> Bool {
        guard Self.isDetached(wantsToContinue: wantsToContinue, recording: recording),
              meetingAcceptsRecovery else { return false }
        guard let deadline = recoveryDeadline else { return true }
        return Date() < deadline
    }

    /// 「另开」点下去,总管会新建一场**而不是**并回旧会 —— 这是投影,不是许可。
    /// 裁决规则在 `coordinator.start()`:只有 preparing/active/interrupted_pending
    /// 会被并回,其余(含 finishing)一律新建。顶部「开启」永远可点,裁决权在总管。
    func canStartNew() -> Bool {
        !meetingAcceptsRecovery
    }

    /// 「主动终止」:只在断线后成立 —— 它有明确含义(号不要了、录音与纪要照要),
    /// 不是日常结束按钮;日常结束是顶部「停止」。
    func canTerminate(wantsToContinue: Bool, recording: Bool) -> Bool {
        hasOpenMeeting && Self.isDetached(wantsToContinue: wantsToContinue, recording: recording)
    }

    /// 点了不能点的按钮时,给一句人话说明为什么。
    /// 电脑端只做事后拒绝(409 + 错误码),没有事前原因;这里只把
    /// 「本机事实 + 总管状态」翻成人话,不发明新结论。
    func blockReason(wantsToContinue: Bool, recording: Bool) -> String? {
        guard hasOpenMeeting else { return nil }
        if let deadline = recoveryDeadline, Date() >= deadline, meetingAcceptsRecovery {
            return "断线太久,这场已在收尾,再点开启就是新会"
        }
        if systemAudio == .active { return "系统声音直播还在,先在控制中心停止录屏" }
        if recording { return "正在录音,先停止再另开" }
        return "这场会议尚未封场,请等电脑端完成收尾"
    }
}
