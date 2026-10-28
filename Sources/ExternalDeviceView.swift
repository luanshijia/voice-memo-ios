import SwiftUI

@MainActor
struct ExternalDeviceView: View {
    @ObservedObject var assistant: MeetingAssistant
    @ObservedObject var device: CB08SDKBridge
    @ObservedObject var provider: CB08InputProvider
    private var controlsLocked: Bool { assistant.deviceConnectionLocked }
    @ObservedObject private var deviceTelemetry: DeviceTelemetry
    @ObservedObject private var audioTelemetry: DeviceTelemetry
    init(assistant: MeetingAssistant) {
        self.assistant = assistant
        let device = assistant.input.device
        let provider = assistant.input.external
        self.device = device; self.provider = provider
        deviceTelemetry = device.telemetry; audioTelemetry = provider.telemetry
    }
    var body: some View {
        List {
            Section("CB08连接") {
                HStack(spacing: 12) {
                    Button(device.isScanning ? "停止扫描" : "扫描") {
                        if device.isScanning { device.stopScan() } else { device.scan() }
                    }
                    .buttonStyle(WorkspaceActionButtonStyle(tint: device.isScanning ? .red : .blue))
                    .disabled(controlsLocked || device.connected || device.connectionPhase == .connecting || device.connectionPhase == .disconnecting)
                    Button(connectionButtonTitle) {
                        if device.connectionPhase == .connected || device.connectionPhase == .unknown {
                            device.disconnect()
                        } else if let selected = device.selectedDevice { device.connect(selected) }
                    }
                    .buttonStyle(WorkspaceActionButtonStyle(tint: device.connected || device.connectionPhase == .unknown ? .red : .blue))
                    .disabled(controlsLocked || device.connectionPhase == .connecting || device.connectionPhase == .disconnecting ||
                              (device.connectionPhase == .disconnected && device.selectedDevice == nil))
                }
                LabeledContent(device.selectedDevice?.name ?? "", value: device.connectionPhase.rawValue)
                if device.devices.count > 1 {
                    Picker("选择设备", selection: $device.selectedDeviceID) {
                        ForEach(Array(device.devices.enumerated()), id: \.element.id) { index, item in
                            Text("\(item.name) · \(index + 1)").tag(Optional(item.id))
                        }
                    }
                    .disabled(device.connected || controlsLocked || device.connectionPhase == .connecting)
                }
                if device.devices.isEmpty && !device.connected {
                    Text(device.isScanning ? "正在查找CB08" : "尚未发现CB08").foregroundStyle(.secondary)
                }
                if controlsLocked { Text("会议或设备动作进行中，连接操作已锁定").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("录音控制") {
                HStack(spacing: 8) {
                    Button(assistant.deviceStartTitle) { assistant.startFromDeviceConsole() }
                        .buttonStyle(WorkspaceActionButtonStyle())
                        .disabled(!assistant.deviceCanStart)
                    Button("暂停") { assistant.accept(.pause) }
                        .buttonStyle(WorkspaceActionButtonStyle())
                        .disabled(!assistant.deviceCanPause)
                    Button("停止并保存") { assistant.requestDeviceStop() }
                        .buttonStyle(WorkspaceActionButtonStyle(tint: .red))
                        .disabled(!assistant.deviceCanStop)
                }
                Text(assistant.deviceControlStatus)
                    .font(.callout)
                    .foregroundStyle(assistant.deviceIndependentWarning ? Color.red : Color.primary)
                    .accessibilityLabel("设备状态：\(assistant.deviceControlStatus)")
                if assistant.input.binding.kind != .external {
                    Text("开始会议采集前，请在输入页选择CB08。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("卡片录音状态", value: device.connected ? recordWord : "未知")
                if provider.flowing {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        LabeledContent("音频接收", value: provider.audioStatus(at: timeline.date))
                    }
                } else {
                    LabeledContent("音频接收", value: provider.stage)
                }
                LabeledContent("电量", value: device.battery.map { $0 == 110 ? "充电中" : "\($0)%" } ?? "未知")
                LabeledContent("剩余/总容量", value: device.capacity)
                LabeledContent("卡片返回录音时长", value: device.deviceRecordingSeconds.map { "\($0)秒" } ?? "未知")
            } header: {
                HStack {
                    Text("设备状态")
                    Spacer()
                    Button("刷新") { device.refreshStatus() }.disabled(!device.connected || assistant.deviceConnectionLocked)
                }
            }
            Section("设备参数") {
                LabeledContent("增益", value: gainWord)
                LabeledContent("低功耗录音", value: device.lowPowerRecording.map { $0 ? "开启" : "关闭" } ?? "未知")
            }
            Section("设备详情") {
                LabeledContent("固件", value: device.firmware)
                LabeledContent("当前文件", value: device.currentFile)
            }
            Section("音频诊断") {
                LabeledContent("SDK累计回调", value: "\(device.packetCount)")
                LabeledContent("SDK累计字节", value: "\(device.packetBytes)")
                LabeledContent("队列丢包", value: "\(device.droppedPackets)")
                LabeledContent("解码成功/失败", value: "\(provider.decodedPackets) / \(provider.decodeFailures)")
                LabeledContent("解码帧数", value: "\(provider.decodedFrames)")
                LabeledContent("帧对应音频", value: String(format: "%.2f 秒", Double(provider.expectedSamples) / 16_000))
                LabeledContent("已提交音频", value: String(format: "%.2f 秒", Double(provider.submittedSamples) / 16_000))
                LabeledContent("提交PCM样本", value: "\(provider.submittedSamples)")
                if let failure = provider.failure { Text(failure).foregroundStyle(.orange) }
                DisclosureGroup("诊断详情") {
                    Text(device.status)
                    LabeledContent("连接回调", value: device.connectionSummary)
                    LabeledContent("录音状态查询", value: device.querySummary)
                    LabeledContent("录音动作回执", value: device.actionSummary)
                    LabeledContent("实体键请求", value: device.hardwareSummary)
                    Text(device.diagnostics.joined(separator: "\n"))
                        .font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
        }
        .font(.body)
        .onAppear { device.activate() }
        .onDisappear { device.stopScan() }
        .navigationTitle("外设控制台")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var recordWord: String {
        device.recordState?.rawValue ?? "未知"
    }
    private var gainWord: String {
        switch device.gain { case 1: return "低"; case 2: return "中"; case 3: return "高"; default: return "未知" }
    }
    private var connectionButtonTitle: String {
        switch device.connectionPhase {
        case .connected, .unknown: return "断开连接"
        case .connecting: return "连接中…"
        case .disconnecting: return "断开中…"
        case .disconnected: return "连接设备"
        }
    }
}
