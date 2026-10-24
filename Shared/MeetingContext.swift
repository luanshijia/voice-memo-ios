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

    /// 「另开」只能在旧会议封场后进行;总管会把新申请并回仍开放的会议。
    func canStartNew(recording: Bool) -> Bool {
        !recording && !hasOpenMeeting
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
        return "这场会议尚未封场,请等电脑端完成收尾"
    }
}
