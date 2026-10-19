import Foundation

/// 家里 LiveKit 的连接参数。
///
/// 会议启动由电脑总管统一发号与授权；App 不生成会议 UUID，也不持有 LiveKit 长期密钥。
struct LiveKitConfig {
    static let defaultURL = "wss://100.64.0.2:7443"   // 经本地 TLS 代理(ATS 要求 wss)
    static let defaultDevice = "iphone"               // C 口径:公开仓库里不写自己的设备名

    var url: String
    var device: String
    var userID: String
    var identity: String { device + "-livekit" }
    var broadcastIdentity: String { device + "-replaykit" }

    static func load() -> LiveKitConfig {
        let d = UserDefaults.standard
        return LiveKitConfig(url: d.string(forKey: "lk.url") ?? defaultURL,
                             device: d.string(forKey: "lk.device") ?? defaultDevice,
                             userID: d.string(forKey: "lk.user") ?? "owner")
    }

    func save() {
        let d = UserDefaults.standard
        d.set(url, forKey: "lk.url")
        d.set(device, forKey: "lk.device")
        d.set(userID, forKey: "lk.user")
        if let shared = MeetingControlClient.sharedDefaults() {
            shared.set(url, forKey: "lk.url")
            shared.set(device, forKey: "lk.device")
            shared.set(userID, forKey: "lk.user")
        }
        d.removeObject(forKey: "lk.key")        // 老版本留下的长期密钥:不再使用,清掉
        d.removeObject(forKey: "lk.secret")
    }

    typealias Token = MeetingGrant

    /// 向家里要一张卡。失败一律抛出 —— 调用方必须让用户看到"取卡失败",不能静默连不上。
    func requestToken(identity: String, ttl: Int = 15 * 60, channel: String? = nil) async throws -> Token {
        let resolvedChannel = channel ?? (identity == broadcastIdentity ? "system_audio" : "mic")
        return try await MeetingControlClient.requestGrant(serverURL: url, identity: identity,
                                                            userID: userID, deviceID: device,
                                                            channel: resolvedChannel, ttl: ttl)
    }

    /// 为广播扩展准备一张只发布用的卡,写进 App Group。
    /// 已经有一张 12 分钟内的卡就直接返回 —— 调用点是 3 秒一次的刷新循环,
    /// 每次都真去取会变成每 3 秒一次 TLS 请求 + 一次写盘(实测 3 分钟签了 21 次)。
    /// 原子写:扩展随时可能读,绝不能让它读到半个文件。
    @discardableResult
    func prepareBroadcastToken(force: Bool = false, session: String? = nil) async throws -> Bool {
        guard let container = BroadcastProbe.containerURL() else {
            throw Self.error(5, "App Group 不可用,扩展无法读取广播配置")
        }
        let target = container.appendingPathComponent("broadcast-livekit.json")
        let wantSession = session ?? ""
        if !force,
           let data = try? Data(contentsOf: target),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stamp = (obj["fetchedAt"] as? NSNumber)?.doubleValue,
           let ident = obj["identity"] as? String, ident == broadcastIdentity,
           Date().timeIntervalSince1970 - stamp < 12 * 60,
           (obj["token"] as? String)?.isEmpty == false,
           // 契约 §五:卡必须属于「本场」——录音中(有场次号)时,旧场的卡一律重取,
           // 否则扩展拿到的 JWT metadata 会带上一场的 UUID,两路就归不到同一场。
           wantSession.isEmpty || ((obj["session"] as? String) ?? "") == wantSession {
            return false                      // 卡还新鲜且属于本场,不打扰家里
        }
        let card = try await requestToken(identity: broadcastIdentity, ttl: 15 * 60, channel: "system_audio")
        try MeetingControlClient.storeBroadcastGrant(card)
        return true
    }

    enum BroadcastCardState {
        /// 没有卡文件(App Group 可用但还没取过卡)。
        case missing
        /// 有文件但读不出来(坏 JSON / 缺 fetchedAt / 空 token)。
        case unreadable
        /// 有卡,剩余可用秒数(按卡里记的 ttl 算,老卡缺 ttl 才退回 900)。
        case valid(remaining: TimeInterval)
    }

    /// 广播卡的四态观测:`missing / unreadable / valid(remaining)`。
    /// 以前只有一个 `remaining`,"没卡/读不到"和"已过期"都落在 0 上,结论因此把"看不见"说成"坏了"。
    /// 只读那张既有文件,不新增状态源。
    func broadcastCardState() -> BroadcastCardState {
        guard let container = BroadcastProbe.containerURL() else { return .missing }
        let target = container.appendingPathComponent("broadcast-livekit.json")
        guard FileManager.default.fileExists(atPath: target.path) else { return .missing }
        guard let data = try? Data(contentsOf: target),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = (obj["fetchedAt"] as? NSNumber)?.doubleValue,
              (obj["token"] as? String)?.isEmpty == false
        else { return .unreadable }
        let ttl = (obj["ttl"] as? NSNumber)?.doubleValue ?? 15 * 60
        let elapsed = Date().timeIntervalSince1970 - stamp
        return .valid(remaining: max(0, ttl - elapsed))
    }

    private static func error(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "VoiceMemo.Token", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
