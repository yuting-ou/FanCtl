import Foundation

// MARK: - 风扇加速归因监视器（R82 续十）
//
// 背景（2026-10-03 实战）：风扇突然拉高时用户只能来问"什么东西在占用？"——
// 占用页显示的是**当下**，而加速瞬间的元凶可能已经退场。本监视器在 AI 输出
// 持续高位（或单拍急升）时触发一次归因采样，把"刚刚是谁在吃机器"留在界面上。
//
// 职责边界：只做**触发判定与文案**（纯逻辑，可测）；采样与展示由 App 侧接线
// （FanModel 复用 sampleCPUUsage，PanelView 渲染）。不改控制行为——归因是
// 旁路观察，绝不反作用于风扇。

public enum RampMonitor {
    /// 输出门：AI/曲线输出 ≥ 此值视为"风扇在高负荷工作"
    public static let outputGate: Double = 60
    /// 急升门：单拍涨幅 ≥ 此值（百分点）且输出 ≥ 50% 立即触发
    public static let riseGate: Double = 30
    /// 持续拍数门：连续 N 拍 ≥ outputGate 触发（拍距 = status 轮询周期）
    public static let beatsToTrigger = 3
    /// 冷却：两次归因至少隔 10 分钟——重负载工作时段不刷屏
    public static let cooldown: TimeInterval = 600
    /// 归因在界面上的保鲜期：过时自动隐藏（负载早变了，旧答案会误导）
    public static let freshWindow: TimeInterval = 900

    /// 每拍累计：输出 ≥ 门 +1，否则清零（连续性是"持续高负荷"的本意）
    public static func beat(applied: Double, beats: Int) -> Int {
        applied >= outputGate ? beats + 1 : 0
    }

    /// 急升判定：单拍涨 ≥ riseGate 个百分点且当下输出 ≥ 50%
    public static func isSteepRise(applied: Double, prev: Double) -> Bool {
        applied - prev >= riseGate && applied >= 50
    }

    /// 是否触发归因：持续达标或急升，且已过冷却期
    public static func shouldTrigger(beats: Int, steep: Bool,
                                     lastAttributionAt: Date?, now: Date) -> Bool {
        let sustained = beats >= beatsToTrigger
        guard sustained || steep else { return false }
        guard let last = lastAttributionAt else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }

    /// 归因文案：取前 3 名拼成「抖音（渲染进程） 94% · 聚焦索引 48%」样式。
    /// 四舍五入后不足 1% 的条目不显示（"A 0%"是噪音）；输入为空（采样失败/无
    /// 有效占用者）→ nil，界面不显示空行。
    public static func line(_ top: [(app: String, cpu: Double)]) -> String? {
        let shown = top.filter { $0.cpu.rounded() >= 1 }.prefix(3)
        guard !shown.isEmpty else { return nil }
        return shown.map { "\($0.app) \(Int($0.cpu.rounded()))%" }.joined(separator: " · ")
    }
}
