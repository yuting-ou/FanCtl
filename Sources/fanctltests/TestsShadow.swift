// 第一性原理 Phase 1：影子前馈账本（只读测量，不参与控制）
// v2 口径：主判据 = 模型@当前温度（与实际输出同一工作点）；模型@目标只作前馈参考。
// 覆盖：四候选桶数学、当前/目标偏移语义、无目标窗入桶、模型 0 入账、只读查表、
// schema 迁移/坏桶/overall 不一致、静音/空风扇/写失败排除面。

import Foundation
import SMCCore

// 与 VirtualMachine 同源的一阶热平衡：T = env + a·P − b·u（a=0.5°C/W, b=0.1°C/%）。
// ThermalModel 的归一化域是 a×50、b×50，初值恰好就是这组真值——样本零误差，
// 用来钉住"predictedPercent 就是稳态反解"这条语义，而不是测 RLS 收敛速度。
private func trainedShadowModel() -> ThermalModel {
    var m = ThermalModel()
    for _ in 0..<4 {
        for power in [60.0, 90, 110] {
            for pct in [20.0, 40, 60, 80] {
                let temp = 25 + 0.5 * power - 0.1 * pct
                m.update(env: 25, power: power, percent: pct, temp: temp)
            }
        }
    }
    return m
}

func testShadowFFModelInverse() {
    group("热模型稳态反解")
    let m = trainedShadowModel()
    expect(m.isMature, "模型成熟（样本 \(m.sampleCount)）")
    let need = m.predictedPercent(for: 25, power: 110, targetTemp: 76)
    expectClose(need ?? -1, 40, 2, "110W/目标76 → 40%（稳态反解）")
    let colder = m.predictedPercent(for: 25, power: 110, targetTemp: 70) ?? -1
    let hotter = m.predictedPercent(for: 25, power: 110, targetTemp: 78) ?? -1
    expect(colder > hotter, "目标越低需求越高（\(colder) > \(hotter)）")
    // 控制路径：目标高于被动平衡（25+55=80）→ need≤0 返回 nil（R33 防 .some(0) 短路）
    expectEqual(m.predictedPercent(for: 25, power: 110, targetTemp: 85), nil,
                "控制路径：目标高于被动平衡 → nil（不静默给 0%）")
    // 影子路径：同一个 need≤0 必须给出有效的 0——"模型认为不需要风"也是预测
    expectClose(m.predictedPercentIncludingZero(for: 25, power: 110, targetTemp: 85) ?? -1,
                0, 1e-9, "影子路径：need≤0 → 有效 0")
    // 采信带外仍是 nil（不可用），不能把"带外"也当成 0
    expectEqual(m.predictedPercentIncludingZero(for: 25, power: 200, targetTemp: 76), nil,
                "影子路径：采信带外 → nil（不可用）")
}

func testShadowFFLedgerMath() {
    group("影子前馈账本")
    var b = ShadowFFBucket()
    b.add(actual: 50, modelNow: 40, tableNow: 45, modelTarget: 20, tableTarget: 42,
          tempError: -5, power: 30, temp: 66, target: 71, env: 25)
    b.add(actual: 44, modelNow: 50, tableNow: nil, modelTarget: 30, tableTarget: 40,
          tempError: -4, power: 30, temp: 67, target: 71, env: 25)
    expectEqual(b.samples, 2, "样本数")
    expectClose(b.meanActual ?? -1, 47, 1e-9, "实际均值")
    // 模型@当前：残差 +10 / −6 → 偏差 +2、MAE 8
    expectClose(b.modelNow.mean ?? -1, 45, 1e-9, "模型@当前均值")
    expectClose(b.modelNow.bias ?? -1, 2, 1e-9, "模型@当前偏差")
    expectClose(b.modelNow.mae ?? -1, 8, 1e-9, "模型@当前 MAE")
    expectClose(b.modelNow.coverage(total: b.samples) ?? -1, 1.0, 1e-9, "模型覆盖率")
    // 查表@当前：只有第一拍可用 → 覆盖 50%、MAE 5
    expectEqual(b.tableNow.samples, 1, "查表@当前样本数")
    expectClose(b.tableNow.mae ?? -1, 5, 1e-9, "查表@当前 MAE")
    expectClose(b.tableNow.coverage(total: b.samples) ?? -1, 0.5, 1e-9, "查表覆盖率")
    // 模型@目标：残差 +30 / +14 → MAE 22、偏差 22（含工作点偏移，仅参考）
    expectClose(b.modelTarget.mae ?? -1, 22, 1e-9, "模型@目标 MAE")
    expectClose(b.modelTarget.bias ?? -1, 22, 1e-9, "模型@目标偏差")
    expectClose(b.tableTarget.mae ?? -1, 6, 1e-9, "查表@目标 MAE")
    expectClose(b.meanTemp ?? -1, 66.5, 1e-9, "工作点温度均值")
    expectClose(b.meanTarget ?? -1, 71, 1e-9, "目标均值")
    expectClose(b.meanTempError ?? -1, -4.5, 1e-9, "工作点偏差均值")

    // 分桶边界（锁死语义：power 15/35/60/90；target 70/74/78/82）
    expectEqual(ShadowFFLedger.powerBand(14.9), 0, "power <15 → 0")
    expectEqual(ShadowFFLedger.powerBand(15), 1, "power 15 → 1")
    expectEqual(ShadowFFLedger.powerBand(90), 4, "power ≥90 → 4")
    expectEqual(ShadowFFLedger.targetBand(73.9), 1, "target <74 → 1")
    expectEqual(ShadowFFLedger.targetBand(74), 2, "target 74 → 2")
    expectEqual(ShadowFFLedger.targetBand(76), 2, "target 76 → 2")
    expectEqual(ShadowFFLedger.targetBand(82), 4, "target ≥82 → 4")
}

func testShadowFFLedgerConsider() {
    group("影子账本对账")
    var l = ShadowFFLedger()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // 关键语义：temp=66、target=76（差 10°）仍入桶——不能用目标 ±2° 窗把
    // "现行律在目标下方稳定"的稳态点排除。主判据是模型@当前。
    l.consider(temp: 66, target: 76, env: 25, power: 60, actual: 40,
               modelNow: 40, tableNow: 44, modelTarget: 0, tableTarget: 40,
               steady: true, now: now)
    expectEqual(l.considered, 1, "进入 1 拍")
    expectEqual(l.recorded, 1, "工作点远离目标也入桶")
    expectEqual(l.overall.modelNow.samples, 1, "模型@当前样本")
    expectEqual(l.overall.modelTarget.samples, 1, "模型@目标样本")
    expectEqual(l.buckets[ShadowFFLedger.bucketIndex(power: 60, target: 76)].samples, 1,
                "分桶命中（60W/76°）")
    expectClose(l.overall.meanTempError ?? 0, -10, 1e-9, "工作点偏差被记录")
    expectClose(l.overall.modelNow.mae ?? -1, 0, 1e-9, "模型@当前与实输出一致")
    expectClose(l.overall.modelTarget.mae ?? -1, 40, 1e-9, "模型@目标残差含工作点偏移")
    // 非稳态：计入 notSteady，不入桶
    l.consider(temp: 66, target: 76, env: 25, power: 60, actual: 40,
               modelNow: 40, tableNow: 44, modelTarget: 0, tableTarget: 40,
               steady: false, now: now)
    expectEqual(l.notSteady, 1, "非稳态计数")
    expectEqual(l.recorded, 1, "非稳态不入桶")
    // 缺功耗 → missingInputs（不混进 notSteady）
    l.consider(temp: 66, target: 76, env: 25, power: nil, actual: 40,
               modelNow: 40, tableNow: 44, modelTarget: 0, tableTarget: 40,
               steady: true, now: now)
    expectEqual(l.missingInputs, 1, "缺功耗单列")
    expectEqual(l.notSteady, 1, "缺功耗不污染非稳态计数")
    // 非法值 → invalidInputs，且不污染累加
    l.consider(temp: .nan, target: 76, env: 25, power: 60, actual: 40,
               modelNow: 40, tableNow: 44, modelTarget: 0, tableTarget: 40,
               steady: true, now: now)
    expectEqual(l.invalidInputs, 1, "NaN 输入单列")
    expect(l.overall.sumActual.isFinite && l.overall.samples == 1, "NaN 不污染账本")
    // 对账不变量
    expectEqual(l.considered, l.recorded + l.notSteady + l.missingInputs + l.invalidInputs,
                "四类计数必须对平")
    // 聚合
    let byPower = l.collapsed(.power)
    let byTarget = l.collapsed(.target)
    expectEqual(byPower.count, ShadowFFLedger.powerBandCount, "功耗轴档数")
    expectEqual(byTarget.count, ShadowFFLedger.targetBandCount, "目标轴档数")
    expectEqual(byPower[3].samples, 1, "功耗 60–90W 档（60 落在上边界）")
    expectEqual(byTarget[2].samples, 1, "目标 74–78° 档")

    // 报告：无数据与有数据都必须可读；主判读只看模型@当前（目标候选 MAE 40 但
    // 模型@当前 MAE 0/覆盖 100% → 应判达标）；recorded=0 也要报对账不平。
    let empty = ShadowFFReport.text(ShadowFFLedger())
    expect(empty.contains("尚无 AI 稳态样本"), "空账本报告给出原因")
    let text = ShadowFFReport.text(l)
    expect(text.contains("整体:") && text.contains("模型@当前（主判据）")
           && text.contains("模型@目标") && text.contains("判读门槛"),
           "报告含当前/目标候选与主判读")
    expect(text.contains("样本不足"), "n=1 不判达标（预注册样本量下限）")
    expect(!text.contains("对账不平"), "合法账本不误报对账不平")
    // 30 个样本、模型@当前 MAE 0、覆盖 100% → 达标；模型@目标 MAE 40 不应拉低主判读
    var full = ShadowFFLedger()
    for i in 0..<30 {
        full.consider(temp: 66, target: 76, env: 25, power: 60, actual: 40,
                      modelNow: 40, tableNow: 44, modelTarget: 0, tableTarget: 40,
                      steady: true, now: now.addingTimeInterval(Double(i) * 3))
    }
    let fullText = ShadowFFReport.text(full)
    expect(fullText.contains("→ 达标"), "30 样本 + 模型@当前 MAE 0/覆盖 100% → 达标")
    expect(!fullText.contains("样本不足"), "足量样本不再报样本不足")
    var broken = ShadowFFLedger()
    broken.considered = 6
    broken.notSteady = 5
    expect(ShadowFFReport.text(broken).contains("对账不平"),
           "recorded=0 也要报对账不平（不静默丢样本）")
}

func testShadowFFPersistence() {
    group("影子前馈持久化")
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fanctltests-shadow-\(UUID().uuidString)")
    FanCtlPaths.setOverridesForTesting(supportDir: dir, logDir: dir)
    FanCtlPaths.ensureDirectories()
    defer {
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        try? FileManager.default.removeItem(at: dir)
    }
    var l = ShadowFFLedger()
    l.consider(temp: 66, target: 76, env: 25, power: 60, actual: 40,
               modelNow: 40, tableNow: 44, modelTarget: 0, tableTarget: 40,
               steady: true, now: Date(timeIntervalSince1970: 1_700_000_000))
    expect(ConfigStore.saveShadowFF(l), "保存影子账本")
    let back = ConfigStore.loadShadowFF(readOnly: true)
    expectEqual(back?.version, ShadowFFLedger.schemaVersion, "版本落盘")
    expectEqual(back?.overall.samples, 1, "往返样本数")
    expectEqual(back?.buckets.count, ShadowFFLedger.bucketCount, "往返桶数")
    expectClose(back?.overall.modelNow.mae ?? -1, 0, 1e-9, "往返模型@当前 MAE")

    // 旧 schema（v1）：不混账，空账本重攒
    let v1 = #"{"version":1,"considered":6,"notSteady":6,"buckets":[]}"#.data(using: .utf8)!
    do {
        try v1.write(to: FanCtlPaths.shadowFFFile)
        let reset = ConfigStore.loadShadowFF(readOnly: true)
        expectEqual(reset?.version, ShadowFFLedger.schemaVersion, "旧 schema 升级到当前版本")
        expectEqual(reset?.considered, 0, "旧 schema 计数不混入新账本")
        expectEqual(reset?.recorded, 0, "旧 schema 无记录样本")
    } catch { expect(false, "写 v1 夹具失败: \(error)") }

    // 当前 schema 但桶数组长度错：抛错 → 只读加载 nil（不静默截断/补空）
    let badBuckets = #"{"version":2,"considered":1,"buckets":[]}"#.data(using: .utf8)!
    do {
        try badBuckets.write(to: FanCtlPaths.shadowFFFile)
        expectEqual(ConfigStore.loadShadowFF(readOnly: true), nil, "坏桶数组判废")
    } catch { expect(false, "写坏桶夹具失败: \(error)") }

    // 缺 overall：桶是主数据，由桶和补齐
    do {
        let enc = JSONEncoder()
        let data = try enc.encode(l)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "overall")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        try stripped.write(to: FanCtlPaths.shadowFFFile)
        let rescued = ConfigStore.loadShadowFF(readOnly: true)
        expectEqual(rescued?.overall.samples, 1, "缺 overall 由桶和补齐")
        expectEqual(rescued?.recorded, 1, "recorded 跟随桶和")
    } catch { expect(false, "缺 overall 夹具失败: \(error)") }

    // overall 与桶和不一致：自相矛盾 → 判废
    do {
        let enc = JSONEncoder()
        let data = try enc.encode(l)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var overall = obj["overall"] as! [String: Any]
        overall["samples"] = 2
        obj["overall"] = overall
        let inconsistent = try JSONSerialization.data(withJSONObject: obj)
        try inconsistent.write(to: FanCtlPaths.shadowFFFile)
        expectEqual(ConfigStore.loadShadowFF(readOnly: true), nil, "overall 与桶和不一致判废")
    } catch { expect(false, "overall 不一致夹具失败: \(error)") }
}

func testThermalLearnReadOnlyLookup() {
    group("查表只读入口")
    // 场景桶：light=40%、medium=60%（同一温度 70°）；读数会同时写全局与场景
    var learn = ThermalLearn()
    for _ in 0..<5 { learn.record(temp: 70, percent: 40, onBattery: false, powerWatts: 10) }
    for _ in 0..<5 { learn.record(temp: 70, percent: 60, onBattery: false, powerWatts: 20) }
    // 先把滞回状态置为 light（mutating 查询会更新 lastPowerBand）
    let light = learn.percent(for: 70, onBattery: false, powerWatts: 10)
    expectClose(light ?? -1, 40, 1e-9, "light 场景 40%")
    // 只读查询 18W：距 15W 边界 3W，会选 medium（60%），但不得更新滞回状态
    let ro = learn.percentReadOnly(for: 70, onBattery: false, powerWatts: 18)
    expectClose(ro ?? -1, 60, 1e-9, "只读查询选 medium")
    // 若只读查询偷偷更新了状态，16W 会被滞回锁在 medium（60%）；
    // 正确行为：状态仍是 light，16W 距边界 1W → 保持 light（40%）
    let after = learn.percent(for: 70, onBattery: false, powerWatts: 16)
    expectClose(after ?? -1, 40, 1e-9, "只读查询不更新功耗档滞回（16W 仍回 light）")
}

func testShadowFFEngineWiring() {
    group("影子前馈引擎接线")
    let dir = engineTestEnv()
    defer {
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        try? FileManager.default.removeItem(at: dir)
    }
    ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, aiTargetTemp: 76,
                                     envCompensation: false, envTempOverride: 25))
    // 2 个采信桶绕过冷启动校准；76° 桶学到 40%，与模型反解一致
    seedLearnTable(buckets: [(70, 30), (76, 40)])
    let model = trainedShadowModel()
    expect(model.isMature, "测试模型成熟")
    ConfigStore.saveModel(model)

    let smc = makeFanSMC()
    smc.set("Tp01", 76)
    smc.set("PSTR", 110)
    let clock = FakeClock()
    let col = EngineCollector()
    let engine = makeEngine(smc: smc, clock: clock, collector: col)
    for _ in 0..<12 {
        engine.beat()
        // 让转速跟随命令，避免 feedbackHealth 判故障（故障拍会被影子采样排除）
        if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
        clock.advance(3)
    }
    expect(engine.shadowFF.considered > 0, "AI 正常拍进入影子账本")
    expect(engine.shadowFF.recorded > 0,
           "稳态拍入桶（considered=\(engine.shadowFF.considered)）")
    expect(engine.shadowFF.overall.modelNow.samples > 0, "模型@当前样本被记录")
    expect(engine.shadowFF.overall.tableNow.samples > 0, "查表@当前样本被记录")
    let idx = ShadowFFLedger.bucketIndex(power: 110, target: 76)
    expect(engine.shadowFF.buckets[idx].samples > 0, "功耗/目标分桶命中")
    // 落盘：入睡 flush 后可从盘上读回（60s 节流未到，睡眠必须全量落盘）
    engine.enterSleep()
    let disk = ConfigStore.loadShadowFF(readOnly: true)
    expect((disk?.overall.samples ?? 0) > 0, "睡眠 flush 后账本落盘")
    expect(disk?.buckets.count == ShadowFFLedger.bucketCount, "落盘桶数完整")
    // 影子账本不能改变控制：稳态拍的实际输出应落在模型/查表附近（40% 量级）
    let actual = disk?.overall.meanActual ?? -1
    expect(actual > 30 && actual < 55, "影子采样不扰动控制（实际均值 \(actual)%）")
}

func testShadowFFModelZeroRecorded() {
    group("影子账本记录模型 0")
    let dir = engineTestEnv()
    defer {
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        try? FileManager.default.removeItem(at: dir)
    }
    ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, aiTargetTemp: 76,
                                     envCompensation: false, envTempOverride: 25))
    seedLearnTable(buckets: [(70, 30), (76, 40)])
    ConfigStore.saveModel(trainedShadowModel())
    // 60W 在模型采信带下沿；被动平衡 25+0.283×60≈42° < 目标 76°
    // → 模型反解 0%，但学习表种子让控制律实际给 ~40%。这正是最该被看见的偏差。
    let smc = makeFanSMC(); smc.set("Tp01", 76); smc.set("PSTR", 60)
    let clock = FakeClock()
    let engine = makeEngine(smc: smc, clock: clock, collector: EngineCollector())
    for _ in 0..<12 {
        engine.beat()
        if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
        clock.advance(3)
    }
    expect(engine.shadowFF.overall.modelNow.samples > 0, "模型 0 也算有效样本（非'无样本'）")
    expectClose(engine.shadowFF.overall.modelNow.mean ?? -1, 0, 1e-9, "模型@当前均值为 0")
    expect(engine.shadowFF.overall.tableNow.samples > 0, "查表@当前样本被记录")
    expect((engine.shadowFF.overall.meanActual ?? 0) > 20,
           "实际输出 >20%（模型说 0、控制律仍在给风，偏差被记录）")
    expect((engine.shadowFF.overall.modelNow.mae ?? 0) > 20,
           "模型@当前 MAE >20%（模型 0 vs 实际给风）")
}

func testShadowFFEngineExclusions() {
    group("影子前馈排除面")
    // ① 静音封顶：输出被压、温度不反映基础律 → 不采样
    do {
        let dir = engineTestEnv()
        defer {
            FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
            try? FileManager.default.removeItem(at: dir)
        }
        let clock = FakeClock()
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced,
                                         quietUntil: clock.time().addingTimeInterval(3600),
                                         quietCapPercent: 30, aiTargetTemp: 76,
                                         envCompensation: false, envTempOverride: 25))
        seedLearnTable(buckets: [(70, 30), (76, 40)])
        ConfigStore.saveModel(trainedShadowModel())
        let smc = makeFanSMC(); smc.set("Tp01", 76); smc.set("PSTR", 110)
        let engine = makeEngine(smc: smc, clock: clock, collector: EngineCollector())
        for _ in 0..<6 {
            engine.beat()
            if let tg = smc.lastWrite("F0Tg") { smc.set("F0Ac", tg) }
            clock.advance(3)
        }
        expectEqual(engine.shadowFF.considered, 0, "静音封顶期不进入影子账本")
    }
    // ② 全风扇读失败（fanStates 为空）：没有任何值被施加 → 不采样
    do {
        let dir = engineTestEnv()
        defer {
            FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
            try? FileManager.default.removeItem(at: dir)
        }
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, aiTargetTemp: 76,
                                         envCompensation: false, envTempOverride: 25))
        seedLearnTable(buckets: [(70, 30), (76, 40)])
        ConfigStore.saveModel(trainedShadowModel())
        let smc = makeFanSMC()
        for key in ["F0Ac", "F0Mn", "F0Mx", "F0Tg"] { smc.values.removeValue(forKey: key) }
        smc.set("Tp01", 76); smc.set("PSTR", 110)
        let clock = FakeClock()
        let engine = makeEngine(smc: smc, clock: clock, collector: EngineCollector())
        for _ in 0..<6 { engine.beat(); clock.advance(3) }
        expectEqual(engine.shadowFF.considered, 0, "fanStates 为空时不采样")
    }
    // ③ 写扇失败（单拍未 fault 的窗口也算）：实际值没有写下去 → 不采样
    do {
        let dir = engineTestEnv()
        defer {
            FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
            try? FileManager.default.removeItem(at: dir)
        }
        ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, aiTargetTemp: 76,
                                         envCompensation: false, envTempOverride: 25))
        seedLearnTable(buckets: [(70, 30), (76, 40)])
        ConfigStore.saveModel(trainedShadowModel())
        let smc = makeFanSMC(); smc.set("Tp01", 76); smc.set("PSTR", 110)
        smc.failWriteKeys = ["F0Tg"]
        let clock = FakeClock()
        let engine = makeEngine(smc: smc, clock: clock, collector: EngineCollector())
        for _ in 0..<6 { engine.beat(); clock.advance(3) }
        expectEqual(engine.shadowFF.considered, 0, "写扇失败拍不采样")
    }
}
