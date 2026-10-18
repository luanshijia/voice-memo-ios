import Foundation

/// 家里 LiveKit 的连接参数。
///
/// 2026-10-18 起:**App 不再内置 key/secret**。连接前先向家里要一张短期门禁卡
/// (`GET https://<host>:7443/token?identity=…&ttl=…`,默认 15 分钟)。
/// 签发口在 `server/lk_tls_proxy.py`:只接受白名单 IP,只发 `*-livekit` / `*-replaykit`,
/// 拒绝 `stt-agent` 这类服务身份。长期密钥只在服务器上(secrets/livekit.json,不进仓库)。
struct LiveKitConfig {
    static let defaultURL = "wss://100.64.0.2:7443"   // 经本地 TLS 代理(ATS 要求 wss)
    static let defaultDevice = "iphone"               // C 口径:公开仓库里不写自己的设备名

    var url: String
    var device: String
    var identity: String { device + "-livekit" }
    var broadcastIdentity: String { device + "-replaykit" }

    static func load() -> LiveKitConfig {
        let d = UserDefaults.standard
        return LiveKitConfig(url: d.string(forKey: "lk.url") ?? defaultURL,
                             device: d.string(forKey: "lk.device") ?? defaultDevice)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(url, forKey: "lk.url")
        d.set(device, forKey: "lk.device")
        d.removeObject(forKey: "lk.key")        // 老版本留下的长期密钥:不再使用,清掉
        d.removeObject(forKey: "lk.secret")
    }

    /// 门禁卡端点:`wss://host:port` → `https://host:port/token`。
    var tokenEndpoint: URL? {
        guard var comps = URLComponents(string: url) else { return nil }
        comps.scheme = (comps.scheme == "wss") ? "https" : "http"
        comps.path = "/token"
        comps.query = nil
        return comps.url
    }

    struct Token: Decodable {
        let url: String
        let token: String
        let identity: String?
        let ttl: Int?
    }

    /// 向家里要一张卡。失败一律抛出 —— 调用方必须让用户看到"取卡失败",不能静默连不上。
    func requestToken(identity: String, ttl: Int = 15 * 60) async throws -> Token {
        guard let endpoint = tokenEndpoint,
              var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw Self.error(2, "连接地址不合法:\(url)")
        }
        comps.queryItems = [URLQueryItem(name: "identity", value: identity),
                            URLQueryItem(name: "ttl", value: String(ttl))]
        guard let finalURL = comps.url else { throw Self.error(2, "取卡地址拼不出来") }
        var req = URLRequest(url: finalURL)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Self.error(3, "取卡没有响应") }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw Self.error(http.statusCode, "家里拒绝签发(\(http.statusCode))\(body.isEmpty ? "" : ":" + body)")
        }
        do {
            return try JSONDecoder().decode(Token.self, from: data)
        } catch {
            throw Self.error(4, "取卡回包解析失败:\(error.localizedDescription)")
        }
    }

    /// 为广播扩展准备一张只发布用的卡,写进 App Group。
    /// 原子写:扩展在 3 秒一次的轮询里随时可能读,绝不能让它读到半个文件。
    func prepareBroadcastToken() async throws {
        guard let container = BroadcastProbe.containerURL() else {
            throw Self.error(5, "App Group 不可用,扩展无法读取广播配置")
        }
        let card = try await requestToken(identity: broadcastIdentity, ttl: 15 * 60)
        let payload: [String: String] = ["url": card.url,
                                         "identity": broadcastIdentity,
                                         "token": card.token]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: container.appendingPathComponent("broadcast-livekit.json"), options: .atomic)
    }

    private static func error(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "VoiceMemo.Token", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
