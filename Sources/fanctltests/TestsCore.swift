// 测试按模块拆分（v3.3.1）：本文件为各模块共享的 harness 与主入口。
// 断言 harness 见 main.swift，共享构造（MockSMC/FakeClock/makeEngine）见 TestsEngine.swift 头部。
import Foundation
import Darwin
import SMCCore

// MARK: - 曲线插值


// R47：UI 动画静态门（源码级）。观感类断言跑不了 CI 里的 GUI，但"谁在每拍被补间"
// 是可以在源码里钉死的事实。三条都在防"复现一次就再也说不清"的回归：
//   1) FanRow 的每拍数字不得再用 numericText（高频数字转场=看着缩小 + 字形位图膨胀）；
//   2) fans 赋值不得再被 withAnimation 包住（事务级动画把整棵子树拖进补间）；
//   3) 风扇图标尺寸只有一个来源（fanSpinnerSide），调用方不得再套 frame。
func testUIAnimationGuards() {
    group("UI 动画静态门(R47)")
    // TestsCore.swift 在 <root>/Sources/fanctltests/ → 上溯三层才是仓库根
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func source(_ rel: String) -> String? {
        guard let s = try? String(contentsOfFile: root.appendingPathComponent(rel).path,
                                  encoding: .utf8) else {
            expect(false, "静态门读不到 \(rel)（源码缺席必须判红，不得空转）")
            return nil
        }
        return s
    }
    guard let gauge = source("Sources/FanCtlApp/GaugeViews.swift"),
          let model = source("Sources/FanCtlApp/FanModel.swift") else { return }
    let row = String(gauge[gauge.range(of: "struct FanRow: View")!.lowerBound...])
    // 次数用 components 数，不用 filter（filter 在 String 上逐 Character 迭代，$0.contains 不存在）
    expectEqual(row.components(separatedBy: ".contentTransition(.numericText())").count - 1, 0,
                "FanRow 之后 numericText 出现次数=0（每拍数字不做转场）")
    expect(row.contains("FanSpinner(rpm: fan.actualRPM, tint: .blue)"),
           "FanRow 用带默认 tint 的构造器（调用方不再自选尺寸）")
    // 精确判"调用点下一行"，不判整段文件（.frame(width: 22) 在别的视图里是合法尺寸）
    let glines = row.split(separator: "\n").map(String.init)
    if let i = glines.firstIndex(where: { $0.contains("FanSpinner(rpm:") }) {
        let nxt = i + 1 < glines.count
            ? glines[i + 1].trimmingCharacters(in: .whitespaces) : ""
        expect(!nxt.hasPrefix(".frame("), "FanSpinner 调用点下一行不得再套 frame（尺寸单一来源）")
    } else {
        expect(false, "找不到 FanSpinner 调用点（门空转即红）")
    }
    let mon = source("Sources/FanCtlApp/MonitorViews.swift") ?? ""
    expect(!mon.contains("contentTransition(.numericText()).animation(.snappy, value: p.cpu)"),
           "逐项功耗百分比不挂数字转场（每拍抖动的量，与 RPM 同族）")
    expectEqual(gauge.components(separatedBy: "frame(width: fanSpinnerSide").count - 1, 1,
                "图标边长只在 FanSpinner 内部出现一次")
    expect(model.contains("self.fans = fanStates"), "fans 仍被赋值（门不是靠删功能变绿）")
    expect(!model.contains("withAnimation(.snappy(duration: 0.25)) { self.fans ="),
           "fans 赋值不包 withAnimation")

    // R51 补三条可绕路径（R50 记账的原文）：
    // ① 只切 "struct FanRow" 之后的文本 → 把转速数字搬进前置/独立子视图即绕；
    //    改为按**数据源**判：任何读 actualRPM / loadFraction 的 Text 之后 3 行内不得出现转场。
    // ② 精确字面量 → `.numericText(countsDown:)` 或换行写法即绕；
    //    改为剥注释 + 去空白后按前缀 "contentTransition(.numericText" 匹配。
    // ③ fans 那条只钉字面 "withAnimation…{ self.fans =" → 把赋值搬进 assign() 即原样复活；
    //    改为钉 withAnimation 的**总预算**（死数字），新增一处就红。
    func codeOnly(_ s: String) -> [String] {
        s.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
    func flat(_ s: String) -> String {
        codeOnly(s).joined().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }
    let viewDir = root.appendingPathComponent("Sources/FanCtlApp")
    let viewFiles = (try? FileManager.default.contentsOfDirectory(atPath: viewDir.path))?.sorted() ?? []
    expectEqual(viewFiles.filter { $0.hasSuffix(".swift") }.count, 11,
                "FanCtlApp 视图文件数=11（死数字：新增文件会同时进下面的转场预算）")
    var transTotal = 0
    for f in viewFiles where f.hasSuffix(".swift") {
        guard let src = source("Sources/FanCtlApp/\(f)") else { return }
        let n = flat(src).components(separatedBy: "contentTransition(.numericText").count - 1
        transTotal += n
        // 逐文件死预算：加一处即红，**搬到别的文件/独立子视图也红**（绕路径①的完整版）
        let expectN: Int
        switch f {
        case "GaugeViews.swift": expectN = 1
        case "MonitorViews.swift": expectN = 2
        case "PanelView.swift": expectN = 7
        default: expectN = 0
        }
        expectEqual(n, expectN, "\(f) 的 numericText 处数=\(expectN)（每拍数字不做转场）")
        let lines = codeOnly(src)
        for (i, ln) in lines.enumerated() where ln.contains("Text(")
            && (ln.contains("actualRPM") || ln.contains("loadFraction")) {
            let window = lines[i..<min(lines.count, i + 4)].joined()
            expect(!window.contains("contentTransition(.numericText"),
                   "\(f):\(i + 1) 每拍数字（转速/占比）不挂转场——换宿主视图也一样红")
        }
    }
    expectEqual(transTotal, 10, "全面板 numericText 总数=10（死预算：新文件里加一处也红）")
    expectEqual(flat(model).components(separatedBy: "withAnimation").count - 1, 3,
                "FanModel 的 withAnimation 总数=3（死预算：新增一处事务级动画即红）")
    // :722 的 `withAnimation(.snappy(0.25)) { assign() }` **刻意不设反断言**：R51 用
    // --tickbench 量过（每拍 CPU：留着 804/818/834ms vs 撤掉 848/867ms，差在噪声内；
    // 玻璃换实心、主温度去渐变/辉光同样不动），撤它换不来成本，只会改掉作者钉过的
    // 温度数字转场观感。预算门（上一条）仍然守着"别再加第四处"。
}

/// R51：--tickbench 渲染量具的安全边界。它是**发行二进制里的调试入口**，
/// 所以"只读真夹具、写盘落临时目录"不能靠注释承诺，必须有机器的牙。
func testTickBenchSafety() {
    group("渲染量具安全门(R51)")
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func codeOnly(_ rel: String) -> String? {
        guard let s = try? String(contentsOfFile: root.appendingPathComponent(rel).path,
                                  encoding: .utf8) else {
            expect(false, "静态门读不到 \(rel)（源码缺席必须判红，不得空转）")
            return nil
        }
        return s.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }
    guard let bench = codeOnly("Sources/FanCtlApp/TickBench.swift"),
          let appEntry = codeOnly("Sources/FanCtlApp/FanCtlApp.swift") else { return }
    // ① 不许出现真实数据目录的字面量：所有写盘必须走覆盖后的临时目录
    expect(!bench.contains("/Library/Application Support"),
           "量具里不得硬编码真实 support 目录（写盘只能落临时目录）")
    // ② 顺序前提：先重定向路径，再构造 FanModel（否则 watch/config 读写打在真目录上）
    let iOverride = bench.range(of: "setOverridesForTesting")?.lowerBound
    let iModel = bench.range(of: "FanModel()")?.lowerBound
    guard let o = iOverride, let m = iModel else {
        expect(false, "量具缺少 setOverridesForTesting 或 FanModel() 锚点（改名要连门一起改）")
        return
    }
    expect(o < m, "必须先重定向路径再建 FanModel（否则首拍就碰真实 /Library）")
    // ③ 接线自证：入口真的被调用（存在性反断言不算牙，见 R47 教训）
    expect(appEntry.contains("--tickbench") && appEntry.contains("TickBench.run()"),
           "--tickbench 入口已接线到 App 启动路径")
    // ④ 量具有"不测空气"的守卫：夹具读不到必须 exit 非零，不能静默出 0 成本
    expect(bench.contains("ABORT=no-fixture") && bench.contains("exit(2)"),
           "夹具缺席时量具判废退出（不做空气门）")
}

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

    // R29/R32：speedChangesPerMinute 磨损速率口径（批次 B 控制律延后的裁决探针）
    do {
        var d = DailyStats(date: "2026-09-21")
        expectEqual(d.speedChangesPerMinute, 0, "无采样秒 → 0")
        d.tempSeconds = 30; d.speedChanges = 10
        expectEqual(d.speedChangesPerMinute, 0, "采样秒≤0.5 分 → 0（防抖）")
        d.tempSeconds = 120; d.speedChanges = 30
        expectClose(d.speedChangesPerMinute, 15, 1e-9, "30次/2分 = 15/min")
        d.tempSeconds = 600; d.speedChanges = 30
        expectClose(d.speedChangesPerMinute, 3, 1e-9, "30次/10分 = 3/min（拍频归一）")
        var bad = DailyStats(date: "x"); bad.tempSeconds = 120; bad.speedChanges = .nan
        expectEqual(bad.speedChangesPerMinute, 0, "非有限 speedChanges → 0")
        var bad2 = DailyStats(date: "y"); bad2.tempSeconds = .infinity; bad2.speedChanges = 10
        expectEqual(bad2.speedChangesPerMinute, 0, "非有限 tempSeconds → 0")
        // R45：单位串单一真值 + 两个 surface 的静态接线门。
        // 动因：同一个 speedChangesPerMinute 在诊断包里印"次/采样分"、在 fanprobe 的
        // 今日战报里印"次/受控分"，而分母其实是采样秒（StatsSampler 对每个有效温度样本
        // 累加）——它是批次 B 控制律延后裁决的读数，口径标签不能两处各说一套。
        // 读不到源码一律判红（R41 教训：查不到就静默跳过 = 门自己变空气）。
        expectEqual(DailyStats.wearRateUnit, "次/采样分", "单位串唯一真值=采样分（分母 tempSeconds）")
        // #filePath = <root>/Sources/fanctltests/TestsCore.swift → 上溯三层到仓库根，
        // 并把"根必须有 Package.swift"当前提断言（层数写错必须判红，不许静默读不到）
        let wearRateCallSites = ["Sources/fanprobe/main.swift": 2,
                                 "Sources/SMCCore/DiagnosticReport.swift": 1]
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        expect(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path),
               "接线门的仓库根定位必须命中 Package.swift（层数错=空气门）")
        for rel in ["Sources/fanprobe/main.swift", "Sources/SMCCore/DiagnosticReport.swift"] {
            let path = repoRoot.appendingPathComponent(rel).path
            guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                expect(false, "接线门读不到 \(rel)（源码缺席必须判红，不得空转）")
                continue
            }
            // 按**代码行**里出现该常量的次数判（剥掉 // 开头的行再数）：本文件注释里
            // 曾提到过常量名，把"contains"满足掉而删掉真正的打印行仍会绿——半颗牙。
            let codeOnly = src.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }.joined(separator: "\n")
            expectEqual(codeOnly.components(separatedBy: "DailyStats.wearRateUnit").count - 1,
                        wearRateCallSites[rel] ?? -1, "接线处数不符（注释凑数不算）: " + rel)
            expect(!src.contains("次/受控"), "\(rel) 不再硬编码错口径")
            expect(!src.contains("\"次/采样分\""), "\(rel) 不重复硬编码单位串（保持单一来源）")
        }
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
    // R23（P2-2）：数组长度上限——组内用户写超长曲线会让每拍 percent() 排序 O(n log n)
    // 拖爆主队列看门狗（自杀-重启死循环）。>64 点视为攻击，回退预设；偏移 >8 截断。
    do {
        let huge = (0..<1000).map { CurvePoint(temp: 40.0 + Double($0) * 0.05,
                                               percent: Double($0 % 100)) }
        let s = FanConfig(mode: .curve, curve: huge, preset: .balanced).sanitized()
        expect(s.curve.count <= 64, "超长曲线（1000 点）被拒→回退预设（≤64）")
        expectEqual(s.curve, CurvePreset.balanced.points, "超长曲线精确回退均衡预设")
        let offsets = Array(repeating: 5.0, count: 500)
        let s2 = FanConfig(mode: .ai, fanOffsets: offsets).sanitized()
        // R23 再审（A2）：精确断言保留的是"前 8 个"（prefix 语义）——`?? 0`/仅查 count
        // 会让"置 nil"或"截到 6 个"两个变异存活
        expectEqual(s2.fanOffsets, Array(repeating: 5.0, count: 8), "超长 fanOffsets 截断保留前 8 个")
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

// R23 再审（变异审查 B1，P1）：saveConfig 的 fd 级写 + fchmod + rename 语义此前零测试——
// 本轮刚修的 umask 掩码回归（open mode 被削成 644 → App 失去写权限）与 P1 提权修复
// （rename 替换符号链接而非跟随）都无回归质。锁三条不变量：正常写 mode==664；config.json
// 是符号链接时 rename 替换链接本身、目标文件纹丝不动；成功路径无临时残留。
func testSaveConfigPermissions() {
    group("saveConfig 权限/符号链接")
    let dir = engineTestEnv()
    defer {
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        try? FileManager.default.removeItem(at: dir)
    }
    let fm = FileManager.default
    expect(ConfigStore.saveConfig(FanConfig(mode: .curve, curve: CurvePreset.balanced.points, preset: .balanced)),
           "saveConfig 成功")
    let mode = ((try? fm.attributesOfItem(atPath: FanCtlPaths.configFile.path))?[.posixPermissions]) as? Int
    expectEqual(mode ?? -1, 0o664, "config.json mode==664（fchmod 穿透 umask；删 fchmod 且 umask 022 则 644→红）")
    // 符号链接场景：把 config.json 换成指向 victim 的软链，saveConfig 的 rename 必须替换
    // 链接本身而非跟随写进 victim——否则 root 把任意文件改 664 就是提权原语
    let victim = dir.appendingPathComponent("victim.txt")
    try? "SECRET".data(using: .utf8)!.write(to: victim)
    try? fm.removeItem(at: FanCtlPaths.configFile)
    symlink(victim.path, FanCtlPaths.configFile.path)
    expect(ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced)), "符号链接场景 saveConfig 成功")
    let victimText = (try? Data(contentsOf: victim)).flatMap { String(data: $0, encoding: .utf8) }
    expectEqual(victimText ?? "?", "SECRET", "rename 未跟随符号链接：victim 内容未被覆盖（提权闭合）")
    expectEqual(ConfigStore.loadConfig().mode, .ai, "config.json 已是本次写入的常规文件（loadConfig 读到）")
    let leftovers = (try? fm.contentsOfDirectory(atPath: dir.path))?
        .filter { $0.hasPrefix(".config.json.") } ?? []
    expect(leftovers.isEmpty, "无 .config.json.<uuid> 临时残留")
}

// R28（安全 P1）：损坏备份 O_EXCL|O_NOFOLLOW——预置符号链接时不得写穿 victim
func testCorruptionBackupNoFollow() {
    group("损坏备份不跟随符号链接")
    let dir = engineTestEnv()
    FanCtlPaths.ensureDirectories()
    defer {
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        try? FileManager.default.removeItem(at: dir)
    }
    let fm = FileManager.default
    // 1) 正常新建备份
    let okURL = FanCtlPaths.supportDir.appendingPathComponent("probe.corrupted.1.json")
    expect(FanCtlPaths.writeNewFileExclusive(Data("hello".utf8), to: okURL), "正常路径可新建备份")
    expectEqual((try? String(contentsOf: okURL, encoding: .utf8)) ?? "?", "hello", "内容落盘")
    // 2) 预置符号链接 → 必须失败且 victim 不变
    let victim = dir.appendingPathComponent("p1-victim.txt")
    let secret = "SECRET".data(using: .utf8)!
    let wrote = (try? secret.write(to: victim)) != nil
    expect(wrote, "victim 写入成功")
    let linked = FanCtlPaths.supportDir.appendingPathComponent("learn.corrupted.999999.json")
    try? fm.removeItem(at: linked)
    let sl = symlink(victim.path, linked.path)
    expect(sl == 0, "预置符号链接成功")
    expect(!FanCtlPaths.writeNewFileExclusive(Data("PWNED".utf8), to: linked),
           "目标为符号链接时 writeNewFileExclusive 必须失败")
    let victimText = (try? Data(contentsOf: victim)).flatMap { String(data: $0, encoding: .utf8) }
    expectEqual(victimText ?? "?", "SECRET", "victim 未被备份写穿（P1 提权闭合）")
    // 3) 目标已存在（普通文件）→ O_EXCL 失败
    expect(!FanCtlPaths.writeNewFileExclusive(Data("X".utf8), to: okURL), "已存在文件 O_EXCL 拒绝覆盖")
    // 4) loadConfig 损坏路径仍回默认，且不污染无关 victim
    let bad = "NOT JSON {".data(using: .utf8)!
    expect((try? bad.write(to: FanCtlPaths.configFile)) != nil, "写入损坏 config")
    let cfg = ConfigStore.loadConfig()
    expectEqual(cfg.mode, FanConfig().sanitized().mode, "损坏 config 回默认")
    expectEqual((try? Data(contentsOf: victim)).flatMap { String(data: $0, encoding: .utf8) } ?? "?",
                "SECRET", "loadConfig 损坏备份未污染 pre-planted victim 类目标")
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

// MARK: - v3.6 版本语义比较（更新检查的地基，纯函数）

func testVersionCheck() {
    group("版本比较")
    expect(VersionCheck.isNewer("v3.6.0", than: "3.5.0"), "tag 带 v 前缀可解析")
    expect(VersionCheck.isNewer("3.10.0", than: "3.9.9"), "数值比较非字典序（10>9）")
    expect(VersionCheck.isNewer("3.6", than: "3.5.9"), "缺段补 0（3.6 == 3.6.0 > 3.5.9）")
    expect(!VersionCheck.isNewer("3.6.0", than: "3.6.0"), "相等不算新")
    expect(!VersionCheck.isNewer("3.5.0", than: "3.6.0"), "倒退不算新")
    expect(VersionCheck.isNewer("4.0", than: "3.99.99"), "主版本越级")
    expect(!VersionCheck.isNewer("", than: "3.5.0"), "空串当 0.0.0 不算新")
    expect(!VersionCheck.isNewer("beta-2026", than: "3.5.0"), "无数字段全 0 不算新")
    expect(VersionCheck.isNewer("3.6.0-beta.1", than: "3.5.0"), "带后缀 tag 取数字段比较")
    expect(!VersionCheck.isNewer("3.5.0", than: "3.5"), "等价版本（缺段补 0 后相等）")
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
                "macOS26 GPU：0 mW 被范围门拒绝 → 保留最后有效样本 12 mW（陈旧滞留由 PowerCompositionSampler 单侧过期兜底）")
    // v3.6.1：显式锁定"0 mW 拒绝后回退最后有效样本"语义（此前隐式契约被错误标签掩盖）
    expectClose(PowerMetricsParser.watts(in: "CPU Power: 100 mW\nCPU Power: 0 mW", key: "CPU Power:")!, 0.1, 1e-6,
                "0 mW 范围门拒绝 → 回退上一有效样本")
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

// MARK: - R35 数据诚实：配置 last-good 自愈 / history 逐日抢救 / AI 评测秒加权

/// 配置损坏自愈的目标是"最后一份能解码的配置"，不是出厂默认。
/// 同时锁定 writeAtomicFD 抽取（saveConfig 改调它）没有改变写盘语义
/// ——符号链接/权限语义由 testSaveConfigPermissions 覆盖。
func testConfigLastGood() {
    group("config last-good 自愈(R35)")
    let dir = engineTestEnv()
    defer {
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        try? FileManager.default.removeItem(at: dir)
    }
    FanCtlPaths.ensureDirectories()
    let custom = FanConfig(mode: .manual, manualPercent: 77,
                           curve: CurvePreset.aggressive.points, preset: .aggressive,
                           aiTargetTemp: 80, envCompensation: false)
    expect(ConfigStore.saveConfig(custom), "① 写入用户配置")
    expectEqual(ConfigStore.loadConfig().mode, .manual, "① 正常解码")
    expect(FileManager.default.fileExists(atPath: FanCtlPaths.configLastGoodFile.path),
           "① 解码成功后滚动出 last-good 副本")
    // ② 活文件损坏（截断/手改）→ 回用户配置，不回出厂默认
    try? "{\"mode\":\"manual\",\"curve\":[".write(to: FanCtlPaths.configFile,
                                                  atomically: true, encoding: .utf8)
    let healed = ConfigStore.loadConfig()
    expectEqual(healed.mode, .manual, "② 从 last-good 恢复模式")
    expectEqual(healed.manualPercent, 77, "② 用户百分比保留（旧实现静默变默认 50）")
    expectEqual(healed.preset, .aggressive, "② 曲线档不被抹回均衡")
    expectEqual(healed.aiTargetTemp, 80, "② AI 目标保留")
    expectEqual(ConfigStore.loadConfig().manualPercent, 77, "② 恢复结果已写回，重读仍成立")
    if let live = try? Data(contentsOf: FanCtlPaths.configFile),
       let good = try? Data(contentsOf: FanCtlPaths.configLastGoodFile) {
        expect(live == good, "② 恢复后活文件与副本一致（下次成功解码再滚动更新）")
    } else { expect(false, "② 两份文件都应存在") }
    // ③ 副本也损坏 → 默认配置仍是有界的最后退路，且不留半态
    try? "garbage".write(to: FanCtlPaths.configLastGoodFile, atomically: true, encoding: .utf8)
    try? "garbage".write(to: FanCtlPaths.configFile, atomically: true, encoding: .utf8)
    let fallback = ConfigStore.loadConfig()
    expectEqual(fallback.mode, FanConfig().sanitized().mode, "③ 无可用副本才回默认")
    expect(fallback.curve.count >= 2, "③ 默认配置自带可用曲线")
    // ④ 正常写盘不该制造残留临时文件（writeAtomicFD 的 tmp 命名被清扫逻辑覆盖）
    expect(ConfigStore.saveConfig(FanConfig(mode: .ai, aiTargetTemp: 72)), "④ 写新配置")
    let temps = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(".") }
    expect(temps.isEmpty, "④ 无 .config.* 临时残留（得 \(temps)）")
    // ⑤ R35 审查（P2）：last-good 的语义是"最后一份可用"，不是"最后一份可解码"。
    //   越界值（组内用户直写 manualPercent=450）解码是成功的，原样进副本就等于把越界
    //   配置预备成将来损坏时的"好消息"——副本必须落消毒后的字节。
    try? #"{"mode":"manual","manualPercent":450,"aiTargetTemp":0,"curve":[{"temp":52,"percent":0},{"temp":85,"percent":450}]}"#
        .write(to: FanCtlPaths.configFile, atomically: true, encoding: .utf8)
    let clamped = ConfigStore.loadConfig()
    expectEqual(clamped.manualPercent, 100, "⑤ 越界 manualPercent 被消毒钳位")
    expectEqual(clamped.aiTargetTemp, 40, "⑤ 越界 aiTargetTemp 被消毒钳位")
    if let good = try? String(contentsOf: FanCtlPaths.configLastGoodFile, encoding: .utf8) {
        expect(!good.contains("450"), "⑤ 原始越界值不得进副本")
        expect(good.contains("\"manualPercent\" : 100"), "⑤ 副本落的是消毒后字节")
    } else { expect(false, "⑤ 越界但可解码的配置仍应滚动出副本") }
    // ⑥ R35 审查：崩溃残留的原子写临时文件按家族白名单清扫——exit-reason.flag 也走
    //   writeAtomicFD 后，它的 `.exit-reason.flag.<uuid>` 必须在清扫面内；
    //   同时白名单不得扩大化误删组内用户的其它点文件。
    func touch(_ name: String, age: TimeInterval) -> URL {
        let u = dir.appendingPathComponent(name)
        try? "x".write(to: u, atomically: false, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                               ofItemAtPath: u.path)
        return u
    }
    let staleCfg = touch(".config.json.\(UUID().uuidString)", age: 7200)
    let staleGood = touch(".config.last-good.json.\(UUID().uuidString)", age: 7200)
    let staleFlag = touch(".exit-reason.flag.\(UUID().uuidString)", age: 7200)
    let fresh = touch(".config.json.\(UUID().uuidString)", age: 60)
    let foreign = touch(".not-ours.config.json", age: 7200)
    let unrelated = touch(".DS_Store", age: 7200)
    ConfigStore.cleanupStaleTemps()
    expect(!FileManager.default.fileExists(atPath: staleCfg.path), "⑥ 旧 config 临时件清掉")
    expect(!FileManager.default.fileExists(atPath: staleGood.path), "⑥ 旧 last-good 临时件清掉")
    expect(!FileManager.default.fileExists(atPath: staleFlag.path), "⑥ 旧 exit-reason 临时件清掉")
    expect(FileManager.default.fileExists(atPath: fresh.path), "⑥ 在途（<1h）临时件不动")
    expect(FileManager.default.fileExists(atPath: foreign.path)
           && FileManager.default.fileExists(atPath: unrelated.path),
           "⑥ 白名单外的点文件不误删（得 \(foreign.lastPathComponent)/\(unrelated.lastPathComponent)）")
}

/// 一条坏记录不得抹掉 30 天归档（旧实现：整表解码失败 → [] → archiveDay 用空表覆盖）
func testHistorySalvage() {
    group("history 逐日抢救(R35)")
    let dir = engineTestEnv()
    defer {
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        try? FileManager.default.removeItem(at: dir)
    }
    FanCtlPaths.ensureDirectories()
    let mixed = """
    [{"date":"2026-09-01","maxTemp":80,"maxTempAt":"2026-09-01T10:00:00Z","highTempSeconds":0,"tempSum":2400,"tempCount":30,"revolutions":0,"tempSeconds":30},
     {"date":"broken","maxTemp":{"not":"a number"},"maxTempAt":null,"tempSum":"x"},
     {"date":"2026-09-02","maxTemp":84,"maxTempAt":"2026-09-02T10:00:00Z","highTempSeconds":0,"tempSum":2520,"tempCount":30,"revolutions":0,"tempSeconds":30}]
    """
    try? mixed.write(to: FanCtlPaths.historyFile, atomically: true, encoding: .utf8)
    let days = ConfigStore.loadHistory()
    expectEqual(days.count, 2, "坏元素丢弃、好日子抢救（得 \(days.count)）")
    expect(days.map(\.date) == ["2026-09-01", "2026-09-02"], "抢救顺序与日期保留")
    expectEqual(days.first?.maxTemp, 80, "抢救内容完好")
    let backups = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix("history.corrupted.") }
    expectEqual(backups.count, 1, "坏文件仍按既有协议备份")
    // 关键回归：归档一次新日子后，抢救回来的日子不得被空表覆盖丢弃
    var fresh = DailyStats(date: "2026-09-03"); fresh.tempCount = 5; fresh.maxTemp = 88
    ConfigStore.archiveDay(fresh)
    let after = ConfigStore.loadHistory()
    expectEqual(after.count, 3, "archiveDay 后 3 天俱在（旧实现此处只剩 1 天）")
    expect(after.map(\.date) == ["2026-09-01", "2026-09-02", "2026-09-03"], "归档不抹历史")
    // 完全不可抢救的形态：返回空但不炸，且行为与旧版一致
    try? "NOT JSON {".write(to: FanCtlPaths.historyFile, atomically: true, encoding: .utf8)
    expect(ConfigStore.loadHistory().isEmpty, "非 JSON → 空（不 trap）")
    try? "{\"a\":1}".write(to: FanCtlPaths.historyFile, atomically: true, encoding: .utf8)
    expect(ConfigStore.loadHistory().isEmpty, "顶层非数组 → 空（不 trap）")
    // R35 审查（P3）：非对象元素混入不得连累好日子——整表 `as? [[String: Any]]`
    // 在这种形态下 cast 失败会丢掉全部可抢救的天，正是"逐日抢救"最该救的形态
    let mixedScalar = """
    [{"date":"2026-09-04","maxTemp":79,"maxTempAt":"2026-09-04T10:00:00Z","highTempSeconds":0,"tempSum":2400,"tempCount":30,"revolutions":0,"tempSeconds":30},
     42, "junk", null,
     {"date":"2026-09-05","maxTemp":83,"maxTempAt":"2026-09-05T10:00:00Z","highTempSeconds":0,"tempSum":2520,"tempCount":30,"revolutions":0,"tempSeconds":30}]
    """
    try? mixedScalar.write(to: FanCtlPaths.historyFile, atomically: true, encoding: .utf8)
    let rescued = ConfigStore.loadHistory()
    expectEqual(rescued.count, 2, "混入标量/null 仍抢救出 2 天（得 \(rescued.count)）")
    expect(rescued.map(\.date) == ["2026-09-04", "2026-09-05"], "非对象元素只丢自己")
}

/// 均温/波动/均输出按秒加权：自适应 1–20s 拍下不再偏袒繁忙时段（同 v2.6.2 DailyStats 口径）
func testAIMetricsWeighted() {
    group("AI 评测秒加权(R35)")
    var m = AIControlMetrics(targetTemp: 76)
    m.record(temp: 90, output: 90, seconds: 1)          // 1s 快拍（繁忙期）
    m.record(temp: 70, output: 30, seconds: 15)         // 15s 长拍（空闲期）
    // 秒加权：(90×1+70×15)/16 = 71.25；样本口径（旧）：(90+70)/2 = 80
    expectClose(m.averageTemp, 71.25, 1e-9, "均温按秒加权（旧样本口径给 80）")
    expectClose(m.averageOutput, 33.75, 1e-9, "均输出按秒加权（(90+450)/16）")
    // E[t²]=(8100+4900×15)/16 = 5100 → sd = √(5100 − 71.25²)
    expectClose(m.temperatureStdDev, (5100 - 71.25 * 71.25).squareRoot(), 1e-6, "波动按秒加权")
    expectEqual(m.sampleCount, 2, "样本数仍计（口径只影响均值分母）")
    // 往返保留新字段（updatedAt 先归整秒：iso8601 策略不带亚秒）
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    var pinned = m
    pinned.updatedAt = Date(timeIntervalSince1970: 700_000_000)
    guard let blob = try? enc.encode(pinned),
          let back = try? dec.decode(AIControlMetrics.self, from: blob) else {
        expect(false, "往返编解码失败（harness 缺陷）"); return
    }
    expectEqual(back, pinned, "秒加权字段往返")
    // 旧 ai-metrics.json（无加权键）：weighted 为 nil → 回退样本口径，与升级前一致
    let legacy = #"{"targetTemp":76,"activeSeconds":10,"sampleCount":2,"temperatureSum":150,"temperatureSquaredSum":11252,"peakTemp":80,"maxOvershoot":4,"highTempSeconds":0,"outputSum":80,"outputChangeCount":1,"outputChangeMagnitude":10,"updatedAt":"2026-09-01T00:00:00Z"}"#
    guard let old = try? dec.decode(AIControlMetrics.self, from: Data(legacy.utf8)) else {
        expect(false, "旧账本解码失败"); return
    }
    expect(old.temperatureWeightedSum == nil, "旧账本无加权字段 → nil")
    expectClose(old.averageTemp, 75, 1e-9, "旧账本回退样本口径 150/2")
    expectClose(old.temperatureStdDev, 1, 1e-9, "旧账本波动回退样本口径")
    expectClose(old.averageOutput, 40, 1e-9, "旧账本均输出回退样本口径 80/2")
    // R35 审查（P1）：跨版本混合账本——旧文件载入后第一拍 record 让加权键由 nil 变非 nil，
    // 分母必须是"加权覆盖的秒"。原实现拿 activeSeconds 当分母 → 78×3/(10+3)=18.0°，
    // 且被 saveAIMetrics 持久化（真机量级：7 天旧秒 → 均温 0.46°）。
    var mixed = old
    mixed.record(temp: 78, output: 50, seconds: 3)
    expectClose(mixed.averageTemp, 78, 1e-9, "混合账本首拍不被升级前秒数稀释（旧实现 18.0）")
    expectClose(mixed.averageOutput, 50, 1e-9, "混合账本均输出同口径")
    expectClose(mixed.temperatureStdDev, 0, 1e-9, "混合账本波动同口径（单拍方差 0）")
    expectClose(mixed.activeSeconds, 13, 1e-9, "activeSeconds 仍是总受控时长 10+3（语义未改）")
    expectEqual(mixed.weightedSecondsTotal, 3, "加权覆盖秒单独记账")
    // 垃圾解码（合法有限巨值，iso8601 日期）：sanitized 必须钳位，视图 Int() 才不 trap
    let garbage = #"{"targetTemp":76,"activeSeconds":3,"sampleCount":2,"temperatureSum":1e300,"temperatureSquaredSum":1e300,"temperatureWeightedSum":1e300,"temperatureSquaredWeightedSum":-5,"peakTemp":80,"maxOvershoot":4,"highTempSeconds":0,"outputSum":1e300,"outputWeightedSum":1e300,"outputChangeCount":0,"outputChangeMagnitude":0,"updatedAt":"2026-09-01T00:00:00Z"}"#
    do {
        let clean = try dec.decode(AIControlMetrics.self, from: Data(garbage.utf8)).sanitized()
        func bounded(_ v: Double?) -> Bool { v == nil || (v!.isFinite && v! >= 0 && v! < 1e12) }
        expect(bounded(clean.temperatureWeightedSum) && bounded(clean.temperatureSquaredWeightedSum)
               && bounded(clean.outputWeightedSum),
               "加权巨值被 sanitized 钳位（得 \(String(describing: clean.temperatureWeightedSum)))")
        expect(clean.averageTemp.isFinite && clean.temperatureStdDev.isFinite
               && clean.averageOutput.isFinite, "钳位后统计量有限（视图 Int() 安全）")
    } catch {
        expect(false, "垃圾账本应可解码（Optional 字段容忍缺键）: \(error)")
    }
}
