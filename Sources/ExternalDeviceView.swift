import SwiftUI

struct ExternalDeviceView: View {
    @ObservedObject var device: CB08SDKBridge
    @ObservedObject var provider: CB08InputProvider
    let controlsLocked: Bool
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
                Text("连接和选择输入均不会开始录音。请在会议页开始、暂停、继续或结束。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("设备返回的事实") {
                LabeledContent("录音状态", value: recordWord)
                LabeledContent("电量", value: device.battery.map { $0 == 110 ? "充电中" : "\($0)%" } ?? "未知")
                LabeledContent("固件", value: device.firmware)
                LabeledContent("剩余/总容量", value: device.capacity)
                LabeledContent("当前文件", value: device.currentFile)
                Text(device.eventSummary).font(.caption.monospaced())
            }
            Section("本段音频提交") {
                LabeledContent("SDK累计回调", value: "\(device.packetCount)")
                LabeledContent("SDK累计字节", value: "\(device.packetBytes)")
                LabeledContent("队列丢包", value: "\(device.droppedPackets)")
                LabeledContent("解码成功/失败", value: "\(provider.decodedPackets) / \(provider.decodeFailures)")
                LabeledContent("提交PCM样本", value: "\(provider.submittedSamples)")
                if let failure = provider.failure { Text(failure).foregroundStyle(.orange) }
                Text("提交数仅表示交给LiveKit，不代表电脑已收到。帧边界与真实时长仍需真机核验。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("外设控制台")
    }
    private var recordWord: String {
        switch device.recordState { case 0: return "停止"; case 1: return "录音中"; case 2: return "暂停"; default: return "未知" }
    }
}
