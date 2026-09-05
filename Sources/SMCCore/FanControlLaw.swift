import Foundation

// MARK: - 风扇调度控制律（纯逻辑，守护进程与仿真共用）
//
// 把"温度 → 实际施加百分比"的调速手感逻辑集中在这里，与 SMC 读写、日志、
// 兜底/SSD 托底等编排分离，便于用温度轨迹仿真量化抖动/响应/回落，数据驱动调参。
//
// 两段式：
//   smooth(rawTemp:) —— 坏读剔除 + 升快降慢的指数平滑，输出平滑温度（曲线/兜底判据）
//   shape(target:)   —— 对目标百分比施加降速限速 + 输出死区，得到实际写入值
// 之所以拆两段：平滑发生在"查曲线"之前，而限速/死区作用在 SSD 托底、高温兜底
// 等覆盖生效之后的最终目标上，顺序与守护进程一致。

public struct FanControlTuning: Equatable {
    public var loopInterval: Double = 3.0     // 主循环周期（秒），仿真用
    public var alphaUp: Double = 0.35         // 升温 EMA 系数（大=响应快）
    public var alphaDown: Double = 0.2        // 降温 EMA 系数（小=回落稳）
    public var maxStepDown: Double = 6.0      // 降速限速（%/循环），升速不限
    public var maxStepUp: Double = 8.0        // 升速限速（%/循环）：与降速对称，抑制负载波动引起的"启停"抖动。
                                              //   原实现只限降速、升速瞬时抬升，负载稍一波动风扇就猛升缓降反复循环，
                                              //   频繁变转会加速风扇轴承磨损。加升速限速后升降都平滑，减少启停冲击。
                                              //   安全事件（SSD/高温兜底）经 shape(force:) 跳过限速，仍需瞬时全速。
    public var pctDeadband: Double = 5.0      // 输出死区（%）：小幅波动维持原输出
    public var glitchDrop: Double = 30.0      // 单周期骤降超过此值判为坏读（°C）
    public var glitchMaxHold: Int = 3         // 坏读最多连续沿用几拍
    public var settleBoostDrop: Double = 8.0  // 平滑温度较峰值回落超过此值，判定"负载已结束"
    public var alphaSettle: Double = 0.45     // 负载结束后的加速回落 EMA 系数

    public init() {}
}

public struct FanCurveController {
    public var tuning: FanControlTuning
    public private(set) var smoothedTemp: Double?
    public var lastAppliedPercent: Double?
    private var glitchCount = 0
    private var peakSinceRise: Double?   // 本轮升温以来的平滑温度峰值（判负载结束用）

    public init(tuning: FanControlTuning = FanControlTuning()) { self.tuning = tuning }

    // 坏读剔除 + 指数平滑。返回 nil 表示本拍为坏读（骤降），调用方应保持上一拍、不写。
    public mutating func smooth(rawTemp: Double) -> Double? {
        // 防御：非有限值（NaN/Inf）不入平滑，否则会把 smoothedTemp 污染成 NaN 永久卡死
        guard rawTemp.isFinite else { return smoothedTemp }
        if let prev = smoothedTemp, rawTemp < prev - tuning.glitchDrop, glitchCount < tuning.glitchMaxHold {
            glitchCount += 1
            return nil
        }
        glitchCount = 0
        guard let prev = smoothedTemp else {
            smoothedTemp = rawTemp
            peakSinceRise = rawTemp
            return rawTemp
        }
        let alpha: Double
        if rawTemp > prev {
            alpha = tuning.alphaUp
        } else {
            // 负载明显结束（已从峰值回落 settleBoostDrop）后加速回落，缩短"任务做完风扇仍响"；
            // 仅小幅波动时维持慢平滑，避免抖动。
            let peak = peakSinceRise ?? prev
            alpha = (peak - rawTemp >= tuning.settleBoostDrop) ? tuning.alphaSettle : tuning.alphaDown
        }
        let next = prev + alpha * (rawTemp - prev)
        smoothedTemp = next
        // 峰值跟踪：上升刷新峰值；显著回落后重置峰值锚点，为下一次尖峰做准备
        if next >= (peakSinceRise ?? next) {
            peakSinceRise = next
        } else if (peakSinceRise ?? next) - next >= tuning.settleBoostDrop {
            peakSinceRise = next
        }
        return next
    }

    // 升降速限速 + 输出死区。target 为经曲线/手动 + SSD/兜底覆盖后的最终目标百分比。
    // force=true（安全事件：SSD 托底/高温兜底）时跳过限速与死区，瞬时写满目标——安全优先级最高，
    // 不能因平滑升速而延误全速散热。
    // 入口统一钳位 [0,100]（与 slew 对齐）：损坏配置（sanitized 前的坏点）可能插值出越界值，
    // 透传会污染 lastAppliedPercent 导致风扇被钉满速
    public mutating func shape(target: Double, force: Bool = false) -> Double {
        let t = max(0, min(100, target))
        if force {
            lastAppliedPercent = t
            return t
        }
        var pct = t
        if let last = lastAppliedPercent {
            if pct > last { pct = min(pct, last + tuning.maxStepUp) }     // 升速限速（缓慢上升）
            if pct < last { pct = max(pct, last - tuning.maxStepDown) }   // 降速限速（缓慢下降）
            if pct != 100 && pct != 0 && abs(pct - last) < tuning.pctDeadband { pct = last }  // 死区（0%/满速边界不受限：0%=停转意图、100%=满速兜底，卡在 1-4% 或 97-99% 都违背目标语义）
        }
        lastAppliedPercent = pct
        return pct
    }

    // 切回系统自动：清空输出记忆（下次重新接管从头限速）
    public mutating func clearOutput() { lastAppliedPercent = nil }

    // 纯升降速限速（不含死区）。供 AI 模式用——AI 控制器本身是平滑积分 PD，
    // 不能再用 shape() 的死区（死区会吞噬 AI 的 1-4% 微调、与 PD 叠加易振荡），
    // 只需加 slew-rate 限制，与曲线模式共用同一套 maxStepUp/maxStepDown，保证"缓慢升降"规律一致。
    // force=true（SSD/高温兜底）跳过限速，瞬时写满目标——安全优先级最高。
    // 注意：AI 空闲交还时 lastAppliedPercent 被 clearOutput 清空，重新接管（负载回来）时
    // last 为 nil 直接到位，不限制"夺回"路径，保证负载突增时响应不滞后。
    // v3.2 迟滞带（hysteresis > 0 时生效）：限速后的变化小于带宽时维持原写入。
    // 物理依据：热系统 τ≈40s >> 3s 控制拍，AI 输出每拍 3-8% 的变化属于过度响应
    //（实测 2000-3000 次/天 ≥3% 调速）。只延迟"写入"，AI 决策积分（output）独立
    // 演化不受影响——温度误差持续存在时输出终将越过带缘，精度损失 ≤ 带宽×b。
    // force（安全事件）跳过一切限速/迟滞，瞬时写满。
    public mutating func slew(target: Double, force: Bool = false, hysteresis: Double = 0) -> Double {
        var pct = max(0, min(100, target))   // 入口钳位（含 force 分支，与 shape 对齐）
        if force {
            lastAppliedPercent = pct
            return pct
        }

        if let last = lastAppliedPercent {
            if pct > last { pct = min(pct, last + tuning.maxStepUp) }
            if pct < last { pct = max(pct, last - tuning.maxStepDown) }
            // v3.6.1 迟滞带边界豁免（与 shape() 死区对齐）：候选 100 时必须写满——
            // 否则 AI 积分钳顶后 last 可能滞留在 97-99（如爬坡步进恰好落在 97），
            // |100-last| < 带宽永远 hold，风扇钉在 97% 且 saturated(≥98) 检测失灵，
            // "AI 目标压不住"状态永不触发。0 侧同理（AI 输出趋 0 时滞留 1-3%）。
            if hysteresis > 0, pct != 100, pct != 0, abs(pct - last) < hysteresis { pct = last }
        }
        lastAppliedPercent = pct
        return pct
    }
    // 睡眠唤醒：平滑温度缓存作废，下一拍重新起平滑
    public mutating func invalidateTemp() { smoothedTemp = nil; peakSinceRise = nil }
}

// MARK: - App 侧温度毛刺剔除（纯逻辑，App 与测试共用）
// status.json 原子写时个别读（≤1 或骤降>30°C）为写瞬间截断，沿用上一拍有效值。
// 参数化 glitchHold/zeroHold 使 CPU/GPU 独立计数，避免一个传感器毛刺消耗另一个的额度。
public func deglitchTemperature(_ raw: Double, prev: Double,
                                glitchHold: inout Int, zeroHold: inout Int,
                                glitchDrop: Double = 30.0, maxHold: Int = 3) -> Double {
    // 非有限值（手改/损坏的 status.json）不入 UI，避免 Int() trap 崩溃
    guard raw.isFinite else { return prev }
    if prev > 1 {
        if raw <= 1 {
            // daemon 传感器故障时持续写 0：挡 maxHold 拍后采信（UI 显示 0/故障态），
            // 否则旧温度(可能 ≥90°)被无限期沿用,checkOverheat 会反复误发高温通知
            if zeroHold < maxHold { zeroHold += 1; return prev }
            zeroHold = 0
            return raw
        }
        zeroHold = 0
        if raw < prev - glitchDrop {
            // 与 daemon smooth() 的 glitchMaxHold 对齐：连续 maxHold 拍仍异常则采信，
            // 避免真实大幅降温（负载结束）被无限期遮蔽
            if glitchHold < maxHold { glitchHold += 1; return prev }
            glitchHold = 0
            return raw
        }
    }
    glitchHold = 0
    zeroHold = 0
    return raw
}

// MARK: - 学习稳态门（daemon 与测试共用）
//
// 热经验稳态采样的判定阈值按"秒"标定（°C/s、%/s）：自适应循环间隔 1~20s 下语义恒定。
// 此前按"每拍"比较（<0.35°/拍、<3%/拍），间隔 3→10s 漂移时按秒严格度变化 ~3.3 倍，
// 样本会系统性偏向短间隔（繁忙）时段。0.12°C/s ≈ 3s 标称拍 0.35°/拍 的秒语义。
// shaped 残留比较保持每拍语义：slew/shape 限速本身就是 %/拍。
public enum LearningGate {
    public static let tempRatePerSec = 0.12       // 温度变化率阈值（°C/s）
    public static let targetRatePerSec = 1.0      // 基础目标变化率阈值（%/s）
    public static let shapedGapPercent = 3.0      // shaped 与 base 的限速残留上限（%）

    public static func isSteady(temp: Double, prevTemp: Double,
                                baseTarget: Double, prevBase: Double,
                                shapedBase: Double, dt: Double) -> Bool {
        // dt 防御（NaN 穿透比较；睡眠唤醒超大间隔钳到 [0.5, 20]——20 对齐 idle 最大间隔，
        // 否则 idle 长拍按 15 结算会把 °C/s 阈值放宽 ~25%）
        guard temp.isFinite, prevTemp.isFinite, baseTarget.isFinite,
              prevBase.isFinite, shapedBase.isFinite, dt.isFinite else { return false }
        let dtn = min(max(dt, 0.5), 20.0)
        return abs(temp - prevTemp) / dtn < tempRatePerSec
            && abs(baseTarget - prevBase) / dtn < targetRatePerSec
            && abs(baseTarget - shapedBase) < shapedGapPercent
    }
}
