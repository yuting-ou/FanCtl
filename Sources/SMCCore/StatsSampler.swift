import Foundation

// MARK: - 每日统计采样器（纯逻辑，守护进程与测试共用）
//
// 把"采样累计 + 跨天重置"从 fanctld 主循环抽出：跨天时返回前一天战报
// 供调用方归档，自身只管累计。归档落盘（archiveDay/saveStats）涉及文件 IO，
// 仍留在 daemon。

public struct StatsSampler {
    public private(set) var stats: DailyStats

    public init(stats: DailyStats) { self.stats = stats }

    public init(now: Date) {
        self.init(stats: DailyStats(date: DailyStats.dayString(for: now)))
    }

    /// 启动恢复：返回续用的采样器 + 需要归档的旧战报（如有）。
    /// 停机跨天场景（daemon 未在跨天时刻运行，主循环的归档没机会执行）：
    /// stats.json 里是昨天的数据，若直接丢弃则前一天战报永久丢失，
    /// 这里把它返回给调用方归档后再开新账。
    public static func restore(saved: DailyStats?, now: Date)
        -> (sampler: StatsSampler, toArchive: DailyStats?) {
        guard let s = saved, s.tempCount > 0 else { return (StatsSampler(now: now), nil) }
        if s.date == DailyStats.dayString(for: now) { return (StatsSampler(stats: s), nil) }
        return (StatsSampler(now: now), s)   // 旧日期 → 先归档
    }

    /// 计入一个采样点（温度、总转速、采样时长、功耗、是否发生显著调速）。
    /// 若与当前统计跨天：先把前一天战报返回给调用方归档，再以新日期开账；
    /// 返回值 nil 表示同一天。
    @discardableResult
    public mutating func record(temp: Double, totalRPM: Double,
                                seconds: Double, now: Date,
                                powerWatts: Double? = nil,
                                reason: ControlReason? = nil,
                                speedChange: Bool = false,
                                cyclingGuard: Bool = false) -> DailyStats? {
        let day = DailyStats.dayString(for: now)
        var archived: DailyStats? = nil
        if stats.date != day {
            archived = stats
            stats = DailyStats(date: day)
        }
        if temp > stats.maxTemp {
            stats.maxTemp = temp
            stats.maxTempAt = now
        }
        if temp >= 80 { stats.highTempSeconds += seconds }
        // v2.6.2:温度按秒加权累计(与直方图/avgPower 同一时间口径)。
        // 此前 tempSum 每拍 +temp、tempCount 每拍 +1,自适应间隔(1~20s)下
        // 均温被高频采样时段等权扭曲
        stats.tempSum += temp * seconds
        stats.tempCount += 1
        stats.tempSeconds += seconds
        // 温度分布直方图：AI 曲线优化的数据底座（按 2°C 桶累计秒数）
        stats.addTempSample(temp, seconds: seconds)
        stats.revolutions += totalRPM * seconds / 60
        // 功耗累计（散热退化趋势的数据底座；无功耗键的机型跳过）
        if let p = powerWatts, p.isFinite, p > 0.1, p < 1000 {
            stats.powerSum += p * seconds
            stats.powerCount += seconds
        }
        // 静音/安静档生效时长累计
        if reason == .quiet || reason == .night {
            stats.quietSeconds += seconds
        }
        // 显著调速计数（|输出Δ|≥3%，由调用方判定；风扇寿命代理指标）
        if speedChange { stats.speedChanges += 1 }
        // 启停循环抑制武装计数（v3.1：观察期核心指标，过高 → 需要预测式释放）
        if cyclingGuard { stats.aiCyclingGuards += 1 }
        return archived
    }
}
