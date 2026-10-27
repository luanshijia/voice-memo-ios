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

@MainActor final class CB08SDKBridge: NSObject, ObservableObject, CB08DeviceControlling {
    @Published private(set) var devices: [CB08Device] = []
    @Published private(set) var connected = false
    @Published private(set) var connectionPhase: CB08ConnectionPhase = .disconnected
    @Published private(set) var isScanning = false
    @Published var selectedDeviceID: String?
    private(set) var connectionID: UUID?
    @Published private(set) var status = "未连接"
    @Published private(set) var eventSummary = ""
    @Published private(set) var recordState: CB08RecordingState?
    @Published private(set) var querySummary = "尚未查询"
    @Published private(set) var actionSummary = "尚无录音动作"
    @Published private(set) var hardwareSummary = "尚无实体键请求"
    @Published private(set) var connectionSummary = "尚无连接回调"
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var lowPowerRecording: Bool?
    @Published private(set) var gain: Int?
    @Published private(set) var deviceRecordingSeconds: Int?
    @Published private(set) var battery: Int?
    @Published private(set) var firmware = "未知"
    @Published private(set) var capacity = "未知（SDK原始单位）"
    @Published private(set) var currentFile = "未知"
    private(set) var packetCount = 0
    private(set) var packetBytes = 0
    private(set) var droppedPackets = 0
    private(set) var packetSizes: [Int: Int] = [:]
    @Published private(set) var hardwareButtonEvents: [Int: Int] = [:]
    var onPacket: ((Data) -> Void)?
    var onLoss: (() -> Void)?
    var onHardware: ((CB08RecordAction) -> Bool)?
    var onDiagnostic: ((String) -> Void)?
    private var hardwareIntent: CB08RecordAction?
    private var foreground = true
    private var queryRevision = 0
    private var recordQueryPending = false
    private var actionRevision = 0
    private var confirmedActionRevision = -1
    private var pendingAction: CB08RecordAction?
    private var connectionTimeout: Task<Void, Never>?
    private let budget = CB08PacketBudget()
#if !targetEnvironment(simulator)
    private var node: PNode?
#endif
    @Published private(set) var isSDKInitialized = false
    override init() { super.init() }
    /// Activation is explicit; constructing the phone workspace never starts Bluetooth.
    func activate() {
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
        activate()
        guard isSDKInitialized else { return }
        guard connectionPhase == .disconnected || connectionPhase == .unknown else { return }
        devices.removeAll(); isScanning = true; status = "扫描中"
#if !targetEnvironment(simulator)
        node?.startSearch()
#else
        status = "模拟器不支持CB08蓝牙"
#endif
    }
    func stopScan() {
        isScanning = false
#if !targetEnvironment(simulator)
        node?.stopSearch()
#endif
        if status == "扫描中" { status = "已停止扫描" }
    }
    var selectedDevice: CB08Device? { devices.first { $0.id == selectedDeviceID } }
    func connect(_ device: CB08Device) {
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
#if !targetEnvironment(simulator)
        if connected { node?.sendAppShowState(foreground ? 1 : 2) }
#endif
    }
    func noteDevice(_ message: String) {
        diagnostics.append("\(Date().formatted(date: .omitted, time: .standard)) \(message)")
        if diagnostics.count > 30 { diagnostics.removeFirst(diagnostics.count - 30) }
        onDiagnostic?(message)
    }
    private func resetDeviceFacts() {
        recordState = nil; battery = nil; firmware = "未知"; capacity = "未知（SDK原始单位）"
        currentFile = "未知"; gain = nil; lowPowerRecording = nil; deviceRecordingSeconds = nil
        pendingAction = nil; actionRevision += 1
        recordQueryPending = false
        querySummary = "尚未查询"; actionSummary = "尚无录音动作"
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
        guard let bytes = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        let cmd = integer(object["cmd"])
        let state = integer(object["state"])
        let data = object["data"] as? [String: Any] ?? [:]
        eventSummary = "cmd=\(cmd.map(String.init) ?? "?"), state=\(state.map(String.init) ?? "?")"
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
            let raw = integer(data["record_state"])
            switch raw { case 0: recordState = .stopped; case 1: recordState = .recording
            case 2: recordState = .paused; default: recordState = nil }
            actionSummary = "cmd=3, record_state=\(raw.map(String.init) ?? "?")"
            noteDevice(actionSummary)
            if let action = pendingAction {
                let expected: CB08RecordingState = action == .stop ? .stopped : action == .pause ? .paused : .recording
                if recordState == expected {
                    confirmedActionRevision = actionRevision; pendingAction = nil
                    status = "设备动作已确认：\(expected.rawValue)"
                }
            }
            if let name = data["fileName"] as? String { currentFile = name }
        case 9:
            guard connected else { return }
            recordQueryPending = false
            queryRevision += 1
            let raw = integer(data["recordState"])
            querySummary = "cmd=9, recordState=\(raw.map(String.init) ?? "?")"
            // Query 2 only means inactive; preserve finer cmd=3 evidence in this connection.
            if raw == 1 { recordState = .recording }
            else if raw == 2 {
                if recordState != .paused && recordState != .stopped { recordState = .inactive }
            } else { recordState = nil }
            noteDevice(querySummary)
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
            nextPacketUpdate = Date().addingTimeInterval(0.5); objectWillChange.send()
        }
    }
}
#if !targetEnvironment(simulator)
extension CB08SDKBridge: WindBleDelegate {
    nonisolated func deviceDataEvent(_ data: String) {
        Task { @MainActor [weak self] in self?.receiveEvent(data) }
    }
    nonisolated func deviceRecord(_ recordData: Data) {
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
