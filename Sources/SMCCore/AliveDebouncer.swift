import Foundation

/// v3.8（R4 跳过项 2 加固）：daemon 存活判定的宽限去抖。
/// rename 竞态/写中读取等单次失败会让 status.json 瞬时不可读或时间戳瞬时陈旧，
/// 旧实现单拍翻转到"未运行"→ UI 状态点闪烁 + 决策行清空再回填。
/// 语义：上线方向立即生效（重新看到活 daemon 应马上恢复，用户等着用它）；
/// 下线方向需连续 2 次死观测（12s 兜底轮询下 ≈ 额外 12s 延迟）——
/// 假"活"的代价只是多显示一轮旧数据，假"死"的代价是清空用户正看着的决策状态。
public struct AliveDebouncer: Equatable {
    /// 连续死观测达到该次数才宣布下线
    public static let deadThreshold = 2

    public private(set) var alive: Bool
    public private(set) var deadStreak = 0

    public init(initialAlive: Bool = false) { alive = initialAlive }

    /// 观测一拍（成功读到 status 且 age<30s = true；读失败或陈旧 = false），
    /// 返回去抖后的存活判定。
    @discardableResult
    public mutating func update(observedAlive: Bool) -> Bool {
        if observedAlive {
            deadStreak = 0
            alive = true
        } else {
            deadStreak = min(deadStreak + 1, Self.deadThreshold)   // 封顶防无界增长
            if deadStreak >= Self.deadThreshold { alive = false }
        }
        return alive
    }
}
