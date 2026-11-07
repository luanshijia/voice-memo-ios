import SwiftUI

@MainActor struct CB08FilesSection: View {
    @ObservedObject var assistant: MeetingAssistant
    @ObservedObject var manager: CB08FileManager
    @State private var newestFirst = true
    @State private var selected: CB08CardFile?
    @State private var selectedConnection: UUID?
    @State private var showingDelete = false

    var body: some View {
        Section {
            Text(manager.displayStatus).font(.callout).foregroundStyle(.secondary)
            if manager.hasCurrentList {
                LabeledContent("文件数量", value: "\(manager.visibleFiles.count)")
                if manager.visibleFiles.isEmpty { Text("卡片中没有录音文件").foregroundStyle(.secondary) }
                ForEach(manager.sortedFiles(newestFirst: newestFirst)) { file in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(file.name).font(.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text(size(file.bytes))
                            Text("·")
                            Text(duration(file.seconds))
                            Spacer()
                            Button("删除", role: .destructive) {
                                selectedConnection = assistant.input.device.connectionID
                                selected = file
                                showingDelete = true
                            }
                            .buttonStyle(.borderless)
                            .disabled(!manager.canDelete || !CB08CardFile.supportsDeletion(file.name))
                        }.font(.subheadline)
                        if let date = file.recordedAt {
                            Text("录音时间（文件名）：\(date.formatted(date: .numeric, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text("录音时间未知").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
                if !manager.busy && assistant.input.device.recordState != .stopped {
                    Text("删除前请先停止并保存录音，等待卡片确认停止。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("文件管理")
                Spacer()
                Button(newestFirst ? "最新优先" : "最早优先") { newestFirst.toggle() }
                    .disabled(!manager.hasCurrentList || manager.busy)
                Button("刷新") { manager.refresh() }.disabled(!manager.canRefresh)
            }
        }
        .alert("删除卡片录音？", isPresented: $showingDelete) {
            Button("删除", role: .destructive) {
                if let file = selected { manager.delete(file, expectedConnection: selectedConnection) }
                selected = nil
            }
            Button("取消", role: .cancel) { selected = nil }
        } message: {
            Text("\(selected?.name ?? "")\n将从录音卡永久删除，无法恢复。")
        }
    }
    private func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知"
    }
    private func duration(_ seconds: Int64?) -> String {
        guard let seconds else { return "时长未知" }
        return "\(seconds / 60)分\(seconds % 60)秒"
    }
}
