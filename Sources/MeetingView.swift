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
                               isRecording: model.isRecording, revision: model.transcriptRevision) { _ in
                    summaryPanel
                }
            }
            .padding(.horizontal)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 4) {
                    Button("待办") { if assistant.memoButtonEnabled { assistant.toggleMemo() } }
                        .buttonStyle(MeetingActionButtonStyle(tint: assistant.memoActive ? .red : (assistant.memoButtonEnabled ? .primary : .secondary),
                            filled: assistant.memoActive))
                        .accessibilityValue(assistant.memoActive ? "录音中，点击结束" : "点击开始个人备忘")
                    Button(captureButtonTitle) { assistant.accept(captureButtonAction) }
                        .buttonStyle(MeetingActionButtonStyle(tint: !assistant.memoActive && model.intent == .wanted ? .blue : .primary,
                            selected: !assistant.memoActive && model.intent == .wanted))
                        .disabled(captureButtonDisabled)
                    Button("结束", role: .destructive) { confirmStop = true }
                        .buttonStyle(MeetingActionButtonStyle(tint: confirmStop ? .blue : .primary, selected: confirmStop))
                        .disabled(assistant.memoActive || assistant.meeting.terminating ||
                                  (!model.isRecording && model.intent != .wanted && !assistant.meeting.presentation.terminateAction.enabled))
                        .popover(isPresented: $confirmStop, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                            VStack(spacing: 16) {
                                Button("结束会议", role: .destructive) {
                                    confirmStop = false
                                    assistant.accept(.end)
                                }
                                .buttonStyle(MeetingActionButtonStyle(tint: .red, selected: true))
                                Button("取消", role: .cancel) { confirmStop = false }
                                    .buttonStyle(MeetingActionButtonStyle(selected: true))
                            }
                            .padding(20).frame(width: 260)
                            .presentationCompactAdaptation(.popover)
                        }
                    Button("提要") { assistant.meeting.requestSummary() }
                        .buttonStyle(MeetingActionButtonStyle(tint: model.sumMode == "manual" ? .blue : .primary, filled: model.sumMode == "manual"))
                        .contextMenu {
                            Button { model.setSumMode("auto") } label: {
                                Label("自动", systemImage: model.sumMode == "auto" ? "checkmark" : "")
                            }
                            .disabled(assistant.meeting.pendingSumMode != nil)
                            Button { model.setSumMode("manual") } label: {
                                Label("手动", systemImage: model.sumMode == "manual" ? "checkmark" : "")
                            }
                            .disabled(assistant.meeting.pendingSumMode != nil)
                        }
                        .accessibilityValue(model.sumMode == "auto" ? "自动，短按无动作" : "手动，点击生成提要")
                        .accessibilityHint("长按选择自动或手动")
                    NavigationLink("总结") {
                        reportContent.navigationTitle("总结").navigationBarTitleDisplayMode(.inline)
                    }
                    .buttonStyle(MeetingActionButtonStyle())
                }
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(6)
                .background(Color(uiColor: .systemGray6), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .padding(.horizontal).padding(.vertical, 8)
                .frame(maxWidth: .infinity).background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 6) {
                    Button(assistant.input.displayName) { assistant.page = .input }
                        .buttonStyle(.plain).foregroundStyle(.blue)
                    Text("·").foregroundStyle(.secondary)
                    Text(model.captureStatusText)
                    Text("·").foregroundStyle(.secondary)
                    Text(model.sumState).foregroundStyle(sumStateColor)
                }
                .font(.caption.weight(.regular)).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal).padding(.vertical, 8)
                .frame(maxWidth: .infinity).background(.bar)
            }


        }
    }
    private var captureButtonTitle: String {
        if assistant.memoActive { return "开始" }
        if model.isPaused { return "继续" }
        if model.isRecording { return "暂停" }
        return model.intent == .wanted ? "恢复" : "开始"
    }
    private var captureButtonAction: CaptureAction {
        if model.isPaused { return .resume }
        if model.isRecording { return .pause }
        return model.intent == .wanted ? .recover : .start
    }
    private var captureButtonDisabled: Bool {
        if assistant.memoActive { return true }
        if !model.isRecording && !assistant.canStartCapture { return true }
        if assistant.meeting.terminating { return true }
        if model.isPaused {
            return assistant.meeting.actionPending || assistant.meeting.capture?.observedState != "paused" ||
                assistant.connection.pendingDisconnect != nil
        }
        return !model.isRecording && assistant.meeting.actionPending
    }
    @ViewBuilder private var reportContent: some View {
        if let operation = assistant.meeting.latestResultOperation {
            VStack(alignment: .leading, spacing: 12) {
                Text(operation.label).font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
                if let memo = assistant.meeting.latestMemoReport {
                    MemoReportEditor(report: memo).id(memo.id)
                } else if let text = assistant.meeting.latestResultText {
                    ScrollView {
                        Text(text).font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                } else {
                    ContentUnavailableView(assistant.meeting.latestResultStatus, systemImage: "doc.text")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ContentUnavailableView("暂无结果", systemImage: "doc.text")
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
        case "quality", "busy_prev", "busy_refine", "busy_vram", "busy_cpu", "busy_gpu", "failed": return .orange
        default: return .secondary
        }
    }
}
