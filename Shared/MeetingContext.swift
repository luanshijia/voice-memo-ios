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
    let systemAudio: AppSharedContract.ChannelState?
    let pendingReports: Int
    let revision: Int

    static let empty = MeetingContext(meetingID: nil, meeting: nil, mic: nil,
                                      systemAudio: nil, pendingReports: 0, revision: 0)

    private init(meetingID: String?, meeting: AppSharedContract.MeetingState?,
                 mic: AppSharedContract.ChannelState?, systemAudio: AppSharedContract.ChannelState?,
                 pendingReports: Int, revision: Int) {
        self.meetingID = meetingID
        self.meeting = meeting
        self.mic = mic
        self.systemAudio = systemAudio
        self.pendingReports = pendingReports
        self.revision = revision
    }

    init(view: DeviceMeetingView) {
        let meeting = view.meeting
        self.meetingID = meeting?.meetingID
        self.meeting = meeting.flatMap { AppSharedContract.meetingState($0.status) }
        self.mic = (meeting?.channels["mic"]?.status).flatMap { AppSharedContract.channelState($0) }
        self.systemAudio = (meeting?.channels["system_audio"]?.status)
            .flatMap { AppSharedContract.channelState($0) }
        self.pendingReports = view.pendingReports.count
        self.revision = view.stateRevision
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
    var hasOpenMeeting: Bool {
        guard let meeting else { return false }
        return [.preparing, .active, .interruptedPending, .finishing].contains(meeting)
    }

    /// 「另开」:没有未封场会议时直接可用;有的话必须本机已经不在录、
    /// 且系统声那一路也已停 —— 否则新会议会被总管并回旧会议(同设备只有一场未封场)。
    func canStartNew(recording: Bool) -> Bool {
        guard hasOpenMeeting else { return true }
        return !recording && systemAudio != .active
    }

    /// 「重连」:有未结束的会议才有意义;本机正录着且这一路还在时不需要重连。
    func canReconnect(recording: Bool) -> Bool {
        guard hasOpenMeeting, meetingID != nil else { return false }
        return !(recording && mic == .active)
    }

    /// 点了不能点的按钮时,给一句人话说明为什么。
    func blockReason(recording: Bool) -> String? {
        guard hasOpenMeeting else { return nil }
        if systemAudio == .active { return "系统声音直播还在,先在控制中心停止录屏" }
        if recording { return "正在录音,先停止再另开" }
        return nil
    }
}
