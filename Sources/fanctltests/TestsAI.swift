// 测试按模块拆分（v3.3.1）：本文件为各模块共享的 harness 与主入口。
// 断言 harness 见 main.swift，共享构造（MockSMC/FakeClock/makeEngine）见 TestsEngine.swift 头部。
import Foundation
import SMCCore

func testControlLaw() {
    group("控制律")
    // 坏读：骤降>30 返回 nil 并 hold，连续 3 拍后采信
    var c = FanCurveController()
    _ = c.smooth(rawTemp: 70)
    expect(c.smooth(rawTemp: 30) == nil, "骤降判坏读1")
    expect(c.smooth(rawTemp: 30) == nil, "骤降判坏读2")
    expect(c.smooth(rawTemp: 30) == nil, "骤降判坏读3")
    expect(c.smooth(rawTemp: 30) != nil, "第4拍采信")

    // shape：升降速双向限速 + 死区
    var c2 = FanCurveController(); _ = c2.smooth(rawTemp: 60)
    expectEqual(c2.shape(target: 50), 50, "首次直接应用")
    expectEqual(c2.shape(target: 100), 58, "升速限 8/拍（缓慢上升）")   // 50+8
    expectClose(c2.shape(target: 50), 52, 1e-9, "降速限 6/拍")          // 58-6
    var c3 = FanCurveController(); _ = c3.smooth(rawTemp: 60); _ = c3.shape(target: 40)
    expectEqual(c3.shape(target: 43), 40, "死区内维持")
    // force=true（SSD/高温兜底）跳过升速限速，安全事件必须瞬时全速
    var c4 = FanCurveController(); _ = c4.smooth(rawTemp: 60); _ = c4.shape(target: 40)
    expectEqual(c4.shape(target: 100, force: true), 100, "安全事件跳过升速限速，瞬时写满")
    // v8: shape 入口钳位 [0,100]——损坏配置插值出越界值时不再污染 lastAppliedPercent
    var c5 = FanCurveController(); _ = c5.smooth(rawTemp: 60); _ = c5.shape(target: 40)
    expectEqual(c5.shape(target: 450), 48, "越界目标钳到 100 再限速（40+8）")
    expectEqual(c5.lastAppliedPercent, 48, "lastAppliedPercent 不被越界值污染")
    var c6 = FanCurveController(); _ = c6.smooth(rawTemp: 60); _ = c6.shape(target: 40)
    expectEqual(c6.shape(target: -50, force: true), 0, "force 路径也钳位（负值→0）")

    // slew：AI 模式缓慢升降（无死区），与曲线准则一致
    var a1 = FanCurveController(); _ = a1.slew(target: 40)
    expectEqual(a1.slew(target: 100), 48, "AI 升速限 8/拍（缓慢上升）")   // 40+8
    expectClose(a1.slew(target: 40), 42, 1e-9, "AI 降速限 6/拍")          // 48-6
    // AI 安全事件跳过限速
    var a2 = FanCurveController(); _ = a2.slew(target: 40)
    expectEqual(a2.slew(target: 100, force: true), 100, "AI 安全事件瞬时全速")
    // AI 空闲交还后再夺回（last 已清空）：负载回来直接到位，不限制夺回路径
    var a3 = FanCurveController(); _ = a3.slew(target: 40); a3.clearOutput()
    expectEqual(a3.slew(target: 80), 80, "AI 夺回不走限速（last 已清）")

    // deglitchTemperature：App 侧毛刺剔除（从 FanModel 提取到 SMCCore）
    do {
        var gh = 0, zh = 0
        expectClose(deglitchTemperature(70, prev: 68, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: 正常值通过")
        expect(gh == 0 && zh == 0, "deglitch: 正常值不触发 hold")
    }
    do {
        var gh = 0, zh = 0
        expectClose(deglitchTemperature(.nan, prev: 70, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: NaN 返回 prev")
        expectClose(deglitchTemperature(.infinity, prev: 70, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: Inf 返回 prev")
    }
    do {
        var gh = 0, zh = 0
        _ = deglitchTemperature(70, prev: 70, glitchHold: &gh, zeroHold: &zh)
        expectClose(deglitchTemperature(0, prev: 70, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: 零值 hold 第1拍")
        expect(zh == 1, "deglitch: zeroHold 递增")
        expectClose(deglitchTemperature(0, prev: 70, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: 零值 hold 第2拍")
        expectClose(deglitchTemperature(0, prev: 70, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: 零值 hold 第3拍")
        expectClose(deglitchTemperature(0, prev: 70, glitchHold: &gh, zeroHold: &zh), 0, 1e-9, "deglitch: 零值第4拍采信")
        expect(zh == 0, "deglitch: zeroHold 重置")
    }
    do {
        var gh = 0, zh = 0
        _ = deglitchTemperature(70, prev: 70, glitchHold: &gh, zeroHold: &zh)
        expectClose(deglitchTemperature(30, prev: 70, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: 骤降 hold 第1拍")
        expect(gh == 1, "deglitch: glitchHold 递增")
        expectClose(deglitchTemperature(30, prev: 70, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: 骤降 hold 第2拍")
        expectClose(deglitchTemperature(30, prev: 70, glitchHold: &gh, zeroHold: &zh), 70, 1e-9, "deglitch: 骤降 hold 第3拍")
        expectClose(deglitchTemperature(30, prev: 70, glitchHold: &gh, zeroHold: &zh), 30, 1e-9, "deglitch: 骤降第4拍采信")
        expect(gh == 0, "deglitch: glitchHold 重置")
    }
    do {
        var gh = 0, zh = 0
        _ = deglitchTemperature(70, prev: 70, glitchHold: &gh, zeroHold: &zh)
        expectClose(deglitchTemperature(50, prev: 70, glitchHold: &gh, zeroHold: &zh), 50, 1e-9, "deglitch: 小幅降温通过")
        expect(gh == 0, "deglitch: 小幅降温不触发 hold")
    }
    do {
        var gh = 0, zh = 0
        _ = deglitchTemperature(70, prev: 70, glitchHold: &gh, zeroHold: &zh)
        expectClose(deglitchTemperature(55, prev: 70, glitchHold: &gh, zeroHold: &zh, glitchDrop: 10, maxHold: 2), 70, 1e-9, "deglitch: 自定义阈值 hold")
        expectClose(deglitchTemperature(55, prev: 70, glitchHold: &gh, zeroHold: &zh, glitchDrop: 10, maxHold: 2), 70, 1e-9, "deglitch: 自定义阈值 hold 第2拍")
        expectClose(deglitchTemperature(55, prev: 70, glitchHold: &gh, zeroHold: &zh, glitchDrop: 10, maxHold: 2), 55, 1e-9, "deglitch: 自定义阈值第3拍采信")
    }

    // 场景仿真（balanced 曲线）：旧行为=关闭加速回落 vs 新默认
    let bal = CurvePreset.balanced.points
    var old = FanControlTuning(); old.settleBoostDrop = 999
    let new = FanControlTuning()

    // 尖峰：60 基线 → 85 保持 6s(2拍) → 回 60 保持 60s(20拍)
    let spike = Array(repeating: 60.0, count: 5) + [85, 85] + Array(repeating: 60.0, count: 20)
    let so = simulate(old, trace: spike, curve: bal)
    let sn = simulate(new, trace: spike, curve: bal)
    func settleLoops(_ s: [Double]) -> Int {
        let base = s[4]
        // 回落判定阈值取死区宽度（pctDeadband=5）：输出回到基线 ±死区 即视为已稳定。
        // 用更严的 ≤2 会把落在死区边缘的路径误判为"未回落"（死区本就允许输出停在基线±5%内保持）。
        let tol = FanControlTuning().pctDeadband
        for i in 7..<s.count where abs(s[i] - base) <= tol { return i - 7 }
        return s.count - 7
    }
    print("  [尖峰回落] 旧=\(settleLoops(so))拍 新=\(settleLoops(sn))拍 (每拍3s)")
    expect(settleLoops(sn) <= settleLoops(so), "加速回落不应更慢")

    // 持续升温：60→88 线性，升温路径不受加速回落影响，两者应一致
    let rise = stride(from: 60.0, through: 88.0, by: 2.8).map { $0 }
    let ro = simulate(old, trace: rise, curve: bal)
    let rn = simulate(new, trace: rise, curve: bal)
    print("  [升温响应] 末拍 旧=\(Int(ro.last!))% 新=\(Int(rn.last!))%")
    expectClose(ro.last!, rn.last!, 1e-9, "升温路径两者一致")

    // 怠速噪声：60±3 抖动，死区应压制大部分变化
    var rng = SystemRandomNumberGenerator()
    let noisy = (0..<40).map { _ in 60 + Double.random(in: -3...3, using: &rng) }
    let no = changeCount(simulate(old, trace: noisy, curve: bal))
    let nn = changeCount(simulate(new, trace: noisy, curve: bal))
    print("  [怠速抖动] 旧变化=\(no)次 新变化=\(nn)次 (共40拍)")
    expect(nn <= no + 2, "加速回落不显著增加怠速抖动")

    // 突发型：60→85 交替（每 3 拍切），验证降速限速仍兜住可闻降坡
    let bursty = (0..<30).map { i in (i / 3) % 2 == 0 ? 60.0 : 85.0 }
    let bn = simulate(new, trace: bursty, curve: bal)
    var maxDrop = 0.0
    for i in 1..<bn.count { maxDrop = max(maxDrop, bn[i-1] - bn[i]) }
    expect(maxDrop <= 6.0 + 1e-9, "突发型：单拍降幅仍≤降速限速 6%")
}


func testPipeline() {
    group("决策管线")
    let bal = CurvePreset.balanced.points

    // —— 各模式基础输出与主因 ——
    var d = decide(FanConfig(mode: .auto))
    expectEqual(d.targetPercent, nil, "auto 交还系统")
    expectEqual(d.reason, .auto, "auto 主因")

    d = decide(FanConfig(mode: .curve, curve: bal, preset: .balanced), smoothed: 70)
    expectClose(d.targetPercent!, FanConfig.percent(temp: 70, curve: bal), 1e-9, "曲线插值")
    expectEqual(d.reason, .curve, "曲线主因")

    d = decide(FanConfig(mode: .manual, manualPercent: 66))
    expectEqual(d.targetPercent, 66, "手动输出")
    expectEqual(d.reason, .manual, "手动主因")

    d = decide(FanConfig(mode: .ai), ai: 37)
    expectEqual(d.targetPercent, 37, "AI 输出透传")
    expectEqual(d.reason, .ai, "AI 主因")

    // —— 电池安静档覆盖 ——
    let cfgBatt = FanConfig(mode: .curve, curve: bal, preset: .balanced, batteryPreset: .quiet)
    d = decide(cfgBatt, smoothed: 70, battery: true)
    expectClose(d.targetPercent!, FanConfig.percent(temp: 70, curve: CurvePreset.quiet.points),
                1e-9, "电池用安静档曲线")
    expectEqual(d.reason, .battery, "电池主因")
    expect(d.batteryOverride, "电池覆盖标记")
    d = decide(cfgBatt, smoothed: 70, battery: false)
    expectEqual(d.reason, .curve, "市电不覆盖")
    expect(!d.batteryOverride, "市电无覆盖标记")

    // —— 静音承诺（会议模式）封顶 ——
    let future = Date().addingTimeInterval(600)
    let past = Date().addingTimeInterval(-10)
    d = decide(FanConfig(mode: .manual, manualPercent: 80, quietUntil: future, quietCapPercent: 30))
    expectEqual(d.targetPercent, 30, "静音压到上限")
    expectEqual(d.reason, .quiet, "静音压低后成主因")
    d = decide(FanConfig(mode: .manual, manualPercent: 20, quietUntil: future, quietCapPercent: 30))
    expectEqual(d.targetPercent, 20, "低于上限不提升")
    expectEqual(d.reason, .manual, "静音未压低→主因不变")
    d = decide(FanConfig(mode: .manual, manualPercent: 80, quietUntil: past, quietCapPercent: 30))
    expectEqual(d.targetPercent, 80, "过期不限")
    d = decide(FanConfig(mode: .manual, manualPercent: 80))
    expectEqual(d.targetPercent, 80, "未启用不限")
    d = decide(FanConfig(mode: .auto, quietUntil: future, quietCapPercent: 30))
    expectEqual(d.targetPercent, nil, "auto(nil 输出)不受静音封顶")

    // —— SSD 托底：阈值分级 + 模式门控 ——
    let cfgCurve = FanConfig(mode: .curve, curve: bal, preset: .balanced)
    d = decide(cfgCurve, smoothed: 50, nand: 75)   // 50° 曲线输出=0 → 托底主导
    expectEqual(d.targetPercent, 60, "NAND ≥70 托底 60%")
    expectEqual(d.reason, .ssd, "托底抬高后成主因")
    expect(d.ssdGuard, "ssdGuard 标记")
    d = decide(cfgCurve, smoothed: 50, nand: 78)
    expectEqual(d.targetPercent, 100, "NAND ≥78 托底 100%")
    d = decide(cfgCurve, smoothed: 50, nand: 69)
    expect(!d.ssdGuard, "NAND <70 不托底")
    d = decide(cfgCurve, smoothed: 50, nand: 68, wasSSDGuardActive: true)
    expect(d.ssdGuard && d.targetPercent == 60, "SSD 托底低于触发线仍保持")
    d = decide(cfgCurve, smoothed: 50, nand: 66, wasSSDGuardActive: true)
    expect(!d.ssdGuard, "SSD 托底降至解除线才解除")
    d = decide(cfgCurve, smoothed: 50, nand: 0)
    expect(!d.ssdGuard, "NAND 坏读(≤1)不托底")
    // 手动模式：SSD 危急档（≥78°C）是硬件安全红线，强制 100%；
    // 警告档（70–77°C）不介入，尊重用户固定意图
    d = decide(FanConfig(mode: .manual, manualPercent: 20), smoothed: 50, nand: 85)
    expectEqual(d.targetPercent, 100, "手动模式 SSD 危急档强制全速（硬件安全）")
    expect(d.ssdGuard, "手动模式危急档 ssdGuard 标记")
    d = decide(FanConfig(mode: .manual, manualPercent: 20), smoothed: 50, nand: 73)
    expectEqual(d.targetPercent, 20, "手动模式 SSD 警告档不介入（尊重固定意图）")
    expect(!d.ssdGuard, "手动模式警告档不标记 ssdGuard")
    d = decide(FanConfig(mode: .auto), smoothed: 50, nand: 85)
    expectEqual(d.targetPercent, nil, "auto 模式不托底")

    // —— 安全红线覆盖静音：静音绝不抑制散热 ——
    let cfgQuiet = FanConfig(mode: .curve, curve: bal, preset: .balanced,
                             quietUntil: future, quietCapPercent: 30)
    d = decide(cfgQuiet, smoothed: 85, nand: 75)   // 曲线 100 → 静音压 30 → SSD 抬回 60
    expectEqual(d.targetPercent, 60, "SSD 托底覆盖静音封顶")
    expectEqual(d.reason, .ssd, "覆盖后主因 SSD")
    d = decide(cfgQuiet, smoothed: 85, nand: 80)
    expectEqual(d.targetPercent, 100, "SSD 危急档覆盖静音")

    // —— 高温兜底：用原始读数判定（平滑不得延迟救援），优先级最高 ——
    d = decide(cfgQuiet, smoothed: 60, raw: 93)
    expectEqual(d.targetPercent, 100, "raw ≥92 全速（即使平滑温度低）")
    expectEqual(d.reason, .failsafe, "兜底主因")
    expect(d.failsafeActive, "兜底标记")
    expect(!d.batteryOverride, "兜底清电池覆盖标记（防 UI 误显示安静档）")
    d = decide(cfgQuiet, smoothed: 60, raw: 90, wasFailsafeActive: true)
    expect(d.failsafeActive && d.targetPercent == 100, "高温兜底回差保持全速")
    d = decide(cfgQuiet, smoothed: 60, raw: 87, wasFailsafeActive: true)
    expect(!d.failsafeActive, "高温降至解除线才解除兜底")
    d = decide(cfgBatt, smoothed: 60, raw: 93, battery: true)
    expect(!d.batteryOverride, "电池覆盖进行中也以兜底为先")
    d = decide(FanConfig(mode: .auto), smoothed: 60, raw: 95)
    expectEqual(d.targetPercent, nil, "auto 模式豁免兜底（风扇本就归系统管）")

    // —— 不变式扫描：任意组合下红线不可破 ——
    for smoothed in stride(from: 45.0, through: 90.0, by: 15.0) {
        for nand in [40.0, 72, 79] {
            for raw in [50.0, 91, 96] {
                let r = decide(cfgQuiet, smoothed: smoothed, raw: raw, nand: nand)
                let tag = "s\(Int(smoothed))/n\(Int(nand))/r\(Int(raw))"
                if raw >= FanPipeline.failsafeTemp {
                    expectEqual(r.targetPercent, 100, "扫描·兜底必全速 \(tag)")
                } else if nand >= 70 {
                    // v3.6.3：期望值用字面量（78/100/60），禁止从实现常量反推——
                    // 原写法在 ssdCriticalTemp 被变异时期望值同步变化，变异体存活（循环论证）
                    let floor = nand >= 78 ? 100.0 : 60.0
                    expect((r.targetPercent ?? -1) >= floor, "扫描·SSD 托底必保住 \(tag)")
                }
            }
        }
    }

    // —— AI 空闲交还：nil 输出交还系统，但安全红线不豁免 ——
    let cfgAI = FanConfig(mode: .ai)
    d = decide(cfgAI, smoothed: 55, ai: nil)    // nil = AI 判定交还
    expectEqual(d.targetPercent, nil, "AI 交还时输出为 nil")
    expectEqual(d.reason, .ai, "管线保持 .ai（daemon 改标 aiIdle）")
    d = decide(cfgAI, smoothed: 55, nand: 79, ai: nil)
    expectEqual(d.targetPercent, 100, "交还期 SSD 危急托底仍生效")
    d = decide(cfgAI, smoothed: 55, nand: 72, ai: nil)
    expectEqual(d.targetPercent, 60, "交还期 SSD 托底仍生效")
    d = decide(cfgAI, smoothed: 55, raw: 95, ai: nil)
    expectEqual(d.targetPercent, 100, "交还期高温兜底仍生效")
}


func testBatteryGuard() {
    group("电池托底")
    let bal = CurvePreset.balanced.points
    let cfg = FanConfig(mode: .curve, curve: bal, preset: .balanced)

    // ≥45° 托底 60%（警告档仅 curve/ai 介入）
    var d = decide(cfg, smoothed: 50, batt: 45)
    expectEqual(d.targetPercent, 60, "电池 ≥45 托底 60%")
    expectEqual(d.reason, .batteryHot, "托底抬高后成主因")
    expect(d.batteryGuard, "batteryGuard 标记")
    // 滞回：低于触发线保持，降至解除线才解除
    d = decide(cfg, smoothed: 50, batt: 44, wasBatteryGuardActive: true)
    expect(d.batteryGuard && d.targetPercent == 60, "托底低于触发线仍保持")
    d = decide(cfg, smoothed: 50, batt: 42, wasBatteryGuardActive: true)
    expect(!d.batteryGuard, "降至解除线才解除")
    // 危急档 ≥48→100，回差释放 46
    d = decide(cfg, smoothed: 50, batt: 48)
    expectEqual(d.targetPercent, 100, "电池 ≥48 危急全速")
    expect(d.batteryCriticalActive, "危急档标记")
    d = decide(cfg, smoothed: 50, batt: 47, wasBatteryGuardActive: true, wasBatteryCriticalActive: true)
    expectEqual(d.targetPercent, 100, "危急档回差保持全速")
    d = decide(cfg, smoothed: 50, batt: 45, wasBatteryGuardActive: true, wasBatteryCriticalActive: true)
    expect(!d.batteryCriticalActive && d.targetPercent == 60, "危急降到警告区间→60%")
    // 手动模式：仅危急档介入（尊重固定意图，但硬件安全不让步）
    d = decide(FanConfig(mode: .manual, manualPercent: 20), smoothed: 50, batt: 46)
    expectEqual(d.targetPercent, 20, "手动模式警告档不介入")
    d = decide(FanConfig(mode: .manual, manualPercent: 20), smoothed: 50, batt: 49)
    expectEqual(d.targetPercent, 100, "手动模式危急档强制全速")
    // auto 豁免（风扇本就归系统管，含充电热策略）
    d = decide(FanConfig(mode: .auto), smoothed: 50, batt: 50)
    expectEqual(d.targetPercent, nil, "auto 模式豁免电池托底")
    // 坏读/无电池键（0）不托底
    d = decide(cfg, smoothed: 50, batt: 0)
    expect(!d.batteryGuard && d.reason == .curve, "batt=0（无键）不托底")
    // NaN 不托底
    d = decide(cfg, smoothed: 50, batt: .nan)
    expect(!d.batteryGuard, "NaN 电池温度不托底")
    // 静音封顶被托底覆盖（安全 > 安静承诺）
    let cfgQ = FanConfig(mode: .curve, curve: bal, preset: .balanced,
                         quietUntil: Date().addingTimeInterval(600), quietCapPercent: 30)
    d = decide(cfgQ, smoothed: 50, batt: 46)
    expectEqual(d.targetPercent, 60, "电池托底覆盖静音封顶")
    expectEqual(d.reason, .batteryHot, "覆盖后主因电池托底")
    // 兜底仍最高优先
    d = decide(cfgQ, smoothed: 50, raw: 93, batt: 46)
    expectEqual(d.targetPercent, 100, "92° 兜底仍压过电池托底")
    expectEqual(d.reason, .failsafe, "主因兜底")
    // 托底不抬高输出时不改主因（曲线本来 100%）
    d = decide(cfg, smoothed: 88, batt: 45)
    expectEqual(d.reason, .curve, "曲线输出更高时主因不变")
    // AI 空闲交还期托底仍生效（daemon 由此重新接管）
    d = decide(FanConfig(mode: .ai), smoothed: 55, ai: nil, batt: 46)
    expectEqual(d.targetPercent, 60, "交还期电池托底仍生效")
    // safetyFloor 汇总：SSD 与电池取较大者
    d = decide(cfg, smoothed: 50, nand: 79, batt: 46)
    expectEqual(d.targetPercent, 100, "SSD 危急与电池警告并存取 100")
    expectEqual(d.safetyFloorPercent, 100, "safetyFloor 取较大托底")
    d = decide(cfg, smoothed: 50, nand: 72, batt: 46)
    expectEqual(d.safetyFloorPercent, 60, "同为警告档取 60")
}


// MARK: - AI 自动接管控制器（目标温度 + 趋势预判的增量式控制）

// R77：dt 钳位必须全仓同源。此前三处各写各的：引擎 20s、LearningGate 20s、
// FanAIController **15s**——idle 长拍下 AI 的 P/D 增量按 15s 结算而学习门/统计按 20s，
// 同拍两处口径差 25%，不报错、只是控制与度量悄悄不同源。本门用"同一输入喂两处、
// 结果必须一致"来钉死这个不变量：将来谁再改回局部常量，这里先红。
func testDtClampSingleSource() {
    group("dt 钳位同源(R77)")

    // ① FanDt.clamped 的边界语义（它是三处共用的那一个定义）
    expectEqual(FanDt.clamped(3.0), 3.0, "标称拍长原样通过")
    expectEqual(FanDt.clamped(20.0), 20.0, "上界 20s 原样通过（= idle 最大间隔）")
    expectEqual(FanDt.clamped(1e9), 20.0, "睡眠唤醒的超大 elapsed 钳到 20s")
    expectEqual(FanDt.clamped(0.0), 0.5, "下界 0.5s")
    expectEqual(FanDt.clamped(-5), 0.5, "负值钳到下界")
    expectEqual(FanDt.clamped(.nan), 3.0, "NaN 退回标称 3s（NaN 会穿透 min/max 并污染 output）")
    // ±Inf 也是 isFinite == false → 一并退回标称 3s。会话时钟跳变理论上只产生有限大值，
    // 故"非有限一律退回标称"比"Inf 走 min/max"更保守：宁可当 3s 拍，也不让 P 项按 20s 冲。
    expectEqual(FanDt.clamped(.infinity), 3.0, "+Inf（非有限）退回标称 3s")
    expectEqual(FanDt.clamped(-.infinity), 3.0, "-Inf（非有限）退回标称 3s")
    expectEqual(FanDt.clamped(1e300), 20.0, "有限超大值（时钟跳变常见形态）钳到上界 20s")

    // ② 关键不变量：LearningGate 与 FanAIController 必须给出**同一个** dtn。
    // LearningGate 是以 °C/s 判稳态，dt 非有限直接 false（它要区分"不可判"），
    // 故这里只比有限值区间——正是分叉发生的那一段（15 vs 20）。
    for dt in [0.3, 0.5, 1.0, 3.0, 15.0, 15.5, 20.0, 60.0, 1e9] {
        let a = FanDt.clamped(dt)
        // 稳态判据用同一 dtn：取"恰好在阈值上/下"的温升反推，确认两边算的是同一个分母。
        // 0.12°C/s × dtn 是 LearningGate 的判据线。
        let line = LearningGate.tempRatePerSec * a
        let justUnder = line * 0.9
        let justOver = line * 1.1
        expect(LearningGate.isSteady(temp: 70 + justUnder, prevTemp: 70,
                                     baseTarget: 50, prevBase: 50,
                                     shapedBase: 50, dt: dt),
               "dt=\(dt)s：阈值 90% 的温升判稳态（分母按 FanDt=\(a)s）")
        expect(!LearningGate.isSteady(temp: 70 + justOver, prevTemp: 70,
                                      baseTarget: 50, prevBase: 50,
                                      shapedBase: 50, dt: dt),
               "dt=\(dt)s：阈值 110% 的温升判非稳态")
    }

    // ③ 回归本体：15.5s 这个输入在修复前会被 AI 侧截成 15s（口径差 3.3%），
    // 在 20s 这个输入上差 25%。现在两处都返回 15.5/20.0。
    expectEqual(FanDt.clamped(15.5), 15.5, "15.5s 不再被截成 15s（旧 AIController 内部上界）")
    expectEqual(FanDt.clamped(20.0), 20.0, "20s 不再被截成 15s（旧分叉点：20 vs 15 = 25%）")
}

func testAIController() {
    group("AI控制器")
    let target = AITuning().targetTemp   // 76

    // 输出始终限在 0~100
    do {
        var c = AIController()
        for t in [40.0, 55, 70, 85, 95, 100, 60, 45] {
            let o = c.step(temp: t, dt: 3.0)!
            expect(o >= 0 && o <= 100, "输出越界 @\(t): \(o)")
        }
    }

    // v6: NaN dt 防御——NaN 穿透 min(max(dt, 0.5), 15.0) 导致 output 变 NaN
    do {
        var c = AIController()
        _ = c.step(temp: target + 5, dt: 3.0)  // 建立非零 output
        let prevOutput = c.output
        let o = c.step(temp: target + 5, dt: .nan)!
        expect(o.isFinite, "NaN dt 不传播到 output")
        expect(o >= 0 && o <= 100, "NaN dt 后 output 仍合法")
        // NaN dt 退回标称 3s，P 项应正常推进（output 应变化而非冻结）
        expect(o != prevOutput || prevOutput == 100, "NaN dt 降级为 3s 后控制律仍推进")
    }

    // 持续高于目标 → 输出单调上升并冲高（饱和到 100 也算正确，因为确实该拉满）
    do {
        // 温和偏热 +3°（不会瞬时饱和）：验证输出逐拍单调爬升
        var c = AIController()
        _ = c.step(temp: target, dt: 3.0)
        let o0 = c.step(temp: target + 3, dt: 3.0)!
        let o1 = c.step(temp: target + 3, dt: 3.0)!
        let o2 = c.step(temp: target + 3, dt: 3.0)!
        expect(o0 < o1 && o1 < o2, "温和持续偏热输出应逐拍爬升 (\(Int(o0))->\(Int(o1))->\(Int(o2)))")
        // 大幅持续偏热 +10°：应快速冲到高输出
        var h = AIController(); _ = h.step(temp: target, dt: 3.0)
        _ = h.step(temp: target + 10, dt: 3.0); let hi = h.step(temp: target + 10, dt: 3.0)!
        expect(hi >= 90, "大幅偏热应冲到高输出 (\(Int(hi)))")
    }

    // 升温趋势前馈：同一温度下，「正在快速升温」比「稳态」输出更高（提前加速）
    do {
        var rising = AIController(); var steady = AIController()
        // rising: 从低温快速升到 74；temp 序列斜率大
        _ = rising.step(temp: 60, dt: 3.0); _ = rising.step(temp: 67, dt: 3.0); let orise = rising.step(temp: 74, dt: 3.0)!
        // steady: 一直稳在 74，斜率≈0
        _ = steady.step(temp: 74, dt: 3.0); _ = steady.step(temp: 74, dt: 3.0); let ostead = steady.step(temp: 74, dt: 3.0)!
        expect(orise > ostead, "升温趋势应比稳态输出更高 (升\(Int(orise)) vs 稳\(Int(ostead)))")
    }

    // 回落收敛：从高输出状态降温，输出应下降
    do {
        var c = AIController()
        for _ in 0..<6 { _ = c.step(temp: target + 10, dt: 3.0) }  // 推高输出
        let hi = c.output
        for _ in 0..<4 { _ = c.step(temp: target - 15, dt: 3.0) }  // 降温
        expect(c.output < hi, "降温后输出应回落 (\(Int(hi))->\(Int(c.output)))")
        expect(!c.idleReleased, "短暂降温不误触发交还")
    }

    // 目标收敛：固定温度长时间运行，输出应稳定下来（不发散、不震荡）
    do {
        var c = AIController()
        for _ in 0..<40 { _ = c.step(temp: target, dt: 3.0) }  // 恰好在目标
        let a = c.step(temp: target, dt: 3.0); let b = c.step(temp: target, dt: 3.0)
        expect(a == b, "目标温度下输出应稳定不变 (\(String(describing: a)),\(String(describing: b)))")
    }

    // reset 后重新起步（首拍重新播种，空闲状态清零）
    do {
        var c = AIController()
        for _ in 0..<5 { _ = c.step(temp: 90, dt: 3.0) }
        c.reset()
        expect(c.output == 0 && !c.idleReleased, "reset 后积分与空闲状态清零")
    }

    // 唤醒场景：reset 后用悬殊温度起步，不应因“睡前→唤醒”斜率产生巨大前馈尖峰
    do {
        var c = AIController()
        for _ in 0..<8 { _ = c.step(temp: 45, dt: 3.0) }   // 睡前长期低温，输出稳在低位
        c.reset()                                 // 唤醒重置
        let woke = c.step(temp: 70, dt: 3.0)!              // 唤醒后温度已不同（首拍播种路径）
        // 首拍走“播种”路径（不算斜率），不会因 (70-45) 的假斜率被 kD 放大成 100
        expect(woke < 60, "唤醒首拍不应有斜率尖峰 (得 \(Int(woke)))")
    }

    // NaN/Inf 守卫：坏值不污染状态，后续正常值仍得有限输出
    do {
        var c = AIController()
        _ = c.step(temp: 76, dt: 3.0)
        _ = c.step(temp: .nan, dt: 3.0)
        _ = c.step(temp: .infinity, dt: 3.0)
        if let o = c.step(temp: 80, dt: 3.0) {
            expect(o.isFinite && o >= 0 && o <= 100, "NaN/Inf 后输出仍有限且合法 (\(o))")
        } else { expect(false, "NaN 后不应进入交还") }
    }

    // 不同目标温度：目标高则同一温度下输出更低（更安静）
    do {
        func out(target: Double) -> Double {
            var t = AITuning(); t.targetTemp = target
            var c = AIController(tuning: t)
            for _ in 0..<20 { _ = c.step(temp: 78, dt: 3.0) }  // 固定 78°
            return c.output
        }
        let perf = out(target: 72)   // 性能：78 超目标多→输出高
        let quiet = out(target: 80)  // 静音：78 低于目标→输出低
        expect(perf > quiet, "目标越高同温下输出越低 (性能\(Int(perf)) vs 静音\(Int(quiet)))")
    }

    // config 携带 aiTargetTemp 往返 + 旧配置（无此字段）兼容
    do {
        let cfg = FanConfig(mode: .ai, aiTargetTemp: 80)
        let back = try? JSONDecoder().decode(FanConfig.self, from: JSONEncoder().encode(cfg))
        expect(back?.aiTargetTemp == 80 && back?.mode == .ai, "aiTargetTemp 往返")
        let legacy = #"{"mode":"ai","manualPercent":50,"curve":[{"temp":52,"percent":0},{"temp":85,"percent":100}]}"#.data(using: .utf8)!
        let lc = try? JSONDecoder().decode(FanConfig.self, from: legacy)
        expect(lc?.aiTargetTemp == nil, "旧 config 无 aiTargetTemp 兼容")
    }

    // v3: 斜率死区——微小斜率（<0.15°C/s）不触发 D 项
    do {
        var t = AITuning(); t.slopeDeadband = 0  // 禁用死区作对照
        var withDeadband = AIController()
        var noDeadband = AIController(tuning: t)
        _ = withDeadband.step(temp: target + 3, dt: 3.0)   // error=3 > 1, P 项活跃
        _ = noDeadband.step(temp: target + 3, dt: 3.0)
        // 0.3°C/3s = 0.1°C/s < 0.15 死区 → withDeadband 的 D 项归零
        let o1 = withDeadband.step(temp: target + 3.3, dt: 3.0)!
        let o2 = noDeadband.step(temp: target + 3.3, dt: 3.0)!
        expect(o2 > o1, "斜率死区抑制了 D 项 (有死区\(Int(o1)) vs 无死区\(Int(o2)))")
        expectClose(o2 - o1, 8.0 * 0.3, 0.01, "D 项差值 = kD×slope")  // 2.4
    }

    // v3: 误差死区——目标±1° 内 P 项归零，输出不漂移
    do {
        var c = AIController()
        _ = c.step(temp: target, dt: 3.0)                    // 建立基线
        _ = c.step(temp: target + 0.5, dt: 3.0)              // 初始斜率推一下 D 项
        let baseline = c.output                     // 此后温度恒定
        for _ in 0..<20 { _ = c.step(temp: target + 0.5, dt: 3.0) }  // 误差 0.5° < 1° 死区，斜率=0
        expectClose(c.output, baseline, 0.01, "误差死区内 P 项不积累（防漂移）")
        // 超出死区后 P 项恢复
        let before = c.output
        _ = c.step(temp: target + 2, dt: 3.0)                // 误差 2° > 1° 死区
        expect(c.output != before, "超出死区后 P 项恢复推动")
    }

    // v3: 无学习数据时的主动前馈——升温段至少有 20% 地板
    do {
        var c = AIController()
        _ = c.step(temp: 60, dt: 3.0)
        // 升温到 65（误差 -11°，斜率 5/3s ≈ 1.67°C/s > 0.15 死区）
        let o = c.step(temp: 65, dt: 3.0)!
        // 无 learned → 前馈 = error > 5 ? 60 : error > 2 ? 35 : 20 = 20
        // PD 项可能给出更低值（误差负 → P 项为负），前馈地板应抬到 20
        expect(o >= 20, "无学习数据时升温前馈地板 ≥ 20% (得 \(Int(o)))")
    }
    // v3: 无学习数据 + 大幅超目标时前馈更强
    do {
        var c = AIController()
        _ = c.step(temp: 75, dt: 3.0)   // 建立基线
        let o = c.step(temp: 82, dt: 3.0)!  // 升温 7°，误差 6° > 5 → 前馈 60
        expect(o >= 60, "大幅超目标时前馈 ≥ 60% (得 \(Int(o)))")
    }

    // v6: 冷启动用曲线插值作为基准（替代硬编码）
    // 无 learned 时，curvePercent 作为升温前馈基准
    do {
        var c = AIController()
        _ = c.step(temp: 60, dt: 3.0)
        // 升温到 65，无 learned，curvePercent=25（用户曲线在 65°C 的值）
        // 前馈 = min(25, 80) = 25 > 硬编码 20 → 用曲线值
        let o = c.step(temp: 65, curvePercent: 25, dt: 3.0)!
        expect(o >= 25, "curvePercent=25 作为前馈基准 (得 \(Int(o)))")
    }
    // v6: learned 优先于 curvePercent
    do {
        var c = AIController()
        _ = c.step(temp: 60, dt: 3.0)
        // learned=40, curvePercent=25 → 前馈用 learned=40
        let o = c.step(temp: 65, learned: 40, curvePercent: 25, dt: 3.0)!
        expect(o >= 40, "learned=40 优先于 curvePercent=25 (得 \(Int(o)))")
    }
    // v6: 首拍种子用 curvePercent（无 learned 时）
    do {
        var c = AIController()
        // 首拍无 learned，curvePercent=30 → output=30
        let o = c.step(temp: 70, curvePercent: 30, dt: 3.0)!
        expectClose(o, 30, 0.01, "首拍种子用 curvePercent=30 (得 \(Int(o)))")
    }
    // v6: 夺回种子用 curvePercent（无 learned 时）
    do {
        var c = AIController()
        // 先进入空闲交还
        for _ in 0..<40 { _ = c.step(temp: 60, dt: 3.0) }  // 深凉 10 拍交还
        expect(c.idleReleased, "已交还")
        // 夺回时无 learned，curvePercent=35 → output=35
        let o = c.step(temp: 80, curvePercent: 35, dt: 3.0)!
        expectClose(o, 35, 0.01, "夺回种子用 curvePercent=35 (得 \(Int(o)))")
    }

    // v4: errorDeadband 边界——error=2.0 恰好在死区内（<= 而非 <）
    do {
        var c = AIController()
        _ = c.step(temp: target, dt: 3.0)           // 建立基线
        _ = c.step(temp: target + 2, dt: 3.0)       // slope 推一下 D 项
        let baseline = c.output
        // error=2.0，abs(2.0)<=2.0 为 true → P 项归零，不会 windup
        for _ in 0..<20 { _ = c.step(temp: target + 2, dt: 3.0) }
        expectClose(c.output, baseline, 0.01, "error=2.0 在死区内（<=），P 项不积累")
    }

    // v4: anti-windup——饱和后降温恢复更快
    do {
        // 场景：88°C 保持 10 拍 → 降到 80°C
        // 旧逻辑（无 anti-windup）：80°C 时 output 仍接近 100（P 项抵消 D 项）
        // 新逻辑（有 anti-windup）：80°C 时 output 明显下降（饱和时跳过同向 P 项）
        var c = AIController()
        _ = c.step(temp: 76, dt: 3.0)                    // 建立基线
        for _ in 0..<10 { _ = c.step(temp: 88, dt: 3.0) } // 推到饱和
        expect(c.output >= 95, "88°C 应饱和到接近 100 (得 \(Int(c.output)))")
        // 降温到 80°C（error=4，P 项为正但在饱和时被跳过）
        for _ in 0..<4 { _ = c.step(temp: 80, dt: 3.0) }
        // anti-windup 下，降温段 D 项不被 P 项抵消，output 应明显低于 100
        expect(c.output < 80, "anti-windup 让饱和后降温恢复更快 (得 \(Int(c.output)))")
    }

    // v4: 死区内缓慢回落——output 远高于 learned 时每拍 -1%
    // v7: 升级为曲线锚定，output 向 curvePercent 双向收敛（3%/拍）
    do {
        var c = AIController()
        _ = c.step(temp: 76, dt: 3.0)   // seed=30
        // 推高 output（kP=1.5，需要更多拍）
        for _ in 0..<15 { _ = c.step(temp: 85, dt: 3.0) }
        let hi = c.output
        expect(hi >= 80, "推高到 80+ (得 \(Int(hi)))")
        // 缓慢降温到死区（每拍降 1°C），避免 D 项一次性把 output 拉低：
        // deadband=2.0，死区 [74,78]，76.5°C 在死区内
        // curvePercent=40 作为锚定目标，output 应向 40 收敛
        for t in stride(from: 84.0, through: 77.0, by: -1.0) {
            _ = c.step(temp: t, learned: 40, curvePercent: 40, dt: 3.0)
        }
        // 进入死区 (76.5, error=0.5 < 2.0 在死区内)
        _ = c.step(temp: 76.5, learned: 40, curvePercent: 40, dt: 3.0)
        let afterSlope = c.output
        expect(afterSlope > 45, "进入死区时 output 仍高于 learned+5=45 (得 \(Int(afterSlope)))")
        // 后续拍 slope=0，曲线锚定（v9 探测阶梯：每 25s 迈 ≤1.5%）向 curvePercent=40 收敛。
        // 280 拍 × 3s = 840s ≈ 33 步 × 1.5% ≈ 50pp 行程，足够从 ~70 收敛到 40
        for _ in 0..<280 { _ = c.step(temp: 76.5, learned: 40, curvePercent: 40, dt: 3.0) }
        expect(c.output < afterSlope, "死区内 output 持续回落 (从\(Int(afterSlope))到\(Int(c.output)))")
        expect(c.output <= 43, "曲线锚定到 40 附近 (得 \(Int(c.output)))")
        expect(c.output >= 39, "不低于曲线锚定目标 (得 \(Int(c.output)))")
    }

    // v4: 升温前馈对 learned 加上限 80%——即使 learned 被污染为 100%，前馈也不会拉满
    do {
        var c = AIController()
        _ = c.step(temp: 70, dt: 3.0)   // 建立基线
        // 升温到 75（slope=5/3≈1.67 > 0.15 死区），learned=100（污染）
        let o = c.step(temp: 75, learned: 100, dt: 3.0)!
        expect(o <= 80, "learned=100% 被污染时前馈上限 80% (得 \(Int(o)))")
        expect(o >= 60, "仍保留合理的前馈力度 (得 \(Int(o)))")
    }

    // v4: anti-windup output=0 触底——负向 P 项被跳过，不让 output 变负
    do {
        var c = AIController()
        _ = c.step(temp: 76, dt: 3.0)   // 首拍 seed=30
        // 大幅降温到 60°C（error=-16），P 项应把 output 推向 0
        for _ in 0..<5 { _ = c.step(temp: 60, dt: 3.0) }
        expect(c.output == 0, "大幅降温后 output 触底 0% (得 \(Int(c.output)))")
        // 触底后继续降温：P 项负向被跳过，output 不变
        let frozen = c.output
        for _ in 0..<5 { _ = c.step(temp: 60, dt: 3.0) }
        expect(c.output == frozen, "触底后负向 P 项被跳过，output 冻结 (得 \(Int(c.output)))")
    }

    // v4: learned=nil + curvePercent=nil 时死区内不回落（无基准，保守维持）
    do {
        var c = AIController()
        _ = c.step(temp: 76, dt: 3.0)   // seed=30
        // 缓慢升温到 80°C 推高 output
        for _ in 0..<10 { _ = c.step(temp: 80, dt: 3.0) }
        expect(c.output > 30, "推高 output (得 \(Int(c.output)))")
        // 平缓降温到死区
        for t in stride(from: 79.0, through: 77.0, by: -1.0) {
            _ = c.step(temp: t, dt: 3.0)
        }
        // 进入死区 (76.5, error=0.5)，learned=nil, curvePercent=nil
        let r = c.step(temp: 76.5, dt: 3.0)
        let afterStep = c.output
        expect(r != nil, "learned=nil+curvePercent=nil 不交还")
        // 后续 10 拍温度不变，无基准不回落
        for _ in 0..<10 { _ = c.step(temp: 76.5, dt: 3.0) }
        expect(abs(c.output - afterStep) < 1,
               "无基准时死区内不回落 (得 \(Int(c.output)) vs \(Int(afterStep)))")
    }

    // v6: learned=nil + curvePercent 提供基准时死区内回落
    // 打破正反馈：即使无 learned，curvePercent 也能拉下冻结在高位的 output
    do {
        var c = AIController()
        _ = c.step(temp: 76, dt: 3.0)
        for _ in 0..<10 { _ = c.step(temp: 80, dt: 3.0) }  // 推高 output
        expect(c.output > 30, "推高 output (得 \(Int(c.output)))")
        for t in stride(from: 79.0, through: 77.0, by: -1.0) {
            _ = c.step(temp: t, curvePercent: 45, dt: 3.0)
        }
        // 进入死区，curvePercent=45（用户曲线在 76.5°C 的值）
        _ = c.step(temp: 76.5, curvePercent: 45, dt: 3.0)
        let afterStep = c.output
        // 后续 10 拍温度不变，curvePercent=45 < output-5 → 每拍降 1%
        for _ in 0..<10 { _ = c.step(temp: 76.5, curvePercent: 45, dt: 3.0) }
        expect(c.output < afterStep,
               "curvePercent=45 时死区内回落 (得 \(Int(c.output)) vs \(Int(afterStep)))")
        expect(c.output >= 45, "回落不低于 curvePercent-5 (得 \(Int(c.output)))")
    }

    // v6: 死区回落用 min(learned, curvePercent)——learned 被污染时仍能回落
    // 这是正反馈锁死的核心修复：learned=96%（污染）+ curvePercent=18%（用户曲线）
    // 用 min(96, 18)=18 作基准 → output > 18+5=23 → 回落
    do {
        var c = AIController()
        _ = c.step(temp: 76, dt: 3.0)
        for _ in 0..<10 { _ = c.step(temp: 80, dt: 3.0) }  // 推高 output
        // 降温到死区（target=76, deadband=2, 死区 [74,78]）
        for t in stride(from: 79.0, through: 77.0, by: -1.0) {
            _ = c.step(temp: t, learned: 96, curvePercent: 18, dt: 3.0)
        }
        _ = c.step(temp: 76.5, learned: 96, curvePercent: 18, dt: 3.0)
        let afterStep = c.output
        // 后续 10 拍：learned=96, curvePercent=18, min=18
        // output > 18+5=23 → 每拍降 1%
        for _ in 0..<10 { _ = c.step(temp: 76.5, learned: 96, curvePercent: 18, dt: 3.0) }
        expect(c.output < afterStep,
               "learned=96 污染时 curvePercent=18 仍能回落 (得 \(Int(c.output)) vs \(Int(afterStep)))")
        // 回落不低于 min(96,18)-5=13
        expect(c.output >= 13, "回落不低于 min(learned,curvePercent)-5 (得 \(Int(c.output)))")
    }

    // v7: 曲线锚定双向收敛——稳态时 output 向曲线靠拢（过高降、过低升）
    // 这是"曲线+AI 结合"的核心：调曲线=调 AI 期望转速，AI 只修其偏差
    do {
        // 场景1：output 低于曲线 → 锚定向上抬（用户想要更高转速）
        var c1 = AIController()
        var o1: Double = 0
        // 建立低位稳态（低温 + 高曲线，模拟"用户想要 60% 但 AI 积分停在低位"）
        for _ in 0..<5 { o1 = c1.step(temp: 76, curvePercent: 60, dt: 3.0)! }  // 死区内，锚=60
        expect(o1 > 30, "低位向曲线抬升起点 >30 (得 \(Int(o1)))")
        // 继续稳态，锚定向 60 双向收敛
        for _ in 0..<20 { o1 = c1.step(temp: 76, curvePercent: 60, dt: 3.0)! }
        expect(o1 >= 55, "稳态双向收敛到曲线 60 附近（低位抬升）(得 \(Int(o1)))")

        // 场景2：output 高于曲线 → 锚定向下压（散热好，用户想要更低转速）
        var c2 = AIController()
        _ = c2.step(temp: 76, dt: 3.0)
        for _ in 0..<15 { _ = c2.step(temp: 85, dt: 3.0) }  // 推高到高位
        for t in stride(from: 84.0, through: 77.0, by: -1.0) { _ = c2.step(temp: t, curvePercent: 30, dt: 3.0) }
        _ = c2.step(temp: 76.5, curvePercent: 30, dt: 3.0)   // 进入死区
        let hi2 = c2.output
        // v9 探测阶梯：280 拍 ≈ 33 步行程，从 ~70 收敛到 30
        for _ in 0..<280 { _ = c2.step(temp: 76.5, curvePercent: 30, dt: 3.0) }
        expect(c2.output < hi2, "高位向曲线收敛（过高回落）(得 \(Int(c2.output)) vs \(Int(hi2)))")
        expect(c2.output <= 33, "回落到曲线 30 附近 (得 \(Int(c2.output)))")
        expect(c2.output >= 29, "不低于曲线 30 (得 \(Int(c2.output)))")
    }

    // v4: 清洗分级阈值——<60°C/>30%, <70°C/>50%, <75°C/>80%
    do {
        var q = ThermalLearn()
        // 72°C 桶（midTemp=73）学到 81% → 清洗（<75°C 且 >80%）
        for _ in 0..<3 { q.record(temp: 72, percent: 81) }
        // 74°C 桶（midTemp=75）学到 81% → 不清洗（midTemp 不 <75）
        for _ in 0..<3 { q.record(temp: 74, percent: 81) }
        // 72°C 桶学到 80% → 不清洗（>80 严格大于）
        for _ in 0..<3 { q.record(temp: 72, percent: 80) }
        let cleaned = q.sanitizeCorruptedBuckets()
        expectEqual(cleaned, 1, "只清洗 72°C/81% 桶（边界值不清洗）")
    }

    // v6: 分级清洗——低温区更严格的阈值
    do {
        var q = ThermalLearn()
        // 50°C 桶（midTemp=51）学到 35% → 清洗（<60°C 且 >30%）
        for _ in 0..<3 { q.record(temp: 50, percent: 35) }
        // 65°C 桶（midTemp=65）学到 55% → 清洗（<70°C 且 >50%）
        for _ in 0..<3 { q.record(temp: 65, percent: 55) }
        // 50°C 桶学到 30% → 不清洗（>30 严格大于，30% 是允许的）
        for _ in 0..<3 { q.record(temp: 50, percent: 30) }
        // 65°C 桶学到 50% → 不清洗（>50 严格大于）
        for _ in 0..<3 { q.record(temp: 65, percent: 50) }
        let cleaned = q.sanitizeCorruptedBuckets()
        expectEqual(cleaned, 2, "分级清洗 50°C/35% 和 65°C/55%（2 个）")
    }
}


// MARK: - AI 空闲交还与学习前馈（v2：学会机器特性，低负载交还系统）


func testAIIdleAndLearn() {
    group("AI空闲交还")
    // 常规清凉（66°，非深凉）→ 40 拍交还
    do {
        var c = AIController()
        var early = true
        for _ in 0..<39 { if c.step(temp: 66, dt: 3.0) == nil { early = false } }
        expect(early, "前 39 拍不提前交还")
        expect(c.step(temp: 66, dt: 3.0) == nil, "第 40 拍交还")
        expect(c.idleReleased, "交还状态置位")
        // 停转瞬态：交还后立即升温斜率，宽限期内不夺回（否则风扇永远停不下来）
        expect(c.step(temp: 70, dt: 3.0) == nil, "宽限期内瞬态斜率不夺回")
        for _ in 0..<20 { _ = c.step(temp: 66, dt: 3.0) }   // 宽限过期
        let r = c.step(temp: 70, dt: 3.0)                    // 斜率 +4 ≥ 0.8，宽限后单拍夺回
        expect(r != nil && !c.idleReleased, "宽限后斜率骤增单拍夺回")
    }
    // 深凉快速通道（60° ≤ 76−12）→ 10 拍交还，缩短负载后空转窗口
    do {
        var c = AIController()
        for _ in 0..<9 { expect(c.step(temp: 60, dt: 3.0) != nil, "深凉前 9 拍不交还") }
        expect(c.step(temp: 60, dt: 3.0) == nil, "深凉第 10 拍交还")
    }
    // dt 语义：10s 间隔下深凉 30s = 3 拍释放（计时按秒恒定，不随拍长伸缩）
    do {
        var c = AIController()
        expect(c.step(temp: 60, dt: 10) != nil, "10s 未释放")
        expect(c.step(temp: 60, dt: 10) != nil, "20s 未释放")
        expect(c.step(temp: 60, dt: 10) == nil, "30s 深凉释放（dt 恒定）")
    }
    // 斜率突增 → 宽限后单拍抢跑夺回（负载陡升抢时间）
    do {
        var c = AIController()
        for _ in 0..<10 { _ = c.step(temp: 60, dt: 3.0) }   // 深凉第 10 拍精确释放，宽限刚开启
        expect(c.idleReleased, "先交还")
        expect(c.step(temp: 63, dt: 3.0) == nil, "释放后首拍斜率被宽限吸收")
        for _ in 0..<20 { _ = c.step(temp: 60, dt: 3.0) }   // 宽限过期
        let r = c.step(temp: 63, dt: 3.0)                    // 63 < 76 但斜率 +3 ≥ 0.8
        expect(r != nil && !c.idleReleased, "宽限后斜率骤增单拍夺回")
    }
    // 过线夺回不受宽限限制：释放后立刻被动破目标，连续 2 拍夺回（真负载兜底）
    do {
        var c = AIController()
        for _ in 0..<10 { _ = c.step(temp: 60, dt: 3.0) }
        expect(c.idleReleased, "深凉交还")
        expect(c.step(temp: 76, dt: 3.0) == nil, "破目标首拍确认中（宽限期内也夺回得到）")
        let r = c.step(temp: 76, dt: 3.0)
        expect(r != nil && !c.idleReleased, "过线连续 2 拍夺回")
    }
    // 滞回防抖：被动升温不破目标不夺回（斜率阈值调高隔离温度条件）
    do {
        var t = AITuning(); t.idleReclaimSlopePerSec = 99
        var c = AIController(tuning: t)
        for _ in 0..<40 { _ = c.step(temp: 55, dt: 3.0) }
        expect(c.step(temp: 69, dt: 3.0) == nil, "69 远低于目标维持交还")
        expect(c.step(temp: 75, dt: 3.0) == nil, "75 被动平衡温不破目标仍交还（防极限环关键）")
        expect(c.step(temp: 76, dt: 3.0) == nil, "76 破目标首拍确认中")
        expect(c.step(temp: 76, dt: 3.0) != nil, "76 连续 2 拍夺回")
    }
    // 静音会议期禁止交还（系统接管行为不确定）
    do {
        var c = AIController()
        for _ in 0..<60 { _ = c.step(temp: 55, allowRelease: false, dt: 3.0) }
        expect(!c.idleReleased, "allowRelease=false 不交还")
        expect(c.step(temp: 55, allowRelease: false, dt: 3.0) != nil, "会议期持续输出")
    }
    // 交还中途静音激活 → 强制夺回（不等连续拍确认：会议风扇必须受静音封顶约束）
    do {
        var c = AIController()
        for _ in 0..<40 { _ = c.step(temp: 55, dt: 3.0) }
        expect(c.idleReleased, "先交还")
        let r = c.step(temp: 55, allowRelease: false, dt: 3.0)   // 温度未变，仅静音激活
        expect(r != nil && !c.idleReleased, "静音激活强制夺回")
    }
    // 振荡冷却 + 循环抑制（v2.9.2）：夺回后 10 分钟窗口内非深凉门槛翻倍（40→80 拍）；
    // 且"释放后 ≤240s 即被夺回"武装 30 分钟循环抑制——期间保持最低转速不交还
    // （0→2000+RPM 启停是轴承最高磨损事件，实测极限环周期 ~110s、2 天 261 次）。
    // 抑制期满后恢复释放能力（30 分钟一次试探，降磨损 15×）。
    do {
        var c = AIController()
        for _ in 0..<40 { _ = c.step(temp: 66, dt: 3.0) }
        expect(c.idleReleased, "首次交还")
        _ = c.step(temp: 76, dt: 3.0); _ = c.step(temp: 76, dt: 3.0)      // 过线连续 2 拍夺回
        expect(!c.idleReleased, "已夺回")
        expect(c.cyclingGuardArmed, "释放后 6s 即夺回 → 武装循环抑制")
        var releasedAt40 = false
        for i in 0..<80 {
            let r = c.step(temp: 66, dt: 3.0)
            if i == 39 { releasedAt40 = (r == nil) }
        }
        expect(!releasedAt40, "冷却窗口内 40 拍不释放")
        expect(!c.idleReleased, "80 拍（240s）仍在循环抑制期内不释放")
        // 抑制期满（1800s = 600 拍）→ 恢复释放能力
        var released = false
        for _ in 0..<600 { if c.step(temp: 66, dt: 3.0) == nil { released = true; break } }
        expect(released, "抑制期满后恢复交还")
    }
    // 交还中安全事件由管线兜住（AI 输出 nil 不豁免红线）——管线侧测试另见 testPipeline

    group("AI学习前馈")
    // 首拍播种优先学习值
    do {
        var c = AIController()
        expectEqual(c.step(temp: 76, learned: 42, dt: 3.0), 42, "首拍用学习值播种")
        var c2 = AIController()
        expectEqual(c2.step(temp: 76, dt: 3.0), 30, "无学习退回公式种子")
    }
    // 升温抬到学习值（直接拉转速）；降温不抬
    do {
        var c = AIController()
        _ = c.step(temp: 70, dt: 3.0)
        let o = c.step(temp: 72, learned: 55, dt: 3.0)!   // 斜率 +2 升温
        expect(o >= 55, "升温抬到学习值 (\(Int(o)))")
        var c2 = AIController()
        _ = c2.step(temp: 80, dt: 3.0); let hi = c2.output
        let d = c2.step(temp: 78, learned: 90, dt: 3.0)!  // 斜率 −2 降温
        expect(d <= hi, "降温段不抬输出")
    }
    // 夺回时也用学习值播种
    do {
        var c = AIController()
        for _ in 0..<40 { _ = c.step(temp: 55, dt: 3.0) }
        expect(c.idleReleased, "先交还")
        _ = c.step(temp: 76, learned: 33, dt: 3.0)        // 过线确认拍 1
        expectEqual(c.step(temp: 76, learned: 33, dt: 3.0), 33, "夺回用学习值起步")
    }
}


// MARK: - AI 意图与电源感知


func testAIIntentAndPower() {
    group("AI意图")
    do {
        var c = AIController()
        expectEqual(c.intent(temp: 70), .holding, "无历史=维持")
        // intent() 在 daemon 中紧跟 step(temp:) 以同温调用，读取 step 内部算出的变化率
        _ = c.step(temp: 70, dt: 3.0)
        _ = c.step(temp: 74, dt: 3.0)   // 斜率 +4/3s ≈ 1.33°C/s > 0.2 → rising
        expectEqual(c.intent(temp: 74), .rising, "升温斜率判 rising")
        _ = c.step(temp: 66, dt: 3.0)   // 斜率 −8/3s ≈ −2.67°C/s < −0.2 → falling
        expectEqual(c.intent(temp: 66), .falling, "降温斜率判 falling")
        _ = c.step(temp: 66.3, dt: 3.0) // 斜率 +0.3/3s = 0.1°C/s < 0.2 → holding
        expectEqual(c.intent(temp: 66.3), .holding, "带内平稳判维持")
        expect(!AIIntent.rising.label.isEmpty && AIIntent.falling.label.isEmpty == false
               && AIIntent.holding.label.isEmpty == false, "意图文案齐备")
    }
    group("AI电源感知")
    expectEqual(AIController.effectiveTarget(76, onBattery: false, batterySaver: true), 76,
                "市电不放宽")
    expectEqual(AIController.effectiveTarget(76, onBattery: true, batterySaver: false), 76,
                "未开省电开关不放宽")
    expectEqual(AIController.effectiveTarget(76, onBattery: true, batterySaver: true), 80,
                "电池+省电放宽 +4°")
    expectEqual(AIController.effectiveTarget(72, onBattery: true, batterySaver: true), 76,
                "性能档同样放宽")

    // v2.4：负载功耗会先于芯片温度抬升，功耗突增应在温度不变时先拉起风量。
    // v6：双通路前馈——快速通路（raw 增量 >15W）1 拍捕捉负载 onset，绕过 EMA 延迟。
    // 测试场景：12W→42W（raw 增量 30W）应立即触发快速通路，boost ≥ 10%。
    // 修复前（单一 EMA）：EMA 把 30W 压缩到 12W，boost 仅 2.4%，测试失败。
    do {
        var steady = AIController()
        var predictive = AIController()
        _ = steady.step(temp: 74, curvePercent: 30, powerWatts: 12, dt: 3.0)
        _ = predictive.step(temp: 74, curvePercent: 30, powerWatts: 12, dt: 3.0)
        let baseline = steady.step(temp: 74, curvePercent: 30, powerWatts: 12, dt: 3.0)!
        let boosted = predictive.step(temp: 74, curvePercent: 30, powerWatts: 42, dt: 3.0)!
        expect(boosted > baseline + 10, "功耗突增在温度未升前提前加速")
        expect(boosted <= 100, "功耗前馈受安全上限约束")
    }

    // v6 对抗式审查：双通路边界
    do {
        // 噪声带内（±2W）：快速通路（15W 阈值）不应触发，慢速通路 EMA 后 <3W 也不触发
        var noise = AIController()
        _ = noise.step(temp: 74, curvePercent: 30, powerWatts: 12, dt: 3.0)
        let n1 = noise.step(temp: 74, curvePercent: 30, powerWatts: 14, dt: 3.0)!  // +2W 噪声
        var stable = AIController()
        _ = stable.step(temp: 74, curvePercent: 30, powerWatts: 12, dt: 3.0)
        let s1 = stable.step(temp: 74, curvePercent: 30, powerWatts: 12, dt: 3.0)!
        expect(n1 <= s1 + 1, "噪声级功耗波动不触发前馈（±2W）")

        // 快速通路阈值边缘：raw=15W 恰不触发（> 而非 >=），raw=16W 触发但 boost 很小
        var edge = AIController()
        _ = edge.step(temp: 74, curvePercent: 30, powerWatts: 10, dt: 3.0)
        let e1 = edge.step(temp: 74, curvePercent: 30, powerWatts: 25, dt: 3.0)!  // raw=15W, 恰不触发
        var edge2 = AIController()
        _ = edge2.step(temp: 74, curvePercent: 30, powerWatts: 10, dt: 3.0)
        let e2 = edge2.step(temp: 74, curvePercent: 30, powerWatts: 26, dt: 3.0)! // raw=16W, fastBoost=0.7
        expect(e2 > e1, "raw 阈值边缘：16W 触发而 15W 不触发（> 语义）")
        expect(e2 - e1 <= 1.5, "快速通路边缘 boost 受 fastGain 约束")

        // 渐变负载：连续小步上升（每拍 +5W），快速通路不触发（<15W），
        // 慢速通路 EMA 累积后应能触发，验证慢速通路未被破坏
        var gradual = AIController()
        var stable2 = AIController()
        var gOut: Double = 0, sOut: Double = 0
        for p in [10.0, 15.0, 20.0, 25.0, 30.0] {
            gOut = gradual.step(temp: 74, curvePercent: 30, powerWatts: p, dt: 3.0)!
            sOut = stable2.step(temp: 74, curvePercent: 30, powerWatts: 10, dt: 3.0)!
        }
        expect(gOut > sOut, "渐变负载（5 拍 10→30W）慢速通路累积触发前馈")
    }
}


// MARK: - 热经验学习 ThermalLearn


func testThermalLearn() {
    group("热经验学习")
    var l = ThermalLearn()
    expect(l.percent(for: 60) == nil, "无数据返回 nil")
    l.record(temp: 60, percent: 40); l.record(temp: 60, percent: 44)
    expect(l.percent(for: 60) == nil, "样本不足(<3)不采信")
    l.record(temp: 60, percent: 42)
    expect(l.percent(for: 60) != nil, "3 样本后采信")

    // 早期平均：前 5 个样本算术平均，之后切换到 EMA
    var e = ThermalLearn()
    e.record(temp: 70, percent: 10)
    e.record(temp: 70, percent: 10)    // 补样本到采信阈值（值不变，不影响期望）
    e.record(temp: 70, percent: 100)
    // 3 个样本均在早期平均窗口内：(10+10+100)/3 = 40
    expectClose(e.percent(for: 70)!, 40, 1e-9, "早期平均")
    // EMA 切换：第 6 个样本开始用 EMA
    var e2 = ThermalLearn()
    for _ in 0..<5 { e2.record(temp: 70, percent: 10) }  // 早期平均完成，值为 10
    e2.record(temp: 70, percent: 100)  // 第 6 个样本，EMA: 10 + 0.15*(100-10) = 23.5
    expectClose(e2.percent(for: 70)!, 23.5, 1e-9, "EMA 切换后权重")

    // 两点插值与单侧外推
    // 桶 50°C → 桶 5 (midTemp=51, output=10), 桶 70°C → 桶 15 (midTemp=71, output=50)
    // 插值用实际温度在 [tLo, tHi] 之间的位置，而非桶索引位置（修复前的 bug）
    var m = ThermalLearn()
    for _ in 0..<5 { m.record(temp: 50, percent: 10); m.record(temp: 70, percent: 50) }
    expectClose(m.percent(for: 50)!, 10, 1e-9, "数据桶直取")
    // temp=60 在 [51, 71] 之间，t=(60-51)/(71-51)=0.45 → 10+0.45*40=28
    expectClose(m.percent(for: 60)!, 28, 1e-9, "桶间插值用实际温度比例")
    // temp=61 恰好是 51 和 71 的中点 → t=0.5 → 30
    expectClose(m.percent(for: 61)!, 30, 1e-9, "桶中值温度中点插值")
    // temp=55 在 [51, 71] 之间，t=(55-51)/(71-51)=0.2 → 10+0.2*40=18
    expectClose(m.percent(for: 55)!, 18, 1e-9, "非中点位置插值精度")
    // 4.0 B3 采信域：单侧外推限带宽 10°C——带内沿用单侧值，带外返回 nil
    //（低温平衡平推到高温 = 欠冷却方向的错误播种，族扫描 env28/R1.3/τ25/A28 实证）
    expectClose(m.percent(for: 79)!, 50, 1e-9, "带内单侧（71+8 ≤ 10）沿用")
    expectClose(m.percent(for: 43)!, 10, 1e-9, "带内下单侧（51-8 ≤ 10）沿用")
    expect(m.percent(for: 84) == nil, "超出数据区 13° > 带宽 → nil（不再外推）")
    expect(m.percent(for: 30) == nil, "低于数据区 21° > 带宽 → nil（对称防御）")

    // 记录钳位 + Codable 往返
    var cl = ThermalLearn()
    for _ in 0..<3 { cl.record(temp: 60, percent: 150) }
    expectClose(cl.percent(for: 60)!, 100, 1e-9, "输出钳到 100")
    let data = try! JSONEncoder().encode(m)
    let back = try! JSONDecoder().decode(ThermalLearn.self, from: data)
    expect(back == m, "Codable 往返")
    expectEqual(m.sampleTotal, 10, "样本总数")
    expectEqual(m.learnedBucketCount, 2, "学会的桶数（UI 温度点语义）")
    expectEqual(ThermalLearn().learnedBucketCount, 0, "空白无学习点")

    // v2.4：同温度的轻载/重载热需求分开学习，避免低负载样本拉低重载前馈。
    do {
        var contextual = ThermalLearn()
        for _ in 0..<3 {
            contextual.record(temp: 70, percent: 25, onBattery: false, powerWatts: 10)
            contextual.record(temp: 70, percent: 65, onBattery: false, powerWatts: 45)
        }
        expectClose(contextual.percent(for: 70, onBattery: false, powerWatts: 10)!, 25, 1e-9,
                    "轻载场景采用轻载经验")
        expectClose(contextual.percent(for: 70, onBattery: false, powerWatts: 45)!, 65, 1e-9,
                    "重载场景采用重载经验")
        expectClose(contextual.percent(for: 70, onBattery: true, powerWatts: 10)!, 44.6, 1e-9,
                    "未学习的新场景回退全局经验")
    }

    // 早期平均抗异常值：首样本偏高（瞬态残留）后接正常值，平均后偏离更小
    do {
        var early = ThermalLearn()    // 早期平均
        early.record(temp: 60, percent: 80)   // 首样本异常高（如手动模式残留）
        for _ in 0..<4 { early.record(temp: 60, percent: 30) }  // 4 个正常值
        // 早期平均: (80+30+30+30+30)/5 = 40
        expectClose(early.percent(for: 60)!, 40, 1e-9, "早期平均抗异常值")

        // 对照：旧策略（首样本直接落值 + EMA）在相同数据下偏离更大
        // 首样本 80，其后 4 个 EMA: 80 → 80+0.15*(30-80)=72.5 → 72.5+0.15*(30-72.5)=66.125
        // → 66.125+0.15*(30-66.125)=60.7 → 60.7+0.15*(30-60.7)=56.1
        // 旧策略 5 拍后 ≈56.1 vs 早期平均 40 → 早期平均更接近真值 30
        expect(early.percent(for: 60)! < 56, "早期平均比旧 EMA 更快收敛到真值")
    }

    // 污染桶清洗：低温高输出桶被重置，高温高输出桶保留
    do {
        var q = ThermalLearn()
        for _ in 0..<5 { q.record(temp: 60, percent: 95) }  // 60°C 污染（>30% 阈值）
        for _ in 0..<5 { q.record(temp: 85, percent: 90) }  // 85°C 合理（高温确实需要高转速）
        for _ in 0..<5 { q.record(temp: 50, percent: 25) }  // 50°C 合理（<30% 阈值）
        let bucket60 = TempHistogram.bucketIndex(for: 60)
        expect(q.samplesByBucket[bucket60] >= 3, "清洗前 60°C 桶有样本")
        let cleaned = q.sanitizeCorruptedBuckets()
        expectEqual(cleaned, 1, "只清洗 60°C 污染桶（1 个）")
        expectEqual(q.samplesByBucket[bucket60], 0, "60°C 污染桶样本已清零")
        expectClose(q.percent(for: 85)!, 90, 1e-9, "85°C 合理桶保留")
        expectClose(q.percent(for: 50)!, 25, 1e-9, "50°C 合理桶保留")
    }

    // v3.6（方向二）：包络健康度仪表——gap = 高温段 max(更低采信桶 − 本桶 EMA)
    do {
        var g = ThermalLearn()
        for _ in 0..<3 { g.record(temp: 82, percent: 85) }   // 82° 采信
        for _ in 0..<3 { g.record(temp: 88, percent: 62) }   // 88° 采信（非单调）
        expectClose(g.envelopeGap()!, 23, 1e-9, "88° 桶包络差 = 85-62 = 23")
        var h = ThermalLearn()
        for _ in 0..<3 { h.record(temp: 82, percent: 60) }
        for _ in 0..<3 { h.record(temp: 88, percent: 85) }   // 已单调
        expectClose(h.envelopeGap()!, 0, 1e-9, "单调学习图 gap = 0")
        expect(ThermalLearn().envelopeGap() == nil, "无数据返回 nil")
        var lo = ThermalLearn()
        for _ in 0..<3 { lo.record(temp: 60, percent: 30) }
        for _ in 0..<3 { lo.record(temp: 70, percent: 10) }  // 查询域外统计：gap 仍看 ≥75°
        expect(lo.envelopeGap() == nil, "仅 <75° 数据 → nil（高温段域外，R27 不改 gap 口径）")
    }

    // v3.4.5（3B）：高温段单调化——非单调先验在 ≥75° 查询时向上取包络
    do {
        var nm = ThermalLearn()
        for _ in 0..<3 { nm.record(temp: 82, percent: 85) }   // 82° 桶采信（高需求）
        for _ in 0..<3 { nm.record(temp: 88, percent: 62) }   // 88° 桶采信（瞬态污染，低于 82°）
        expectClose(nm.percent(for: 88)!, 85, 1e-9, "高温非单调向上取包络（88° 需求 ≥ 82°）")
        expectClose(nm.percent(for: 86)!, 85, 1e-9, "86° 插值(73.5) 后仍取包络 85")
        // R27（L3-F3）：查表单调化扩到全温域——真机 69°=96%>73°=84% 属先验违例
        var lo = ThermalLearn()
        for _ in 0..<3 { lo.record(temp: 60, percent: 30) }
        for _ in 0..<3 { lo.record(temp: 70, percent: 20) }   // 70° 低于 60°（低温非单调）
        expectClose(lo.percent(for: 70)!, 30, 1e-9,
                    "R27：低温非单调也向上取包络（70° 需求 ≥ 60°）")
        expectClose(lo.percent(for: 60)!, 30, 1e-9, "60° 桶原值")
    }

    // v5: NaN/Inf 防御——record 接收 NaN percent 时不污染学习数据
    // 修复前：min(max(NaN, 0), 100) 依赖 Swift NaN 比较返回 false 的隐式行为得到 0
    // 修复后：显式 isFinite 检查，NaN 记为 0（不污染，但占用样本计数）
    // 上游 controller.shape 理论上已钳位，但学习数据污染后果严重（影响 AI 前馈），值得双重防御
    do {
        var n = ThermalLearn()
        n.record(temp: 70, percent: .nan)       // call 1: samples 0→1, output=(0*0+0)/1=0
        n.record(temp: 70, percent: .infinity)   // call 2: samples 1→2, output=(0*1+0)/2=0
        n.record(temp: 70, percent: 50)          // call 3: samples 2→3, output=(0*2+50)/3=16.6667
        expectClose(n.percent(for: 70)!, 50.0/3.0, 1e-9, "NaN/Inf 记为 0 不污染（早期平均）")
        // 正常值仍可学习：前 5 个样本走早期平均，之后切换 EMA
        // call 4: samples 3→4, early avg: (16.6667*3+60)/4 = 27.5
        // call 5: samples 4→5, early avg: (27.5*4+60)/5 = 34.0
        // call 6: samples 5→6, EMA: 34.0 + 0.15*(60-34.0) = 37.9
        // call 7: samples 6→7, EMA: 37.9 + 0.15*(60-37.9) = 41.215
        // call 8: samples 7→8, EMA: 41.215 + 0.15*(60-41.215) = 44.03275
        for _ in 0..<5 { n.record(temp: 70, percent: 60) }
        let expected = 41.215 + 0.15 * (60 - 41.215)
        expectClose(n.percent(for: 70)!, expected, 1e-9, "NaN 后正常值可继续学习（EMA）")
    }

    // v6: 时间衰减——超过 staleDays 天未更新的桶样本数减半
    do {
        var q = ThermalLearn()
        for _ in 0..<10 { q.record(temp: 70, percent: 50) }
        for _ in 0..<10 { q.record(temp: 80, percent: 90) }
        // 70°C 桶最后更新时间在 15 天前（超过 14 天阈值）
        let oldDate = Date().addingTimeInterval(-15 * 86400)
        q.setLastUpdated(bucket: TempHistogram.bucketIndex(for: 70), date: oldDate)
        // 80°C 桶最后更新时间在 5 天前（未超阈值）
        q.setLastUpdated(bucket: TempHistogram.bucketIndex(for: 80), date: Date().addingTimeInterval(-5 * 86400))

        let decayed = q.decayStaleBuckets()
        expectEqual(decayed, 1, "只衰减 70°C 过时桶（1 个）")
        // 70°C 桶样本 10→5（减半），仍 ≥ minSamples=3，output 保留
        expect(q.samplesByBucket[TempHistogram.bucketIndex(for: 70)] == 5, "70°C 桶样本减半 10→5")
        expect(q.percent(for: 70) != nil, "70°C 桶样本仍 ≥3，output 保留")
        // 80°C 桶不受影响
        expectEqual(q.samplesByBucket[TempHistogram.bucketIndex(for: 80)], 10, "80°C 桶不受影响")
    }

    // v6: 时间衰减——样本数 < minSamples 时清除 output
    do {
        var q = ThermalLearn()
        for _ in 0..<3 { q.record(temp: 70, percent: 50) }  // 样本=3=minSamples
        q.setLastUpdated(bucket: TempHistogram.bucketIndex(for: 70), date: Date().addingTimeInterval(-20 * 86400))
        let decayed = q.decayStaleBuckets()
        expectEqual(decayed, 1, "衰减 1 个桶")
        // v3.6.1：3/2=1（整数除法），1 < minSamples=3 → output 与 samples 双清
        //（原实现清 output 留 samples=1，复学首样本走 (0×1+p)/2 的幽灵 0 平均）
        expectEqual(q.samplesByBucket[TempHistogram.bucketIndex(for: 70)], 0, "样本 3→0（双清）")
        expect(q.percent(for: 70) == nil, "样本 <3 时 percent 返回 nil（output 已清零）")
    }

    // v3.6.1: 幽灵 0 回归——过期桶双清后复学，首个新样本不得被"幽灵 0"拉低
    do {
        var q = ThermalLearn()
        for _ in 0..<4 { q.record(temp: 85, percent: 85) }   // samples=4, output=85
        q.setLastUpdated(bucket: TempHistogram.bucketIndex(for: 85), date: Date().addingTimeInterval(-20 * 86400))
        _ = q.decayStaleBuckets()
        // 旧行为：samples=2 保留、output=0 → 首样本 (0×2+85)/3 ≈ 28.3，1 样本即达 minSamples
        // 采信伪低值 28%，系统性欠冷。新行为：双清 → 首样本即 85
        q.record(temp: 85, percent: 85)
        let v = q.outputByBucket[TempHistogram.bucketIndex(for: 85)]
        expectClose(v, 85, 1e-9, "双清后复学首样本 = 85（无幽灵 0 拉低，得 \(v)）")
        // 衰减后 updated 已推进：同一时间轴再次衰减不得重复减半
        let second = q.decayStaleBuckets(now: Date().addingTimeInterval(86400))
        expectEqual(second, 0, "衰减已标记 updated，14 天窗口内不重复衰减")
    }

    // v8: 场景桶同样衰减——旧场景经验（含手动污染/旧 target 数据）不再永存
    do {
        var q = ThermalLearn()
        for _ in 0..<5 { q.record(temp: 70, percent: 40, onBattery: false, powerWatts: 10) }
        for _ in 0..<5 { q.record(temp: 70, percent: 60, onBattery: true, powerWatts: 10) }
        // 16 天后再衰减：全局桶 10→5（仍 ≥3 采信），ac-light/battery-light 场景桶 5→2（<3 失效）
        let decayed = q.decayStaleBuckets(now: Date().addingTimeInterval(16 * 86400))
        expect(decayed >= 3, "全局 1 桶 + 场景 2 桶都触发衰减（实际 \(decayed)）")
        // 场景桶样本 <3 → 回退全局。全局 = 5×40 早期平均 + 5×60 EMA ≈ 51.1，
        // 不再返回场景原值 40（证明场景经验已被衰减失效）
        let s1 = q.percent(for: 70, onBattery: false, powerWatts: 10)
        expect(s1 != nil && s1! > 40 && s1! < 55,
               "过时场景桶回退全局（不返回场景原值 40，得 \(String(describing: s1))）")
    }

    // v8: 场景桶同样清洗——低温高输出场景桶被重置
    do {
        var q = ThermalLearn()
        for _ in 0..<5 { q.record(temp: 55, percent: 95, onBattery: true, powerWatts: 45) }
        let cleaned = q.sanitizeCorruptedBuckets()
        expectEqual(cleaned, 2, "清洗全局桶 + 场景桶各 1 个（55°C/95% 污染）")
        expect(q.percent(for: 55, onBattery: true, powerWatts: 45) == nil, "污染场景桶清洗后回退全局")
    }

    // v6: Codable 向后兼容——旧版本无 lastUpdatedByBucket 字段
    do {
        // 模拟旧版本数据（无 lastUpdatedByBucket，桶 15 = 70°C 有数据）
        var outputs = [Double](repeating: 0, count: TempHistogram.bucketCount)
        var samples = [Int](repeating: 0, count: TempHistogram.bucketCount)
        let b70 = TempHistogram.bucketIndex(for: 70)
        outputs[b70] = 50.0
        samples[b70] = 5
        // 用 JSONSerialization 构造不含 lastUpdatedByBucket 的字典
        let dict: [String: Any] = ["outputByBucket": outputs, "samplesByBucket": samples]
        let data = try JSONSerialization.data(withJSONObject: dict)
        var decoded = try JSONDecoder().decode(ThermalLearn.self, from: data)
        expectEqual(decoded.samplesByBucket[b70], 5, "旧数据 samplesByBucket 正确解码")
        expectClose(decoded.outputByBucket[b70], 50, 1e-9, "旧数据 outputByBucket 正确解码")
        // lastUpdatedByBucket 默认 .distantPast → 衰减会触发
        let decayed = decoded.decayStaleBuckets()
        expect(decayed >= 1, "旧数据 lastUpdated=.distantPast，衰减触发")
    } catch {
        expect(false, "旧版本 ThermalLearn 解码失败: \(error)")
    }

    // v6: Codable 往返（含 lastUpdatedByBucket）
    do {
        var q = ThermalLearn()
        for _ in 0..<5 { q.record(temp: 70, percent: 50) }
        let encoded = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(ThermalLearn.self, from: encoded)
        expectEqual(decoded.samplesByBucket, q.samplesByBucket, "往返 samplesByBucket 一致")
        expectEqual(decoded.outputByBucket, q.outputByBucket, "往返 outputByBucket 一致")
        expectEqual(decoded.lastUpdatedByBucket.count, TempHistogram.bucketCount, "往返 lastUpdatedByBucket 长度")
    } catch {
        expect(false, "ThermalLearn 往返失败: \(error)")
    }
}


func testThermalModel() {
    group("散热参数模型")
    var m = ThermalModel()
    expect(m.predictedPercent(for: 25, power: 40, targetTemp: 76) == nil, "样本不足不预测")

    // 合成线性数据：temp = env + 0.8·P − 0.3·percent（真值 a=0.8°C/W, b=0.3°C/%，
    // 接近真实 Apple Silicon 的量级：40W 负载温升 32°C，100% 风量压 30°C）
    let truths: [(env: Double, power: Double, percent: Double)] = [
        (20, 20, 30), (25, 40, 50), (30, 60, 70), (22, 35, 45),
        (28, 55, 65), (25, 80, 85), (18, 15, 20), (26, 45, 55),
        (24, 70, 75), (21, 30, 40), (27, 50, 60), (23, 65, 72),
    ]
    for _ in 0..<150 {
        for t in truths {
            let temp = t.env + 0.8 * t.power - 0.3 * t.percent
            m.update(env: t.env, power: t.power, percent: t.percent, temp: temp)
        }
    }
    expect(m.sampleCount >= ThermalModel.minSamples, "样本数达标")
    expect(abs(m.a - 40) < 6, "热阻参数收敛到物理 0.8（归一化得 \(m.a)）")
    expect(abs(m.b - 15) < 3, "风量降温参数收敛到物理 0.3（归一化得 \(m.b)）")
    // R29：isMature 与 predictedPercent 同门槛（b>2.5）
    expect(m.isMature && m.b > 2.5, "收敛模型 isMature=true 且 b>2.5")

    // 预测一致性：模型学到的参数应能回答"压到目标需要多少风量"
    if let pred = m.predictedPercent(for: 25, power: 40, targetTemp: 45) {
        // 真值：45 = 25 + 0.8·40 − 0.3·p → p = (25+32−45)/0.3 = 40
        expectClose(pred, 40, 8, "预测与真值一致（得 \(pred)）")
    } else { expect(false, "成熟模型应能预测") }

    // R29：样本多但 b 钉死在下限 → 不得宣称 mature（真机 b=1.0 预测恒 nil）
    var stuck = ThermalModel()
    for i in 0..<1200 {
        // 极弱风量效应样本：温度几乎不随 percent 变化 → b 推向下限。
        // R35：原用未播种 Double.random——b 偶尔>2.5 时下面整段断言静默不执行
        // （断言总数在 4690/4696 间随机漂移，CI 徽章与契约门槛都在说谎）。
        // 改确定性伪随机序列 + 轮数 200→1200：审查实测 200 轮 b=2.44 只离诚实门 0.06，
        // 改任何常量都会翻越门槛让段内 6 条断言静默失踪；1200 轮 b≈0.94，余量 64%。
        stuck.update(env: 30, power: 20, percent: 10 + Double((i * 37) % 81), temp: 70)
    }
    expect(stuck.sampleCount >= ThermalModel.minSamples, "卡死模型样本数仍可很高")
    expect(stuck.b <= 2.5, "确定性弱风量样本把 b 压进诚实门下方（得 \(stuck.b)）")
    expect(!stuck.isMature, "b≤2.5 时 isMature=false（R29 诚实门）")
    expect(stuck.predictedPercent(for: 30, power: 20, targetTemp: 50) == nil,
           "b≤2.5 预测 nil")
    var why: String? = nil
    expect(stuck.resetIfUnusable(reason: &why), "未收敛模型可重置")
    expect(stuck.sampleCount == 0 && stuck.b > 2.5, "重置后回到新模型")
    expect(why != nil, "重置给出日志原因")
    var why2: String? = nil
    expect(!stuck.resetIfUnusable(reason: &why2), "新模型不再重置")

    // 物理约束：异常样本不把参数推出合理域（归一化域 [0,100]×[1,100]）
    var m2 = ThermalModel()
    for _ in 0..<5 { m2.update(env: 25, power: 1000, percent: 100, temp: 200) }
    expect(m2.a >= 0 && m2.a <= 100 && m2.b >= 1 && m2.b <= 100, "参数钳位在物理合理域")

    // NaN 防御
    var m3 = ThermalModel()
    m3.update(env: .nan, power: 40, percent: 50, temp: 60)
    expect(m3.sampleCount == 0, "NaN 样本不计数")

    // Codable 往返
    let back = try! JSONDecoder().decode(ThermalModel.self, from: JSONEncoder().encode(m))
    expect(back == m, "模型 Codable 往返")

    // v2.6.2: 冷启动(多样本:env 25, 40W, 风量越足温度越低,真实 b≈0.16)——
    // 初始化典型值 + 误差钳制后,b 不被钉死在 0.02 下限(预测长期 nil)
    do {
        var m0 = ThermalModel()
        let samples: [(power: Double, percent: Double, temp: Double)] = [
            (40, 30, 50), (40, 70, 44), (40, 100, 38), (20, 50, 40),
            (60, 40, 62), (30, 80, 34), (50, 60, 48), (35, 90, 40),
        ]
        for _ in 0..<10 {
            for s in samples {
                m0.update(env: 25, power: s.power, percent: s.percent, temp: s.temp)
            }
        }
        expect(m0.b >= 2.5, "冷启动后 b 脱离钉死下限（归一化得 \(m0.b)，物理 \(m0.b/50)）")
        expect(m0.predictedPercent(for: 25, power: 40, targetTemp: 45) != nil,
               "冷启动后可预测（模型未白学）")
    }

    // v2.7 预测采信域：样本带外（+余量）不外推（闭环辨识偏差经除以 b 放大不可控）
    do {
        var mb = ThermalModel()
        let samples: [(power: Double, percent: Double, temp: Double)] = [
            (40, 30, 50), (40, 70, 44), (40, 100, 38), (20, 50, 40),
            (60, 40, 62), (30, 80, 34), (50, 60, 48), (35, 90, 40),
        ]
        for _ in 0..<10 {
            for s in samples { mb.update(env: 25, power: s.power, percent: s.percent, temp: s.temp) }
        }
        // 采样带：power 20~60（±10 余量 → 10~70），env 25（±5 → 20~30）
        expect(mb.predictedPercent(for: 25, power: 40, targetTemp: 45) != nil, "band 内可预测")
        expect(mb.predictedPercent(for: 25, power: 200, targetTemp: 45) == nil, "power 带外不外推")
        expect(mb.predictedPercent(for: 45, power: 40, targetTemp: 45) == nil, "env 带外不外推")
        expect(mb.predictedPercent(for: 27, power: 55, targetTemp: 45) != nil, "band+余量内可预测")
    }

    // v2.7 旧数据（无范围记录）兼容：范围缺失 = 不设限，保持升级前行为
    do {
        let legacy = #"{"a":25,"b":5,"sampleCount":100}"#.data(using: .utf8)!
        let old = try! JSONDecoder().decode(ThermalModel.self, from: legacy)
        expect(old.minPower == nil && old.maxEnv == nil, "旧模型无范围字段兼容")
        // 目标 40：need = (25+20−40)/0.1 = 50 > 0
        expect(old.predictedPercent(for: 25, power: 40, targetTemp: 40) != nil,
               "旧数据保持原行为（范围不设限）")
        // R33：need≤0（目标 45 → need=0）不得返回合法 0%
        expect(old.predictedPercent(for: 25, power: 40, targetTemp: 45) == nil,
               "need≤0 → nil（防 0% 短路）")
    }

    // R33（控制安全 P1）：need≤0 不得返回合法 0%（.some(0) 会短路 learned??curve??seed）
    do {
        expect(m.predictedPercent(for: 25, power: 40, targetTemp: 200) == nil,
               "目标远高于模型平衡 → need≤0 → nil 而非 0% 前馈")
        if let p = m.predictedPercent(for: 25, power: 40, targetTemp: 45) {
            expect(p > 0, "正常工况预测为正风量（得 \(p)）")
        }
    }

    // R33：learned=0 不得短路曲线/公式种子（P5 欠冷更贵）；优先级仍 learned>curve>seed
    do {
        var c = AIController()
        let o = c.step(temp: 85, learned: 0, curvePercent: 40, dt: 3.0)
        if let o {
            expect(o >= 40, "learned=0 播种应落到曲线 40 或更高（得 \(o)）")
        } else { expect(false, "首拍应有输出") }
    }
}


func testNightAndEnv() {
    group("夜间与环境补偿")
    let bal = CurvePreset.balanced.points
    let future = Date().addingTimeInterval(600)

    // envOffset 边界
    expectEqual(FanPipeline.envOffset(envTemp: nil, enabled: true), 0, "无环境 → 0")
    expectEqual(FanPipeline.envOffset(envTemp: 25, enabled: true), 0, "25° 基准 → 0")
    expectClose(FanPipeline.envOffset(envTemp: 35, enabled: true), 5, 1e-9, "35° → +5")
    expectClose(FanPipeline.envOffset(envTemp: 15, enabled: true), -5, 1e-9, "15° → −5")
    expectClose(FanPipeline.envOffset(envTemp: 45, enabled: true), 8, 1e-9, "45° 封顶 +8")
    expectEqual(FanPipeline.envOffset(envTemp: 35, enabled: false), 0, "关闭 → 0")

    // 曲线模式 + 环境补偿：夏天（env=35, offset=+5）同一绝对温度查表左移 → 输出更低
    let cfg = FanConfig(mode: .curve, curve: bal, preset: .balanced, envCompensation: true)
    let summer = FanPipeline.decide(config: cfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                    onBattery: false, aiPercent: nil, now: Date(),
                                    envTemp: 35)
    let plain = FanPipeline.decide(config: cfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                   onBattery: false, aiPercent: nil, now: Date(),
                                   envTemp: 25)
    expect(summer.targetPercent! < plain.targetPercent!,
           "夏天补偿后同温输出更低（65° 查表 vs 70° 查表）")
    expectEqual(summer.reason, .curve, "主因仍为曲线")
    let winter = FanPipeline.decide(config: cfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                    onBattery: false, aiPercent: nil, now: Date(),
                                    envTemp: 15)
    expect(winter.targetPercent! > plain.targetPercent!, "冬天补偿后同温输出更高")

    // 环境补偿关闭时行为与原来一致
    let off = FanPipeline.decide(config: FanConfig(mode: .curve, curve: bal, preset: .balanced,
                                                   envCompensation: false),
                                 smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                 onBattery: false, aiPercent: nil, now: Date(), envTemp: 35)
    expectClose(off.targetPercent!, plain.targetPercent!, 1e-9, "关闭补偿 = 原行为")

    // 夜间安静档：夜间用 quiet 曲线 + nightOverride 标记 + reason .night
    let nightCfg = FanConfig(mode: .curve, curve: bal, preset: .balanced, quietHours: true)
    let night = FanPipeline.decide(config: nightCfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                   onBattery: false, aiPercent: nil, now: Date(), nightActive: true)
    expectEqual(night.reason, .night, "夜间主因 .night")
    expect(night.nightOverride, "夜间覆盖标记")
    expectClose(night.targetPercent!,
                FanConfig.percent(temp: 70, curve: CurvePreset.quiet.points), 1e-9,
                "夜间用 quiet 曲线")
    // 白天不覆盖
    let day = FanPipeline.decide(config: nightCfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                 onBattery: false, aiPercent: nil, now: Date(), nightActive: false)
    expect(!day.nightOverride && day.reason == .curve, "白天正常曲线")
    // 未开启 quietHours 不覆盖
    let off2 = FanPipeline.decide(config: FanConfig(mode: .curve, curve: bal, preset: .balanced),
                                  smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                  onBattery: false, aiPercent: nil, now: Date(), nightActive: true)
    expect(!off2.nightOverride, "未开启夜间档不覆盖")
    // 电池档优先于夜间档
    let battNight = FanPipeline.decide(config: FanConfig(mode: .curve, curve: bal, preset: .balanced,
                                                         batteryPreset: .quiet, quietHours: true),
                                       smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                       onBattery: true, aiPercent: nil, now: Date(), nightActive: true)
    expectEqual(battNight.reason, .battery, "电池档优先于夜间档")
    // 安全红线覆盖夜间档
    let fs = FanPipeline.decide(config: nightCfg, smoothedTemp: 60, rawTemp: 93, nandTemp: 40,
                                onBattery: false, aiPercent: nil, now: Date(), nightActive: true)
    expectEqual(fs.reason, .failsafe, "兜底覆盖夜间档")
    expectEqual(fs.targetPercent, 100, "兜底全速不受夜间档影响")
    expect(!fs.nightOverride, "兜底清除夜间标记")

    // 静音承诺叠加夜间档
    let quietNight = FanPipeline.decide(config: FanConfig(mode: .curve, curve: bal, preset: .balanced,
                                                          quietUntil: future,
                                                          quietCapPercent: 30,
                                                          quietHours: true),
                                        smoothedTemp: 85, rawTemp: 85, nandTemp: 40,
                                        onBattery: false, aiPercent: nil, now: Date(),
                                        nightActive: true)
    expectEqual(quietNight.reason, ControlReason.quiet, "会议静音压过夜间档")

    // 电池档同样应用环境补偿：夏天（env=35, offset=+5）查表温度左移 → 输出更低。
    // 此前电池分支漏了 envOff，夏天电池模式风扇比语义上更激进
    let battCfg = FanConfig(mode: .curve, curve: bal, preset: .balanced,
                            batteryPreset: .quiet, envCompensation: true)
    let battSummer = FanPipeline.decide(config: battCfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                        onBattery: true, aiPercent: nil, now: Date(),
                                        envTemp: 35)
    let battPlain = FanPipeline.decide(config: battCfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                       onBattery: true, aiPercent: nil, now: Date(),
                                       envTemp: 25)
    expect(battSummer.targetPercent! < battPlain.targetPercent!,
           "夏天电池档补偿后同温输出更低（65° 查表 vs 70° 查表）")
    expectClose(battSummer.targetPercent!,
                FanConfig.percent(temp: 65, curve: CurvePreset.quiet.points), 1e-9,
                "电池档按 temp−envOff 查表（与日间/夜间一致）")
    expectEqual(battSummer.reason, .battery, "主因仍为电池档")

    // activeCurve：AI 锚定基准的语境曲线选择（电池 > 夜间 > 基础，与 decide() 一致）。
    // 电池省电时目标 +4° 使工作点更热，基础曲线在更热温度上期望值反而更高——
    // 锚定必须换用电池/夜间曲线，否则把 AI 稳态拉向高转速，与省电意图相反
    do {
        let base = CurvePreset.balanced.points
        let cfg = FanConfig(mode: .curve, curve: base, preset: .balanced,
                            batteryPreset: .quiet, quietHours: true)
        expect(FanPipeline.activeCurve(config: cfg, onBattery: true, nightActive: true)
            == CurvePreset.quiet.points, "电池档优先于夜间档")
        expect(FanPipeline.activeCurve(config: cfg, onBattery: false, nightActive: true)
            == CurvePreset.quiet.points, "夜间档用安静预设")
        expect(FanPipeline.activeCurve(config: cfg, onBattery: false, nightActive: false) == base,
            "白天用基础曲线")
        var c2 = cfg
        c2.batteryCurve = CurvePreset.aggressive.points
        expect(FanPipeline.activeCurve(config: c2, onBattery: true, nightActive: false)
            == CurvePreset.aggressive.points, "电池个性化曲线优先于预设")
        var c3 = cfg
        c3.nightCurve = CurvePreset.aggressive.points
        expect(FanPipeline.activeCurve(config: c3, onBattery: false, nightActive: true)
            == CurvePreset.aggressive.points, "夜间个性化曲线优先于预设")
        var c4 = cfg
        c4.quietHours = false
        expect(FanPipeline.activeCurve(config: c4, onBattery: false, nightActive: true) == base,
            "未开启 quietHours 夜间不覆盖")
        expect(FanPipeline.activeCurve(config: c4, onBattery: true, nightActive: false)
            == CurvePreset.quiet.points, "电池档不依赖 quietHours")
    }

    // FanConfig 新字段 Codable 兼容
    do {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let c = FanConfig(mode: .curve, envCompensation: false, quietHours: true)
        let back = try dec.decode(FanConfig.self, from: try enc.encode(c))
        expect(back.envCompensation == false && back.quietHours == true, "新字段往返")
        let legacy = #"{"mode":"curve","manualPercent":50,"curve":[{"temp":52,"percent":0},{"temp":85,"percent":100}]}"#.data(using: .utf8)!
        let lc = try dec.decode(FanConfig.self, from: legacy)
        expect(lc.envCompensation == true && lc.quietHours == false, "旧配置缺省兼容")
    } catch { expect(false, "night/env Codable 抛错: \(error)") }

    // DailyStats.avgPower 累计 + 旧数据兼容
    do {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var k = StatsSampler(now: Date())
        _ = k.record(temp: 60, totalRPM: 3000, seconds: 3, now: Date(), powerWatts: 40)
        _ = k.record(temp: 62, totalRPM: 3000, seconds: 3, now: Date(), powerWatts: 60)
        expectClose(k.stats.avgPower, 50, 1e-9, "平均功耗 = 加权平均")
        let back = try dec.decode(DailyStats.self, from: try enc.encode(k.stats))
        expectClose(back.avgPower, 50, 1e-9, "avgPower 往返")
        let legacy = #"{"date":"2026-07-01","maxTemp":80,"maxTempAt":"2026-07-01T10:00:00Z","highTempSeconds":60,"tempSum":50000,"tempCount":1000,"revolutions":123}"#.data(using: .utf8)!
        let ls = try dec.decode(DailyStats.self, from: legacy)
        expect(ls.avgPower == 0, "旧战报 avgPower=0 兼容")
        expectClose(ls.avgTemp, 50, 1e-9, "旧战报(无 tempSeconds)回退样本平均 50000/1000")
    } catch { expect(false, "avgPower Codable 抛错: \(error)") }
}


// MARK: - v8 虚拟热模型闭环回归（HIL）

// 一阶热系统：dT/dt = (P·R − (T−env)) / τ − k·percent
// 稳态: T = env + P·R − τ·k·percent
// 参数标定：40W 无风 → 65°C（env 25 + 40 温升）；100% 风量压 20°C 温升
struct VirtualMachine {
    var env: Double = 25
    let R: Double = 1.0      // °C/W
    let tau: Double = 40     // s
    let k: Double = 0.005    // °C/s/%
    var temp: Double = 45
    mutating func step(power: Double, percent: Double, dt: Double) {
        temp += ((power * R - (temp - env)) / tau - k * percent) * dt
    }
}


func testVirtualMachine() {
    group("虚拟热模型闭环")

    // 曲线模式：恒定负载闭环，应收敛无极限环
    do {
        var vm = VirtualMachine()
        var ctrl = FanCurveController()
        let bal = CurvePreset.balanced.points
        let power = 45.0
        var outputs: [Double] = []
        for _ in 0..<400 {   // 400 拍 × 3s = 20 分钟
            let t = ctrl.smooth(rawTemp: vm.temp)!
            let target = FanConfig.percent(temp: t, curve: bal)
            let out = ctrl.shape(target: target)
            outputs.append(out)
            vm.step(power: power, percent: out, dt: 3.0)
        }
        expect(vm.temp.isFinite && vm.temp > 30 && vm.temp < 92, "曲线闭环温度合理（\(Int(vm.temp))°）")
        let last = outputs.suffix(30)
        let spread = (last.max() ?? 0) - (last.min() ?? 0)
        expect(spread < 1.0, "稳态输出无振荡（波动 \(spread)%）")
        // 稳态平衡：稳态温度 T 应满足曲线查表 ≈ 输出（自洽）
        let steadyT = FanConfig.percent(temp: vm.temp, curve: bal)
        expect(abs(steadyT - (outputs.last ?? 0)) < 8, "稳态温度与输出自洽")
    }

    // AI 模式：目标 76，负载 30W→70W→30W，断言收敛 + 压得住 + 回落
    do {
        var vm = VirtualMachine()
        var ai = AIController()
        ai.tuning.targetTemp = 76
        var outs: [Double] = []
        var temps: [Double] = []
        // 阶段 1：轻载 30W 预热
        for _ in 0..<60 {
            let o = ai.step(temp: vm.temp, dt: 3.0) ?? 0
            outs.append(o); temps.append(vm.temp)
            vm.step(power: 30, percent: o, dt: 3)
        }
        // 阶段 2：重载 70W（AI 应把温度压回目标附近）
        for _ in 0..<200 {
            let o = ai.step(temp: vm.temp, dt: 3.0) ?? 0
            outs.append(o); temps.append(vm.temp)
            vm.step(power: 70, percent: o, dt: 3)
        }
        let t2 = temps.suffix(30)
        let steady2 = t2.reduce(0.0) { $0 + $1 } / Double(t2.count)
        expect(abs(steady2 - 76) < 6, "重载下收敛到目标附近（稳态 \(Int(steady2))°）")
        // 阶段 3：负载回落 30W，输出应明显下降
        let hiOut = outs.suffix(30).reduce(0.0) { $0 + $1 } / 30
        for _ in 0..<60 {
            let o = ai.step(temp: vm.temp, dt: 3.0) ?? 0
            outs.append(o)
            vm.step(power: 30, percent: o, dt: 3)
        }
        let loOut = outs.suffix(30).reduce(0.0) { $0 + $1 } / 30
        expect(loOut < hiOut - 20, "负载结束输出回落（\(Int(hiOut))%→\(Int(loOut))%）")
        // 交还只在温度充分回落后发生（30W 无风稳态 55° < 目标−8°），
        // 这是正确行为而非误判——断言其发生时温度已回落
        if ai.idleReleased {
            expect(vm.temp < 70, "交还发生在温度充分回落后（合理）")
        }
    }

    // AI 空闲交还：长时间低负载 → 交还系统；负载回升 → 夺回
    do {
        var vm = VirtualMachine(env: 25)
        var ai = AIController()
        ai.tuning.targetTemp = 76
        for _ in 0..<120 {   // 先稳定在低负载
            let o = ai.step(temp: vm.temp, dt: 3.0) ?? 0
            vm.step(power: 20, percent: o, dt: 3)
        }
        var released = false
        for _ in 0..<120 {   // 继续低负载，应交还
            let o = ai.step(temp: vm.temp, dt: 3.0)
            if o == nil { released = true; break }
            vm.step(power: 20, percent: o ?? 0, dt: 3)
        }
        expect(released, "低负载 AI 交还系统（风扇可停转）")
        // 负载突增 → 夺回并压温
        for _ in 0..<30 { vm.step(power: 80, percent: 0, dt: 3) }  // 被动升温（交还中）
        var reclaimed = false
        for _ in 0..<20 {
            let o = ai.step(temp: vm.temp, dt: 3.0)
            if o != nil { reclaimed = true; break }
            vm.step(power: 80, percent: 0, dt: 3)
        }
        expect(reclaimed, "负载回升 AI 夺回")
    }

    // 分项功耗前馈：CPU 突增 10W（整机不变）应触发分项快速通路提前抬输出
    do {
        var a1 = AIController()
        var a2 = AIController()
        // 两路都稳定在低负载
        for _ in 0..<10 {
            _ = a1.step(temp: 70, powerWatts: 30, cpuPower: 12, gpuPower: 10, dt: 3.0)
            _ = a2.step(temp: 70, powerWatts: 30, cpuPower: 12, gpuPower: 10, dt: 3.0)
        }
        let baseline = a1.step(temp: 70, powerWatts: 30, cpuPower: 12, gpuPower: 10, dt: 3.0)!
        // 对照组整机不变、分项不变；实验组 CPU 12→22W（+10W > 8W 阈值）
        let control = a2.step(temp: 70, powerWatts: 30, cpuPower: 12, gpuPower: 10, dt: 3.0)!
        let boosted = a1.step(temp: 70, powerWatts: 30, cpuPower: 22, gpuPower: 10, dt: 3.0)!
        expect(boosted > control, "CPU 分项突增触发前馈（\(Int(control))→\(Int(boosted))）")
        expect(boosted - baseline <= 15, "前馈受分项上限约束")
        // 分项噪声（+2W < 8W 阈值）不触发
        var n1 = AIController()
        for _ in 0..<10 { _ = n1.step(temp: 70, powerWatts: 30, cpuPower: 12, gpuPower: 10, dt: 3.0) }
        let nb = n1.step(temp: 70, powerWatts: 30, cpuPower: 12, gpuPower: 10, dt: 3.0)!
        let nn = n1.step(temp: 70, powerWatts: 30, cpuPower: 14, gpuPower: 10, dt: 3.0)!
        expect(nn <= nb + 1, "分项噪声级波动不触发前馈")
    }
}


// MARK: - AI 空闲期分项功耗基线刷新
// 空闲交还可持续数分钟~小时；若期间 lastCpuPower/lastGpuPower 冻结，
// 夺回后首拍 cpuRise 是"与空闲前的跨时长差值"，产生一次假前馈（≤12%，有界但语义错）。
// 修复：分项功耗追踪在 idle 分支之前执行，空闲期间基线持续刷新。

func testAIIdleComponentPowerBaseline() {
    group("AI 空闲期分项功耗基线")
    var c = AIController()   // 默认目标 76°C
    // 活动期基线 cpu=10W
    _ = c.step(temp: 70, powerWatts: 20, cpuPower: 10, gpuPower: 5, dt: 3)
    // 冷却到深凉（60 ≤ 76−12）→ 30s 快速通道交还
    for _ in 0..<10 { _ = c.step(temp: 60, powerWatts: 20, cpuPower: 10, gpuPower: 5, dt: 3) }
    expect(c.idleReleased, "深凉 30s 后交还")
    // 空闲期间负载已回升（powermetrics 读到 cpu=40W）——基线应随之刷新到 40
    _ = c.step(temp: 60, powerWatts: 20, cpuPower: 40, gpuPower: 5, dt: 3)
    // 温度过线夺回（连续 2 拍 ≥ 目标）
    _ = c.step(temp: 76, powerWatts: 20, cpuPower: 40, gpuPower: 5, dt: 3)
    let reclaimed = c.step(temp: 76, powerWatts: 20, cpuPower: 40, gpuPower: 5, dt: 3)
    expect(reclaimed != nil && !c.idleReleased, "过线连续 2 拍夺回")
    // 夺回后稳态拍：cpu 仅 +1W（远低于 8W 阈值），分项前馈不应触发。
    // 若基线冻结在空闲前的 10W：cpuRise=31W → 假前馈 +12%
    let out = c.step(temp: 76, powerWatts: 20, cpuPower: 41, gpuPower: 5, dt: 3)!
    expectClose(out, 30, 0.6, "空闲期基线已刷新，+1W 不触发分项前馈（无假 +12%）")
}


// MARK: - v9 曲线锚定探测式阶梯（极限环修复）
// 旧连续锚定（3%/拍）与 PD 目标构成"两个设定点抢一个执行器"：
// 曲线期望偏离物理需求超过带宽容忍（±2°×b≈±10pp 输出）时输出锯齿振荡（~100s 周期）。
// 探测式：每 25s 迈 ≤1.5% 小步，|error| ≥ comfortBand−anchorInnerMargin(=1.0°) 停步。
// 门控不能只看"贴带沿刹车"：热时间常数(τ≈40s)>>拍长(3s)，连续拉取的温度反馈来不及刹车。

func testAnchorProbing() {
    group("曲线锚定探测阶梯")

    // 纯控制器：带内安全区门控（上拉/下拉双向贴内沿停步）
    do {
        var c = AIController()   // target 76, band 2, margin 1 → 内沿 |error| < 1.0
        _ = c.step(temp: 75.0, learned: 40, curvePercent: 90, dt: 3.0)   // seed=40, error=-1.0 贴下内沿
        for _ in 0..<12 { _ = c.step(temp: 75.0, learned: 40, curvePercent: 90, dt: 3.0) }
        expect(c.output <= 40.5, "贴下内沿不向上迈步 (得 \(c.output))")
        var c2 = AIController()
        _ = c2.step(temp: 75.8, learned: 40, curvePercent: 90, dt: 3.0)  // error=-0.2 带中心
        for _ in 0..<12 { _ = c2.step(temp: 75.8, learned: 40, curvePercent: 90, dt: 3.0) }
        expect(c2.output > 41, "带中心正常向上迈步 (得 \(c2.output))")
        var c3 = AIController()
        _ = c3.step(temp: 77.0, learned: 90, curvePercent: 20, dt: 3.0)  // error=+1.0 贴上内沿
        for _ in 0..<12 { _ = c3.step(temp: 77.0, learned: 90, curvePercent: 20, dt: 3.0) }
        expect(c3.output >= 89.5, "贴上内沿不向下迈步 (得 \(c3.output))")
    }

    // 探测节奏：间隔（25s）内不重复迈步，间隔过后迈下一步
    do {
        var c = AIController()
        _ = c.step(temp: 75.5, learned: 40, curvePercent: 90, dt: 3.0)
        for _ in 0..<5 { _ = c.step(temp: 75.5, learned: 40, curvePercent: 90, dt: 3.0) }  // 拍6 首步（holdTicks=5 后）
        let mid = c.output
        for _ in 0..<6 { _ = c.step(temp: 75.5, learned: 40, curvePercent: 90, dt: 3.0) }  // +18s < 25s
        expect(c.output == mid, "探测间隔内不重复迈步 (\(mid) 保持)")
        for _ in 0..<4 { _ = c.step(temp: 75.5, learned: 40, curvePercent: 90, dt: 3.0) }  // 累计 30s ≥ 25s
        expect(c.output > mid, "间隔过后迈下一步 (\(mid) → \(c.output))")
    }

    // HIL 上拉：曲线期望(68%)远超物理需求(45%)——旧连续锚定 45↔68 拉锯；
    // 探测阶梯停在带内沿对应值（≈50%），输出/温度双稳定
    do {
        var vm = VirtualMachine()
        var ai = AIController()
        ai.tuning.targetTemp = 76
        let bal = CurvePreset.balanced.points
        var outs: [Double] = []
        for _ in 0..<400 {
            let cp = FanConfig.percent(temp: vm.temp, curve: bal)
            let o = ai.step(temp: vm.temp, curvePercent: cp, dt: 3.0) ?? 0
            outs.append(o)
            vm.step(power: 60, percent: o, dt: 3)
        }
        let last = outs.suffix(60)
        let spread = (last.max() ?? 0) - (last.min() ?? 0)
        expect(spread < 5, "上拉方向无极限环（输出波动 \(String(format: "%.1f", spread))% < 5%）")
        let final = last.reduce(0, +) / Double(last.count)
        expect(final > 45 && final < 62,
               "停在带内沿对应值，不冲向曲线 68%（物理 45% < 稳态 \(Int(final))% < 62）")
        expect(vm.temp > 73.5 && vm.temp < 78.5,
               "温度留在舒适带内（\(String(format: "%.1f", vm.temp))°）")
    }

    // HIL 下拉：曲线期望(36%)低于物理需求(45%)——停在带上内沿（更安静），同样稳定
    do {
        var vm = VirtualMachine()
        var ai = AIController()
        ai.tuning.targetTemp = 76
        let quiet = CurvePreset.quiet.points
        var outs: [Double] = []
        for _ in 0..<400 {
            let cp = FanConfig.percent(temp: vm.temp, curve: quiet)
            let o = ai.step(temp: vm.temp, curvePercent: cp, dt: 3.0) ?? 0
            outs.append(o)
            vm.step(power: 60, percent: o, dt: 3)
        }
        let last = outs.suffix(60)
        let spread = (last.max() ?? 0) - (last.min() ?? 0)
        expect(spread < 5, "下拉方向无极限环（输出波动 \(String(format: "%.1f", spread))% < 5%）")
        let final = last.reduce(0, +) / Double(last.count)
        expect(final > 34 && final < 45,
               "下拉停在带上内沿（曲线 36% < 稳态 \(Int(final))% < 物理 45%，更安静）")
        expect(vm.temp > 74 && vm.temp < 78.5,
               "温度留在舒适带内（\(String(format: "%.1f", vm.temp))°）")
    }

    // HIL 完整收敛分支：曲线期望 ≈ 物理需求（76° 处曲线=45%=物理值）时，
    // 门控永不触发 → 锚定应完整收敛到曲线本身（而非停在带内沿）。
    // 这是"调曲线直接改变 AI 稳态"承诺的核心验证
    do {
        var vm = VirtualMachine()
        var ai = AIController()
        ai.tuning.targetTemp = 76
        // 60W 稳态：T = 85 − 0.2·pct → T=76 需 45%。构造 76° 处 = 45% 的曲线
        let matchCurve = [CurvePoint(temp: 52, percent: 0),
                          CurvePoint(temp: 76, percent: 45),
                          CurvePoint(temp: 85, percent: 100)]
        var outs: [Double] = []
        for _ in 0..<400 {
            let cp = FanConfig.percent(temp: vm.temp, curve: matchCurve)
            let o = ai.step(temp: vm.temp, curvePercent: cp, dt: 3.0) ?? 0
            outs.append(o)
            vm.step(power: 60, percent: o, dt: 3)
        }
        let last = outs.suffix(60)
        let spread = (last.max() ?? 0) - (last.min() ?? 0)
        expect(spread < 3, "匹配曲线无振荡（输出波动 \(String(format: "%.1f", spread))% < 3%）")
        let final = last.reduce(0, +) / Double(last.count)
        expect(final > 42 && final < 48,
               "完整收敛到曲线 45%（得 \(Int(final))%，非带沿截断值）")
        expect(vm.temp > 74.5 && vm.temp < 77.5,
               "温度稳在目标附近（\(String(format: "%.1f", vm.temp))°）")
    }

    // HIL 负载切换扰动：60W 稳态（锚定收敛）→ 70W（物理需求 95%）→ 回 60W。
    // 验证锚定与 P 的交接：扰动期 P 主导恢复温度，随后锚定在新平衡点重新收敛，全程无极限环
    do {
        var vm = VirtualMachine()
        var ai = AIController()
        ai.tuning.targetTemp = 76
        let bal = CurvePreset.balanced.points
        func run(_ power: Double, _ ticks: Int, record outs: inout [Double]) {
            for _ in 0..<ticks {
                let cp = FanConfig.percent(temp: vm.temp, curve: bal)
                let o = ai.step(temp: vm.temp, curvePercent: cp, dt: 3.0) ?? 0
                outs.append(o)
                vm.step(power: power, percent: o, dt: 3)
            }
        }
        var outs: [Double] = []
        run(60, 400, record: &outs)   // 阶段1：60W 稳态（物理 45%，锚定向曲线 68% 上探后被带沿停住）
        var seg = outs.suffix(60)
        expect((seg.max() ?? 0) - (seg.min() ?? 0) < 5, "阶段1稳态无振荡")
        let out1 = seg.reduce(0, +) / 60
        run(70, 400, record: &outs)   // 阶段2：70W（物理 95%）——P 应抬输出压温
        seg = outs.suffix(60)
        expect((seg.max() ?? 0) - (seg.min() ?? 0) < 5, "阶段2稳态无振荡")
        let out2 = seg.reduce(0, +) / 60
        expect(out2 > out1 + 30, "重载输出大幅抬升（\(Int(out1))%→\(Int(out2))%）")
        expect(vm.temp > 73.5 && vm.temp < 78.5, "阶段2温度回到带内（\(String(format: "%.1f", vm.temp))°）")
        run(60, 400, record: &outs)   // 阶段3：回 60W——输出回落并重新收敛
        seg = outs.suffix(60)
        expect((seg.max() ?? 0) - (seg.min() ?? 0) < 5, "阶段3稳态无振荡（锚定扰动后重新收敛）")
        let out3 = seg.reduce(0, +) / 60
        expect(abs(out3 - out1) < 6, "阶段3回到阶段1平衡点（\(Int(out1))%→\(Int(out3))%，无滞回漂移）")
        expect(vm.temp > 74 && vm.temp < 78.5, "阶段3温度在带内（\(String(format: "%.1f", vm.temp))°）")
    }
}


// MARK: - v2.8 传感器卡死检测（物理一致性门）


func testStuckDetector() {
    group("传感器卡死检测")
    let t0 = Date()
    // 功耗波动（15W swing）+ 读数 300s 逐位恒定 → 判卡死
    var d = StuckSensorDetector()
    var confirmed = false
    for k in 0..<12 {
        let c = d.record(rawTemp: 60, powerWatts: k % 2 == 0 ? 20.0 : 35.0,
                         now: t0.addingTimeInterval(Double(k) * 30))
        if c { confirmed = true; expectEqual(k, 10, "第 11 拍（300s 整）确认") }
    }
    expect(confirmed, "恒定读数+功耗波动判卡死")
    expect(d.faulted, "faulted 锁存")
    // 锁存期间读数移动 → 解除（恢复沿）
    _ = d.record(rawTemp: 65, powerWatts: 30, now: t0.addingTimeInterval(400))
    expect(!d.faulted, "读数变化解除卡死")
    // 功耗平稳（swing < 10W）不判
    var d2 = StuckSensorDetector()
    for k in 0..<12 { _ = d2.record(rawTemp: 60, powerWatts: 30, now: t0.addingTimeInterval(Double(k) * 30)) }
    expect(!d2.faulted, "功耗无波动不判卡死")
    // 读数真实抖动（LSB 噪声）不断重置窗口，不判
    var d3 = StuckSensorDetector()
    let temps: [Double] = [60, 60.2, 59.8, 60.1, 60, 60.3, 59.9, 60.2, 60, 60.1, 59.8, 60.2]
    for (k, t) in temps.enumerated() {
        _ = d3.record(rawTemp: t, powerWatts: k % 2 == 0 ? 20.0 : 35.0,
                      now: t0.addingTimeInterval(Double(k) * 30))
    }
    expect(!d3.faulted, "读数抖动（真实噪声）不判卡死")
    // 无功耗键（nil）检测惰性——无法做物理互检
    var d4 = StuckSensorDetector()
    for k in 0..<12 { _ = d4.record(rawTemp: 60, powerWatts: nil, now: t0.addingTimeInterval(Double(k) * 30)) }
    expect(!d4.faulted, "无功耗传感器惰性")
    // 窗口不足 5 分钟不判
    var d5 = StuckSensorDetector()
    for k in 0..<5 { _ = d5.record(rawTemp: 60, powerWatts: k % 2 == 0 ? 20.0 : 35.0,
                                   now: t0.addingTimeInterval(Double(k) * 30)) }
    expect(!d5.faulted, "120s 窗口不足")
}


// MARK: - v2.9.2 AI 启停循环抑制（风扇寿命：深凉释放绕过防拍打窗的极限环）


func testAICyclingGuard() {
    group("AI 启停循环抑制")
    // 走到深凉释放（≤ target−12 = 60° 持续 30s）
    var c = AIController()
    _ = c.step(temp: 70, powerWatts: 20, dt: 3.0)
    var released = false
    for _ in 0..<12 {
        if c.step(temp: 60, powerWatts: 20, dt: 3) == nil { released = true; break }
    }
    expect(released, "深凉 30s 交还")
    // 浸泡：温度从 60 爬到 77（≥ 默认目标 76，连续 2 拍）→ 夺回
    _ = c.step(temp: 77, powerWatts: 20, dt: 3)
    let reclaimed = c.step(temp: 77, powerWatts: 20, dt: 3)
    expect(reclaimed != nil, "浸泡破目标夺回")
    expect(c.cyclingGuardArmed, "释放后 6s 即被夺回 → 武装循环抑制")
    // 抑制期：满足深凉释放条件也不交还（保持最低输出 = 风扇最低转速稳定运行）
    var out: Double? = nil
    for _ in 0..<12 { out = c.step(temp: 60, powerWatts: 20, dt: 3) }
    expect(out != nil, "抑制期不交还（保持最低转速稳定运行）")
    expect(!c.idleReleased, "抑制期 idleReleased 不置位")
    // 抑制期结束（1800s）→ 恢复释放能力
    for _ in 0..<620 { out = c.step(temp: 60, powerWatts: 20, dt: 3) }
    expect(out == nil && c.idleReleased, "抑制期结束恢复交还（30 分钟一次试探）")
    // reset 清空抑制状态
    c.reset()
    expect(!c.cyclingGuardArmed, "reset 清空抑制状态")
    // 静音激活的强制夺回不武装抑制（模式切换 ≠ 热振荡，否则会议后 30 分钟拒绝交还）
    var q = AIController()
    for _ in 0..<10 { _ = q.step(temp: 60, dt: 3.0) }
    expect(q.idleReleased, "先交还")
    let qr = q.step(temp: 60, allowRelease: false, dt: 3.0)   // 会议激活强制夺回（释放后 3s）
    expect(qr != nil && !q.idleReleased, "静音激活强制夺回")
    expect(!q.cyclingGuardArmed, "静音激活夺回不武装抑制")
    // v3.1 指数退避：连续快速循环 → 抑制期 1800→3600→7200→14400（封顶 4h）
    var b = AIController()
    var lastGuard = 0.0
    for round in 0..<5 {
        var rel = false
        for _ in 0..<12 { if b.step(temp: 60, powerWatts: 20, dt: 3) == nil { rel = true; break } }
        expect(rel, "round \(round) 深凉释放")
        _ = b.step(temp: 77, powerWatts: 20, dt: 3)
        let rc = b.step(temp: 77, powerWatts: 20, dt: 3)
        expect(rc != nil, "round \(round) 快速循环夺回")
        lastGuard = b.currentGuardSeconds
        let expected = min(1800.0 * pow(2, Double(round)), 14400.0)
        expectEqual(lastGuard, expected, "round \(round) 抑制期指数退避（得 \(lastGuard)）")
        let beats = Int(lastGuard / 3) + 2
        for _ in 0..<beats { _ = b.step(temp: 60, powerWatts: 20, dt: 3) }
        expect(!b.cyclingGuardArmed, "round \(round) 抑制期满")
    }
    expectEqual(lastGuard, 14400, "封顶 4 小时")
    // 可持续释放（夺回间隔 >240s）→ 退避归位
    var rel2 = false
    for _ in 0..<12 { if b.step(temp: 60, powerWatts: 20, dt: 3) == nil { rel2 = true; break } }
    expect(rel2, "退避归位前再次释放")
    for _ in 0..<120 { _ = b.step(temp: 74, powerWatts: 20, dt: 3) }   // 浸泡 360s（>240s）
    let rc2 = b.step(temp: 77, powerWatts: 20, dt: 3)
    expect(rc2 != nil, "浸泡夺回")
    var rel3 = false
    for _ in 0..<12 { if b.step(temp: 60, powerWatts: 20, dt: 3) == nil { rel3 = true; break } }
    expect(rel3, "归位后再次深凉释放")
    _ = b.step(temp: 77, powerWatts: 20, dt: 3)
    let rc3 = b.step(temp: 77, powerWatts: 20, dt: 3)
    expect(rc3 != nil, "归位后夺回")
    expectEqual(b.currentGuardSeconds, 1800, "可持续释放后退避归位（得 \(b.currentGuardSeconds)）")
}


func testHILHysteresis() {
    group("HIL 迟滞带对比")
    let base = runHIL(hysteresis: 0)
    let hyst = runHIL(hysteresis: 4)
    print("  [HIL 迟滞] 调速(≥3%): \(base.changes) → \(hyst.changes) | 温度RMS: \(String(format: "%.2f", base.rms)) → \(String(format: "%.2f", hyst.rms)) | 峰值: \(String(format: "%.1f", base.maxO)) → \(String(format: "%.1f", hyst.maxO))")
    expect(!base.nan && !hyst.nan, "两版均无数值发散")
    expect(hyst.changes < base.changes, "迟滞减少调速（\(base.changes) → \(hyst.changes)）")
    expect(abs(hyst.rms - base.rms) <= 1.5, "温度精度损失 ≤1.5°（ΔRMS \(String(format: "%.2f", abs(hyst.rms - base.rms)))）")
    expect(hyst.maxO <= base.maxO + 2, "过冲不恶化（\(String(format: "%.1f", hyst.maxO)) vs \(String(format: "%.1f", base.maxO))）")
}


// MARK: - v3.3 体感补偿 + 功耗直方图 + 优化器功耗门控


func testPalmComp() {
    group("体感补偿")
    expectEqual(FanPipeline.palmComp(palmRest: 39, enabled: true), 0, "39° 舒适区内不收紧")
    expectEqual(FanPipeline.palmComp(palmRest: 40, enabled: true), 0, "40° 阈值起点为 0")
    expectEqual(FanPipeline.palmComp(palmRest: 42, enabled: true), 2, "42° 收紧 2°")
    expectEqual(FanPipeline.palmComp(palmRest: 45, enabled: true), 4, "45° 封顶 +4")
    expectEqual(FanPipeline.palmComp(palmRest: 50, enabled: true), 4, "50° 封顶 +4")
    expectEqual(FanPipeline.palmComp(palmRest: nil, enabled: true), 0, "无传感器为 0")
    expectEqual(FanPipeline.palmComp(palmRest: 44, enabled: false), 0, "未启用为 0")
    expectEqual(FanPipeline.palmComp(palmRest: .nan, enabled: true), 0, "NaN 为 0")
    expectEqual(FanPipeline.palmComp(palmRest: 60, enabled: true), 0, ">55° 读数异常为 0")

    // decide 集成：仅基础曲线分支收紧，电池档不受影响
    let bal = CurvePreset.balanced.points
    let cfg = FanConfig(mode: .curve, curve: bal, preset: .balanced, envCompensation: false)
    let with = FanPipeline.decide(config: cfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                  onBattery: false, aiPercent: nil, now: Date(), palmComp: 4)
    let without = FanPipeline.decide(config: cfg, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                     onBattery: false, aiPercent: nil, now: Date())
    expectClose(with.targetPercent!, FanConfig.percent(temp: 74, curve: bal), 1e-9, "体感补偿查表右移 4°（74° 查表）")
    expect(with.targetPercent! > without.targetPercent!, "体感补偿加强散热")
    let batt = FanConfig(mode: .curve, curve: bal, preset: .balanced,
                         batteryPreset: .quiet, envCompensation: false)
    let withB = FanPipeline.decide(config: batt, smoothedTemp: 70, rawTemp: 70, nandTemp: 40,
                                   onBattery: true, aiPercent: nil, now: Date(), palmComp: 4)
    expectClose(withB.targetPercent!, FanConfig.percent(temp: 70, curve: CurvePreset.quiet.points), 1e-9,
                "电池安静档不被体感补偿覆盖")
}


// MARK: - v2.9 学习卫生（环境修正清洗 + 功耗分档滞回）


func testLearningHygiene() {
    group("学习卫生(v2.9)")
    // 环境修正清洗：65°/55% 在 25° 室温假设下判污染，35° 环境下合法保留
    var tl = ThermalLearn()
    for _ in 0..<5 { tl.record(temp: 65, percent: 55) }
    expectEqual(tl.sanitizeCorruptedBuckets(), 1, "默认阈值清洗 65°/55%（隐含 25° 室温）")
    for _ in 0..<5 { tl.record(temp: 65, percent: 55) }
    expectEqual(tl.sanitizeCorruptedBuckets(envTemp: 35), 0, "环境 35°（slack+20）下 65°/55% 合法保留")
    for _ in 0..<5 { tl.record(temp: 60, percent: 100) }
    expectEqual(tl.sanitizeCorruptedBuckets(envTemp: 35), 1, "60°/100% 真污染仍清洗")

    // 功耗分档滞回（纯函数）
    expectEqual(ThermalLearn.powerBand(for: 34.9, previous: "heavy"), "heavy", "35W 边界 0.1W 保持 heavy")
    expectEqual(ThermalLearn.powerBand(for: 35.1, previous: "medium"), "medium", "35W 边界 0.1W 保持 medium")
    expectEqual(ThermalLearn.powerBand(for: 38, previous: "medium"), "heavy", "越界 3W 才切 heavy")
    expectEqual(ThermalLearn.powerBand(for: 32, previous: "heavy"), "medium", "越界 3W 才切 medium")
    expectEqual(ThermalLearn.powerBand(for: 14.9, previous: "medium"), "medium", "15W 边界滞回")
    expectEqual(ThermalLearn.powerBand(for: 12.9, previous: "medium"), "light", "越界 2.1W 切 light")
    expectEqual(ThermalLearn.powerBand(for: 40, previous: "light"), "heavy", "跨档跳变无滞回")
    expectEqual(ThermalLearn.powerBand(for: 34.9, previous: nil), "medium", "冷启动无滞回")

    // 实例级：record/lookup 共用滞回状态
    var tl2 = ThermalLearn()
    for _ in 0..<4 { tl2.record(temp: 60, percent: 80, onBattery: false, powerWatts: 45) }   // heavy
    for _ in 0..<4 { tl2.record(temp: 60, percent: 30, onBattery: false, powerWatts: 25) }   // 越界 10W → medium
    expectEqual(tl2.percent(for: 60, onBattery: false, powerWatts: 35.1)!, 30,
                "35.1W 边界滞回保持 medium 桶")
    expectEqual(tl2.percent(for: 60, onBattery: false, powerWatts: 38)!, 80, "38W 越界切 heavy 桶")
}


// MARK: - R70：AI 模式 vs 纯曲线，同一热机、同一负载、三种拍距的对照（测量，不是调参）

/// 一条臂跑完的指标。`mode` 是唯一变量：控制器不同，热机/负载/限速管线完全相同。
private func runModeArm(ai: Bool, dt: Double, seconds: Double, target: Double)
    -> (maxO: Double, highSec: Double, rms: Double, changes: Int, avgOut: Double, nan: Bool) {
    var vm = VirtualMachine()
    var aiCtl = AIController()
    aiCtl.tuning.targetTemp = target
    var ctrl = FanCurveController()
    let curve = CurvePreset.balanced.points
    var prevOut = 0.0, changes = 0, sumSq = 0.0, n = 0.0, maxO = 0.0, highSec = 0.0, sumOut = 0.0
    var nan = false
    let steps = Int(seconds / dt)
    for i in 0..<steps {
        let t = Double(i) * dt
        let power = 45 + 15 * sin(t / 300.0 * .pi) + ((Int(t / 600) % 2 == 0) ? 8 : 0)
        let want: Double = ai
            ? (aiCtl.step(temp: vm.temp, powerWatts: power, dt: dt) ?? 0)
            : FanConfig.percent(temp: vm.temp, curve: curve)
        let applied = ctrl.slew(target: want, force: false, hysteresis: 4)
        if abs(applied - prevOut) >= 3 { changes += 1 }
        prevOut = applied
        vm.step(power: power, percent: applied, dt: dt)
        guard vm.temp.isFinite, applied.isFinite, applied >= 0, applied <= 100 else { nan = true; break }
        sumSq += vm.temp * vm.temp; n += 1; sumOut += applied
        maxO = max(maxO, vm.temp - target)
        if vm.temp > target + 2 { highSec += dt }
    }
    return (maxO, highSec, n > 0 ? (sumSq / n).squareRoot() : 0, changes, n > 0 ? sumOut / n : 0, nan)
}

/// 对照 + 回归天花板。**天花板不是最优声明**：它只钉"比今天更差就红"。
func testAIModeVersusCurve() {
    group("AI 对照曲线(R70)")
    let target = 76.0
    for dt in [1.0, 3.0, 10.0] {
        let a = runModeArm(ai: true, dt: dt, seconds: 3600, target: target)
        let c = runModeArm(ai: false, dt: dt, seconds: 3600, target: target)
        print(String(format: "HIL dt=%.0fs  AI: 过冲+%.2f° 超温%.0fs RMS %.2f 调速%d 均输出%.1f%%  |  曲线: 过冲+%.2f° 超温%.0fs RMS %.2f 调速%d 均输出%.1f%%",
                     dt, a.maxO, a.highSec, a.rms, a.changes, a.avgOut, c.maxO, c.highSec, c.rms, c.changes, c.avgOut))
        expect(!a.nan && !c.nan, "dt=\(dt) 两臂都不出 NaN/越界")
    }
    let a3 = runModeArm(ai: true, dt: 3, seconds: 3600, target: target)
    let c3 = runModeArm(ai: false, dt: 3, seconds: 3600, target: target)
    // 第一版我把这两条写成"AI 不得劣于曲线（过冲/超温秒）"，实测**直接红**：
    // AI 过冲 +3.39° vs 曲线 +2.43°、超温 177s vs 150s。但那不是"AI 更差"——两臂目标不同
    // （曲线 balanced 均输出 36.2% 把 RMS 压在 67.0，AI 目标 76° 均输出 19.8%、RMS 70.2）。
    // 所以正确的门是"省风扇是真的、温度代价有上限"，而不是"AI 处处更优"：
    expect(a3.avgOut <= c3.avgOut, "AI 臂均输出必须低于同机同负载的纯曲线（省风扇是它的设计目标，实得 19.8% vs 36.2%）")
    expect(a3.rms - c3.rms <= 4.0,
           "AI 的温度代价天花板：RMS 不得比曲线高过 4°（实得 +\(String(format: "%.2f", a3.rms - c3.rms))°）——**天花板，不是最优声明**")
    // dt 敏感性天花板：AI 的 D 项上游滤波器是每拍常数（`FanControlLaw.smooth` 无 dt），
    // 拍距 1s→10s 时过冲会明显变化。这条钉的是"别变得更敏感"，不是"已经够稳"。
    let a1 = runModeArm(ai: true, dt: 1, seconds: 3600, target: target)
    let a10 = runModeArm(ai: true, dt: 10, seconds: 3600, target: target)
    expect(abs(a1.maxO - a10.maxO) <= 3.0,
           "AI 过冲对拍距的敏感度天花板 3°（1s 臂 +\(a1.maxO)° vs 10s 臂 +\(a10.maxO)°）")
}

// MARK: - R71：把两条"读代码才知道"的缺陷变成量具里的数字（只测量，不动控制行为）

/// ① 输入滤波器的等效时间常数随拍距线性放大。
/// `FanControlLaw.smooth` 的 α 是**每拍常数**（无 dt 参数）⇒ 同一物理信号在 1s 拍距下
/// τ≈2.6s，在 20s 拍距下 τ≈51s——D 项吃的正是这个差分。宪法禁止在账本 <7 天时改 α，
/// 但"缺陷可见"不需要改代码：这里把 τ 与放大倍数量出来，并把"τ 必须与 dt 成正比"钉成门
/// （将来谁把 α 改成秒基，这条会红，那时连它一起改）。
func testFilterTauScalesWithDt() {
    group("滤波滞后可观测性(R71)")
    let target = 80.0
    func ticksToReach(alpha: Double, dt: Double, fraction: Double) -> (ticks: Int, tauSeconds: Double) {
        var c = FanCurveController(tuning: { var t = FanControlTuning(); t.alphaUp = alpha; t.alphaDown = alpha
                                             t.alphaSettle = alpha; return t }())
        _ = c.smooth(rawTemp: target)                       // 从稳态开始
        var n = 0
        while n < 10_000 {
            n += 1
            guard let v = c.smooth(rawTemp: target + 10) else { continue }
            if v - target >= 10 * fraction { break }
        }
        // 一阶 EMA 的 63.2% 时间常数：τ = −dt / ln(1−α)
        let tau = -dt / log(1 - alpha)
        return (n, tau)
    }
    for (alpha, dt) in [(0.35, 1.0), (0.35, 3.0), (0.35, 20.0), (0.2, 3.0)] {
        let r = ticksToReach(alpha: alpha, dt: dt, fraction: 0.632)
        print(String(format: "TAU alpha=%.2f dt=%.0fs → 63.2%% 用了 %d 拍，物理时间常数 τ=%.1fs",
                     alpha, dt, r.ticks, r.tauSeconds))
    }
    let t1 = ticksToReach(alpha: 0.35, dt: 1.0, fraction: 0.632)
    let t20 = ticksToReach(alpha: 0.35, dt: 20.0, fraction: 0.632)
    expectEqual(t1.ticks, 3, "α=0.35 时 63.2% 需 3 拍（每拍 α 与 dt 无关 ⇒ 拍数不变）")
    expectEqual(t20.ticks, 3, "同样 α、dt=20s 仍是 3 拍 ⇒ 物理时间常数被拍距放大了 20 倍（缺陷本体）")
    expect(abs(t1.tauSeconds - 2.32) < 0.02, "τ(1s)=2.32s：快拍下滤波几乎无滞后（−ln(0.65)=0.4308）")
    expect(abs(t20.tauSeconds - 46.4) < 0.2, "τ(20s)=46.4s：慢拍下滤波比虚拟热机 τ=40s 还慢（斜率被抹平）")
    expect(abs(t20.tauSeconds / t1.tauSeconds - 20.0) < 0.01,
           "τ 必须与 dt 成正比（倍数 20）——这正是「滤波器没按 dt 归一」的可复核签名")
}

/// ② 曲线锚定的步长被限速迟滞吞掉：设计意图 1.5pp/25s 的小步，实际变成 ≥4pp/75s 的台阶。
/// 量法：每 anchorProbeSeconds 向目标推 1.5pp，过 `slew(hysteresis:4)`，看实际写入的台阶。
func testAnchorStepSwallowedBySlew() {
    group("锚定台阶可观测性(R71)")
    var c = FanCurveController()
    var target = 40.0
    var applied: Double? = nil
    var changes: [(Double, Double)] = []      // (时间秒, 台阶 pp)
    var t = 0.0
    for _ in 0..<20 {                          // 20 个探测周期 × 25s = 500s
        t += 25
        target = min(target + 1.5, 100)         // anchorStepPercent 步进
        let out = c.slew(target: target, force: false, hysteresis: 4)
        if let prev = applied, abs(out - prev) >= 0.001 {
            changes.append((t, out - prev))
        }
        applied = out
    }
    print("ANCHOR 台阶：\(changes.map { String(format: "t=%.0fs %+.1fpp", $0.0, $0.1) }.joined(separator: " | "))")
    expectEqual(changes.count, 6, "500s 内实际只发生 6 次台阶（而不是 20 次小步；首次在第 4 个探测点）")
    expectEqual(String(format: "%.1f", changes[0].0), "100.0", "第一次台阶在 t=100s：1.5pp 的意图步要攒够迟滞 4pp 才落得下去")
    expectEqual(String(format: "%.0f", changes[1].0 - changes[0].0), "75", "此后每 75s（3 个探测周期）才有一次台阶")
    for (_, step) in changes {
        expect(abs(step) >= 4.0 - 0.001, "每次台阶 ≥4pp（= 迟滞宽度；1.5pp 的意图步被吞）")
        expect(abs(step) <= 4.5 + 0.001, "每次台阶 ≤4.5pp（= 迟滞 + 1.5pp，不是连续滑移）")
    }
    expectEqual(String(format: "%.1f", changes[0].1), "4.5",
                "每次台阶 +4.5pp（= 迟滞 4 + 落后 1.5 的意图步），不是设计意图的 1.5pp 小步")
}

// MARK: - R72：把热机换成一阶以上——R70 的"拍距越慢 AI 越差"是否只在单时间常数模型下成立？

/// 双时间常数热机：die（快，τ≈8s）+ 散热片/机壳（慢，τ≈120s）耦合。
/// 现有 `VirtualMachine` 是一阶（τ=40s、单状态），而 R70 的因果结论建立在它上面 ⇒ 必须换模型复核。
/// 参数只求"物理上说得通"（45W 无风时 die 落在 ~70°、环境 25°），不是真机标定。
private struct ThermalVM2 {
    var die: Double = 45
    var sink: Double = 40
    let env: Double = 25
    let Rd: Double = 0.8      // °C/W：die 对功耗的内阻
    let Rdis: Double = 0.25   // °C/W：die→散热片
    let Renv: Double = 0.6    // °C/W：散热片→环境
    let Cd: Double = 8.0      // s·°C/W：die 热容（快）
    let Cs: Double = 120.0    // s·°C/W：散热片热容（慢）
    let k: Double = 0.004     // °C/s/%：风扇对 die 的直接抽热

    // 指数松弛（对步内常输入是精确解、无条件稳定）。显式欧拉在这里会炸：
    // dt·(1/Rdis + k·%)/Cd 在 dt=20s 时 ≈11 ⇒ |增益|>1 直接发散，与控制器无关。
    mutating func step(power: Double, percent: Double, dt: Double) {
        let bD = (1 / Rdis + k * percent) / Cd
        let aD = (power * Rd + sink / Rdis + k * percent * env) / Cd
        die = aD / bD + (die - aD / bD) * exp(-bD * dt)
        let bS = (1 / Rdis + 1 / Renv) / Cs
        let aS = (die / Rdis + env / Renv) / Cs
        sink = aS / bS + (sink - aS / bS) * exp(-bS * dt)
    }
}

/// 与 `runModeArm` 同构，只是换热机；同样只让控制器这一个变量变。
private func runModeArm2(ai: Bool, dt: Double, seconds: Double, target: Double)
    -> (maxO: Double, highSec: Double, rmsDie: Double, rmsSink: Double, changes: Int, avgOut: Double, nan: Bool) {
    var vm = ThermalVM2()
    var aiCtl = AIController()
    aiCtl.tuning.targetTemp = target
    var ctrl = FanCurveController()
    let curve = CurvePreset.balanced.points
    var prevOut = 0.0, changes = 0, sumDie = 0.0, sumSink = 0.0, n = 0.0, maxO = 0.0, highSec = 0.0, sumOut = 0.0
    var nan = false
    let steps = Int(seconds / dt)
    for i in 0..<steps {
        let t = Double(i) * dt
        // 负载加倍：一阶版用 45W 让 die≈76；双时间常数版 45W 只到 57.5°（目标根本没被逼近，
        // 两臂都没被压到工作区 ⇒ 比较退化）。按同一物理量标定到目标附近再比。
        let power = 95 + 28 * sin(t / 300.0 * .pi) + ((Int(t / 600) % 2 == 0) ? 16 : 0)
        let want: Double = ai
            ? (aiCtl.step(temp: vm.die, powerWatts: power, dt: dt) ?? 0)
            : FanConfig.percent(temp: vm.die, curve: curve)
        let applied = ctrl.slew(target: want, force: false, hysteresis: 4)
        if abs(applied - prevOut) >= 3 { changes += 1 }
        prevOut = applied
        vm.step(power: power, percent: applied, dt: dt)
        guard vm.die.isFinite, vm.sink.isFinite, applied.isFinite, applied >= 0, applied <= 100
        else { nan = true; break }
        sumDie += vm.die * vm.die; sumSink += vm.sink * vm.sink; n += 1; sumOut += applied
        maxO = max(maxO, vm.die - target)
        if vm.die > target + 2 { highSec += dt }
    }
    return (maxO, highSec, n > 0 ? (sumDie / n).squareRoot() : 0, n > 0 ? (sumSink / n).squareRoot() : 0,
            changes, n > 0 ? sumOut / n : 0, nan)
}

func testAIModeVersusCurveTwoTau() {
    group("AI 双时间常数对照(R72)")
    let target = 76.0
    var results: [String: (maxO: Double, highSec: Double)] = [:]
    for dt in [1.0, 3.0, 10.0, 20.0] {
        let a = runModeArm2(ai: true, dt: dt, seconds: 3600, target: target)
        let c = runModeArm2(ai: false, dt: dt, seconds: 3600, target: target)
        results["a\(Int(dt))"] = (a.maxO, a.highSec)
        results["c\(Int(dt))"] = (c.maxO, c.highSec)
        print(String(format: "TAU2 dt=%4.0fs  AI: 过冲+%.2f° 超温%.0fs RMS die %.2f sink %.2f 调速%d 均输出%.1f%%  |  曲线: 过冲+%.2f° 超温%.0fs RMS die %.2f sink %.2f 调速%d 均输出%.1f%%",
                     dt, a.maxO, a.highSec, a.rmsDie, a.rmsSink, a.changes, a.avgOut,
                     c.maxO, c.highSec, c.rmsDie, c.rmsSink, c.changes, c.avgOut))
        expect(!a.nan && !c.nan, "双时间常数热机 dt=\(dt) 两臂都不出 NaN/越界")
    }
    let d1 = results["a1"]!, d20 = results["a20"]!
    let c1 = results["c1"]!, c20 = results["c20"]!
    let dGap1 = d1.maxO - c1.maxO, dGap20 = d20.maxO - c20.maxO
    print(String(format: "TAU2 拍距敏感性：AI 过冲 %.2f°→%.2f°（%+.2f°），曲线 %.2f°→%.2f°（%+.2f°）；AI 相对曲线的差 %+.2f°→%+.2f°",
                 d1.maxO, d20.maxO, d20.maxO - d1.maxO, c1.maxO, c20.maxO, c20.maxO - c1.maxO, dGap1, dGap20))
    // R70 在一阶模型（单 τ=40s）下看到"AI 对拍距的过冲恶化远大于曲线"。**这个结论没有迁移过来**：
    // 双时间常数下两臂的拍距敏感度几乎相同（见上行的打印）。所以门只钉"两臂差距不得随拍距放大"，
    // 并如实注明：一阶模型的敏感性数字**不能**当作真机预期引用。
    expect(abs(dGap20 - dGap1) <= 1.5,
           "AI 与曲线的过冲差距不得随拍距明显放大（1s 差 \(String(format: "%.2f", dGap1))°，20s 差 \(String(format: "%.2f", dGap20))°）")
    for dt in [1, 3, 10, 20] {
        let a = results["a\(dt)"]!, c = results["c\(dt)"]!
        expect(abs(a.maxO - c.maxO) <= 5.0, "dt=\(dt)s 两臂过冲差 ≤5°（同热机同负载）")
    }
}

// MARK: - R73：红线的"误触发面"与"恢复轨迹"——此前的测试全是"该触发时触发"

/// 已知取舍（`FanPipeline.swift:15-17`）：兜底刻意用 **raw** 而非平滑值，"毛刺不漏报"。
/// 所以单拍尖峰 ≥92 会触发一次全速——这不是 bug。真正必须成立的是它的**边界**：
///   不得锁存、不得在 88–92 之间抖动、恢复单调、坏值不会把输出卡死。
/// 误触发比漏触发更伤信任：陌生人机器上误全速 = 噪音投诉 + 无谓磨损。
func testRedLineFalseTriggerAndRecovery() {
    group("红线误触发与恢复(R73)")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var cfg = FanConfig()
    cfg.mode = .ai

    func beat(raw: Double = 70, smoothed: Double = 70, nand: Double = 40, batt: Double = 30,
              wasFailsafe: Bool = false, wasSSD: Bool = false, wasSSDCrit: Bool = false,
              mode: FanMode = .ai) -> FanPipeline.Decision {
        var c = cfg
        c.mode = mode
        return FanPipeline.decide(config: c, smoothedTemp: smoothed, rawTemp: raw, nandTemp: nand,
                                  onBattery: false, aiPercent: 50, now: now,
                                  wasSSDGuardActive: wasSSD, wasSSDCriticalActive: wasSSDCrit,
                                  wasFailsafeActive: wasFailsafe, battTemp: batt)
    }

    // ① 单拍尖峰：该拍全速（设计取舍），但**下一拍必须释放**，不得锁存
    let spike = beat(raw: 92)
    expectEqual(spike.targetPercent, 100, "单拍 raw=92：该拍全速（刻意用 raw）")
    expect(spike.failsafeActive, "该拍 failsafeActive 置位（daemon 据此记边沿日志）")
    let after = beat(raw: 80, wasFailsafe: true)
    expect(!after.failsafeActive, "尖峰后一拍 raw=80（<释放线 88）必须释放，不得锁存")
    expect(after.targetPercent != 100, "释放后不得保持全速")

    // ② 迟滞两侧：未激活时 88–92 之间**不得**触发；已激活时同区间**必须**保持
    for raw in [88.0, 89.5, 91.0, 91.9] {
        let d = beat(raw: raw)
        expect(!d.failsafeActive, "未激活态 raw=\(raw)（<92）不得触发兜底")
    }
    for raw in [88.0, 89.5, 91.0, 91.9] {
        let d = beat(raw: raw, wasFailsafe: true)
        expect(d.failsafeActive, "已激活态 raw=\(raw)（≥释放线 88）必须保持兜底（迟滞防抖）")
    }
    expect(!beat(raw: 87.9, wasFailsafe: true).failsafeActive, "已激活态 raw=87.9（<88）才释放")

    // ③ 恢复轨迹：从 92 逐拍降温到 86，输出必须单调非增、中途不得二次触发
    var prevTarget = 101.0
    var reTriggered = false
    var raw = 92.0
    while raw >= 86 {
        let d = beat(raw: raw, wasFailsafe: true)
        if let t = d.targetPercent {
            if t > prevTarget + 0.001 { reTriggered = true }   // 回升即算二次触发
            prevTarget = t
        }
        raw -= 1
    }
    expect(!reTriggered, "降温过程中输出不得回升（单调回落）")
    expect(!beat(raw: 86, wasFailsafe: true).failsafeActive, "降到 86 必须已释放")

    // ④ 坏读数不会把输出卡死：92 之后紧跟一个荒谬低值（骤降），必须正常释放
    let crash = beat(raw: 20, wasFailsafe: true)
    expect(!crash.failsafeActive, "raw 从 92 骤降到 20：必须释放（不得因坏读卡在全速）")

    // ⑤ SSD/电池同构：单拍越线触发一次，下一拍回落即释放；未越线不得触发
    expectEqual(beat(nand: 78, wasSSDCrit: false).targetPercent, 100, "单拍 NAND=78 触发危急档")
    expect(!beat(nand: 60, wasSSDCrit: true).ssdGuard, "NAND 回落到 60（<67）必须解除托底")
    expect(!beat(nand: 69.9).ssdGuard, "未激活态 NAND=69.9（<70）不得触发托底")
    // 危急档**蕴含**警告档（`ssdState` 里 `guardActive = critical || …`，消费者把 ssdGuard 当"安全在生效"用）
    // ⇒ 我原来的断言"78 只进危急、不标 guard"是错的，按设计改。
    let crit = beat(nand: 78, wasSSDCrit: false)
    expect(crit.ssdGuard && crit.ssdCriticalActive && crit.targetPercent == 100,
           "NAND=78：危急档蕴含警告标记且强制全速（设计如此）")
    let warn = beat(nand: 72)
    expect(warn.ssdGuard && !warn.ssdCriticalActive && warn.targetPercent == 60,
           "NAND=72：只进警告档（60%），不标危急")
    expect(!beat(batt: 44.9).batteryGuard, "未激活态电池 44.9（<45）不得触发托底")
}
