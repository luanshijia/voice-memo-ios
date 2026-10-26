import SwiftUI

struct InputView: View {
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        NavigationStack {
            List {
                Section("手机") {
                    Label("iPhone 麦克风 · 面对面", systemImage: "iphone")
                    Text(assistant.input.permission == .yes ? "麦克风权限已允许" : "开始时检查麦克风权限")
                        .foregroundStyle(.secondary)
                    Button(assistant.input.binding.kind == .phone ? "已选择手机" : "选择手机") { assistant.selectInput(.phone) }
                        .buttonStyle(.borderless).disabled(!assistant.canSelectInput)
                }
                Section("外置设备") {
                    Label("CB08", systemImage: "waveform")
                    Text(assistant.input.device.connected ? "蓝牙已连接" : "蓝牙未连接")
                    NavigationLink("外设控制台") {
                        ExternalDeviceView(device: assistant.input.device, provider: assistant.input.external,
                                           controlsLocked: assistant.meeting.isRecording)
                    }
                    Button("选择CB08 · 面对面") { assistant.selectInput(.external, tag: .face2face) }
                        .buttonStyle(.borderless).disabled(!assistant.canSelectInput)
                    Button("选择CB08 · 通话") { assistant.selectInput(.external, tag: .call) }
                        .buttonStyle(.borderless).disabled(!assistant.canSelectInput)
                    Text("面对面：下推；通话：上推、贴附手机并使用听筒。标签只记录场景，请手动拨动开关。AirPods通话暂不支持。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("当前输入") {
                    Text(assistant.input.displayName)
                    Text("采集中先暂停，电脑确认后可切换输入；继续沿用同一会议并开启新段。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("输入")
        }
    }
}
