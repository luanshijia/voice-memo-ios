import Foundation
import Combine
#if !targetEnvironment(simulator)
import CB08SDK
#endif

struct CB08Device: Identifiable, Equatable {
    let name: String
    let address: String
    let productType: String
    var id: String { address }
}

enum CB08RecordAction: Int {
    case start = 1, stop = 3, pause = 5, resume = 7
    var title: String {
        switch self { case .start: return "开始"; case .stop: return "保存并停止"
        case .pause: return "暂停"; case .resume: return "继续" }
    }
}
enum CB08RecordingState: String {
    case stopped = "停止", recording = "录音中", paused = "暂停", inactive = "未在录音（停止或暂停待确认）"
}
enum CB08ConnectionPhase: String {
    case disconnected = "未连接", connecting = "连接中", connected = "已连接"
    case disconnecting = "断开中", unknown = "连接状态未知"
}
@MainActor protocol CB08DeviceControlling: AnyObject {
    var connected: Bool { get }
    var connectionID: UUID? { get }
    var recordState: CB08RecordingState? { get }
    var onPacket: ((Data) -> Void)? { get set }
    var onLoss: (() -> Void)? { get set }
    func refreshRecordState(timeout: Duration) async -> CB08RecordingState?
    func command(_ action: CB08RecordAction)
    func waitForRecordAction(timeout: Duration) async -> Bool
    func discardQueuedPackets()
}

/// Bound delegate-to-main handoff; no unbounded backlog of PCM work.
private final class CB08PacketBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var lost = 0
    private var epoch = 0
    func invalidate() { lock.lock(); epoch += 1; lock.unlock() }
    func current(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == epoch }
    func reserve() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard pending < 8 else { lost += 1; return nil }
        pending += 1; return epoch
    }
    func release() -> Int {
        lock.lock(); defer { lock.unlock() }
        pending -= 1; return lost
    }
}

struct CB08SDKEvent: @unchecked Sendable {
    let command: Int
    let state: Int?
    let data: [String: Any]
    static func parse(_ text: String) -> Self? {
        RuntimeActivity.add(.sdkEvent)
        guard let bytes = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        func integer(_ value: Any?) -> Int? {
            if let n = value as? NSNumber { return n.intValue }
            return (value as? String).flatMap(Int.init)
        }
        guard let command = integer(object["cmd"]),
              [1, 2, 3, 6, 8, 9, 10, 11, 13, 15, 17, 22].contains(command) else { return nil }
        RuntimeActivity.recordSDKCommand(command)
        let data = object["data"] as? [String: Any] ?? [:]
        if command == 1 {
            guard let name = data["name"] as? String,
                  name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("CB08") else { return nil }
        }
        return Self(command: command, state: integer(object["state"]), data: data)
    }
}

/// Only stable informational events may be deduplicated; action/query/key events always pass.
final class CB08EventFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [Int: String] = [:]
    func reset() { lock.lock(); last.removeAll(); lock.unlock() }
    func accept(_ event: CB08SDKEvent, raw: String) -> Bool {
        guard event.state == 0, [6, 10, 11, 13, 15, 17, 22].contains(event.command) else { return true }
        lock.lock(); defer { lock.unlock() }
        guard last[event.command] != raw else { return false }
        last[event.command] = raw
        return true
    }
}

@MainActor final class CB08SDKBridge: NSObject, ObservableObject, CB08DeviceControlling {
    let objectWillChange = ObservableObjectPublisher()
    let telemetry = DeviceTelemetry()
    private(set) var devices: [CB08Device] = [] { willSet { if devices != newValue { objectWillChange.send() } } }
    private(set) var connected = false { willSet { if connected != newValue { objectWillChange.send() } } }
    private(set) var connectionPhase: CB08ConnectionPhase = .disconnected { willSet { if connectionPhase != newValue { objectWillChange.send() } } }
    private(set) var isScanning = false { willSet { if isScanning != newValue { objectWillChange.send() } } }
    var selectedDeviceID: String? { willSet { if selectedDeviceID != newValue { objectWillChange.send() } } }
    private(set) var connectionID: UUID?
    private(set) var status = "未连接" { willSet { if status != newValue { telemetry.changed() } } }
    private(set) var eventSummary = "" { willSet { if eventSummary != newValue { telemetry.changed() } } }
    private(set) var recordState: CB08RecordingState? { willSet { if recordState != newValue { objectWillChange.send() } } }
    private(set) var querySummary = "尚未查询" { willSet { if querySummary != newValue { telemetry.changed() } } }
    private(set) var actionSummary = "尚无录音动作" { willSet { if actionSummary != newValue { telemetry.changed() } } }
    private(set) var hardwareSummary = "尚无实体键请求" { willSet { if hardwareSummary != newValue { telemetry.changed() } } }
    private(set) var connectionSummary = "尚无连接回调" { willSet { if connectionSummary != newValue { telemetry.changed() } } }
    private(set) var diagnostics: [String] = [] { willSet { if diagnostics != newValue { telemetry.changed() } } }
    private(set) var lowPowerRecording: Bool? { willSet { if lowPowerRecording != newValue { telemetry.changed() } } }
    private(set) var gain: Int? { willSet { if gain != newValue { telemetry.changed() } } }
    private(set) var deviceRecordingSeconds: Int? { willSet { if deviceRecordingSeconds != newValue { telemetry.changed() } } }
    private(set) var battery: Int? { willSet { if battery != newValue { telemetry.changed() } } }
    private(set) var firmware = "未知" { willSet { if firmware != newValue { telemetry.changed() } } }
    private(set) var capacity = "未知（SDK原始单位）" { willSet { if capacity != newValue { telemetry.changed() } } }
    private(set) var currentFile = "未知" { willSet { if currentFile != newValue { telemetry.changed() } } }
    private(set) var packetCount = 0
    private(set) var packetBytes = 0
    private(set) var droppedPackets = 0
    private(set) var packetSizes: [Int: Int] = [:]
    private(set) var hardwareButtonEvents: [Int: Int] = [:] { willSet { if hardwareButtonEvents != newValue { telemetry.changed() } } }
    var onPacket: ((Data) -> Void)?
    var onLoss: (() -> Void)?
    var onHardware: ((CB08RecordAction) -> Bool)?
    var onRecordingObservation: ((CB08RecordingState) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var hardwareIntent: CB08RecordAction?
    private var foreground = true
    private var queryRevision = 0
    private var recordQueryPending = false
    private var actionRevision = 0
    private var confirmedActionRevision = -1
    private var pendingAction: CB08RecordAction?
    private var connectionTimeout: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var lastDiagnostic: String?
    private let budget = CB08PacketBudget()
    private let eventFilter = CB08EventFilter()
#if !targetEnvironment(simulator)
    private var node: PNode?
#endif
    private(set) var isSDKInitialized = false { willSet { if isSDKInitialized != newValue { objectWillChange.send() } } }
    var connectionAllowed: () -> Bool = { true }
    override init() { super.init() }
    deinit { scanTimeout?.cancel(); connectionTimeout?.cancel() }
    /// Activation is explicit; constructing the phone workspace never starts Bluetooth.
    func activate() {
        guard connectionAllowed() else { status = "服务器未就绪，蓝牙暂不可用"; return }
        guard !isSDKInitialized else { return }
#if !targetEnvironment(simulator)
        guard let shared = PNode.shared() else { status = "CB08 SDK初始化失败"; return }
        node = shared
        isSDKInitialized = true
        node?.delegate = self
        PNode.setShowLog(false)
        connected = node?.isDeviceConnected() ?? false
        if connected {
            connectionID = UUID(); connectionPhase = .connected
            initializeConnection()
        }
#else
        isSDKInitialized = true
        status = "模拟器不支持CB08蓝牙，需真机验证"
#endif
    }
    func scan() {
        guard connectionAllowed() else { status = "服务器未就绪，蓝牙暂不可用"; return }
        activate()
        guard isSDKInitialized else { return }
        guard connectionPhase == .disconnected || connectionPhase == .unknown else { return }
        devices.removeAll(); isScanning = true; status = "扫描中"
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.stopScan()
        }
#if !targetEnvironment(simulator)
        node?.startSearch()
#else
        status = "模拟器不支持CB08蓝牙"
#endif
    }
    func stopScan() {
        scanTimeout?.cancel(); scanTimeout = nil
        guard isScanning else { return }
        isScanning = false
#if !targetEnvironment(simulator)
        node?.stopSearch()
#endif
        if status == "扫描中" { status = "已停止扫描" }
    }
    var selectedDevice: CB08Device? { devices.first { $0.id == selectedDeviceID } }
    func connect(_ device: CB08Device) {
        guard connectionAllowed() else { status = "服务器未就绪，蓝牙暂不可用"; return }
        activate()
        guard isSDKInitialized else { return }
        guard !connected, connectionPhase != .connecting, connectionPhase != .disconnecting else { return }
        stopScan(); hardwareIntent = nil; connectionID = nil; status = "正在连接CB08"
        selectedDeviceID = device.id; connectionPhase = .connecting
        resetDeviceFacts(); noteDevice("发出蓝牙连接请求")
        armConnectionTimeout(for: .connecting)
#if !targetEnvironment(simulator)
        node?.connectDeviceAndAddress(device.name, device.address)
#endif
    }
    func disconnect() {
        guard connectionPhase != .disconnecting else { return }
        stopScan(); hardwareIntent = nil; discardQueuedPackets(); connected = false; connectionID = nil; recordState = nil
        connectionPhase = .disconnecting
        status = "已请求断开"; noteDevice("发出断开请求，等待cmd=2确认"); onLoss?()
        armConnectionTimeout(for: .disconnecting)
#if !targetEnvironment(simulator)
        node?.closeConnect()
#endif
    }
    func refreshStatus() {
        guard connected else { status = "未连接"; return }
#if !targetEnvironment(simulator)
        node?.getCBC(); node?.getDeviceVersion(); node?.getDeviceCapacity()
        node?.getFileNameOnlyRecording()
        node?.getDeviceGain(); node?.getDeviceLowPowerRecordMode()
        if recordState == .recording { node?.getTimeOnlyRecording() }
#endif
        requestRecordQuery()
        status = "已请求设备状态"
    }
    func refreshRecordState(timeout: Duration) async -> CB08RecordingState? {
        guard connected else { return nil }
        let revision = queryRevision
        let connection = connectionID
        requestRecordQuery()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while queryRevision == revision, connected, connectionID == connection, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard queryRevision != revision, connected, connectionID == connection, !Task.isCancelled else {
            if connectionID == connection { recordQueryPending = false }
            return nil
        }
        return recordState
    }
    private func requestRecordQuery() {
        guard !recordQueryPending else { return }
        recordQueryPending = true
#if !targetEnvironment(simulator)
        node?.getRecordState()
#endif
    }
    func cancelHardwareIntent(unless action: CB08RecordAction? = nil) {
        if hardwareIntent != action { hardwareIntent = nil }
    }
    func discardQueuedPackets() { budget.invalidate() }
    func command(_ action: CB08RecordAction) {
        guard connected else { return }
        let acknowledge = hardwareIntent == action
        hardwareIntent = nil
        actionRevision += 1; pendingAction = action
        actionSummary = "\(action.title)：等待cmd=3确认"
        noteDevice("发出\(acknowledge ? "实体键确认" : "App录音动作") \(action.title)，action=\(action.rawValue)")
#if !targetEnvironment(simulator)
        switch (action, acknowledge) {
        case (.start, true): node?.startBtnBackRecord()
        case (.stop, true): node?.stopBtnBackRecord()
        case (.pause, true): node?.pauseBtnBackRecord()
        case (.resume, true): node?.continueBtnBackRecord()
        case (.start, false): node?.startRecord()
        case (.stop, false): node?.stopRecord()
        case (.pause, false): node?.pauseRecord()
        case (.resume, false): node?.continueRecord()
        }
#endif
        status = "已请求设备动作，等待状态回调"
    }
    func waitForRecordAction(timeout: Duration) async -> Bool {
        let revision = actionRevision
        let connection = connectionID
        let clock = ContinuousClock(); let deadline = clock.now + timeout
        while connected, connectionID == connection, actionRevision == revision,
              confirmedActionRevision != revision, clock.now < deadline, !Task.isCancelled {
            if pendingAction == nil { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return connected && connectionID == connection && actionRevision == revision &&
            confirmedActionRevision == revision && !Task.isCancelled
    }
    func appState(foreground: Bool) {
        self.foreground = foreground
        if !foreground { stopScan() }
#if !targetEnvironment(simulator)
        if connected { node?.sendAppShowState(foreground ? 1 : 2) }
#endif
    }
    func noteDevice(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        diagnostics.append("\(Date().formatted(date: .omitted, time: .standard)) \(message)")
        if diagnostics.count > 30 { diagnostics.removeFirst(diagnostics.count - 30) }
        onDiagnostic?(message)
    }
    private func resetDeviceFacts() {
        eventFilter.reset(); lastDiagnostic = nil
        recordState = nil; battery = nil; firmware = "未知"; capacity = "未知（SDK原始单位）"
        currentFile = "未知"; gain = nil; lowPowerRecording = nil; deviceRecordingSeconds = nil
        pendingAction = nil; actionRevision += 1
        recordQueryPending = false
        querySummary = "尚未查询"; actionSummary = "尚无录音动作"
        hardwareIntent = nil; hardwareSummary = "本次连接尚无实体键请求"
        hardwareButtonEvents = [:]
    }
    private func initializeConnection() {
#if !targetEnvironment(simulator)
        node?.syncTime(); node?.sendAppShowState(foreground ? 1 : 2)
#endif
        noteDevice("连接初始化：同步时间、通知前后台状态、查询设备信息")
        refreshStatus()
    }
    private func armConnectionTimeout(for phase: CB08ConnectionPhase) {
        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.connectionPhase == phase else { return }
            self.connectionPhase = .unknown; self.status = "蓝牙操作超时，请断开后重试"
            self.noteDevice("蓝牙操作超时，未收到确认")
        }
    }
    private func integer(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        return (value as? String).flatMap(Int.init)
    }
    // Retain only selected facts. Raw SDK JSON can contain addresses and serials.
    func receiveEvent(_ text: String) {
        guard let event = CB08SDKEvent.parse(text), eventFilter.accept(event, raw: text) else { return }
        receiveEvent(event)
    }
    private func receiveEvent(_ event: CB08SDKEvent) {
        let cmd = event.command, state = event.state, data = event.data
        guard cmd == 1 || cmd == 2 || connected else { return }
        if cmd == 1 && !isScanning { return }
        eventSummary = "cmd=\(String(cmd)), state=\(state.map(String.init) ?? "?")"
        guard state == 0 else {
            status = "设备返回异常状态"
            if cmd == 3 { pendingAction = nil; actionSummary = eventSummary }
            noteDevice("设备异常 \(eventSummary)"); return
        }
        guard cmd == 1 || cmd == 2 || connected else { return }
        switch cmd {
        case 1:
            if isScanning, let name = data["name"] as? String, let address = data["address"] as? String {
                guard name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("CB08") else { return }
                let item = CB08Device(name: name, address: address, productType: String(describing: data["productType"] ?? ""))
                if !devices.contains(where: { $0.id == item.id }) {
                    devices.append(item)
                    if selectedDevice == nil { selectedDeviceID = item.id }
                }
            }
        case 2:
            guard let observed = integer(data["connect_state"]) else { status = "连接状态未知"; return }
            guard observed == 0 || observed == 1 else { status = "连接状态未知"; return }
            let phase: CB08ConnectionPhase = observed == 1 ? .connected : .disconnected
            if connected == (observed == 1), connectionPhase == phase { return }
            connectionSummary = "cmd=2, connect_state=\(observed)"
            noteDevice(connectionSummary)
            if connectionPhase == .disconnecting && observed == 1 {
                noteDevice("断开中收到连接通知，继续等待断开确认"); return
            }
            connectionTimeout?.cancel()
            let wasConnected = connected
            if observed == 1 {
                if !connected || connectionID == nil { connectionID = UUID(); resetDeviceFacts() }
            } else { connectionID = nil }
            connected = observed == 1; connectionPhase = connected ? .connected : .disconnected
            status = connected ? "已连接，等待刷新状态" : "已断开"
            if connected {
                if !wasConnected { stopScan(); initializeConnection() }
            } else {
                hardwareIntent = nil; discardQueuedPackets(); resetDeviceFacts()
                if wasConnected { onLoss?() }
            }
        case 3:
            guard connected else { return }
            let previous = recordState
            let wasPending = pendingAction != nil
            let raw = integer(data["record_state"])
            switch raw { case 0: recordState = .stopped; case 1: recordState = .recording
            case 2: recordState = .paused; default: recordState = nil }
            let summary = "cmd=3, record_state=\(raw.map(String.init) ?? "?")"
            if actionSummary != summary { actionSummary = summary; noteDevice(summary) }
            if let action = pendingAction {
                let expected: CB08RecordingState = action == .stop ? .stopped : action == .pause ? .paused : .recording
                if recordState == expected {
                    confirmedActionRevision = actionRevision; pendingAction = nil
                    status = "设备动作已确认：\(expected.rawValue)"
                }
            }
            if let name = data["fileName"] as? String { currentFile = name }
            if !wasPending, let recordState, recordState != previous { onRecordingObservation?(recordState) }
        case 9:
            guard connected else { return }
            let previous = recordState
            recordQueryPending = false
            queryRevision += 1
            let raw = integer(data["recordState"])
            let summary = "cmd=9, recordState=\(raw.map(String.init) ?? "?")"
            let changed = querySummary != summary
            querySummary = summary
            // Query 2 only means inactive; preserve finer cmd=3 evidence in this connection.
            if raw == 1 { recordState = .recording }
            else if raw == 2 {
                if recordState != .paused && recordState != .stopped { recordState = .inactive }
            } else { recordState = nil }
            if changed { noteDevice(querySummary) }
            if pendingAction == nil, let recordState, recordState != previous { onRecordingObservation?(recordState) }
        case 6: battery = integer(data["cbc"])
        case 8:
            if let raw = integer(data["event"]), let action = CB08RecordAction(rawValue: raw) {
                hardwareButtonEvents[raw, default: 0] += 1
                hardwareSummary = "cmd=8, event=\(raw)（\(action.title)）"; noteDevice(hardwareSummary)
                guard hardwareIntent == nil else { status = "已有实体键动作待确认"; return }
                hardwareIntent = action
                if onHardware?(action) != true {
                    hardwareIntent = nil; status = "实体键动作不适用于当前会议"
                    noteDevice("实体键请求未获会议助手接受")
                } else { noteDevice("实体键请求已交会议助手，等待执行") }
            }
        case 11: currentFile = data["recordName"] as? String ?? "未知"
        case 10: deviceRecordingSeconds = integer(data["recordTime"])
        case 15: gain = integer(data["gain"])
        case 13: capacity = "\(data["residueSpace"] ?? "?") / \(data["totalSpace"] ?? "?")（SDK单位）"
        case 17: firmware = String(describing: data["version"] ?? "未知")
        case 22:
            let raw = integer(data["low_power_state"])
            lowPowerRecording = raw == 0 ? false : raw == 1 ? true : nil
        default: break
        }
    }
    private var nextPacketUpdate = Date.distantPast
    private func receivePacket(_ data: Data, lost: Int) {
        if lost > droppedPackets {
            droppedPackets = lost; status = "回调拥塞，已请求暂停"; onLoss?()
        }
        packetCount += 1; packetBytes += data.count
        if packetCount == 1 { noteDevice("首个实时Opus回调到达，\(data.count)字节") }
        packetSizes[data.count, default: 0] += 1
        onPacket?(data)
        if Date() >= nextPacketUpdate {
            nextPacketUpdate = Date().addingTimeInterval(0.5); telemetry.changed()
        }
    }
}
#if !targetEnvironment(simulator)
extension CB08SDKBridge: WindBleDelegate {
    nonisolated func deviceDataEvent(_ data: String) {
        guard let event = CB08SDKEvent.parse(data), eventFilter.accept(event, raw: data) else { return }
        Task { @MainActor [weak self] in self?.receiveEvent(event) }
    }
    nonisolated func deviceRecord(_ recordData: Data) {
        RuntimeActivity.add(.sdkPacket)
        guard let epoch = budget.reserve() else { return }
        let packet = Data(recordData)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let lost = self.budget.release()
            guard self.budget.current(epoch) else { return }
            self.receivePacket(packet, lost: lost)
        }
    }
    nonisolated func deviceFileData(_ fileData: Data) {}
    nonisolated func logInfo(_ log: String) {}
}
#endif
