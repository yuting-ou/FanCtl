import Foundation
import Combine
import SMCCore
import FanCtlAppCore

// App 展示层纯逻辑（FanCtlAppCore）的执行级测试。
// 此前这层只存在于 App target，fanctltests 编不到它，只能用源码文本做静态门。

func testStatusDefense() {
    group("AppCore 状态防御：温度/RPM/百分比")

    expectClose(StatusDefense.temperature(72.5), 72.5, 1e-9, "正常温度原样通过")
    for bad in [Double.nan, .infinity, -.infinity, 0, -1, 150, 1e300] {
        expectEqual(StatusDefense.temperature(bad), 0, "非法温度 \(bad) 归零")
    }
    expectEqual(StatusDefense.temperature(149.9), 149.9, "温度上界内保留")

    expectEqual(StatusDefense.rpm(3_000), 3_000, "正常 RPM 原样")
    expectEqual(StatusDefense.rpm(.nan), 0, "NaN RPM 归零")
    expectEqual(StatusDefense.rpm(.infinity), 0, "Inf RPM 归零")
    expectEqual(StatusDefense.rpm(-120), 0, "负 RPM 钳到 0")
    expectEqual(StatusDefense.rpm(1e300), 20_000, "超大 RPM 钳到 20000（防 Int 越界）")

    expectEqual(StatusDefense.percent(42.5), 42.5, "正常百分比原样")
    expectEqual(StatusDefense.percent(.nan), 0, "NaN 百分比归零")
    expectEqual(StatusDefense.percent(-5), 0, "负百分比钳到 0")
    expectEqual(StatusDefense.percent(105), 100, "超 100 百分比钳到 100")
    expectEqual(StatusDefense.percent(1e300), 100, "1e300 百分比钳到 100（防 Int trap）")

    expectEqual(StatusDefense.appliedPercents(nil, fallback: 37), [37], "整段缺失退回单值")
    expectEqual(StatusDefense.appliedPercents([50, .nan, 120], fallback: 37),
                [50, 0, 100], "逐风扇百分比：坏值归零、超界钳位")
    expectEqual(StatusDefense.appliedPercents([], fallback: 37), [],
                "空数组保留空（与风扇数一致性由上层判定）")

    group("AppCore 状态防御：可选读数")

    expect(StatusDefense.temperatureReading(nil) == nil, "nil 分项温度保持 nil")
    expectEqual(StatusDefense.temperatureReading(45), 45, "有效分项温度保留")
    for bad in [Double.nan, .infinity, 0, -1, 150, 1e300] {
        expectEqual(StatusDefense.temperatureReading(bad), nil, "非法分项温度 \(bad) → nil")
    }

    expectEqual(StatusDefense.environmentTemperature(35), 35, "有效环境温度保留")
    expectEqual(StatusDefense.environmentTemperature(59.9), 59.9, "环境温度上界内保留")
    expectEqual(StatusDefense.environmentTemperature(60), nil, "环境温度 60 越界 → nil")
    expectEqual(StatusDefense.environmentTemperature(-.infinity), nil, "环境温度 -Inf → nil")

    expectEqual(StatusDefense.aiTarget(20), nil, "AI 目标 20 越界（开区间）")
    expectEqual(StatusDefense.aiTarget(20.1), 20.1, "AI 目标 20.1 有效")
    expectEqual(StatusDefense.aiTarget(99.9), 99.9, "AI 目标 99.9 有效")
    expectEqual(StatusDefense.aiTarget(100), nil, "AI 目标 100 越界")
    expectEqual(StatusDefense.aiTarget(.nan), nil, "AI 目标 NaN → nil")

    expectEqual(StatusDefense.palmCompensation(0.5), nil, "体感补偿 0.5 不展示")
    expectEqual(StatusDefense.palmCompensation(0.6), 0.6, "体感补偿 0.6 展示")
    expectEqual(StatusDefense.palmCompensation(4), 4, "体感补偿 4 展示（闭区间）")
    expectEqual(StatusDefense.palmCompensation(4.1), nil, "体感补偿 4.1 越界")

    expectEqual(StatusDefense.powerWatts(0.1), nil, "功耗 0.1 越界")
    expectEqual(StatusDefense.powerWatts(0.2), 0.2, "功耗 0.2 有效")
    expectEqual(StatusDefense.powerWatts(999), 999, "功耗 999 有效")
    expectEqual(StatusDefense.powerWatts(1000), nil, "功耗 1000 越界")
    expectEqual(StatusDefense.powerWatts(.infinity), nil, "功耗 Inf → nil")

    group("AppCore 状态防御：风扇与学习点")

    let entries = [
        FanStatusEntry(id: 0, actualRPM: 2_000, targetRPM: 2_100, minRPM: 1_200, maxRPM: 5_500),
        FanStatusEntry(id: -1, actualRPM: 2_000, targetRPM: 2_000, minRPM: 1_200, maxRPM: 5_500),
        FanStatusEntry(id: 8, actualRPM: 2_000, targetRPM: 2_000, minRPM: 1_200, maxRPM: 5_500),
        FanStatusEntry(id: 7, actualRPM: .nan, targetRPM: -5, minRPM: 1e300, maxRPM: .infinity),
    ]
    let fans = StatusDefense.fanStates(from: entries)
    expectEqual(fans.count, 2, "风扇 id 只接受 0..<8（-1/8 被剔除）")
    expectEqual(fans[0].id, 0, "合法风扇 id 保留")
    expectEqual(fans[0].actualRPM, 2_000, "合法风扇 RPM 保留")
    expectEqual(fans[1].id, 7, "id=7 是上界合法值")
    expectEqual(fans[1].actualRPM, 0, "风扇 NaN RPM 归零")
    expectEqual(fans[1].targetRPM, 0, "风扇负目标归零")
    expectEqual(fans[1].minRPM, 20_000, "风扇超大 minRPM 钳位")
    expectEqual(fans[1].maxRPM, 0, "风扇 Inf maxRPM 归零")

    let learned = [
        ThermalLearn.LearnedPoint(temp: 60, percent: 40, samples: 3),
        ThermalLearn.LearnedPoint(temp: 65, percent: 0, samples: 1),
        ThermalLearn.LearnedPoint(temp: 66, percent: 100, samples: 1),
        ThermalLearn.LearnedPoint(temp: .nan, percent: 40, samples: 3),
        ThermalLearn.LearnedPoint(temp: 150, percent: 40, samples: 3),
        ThermalLearn.LearnedPoint(temp: 1e300, percent: 40, samples: 3),
        ThermalLearn.LearnedPoint(temp: 70, percent: .nan, samples: 3),
        ThermalLearn.LearnedPoint(temp: 70, percent: 101, samples: 3),
        ThermalLearn.LearnedPoint(temp: 70, percent: 40, samples: 0),
    ]
    let trusted = StatusDefense.learnedPoints(learned)
    expectEqual(trusted.count, 3, "学习点只留温度/百分比/样本数全部合法的项")
    expectEqual(trusted.first?.temp, 60, "合法学习点保留")
    expect(trusted.contains { $0.percent == 0 }, "percent=0 是合法下界（闭区间）")
    expect(trusted.contains { $0.percent == 100 }, "percent=100 是合法上界（闭区间）")
}

func testMenuBarStateDeduplication() {
    group("AppCore 菜单栏状态：阈值与发布去重")

    let state = MenuBarState()
    var publishes = 0
    let token = state.objectWillChange.sink { publishes += 1 }
    defer { token.cancel() }

    state.update(temp: 62.4, boost: false, quiet: false, style: "both")
    expectEqual(state.display.tempBucket, 62, "温度向下取整为整数桶")
    expectEqual(state.display.warnLevel, 0, "62° 无警示")
    expectEqual(state.display.boostActive, false, "冲刺真值更新")
    expectEqual(state.display.quietActive, false, "静音真值更新")
    expectEqual(publishes, 1, "首次状态变化发布一次")

    state.update(temp: 62.9, boost: false, quiet: false, style: "both")
    expectEqual(publishes, 1, "同整数桶不发布（小数抖动不重渲标签）")

    state.update(temp: 78, boost: false, quiet: false, style: "both")
    expectEqual(state.display.warnLevel, 1, "78° 进入橙色警示")
    expectEqual(publishes, 2, "警示级别变化发布")

    state.update(temp: 88, boost: false, quiet: false, style: "both")
    expectEqual(state.display.warnLevel, 2, "88° 进入红色警示")
    expectEqual(publishes, 3, "红色警示发布")

    // icon 样式下温度不可见：桶变化不应发布（保持警示档不变，只动桶）
    let beforeIcon = publishes
    state.update(temp: 95, boost: false, quiet: false, style: "icon")
    expectEqual(state.display.tempBucket, 95, "icon 样式仍更新真值")
    expectEqual(publishes, beforeIcon, "icon 样式下温度变化不发布")
    state.update(temp: 95, boost: true, quiet: false, style: "icon")
    expectEqual(publishes, beforeIcon + 1, "icon 样式下字形变化发布")
    expectEqual(state.display.boostActive, true, "icon 样式仍更新冲刺真值")
    state.update(temp: 95, boost: true, quiet: true, style: "icon")
    expectEqual(publishes, beforeIcon + 2, "icon 样式下静音字形变化发布")
    expectEqual(state.display.quietActive, true, "icon 样式仍更新静音真值")

    // temp 样式下冲刺/静音字形不可见：只切这两个不应发布
    let beforeTempStyle = publishes
    state.update(temp: 95, boost: false, quiet: true, style: "temp")
    expectEqual(publishes, beforeTempStyle, "temp 样式下静音字形变化不发布")
    state.update(temp: 80, boost: false, quiet: true, style: "temp")
    expectEqual(publishes, beforeTempStyle + 1, "temp 样式下温度桶 + 警示变化发布")

    // 恶意/坏读数不得触发 Int() trap
    state.update(temp: 1e300, boost: false, quiet: false, style: "both")
    expectEqual(state.display.tempBucket, -1, "1e300 温度显示占位（不 trap）")
    state.update(temp: .nan, boost: false, quiet: false, style: "both")
    expectEqual(state.display.tempBucket, -1, "NaN 温度显示占位")

    // icon 样式的警示色是可见的：77→78 必须发布，同桶小数抖动不发布
    let warnState = MenuBarState()
    var warnPublishes = 0
    let warnToken = warnState.objectWillChange.sink { warnPublishes += 1 }
    defer { warnToken.cancel() }
    warnState.update(temp: 77, boost: false, quiet: false, style: "icon")
    expectEqual(warnState.display.warnLevel, 0, "77° 无警示")
    expectEqual(warnPublishes, 0, "icon 样式首拍警示档未变不发布")
    warnState.update(temp: 77.9, boost: false, quiet: false, style: "icon")
    expectEqual(warnPublishes, 0, "同桶同警示不发布")
    warnState.update(temp: 78, boost: false, quiet: false, style: "icon")
    expectEqual(warnState.display.warnLevel, 1, "78° 进入橙色警示")
    expectEqual(warnPublishes, 1, "icon 样式下警示色变化发布")
}

func testProcessUsageParsing() {
    group("AppCore 进程榜：ps 解析与软件名归并")

    let mapping: [String: (app: String, role: String?)] = [
        "/Applications/抖音.app/Contents/Frameworks/抖音 Helper (Renderer).app/Contents/MacOS/抖音 Helper (Renderer)":
            ("抖音", "渲染进程"),
        "/Applications/抖音.app/Contents/Frameworks/抖音 Helper (GPU).app/Contents/MacOS/抖音 Helper (GPU)":
            ("抖音", "图形进程"),
        "/Applications/谷歌浏览器.app/Contents/MacOS/谷歌浏览器": ("谷歌浏览器", nil),
        "/usr/bin/foo": ("foo", ""),
    ]
    let output = """
     %CPU COMM
      94.6 /Applications/抖音.app/Contents/Frameworks/抖音 Helper (Renderer).app/Contents/MacOS/抖音 Helper (Renderer)
      20.0 /Applications/抖音.app/Contents/Frameworks/抖音 Helper (GPU).app/Contents/MacOS/抖音 Helper (GPU)
      48.7 /Applications/谷歌浏览器.app/Contents/MacOS/谷歌浏览器
      30.0 /usr/bin/foo
       5.0 /usr/bin/below-threshold
     nan /usr/bin/nan-cpu
     inf /usr/bin/inf-cpu
    no-space-here
      99.0
    """
    let parsed = ProcessUsageParser.parse(output, limit: 5, minCPU: 8) { path in
        mapping[path] ?? ("未知进程", nil)
    }
    expectEqual(parsed.count, 3, "低于阈值/NaN/畸形行/无路径行全部丢弃")
    expectEqual(parsed[0].app, "抖音", "同软件 helper 合并后按总和排第一")
    expectClose(parsed[0].cpu, 114.6, 1e-9, "同软件多个 helper 的 CPU 相加")
    expectEqual(parsed[0].id, "抖音（渲染进程）", "归并后角色取第一个出现的 helper")
    expectEqual(parsed[1].app, "谷歌浏览器", "无角色进程按软件名展示")
    expectEqual(parsed[1].id, "谷歌浏览器", "role=nil 不加空括号")
    expectEqual(parsed[2].id, "foo", "空字符串 role 也不加括号")

    let top2 = ProcessUsageParser.parse(output, limit: 2, minCPU: 8) { path in
        mapping[path] ?? ("未知进程", nil)
    }
    expectEqual(top2.count, 2, "limit 截断生效")
    expectEqual(top2.map(\.app), ["抖音", "谷歌浏览器"], "limit 截断保留 CPU 最高的前二")

    let headerOnly = ProcessUsageParser.parse(" %CPU COMM\n", limit: 5, minCPU: 8) { _ in
        ("x", nil)
    }
    expect(headerOnly.isEmpty, "只有表头时返回空数组")
    expect(ProcessUsageParser.parse("", limit: 5, minCPU: 8) { _ in ("x", nil) }.isEmpty,
           "空输出返回空数组")

    var detailCalls = 0
    _ = ProcessUsageParser.parse("""
     %CPU COMM
      99.0 /a
       1.0 /b
    """, limit: 5, minCPU: 8) { path in
        detailCalls += 1
        return (path, nil)
    }
    expectEqual(detailCalls, 1, "低于阈值的行不应浪费路径归属解析")
}

func testTrendHistoryRingAndPolicy() {
    group("AppCore 趋势历史：环形缓冲")
    var ring = RingBuffer<Int>(capacity: 3)
    expect(ring.isEmpty, "空环 isEmpty")
    ring.append(1); ring.append(2); ring.append(3)
    expectEqual(ring.elements, [1, 2, 3], "未满时按插入顺序返回")
    ring.append(4)
    expectEqual(ring.elements, [2, 3, 4], "满后淘汰最旧元素")
    expectEqual(ring.count, 3, "count 不超过容量")
    ring.append(5)
    expectEqual(ring.elements, [3, 4, 5], "连续回绕后顺序仍正确")

    group("AppCore 趋势历史：采样与落盘节奏")
    expectEqual(TrendHistoryPolicy.sampleSeconds, 3, "采样节奏真值=3s（改它就是改信息率）")
    expectEqual(TrendHistoryPolicy.saveSeconds, 30, "落盘节奏真值=30s")
    expectEqual(TrendHistoryPolicy.window, 600, "趋势窗口真值=600s")
    expectEqual(TrendHistoryPolicy.capacity, 200, "趋势环容量真值=200")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let at3 = t0.addingTimeInterval(TrendHistoryPolicy.sampleSeconds)
    expect(TrendHistoryPolicy.shouldAppend(hottest: 70, envTemp: 30, now: at3, lastAppend: t0),
           "到 3s 采样点且读数可信 → 入环")
    expect(!TrendHistoryPolicy.shouldAppend(hottest: 70, envTemp: 30,
                                            now: t0.addingTimeInterval(2.999), lastAppend: t0),
           "未到 3s 不入环")
    expect(TrendHistoryPolicy.shouldAppend(hottest: 70, envTemp: nil, now: at3, lastAppend: t0),
           "无环境温度时 >=15° 仍可信")
    expect(!TrendHistoryPolicy.shouldAppend(hottest: 8.4, envTemp: 30, now: at3, lastAppend: t0),
           "8.4° 坏读数被可信门挡住（R76 回归）")
    expect(!TrendHistoryPolicy.shouldAppend(hottest: 126, envTemp: nil, now: at3, lastAppend: t0),
           "超过 125° 不可信")
    expect(!TrendHistoryPolicy.shouldAppend(hottest: 1, envTemp: nil, now: at3, lastAppend: t0),
           "占位值 1° 不入环")

    let at30 = t0.addingTimeInterval(TrendHistoryPolicy.saveSeconds)
    expect(TrendHistoryPolicy.shouldPersist(now: at30, lastSave: t0, panelVisible: true),
           "面板可见且到 30s → 落盘")
    expect(!TrendHistoryPolicy.shouldPersist(now: t0.addingTimeInterval(29.9),
                                             lastSave: t0, panelVisible: true),
           "未到 30s 不落盘")
    expect(!TrendHistoryPolicy.shouldPersist(now: at30, lastSave: t0, panelVisible: false),
           "面板关闭时不落盘（文件唯一消费者是面板）")

    group("AppCore 趋势历史：落盘与恢复")
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fanctl-trend-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TrendHistoryStore(fileURL: dir.appendingPathComponent("trend.json"))
    let samples = [TrendSample(id: t0, cpu: 60, gpu: 55),
                   TrendSample(id: t0.addingTimeInterval(10), cpu: 70, gpu: 65)]
    store.persist(samples)
    let loaded = store.load(now: t0.addingTimeInterval(20), window: 600, capacity: 10)
    expectEqual(loaded.elements, samples, "落盘后可完整恢复")
    expectEqual(loaded.elements.first?.temp, 60, "temp 取 CPU/GPU 上包络")

    let mixed = [TrendSample(id: t0.addingTimeInterval(-700), cpu: 50, gpu: 50),
                 TrendSample(id: t0, cpu: 60, gpu: 60)]
    store.persist(mixed)
    let filtered = store.load(now: t0, window: 600, capacity: 10)
    expectEqual(filtered.elements.map(\.id), [t0], "窗口外的旧样本被丢弃")

    let five = (0..<5).map {
        TrendSample(id: t0.addingTimeInterval(Double($0)), cpu: 60, gpu: 60)
    }
    store.persist(five)
    let clamped = store.load(now: t0.addingTimeInterval(4), window: 600, capacity: 3)
    expectEqual(clamped.elements.map(\.id), five.suffix(3).map(\.id),
                "恢复时按容量只保留最新样本")

    try? Data("not-json".utf8).write(to: store.fileURL)
    expect(store.load(now: t0, window: 600, capacity: 3).isEmpty,
           "损坏文件按空历史处理，不抛错")
    let missing = TrendHistoryStore(fileURL: dir.appendingPathComponent("missing.json"))
    expect(missing.load(now: t0, window: 600, capacity: 3).isEmpty,
           "文件不存在按空历史处理")
}

func testStatusProjection() {
    group("AppCore 状态投影：映射/消毒/毛刺")

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let status = DaemonStatus(
        sensors: SensorReadings(cpuDie: 72.5, cpuAverage: 65, gpuDie: 60, ssd: 45, palmRest: 38),
        mode: .ai,
        appliedPercent: 55.4,
        appliedPercents: [55, 55],
        fans: [FanStatusEntry(id: 0, actualRPM: 2_000, targetRPM: 2_100,
                              minRPM: 1_200, maxRPM: 5_500)],
        timestamp: t0,
        onBattery: true, batteryOverride: true,
        reason: .ai, aiIntent: .rising,
        loopInterval: 3, controlFault: false,
        faultReason: nil, curveTargetPercent: 60,
        learningRecently: true, learnedPoints: 5, learnedSamples: 42,
        targetUnreachable: true, aiHighEffort: true,
        powerWatts: 38.5, nightOverride: true, envTemp: 31,
        aiTargetEffective: 74, palmComp: 2.5,
        learnMap: [ThermalLearn.LearnedPoint(temp: 60, percent: 40, samples: 3)],
        decisionTrace: DecisionTrace(target: 72, temp: 73, error: 1, learned: 60,
                                    idle: false, hysteresisHold: true, guardSeconds: 900),
        calibrating: true)
    var projector = StatusProjector()
    let p = projector.project(status)
    expectClose(p.cpuTemp, 72.5, 1e-9, "CPU 温度映射")
    expectEqual(p.cpuAverageTemp, 65, "CPU 核心平均映射")
    expectClose(p.gpuTemp, 60, 1e-9, "GPU 温度映射")
    expectEqual(p.ssdTemp, 45, "SSD 温度映射")
    expectEqual(p.palmRestTemp, 38, "掌托温度映射")
    expectClose(p.appliedPercent, 55.4, 1e-9, "输出百分比映射")
    expectEqual(p.appliedPercents, [55, 55], "每风扇百分比映射")
    expect(p.onBattery && p.batteryOverride && p.nightOverride, "电源/夜间覆盖标记映射")
    expectEqual(p.envTemp, 31, "环境温度映射")
    expectEqual(p.controlReason, .ai, "控制原因映射")
    expectEqual(p.aiIntent, .rising, "AI 意图映射")
    expectEqual(p.curveTargetPercent, 60, "曲线锚定映射")
    expect(p.learningRecently, "学习活跃标记映射")
    expectEqual(p.learnedSamples, 42, "学习样本数映射")
    expectEqual(p.learnMap.count, 1, "学习地图映射")
    expectEqual(p.decisionTrace?.target, 72, "决策透镜映射")
    expect(p.targetUnreachable && p.aiHighEffort, "AI 告警标记映射")
    expectEqual(p.learnedPoints, 5, "学习点数映射")
    expectEqual(p.currentLoopInterval, 3, "循环间隔映射")
    expect(!p.controlFault, "无故障标记映射")
    expectEqual(p.aiTargetEffective, 74, "AI 生效目标映射")
    expectEqual(p.palmComp, 2.5, "体感补偿映射")
    expectEqual(p.systemPower, 38.5, "整机功耗映射")
    expectEqual(p.fans.count, 1, "风扇状态映射")
    expectEqual(p.fans.first?.actualRPM, 2_000, "风扇 RPM 映射")
    expect(p.changed, "首拍 0 → 72.5 触发数字动画")

    let again = projector.project(status)
    expect(!again.changed, "同整数温度桶不触发数字动画")
    expectClose(again.cpuTemp, 72.5, 1e-9, "重复投影温度稳定")

    // 旧 daemon：可选字段缺席时给安全默认值
    var minimal = DaemonStatus(sensors: SensorReadings(cpuDie: 70, gpuDie: 60),
                               mode: .curve, appliedPercent: 50,
                               fans: [], timestamp: t0)
    var oldProjector = StatusProjector()
    let old = oldProjector.project(minimal)
    expect(!old.onBattery && !old.batteryOverride && !old.nightOverride, "旧 daemon 覆盖标记默认 false")
    expect(old.controlReason == nil && old.aiIntent == nil, "旧 daemon 控制原因默认 nil")
    expect(old.learnedPoints == nil, "旧 daemon 学习点数保持 nil（调用方不得清零）")
    expectEqual(old.learnedSamples, 0, "旧 daemon 学习样本数默认 0")
    expect(old.learnMap.isEmpty && old.decisionTrace == nil, "旧 daemon 学习/透镜默认空")

    // 坏数据：status.json 可被手改，投影必须挡住 Int() trap 与越界值
    minimal.sensors = SensorReadings(cpuDie: .nan, cpuAverage: 1e300, gpuDie: .infinity,
                                     ssd: 150, palmRest: -1)
    minimal.appliedPercent = 1e300
    minimal.appliedPercents = [50, .nan, 120]
    minimal.fans = [
        FanStatusEntry(id: -1, actualRPM: 2_000, targetRPM: 2_000, minRPM: 1_200, maxRPM: 5_500),
        FanStatusEntry(id: 0, actualRPM: .nan, targetRPM: -5, minRPM: 1e300, maxRPM: .infinity),
        FanStatusEntry(id: 8, actualRPM: 2_000, targetRPM: 2_000, minRPM: 1_200, maxRPM: 5_500),
    ]
    minimal.envTemp = 100
    minimal.aiTargetEffective = 1e300
    minimal.palmComp = 9
    minimal.powerWatts = 5_000
    minimal.learnMap = [
        ThermalLearn.LearnedPoint(temp: 60, percent: 40, samples: 3),
        ThermalLearn.LearnedPoint(temp: .nan, percent: 40, samples: 3),
        ThermalLearn.LearnedPoint(temp: 70, percent: 101, samples: 3),
    ]
    var hostileProjector = StatusProjector()
    let hostile = hostileProjector.project(minimal)
    expectEqual(hostile.cpuTemp, 0, "NaN CPU 温度归零（不 trap）")
    expectEqual(hostile.gpuTemp, 0, "Inf GPU 温度归零")
    expect(hostile.cpuAverageTemp == nil, "超大 CPU 平均温度 → nil")
    expect(hostile.ssdTemp == nil, "150° SSD → nil")
    expect(hostile.palmRestTemp == nil, "负掌托温度 → nil")
    expectEqual(hostile.appliedPercent, 100, "1e300 百分比钳到 100（不 trap）")
    expectEqual(hostile.appliedPercents, [50, 0, 100], "每风扇百分比逐项消毒")
    expect(hostile.envTemp == nil, "100° 环境温度 → nil")
    expect(hostile.aiTargetEffective == nil, "1e300 AI 目标 → nil")
    expect(hostile.palmComp == nil, "9° 体感补偿 → nil")
    expect(hostile.systemPower == nil, "5000W 功耗 → nil")
    expectEqual(hostile.fans.count, 1, "越界风扇 id 被剔除")
    expectEqual(hostile.fans.first?.actualRPM, 0, "NaN RPM 归零")
    expectEqual(hostile.fans.first?.targetRPM, 0, "负目标 RPM 归零")
    expectEqual(hostile.fans.first?.minRPM, 20_000, "超大 minRPM 钳位")
    expectEqual(hostile.learnMap.count, 1, "坏学习点被过滤")

    // 毛刺剔除：骤降 >30° 先沿用旧值，连续 3 拍后采信（与 daemon 对齐）
    var glitchProjector = StatusProjector()
    var glitchStatus = DaemonStatus(sensors: SensorReadings(cpuDie: 70, gpuDie: 60),
                                    mode: .curve, appliedPercent: 50,
                                    fans: [], timestamp: t0)
    expectClose(glitchProjector.project(glitchStatus).cpuTemp, 70, 1e-9, "首拍 70° 入")
    glitchStatus.sensors = SensorReadings(cpuDie: 8.4, gpuDie: 60)
    for i in 0..<3 {
        expectClose(glitchProjector.project(glitchStatus).cpuTemp, 70, 1e-9,
                    "骤降 hold 第 \(i + 1) 拍沿用 70°")
    }
    expectClose(glitchProjector.project(glitchStatus).cpuTemp, 8.4, 1e-9,
                "连续第 4 拍采信真实降温")
}

func testUpdateCheckPolicy() {
    group("AppCore 升级检查：节流/重试/提示")
    expectEqual(UpdateCheckPolicy.successInterval, 24 * 3600, "成功窗口真值=24h")
    expectEqual(UpdateCheckPolicy.retryInterval, 600, "重试间隔真值=600s")
    expectEqual(UpdateCheckPolicy.retryTolerance, 120, "重试 timer 容差真值=120s")
    expectEqual(UpdateCheckPolicy.maxRetries, 3, "重试预算真值=3 次")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    expect(!UpdateCheckPolicy.shouldCheck(now: now, lastSuccess: nil,
                                         force: true, inFlight: true),
           "在途永远阻断（force 也不例外）")
    expect(UpdateCheckPolicy.shouldCheck(now: now,
                                        lastSuccess: now.addingTimeInterval(-10),
                                        force: true, inFlight: false),
           "force 绕过 24h 成功窗口")
    expect(UpdateCheckPolicy.shouldCheck(now: now, lastSuccess: nil,
                                        force: false, inFlight: false),
           "从未成功查过 → 允许")
    expect(!UpdateCheckPolicy.shouldCheck(now: now,
                                         lastSuccess: now.addingTimeInterval(-3600),
                                         force: false, inFlight: false),
           "1h 前查过 → 24h 内不查")
    expect(!UpdateCheckPolicy.shouldCheck(now: now,
                                         lastSuccess: now.addingTimeInterval(-24 * 3600 + 0.1),
                                         force: false, inFlight: false),
           "差 0.1s 不满 24h 不查")
    expect(UpdateCheckPolicy.shouldCheck(now: now,
                                        lastSuccess: now.addingTimeInterval(-24 * 3600),
                                        force: false, inFlight: false),
           "满 24h → 允许再查")

    expectEqual(UpdateCheckPolicy.nextRetryDelay(afterFailure: 0), 600,
                "首次失败 10 分钟后重试")
    expectEqual(UpdateCheckPolicy.nextRetryDelay(afterFailure: 1), 600,
                "第二次失败仍重试")
    expectEqual(UpdateCheckPolicy.nextRetryDelay(afterFailure: 2), 600,
                "第三次失败仍重试")
    expectEqual(UpdateCheckPolicy.nextRetryDelay(afterFailure: 3), nil,
                "3 次预算用完不再挂 timer")
    expectEqual(UpdateCheckPolicy.nextRetryDelay(afterFailure: 99), nil,
                "超预算仍不重试")

    expectEqual(UpdateCheckPolicy.availableUpdate(fetchedTag: "v4.3.0",
                                                  localVersion: "4.2.56", skippedTag: nil),
                "v4.3.0", "更新版本且未跳过 → 提示")
    expectEqual(UpdateCheckPolicy.availableUpdate(fetchedTag: "v4.3.0",
                                                  localVersion: "4.2.56",
                                                  skippedTag: "v4.3.0"),
                nil, "用户已跳过该 tag → 不提示")
    expectEqual(UpdateCheckPolicy.availableUpdate(fetchedTag: "v4.2.56",
                                                  localVersion: "4.2.56", skippedTag: nil),
                nil, "同版本不提示")
    expectEqual(UpdateCheckPolicy.availableUpdate(fetchedTag: "v4.2.55",
                                                  localVersion: "4.2.56", skippedTag: nil),
                nil, "旧版本不提示")
    expectEqual(UpdateCheckPolicy.availableUpdate(fetchedTag: nil,
                                                  localVersion: "4.2.56", skippedTag: nil),
                nil, "拉取失败不提示")
    expectEqual(UpdateCheckPolicy.availableUpdate(fetchedTag: "v4.3.0",
                                                  localVersion: "4.2.56",
                                                  skippedTag: "v4.2.9"),
                "v4.3.0", "跳过的是别的版本 → 仍然提示")
}

private func makeIntent(
    mode: FanMode = .curve,
    manualPercent: Double = 50,
    preset: CurvePreset = .balanced,
    curve: [CurvePoint] = CurvePreset.balanced.points,
    quietCurve: [CurvePoint] = CurvePreset.quiet.points,
    batterySaver: Bool = false,
    quietUntil: Date? = nil,
    quietCapPercent: Double = 30,
    aiTargetTemp: Double = 76,
    fanOffsets: [Double] = [0, 0],
    boostUntil: Date? = nil,
    envCompensation: Bool = true,
    quietHours: Bool = false,
    envTempOverride: Double? = nil,
    palmCompensation: Bool = false
) -> FanConfig {
    FanConfigIntent.make(
        mode: mode,
        manualPercent: manualPercent,
        curve: curve,
        preset: preset,
        batterySaver: batterySaver,
        quietCurve: quietCurve,
        quietUntil: quietUntil,
        quietCapPercent: quietCapPercent,
        aiTargetTemp: aiTargetTemp,
        fanOffsets: fanOffsets,
        boostUntil: boostUntil,
        envCompensation: envCompensation,
        quietHours: quietHours,
        nightCurve: quietCurve,
        envTempOverride: envTempOverride,
        palmCompensation: palmCompensation)
}

func testFanConfigIntent() {
    group("AppCore 配置意图：字段生命周期")

    let base = makeIntent()
    expectEqual(base.mode, .curve, "模式透传")
    expectEqual(base.manualPercent, 50, "手动百分比透传")
    expectEqual(base.curve, CurvePreset.balanced.points, "当前曲线透传")
    expectEqual(base.preset, .balanced, "预设透传")
    expectEqual(base.quietUntil, nil, "未静音时 quietUntil 为 nil")
    expectEqual(base.quietCapPercent, nil, "未静音时封顶值也必须 nil（同生共死）")
    expectEqual(base.batteryPreset, nil, "未开电池安静档时 batteryPreset 为 nil")
    expectEqual(base.batteryCurve, nil, "未开电池安静档时 batteryCurve 为 nil")
    expectEqual(base.nightCurve, nil, "未开夜间安静档时 nightCurve 为 nil")
    expectEqual(base.quietHours, false, "未开夜间安静档时开关为 false")
    expectEqual(base.fanOffsets, nil, "全零偏移不落盘")
    expectEqual(base.envCompensation, true, "环境补偿开关透传")
    expectEqual(base.palmCompensation, false, "体感补偿开关透传")

    let quietDate = Date(timeIntervalSince1970: 1_800_000_000)
    let quiet = makeIntent(quietUntil: quietDate, quietCapPercent: 25)
    expectEqual(quiet.quietUntil, quietDate, "静音生效时截止时间落盘")
    expectEqual(quiet.quietCapPercent, 25, "静音生效时封顶值落盘")

    let battery = makeIntent(batterySaver: true)
    expectEqual(battery.batteryPreset, .quiet, "电池安静档下发 quiet 预设")
    expectEqual(battery.batteryCurve, CurvePreset.quiet.points, "电池安静档下发安静曲线")

    let night = makeIntent(quietHours: true)
    expectEqual(night.quietHours, true, "夜间安静开关落盘")
    expectEqual(night.nightCurve, CurvePreset.quiet.points, "夜间安静档下发安静曲线")

    let customCurve = [CurvePoint(temp: 50, percent: 0), CurvePoint(temp: 90, percent: 100)]
    let customQuiet = [CurvePoint(temp: 55, percent: 0), CurvePoint(temp: 85, percent: 100)]
    let customIntent = makeIntent(preset: .custom, curve: customCurve,
                                  quietCurve: customQuiet, batterySaver: true)
    expectEqual(customIntent.preset, .custom, "自定义预设透传")
    expectEqual(customIntent.curve, customCurve, "自定义曲线不被预设默认值覆盖")
    expectEqual(customIntent.batteryCurve, customQuiet, "电池曲线用调用方传入的安静曲线")
    let nightCustom = makeIntent(quietCurve: customQuiet, quietHours: true)
    expectEqual(nightCustom.nightCurve, customQuiet, "夜间曲线用调用方传入的安静曲线")

    let offsets = makeIntent(fanOffsets: [-3, 5])
    expectEqual(offsets.fanOffsets, [-3, 5], "非零风扇偏移保留")

    let oneZero = makeIntent(fanOffsets: [0])
    expectEqual(oneZero.fanOffsets, nil, "单元素全零偏移也不落盘")

    let boost = makeIntent(mode: .manual, manualPercent: 72,
                           aiTargetTemp: 72, boostUntil: quietDate,
                           envCompensation: false, envTempOverride: 33,
                           palmCompensation: true)
    expectEqual(boost.boostUntil, quietDate, "冲刺截止时间透传")
    expectEqual(boost.mode, .manual, "手动模式透传")
    expectEqual(boost.manualPercent, 72, "手动档位透传")
    expectEqual(boost.aiTargetTemp, 72, "AI 目标透传（切模式后仍保留）")
    expectEqual(boost.envTempOverride, 33, "环境温度覆盖透传")
    expectEqual(boost.envCompensation, false, "关闭环境补偿透传")
    expectEqual(boost.palmCompensation, true, "开启体感补偿透传")
}
