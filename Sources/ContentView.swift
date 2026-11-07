import SwiftUI

/// Five pages share one root model and one dispatcher.
@MainActor
struct ContentView: View {
    @StateObject private var workspace = MeetingWorkspace()
    @Environment(\.scenePhase) private var scenePhase
    private var model: SessionModel { workspace.model }
    private var assistant: MeetingAssistant { workspace.assistant }

    var body: some View {
        TabView(selection: Binding(get: { assistant.page }, set: { assistant.page = $0 })) {
            MeetingView(model: model, assistant: assistant)
                .tabItem { Label("会议", systemImage: "text.bubble") }.tag(WorkspacePage.meeting)
            NavigationStack {
                ExternalDeviceView(assistant: assistant)
            }
            .tabItem { Label("外设", systemImage: "waveform") }.tag(WorkspacePage.externalDevice)
            ConnectionView(assistant: assistant)
                .tabItem { Label("连接", systemImage: "network") }.tag(WorkspacePage.connection)
            InputView(assistant: assistant)
                .tabItem { Label("输入", systemImage: "mic") }.tag(WorkspacePage.input)
            SettingsView(model: model, worker: assistant.settings)
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(WorkspacePage.settings)
        }
        .alert("停止并保存", isPresented: Binding(get: { assistant.showingDeviceStop },
                                              set: { assistant.showingDeviceStop = $0 })) {
            Button("停止并保存", role: .destructive) { assistant.confirmDeviceStop() }
            Button("取消", role: .cancel) { assistant.cancelDeviceStop() }
        } message: {
            Text(assistant.deviceStopMessage)
        }
        .task(id: scenePhase == .active ? assistant.meeting.foregroundObservationInterval : nil) {
            assistant.setRuntimeForeground(scenePhase == .active)
            assistant.startDesktopObservation()
            if scenePhase == .active { await model.refreshForegroundStateLoop() }
        }
        .onDisappear { assistant.stopDesktopObservation() }
        .onChange(of: assistant.runtimeContext) { _, _ in assistant.observeRuntimePhase() }
        .onChange(of: assistant.usesIdlePolling) { _, _ in assistant.restartDesktopObservation() }
        .onChange(of: scenePhase) { _, phase in
            assistant.setRuntimeForeground(phase == .active)
            assistant.input.device.appState(foreground: phase == .active)
            guard phase == .active else { return }
            assistant.meeting.refreshForegroundObservations()
            MeetingClient.refreshControlStorage()
            assistant.settings.refreshPendingControls()
            Task {
                await assistant.checkConnection()
                await model.catchUpNow()
            }
        }
        .onChange(of: assistant.settings.snapshot.revision) { _, _ in
            Task { await assistant.checkConnection() }
        }
    }
}
