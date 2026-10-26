import Foundation

/// 状态层的第二层(L2):持有事实、算结论。
/// 规则正本:`notes/规范-状态显示.md`。本文件只放"值 → 结论"的纯逻辑,不碰 UI、不碰 IO。
///
/// 覆盖范围:`Cap.AppGroup`、`Link.Probe`、`Link.LiveKit`、`Cap.MicPermission`、`Cap.MicMode`、
/// `Metric.Recorded`/`Received`/`Progress`/`Summary(+Fresh/Round)`、`Cap.Config`、`Cap.Protocol`。
/// 旧注释曾写“只完成站 1”,已过期 —— 站 5(界面全量改读本文件的结论、删旧 `status` 字段)尚未完成。

// MARK: - 值域

/// 期望:**只有发起动作的一方**能写(用户按了开启/停止、上层指令)。
enum LinkDesired: Equatable { case wanted, notWanted }

/// 链路实况:谁真正知道谁写。
/// `unknown` = SDK 报了一个我们不认识的新态 —— 宁可说"不知道",也不能按"断开=失败"处理。
enum LinkObserved: Equatable { case notStarted, connecting, connected, reconnecting, disconnected, unknown }

/// 能力实况:具备 / 不具备 / 不知道。
enum CapObserved: Equatable { case yes, no, unknownState }

/// 麦克风模式实况(值域独立:它不是"有没有",而是"哪一种")。
enum MicModeObserved: Equatable { case wide, other, unknownState }

/// 数值实况:值 + 单位。它本身没有健康语义 —— 健康由"多久没更新"决定。
struct MetricValue: Equatable {
    var value: Double
    var unit: String
}

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

enum MetricReason: String, StatusReason {
    case noProgress = "Metric.NoProgress"
    case insufficient = "Metric.Insufficient"
    case quality = "Metric.Quality"
    case busy = "Metric.Busy"
    case noSession = "Metric.NoSession"

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

    // ---- 本机输入能力 ----
    var micPermission = Status<LinkDesired, CapObserved, CapReason>(
        desired: .wanted, observed: .unknownState)
    var micMode = Status<LinkDesired, MicModeObserved, CapReason>(
        desired: .wanted, observed: .unknownState)

    // ---- 站 3:数值三项(录 / 收 / 提要) ----
    var recorded = Status<LinkDesired, MetricValue, MetricReason>(
        desired: .wanted, observed: MetricValue(value: 0, unit: "秒"))
    var received = Status<LinkDesired, MetricValue, MetricReason>(
        desired: .wanted, observed: MetricValue(value: 0, unit: "秒"))
    var summary = Status<LinkDesired, MetricValue, MetricReason>(
        desired: .wanted, observed: MetricValue(value: 0, unit: "轮"))

    // ---- 站 4:两个"输入侧"能力 —— 配置是否可用、协议是否落后 ----
    var config = Status<LinkDesired, CapObserved, CapReason>(
        desired: .wanted, observed: .unknownState)
    var protocolLag = Status<LinkDesired, CapObserved, CapReason>(
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
            case .notStarted, .connecting, .reconnecting, .unknown:
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

    // MARK: 站 3 的派生

    /// 项定义表 `Metric.Progress`:家里每送来一条进度就刷新 `lastSeen`;
    /// 10 秒没有任何上报 ⇒ 这一路"看不见了"(unknown),而不是"坏了"(failed)。
    static let receivedStaleAfter: TimeInterval = 10
    /// 项定义表 `Metric.Summary`:家里每 60 秒推一次 sumstatus(哪怕这轮不出提要)。
    static let summaryStaleAfter: TimeInterval = 60
    /// 数值类派生:只看新鲜度。数值本身不判好坏 —— 判好坏是显示层的事。
    func metricCondition(_ status: Status<LinkDesired, MetricValue, MetricReason>,
                         staleAfter: TimeInterval, now: Date = Date()) -> Condition {
        now.timeIntervalSince(status.lastSeen) > staleAfter ? .unknown : .ok
    }

    func receivedCondition(currentGeneration: Int, now: Date = Date()) -> Condition {
        guard received.generation == currentGeneration else { return .unknown }
        return metricCondition(received, staleAfter: Self.receivedStaleAfter, now: now)
    }

    /// 提要有两个不同的问题,必须分开回答(Codex 2026-10-18 评审):
    ///   ① `summaryFreshCondition` —— 家里还在按时推 sumstatus 吗?(新鲜度)
    ///   ② `summaryRoundCondition` —— 这一轮到底出没出、为什么没出?(业务结果)
    /// 合成一个 Condition 会把"机器忙"说成健康、或把"信息量不足"说成故障。
    func summaryFreshCondition(now: Date = Date()) -> Condition {
        metricCondition(summary, staleAfter: Self.summaryStaleAfter, now: now)
    }

    func summaryRoundCondition() -> Condition {
        guard let reason = summary.reason else { return .ok }
        switch reason {
        case .busy:         return .unknown    // 机器忙:这轮暂时出不了,不是故障
        case .noProgress:   return .unknown
        case .noSession, .insufficient, .quality: return .ok   // 正常业务结论
        }
    }

    // MARK: 站 4 的派生(能力类,判据同 cap)

    func configCondition() -> Condition { Self.capabilityCondition(config.observed) }

    func protocolCondition() -> Condition { Self.capabilityCondition(protocolLag.observed) }
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
