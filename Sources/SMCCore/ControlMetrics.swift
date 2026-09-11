import Foundation

/// v3.8 D 项 dt 账本的分桶（快拍/标称/长拍各一）。
/// 每个 AI 评测样本按实际拍长（record 里钳位后的 dt）落入唯一桶，累计
/// 样本数、时长与"实际生效的 |P|/|D| 增量"。
/// - D 项当前实现 dDelta = kD·clampedSlope·(1/dtNom)，其中 clampedSlope=slope·dt
///   → dDelta = 3·kD·slopeRate（每拍与 dt 无关），但每秒贡献 = 3·kD·slopeRate/dt
///   ∝ 1/dt：1s 快拍的 D 推力是标称 3s 拍的 3 倍（R4 跳过项 1）。
///   dAbsSum/seconds 的快拍/标称比就是裁决所需的实测比值。
/// - 4.0.1（4.1-A3 规则修订）：原"P 每秒恒定 → 三桶校准线"前提被证伪——
///   pDelta = kP·clampedError·dtNom，每秒贡献 = kP·clampedError/3，桶间相等
///   ⟺ 平均 clampedError 相等，而快拍恰在 error 大的瞬态期触发（选择偏差）。
///   新增 slopeWeightedSum = Σ|slopeRate|·dt：把快拍/标称比拆成 dt 效应与
///   斜率选择效应两个因子（真机 7.28 ≈ 3×2.4），斜率归一化强度
///   I_D = dAbsSum/slopeWeightedSum 是裁决的诚实口径。P 校准线退役。
public struct DTermLedgerBucket: Codable, Equatable {
    public var samples: Int
    public var seconds: Double
    public var dAbsSum: Double   // Σ|实际生效的 dDelta|
    public var pAbsSum: Double   // Σ|实际生效的 pDelta|（4.0.1 起仅诊断用，不作校准线）
    // 4.0.1：Σ|slopeRate|·dt —— 斜率加权时长。选择偏差的量化器：
    // 原始比值 7.28 = (slopeRate 比)×(dt 比)，此字段把前者从后者中分离出来
    public var slopeWeightedSum: Double

    public init(samples: Int = 0, seconds: Double = 0, dAbsSum: Double = 0, pAbsSum: Double = 0,
                slopeWeightedSum: Double = 0) {
        self.samples = samples; self.seconds = seconds
        self.dAbsSum = dAbsSum; self.pAbsSum = pAbsSum
        self.slopeWeightedSum = slopeWeightedSum
    }

    public static let empty = DTermLedgerBucket()

    public mutating func add(seconds dt: Double, dApplied: Double, pApplied: Double,
                             slopeWeight: Double = 0) {
        samples += 1
        self.seconds += dt
        dAbsSum += abs(dApplied)
        pAbsSum += abs(pApplied)
        slopeWeightedSum += abs(slopeWeight)
    }

    /// 每秒 |D| 贡献（无样本返回 nil，区别于"有样本但 D 全程死区"的 0）
    public var dRatePerSecond: Double? {
        seconds > 0 ? dAbsSum / seconds : nil
    }
    /// 每秒 |P| 贡献（4.0.1 起仅诊断：桶间不等 = 选择偏差的预期表现，不再是 bug 信号）
    public var pRatePerSecond: Double? {
        seconds > 0 ? pAbsSum / seconds : nil
    }
    /// 斜率归一化 D 强度：每单位斜率加权的每秒推力。快/标称比 ≈ dt 比（当前律下
    /// 按构造 ≈3）；"改秒基"裁决看暴露度（快拍秒占比）+ VM 危害测试，不再看此比值
    public var dIntensity: Double? {
        slopeWeightedSum > 0 ? dAbsSum / slopeWeightedSum : nil
    }

    // 读出侧钳位（P3 同源，模糊测试惯例）：手改/损坏 JSON 的合法有限巨值不得污染账本
    private enum CodingKeys: String, CodingKey {
        case samples, seconds, dAbsSum, pAbsSum, slopeWeightedSum
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let clampD: (Double) -> Double = { v in
            (v.isFinite && v >= 0) ? min(v, 1e9) : 0
        }
        let rawSamples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 0
        self.samples = (rawSamples >= 0 && rawSamples <= 1_000_000_000) ? rawSamples : 0
        self.seconds = clampD(try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0)
        self.dAbsSum = clampD(try c.decodeIfPresent(Double.self, forKey: .dAbsSum) ?? 0)
        self.pAbsSum = clampD(try c.decodeIfPresent(Double.self, forKey: .pAbsSum) ?? 0)
        // 4.0.1 新字段：旧版账本（v3.8–4.0.0）无此字段 → 0（legacy 数据不参与斜率归一化口径）
        self.slopeWeightedSum = clampD(try c.decodeIfPresent(Double.self, forKey: .slopeWeightedSum) ?? 0)
    }
}

/// 4.0.1（4.1-A1）：dt 账本独立持久化状态。
/// 背景：账本原本挂在 AIControlMetrics 里，而评测指标在用户切换目标档位时整体
/// 重置（init 比对 + 运行中 aiMetricsUserTarget 漂移两处）→ 档位切换即清零陪葬，
/// "账本 ≥7 天"门槛按正常使用习惯可能永远不可达。账本度量的是控制律的 dt 语义，
/// 与用户目标无关 → 生命周期必须解耦：独立文件 + 无自动重置
/// （控制律结构变更时手动删除 dt-ledger.json，EVOLUTION 记账）。
public struct DTLedgerState: Codable, Equatable {
    public var fast: DTermLedgerBucket?
    public var nominal: DTermLedgerBucket?
    public var slow: DTermLedgerBucket?
    // 首个入账样本时刻（注入时钟，P7）——受控时长与墙钟两个口径换算的锚点
    public var startedAt: Date?

    public init(fast: DTermLedgerBucket? = nil, nominal: DTermLedgerBucket? = nil,
                slow: DTermLedgerBucket? = nil, startedAt: Date? = nil) {
        self.fast = fast; self.nominal = nominal; self.slow = slow
        self.startedAt = startedAt
    }

    public var isEmpty: Bool {
        fast == nil && nominal == nil && slow == nil
    }

    /// 受控总时长（秒）——A2 口径定版：预注册裁决门槛"账本 ≥7 天"以此为准
    ///（桶边界无缝 → 三桶 seconds 之和 = 全部受控拍时长）
    public var totalSeconds: Double {
        (fast?.seconds ?? 0) + (nominal?.seconds ?? 0) + (slow?.seconds ?? 0)
    }

    /// 快拍秒占比（预注册裁决的暴露度门槛：>5% 才有裁决资格）
    public var fastSecondsShare: Double? {
        let total = totalSeconds
        return total > 0 ? (fast?.seconds ?? 0) / total : nil
    }

    /// 与原 AIControlMetrics.record 完全同源的守卫/钳位/分桶（守卫失败不入账；
    /// dt 钳 [0,60]；<1.5s 快拍 / ≤4.5s 标称 / 其余长拍）。分桶逻辑与桶边界
    /// 是预注册口径，两处实现必须逐字一致——本函数是唯一实现，调用方不再自算。
    /// 斜率权重只认 D 项实际出力的拍（dDelta≠0）：死区拍/非 PD 拍 dDelta=0，
    /// 计入权重会把 I_D 稀释向 0——I_D 的语义是"每单位斜率加权的出力强度"，
    /// 权重与分子必须同源。同桶同 dt 时 I_D = 3kD/dt 恒成立（桶内 dt 混合时为加权均值）。
    public mutating func record(temp: Double, output: Double, seconds: Double,
                                dDelta: Double?, pDelta: Double?,
                                slopeRate: Double?, now: Date) {
        guard temp.isFinite, output.isFinite, seconds.isFinite, seconds > 0 else { return }
        let dt = min(seconds, 60)
        let d = dDelta.flatMap { $0.isFinite ? $0 : 0 } ?? 0
        let pd = pDelta.flatMap { $0.isFinite ? $0 : 0 } ?? 0
        let sw: Double?
        if let sr = slopeRate, sr.isFinite, d != 0 { sw = abs(sr) * dt } else { sw = nil }
        if startedAt == nil { startedAt = now }
        if dt < 1.5 {
            fast = (fast ?? .init()).adding(seconds: dt, d: d, p: pd, slopeWeight: sw ?? 0)
        } else if dt <= 4.5 {
            nominal = (nominal ?? .init()).adding(seconds: dt, d: d, p: pd, slopeWeight: sw ?? 0)
        } else {
            slow = (slow ?? .init()).adding(seconds: dt, d: d, p: pd, slopeWeight: sw ?? 0)
        }
    }
}

public struct AIControlMetrics: Codable, Equatable {
    public var targetTemp: Double
    // v2.9：用户设定的目标温度（持久化，跨启动比对用）。targetTemp 现在存的是
    // "有效目标"（环境/夜间/电池叠加后，随时间漂移），不能再用作"用户是否换档"的判据——
    // 否则夜间会话（有效目标 +4°）后每次重启都会误重置评测账本。
    public var userTargetTemp: Double?
    public var activeSeconds: Double
    public var sampleCount: Int
    public var temperatureSum: Double
    public var temperatureSquaredSum: Double
    public var peakTemp: Double
    public var maxOvershoot: Double
    public var highTempSeconds: Double
    public var outputSum: Double
    public var outputChangeCount: Int
    public var outputChangeMagnitude: Double
    public var lastOutput: Double?
    public var updatedAt: Date
    // 4.0.1（4.1-A1）：dt 账本已拆出为独立的 DTLedgerState（dt-ledger.json）。
    // 原挂载在本结构上（v3.8–4.0.0），用户切换目标档位触发评测指标整体重置时
    // 账本清零陪葬——"账本 ≥7 天"门槛结构性不可达。本结构不再持有账本字段；
    // 旧 ai-metrics.json 里的 dtLedger* 键由合成 Codable 自动忽略。

    public init(targetTemp: Double, userTargetTemp: Double? = nil) {
        self.targetTemp = targetTemp; self.userTargetTemp = userTargetTemp
        self.activeSeconds = 0; self.sampleCount = 0
        self.temperatureSum = 0; self.temperatureSquaredSum = 0; self.peakTemp = 0
        self.maxOvershoot = 0; self.highTempSeconds = 0; self.outputSum = 0
        self.outputChangeCount = 0; self.outputChangeMagnitude = 0; self.lastOutput = nil
        self.updatedAt = Date()
    }

    /// dDelta/pDelta：本拍实际生效的 P/D 增量（anti-windup 跳过时 pDelta 记 0）。
    /// nil = 该拍未走 PD 路径（首拍播种/空闲交还）——样本仍计入时长分布，增量记 0。
    public mutating func record(temp: Double, output: Double, seconds: Double,
                                dDelta: Double? = nil, pDelta: Double? = nil) {
        guard temp.isFinite, output.isFinite, seconds.isFinite, seconds > 0 else { return }
        let t = max(0, min(150, temp)), p = max(0, min(100, output)), dt = min(seconds, 60)
        activeSeconds += dt; sampleCount += 1; temperatureSum += t
        temperatureSquaredSum += t * t; peakTemp = max(peakTemp, t)
        maxOvershoot = max(maxOvershoot, t - targetTemp)
        if t >= targetTemp + 5 { highTempSeconds += dt }
        outputSum += p
        if let last = lastOutput, abs(p - last) >= 2 {
            outputChangeCount += 1; outputChangeMagnitude += abs(p - last)
        }
        lastOutput = p; updatedAt = Date()
    }

    public var averageTemp: Double { sampleCount > 0 ? temperatureSum / Double(sampleCount) : 0 }
    public var temperatureStdDev: Double {
        guard sampleCount > 0 else { return 0 }
        return sqrt(max(0, temperatureSquaredSum / Double(sampleCount) - averageTemp * averageTemp))
    }
    public var averageOutput: Double { sampleCount > 0 ? outputSum / Double(sampleCount) : 0 }
}

extension DTermLedgerBucket {
    func adding(seconds dt: Double, d: Double, p: Double, slopeWeight: Double = 0) -> DTermLedgerBucket {
        var copy = self
        copy.add(seconds: dt, dApplied: d, pApplied: p, slopeWeight: slopeWeight)
        return copy
    }
}
