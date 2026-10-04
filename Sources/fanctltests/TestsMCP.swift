// TestsMCP —— 清风 MCP 服务器（SMCCore.FanMCP）回归
//
// 覆盖：协议帧（握手/通知不回信/批量拒绝/坏 JSON/未知方法/ping）、工具清单契约、
// status/stats 只读面、set_mode/set_ai_target/quiet/boost 意图面（含互斥与钳位）、
// 参数类型防御（布尔≠数值、数字字符串容忍、未知工具 -32602）、写盘失败可见化、
// NaN 防御、fanprobe 失败关闭、fanmcpVersion 与 VERSION 同源。
// IO 全走 Hooks 注入；涉及真实 ConfigStore 的用例先把 FanCtlPaths 重定向到临时目录
// （engineTestEnv 同款纪律，不碰真实 /Library 安装）。

import Foundation
import SMCCore

func testFanMCP() {
    group("清风 MCP 服务器(R83)")

    // MARK: 夹具与时钟

    let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)
    func makeHooks(loadStatus: @escaping () -> DaemonStatus? = { nil },
                   loadStats: @escaping () -> DailyStats? = { nil },
                   loadHistory: @escaping () -> [DailyStats] = { [] },
                   loadConfig: @escaping () -> FanConfig = { FanConfig().sanitized() },
                   saveConfig: @escaping (FanConfig) -> Bool = { _ in true },
                   runDiagnostics: @escaping () -> FanMCPDiagnosis = { .failure("未找到 /usr/local/bin/fanprobe") }
    ) -> FanMCP.Hooks {
        var h = FanMCP.Hooks()
        h.now = { fixedNow }
        h.loadStatus = loadStatus
        h.loadStats = loadStats
        h.loadHistory = loadHistory
        h.loadConfig = loadConfig
        h.saveConfig = saveConfig
        h.runDiagnostics = runDiagnostics
        return h
    }

    func makeStatus(envTemp: Double? = 28.17, powerWatts: Double? = 33.44) -> DaemonStatus {
        DaemonStatus(
            sensors: SensorReadings(cpuDie: 68.034, cpuAverage: 52.87, gpuDie: 48.7,
                                    ssd: 42.2, palmRest: 44.3, heatsink: 66.6,
                                    otherHotspots: ["Te06": 51.68]),
            mode: .ai, appliedPercent: 64, appliedPercents: [64, 64],
            fans: [FanStatusEntry(id: 0, actualRPM: 4192.1, targetRPM: 3909.36, minRPM: 1350, maxRPM: 5349),
                   FanStatusEntry(id: 1, actualRPM: 4493.1, targetRPM: 4222.16, minRPM: 1458, maxRPM: 5777)],
            timestamp: fixedNow.addingTimeInterval(-5),
            onBattery: false, batteryOverride: false,
            reason: .ai, aiIntent: .falling, loopInterval: 1,
            controlFault: false, faultReason: nil,
            baseTargetPercent: 49.87, safetyFloorPercent: nil, curveTargetPercent: 6.46,
            learningRecently: false, learnedPoints: 8, learnedSamples: 1903,
            targetUnreachable: false, aiHighEffort: false,
            powerWatts: powerWatts, nightOverride: true, envTemp: envTemp,
            aiTargetEffective: 73.58, palmComp: 4, learnEnvelopeGap: 2.54,
            learnMap: nil,
            decisionTrace: DecisionTrace(target: 73.58, temp: 69.18, error: -4.4,
                                         learned: 63.3, idle: false, hysteresisHold: false,
                                         guardSeconds: nil),
            hardwareProfile: HardwareProfile(
                modelID: "Mac14,10", chipName: "Apple M2 Pro", osVersion: "27.0.1",
                fanCount: 2,
                sensorCounts: HardwareProfile.SensorCountSummary(cpu: 54, gpu: 10, nand: 9,
                                                                 batt: 3, palm: 8, heatsink: 45, other: 110),
                hasPowerKey: true, collectedAt: fixedNow.addingTimeInterval(-600)),
            calibrating: false, thermalModelUsable: true, thermalModelB: 94.75,
            thermalModelSamples: 87, daemonVersion: "4.2.49 (143)")
    }

    // MARK: 协议小工具（断言前先 guard 绑定——失败走断言消息而非 trap，exit133 教训）

    func requestLine(_ method: String, _ params: [String: Any]? = nil, id: Any = 1) -> String {
        var req: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let p = params { req["params"] = p }
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    func parse(_ srv: FanMCP, _ line: String) -> [String: Any]? {
        guard let out = srv.handle(line),
              let obj = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] else { return nil }
        return obj
    }

    func resultOf(_ srv: FanMCP, _ line: String) -> [String: Any]? {
        parse(srv, line)?["result"] as? [String: Any]
    }

    func errorOf(_ srv: FanMCP, _ line: String) -> (code: Int, message: String)? {
        guard let e = parse(srv, line)?["error"] as? [String: Any],
              let code = e["code"] as? Int else { return nil }
        return (code, e["message"] as? String ?? "")
    }

    /// 调工具并解析 content[0].text 里的 JSON；isError 直接透出
    func callTool(_ srv: FanMCP, _ name: String, _ args: [String: Any]) -> (isError: Bool, json: [String: Any]?, text: String) {
        guard let result = resultOf(srv, requestLine("tools/call",
                                                     ["name": name, "arguments": args])) else {
            return (true, nil, "无 result 帧")
        }
        let content = result["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        return (result["isError"] as? Bool ?? false, json, text)
    }

    // MARK: 临时目录环境（真实 ConfigStore 的用例用）

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fanmcp-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    FanCtlPaths.setOverridesForTesting(supportDir: dir, logDir: dir)
    defer { FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil) }

    // MARK: 协议帧

    var hooks = makeHooks(loadStatus: { makeStatus() })
    let srv = FanMCP(version: "test", hooks: hooks)

    // 握手：支持集内的版本原样回
    if let r = resultOf(srv, requestLine("initialize", ["protocolVersion": "2025-03-26",
                                                        "capabilities": [:], "clientInfo": ["name": "t"]])) {
        expectEqual(r["protocolVersion"] as? String, "2025-03-26", "握手回显客户端版本")
        let info = r["serverInfo"] as? [String: Any]
        expectEqual(info?["name"] as? String, "qingfeng", "serverInfo.name")
        expect((info?["version"] as? String)?.isEmpty == false, "serverInfo.version 在场")
        let caps = r["capabilities"] as? [String: Any]
        expect((caps?["tools"] as? [String: Any]) != nil, "capabilities.tools 在场")
    } else {
        expect(false, "initialize 应有 result")
    }
    // 握手：不支持的版本回落服务器最新
    if let r = resultOf(srv, requestLine("initialize", ["protocolVersion": "1999-01-01"])) {
        expectEqual(r["protocolVersion"] as? String, FanMCP.latestProtocolVersion, "未知版本回落最新")
    } else { expect(false, "initialize（未知版本）应有 result") }
    // 握手：缺 protocolVersion 也容忍
    expect(resultOf(srv, requestLine("initialize")) != nil, "initialize 缺参数不炸")

    // 通知一律不回信
    expect(srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") == nil,
           "通知不回信")
    expect(srv.handle("   \n") == nil, "空行忽略")
    // 批量已移除
    expectEqual(errorOf(srv, "[{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"id\":1}]")?.code, -32600,
                "批量数组 -32600")
    // 坏 JSON
    expectEqual(errorOf(srv, "not json at all")?.code, -32700, "坏 JSON -32700")
    // 缺 method
    expectEqual(errorOf(srv, "{\"jsonrpc\":\"2.0\",\"id\":1}")?.code, -32600, "缺 method -32600")
    // 未知方法回 -32601 且 id 原样带回
    if let e = errorOf(srv, requestLine("no/such/method")) {
        expectEqual(e.code, -32601, "未知方法 -32601")
    } else { expect(false, "未知方法应有 error 帧") }
    if let raw = parse(srv, "{\"jsonrpc\":\"2.0\",\"method\":\"x/y\",\"id\":\"abc\"}") {
        expectEqual(raw["id"] as? String, "abc", "error 帧 id 原样带回")
    } else { expect(false, "未知方法(id=字符串)应有帧") }
    // ping
    expect((resultOf(srv, requestLine("ping")) ?? [:]).isEmpty, "ping 回空 result")

    // MARK: 工具清单契约

    if let tools = resultOf(srv, requestLine("tools/list"))?["tools"] as? [[String: Any]] {
        expectEqual(tools.count, 8, "工具数 8")
        let names = tools.compactMap { $0["name"] as? String }
        expectEqual(Set(names).count, 8, "工具名唯一")
        let readOnlies = ["fanctl_status", "fanctl_config_get", "fanctl_stats", "fanctl_diagnose"]
        for t in tools {
            let n = t["name"] as? String ?? "?"
            guard let ann = t["annotations"] as? [String: Any],
                  let ro = ann["readOnlyHint"] as? Bool else {
                expect(false, "\(n) 缺 annotations.readOnlyHint"); continue
            }
            guard let sch = t["inputSchema"] as? [String: Any] else {
                expect(false, "\(n) 缺 inputSchema"); continue
            }
            expectEqual(sch["type"] as? String, "object", "\(n) schema type=object")
            expectEqual(ro, readOnlies.contains(n), "\(n) readOnlyHint 标注正确")
            guard let desc = t["description"] as? String else {
                expect(false, "\(n) 缺 description"); continue
            }
            expect(desc.count >= 20, "\(n) description 过短（LLM 靠它选工具）")
        }
    } else { expect(false, "tools/list 应有 tools 数组") }

    // MARK: status 工具

    if let j = callTool(srv, "fanctl_status", [:]).json {
        expectEqual(j["mode"] as? String, "ai", "status.mode 转述")
        expectEqual(j["statusAgeSeconds"] as? Double, 5, "status.statusAgeSeconds（注入时钟）")
        expectEqual(j["statusFresh"] as? Bool, true, "status 新鲜判定")
        let sensors = j["sensors"] as? [String: Any]
        expectEqual(sensors?["cpuDie"] as? Double, 68.0, "cpuDie 四舍五入到 0.1°")
        let fans = j["fans"] as? [[String: Any]]
        expectEqual(fans?.count, 2, "双风扇都在场")
        expectEqual(j["daemonVersion"] as? String, "4.2.49 (143)", "daemonVersion 透传")
        let safety = j["safety"] as? [String: Any]
        expectEqual(safety?["controlFault"] as? Bool, false, "controlFault 缺省 false（nil→false，展示语义）")
        expect((j["reason"] as? String)?.contains("AI") == true, "reason 带 label")
    } else { expect(false, "fanctl_status 应返回 JSON") }

    // status：status.json 缺失 → 可执行错误（不是协议炸）
    hooks = makeHooks(loadStatus: { nil })
    let srvNoStatus = FanMCP(version: "test", hooks: hooks)
    let miss = callTool(srvNoStatus, "fanctl_status", [:])
    expect(miss.isError, "无 status.json → isError")
    expect(miss.text.contains("status.json"), "错误里指路 status.json")

    // status：NaN 防御——坏值过滤成 null 而不是炸序列化
    hooks = makeHooks(loadStatus: { makeStatus(envTemp: .nan, powerWatts: .nan) })
    let srvNaN = FanMCP(version: "test", hooks: hooks)
    if let j = callTool(srvNaN, "fanctl_status", [:]).json {
        expect(j["powerWatts"] is NSNull, "NaN 功耗 → null（不炸 JSON）")
        expect(j["envTemp"] is NSNull, "NaN 环境温度 → null")
    } else { expect(false, "NaN status 也应返回合法 JSON") }

    // MARK: 意图面（真实 ConfigStore + 临时目录）

    func freshConfigSrv() -> FanMCP {
        var h = FanMCP.Hooks()
        h.now = { fixedNow }
        return FanMCP(version: "test", hooks: h)   // load/save 走默认 ConfigStore（已重定向）
    }

    func seedConfig(_ seed: (inout FanConfig) -> Void) {
        var c = FanConfig(mode: .ai, aiTargetTemp: 72).sanitized()
        seed(&c)
        expect(ConfigStore.saveConfig(c), "seedConfig 落盘成功")
    }

    // set_mode：合法切换 + manualPercent
    seedConfig { _ in }
    let srvCfg = freshConfigSrv()
    let r1 = callTool(srvCfg, "fanctl_set_mode", ["mode": "manual", "manualPercent": 40])
    expect(!r1.isError, "set_mode manual 40 成功（\(r1.text.prefix(120))）")
    let c1 = ConfigStore.loadConfig()
    expectEqual(c1.mode, FanMode.manual, "config.mode 已切 manual")
    expectEqual(c1.manualPercent, 40, "config.manualPercent 已写")

    // set_mode：未知模式 → 工具错误并指路合法值
    let r2 = callTool(srvCfg, "fanctl_set_mode", ["mode": "turbo"])
    expect(r2.isError, "mode=turbo → isError")
    expect(r2.text.contains("auto / curve / ai / manual"), "错误列出合法模式")
    expectEqual(ConfigStore.loadConfig().mode, FanMode.manual, "失败不落盘")

    // set_mode：curve + preset 同时改写曲线点
    let r3 = callTool(srvCfg, "fanctl_set_mode", ["mode": "curve", "curvePreset": "aggressive"])
    expect(!r3.isError, "set_mode curve+aggressive 成功")
    let c3 = ConfigStore.loadConfig()
    expectEqual(c3.preset, CurvePreset.aggressive, "preset 已写")
    expectEqual(c3.curve, CurvePreset.aggressive.points, "曲线点与预设同源")
    // curvePreset 类型错（数字）也出声
    expect(callTool(srvCfg, "fanctl_set_mode", ["mode": "curve", "curvePreset": 123]).isError,
           "curvePreset 数字 → isError")
    // 切走 manual 时陈旧 boost 截止被清掉
    seedConfig { $0.mode = .manual; $0.manualPercent = 100; $0.boostUntil = fixedNow.addingTimeInterval(600) }
    expect(callTool(srvCfg, "fanctl_set_mode", ["mode": "ai"]).isError == false, "manual→ai 切换成功")
    expect(ConfigStore.loadConfig().boostUntil == nil, "切走 manual 清陈旧 boostUntil")

    // set_ai_target：合法 + 越界拒绝（84 上限的理由写进错误信息）
    seedConfig { _ in }
    expect(callTool(srvCfg, "fanctl_set_ai_target", ["targetTemp": 70]).isError == false,
           "targetTemp 70 成功")
    expectEqual(ConfigStore.loadConfig().aiTargetTemp ?? -1, 70, "aiTargetTemp 已写")
    let badT = callTool(srvCfg, "fanctl_set_ai_target", ["targetTemp": 90])
    expect(badT.isError && badT.text.contains("84"), "targetTemp 90 拒绝并解释 84 上限")
    expect(callTool(srvCfg, "fanctl_set_ai_target", ["targetTemp": "72"]).isError == false,
           "数字字符串容忍（LLM 常见形态）")
    expectEqual(ConfigStore.loadConfig().aiTargetTemp ?? -1, 72, "字符串参数也落了盘")

    // quiet：开启（默认参数）、互斥清 boost、解除
    seedConfig { $0.boostUntil = fixedNow.addingTimeInterval(600) }
    let rq = callTool(srvCfg, "fanctl_quiet", ["enable": true, "minutes": 45, "capPercent": 25])
    expect(!rq.isError, "quiet 开启成功（\(rq.text.prefix(120))）")
    let cq = ConfigStore.loadConfig()
    expectEqual(cq.quietUntil, fixedNow.addingTimeInterval(45 * 60), "quietUntil = now+45min（注入时钟下精确）")
    expectEqual(cq.quietCapPercent ?? -1, 25, "quietCapPercent 已写")
    expect(cq.boostUntil == nil, "静音启动清掉冲刺（App 同款互斥）")
    expect(callTool(srvCfg, "fanctl_quiet", ["enable": false]).isError == false, "quiet 解除成功")
    let cq2 = ConfigStore.loadConfig()
    expect(cq2.quietUntil == nil && cq2.quietCapPercent == nil, "解除后双字段清空")
    // 参数钳位
    expect(callTool(srvCfg, "fanctl_quiet", ["enable": true, "minutes": 500]).text.contains("1–480"),
           "minutes 500 拒绝并给范围")
    expect(callTool(srvCfg, "fanctl_quiet", ["enable": true, "capPercent": 150]).isError,
           "capPercent 150 拒绝")
    expect(callTool(srvCfg, "fanctl_quiet", ["enable": 1]).isError, "enable=1（数值）拒绝——布尔≠数值")

    // boost：开启（互斥清 quiet）、到期自动恢复、提前结束回 auto
    seedConfig { $0.mode = .ai; $0.quietUntil = fixedNow.addingTimeInterval(600); $0.quietCapPercent = 30 }
    let rb = callTool(srvCfg, "fanctl_boost", ["minutes": 10])
    expect(!rb.isError, "boost 开启成功")
    let cb = ConfigStore.loadConfig()
    expectEqual(cb.mode, FanMode.manual, "boost → manual")
    expectEqual(cb.manualPercent, 100, "boost → 100%")
    expectEqual(cb.boostUntil, fixedNow.addingTimeInterval(10 * 60), "boostUntil = now+10min")
    expect(cb.quietUntil == nil, "冲刺启动清掉静音（App 同款互斥）")
    expect(callTool(srvCfg, "fanctl_boost", ["end": true]).isError == false, "boost 提前结束")
    let cb2 = ConfigStore.loadConfig()
    expectEqual(cb2.mode, FanMode.auto, "提前结束回 auto（MCP 不存冲刺前快照，诚实语义）")
    expect(cb2.boostUntil == nil, "结束后 boostUntil 清空")
    expect(callTool(srvCfg, "fanctl_boost", ["minutes": 120]).text.contains("1–60"),
           "minutes 120 拒绝并给范围")

    // 写盘失败必须出声（App 同一条可见化纪律）
    var failHooks = makeHooks(loadConfig: { FanConfig().sanitized() }, saveConfig: { _ in false })
    failHooks.now = { fixedNow }
    let srvFail = FanMCP(version: "test", hooks: failHooks)
    let rf = callTool(srvFail, "fanctl_set_mode", ["mode": "auto"])
    expect(rf.isError && rf.text.contains("配置写入失败"), "落盘失败 → isError + 指路")

    // MARK: stats

    var today = DailyStats(date: DailyStats.dayString(for: fixedNow))
    today.tempSum = 70 * 3600; today.tempSeconds = 3600; today.tempCount = 1200
    today.maxTemp = 81.5; today.highTempSeconds = 600; today.speedChanges = 63
    today.revolutions = 1_234_567; today.quietSeconds = 300; today.overshootPeak = 4.2
    var d1 = DailyStats(date: "2026-10-01"); d1.revolutions = 100; d1.tempSum = 60 * 1000; d1.tempSeconds = 1000
    var d2 = DailyStats(date: "2026-10-02"); d2.revolutions = 200; d2.tempSum = 62 * 2000; d2.tempSeconds = 2000
    hooks = makeHooks(loadStats: { today }, loadHistory: { [d1, d2] })
    let srvStats = FanMCP(version: "test", hooks: hooks)
    if let j = callTool(srvStats, "fanctl_stats", [:]).json {
        expectEqual(j["avgTemp"] as? Double, 70, "avgTemp 按秒加权（tempSum/tempSeconds）")
        expectEqual(j["speedChanges"] as? Double, 63, "speedChanges 在场")
        expectEqual(j["revolutions"] as? Double, 1_234_567, "revolutions 在场")
    } else { expect(false, "fanctl_stats 单日应返回 JSON") }
    expect(callTool(srvStats, "fanctl_stats", ["days": 31]).isError, "days 31 拒绝（窗口 30）")
    if let j = callTool(srvStats, "fanctl_stats", ["days": 3]).json {
        expectEqual(j["windowDays"] as? Int, 3, "3 天窗口（2 归档日 + 当日）")
        let totals = j["totals"] as? [String: Any]
        expectEqual(totals?["revolutions"] as? Double, 1_234_867, "跨天 revolutions 求和")
        expectEqual(totals?["avgTemp"] as? Double, 66.1, "跨天均温仍按秒加权（(60×1000+62×2000+70×3600)/6600=66.06→66.1）")
    } else { expect(false, "fanctl_stats 多日应返回 JSON") }

    // MARK: diagnose

    hooks = makeHooks()
    let srvDiag = FanMCP(version: "test", hooks: hooks)
    let rd = callTool(srvDiag, "fanctl_diagnose", [:])
    expect(rd.isError && rd.text.contains("fanprobe"), "diagnose 失败关闭并指路")
    hooks = makeHooks(runDiagnostics: { .success("== 诊断 ==\nOK") })
    let srvDiagOk = FanMCP(version: "test", hooks: hooks)
    expect(callTool(srvDiagOk, "fanctl_diagnose", [:]).text.contains("== 诊断 =="), "diagnose 成功透传")
    // 真实失败关闭路径：不存在的二进制 → failure，不 spawn
    if case .failure(let m) = FanMCP.runFanprobeReport(path: "/nonexistent/fanmcp-test-probe") {
        expect(m.contains("/nonexistent"), "runFanprobeReport 缺二进制 → failure")
    } else {
        expect(false, "runFanprobeReport 缺二进制应 failure")
    }

    // MARK: config_get

    seedConfig { $0.mode = .curve; $0.preset = .quiet }
    let cfgText = callTool(srvCfg, "fanctl_config_get", [:]).text
    if let data = cfgText.data(using: .utf8),
       let back = try? JSONDecoder().decode(FanConfig.self, from: data) {
        expectEqual(back.mode, FanMode.curve, "config_get 往返：mode 一致")
        expectEqual(back.preset, CurvePreset.quiet, "config_get 往返：preset 一致")
    } else { expect(false, "config_get 应输出可解码的 FanConfig JSON") }

    // MARK: 未知工具与参数

    expectEqual(errorOf(srv, requestLine("tools/call", ["name": "fanctl_nuke"]))?.code, -32602,
                "未知工具 -32602（协议错误，非 isError）")
    expectEqual(errorOf(srv, requestLine("tools/call", ["arguments": [:]]))?.code, -32602,
                "缺 name -32602")
    // 资源/提示能力诚实回空
    expect((resultOf(srv, requestLine("resources/list"))?["resources"] as? [Any])?.isEmpty == true,
           "resources/list 空列表")
    expect((resultOf(srv, requestLine("prompts/list"))?["prompts"] as? [Any])?.isEmpty == true,
           "prompts/list 空列表")

    // MARK: 版本同源门（fanmcpVersion ↔ VERSION，TestsReport 同款手法）

    func source(_ rel: String) -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }
    let vFields = source("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ").map(String.init)
    guard vFields.count == 2 else {
        expect(false, "VERSION 文件畸形：\(vFields)"); return
    }
    expect(source("Sources/fanmcp/main.swift")
        .contains("let fanmcpVersion = \"\(vFields[0]) (\(vFields[1]))\""),
        "fanmcpVersion 与 VERSION 同步（改号必须同步 fanmcp 壳层常量）")
    expect(FanMCP.supportedProtocolVersions.contains(FanMCP.latestProtocolVersion),
           "latest 在支持集内")
}
