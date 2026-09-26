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
    /// R55：门从 `tempCount > 0` 换成 `hasAccountedActivity`——旧门会让"温度整天不可用"的那本账
    /// 在重启时被整本丢掉（当天的调速次数就此消失），而 `archiveDay` 那边也已经不再收它。
    public static func restore(saved: DailyStats?, now: Date)
        -> (sampler: StatsSampler, toArchive: DailyStats?) {
        guard let s = saved, s.hasAccountedActivity else { return (StatsSampler(now: now), nil) }
        if s.date == DailyStats.dayString(for: now) { return (StatsSampler(stats: s), nil) }
        return (StatsSampler(now: now), s)   // 旧日期 → 先归档
    }

    /// 计入一个采样点（温度、总转速、采样时长、功耗、是否发生显著调速）。
    /// 若与当前统计跨天：先把前一天战报返回给调用方归档，再以新日期开账；
    /// 返回值 nil 表示同一天。
    ///
    /// R26：温度类累计（峰值/直方图/均温分母）只收物理合理读数
    /// （有限且 (0, 125]°C，与传感器发现层 1...120 同量级并留边界）。
    /// 真机战报曾出现 maxTemp≈101.9 的边角读数——控制路径 failsafe 用 rawTemp
    /// 另有红线，但曲线优化器吃 stats 分位数，坏点会直接污染学习底座。
    /// 门外跳过温度累计；功耗/转数/调速/循环抑制等计数照旧。
    @discardableResult
    public mutating func record(temp: Double, totalRPM: Double,
                                seconds: Double, now: Date,
                                powerWatts: Double? = nil,
                                reason: ControlReason? = nil,
                                speedChange: Bool = false,
                                cyclingGuard: Bool = false,
                                overshoot: Double? = nil,
                                envTemp: Double? = nil) -> DailyStats? {
        let day = DailyStats.dayString(for: now)
        var archived: DailyStats? = nil
        if stats.date != day {
            archived = stats
            stats = DailyStats(date: day)
        }
        if StatsSampler.tempPlausible(temp, envTemp: envTemp) {
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
        }
        // 功耗分布直方图（v3.3）：负载分布与曲线无关，优化器功耗锚定的数据底座
        stats.addPowerSample(powerWatts ?? 0, seconds: seconds)
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
        // 过冲峰值（v3.2：当日温度超出 AI 有效目标的最大值，τ 自适应的数据门槛）
        if let o = overshoot, o.isFinite, o > stats.overshootPeak { stats.overshootPeak = o }
        return archived
    }

    /// 战报温度采样是否物理合理（R26→R27）。
    /// - 有限且 (0, 125]°C（上界：真实硅温峰值可 >100，不把热峰当坏点）
    /// - 有环境参照时：不得比环境冷 12°C 以上（与控制路径偏低失真门同源）
    /// - 无环境参照时：temp < 15°C 视为失真（真机曾见 cpuDie≈8°C 而 GPU 正常）
    public static func tempPlausible(_ temp: Double, envTemp: Double? = nil) -> Bool {
        guard temp.isFinite, temp > 1.0, temp <= 125.0 else { return false }
        if let env = envTemp, env.isFinite, env > 5 {
            return temp >= env - 12
        }
        return temp >= 15
    }
}
