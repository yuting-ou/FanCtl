import Foundation

/// v3.8 D 项 dt 账本的分桶（快拍/标称/长拍各一）。
/// 每个 AI 评测样本按实际拍长（record 里钳位后的 dt）落入唯一桶，累计
/// 样本数、时长与"实际生效的 |P|/|D| 增量"。
/// - P 项每秒贡献恒定（pDelta/dt = kP·error/3，与 dt 无关）→ 三桶的
///   pAbsSum/seconds 应近似相等，是账本自身的校准基线；明显不等 = 账本有 bug。
/// - D 项当前实现 dDelta = kD·clampedSlope·(1/dtNom)，其中 clampedSlope=slopeRate·dt
///   → dDelta = 3·kD·slopeRate（每拍与 dt 无关），但每秒贡献 = 3·kD·slopeRate/dt
///   ∝ 1/dt：1s 快拍的 D 推力是标称 3s 拍的 3 倍（R4 跳过项 1）。
///   dAbsSum/seconds 的快拍/标称比就是裁决所需的实测比值。
public struct DTermLedgerBucket: Codable, Equatable {
    public var samples: Int
    public var seconds: Double
    public var dAbsSum: Double   // Σ|实际生效的 dDelta|
    public var pAbsSum: Double   // Σ|实际生效的 pDelta|（P 每秒恒定 → 基线校准用）

    public init(samples: Int = 0, seconds: Double = 0, dAbsSum: Double = 0, pAbsSum: Double = 0) {
        self.samples = samples; self.seconds = seconds
        self.dAbsSum = dAbsSum; self.pAbsSum = pAbsSum
    }

    public static let empty = DTermLedgerBucket()

    public mutating func add(seconds dt: Double, dApplied: Double, pApplied: Double) {
        samples += 1
        self.seconds += dt
        dAbsSum += abs(dApplied)
        pAbsSum += abs(pApplied)
    }

    /// 每秒 |D| 贡献（无样本返回 nil，区别于"有样本但 D 全程死区"的 0）
    public var dRatePerSecond: Double? {
        seconds > 0 ? dAbsSum / seconds : nil
    }
    /// 每秒 |P| 贡献（基线，三桶应近似相等）
    public var pRatePerSecond: Double? {
        seconds > 0 ? pAbsSum / seconds : nil
    }

    // 读出侧钳位（P3 同源，模糊测试惯例）：手改/损坏 JSON 的合法有限巨值不得污染账本
    private enum CodingKeys: String, CodingKey { case samples, seconds, dAbsSum, pAbsSum }

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
    // v3.8 D 项 dt 账本（EVOLUTION R4 跳过项 1 / R8 预注册裁决）：
    // 按实际拍长分桶累计 |P|/|D| 生效增量，用于裁决 D 项 1/dtNom 语义漂移在
    // 真机上是否有实际影响。只记录不改控制律；Optional = 旧版 ai-metrics.json 无此字段。
    // 桶边界：快拍 <1.5s（温变 1s 轮询）/ 标称 1.5–4.5s（3s 标称拍）/ 长拍 >4.5s
    public var dtLedgerFast: DTermLedgerBucket?
    public var dtLedgerNominal: DTermLedgerBucket?
    public var dtLedgerSlow: DTermLedgerBucket?

    public init(targetTemp: Double, userTargetTemp: Double? = nil) {
        self.targetTemp = targetTemp; self.userTargetTemp = userTargetTemp
        self.activeSeconds = 0; self.sampleCount = 0
        self.temperatureSum = 0; self.temperatureSquaredSum = 0; self.peakTemp = 0
        self.maxOvershoot = 0; self.highTempSeconds = 0; self.outputSum = 0
        self.outputChangeCount = 0; self.outputChangeMagnitude = 0; self.lastOutput = nil
        self.updatedAt = Date()
        self.dtLedgerFast = nil; self.dtLedgerNominal = nil; self.dtLedgerSlow = nil
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
        // v3.8 dt 账本：桶内累积时对增量做有限性防御（坏值不入账，样本照记）
        let d = dDelta.flatMap { $0.isFinite ? $0 : 0 } ?? 0
        let pd = pDelta.flatMap { $0.isFinite ? $0 : 0 } ?? 0
        let bucket: DTermLedgerBucket.Key
        if dt < 1.5 { bucket = .fast } else if dt <= 4.5 { bucket = .nominal } else { bucket = .slow }
        switch bucket {
        case .fast:
            dtLedgerFast = (dtLedgerFast ?? .init()).adding(seconds: dt, d: d, p: pd)
        case .nominal:
            dtLedgerNominal = (dtLedgerNominal ?? .init()).adding(seconds: dt, d: d, p: pd)
        case .slow:
            dtLedgerSlow = (dtLedgerSlow ?? .init()).adding(seconds: dt, d: d, p: pd)
        }
    }

    public var averageTemp: Double { sampleCount > 0 ? temperatureSum / Double(sampleCount) : 0 }
    public var temperatureStdDev: Double {
        guard sampleCount > 0 else { return 0 }
        return sqrt(max(0, temperatureSquaredSum / Double(sampleCount) - averageTemp * averageTemp))
    }
    public var averageOutput: Double { sampleCount > 0 ? outputSum / Double(sampleCount) : 0 }
}

extension DTermLedgerBucket {
    enum Key { case fast, nominal, slow }

    func adding(seconds dt: Double, d: Double, p: Double) -> DTermLedgerBucket {
        var copy = self
        copy.add(seconds: dt, dApplied: d, pApplied: p)
        return copy
    }
}
