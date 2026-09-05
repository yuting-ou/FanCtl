// 测试按模块拆分（v3.3.1）：本文件为各模块共享的 harness 与主入口。
// 断言 harness 见 main.swift，共享构造（MockSMC/FakeClock/makeEngine）见 TestsEngine.swift 头部。
import Foundation
import SMCCore

// MARK: - 控制律 + 温度轨迹仿真

// 把一条原始温度轨迹跑过控制律，返回每拍实际施加百分比
func simulate(_ tuning: FanControlTuning, trace: [Double], curve: [CurvePoint]) -> [Double] {
    var c = FanCurveController(tuning: tuning)
    var out: [Double] = []
    for raw in trace {
        guard let temp = c.smooth(rawTemp: raw) else { out.append(c.lastAppliedPercent ?? 0); continue }
        out.append(c.shape(target: FanConfig.percent(temp: temp, curve: curve)))
    }
    return out
}
func changeCount(_ s: [Double]) -> Int {
    var n = 0
    for i in 1..<s.count where abs(s[i] - s[i-1]) > 0.01 { n += 1 }
    return n
}


// MARK: - 控制律回归（证明抽取零行为漂移 + 状态重置）


func testControlLawRegression() {
    group("控制律回归")
    // 关闭加速回落时，平滑序列必须逐拍等于旧版 EMA（升 0.35 / 降 0.2）
    var t = FanControlTuning(); t.settleBoostDrop = 999
    var c = FanCurveController(tuning: t)
    var manualPrev: Double? = nil
    for raw in [55.0, 58, 62, 60, 65, 70, 68, 64, 60, 58, 56, 55] {
        let got = c.smooth(rawTemp: raw)!
        if let p = manualPrev {
            manualPrev = p + (raw > p ? 0.35 : 0.2) * (raw - p)
        } else { manualPrev = raw }
        expectClose(got, manualPrev!, 1e-9, "旧EMA等价 @\(raw)")
    }

    // 加速回落：从同一峰值回落时，启用者应更接近低温
    var son = FanCurveController()              // 默认启用
    var soff = FanCurveController(tuning: t)     // 关闭
    for r in [60.0, 70, 80, 80, 80] { _ = son.smooth(rawTemp: r); _ = soff.smooth(rawTemp: r) }
    let a = son.smooth(rawTemp: 60)!
    let b = soff.smooth(rawTemp: 60)!
    expect(a < b - 0.5, "加速回落应更快逼近低温 (\(a) vs \(b))")

    // invalidateTemp：清缓存后重新起平滑
    var s3 = FanCurveController(); _ = s3.smooth(rawTemp: 70)
    s3.invalidateTemp()
    expectEqual(s3.smooth(rawTemp: 50), 50, "invalidateTemp 后重新播种")

    // clearOutput：清输出记忆后下次 shape 不受降速限速
    var s4 = FanCurveController(); _ = s4.smooth(rawTemp: 60)
    _ = s4.shape(target: 80)
    s4.clearOutput()
    expectEqual(s4.shape(target: 30), 30, "clearOutput 后直接应用")

    // 连续坏读超上限后采信并恢复正常平滑
    var s5 = FanCurveController(); _ = s5.smooth(rawTemp: 75)
    for _ in 0..<3 { _ = s5.smooth(rawTemp: 20) }   // 3 拍 hold
    let accepted = s5.smooth(rawTemp: 20)            // 第4拍采信
    expect(accepted != nil && accepted! < 75, "坏读超限后采信降温")
    expect(s5.smooth(rawTemp: 60) != nil, "坏读后正常读数不再被剔")

    // NaN/Inf 守卫：非有限值不入平滑，不污染 smoothedTemp（后续正常值仍有限）
    var s6 = FanCurveController(); _ = s6.smooth(rawTemp: 70)
    _ = s6.smooth(rawTemp: .nan); _ = s6.smooth(rawTemp: .infinity)
    if let v = s6.smooth(rawTemp: 72) { expect(v.isFinite, "NaN/Inf 后平滑值仍有限 (\(v))") }
    else { expect(false, "NaN 后应能正常返回平滑值") }
}


// MARK: - v2.7 学习稳态门（阈值按秒标定）


func testLearningGate() {
    group("学习稳态门")
    // 秒语义：同一 °C/s 在不同拍长下判定一致
    expect(LearningGate.isSteady(temp: 70, prevTemp: 70, baseTarget: 50, prevBase: 50,
                                 shapedBase: 50, dt: 3), "平稳通过(3s)")
    expect(LearningGate.isSteady(temp: 70.3, prevTemp: 70, baseTarget: 50, prevBase: 50,
                                 shapedBase: 50, dt: 3), "3s 拍 0.1°C/s 通过")
    // 关键回归：10s 拍 0.11°C/s（旧每拍判据 0.35°/拍 会拒绝）应通过
    expect(LearningGate.isSteady(temp: 71.1, prevTemp: 70, baseTarget: 50, prevBase: 50,
                                 shapedBase: 50, dt: 10), "10s 拍 0.11°C/s 通过（旧判据拒绝）")
    expect(!LearningGate.isSteady(temp: 71.3, prevTemp: 70, baseTarget: 50, prevBase: 50,
                                  shapedBase: 50, dt: 10), "10s 拍 0.13°C/s 拒绝")
    expect(!LearningGate.isSteady(temp: 71.0, prevTemp: 70, baseTarget: 50, prevBase: 50,
                                  shapedBase: 50, dt: 3), "3s 拍 0.33°C/s 拒绝")
    // 目标变化率 1%/s
    expect(!LearningGate.isSteady(temp: 70, prevTemp: 70, baseTarget: 55, prevBase: 50,
                                  shapedBase: 52, dt: 3), "目标 5%/3s 变化过快")
    expect(LearningGate.isSteady(temp: 70, prevTemp: 70, baseTarget: 52, prevBase: 50,
                                 shapedBase: 52, dt: 3), "目标 0.67%/s 通过")
    // 限速残留 gap（每拍语义保持）
    expect(!LearningGate.isSteady(temp: 70, prevTemp: 70, baseTarget: 60, prevBase: 60,
                                  shapedBase: 54, dt: 3), "shaped 残留 6% 拒绝（限速过渡态）")
    expect(LearningGate.isSteady(temp: 70, prevTemp: 70, baseTarget: 60, prevBase: 60,
                                 shapedBase: 58, dt: 3), "shaped 残留 2% 通过")
    // dt 防御
    expect(!LearningGate.isSteady(temp: 70, prevTemp: 60, baseTarget: 50, prevBase: 50,
                                  shapedBase: 50, dt: .nan), "NaN dt 拒绝")
    expect(!LearningGate.isSteady(temp: 70, prevTemp: 60, baseTarget: 50, prevBase: 50,
                                  shapedBase: 50, dt: 0.1), "过小 dt 拒绝")
}


// MARK: - v2.7 powermetrics 输出解析（回归：-u 参数不存在曾致功能静默失效）


func testPowerParser() {
    group("powermetrics 解析")
    // 默认输出单位 mW，必须换算为 W
    expectClose(PowerMetricsParser.watts(in: "CPU Power: 789 mW", key: "CPU Power:")!, 0.789, 1e-9, "mW 换算")
    expectClose(PowerMetricsParser.watts(in: "CPU Power: 12.34 W", key: "CPU Power:")!, 12.34, 1e-9, "W 直读")
    expectEqual(PowerMetricsParser.watts(in: "no data here", key: "CPU Power:"), nil, "无匹配 nil")
    expectEqual(PowerMetricsParser.watts(in: "CPU Power: -- mW", key: "CPU Power:"), nil, "无效数值 nil")
    // 多样本取最后一次
    let two = "CPU Power: 100 mW\nGPU Power: 50 mW\nCPU Power: 300 mW"
    expectClose(PowerMetricsParser.watts(in: two, key: "CPU Power:")!, 0.3, 1e-9, "多次出现取最后")
    expectClose(PowerMetricsParser.watts(in: two, key: "GPU Power:")!, 0.05, 1e-9, "GPU 行独立解析")
    // 界外值拒绝（防止坏解析污染前馈）
    expectEqual(PowerMetricsParser.watts(in: "CPU Power: 900 W", key: "CPU Power:"), nil, "超上限拒绝")
    expectEqual(PowerMetricsParser.watts(in: "CPU Power: 0.001 mW", key: "CPU Power:"), nil, "低于下限拒绝")
    // 千分位逗号并入数值（按标点切分会被采信成 0.012 W，错 1000 倍且通过范围检查）
    expectClose(PowerMetricsParser.watts(in: "CPU Power: 12,345 mW", key: "CPU Power:")!, 12.345, 1e-9, "千分位逗号")
    // 词内紧邻单位
    expectClose(PowerMetricsParser.watts(in: "CPU Power: 789mW", key: "CPU Power:")!, 0.789, 1e-9, "词内紧邻单位")
}

