import SwiftUI
import AVFoundation

struct InputView: View {
    @ObservedObject var assistant: MeetingAssistant
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var shortcutOpenFailed = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { openXEdge() } label: {
                            Text("xEdge")
                                .font(.body.weight(.medium))
                                .frame(width: 88)
                                .frame(minHeight: 52)
                                .foregroundStyle(.primary)
                                .background(Color(uiColor: .tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开 xEdge")
                        Spacer()
                        HStack(spacing: 20) {
                            Text("tailscale网络")
                            Image(systemName: assistant.connection.serverReady ? "checkmark" : "xmark")
                        }
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                        .foregroundStyle(assistant.connection.serverReady ? Color.white : Color.secondary)
                        .background(assistant.connection.serverReady ? Color.blue : Color(uiColor: .tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(assistant.connection.serverReady ? "tailscale网络已就绪" : "tailscale网络未就绪")
                    }
                }
                Section("手机") {
                    inputButton("iPhone 麦克风", icon: "iphone", kind: .phone) {
                        assistant.selectInput(.phone)
                    }
                    LabeledContent("麦克风权限", value: microphonePermission)
                    LabeledContent("麦克风模式", value: assistant.input.micModeText)
                }
                Section("外置设备") {
                    inputButton("CB08", icon: "waveform", kind: .external) {
                        let tag = assistant.input.binding.kind == .external ? assistant.input.binding.sourceTag : .face2face
                        assistant.selectInput(.external, tag: tag)
                    }
                    NavigationLink("外设控制台") {
                        ExternalDeviceView(assistant: assistant)
                    }
                    LabeledContent("蓝牙连接", value: assistant.input.device.connectionPhase.rawValue)
                    LabeledContent("卡片录音", value: cardRecordState)
                    if assistant.input.external.flowing {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            LabeledContent("音频接收", value: assistant.input.external.audioStatus(at: timeline.date))
                        }
                    } else {
                        LabeledContent("音频接收", value: assistant.input.external.stage)
                    }
                }
            }.font(.body)
        }
        .onAppear { refreshMicrophoneMode() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshMicrophoneMode() }
        }
        .alert("无法打开快捷指令", isPresented: $shortcutOpenFailed) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("请确认手机已安装“快捷指令”，并保留名称为“打开XEdge”的快捷指令。")
        }
    }
    private func openXEdge() {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: "打开XEdge")]
        guard let url = components.url else { return }
        openURL(url) { accepted in
            shortcutOpenFailed = !accepted
        }
    }

    private func refreshMicrophoneMode() {
        assistant.input.refreshMicMode(generation: assistant.connection.generation)
    }

    private func inputButton(_ title: String, icon: String, kind: InputKind,
                             action: @escaping () -> Void) -> some View {
        let selected = assistant.input.binding.kind == kind
        return Button(action: action) {
            HStack(spacing: 12) {
                Label(title, systemImage: icon)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(!assistant.canSelectInput ? Color.secondary : selected ? Color.white : Color.primary)
            .background(selected && assistant.canSelectInput ? Color.blue : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!assistant.canSelectInput)
        .accessibilityValue(selected ? "已选中" : "未选中")
    }

    private var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已允许"
        case .denied, .restricted: return "未授权"
        case .notDetermined: return "尚未询问"
        @unknown default: return "未知"
        }
    }

    private var cardRecordState: String {
        guard assistant.input.device.connected else { return "未知" }
        return assistant.input.device.recordState?.rawValue ?? "未知"
    }
}
