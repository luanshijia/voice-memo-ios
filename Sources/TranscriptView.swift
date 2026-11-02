import SwiftUI

/// Renders live partials and confirmed transcript lines. It owns only scroll
/// presentation state; transcript facts remain owned by SessionModel.
struct TranscriptView<Summary: View>: View {
    let partials: [TranscriptPartial]
    let lines: [TranscriptLine]
    let isRecording: Bool
    let revision: Int
    private let summary: (CGFloat) -> Summary

    @State private var followsLatestFinal = true
    @State private var rowBuilder = TranscriptRows()
    private var rows: [TranscriptRows.Row] { rowBuilder.rows }

    init(partials: [TranscriptPartial], lines: [TranscriptLine],
         isRecording: Bool, revision: Int,
         @ViewBuilder summary: @escaping (CGFloat) -> Summary) {
        self.partials = partials
        self.lines = lines
        self.isRecording = isRecording
        self.revision = revision
        self.summary = summary
    }

    var body: some View {
        GeometryReader { geo in
            let partialHeight = min(PartialTranscriptTail.panelHeight, geo.size.height)
            let remaining = max(geo.size.height - partialHeight - 14, 0)
            VStack(spacing: 3) {
                partialPanel(width: geo.size.width).frame(height: partialHeight)
                Divider().opacity(0.25)
                finalPanel.frame(height: remaining * 5 / 9)
                Divider().opacity(0.25)
                summary(geo.size.width).frame(height: remaining * 4 / 9)
            }
        }
        .onChange(of: isRecording) { _, active in
            if active { followsLatestFinal = true }
        }
    }

    private func partialPanel(width: CGFloat) -> some View {
        Text(PartialTranscriptTail.latest(partials.map(\.text).joined(separator: "\n"), width: width))
            .font(.system(size: 15))
            .lineSpacing(PartialTranscriptTail.lineSpacing)
            .foregroundStyle(.blue)
            .lineLimit(2).truncationMode(.head)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
    }

    private var finalPanel: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(rows) { row in
                            paragraph(who: row.who, text: row.text, color: .primary)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { _ in
                    followsLatestFinal = false
                })
                .onChange(of: revision) { _, _ in
                    rowBuilder.update(lines)
                    guard followsLatestFinal, let last = rows.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .onAppear {
                    rowBuilder.update(lines)
                }

                if !followsLatestFinal, let last = rows.last {
                    Button {
                        followsLatestFinal = true
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到最新字幕")
                    .padding(6)
                }
            }
        }
    }

    private func paragraph(who: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(6)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
