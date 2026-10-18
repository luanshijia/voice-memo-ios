import Foundation

/// 状态层的第二层(L2):持有事实、算结论。
/// 规则正本:`notes/规范-状态显示.md`。本文件只放"值 → 结论"的纯逻辑,不碰 UI、不碰 IO。
///
/// 站 1 范围:`Cap.AppGroup` / `Link.Probe` / `Link.LiveKit` 三项。
/// 其余项(RepK、麦克风、数值、时效、配置、协议)随后续站点逐项加进来。

// MARK: - 值域

/// 期望:**只有发起动作的一方**能写(用户按了开启/停止、上层指令)。
enum LinkDesired: Equatable { case wanted, notWanted }

/// 链路实况:谁真正知道谁写。
enum LinkObserved: Equatable { case notStarted, connecting, connected, reconnecting, disconnected }

/// 能力实况:具备 / 不具备 / 不知道。
enum CapObserved: Equatable { case yes, no, unknownState }

/// 麦克风模式实况(值域独立:它不是"有没有",而是"哪一种")。
enum MicModeObserved: Equatable { case wide, other, unknownState }

// MARK: - 原因码(只发码,句子在显示层)

enum LinkReason: String, StatusReason {
    case notStarted = "Link.NotStarted"
    case connectFailed = "Link.ConnectFailed"
    case tokenRejected = "Link.TokenRejected"
    case disconnected = "Link.Disconnected"
    case bridgeFailed = "Link.BridgeFailed"
    case configMissing = "Link.ConfigMissing"
    case heartbeatStale = "Link.HeartbeatStale"
    case noAudioFrames = "Link.NoAudioFrames"
    case probeTimeout = "Link.ProbeTimeout"

    var code: String { rawValue }
}

enum CapReason: String, StatusReason {
    case permissionDenied = "Cap.PermissionDenied"
    case appGroupUnavailable = "Cap.AppGroupUnavailable"
    case extensionMissing = "Cap.ExtensionMissing"
    case configInvalid = "Cap.ConfigInvalid"
    case protocolLag = "Cap.ProtocolLag"

    var code: String { rawValue }
}

// MARK: - 面板(每一项一列,五列齐全)

struct StatusBoard {
    var appGroup = Status<LinkDesired, CapObserved, CapReason>(
        desired: .wanted, observed: .unknownState, reason: .appGroupUnavailable)
    var probe = Status<LinkDesired, LinkObserved, LinkReason>(
        desired: .wanted, observed: .notStarted)
    var livekit = Status<LinkDesired, LinkObserved, LinkReason>(
        desired: .notWanted, observed: .notStarted)

    // ---- 站 2:系统直播那一路 + 两项能力 + 扩展是否在包里 ----
    var replaykit = Status<LinkDesired, LinkObserved, LinkReason>(
        desired: .notWanted, observed: .notStarted)
    var micPermission = Status<LinkDesired, CapObserved, CapReason>(
        desired: .wanted, observed: .unknownState)
    var micMode = Status<LinkDesired, MicModeObserved, CapReason>(
        desired: .wanted, observed: .unknownState)
    var extensionEmbedded = Status<LinkDesired, CapObserved, CapReason>(
        desired: .wanted, observed: .unknownState)
}

// MARK: - 派生(纯函数:同一份事实,永远算出同一个结论)

extension StatusBoard {
    /// 项定义表 `Link.Probe`:每 15 秒探一次;45 秒没有新结果 ⇒ 观测不到(unknown)。
    /// 阈值只许这样声明在这里,不许散落到调用处。
    static let probeStaleAfter: TimeInterval = 45

    /// 链路类派生表(规范第四节):
    /// 期望"不要" → ok;期望"要" 且已连 → ok;要 且 断开 → 有原因=失败 / 无原因=未知;
    /// 要 且 未开始·连接中·重连中 → 未知;观测过期 → 未知;世代不符 → 未知。
    static func linkCondition(desired: LinkDesired,
                              observed: LinkObserved,
                              reason: LinkReason?,
                              lastSeen: Date,
                              generation: Int,
                              currentGeneration: Int,
                              staleAfter: TimeInterval?,
                              now: Date = Date()) -> Condition {
        guard generation == currentGeneration else { return .unknown }
        if let age = staleAfter, now.timeIntervalSince(lastSeen) > age { return .unknown }
        switch desired {
        case .notWanted:
            return .ok
        case .wanted:
            switch observed {
            case .connected:
                return .ok
            case .disconnected:
                return reason == nil ? .unknown : .failed
            case .notStarted, .connecting, .reconnecting:
                return .unknown
            }
        }
    }

    /// 能力类派生表:有 → ok;无 → 失败;不知道 → 未知。
    static func capabilityCondition(_ observed: CapObserved) -> Condition {
        switch observed {
        case .yes: return .ok
        case .no: return .failed
        case .unknownState: return .unknown
        }
    }

    // MARK: 当场算出结论(给影子对照与后续显示层用)

    func livekitCondition(currentGeneration: Int, now: Date = Date()) -> Condition {
        Self.linkCondition(desired: livekit.desired, observed: livekit.observed, reason: livekit.reason,
                           lastSeen: livekit.lastSeen, generation: livekit.generation,
                           currentGeneration: currentGeneration, staleAfter: nil, now: now)
    }

    func probeCondition(currentGeneration: Int, now: Date = Date()) -> Condition {
        Self.linkCondition(desired: probe.desired, observed: probe.observed, reason: probe.reason,
                           lastSeen: probe.lastSeen, generation: probe.generation,
                           currentGeneration: currentGeneration, staleAfter: Self.probeStaleAfter, now: now)
    }

    func appGroupCondition() -> Condition {
        Self.capabilityCondition(appGroup.observed)
    }

    // MARK: 站 2 的派生

    /// 项定义表 `Link.ReplayKit`:心跳 30 秒没动 = 观测不到;系统声 40 秒不涨 = 系统声那一路死了。
    /// 判定本身在 `BroadcastProbe`(它读日志);这里只声明"多久算过期",供派生与显示层共用。
    static let replaykitStaleAfter: TimeInterval = 30
    static let replaykitStallAfter: TimeInterval = 40

    func replaykitCondition(currentGeneration: Int, now: Date = Date()) -> Condition {
        Self.linkCondition(desired: replaykit.desired, observed: replaykit.observed, reason: replaykit.reason,
                           lastSeen: replaykit.lastSeen, generation: replaykit.generation,
                           currentGeneration: currentGeneration,
                           staleAfter: Self.replaykitStaleAfter, now: now)
    }

    func micPermissionCondition() -> Condition {
        Self.capabilityCondition(micPermission.observed)
    }

    /// 模式不是健康项:宽谱与其它都算"可用",只有"观测不到"才是 unknown。
    func micModeCondition() -> Condition {
        switch micMode.observed {
        case .wide, .other: return .ok
        case .unknownState: return .unknown
        }
    }

    func extensionCondition() -> Condition {
        Self.capabilityCondition(extensionEmbedded.observed)
    }
}

// MARK: - 结论的可读名(只给日志/影子用;正式文案属显示层)

extension Condition {
    var debugName: String {
        switch self {
        case .ok: return "ok"
        case .failed: return "failed"
        case .unknown: return "unknown"
        }
    }
}
