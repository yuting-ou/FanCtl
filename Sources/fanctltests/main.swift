import Foundation
import SMCCore

// 轻量测试 harness（无需 Xcode/XCTest）：swift run fanctltests
// 任一断言失败则进程退出码非 0。各模块用例见 Tests*.swift。

var checks = 0
var failures = 0
var currentGroup = ""
var seenGroups = Set<String>()   // R23 测试基建：distinct group 数作第二道契约门槛

func group(_ name: String) { currentGroup = name; seenGroups.insert(name) }

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
    var diverged = false
    for t in stride(from: 45.0, through: 95.0, by: 1.0) {
        let pq = FanConfig.percent(temp: t, curve: q)
        let pb = FanConfig.percent(temp: t, curve: b)
        let pa = FanConfig.percent(temp: t, curve: a)
        expect(pa + 1e-6 >= pb, "\(label) @\(Int(t))°: 强劲(\(Int(pa)))<均衡(\(Int(pb)))")
        expect(pb + 1e-6 >= pq, "\(label) @\(Int(t))°: 均衡(\(Int(pb)))<安静(\(Int(pq)))")
        if pa - pq >= 5 { diverged = true }
    }
    // R23 再审（变异审查 A1）：仅 `>=` 允许三档完全相等——把 aggressive 的 shift 改成 0
    // （"强劲"个性静默消失）时全 4504 条仍绿。断言中间温区至少一处真实分叉 ≥5%。
    expect(diverged, "\(label): 三档个性必须真实分叉（防 aggressive/quiet 被压平成同一条曲线）")
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

    // R24（非锁存退避）：反复故障 → 解除所需拍数 3→6→12 退避，但自解路径永在（绝不锁存）；
    // 一次确认跟随即归零。这是"振荡有界"与"假故障可自解"两个目标的合一。
    do {
        var fh = FanFeedbackHealth()
        let bad = FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let good = FanState(id: 0, actualRPM: 3900, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        func fault() { for _ in 0..<FanFeedbackHealth.faultThreshold { fh.record(states: [bad], commandedRPM: cmd) } }
        fh.record(states: [bad], commandedRPM: cmd)   // 启动宽限热身拍
        fault()
        expect(fh.faulted && fh.faultStreak == 1 && fh.effectiveRecoverThreshold == 3, "首故障 streak=1 退避 3")
        for _ in 0..<3 { fh.record(states: [bad], commandedRPM: [:]) }
        expect(!fh.faulted, "自解保留：交还 3 拍解除（不锁存）")
        fault()
        expect(fh.faulted && fh.faultStreak == 2 && fh.effectiveRecoverThreshold == 6, "二故障 streak=2 退避 6")
        for _ in 0..<5 { fh.record(states: [bad], commandedRPM: [:]) }
        expect(fh.faulted, "退避生效：5 拍(<6)仍锁存")
        fh.record(states: [bad], commandedRPM: [:])
        expect(!fh.faulted, "第 6 拍解除（退避后仍自解，非永久锁存）")
        fault()   // streak=3 → 退避 12
        expect(fh.faultStreak == 3 && fh.effectiveRecoverThreshold == 12, "三故障 streak=3 退避 12")
        for _ in 0..<12 { fh.record(states: [bad], commandedRPM: [:]) }
        expect(!fh.faulted, "退避 12 拍后仍自解")
        fh.record(states: [good], commandedRPM: cmd, risingGrace: false)   // 非故障态确认跟随
        expect(fh.faultStreak == 0, "确认跟随 → 退避归零（下次故障回 3 拍基准）")
    }

    // R24c 封顶：streak≥5 时阈值钉在 48，不再指数上溢
    do {
        var fh = FanFeedbackHealth()
        let bad = FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [bad], commandedRPM: cmd)
        for n in 1...6 {
            for _ in 0..<FanFeedbackHealth.faultThreshold { fh.record(states: [bad], commandedRPM: cmd) }
            expect(fh.faultStreak == n, "第 \(n) 轮故障 streak=\(n)")
            let need = fh.effectiveRecoverThreshold
            let expected = n <= 5 ? (3 << (n - 1)) : 48
            expect(need == expected, "streak=\(n) 阈值 \(need) == \(expected)")
            for _ in 0..<need { fh.record(states: [bad], commandedRPM: [:]) }
            expect(!fh.faulted, "streak=\(n) 自解后解除")
        }
        expect(fh.faultStreak == 6 && fh.effectiveRecoverThreshold == 48, "封顶 48 生效")
    }

    // R24c 多风扇 AND：一坏一好时健康扇不得顶掉坏扇退避（旧 OR 会归零）
    do {
        var fh = FanFeedbackHealth()
        let bad = FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let good = FanState(id: 1, actualRPM: 3900, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0, 1: 4000.0]
        fh.record(states: [bad, good], commandedRPM: cmd)   // 热身
        for _ in 0..<FanFeedbackHealth.faultThreshold { fh.record(states: [bad, good], commandedRPM: cmd) }
        expect(fh.faulted && fh.faultStreak == 1, "双风扇前置：坏扇触发故障")
        for _ in 0..<3 { fh.record(states: [bad, good], commandedRPM: [:]) }
        expect(!fh.faulted, "自解仍走空拍路径")
        expect(fh.faultStreak == 1, "空拍自解不归零 streak")
        // 双扇均有高目标：仅好扇跟上 → 不得归零
        fh.record(states: [bad, good], commandedRPM: cmd, risingGrace: false)
        expect(fh.faultStreak == 1, "OR 已修：好扇单侧跟随不顶掉坏扇退避")
        // 无高目标命令（交还）同样不归零
        fh.record(states: [bad, good], commandedRPM: [:])
        expect(fh.faultStreak == 1, "空命令拍不归零（那是恢复进度非跟随证据）")
        // 仅好扇被高目标命令且跟上 → 可归零（无坏扇被考核）
        fh.record(states: [bad, good], commandedRPM: [1: 4000.0], risingGrace: false)
        expect(fh.faultStreak == 0, "仅考核好扇且跟上 → 归零")
    }

    // R25 起转宽限：71 场景——空闲停转（RPM0）→ 高目标，试探窗 risingGrace=false
    // 下物理 RPM 爬升必须给宽限（不 fault）；恒 0 / 恒低速 / 升后停住仍 fault。
    do {
        // —— 71：起转序列，命令恒 4500；滞后窗内连续多拍（预 R25 会凑满阈值）——
        // ramp 故意保持在 lagging 区（actual < 4500-1575≈2925）足够多拍，
        // 使删除 rpmRising 宽限时单测即红，不依赖引擎场景兜底。
        var fh = FanFeedbackHealth()
        let ramp = [0.0, 200, 400, 600, 800, 1000, 1200, 1600, 2000, 2500, 2800, 3200, 4000, 4500]
        let cmd = [0: 4500.0]
        fh.record(states: [FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4500)],
                  commandedRPM: cmd)
        for rpm in ramp.dropFirst() {
            fh.record(states: [FanState(id: 0, actualRPM: rpm, minRPM: 1000, maxRPM: 5000, targetRPM: 4500)],
                      commandedRPM: cmd, risingGrace: false)
            expect(!fh.faulted, "71 起转中 RPM=\(Int(rpm)) 不得 fault（预 R25 在滞后窗会累计 mismatch）")
        }
        expect(!fh.faulted && fh.consecutiveFailures == 0, "71 场景：整段斜坡无故障残留")
    }
    do {
        // —— 试探窗：RPM 物理爬升给宽限（risingGrace=false）——
        var fh = FanFeedbackHealth()
        let cmd = [0: 4500.0]
        func frame(_ rpm: Double, grace: Bool) {
            fh.record(states: [FanState(id: 0, actualRPM: rpm, minRPM: 1000, maxRPM: 5000, targetRPM: 4500)],
                      commandedRPM: cmd, risingGrace: grace)
        }
        frame(2000, grace: true)   // 热身
        for rpm in [2400.0, 2800, 3200, 3600, 4000, 4400] {
            frame(rpm, grace: false)
            expect(!fh.faulted, "试探窗 RPM 上升=\(Int(rpm)) 不 fault")
        }
    }
    do {
        // —— 停转区起转：actual<100 且上升 → 必须宽限（杀 M1/M4）——
        // 热身在 0；下一拍 80（+80>50）仍在停转区：无宽限/热身未记 RPM 都会 mismatch。
        var fh = FanFeedbackHealth()
        let cmd = [0: 4000.0]
        fh.record(states: [FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)],
                  commandedRPM: cmd)
        expect(fh.consecutiveFailures == 0, "热身拍不计数（前置）")
        fh.record(states: [FanState(id: 0, actualRPM: 80, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)],
                  commandedRPM: cmd, risingGrace: false)
        expect(!fh.faulted && fh.consecutiveFailures == 0,
               "停转区起转 0→80：stalled 宽限生效且热身 RPM 基线可用（M1/M4 变异体会挂此断言）")
        fh.record(states: [FanState(id: 0, actualRPM: 200, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)],
                  commandedRPM: cmd, risingGrace: false)
        expect(!fh.faulted, "0→80→200 继续爬升仍不 fault")
    }
    do {
        // —— 真停转：恒 0，高目标，risingGrace=false ——
        var fh = FanFeedbackHealth()
        let dead = FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [dead], commandedRPM: cmd)
        for _ in 0..<FanFeedbackHealth.faultThreshold {
            fh.record(states: [dead], commandedRPM: cmd, risingGrace: false)
        }
        expect(fh.faulted, "真停转：RPM 恒 0 无上升 → 仍 fault")
    }
    do {
        // —— 卡死低速：恒 500，目标 4000，无上升，risingGrace=false ——
        var fh = FanFeedbackHealth()
        let stuck = FanState(id: 0, actualRPM: 500, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [stuck], commandedRPM: cmd)
        for _ in 0..<FanFeedbackHealth.faultThreshold {
            fh.record(states: [stuck], commandedRPM: cmd, risingGrace: false)
        }
        expect(fh.faulted, "卡死低速：恒 RPM 无上升 → 仍 fault")
    }
    do {
        // —— 升后停住：0→300→600→600… 停止上升后应 fault ——
        var fh = FanFeedbackHealth()
        let cmd = [0: 4000.0]
        func frame(_ rpm: Double) {
            fh.record(states: [FanState(id: 0, actualRPM: rpm, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)],
                      commandedRPM: cmd, risingGrace: false)
        }
        frame(0)
        frame(300); frame(600)   // 爬升中，不 fault
        expect(!fh.faulted, "升后停住：爬升拍不 fault（前置）")
        for _ in 0..<FanFeedbackHealth.faultThreshold { frame(600) }
        expect(fh.faulted, "升后停住：停止上升后按阈值 fault")
    }
    do {
        // —— 试探窗恒 RPM 滞后（非起转）仍必须可探测 ——
        var fh = FanFeedbackHealth()
        let st = FanState(id: 0, actualRPM: 2000, minRPM: 1000, maxRPM: 5000, targetRPM: 4500)
        let cmd = [0: 4500.0]
        fh.record(states: [st], commandedRPM: cmd)
        for _ in 0..<FanFeedbackHealth.faultThreshold {
            fh.record(states: [st], commandedRPM: cmd, risingGrace: false)
        }
        expect(fh.faulted, "试探窗：RPM 恒定且滞后（无起转斜坡）→ 仍 fault")
    }
    do {
        // —— 停转→起转中 matched 归零 streak：fault 后起转跟上应清 streak ——
        var fh = FanFeedbackHealth()
        let dead = FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [dead], commandedRPM: cmd)
        for _ in 0..<FanFeedbackHealth.faultThreshold {
            fh.record(states: [dead], commandedRPM: cmd)
        }
        expect(fh.faulted && fh.faultStreak == 1, "前置：真停转 fault")
        for _ in 0..<3 { fh.record(states: [dead], commandedRPM: [:]) }
        expect(!fh.faulted, "自解路径仍保留")
        // 重新高目标且 RPM 真跟上 → streak 归零
        let good = FanState(id: 0, actualRPM: 4000, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        fh.record(states: [good], commandedRPM: cmd, risingGrace: false)
        expect(fh.faultStreak == 0, "确认跟随后 streak 归零（R24c 语义未破）")
    }

    // R27 L3-F1：无界 RPM 爬升不得永久算响应——退化扇（斜坡但远落后目标）须 fault
    do {
        var fh = FanFeedbackHealth()
        let cmd = [0: 4000.0]
        var rpm = 150.0
        fh.record(states: [FanState(id: 0, actualRPM: rpm, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)],
                  commandedRPM: cmd)
        for _ in 0..<(FanFeedbackHealth.riseOnlyGraceMaxBeats + FanFeedbackHealth.faultThreshold + 2) {
            rpm += 60   // 永远上升，但始终严重落后 4000
            fh.record(states: [FanState(id: 0, actualRPM: rpm, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)],
                      commandedRPM: cmd, risingGrace: false)
        }
        expect(fh.faulted,
               "无界爬升退化扇：rise-only 宽限封顶后必须 fault（L3-F1）")
    }

    // R27 L3-F4：countsRecover=false 时不消耗自解进度
    do {
        var fh = FanFeedbackHealth()
        let dead = FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [dead], commandedRPM: cmd)
        for _ in 0..<FanFeedbackHealth.faultThreshold {
            fh.record(states: [dead], commandedRPM: cmd)
        }
        expect(fh.faulted, "前置 fault")
        // 试探写入拍：空命令但 countsRecover=false → 仍 faulted
        fh.record(states: [dead], commandedRPM: [:], countsRecover: false)
        expect(fh.faulted, "试探拍 countsRecover=false 不计自解（L3-F4）")
        for _ in 0..<3 { fh.record(states: [dead], commandedRPM: [:]) }
        expect(!fh.faulted, "其后正常交还 3 拍仍自解")
    }

    // R35：reset()（睡眠唤醒）——锁存、退避 streak、命令/RPM 基线与 warmedUp 必须一并作废。
    // 中间那条 "!faulted" 是 warmedUp 的门：少复位它，reset 后第 5 拍即锁存（应为第 6 拍）。
    do {
        var fh = FanFeedbackHealth()
        let dead = FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [dead], commandedRPM: cmd)
        for _ in 0..<FanFeedbackHealth.faultThreshold { fh.record(states: [dead], commandedRPM: cmd) }
        expect(fh.faulted && fh.faultStreak == 1, "reset 前置：已锁存且退避到 6 拍")
        fh.reset()
        expect(!fh.faulted && fh.consecutiveFailures == 0 && fh.faultStreak == 0
               && fh.effectiveRecoverThreshold == FanFeedbackHealth.recoverThreshold,
               "reset 清零锁存/失败计数/退避 streak")
        for _ in 0..<FanFeedbackHealth.faultThreshold {
            fh.record(states: [dead], commandedRPM: cmd)
        }
        expect(!fh.faulted,
               "reset 后首拍只重建基线（5 拍仅累计 4 次失配；warmedUp 未复位则此断言红）")
        fh.record(states: [dead], commandedRPM: cmd)
        expect(fh.faulted, "reset 后仍按完整阈值判定（不永久免疫）")
    }

    // R35 审查：resetForWake() 与 reset() 的唯一差异 = 保留 faultStreak。反复故障扇的
    // 指数退避是跨会话判决，睡一觉不该退回"3 拍就解除"的最高重接管频率。
    do {
        var fh = FanFeedbackHealth()
        let dead = FanState(id: 0, actualRPM: 0, minRPM: 1000, maxRPM: 5000, targetRPM: 4000)
        let cmd = [0: 4000.0]
        fh.record(states: [dead], commandedRPM: cmd)
        for _ in 0..<FanFeedbackHealth.faultThreshold { fh.record(states: [dead], commandedRPM: cmd) }
        expect(fh.faulted && fh.faultStreak == 1, "唤醒前置：第一轮故障退避到 6 拍")
        for _ in 0..<(FanFeedbackHealth.recoverThreshold + 1) {
            fh.record(states: [], commandedRPM: [:])      // 交还拍自解（不归零 streak）
        }
        expect(!fh.faulted && fh.faultStreak == 1, "自解后 streak 仍留存")
        for _ in 0..<FanFeedbackHealth.faultThreshold { fh.record(states: [dead], commandedRPM: cmd) }
        expect(fh.faulted && fh.faultStreak == 2, "第二轮故障退避翻倍")
        let before = fh.effectiveRecoverThreshold
        fh.resetForWake()
        expect(!fh.faulted && fh.consecutiveFailures == 0, "唤醒清锁存与失败计数")
        expectEqual(fh.faultStreak, 2, "唤醒保留退避记忆（streak）")
        expectEqual(fh.effectiveRecoverThreshold, before,
                    "唤醒后解除阈值仍按退避放大（旧实现回 3 拍）")
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
        // R31：热模型诊断字段可选往返；旧 status 无字段 → nil
        let st2 = DaemonStatus(sensors: SensorReadings(cpuDie: 60, gpuDie: 50),
                               mode: .ai, appliedPercent: 20, fans: [],
                               thermalModelUsable: false, thermalModelB: 1.0, thermalModelSamples: 2576)
        let enc2 = JSONEncoder(); enc2.dateEncodingStrategy = .iso8601
        let dec2 = JSONDecoder(); dec2.dateDecodingStrategy = .iso8601
        let back2 = try! dec2.decode(DaemonStatus.self, from: try! enc2.encode(st2))
        expect(back2.thermalModelUsable == false && back2.thermalModelB == 1.0
               && back2.thermalModelSamples == 2576, "热模型诊断字段往返")
        expect(back.thermalModelUsable == nil, "旧 status 无热模型字段 → nil")
        expect(back.baseTargetPercent == nil && back.safetyFloorPercent == nil,
               "旧状态目标分解字段缺省兼容")
        let legacy = #"{"cpuTemp":70,"gpuTemp":55,"mode":"curve","appliedPercent":45,"fans":[],"timestamp":"2026-07-31T10:00:00Z"}"#.data(using: .utf8)!
        let ls = try dec.decode(DaemonStatus.self, from: legacy)
        expect(ls.controlFault == nil, "旧 status 无 controlFault 兼容")
    } catch { expect(false, "controlFault Codable 抛错: \(error)") }
}

// MARK: - v8 散热参数辨识模型（线性回归收敛）

// MARK: - v2.7 环境温度谷值追踪（抗热浸泡内生性）
// 注：掌托/散热片读数带 10s TTL 展示缓存——cachedMax 走注入时钟（Fans.swift），
// FakeClock 下缓存按测试时间轴正常过期；本测试为聚焦谷值语义只用电池键（每拍新鲜读）驱动。

func testAmbientValley() {
    group("环境谷值估计")
    let smc = MockSMC()
    smc.set("Tp01", 55)   // CPU 热点（谷值合理性检查用）
    smc.set("TB0t", 30)   // 电池 30
    let clock = FakeClock()
    let ts = try! makeTemperatureSensors(smc: smc, clock: { clock.time() })
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
    let ts2 = try! makeTemperatureSensors(smc: smc2, clock: { Date() })
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

// 时钟安全构造（v3.4.5）：TemperatureSensors 的 init 用创建时的 clock()（默认真实时间）
// 记录 lastScanTime；测试随后注入 FakeClock（基准=本地正午）。当真实时间在正午之前时，
// 注入时钟与 lastScanTime 的差值 > 300s → checkRescan 每次访问都触发后台重扫——
// 后台线程与主线程并发写 value-type 缓存字段 → 间歇性 exclusive-access 崩溃（exit 139）。
// 这就是历史"间歇 trap 133/139"的真根因：下午跑不崩、凌晨崩。构造后立即以注入时钟
// 重录 lastScanTime 并重建分类，彻底消除该竞态。所有注入 FakeClock 的测试必须走这里。
func makeTemperatureSensors(smc: SMCIO, clock: @escaping () -> Date) throws -> TemperatureSensors {
    let ts = try TemperatureSensors(smc: smc)
    ts.clock = clock
    ts.rescanAllSensorsBlocking(clockOverride: clock)
    return ts
}

// 每个场景独立临时目录：引擎的 ConfigStore 调用全部落在重定向路径，不碰真实安装
func engineTestEnv() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fanctltests-engine-\(UUID().uuidString)")
    FanCtlPaths.setOverridesForTesting(supportDir: dir, logDir: dir)
    return dir
}

// 4.0 B2：预置成熟学习表（2+ 采信桶）——校准门只对"冷表"生效，
// 既有 AI 行为测试需要绕过观察期直接测控制
func seedLearnTable(buckets: [(Double, Double)] = [(65, 40), (70, 50), (75, 60)]) {
    var learn = ThermalLearn()
    for (t, pct) in buckets {
        for _ in 0..<5 { learn.record(temp: t, percent: pct, now: Date()) }
    }
    ConfigStore.saveLearn(learn)
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
                powerComponents: @escaping () -> (cpu: Double?, gpu: Double?) = { (nil, nil) },
                daemonVersion: String? = nil) -> ControlEngine {
    // v3.4.5：走时钟安全构造（makeTemperatureSensors），否则真实时间在 FakeClock
    // 基准（本地正午）之前时每拍触发后台重扫 → 并发写竞态（间歇 exit 139 真根因）
    let sensors = try! makeTemperatureSensors(smc: smc, clock: { clock.time() })
    return ControlEngine(fans: try! FanController(smc: smc),
                  sensors: sensors,
                  hooks: ControlEngine.Hooks(
                    now: { clock.time() },
                    log: { collector.logs.append($0) },
                    schedule: { collector.schedules.append($0) },
                    onBattery: onBattery,
                    powerComponents: powerComponents,
                    setPowerInterval: { _ in }, daemonVersion: daemonVersion))
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

// MARK: - 4.0 B2 冷启动校准 HIL 对比（观察期播种 vs 现状空表，过冲/收敛不劣化）

func runColdStartHIL(calibrated: Bool) -> (maxO: Double, inBand: Int, changes: Int, nan: Bool) {
    var vm = VirtualMachine()
    var ai = AIController()
    ai.tuning.targetTemp = 76
    var ctrl = FanCurveController()
    var learn = ThermalLearn()
    var prevOut = 0.0, changes = 0, maxO = 0.0
    var inBand = 0, nan = false

    // 负载轨迹（观察期与控制期共用——真实场景：用户在当前负载下开启 AI，
    // 观察到的平衡桶就是接管后立即遇到的桶）
    func load(_ i: Int) -> Double { 45 + 15 * sin(Double(i) / 100.0) + ((i / 200) % 2 == 0 ? 8 : 0) }

    // 观察期（仅校准路径）：45 分钟"系统 auto 管风扇"——系统策略未知，
    // 用均衡曲线近似（macOS 默认策略的合理代理）；稳态样本喂学习表，
    // 与引擎观察期同一稳态门（LearningGate），同一纪律
    if calibrated {
        var obsPrev: Double? = nil
        for i in 0..<900 {   // 45 分钟 @ 3s，同控制期负载
            let power = load(i)
            let p = FanConfig.percent(temp: vm.temp, curve: CurvePreset.balanced.points)
            let applied = ctrl.slew(target: p, force: false, hysteresis: 0)
            vm.step(power: power, percent: applied, dt: 3)
            if let pt = obsPrev,
               LearningGate.isSteady(temp: vm.temp, prevTemp: pt,
                                     baseTarget: applied, prevBase: applied,
                                     shapedBase: applied, dt: 3) {
                learn.record(temp: vm.temp, percent: applied, onBattery: false,
                             powerWatts: power, now: Date())
            }
            obsPrev = vm.temp
        }
    }

    // 控制期（两路径逐拍一致）：AI 接管。
    // 唯一差异 = learned 是否有表可查（校准播种的全部效果都在这里）。
    for i in 0..<1200 {
        let power = load(i)
        let learned = calibrated ? learn.percent(for: vm.temp) : nil
        let o = ai.step(temp: vm.temp, learned: learned, powerWatts: power, dt: 3) ?? 0
        let applied = ctrl.slew(target: o, force: false, hysteresis: 4)
        if abs(applied - prevOut) >= 3 { changes += 1 }
        prevOut = applied
        vm.step(power: power, percent: applied, dt: 3)
        if vm.temp.isFinite {
            maxO = max(maxO, vm.temp - 76)
            if abs(vm.temp - 76) <= 2 { inBand += 1 }
        } else { nan = true }
    }
    return (maxO, inBand, changes, nan)
}

func testColdStartHIL() {
    group("冷启动 HIL（4.0 B2 收尾）")
    let base = runColdStartHIL(calibrated: false)
    let calib = runColdStartHIL(calibrated: true)
    print("  [冷启动HIL] 基线: 过冲 +\(String(format: "%.1f", base.maxO))° 带内 \(base.inBand)/1200 调速 \(base.changes)")
    print("  [冷启动HIL] 校准: 过冲 +\(String(format: "%.1f", calib.maxO))° 带内 \(calib.inBand)/1200 调速 \(calib.changes)")
    expect(!calib.nan, "校准路径无 NaN")
    // 不劣化判据（v3.2 HIL 先例：精度损失 ≤1.5°）：过冲不得比基线差 1.5° 以上，
    // 带内拍数不得少 5% 以上
    expect(calib.maxO <= base.maxO + 1.5,
           "过冲不劣化：校准 \(calib.maxO) vs 基线 \(base.maxO)")
    expect(Double(calib.inBand) >= Double(base.inBand) * 0.95,
           "带内时长不劣化：校准 \(calib.inBand) vs 基线 \(base.inBand)")
}

print("== FanCtl 纯逻辑测试 ==")
testInterpolation()
testHistogram()
testOptimizer()
testConfigAndCodable()
testSaveConfigPermissions()
testCorruptionBackupNoFollow()
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
testColdStartHIL()
testFamilySeeded()
testPalmComp()
testVersionCheck()
testPowerHistogram()
testFamilyScan()
testTwoFanShapes()
testFamilyDefense()
testPowerMetricsGolden()
testOtherHotspotCache()
testHotspotTrackingBudget()
testSMCReadBudget()
testFanLimitsCache()
testSMCBytes()
testEngineWiring()
testLearnSaturatedGate()
testRescanAsync()
testRescanEmptyScanDefense()
testAdversarialFixes()
testSafetyThresholdBoundaries()
testProbeProtocolHandover()
testReassertLoop()
testTrustTriangle()
testDTLedger()
testDTLedgerSelectionBias()
testDTSecondsBaseHarm()
testHardwareProfile()
testAliveDebouncer()
testSelfUpgrade()
testPrivilegedScriptTrust()
testSelfUpgradeFuzz()
testRootScriptGates()
testPassiveMachine()
testPartialFanLoss()
testStatusSummaryCoverage()
testUIAnimationGuards()
testTickBenchSafety()
testWallClockWearRate()
testZeroTempDayStillCounts()
testCalibrationColdStart()
testMetamorphicProperties()
testGarbageCodable()
testChaosTimelines()
testHistorySalvage()
testConfigLastGood()
testAIMetricsWeighted()
testPersistenceFailureRetries()
testDiagnosticReport()
testProbeReadOnlyLoads()
testDaemonVersionField()
print("——")
// 契约下限（与 ci.yml 的徽章门槛一致）：低于此值 = 有测试被删/跳过
// 两源同值由 scripts/test-root-scripts.sh 钉住（R54）。抬升记录：4995=R53 实测 5006/91 组；5005=R54 实测 5016/91 组；5025=R55 实测 5040/92 组
// R33：CI 曾为 4400、源码 4550 双源漂移——已统一；改数值必须两处同时改
// R35/R36：4.2.1 实测 4736 断言 / 82 组；R37：4.2.2 实测 4836 / 84（诊断包结构与口径、
// 只读零副作用两组）；R38：4.2.3 实测 4860 / 85（daemon 版本自报的 JSON 契约组，含
// "init 参数漏赋值"与"接线计数"两条 F9 同族守卫）；R43：4.2.8 实测 4915 / 86；R44：实测 4926 / 87（双风扇不对称量程形状扫描）；R46：实测 4937 / 88（变化感知字段覆盖门）
// （R43 组：交还、边沿不重复写、恢复后再失联、去抖、交还写失败、唤醒补交还）
let minAssertions = 5025
// R23 测试基建：第二道门槛——distinct group 数。断言总数可被循环刷量虚高
// （如 expectPersonalityOrdered 单次产 ~816 条），删掉整段测试但保留循环类断言时
// 总数不降、覆盖却净损；group 数是粗粒度结构量，删函数即少一个 group，刷不出来。
let minGroups = 88
if failures == 0 {
    if checks < minAssertions {
        print("❌ 断言数 \(checks) 低于契约下限 \(minAssertions)（测试被删/跳过？）")
        exit(1)
    }
    if seenGroups.count < minGroups {
        print("❌ distinct group 数 \(seenGroups.count) 低于契约下限 \(minGroups)（整段测试被删/合并？）")
        exit(1)
    }
    print("✅ 全部通过：\(checks) 项断言（\(seenGroups.count) 个测试组）")
    exit(0)
} else {
    print("❌ \(failures)/\(checks) 项断言失败")
    exit(1)
}


