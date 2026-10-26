import SwiftUI

struct MeetingView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var assistant: MeetingAssistant
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(model.captureStatusText, systemImage: "waveform")
                    Spacer()
                    Button(assistant.input.displayName) { assistant.page = .input }
                        .font(.subheadline)
                }
                if !model.transcriptGapText.isEmpty {
                    Text(model.transcriptGapText).font(.caption).foregroundStyle(.orange)
                }
                TranscriptView(partials: model.partials, lines: model.lines,
                               localIdentity: model.identity, isRecording: model.isRecording) { width in
                    summaryPanel(width: width)
                }
            }
            .padding(.horizontal)
            .navigationTitle("会议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.finalReportText.isEmpty {
                    NavigationLink("会后材料") {
                        ScrollView {
                            Text(model.finalReportText).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }.navigationTitle("会后材料")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    HStack {
                        if model.isRecording || model.intent == .wanted || assistant.meeting.actionPending {
                            if model.isPaused {
                                Button("继续采集") { assistant.accept(.resume) }
                                    .disabled(assistant.meeting.actionPending || assistant.meeting.capture?.observedState != "paused")
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("暂停采集") { assistant.accept(.pause) }
                                    .disabled(!model.isRecording)
                                    .buttonStyle(.borderedProminent)
                            }
                            Button("结束会议", role: .destructive) { confirmStop = true }
                                .disabled(assistant.meeting.terminating)
                                .buttonStyle(.bordered)
                        } else {
                            Button("开始采集") { assistant.accept(.start) }
                                .disabled(assistant.meeting.actionPending || assistant.meeting.terminating)
                                .buttonStyle(.borderedProminent)
                        }
                        Button("连接详情") { assistant.page = .connection }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                }.padding().frame(maxWidth: .infinity).background(.bar)
            }
            .confirmationDialog("结束本次会议并保存已有录音？", isPresented: $confirmStop,
                                titleVisibility: .visible) {
                Button("结束会议", role: .destructive) { assistant.accept(.end) }
                Button("取消", role: .cancel) {}
            }
        }
    }
    private func summaryPanel(width: CGFloat) -> some View {
        let gap: CGFloat = 6
        let btnW = max(52, (width - gap * 4) / 5)     // 与第一排同算法:5 等分
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: gap) {
                modeButton("自动", on: model.sumMode == "auto", width: btnW) { model.setSumMode("auto") }
                modeButton("手动", on: model.sumMode == "manual", width: btnW) { model.setSumMode("manual") }
                HStack(spacing: 4) {
                    // 用户口径 2026-10-19:去掉「状态」两个字 —— 这行本身就只讲提要状态,标签无意义。
                    Text(model.sumState)
                        .font(.system(size: 10))
                        .foregroundStyle(sumStateColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)   // 显式左对齐:整行不被居中,也不会被挤出边界

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

    /// 档位按钮:纯文字单行、**矮块**(用户 2026-10-16 要求:高度压到第一排按钮的 50~60%,
    /// 与第一排按钮**同高**),块高 24、圆角 6;宽度仍与第一排同算法(5 等分)。
    private func modeButton(_ title: String, on: Bool, width: CGFloat,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? .white : .primary)
                .frame(width: width, height: 24)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(on ? Color.blue : Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
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
