// MARK: - v3.6.3 性质/模糊测试（第三种方法论：动态验证）
//
// 前两轮审查（4 路对抗子代理、全量第一性原理通读）都是静态阅读；本文件补动态方法：
//   1. chaos 时间线：随机事件流（温升尖峰/突降/丢读/风扇卡死/SSD/电池发热/模式切换/
//      静音/配置事件/长闲置重扫）下逐拍检查全局不变量——安全红线、值域、收敛性、
//      调度合法性。静态审查覆盖不了多事件组合空间。
//   2. 垃圾 Codable：全部持久化文件喂随机变异 JSON——解码不 trap、消毒幂等、读出有界。
//   3. 蜕变性质：纯函数单调性/有界性/反对称性。
// 全部确定性种子（LCG），CI 零 flake。
//
// 测试环境语义注记：
//   - 所有 ConfigStore 触碰前必须 engineTestEnv()（v3.6.2 写穿事故的教训）
//   - 不调 engine.wake()/enterSleep()：wake 的异步重扫在测试进程里后台线程阻塞于
//     main.sync（主队列无 runloop），apply 永不执行——wake 已有专项测试，chaos 里
//     加入只会引入 FakeClock 跨线程读竞争，无增益
//   - 长闲置重扫用 rescanAllSensorsBlocking 手动驱动（绕开异步 main.sync 死锁面）

import Foundation
import SMCCore

// 确定性 LCG（SplitMix64 混淆），避免系统随机源导致 CI flake
struct FuzzRNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0xD1B54A32D192ED03 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 30; x &*= 0xBF58476D1CE4E5B9; x ^= x >> 27
        x &*= 0x94D049BB133111EB; x ^= x >> 31
        return x
    }
    mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
}

private func chaosCheck(_ violations: inout [String], _ beat: Int, _ cond: Bool, _ msg: String) {
    if !cond, violations.count < 20 { violations.append("b\(beat) \(msg)") }
}

// MARK: - 1. Chaos 时间线

func runChaosTimeline(seed: UInt64, beats: Int, label: String) {
    var rng = FuzzRNG(seed)
    var envDirs: [URL] = []
    envDirs.append(engineTestEnv())
    FanCtlPaths.ensureDirectories()
    defer {
        for d in envDirs { try? FileManager.default.removeItem(at: d) }
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
    }

    var battery = false
    ConfigStore.saveConfig(FanConfig(mode: .ai, aiTargetTemp: 76, envCompensation: false))
    let smc = makeFanSMC()
    var temp = 55.0, ssd = 35.0, batt = 30.0, palm = 26.0, power = 20.0
    func refreshKeys() {
        smc.set("FNum", 1, type: "ui8 ")
        smc.set("F0Md", 0, type: "ui8 ")
        smc.set("F0Ac", 1200)
        smc.set("F0Mn", 1200)
        smc.set("F0Mx", 5349)
        smc.set("F0Tg", 1200)
        smc.set("Tp01", temp); smc.set("Tp02", 30)
        smc.set("TH01", ssd); smc.set("TB0t", batt)
        smc.set("Ts0P", palm); smc.set("TVV0", 45)
        smc.set("PSTR", power)
    }
    refreshKeys()
    let clock = FakeClock()
    let col = EngineCollector()
    let engine = makeEngine(smc: smc, clock: clock, collector: col, onBattery: { battery })

    var mode: FanMode = .ai
    var lastManual = 50.0
    var quietIntent = false
    var manualStreak = 0
    var quietStreak = 0
    var freezeAc = false
    var dropoutBeats = 0
    var lastRescanStamp = clock.time()
    var violations: [String] = []
    let validIntervals: Set<Double> = [0, 1, 2, 3, 5, 10, 20]

    for beat in 1...beats {
        // ---- 事件注入（beat 前） ----
        if dropoutBeats > 0 {
            dropoutBeats -= 1
            smc.set("Tp01", 0); smc.set("Tp02", 0)   // 全热点读零 → tempFail 路径
        } else {
            let ev = rng.pick(100)
            if ev < 50 {                              // 随机游走
                temp = min(97, max(30, temp + rng.range(-3, 3)))
            } else if ev < 60 {                       // 负载尖峰（兜底区边缘）
                temp = rng.range(88, 97)
            } else if ev < 68 {                       // 负载结束突降
                temp = rng.range(35, 50)
            } else if ev < 71 {                       // 丢读 1-3 拍
                dropoutBeats = 1 + rng.pick(3)
                smc.set("Tp01", 0); smc.set("Tp02", 0)
            } else if ev < 74 {                       // SSD 发热
                ssd = rng.range(74, 81)
            } else if ev < 77 {                       // SSD 回落
                ssd = rng.range(30, 45)
            } else if ev < 80 {                       // 电池发热
                batt = rng.range(45, 49)
            } else if ev < 83 {                       // 电池回落
                batt = rng.range(28, 40)
            } else if ev < 86 {                       // 掌托/功耗游走
                palm = rng.range(25, 48); power = rng.range(5, 90)
            } else if ev < 92 {                       // 配置事件
                switch rng.pick(5) {
                case 0:
                    mode = [.curve, .ai, .manual, .auto][rng.pick(4)]
                    lastManual = [0, 35, 100][rng.pick(3)]
                    quietIntent = false
                    ConfigStore.saveConfig(FanConfig(mode: mode, manualPercent: lastManual,
                                                     aiTargetTemp: [72, 76, 80][rng.pick(3)],
                                                     envCompensation: false))
                case 1:   // 静音 10 分钟
                    mode = .curve
                    quietIntent = true
                    ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced,
                                                     quietUntil: clock.time().addingTimeInterval(600),
                                                     quietCapPercent: 30,
                                                     envCompensation: false))
                case 2:   // 电池安静档
                    battery = true
                    ConfigStore.saveConfig(FanConfig(mode: mode == .auto ? .curve : mode,
                                                     preset: .balanced,
                                                     batteryPreset: .quiet,
                                                     envCompensation: false))
                case 3:   // 回电源
                    battery = false
                    ConfigStore.saveConfig(FanConfig(mode: mode, manualPercent: lastManual,
                                                     envCompensation: false))
                default:  // 目标温度换档
                    ConfigStore.saveConfig(FanConfig(mode: mode, manualPercent: lastManual,
                                                     aiTargetTemp: [72, 76, 80][rng.pick(3)],
                                                     envCompensation: false))
                }
            } else if ev < 95 {                       // 风扇卡死切换（反馈健康路径）
                freezeAc.toggle()
            } else {                                  // 长闲置：手动驱动重扫
                smc.resetForTesting()                 // 空扫描（防御路径）+ 全键恢复
                refreshKeys()
                engine.sensors.rescanAllSensorsBlocking(clockOverride: { clock.time() })
                lastRescanStamp = clock.time()
            }
            if dropoutBeats == 0 { refreshKeys() }
        }

        // ---- 拍 ----
        engine.beat()
        clock.advance(3)
        if clock.time().timeIntervalSince(lastRescanStamp) > 250 {
            engine.sensors.rescanAllSensorsBlocking(clockOverride: { clock.time() })
            lastRescanStamp = clock.time()
        }
        // 风扇跟随/卡死：跟随 = Ac 贴上一拍命令
        if !freezeAc || smc.lastWrite("F0Md") == 0 {
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
        }

        // ---- 不变量检查 ----
        let safetyDemand = temp >= 92 || ssd >= 78 || batt >= 48
        guard let st = ConfigStore.loadStatus() else {
            chaosCheck(&violations, beat, false, "status 不可解析")
            if violations.count >= 20 { break }
            continue
        }
        chaosCheck(&violations, beat, st.appliedPercent.isFinite && st.appliedPercent >= 0 && st.appliedPercent <= 100,
                   "appliedPercent 越界 \(st.appliedPercent)")
        if let ps = st.appliedPercents {
            for (i, p) in ps.enumerated() {
                chaosCheck(&violations, beat, p.isFinite && p >= 0 && p <= 100, "percents[\(i)]=\(p)")
            }
        }
        let age = clock.time().timeIntervalSince(st.timestamp)
        chaosCheck(&violations, beat, age >= -1 && age < 60, "status 陈旧 \(Int(age))s")
        if let li = col.schedules.last {
            chaosCheck(&violations, beat, validIntervals.contains(li), "非法调度间隔 \(li)")
        }
        // 安全红线：兜底/托底需求在场（非 auto、无故障）→ 本拍输出必须已打满
        if safetyDemand, st.mode != .auto, st.controlFault != true {
            chaosCheck(&violations, beat, st.appliedPercent == 100,
                       "安全需求（raw \(Int(temp))/ssd \(Int(ssd))/batt \(Int(batt))）输出 \(Int(st.appliedPercent))")
        }
        // 静音封顶收敛（曲线模式，非安全期）：≤30% + 死区裕量
        if quietIntent, st.mode == .curve, !safetyDemand, st.controlFault != true {
            quietStreak += 1
            if quietStreak == 25 {
                chaosCheck(&violations, beat, st.appliedPercent <= 33,
                           "静音 25 拍后输出 \(Int(st.appliedPercent))")
            }
        } else {
            quietStreak = 0
        }
        // 手动收敛：非安全期 30 拍后贴住 manualPercent（±死区 5）
        if st.mode == .manual, !safetyDemand, st.controlFault != true {
            manualStreak += 1
            if manualStreak == 30 {
                chaosCheck(&violations, beat, abs(st.appliedPercent - lastManual) <= 5.5,
                           "手动 30 拍后输出 \(Int(st.appliedPercent)) vs 目标 \(Int(lastManual))")
            }
        } else {
            manualStreak = 0
        }
        if violations.count >= 20 { break }
    }

    // ---- 终态不变量 ----
    for v in engine.thermalLearn.outputByBucket {
        chaosCheck(&violations, 0, v.isFinite && v >= 0 && v <= 100, "学习输出 \(v)")
    }
    for s in engine.thermalLearn.samplesByBucket {
        chaosCheck(&violations, 0, s >= 0, "学习样本数 \(s)")
    }
    // 场景桶键有界性：经 Codable 往返取（scenarioBuckets 为 private，编码面即公开契约）
    if let d = try? JSONEncoder().encode(engine.thermalLearn),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let buckets = obj["scenarioBuckets"] as? [String: Any] {
        chaosCheck(&violations, 0, buckets.count <= 8, "场景桶键数 \(buckets.count)")
    }
    let ao = engine.aiController.output
    chaosCheck(&violations, 0, ao.isFinite && ao >= 0 && ao <= 100, "AI 积分 \(ao)")

    expect(violations.isEmpty, "\(label): \(violations.count) 项不变量违例 —— \(violations.prefix(4))")
}

func testChaosTimelines() {
    group("chaos 时间线模糊（确定性种子）")
    runChaosTimeline(seed: 0xC0FFEE, beats: 600, label: "chaos#1")
    runChaosTimeline(seed: 0xDEADBEEF, beats: 600, label: "chaos#2")
    runChaosTimeline(seed: 0x5EED5EED, beats: 600, label: "chaos#3")
}

// MARK: - 2. 垃圾 Codable 模糊

func testGarbageCodable() {
    group("垃圾 Codable 模糊（确定性种子）")
    var rng = FuzzRNG(0xF00D)
    var envDirs: [URL] = []
    envDirs.append(engineTestEnv())
    FanCtlPaths.ensureDirectories()
    defer {
        for d in envDirs { try? FileManager.default.removeItem(at: d) }
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
    }

    func garbageValue() -> Any {
        switch rng.pick(9) {
        case 0: return 0
        case 1: return -1
        case 2: return 1e308
        case 3: return -1e308
        case 4: return 123456.789
        case 5: return "x"
        case 6: return true
        case 7: return [1, 2, 3]
        default: return NSNull()
        }
    }
    func writeMutated(_ base: Data, to path: URL) {
        var obj = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] ?? [:]
        for _ in 0..<(1 + rng.pick(3)) {
            let keys = Array(obj.keys)
            let roll = rng.pick(10)
            if roll < 5, !keys.isEmpty {
                obj[keys[rng.pick(keys.count)]] = garbageValue()
            } else if roll < 8, !keys.isEmpty {
                obj.removeValue(forKey: keys[rng.pick(keys.count)])
            } else {
                obj["junk\(rng.pick(1000))"] = garbageValue()
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: path)
        }
    }
    func enc(_ d: DailyStats) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return String(data: (try? e.encode(d)) ?? Data(), encoding: .utf8) ?? "?"
    }
    func enc(_ c: FanConfig) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return String(data: (try? e.encode(c)) ?? Data(), encoding: .utf8) ?? "?"
    }

    // 配置：解码不 trap；返回值必为 sanitized 形态且幂等
    var cfgViolations: [String] = []
    var parseViolations: [String] = []
    let cfgBase = try! JSONEncoder().encode(FanConfig(mode: .ai, aiTargetTemp: 76))
    for i in 0..<40 {
        writeMutated(cfgBase, to: FanCtlPaths.configFile)
        let cfg = ConfigStore.loadConfig()
        if i % 8 == 0 {
            expect(cfg.sanitized() == cfg, "config 消毒幂等（iter \(i)）")
        }
        for p in cfg.curve { chaosCheck(&cfgViolations, i, p.percent >= 0 && p.percent <= 100, "curve percent") }
        if let t = cfg.aiTargetTemp { chaosCheck(&cfgViolations, i, t >= 40 && t <= 95, "aiTarget \(t)") }
    }
    expect(ConfigStore.loadConfig().curve.count >= 2, "垃圾配置最终可用")

    // 学习/模型/统计/历史/评测/status：解码不 trap；读出有界
    let learnBase = try! JSONEncoder().encode(ThermalLearn())
    var learnDecoded = 0
    for _ in 0..<40 {
        writeMutated(learnBase, to: FanCtlPaths.learnFile)
        if let l = ConfigStore.loadLearn() {
            learnDecoded += 1
            if let p = l.percent(for: 70) {
                chaosCheck(&parseViolations, 0, p >= 0 && p <= 100, "垃圾学习查表 \(p)")
            }
        }
    }
    let modelBase = try! JSONEncoder().encode(ThermalModel())
    var modelDecoded = 0
    for _ in 0..<40 {
        writeMutated(modelBase, to: FanCtlPaths.modelFile)
        if let m = ConfigStore.loadModel() {
            modelDecoded += 1
            if let p = m.predictedPercent(for: 25, power: 30, targetTemp: 76) {
                chaosCheck(&parseViolations, 0, p >= 0 && p <= 100, "垃圾模型预测 \(p)")
            }
        }
    }
    let statsBase = try! JSONEncoder().encode(DailyStats(date: "2026-09-06"))
    for i in 0..<40 {
        writeMutated(statsBase, to: FanCtlPaths.statsFile)
        if let s = ConfigStore.loadStats() {
            if i % 8 == 0 {
                expect(enc(s.sanitized()) == enc(s), "stats 消毒幂等（iter \(i)）")
            }
            chaosCheck(&parseViolations, 0, s.maxTemp.isFinite && s.tempSum.isFinite, "stats 有限性")
        }
    }
    let histBase = try! JSONEncoder().encode([DailyStats(date: "2026-09-05")])
    for _ in 0..<20 {
        writeMutated(histBase, to: FanCtlPaths.historyFile)
        let days = ConfigStore.loadHistory()
        for d in days {
            expect(enc(d.sanitized()) == enc(d), "history 消毒幂等")
        }
    }
    let metricsBase = try! JSONEncoder().encode(AIControlMetrics(targetTemp: 76, userTargetTemp: 76))
    for _ in 0..<20 {
        writeMutated(metricsBase, to: FanCtlPaths.aiMetricsFile)
        if let m = ConfigStore.loadAIMetrics() {
            let sd = m.temperatureStdDev
            chaosCheck(&parseViolations, 0, sd.isFinite && sd >= 0, "垃圾评测 stdDev \(sd)")
            // v3.8 dt 账本：垃圾解码后读出侧必须仍在安全域（钳位/归 0 生效）
            for b in [m.dtLedgerFast, m.dtLedgerNominal, m.dtLedgerSlow].compactMap({ $0 }) {
                chaosCheck(&parseViolations, 0,
                           b.samples >= 0 && b.seconds.isFinite && b.seconds >= 0
                               && b.dAbsSum.isFinite && b.dAbsSum >= 0
                               && b.pAbsSum.isFinite && b.pAbsSum >= 0,
                           "垃圾 dt 账本桶越界 \(b)")
                if b.seconds > 0 {
                    let r = b.dRatePerSecond ?? 0
                    chaosCheck(&parseViolations, 0, r.isFinite && r >= 0, "垃圾桶 D 速率 \(r)")
                }
            }
        }
    }
    // v3.8 硬件画像：直接喂 9 类垃圾值组合（含类型错配——decodeIfPresent 抛错路径）
    for _ in 0..<40 {
        let garbage: [Any] = [0, -1, 1e308, -1e308, "x", true, [1, 2, 3], NSNull(), 12345.678]
        var obj: [String: Any] = [
            "modelID": garbage[rng.pick(garbage.count)],
            "chipName": garbage[rng.pick(garbage.count)],
            "osVersion": garbage[rng.pick(garbage.count)],
            "fanCount": garbage[rng.pick(garbage.count)],
            "sensorCounts": ["cpu": garbage[rng.pick(garbage.count)],
                             "gpu": garbage[rng.pick(garbage.count)]],
            "hasPowerKey": garbage[rng.pick(garbage.count)],
            "collectedAt": garbage[rng.pick(garbage.count)],
        ]
        if rng.pick(3) == 0 { obj.removeValue(forKey: "sensorCounts") }
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let hp = try? JSONDecoder().decode(HardwareProfile.self, from: data) {
            // 解码成功的形态：读出侧保证安全域
            chaosCheck(&parseViolations, 0,
                       hp.fanCount >= 0 && hp.fanCount <= 100
                           && hp.modelID.map { $0.count <= 128 } ?? true,
                       "垃圾画像字段越界 fanCount=\(hp.fanCount)")
        }
    }
    let statusBase = try! JSONEncoder().encode(
        DaemonStatus(sensors: SensorReadings(cpuDie: 70, gpuDie: 60), mode: .curve,
                     appliedPercent: 40, fans: [FanStatusEntry(id: 0, actualRPM: 2000, targetRPM: 2000,
                                                               minRPM: 1200, maxRPM: 5000)]))
    for _ in 0..<20 {
        writeMutated(statusBase, to: FanCtlPaths.statusFile)
        if let s = ConfigStore.loadStatus() {
            _ = statusChangeSummary(s)   // 不得 trap
        }
    }

    // statusChangeSummary 直接喂随机垃圾数值
    var summaryViolations: [String] = []
    for _ in 0..<100 {
        let garbage: [Double] = [.nan, .infinity, -.infinity, 1e308, -1e308, 0, -0, Double(rng.pick(300) - 100)]
        let st = DaemonStatus(
            sensors: SensorReadings(cpuDie: garbage[rng.pick(garbage.count)],
                                    gpuDie: garbage[rng.pick(garbage.count)]),
            mode: .curve, appliedPercent: garbage[rng.pick(garbage.count)],
            appliedPercents: [garbage[rng.pick(garbage.count)], .nan],
            fans: [FanStatusEntry(id: rng.pick(3) - 1, actualRPM: garbage[rng.pick(garbage.count)],
                                  targetRPM: garbage[rng.pick(garbage.count)],
                                  minRPM: 1200, maxRPM: 5000)],
            powerWatts: garbage[rng.pick(garbage.count)],
            envTemp: garbage[rng.pick(garbage.count)],
            palmComp: garbage[rng.pick(garbage.count)],
            learnEnvelopeGap: garbage[rng.pick(garbage.count)])
        let s = statusChangeSummary(st)
        chaosCheck(&summaryViolations, 0, !s.isEmpty, "summary 空")
    }

    expect(summaryViolations.isEmpty, "summary 垃圾输入违例: \(summaryViolations.prefix(3))")
    expect(cfgViolations.isEmpty, "config 垃圾池违例: \(cfgViolations.prefix(3))")
    expect(parseViolations.isEmpty, "解码读出违例: \(parseViolations.prefix(3))")
    expect(learnDecoded > 0 && modelDecoded > 0, "垃圾池确实覆盖了可解码形态（learn \(learnDecoded)/model \(modelDecoded)）")
}

// MARK: - 3. 蜕变性质（纯函数）

func testMetamorphicProperties() {
    group("蜕变性质（纯函数）")
    var rng = FuzzRNG(0xBEEF)

    // 环境补偿：值域 [-5, 8]；分段单调——guard 域（≤5°）恒 0，工作域 (5,45] 线性
    //（5.0→5.5 从 0 跳到 −5 是 guard→线性段的合法跳变：冰点环境按保守下限收紧）
    var prevOff = -100.0
    var env = 5.0
    while env <= 45 {
        let off = FanPipeline.envOffset(envTemp: env, enabled: true)
        expect(off >= -5 && off <= 8, "envOffset 有界 @\(env)")
        if env > 5.5 {
            expect(off >= prevOff - 1e-9, "envOffset 工作域单调 @\(env)")
        }
        prevOff = off
        env += 0.5
    }
    // 体感补偿：值域 [0, 4]；同样分段单调（≤40° 恒 0，>40° 线性）
    prevOff = -1.0
    var palm = 5.0
    while palm <= 54 {
        let c = FanPipeline.palmComp(palmRest: palm, enabled: true)
        expect(c >= 0 && c <= 4, "palmComp 有界 @\(palm)")
        if palm > 40.5 {
            expect(c >= prevOff - 1e-9, "palmComp 工作域单调 @\(palm)")
        }
        prevOff = c
        palm += 0.5
    }

    // 版本比较反对称：不同解析结果恰有一方向为真
    for _ in 0..<200 {
        let a = "v\(rng.pick(5)).\(rng.pick(20)).\(rng.pick(10))"
        let b = "\(rng.pick(5)).\(rng.pick(20)).\(rng.pick(10))"
        let ab = VersionCheck.isNewer(a, than: b)
        let ba = VersionCheck.isNewer(b, than: a)
        expect(!(ab && ba), "版本比较反对称 \(a)/\(b)")
    }

    // 功耗解析：mW→W 换算 + 千分位 + 词内单位，最后样本胜出
    let parserCases: [(String, Double)] = [
        ("CPU Power: 789 mW", 0.789),
        ("CPU Power: 789mW", 0.789),
        ("CPU Power: 12,345 mW", 12.345),
        ("CPU Power: 12.3 W", 12.3),
        ("CPU Power: 100 mW\nCPU Power: 300 mW", 0.3),
    ]
    for (text, want) in parserCases {
        expectClose(PowerMetricsParser.watts(in: text, key: "CPU Power:")!, want, 1e-9, "parser \(text)")
    }

    // 消毒幂等（直接构造垃圾配置，不经 JSON）
    for _ in 0..<50 {
        var cfg = FanConfig(
            mode: .curve,
            manualPercent: rng.range(-50, 500),
            curve: (0..<rng.pick(6)).map { _ in CurvePoint(temp: rng.range(-20, 300), percent: rng.range(-100, 400)) },
            quietCapPercent: rng.range(-10, 200),
            aiTargetTemp: rng.range(-100, 500),
            fanOffsets: (0..<rng.pick(4)).map { _ in rng.range(-100, 100) },
            envCompensation: rng.pick(2) == 0)
        let s1 = cfg.sanitized()
        let s2 = s1.sanitized()
        expect(s1 == s2, "config.sanitized 幂等")
        cfg = s1
    }

    // shape/slew 对任意输入（含 NaN/Inf）输出恒 ∈ [0,100]（L2 加固验证）
    for _ in 0..<100 {
        let targets: [Double] = [.nan, .infinity, -.infinity, rng.range(-500, 500)]
        for t in targets {
            var c = FanCurveController()
            let v1 = c.slew(target: t)
            expect(v1.isFinite && v1 >= 0 && v1 <= 100, "slew(NaN/Inf/越界) ∈ [0,100]（得 \(v1)）")
            var q = FanCurveController()
            let v2 = q.shape(target: t)
            expect(v2.isFinite && v2 >= 0 && v2 <= 100, "shape(NaN/Inf/越界) ∈ [0,100]（得 \(v2)）")
        }
    }

    // 消毒后曲线插值有界（垃圾温度/百分比输入）
    for _ in 0..<50 {
        let curve = (0..<5).map { _ in CurvePoint(temp: rng.range(-20, 300), percent: rng.range(-100, 400)) }
            .map { CurvePoint(temp: $0.temp.isFinite ? max(0, min(120, $0.temp)) : 0,
                              percent: $0.percent.isFinite ? max(0, min(100, $0.percent)) : 0) }
        for probe in [25.0, 55.0, 80.0, 110.0, .nan, .infinity] {
            let p = FanConfig.percent(temp: probe, curve: curve)
            expect(p.isFinite && p >= 0 && p <= 100, "插值有界 @\(probe)（得 \(p)）")
        }
    }
}
