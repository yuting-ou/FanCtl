// 测试按模块拆分（v3.3.1）：本文件为各模块共享的 harness 与主入口。
// 断言/共享构造见 TestSupport.swift，各模块用例见 Tests*.swift。
import Foundation
import SMCCore

// MARK: - 曲线插值


func testInterpolation() {
    group("插值")
    let bal = CurvePreset.balanced.points
    expectEqual(FanConfig.percent(temp: 0, curve: bal), bal.first!.percent, "低于首点取首值")
    expectEqual(FanConfig.percent(temp: 200, curve: bal), bal.last!.percent, "高于末点取末值")
    expectEqual(FanConfig.percent(temp: 70, curve: []), 0, "空曲线返回 0")

    // 单调 + 范围
    var last = -1.0
    for t in stride(from: 40.0, through: 100.0, by: 0.5) {
        let p = FanConfig.percent(temp: t, curve: bal)
        expect(p + 1e-9 >= last, "单调性 @\(t)")
        expect(p >= 0 && p <= 100, "范围 @\(t)")
        last = p
    }
    // 单点
    let one = [CurvePoint(temp: 60, percent: 40)]
    expectEqual(FanConfig.percent(temp: 50, curve: one), 40, "单点<")
    expectEqual(FanConfig.percent(temp: 70, curve: one), 40, "单点>")
    // 乱序等价
    let shuffled = Array(bal.reversed())
    for t in stride(from: 45.0, through: 90.0, by: 1.0) {
        expectClose(FanConfig.percent(temp: t, curve: bal),
                    FanConfig.percent(temp: t, curve: shuffled), 1e-9, "乱序等价 @\(t)")
    }
    // 重合温度不 NaN（除零防护）
    let dup = [CurvePoint(temp: 60, percent: 20), CurvePoint(temp: 60, percent: 80),
               CurvePoint(temp: 80, percent: 100)]
    let pd = FanConfig.percent(temp: 60, curve: dup)
    expect(!pd.isNaN, "重合点 NaN")
    // smoothstep 中点
    let seg = [CurvePoint(temp: 60, percent: 0), CurvePoint(temp: 80, percent: 100)]
    expectClose(FanConfig.percent(temp: 70, curve: seg), 50, 1e-6, "smoothstep 中点=50")
    // v6: NaN/Inf 防御——NaN 比较恒 false 会穿透到 return last.percent（100%），Inf 同理
    expectEqual(FanConfig.percent(temp: .nan, curve: bal), 0, "NaN 温度返回 0%（不拉满风扇）")
    expectEqual(FanConfig.percent(temp: .infinity, curve: bal), 0, "Inf 温度返回 0%（不拉满风扇）")
    expectEqual(FanConfig.percent(temp: -.infinity, curve: bal), 0, "-Inf 温度返回 0%")
}


// MARK: - 直方图


func testHistogram() {
    group("直方图")
    expectEqual(TempHistogram.bucketIndex(for: 0), 0, "下界并入首桶")
    expectEqual(TempHistogram.bucketIndex(for: 40), 0, "40->桶0")
    expectEqual(TempHistogram.bucketIndex(for: 42), 1, "42->桶1")
    expectEqual(TempHistogram.bucketIndex(for: 80), 20, "80->桶20")
    expectEqual(TempHistogram.bucketIndex(for: 200), TempHistogram.bucketCount - 1, "上界并入末桶")
    expectEqual(TempHistogram.bucketIndex(for: -50), 0, "负温并入首桶")
    // v6: NaN/Inf/超大值 防御——Int(.infinity)/Int(1e20) 会因溢出 trap 崩溃
    expectEqual(TempHistogram.bucketIndex(for: .nan), 0, "NaN 归入首桶（不崩溃）")
    expectEqual(TempHistogram.bucketIndex(for: .infinity), 0, "Inf 归入首桶（不崩溃）")
    expectEqual(TempHistogram.bucketIndex(for: -.infinity), 0, "-Inf 归入首桶（不崩溃）")
    expectEqual(TempHistogram.bucketIndex(for: 1e20), TempHistogram.bucketCount - 1, "超大值归入末桶（不崩溃）")
    for i in 0..<TempHistogram.bucketCount {
        expectEqual(TempHistogram.bucketIndex(for: TempHistogram.midTemp(of: i)), i, "中值回落桶\(i)")
    }
    var d = DailyStats(date: "2026-07-30")
    expect(d.tempHistogram == nil, "初始无直方图")
    d.addTempSample(63, seconds: 3); d.addTempSample(63, seconds: 3); d.addTempSample(81, seconds: 3)
    let h = d.tempHistogram!
    expectEqual(h.count, TempHistogram.bucketCount, "直方图长度")
    expectClose(h[TempHistogram.bucketIndex(for: 63)], 6, 1e-9, "63°累计 6s")
    expectClose(h.reduce(0, +), 9, 1e-9, "总秒数守恒")
    // 错误长度自愈
    var d2 = DailyStats(date: "x"); d2.tempHistogram = [1, 2, 3]
    d2.addTempSample(70, seconds: 3)
    expectEqual(d2.tempHistogram!.count, TempHistogram.bucketCount, "错误长度重建")
    expectClose(d2.tempHistogram!.reduce(0, +), 3, 1e-9, "重建后仅新样本")

    // v3.5.1（对抗审查第 5 点）：天数合并/评估窗语义从 App 提取为纯函数后的契约锁定
    // ——此前这三条规则是 FanModel private inline，App target 结构上零测试覆盖
    do {
        var yst = DailyStats(date: "2026-09-03"); yst.tempCount = 100; yst.tempSum = 6000
        var today = DailyStats(date: "2026-09-05"); today.tempCount = 10; today.tempSum = 550
        let hist = [yst, today]   // 归档文件里昨日条目 + 今日条目并存（daemon 未重写 history 时）

        // 同日替换：today 赢（实时值覆盖当日归档值）
        let merged = [DailyStats].mergingToday(hist, today: DailyStats(date: "2026-09-05"))
        expectEqual(merged.count, 2, "同日合并不增条目")
        expectEqual(merged.last!.date, "2026-09-05", "同日替换后仍在末位")

        // 新一天零样本（tempCount==0）：不追加——保留历史末位（昨日），防止空态显示昨天数据
        let emptyToday = DailyStats(date: "2026-09-06")   // tempCount == 0
        let merged2 = [DailyStats].mergingToday([yst], today: emptyToday)
        expectEqual(merged2.count, 1, "零样本不追加")
        expectEqual(merged2[0].date, "2026-09-03", "昨日条目原样保留")

        // today == nil：等价于无操作
        expectEqual([DailyStats].mergingToday(hist, today: nil).count, 2, "nil 今日原样返回")

        // 评估窗：严格大于基线日（基线当天 = 改前快照，必须排除）
        let window = hist.after(baselineDate: "2026-09-03")
        expectEqual(window.count, 1, "基线日当天被排除")
        expectEqual(window[0].date, "2026-09-05", "评估窗只含晚于基线日的天")
        expect([DailyStats]().after(baselineDate: "2026-09-01").isEmpty, "空序列→空窗")
    }
}


// MARK: - 优化器


func testOptimizer() {
    group("优化器")
    // 数据不足
    expect(CurveOptimizer.optimize(days: []) == nil, "空数据 nil")
    expect(CurveOptimizer.optimize(days: [makeDay("d", center: 55, spread: 6, hours: 0.2, maxT: 70, hotRatio: 0)]) == nil, "不足30min nil")
    expect(CurveOptimizer.optimize(days: [DailyStats(date: "a"), DailyStats(date: "b")]) == nil, "全空天 nil")

    // 各类机器
    if let r = CurveOptimizer.optimize(days: [makeDay("d", center: 50, spread: 5, hours: 8, maxT: 72, hotRatio: 0)]) {
        expectAllPresetsGood(r, "凉爽机")
    } else { expect(false, "凉爽机应有结果") }

    let normal = (1...7).map { makeDay("2026-07-2\($0)", center: 60, spread: 7, hours: 6, maxT: 85, hotRatio: 0.03) }
    if let r = CurveOptimizer.optimize(days: normal) { expectAllPresetsGood(r, "中载机") }
    else { expect(false, "中载机应有结果") }

    let hot = (1...7).map { makeDay("2026-07-2\($0)", center: 65, spread: 9, hours: 6, maxT: 96, hotRatio: 0.15) }
    if let r = CurveOptimizer.optimize(days: hot) {
        expectAllPresetsGood(r, "高压机")
        expect(r.presetCurves[.balanced]!.last!.temp <= 88, "高压机抢跑：全速点≤88°")
    } else { expect(false, "高压机应有结果") }

    if let r = CurveOptimizer.optimize(days: [makeDay("d", center: 45, spread: 4, hours: 10, maxT: 52, hotRatio: 0)]) {
        expectAllPresetsGood(r, "极端凉")
    } else { expect(false, "极端凉应有结果") }

    let extreme = (1...5).map { makeDay("2026-07-2\($0)", center: 82, spread: 6, hours: 8, maxT: 99, hotRatio: 0.5) }
    if let r = CurveOptimizer.optimize(days: extreme) { expectAllPresetsGood(r, "常年高温") }
    else { expect(false, "常年高温应有结果") }

    // 退化路径（无直方图）
    var legacy = DailyStats(date: "2026-07-30")
    legacy.maxTemp = 84; legacy.tempCount = 6000; legacy.tempSum = 58 * 6000; legacy.highTempSeconds = 300
    if let r = CurveOptimizer.optimize(days: [legacy]) { expectAllPresetsGood(r, "退化路径") }
    else { expect(false, "退化路径应可用") }

    // 混合数据
    var leg2 = DailyStats(date: "2026-07-20")
    leg2.maxTemp = 80; leg2.tempCount = 5000; leg2.tempSum = 57 * 5000; leg2.highTempSeconds = 200
    let mixed = [leg2, makeDay("2026-07-28", center: 62, spread: 7, hours: 5, maxT: 88, hotRatio: 0.04)]
    if let r = CurveOptimizer.optimize(days: mixed) { expectAllPresetsGood(r, "混合数据") }
    else { expect(false, "混合数据应有结果") }
}


// MARK: - 配置校验 + Codable


func testConfigAndCodable() {
    group("配置校验")
    expectEqual(FanConfig(mode: .curve, curve: [], preset: .aggressive).sanitized().curve,
                CurvePreset.aggressive.points, "空曲线回退预设")
    expectEqual(FanConfig(mode: .curve, curve: [CurvePoint(temp: 60, percent: 30)], preset: .quiet).sanitized().curve,
                CurvePreset.quiet.points, "单点回退预设")
    expectEqual(FanConfig(mode: .curve, curve: [], preset: nil).sanitized().curve,
                CurvePreset.balanced.points, "nil 预设回退均衡")
    expect(FanConfig(mode: .curve, preset: .balanced, batteryPreset: .quiet,
                     batteryCurve: [CurvePoint(temp: 60, percent: 30)]).sanitized().batteryCurve == nil,
           "坏电池曲线清空")
    let good = CurvePreset.balanced.points
    expectEqual(FanConfig(mode: .curve, curve: good, preset: .balanced).sanitized().curve, good, "合法曲线不变")
    // v8: 曲线点逐点防御——percent 越界/NaN 被钳位，不再透传到 shape 污染输出
    do {
        let bad = [CurvePoint(temp: 52, percent: 450),
                   CurvePoint(temp: 62, percent: -10),
                   CurvePoint(temp: 70, percent: .nan),
                   CurvePoint(temp: 80, percent: 100)]
        let s = FanConfig(mode: .curve, curve: bad).sanitized()
        expectEqual(s.curve[0].percent, 100, "percent=450 钳到 100")
        expectEqual(s.curve[1].percent, 0, "percent=-10 钳到 0")
        expectEqual(s.curve[2].percent, 0, "NaN percent 钳到 0")
        expectEqual(s.curve[3].percent, 100, "合法值保留")
    }

    group("Codable")
    do {
        let cfg = FanConfig(mode: .curve, manualPercent: 66, curve: CurvePreset.aggressive.points,
                            preset: .custom, batteryPreset: .quiet, batteryCurve: CurvePreset.quiet.points)
        let back = try JSONDecoder().decode(FanConfig.self, from: try JSONEncoder().encode(cfg))
        expect(cfg == back, "FanConfig 往返(含 batteryCurve)")

        // v8: boostUntil 往返 + 旧 config 兼容（无该字段 → nil）
        let enc2 = JSONEncoder(); enc2.dateEncodingStrategy = .iso8601
        let dec2 = JSONDecoder(); dec2.dateDecodingStrategy = .iso8601
        let boostCfg = FanConfig(mode: .manual, manualPercent: 100,
                                 boostUntil: Date(timeIntervalSince1970: 1_900_000_000))
        let boostBack = try dec2.decode(FanConfig.self, from: try enc2.encode(boostCfg))
        expect(boostBack.boostUntil == boostCfg.boostUntil, "boostUntil iso8601 往返")
        let legacyCfg = #"{"mode":"manual","manualPercent":100,"curve":[{"temp":52,"percent":0},{"temp":85,"percent":100}]}"#.data(using: .utf8)!
        let lc2 = try dec2.decode(FanConfig.self, from: legacyCfg)
        expect(lc2.boostUntil == nil, "旧 config 无 boostUntil 兼容")

        // v8: DaemonStatus powerWatts 往返 + 旧 status 兼容
        let stP = DaemonStatus(sensors: SensorReadings(cpuDie: 70, gpuDie: 55), mode: .ai,
                               appliedPercent: 40, fans: [], powerWatts: 32.5)
        let stBack = try dec2.decode(DaemonStatus.self, from: try enc2.encode(stP))
        expect(stBack.powerWatts == 32.5, "powerWatts 往返")
        let legacyStatus = #"{"cpuTemp":70,"gpuTemp":55,"mode":"curve","appliedPercent":45,"fans":[],"timestamp":"2026-07-31T10:00:00Z"}"#.data(using: .utf8)!
        let ls2 = try dec2.decode(DaemonStatus.self, from: legacyStatus)
        expect(ls2.powerWatts == nil, "旧 status 无 powerWatts 兼容")

        let legacy = #"{"mode":"curve","manualPercent":50,"curve":[{"temp":52,"percent":0},{"temp":85,"percent":100}]}"#.data(using: .utf8)!
        let lc = try JSONDecoder().decode(FanConfig.self, from: legacy)
        expect(lc.batteryPreset == nil && lc.batteryCurve == nil && lc.curve.count == 2, "旧 config 兼容")

        var s = DailyStats(date: "2026-07-30"); s.maxTemp = 91.5
        s.tempSum = 55000; s.tempCount = 1000; s.highTempSeconds = 120; s.addTempSample(70, seconds: 3)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let sb = try dec.decode(DailyStats.self, from: try enc.encode(s))
        expect(sb.tempHistogram == s.tempHistogram && sb.maxTemp == 91.5, "DailyStats 往返(含直方图)")

        let legStats = #"{"date":"2026-07-01","maxTemp":80,"maxTempAt":"2026-07-01T10:00:00Z","highTempSeconds":60,"tempSum":50000,"tempCount":1000,"revolutions":123}"#.data(using: .utf8)!
        let ls = try dec.decode(DailyStats.self, from: legStats)
        expect(ls.tempHistogram == nil && ls.tempCount == 1000, "旧战报兼容")

        let st = DaemonStatus(cpuTemp: 70, gpuTemp: 55, mode: .manual, appliedPercent: 80,
                              fans: [FanStatusEntry(id: 0, actualRPM: 3000, targetRPM: 3100, minRPM: 1200, maxRPM: 5000)],
                              onBattery: true, batteryOverride: false)
        let stb = try dec.decode(DaemonStatus.self, from: try enc.encode(st))
        expect(stb.cpuTemp == 70 && stb.mode == .manual && stb.onBattery == true, "DaemonStatus 往返")
    } catch {
        expect(false, "Codable 抛错: \(error)")
    }
}


// MARK: - 日期链（跨天归档/保留期/AI效果比较的地基）


func testDateChain() {
    group("日期链")
    let t = DailyStats.today()
    // 格式必须为 yyyy-MM-dd 且是合理公历年（系统日历设为佛历/和历也不能变）
    let parts = t.split(separator: "-")
    expectEqual(parts.count, 3, "today() 分段数")
    expectEqual(t.count, 10, "today() 长度固定 10")
    if let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
        expect(y >= 2020 && y <= 2120, "公历年合理（非佛历 2569 类）: \(y)")
        expect(m >= 1 && m <= 12, "月合法")
        expect(d >= 1 && d <= 31, "日合法")
    } else { expect(false, "today() 含非数字: \(t)") }
    // 字典序即时间序（归档裁剪/基准日比较都依赖此性质）
    expect("2026-08-01" > "2026-07-31" && "2027-01-01" > "2026-12-31", "字典序=时间序")
}


func testPowerHistogram() {
    group("功耗直方图")
    expectEqual(PowerHistogram.bucketIndex(for: 0.5), 0, "0.5W → 桶 0")
    expectEqual(PowerHistogram.bucketIndex(for: 3), 1, "3W → 桶 1")
    expectEqual(PowerHistogram.bucketIndex(for: 61), 29, "61W 并入尾桶")
    expectEqual(PowerHistogram.bucketIndex(for: .nan), 0, "NaN → 桶 0")
    var d = DailyStats(date: "2026-09-01")
    d.addPowerSample(25, seconds: 700); d.addPowerSample(26, seconds: 700); d.addPowerSample(45, seconds: 700)
    let h = d.powerHistogram!
    expectEqual(h.count, PowerHistogram.bucketCount, "桶数")
    expectClose(h.reduce(0, +), 2100, 1e-9, "总秒数守恒")
    d.addPowerSample(.nan, seconds: 700)
    expectClose(d.powerHistogram!.reduce(0, +), 2100, 1e-9, "NaN 不入桶")
    // P50 计算（2100s ≥ 30min 门槛；前两桶累计 1400s 过半 → 桶 13 内插值）
    expectClose(CurveOptimizer.powerP50([d])!, 27.0, 0.01, "P50 = 27.0W")
    // Codable 兼容（日期策略必须 iso8601，与 ConfigStore 一致）
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let back = try! dec.decode(DailyStats.self, from: enc.encode(d))
    expectEqual(back.powerHistogram!, h, "powerHistogram 往返")
    let legacy = #"{"date":"2026-08-01","maxTemp":60,"maxTempAt":"2026-08-01T10:00:00Z","highTempSeconds":0,"tempSum":60,"tempCount":1,"revolutions":0}"#.data(using: .utf8)!
    expectEqual(try! dec.decode(DailyStats.self, from: legacy).powerHistogram, nil, "旧战报兼容")
}


// MARK: - v2.9 优化器反漂移（闭环自指的锚点限幅）


func testCurveAntiDrift() {
    group("优化器反漂移")
    let days = (1...7).map { makeDay("2026-08-2\($0)", center: 60, spread: 7, hours: 6, maxT: 85, hotRatio: 0.03) }
    let first = CurveOptimizer.optimize(days: days)!
    expectLegal(first.points, "首次应用合法")

    // cooler 数据（p50 下降 → 锚点想左移）+ 热压力不变 → 限幅 0.5°/周期
    let coolerDays = (1...7).map { makeDay("2026-08-2\($0)", center: 57, spread: 7, hours: 6, maxT: 82, hotRatio: 0.01) }
    let second = CurveOptimizer.optimize(days: coolerDays, previous: first.presetCurves,
                                         previousHotRatio: 0.03)!
    let b1 = first.presetCurves[.balanced]!, b2 = second.presetCurves[.balanced]!
    expect(b2[0].temp < b1[0].temp, "cooler 数据确实想下移（\(b1[0].temp)→\(b2[0].temp)）")
    for i in 0..<5 {
        expect(b2[i].temp >= b1[i].temp - 0.51,
               "锚点\(i) 下移受 0.5°/周期 阻尼（\(b1[i].temp)→\(b2[i].temp)）")
    }
    expectLegal(b2, "阻尼后仍合法（shape 修复单调性）")

    // 闸门判定纯函数
    expectEqual(CurveOptimizer.anchorDropLimit(currentHotRatio: 0.05, previousHotRatio: 0.03), 1.5, "热压力 +2pp → 1.5°")
    expectEqual(CurveOptimizer.anchorDropLimit(currentHotRatio: 0.035, previousHotRatio: 0.03), 0.5, "热压力 +0.5pp（<1pp 门槛）→ 0.5°")
    expectEqual(CurveOptimizer.anchorDropLimit(currentHotRatio: 0.02, previousHotRatio: 0.03), 0.5, "热压力下降 → 0.5°")
    expectEqual(CurveOptimizer.anchorDropLimit(currentHotRatio: 0.05, previousHotRatio: nil), 0.5, "基线缺失保守 0.5°")

    // 热压力大幅上升（center 82 高斯 ≥80° 桶占比 ≈59% ≫ 0.03+1pp）→ 1.5°/周期。
    // 正向断言：必须存在锚点下移超过 0.5°——证明 1.5 分支真实生效（删掉它会红）
    let hotDays = (1...7).map { makeDay("2026-08-2\($0)", center: 82, spread: 9, hours: 6, maxT: 96, hotRatio: 0.15) }
    let hot = CurveOptimizer.optimize(days: hotDays, previous: first.presetCurves,
                                      previousHotRatio: 0.03)!
    let b3 = hot.presetCurves[.balanced]!
    expect(hot.hotRatio > 0.04, "热数据直方图 hotRatio 达门槛（得 \(hot.hotRatio)）")
    expect(b3.enumerated().contains { $0.element.temp <= b1[$0.offset].temp - 0.51 },
           "存在锚点下移 >0.5°（1.5° 分支真实生效）")
    for i in 0..<5 {
        expect(b3[i].temp >= b1[i].temp - 1.51,
               "热压力上升锚点\(i) 限幅 1.5°（\(b1[i].temp)→\(b3[i].temp)）")
    }
    expectLegal(b3, "热压力路径合法")

    // 无 previous（首次）→ 完全不限幅
    let bare = CurveOptimizer.optimize(days: days)!
    expectEqual(bare.points, first.points, "首次应用与旧行为一致")

    // v3.3 功耗锚定门控：温度分位下移而负载未变 → 自降温，下移压到 0.25°/周期
    func powerDays(_ center: Double, _ maxT: Double) -> [DailyStats] {
        (1...7).map { i in
            var d = makeDay("2026-08-2\(i)", center: center, spread: 7, hours: 6, maxT: maxT, hotRatio: 0.01)
            var h = [Double](repeating: 0, count: PowerHistogram.bucketCount)
            h[12] = 6 * 3600   // 负载集中在 ~25W
            d.powerHistogram = h
            return d
        }
    }
    let coolBase = powerDays(60, 85)
    let first2 = CurveOptimizer.optimize(days: coolBase)!
    expectClose(first2.powerP50!, 25.0, 0.1, "powerP50 从直方图计算（得 \(first2.powerP50!)）")
    let cooler2 = powerDays(57, 82)
    let gated = CurveOptimizer.optimize(days: cooler2, previous: first2.presetCurves,
                                        previousHotRatio: 0.03, previousPowerP50: 25.5)!
    let g2 = gated.presetCurves[.balanced]!
    for i in 0..<5 {
        expect(g2[i].temp >= first2.presetCurves[.balanced]![i].temp - 0.26,
               "负载未变 → 锚点\(i)下移压到 0.25°（\(first2.presetCurves[.balanced]![i].temp)→\(g2[i].temp)）")
    }
    // 负载变化（25.5→40W，超过 max(2, 15%) 门槛）→ 正常热压力门控（0.5°）
    let loadShift = CurveOptimizer.optimize(days: cooler2, previous: first2.presetCurves,
                                            previousHotRatio: 0.03, previousPowerP50: 40)!
    let l2 = loadShift.presetCurves[.balanced]!
    expect(l2[0].temp < first2.presetCurves[.balanced]![0].temp - 0.26,
           "负载变化 → 放开 0.5° 下移（\(first2.presetCurves[.balanced]![0].temp)→\(l2[0].temp)）")
    expectLegal(g2, "功耗门控路径合法")

    // v3.3 功耗门控不覆盖热压力快速通道：功耗未变 + 热压力大幅上升 → 仍 1.5°/周期
    let hotPow = (1...7).map { i -> DailyStats in
        var d = makeDay("2026-08-2\(i)", center: 82, spread: 9, hours: 6, maxT: 96, hotRatio: 0.15)
        var h = [Double](repeating: 0, count: PowerHistogram.bucketCount)
        h[12] = 6 * 3600
        d.powerHistogram = h
        return d
    }
    let hp = CurveOptimizer.optimize(days: hotPow, previous: first.presetCurves,
                                     previousHotRatio: 0.03, previousPowerP50: 25.5)!
    expect(hp.powerP50! > 0.04, "功耗 P50 已计算（得 \(hp.powerP50!)）")
    let hb1 = first.presetCurves[.balanced]!
    expect(hp.presetCurves[.balanced]!.enumerated().contains { $0.element.temp <= hb1[$0.offset].temp - 0.51 },
           "功耗未变 + 热压力上升 → 1.5° 快速通道仍生效（未被功耗门控覆盖）")
}


// MARK: - v3.4 powermetrics golden 样本解析（外部依赖加固）
//
// powermetrics 文本输出是全项目最脆的外部面（Apple 不保证稳定；已踩 -u W 与
// 千分位两个坑）。本组测试用真实输出样本 + 已知坏格式锁定解析契约：
//   - macOS 26 真实格式（含 P/E-Cluster 干扰行、多样本取最后、0 mW）
//   - 旧版格式
//   - 完全无法解析（报错输出）→ nil → 调用方退回整机 PSTR 前馈 + 日志
// golden 样本在 Fixtures/ 目录，用 #filePath 定位（零资源声明开销）。

func goldenFixture(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // Sources/fanctltests/
        .appendingPathComponent("Fixtures/\(name)")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

func testPowerMetricsGolden() {
    group("powermetrics golden 样本")
    // macOS 26 真实输出：多样本取最后、P/E-Cluster 干扰行忽略、mW 换算
    let m26 = goldenFixture("powermetrics-macos26.golden")
    expect(!m26.isEmpty, "golden 样本可读取")
    expectClose(PowerMetricsParser.watts(in: m26, key: "CPU Power:")!, 3.890, 1e-6,
                "macOS26 CPU：多样本取最后（3890 mW）")
    expectClose(PowerMetricsParser.watts(in: m26, key: "GPU Power:")!, 0.012, 1e-6,
                "macOS26 GPU：第二样本 12 mW")
    // E-Cluster 行不得被误认为 CPU Power
    expect(PowerMetricsParser.watts(in: m26, key: "Cluster Power:") != 0.812,
           "Cluster 干扰行不误匹配（子串 key 的边界）")
    // 旧版格式
    let legacy = goldenFixture("powermetrics-legacy.golden")
    expectClose(PowerMetricsParser.watts(in: legacy, key: "CPU Power:")!, 2.345, 1e-6, "旧版 CPU")
    expectClose(PowerMetricsParser.watts(in: legacy, key: "GPU Power:")!, 0.890, 1e-6, "旧版 GPU")
    // 坏格式：usage/error 输出 → nil（调用方退回整机 PSTR）
    let broken = goldenFixture("powermetrics-broken.golden")
    expectEqual(PowerMetricsParser.watts(in: broken, key: "CPU Power:"), nil, "报错输出 → nil")
    expectEqual(PowerMetricsParser.watts(in: "", key: "CPU Power:"), nil, "空输出 → nil")
    // 单位歧义行：无单位裸数字按 W 采信（与修复前一致——真实输出恒有单位）
    expectClose(PowerMetricsParser.watts(in: "CPU Power: 45", key: "CPU Power:")!, 45, 1e-9, "无单位按 W")
}
