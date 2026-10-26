import SwiftUI

/// Four pages share one root model and one dispatcher. Tab changes do no IO.
@MainActor
struct ContentView: View {
    @StateObject private var workspace = MeetingWorkspace()
    @Environment(\.scenePhase) private var scenePhase
    private var model: SessionModel { workspace.model }
    private var assistant: MeetingAssistant { workspace.assistant }

    var body: some View {
        TabView(selection: Binding(get: { assistant.page }, set: { assistant.page = $0 })) {
            SettingsView(model: model, worker: assistant.settings)
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(WorkspacePage.settings)
            InputView(assistant: assistant)
                .tabItem { Label("输入", systemImage: "mic") }.tag(WorkspacePage.input)
            ConnectionView(assistant: assistant)
                .tabItem { Label("连接", systemImage: "network") }.tag(WorkspacePage.connection)
            MeetingView(model: model, assistant: assistant)
                .tabItem { Label("会议", systemImage: "text.bubble") }.tag(WorkspacePage.meeting)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = assistant.message {
                Text(message).font(.callout).frame(maxWidth: .infinity)
                    .padding(8).background(.thinMaterial)
            } else if assistant.page != .meeting && (model.isRecording || model.intent == .wanted) {
                Button("手机采集进行中 · 返回会议") { assistant.page = .meeting }
                    .frame(maxWidth: .infinity, minHeight: 44).background(.thinMaterial)
            }
        }
        .task { await model.refreshForegroundStateLoop() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.refreshNet()
                await model.catchUpNow()
            }
        }
    }
}
