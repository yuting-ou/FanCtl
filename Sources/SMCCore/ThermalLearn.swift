import Foundation

// MARK: - 热经验学习（纯本地数据驱动，落盘持久化）
//
// daemon 长期记录稳态下的 (温度, 实际输出) 对，学会"这台机器稳住每个温度
// 需要多大风量"。用途（全部服务于 AI 模式）：
//   - 起步/空闲夺回时的种子：直接从经验出发，不再从硬编码公式爬坡
//   - 升温前馈：温度抬头时把风扇一步拉到已学水平（"直接提升转速"），PD 再细调
//
// 采样纪律（由 daemon 把关）：只记温度平稳拍（变化 <0.35°/拍）且决策来自
// 基础模式（curve/ai/manual/battery）的样本——静音封顶/SSD 托底/兜底覆盖的拍
// 输出不反映该温度的真实热物理，记进去会污染经验。

public struct ThermalLearn: Equatable {
    public static let minSamples = 3        // 桶内样本数达标才采信
    private static let emaAlpha = 0.15      // EMA 系数：新样本权重（旧经验缓慢演化）
    private static let earlyAvgCount = 5    // 前 N 个样本算术平均，之后切换到 EMA
    private static let staleDays: Double = 14  // 超过 14 天未更新的桶视为过时
    // v3.4.5（3B）：高温单调化下限——查询温度 ≥75° 时查表结果与更低温度采信桶取 max。
    // 与 sanitize 的分工：sanitize 管 <75° 的低温高输出污染，单调化管 ≥75° 的高温低输出非单调。
    static let monotonicFloorTemp = 75.0

    public private(set) var outputByBucket: [Double]   // 每 2°C 桶学到的稳态输出
    public private(set) var samplesByBucket: [Int]     // 每桶样本数
    public private(set) var lastUpdatedByBucket: [Date] // 每桶最后更新时间（时间衰减用）
    // 同一温度在电池/外接电源、轻载/重载下所需风量不同。场景桶样本足够时优先使用，
    // 不足时回退到历史全局经验，兼顾隔离性与冷启动可用性。
    private var scenarioBuckets: [String: ScenarioBuckets]
    // v2.9 功耗分档滞回状态：PSTR ±2W 噪声会让稳态功耗在 15/35W 边界附近的机器
    // 逐拍翻转场景桶（采样被分流到两个半饥饿的桶、前馈随瞬时读数跳桶）。
    // 相邻档位切换需越过边界 ±2W 才生效；短暂丢读数（nil）不重置滞回。
    private var lastPowerBand: String? = nil

    private struct ScenarioBuckets: Codable, Equatable {
        var output: [Double]
        var samples: [Int]
        var updated: [Date]

        init() {
            output = [Double](repeating: 0, count: TempHistogram.bucketCount)
            samples = [Int](repeating: 0, count: TempHistogram.bucketCount)
            updated = [Date](repeating: .distantPast, count: TempHistogram.bucketCount)
        }

        var isValid: Bool {
            output.count == TempHistogram.bucketCount && samples.count == TempHistogram.bucketCount
                && updated.count == TempHistogram.bucketCount
        }
    }

    public init() {
        outputByBucket = [Double](repeating: 0, count: TempHistogram.bucketCount)
        samplesByBucket = [Int](repeating: 0, count: TempHistogram.bucketCount)
        lastUpdatedByBucket = [Date](repeating: .distantPast, count: TempHistogram.bucketCount)
        scenarioBuckets = [:]
    }

    public mutating func record(temp: Double, percent: Double) {
        let b = TempHistogram.bucketIndex(for: temp)
        // 防御 NaN/Inf：min(max(NaN, 0), 100) 在 Swift 中因 NaN 比较返回 false 而得到 0，
        // 但显式检查更清晰且不依赖隐式行为；理论上游调用方（controller.shape）已钳位，
        // 但学习数据污染后果严重（影响后续 AI 前馈），值得双重防御
        let p = percent.isFinite ? min(max(percent, 0), 100) : 0
        // 早期平均：前 5 个样本算术平均（降低首样本异常值的影响，加速收敛）
        // 之后切换到 EMA（机器老化/环境变化的缓慢适应靠这里）
        if samplesByBucket[b] < Self.earlyAvgCount {
            outputByBucket[b] = (outputByBucket[b] * Double(samplesByBucket[b]) + p) / Double(samplesByBucket[b] + 1)
        } else {
            outputByBucket[b] += Self.emaAlpha * (p - outputByBucket[b])
        }
        samplesByBucket[b] += 1
        lastUpdatedByBucket[b] = Date()
    }

    /// 按供电状态与功耗档记录经验；同时保留全局样本，以便新场景在样本不足时自然回退。
    public mutating func record(temp: Double, percent: Double, onBattery: Bool, powerWatts: Double?) {
        record(temp: temp, percent: percent)
        let key = currentScenarioKey(onBattery: onBattery, powerWatts: powerWatts)
        var buckets = scenarioBuckets[key] ?? ScenarioBuckets()
        let b = TempHistogram.bucketIndex(for: temp)
        let p = percent.isFinite ? min(max(percent, 0), 100) : 0
        if buckets.samples[b] < Self.earlyAvgCount {
            buckets.output[b] = (buckets.output[b] * Double(buckets.samples[b]) + p) / Double(buckets.samples[b] + 1)
        } else {
            buckets.output[b] += Self.emaAlpha * (p - buckets.output[b])
        }
        buckets.samples[b] += 1
        buckets.updated[b] = Date()
        scenarioBuckets[key] = buckets
    }

    // 温度 temp 处学到的稳态输出；数据不足返回 nil（调用方退回公式种子）。
    // 本桶样本够 → 直接用；否则取左右最近有数据的桶线性插值；只有一侧用该侧。
    // 插值比例用实际温度 temp 在 [tLo, tHi] 之间的位置计算（而非桶索引 b 的位置），
    // 因为 temp 可能在桶 b 内的任意位置（桶宽 2°C），用桶索引会引入最多 1°C 对应的
    // 插值偏差（在 4°C 区间上约 0.25 的 t 偏差，输出差可达 10%）。
    public func percent(for temp: Double) -> Double? {
        percent(for: temp, output: outputByBucket, samples: samplesByBucket)
    }

    /// v3.6（方向二·数据裁判）：单调包络健康度——高温段最大"包络值 − 原始 EMA 值"。
    /// >0 表示该桶的原始学习值仍低于更低温桶（3B 查表层在兜底修正），旧非单调数据
    /// 尚未被新样本洗净；→0 表示学习图已自愈。观察协议见 EVOLUTION.md（2-3 周收敛，
    /// 不收敛则做一次性数据修正——学习数据修正，不碰控制律）。
    /// 只统计 ≥monotonicFloorTemp 且有采信样本的桶；无数据返回 nil（App/fanprobe 隐藏）。
    public func envelopeGap() -> Double? {
        var worst: Double? = nil
        for b in 0..<outputByBucket.count where
            TempHistogram.midTemp(of: b) >= Self.monotonicFloorTemp && samplesByBucket[b] >= Self.minSamples {
            var lowerMax: Double = 0
            var hasLower = false
            for i in 0..<b where samplesByBucket[i] >= Self.minSamples {
                lowerMax = max(lowerMax, outputByBucket[i])
                hasLower = true
            }
            if hasLower {
                let gap = max(0, lowerMax - outputByBucket[b])
                worst = max(worst ?? 0, gap)
            }
        }
        return worst
    }

    /// 场景经验优先；一个场景尚未积累到采信样本数时回退为跨场景全局经验。
    public mutating func percent(for temp: Double, onBattery: Bool, powerWatts: Double?) -> Double? {
        if let buckets = scenarioBuckets[currentScenarioKey(onBattery: onBattery, powerWatts: powerWatts)],
           let learned = percent(for: temp, output: buckets.output, samples: buckets.samples) {
            return learned
        }
        return percent(for: temp)
    }

    private func percent(for temp: Double, output: [Double], samples: [Int]) -> Double? {
        let b = TempHistogram.bucketIndex(for: temp)
        var result: Double?
        if samples[b] >= Self.minSamples {
            result = output[b]
        } else {
            var lo = b - 1
            var hi = b + 1
            while lo >= 0 && samples[lo] < Self.minSamples { lo -= 1 }
            while hi < output.count && samples[hi] < Self.minSamples { hi += 1 }
            switch (lo >= 0, hi < output.count) {
            case (true, true):
                let tLo = TempHistogram.midTemp(of: lo)
                let tHi = TempHistogram.midTemp(of: hi)
                // tHi > tLo 恒成立（不同桶中值不同），无需除零保护
                let t = (temp - tLo) / (tHi - tLo)
                result = output[lo] + t * (output[hi] - output[lo])
            case (true, false): result = output[lo]
            case (false, true): result = output[hi]
            default: result = nil
            }
        }
        // v3.4.5（3B）：高温段（≥75°）单调化——先验只允许随温度不下降。
        // 真实学习图出现过 86°=74%、88°=62% 低于 82° 的 85%（瞬态采样污染），
        // 非单调先验在过冲区导致高温欠冷；向上取 max 方向安全（只多冷不过热）。
        // 与更低温度全部采信桶取运行最大值；<75° 区间不钳（sanitize 负责低温污染）。
        if let r = result, TempHistogram.midTemp(of: b) >= Self.monotonicFloorTemp {
            var envelope = r
            var i = b - 1
            while i >= 0 {
                if samples[i] >= Self.minSamples { envelope = max(envelope, output[i]) }
                i -= 1
            }
            result = envelope
        }
        return result
    }

    // MARK: 功耗分档（15/35W 边界带 2W 滞回，纯函数便于测试）

    private static let bandNames = ["light", "medium", "heavy"]

    /// 功耗 → 分档。previous 为上一拍档位：相邻档位切换需越过边界 ±2W 才生效
    /// （PSTR ±2W 噪声在边界附近的机器否则会逐拍翻转场景桶）；
    /// 跨档跳变（light↔heavy）必然远离边界，直接采纳；previous nil（冷启动）无滞回。
    public static func powerBand(for power: Double, previous: String?) -> String {
        let candidate: String
        if power < 15 {
            candidate = "light"
        } else if power < 35 {
            candidate = "medium"
        } else {
            candidate = "heavy"
        }
        guard let prev = previous, prev != candidate,
              let prevIdx = bandNames.firstIndex(of: prev),
              let candIdx = bandNames.firstIndex(of: candidate) else {
            return candidate
        }
        guard abs(prevIdx - candIdx) == 1 else { return candidate }
        let boundary: Double = min(prevIdx, candIdx) == 0 ? 15 : 35
        if abs(power - boundary) <= 2 { return prev }
        return candidate
    }

    // 场景键（带滞回状态更新；record 与 lookup 共用同一份档位跟踪）
    private mutating func currentScenarioKey(onBattery: Bool, powerWatts: Double?) -> String {
        let band: String
        if let pw = powerWatts, pw.isFinite, pw >= 0 {
            band = Self.powerBand(for: pw, previous: lastPowerBand)
            lastPowerBand = band
        } else {
            band = "unknown"   // 短暂丢读数不更新/不重置滞回状态
        }
        return "\(onBattery ? "battery" : "ac")-\(band)"
    }

    /// 测试辅助：手动设置某桶的最后更新时间（验证时间衰减用）
    public mutating func setLastUpdated(bucket: Int, date: Date) {
        guard bucket >= 0 && bucket < lastUpdatedByBucket.count else { return }
        lastUpdatedByBucket[bucket] = date
    }

    public var sampleTotal: Int { samplesByBucket.reduce(0, +) }

    // 已"学会"的温度桶数（样本达到采信阈值）——UI"已学 N 个温度点"展示此值；
    // sampleTotal 是样本总数（一个桶可攒几百条），不适合当"温度点"展示
    public var learnedBucketCount: Int {
        samplesByBucket.filter { $0 >= Self.minSamples }.count
    }

    /// 时间衰减：超过 staleDays 天未更新的桶，样本数减半。
    /// 物理依据：散热硅脂老化、环境温度变化、风扇积灰等因素会使"稳态需求"缓慢漂移。
    /// 长期未访问的温度桶（如夏天过后到冬天，不再触发 85°C 桶）保留旧数据无意义——
    /// 下次访问时环境已变，旧数据可能不准。样本减半让 EMA 更快适应新环境，
    /// 同时不完全清除（保留大致趋势作为起点）。
    /// 衰减后若样本数 < minSamples，percent(for:) 会退回插值或 nil，自然降级。
    /// v8：场景桶同样衰减——旧场景经验（含手动污染/旧 target 数据）此前永不衰减，
    /// 只要样本 ≥3 就优先于全局经验，持续带偏 AI 前馈。
    public mutating func decayStaleBuckets(now: Date = Date()) -> Int {
        var decayed = decay(global: &outputByBucket, samples: &samplesByBucket,
                            updated: lastUpdatedByBucket, now: now)
        for (key, var buckets) in scenarioBuckets {
            guard buckets.isValid else { continue }
            decayed += decay(global: &buckets.output, samples: &buckets.samples,
                             updated: buckets.updated, now: now)
            scenarioBuckets[key] = buckets
        }
        return decayed
    }

    private func decay(global output: inout [Double], samples: inout [Int],
                       updated: [Date], now: Date) -> Int {
        var decayed = 0
        let staleInterval = Self.staleDays * 86400
        for b in 0..<samples.count {
            guard samples[b] > 0 else { continue }
            if now.timeIntervalSince(updated[b]) > staleInterval {
                samples[b] /= 2
                if samples[b] < Self.minSamples {
                    output[b] = 0
                }
                decayed += 1
            }
        }
        return decayed
    }

    /// 清洗可疑的污染桶：低温桶但学到异常高输出。
    /// 污染来源：
    ///   1. 历史手动模式散热测试（已从采样白名单移除 .manual，但旧数据仍在）
    ///   2. shapedBase 限速过渡态被误学为稳态需求（已改为记录 baseTarget，但旧数据仍在）
    ///   3. aiTargetTemp 变化后旧数据失效（v2.9 起目标变化不再清表——静态映射与目标无关）
    /// 物理判据（基于 Apple Silicon 热设计，隐含 25°C 室温假设）：
    ///   <60°C：闲置温度，不需要 >30% 风量
    ///   <70°C：轻度负载，不需要 >50% 风量
    ///   <75°C：中度负载，不需要 >80% 风量
    /// v2.9：阈值随环境修正（slack = envOff × 4，上限 +32）——热带/夏季重载下
    /// 65°/55% 是合法物理，旧判据会在每次启动时把它清零重学，学习永远无法稳定。
    /// 修正后仍能抓住真污染（如 60°/100%：修正后阈值 62 也远够不着 100）。
    /// v8：场景桶同样清洗（此前只清洗全局桶）。
    public mutating func sanitizeCorruptedBuckets(envTemp: Double? = nil) -> Int {
        let slack: Double
        if let env = envTemp, env.isFinite {
            slack = max(0, FanPipeline.envOffset(envTemp: env, enabled: true)) * 4
        } else {
            slack = 0
        }
        var cleaned = sanitize(global: &outputByBucket, samples: &samplesByBucket, slack: slack)
        for (key, var buckets) in scenarioBuckets {
            guard buckets.isValid else { continue }
            cleaned += sanitize(global: &buckets.output, samples: &buckets.samples, slack: slack)
            scenarioBuckets[key] = buckets
        }
        return cleaned
    }

    private func sanitize(global output: inout [Double], samples: inout [Int], slack: Double) -> Int {
        var cleaned = 0
        for b in 0..<output.count {
            let temp = TempHistogram.midTemp(of: b)
            guard samples[b] >= Self.minSamples else { continue }
            let maxAllowed: Double
            if temp < 60 {
                maxAllowed = 30 + slack
            } else if temp < 70 {
                maxAllowed = 50 + slack
            } else if temp < 75 {
                // <75 桶 slack 减半：满 slack 下阈值可达 100，危急区间真污染全漏
                maxAllowed = 80 + slack * 0.5
            } else {
                continue
            }
            if output[b] > maxAllowed {
                output[b] = 0
                samples[b] = 0
                cleaned += 1
            }
        }
        return cleaned
    }
}

// MARK: - Codable（向后兼容：旧版本无 lastUpdatedByBucket 字段）

extension ThermalLearn: Codable {
    private enum CodingKeys: String, CodingKey {
        case outputByBucket, samplesByBucket, lastUpdatedByBucket, scenarioBuckets
        case lastPowerBand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputByBucket = try c.decode([Double].self, forKey: .outputByBucket)
        samplesByBucket = try c.decode([Int].self, forKey: .samplesByBucket)
        // 向后兼容：旧版本没有 lastUpdatedByBucket 字段
        // 用 .distantPast 让 decayStaleBuckets 在下次启动时衰减旧数据
        if let dates = try c.decodeIfPresent([Date].self, forKey: .lastUpdatedByBucket),
           dates.count == TempHistogram.bucketCount {
            lastUpdatedByBucket = dates
        } else {
            lastUpdatedByBucket = [Date](repeating: .distantPast, count: TempHistogram.bucketCount)
        }
        // 防御：数组长度不一致时重置
        if outputByBucket.count != TempHistogram.bucketCount || samplesByBucket.count != TempHistogram.bucketCount {
            self = ThermalLearn()
            return
        }
        scenarioBuckets = (try c.decodeIfPresent([String: ScenarioBuckets].self, forKey: .scenarioBuckets) ?? [:])
            .filter { $0.value.isValid }
        lastPowerBand = try c.decodeIfPresent(String.self, forKey: .lastPowerBand)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outputByBucket, forKey: .outputByBucket)
        try c.encode(samplesByBucket, forKey: .samplesByBucket)
        try c.encode(lastUpdatedByBucket, forKey: .lastUpdatedByBucket)
        try c.encode(scenarioBuckets, forKey: .scenarioBuckets)
        try c.encodeIfPresent(lastPowerBand, forKey: .lastPowerBand)
    }
}

// MARK: - 持久化（与 config/status 同目录，卸载随目录一并清理）

extension ConfigStore {
    public static func loadLearn() -> ThermalLearn? {
        guard let data = try? Data(contentsOf: FanCtlPaths.learnFile) else { return nil }
        return try? JSONDecoder().decode(ThermalLearn.self, from: data)
    }

    @discardableResult
    public static func saveLearn(_ learn: ThermalLearn) -> Bool {
        guard let data = try? JSONEncoder().encode(learn) else { return false }
        do {
            try data.write(to: FanCtlPaths.learnFile, options: .atomic)
            return true
        } catch { return false }
    }

    public static func loadAIMetrics() -> AIControlMetrics? {
        guard let data = try? Data(contentsOf: FanCtlPaths.aiMetricsFile) else { return nil }
        return try? JSONDecoder().decode(AIControlMetrics.self, from: data)
    }

    @discardableResult
    public static func saveAIMetrics(_ metrics: AIControlMetrics) -> Bool {
        guard let data = try? JSONEncoder().encode(metrics) else { return false }
        do {
            try data.write(to: FanCtlPaths.aiMetricsFile, options: .atomic)
            return true
        } catch { return false }
    }
}
