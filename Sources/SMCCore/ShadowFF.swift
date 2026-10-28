import Foundation

// MARK: - 影子前馈账本（第一性原理重构 Phase 1）
//
// 目的：在不改变任何控制行为的前提下，量化"稳态反解"这个前提是否成立：
//   u* = (env + a·P − T_ref) / b      ← ThermalModel.predictedPercentIncludingZero
// 与当前 AI 控制律在准稳态拍的实际施加输出（shapedBase 写扇成功后）逐样本比较。
//
// 为什么先量这个：当前 AI 的 PD 积分是主输出，热模型只当升温地板/首拍种子。
// 要把它升成"前馈主通道、PD 降为慢 trim"，必须先证明它在用户真实工况下够准；
// 否则替换等于拿机器做实验。
//
// 口径（v2，第二轮审查修正）：
//   - **主判据是模型@当前温度**：实际输出是"维持当前温度"的输出，候选也必须在
//     当前温度处反解，两者才是同一工作点。模型@目标只作新架构的设定点前馈参考，
//     它的残差含 (目标−当前)×增益 的工作点偏移，不能直接当模型误差。
//   - **不按目标 ±2° 筛样本**：现行 AI 经常在目标下方 5–10° 稳定（学习表把它压在
//     低位），±2° 窗恰好把这些最有信息量的稳态样本排除了。只要求 LearningGate
//     稳态门；温度/目标偏差记在 sumTempError 里，报告里明示。
//   - **候选在学习块之前冻结**：学习块会用本拍 baseTarget 更新学习表/热模型；
//     若影子在之后才查候选，候选被待评样本拟合，MAE/偏差系统性偏小（自拟合）。
//     候选（模型/查表 × 当前/目标）在 ControlEngine 的 AI 分支、学习块之前取好。
//   - 实际输出取写扇成功后的 appliedPercent（偏移前基础值，与学习/模型同域）；
//     全风扇读失败/写失败/故障试探拍不计。
//
// 只读承诺：本类型不持有控制器、不写 SMC、不更新任何控制状态；采样不可能改变
// 风扇行为。生命周期同 dt-ledger：跨启动累计，控制律/模型结构变更时手动删文件重攒。
// 分桶：功耗 5 档 × 目标 5 档 + overall，桶数固定，JSON 不随运行时长增长。

public struct ShadowFFBucket: Codable, Equatable {
    /// 一个候选量的配对统计：n / 均值 / MAE / 偏差（actual − candidate）。
    public struct Candidate: Codable, Equatable {
        public var samples: Int = 0
        public var sum: Double = 0
        public var sumAbsResidual: Double = 0
        public var sumResidual: Double = 0

        public init() {}

        public var mean: Double? { samples > 0 ? sum / Double(samples) : nil }
        public var mae: Double? { samples > 0 ? sumAbsResidual / Double(samples) : nil }
        public var bias: Double? { samples > 0 ? sumResidual / Double(samples) : nil }
        public func coverage(total: Int) -> Double? {
            total > 0 ? Double(samples) / Double(total) : nil
        }

        public mutating func add(_ value: Double?, actual: Double) {
            guard let v = value, v.isFinite, actual.isFinite else { return }
            samples += 1
            sum += v
            let residual = actual - v
            sumResidual += residual
            sumAbsResidual += abs(residual)
        }

        static func + (lhs: Candidate, rhs: Candidate) -> Candidate {
            var out = Candidate()
            out.samples = lhs.samples + rhs.samples
            out.sum = lhs.sum + rhs.sum
            out.sumAbsResidual = lhs.sumAbsResidual + rhs.sumAbsResidual
            out.sumResidual = lhs.sumResidual + rhs.sumResidual
            return out
        }

        private enum CodingKeys: String, CodingKey {
            case samples, sum, sumAbsResidual, sumResidual
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func count() -> Int {
                guard let v = (try? c.decodeIfPresent(Int.self, forKey: .samples)) ?? nil else { return 0 }
                return (v >= 0 && v <= 1_000_000_000) ? v : 0
            }
            func value(_ key: CodingKeys) -> Double {
                guard let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil,
                      v.isFinite else { return 0 }
                return max(-1e12, min(1e12, v))
            }
            samples = count()
            sum = value(.sum)
            sumAbsResidual = abs(value(.sumAbsResidual))
            sumResidual = value(.sumResidual)
        }
    }

    public var samples: Int = 0
    public var sumActual: Double = 0
    // 主判据：与实际输出同一工作点（当前温度）
    public var modelNow = Candidate()
    public var tableNow = Candidate()
    // 新架构设定点前馈参考：残差含工作点偏移，不参与主判读
    public var modelTarget = Candidate()
    public var tableTarget = Candidate()
    public var sumTempError: Double = 0
    public var sumPower: Double = 0
    public var sumTemp: Double = 0
    public var sumTarget: Double = 0
    public var sumEnv: Double = 0

    public init() {}

    public var meanActual: Double? { samples > 0 ? sumActual / Double(samples) : nil }
    public var meanTempError: Double? { samples > 0 ? sumTempError / Double(samples) : nil }
    public var meanTemp: Double? { samples > 0 ? sumTemp / Double(samples) : nil }
    public var meanTarget: Double? { samples > 0 ? sumTarget / Double(samples) : nil }
    public var meanPower: Double? { samples > 0 ? sumPower / Double(samples) : nil }
    public var meanEnv: Double? { samples > 0 ? sumEnv / Double(samples) : nil }

    public mutating func add(actual: Double, modelNow: Double?, tableNow: Double?,
                             modelTarget: Double?, tableTarget: Double?,
                             tempError: Double, power: Double, temp: Double,
                             target: Double, env: Double) {
        guard actual.isFinite else { return }
        samples += 1
        sumActual += actual
        sumTempError += tempError
        sumPower += power
        sumTemp += temp
        sumTarget += target
        sumEnv += env
        self.modelNow.add(modelNow, actual: actual)
        self.tableNow.add(tableNow, actual: actual)
        self.modelTarget.add(modelTarget, actual: actual)
        self.tableTarget.add(tableTarget, actual: actual)
    }

    static func + (lhs: ShadowFFBucket, rhs: ShadowFFBucket) -> ShadowFFBucket {
        var out = ShadowFFBucket()
        out.samples = lhs.samples + rhs.samples
        out.sumActual = lhs.sumActual + rhs.sumActual
        out.modelNow = lhs.modelNow + rhs.modelNow
        out.tableNow = lhs.tableNow + rhs.tableNow
        out.modelTarget = lhs.modelTarget + rhs.modelTarget
        out.tableTarget = lhs.tableTarget + rhs.tableTarget
        out.sumTempError = lhs.sumTempError + rhs.sumTempError
        out.sumPower = lhs.sumPower + rhs.sumPower
        out.sumTemp = lhs.sumTemp + rhs.sumTemp
        out.sumTarget = lhs.sumTarget + rhs.sumTarget
        out.sumEnv = lhs.sumEnv + rhs.sumEnv
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case samples, sumActual, modelNow, tableNow, modelTarget, tableTarget
        case sumTempError, sumPower, sumTemp, sumTarget, sumEnv
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count() -> Int {
            guard let v = (try? c.decodeIfPresent(Int.self, forKey: .samples)) ?? nil else { return 0 }
            return (v >= 0 && v <= 1_000_000_000) ? v : 0
        }
        func value(_ key: CodingKeys) -> Double {
            guard let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil,
                  v.isFinite else { return 0 }
            return max(-1e12, min(1e12, v))
        }
        samples = count()
        sumActual = value(.sumActual)
        modelNow = ((try? c.decodeIfPresent(Candidate.self, forKey: .modelNow)) ?? nil) ?? Candidate()
        tableNow = ((try? c.decodeIfPresent(Candidate.self, forKey: .tableNow)) ?? nil) ?? Candidate()
        modelTarget = ((try? c.decodeIfPresent(Candidate.self, forKey: .modelTarget)) ?? nil) ?? Candidate()
        tableTarget = ((try? c.decodeIfPresent(Candidate.self, forKey: .tableTarget)) ?? nil) ?? Candidate()
        sumTempError = value(.sumTempError)
        sumPower = value(.sumPower)
        sumTemp = value(.sumTemp)
        sumTarget = value(.sumTarget)
        sumEnv = value(.sumEnv)
    }
}

public struct ShadowFFLedger: Codable, Equatable {
    /// v2：主判据改为当前温度，候选四路（模型/查表 × 当前/目标）+ 学习前冻结。
    /// v1 的桶语义不同，读到旧版本直接空账本重攒（不混账）。
    public static let schemaVersion = 2
    public static let powerBandCount = 5
    public static let targetBandCount = 5
    public static let bucketCount = powerBandCount * targetBandCount
    public static let powerBandLabels = ["<15W", "15–35W", "35–60W", "60–90W", "≥90W"]
    public static let targetBandLabels = ["<70°", "70–74°", "74–78°", "78–82°", "≥82°"]
    /// Phase 1 预注册判读门槛（首次采集前定下，不随数据回头改）：
    /// **模型@当前**稳态 MAE ≤10%（输出百分比绝对误差）且覆盖率 ≥70%
    /// → 稳态反解可以作为前馈主通道的候选；否则先查 P 口径（PSTR 含充电/屏幕）、
    /// 环境估计、b(u) 非线性，再谈替换。
    public static let verdictMAE = 10.0
    public static let verdictCoverage = 0.7
    /// 判读最小样本量：n=1/2 的 MAE 可以碰巧达标，但不足以证明稳态反解可信。
    /// 30 个 3s 稳态拍 ≈ 90 秒连续受控，是"跑一次编译/渲染"就能达到的量级。
    public static let verdictMinSamples = 30

    public var version: Int = ShadowFFLedger.schemaVersion
    public var startedAt: Date?
    public var lastSampleAt: Date?
    public var considered: Int = 0
    public var invalidInputs: Int = 0
    public var missingInputs: Int = 0
    public var notSteady: Int = 0
    public var buckets: [ShadowFFBucket] = Array(repeating: ShadowFFBucket(),
                                                 count: ShadowFFLedger.bucketCount)
    public var overall: ShadowFFBucket = ShadowFFBucket()

    public init() {}

    public var recorded: Int { overall.samples }

    public static func powerBand(_ watts: Double) -> Int {
        if watts < 15 { return 0 }
        if watts < 35 { return 1 }
        if watts < 60 { return 2 }
        if watts < 90 { return 3 }
        return 4
    }

    public static func targetBand(_ temp: Double) -> Int {
        if temp < 70 { return 0 }
        if temp < 74 { return 1 }
        if temp < 78 { return 2 }
        if temp < 82 { return 3 }
        return 4
    }

    public static func bucketIndex(power: Double, target: Double) -> Int {
        powerBand(power) * targetBandCount + targetBand(target)
    }

    /// 记录一次"eligible 拍"。口径优先级：invalid → missing → notSteady → 入桶。
    /// 四个计数之和必须等于 considered（报告里直接对账，防止静默丢样本）。
    /// 注意：不按目标温度筛样本——模板/候选在"当前温度"处反解，实际输出也维持
    /// 当前温度；目标偏差只进 sumTempError/报告，不决定是否入桶。
    public mutating func consider(temp: Double, target: Double,
                                  env: Double?, power: Double?,
                                  actual: Double,
                                  modelNow: Double?, tableNow: Double?,
                                  modelTarget: Double?, tableTarget: Double?,
                                  steady: Bool, now: Date) {
        considered += 1
        guard temp.isFinite, target.isFinite, actual.isFinite else {
            invalidInputs += 1
            return
        }
        guard let p = power, p.isFinite, p >= 0,
              let e = env, e.isFinite else {
            missingInputs += 1
            return
        }
        guard steady else {
            notSteady += 1
            return
        }
        if startedAt == nil { startedAt = now }
        lastSampleAt = now
        let idx = Self.bucketIndex(power: p, target: target)
        guard buckets.indices.contains(idx) else {
            invalidInputs += 1   // 解码已归一化，此处纯防御；但计数必须补上，保持对账不变量
            return
        }
        buckets[idx].add(actual: actual, modelNow: modelNow, tableNow: tableNow,
                         modelTarget: modelTarget, tableTarget: tableTarget,
                         tempError: temp - target, power: p, temp: temp,
                         target: target, env: e)
        overall.add(actual: actual, modelNow: modelNow, tableNow: tableNow,
                    modelTarget: modelTarget, tableTarget: tableTarget,
                    tempError: temp - target, power: p, temp: temp,
                    target: target, env: e)
    }

    public enum Axis: Equatable { case power, target }

    /// 把 5×5 桶沿一个轴合并，供 CLI 按功耗/按目标展示。
    public func collapsed(_ axis: Axis) -> [ShadowFFBucket] {
        let n = axis == .power ? Self.powerBandCount : Self.targetBandCount
        var out = Array(repeating: ShadowFFBucket(), count: n)
        guard buckets.count == Self.bucketCount else { return out }
        for p in 0..<Self.powerBandCount {
            for t in 0..<Self.targetBandCount {
                let b = buckets[p * Self.targetBandCount + t]
                if axis == .power {
                    out[p] = out[p] + b
                } else {
                    out[t] = out[t] + b
                }
            }
        }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case version, startedAt, lastSampleAt
        case considered, invalidInputs, missingInputs, notSteady
        case buckets, overall
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil
        // 旧 schema 的桶语义不同：不混账，直接空账本重攒（v1 的 6-8 个 considered
        // 只是切换瞬间的非稳态计数，没有记录样本可丢）。
        guard decodedVersion == Self.schemaVersion else {
            self = ShadowFFLedger()
            return
        }
        version = Self.schemaVersion
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? nil
        lastSampleAt = (try? c.decodeIfPresent(Date.self, forKey: .lastSampleAt)) ?? nil
        func count(_ key: CodingKeys) -> Int {
            guard let v = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil else { return 0 }
            return (v >= 0 && v <= 1_000_000_000) ? v : 0
        }
        considered = count(.considered)
        invalidInputs = count(.invalidInputs)
        missingInputs = count(.missingInputs)
        notSteady = count(.notSteady)
        let raw = ((try? c.decodeIfPresent([ShadowFFBucket].self, forKey: .buckets)) ?? nil) ?? []
        // 桶数组长度是结构完整性门：短/长都说明文件半写或跨版本。抛错让
        // loadCorruptionAware 走损坏备份协议，而不是静默截断/补空后继续用。
        guard raw.count == Self.bucketCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .buckets, in: c,
                debugDescription: "桶数组长度 \(raw.count) ≠ \(Self.bucketCount)")
        }
        buckets = raw
        let decodedOverall = ((try? c.decodeIfPresent(ShadowFFBucket.self, forKey: .overall)) ?? nil)
            ?? ShadowFFBucket()
        let bucketSum = buckets.reduce(ShadowFFBucket(), +)
        if bucketSum.samples > 0 {
            // overall 是桶的冗余汇总；桶是主数据。两者都有数却不一致 = 半写/手改，
            // 抛错备份，不让一份自相矛盾的账本参与判读。
            if decodedOverall.samples > 0, decodedOverall.samples != bucketSum.samples {
                throw DecodingError.dataCorruptedError(
                    forKey: .overall, in: c,
                    debugDescription: "overall.samples=\(decodedOverall.samples) 与桶和 \(bucketSum.samples) 不一致")
            }
            overall = bucketSum
        } else if decodedOverall.samples > 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .overall, in: c,
                debugDescription: "overall 有样本但桶为空")
        } else {
            overall = decodedOverall
        }
    }
}

// MARK: - 报告（纯文本，fanprobe --shadow 与测试共用）

public enum ShadowFFReport {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func pct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f%%", v)
    }
    private static func one(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.1f", v)
    }
    private static func bias(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%+.1f", v)
    }
    private static func cover(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f%%", v * 100)
    }

    private static func candidate(_ name: String, _ c: ShadowFFBucket.Candidate,
                                  total: Int) -> String {
        name + " " + pct(c.mean)
            + " (MAE " + one(c.mae) + " · 偏差 " + bias(c.bias)
            + " · 覆盖 " + cover(c.coverage(total: total)) + ")"
    }

    private static func bucketLine(_ b: ShadowFFBucket) -> String {
        "n=\(b.samples) · 实际 " + pct(b.meanActual)
            + " · " + candidate("模型@当前", b.modelNow, total: b.samples)
            + " · " + candidate("查表@当前", b.tableNow, total: b.samples)
            + " · 工作点 " + one(b.meanTemp) + "° / 目标 " + one(b.meanTarget) + "°"
    }

    public static func text(_ l: ShadowFFLedger) -> String {
        var out: [String] = []
        let start = l.startedAt.map { stamp.string(from: $0) } ?? "—"
        let last = l.lastSampleAt.map { stamp.string(from: $0) } ?? "—"
        out.append("影子前馈账本 v\(l.version) · 起 \(start) · 末 \(last)")

        // 对账必须在"有无样本"两个分支都输出：recorded=0 也可能是半写丢样本，
        // 不能因为空账本就跳过对账。
        let accounted = l.recorded + l.invalidInputs + l.missingInputs + l.notSteady
        let mismatch = accounted == l.considered
            ? "" : "（⚠️ 对账不平：\(accounted)≠\(l.considered)）"
        guard l.recorded > 0 else {
            out.append("尚无 AI 稳态样本（需 daemon 以 AI 模式运行且温度/输出稳定；本账本只读，不写硬件）。")
            out.append("已进入采样门 \(l.considered) 拍：无效 \(l.invalidInputs)"
                       + " · 缺功耗/环境 \(l.missingInputs) · 非稳态 \(l.notSteady)"
                       + " · 入桶 0" + mismatch)
            return out.joined(separator: "\n")
        }
        let o = l.overall
        out.append("采样: 进入采样门 \(l.considered) 拍 · 入桶 \(l.recorded)"
                   + " · 非稳态 \(l.notSteady) · 缺功耗/环境 \(l.missingInputs)"
                   + " · 无效 \(l.invalidInputs)" + mismatch)
        out.append("整体: n=\(o.samples) · 实际 " + pct(o.meanActual)
                   + " · 工作点 平均 " + one(o.meanTemp) + "° / 目标 " + one(o.meanTarget)
                   + "°（偏差 " + bias(o.meanTempError) + "°）")
        out.append("  " + candidate("模型@当前（主判据）", o.modelNow, total: o.samples)
                   + " · " + candidate("查表@当前", o.tableNow, total: o.samples))
        out.append("  " + candidate("模型@目标", o.modelTarget, total: o.samples)
                   + " · " + candidate("查表@目标", o.tableTarget, total: o.samples)
                   + "（含工作点偏移，仅前馈参考）")
        out.append("按功耗:")
        let byPower = l.collapsed(.power)
        for (i, b) in byPower.enumerated() where b.samples > 0 {
            out.append("  " + ShadowFFLedger.powerBandLabels[i] + ": " + bucketLine(b))
        }
        if byPower.allSatisfy({ $0.samples == 0 }) { out.append("  （无）") }
        out.append("按目标:")
        let byTarget = l.collapsed(.target)
        for (i, b) in byTarget.enumerated() where b.samples > 0 {
            out.append("  " + ShadowFFLedger.targetBandLabels[i] + ": " + bucketLine(b))
        }
        if byTarget.allSatisfy({ $0.samples == 0 }) { out.append("  （无）") }

        // 主判读只认模型@当前：它和实际输出同一工作点。模型@目标的残差含
        // (目标−当前)×增益，拿它判模型准不准会把工作点偏移算成模型误差。
        let mae = o.modelNow.mae
        let cov = o.modelNow.coverage(total: o.samples)
        let n = o.modelNow.samples
        let pass = (mae.map { $0 <= ShadowFFLedger.verdictMAE } ?? false)
            && (cov.map { $0 >= ShadowFFLedger.verdictCoverage } ?? false)
        let verdictText: String
        if n < ShadowFFLedger.verdictMinSamples {
            verdictText = "样本不足（n=\(n)，判读门槛 ≥\(ShadowFFLedger.verdictMinSamples)）"
        } else if mae == nil || cov == nil {
            verdictText = "无模型样本（模型未成熟或请求在采信带外）"
        } else {
            verdictText = pass ? "达标" : "未达标"
        }
        out.append("判读门槛（预注册）: 模型@当前样本 ≥\(ShadowFFLedger.verdictMinSamples)"
                   + " 且 MAE ≤\(Int(ShadowFFLedger.verdictMAE))%"
                   + " 且覆盖 ≥\(Int(ShadowFFLedger.verdictCoverage * 100))%"
                   + " → 前馈主导前提成立；本次观测 n=\(n) / MAE " + one(mae)
                   + " / 覆盖 " + cover(cov) + " → " + verdictText)
        out.append("注: 实际=本拍施加输出（含 slew/迟滞保持，偏移前基础值）；"
                   + "候选@当前与实际同一工作点，是主判据；候选@目标含"
                   + "(目标−当前温度)×增益 的工作点偏移，只作新架构前馈参考。"
                   + "现行律还含瞬态前馈/学习地板/曲线锚定，残差不是纯模型误差。"
                   + "模型 0 = 模型认为不需要风，是有效预测；『无模型样本』仅指模型未成熟或采信带外。")
        return out.joined(separator: "\n")
    }
}
