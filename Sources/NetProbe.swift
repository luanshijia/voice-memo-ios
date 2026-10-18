import Foundation
import Network

/// 「网络」按钮的判据:能不能连上家里那条链路。
/// 做法:直接用 TCP 连一下配置里的主机(ws://100.64.0.2:7880 → 100.64.0.2:7880)。
/// 为什么不用 http 请求:那会额外受 ATS/证书这些东西干扰,而我们只想回答
/// 「路通不通」这一个问题 —— TCP 能建起来就算通,3 秒建不起来就算不通。
enum NetProbe {
    static func check(host: String, port: UInt16, timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: false)
                return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var done = false
            let finish: (Bool) -> Void = { ok in
                lock.lock()
                if done { lock.unlock(); return }
                done = true
                lock.unlock()
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)                       // 连上了 = 通
                case .failed, .cancelled: finish(false)         // 明确失败 = 不通
                default: break                                  // 还在连
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// 从设置页里的 ws://100.64.0.2:7443 取出主机和端口
    static func hostPort(from serverURL: String) -> (host: String, port: UInt16)? {
        guard let comps = URLComponents(string: serverURL), let host = comps.host else { return nil }
        // 缺端口时不能落回 7880:真正连的是 7443(TLS 代理),探 7880 会给出"网络灯断但录音正常"的假象。
        let fallback = URLComponents(string: LiveKitConfig.defaultURL)?.port ?? 7443
        // UInt16(Int) 越界会直接崩:设置页里把端口写成 99999 这种就是在下次启动时闪退
        guard let port = UInt16(exactly: comps.port ?? fallback) else { return nil }
        return (host, port)
    }
}
