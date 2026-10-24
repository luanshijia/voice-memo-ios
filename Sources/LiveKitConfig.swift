import Foundation

/// 家里 LiveKit 的连接参数。
///
/// 会议启动由电脑总管统一发号与授权；App 不生成会议 UUID，也不持有 LiveKit 长期密钥。
struct LiveKitConfig {
    static let defaultURL = "wss://100.64.0.2:7443"   // 经本地 TLS 代理(ATS 要求 wss)

    /// 设备名与使用者默认值来自 Info.plist 的 VMDefaultDevice / VMDefaultUser。
    /// 源码里只留中性占位(C 口径:公开仓库不写自己的设备名),真值由 CI 打包时用
    /// Secrets 传入 build setting 注入 —— 值不落在代码里,只落在不签名的 IPA 里。
    static var defaultDevice: String { MeetingControlClient.defaultDeviceID }
    static var defaultUser: String { MeetingControlClient.defaultUserID }

    var url: String
    var device: String
    var userID: String
    var identity: String { device + "-livekit" }
    var broadcastIdentity: String { device + "-replaykit" }

    static func load() -> LiveKitConfig {
        let d = UserDefaults.standard
        return LiveKitConfig(url: d.string(forKey: "lk.url") ?? defaultURL,
                             device: d.string(forKey: "lk.device") ?? defaultDevice,
                             userID: d.string(forKey: "lk.user") ?? defaultUser)
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
    func requestToken(identity: String, ttl: Int = 15 * 60, channel: String? = nil,
                      meetingID: String? = nil) async throws -> Token {
        let resolvedChannel = channel ?? (identity == broadcastIdentity ? "system_audio" : "mic")
        return try await MeetingControlClient.requestGrant(serverURL: url, identity: identity,
                                                            userID: userID, deviceID: device,
                                                            channel: resolvedChannel,
                                                            meetingID: meetingID, ttl: ttl)
    }

}
