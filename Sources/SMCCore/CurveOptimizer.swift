import Foundation

// MARK: - AI 曲线优化器
// 纯本地数据驱动：不依赖网络与外部模型，用守护进程长期累计的温度分布
// 为“这台机器 + 这位用户的真实负载”定制风扇曲线。
//
// 思路：风扇曲线的本质是「温度分布 → 介入时机」的映射。
//   - 机器一半以上时间所处的温度区间（P50）→ 静音区，风扇保持最低转速
//   - 日常繁忙上限（P80）→ 轻度介入点
//   - 高负载区（P95）→ 加速压温点
//   - 历史峰值 → 全速点（始终在 92°C 硬兜底之前封顶）
//   - ≥80°C 时间占比 → 整条曲线的激进程度偏置
//
// 数据来源两级：
//   1. 直方图路径（精确）：DailyStats.tempHistogram 合并后算分位数
//   2. 聚合退化路径（兼容旧数据）：仅有均温/峰值时按经验比例估计分位数，
//      保证功能开箱即用，随着直方图积累自动变准
public enum CurveOptimizer {

    public struct Result {
        public let points: [CurvePoint]                      // 均衡个性化（自定义档底稿）
        public let presetCurves: [CurvePreset: [CurvePoint]] // 安静/均衡/强劲的个性化版本
        public let hotRatio: Double                          // 热压力（最近 7 天 ≥80°C 时间占比，
                                                             // 反漂移闸门与基线持久化的同一口径）
        public let summary: String   // 一行结论（面板内展示）
        public let detail: String    // 完整依据（tooltip 展示）
    }

    // 最少需要 30 分钟的有效采样，否则返回 nil（App 提示继续积累）
    private static let minSeconds = 30.0 * 60
    // 旧数据（无直方图）退化估算：自适应间隔前守护进程固定 3s 一拍
    private static let legacySampleInterval = 3.0

    // 某日的真实采样秒数：直方图直接求和（自适应间隔下精确），
    // 旧数据无直方图时用样本数 × 旧版固定间隔估算
    private static func daySeconds(_ d: DailyStats) -> Double {
        if let h = d.tempHistogram, h.count == TempHistogram.bucketCount {
            return h.reduce(0, +)
        }
        return d.tempCount * legacySampleInterval
    }

    public static func optimize(days: [DailyStats],
                                previous: [CurvePreset: [CurvePoint]]? = nil,
                                previousHotRatio: Double? = nil) -> Result? {
        let valid = days.filter { $0.tempCount > 0 }
        guard !valid.isEmpty else { return nil }

        // 合并全部直方图
        var merged = [Double](repeating: 0, count: TempHistogram.bucketCount)
        for d in valid {
            guard let h = d.tempHistogram, h.count == TempHistogram.bucketCount else { continue }
            for i in 0..<merged.count { merged[i] += h[i] }
        }
        let histSeconds = merged.reduce(0, +)

        let maxT = valid.map(\.maxTemp).max() ?? 0
        let totalCount = valid.reduce(0) { $0 + $1.tempCount }
        let hotSeconds = valid.reduce(0) { $0 + $1.highTempSeconds }
        let aggSeconds = valid.reduce(0) { $0 + daySeconds($1) }
        guard maxT > 1, totalCount > 0 else { return nil }

        let p50: Double, p80: Double, p95: Double
        let totalSeconds: Double
        let hotRatio: Double
        let precise: Bool
        // v2.9：热压力取最近 7 天窗口——反漂移闸门与 summary 同口径，且全历史累计
        // 会被稀释（历史越长"真变热"越难达到 +1pp 门槛，1.5° 分支形同虚设）
        let recentDays = Array(valid.suffix(7))
        if histSeconds >= minSeconds {
            // 直方图路径：真实分位数；高温占比也从直方图取（≥80°C 的桶），
            // 与分母同一时间窗——绝不能拿全天的 highTempSeconds 除直方图窗口秒数
            var p = percentile(merged, total: histSeconds, q: 0.50)
            // 直方图窗口若明显短于聚合窗口（功能刚上线/当天重启），
            // P50 会被“正在忙”的时段带偏；与全天均温按窗口占比加权，
            // 静音点随数据积累自动收敛到纯直方图值
            let avgAll = Self.weightedAvg(valid, fallbackCount: totalCount)
            if aggSeconds > histSeconds {
                let w = histSeconds / aggSeconds
                p = w * p + (1 - w) * avgAll
            }
            p50 = p
            p80 = percentile(merged, total: histSeconds, q: 0.80)
            p95 = percentile(merged, total: histSeconds, q: 0.95)
            let hotStart = TempHistogram.bucketIndex(for: 80)
            let histHotSeconds = merged[hotStart...].reduce(0, +)
            var recentHist = [Double](repeating: 0, count: TempHistogram.bucketCount)
            for d in recentDays {
                guard let h = d.tempHistogram, h.count == TempHistogram.bucketCount else { continue }
                for i in 0..<recentHist.count { recentHist[i] += h[i] }
            }
            let recentSeconds = recentHist.reduce(0, +)
            let recentHot = recentHist[hotStart...].reduce(0, +)
            // 近期窗口无直方图数据（旧数据为主）时回退全历史口径
            hotRatio = recentSeconds > 0 ? recentHot / recentSeconds : histHotSeconds / histSeconds
            totalSeconds = histSeconds
            precise = true
        } else if aggSeconds >= minSeconds {
            // 退化路径：用 均温→峰值 的经验比例近似分布（右偏分布的粗略拟合）
            let avg = Self.weightedAvg(valid, fallbackCount: totalCount)
            p50 = avg
            p80 = avg + 0.45 * (maxT - avg)
            p95 = avg + 0.75 * (maxT - avg)
            totalSeconds = aggSeconds
            let recentHotSeconds = recentDays.reduce(0.0) { $0 + $1.highTempSeconds }
            let recentTotal = recentDays.reduce(0.0) { $0 + $1.tempCount * legacySampleInterval }
            hotRatio = recentTotal > 0 ? recentHotSeconds / recentTotal : hotSeconds / totalSeconds
            precise = false
        } else {
            return nil
        }

        let curves = makeCurves(p50: p50, p80: p80, p95: p95,
                                maxT: maxT, hotRatio: hotRatio)
        // v2.9 反漂移：曲线改变温度分布，分布又决定下一条曲线（闭环自指）——
        // 无约束时静音锚单调下漂至 48° 下限（"自优化越用越吵"）。锚点下移
        // （更激进）按热压力门控限幅：≥80° 时间占比较上次应用上升 ≥1pp（真变热）
        // → 每周期最多 −1.5°；否则 −0.5°（真实 workload 变轻仍可缓慢下移）。
        // 上移不受限（机器变热自纠方向）。damp 后重新 shape 保证单调性不被破坏。
        // 热压力取最近 7 天窗口（v2.9）：与基线持久化同口径，且避免全历史累计
        // 稀释让"真变热"永远达不到 +1pp 门槛。
        let damped = Self.damp(curves: curves, previous: previous,
                               previousHotRatio: previousHotRatio, currentHotRatio: hotRatio)
        // 防御：基准曲线必须齐备 5 点，否则不返回（避免下游索引越界）
        guard let balanced = damped[.balanced], balanced.count == 5 else { return nil }

        let hours = totalSeconds / 3600
        let hoursText = hours >= 1 ? String(format: "%.1f 小时", hours) : "\(Int(totalSeconds / 60)) 分钟"
        let hotText = hotRatio >= 0.001 ? String(format: "%.1f%%", hotRatio * 100) : "几乎为 0"
        let summary = "AI 已定制：≤\(Int(balanced[0].temp))° 静音 · \(Int(balanced[2].temp))° 加速 · \(Int(balanced[4].temp))° 全速"
        let detail = """
        基于 \(valid.count) 天共 \(hoursText) 的使用数据\(precise ? "" : "（精确分布仍在积累，会越用越准）")：
        一半时间 ≤\(Int(p50))°C，95% 时间 ≤\(Int(p95))°C，历史峰值 \(Int(maxT))°C，近 7 天 ≥80°C 时间占 \(hotText)。
        安静/均衡/强劲三个预设已全部按本机分布个性化：安静更晚介入保低噪，强劲提前压温，均衡两者兼顾（92° 硬兜底不变）。
        """
        return Result(points: balanced, presetCurves: damped, hotRatio: hotRatio,
                      summary: summary, detail: detail)
    }

    // 反漂移限幅决策（纯函数）：热压力较上次应用上升 ≥1pp → 1.5°/周期（真变热），
    // 否则 0.5°/周期。previousHotRatio 缺失（升级残留/清理过偏好）按保守 0.5 处理
    // ——反漂移的保守方向是"少下移"，不能在基线不明时放宽。
    public static func anchorDropLimit(currentHotRatio: Double, previousHotRatio: Double?) -> Double {
        guard let prev = previousHotRatio else { return 0.5 }
        return currentHotRatio > prev + 0.01 ? 1.5 : 0.5
    }

    // 反漂移限幅（previous 为上次应用的曲线；首次应用 previous nil → 不限幅）
    private static func damp(curves: [CurvePreset: [CurvePoint]],
                             previous: [CurvePreset: [CurvePoint]]?,
                             previousHotRatio: Double?,
                             currentHotRatio: Double) -> [CurvePreset: [CurvePoint]] {
        guard let previous, !previous.isEmpty else { return curves }
        let maxDrop = anchorDropLimit(currentHotRatio: currentHotRatio, previousHotRatio: previousHotRatio)
        var result: [CurvePreset: [CurvePoint]] = [:]
        for (preset, pts) in curves {
            guard let prev = previous[preset], prev.count == pts.count, pts.count == 5 else {
                result[preset] = pts
                continue
            }
            let dampedTemps = pts.enumerated().map { (i, p) in
                max(p.temp, prev[i].temp - maxDrop)
            }
            let repaired = shape(dampedTemps)
            result[preset] = zip(repaired, pts.map { $0.percent })
                .map { CurvePoint(temp: $0.0, percent: $0.1) }
        }
        return result
    }

    // 时间加权平均温度：优先 tempSum/tempSeconds(v2.6.2 秒加权)；
    // 旧数据无 tempSeconds 时回退样本平均(tempSum 是每拍 +temp 的旧语义,除以样本数)
    private static func weightedAvg(_ days: [DailyStats], fallbackCount: Double) -> Double {
        let secs = days.reduce(0.0) { $0 + $1.tempSeconds }
        if secs > 0 {
            return days.reduce(0.0) { $0 + $1.tempSum } / secs
        }
        return days.reduce(0.0) { $0 + $1.tempSum } / fallbackCount
    }

    // 直方图分位数：找累计秒数过阈值的桶，桶内线性插值
    private static func percentile(_ hist: [Double], total: Double, q: Double) -> Double {
        let target = total * q
        var cum = 0.0
        for (i, s) in hist.enumerated() where s > 0 {
            if cum + s >= target {
                let lower = TempHistogram.lowerBound + Double(i) * TempHistogram.bucketWidth
                return lower + TempHistogram.bucketWidth * (target - cum) / s
            }
            cum += s
        }
        return TempHistogram.lowerBound + Double(TempHistogram.bucketCount) * TempHistogram.bucketWidth
    }

    // 分位数 + 热压力 → 基准锚点，再派生 安静/均衡/强劲 三种个性
    //（温度平移 ±3° + 转速阶梯按风格×热压力取值，保留各档“性格”）
    private static func makeCurves(p50: Double, p80: Double, p95: Double,
                                   maxT: Double, hotRatio: Double) -> [CurvePreset: [CurvePoint]] {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), max(lo, hi)) }

        // 基准锚点温度（均衡个性）
        var t = [Double](repeating: 0, count: 5)
        t[0] = clamp(p50 + 3, 48, 64)          // 静音区上限：盖住一半以上的日常时间
        t[1] = clamp(p80 + 2, t[0] + 4, 74)    // 轻度介入：日常繁忙上限之后
        t[2] = clamp(p95 + 1, t[1] + 4, 81)    // 加速压温：进入高负载区
        t[3] = clamp(maxT - 3, t[2] + 4, 86)   // 强力区：逼近历史峰值
        t[4] = clamp(maxT + 2, t[3] + 3, 89)   // 全速：峰值再往上一点，且早于 92° 兜底

        // 热压力分级
        enum Heat { case hot, normal, cool }
        let heat: Heat = hotRatio > 0.08 ? .hot : (hotRatio < 0.005 && maxT < 78 ? .cool : .normal)
        if heat == .hot {
            // 高温压力大（≥80° 超过 8% 时间）：整体左移
            for i in 1...4 { t[i] -= 3 }
        }
        if maxT >= 90 {
            // 爆发型机器：峰值曾逼近/超过 92° 兜底线，说明负载爆发时风扇追不上，
            // 强力区/全速点提前抢跑，赶在飙温前把风量拉起来
            t[3] = min(t[3], 81)
            t[4] = min(t[4], 85)
        }

        // 三种个性：安静右移 3°、强劲左移 3°；转速阶梯按 风格×热压力 取值
        let shift: [CurvePreset: Double] = [.quiet: 3, .balanced: 0, .aggressive: -3]
        let ladder: [CurvePreset: [Heat: [Double]]] = [
            .quiet:      [.hot: [0, 20, 45, 75, 100], .normal: [0, 12, 35, 65, 100], .cool: [0, 10, 30, 60, 100]],
            .balanced:   [.hot: [0, 25, 55, 82, 100], .normal: [0, 18, 45, 72, 100], .cool: [0, 14, 38, 68, 100]],
            .aggressive: [.hot: [0, 30, 62, 88, 100], .normal: [0, 25, 55, 82, 100], .cool: [0, 20, 48, 78, 100]],
        ]
        var result: [CurvePreset: [CurvePoint]] = [:]
        for (preset, d) in shift {
            let temps = shape(t.map { $0 + d })
            let pcts = ladder[preset]![heat]!
            result[preset] = zip(temps, pcts).map { CurvePoint(temp: $0, percent: $1) }
        }
        return result
    }

    // 排序与间距整形：正向保证递增间距，尾部封顶后反向回压，最后 0.5° 步进取整
    //（满足编辑器约束：温度递增≥1.5°、域内）
    private static func shape(_ temps: [Double]) -> [Double] {
        var t = temps
        t[0] = max(t[0], 46)
        for i in 1...4 { t[i] = max(t[i], t[i - 1] + 1.5) }
        t[4] = min(t[4], 90)
        for i in (0...3).reversed() { t[i] = min(t[i], t[i + 1] - 1.5) }
        return t.map { ($0 * 2).rounded() / 2 }
    }
}
