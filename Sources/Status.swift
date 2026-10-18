import Foundation

/// 状态层的公共骨架 —— 规则正本见 `notes/规范-状态显示.md`。
///
/// 这一版**只提供类型骨架,不接线**:现有界面仍读旧字段,这里的东西暂时没有消费者。
/// 站 0.5 的唯一目的,是让 CI 证明这套写法在本工程(Swift 5 / iOS 17)编译得过。
///
/// 三条不许破的纪律:
///   1. 五列之外不许另立同义字段;同一事实不许两份副本。
///   2. 结论必须是**算**出来的(派生),不许存成可变字段。
///   3. `unknown` 不许并入 `failed` —— 观测不到 ≠ 观测到不满足。

// MARK: - 结论(三值)

enum Condition {
    /// 观测到满足。
    case ok
    /// 观测到不满足(明确失败、明确拒绝)。
    case failed
    /// 观测不到(心跳过期、日志缺失、还没测、推断中)。
    case unknown

    /// 聚合:一个项由多个子项合成时,按 failed > unknown > ok 取值。
    static func combine(_ items: Condition...) -> Condition {
        combine(items)
    }

    static func combine<S: Sequence>(_ items: S) -> Condition where S.Element == Condition {
        var sawUnknown = false
        for item in items {
            switch item {
            case .failed: return .failed
            case .unknown: sawUnknown = true
            case .ok: continue
            }
        }
        return sawUnknown ? .unknown : .ok
    }
}

// MARK: - 原因码

/// 原因只发码(`Link.ConnectFailed` 这种),不发句子、不发错误原文。
/// 句子与本地化由显示层按码查表生成;码表是唯一来源,新增原因必须先加行。
protocol StatusReason {
    var code: String { get }
}

// MARK: - 公共五列

/// 每一项可观测状态都摊成这五列,缺一列即违规。
struct Status<Desired, Observed, Reason: StatusReason> {
    /// 我们要它处于什么状态 —— 只有发起动作的一方(用户动作/上层指令)能写。
    var desired: Desired
    /// 它此刻真正到哪一步 —— 只有真正知道的那一方(SDK/探测器/系统)能写。
    var observed: Observed
    /// 为什么停在现在这一步:码。`nil` 表示不需要解释(正常态)。
    var reason: Reason?
    /// 这次观测的时刻(UTC)。
    var lastSeen: Date
    /// 这条观测属于第几代会话,用来丢弃上一代连接的迟到回写。
    var generation: Int

    init(desired: Desired,
         observed: Observed,
         reason: Reason? = nil,
         lastSeen: Date = Date(),
         generation: Int = 0) {
        self.desired = desired
        self.observed = observed
        self.reason = reason
        self.lastSeen = lastSeen
        self.generation = generation
    }

    /// 观测是否已过期。阈值(`staleAfter`)一律来自规范里的项定义表,不许在调用处写魔法数字。
    func isStale(_ staleAfter: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) > staleAfter
    }

    /// 这条观测是否属于当前这一代。
    func belongs(to currentGeneration: Int) -> Bool {
        generation == currentGeneration
    }
}

// MARK: - 证据(横切,不参与判定)

/// 原文留档:错误原文、日志行、扩展日志。只给设置页与日志,**不参与 `Condition` 的计算**。
struct StatusEvidence {
    var code: String?
    var text: String
    var at: Date

    init(code: String? = nil, text: String, at: Date = Date()) {
        self.code = code
        self.text = text
        self.at = at
    }
}
