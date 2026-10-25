import SwiftUI

struct ConnectionView: View {
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        NavigationStack {
            List {
                Section("当前来源：手机") {
                    LabeledContent("输入", value: "iPhone 麦克风")
                    LabeledContent("手机 → 电脑入口", value: word(assistant.connection.network))
                    LabeledContent("电脑会议管家", value: assistant.connection.controlIsFresh ? "最近查询成功" : "无新鲜鉴权证据")
                    LabeledContent("媒体连接", value: word(assistant.connection.media))
                    LabeledContent("电脑实际收音", value: assistant.connection.desktopAudioEvidence)
                    LabeledContent("已识别音频", value: "\(Int(assistant.connection.recognitionSeconds)) 秒")
                }
                Section {
                    Button("检查网络入口") { Task { await assistant.checkConnection() } }
                        .buttonStyle(.borderless)
                    Text("入口可达只证明 TCP 可达。会议管家、媒体连接和实际收音分别依据各自证据。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("恢复本会议") { assistant.accept(.recover) }
                        .buttonStyle(.borderless)
                        .disabled(!assistant.meeting.projection.canReconnect(
                            wantsToContinue: assistant.meeting.wantsCapture,
                            recording: assistant.meeting.isRecording,
                            networkOK: assistant.connection.network == .connected))
                }
                Section {
                    Button("前往设置") { assistant.page = .settings }.buttonStyle(.borderless)
                    Button("前往输入") { assistant.page = .input }.buttonStyle(.borderless)
                }
            }
            .navigationTitle("连接")
        }
    }
    private func word(_ value: LinkObserved) -> String {
        switch value {
        case .notStarted: return "未开始"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reconnecting: return "恢复中"
        case .disconnected: return "已断开"
        case .unknown: return "未知"
        }
    }
}
