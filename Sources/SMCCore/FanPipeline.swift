import Foundation

// MARK: - 风扇调速决策管线（纯逻辑，守护进程与测试共用）
//
// 把"基础目标 → 实际目标 + 决策主因"的三级覆盖链从 fanctld 主循环抽出：
//   基础模式(auto/curve/AI/manual/电池档) < 静音封顶 < SSD 托底 < 高温兜底
// 静音承诺能压低转速，但安全红线（SSD/高温）后置覆盖、永远能压过它——
// 静音绝不抑制散热安全。
//
// 抽取动机：此前管线内联在 daemon 主循环，测试只能手写"镜像"函数验证，
// 镜像与真实代码会漂移（测试绿 ≠ daemon 对）。现在 daemon 直接调用本函数，
// 测试覆盖的就是被执行的那份代码。

public enum FanPipeline {
    /// 高温兜底阈值：原始读数 ≥ 此温度强制全速（用 raw 而非平滑值，毛刺不漏报）
    public static let failsafeTemp = 92.0
    /// NAND 过热阈值：≥ 此温度托底 60% 拉风道（NAND 颗粒安全温度远低于 CPU）
    public static let ssdGuardTemp = 70.0
    /// NAND 危急阈值：≥ 此温度托底 100%
    public static let ssdCriticalTemp = 78.0
    public static let ssdGuardReleaseTemp = 67.0
    public static let ssdCriticalReleaseTemp = 75.0
    public static let failsafeReleaseTemp = 88.0
    /// 电池过热阈值：≥ 此温度托底 60% 拉风（电池健康/鼓包风险，充电降额线附近）
    public static let batteryGuardTemp = 45.0
    /// 电池危急阈值：≥ 此温度托底 100%（与 SSD 危急档同级：手动模式也不豁免——
    /// manual/curve/ai 覆盖了系统本应对电池高温做出的风扇响应，必须有补偿红线）
    public static let batteryCriticalTemp = 48.0
    public static let batteryGuardReleaseTemp = 43.0
    public static let batteryCriticalReleaseTemp = 46.0

    public struct Decision: Equatable {
        public var targetPercent: Double?    // nil = 交还系统自动调度
        public var reason: ControlReason     // 主决策因素（可解释性）
        public var batteryOverride: Bool     // 电池安静档是否正在生效
        public var nightOverride: Bool       // 夜间安静档是否正在生效（22:00–8:00）
        public var ssdGuard: Bool            // SSD 托底是否生效（daemon 做边沿日志）
        public var failsafeActive: Bool      // 高温兜底是否生效（daemon 做边沿日志）
        public var batteryGuard: Bool        // 电池高温托底是否生效（daemon 做边沿日志）
        public var ssdCriticalActive: Bool
        public var batteryCriticalActive: Bool
        public var baseTargetPercent: Double?
        public var safetyFloorPercent: Double?

        public init(targetPercent: Double?, reason: ControlReason,
                    batteryOverride: Bool = false, nightOverride: Bool = false,
                    ssdGuard: Bool = false,
                    failsafeActive: Bool = false,
                    batteryGuard: Bool = false) {
            self.targetPercent = targetPercent
            self.reason = reason
            self.batteryOverride = batteryOverride
            self.nightOverride = nightOverride
            self.ssdGuard = ssdGuard
            self.failsafeActive = failsafeActive
            self.batteryGuard = batteryGuard
            self.ssdCriticalActive = false
            self.batteryCriticalActive = false
            self.baseTargetPercent = targetPercent
            self.safetyFloorPercent = nil
        }
    }

    /// 体感补偿偏移（v3.3）：palmComp = clamp((掌托−40)×1, 0, +4)，正値 = 目标收紧。
    /// 物理依据：芯片温度是代理指标，用户感知的是掌托；"掌托 − 40°C"是体感超阈值量
    /// （不用掌托−环境，避免与环境补偿双重计账）。风扇对底盘温度控制权限有限，
    /// 钳位 +4 保守。nil/无效/低于 40°（舒适区内）→ 0，零噪声代价。
    public static func palmComp(palmRest: Double?, enabled: Bool) -> Double {
        guard enabled, let palm = palmRest, palm.isFinite, palm > 5, palm < 55 else { return 0 }
        return max(0, min(4, palm - 40))
    }

    /// 环境温度补偿偏移：envOffset = clamp((env−25)×0.5, −5, +8)。
    /// 物理依据：绝对温度 = 环境 + 温升；夏天环境 35°C 时芯片 70°C 只相当于
    /// 冬天环境 15°C 时的 60°C 负载——曲线查表温度应左移（更保守）、
    /// AI 目标应放宽，让同一曲线在冬夏语义一致。负偏移（冬天）收紧，正偏移（夏天）放宽。
    public static func envOffset(envTemp: Double?, enabled: Bool) -> Double {
        guard enabled, let env = envTemp, env.isFinite, env > 5, env <= 45 else { return 0 }
        return max(-5, min(8, (env - 25) * 0.5))
    }

    /// 当前语境下实际生效的曲线（电池档 > 夜间档 > 基础曲线），与 decide() 的选择链一致。
    /// AI 曲线锚定/种子/前馈的基准必须用它：电池省电时 AI 目标放宽 +4°（工作点更热），
    /// 基础曲线在更热温度上的期望值反而更高（均衡曲线 80° 处 ≈78%），用基础曲线锚定
    /// 会把 AI 稳态拉向高转速——与省电意图正相反；夜间安静档同理（目标放宽了，
    /// 锚却在拉响度）。UI 的"曲线基准"刻度也据此展示用户当前真正生效的曲线期望。
    public static func activeCurve(config: FanConfig, onBattery: Bool, nightActive: Bool) -> [CurvePoint] {
        if onBattery, let bp = config.batteryPreset {
            return config.batteryCurve ?? bp.points
        }
        if nightActive && config.quietHours {
            return config.nightCurve ?? CurvePreset.quiet.points
        }
        return config.curve
    }

    /// SSD 托底档位：≥危急→100，≥过热→60，其余（含 ≤1 的坏读）不托底
    public static func ssdFloor(nandTemp: Double) -> Double? {
        guard nandTemp > 1 else { return nil }
        if nandTemp >= ssdCriticalTemp { return 100 }
        if nandTemp >= ssdGuardTemp { return 60 }
        return nil
    }

    public static func ssdState(nandTemp: Double, wasGuardActive: Bool,
                                wasCriticalActive: Bool) -> (guardActive: Bool, criticalActive: Bool, floor: Double?) {
        guard nandTemp.isFinite, nandTemp > 1 else { return (false, false, nil) }
        let critical = wasCriticalActive
            ? nandTemp >= ssdCriticalReleaseTemp
            : nandTemp >= ssdCriticalTemp
        let guardActive = critical || (wasGuardActive
            ? nandTemp >= ssdGuardReleaseTemp
            : nandTemp >= ssdGuardTemp)
        return (guardActive, critical, critical ? 100 : (guardActive ? 60 : nil))
    }

    /// 电池托底档位：≥危急→100，≥过热→60，其余（含 ≤1 的坏读/无电池键的 0）不托底
    public static func batteryState(battTemp: Double, wasGuardActive: Bool,
                                    wasCriticalActive: Bool) -> (guardActive: Bool, criticalActive: Bool, floor: Double?) {
        guard battTemp.isFinite, battTemp > 1 else { return (false, false, nil) }
        let critical = wasCriticalActive
            ? battTemp >= batteryCriticalReleaseTemp
            : battTemp >= batteryCriticalTemp
        let guardActive = critical || (wasGuardActive
            ? battTemp >= batteryGuardReleaseTemp
            : battTemp >= batteryGuardTemp)
        return (guardActive, critical, critical ? 100 : (guardActive ? 60 : nil))
    }

    /// 完整管线决策。
    /// - Parameters:
    ///   - smoothedTemp: 平滑后温度（曲线插值/AI 判定的输入）
    ///   - rawTemp: 原始读数（兜底判据，不经平滑以免毛刺漏报）
    ///   - nandTemp: SSD/NAND 温度（托底判据）
    ///   - aiPercent: AI 控制器本拍输出。AI 的积分状态留在 daemon（有状态），
    ///     管线保持无状态纯函数；非 .ai 模式传 nil
    public static func decide(config: FanConfig,
                              smoothedTemp: Double,
                              rawTemp: Double,
                              nandTemp: Double,
                              onBattery: Bool,
                              aiPercent: Double?,
                              now: Date,
                              nightActive: Bool = false,
                              envTemp: Double? = nil,
                              palmComp: Double = 0,
                              wasSSDGuardActive: Bool = false,
                              wasSSDCriticalActive: Bool = false,
                              wasFailsafeActive: Bool = false,
                              battTemp: Double = 0,
                              wasBatteryGuardActive: Bool = false,
                              wasBatteryCriticalActive: Bool = false) -> Decision {
        var target: Double? = nil
        var reason: ControlReason = .auto
        var batteryOverride = false
        var nightOverride = false
        // 环境温度补偿（v8）：曲线查表温度左移，让绝对温度曲线在冬夏语义一致
        let envOff = envOffset(envTemp: envTemp, enabled: config.envCompensation)

        switch config.mode {
        case .auto:
            break   // 交还系统，target 保持 nil
        case .curve:
            if onBattery, let bp = config.batteryPreset {
                batteryOverride = true
                reason = .battery
                // AI 个性化过的电池档曲线优先，没有则用出厂预设点。
                // 查表温度同样减 envOff：环境补偿是"绝对温度→温升"的语义修正，
                // 电池档不能豁免（夏天电池模式查表温度偏高 → 风扇无谓激进），与日间/夜间一致。
                // 体感补偿不参与电池/夜间档：它们是明确的安静意图，不被体感覆盖
                target = FanConfig.percent(temp: smoothedTemp - envOff,
                                           curve: config.batteryCurve ?? bp.points)
            } else if nightActive && config.quietHours {
                // 夜间安静档：22:00–8:00 自动切安静曲线（不干预电池档）
                nightOverride = true
                reason = .night
                target = FanConfig.percent(temp: smoothedTemp - envOff,
                                           curve: config.nightCurve ?? CurvePreset.quiet.points)
            } else {
                reason = .curve
                // 体感补偿（v3.3）：掌托超阈值 → 查表温度右移（更早介入更强散热）
                target = config.percentFor(temp: smoothedTemp - envOff + palmComp)
            }
        case .ai:
            reason = .ai
            target = aiPercent
        case .manual:
            reason = .manual
            target = config.manualPercent
        }

        let baseTarget = target

        // 静音承诺（会议模式）：截止前把输出压到上限；过期/未设/无输出(nil)不限
        if let until = config.quietUntil, let cap = config.quietCapPercent,
           now < until, let t = target {
            if cap < t { reason = .quiet }   // 仅当静音真正压低了输出才计为主因
            target = min(t, cap)
        }

        // SSD 高温托底：大量拷贝时 CPU 不热但 SSD 发烫。
        // 危急档（≥78°C→100%）是硬件安全红线，对所有非 auto 模式生效——手动模式也不例外，
        //   因为 NAND 颗粒临界温度远低于 CPU，92°C 兜底为时过晚。
        // 警告档（≥70°C→60%，主动拉风道）仅 curve/ai 介入，不干预手动固定意图。
        // auto 模式豁免：风扇本就由系统调度。
        var ssdGuard = false
        var ssdCritical = false
        var safetyFloor: Double? = nil
        if config.mode != .auto {
            let state = ssdState(nandTemp: nandTemp, wasGuardActive: wasSSDGuardActive,
                                 wasCriticalActive: wasSSDCriticalActive)
            // 手动模式只接受 SSD 危急安全红线；普通警告档不介入，也不标记为 active。
            let appliesGuard = state.criticalActive || config.mode == .curve || config.mode == .ai
            ssdGuard = state.guardActive && appliesGuard
            ssdCritical = state.criticalActive
            if appliesGuard, let f = state.floor {
                safetyFloor = max(safetyFloor ?? f, f)
                // 仅当托底真正抬高了输出（成为主导）才计为主因
                if f > (target ?? 0) { reason = .ssd }
                target = max(target ?? 0, f)
            }
        }

        // 电池高温托底：与 SSD 托底同构。电池是最怕热的部件（健康度/鼓包风险），
        // 而 manual/curve/ai 覆盖了系统本应对电池高温做出的风扇响应——必须有补偿红线。
        // 危急档（≥48°C→100%）对所有非 auto 模式生效（手动模式不豁免）；
        // 警告档（≥45°C→60%）仅 curve/ai 介入；auto 模式豁免（含系统自己的充电热策略）。
        var batteryGuard = false
        var batteryCritical = false
        if config.mode != .auto {
            let bstate = batteryState(battTemp: battTemp, wasGuardActive: wasBatteryGuardActive,
                                      wasCriticalActive: wasBatteryCriticalActive)
            let appliesGuard = bstate.criticalActive || config.mode == .curve || config.mode == .ai
            batteryGuard = bstate.guardActive && appliesGuard
            batteryCritical = bstate.criticalActive
            if appliesGuard, let f = bstate.floor {
                safetyFloor = max(safetyFloor ?? f, f)
                if f > (target ?? 0) { reason = .batteryHot }
                target = max(target ?? 0, f)
            }
        }

        // 高温兜底：优先级最高，超阈值强制全速并清电池/夜间覆盖标记（避免 UI 误显示"安静档生效中"）。
        // auto 模式豁免：风扇本就由系统调度
        var failsafe = config.mode != .auto && (wasFailsafeActive
            ? rawTemp >= failsafeReleaseTemp
            : rawTemp >= failsafeTemp)
        if failsafe {
            target = 100
            reason = .failsafe
            batteryOverride = false
            nightOverride = false
            failsafe = true
        }

        var result = Decision(targetPercent: target, reason: reason,
                        batteryOverride: batteryOverride, nightOverride: nightOverride,
                        ssdGuard: ssdGuard,
                        failsafeActive: failsafe,
                        batteryGuard: batteryGuard)
        result.ssdCriticalActive = ssdCritical
        result.batteryCriticalActive = batteryCritical
        result.baseTargetPercent = baseTarget
        result.safetyFloorPercent = failsafe ? 100 : safetyFloor
        return result
    }
}
