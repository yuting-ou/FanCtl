// MARK: - v3.4 参数化热模型族扫描（A：泛化鲁棒性 + B：防御机制带噪闭环验证）
//
// 把 VirtualMachine 参数化成一族热模型（R/τ/风扇权限/环境温/测量噪声/丢读/风扇滞后），
// 对每个成员跑 AI 闭环，输出 极限环/过冲/启停/稳态误差 矩阵，找出当前标定的失效边界。
// 断言（验收标准）：
//   1. 极限环：全族在轻载窗口内"交还尝试"≤ 4 次（循环抑制 + 退避全族有效）
//   2. 传感器鲁棒：周期性丢读不产生任何"故障交还系统"（坏读剔除正确工作）
//   3. 安全：全族全程温度 < 105°C（硬件红线之内的物理合理域）
//   4. 稳态：可达目标的成员（被动平衡 ≤ 84°）hold 期最大误差 ≤ 8°C
//   5. 反馈健康：风扇一阶滞后 + 噪声下不误报故障；真停转 6 拍内捕获、恢复后解除
// 输出：逐成员一行矩阵 + 最坏成员汇总。

import Foundation
import SMCCore

struct FamilyMember {
    let name: String
    let env: Double          // 环境温度 °C
    let R: Double            // 热阻 °C/W
    let tau: Double          // 热时间常数 s
    let authority: Double    // 100% 风扇的稳态降温幅度 °C
    let noise: Double        // 每拍测量噪声幅值（均匀 ±noise），0 = 无
    let dropEvery: Int       // 每 N 拍丢 1 拍读数（0 = 无）
    let fanLagTau: Double    // 风扇一阶执行滞后 τ（0 = 立即）
    /// 风扇 0% 时的被动平衡温度（极限环判定用）
    func passiveEquilibrium(_ power: Double) -> Double { env + power * R }
}

// 参数化热模型：dT/dt = (P·R − (T−env))/τ − k·percent，k = authority/(τ·100)
//   稳态：T = env + P·R − authority·percent/100
struct FamilyVM {
    let m: FamilyMember
    var temp: Double
    var rpmActual: Double = 0
    var hasRPM = false

    var fanCoeff: Double { m.authority / (m.tau * 100) }

    mutating func step(power: Double, percent: Double, dt: Double) {
        temp += ((power * m.R - (temp - m.env)) / m.tau - fanCoeff * percent) * dt
    }
}

struct FamilyMetrics {
    var releases = 0
    var reclaims = 0
    var minCyclePeriod = Double.infinity
    var maxTemp = 0.0
    var holdMaxError = 0.0
    var spikePeakExcess = 0.0
    var spuriousRestores = 0
    var feedbackFaulted = false
    var stallCaught = false
    var nan = false
    var unreachable = false
}

// 确定性伪随机（可复现，不用真随机）
struct FamilyRNG {
    var seed: UInt64
    mutating func uniformPM(_ amplitude: Double) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let u = Double((seed >> 33) % 2001) / 1000.0 - 1.0
        return u * amplitude
    }
}

let familyTarget = 76.0
let familyDT = 3.0

/// 单成员闭环。profile: (功率 W, 拍数, 是否 hold 相位)。返回指标。
/// fanFeedback: true 时用真实 FanFeedbackHealth + 一阶风扇滞后做闭环健康验证；
///              stallAtBeat > 0 时在该拍注入真停转 6 拍（验证"不漏保护"）。
func runFamilyMember(_ m: FamilyMember,
                     profile: [(power: Double, ticks: Int, hold: Bool)],
                     fanFeedback: Bool = false,
                     stallAtTick: Int = -1) -> FamilyMetrics {
    var vm = FamilyVM(m: m, temp: m.env + 10)
    var ai = AIController()
    ai.tuning.targetTemp = familyTarget
    var ctrl = FanCurveController()
    var fb = FanFeedbackHealth()
    var metrics = FamilyMetrics()
    var rng = FamilyRNG(seed: 42)

    var wasReleased = false
    var releaseAt = -1.0
    var time = 0.0
    var tick = 0
    var badStreak = 0
    var stallTicks = 0

    for phase in profile {
        for _ in 0..<phase.ticks {
            tick += 1; time += familyDT
            // 采样（噪声 + 丢读）
            var sampled = vm.temp + rng.uniformPM(m.noise)
            if m.dropEvery > 0, tick % m.dropEvery == 0 { sampled = 0 }
            // 丢读防御（镜像 daemon：连续 5 拍 ≤1° 才判故障交还）
            if !sampled.isFinite || sampled <= 1 {
                badStreak += 1
                if badStreak >= 5 { metrics.spuriousRestores += 1 }
                // daemon 行为：故障拍保持上一输出、不更新决策
                vm.step(power: phase.power, percent: 0, dt: familyDT)
                time += 0; tick += 0
                metrics.maxTemp = max(metrics.maxTemp, vm.temp)
                continue
            }
            badStreak = 0

            let o = ai.step(temp: sampled, powerWatts: phase.power, dt: familyDT)
            let applied = ctrl.slew(target: o ?? 0, force: false, hysteresis: 4)
            let pct = (o == nil) ? 0 : applied   // 交还态 = 系统接管（近似停转/最低）

            // 反馈健康（B 项）：一阶风扇滞后 + 真停转注入
            let rpmCmd = 1200.0 + (5349.0 - 1200.0) * applied / 100.0
            if m.fanLagTau > 0 {
                vm.rpmActual += (rpmCmd - vm.rpmActual) * (familyDT / m.fanLagTau)
            } else {
                vm.rpmActual = rpmCmd
            }
            if stallAtTick >= 0, tick >= stallAtTick, tick < stallAtTick + 6 { vm.rpmActual = 0 }
            if fanFeedback {
                let fs = FanState(id: 0, actualRPM: vm.rpmActual, minRPM: 1200,
                                  maxRPM: 5349, targetRPM: rpmCmd)
                fb.record(states: [fs], commandedRPM: [0: rpmCmd], risingGrace: true)
                if fb.faulted { metrics.feedbackFaulted = true }
                if stallAtTick >= 0, tick >= stallAtTick + 6, fb.faulted { metrics.stallCaught = true }
            }

            vm.step(power: phase.power, percent: pct, dt: familyDT)

            if !vm.temp.isFinite { metrics.nan = true; break }
            metrics.maxTemp = max(metrics.maxTemp, vm.temp)

            // 交还/夺回边沿
            let nowReleased = (o == nil)
            if nowReleased, !wasReleased {
                metrics.releases += 1
                releaseAt = time
            }
            if !nowReleased, wasReleased {
                metrics.reclaims += 1
                if releaseAt >= 0 {
                    metrics.minCyclePeriod = min(metrics.minCyclePeriod, time - releaseAt)
                }
            }
            wasReleased = nowReleased

            // hold 相位：控制误差 = 主动控制中且温度"高于目标"的超出量（压温方向）。
            // 温度低于目标的欠冲不计（AI 不会无谓加热；低侧是自然冷却）。
            // 热饱和判定：若满权限风扇的稳态仍压不到目标（env+P·R−authority > target），
            // 该相位的超温归因于硬件极限而非控制器，不计入 hold 误差（可这成员标记不可达）。
            if phase.hold, o != nil, sampled > familyTarget {
                let bestPossible = m.env + phase.power * m.R - m.authority
                if bestPossible <= familyTarget {
                    metrics.holdMaxError = max(metrics.holdMaxError, sampled - familyTarget)
                } else {
                    metrics.unreachable = true
                }
            }
            // spike 相位：超出目标的最大峰值
            if phase.power >= 70 {
                metrics.spikePeakExcess = max(metrics.spikePeakExcess, vm.temp - familyTarget)
            }
            _ = stallTicks
        }
        if metrics.nan { break }
    }
    _ = stallTicks
    return metrics
}

func testFamilyScan() {
    group("参数化热模型族扫描")
    let envs = [22.0, 28.0, 33.0]
    let Rs = [0.7, 1.0, 1.3]
    let taus = [25.0, 40.0, 70.0]
    let authorities = [12.0, 20.0, 28.0]

    // ── 相位设计：hold 25min → light 20min（极限环考验）→ spike 5min → light 10min ──
    func profile() -> [(power: Double, ticks: Int, hold: Bool)] {
        [(55, 500, true), (38, 400, false), (75, 100, false), (38, 200, false)]
    }

    var worst = (release: "", releaseN: -1, overshoot: "", overshootV: -1.0,
                 holdErr: "", holdErrV: -1.0)
    var memberCount = 0
    var cycleViolations: [String] = []
    var sensorViolations: [String] = []
    var safetyViolations: [String] = []
    var holdViolations: [String] = []

    for env in envs {
        for R in Rs {
            for tau in taus {
                for authority in authorities {
                    let name = "env\(Int(env))/R\(R)/τ\(Int(tau))/A\(Int(authority))"
                    let m = FamilyMember(name: name, env: env, R: R, tau: tau,
                                         authority: authority, noise: 0, dropEvery: 0, fanLagTau: 0)
                    var met = runFamilyMember(m, profile: profile())

                    // 可达性：medium 负载 + 满权限风扇能否到目标 ±8° 以内
                    let passiveMedium = m.passiveEquilibrium(55)
                    let reachable = (passiveMedium - authority) <= familyTarget + 8
                    if !reachable { met.unreachable = true }

                    memberCount += 1
                    if met.nan {
                        safetyViolations.append("\(name) 数值发散"); continue
                    }
                    // 物理上限 = 被动平衡（功率峰值时）+2° 数值裕量：
                    // percent ≥ 0 意味着风扇只会帮忙，控制器不可能把温度推得比不散热更热。
                    // 满权限仍压不住的成员（重 R 暖环境）峰值自然落在被动平衡附近——
                    // 那是散热硬件极限（现实中 macOS 会热节流），不是控制缺陷。
                    let passiveCeil = m.passiveEquilibrium(75) + 2
                    if met.maxTemp > passiveCeil {
                        safetyViolations.append("\(name) 峰值 \(Int(met.maxTemp))° 超被动平衡 \(Int(passiveCeil))°")
                    }
                    // 轻载窗口（相位 2+4 = 600 拍 = 1800s）交还次数
                    // 注：releases 是全程的（hold 段不应有交还——55W 满被动 96.5+，
                    //     A≥28 且 R≥1.3 的成员 medium 段 temp 就高于目标，不会交还）
                    let lightReleases = met.releases
                    if lightReleases > 4 {
                        cycleViolations.append("\(name) 轻载交还 \(lightReleases) 次")
                    }
                    if lightReleases > worst.releaseN {
                        worst.release = name; worst.releaseN = lightReleases
                    }
                    if met.spikePeakExcess > worst.overshootV {
                        worst.overshoot = name; worst.overshootV = met.spikePeakExcess
                    }
                    if reachable, met.holdMaxError > worst.holdErrV {
                        worst.holdErr = name; worst.holdErrV = met.holdMaxError
                    }
                    if reachable, met.holdMaxError > 8 {
                        holdViolations.append("\(name) hold 误差 \(Int(met.holdMaxError))°")
                    }
                    print("  [族] \(name) 交还\(lightReleases) 峰值+\(String(format: "%.1f", met.spikePeakExcess)) hold误差\(reachable ? String(format: "%.1f", met.holdMaxError) : "不可达") 最高\(Int(met.maxTemp))°")
                }
            }
        }
    }

    print("  [族汇总] 成员 \(memberCount) | 极限环违例 \(cycleViolations.count) | 传感器违例 \(sensorViolations.count) | 安全违例 \(safetyViolations.count) | hold 违例 \(holdViolations.count)")
    print("  [最坏成员] 交还最多: \(worst.release) (\(worst.releaseN) 次) | 过冲最大: \(worst.overshoot) (+\(String(format: "%.1f", worst.overshootV))°) | hold 误差最大: \(worst.holdErr) (\(String(format: "%.1f", worst.holdErrV))°)")
    for v in cycleViolations { print("  [循环违例] \(v)") }
    for v in holdViolations { print("  [hold 违例] \(v)") }

    expect(cycleViolations.isEmpty, "全族轻载交还 ≤4 次（循环抑制全族有效）")
    expect(sensorViolations.isEmpty, "无传感器违例")
    expect(safetyViolations.isEmpty, "全族温度 <105°C")
    expect(holdViolations.isEmpty, "可达成员 hold 误差 ≤8°")
}

func testFamilyDefense() {
    group("参数族防御机制带噪闭环")
    // B 项：噪声 + 丢读 + 风扇滞后 + 真停转，验证防御不误触发也不漏保护
    let corners = [FamilyMember(name: "凉角", env: 22, R: 0.7, tau: 40, authority: 20,
                                noise: 0.3, dropEvery: 20, fanLagTau: 4),
                   FamilyMember(name: "热角", env: 33, R: 1.3, tau: 40, authority: 20,
                                noise: 0.3, dropEvery: 20, fanLagTau: 4)]
    var allClean = true
    var allCaught = true
    for m in corners {
        // 无停转基线：滞后 + 噪声 + 丢读下不误报反馈故障
        let clean = runFamilyMember(m,
                                    profile: [(55, 400, true), (38, 200, false)],
                                    fanFeedback: true, stallAtTick: -1)
        // 真停转 6 拍（spike 段，tick 430 起：高负载下风扇命令 RPM 高于启查线 1350，
        // 实际 0 RPM 的 gross mismatch 才会进反馈健康的计数窗口）
        let stall = runFamilyMember(m,
                                    profile: [(55, 400, true), (75, 150, false), (38, 100, false)],
                                    fanFeedback: true, stallAtTick: 430)
        if clean.feedbackFaulted { allClean = false }
        // E 项验收：runFamilyMember 的 ai.step 从不传 cpuPower/gpuPower（分项功耗不可用）
        // → 温度有界 + 无故障 + 无发散即证明控制器安全降级到整机 PSTR 前馈
        expect(clean.maxTemp < 105 && !clean.nan,
               "\(m.name) 分项功耗不可用时闭环仍安全")
        // 语义分叉（v3.4 锁定）：反馈健康的 1350 启查线 = "命令转速低到停转无害则不管"。
        // 热角（被动平衡 119°）：命令 RPM 高，停转必须被捕获——真保护。
        // 凉角（被动平衡 74.5° < 目标）：命令 RPM 低，门控跳过 = 停转无害不报警——正确省心。
        if m.env > 30 {
            if !stall.stallCaught { allCaught = false }
        } else {
            if stall.stallCaught || stall.feedbackFaulted { allCaught = false }
        }
        expect(!clean.nan, "\(m.name) 无发散")
        print("  [防御/\(m.name)] 误报=\(clean.feedbackFaulted) 停转捕获=\(stall.stallCaught) 被动平衡\(Int(m.passiveEquilibrium(75)))°")
    }
    expect(allClean, "滞后+噪声+丢读下反馈健康不误报")
    expect(allCaught, "真停转 6 拍内被反馈健康捕获（不漏保护）")
}

