import Combine
import Foundation

/// Device-only preparation never creates a meeting. Meeting commands stay in MeetingAssistant.
@MainActor final class CB08DeviceManager: ObservableObject {
    @Published private(set) var busy = false
    @Published private var failure: String?
    private var failureConnection: UUID?
    private let device: CB08DeviceControlling
    private let timeout: Duration

    init(device: CB08DeviceControlling, timeout: Duration = .seconds(8)) {
        self.device = device; self.timeout = timeout
    }
    var problem: String? {
        failureConnection == device.connectionID ? failure : nil
    }
    private func fail(_ message: String, connection: UUID?) {
        failureConnection = connection; failure = message
    }
    func checkForCapture(canResume: Bool) async throws {
        guard !busy else { throw CB08InputError.deviceBusy }
        busy = true
        defer { busy = false }
        let connection = device.connectionID
        guard device.connected, connection != nil else { throw CB08InputError.unavailable }
        let state = await device.refreshRecordState(timeout: .seconds(3))
        guard device.connected, device.connectionID == connection, !Task.isCancelled else {
            throw CB08InputError.unavailable
        }
        guard let state else { throw CB08InputError.recordStateUnknown }
        if state == .paused && !canResume { throw CB08InputError.pausedRecordingNotOwned }
        guard state == .stopped || state == .inactive || (state == .paused && canResume) else {
            throw CB08InputError.alreadyRecording(state)
        }
        failure = nil
    }
    /// Caller must exclude every active/recoverable meeting before using this operation.
    func stopIndependent(cleanup: @escaping @MainActor () async -> Bool) -> Task<Bool, Never>? {
        guard !busy, device.connected, let connection = device.connectionID else { return nil }
        busy = true; failure = nil
        return Task { await self.finishIndependentStop(connection: connection, cleanup: cleanup) }
    }
    private func finishIndependentStop(connection: UUID, cleanup: @MainActor () async -> Bool) async -> Bool {
        defer { busy = false }
        guard await cleanup() else {
            fail("App音频资源清理未完成，请重试", connection: connection); return false
        }
        guard device.connected, device.connectionID == connection, !Task.isCancelled else {
            fail("连接已变化，未确认原设备停止", connection: connection); return false
        }
        device.command(.stop)
        guard await device.waitForRecordAction(timeout: timeout), device.connected,
              device.connectionID == connection, !Task.isCancelled else {
            fail("停止未确认，请检查卡端状态并重试", connection: connection); return false
        }
        let state = await device.refreshRecordState(timeout: .seconds(3))
        guard device.connected, device.connectionID == connection, !Task.isCancelled,
              state == .stopped || state == .inactive else {
            fail("停止回执与状态查询尚未对齐，请刷新后重试", connection: connection); return false
        }
        return true
    }
}
