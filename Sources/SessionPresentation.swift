import SwiftUI

/// Pure presentation projection for session actions. It combines local facts with
/// the computer-owned meeting projection; views only render the resulting state.
struct SessionPresentation {
    enum Tone: Equatable {
        case accent
        case stop
        case muted
    }

    struct PrimaryAction {
        let title: String
        let icon: String
        let tone: Tone
        let enabled: Bool
        let hint: String
    }

    struct TerminateAction {
        let enabled: Bool
        let pending: Bool
        let hint: String?
    }

    let primaryAction: PrimaryAction
    let terminateAction: TerminateAction

    init(isRecording: Bool, wantsToContinue: Bool, networkOK: Bool?,
         terminating: Bool, meeting: MeetingContext) {
        let detached = meeting.meetingAcceptsRecovery && meeting.isDetachedBranch(
            wantsToContinue: wantsToContinue,
            recording: isRecording,
            networkOK: networkOK)
        // A failed XEdge probe may reveal the detached path before the LiveKit
        // SDK gives up reconnecting. When the path returns, the SDK's recording
        // state decides whether it is still retrying or the App must reconnect.
        let reconnecting = meeting.canReconnect(
            wantsToContinue: wantsToContinue,
            recording: isRecording,
            networkOK: networkOK)
        let title = detached ? "重连" : (isRecording ? "停止" : "开启")
        let tone: Tone = detached
            ? (reconnecting ? .accent : .muted)
            : (isRecording ? .stop : .accent)
        let hint = reconnecting
            ? "带原会议号接回原房间"
            : (meeting.canStartNew() ? "会新开一场,不接回原会" : "会接回原会,不新开")

        primaryAction = PrimaryAction(
            title: title,
            icon: (detached || !isRecording) ? "record.circle" : "stop.circle.fill",
            tone: tone,
            enabled: !terminating && (!detached || reconnecting),
            hint: hint)

        terminateAction = TerminateAction(
            enabled: meeting.canTerminate(
                wantsToContinue: wantsToContinue,
                recording: isRecording,
                networkOK: networkOK) && !terminating,
            pending: detached,
            hint: meeting.blockReason(
                wantsToContinue: wantsToContinue,
                recording: isRecording,
                networkOK: networkOK))
    }
}
