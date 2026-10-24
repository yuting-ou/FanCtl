import Foundation

/// 自动 AI 优化的节奏与数据门槛（R90 从 FanModel.maybeAutoOptimize 下沉）。
/// 定时器/UserDefaults（lastAutoOptCheck 的写入）留在 FanModel，此处纯函数。
public enum AutoOptimizePolicy {

    /// 用户刚动过配置（5s 内）不打扰——那是他在回应操作，不是"自动"的时机。
    public static let userChangeCooldown: TimeInterval = 5

    /// 检查节流：1 小时至多一次。
    public static let recheckInterval: TimeInterval = 3600

    /// 数据门槛：上次优化后积累 ≥3 天新数据才值得再优化。
    public static let freshDataDays = 3

    /// 是否该跑一轮自动优化检查（开关开 + 曲线模式 + 两个冷却窗都过）。
    public static func shouldRun(enabled: Bool, modeIsCurve: Bool,
                                 sinceUserChange: TimeInterval,
                                 sinceLastCheck: TimeInterval) -> Bool {
        guard enabled, modeIsCurve else { return false }
        return sinceUserChange > userChangeCooldown && sinceLastCheck > recheckInterval
    }

    /// 检查之后是否真的执行优化：还没有基线（首次启用）或已积累足够新数据。
    public static func needsOptimize(hasBaseline: Bool, daysSinceBaseline: Int) -> Bool {
        !hasBaseline || daysSinceBaseline >= freshDataDays
    }
}
