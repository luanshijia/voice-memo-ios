import SwiftUI

struct InputView: View {
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        NavigationStack {
            List {
                Section("手机") {
                    Label("iPhone 麦克风", systemImage: "iphone")
                    LabeledContent("权限", value: permissionText)
                    LabeledContent("场景", value: "面对面")
                    LabeledContent("实际路由", value: "由系统当前音频路由决定")
                    Button("已选择为输入") { assistant.selectInput(.phone) }
                        .disabled(assistant.settings.isLocked)
                }
                Section("外置设备") {
                    Label("CB08", systemImage: "waveform")
                    Text("正式外设通路待接入；选择、蓝牙连接与开始录音分别处理。")
                        .foregroundStyle(.secondary)
                    Text("面对面：下推；通话：上推、贴附手机并使用听筒。场景标签不改变物理拨杆。")
                        .font(.footnote)
#if CB08_PROBE
                    NavigationLink("CB08 技术诊断（S1）") { CB08ProbeView() }
#endif
                }
            }
            .navigationTitle("输入")
        }
    }
    private var permissionText: String {
        switch assistant.input.permission {
        case .yes: return "已允许"
        case .no: return "未允许；开始时申请系统权限"
        case .unknownState: return "未知"
        }
    }
}
