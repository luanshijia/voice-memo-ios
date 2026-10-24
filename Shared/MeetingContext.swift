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
    let pendingReports: Int
    let revision: Int

    static let empty = MeetingContext(meetingID: nil, meeting: nil, mic: nil,
                                      micGeneration: nil, systemAudio: nil,
                                      systemAudioGeneration: nil,
                                      pendingReports: 0, revision: 0)

    private init(meetingID: String?, meeting: AppSharedContract.MeetingState?,
                 mic: AppSharedContract.ChannelState?, micGeneration: Int?,
                 systemAudio: AppSharedContract.ChannelState?,
                 systemAudioGeneration: Int?, pendingReports: Int, revision: Int) {
        self.meetingID = meetingID
        self.meeting = meeting
        self.mic = mic
        self.micGeneration = micGeneration
        self.systemAudio = systemAudio
        self.systemAudioGeneration = systemAudioGeneration
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

    // MARK: - 对账:还有没有会、哪一路没关

    /// 总管眼里这场会还没结束(没封场、也没取消)。
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
}
