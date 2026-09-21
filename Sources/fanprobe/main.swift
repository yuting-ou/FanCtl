import Foundation
import SMCCore

// fanprobe — 只读诊断工具：打印温度传感器、风扇状态、daemon 实时状态与 AI 学习进度（无需 root）

do {
    let smc = try SMCConnection()
    let fans = try FanController(smc: smc)
    let sensors = try TemperatureSensors(smc: smc)

    let counts = sensors.sensorCounts
    print("传感器: CPU x\(counts.cpu), GPU x\(counts.gpu), SSD x\(counts.nand), 电池 x\(counts.batt), 掌托 x\(counts.palm), 散热片 x\(counts.heatsink), 其他 x\(counts.other)")
    print(String(format: "CPU 热点: %.1f°C", sensors.cpuTemperature))
    print(String(format: "GPU 热点: %.1f°C", sensors.gpuTemperature))
    if counts.nand > 0 { print(String(format: "SSD 热点: %.1f°C", sensors.nandTemperature)) }
    if counts.batt > 0 { print(String(format: "电池温度: %.1f°C", sensors.batteryTemperature)) }
    if counts.palm > 0 { print(String(format: "掌托温度: %.1f°C", sensors.palmRestTemperature)) }
    if counts.heatsink > 0 { print(String(format: "散热片温度: %.1f°C", sensors.heatsinkTemperature)) }
    if let w = sensors.systemPowerWatts { print(String(format: "整机功耗: %.1f W", w)) }
    print("风扇数量: \(fans.fanCount)")
    for st in fans.allStates() {
        print(String(format: "  风扇 %d: 当前 %.0f RPM | 目标 %.0f | 范围 %.0f ~ %.0f",
                     st.id + 1, st.actualRPM, st.targetRPM, st.minRPM, st.maxRPM))
    }

    // daemon 实时状态（status.json 超过 30s 视为离线）
    // 阈值与 App 一致：daemon idle 状态循环间隔可达 20s（LOOP_INTERVAL_IDLE），
    // status 每 20s 才更新一次——此前用 15s 会在低负载时误报"未运行"
    if let s = ConfigStore.loadStatus(),
       Date().timeIntervalSince(s.timestamp) < 30 {
        print("daemon: 运行中 | 模式 \(s.mode.rawValue) | 主因 \(s.reason?.label ?? "-")"
            + " | 输出 \(Int(s.appliedPercent))%"
            + (s.aiIntent.map { " | 意图 \($0.label)" } ?? "")
            + (s.controlFault == true ? " | 故障 \(s.faultReason?.rawValue ?? "unknown")" : "")
            + (s.onBattery == true ? " | 电池供电" : ""))
    } else {
        print("daemon: 未运行（调速不生效）")
    }

    // AI 热经验学习进度
    if let learn = ConfigStore.loadLearn() {
        print("AI 热经验: \(learn.sampleTotal) 样本 / \(learn.learnedBucketCount) 个温度点")
        // R31：生效查表（含 R27 单调包络）vs 桶 raw EMA——展示与控制可能不同
        print("学习生效查表 percent(for:)（raw=同桶 samples≥min 的 EMA）:")
        for t in [55.0, 65.0, 70.0, 73.0, 75.0, 80.0] {
            let eff = learn.percent(for: t)
            let effStr = eff.map { String(format: "%.0f%%", $0) } ?? "nil"
            print(String(format: "  %.0f°C → %@", t, effStr))
        }
        let pts = learn.learnedPoints()
        let rawParts = pts.filter { $0.samples >= ThermalLearn.minSamples }
            .map { String(format: "%.0f°C:%.0f%%(n=%d)", $0.temp, $0.percent, $0.samples) }
        if !rawParts.isEmpty {
            print("  raw 采信桶: " + rawParts.joined(separator: " · "))
        }
    } else {
        print("AI 热经验: 尚无数据")
    }
    // v3.6 学习图包络健康度（方向二·数据裁判）：>0 = 高温段旧非单调数据未被新样本
    // 洗净（查询层单调包络在兜底修正，控制不受影响）；→0 = 已自愈。观察协议见 EVOLUTION.md
    if let s = ConfigStore.loadStatus(), s.learnEnvelopeGap != nil {
        print(String(format: "学习图包络健康度: %.1f°（→0 = 高温段已自愈）", s.learnEnvelopeGap!))
    }
    // 今日战报摘要（调速次数 = |输出Δ|≥3% 的拍数，风扇寿命代理指标）
    if let s = ConfigStore.loadStats(), s.date == DailyStats.today(), s.tempCount > 0 {
        print("今日: 最高 \(String(format: "%.1f", s.maxTemp))°C · 调速 \(Int(s.speedChanges)) 次 · 启停抑制 \(Int(s.aiCyclingGuards)) 次\(s.overshootPeak >= 3 ? " · 过冲峰值 +\(Int(s.overshootPeak.rounded()))°" : "") · 静音/安静 \(Int(s.quietSeconds / 60)) 分钟")
        print(String(format: "  磨损速率: %.2f 次/受控分（R29 口径；批次B门看趋势）",
                     s.speedChangesPerMinute))
    }
    // R32：近 14 归档日磨损速率 + 今日实时（history 未必含今天；裁决看趋势不看单日）
    // 防御性按日期排序：archiveDay 维护有序，但损坏/手改 JSON 不保证；suffix(14) 才是「最近」
    do {
        var rows: [(String, Double, Double)] = []
        let hist = ConfigStore.loadHistory().sorted { $0.date < $1.date }
        for d in hist.suffix(14) where d.tempSeconds > 30 {
            rows.append((d.date, d.speedChanges, d.speedChangesPerMinute))
        }
        if let s = ConfigStore.loadStats(), s.date == DailyStats.today(), s.tempSeconds > 30 {
            if let last = rows.last, last.0 == s.date { rows.removeLast() }
            rows.append((s.date, s.speedChanges, s.speedChangesPerMinute))
        }
        if !rows.isEmpty {
            print("磨损速率趋势（次/受控分，R29 口径；近 14 归档日 + 今日实时）:")
            for (date, ch, rate) in rows {
                print(String(format: "  %@: %.2f（调速 %.0f 次）", date, rate, ch))
            }
        }
    }
    if let m = ConfigStore.loadAIMetrics(), m.sampleCount > 0 {
        print(String(format: "AI 指标: %.1f 分钟 | 平均 %.1f°C | 波动 %.1f°C | 平均输出 %.1f%% | 超温 %.0f 秒",
                     m.activeSeconds / 60, m.averageTemp, m.temperatureStdDev,
                     m.averageOutput, m.highTempSeconds))
    }
    // v3.8 D 项 dt 账本（EVOLUTION R8 预注册裁决；4.1-A3 规则修订见 EVOLUTION R17）：
    //   D 快拍/标称比 = 快拍 D 每秒贡献 ÷ 标称拍 D 每秒贡献。当前律下按构造 ≈3×斜率比
    //   （选择偏差保证 ≥3），该比值只作诊断；裁决 = 快拍秒占比门槛 + VM 危害测试。
    //   P 基线跨桶不等 = 选择偏差的预期表现（4.0.1 起退役"校准线"语义）。
    // 4.0.1（4.1-A1）：账本在独立 dt-ledger.json（生命周期 = 控制律版本，与评测指标解耦）。
    let ledger = ConfigStore.loadDTLedger()
    let buckets: [(String, DTermLedgerBucket?)] = [
        ("快拍<1.5s", ledger?.fast), ("标称1.5-4.5s", ledger?.nominal), ("长拍>4.5s", ledger?.slow)]
    if let l = ledger, buckets.contains(where: { $0.1?.seconds ?? 0 > 0 }) {
        let started = l.startedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "?"
        print(String(format: "D 项 dt 账本（自 %@，受控 %.2f 天）:", started, l.totalSeconds / 86400))
        for (label, b) in buckets {
            guard let b, b.seconds > 0 else { continue }
            let dRate = b.dRatePerSecond ?? 0
            let pRate = b.pRatePerSecond ?? 0
            let dInt = b.dIntensity.map { String(format: "%.1f", $0) } ?? "-"
            print(String(format: "  %@: %d 拍 / %.0f 分钟 | D 每秒 %.2f%% | P 每秒 %.2f%% | 斜率权重 %.0f | I_D %@",
                         label, b.samples, b.seconds / 60, dRate, pRate, b.slopeWeightedSum, dInt))
        }
        if let share = l.fastSecondsShare {
            print(String(format: "  ⇒ 快拍秒占比: %.1f%%（裁决暴露度门槛 5%%）", share * 100))
        }
    }
    // v3.8 硬件画像（陌生机器 issue 首问）
    if let s = ConfigStore.loadStatus(), let hp = s.hardwareProfile {
        print("硬件画像: \(hp.oneLine)")
    }
    // R31：热模型诊断（status 下发；usable 与 predictedPercent 同门 b>2.5）
    if let s = ConfigStore.loadStatus() {
        if let usable = s.thermalModelUsable {
            let b = s.thermalModelB.map { String(format: "%.2f", $0) } ?? "-"
            print("热模型: \(usable ? "可用" : "不可用（预测回退查表）") | b=\(b) | 样本 \(s.thermalModelSamples ?? 0)")
        }
    }
    // R32：磁盘热模型明细（status 只带 b/samples/usable；辨识带与 a 仅文件有）
    if let m = ConfigStore.loadModel() {
        let pw: String
        if let lo = m.minPower, let hi = m.maxPower {
            pw = String(format: "%.1f–%.1fW", lo, hi)
        } else { pw = "-" }
        let env: String
        if let lo = m.minEnv, let hi = m.maxEnv {
            env = String(format: "%.1f–%.1f°C", lo, hi)
        } else { env = "-" }
        print(String(format: "热模型文件: a=%.2f b=%.2f 样本 %d | 采信带 功耗 %@ 环境 %@ | mature=%@",
                     m.a, m.b, m.sampleCount, pw, env, m.isMature ? "true" : "false"))
    }
} catch {
    print("SMC 访问失败: \(error)")
    exit(1)
}
