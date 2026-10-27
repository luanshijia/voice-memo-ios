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

enum CB08RecordAction: Int { case start = 1, stop = 3, pause = 5, resume = 7 }
@MainActor protocol CB08DeviceControlling: AnyObject {
    var connected: Bool { get }
    var connectionID: UUID? { get }
    var recordState: Int? { get }
    var onPacket: ((Data) -> Void)? { get set }
    var onLoss: (() -> Void)? { get set }
    func command(_ action: CB08RecordAction)
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
    private(set) var connectionID: UUID?
    @Published private(set) var status = "未连接"
    @Published private(set) var eventSummary = ""
    @Published private(set) var recordState: Int?
    @Published private(set) var battery: Int?
    @Published private(set) var firmware = "未知"
    @Published private(set) var capacity = "未知（SDK原始单位）"
    @Published private(set) var currentFile = "未知"
    @Published private(set) var packetCount = 0
    @Published private(set) var packetBytes = 0
    @Published private(set) var droppedPackets = 0
    @Published private(set) var packetSizes: [Int: Int] = [:]
    @Published private(set) var hardwareButtonEvents: [Int: Int] = [:]
    var onPacket: ((Data) -> Void)?
    var onLoss: (() -> Void)?
    var onHardware: ((CB08RecordAction) -> Bool)?
    private var hardwareIntent: CB08RecordAction?
    private var isScanning = false
    private let budget = CB08PacketBudget()
#if !targetEnvironment(simulator)
    private let node = PNode.shared()!
#endif
    override init() {
        super.init()
#if !targetEnvironment(simulator)
        node.delegate = self
        PNode.setShowLog(false)
        connected = node.isDeviceConnected()
        if connected { connectionID = UUID() }
#else
        status = "模拟器不支持CB08蓝牙，需真机验证"
#endif
    }
    func scan() {
        devices.removeAll(); isScanning = true; status = "扫描中"
#if !targetEnvironment(simulator)
        node.startSearch()
#else
        status = "模拟器不支持CB08蓝牙"
#endif
    }
    func stopScan() {
        isScanning = false
#if !targetEnvironment(simulator)
        node.stopSearch()
#endif
    }
    func connect(_ device: CB08Device) {
        stopScan(); hardwareIntent = nil; connectionID = nil; status = "正在连接CB08"
#if !targetEnvironment(simulator)
        node.connectDeviceAndAddress(device.name, device.address)
#endif
    }
    func disconnect() {
        stopScan(); hardwareIntent = nil; discardQueuedPackets(); connected = false; connectionID = nil; recordState = nil
        status = "已请求断开"; onLoss?()
#if !targetEnvironment(simulator)
        node.closeConnect()
#endif
    }
    func refreshStatus() {
        guard connected else { status = "未连接"; return }
#if !targetEnvironment(simulator)
        node.getCBC(); node.getDeviceVersion(); node.getRecordState(); node.getDeviceCapacity()
        node.getFileNameOnlyRecording()
#endif
        status = "已请求设备状态"
    }
    func cancelHardwareIntent(unless action: CB08RecordAction? = nil) {
        if hardwareIntent != action { hardwareIntent = nil }
    }
    func discardQueuedPackets() { budget.invalidate() }
    func command(_ action: CB08RecordAction) {
        guard connected else { return }
        let acknowledge = hardwareIntent == action
        hardwareIntent = nil
#if !targetEnvironment(simulator)
        switch (action, acknowledge) {
        case (.start, true): node.startBtnBackRecord()
        case (.stop, true): node.stopBtnBackRecord()
        case (.pause, true): node.pauseBtnBackRecord()
        case (.resume, true): node.continueBtnBackRecord()
        case (.start, false): node.startRecord()
        case (.stop, false): node.stopRecord()
        case (.pause, false): node.pauseRecord()
        case (.resume, false): node.continueRecord()
        }
#endif
        status = "已请求设备动作，等待状态回调"
    }
    func appState(foreground: Bool) {
#if !targetEnvironment(simulator)
        if connected { node.sendAppShowState(foreground ? 1 : 2) }
#endif
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
        guard state == 0 else { status = "设备返回异常状态"; return }
        switch cmd {
        case 1:
            if isScanning, let name = data["name"] as? String, let address = data["address"] as? String {
                let item = CB08Device(name: name, address: address, productType: String(describing: data["productType"] ?? ""))
                if !devices.contains(where: { $0.id == item.id }) { devices.append(item) }
            }
        case 2:
            guard let observed = integer(data["connect_state"]) else { status = "连接状态未知"; return }
            if observed == 1 {
                if !connected || connectionID == nil { connectionID = UUID() }
            } else { connectionID = nil }
            connected = observed == 1; hardwareIntent = nil; discardQueuedPackets(); recordState = nil
            status = connected ? "已连接，等待刷新状态" : "已断开"
            if connected { refreshStatus() } else { onLoss?() }
        case 3, 9:
            recordState = integer(data["record_state"] ?? data["recordState"])
            if let name = data["fileName"] as? String { currentFile = name }
        case 6: battery = integer(data["cbc"])
        case 8:
            if let raw = integer(data["event"]), let action = CB08RecordAction(rawValue: raw) {
                hardwareButtonEvents[raw, default: 0] += 1
                guard hardwareIntent == nil else { status = "已有实体键动作待确认"; return }
                hardwareIntent = action
                if onHardware?(action) != true { hardwareIntent = nil; status = "实体键动作不适用于当前会议" }
            }
        case 11: currentFile = data["recordName"] as? String ?? "未知"
        case 13: capacity = "\(data["residueSpace"] ?? "?") / \(data["totalSpace"] ?? "?")（SDK单位）"
        case 17: firmware = String(describing: data["version"] ?? "未知")
        default: break
        }
    }
    private func receivePacket(_ data: Data, lost: Int) {
        if lost > droppedPackets {
            droppedPackets = lost; status = "回调拥塞，已请求暂停"; onLoss?()
        }
        packetCount += 1; packetBytes += data.count
        packetSizes[data.count, default: 0] += 1
        onPacket?(data)
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
