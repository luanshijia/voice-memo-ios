import Combine

/// Diagnostic counters have their own observer; they never invalidate the workspace.
@MainActor final class DeviceTelemetry: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    func changed() { objectWillChange.send() }
}
