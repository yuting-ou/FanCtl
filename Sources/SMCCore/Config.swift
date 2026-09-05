import Foundation

// MARK: - 共享配置与状态
// 菜单栏 App 写 config.json（用户意图），root 守护进程读取执行；
// 守护进程写 status.json（实时状态），App 读取展示。
// 目录权限由安装脚本设置为 staff 组可写。

public enum FanMode: String, Codable, CaseIterable {
    case auto    // 交还 macOS 系统调度
    case curve   // 按温度曲线智能调速（默认）
    case ai      // AI 自动接管：盯目标温度 + 预判趋势动态调速
    case manual  // 手动固定转速
}

// 曲线预设：三档强度，针对 Apple Silicon 热点温度特性调校；另支持自定义拖点
public enum CurvePreset: String, Codable, CaseIterable {
    case quiet       // 安静：优先噪音，高温才介入
    case balanced    // 均衡：默认，噪音与散热兼顾
    case aggressive  // 强劲：优先压温，风扇积极介入
    case custom      // 自定义：用户在曲线图上拖动控制点，实际点存在 config.curve

    public var displayName: String {
        switch self {
        case .quiet: return "安静"
        case .balanced: return "均衡"
        case .aggressive: return "强劲"
        case .custom: return "自定义"
        }
    }

    public var points: [CurvePoint] {
        switch self {
        case .quiet:
            return [CurvePoint(temp: 55, percent: 0),
                    CurvePoint(temp: 66, percent: 12),
                    CurvePoint(temp: 75, percent: 35),
                    CurvePoint(temp: 83, percent: 65),
                    CurvePoint(temp: 89, percent: 100)]
        case .balanced:
            return [CurvePoint(temp: 52, percent: 0),
                    CurvePoint(temp: 62, percent: 20),
                    CurvePoint(temp: 70, percent: 45),
                    CurvePoint(temp: 78, percent: 72),
                    CurvePoint(temp: 85, percent: 100)]
        case .aggressive:
            return [CurvePoint(temp: 48, percent: 0),
                    CurvePoint(temp: 58, percent: 32),
                    CurvePoint(temp: 66, percent: 60),
                    CurvePoint(temp: 74, percent: 85),
                    CurvePoint(temp: 80, percent: 100)]
        case .custom:
            // 占位兼底（真实自定义点由 App 维护并写入 config.curve）
            return CurvePreset.balanced.points
        }
    }
}

public struct CurvePoint: Codable, Equatable {
    public var temp: Double     // °C
    public var percent: Double  // 0~100，0=最低转速 100=最高转速

    public init(temp: Double, percent: Double) {
        self.temp = temp
        self.percent = percent
    }
}

public struct FanConfig: Codable, Equatable {
    public var mode: FanMode
    public var manualPercent: Double
    public var curve: [CurvePoint]
    public var preset: CurvePreset?       // 可选，旧配置兼容；nil 视为均衡
    public var batteryPreset: CurvePreset? // 电池供电时改用的档位；nil = 不启用电源感知
    public var batteryCurve: [CurvePoint]? // 电池档实际曲线（AI 个性化后与出厂预设不同）；nil 用 batteryPreset.points
    // 静音承诺（会议模式）：截止时间前把风扇输出上限压到 quietCapPercent；
    // 高温兜底/SSD 托底优先级更高不受其限（安全红线不让步）；nil = 未启用
    public var quietUntil: Date?
    public var quietCapPercent: Double?
    public var aiTargetTemp: Double?      // AI 接管模式目标温度（性能72/均衡76/静音80）；nil = 默认 76
    public var fanOffsets: [Double]?      // 双风扇独立偏移（百分比），nil/空=统一偏移0；每个风扇单独叠加
    // 冲刺（临时全速）截止时间。App 崩溃/退出后 daemon 侧超时兜底：
    // 超过该时间后 manual 100% 不再无限持续（App 的结束时间仅存 UserDefaults，daemon 读不到）。
    // 与 quietUntil 的语义一致：daemon 读、App 写；nil = 未启用
    public var boostUntil: Date?
    // 环境温度补偿（默认开启）：绝对温度 = 环境 + 温升，控制输入改为温升后
    // 同一曲线在冬夏语义一致（夏天同样的绝对温度意味着更轻的负载）。
    // 曲线查表温度左移、AI 目标放宽，幅度 envOffset = clamp((env−25)×0.5, −5, +8)
    public var envCompensation: Bool
    // 夜间安静档（22:00–8:00 生效，daemon 按本地时间判断）：
    // curve 模式改用 nightCurve（App 写安静预设点），AI 模式目标放宽 +4°
    public var quietHours: Bool
    public var nightCurve: [CurvePoint]?
    // 环境温度手动覆盖（App 写入，daemon 读取优先于自动代理）：
    // 自动代理在热带环境/特殊散热结构下可能不准，允许用户手动指定。
    // nil = 使用自动代理（电池/掌托/散热片的有效低值）
    public var envTempOverride: Double?
    // 体感补偿（v3.3，默认关）：掌托超过 40°C（体感阈值）时适度收紧目标——
    // 芯片温度是代理指标，用户真正感知的是掌托温度。钳位 +4°C（风扇对底盘
    // 温度的控制权限有限），电池/夜间安静档不参与（明确的安静意图不被覆盖）
    public var palmCompensation: Bool

    public init(mode: FanMode = .curve,
                manualPercent: Double = 50,
                curve: [CurvePoint] = FanConfig.defaultCurve,
                preset: CurvePreset? = .balanced,
                batteryPreset: CurvePreset? = nil,
                batteryCurve: [CurvePoint]? = nil,
                quietUntil: Date? = nil,
                quietCapPercent: Double? = nil,
                aiTargetTemp: Double? = nil,
                fanOffsets: [Double]? = nil,
                boostUntil: Date? = nil,
                envCompensation: Bool = true,
                quietHours: Bool = false,
                nightCurve: [CurvePoint]? = nil,
                envTempOverride: Double? = nil,
                palmCompensation: Bool = false) {
        self.mode = mode
        self.manualPercent = manualPercent
        self.curve = curve
        self.preset = preset
        self.batteryPreset = batteryPreset
        self.batteryCurve = batteryCurve
        self.quietUntil = quietUntil
        self.quietCapPercent = quietCapPercent
        self.aiTargetTemp = aiTargetTemp
        self.fanOffsets = fanOffsets
        self.boostUntil = boostUntil
        self.envCompensation = envCompensation
        self.quietHours = quietHours
        self.nightCurve = nightCurve
        self.envTempOverride = envTempOverride
        self.palmCompensation = palmCompensation
    }

    // 获取指定风扇的偏移（0-based），自动处理越界
    public func offsetForFan(index: Int) -> Double {
        guard let offsets = fanOffsets, index >= 0, index < offsets.count else { return 0 }
        return offsets[index]
    }

    // 默认曲线 = 均衡预设
    public static let defaultCurve: [CurvePoint] = CurvePreset.balanced.points

    // 曲线插值：温度 → 风扇百分比
    // 节点间用 smoothstep 平滑过渡，避免线性折点处转速阶跃感
    public func percentFor(temp: Double) -> Double {
        FanConfig.percent(temp: temp, curve: curve)
    }

    // 静态版本：供守护进程用任意曲线（如电源感知覆盖后的曲线）插值
    public static func percent(temp: Double, curve: [CurvePoint]) -> Double {
        // 防御 NaN/Inf：NaN 比较恒为 false，会跳过所有分支直达 `return last.percent`（100%），
        // 导致异常温度误拉满风扇。Inf 同理（Inf >= last.temp 为 true，返回 100%）。
        // 守护进程已在上游过滤 NaN/Inf，但学习数据污染/未来回归的风险值得双重防御。
        // NaN/Inf → 返回 0%（安全降级：不动风扇，由 shape 死区和 failsafe 兜底）
        guard temp.isFinite else { return 0 }
        let pts = curve.sorted { $0.temp < $1.temp }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if temp <= first.temp { return first.percent }
        if temp >= last.temp { return last.percent }
        for i in 1..<pts.count where temp <= pts[i].temp {
            let a = pts[i - 1], b = pts[i]
            // 相邻点温度重合时避免除零，直接取后点百分比
            guard b.temp > a.temp else { return b.percent }
            var t = (temp - a.temp) / (b.temp - a.temp)
            t = t * t * (3 - 2 * t)  // smoothstep
            return a.percent + t * (b.percent - a.percent)
        }
        return last.percent
    }

    // 防御性校验：曲线点数异常（外部篡改/写坏）时回退出厂曲线，
    // 避免空/单点曲线插值恒为异常值导致风扇长期压在最低转速
    public func sanitized() -> FanConfig {
        var c = self
        // 曲线点逐点防御：NaN/Inf 温度与百分比清零；百分比钳位 [0,100]。
        // 此前只查点数不查点值：外部写坏的 percent=450 会经插值透传到 shape()，
        // 污染 lastAppliedPercent 导致风扇被钉满速（FanControlLaw 已加入口钳位，双保险）
        c.curve = c.curve.map { p in
            CurvePoint(temp: p.temp.isFinite ? p.temp : 0,
                       percent: p.percent.isFinite ? max(0, min(100, p.percent)) : 0)
        }
        if c.curve.count < 2 { c.curve = (c.preset ?? .balanced).points }
        if let bc = c.batteryCurve {
            c.batteryCurve = bc.map { p in
                CurvePoint(temp: p.temp.isFinite ? p.temp : 0,
                           percent: p.percent.isFinite ? max(0, min(100, p.percent)) : 0)
            }
            if c.batteryCurve!.count < 2 { c.batteryCurve = nil }
        }
        // v2.6.2:nightCurve 与 batteryCurve 同样逐点防御(此前漏了,坏曲线会绕过 sanitized)
        if let nc = c.nightCurve {
            c.nightCurve = nc.map { p in
                CurvePoint(temp: p.temp.isFinite ? p.temp : 0,
                           percent: p.percent.isFinite ? max(0, min(100, p.percent)) : 0)
            }
            if c.nightCurve!.count < 2 { c.nightCurve = nil }
        }
        // 偏移值钳位到 [-20, 20] 合理范围
        // NaN 穿透 min/max（NaN 比较恒 false），需显式过滤
        if let offsets = c.fanOffsets {
            c.fanOffsets = offsets.map { $0.isFinite ? max(-20, min(20, $0)) : 0 }
        }
        // AI 目标温度钳位到 [40, 95]：0/200/NaN 会导致 AI 锁死或 NaN 传播到 SMC
        if let t = c.aiTargetTemp, t.isFinite {
            c.aiTargetTemp = max(40, min(95, t))
        } else {
            c.aiTargetTemp = 76
        }
        // 手动百分比钳位到 [0, 100]
        c.manualPercent = max(0, min(100, c.manualPercent.isFinite ? c.manualPercent : 0))
        // 静音上限钳位到 [0, 100]
        if let q = c.quietCapPercent, q.isFinite {
            c.quietCapPercent = max(0, min(100, q))
        } else {
            c.quietCapPercent = nil
        }
        // 环境温度手动覆盖钳位到 [0, 60]（合理环境温度范围），NaN/Inf 清 nil
        if let e = c.envTempOverride, e.isFinite {
            c.envTempOverride = max(0, min(60, e))
        } else {
            c.envTempOverride = nil
        }
        return c
    }
}

// 自定义 Codable：envCompensation/quietHours 是 v8 新增的非 Optional 字段，
// 合成解码对旧配置（无此字段）会直接失败——decodeIfPresent 缺省默认值保持兼容
extension FanConfig {
    private enum CodingKeys: String, CodingKey {
        case mode, manualPercent, curve, preset, batteryPreset, batteryCurve
        case quietUntil, quietCapPercent, aiTargetTemp, fanOffsets, boostUntil
        case envCompensation, quietHours, nightCurve, envTempOverride, palmCompensation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(FanMode.self, forKey: .mode)
        manualPercent = try c.decode(Double.self, forKey: .manualPercent)
        curve = try c.decode([CurvePoint].self, forKey: .curve)
        preset = try c.decodeIfPresent(CurvePreset.self, forKey: .preset)
        batteryPreset = try c.decodeIfPresent(CurvePreset.self, forKey: .batteryPreset)
        batteryCurve = try c.decodeIfPresent([CurvePoint].self, forKey: .batteryCurve)
        quietUntil = try c.decodeIfPresent(Date.self, forKey: .quietUntil)
        quietCapPercent = try c.decodeIfPresent(Double.self, forKey: .quietCapPercent)
        aiTargetTemp = try c.decodeIfPresent(Double.self, forKey: .aiTargetTemp)
        fanOffsets = try c.decodeIfPresent([Double].self, forKey: .fanOffsets)
        boostUntil = try c.decodeIfPresent(Date.self, forKey: .boostUntil)
        envCompensation = try c.decodeIfPresent(Bool.self, forKey: .envCompensation) ?? true
        quietHours = try c.decodeIfPresent(Bool.self, forKey: .quietHours) ?? false
        nightCurve = try c.decodeIfPresent([CurvePoint].self, forKey: .nightCurve)
        envTempOverride = try c.decodeIfPresent(Double.self, forKey: .envTempOverride)
        palmCompensation = try c.decodeIfPresent(Bool.self, forKey: .palmCompensation) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(manualPercent, forKey: .manualPercent)
        try c.encode(curve, forKey: .curve)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encodeIfPresent(batteryPreset, forKey: .batteryPreset)
        try c.encodeIfPresent(batteryCurve, forKey: .batteryCurve)
        try c.encodeIfPresent(quietUntil, forKey: .quietUntil)
        try c.encodeIfPresent(quietCapPercent, forKey: .quietCapPercent)
        try c.encodeIfPresent(aiTargetTemp, forKey: .aiTargetTemp)
        try c.encodeIfPresent(fanOffsets, forKey: .fanOffsets)
        try c.encodeIfPresent(boostUntil, forKey: .boostUntil)
        try c.encode(envCompensation, forKey: .envCompensation)
        try c.encode(quietHours, forKey: .quietHours)
        try c.encodeIfPresent(nightCurve, forKey: .nightCurve)
        try c.encodeIfPresent(envTempOverride, forKey: .envTempOverride)
        try c.encode(palmCompensation, forKey: .palmCompensation)
    }
}

// 温度传感器读数集合（App 从 status.json 获取，无需直读 SMC）
public struct SensorReadings: Codable, Equatable {
    public var cpuDie: Double       // CPU 核心温度（主热点，用于控制决策）
    public var cpuAverage: Double?  // CPU 核心平均温度（仅展示，对齐其他软件的"核心平均"；旧版 status 无此字段为 nil）
    public var gpuDie: Double       // GPU 温度
    public var ssd: Double?         // SSD/NAND 温度（可选，部分机型无）
    public var palmRest: Double?    // 掌托/键盘附近温度（可选）
    public var heatsink: Double?    // 散热片/风道温度（可选）
    public var otherHotspots: [String: Double]? // 其他发现的热点温度

    public init(cpuDie: Double, cpuAverage: Double? = nil, gpuDie: Double, ssd: Double? = nil,
                palmRest: Double? = nil, heatsink: Double? = nil,
                otherHotspots: [String: Double]? = nil) {
        self.cpuDie = cpuDie
        self.cpuAverage = cpuAverage
        self.gpuDie = gpuDie
        self.ssd = ssd
        self.palmRest = palmRest
        self.heatsink = heatsink
        self.otherHotspots = otherHotspots
    }

    // CPU/GPU 主控温度。SSD 通过 FanPipeline 独立安全托底，不混入基础曲线。
    public var maxTemp: Double {
        max(cpuDie, gpuDie)
    }
}

public struct FanStatusEntry: Codable {
    public var id: Int
    public var actualRPM: Double
    public var targetRPM: Double
    public var minRPM: Double
    public var maxRPM: Double

    public init(id: Int, actualRPM: Double, targetRPM: Double, minRPM: Double, maxRPM: Double) {
        self.id = id
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

public struct DaemonStatus: Codable {
    public var sensors: SensorReadings
    public var mode: FanMode
    public var appliedPercent: Double
    public var appliedPercents: [Double]?  // 双风扇独立百分比（可选，旧版为 nil）
    public var fans: [FanStatusEntry]
    public var timestamp: Date
    public var onBattery: Bool?          // 当前是否电池供电
    public var batteryOverride: Bool?    // 电源感知是否正在覆盖档位
    public var reason: ControlReason?    // 当前转速的决定因素（旧版无此字段为 nil）
    public var aiIntent: AIIntent?       // AI 实时意图（仅 .ai 模式且非交还态；旧版无此字段为 nil）
    public var loopInterval: Double?     // 当前自适应循环间隔（秒），便于调试观测
    public var controlFault: Bool?       // SMC 写入持续失败、调速闭环失效（旧版无此字段为 nil）
    public var faultReason: ControlFaultReason? // 故障的具体原因（旧版无此字段）
    public var baseTargetPercent: Double?       // 安全覆盖前的基础目标（旧版无此字段）
    public var safetyFloorPercent: Double?      // SSD/高温安全覆盖目标（旧版无此字段）
    public var curveTargetPercent: Double?      // AI 模式下当前温度的用户曲线期望值（v7 曲线锚定展示）
    public var learningRecently: Bool?   // 最近 120s 内是否记录过热经验样本（AI 结合曲线后仍在自学习）
    public var learnedPoints: Int?       // 已"学会"的温度点数（采样达标的桶数，UI"已掌握 N 点"）
    public var learnedSamples: Int?      // 累计学习样本总数（学习成熟度）
    public var targetUnreachable: Bool?  // AI 目标温度压不住：持续满速(≥98%)且温度高于目标+4°C。
                                         // 此时学习必然停滞（饱和输出+温度离开学习窗口），提示用户目标设得过激进。
    public var powerWatts: Double?       // 整机实时功耗（W），daemon 每拍直读 SMC（AI 功耗前馈同源），
                                         // 写入 status 供 App 展示"功耗胶囊"；无功耗键的机型为 nil
    public var nightOverride: Bool?      // 夜间安静档是否正在生效（22:00–8:00 且开启 quietHours）
    public var envTemp: Double?          // 环境温度代理（°C），环境补偿的输入与展示；无有效代理为 nil
    public var aiTargetEffective: Double? // AI 实际生效的目标温度（环境/夜间/电池叠加并钳位 ≤84° 后）；
                                          // App 的"全力散热"等判定须用它而非用户原始目标。旧版无此字段为 nil
    public var palmComp: Double?         // 体感补偿量（°C，v3.3）：掌托 >40° 时的目标收紧量，
                                          // App 展示“体感补偿 −N°”胶囊；无/未启用为 nil
    public var learnEnvelopeGap: Double? // v3.6 学习图单调包络健康度（°C 差值，仅展示/观察）：
                                         // 高温段 max(更低采信桶 − 本桶 EMA)；→0=已自愈。旧版无此字段为 nil
    public var cpuTemp: Double { sensors.cpuDie }
    public var gpuTemp: Double { sensors.gpuDie }

    public init(sensors: SensorReadings, mode: FanMode,
                appliedPercent: Double, appliedPercents: [Double]? = nil,
                fans: [FanStatusEntry], timestamp: Date = Date(),
                onBattery: Bool? = nil, batteryOverride: Bool? = nil,
                reason: ControlReason? = nil, aiIntent: AIIntent? = nil,
                loopInterval: Double? = nil, controlFault: Bool? = nil,
                faultReason: ControlFaultReason? = nil,
                baseTargetPercent: Double? = nil,
                safetyFloorPercent: Double? = nil,
                curveTargetPercent: Double? = nil,
                learningRecently: Bool? = nil,
                learnedPoints: Int? = nil,
                learnedSamples: Int? = nil,
                targetUnreachable: Bool? = nil,
                powerWatts: Double? = nil,
                nightOverride: Bool? = nil,
                envTemp: Double? = nil,
                aiTargetEffective: Double? = nil,
                palmComp: Double? = nil,
                learnEnvelopeGap: Double? = nil) {
        self.sensors = sensors
        self.mode = mode
        self.appliedPercent = appliedPercent
        self.appliedPercents = appliedPercents
        self.fans = fans
        self.timestamp = timestamp
        self.onBattery = onBattery
        self.batteryOverride = batteryOverride
        self.reason = reason
        self.aiIntent = aiIntent
        self.loopInterval = loopInterval
        self.controlFault = controlFault
        self.faultReason = faultReason
        self.baseTargetPercent = baseTargetPercent
        self.safetyFloorPercent = safetyFloorPercent
        self.curveTargetPercent = curveTargetPercent
        self.learningRecently = learningRecently
        self.learnedPoints = learnedPoints
        self.learnedSamples = learnedSamples
        self.targetUnreachable = targetUnreachable
        self.powerWatts = powerWatts
        self.nightOverride = nightOverride
        self.envTemp = envTemp
        self.aiTargetEffective = aiTargetEffective
        self.palmComp = palmComp
    }

    // 旧版便利初始化（保持源码兼容）
    public init(cpuTemp: Double, gpuTemp: Double, mode: FanMode,
                appliedPercent: Double, fans: [FanStatusEntry], timestamp: Date = Date(),
                onBattery: Bool? = nil, batteryOverride: Bool? = nil,
                reason: ControlReason? = nil, aiIntent: AIIntent? = nil) {
        self.sensors = SensorReadings(cpuDie: cpuTemp, gpuDie: gpuTemp)
        self.mode = mode
        self.appliedPercent = appliedPercent
        self.appliedPercents = nil
        self.fans = fans
        self.timestamp = timestamp
        self.onBattery = onBattery
        self.batteryOverride = batteryOverride
        self.reason = reason
        self.aiIntent = aiIntent
        self.loopInterval = nil
        self.controlFault = nil
        self.faultReason = nil
        self.baseTargetPercent = nil
        self.safetyFloorPercent = nil
        self.targetUnreachable = nil
    }

    // 自定义 Codable：兼容旧版 status.json（含 cpuTemp/gpuTemp 字段，无 sensors）
    private enum CodingKeys: String, CodingKey {
        case sensors, mode, appliedPercent, appliedPercents, fans, timestamp
        case onBattery, batteryOverride, reason, aiIntent, loopInterval, controlFault, faultReason
        case baseTargetPercent, safetyFloorPercent, curveTargetPercent
        case learningRecently, learnedPoints, learnedSamples
        case targetUnreachable, powerWatts, nightOverride, envTemp
        case aiTargetEffective
                case palmComp, learnEnvelopeGap // 旧字段
        case cpuTemp, gpuTemp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 优先读新 sensors 字段，不存在则用旧 cpuTemp/gpuTemp 构造
        if let sensors = try? container.decode(SensorReadings.self, forKey: .sensors) {
            self.sensors = sensors
        } else {
            let cpu = try container.decodeIfPresent(Double.self, forKey: .cpuTemp) ?? 40
            let gpu = try container.decodeIfPresent(Double.self, forKey: .gpuTemp) ?? cpu
            self.sensors = SensorReadings(cpuDie: cpu, gpuDie: gpu)
        }
        self.mode = try container.decode(FanMode.self, forKey: .mode)
        self.appliedPercent = try container.decode(Double.self, forKey: .appliedPercent)
        self.appliedPercents = try container.decodeIfPresent([Double].self, forKey: .appliedPercents)
        self.fans = try container.decode([FanStatusEntry].self, forKey: .fans)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.onBattery = try container.decodeIfPresent(Bool.self, forKey: .onBattery)
        self.batteryOverride = try container.decodeIfPresent(Bool.self, forKey: .batteryOverride)
        // 前向兼容：旧 App 读新 daemon 写出的新增枚举 case（如 .batteryHot）时，
        // 直接 decode 枚举会 throw 使整包 status 解码失败（App 误判 daemon 离线，
        // 恰发生在最需要可信状态的过热时段）——按 rawValue 字符串解析，未知值降级 nil
        self.reason = ((try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil)
            .flatMap(ControlReason.init(rawValue:))
        self.aiIntent = ((try? container.decodeIfPresent(String.self, forKey: .aiIntent)) ?? nil)
            .flatMap(AIIntent.init(rawValue:))
        self.loopInterval = try container.decodeIfPresent(Double.self, forKey: .loopInterval)
        self.controlFault = try container.decodeIfPresent(Bool.self, forKey: .controlFault)
        self.faultReason = ((try? container.decodeIfPresent(String.self, forKey: .faultReason)) ?? nil)
            .flatMap(ControlFaultReason.init(rawValue:))
        self.baseTargetPercent = try container.decodeIfPresent(Double.self, forKey: .baseTargetPercent)
        self.safetyFloorPercent = try container.decodeIfPresent(Double.self, forKey: .safetyFloorPercent)
        self.curveTargetPercent = try container.decodeIfPresent(Double.self, forKey: .curveTargetPercent)
        self.learningRecently = try container.decodeIfPresent(Bool.self, forKey: .learningRecently)
        self.learnedPoints = try container.decodeIfPresent(Int.self, forKey: .learnedPoints)
        self.learnedSamples = try container.decodeIfPresent(Int.self, forKey: .learnedSamples)
        self.targetUnreachable = try container.decodeIfPresent(Bool.self, forKey: .targetUnreachable)
        self.powerWatts = try container.decodeIfPresent(Double.self, forKey: .powerWatts)
        self.nightOverride = try container.decodeIfPresent(Bool.self, forKey: .nightOverride)
        self.envTemp = try container.decodeIfPresent(Double.self, forKey: .envTemp)
        self.aiTargetEffective = try container.decodeIfPresent(Double.self, forKey: .aiTargetEffective)
        self.palmComp = try container.decodeIfPresent(Double.self, forKey: .palmComp)
        self.learnEnvelopeGap = try container.decodeIfPresent(Double.self, forKey: .learnEnvelopeGap)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sensors, forKey: .sensors)
        try container.encode(mode, forKey: .mode)
        try container.encode(appliedPercent, forKey: .appliedPercent)
        try container.encodeIfPresent(appliedPercents, forKey: .appliedPercents)
        try container.encode(fans, forKey: .fans)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(onBattery, forKey: .onBattery)
        try container.encodeIfPresent(batteryOverride, forKey: .batteryOverride)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(aiIntent, forKey: .aiIntent)
        try container.encodeIfPresent(loopInterval, forKey: .loopInterval)
        try container.encodeIfPresent(controlFault, forKey: .controlFault)
        try container.encodeIfPresent(faultReason, forKey: .faultReason)
        try container.encodeIfPresent(baseTargetPercent, forKey: .baseTargetPercent)
        try container.encodeIfPresent(safetyFloorPercent, forKey: .safetyFloorPercent)
        try container.encodeIfPresent(curveTargetPercent, forKey: .curveTargetPercent)
        try container.encodeIfPresent(learningRecently, forKey: .learningRecently)
        try container.encodeIfPresent(learnedPoints, forKey: .learnedPoints)
        try container.encodeIfPresent(learnedSamples, forKey: .learnedSamples)
        try container.encodeIfPresent(targetUnreachable, forKey: .targetUnreachable)
        try container.encodeIfPresent(powerWatts, forKey: .powerWatts)
        try container.encodeIfPresent(nightOverride, forKey: .nightOverride)
        try container.encodeIfPresent(envTemp, forKey: .envTemp)
        try container.encodeIfPresent(aiTargetEffective, forKey: .aiTargetEffective)
        try container.encodeIfPresent(palmComp, forKey: .palmComp)
        try container.encodeIfPresent(learnEnvelopeGap, forKey: .learnEnvelopeGap)
        // 同时写旧字段，保证回滚到旧版本 App/daemon 时也能读
        try container.encode(sensors.cpuDie, forKey: .cpuTemp)
        try container.encode(sensors.gpuDie, forKey: .gpuTemp)
    }
}

// 控制闭环故障原因：比单一 Bool 更适合 UI、诊断工具和日志定位。
public enum ControlFaultReason: String, Codable, Equatable {
    case sensorUnavailable
    case fanStateReadFailed
    case smcWriteFailed
    case fanFeedbackMismatch
    case sensorImplausible   // 温度读数疑似卡死：功耗波动 ≥10W 而读数 5 分钟纹丝不动

    public var displayName: String {
        switch self {
        case .sensorUnavailable: return "温度传感器不可用"
        case .fanStateReadFailed: return "风扇状态读取失败"
        case .smcWriteFailed: return "SMC 写入失败"
        case .fanFeedbackMismatch: return "风扇实际转速未跟随目标"
        case .sensorImplausible: return "温度读数疑似失真（传感器卡死）"
        }
    }
}

// 当前风扇转速的“决定者”（可解释性）：守护进程把已算好的决策结果标注为其中一种，
// 优先级从低到高：基础模式(auto/curve/manual/battery) < 静音封顶 < SSD 托底 < 高温兜底。
public enum ControlReason: String, Codable {
    case auto        // 系统自动调度
    case curve       // 按温度曲线
    case ai          // AI 自动接管
    case aiIdle      // AI 低负载交还系统（风扇可降转/停转）
    case manual      // 手动固定
    case battery     // 电池安静档覆盖
    case night       // 夜间安静档覆盖（22:00–8:00 自动切安静）
    case batteryHot  // 电池高温托底（≥45° 拉风 / ≥48° 全速）
    case quiet       // 会议静音封顶
    case ssd         // SSD 高温托底
    case failsafe    // 高温全速兜底

    public var label: String {
        switch self {
        case .auto: return "系统自动调度"
        case .curve: return "按温度曲线调速"
        case .ai: return "AI 自动接管"
        case .aiIdle: return "AI 低负载 · 系统接管"
        case .manual: return "手动固定转速"
        case .battery: return "电池安静档"
        case .night: return "夜间安静档"
        case .batteryHot: return "电池高温托底"
        case .quiet: return "会议静音中"
        case .ssd: return "SSD 高温托底"
        case .failsafe: return "高温全速兜底"
        }
    }
}

// 功耗分布直方图（v3.3）：与温度直方图同构，2W 桶 × 30（0~60W，越界并入尾桶）。
// 负载分布由用户行为决定、与曲线无关——它是优化器打破“曲线→温度分布→曲线”
// 闭环自指的锚定量：温度分位下移而功耗分位未变 = 自降温，禁止锚点跟进。
public enum PowerHistogram {
    public static let bucketWidth = 2.0
    public static let bucketCount = 30   // 覆盖 0~60W

    public static func bucketIndex(for power: Double) -> Int {
        guard power.isFinite, power > 0 else { return 0 }
        let raw = power / bucketWidth
        return Int(min(max(raw, 0), Double(bucketCount - 1)))
    }

    public static func bucketMidPower(of index: Int) -> Double {
        (Double(index) + 0.5) * bucketWidth
    }
}

// MARK: - 每日统计（守护进程累计，App 展示“今日战报”）

// 温度分布直方图桶定义（AI 曲线优化的数据底座）：
// 守护进程每拍把温度落入对应 2°C 桶累计秒数，按天存进 DailyStats；
// 优化器合并多天直方图算分位数，刻画“这台机器”的真实温度分布。
public enum TempHistogram {
    public static let lowerBound = 40.0   // 40°C 以下并入首桶
    public static let bucketWidth = 2.0
    public static let bucketCount = 28    // 覆盖 40~96°C，超出并入尾桶

    public static func bucketIndex(for temp: Double) -> Int {
        // 防御 NaN/Inf/超大值：
        // - Int(.infinity)/Int(1e20) 会因溢出 trap 导致 daemon 崩溃
        // - Int(.nan) 返回 0（实现定义行为，不可依赖）
        // - 1e20.isFinite == true，guard isFinite 无法拦截
        // 先钳位 raw 到 [0, bucketCount-1] 再转 Int，确保不溢出
        guard temp.isFinite else { return 0 }
        let raw = (temp - lowerBound) / bucketWidth
        let clamped = min(max(raw, 0), Double(bucketCount - 1))
        return Int(clamped)
    }

    // 桶中值温度（分位数计算用）
    public static func midTemp(of index: Int) -> Double {
        lowerBound + (Double(index) + 0.5) * bucketWidth
    }
}

public struct DailyStats: Codable {
    public var date: String              // "2026-07-29"，跨天自动重置
    public var maxTemp: Double
    public var maxTempAt: Date
    public var highTempSeconds: Double   // ≥80°C 累计时长
    public var tempSum: Double
    public var tempCount: Double
    public var revolutions: Double       // 双风扇累计转数
    public var tempHistogram: [Double]?  // 温度分布（秒/桶）；旧数据无此字段为 nil
    public var powerSum: Double          // 功耗累计（W·s），散热退化趋势的数据底座
    public var powerCount: Double        // 功耗样本数
    // 温度采样累计秒数（v2.6.2）：tempSum 按秒加权累计，avgTemp 是时间加权平均。
    // 此前 avgTemp = tempSum/tempCount 是"按拍不加权"——自适应循环间隔（1~20s）下
    // 高频采样时段被等权计入，均温系统性偏向繁忙时段，且与秒加权的直方图/avgPower
    // 口径不一致，会扭曲散热健康趋势判定。旧数据无此字段时回退样本平均。
    public var tempSeconds: Double
    // 静音/安静档生效累计时长（秒）：静音会议+夜间安静档的总时长，战报展示用
    public var quietSeconds: Double
    // 显著调速次数（|输出Δ|≥3% 的拍数，v2.8）：风扇寿命代理指标——
    // 频繁变转加速轴承磨损（项目注释多次记录的价值观），只差把它 surface 出来
    public var speedChanges: Double
    // AI 启停循环抑制武装次数（v3.1）：每天"停转不可持续被实测"的次数——
    // 观察期核心指标，频率过高说明需要预测式释放（τ 自适应）而非记忆式抑制
    public var aiCyclingGuards: Double
    // 当日温度超出 AI 有效目标的最大值（v3.2，°C）：滚动 30 天的过冲观察数据——
    // 账本级 maxOvershoot 不滚动、无法区分"上周一次事件"与"持续过冲"；
    // 连续多日 >8° 是启动 τ 自适应（动态学习）的数据门槛
    public var overshootPeak: Double
    // 功耗分布直方图（v3.3，秒/桶）：负载分布与曲线无关，是优化器功耗锚定的
    // 数据底座（打破闭环自指）与未来“按负载个性化”的基础
    public var powerHistogram: [Double]?

    // v3.6.1：分母加 1e-6 下限——手改 JSON 里 tempSeconds=1e-300 会让比值溢出为
    // 巨数，下游 Int(avgTemp.rounded()) runtime trap（合法数据分母 ≥ 1s，下限无影响）
    public var avgTemp: Double {
        tempSeconds > 1e-6 ? tempSum / tempSeconds : (tempCount > 1e-6 ? tempSum / tempCount : 0)
    }
    public var avgPower: Double { powerCount > 1e-6 ? powerSum / powerCount : 0 }

    public init(date: String) {
        self.date = date
        self.maxTemp = 0
        self.maxTempAt = Date()
        self.highTempSeconds = 0
        self.tempSum = 0
        self.tempCount = 0
        self.revolutions = 0
        self.tempHistogram = nil
        self.powerSum = 0
        self.powerCount = 0
        self.tempSeconds = 0
        self.quietSeconds = 0
        self.speedChanges = 0
        self.aiCyclingGuards = 0
        self.overshootPeak = 0
        self.powerHistogram = nil
    }

    // 功耗分布采样（v3.3）：落入对应桶累计秒数（桶数变更的旧数据直接重建）
    public mutating func addPowerSample(_ power: Double, seconds: Double) {
        guard power.isFinite, power > 0.1, power < 1000 else { return }
        var h = powerHistogram ?? [Double](repeating: 0, count: PowerHistogram.bucketCount)
        if h.count != PowerHistogram.bucketCount {
            h = [Double](repeating: 0, count: PowerHistogram.bucketCount)
        }
        h[PowerHistogram.bucketIndex(for: power)] += seconds
        powerHistogram = h
    }

    // 温度分布采样：落入对应桶累计秒数（桶数变更的旧数据直接重建）
    public mutating func addTempSample(_ temp: Double, seconds: Double) {
        var h = tempHistogram ?? [Double](repeating: 0, count: TempHistogram.bucketCount)
        if h.count != TempHistogram.bucketCount {
            h = [Double](repeating: 0, count: TempHistogram.bucketCount)
        }
        h[TempHistogram.bucketIndex(for: temp)] += seconds
        tempHistogram = h
    }

    // 指定时刻的日期字符串。固定公历 + POSIX locale：系统日历设为佛历/和历时
    // yyyy 会输出 2569 等非公历年，会打断跨天归档、保留期裁剪与 AI 效果的日期
    // 比较链；时区保持用户本地（按本地自然日分天）。参数化时间便于测试注入。
    // v3.4.5（2C）：formatter 提为静态缓存——每拍新建（含 locale/calendar 解析）
    // 是著名 ~百微秒级开销，StatsSampler.record 每拍调用；日历/时区固定场景无失效问题。
    // 主队列约定（daemon 全局状态单线程），App 侧亦主队列调用，无竞争。
    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    public static func dayString(for date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    public static func today() -> String { dayString(for: Date()) }

    // 自定义 Codable：powerSum/powerCount 是 v8 新增字段，旧战报 JSON 无此字段，
    // 非 Optional 的合成解码会直接失败——decodeIfPresent 缺省 0 保持旧数据兼容
    private enum CodingKeys: String, CodingKey {
        case date, maxTemp, maxTempAt, highTempSeconds, tempSum, tempCount
        case revolutions, tempHistogram, powerSum, powerCount, tempSeconds, quietSeconds
        case speedChanges, aiCyclingGuards, overshootPeak, powerHistogram
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        maxTemp = try c.decode(Double.self, forKey: .maxTemp)
        maxTempAt = try c.decode(Date.self, forKey: .maxTempAt)
        highTempSeconds = try c.decode(Double.self, forKey: .highTempSeconds)
        tempSum = try c.decode(Double.self, forKey: .tempSum)
        tempCount = try c.decode(Double.self, forKey: .tempCount)
        revolutions = try c.decode(Double.self, forKey: .revolutions)
        tempHistogram = try c.decodeIfPresent([Double].self, forKey: .tempHistogram)
        powerSum = try c.decodeIfPresent(Double.self, forKey: .powerSum) ?? 0
        powerCount = try c.decodeIfPresent(Double.self, forKey: .powerCount) ?? 0
        tempSeconds = try c.decodeIfPresent(Double.self, forKey: .tempSeconds) ?? 0
        quietSeconds = try c.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? 0
        speedChanges = try c.decodeIfPresent(Double.self, forKey: .speedChanges) ?? 0
        aiCyclingGuards = try c.decodeIfPresent(Double.self, forKey: .aiCyclingGuards) ?? 0
        overshootPeak = try c.decodeIfPresent(Double.self, forKey: .overshootPeak) ?? 0
        powerHistogram = try c.decodeIfPresent([Double].self, forKey: .powerHistogram)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(maxTemp, forKey: .maxTemp)
        try c.encode(maxTempAt, forKey: .maxTempAt)
        try c.encode(highTempSeconds, forKey: .highTempSeconds)
        try c.encode(tempSum, forKey: .tempSum)
        try c.encode(tempCount, forKey: .tempCount)
        try c.encode(revolutions, forKey: .revolutions)
        try c.encodeIfPresent(tempHistogram, forKey: .tempHistogram)
        try c.encode(powerSum, forKey: .powerSum)
        try c.encode(powerCount, forKey: .powerCount)
        try c.encode(tempSeconds, forKey: .tempSeconds)
        try c.encode(quietSeconds, forKey: .quietSeconds)
        try c.encode(speedChanges, forKey: .speedChanges)
        try c.encode(aiCyclingGuards, forKey: .aiCyclingGuards)
        try c.encode(overshootPeak, forKey: .overshootPeak)
        try c.encodeIfPresent(powerHistogram, forKey: .powerHistogram)
    }

    // v3.6.1：从磁盘加载后的数值消毒（纯函数，daemon/App/测试同源）。
    // 手改/损坏的 stats/history JSON 可携带 1e300 级有限值——avgTemp 计算后进
    // Int(x.rounded()) 是 runtime trap（App 崩溃类，与 TempHistogram 的 NaN 防御同源）。
    // 负值/非有限/超 1e7 均钳为 0；日期字段不处理（Formatter 对越界日期安全返回 nil）。
    public func sanitized() -> DailyStats {
        var s = self
        func fin(_ v: Double) -> Double { v.isFinite && v >= 0 && v < 1e7 ? v : 0 }
        s.maxTemp = fin(s.maxTemp)
        s.highTempSeconds = fin(s.highTempSeconds)
        s.tempSum = fin(s.tempSum)
        s.tempCount = fin(s.tempCount)
        s.revolutions = fin(s.revolutions)
        s.powerSum = fin(s.powerSum)
        s.powerCount = fin(s.powerCount)
        s.tempSeconds = fin(s.tempSeconds)
        s.quietSeconds = fin(s.quietSeconds)
        s.speedChanges = fin(s.speedChanges)
        s.aiCyclingGuards = fin(s.aiCyclingGuards)
        s.overshootPeak = fin(s.overshootPeak)
        s.tempHistogram = s.tempHistogram?.map(fin)
        s.powerHistogram = s.powerHistogram?.map(fin)
        return s
    }
}

// v3.5.1：天数序列的纯函数语义（从 FanModel 提取，App 与测试共用同一实现——
// 此前合并/过滤逻辑是 App private inline，"今日零样本保留历史末位"等关键语义
// 无测试覆盖且 App target 结构上不可测）。
public extension Array where Element == DailyStats {
    /// 把"今日实时统计"合并进历史天数序列：同日替换（today 赢，实时值覆盖当日归档值）；
    /// today 为 nil 或 tempCount == 0（新一天尚无样本）时原样保留历史（含末位=昨日），
    /// 避免"新一天零样本显示昨天数据"的语义漂移。
    static func mergingToday(_ history: [DailyStats], today: DailyStats?) -> [DailyStats] {
        var days = history
        if let s = today, s.tempCount > 0 {
            days.removeAll { $0.date == s.date }
            days.append(s)
        }
        return days
    }

    /// AI 效果评估窗：严格晚于基线日的天数（基线日当天是"改前"快照，必须排除——
    /// 同日既算 before 又算 after 会把改动前的数据算进效果，稀释/伪造改善）。
    func after(baselineDate: String) -> [DailyStats] {
        filter { $0.date > baselineDate }
    }
}

// MARK: - 文件存取

public enum FanCtlPaths {
    private static let pathLock = NSLock()
    private static var overrideSupportDir: URL? = nil
    private static var overrideLogDir: URL? = nil

    /// 测试专用：重定向数据/日志目录（引擎接线测试用，避免触碰真实 /Library 安装）。
    /// 传 nil 恢复默认。仅在测试进程内使用，生产代码不得调用。
    public static func setOverridesForTesting(supportDir: URL?, logDir: URL?) {
        pathLock.lock()
        overrideSupportDir = supportDir
        overrideLogDir = logDir
        pathLock.unlock()
    }

    public static var supportDir: URL {
        pathLock.lock(); defer { pathLock.unlock() }
        return overrideSupportDir ?? URL(fileURLWithPath: "/Library/Application Support/FanCtl")
    }
    public static var logDir: URL {
        pathLock.lock(); defer { pathLock.unlock() }
        return overrideLogDir ?? URL(fileURLWithPath: "/Library/Logs/FanCtl")
    }
    public static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    public static var statusFile: URL { supportDir.appendingPathComponent("status.json") }
    public static var statsFile: URL { supportDir.appendingPathComponent("stats.json") }
    public static var historyFile: URL { supportDir.appendingPathComponent("history.json") }
    public static var learnFile: URL { supportDir.appendingPathComponent("ai-learn.json") }
    public static var aiMetricsFile: URL { supportDir.appendingPathComponent("ai-metrics.json") }
    public static var modelFile: URL { supportDir.appendingPathComponent("thermal-model.json") }
    public static var resetLearnFlag: URL { supportDir.appendingPathComponent("reset-learn.flag") }
    public static var exitReasonFile: URL { supportDir.appendingPathComponent("exit-reason.flag") }
    public static var logFile: URL { logDir.appendingPathComponent("fanctld.log") }
    public static var stdLogFile: URL { logDir.appendingPathComponent("fanctld.out.log") }
    public static var errLogFile: URL { logDir.appendingPathComponent("fanctld.err.log") }

    // 确保所需目录存在
    public static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }
}

public enum ConfigStore {
    // 带损坏自愈的配置加载：失败时备份坏文件、返回默认配置并立即写回健康文件
    public static func loadConfig() -> FanConfig {
        FanCtlPaths.ensureDirectories()
        let defaultConfig = FanConfig().sanitized()
        guard let data = try? Data(contentsOf: FanCtlPaths.configFile) else {
            // 文件不存在：写入默认配置并返回
            saveConfig(defaultConfig)
            return defaultConfig
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let config = try decoder.decode(FanConfig.self, from: data)
            return config.sanitized()
        } catch {
            // 配置损坏：备份坏文件，写回默认配置
            let backupPath = FanCtlPaths.supportDir
                .appendingPathComponent("config.corrupted.\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backupPath)
            NSLog("fanctld: config.json 损坏，已备份到 \(backupPath.path)，使用默认配置")
            saveConfig(defaultConfig)
            return defaultConfig
        }
    }

    @discardableResult
    public static func saveConfig(_ config: FanConfig) -> Bool {
        FanCtlPaths.ensureDirectories()
        let sanitized = config.sanitized()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sanitized) else { return false }
        do {
            try data.write(to: FanCtlPaths.configFile, options: .atomic)
            // 原子写（临时文件+rename）会重置权限为 644，
            // 必须补回组写：daemon(root) 与 App(staff 组) 双方都要能写这个文件
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o664], ofItemAtPath: FanCtlPaths.configFile.path)
            return true
        } catch {
            return false
        }
    }

    public static func loadStatus() -> DaemonStatus? {
        guard let data = try? Data(contentsOf: FanCtlPaths.statusFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DaemonStatus.self, from: data)
    }

    @discardableResult
    public static func saveStatus(_ status: DaemonStatus) -> Bool {
        FanCtlPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return false }
        do {
            try data.write(to: FanCtlPaths.statusFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func configModificationDate() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: FanCtlPaths.configFile.path)[.modificationDate] as? Date
    }

    public static func loadStats() -> DailyStats? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return loadCorruptionAware(DailyStats.self, from: FanCtlPaths.statsFile, name: "stats", decoder: decoder)?.sanitized()
    }

    // MARK: 历史战报（按天归档，保留 30 天）

    public static func loadHistory() -> [DailyStats] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (loadCorruptionAware([DailyStats].self, from: FanCtlPaths.historyFile, name: "history", decoder: decoder) ?? []).map { $0.sanitized() }
    }

    @discardableResult
    public static func saveHistory(_ days: [DailyStats]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(days) else { return false }
        do {
            try data.write(to: FanCtlPaths.historyFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // 跨天时把前一天的统计归档（同一天重复归档取最新，兼容 daemon 重启）
    public static func archiveDay(_ day: DailyStats) {
        guard day.tempCount > 0 else { return }
        var days = loadHistory().filter { $0.date != day.date }
        days.append(day)
        days.sort { $0.date < $1.date }
        if days.count > 30 { days.removeFirst(days.count - 30) }
        saveHistory(days)
    }

    @discardableResult
    public static func saveStats(_ stats: DailyStats) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stats) else { return false }
        do {
            try data.write(to: FanCtlPaths.statsFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Status 变化摘要（纯函数，daemon 与测试共用）
// 将传感器噪声级别的波动量化取整，仅当有实质变化时才触发磁盘写入。
public func statusChangeSummary(_ s: DaemonStatus) -> String {
    // v3.6.1：NaN/Inf → 0。Int(NaN) 是 runtime trap（root 守护进程崩溃），
    // actualRPM/targetRPM 来自 SMC flt 解码，固件垃圾数据可产生 NaN
    let r: (Double) -> Int = { $0.isFinite ? Int($0.rounded()) : 0 }
    let fanParts = s.fans.map { "\($0.id):\(r($0.actualRPM/100)*100)>\(r($0.targetRPM/100)*100)" }
    let fanStr = fanParts.joined(separator: ",")
    let pctStr: String
    if let percs = s.appliedPercents {
        pctStr = percs.map { String(r($0)) }.joined(separator: ",")
    } else {
        pctStr = String(r(s.appliedPercent))
    }
    let ssdStr = s.sensors.ssd.map { String(r($0)) } ?? "-"
    let batStr = s.onBattery == true ? "b" : (s.onBattery == false ? "p" : "-")
    let overrideStr = s.batteryOverride == true ? "1" : (s.batteryOverride == false ? "0" : "-")
    let nightStr = s.nightOverride == true ? "N" : (s.nightOverride == false ? "-" : "-")
    let envStr = s.envTemp.map { String(r($0)) } ?? "-"
    let reasonStr = s.reason?.rawValue ?? "-"
    let intentStr = s.aiIntent?.rawValue ?? "-"
    let faultStr = s.controlFault == true ? "FAULT" : "ok"
    let faultReasonStr = s.faultReason?.rawValue ?? "-"
    let curveStr = s.curveTargetPercent.map { String(r($0)) } ?? "-"
    let unreachStr = s.targetUnreachable == true ? "UNREACH" : "ok"
    let learnStr = (s.learningRecently == true ? "L" : "-") + ":\(s.learnedPoints ?? 0)"
    let powerStr = s.powerWatts.map { String(r($0)) } ?? "-"
    let aiTargetStr = s.aiTargetEffective.map { String(r($0)) } ?? "-"
    // v3.6.1：补齐此前遗漏的变化感知字段——掌托补偿/包络健康度单独变化时
    // 此前不触发写盘，App/fanprobe 只能等 10s 心跳（learnEnvelopeGap 是 v3.6
    // 观察指标，陈旧显示会误导自愈判断）。palmRest/heatsink 取整后噪声不敏感
    let palmRestStr = s.sensors.palmRest.map { String(r($0)) } ?? "-"
    let heatsinkStr = s.sensors.heatsink.map { String(r($0)) } ?? "-"
    let palmCompStr = s.palmComp.map { String(r($0 * 10)) } ?? "-"
    let envGapStr = s.learnEnvelopeGap.map { String(r($0)) } ?? "-"
    return [
        String(r(s.sensors.cpuDie)),
        String(r(s.sensors.gpuDie)),
        ssdStr,
        s.mode.rawValue,
        pctStr,
        fanStr,
        batStr,
        overrideStr,
        nightStr,
        envStr,
        reasonStr,
        intentStr,
        faultStr,
        faultReasonStr,
        curveStr,
        unreachStr,
        learnStr,
        powerStr,
        aiTargetStr,
        palmRestStr,
        heatsinkStr,
        palmCompStr,
        envGapStr
    ].joined(separator: "|")
}
