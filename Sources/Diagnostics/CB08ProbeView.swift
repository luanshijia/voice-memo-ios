#if CB08_PROBE
import SwiftUI

struct CB08ProbeView: View {
    @StateObject private var probe = CB08Probe()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("CB08 设备探测") {
                Text(probe.device.status)
                HStack {
                    Button("扫描") { probe.device.scan() }
                    Button("停止扫描") { probe.device.stopScan() }
                    Button("刷新状态") { probe.device.refreshStatus() }
                }
                ForEach(probe.device.devices) { device in
                    Button("连接 \(device.name) · \(device.productType)") {
                        probe.device.connect(device)
                    }
                    .disabled(probe.device.connected)
                }
                if probe.device.connected {
                    HStack {
                        Button("开始") { probe.device.startRecording() }
                        Button("暂停") { probe.device.pauseRecording() }
                        Button("继续") { probe.device.resumeRecording() }
                        Button("停止") { probe.device.stopRecording() }
                    }
                    Button("断开") { probe.device.disconnect() }
                }
                Text(probe.device.eventSummary).font(.caption.monospaced())
                LabeledContent("实体键事件", value: probe.device.hardwareButtonEvents
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }.joined(separator: ", "))
            }
            Section("Opus 回调指标") {
                LabeledContent("回调数", value: "\(probe.device.packetCount)")
                LabeledContent("总字节", value: "\(probe.device.packetBytes)")
                LabeledContent("包长分布", value: probe.device.packetSizes
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }.joined(separator: ", "))
                Button("探测系统 Opus 解码器") { probe.probeDecoder() }
                Text(probe.decoderStatus).font(.caption)
                LabeledContent("解码成功 / 失败", value: "\(probe.decodeSuccess) / \(probe.decodeFailure)")
                LabeledContent("PCM 样本", value: "\(probe.decodedSamples)")
            }
            Section {
                Text("本页是诊断探针，不创建会议、不连接 LiveKit、不写录音文件。包长仅统计，不按固定长度切包。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("CB08 探测")
        .onAppear { if scenePhase == .active { probe.device.appDidEnterForeground() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { probe.device.appDidEnterForeground() }
            else { probe.device.appDidEnterBackground() }
        }
    }
}
#endif
