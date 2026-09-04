import Foundation
import SMCCore

// 轻量测试 harness（无需 Xcode/XCTest）：swift run fanctltests
// 任一断言失败则进程退出码非 0。各模块用例见 Tests*.swift。

var checks = 0
var failures = 0
var currentGroup = ""

func group(_ name: String) { currentGroup = name }

func expect(_ cond: Bool, _ msg: String) {
    checks += 1
    if !cond { failures += 1; print("  ❌ [\(currentGroup)] \(msg)") }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    expect(a == b, "\(msg) — got \(a), want \(b)")
}
func expectClose(_ a: Double, _ b: Double, _ tol: Double = 1e-9, _ msg: String) {
    expect(abs(a - b) <= tol, "\(msg) — got \(a), want \(b) (±\(tol))")
}

func makeDay(_ date: String, center: Double, spread: Double,
             hours: Double, maxT: Double, hotRatio: Double) -> DailyStats {
    var d = DailyStats(date: date)
    d.maxTemp = maxT
    let total = hours * 3600
    var h = [Double](repeating: 0, count: TempHistogram.bucketCount)
    for i in 0..<h.count {
        let t = TempHistogram.midTemp(of: i)
        h[i] = exp(-pow((t - center) / spread, 2))
    }
    let sum = h.reduce(0, +)
    d.tempHistogram = h.map { $0 / sum * total }
    // v2.6.2：tempSum 按秒加权（tempSeconds 语义），avgTemp = tempSum/tempSeconds
    d.tempSum = center * total
    d.tempSeconds = total
    d.tempCount = total / 3
    d.highTempSeconds = total * hotRatio
    return d
}

func expectLegal(_ pts: [CurvePoint], _ label: String) {
    expectEqual(pts.count, 5, "\(label) 点数应为 5")
    guard pts.count == 5 else { return }
    expectEqual(pts.first!.percent, 0, "\(label) 首点应 0%")
    expectEqual(pts.last!.percent, 100, "\(label) 末点应 100%")
    for (i, p) in pts.enumerated() {
        expect(p.temp >= 45 && p.temp <= 95, "\(label)[\(i)] 温度越界 \(p.temp)")
        expect(!p.temp.isNaN && !p.percent.isNaN, "\(label)[\(i)] NaN")
        if i > 0 {
            expect(p.temp > pts[i-1].temp, "\(label)[\(i)] 温度未递增 \(pts[i-1].temp)->\(p.temp)")
            expect(p.percent >= pts[i-1].percent, "\(label)[\(i)] 百分比下降")
        }
    }
}

func expectPersonalityOrdered(_ r: CurveOptimizer.Result, _ label: String) {
    guard let q = r.presetCurves[.quiet], let b = r.presetCurves[.balanced],
          let a = r.presetCurves[.aggressive] else {
        expect(false, "\(label) 缺预设曲线"); return
    }
    for t in stride(from: 45.0, through: 95.0, by: 1.0) {
        let pq = FanConfig.percent(temp: t, curve: q)
        let pb = FanConfig.percent(temp: t, curve: b)
        let pa = FanConfig.percent(temp: t, curve: a)
        expect(pa + 1e-6 >= pb, "\(label) @\(Int(t))°: 强劲(\(Int(pa)))<均衡(\(Int(pb)))")
        expect(pb + 1e-6 >= pq, "\(label) @\(Int(t))°: 均衡(\(Int(pb)))<安静(\(Int(pq)))")
    }
}

func expectAllPresetsGood(_ r: CurveOptimizer.Result, _ label: String) {
    expectEqual(Set(r.presetCurves.keys), [.quiet, .balanced, .aggressive], "\(label) 预设不全")
    for (p, c) in r.presetCurves { expectLegal(c, "\(label)/\(p.rawValue)") }
    expectLegal(r.points, "\(label)/points")
    expectPersonalityOrdered(r, label)
}

// MARK: - 管线相关 Codable（quiet/reason 字段往返与旧数据兼容）

func testOffsetsAndReadings() {
    group("风扇偏移与读数")
    let s = FanConfig(mode: .curve, fanOffsets: [5, -30]).sanitized()
    expectEqual(s.offsetForFan(index: 0), 5, "偏移保留")
    expectEqual(s.offsetForFan(index: 1), -20, "偏移钳到 ±20")
    expectEqual(s.offsetForFan(index: 2), 0, "越界索引 0")
    expectEqual(FanConfig(mode: .curve).offsetForFan(index: 0), 0, "无偏移默认 0")
    // v6: NaN fanOffsets 防御——NaN 穿透 min/max 钳位
    let nanCfg = FanConfig(mode: .curve, fanOffsets: [.nan, .infinity, 10]).sanitized()
    expectEqual(nanCfg.offsetForFan(index: 0), 0, "NaN 偏移钳为 0")
    expectEqual(nanCfg.offsetForFan(index: 1), 0, "Inf 偏移钳为 0")
    expectEqual(nanCfg.offsetForFan(index: 2), 10, "正常偏移保留")
    // maxTemp 只含 CPU/GPU；SSD 单独走安全托底，不改变基础曲线主控温度
    let r = SensorReadings(cpuDie: 70, gpuDie: 60, ssd: 80, palmRest: 95, heatsink: 90)
    expectEqual(r.maxTemp, 70, "maxTemp 只含 CPU/GPU，SSD 独立安全托底")
    // 无效读数必须为 0（不伪造兜底值），daemon 的 rawTemp≤1 安全链才能触发
    expectEqual(SensorReadings(cpuDie: 0, gpuDie: 0).maxTemp, 0,
                "无效读数 maxTemp=0（安全链可检测）")

    var metrics = AIControlMetrics(targetTemp: 76)
    metrics.record(temp: 76, output: 40, seconds: 3)
    metrics.record(temp: 82, output: 50, seconds: 3)
    expectEqual(metrics.sampleCount, 2, "AI 指标样本数")
    expectClose(metrics.averageTemp, 79, 1e-9, "AI 指标平均温度")
    expect(metrics.maxOvershoot == 6 && metrics.highTempSeconds == 3, "AI 指标记录过冲与超温时间")
    expect(metrics.outputChangeCount == 1 && metrics.outputChangeMagnitude == 10,
           "AI 指标记录输出变化")

    // WriteHealth：连续失败超阈值置 fault，一次成功即清除
    var wh = WriteHealth()
    for _ in 0..<(WriteHealth.faultThreshold - 1) { wh.record(loopSuccess: false) }
    expect(!wh.faulted, "阈值前不报故障")
    wh.record(loopSuccess: false)
    expect(wh.faulted, "连续失败超阈值报故障")
    wh.record(loopSuccess: true)
    expect(!wh.faulted && wh.consecutiveFailures == 0, "一次成功即清除")

    // FanFeedbackHealth：SMC 写入成功但实际 RPM 不跟随时，连续多拍才报故障
    do {
        var fh = FanFeedbackHealth()
        let st = FanState(id: 0, actualRPM: 1000, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [st], commandedRPM: cmd)   // 启动宽限热身拍（只记录不计数）
        for _ in 0..<(FanFeedbackHealth.faultThreshold - 1) {
            fh.record(states: [st], commandedRPM: cmd)
        }
        expect(!fh.faulted, "风扇反馈偏差未达阈值不报故障")
        fh.record(states: [st], commandedRPM: cmd)
        expect(fh.faulted, "风扇反馈持续偏差报故障")
        // v8: 锁存语义——单拍匹配不再立即解除，需连续 recoverThreshold 拍
        let ok = FanState(id: 0, actualRPM: 3900, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        fh.record(states: [ok], commandedRPM: cmd)
        expect(fh.faulted, "恢复第 1 拍仍锁存（防交还→夺回振荡）")
        fh.record(states: [ok], commandedRPM: cmd)
        expect(fh.faulted, "恢复第 2 拍仍锁存")
        fh.record(states: [ok], commandedRPM: cmd)
        expect(!fh.faulted && fh.consecutiveFailures == 0, "连续 3 拍匹配后解除故障")
    }

    // v8: 升速宽限——目标正在上升时风扇物理追赶，滞后不计入故障
    // （否则高温兜底/SSD 危急的瞬时全速会被误判"闭环失效"，UI 报假故障）
    do {
        var fh = FanFeedbackHealth()
        // 目标 1500 → 5000 持续上升（兜底升速），风扇实际 2000（滞后但追赶中）
        let lagging = FanState(id: 0, actualRPM: 2000, minRPM: 1000, maxRPM: 5000, targetRPM: 5000)
        fh.record(states: [lagging], commandedRPM: [0: 1500])   // 启动宽限热身拍
        for i in 0..<(FanFeedbackHealth.faultThreshold + 2) {
            fh.record(states: [lagging], commandedRPM: [0: 1500 + Double(i) * 500])
        }
        expect(!fh.faulted, "目标持续上升期（升速追赶）不报故障")
        // 目标稳定后仍滞后 → 开始计数（首拍 4500→5000 仍处升速宽限）
        let still = FanState(id: 0, actualRPM: 2000, minRPM: 1000, maxRPM: 5000, targetRPM: 5000)
        fh.record(states: [still], commandedRPM: [0: 5000])
        for _ in 0..<(FanFeedbackHealth.faultThreshold) {
            fh.record(states: [still], commandedRPM: [0: 5000])
        }
        expect(fh.faulted, "目标稳定后持续滞后报故障")
    }

    // v2.6.2: 启动宽限——首拍只记录命令不计数(daemon 重启后接管爬升不误判)
    do {
        var fh = FanFeedbackHealth()
        let st = FanState(id: 0, actualRPM: 1500, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        fh.record(states: [st], commandedRPM: [0: 4000])
        expect(fh.consecutiveFailures == 0, "启动首拍只记录不计数")
        for _ in 0..<(FanFeedbackHealth.faultThreshold - 1) {
            fh.record(states: [st], commandedRPM: [0: 4000])
        }
        expect(!fh.faulted, "首拍宽限后仍需完整阈值才 fault")
        fh.record(states: [st], commandedRPM: [0: 4000])
        expect(fh.faulted, "阈值判定正常")
    }

    // v2.6.2: risingGrace=false 时升速不再宽限(故障试探验证期用严格检查)
    do {
        var fh = FanFeedbackHealth()
        let st = FanState(id: 0, actualRPM: 2000, minRPM: 1000, maxRPM: 5000, targetRPM: 5000)
        fh.record(states: [st], commandedRPM: [0: 4000])
        for _ in 0..<(FanFeedbackHealth.faultThreshold - 1) {
            fh.record(states: [st], commandedRPM: [0: 4500], risingGrace: false)
        }
        expect(!fh.faulted, "严格检查阈值前不 fault")
        fh.record(states: [st], commandedRPM: [0: 4500], risingGrace: false)
        expect(fh.faulted, "risingGrace=false 下目标上升也计数(探测真实故障)")
    }

    // v8: 故障锁存——交还（无命令）不单拍解除，需连续 recoverThreshold 拍匹配
    // （否则 restoreAutoAll 清空证据后立即夺回，形成"交还→夺回"振荡）
    do {
        var fh = FanFeedbackHealth()
        let st = FanState(id: 0, actualRPM: 1000, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [st], commandedRPM: cmd)   // 启动宽限热身拍（只记录不计数）
        for _ in 0..<FanFeedbackHealth.faultThreshold { fh.record(states: [st], commandedRPM: cmd) }
        expect(fh.faulted, "前置：已故障")
        // 交还：无命令 → 恢复进度 1 拍，仍保持 faulted
        fh.record(states: [st], commandedRPM: [:])
        expect(fh.faulted, "交还 1 拍不解除（防夺回振荡）")
        fh.record(states: [st], commandedRPM: [:])
        expect(fh.faulted, "交还 2 拍仍不解除")
        fh.record(states: [st], commandedRPM: [:])
        expect(!fh.faulted, "交还 3 拍后解除（daemon 据此恢复正常接管）")
    }

    // controlFault 字段往返 + 旧 status 兼容
    do {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let st = DaemonStatus(sensors: SensorReadings(cpuDie: 70, gpuDie: 55),
                              mode: .curve, appliedPercent: 45, fans: [],
                              controlFault: true, faultReason: .smcWriteFailed)
        let back = try dec.decode(DaemonStatus.self, from: try enc.encode(st))
        expect(back.controlFault == true, "controlFault 往返")
        expect(back.faultReason == .smcWriteFailed, "faultReason 往返")
        expect(back.baseTargetPercent == nil && back.safetyFloorPercent == nil,
               "旧状态目标分解字段缺省兼容")
        let legacy = #"{"cpuTemp":70,"gpuTemp":55,"mode":"curve","appliedPercent":45,"fans":[],"timestamp":"2026-07-31T10:00:00Z"}"#.data(using: .utf8)!
        let ls = try dec.decode(DaemonStatus.self, from: legacy)
        expect(ls.controlFault == nil, "旧 status 无 controlFault 兼容")
    } catch { expect(false, "controlFault Codable 抛错: \(error)") }
}

// MARK: - v8 散热参数辨识模型（线性回归收敛）

// MARK: - v2.7 环境温度谷值追踪（抗热浸泡内生性）
// 注意：掌托/散热片读数带 10s TTL 展示缓存（内部用真实时钟，测试注入不了），
// 快节奏测试下缓存值永不过期——本测试只用电池键（每拍新鲜读）驱动，语义等价。

func testAmbientValley() {
    group("环境谷值估计")
    let smc = MockSMC()
    smc.set("Tp01", 55)   // CPU 热点（谷值合理性检查用）
    smc.set("TB0t", 30)   // 电池 30
    let clock = FakeClock()
    let ts = try! TemperatureSensors(smc: smc)
    ts.clock = { clock.time() }   // TTL 缓存与测试时间轴同步（否则真实时钟下永不过期）
    let t0 = clock.time()
    let rate = 0.5 / 3600.0

    // 首次建立谷值 = 候选值
    expectEqual(ts.ambientEstimate(now: t0)!, 30, "首次谷值取候选值")

    // 热浸泡：候选上漂到 38（负载），谷值只按泄漏速率爬 10 分钟的量（≈0.083°），
    // 绝不跟随候选——10 分钟室温漂移 0.08°，负载热浸泡的小时级上升不进入谷值
    smc.set("TB0t", 38)
    clock.advance(600)
    let v1 = ts.ambientEstimate(now: clock.time())!
    expect(v1 > 30 && v1 < 30 + 600 * rate + 1e-9, "10 分钟热浸泡谷值仅泄漏爬升（得 \(v1)）")

    // 泄漏上漂封顶：再过 2h 一次调用只积 1h（+0.5°，防睡眠唤醒超大间隔一拍涨满）；
    // 总量 = 首段 600s 泄漏 + 封顶 3600s 泄漏
    clock.advance(7200)
    let v2 = ts.ambientEstimate(now: clock.time())!
    expect(abs(v2 - (30 + 600 * rate + 3600 * rate)) < 1e-9, "2h 间隔泄漏封顶 1h（得 \(v2)）")

    // 候选下探立即跟随（空闲回到低温）
    smc.set("TB0t", 24)
    clock.advance(60)
    expectEqual(ts.ambientEstimate(now: clock.time())!, 24, "候选下探立即跟随")

    // 瞬时读失败（≤1 无效）不清谷值：1h 内沿用
    smc.set("TB0t", 0)
    clock.advance(60)
    expectEqual(ts.ambientEstimate(now: clock.time())!, 24, "瞬时读失败沿用谷值")
    // 持续无候选超过 1h → 代理失效返回 nil
    clock.advance(3700)
    expect(ts.ambientEstimate(now: clock.time()) == nil, "持续 1h+ 无候选判失效")

    // 全部候选热浸泡（贴近芯片温度）→ 宁可关闭补偿
    let smc2 = MockSMC()
    smc2.set("Tp01", 40)   // CPU 仅 40°
    smc2.set("TB0t", 39)   // 候选 39 ≥ cpu−3 → 不可信
    let ts2 = try! TemperatureSensors(smc: smc2)
    expect(ts2.ambientEstimate(now: Date()) == nil, "候选贴近芯片温度判热浸泡，关闭补偿")
}

// MARK: - v8 夜间安静档 + 环境温度补偿

// MARK: - v2.8 控制引擎接线 HIL（MockSMC + FakeClock 真实跑拍，断言 SMC 写入序列）
//
// 引擎测试覆盖的就是 daemon 执行的那份代码（ControlEngine 与 main.swift 共用），
// 此前主循环"接线"零测试覆盖——v2.6/v2.7 的 bug 几乎全部出在这一层。

final class FakeClock {
    var now: Date
    init() {
        // 固定本地正午：夜间安静档（22:00–8:00）永不触发，测试不受时区影响
        now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }
    func time() -> Date { now }
    func advance(_ s: Double) { now = now.addingTimeInterval(s) }
}

// 每个场景独立临时目录：引擎的 ConfigStore 调用全部落在重定向路径，不碰真实安装
func engineTestEnv() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fanctltests-engine-\(UUID().uuidString)")
    FanCtlPaths.setOverridesForTesting(supportDir: dir, logDir: dir)
    return dir
}

func makeFanSMC() -> MockSMC {
    let smc = MockSMC()
    smc.set("FNum", 1, type: "ui8 ")
    smc.set("F0Md", 0, type: "ui8 ")
    smc.set("F0Ac", 1200)
    smc.set("F0Mn", 1200)
    smc.set("F0Mx", 5000)
    smc.set("F0Tg", 1200)
    return smc
}

final class EngineCollector {
    var logs: [String] = []
    var schedules: [Double] = []
}

// v3.4.1：钩子可注入（DoD-7）——电池/分项功耗/wake 路径此前零覆盖
func makeEngine(smc: MockSMC, clock: FakeClock, collector: EngineCollector,
                onBattery: @escaping () -> Bool = { false },
                powerComponents: @escaping () -> (cpu: Double?, gpu: Double?) = { (nil, nil) }) -> ControlEngine {
    let sensors = try! TemperatureSensors(smc: smc)
    sensors.clock = { clock.time() }   // TTL 缓存与测试时间轴同步
    return ControlEngine(fans: try! FanController(smc: smc),
                  sensors: sensors,
                  hooks: ControlEngine.Hooks(
                    now: { clock.time() },
                    log: { collector.logs.append($0) },
                    schedule: { collector.schedules.append($0) },
                    onBattery: onBattery,
                    powerComponents: powerComponents,
                    setPowerInterval: { _ in }))
}


// MARK: - v3.2 AI 输出迟滞带 HIL 对比（调速频率 vs 温度精度，数据决定去留）

func runHIL(hysteresis: Double) -> (changes: Int, rms: Double, maxO: Double, nan: Bool) {
    var vm = VirtualMachine()
    var ai = AIController()
    ai.tuning.targetTemp = 76
    var ctrl = FanCurveController()
    var prevOut = 0.0, changes = 0
    var sumSq = 0.0, n = 0.0, maxO = 0.0
    var nan = false
    // 负载轨迹：45W 基础 + 15W 正弦（周期 ~600s）+ 周期性 8W 阶跃（应用开合）
    // 无风稳态 47~93°：AI 在 0~85% 区间真实工作，迟滞带有发挥空间
    for i in 0..<1200 {   // 1 小时 @ 3s
        let power = 45 + 15 * sin(Double(i) / 100.0) + ((i / 200) % 2 == 0 ? 8 : 0)
        let o = ai.step(temp: vm.temp, powerWatts: power, dt: 3) ?? 0
        let applied = ctrl.slew(target: o, force: false, hysteresis: hysteresis)
        if abs(applied - prevOut) >= 3 { changes += 1 }
        prevOut = applied
        vm.step(power: power, percent: applied, dt: 3)
        if vm.temp.isFinite {
            sumSq += vm.temp * vm.temp; n += 1
            maxO = max(maxO, vm.temp - 76)
        } else { nan = true }
    }
    let rms = (sumSq / max(n, 1)).squareRoot()
    return (changes, rms, maxO, nan)
}

print("== FanCtl 纯逻辑测试 ==")
testInterpolation()
testHistogram()
testOptimizer()
testConfigAndCodable()
testControlLaw()
testControlLawRegression()
testDateChain()
testPipeline()
testPipelineCodable()
testLearningGate()
testPowerParser()
testAIIdleAndLearn()
testAIIntentAndPower()
testOffsetsAndReadings()
testThermalLearn()
testFanControllerMock()
testSensorsMock()
testAmbientValley()
testStatsSampler()
testAIController()
testAIIdleComponentPowerBaseline()
testAnchorProbing()
testThermalModel()
testNightAndEnv()
testVirtualMachine()
testBatteryGuard()
testStuckDetector()
testControlEngine()
testCurveAntiDrift()
testLearningHygiene()
testAICyclingGuard()
testHILHysteresis()
testPalmComp()
testPowerHistogram()
testFamilyScan()
testFamilyDefense()
testPowerMetricsGolden()
testOtherHotspotCache()
testFanLimitsCache()
testSMCBytes()
testEngineWiring()
testRescanAsync()
print("——")
// 契约下限（与 ci.yml 的徽章门槛一致）：低于此值 = 有测试被删/跳过
let minAssertions = 2499
if failures == 0 {
    if checks < minAssertions {
        print("❌ 断言数 \(checks) 低于契约下限 \(minAssertions)（测试被删/跳过？）")
        exit(1)
    }
    print("✅ 全部通过：\(checks) 项断言")
    exit(0)
} else {
    print("❌ \(failures)/\(checks) 项断言失败")
    exit(1)
}


