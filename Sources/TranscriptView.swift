import SwiftUI

/// Renders live partials and confirmed transcript lines. It owns only scroll
/// presentation state; transcript facts remain owned by SessionModel.
struct TranscriptView<Summary: View>: View {
    let partials: [TranscriptPartial]
    let lines: [TranscriptLine]
    let localIdentity: String
    let isRecording: Bool
    let revision: Int
    private let summary: (CGFloat) -> Summary

    @State private var followsLatestFinal = true
    @State private var rowBuilder = TranscriptRows()
    private var rows: [TranscriptRows.Row] { rowBuilder.rows }

    init(partials: [TranscriptPartial], lines: [TranscriptLine],
         localIdentity: String, isRecording: Bool, revision: Int,
         @ViewBuilder summary: @escaping (CGFloat) -> Summary) {
        self.partials = partials
        self.lines = lines
        self.localIdentity = localIdentity
        self.isRecording = isRecording
        self.revision = revision
        self.summary = summary
    }

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.height - 6, 0)
            VStack(spacing: 3) {
                partialPanel.frame(height: usable * 0.1)
                Divider().opacity(0.25)
                finalPanel.frame(height: usable * 0.5)
                Divider().opacity(0.25)
                summary(geo.size.width).frame(height: usable * 0.4)
            }
        }
        .onChange(of: isRecording) { _, active in
            if active { followsLatestFinal = true }
        }
    }

    private var partialPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(partials) { item in
                        paragraph(who: displayWho(item.who, source: item.source),
                                  text: item.text, color: .blue)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: partials.map(\.text)) { _, _ in
                guard let last = partials.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
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

    private func displayWho(_ who: String, source: String) -> String {
        if source == localIdentity { return "本地1" }
        if source.hasSuffix("-livekit") { return "现场·\(who)" }
        if source.hasSuffix("-replaykit") { return "在线1" }
        return source.isEmpty ? who : "\(source)·\(who)"
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
