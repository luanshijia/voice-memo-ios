import SwiftUI

struct MeetingView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var assistant: MeetingAssistant
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if !model.transcriptGapText.isEmpty {
                    Text(model.transcriptGapText).font(.caption).foregroundStyle(.orange)
                }
                TranscriptView(partials: model.partials, lines: model.lines,
                               localIdentity: model.identity, isRecording: model.isRecording) { _ in
                    summaryPanel
                }
            }
            .padding(.horizontal)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Button(captureButtonTitle) { assistant.accept(captureButtonAction) }
                        .buttonStyle(WorkspaceActionButtonStyle(filled: false))
                        .disabled(captureButtonDisabled)
                    Button("结束会议", role: .destructive) { confirmStop = true }
                        .buttonStyle(WorkspaceActionButtonStyle(tint: .red, filled: false))
                        .disabled(assistant.meeting.terminating ||
                                  (!model.isRecording && model.intent != .wanted && !assistant.meeting.presentation.terminateAction.enabled))
                    Menu {
                        Button { model.setSumMode("auto") } label: {
                            Label("自动", systemImage: model.sumMode == "auto" ? "checkmark.circle.fill" : "circle")
                        }
                        Button { model.setSumMode("manual") } label: {
                            Label("手动", systemImage: model.sumMode == "manual" ? "checkmark.circle.fill" : "circle")
                        }
                    } label: { Text("会中提要").lineLimit(1).minimumScaleFactor(0.75) }
                    .buttonStyle(WorkspaceActionButtonStyle(filled: false))
                    .accessibilityValue(model.sumMode == "auto" ? "自动" : "手动")
                    NavigationLink("会后材料") {
                        reportContent.navigationTitle("会后材料").navigationBarTitleDisplayMode(.inline)
                    }
                    .buttonStyle(WorkspaceActionButtonStyle(filled: false))
                }
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal).padding(.vertical, 8)
                .frame(maxWidth: .infinity).background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 6) {
                    Button(assistant.input.displayName) { assistant.page = .input }
                    Text("·").foregroundStyle(.secondary)
                    Text(model.captureStatusText)
                    Text("·").foregroundStyle(.secondary)
                    Text(model.sumState).foregroundStyle(sumStateColor)
                }
                .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal).padding(.vertical, 8)
                .frame(maxWidth: .infinity).background(.bar)
            }
            .confirmationDialog("结束本次会议并保存已有录音？", isPresented: $confirmStop,
                                titleVisibility: .visible) {
                Button("结束会议", role: .destructive) { assistant.accept(.end) }
                Button("取消", role: .cancel) {}
            }
        }
    }
    private var captureButtonTitle: String {
        if model.isPaused { return "继续采集" }
        if model.isRecording { return "暂停采集" }
        return model.intent == .wanted ? "恢复采集" : "开始采集"
    }
    private var captureButtonAction: CaptureAction {
        if model.isPaused { return .resume }
        if model.isRecording { return .pause }
        return model.intent == .wanted ? .recover : .start
    }
    private var captureButtonDisabled: Bool {
        if assistant.meeting.terminating { return true }
        if model.isPaused {
            return assistant.meeting.actionPending || assistant.meeting.capture?.observedState != "paused" ||
                assistant.connection.pendingDisconnect != nil
        }
        return !model.isRecording && assistant.meeting.actionPending
    }
    @ViewBuilder private var reportContent: some View {
        if model.finalReportText.isEmpty {
            ContentUnavailableView("暂无会后材料", systemImage: "doc.text",
                description: Text("收到并保存的会后报告会显示在这里。"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("会议：\(assistant.meeting.finalReportMeetingID)").font(.footnote).foregroundStyle(.secondary)
                    Text(model.finalReportText).font(.body)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        }
    }
    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.summaries) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.clock)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)
                                Text(item.text)
                                    .font(.system(size: 15))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(item.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: model.summaries.last?.id) { _, _ in
                    guard let last = model.summaries.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 状态行配色:灰 = 等(周期未到/内容不足)、橙 = 机器忙或转写质量不足、蓝 = 正在生成。
    private var sumStateColor: Color {
        switch model.sumCode {
        case "go": return .blue
        case "quality", "busy_prev", "busy_refine", "busy_vram", "busy_cpu": return .orange
        default: return .secondary
        }
    }
}
