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
    } else {
        print("AI 热经验: 尚无数据")
    }
    // 今日战报摘要（调速次数 = |输出Δ|≥3% 的拍数，风扇寿命代理指标）
    if let s = ConfigStore.loadStats(), s.date == DailyStats.today(), s.tempCount > 0 {
        print("今日: 最高 \(String(format: "%.1f", s.maxTemp))°C · 调速 \(Int(s.speedChanges)) 次 · 启停抑制 \(Int(s.aiCyclingGuards)) 次 · 静音/安静 \(Int(s.quietSeconds / 60)) 分钟")
    }
    if let m = ConfigStore.loadAIMetrics(), m.sampleCount > 0 {
        print(String(format: "AI 指标: %.1f 分钟 | 平均 %.1f°C | 波动 %.1f°C | 平均输出 %.1f%% | 超温 %.0f 秒",
                     m.activeSeconds / 60, m.averageTemp, m.temperatureStdDev,
                     m.averageOutput, m.highTempSeconds))
    }
} catch {
    print("SMC 访问失败: \(error)")
    exit(1)
}
