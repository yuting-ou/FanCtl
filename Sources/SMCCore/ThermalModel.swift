import Foundation

// MARK: - 散热参数辨识模型（在线线性回归，纯本地）
//
// 第一性原理：散热系统近似线性——稳态下 温度 ≈ 环境 + a·功耗 − b·风量
//   a = 每瓦温升（°C/W，等效热阻）
//   b = 每百分比风量的降温能力（°C/%）
// 用在线梯度下降拟合 a/b（样本 = daemon 在学习采样处同步喂入的稳态点）。
// 相比 ThermalLearn 的"28 桶 × 4 场景查表"（100+ 自由参数拟合一条直线），
// 线性模型只有 2 个参数：收敛快、可外推到没见过的温度区间，
// 还能直接回答"压到目标温度需要多少风量"：percent = (环境 + a·功耗 − 目标) / b。
// 用途（全部服务于 AI 模式，与 ThermalLearn 查表互补）：
//   - 升温前馈/夺回种子的补充：模型预测可外推，查表不能
//   - 目标温度变化时无需重新学习（查表依赖 target 相关，模型参数与 target 无关）

public struct ThermalModel: Codable {
    // v2.6.2 数值稳定化：存储归一化系数 a' = a×50、b' = b×50（特征取 power/50、
    // percent/50，尺度 ~1，各特征 Hessian 相当），初始化为 Apple Silicon 典型值
    // （物理 a=0.5°C/W → a'=25，物理 b=0.1°C/% → b'=5）。
    // 此前直接拟合原始特征（power/percent 达 40–100），学习率要么在 b 的稳定上界
    // （η<2/100²=0.0002）之上导致钳位边界振荡，要么收敛极慢；且从 0 起步时
    // 首样本误差（≈-45°C）单步把 b 撞上 0 下限，预测长期返回 nil（“白学”）。
    public private(set) var a: Double = 25    // 归一化热阻系数（物理 a/50，°C/W）
    public private(set) var b: Double = 5     // 归一化风量系数（物理 b/50，°C/%）
    public private(set) var sampleCount: Int = 0
    // 递推最小二乘（RLS）协方差（对称 2×2，存 3 个标量）：
    // 梯度下降在误差减小时收敛指数减速（实测 1800 样本后仍离真值 30%），
    // RLS 一次更新即大幅校正，无学习率参数；λ<1 慢遗忘，适应散热缓慢漂移
    private var p11: Double = 100
    private var p12: Double = 0
    private var p22: Double = 100
    private let lambda: Double = 0.999

    // #3 瞬态增强：短窗口 OLS 回归捕捉负载突变时的瞬态热阻（运行时状态，不持久化）
    // 瞬态热阻在负载突增初期高于稳态值（散热系统尚未达到新平衡），
    // predictedPercent 取 max(稳态, 瞬态) 保守偏安全——宁可多给风量不能少给。
    private var recentSamples: [(env: Double, power: Double, percent: Double, temp: Double)] = []
    public private(set) var transientA: Double = 25  // 瞬态热阻（与 a 同归一化域）
    private var transientB: Double = 5               // 瞬态风量系数
    private static let transientWindow = 10          // 短窗口容量
    private static let transientMinSamples = 5       // 窗口内最少样本数才采信

    // 需要多少样本才采信（数据不足时预测返回 nil）
    public static let minSamples = 30

    // MARK: 预测采信域（闭环辨识的物理有效性）
    // percent 是控制器对 power/temp 的反馈输出——回归量与被控量相关（闭环辨识），
    // a/b 只在被采样覆盖的操作带内可辨识；带外外推的参数偏差经 predictedPercent
    // 除以 b 放大后不可控。带外（+余量）返回 nil，调用方回退查表前馈。
    // nil 范围 = 不设限（旧版本持久化数据无此记录，保持升级前行为）。
    public private(set) var minPower: Double?
    public private(set) var maxPower: Double?
    public private(set) var minEnv: Double?
    public private(set) var maxEnv: Double?
    public static let bandMarginPower = 10.0   // W：带外允许的轻度外推余量
    public static let bandMarginEnv = 5.0      // °C

    public init() {}

    // 在线更新：样本 (env, power, percent, temp)
    // 误差 e = (env + a·power − b·percent) − temp；梯度下降使 |e| 最小化。
    // 学习率随样本数衰减：前期快速收敛，后期缓慢微调（散热系统缓慢漂移的适应）。
    public mutating func update(env: Double, power: Double, percent: Double, temp: Double) {
        guard env.isFinite, power.isFinite, percent.isFinite, temp.isFinite,
              power >= 0, percent >= 0, percent <= 100 else { return }
        // 采信域随样本扩张（只扩不缩：单点 band 即可拦住明显外推）
        minPower = min(minPower ?? power, power)
        maxPower = max(maxPower ?? power, power)
        minEnv = min(minEnv ?? env, env)
        maxEnv = max(maxEnv ?? env, env)
        // 归一化特征：power/50、percent/50（尺度 ~1，数值稳定）
        let x1 = power / 50.0
        let x2 = -percent / 50.0
        let y = temp - env
        // RLS 增益向量 k = P·x / (λ + xᵀ·P·x)
        let denom = lambda + p11 * x1 * x1 + 2 * p12 * x1 * x2 + p22 * x2 * x2
        guard denom.isFinite, denom > 1e-9 else { return }
        let k1 = (p11 * x1 + p12 * x2) / denom
        let k2 = (p12 * x1 + p22 * x2) / denom
        // 参数更新（误差钳制 ±15°C：异常样本不把参数大幅推离物理域）
        let err = max(-15, min(15, y - (a * x1 + b * x2)))
        a += k1 * err
        b += k2 * err
        // 协方差更新 P ← (P − k·xᵀ·P)/λ
        let q11 = p11 - k1 * (p11 * x1 + p12 * x2)
        let q12 = p12 - k1 * (p12 * x1 + p22 * x2)
        let q22 = p22 - k2 * (p12 * x1 + p22 * x2)
        p11 = min(q11 / lambda, 1000)
        p12 = max(-1000, min(1000, q12 / lambda))
        p22 = min(q22 / lambda, 1000)
        // 物理约束钳位（归一化域）：热阻 [0, 2]°C/W、风量 [0.02, 2]°C/%
        a = max(0, min(100, a))
        b = max(1, min(100, b))
        sampleCount += 1

        // #3 瞬态窗口更新：维护最近 N 个样本的滑动窗口
        recentSamples.append((env, power, percent, temp))
        if recentSamples.count > Self.transientWindow { recentSamples.removeFirst() }
        if recentSamples.count >= Self.transientMinSamples {
            // 短窗口 OLS 解析解：y = a'·x1 + b'·x2，其中 x1=power/50, x2=-percent/50, y=temp-env
            // 法方程 (X'X) β = X'y，2×2 直接求逆
            var s11 = 0.0, s12 = 0.0, s22 = 0.0, sy1 = 0.0, sy2 = 0.0
            for s in recentSamples {
                let x1 = s.power / 50.0
                let x2 = -s.percent / 50.0
                let y = s.temp - s.env
                s11 += x1 * x1; s12 += x1 * x2; s22 += x2 * x2
                sy1 += y * x1; sy2 += y * x2
            }
            let det = s11 * s22 - s12 * s12
            if det > 1e-9 {
                let newA = (s22 * sy1 - s12 * sy2) / det
                let newB = (s11 * sy2 - s12 * sy1) / det
                // 物理约束钳位
                transientA = max(0, min(100, newA))
                transientB = max(1, min(100, newB))
            }
        }
    }

    // 预测"把温度压到 target 所需的风量百分比"；数据不足/参数未收敛返回 nil。
    // 门槛 b > 2.5（物理 0.05°C/%——100% 风量至少应降 5°C，更小说明模型未拟合好，
    // 预测会因除以小 b 产生超大前馈）
    public func predictedPercent(for env: Double, power: Double, targetTemp: Double) -> Double? {
        guard sampleCount >= Self.minSamples, b > 2.5 else { return nil }
        guard env.isFinite, power.isFinite, targetTemp.isFinite else { return nil }
        // 采信域守卫：请求点落在样本带外（+余量）时不外推（nil → 调用方回退查表前馈）
        if let lo = minPower, let hi = maxPower,
           power < lo - Self.bandMarginPower || power > hi + Self.bandMarginPower { return nil }
        if let lo = minEnv, let hi = maxEnv,
           env < lo - Self.bandMarginEnv || env > hi + Self.bandMarginEnv { return nil }
        let need = (env + a * power / 50.0 - targetTemp) / (b / 50.0)
        guard need.isFinite else { return nil }
        let steady = max(0, min(100, need))
        // #3 瞬态预测：短窗口参数可能反映更高的瞬态热阻，取 max 保守偏安全
        if recentSamples.count >= Self.transientMinSamples, transientB > 2.5 {
            let tNeed = (env + transientA * power / 50.0 - targetTemp) / (transientB / 50.0)
            if tNeed.isFinite {
                let transient = max(0, min(100, tNeed))
                return max(steady, transient)
            }
        }
        return steady
    }

    // 模型是否已采信（供 UI 展示“模型已掌握 N 样本”）
    public var isMature: Bool { sampleCount >= Self.minSamples }
}

// 自定义 Codable：recentSamples (tuple 数组) 不支持 Codable，需手动排除
// 自定义 Equatable：tuple 不自动 Equatable，只比较持久化字段
extension ThermalModel: Equatable {
    public static func == (lhs: ThermalModel, rhs: ThermalModel) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.sampleCount == rhs.sampleCount
    }
    private enum CodingKeys: String, CodingKey {
        case a, b, sampleCount, p11, p12, p22, lambda
        case minPower, maxPower, minEnv, maxEnv
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        a = try c.decode(Double.self, forKey: .a)
        b = try c.decode(Double.self, forKey: .b)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        p11 = try c.decodeIfPresent(Double.self, forKey: .p11) ?? 100
        p12 = try c.decodeIfPresent(Double.self, forKey: .p12) ?? 0
        p22 = try c.decodeIfPresent(Double.self, forKey: .p22) ?? 100
        // 采信域：旧版本无此记录 → nil（不设限），保持升级前行为
        minPower = try c.decodeIfPresent(Double.self, forKey: .minPower)
        maxPower = try c.decodeIfPresent(Double.self, forKey: .maxPower)
        minEnv = try c.decodeIfPresent(Double.self, forKey: .minEnv)
        maxEnv = try c.decodeIfPresent(Double.self, forKey: .maxEnv)
        // lambda 是 let，用默认值
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(a, forKey: .a)
        try c.encode(b, forKey: .b)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(p11, forKey: .p11)
        try c.encode(p12, forKey: .p12)
        try c.encode(p22, forKey: .p22)
        try c.encode(lambda, forKey: .lambda)
        try c.encodeIfPresent(minPower, forKey: .minPower)
        try c.encodeIfPresent(maxPower, forKey: .maxPower)
        try c.encodeIfPresent(minEnv, forKey: .minEnv)
        try c.encodeIfPresent(maxEnv, forKey: .maxEnv)
    }
}

// MARK: - 持久化（与学习数据同目录）

extension ConfigStore {
    public static func loadModel() -> ThermalModel? {
        guard let data = try? Data(contentsOf: FanCtlPaths.modelFile) else { return nil }
        return try? JSONDecoder().decode(ThermalModel.self, from: data)
    }

    @discardableResult
    public static func saveModel(_ model: ThermalModel) -> Bool {
        guard let data = try? JSONEncoder().encode(model) else { return false }
        do {
            try data.write(to: FanCtlPaths.modelFile, options: .atomic)
            return true
        } catch { return false }
    }
}
