import SwiftUI

struct ConnectionView: View {
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("当前输入", value: assistant.input.displayName)
                    if assistant.input.binding.kind == .external {
                        LabeledContent("CB08 → 手机", value: assistant.input.device.connected ? "蓝牙已连接" : "蓝牙未连接")
                        LabeledContent("提交PCM样本", value: "\(assistant.input.external.submittedSamples)")
                    }
                    LabeledContent("手机 → 电脑入口", value: word(assistant.connection.network))
                    LabeledContent("电脑会议管家", value: assistant.connection.controlIsFresh ? "最近查询成功" : "无新鲜鉴权证据")
                    LabeledContent("媒体连接", value: word(assistant.connection.media))
                    LabeledContent("电脑实际收音", value: assistant.connection.desktopAudioEvidence)
                    LabeledContent("已识别音频", value: "\(Int(assistant.connection.recognitionSeconds)) 秒")
                }
            }
            .font(.body)
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
