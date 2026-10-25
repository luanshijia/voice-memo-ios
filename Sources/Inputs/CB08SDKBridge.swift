#if CB08_PROBE
import Foundation
import Combine
import CB08SDK

struct CB08Device: Identifiable, Equatable {
    let name: String
    let address: String
    let productType: String
    var id: String { address }
}

@MainActor
final class CB08SDKBridge: NSObject, ObservableObject {
    @Published private(set) var devices: [CB08Device] = []
    @Published private(set) var connected = false
    @Published private(set) var status = "未连接"
    @Published private(set) var eventSummary = ""
    @Published private(set) var packetCount = 0
    @Published private(set) var packetBytes = 0
    @Published private(set) var packetSizes: [Int: Int] = [:]
    @Published private(set) var latestPacket: Data?
    @Published private(set) var hardwareButtonEvents: [Int: Int] = [:]

    private let node = PNode.shared()!
    private var isScanning = false

    override init() {
        super.init()
        node.delegate = self
        PNode.setShowLog(false)
        connected = node.isDeviceConnected()
        status = connected ? "已连接" : "未连接"
    }

    func scan() {
        devices.removeAll()
        isScanning = true
        status = "扫描中"
        node.startSearch()
    }

    func stopScan() {
        isScanning = false
        node.stopSearch()
        if !connected { status = "未连接" }
    }

    func connect(_ device: CB08Device) {
        stopScan()
        status = "正在连接：\(device.name)"
        node.connectDeviceAndAddress(device.name, device.address)
    }

    func disconnect() {
        stopScan()
        node.closeConnect()
        connected = false
        status = "已请求断开"
    }

    func refreshStatus() {
        guard connected else { status = "未连接"; return }
        node.getCBC()
        node.getDeviceVersion()
        node.getRecordState()
        status = "已请求电量、固件、录音状态"
    }

    func startRecording() { node.startRecord(); status = "已请求开始录音" }
    func pauseRecording() { node.pauseRecord(); status = "已请求暂停录音" }
    func resumeRecording() { node.continueRecord(); status = "已请求继续录音" }
    func stopRecording() { node.stopRecord(); status = "已请求停止录音" }
    func appDidEnterForeground() { node.sendAppShowState(1) }
    func appDidEnterBackground() { node.sendAppShowState(2) }

    private func receiveEvent(_ text: String) {
        // Never retain raw SDK JSON: it can include the device address/serial.
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            eventSummary = "收到不可解析事件（内容已丢弃）"
            return
        }
        let cmd = String(describing: object["cmd"] ?? "?")
        let state = String(describing: object["state"] ?? "?")
        let payload = object["data"] as? [String: Any] ?? [:]
        eventSummary = "cmd=\(cmd), state=\(state)"
        if cmd == "1", state == "0", isScanning,
           let name = payload["name"] as? String,
           let address = payload["address"] as? String {
            let device = CB08Device(name: name, address: address,
                                    productType: payload["productType"] as? String ?? "")
            if !devices.contains(device) { devices.append(device) }
        } else if cmd == "2" {
            let connectionState = integerValue(payload["connect_state"])
            eventSummary = "cmd=2, state=\(state), connect_state=\(connectionState.map { String($0) } ?? "?")"
            if let connectionState {
                connected = (connectionState == 1)
                status = connected ? "已连接" : "已断开"
            } else {
                connected = node.isDeviceConnected()
                status = connected ? "已连接" : "连接事件缺少有效 connect_state"
            }
        } else if cmd == "8", let event = Int(String(describing: payload["event"] ?? "")) {
            hardwareButtonEvents[event, default: 0] += 1
            switch event {
            case 1: node.startBtnBackRecord(); status = "实体键请求开始，已确认"
            case 3: node.stopBtnBackRecord(); status = "实体键请求停止，已确认"
            case 5: node.pauseBtnBackRecord(); status = "实体键请求暂停，已确认"
            case 7: node.continueBtnBackRecord(); status = "实体键请求继续，已确认"
            default: status = "收到未知实体键事件 \(event)"
            }
        }
    }

    private func receivePacket(_ data: Data) {
        packetCount += 1
        packetBytes += data.count
        packetSizes[data.count, default: 0] += 1
        latestPacket = data
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

extension CB08SDKBridge: WindBleDelegate {
    nonisolated func deviceDataEvent(_ data: String) {
        Task { @MainActor [weak self] in self?.receiveEvent(data) }
    }

    nonisolated func deviceRecord(_ recordData: Data) {
        let packet = Data(recordData)
        Task { @MainActor [weak self] in self?.receivePacket(packet) }
    }

    nonisolated func deviceFileData(_ fileData: Data) { }

    nonisolated func logInfo(_ log: String) {
        // SDK logs may contain identifying data. Intentionally do not retain or print them.
    }
}
#endif
