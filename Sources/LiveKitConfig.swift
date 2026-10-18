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
    /// 已经有一张 12 分钟内的卡就直接返回 —— 调用点是 3 秒一次的刷新循环,
    /// 每次都真去取会变成每 3 秒一次 TLS 请求 + 一次写盘(实测 3 分钟签了 21 次)。
    /// 原子写:扩展随时可能读,绝不能让它读到半个文件。
    @discardableResult
    func prepareBroadcastToken(force: Bool = false) async throws -> Bool {
        guard let container = BroadcastProbe.containerURL() else {
            throw Self.error(5, "App Group 不可用,扩展无法读取广播配置")
        }
        let target = container.appendingPathComponent("broadcast-livekit.json")
        if !force,
           let data = try? Data(contentsOf: target),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stamp = (obj["fetchedAt"] as? NSNumber)?.doubleValue,
           let ident = obj["identity"] as? String, ident == broadcastIdentity,
           Date().timeIntervalSince1970 - stamp < 12 * 60,
           (obj["token"] as? String)?.isEmpty == false {
            return false                      // 卡还新鲜,不打扰家里
        }
        let card = try await requestToken(identity: broadcastIdentity, ttl: 15 * 60)
        let payload: [String: Any] = ["url": card.url,
                                      "identity": broadcastIdentity,
                                      "token": card.token,
                                      "fetchedAt": Date().timeIntervalSince1970]
        let out = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try out.write(to: target, options: .atomic)
        return true
    }

    /// 广播卡剩余可用秒数(卡 TTL 15 分钟,`fetchedAt` 就是写入时刻)。
    /// `nil` = 还没有卡 / App Group 读不到 —— 与"卡已过期"不是同一件事。
    /// 只读那张既有文件,不新增状态源。
    func broadcastCardRemaining() -> TimeInterval? {
        guard let container = BroadcastProbe.containerURL() else { return nil }
        let target = container.appendingPathComponent("broadcast-livekit.json")
        guard let data = try? Data(contentsOf: target),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = (obj["fetchedAt"] as? NSNumber)?.doubleValue,
              (obj["token"] as? String)?.isEmpty == false
        else { return nil }
        let elapsed = Date().timeIntervalSince1970 - stamp
        return max(0, 15 * 60 - elapsed)
    }

    private static func error(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "VoiceMemo.Token", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
