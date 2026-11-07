import Combine
import Foundation

@MainActor protocol CB08FileDevice: CB08DeviceControlling {
    var onFileEvent: ((CB08SDKEvent) -> Void)? { get set }
    func requestFiles()
    func deleteFile(named name: String)
}

struct CB08CardFile: Identifiable, Equatable {
    let name: String
    let bytes: Int64?
    let seconds: Int64?
    let recordedAt: Date?
    var id: String { name }
    init(_ data: [String: Any]) throws {
        guard let name = data["name"] as? String, !name.isEmpty, !name.contains("\0") else {
            throw CB08FileError.invalidResponse
        }
        self.name = name
        func number(_ key: String) -> Int64? {
            let raw = data[key].map { String(describing: $0) }
            guard let raw, let value = Int64(raw), value >= 0 else { return nil }
            return value
        }
        bytes = number("size"); seconds = number("time") // Vendor iOS contract: bytes and seconds.
        recordedAt = Self.date(from: name)
    }
    static func supportsDeletion(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 24 && !name.contains("\0") &&
        !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }
    private static func date(from name: String) -> Date? {
        guard let range = name.range(of: #"^(?:note|call)[0-9]{8}-[0-9]{6}"#, options: .regularExpression) else { return nil }
        let stamp = String(name[range].suffix(15))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"; formatter.isLenient = false
        guard let date = formatter.date(from: stamp), formatter.string(from: date) == stamp else { return nil }
        return date
    }
}

enum CB08FileError: LocalizedError {
    case unavailable, busy, recording, invalidResponse, rejected, timeout, changed, notDeleted
    var errorDescription: String? {
        switch self {
        case .unavailable: return "CB08未连接或连接已变化，请重新刷新"
        case .busy: return "请先完成当前会议或设备动作"
        case .recording: return "删除前请先停止并保存录音，等待卡片确认停止"
        case .invalidResponse: return "文件响应格式不完整，请断开重连后刷新"
        case .rejected: return "卡片未完成文件操作，请刷新后重试"
        case .timeout: return "文件响应未确认，请断开重连后再试"
        case .changed: return "文件或列表已变化，请刷新后重新选择"
        case .notDeleted: return "卡片返回成功，但文件仍在列表中，删除未确认"
        }
    }
}

@MainActor final class CB08FileManager: ObservableObject {
    @Published private(set) var files: [CB08CardFile] = []
    @Published private(set) var status = "点击刷新查看卡片文件"
    @Published private(set) var busy = false
    private let device: CB08FileDevice
    private let operations: CB08DeviceManager
    private let timeout: Duration
    private var listConnection: UUID?
    private var uncertainConnection: UUID?
    private var activeConnection: UUID?
    private enum Pending: Equatable { case list, deletion }
    private var pending: Pending?
    private var entries: [String: CB08CardFile] = [:]
    private var response: Result<Void, Error>?
    var operationAllowed: () -> Bool = { false }

    init(device: CB08FileDevice, operations: CB08DeviceManager, timeout: Duration = .seconds(20)) {
        self.device = device; self.operations = operations; self.timeout = timeout
        device.onFileEvent = { [weak self] in self?.receive($0) }
    }
    var visibleFiles: [CB08CardFile] {
        device.connected && listConnection == device.connectionID ? files : []
    }
    var hasCurrentList: Bool { device.connected && listConnection != nil && listConnection == device.connectionID }
    var requiresReconnect: Bool { device.connected && uncertainConnection != nil && uncertainConnection == device.connectionID }
    var canRefresh: Bool {
        device.connected && !operations.busy && operationAllowed() && !requiresReconnect
    }
    var canDelete: Bool { canRefresh && hasCurrentList && device.recordState == .stopped }
    var displayStatus: String {
        guard device.connected else { return "连接CB08后刷新文件列表" }
        if uncertainConnection == device.connectionID { return CB08FileError.timeout.localizedDescription }
        return status
    }
    func sortedFiles(newestFirst: Bool) -> [CB08CardFile] {
        visibleFiles.sorted {
            switch ($0.recordedAt, $1.recordedAt) {
            case let (a?, b?) where a != b: return newestFirst ? a > b : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.name < $1.name
            }
        }
    }
    @discardableResult func refresh() -> Task<Void, Never>? {
        guard canRefresh else { return nil }
        return perform {
            try await self.checkState(deleting: false)
            try await self.readList()
            self.status = "已读取\(self.files.count)个文件"
        }
    }
    @discardableResult func delete(_ file: CB08CardFile, expectedConnection: UUID? = nil) -> Task<Void, Never>? {
        guard expectedConnection == nil || expectedConnection == device.connectionID,
              canDelete, CB08CardFile.supportsDeletion(file.name), visibleFiles.contains(file) else {
            status = CB08FileError.changed.localizedDescription; return nil
        }
        return perform {
            try await self.checkState(deleting: true)
            try await self.readList()
            guard self.files.contains(file) else { throw CB08FileError.changed }
            try self.checkConnection()
            guard self.operationAllowed(), self.device.recordState == .stopped else { throw CB08FileError.recording }
            self.pending = .deletion; self.response = nil
            self.status = "正在删除所选文件"
            self.device.deleteFile(named: file.name)
            try await self.waitForResponse()
            try await self.readList()
            guard !self.files.contains(where: { $0.name == file.name }) else { throw CB08FileError.notDeleted }
            self.status = "删除已确认，剩余\(self.files.count)个文件"
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        let task = operations.performFileOperation { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.activeConnection = nil; self.pending = nil; self.response = nil }
            do { try await operation() }
            catch { self.status = error.localizedDescription }
        }
        if task != nil { busy = true; activeConnection = device.connectionID }
        return task
    }
    private func checkConnection() throws {
        guard device.connected, let activeConnection, device.connectionID == activeConnection else {
            throw CB08FileError.unavailable
        }
    }
    private func checkState(deleting: Bool) async throws {
        try checkConnection()
        guard operationAllowed() else { throw CB08FileError.busy }
        status = "正在核对卡片状态"
        let state = await device.refreshRecordState(timeout: .seconds(3))
        try checkConnection()
        guard operationAllowed(), deleting ? state == .stopped : (state == .stopped || state == .inactive) else {
            throw CB08FileError.recording
        }
    }
    private func readList() async throws {
        try checkConnection()
        guard operationAllowed(), device.recordState != .recording, device.recordState != .paused else {
            throw CB08FileError.recording
        }
        pending = .list; response = nil; entries = [:]
        status = "正在读取文件列表"
        device.requestFiles()
        try await waitForResponse()
        files = Array(entries.values); listConnection = activeConnection
    }
    private func waitForResponse() async throws {
        let clock = ContinuousClock(); let deadline = clock.now + timeout
        while response == nil, clock.now < deadline, !Task.isCancelled {
            try checkConnection()
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { uncertainConnection = activeConnection; throw error }
        }
        try checkConnection()
        guard !Task.isCancelled else { uncertainConnection = activeConnection; throw CancellationError() }
        guard let response else { uncertainConnection = activeConnection; throw CB08FileError.timeout }
        pending = nil
        try response.get()
    }
    private func receive(_ event: CB08SDKEvent) {
        guard device.connected, activeConnection == device.connectionID, response == nil else { return }
        guard (pending == .list && event.command == 4) || (pending == .deletion && event.command == 14) else { return }
        guard event.state == 0 else { response = .failure(CB08FileError.rejected); return }
        if pending == .deletion {
            let raw = event.data["delete_state"].map { String(describing: $0) }
            if raw == "0" { response = .success(()) }
            else if raw == "1" { response = .failure(CB08FileError.rejected) }
            else { uncertainConnection = activeConnection; response = .failure(CB08FileError.invalidResponse) }
            return
        }
        do {
            guard let batch = event.fileEntries, event.finish == 0 || event.finish == 1 else { throw CB08FileError.invalidResponse }
            for raw in batch {
                let file = try CB08CardFile(raw)
                if let old = entries[file.name], old != file { throw CB08FileError.invalidResponse }
                entries[file.name] = file
                guard entries.count <= 10_000 else { throw CB08FileError.invalidResponse }
            }
            if event.finish == 1 { response = .success(()) }
        } catch { uncertainConnection = activeConnection; response = .failure(error) }
    }
}
