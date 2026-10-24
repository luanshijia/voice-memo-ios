import Foundation
import Network

/// 「代理」按钮检测 XEdge 提供的点到点链路是否能到达家里的 TLS 入口。
/// 通过 TCP 探测配置地址的主机和端口；当前默认目标是 100.64.0.2:7443。
/// TCP 建立成功表示这条链路可达，不单独证明 LiveKit 房间或媒体流已连接。
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

    /// 从设置页的 TLS 入口地址中取出主机和端口；默认入口由 XEdge 点到点网络提供。
    static func hostPort(from serverURL: String) -> (host: String, port: UInt16)? {
        guard let comps = URLComponents(string: serverURL), let host = comps.host else { return nil }
        // 缺端口时不能落回 7880:真正连的是 7443(TLS 代理),探 7880 会给出"网络灯断但录音正常"的假象。
        let fallback = URLComponents(string: LiveKitConfig.defaultURL)?.port ?? 7443
        // UInt16(Int) 越界会直接崩:设置页里把端口写成 99999 这种就是在下次启动时闪退
        guard let port = UInt16(exactly: comps.port ?? fallback) else { return nil }
        return (host, port)
    }
}
