import SwiftUI

/// Local corrections are kept separately; verified server reports remain intact.
struct MemoReportEditor: View {
    let report: MeetingWorker.MemoReport
    @State private var draft: String
    @State private var saved = false

    init(report: MeetingWorker.MemoReport) {
        self.report = report
        _draft = State(initialValue: UserDefaults.standard.string(forKey: "vm.memoDraft." + report.id) ?? report.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $draft)
                .accessibilityLabel("代办内容，可修改")
                .onChange(of: draft) { _, _ in saved = false }
            DisclosureGroup("原始结果与转写") {
                ScrollView { Text(report.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220)
            }
            if saved { Text("修改已保存在手机").font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
        .navigationTitle("代办结果")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存修改") {
                    UserDefaults.standard.set(draft, forKey: "vm.memoDraft." + report.id)
                    saved = true
                }
            }
        }
    }
}
