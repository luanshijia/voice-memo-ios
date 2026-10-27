import SwiftUI
import AVFoundation

struct InputView: View {
    @ObservedObject var assistant: MeetingAssistant
    var body: some View {
        NavigationStack {
            List {
                Section("手机") {
                    inputButton("iPhone 麦克风", icon: "iphone", kind: .phone) {
                        assistant.selectInput(.phone)
                    }
                    LabeledContent("麦克风权限", value: microphonePermission)
                }
                Section("外置设备") {
                    inputButton("CB08", icon: "waveform", kind: .external) {
                        let tag = assistant.input.binding.kind == .external ? assistant.input.binding.sourceTag : .face2face
                        assistant.selectInput(.external, tag: tag)
                    }
                    NavigationLink("外设控制台") {
                        ExternalDeviceView(device: assistant.input.device, provider: assistant.input.external,
                                           controlsLocked: assistant.meeting.isRecording)
                    }
                    LabeledContent("蓝牙连接", value: assistant.input.device.connectionPhase.rawValue)
                    LabeledContent("卡片录音", value: cardRecordState)
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        LabeledContent("音频接收", value: assistant.input.external.audioStatus(at: timeline.date))
                    }
                }
            }.font(.body)
        }
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
