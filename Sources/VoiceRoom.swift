import Foundation
import CoreFoundation
import LiveKit

/// LiveKit 房间的薄封装:连/断、开关麦克风、把收到的文字回调出去。
/// 传输、加密(DTLS-SRTP)、断线重连、ICE 都由 SDK 负责 —— 这正是换到 WebRTC 的目的。
@MainActor
final class VoiceRoom: NSObject {
    private var room: Room?

    /// 主动断开的目标实例:自己断的那条连接,SDK 也会回调 didDisconnect·didFailToConnect,
    /// 以前那条回调会把状态从"已停止"改成"连接已断开"。按实例记,避免标志残留给下一次断开。
    private var intentionalTarget: ObjectIdentifier?

    var onState: ((String) -> Void)?
    var onNote: ((String) -> Void)?
    /// (类型 partial/final/summary, 说话人, 服务端已识别的音频秒数, 文字, 前面静了多久, 绝对时间戳)
    /// gap 为 nil = 服务端没测出来(比如刚重连);ts 为 0 = 老服务端没给。
    var onTranscript: ((String, String, Double, String, Double?, Double, [String: Any]) -> Void)?
    var onEnded: ((String) -> Void)?

    var isConnected: Bool { room?.connectionState == .connected }

    /// 传输层实况(只交值,不交句子)。`nil` = 当前没有房间对象。
    var connectionState: ConnectionState? { room?.connectionState }

    /// 这一代被动结束的原因码。主动性由上层"期望"决定,这里只报原因。
    var onEndReason: ((LinkReason) -> Void)?

    /// 收包层的结构性问题:JSON 坏(`parse`)、缺 type(`missing_type`)、topic 不符(`topic:x`)、
    /// 协议版本不认(`version:x`)。这些**不能静默丢掉** —— 它们与"家里多发了可选字段"是两回事。
    var onProtocolIssue: ((String) -> Void)?

    /// 往房间里发一条自己的数据消息(topic=stt,与 agent 回传同一条通道,可靠送达)。
    /// 用途:「实时总结」按钮点一次 → 请家里立刻出一段总结。
    func send(_ payload: [String: Any]) async {
        guard let room, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            // 2.17.0 的 API 是 publish(data:options:);reliable=true 保证这条请求不丢
            try await room.localParticipant.publish(data: data,
                                                    options: DataPublishOptions(topic: "stt", reliable: true))
        } catch {
            onNote?("发消息失败:\(error.localizedDescription)")
        }
    }

    @discardableResult
    func connect(url: String, token: String, identity: String) async throws -> Room {
        // token 由主 App 向家里现取(LiveKitConfig.requestToken),这里只管连
        let newRoom = Room()
        newRoom.add(delegate: self)
        self.room = newRoom
        onNote?("发起连接 \(url) 身份=\(identity)")
        do {
            try await newRoom.connect(url: url, token: token)
            try await newRoom.localParticipant.setMicrophone(enabled: true)
        } catch {
            // 连上一半失败(例如开麦被拒)也要把这条连接收干净:不留同身份影子
            await newRoom.disconnect()
            if room === newRoom { room = nil }
            throw error
        }
        onState?("已连上房间,麦克风已开")
        onNote?("已连接房间=\(newRoom.name) 参与者=\(newRoom.remoteParticipants.count)")
        return newRoom
    }

    /// 断开指定这一条连接。只清理自己:目标不是当前 `room` 时不动 `self.room`。
    /// 为什么必须传实例:旧连接任务迟到完成时若执行"断开当前房间",会把后来新建的会话断掉。
    func disconnect(_ target: Room) async {
        intentionalTarget = ObjectIdentifier(target)
        _ = try? await target.localParticipant.setMicrophone(enabled: false)
        await target.disconnect()
        if room === target { room = nil }
    }

    /// 断开当前连接(兜底入口,正常情况下都走 disconnect(_:))。
    func disconnectCurrent() async {
        guard let room else { return }
        onNote?("主动断开")
        await disconnect(room)
    }
}

extension VoiceRoom: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState,
                          from oldValue: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }   // 旧实例的回调不许改新会话状态
            self.onState?("连接状态:\(Self.describe(state))")
        }
    }

    nonisolated func room(_ room: Room, participant _: RemoteParticipant?, didReceiveData data: Data,
                          forTopic topic: String, encryptionType _: EncryptionType) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            // topic 是契约的一部分:只处理 stt,别的 topic 记一笔结构性问题,不当字幕。
            guard topic == "stt" else {
                self.onProtocolIssue?("topic:\(topic.isEmpty ? "(空)" : topic)")
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.onProtocolIssue?("parse")
                return
            }
            // 契约 §二:版本必须存在且为整数;v1/v2 都接受,v2 只多要求 session_id。
            guard let rawVersion = obj["schema_version"] else {
                self.onProtocolIssue?("missing_schema_version")
                return
            }
            // NSNumber.intValue 会把 2.5 截成 2、把 true 读成 1 ⇒ 必须显式判"整数字面值"。
            guard let version = VoiceRoom.strictInteger(rawVersion) else {
                self.onProtocolIssue?("invalid_schema_version")
                return
            }
            guard version == 1 || version == 2 else {
                self.onProtocolIssue?("version:\(version)")
                return
            }
            guard let type = obj["type"] as? String, !type.isEmpty else {
                self.onProtocolIssue?("missing_type")
                return
            }
            // 契约 §三:收包端必须按 type 校验全部必填字段与类型 ——
            // 缺字段/类型不对就记诊断并丢弃,不能默认成 ""/?/0/nil 继续往下处理。
            if let bad = VoiceRoom.fieldProblem(type: type, obj: obj) {
                self.onProtocolIssue?(bad)
                return
            }
            // v2:session_id 必填(是否属于本场由上层比对,这里只查存在性)
            if version == 2 {
                guard let sid = obj["session_id"] as? String, !sid.isEmpty else {
                    self.onProtocolIssue?("missing_session_id")
                    return
                }
            }
            // 走到这里字段已按契约校验过,不再用默认值兜底(以前的 ?? "" / ?? "?" / ?? 0 会掩盖协议错误)。
            let text = (obj["text"] as? String) ?? ""
            let who = (obj["who"] as? String) ?? ""
            let audioS = VoiceRoom.number(obj["audio_s"]) ?? 0
            let gap = VoiceRoom.number(obj["gap_s"])           // 契约:显式 null 或数字
            let ts = VoiceRoom.number(obj["ts"]) ?? 0
            self.onTranscript?(type, who, audioS, text, gap, ts, obj)
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            if self.consumeIntentionalDisconnect(room) { return }      // 自己停的,不算连接失败
            self.onEndReason?(.connectFailed)
            self.onEnded?("连接失败:" + (error?.description ?? "未知"))
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            if self.consumeIntentionalDisconnect(room) {               // 自己停的:只更新状态,别覆盖"已停止"
                self.onState?("已断开(主动停止)")
                return
            }
            self.onEndReason?(.disconnected)
            self.onEnded?(error.map { "连接断开:" + $0.description } ?? "连接已断开")
        }
    }

    // MARK: - 契约字段校验(§ 三)

    /// JSON 数字:排除 Bool(JSONSerialization 把 true/false 也包成 NSNumber)。
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// 严格整数:schema_version 只认整数字面值。
    /// 与电脑端 `contracts.py` 的 `type(v) is not int` 对齐:2.5 不能被 intValue 截成 2、
    /// 2.0 虽然数学上是整数但字面值是浮点,同样不算 integer、true 不能读成 1。
    static func strictInteger(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let t = String(cString: n.objCType)
        guard t != "d", t != "f" else { return nil }        // JSON 里的 2.0 / 2.5 落成 double
        let d = n.doubleValue
        // 只挡 NaN/Inf 和 double 已无法精确表示整数的区间(2^53)——这是表示能力边界,不是人为策略上限;
        // 电脑端 Python int 无上限,所以这里不设 1e6 之类的人为阈值。
        guard d.isFinite, d == d.rounded(), abs(d) <= 9_007_199_254_740_992 else { return nil }
        return Int(d)
    }

    private static func present(_ obj: [String: Any], _ k: String) -> Bool { obj.keys.contains(k) }

    /// 按 type 校验必填字段与类型(契约 §3.1–§3.4)。返回诊断码,nil = 合规。
    /// 码:missing_field:<name>(缺字段)/ invalid_field:<name>(类型不对);仅本地诊断,不上网线。
    static func fieldProblem(type: String, obj: [String: Any]) -> String? {
        func missing(_ k: String) -> String? { obj[k] == nil ? "missing_field:\(k)" : nil }
        func str(_ k: String) -> String? {
            if let m = missing(k) { return m }
            guard let v = obj[k] else { return nil }
            return v is String ? nil : "invalid_field:\(k)"
        }
        func num(_ k: String) -> String? {
            if let m = missing(k) { return m }
            return number(obj[k]) != nil ? nil : "invalid_field:\(k)"
        }
        func int(_ k: String) -> String? {
            if let m = missing(k) { return m }
            return strictInteger(obj[k]) != nil ? nil : "invalid_field:\(k)"
        }
        func numOrNull(_ k: String) -> String? {
            if let m = missing(k) { return m }
            if let v = obj[k], v is NSNull { return nil }
            return number(obj[k]) != nil ? nil : "invalid_field:\(k)"
        }
        // 非负 / 正数:与 contracts.py 的 `value[...] < 0` 检查一一对应
        func isNull(_ k: String) -> Bool { if let v = obj[k] { return v is NSNull }; return false }
        func nonNeg(_ k: String) -> String? {
            if let m = missing(k) { return m }
            guard let d = number(obj[k]) else { return "invalid_field:\(k)" }
            return d >= 0 ? nil : "invalid_field:\(k)"
        }
        func positive(_ k: String) -> String? {
            if let m = missing(k) { return m }
            guard let d = number(obj[k]) else { return "invalid_field:\(k)" }
            return d > 0 ? nil : "invalid_field:\(k)"
        }
        func oneOf(_ k: String, _ allowed: Set<String>) -> String? {
            if let m = missing(k) { return m }
            guard let s = obj[k] as? String else { return "invalid_field:\(k)" }
            return allowed.contains(s) ? nil : "invalid_field:\(k)"
        }
        // HH:mm,且 00–23 : 00–59(契约 §3.3;电脑端 contracts.py 同口径)
        func clockHM(_ k: String) -> String? {
            if let m = missing(k) { return m }
            guard let s = obj[k] as? String else { return "invalid_field:\(k)" }
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2 else { return "invalid_field:\(k)" }
            // 只认 ASCII 数字:Int("+1") 会是 1,而契约(和电脑端 \d{2})不接受 "+1" / " 1"
            func asciiDigits(_ t: Substring) -> Bool { t.allSatisfy { $0 >= "0" && $0 <= "9" } }
            guard asciiDigits(parts[0]), asciiDigits(parts[1]),
                  let h = Int(parts[0]), let m = Int(parts[1]),
                  h <= 23, m <= 59 else { return "invalid_field:\(k)" }
            return nil
        }
        switch type {
        case "partial":
            return str("who") ?? str("source") ?? str("text") ?? num("audio_s") ?? num("ts")
                ?? nonNeg("audio_s") ?? positive("ts")
        case "final":
            return str("who") ?? str("source") ?? str("text") ?? num("audio_s")
                ?? numOrNull("gap_s") ?? num("ts")
                ?? nonNeg("audio_s") ?? positive("ts")
                ?? (isNull("gap_s") ? nil : nonNeg("gap_s"))
        case "summary":
            // 注意:刻意不校验 code —— 电脑端在 build_message 里做白名单,
            // 注释写明是为了让 App 收包端保持前向兼容。本端遇到新码按未知处理、照常显示。
            return str("text") ?? str("clock") ?? num("ts") ?? int("unsupported")
                ?? clockHM("clock") ?? nonNeg("unsupported") ?? positive("ts")
        case "sumstatus":
            return str("mode") ?? str("code") ?? str("text") ?? int("chars")
                ?? numOrNull("next_in") ?? num("ts")
                ?? oneOf("mode", ["auto", "manual"]) ?? nonNeg("chars") ?? positive("ts")
                ?? (isNull("next_in") ? nil : nonNeg("next_in"))
        default:
            return nil       // 未知 type 交给上层(记未知类型),这里不重复判
        }
    }

    /// 取走"主动断开"标记:只对同一个 Room 实例有效,不留给下一次断开。
    private func consumeIntentionalDisconnect(_ target: Room) -> Bool {
        guard intentionalTarget == ObjectIdentifier(target) else { return false }
        intentionalTarget = nil
        return true
    }

    private static func describe(_ s: ConnectionState) -> String {
        switch s {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .disconnected: return "已断开"
        @unknown default: return String(describing: s)
        }
    }
}
