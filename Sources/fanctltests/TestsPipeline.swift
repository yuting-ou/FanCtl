// 测试按模块拆分（v3.3.1）：本文件为各模块共享的 harness 与主入口。
// 断言 harness 见 main.swift，共享构造（MockSMC/FakeClock/makeEngine）见 TestsEngine.swift 头部。
import Foundation
import SMCCore

// MARK: - 决策管线 FanPipeline（守护进程同款代码，无镜像漂移）

// 标准决策环境：只改配置与温度参数，其余取常用默认
func decide(_ config: FanConfig,
            smoothed: Double = 60, raw: Double? = nil, nand: Double = 40,
            battery: Bool = false, ai: Double? = nil,
            now: Date = Date(), wasSSDGuardActive: Bool = false,
            wasSSDCriticalActive: Bool = false, wasFailsafeActive: Bool = false,
            batt: Double = 36, wasBatteryGuardActive: Bool = false,
            wasBatteryCriticalActive: Bool = false) -> FanPipeline.Decision {
    FanPipeline.decide(config: config, smoothedTemp: smoothed, rawTemp: raw ?? smoothed,
                       nandTemp: nand, onBattery: battery, aiPercent: ai, now: now,
                       wasSSDGuardActive: wasSSDGuardActive,
                       wasSSDCriticalActive: wasSSDCriticalActive,
                       wasFailsafeActive: wasFailsafeActive,
                       battTemp: batt,
                       wasBatteryGuardActive: wasBatteryGuardActive,
                       wasBatteryCriticalActive: wasBatteryCriticalActive)
}


// MARK: - v3.6.3 变异测试补洞：安全阈值边界用字面量断言
// P5/P6 变异体（兜底 >=→>、SSD 危急档 100→60）曾存活——暴露两处盲区：
// 边界整点无断言 + 期望值从实现常量反推。以下全部用字面量，锁死语义。

func testSafetyThresholdBoundaries() {
    group("安全阈值边界（字面量，防变异回潮）")
    // SSD 托底三档边界
    expectEqual(FanPipeline.ssdFloor(nandTemp: 78), 100, "SSD 78° 整点 = 危急档 100")
    expectEqual(FanPipeline.ssdFloor(nandTemp: 77.9), 60, "SSD 77.9° = 警告档 60")
    expectEqual(FanPipeline.ssdFloor(nandTemp: 69.9), nil, "SSD 69.9° 不托底")
    expectEqual(FanPipeline.ssdFloor(nandTemp: 70), 60, "SSD 70° 整点 = 警告档")
    // 高温兜底 92° 整点含（>= 语义）
    let dIn = decide(FanConfig(mode: .curve), smoothed: 80, raw: 92)
    expectEqual(dIn.targetPercent, 100, "兜底 92° 整点含")
    expectEqual(dIn.reason, .failsafe, "92° 主因 = 兜底")
    let dOut = decide(FanConfig(mode: .curve), smoothed: 80, raw: 91.9)
    expect(dOut.targetPercent != 100, "兜底 91.9° 不触发")
    // 电池危急 48° 整点 / 警告 45° 整点
    let bCrit = FanPipeline.batteryState(battTemp: 48, wasGuardActive: false, wasCriticalActive: false)
    expect(bCrit.criticalActive && bCrit.floor == 100, "电池 48° 整点 = 危急 100")
    let bWarn = FanPipeline.batteryState(battTemp: 45, wasGuardActive: false, wasCriticalActive: false)
    expect(bWarn.guardActive && !bWarn.criticalActive && bWarn.floor == 60, "电池 45° 整点 = 警告 60")
    // 释放滞回边界：激活后回落——88° 整点仍保持（>= 语义），87.9° 才释放
    let dHold = decide(FanConfig(mode: .curve), smoothed: 80, raw: 88, wasFailsafeActive: true)
    expectEqual(dHold.targetPercent, 100, "兜底释放滞回：88° 整点仍激活")
    let dRel = decide(FanConfig(mode: .curve), smoothed: 80, raw: 87.9, wasFailsafeActive: true)
    expect(dRel.targetPercent != 100, "兜底 87.9° 释放")
}

// MARK: - v2.7 电池高温托底（与 SSD 同构的安全红线）


func testPipelineCodable() {
    group("管线 Codable")
    do {
        let cfg = FanConfig(mode: .curve, preset: .balanced,
                            quietUntil: Date(timeIntervalSince1970: 1_800_000_000), quietCapPercent: 30)
        let back = try JSONDecoder().decode(FanConfig.self, from: try JSONEncoder().encode(cfg))
        expect(back.quietCapPercent == 30 && back.quietUntil != nil, "quiet 字段往返")
        let legacy = #"{"mode":"curve","manualPercent":50,"curve":[{"temp":52,"percent":0},{"temp":85,"percent":100}]}"#.data(using: .utf8)!
        let lc = try JSONDecoder().decode(FanConfig.self, from: legacy)
        expect(lc.quietUntil == nil && lc.quietCapPercent == nil, "旧 config 无 quiet 字段兼容")
        // sanitized 不影响 quiet 字段
        let future = Date().addingTimeInterval(600)
        let sanitized = FanConfig(mode: .curve, curve: [], preset: .quiet,
                                  quietUntil: future, quietCapPercent: 30).sanitized()
        expect(sanitized.quietCapPercent == 30, "sanitized 保留 quiet 字段")
        // 关键回归：config 含 Date 时编解码策略必须一致（iso8601），
        // 否则 daemon 读不出静音字段 → 静音模式静默失效。镜像 ConfigStore 的策略：
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let iso = try dec.decode(FanConfig.self, from: try enc.encode(cfg))
        expect(iso.quietUntil != nil && iso.quietCapPercent == 30, "iso8601 策略下 quiet 字段可解码")
        // 交叉：默认策略写、iso8601 读——Date 字段应解失败（证明策略不匹配会真出问题）
        let mismatchData = try JSONEncoder().encode(cfg)   // 默认=Double 时间戳
        let mismatch = try? dec.decode(FanConfig.self, from: mismatchData)  // iso8601 读
        expect(mismatch == nil || mismatch?.quietUntil == nil, "策略不匹配时 Date 无法还原（需统一策略）")
        // reason 往返 + 旧 status 兼容
        let st = DaemonStatus(cpuTemp: 70, gpuTemp: 55, mode: .curve, appliedPercent: 45,
                              fans: [], reason: .ssd)
        let stb = try dec.decode(DaemonStatus.self, from: try enc.encode(st))
        expect(stb.reason == .ssd, "reason 字段往返")
        // aiIntent 往返 + 旧版 status（无此字段）解码为 nil
        let sta = DaemonStatus(cpuTemp: 70, gpuTemp: 55, mode: .ai, appliedPercent: 45,
                               fans: [], reason: .ai, aiIntent: .rising)
        let stab = try dec.decode(DaemonStatus.self, from: try enc.encode(sta))
        expect(stab.aiIntent == .rising, "aiIntent 字段往返")
        let legacyStatus = #"{"cpuTemp":70,"gpuTemp":55,"mode":"curve","appliedPercent":45,"fans":[],"timestamp":"2026-07-31T10:00:00Z"}"#.data(using: .utf8)!
        let ls = try dec.decode(DaemonStatus.self, from: legacyStatus)
        expect(ls.reason == nil && ls.aiIntent == nil, "旧 status 无 reason/aiIntent 字段兼容")
        // v2.7: aiTargetEffective 往返 + 旧 status 兼容
        let stE = DaemonStatus(sensors: SensorReadings(cpuDie: 70, gpuDie: 55), mode: .ai,
                               appliedPercent: 40, fans: [], aiTargetEffective: 82.0)
        let stEb = try dec.decode(DaemonStatus.self, from: try enc.encode(stE))
        expectEqual(stEb.aiTargetEffective!, 82.0, "aiTargetEffective 往返")
        expect(ls.aiTargetEffective == nil, "旧 status 无 aiTargetEffective 兼容")
        // v2.7 前向兼容：旧 App 读新 daemon 写出的未知枚举 case → 该字段降级 nil，
        // 其余字段照常解码（此前整包失败，App 误判 daemon 离线，恰在过热时段）
        let futureStatus = #"{"cpuTemp":70,"gpuTemp":55,"mode":"curve","appliedPercent":45,"fans":[],"timestamp":"2026-07-31T10:00:00Z","reason":"someFutureReason","aiIntent":"alsoFuture","faultReason":"futureFault"}"#.data(using: .utf8)!
        let lsF = try dec.decode(DaemonStatus.self, from: futureStatus)
        expect(lsF.reason == nil && lsF.aiIntent == nil, "未知枚举 case 降级 nil")
        expect(lsF.faultReason == nil, "未知 faultReason case 降级 nil")
        expectEqual(lsF.appliedPercent, 45, "未知枚举 case 不影响其余字段解码")
        expectEqual(lsF.cpuTemp, 70, "未知枚举 case 不影响温度字段")
    } catch { expect(false, "管线 Codable 抛错: \(error)") }
}


// MARK: - 风扇偏移与传感器读数安全语义

