// 测试按模块拆分（v3.3.1）：本文件为各模块共享的 harness 与主入口。
// 断言/共享构造见 TestSupport.swift，各模块用例见 Tests*.swift。
import Foundation
import SMCCore

// MARK: - MockSMC：协议抽象下的硬件编排测试（无需物理 SMC）

// 内存键值表 + 写记录：readDouble/writeDouble 直查直记，
// read() 按 flt 小端编码真实字节，让 isFloatKey 的 doubleValue 解码链路也跑到
final class MockSMC: SMCIO {
    var values: [String: (type: String, value: Double)] = [:]
    var writes: [(key: String, value: Double)] = []

    func set(_ key: String, _ value: Double, type: String = "flt ") {
        values[key] = (type, value)
    }
    func lastWrite(_ key: String) -> Double? { writes.last { $0.key == key }?.value }

    func read(_ key: String) throws -> SMCValue {
        guard let v = values[key] else { throw SMCError.keyNotFound(key) }
        var f = Float32(v.value)
        let bytes = withUnsafeBytes(of: &f) { Array($0) }
        return SMCValue(key: key, dataType: v.type, dataSize: 4, bytes: bytes)
    }
    func readDouble(_ key: String) throws -> Double {
        guard let v = values[key] else { throw SMCError.keyNotFound(key) }
        return v.value
    }
    func write(_ key: String, bytes: [UInt8]) throws {}
    func writeDouble(_ key: String, value: Double) throws {
        writes.append((key, value))
        values[key]?.value = value
    }
    func keyExists(_ key: String) -> Bool { values[key] != nil }
    func allKeys() throws -> [String] { Array(values.keys) }
}


func testFanControllerMock() {
    group("风扇控制(mock)")
    // Apple Silicon 风格（F0Md 存在）：先切手动模式再写目标，钳位到 [min,max]
    do {
        let smc = MockSMC()
        smc.set("FNum", 2, type: "ui8 ")
        for i in 0...1 {
            smc.set("F\(i)Md", 0, type: "ui8 ")
            smc.set("F\(i)Ac", 1500)
            smc.set("F\(i)Mn", 1200)
            smc.set("F\(i)Mx", 5000)
            smc.set("F\(i)Tg", 1500)
        }
        let fc = try! FanController(smc: smc)
        expectEqual(fc.fanCount, 2, "风扇数量")
        try! fc.setForcedRPM(fan: 0, rpm: 3000)
        expectEqual(smc.lastWrite("F0Md"), 1, "AS 风格先切手动模式")
        expectEqual(smc.lastWrite("F0Tg"), 3000, "写入目标转速")
        try! fc.setForcedRPM(fan: 0, rpm: 9999)
        expectEqual(smc.lastWrite("F0Tg"), 5000, "超上限钳到 maxRPM")
        try! fc.setForcedRPM(fan: 1, rpm: 100)
        expectEqual(smc.lastWrite("F1Tg"), 1200, "低于下限钳到 minRPM")
        try! fc.restoreAuto(fan: 0)
        expectEqual(smc.lastWrite("F0Md"), 0, "恢复自动=模式 0")
        let st = try! fc.state(of: 0)
        expectClose(fc.rpm(forPercent: 50, state: st), 3100, 1e-9, "50%=(min+max)/2")
        expectClose(fc.rpm(forPercent: 150, state: st), 5000, 1e-9, "百分比钳到 100")
    }
    // Intel 风格（无 F0Md，用 FS! 位掩码）：强制置位、恢复清位
    do {
        let smc = MockSMC()
        smc.set("FNum", 2, type: "ui8 ")
        smc.set("FS! ", 0, type: "ui16")
        for i in 0...1 {
            smc.set("F\(i)Ac", 2000); smc.set("F\(i)Mn", 1500)
            smc.set("F\(i)Mx", 6000); smc.set("F\(i)Tg", 2000)
        }
        let fc = try! FanController(smc: smc)
        try! fc.setForcedRPM(fan: 1, rpm: 4000)
        expectEqual(smc.lastWrite("FS! "), 2, "Intel 强制置 bit1")
        expectEqual(smc.lastWrite("F1Tg"), 4000, "Intel 写目标")
        try! fc.setForcedRPM(fan: 0, rpm: 4000)
        expectEqual(smc.lastWrite("FS! "), 3, "双风扇掩码叠加")
        try! fc.restoreAuto(fan: 1)
        expectEqual(smc.lastWrite("FS! "), 1, "恢复清 bit1 留 bit0")
        fc.restoreAutoAll()
        expectEqual(smc.lastWrite("FS! "), 0, "全部恢复清位")
    }

    // v5: 风扇偏移量用 st.id 索引而非 enumerated index
    // daemon 主循环构建 percents 数组时，必须用 st.id 索引 fanOffsets：
    //   fanOffsets[0] = 风扇 0 偏移, fanOffsets[1] = 风扇 1 偏移
    // v8: state(of:) 改为严格读取（任一键缺失即抛错），缺失键风扇被 allStates 跳过，
    // 让 daemon 的 fanStates.isEmpty 安全网真正可达（此前 try?+??0 使空分支成死代码，
    // 且 Mn/Mx=0 时 rpm 映射恒为 0，会把 92°C 兜底的 100% 写成 Tg=0）
    do {
        let smc = MockSMC()
        smc.set("FNum", 2, type: "ui8 ")
        smc.set("F0Md", 0, type: "ui8 "); smc.set("F0Ac", 1500)
        smc.set("F0Mn", 1200); smc.set("F0Mx", 5000); smc.set("F0Tg", 1500)
        smc.set("F1Md", 0, type: "ui8 "); smc.set("F1Ac", 1500)
        smc.set("F1Mn", 1200); smc.set("F1Mx", 5000); smc.set("F1Tg", 1500)
        let fc = try! FanController(smc: smc)
        let states = fc.allStates()
        expectEqual(states.count, 2, "双风扇全有效")
        expectEqual(states[0].id, 0, "states[0].id = 0")
        expectEqual(states[1].id, 1, "states[1].id = 1")

        // 缺失键时 state(of:) 抛错 → 该风扇被 allStates 跳过（而不是返回 0 值风扇）
        smc.values.removeValue(forKey: "F0Ac")
        smc.values.removeValue(forKey: "F0Mn")
        smc.values.removeValue(forKey: "F0Mx")
        smc.values.removeValue(forKey: "F0Tg")
        let statesPartial = fc.allStates()
        expectEqual(statesPartial.count, 1, "缺失键风扇被跳过")
        expectEqual(statesPartial[0].id, 1, "剩余风扇 id 正确")
        expectEqual(statesPartial[0].actualRPM, 1500, "剩余风扇读数正常")

        // setForcedRPM 防御：min/max 无效（读失败 0）时抛错，禁止写入 Tg=0
        do {
            let bad = FanState(id: 0, actualRPM: 0, minRPM: 0, maxRPM: 0, targetRPM: 0)
            try fc.setForcedRPM(state: bad, rpm: 5000)
            expect(false, "min/max 无效应抛错")
        } catch {
            expect(true, "min/max 无效抛错（不写 Tg=0）")
        }

        // offsetForFan 边界条件
        let cfg = FanConfig(mode: .curve, fanOffsets: [5, -10])
        expectEqual(cfg.offsetForFan(index: 0), 5, "风扇 0 偏移 +5")
        expectEqual(cfg.offsetForFan(index: 1), -10, "风扇 1 偏移 -10")
        expectEqual(cfg.offsetForFan(index: 2), 0, "越界索引返回 0")
        expectEqual(cfg.offsetForFan(index: -1), 0, "负索引返回 0")

        // 无偏移配置
        let cfgNoOffset = FanConfig(mode: .curve)
        expectEqual(cfgNoOffset.offsetForFan(index: 0), 0, "nil fanOffsets 返回 0")
        expectEqual(cfgNoOffset.offsetForFan(index: 1), 0, "nil fanOffsets 返回 0")

        // 用 st.id 索引得到正确的偏移（核心断言：daemon 必须用 st.id 而非 enumerated index）
        for st in states {
            expectEqual(cfg.offsetForFan(index: st.id),
                        st.id == 0 ? 5 : -10,
                        "风扇 \(st.id) 用 st.id 索引得到正确偏移")
        }
    }
}


func testSensorsMock() {
    group("传感器发现(mock)")
    let smc = MockSMC()
    smc.set("Tp01", 55); smc.set("Tp02", 61); smc.set("Tp0x", 0)   // 0=休眠核心，启动时应保留
    smc.set("Tg03", 48); smc.set("Tg0y", 130)                      // ≥120 启动时即排除
    smc.set("TH0a", 70); smc.set("TB0t", 30)
    smc.set("PSTR", 38)
    let ts = try! TemperatureSensors(smc: smc)
    let c = ts.sensorCounts
    expectEqual(c.cpu, 3, "CPU 键含零读数（启动排除会永久丢失休眠核心）")
    expectEqual(c.gpu, 1, "GPU 排除启动即越界的键")
    expectEqual(c.nand, 1, "SSD 键发现")
    expectEqual(c.batt, 1, "电池键发现")
    expectEqual(ts.cpuTemperature, 61, "CPU 取有效读数最大值")
    expectEqual(ts.gpuTemperature, 48, "GPU 热点")
    expectEqual(ts.nandTemperature, 70, "SSD 热点")
    expectEqual(ts.batteryTemperature, 30, "电池温度")
    expectEqual(ts.systemPowerWatts, 38, "整机功耗")
    let hot = ts.hottestSensors(count: 2)
    expect(hot.count == 2 && hot[0].id == "TH0a" && hot[1].id == "Tp02", "最热排行（混合部件）")
    // 运行时容错：零读数不拉低 max，≥120 不污染。
    // 热点追踪机制下，被追踪的热键读零时首拍返回 0（平滑层会拒绝骤降），
    // 清空追踪后第二拍全量扫描发现新热点 Tp01=58。
    smc.set("Tp02", 0); smc.set("Tp01", 58)
    _ = ts.cpuTemperature   // 首拍：追踪键 Tp02 读零，清空追踪
    expectEqual(ts.cpuTemperature, 58, "运行时零读数被忽略（全量重扫后恢复）")
    smc.set("Tp01", 150)
    _ = ts.cpuTemperature   // 首拍：追踪键读零，清空追踪
    expectEqual(ts.cpuTemperature, 0, "全无效读数→0（调用方据此判读取失败）")
    let comps = ts.componentTemperatures()
    expect(comps.count == 3 && comps.first?.id == "SSD", "部件排行：CPU 全无效时不出现，最热在顶")
    // Intel 兜底：无 Tp* 键时回落经典 sp78 键
    let smc2 = MockSMC()
    smc2.set("TC0P", 65, type: "sp78"); smc2.set("TG0D", 55, type: "sp78")
    let ts2 = try! TemperatureSensors(smc: smc2)
    expectEqual(ts2.cpuTemperature, 65, "Intel 经典键兜底")
    expectEqual(ts2.gpuTemperature, 55, "Intel GPU 键兜底")
    expect(ts2.systemPowerWatts == nil, "无功耗键返回 nil")
}


// MARK: - 每日统计采样器（跨天归档逻辑，原 daemon 内联）


func testStatsSampler() {
    group("统计采样")
    let now = Date()
    let day1 = DailyStats.dayString(for: now)
    expectEqual(DailyStats.today(), day1, "dayString 与 today 等价")

    var k = StatsSampler(stats: DailyStats(date: day1))
    expect(k.record(temp: 75, totalRPM: 6000, seconds: 3, now: now) == nil, "同日不归档")
    expectEqual(k.stats.maxTemp, 75, "最高温记录")
    expectClose(k.stats.highTempSeconds, 0, 1e-9, "<80° 不计高温时长")
    expectClose(k.stats.revolutions, 300, 1e-9, "转数=RPM×秒/60")

    expect(k.record(temp: 85, totalRPM: 6000, seconds: 3, now: now) == nil, "同日继续累计")
    expectEqual(k.stats.maxTemp, 85, "最高温更新")
    expectClose(k.stats.highTempSeconds, 3, 1e-9, "≥80° 累计高温时长")
    expectClose(k.stats.revolutions, 600, 1e-9, "转数累加")
    expectEqual(k.stats.tempHistogram?[TempHistogram.bucketIndex(for: 85)], 3, "直方图落桶累计")
    expectClose(k.stats.avgTemp, 80, 1e-9, "均温=(75+85)/2（等权 3s 样本，秒加权=算术平均）")
    expectClose(k.stats.tempSeconds, 6, 1e-9, "温度采样秒数累计")
    // v2.6.2: 不等权样本验证秒加权
    var w = StatsSampler(now: Date())
    _ = w.record(temp: 70, totalRPM: 0, seconds: 1, now: Date())
    _ = w.record(temp: 90, totalRPM: 0, seconds: 3, now: Date())
    expectClose(w.stats.avgTemp, 85, 1e-9, "秒加权均温 (70×1+90×3)/4")

    // 跨天：返回前一天战报供归档，新账从零开始
    let future = now.addingTimeInterval(25 * 3600)
    let day2 = DailyStats.dayString(for: future)
    expect(day2 > day1, "25 小时后必跨天（字典序=时间序）")
    let archived = k.record(temp: 60, totalRPM: 0, seconds: 3, now: future)
    expect(archived != nil && archived!.date == day1 && archived!.tempCount == 2,
           "跨天返回前一天完整战报")
    expectEqual(k.stats.date, day2, "当日切换到新日期")
    expectEqual(k.stats.tempCount, 1, "新账只含当拍样本")
    expectEqual(k.stats.maxTemp, 60, "新账最高温重新起步")

    // v3.1: 启停抑制计数 + 旧数据兼容
    var cg = StatsSampler(now: Date())
    _ = cg.record(temp: 60, totalRPM: 0, seconds: 3, now: Date(), cyclingGuard: true)
    _ = cg.record(temp: 60, totalRPM: 0, seconds: 3, now: Date())
    expectEqual(cg.stats.aiCyclingGuards, 1, "启停抑制计数")
    let cgEnc = JSONEncoder(); cgEnc.dateEncodingStrategy = .iso8601
    let cgDec = JSONDecoder(); cgDec.dateDecodingStrategy = .iso8601
    let cgBack = try! cgDec.decode(DailyStats.self, from: cgEnc.encode(cg.stats))
    expectEqual(cgBack.aiCyclingGuards, 1, "aiCyclingGuards 往返")
    let cgLegacy = #"{"date":"2026-08-01","maxTemp":60,"maxTempAt":"2026-08-01T10:00:00Z","highTempSeconds":0,"tempSum":60,"tempCount":1,"revolutions":0}"#.data(using: .utf8)!
    expectEqual(try! cgDec.decode(DailyStats.self, from: cgLegacy).aiCyclingGuards, 0, "旧战报无 aiCyclingGuards 兼容")
    // v3.2: 过冲峰值（max 语义）
    var ov = StatsSampler(now: Date())
    _ = ov.record(temp: 84, totalRPM: 0, seconds: 3, now: Date(), overshoot: 8.0)
    _ = ov.record(temp: 86, totalRPM: 0, seconds: 3, now: Date(), overshoot: 10.5)
    _ = ov.record(temp: 80, totalRPM: 0, seconds: 3, now: Date(), overshoot: 4.0)
    expectEqual(ov.stats.overshootPeak, 10.5, "过冲峰值取最大（10.5，后续 4.0 不回退）")
    _ = ov.record(temp: 60, totalRPM: 0, seconds: 3, now: Date())
    expectEqual(ov.stats.overshootPeak, 10.5, "无过冲拍不回退峰值")
    let ovBack = try! cgDec.decode(DailyStats.self, from: cgEnc.encode(ov.stats))
    expectEqual(ovBack.overshootPeak, 10.5, "overshootPeak 往返")
    expectEqual(try! cgDec.decode(DailyStats.self, from: cgLegacy).overshootPeak, 0, "旧战报无 overshootPeak 兼容")

    // 启动恢复 restore（停机跨天不丢战报）
    group("启动恢复")
    // 无存档 / 空存档 → 开新账、无需归档
    let r0 = StatsSampler.restore(saved: nil, now: now)
    expect(r0.toArchive == nil && r0.sampler.stats.date == day1, "无存档开新账")
    let r1 = StatsSampler.restore(saved: DailyStats(date: day1), now: now)
    expect(r1.toArchive == nil && r1.sampler.stats.date == day1, "空存档不归档")
    // 今天的存档 → 续用（重启不丢当日累计）
    var todayStats = DailyStats(date: day1); todayStats.tempCount = 5; todayStats.maxTemp = 88
    let r2 = StatsSampler.restore(saved: todayStats, now: now)
    expect(r2.toArchive == nil && r2.sampler.stats.maxTemp == 88, "今天存档续用")
    // 停机跨天：stats.json 是昨天的 → 返回待归档 + 开今天新账（不静默丢弃）
    var stale = DailyStats(date: "2026-01-01"); stale.tempCount = 9; stale.maxTemp = 91
    let r3 = StatsSampler.restore(saved: stale, now: now)
    expect(r3.toArchive != nil && r3.toArchive!.date == "2026-01-01" && r3.toArchive!.maxTemp == 91,
           "旧日期战报返回待归档")
    expect(r3.sampler.stats.date == day1 && r3.sampler.stats.tempCount == 0, "同时开今天新账")
}


func testControlEngine() {
    group("控制引擎(接线)")
    var envDirs: [URL] = []
    defer {
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        for d in envDirs { try? FileManager.default.removeItem(at: d) }
    }

    // —— 场景 1：曲线模式首拍 → SMC 写入 Md=1 + 曲线目标 RPM，status 可解释 ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        engine.beat()
        expectEqual(smc.lastWrite("F0Md"), 1, "首拍切入强制模式")
        // 曲线 60° → smoothstep 17.92% → RPM = 1200 + 0.1792×3800 ≈ 1881
        expect(abs((smc.lastWrite("F0Tg") ?? 0) - 1880.96) < 1.0,
               "首拍写入曲线目标（得 \(smc.lastWrite("F0Tg") ?? -1)）")
        let st = ConfigStore.loadStatus()
        expect(abs((st?.appliedPercent ?? 0) - 17.92) < 0.01,
               "status appliedPercent（得 \(st?.appliedPercent ?? -1)）")
        expectEqual(st?.reason, .curve, "status 主因 curve")
        expect(col.schedules.count == 1 && col.schedules[0] > 0, "首拍后安排下一拍")
    }

    // —— 场景 2：raw 93° → 兜底 force 全速（不经平滑，瞬时写满） ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 93); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        engine.beat()
        expectEqual(smc.lastWrite("F0Tg"), 5000, "92° 兜底瞬时全速")
        let st = ConfigStore.loadStatus()
        expectEqual(st?.reason, .failsafe, "主因 failsafe")
        expectEqual(st?.safetyFloorPercent, 100, "safetyFloor 100")
    }

    // —— 场景 3：手动 20% + 电池 49° → 危急托底压过手动意图（偏移旁路语义同源） ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .manual, manualPercent: 20, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("TB0t", 49); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        engine.beat()
        expectEqual(smc.lastWrite("F0Tg"), 5000, "电池危急档手动模式也全速")
        let st = ConfigStore.loadStatus()
        expectEqual(st?.reason, .batteryHot, "主因电池托底")
        expectEqual(st?.safetyFloorPercent, 100, "safetyFloor 100")
    }

    // —— 场景 4：温度读失败 5 拍 → 交还系统 + controlFault ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        engine.beat()   // 先正常控制一拍（forcedModeActive = true）
        expectEqual(smc.lastWrite("F0Md"), 1, "正常拍已接管")
        smc.set("Tp01", 0)
        for _ in 0..<5 { clock.advance(3); engine.beat() }
        expectEqual(smc.lastWrite("F0Md"), 0, "连续 5 拍读失败交还系统")
        let st = ConfigStore.loadStatus()
        expectEqual(st?.faultReason, .sensorUnavailable, "故障原因 sensorUnavailable")
        expectEqual(st?.appliedPercent, 0, "故障期 appliedPercent=0")
    }

    // —— 场景 5：功耗波动 15W 而读数恒定 5 分钟 → 卡死门交还；读数复活自动接管 ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("PSTR", 20)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        for _ in 0..<11 {
            smc.set("PSTR", smc.values["PSTR"]!.value == 20 ? 35 : 20)   // 功耗波动 15W
            engine.beat()
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }   // 模拟风扇物理跟转
            clock.advance(30)
        }
        expectEqual(smc.lastWrite("F0Md"), 0, "卡死确认交还系统")
        let st = ConfigStore.loadStatus()
        expectEqual(st?.faultReason, .sensorImplausible, "故障原因 sensorImplausible")
        expect(st?.reason == nil, "故障期 reason 置 nil")
        smc.set("Tp01", 65)   // 读数复活
        clock.advance(30)
        engine.beat()
        if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
        expectEqual(smc.lastWrite("F0Md"), 1, "读数恢复变化自动重新接管")
        expect(ConfigStore.loadStatus()?.controlFault != true, "故障解除")
    }

    // —— 场景 6：显著调速计数（|Δ|≥3%）+ speedChanges 战报/Codable ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .manual, manualPercent: 50, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        engine.beat()
        if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
        ConfigStore.saveConfig(FanConfig(mode: .manual, manualPercent: 80, envCompensation: false))
        clock.advance(3)
        engine.beat()   // 50% → +8%/拍限速 → 58%，|Δ|=8% ≥3% 计一次
        if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
        engine.shutdownSave()
        let s = ConfigStore.loadStats()
        expectEqual(s?.speedChanges, 1, "调速次数计 1（得 \(s?.speedChanges ?? -1)）")
        expectEqual(s?.tempCount, 2, "两拍采样")
        // Codable 往返 + 旧战报兼容
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try! dec.decode(DailyStats.self, from: enc.encode(s!))
        expectEqual(back.speedChanges, 1, "speedChanges 往返")
        let legacy = #"{"date":"2026-08-01","maxTemp":60,"maxTempAt":"2026-08-01T10:00:00Z","highTempSeconds":0,"tempSum":60,"tempCount":1,"revolutions":0}"#.data(using: .utf8)!
        expectEqual(try! dec.decode(DailyStats.self, from: legacy).speedChanges, 0, "旧战报无 speedChanges 兼容")
    }
    // —— 场景 7：快速下拖风暴（fast apply 连拍）不误判闭环失效（审查 P1 回归） ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .manual, manualPercent: 80, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        engine.beat()
        // 模拟拖动滑块：config 从 80% 快速写到 20%，每次写触发一次 fast apply 拍；
        // mock 风扇 Ac 不跟转（最恶劣物理假设），fast 拍不得累计 mismatch
        var pct = 80.0
        while pct > 20 {
            pct = max(20, pct - 5)
            ConfigStore.saveConfig(FanConfig(mode: .manual, manualPercent: pct, envCompensation: false))
            clock.advance(0.03)
            engine.beat(fastConfigApply: true)
        }
        expect(smc.lastWrite("F0Md") == 1, "风暴期间保持接管（未交还）")
        expect(ConfigStore.loadStatus()?.controlFault != true, "快速下拖不误判闭环失效")
        // 2s 后的正常拍恢复跟随评估（此时 Ac 未跟转，计 1 次 mismatch 但远不到 5）
        clock.advance(2)
        engine.beat()
        expect(ConfigStore.loadStatus()?.controlFault != true, "正常拍不连锁误判")
    }

    // —— 场景 8：AI 目标切换不清空学习数据（v2.9） ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        for _ in 0..<5 {
            engine.beat()
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }   // 模拟风扇跟转（否则反馈故障协议会正当触发并排除学习）
            clock.advance(3)
        }   // 稳态：4 拍采样
        let samplesBefore = engine.thermalLearn.sampleTotal
        expect(samplesBefore >= 3, "curve 稳态已积累样本（得 \(samplesBefore)）")
        ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced,
                                         aiTargetTemp: 80, envCompensation: false))
        clock.advance(3)
        engine.beat()
        if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
        let samplesAfter = engine.thermalLearn.sampleTotal
        expect(samplesAfter == samplesBefore + 1,
               "目标切换学习数据保留并继续积累（\(samplesBefore)→\(samplesAfter)）")
        expect(col.logs.contains { $0.contains("学习数据保留") }, "日志声明保留语义")
    }

    // —— 场景 10：读数偏低型合理性门（max 比环境冷 12° 持续 90s → 交还，恢复自动接管） ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("TB0t", 35); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        engine.beat()   // 谷值建立（电池 35 = 环境参照）+ 正常接管
        expectEqual(smc.lastWrite("F0Md"), 1, "正常接管")
        smc.set("Tp01", 15)   // max=15 < 35−12=23：物理不可能（发热源比环境冷 20°）
        // 前 3 拍被骤降毛刺剔除 hold，之后偏低计数累计 30 拍（90s）判失真
        for _ in 0..<40 { clock.advance(3); engine.beat()
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) } }
        expectEqual(smc.lastWrite("F0Md"), 0, "偏低失真 90s 交还系统")
        expect(ConfigStore.loadStatus()?.faultReason == .sensorImplausible, "故障原因 sensorImplausible")
        smc.set("Tp01", 60)   // 恢复合理区间（对称消抖：90s 合理读数才解除，防边界抖动拍打）
        for _ in 0..<32 { clock.advance(3); engine.beat()
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) } }
        expectEqual(smc.lastWrite("F0Md"), 1, "读数恢复自动接管")
        expect(ConfigStore.loadStatus()?.controlFault != true, "故障解除")
    }

    // —— 场景 11：启停抑制武装 → 战报 aiCyclingGuards 计数（接线层回归） ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        var released = false
        for _ in 0..<15 { engine.beat()
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
            if engine.aiController.idleReleased { released = true; break }
            clock.advance(3) }
        expect(released, "AI 深凉交还")
        // 浸泡破目标 → 夺回并武装（同一拍计入战报）。
        // AI 收到的是平滑温度（EMA α=0.35），77° 约需 7 拍爬过 76° 夺回线 + 2 拍确认
        smc.set("Tp01", 77)
        for _ in 0..<12 { clock.advance(3); engine.beat()
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) } }
        expect(engine.aiController.cyclingGuardArmed, "引擎层武装")
        engine.shutdownSave()
        let st = ConfigStore.loadStats()
        expect(st?.aiCyclingGuards ?? 0 >= 1, "战报 aiCyclingGuards 计数（得 \(st?.aiCyclingGuards ?? -1)）")
    }

    // —— 场景 12：AI 迟滞带接线（v3.2 头号特性的引擎级回归——审查 P0 教训） ——
    // temp 73.9 → error −2.1 → P 步长 3.15%/拍，全部落在 4% 迟滞带内 →
    // 写入保持种子值 curve(73.9) ≈ 58%；未接线时决策一路降到底、Tg → 1200。
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 73.9); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        for _ in 0..<15 { engine.beat()
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
            clock.advance(3) }
        // 迟滞把 3.15%/拍的决策微步量化为 ≥4% 台阶：总写入 ~9 次（含首拍种子）
        // 而非逐拍 15 次。断言用总写入数（复核教训：逐拍 delta 计数曾因快照顺序空转）
        let tgTotal = smc.writes.filter { $0.key == "F0Tg" }.count
        expect(tgTotal <= 11, "迟滞量化写入（总 \(tgTotal) 次，未接线为 15）")
    }

    // —— 场景 13：体感补偿 → AI 有效目标收紧（v3.3） ——
    do {
        envDirs.append(engineTestEnv())
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, envCompensation: false,
                                         palmCompensation: true))
        let smc = makeFanSMC(); smc.set("Tp01", 70); smc.set("Ts0P", 44); smc.set("PSTR", 30)
        let clock = FakeClock()
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        engine.beat()
        let st = ConfigStore.loadStatus()
        expectClose(st?.aiTargetEffective ?? 0, 72, 0.01, "掌托 44° → 有效目标 76−4 = 72（得 \(st?.aiTargetEffective ?? -1)）")
        expect(st?.palmComp == 4, "status 下发体感补偿量")
        // 关闭后恢复
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, envCompensation: false))
        clock.advance(3)
        engine.beat()
        expectClose(ConfigStore.loadStatus()?.aiTargetEffective ?? 0, 76, 0.01, "关闭体感补偿恢复 76")
    }

    // —— 场景 9：静音封顶期不污染 AI 评测（v2.9） ——
    do {
        envDirs.append(engineTestEnv())
        let clock = FakeClock()
        let future = clock.time().addingTimeInterval(600)   // 用 FakeClock 时间轴（真实时钟在凌晨运行时会相对假时钟过期）
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced,
                                         quietUntil: future, quietCapPercent: 30,
                                         envCompensation: false))
        let smc = makeFanSMC(); smc.set("Tp01", 82); smc.set("PSTR", 30)
        let col = EngineCollector()
        let engine = makeEngine(smc: smc, clock: clock, collector: col)
        for _ in 0..<4 { engine.beat(); clock.advance(3) }
        expectEqual(engine.aiMetrics.sampleCount, 0, "静音封顶期不记评测样本")
        engine.shutdownSave()
        expect(ConfigStore.loadStats()?.overshootPeak == 0, "静音封顶期过冲峰值不入账（temp 82 − 目标 76 = 6 被排除）")
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, envCompensation: false))
        clock.advance(3)
        engine.beat()
        expect(engine.aiMetrics.sampleCount >= 1, "解除静音后恢复评测")
    }
}
