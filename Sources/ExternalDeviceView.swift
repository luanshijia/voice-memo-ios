import SwiftUI

struct ExternalDeviceView: View {
    @ObservedObject var device: CB08SDKBridge
    @ObservedObject var provider: CB08InputProvider
    let controlsLocked: Bool
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        List {
            Section("CB08连接") {
                Text(device.status)
                Button("扫描") { device.scan() }.buttonStyle(.borderedProminent).disabled(device.connected || controlsLocked)
                Button("停止扫描") { device.stopScan() }.buttonStyle(.borderless)
                ForEach(device.devices) { item in
                    Button("连接 \(item.name)") { device.connect(item) }
                        .buttonStyle(.borderless).disabled(device.connected || controlsLocked)
                }
                Button("刷新设备状态") { device.refreshStatus() }.buttonStyle(.borderless).disabled(!device.connected)
                Button("断开设备") { device.disconnect() }.buttonStyle(.borderless)
            }
            if assistant.input.binding.kind == .external {
                Section("用途标记（手动）") {
                    Picker("用途标记", selection: Binding(
                        get: { assistant.input.binding.sourceTag },
                        set: { assistant.selectInput(.external, tag: $0) })) {
                        Text("面对面").tag(SourceTag.face2face)
                        Text("通话").tag(SourceTag.call)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!assistant.canSelectInput)
                }
            }
            Section("设备信息") {
                LabeledContent("卡片录音状态", value: device.connected ? recordWord : "未知")
                LabeledContent("电量", value: device.battery.map { $0 == 110 ? "充电中" : "\($0)%" } ?? "未知")
                LabeledContent("固件", value: device.firmware)
                LabeledContent("剩余/总容量", value: device.capacity)
                LabeledContent("当前文件", value: device.currentFile)
            }
            Section("音频诊断") {
                if !device.eventSummary.isEmpty {
                    Text(device.eventSummary).font(.footnote.monospaced()).textSelection(.enabled)
                }
                LabeledContent("SDK累计回调", value: "\(device.packetCount)")
                LabeledContent("SDK累计字节", value: "\(device.packetBytes)")
                LabeledContent("队列丢包", value: "\(device.droppedPackets)")
                LabeledContent("解码成功/失败", value: "\(provider.decodedPackets) / \(provider.decodeFailures)")
                LabeledContent("提交PCM样本", value: "\(provider.submittedSamples)")
                if let failure = provider.failure { Text(failure).foregroundStyle(.orange) }
            }
        }
        .font(.body)
        .navigationTitle("外设控制台")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var recordWord: String {
        switch device.recordState { case 0: return "停止"; case 1: return "录音中"; case 2: return "暂停"; default: return "未知" }
    }
}
