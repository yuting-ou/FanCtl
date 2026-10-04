// FanMCP —— 清风的 MCP（Model Context Protocol）服务器核心
//
// 把清风的只读状态与用户意图配置暴露为 MCP 工具，供本地 AI 客户端（如 Hermes）
// 以标准协议查询与控制。架构位置与 fanprobe 同层：**只碰文件，不碰 SMC**——
// 温度/转速读 status.json（daemon 是唯一 SMC 读者），意图写 config.json
// （daemon ConfigWatch 热加载，下一拍生效），全部走 ConfigStore 的既有
// Codable/消毒/原子写纪律。本文件零控制语义、零 SMC 访问——展示的字段
// 全是 daemon 已判定的转述（reason/aiIntent 等），不重算任何控制结论
// （与 App 同一条硬约束）。
//
// 协议：stdio 传输（换行分隔 JSON-RPC 2.0），按 2025-06-18 规范实现；
// 批量数组在该版规范已移除——收到即回 -32600。通知（无 id）一律不回信。
//
// 工具面（8 个）：
//   只读：fanctl_status / fanctl_config_get / fanctl_stats / fanctl_diagnose
//   意图：fanctl_set_mode / fanctl_set_ai_target / fanctl_quiet / fanctl_boost
//
// 安全边界不变：安全红线（92° 兜底 / SSD·电池托底 / 传感器故障交还）在 daemon
// 决策管线里，永远高于这里写入的任何用户意图；MCP 只是把 App 面板能做的事
// 换了个入口，不新增任何绕过路径。写 config 走 saveConfig 的 sanitize +
// O_EXCL 临时文件 + rename 原子替换，与 App 同一条写盘纪律。
//
// 静音/冲刺与 App 的语义对齐（FanControlActions）：
//   • quiet 启动清除 boost（互斥）；boost 启动清除 quiet。
//   • boost 到期由 daemon 兜底（过期 manual 100% 本拍起视为 auto 交还系统），
//     MCP 提前结束 boost 直接回 auto——MCP 侧不存"冲刺前模式"快照，
//     面板仍是恢复原模式的权威入口。

import Foundation

/// 诊断子进程的产出：报告文本或"不可用原因"（失败关闭，不给半态）
public enum FanMCPDiagnosis {
    case success(String)
    case failure(String)
}

/// 参数解析产出：success(nil) = 参数缺席（走默认值）；failure = 类型/取值错误。
/// （不使用标准 Result：Failure 侧是纯文本提示，不满足 Failure: Error 约束）
private enum Parsed<T> {
    case success(T?)
    case failure(String)
}

public struct FanMCP {

    // MARK: - IO 注入（同 ControlEngine 的 Hooks 惯例，测试全量替换）

    public struct Hooks {
        public var now: () -> Date
        public var loadConfig: () -> FanConfig
        public var saveConfig: (FanConfig) -> Bool
        public var loadStatus: () -> DaemonStatus?
        public var loadStats: () -> DailyStats?
        public var loadHistory: () -> [DailyStats]
        public var runDiagnostics: () -> FanMCPDiagnosis
        public var writeLog: (String) -> Void

        public init(now: @escaping () -> Date = { Date() },
                    loadConfig: @escaping () -> FanConfig = { ConfigStore.loadConfig() },
                    saveConfig: @escaping (FanConfig) -> Bool = { ConfigStore.saveConfig($0) },
                    loadStatus: @escaping () -> DaemonStatus? = { ConfigStore.loadStatus() },
                    loadStats: @escaping () -> DailyStats? = { ConfigStore.loadStats(readOnly: true) },
                    loadHistory: @escaping () -> [DailyStats] = { ConfigStore.loadHistory(readOnly: true) },
                    runDiagnostics: @escaping () -> FanMCPDiagnosis = { FanMCP.runFanprobeReport() },
                    writeLog: @escaping (String) -> Void = { NSLog($0) }) {
            self.now = now
            self.loadConfig = loadConfig
            self.saveConfig = saveConfig
            self.loadStatus = loadStatus
            self.loadStats = loadStats
            self.loadHistory = loadHistory
            self.runDiagnostics = runDiagnostics
            self.writeLog = writeLog
        }
    }

    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let latestProtocolVersion = "2025-06-18"

    public let version: String
    public var hooks: Hooks

    public init(version: String, hooks: Hooks = .init()) {
        self.version = version
        self.hooks = hooks
    }

    /// 接真实数据面：ConfigStore（status/config/stats/history）+ /usr/local/bin/fanprobe。
    /// 注意 loadConfig 的既有副作用与 App 相同：文件缺失会写默认配置、损坏会自愈——
    /// 本服务是"又一个面板"，不引入新的写语义。
    public static func live(version: String) -> FanMCP {
        FanMCP(version: version, hooks: Hooks())
    }

    // MARK: - 协议入口

    /// 处理一行输入。返回要写回 stdout 的完整消息（含换行由调用方补）；
    /// nil = 通知/空行/不可解析的坏帧中"无 id 可回"的场景，静默忽略。
    @discardableResult
    public func handle(_ line: String) -> Data? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return jError(NSNull(), -32700, "Parse error: 不是合法的 JSON")
        }
        // 2025-06-18 起批量已移除：数组一律 -32600（有 id 的批量也不可能逐个回）
        guard let dict = obj as? [String: Any] else {
            return jError(NSNull(), -32600, "Invalid Request: 批量数组已不再支持（2025-06-18），一次一条消息")
        }
        guard let method = dict["method"] as? String else {
            return jError(NSNull(), -32600, "Invalid Request: 缺少 method 字段")
        }
        // JSON-RPC：无 id = 通知，永不回信（id 显式 null 按请求对待，回 null id）
        guard dict.keys.contains("id") else { return nil }
        let id = dict["id"] ?? NSNull()

        switch method {
        case "initialize":
            let clientVersion = (dict["params"] as? [String: Any])?["protocolVersion"] as? String
            return jResult(id, initializeResult(clientVersion: clientVersion))
        case "ping":
            return jResult(id, [:])
        case "tools/list":
            return jResult(id, ["tools": FanMCP.toolDescriptors()])
        case "tools/call":
            return handleToolCall(id, (dict["params"] as? [String: Any]) ?? [:])
        // 客户端可能探测这三类能力；诚实回答"空"而不是 -32601，避免误判服务器残废
        case "resources/list":
            return jResult(id, ["resources": [Any]()])
        case "resources/templates/list":
            return jResult(id, ["resourceTemplates": [Any]()])
        case "prompts/list":
            return jResult(id, ["prompts": [Any]()])
        default:
            return jError(id, -32601, "Method not found: \(method)")
        }
    }

    private func initializeResult(clientVersion: String?) -> [String: Any] {
        // 规范：客户端请求的版本在支持集内则原样回，否则回服务器最新支持版
        let negotiated = clientVersion.flatMap { v in
            FanMCP.supportedProtocolVersions.first(where: { $0 == v })
        } ?? FanMCP.latestProtocolVersion
        return [
            "protocolVersion": negotiated,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "qingfeng", "title": "清风风扇控制", "version": version],
            "instructions": "macOS 风扇管理工具「清风」的 MCP 接口。fanctl_status 查看温度/风扇/当前转速由谁决定；"
                + "fanctl_set_mode 切换调速模式（auto/curve/ai/manual）；fanctl_set_ai_target 调 AI 目标温度；"
                + "fanctl_quiet 会议静音封顶；fanctl_boost 冲刺全速（到时自动恢复）；"
                + "fanctl_stats 今日战报与历史；fanctl_diagnose 只读诊断报告。"
                + "92°C 高温兜底、SSD/电池托底等安全红线永远高于这些设置。",
        ]
    }

    // MARK: - 工具调用

    private func handleToolCall(_ id: Any, _ params: [String: Any]) -> Data {
        guard let name = params["name"] as? String else {
            return jError(id, -32602, "tools/call 缺少工具名（name）")
        }
        let args = (params["arguments"] as? [String: Any]) ?? [:]
        hooks.writeLog("fanmcp: tool call \(name)")
        switch dispatch(name, args) {
        case .success(let t): return jToolResult(id, t, isError: false)
        case .failure(let t): return jToolResult(id, t, isError: true)
        case .protocolError(let code, let msg): return jError(id, code, msg)
        }
    }

    private enum ToolOutcome {
        case success(String)
        case failure(String)             // 工具执行失败 → isError 结果（对话内可恢复）
        case protocolError(Int, String)  // 规范级错误 → JSON-RPC error（未知工具等）
    }

    private func dispatch(_ name: String, _ args: [String: Any]) -> ToolOutcome {
        switch name {
        case "fanctl_status": return toolStatus()
        case "fanctl_config_get": return toolConfigGet()
        case "fanctl_set_mode": return toolSetMode(args)
        case "fanctl_set_ai_target": return toolSetAITarget(args)
        case "fanctl_quiet": return toolQuiet(args)
        case "fanctl_boost": return toolBoost(args)
        case "fanctl_stats": return toolStats(args)
        case "fanctl_diagnose": return toolDiagnose()
        default:
            // 未知工具按规范回 -32602（协议错误，非工具执行错误）
            return .protocolError(-32602, "Unknown tool: \(name)（tools/list 可列出全部工具）")
        }
    }

    // MARK: - 工具：只读面

    private func toolStatus() -> ToolOutcome {
        let now = hooks.now()
        guard let s = hooks.loadStatus() else {
            return .failure("status.json 不可读：清风守护进程（fanctld）可能未安装或未运行。"
                + "可先跑 fanctl_diagnose，或让用户检查菜单栏是否有清风图标。")
        }
        var out = [String: Any]()
        // 新鲜度：只报实测量，不模仿 daemon 下判断（daemonAlive 的去抖语义归 App）
        let age = max(0, now.timeIntervalSince(s.timestamp))
        out["statusAgeSeconds"] = num(age, 0)
        out["statusFresh"] = age <= 30   // daemon 最长 20s 一拍；30s 内视为新鲜（展示用判据）
        out["timestamp"] = iso(s.timestamp)
        out["daemonVersion"] = opt(s.daemonVersion)
        if let hw = s.hardwareProfile {
            out["hardware"] = [
                "modelID": opt(hw.modelID),
                "chip": opt(hw.chipName),
                "osVersion": opt(hw.osVersion),
                "fanCount": hw.fanCount,
            ]
        }
        out["mode"] = s.mode.rawValue
        out["appliedPercent"] = num(s.appliedPercent, 0)
        if let ps = s.appliedPercents { out["appliedPercents"] = ps.map { num($0, 0) } }
        out["fans"] = s.fans.map { f in
            ["id": f.id, "actualRPM": num(f.actualRPM, 0), "targetRPM": num(f.targetRPM, 0),
             "minRPM": num(f.minRPM, 0), "maxRPM": num(f.maxRPM, 0)] as [String: Any]
        }
        out["sensors"] = [
            "cpuDie": num(s.sensors.cpuDie, 1),
            "cpuAverage": num(s.sensors.cpuAverage, 1),
            "gpuDie": num(s.sensors.gpuDie, 1),
            "ssd": num(s.sensors.ssd, 1),
            "palmRest": num(s.sensors.palmRest, 1),
            "heatsink": num(s.sensors.heatsink, 1),
        ]
        if let reason = s.reason { out["reason"] = reason.rawValue + " · " + reason.label }
        if let intent = s.aiIntent { out["aiIntent"] = intent.rawValue + " · " + intent.label }
        if let t = s.decisionTrace {
            let d = t.sanitized()
            out["decisionTrace"] = [
                "target": num(d.target, 1), "temp": num(d.temp, 1),
                "error": num(d.error, 1), "learned": num(d.learned, 1),
                "idle": opt(d.idle), "hysteresisHold": opt(d.hysteresisHold),
                "guardSeconds": num(d.guardSeconds, 0),
            ]
        }
        var safety = [String: Any]()
        safety["controlFault"] = s.controlFault ?? false
        if let fr = s.faultReason { safety["faultReason"] = fr.rawValue + " · " + fr.displayName }
        safety["baseTargetPercent"] = num(s.baseTargetPercent, 1)
        safety["safetyFloorPercent"] = num(s.safetyFloorPercent, 1)
        safety["targetUnreachable"] = opt(s.targetUnreachable)
        safety["aiHighEffort"] = opt(s.aiHighEffort)
        safety["calibrating"] = opt(s.calibrating)
        out["safety"] = safety
        out["powerWatts"] = num(s.powerWatts, 1)
        out["envTemp"] = num(s.envTemp, 1)
        out["onBattery"] = opt(s.onBattery)
        out["nightOverride"] = opt(s.nightOverride)
        var learning = [String: Any]()
        learning["learnedPoints"] = opt(s.learnedPoints)
        learning["learnedSamples"] = opt(s.learnedSamples)
        learning["learningRecently"] = opt(s.learningRecently)
        learning["thermalModelUsable"] = opt(s.thermalModelUsable)
        learning["thermalModelSamples"] = opt(s.thermalModelSamples)
        out["learning"] = learning
        // 配置侧摘要：静音/冲刺窗口与到期剩余是 config 里的时间戳，这里只换算成
        // "还剩多少秒"，决策语义仍全在 daemon
        let c = hooks.loadConfig()
        var overlay = [String: Any]()
        overlay["quietActive"] = isActive(c.quietUntil, now: now)
        overlay["quietRemainingSeconds"] = remaining(c.quietUntil, now: now)
        overlay["quietCapPercent"] = num(c.quietCapPercent, 0)
        overlay["boostActive"] = isActive(c.boostUntil, now: now)
        overlay["boostRemainingSeconds"] = remaining(c.boostUntil, now: now)
        out["overlay"] = overlay
        out["config"] = [
            "aiTargetTemp": num(c.aiTargetTemp, 0),
            "preset": opt(c.preset?.rawValue),
            "manualPercent": num(c.manualPercent, 0),
            "envCompensation": c.envCompensation,
            "quietHours": c.quietHours,
            "palmCompensation": c.palmCompensation,
            "fanOffsets": opt(c.fanOffsets.map { $0.map { num($0, 0) } }),
        ]
        return .success(pretty(out))
    }

    private func toolConfigGet() -> ToolOutcome {
        let c = hooks.loadConfig()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(c), let text = String(data: data, encoding: .utf8) else {
            return .failure("配置编码失败（不应发生——与 saveConfig 同一条编码路径）")
        }
        return .success(text)
    }

    private func toolStats(_ args: [String: Any]) -> ToolOutcome {
        let days: Int
        switch intArg(args, "days") {
        case .failure(let m): return .failure(m)
        case .success(let v):
            if let d = v {
                guard d >= 1, d <= 30 else {
                    return .failure("days 必须在 1–30（history.json 归档窗口只有 30 个日历日），收到 \(d)")
                }
                days = d
            } else {
                days = 1
            }
        }
        let today = hooks.loadStats()
        guard days == 1 else { return .success(pretty(statsMultiDay(days: days, today: today))) }
        guard let s = today else {
            return .failure("stats.json 不可读：daemon 可能未运行（战报由 daemon 每拍累计）。")
        }
        var out = [String: Any]()
        out["date"] = s.date
        out["avgTemp"] = num(s.avgTemp, 1)                    // 按秒加权（tempSeconds 口径）
        out["maxTemp"] = num(s.maxTemp, 1)
        out["maxTempAt"] = iso(s.maxTempAt)
        out["highTempSeconds"] = num(s.highTempSeconds, 0)    // ≥80°C 累计
        out["quietSeconds"] = num(s.quietSeconds, 0)
        out["revolutions"] = num(s.revolutions, 0)            // 双风扇累计转数
        out["speedChanges"] = num(s.speedChanges, 0)          // |Δ|≥3% 调速次数（风扇磨损代理）
        out["overshootPeak"] = num(s.overshootPeak, 1)        // 超出 AI 有效目标峰值
        out["aiCyclingGuards"] = num(s.aiCyclingGuards, 0)    // 启停循环抑制武装次数
        out["avgPower"] = num(s.avgPower, 1)
        return .success(pretty(out))
    }

    private func statsMultiDay(days: Int, today: DailyStats?) -> [String: Any] {
        var all = hooks.loadHistory()
        if let t = today { all.append(t) }   // history 是跨天归档，当日不在其中
        // 只取能解析日键的行，按日期排序后取最近 N 天
        let rows = all
            .filter { DailyStats.epochDay(ofDayKey: $0.date) != nil }
            .sorted { epoch($0.date) < epoch($1.date) }
            .suffix(days)
        var list = [[String: Any]]()
        var tempSum = 0.0, tempSec = 0.0, revolutions = 0.0, speed = 0.0
        var high = 0.0, quiet = 0.0, maxT = -Double.infinity
        for s in rows {
            list.append([
                "date": s.date, "avgTemp": num(s.avgTemp, 1), "maxTemp": num(s.maxTemp, 1),
                "speedChanges": num(s.speedChanges, 0), "revolutions": num(s.revolutions, 0),
                "highTempSeconds": num(s.highTempSeconds, 0),
            ])
            tempSum += s.tempSum; tempSec += s.tempSeconds
            revolutions += s.revolutions; speed += s.speedChanges
            high += s.highTempSeconds; quiet += s.quietSeconds
            maxT = max(maxT, s.maxTemp)
        }
        let aggAvg = tempSec > 1e-6 ? tempSum / tempSec : 0.0   // 跨天仍按秒加权
        return [
            "windowDays": rows.count,
            "perDay": list,
            "totals": [
                "avgTemp": num(aggAvg, 1), "maxTemp": maxT.isFinite ? num(maxT, 1) : NSNull(),
                "revolutions": num(revolutions, 0), "speedChanges": num(speed, 0),
                "highTempSeconds": num(high, 0), "quietSeconds": num(quiet, 0),
            ] as [String: Any],
        ]
    }

    private func epoch(_ key: String) -> Int { DailyStats.epochDay(ofDayKey: key) ?? 0 }

    private func toolDiagnose() -> ToolOutcome {
        switch hooks.runDiagnostics() {
        case .success(let text): return .success(text)
        case .failure(let msg): return .failure(msg)
        }
    }

    // MARK: - 工具：意图面（写 config.json，daemon 下一拍热加载）

    private func persist(_ c: FanConfig, _ what: String) -> ToolOutcome {
        guard hooks.saveConfig(c) else {
            return .failure("配置写入失败：config.json 落盘被拒。数据目录在 /Library/Application Support/FanCtl/"
                + "（root:admin 775），当前用户需要 admin 组身份；可让用户在面板里改一次以确认 App 侧是否同样失败。")
        }
        return .success(pretty(["ok": true, "changed": what,
                                "note": "daemon 会在下一拍热加载（≤20s）；安全红线（92° 兜底/SSD/电池托底）不受此设置影响。"]))
    }

    private func toolSetMode(_ args: [String: Any]) -> ToolOutcome {
        let modeStr: String
        switch strArg(args, "mode") {
        case .failure(let m): return .failure(m)
        case .success(let v):
            guard let s = v else { return .failure("缺少必填参数 mode（auto/curve/ai/manual）") }
            modeStr = s
        }
        guard let mode = FanMode(rawValue: modeStr) else {
            return .failure("mode 必须是 auto / curve / ai / manual 之一，收到 [\(modeStr)]。"
                + "auto=交还系统调度，curve=温度曲线，ai=自适应目标温控，manual=固定转速。")
        }
        var c = hooks.loadConfig()
        c.mode = mode
        switch mode {
        case .curve:
            switch strArg(args, "curvePreset") {
            case .failure(let m): return .failure(m)
            case .success(let v):
                if let presetStr = v {
                    guard let preset = CurvePreset(rawValue: presetStr), preset != CurvePreset.custom else {
                        return .failure("curvePreset 必须是 quiet / balanced / aggressive 之一，收到 [\(presetStr)]。"
                            + "自定义曲线请用面板拖点（MCP 不代改 custom 点，避免覆盖用户手调的曲线）。")
                    }
                    c.preset = preset
                    c.curve = preset.points
                }
            }
        case .ai:
            switch numArg(args, "aiTargetTemp") {
            case .failure(let m): return .failure(m)
            case .success(let v):
                if let t = v {
                    guard t >= 40, t <= 84 else { return aiTargetRangeError(t) }
                    c.aiTargetTemp = t
                }
            }
        case .manual:
            switch numArg(args, "manualPercent") {
            case .failure(let m): return .failure(m)
            case .success(let v):
                if let p = v {
                    guard p >= 0, p <= 100 else {
                        return .failure("manualPercent 必须在 0–100，收到 \(p)")
                    }
                    c.manualPercent = p
                }
            }
        case .auto:
            break
        }
        // 冲刺截止只对 manual 有意义：切走时清掉陈旧 deadline（engine 只在 manual 判过期）
        if mode != .manual { c.boostUntil = nil }
        return persist(c, "mode=\(mode.rawValue)")
    }

    private func toolSetAITarget(_ args: [String: Any]) -> ToolOutcome {
        switch numArg(args, "targetTemp") {
        case .failure(let m): return .failure(m)
        case .success(let v):
            guard let t = v else {
                return .failure("缺少必填参数 targetTemp（数值，°C，40–84）")
            }
            guard t >= 40, t <= 84 else { return aiTargetRangeError(t) }
            var c = hooks.loadConfig()
            c.aiTargetTemp = t
            return persist(c, "aiTargetTemp=\(t)")
        }
    }

    private func aiTargetRangeError(_ t: Double) -> ToolOutcome {
        .failure("AI 目标温度必须在 40–84°C，收到 \(t)。上限 84 的原因：引擎把有效目标钳在 ≤84°，"
            + "更高的目标会在 88° 兜底释放线下方形成\"低转↔全速\"振荡（v2.6.2 的教训）；"
            + "压不住温度时正确动作是 fanctl_boost 或检查负载，而不是抬目标。")
    }

    private func toolQuiet(_ args: [String: Any]) -> ToolOutcome {
        let enable: Bool
        switch boolArg(args, "enable") {
        case .failure(let m): return .failure(m)
        case .success(let v):
            guard let b = v else { return .failure("缺少必填参数 enable（true=开启静音封顶，false=解除）") }
            enable = b
        }
        var c = hooks.loadConfig()
        guard enable else {
            c.quietUntil = nil
            c.quietCapPercent = nil
            return persist(c, "quiet=解除")
        }
        let minutes: Double
        switch numArg(args, "minutes") {
        case .failure(let m): return .failure(m)
        case .success(let v):
            if let m = v {
                guard m >= 1, m <= 480 else {
                    return .failure("minutes 必须在 1–480，收到 \(m)。静音是封顶不是关扇，更长请分次续。")
                }
                minutes = m
            } else {
                minutes = 30   // App 默认 30 分钟
            }
        }
        let cap: Double
        switch numArg(args, "capPercent") {
        case .failure(let m): return .failure(m)
        case .success(let v):
            if let p = v {
                guard p >= 0, p <= 100 else {
                    return .failure("capPercent 必须在 0–100，收到 \(p)")
                }
                cap = p
            } else {
                cap = 30       // App 常量 quietCapPercent = 30
            }
        }
        c.quietUntil = hooks.now().addingTimeInterval(minutes * 60)
        c.quietCapPercent = cap
        c.boostUntil = nil   // 与 App startQuiet 同款互斥：静音优先于冲刺
        return persist(c, "quiet=开启 \(Int(minutes)) 分钟封顶 \(Int(cap))%")
    }

    private func toolBoost(_ args: [String: Any]) -> ToolOutcome {
        let end: Bool
        switch boolArg(args, "end") {
        case .failure(let m): return .failure(m)
        case .success(let v): end = v ?? false
        }
        var c = hooks.loadConfig()
        if end {
            // App 的 endBoost 会恢复冲刺前快照；MCP 不存快照，诚实回 auto
            // （daemon 对过期 boost 也是"本拍起视为 auto 交还系统"，方向一致）
            c.mode = .auto
            c.manualPercent = 50
            c.boostUntil = nil
            return persist(c, "boost=提前结束，回到系统自动调度（如需 curve/ai 请再 fanctl_set_mode）")
        }
        let minutes: Double
        switch numArg(args, "minutes") {
        case .failure(let m): return .failure(m)
        case .success(let v):
            if let m = v {
                guard m >= 1, m <= 60 else {
                    return .failure("minutes 必须在 1–60，收到 \(m)。冲刺是短时手段，更长请分次。")
                }
                minutes = m
            } else {
                minutes = 15   // App 默认 15 分钟
            }
        }
        c.mode = .manual
        c.manualPercent = 100
        c.boostUntil = hooks.now().addingTimeInterval(minutes * 60)
        c.quietUntil = nil   // 与 App startBoost 同款互斥
        return persist(c, "boost=manual 100% 持续 \(Int(minutes)) 分钟（到期 daemon 自动交还系统）")
    }

    // MARK: - 参数解析（LLM 传参防御：类型错给可执行的错误信息，容忍数字字符串）

    private func strArg(_ args: [String: Any], _ key: String) -> Parsed<String> {
        guard let v = args[key] else { return .success(nil) }
        if let s = v as? String { return .success(s) }
        return .failure("参数 \(key) 应为字符串，收到 \(typeName(v))")
    }

    private func numArg(_ args: [String: Any], _ key: String) -> Parsed<Double> {
        guard let v = args[key] else { return .success(nil) }
        if isBool(v) { return .failure("参数 \(key) 应为数值，收到布尔值") }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), let d = n as? Double {
            return d.isFinite ? .success(d) : .failure("参数 \(key) 不是有限数值")
        }
        if let s = v as? String, let d = Double(s), d.isFinite { return .success(d) }  // "72" 也收
        return .failure("参数 \(key) 应为数值，收到 \(typeName(v))")
    }

    private func intArg(_ args: [String: Any], _ key: String) -> Parsed<Int> {
        switch numArg(args, key) {
        case .success(let v): return .success(v.map { Int($0.rounded()) })
        case .failure(let m): return .failure(m)
        }
    }

    private func boolArg(_ args: [String: Any], _ key: String) -> Parsed<Bool> {
        guard let v = args[key] else { return .success(nil) }
        // 本仓"零强拆包"纪律（R82 审计口径）：isBool 判定后用可失败转换，不用 as!
        if isBool(v), let b = v as? Bool { return .success(b) }
        return .failure("参数 \(key) 应为布尔值（true/false），收到 \(typeName(v))")
    }

    private func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private func typeName(_ v: Any) -> String {
        if v is String { return "字符串" }
        if isBool(v) { return "布尔值" }
        if v is NSNumber { return "数值" }
        return String(describing: Swift.type(of: v))
    }

    // MARK: - 工具描述（协议元数据）

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var s: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { s["required"] = required }
        s["additionalProperties"] = false
        return s
    }

    private static func descriptor(_ name: String, _ title: String, _ description: String,
                                   _ inputSchema: [String: Any],
                                   readOnly: Bool, idempotent: Bool) -> [String: Any] {
        return [
            "name": name, "title": title, "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": readOnly, "destructiveHint": false,
                "idempotentHint": idempotent, "openWorldHint": false,
            ],
        ]
    }

    public static func toolDescriptors() -> [[String: Any]] {
        let tempNum: [String: Any] = ["type": "number", "minimum": 40, "maximum": 84,
                                      "description": "目标温度 °C（40–84；84 以上会被拒绝，见工具说明）"]
        let modeStr: [String: Any] = ["type": "string", "enum": ["auto", "curve", "ai", "manual"],
                                      "description": "auto=交还系统调度；curve=温度曲线；ai=自适应目标温控；manual=固定转速"]
        return [
            descriptor("fanctl_status", "清风状态", "查看清风当前状态：CPU/GPU/SSD/掌托/散热片温度、双风扇转速、当前模式与"
                + "「转速由谁决定」（reason）、AI 意图与有效目标、功耗、电池/夜间档、故障与安全托底、静音/冲刺剩余时间。"
                + "读 daemon 写出的 status.json，只读。", schema([:], required: []), readOnly: true, idempotent: true),
            descriptor("fanctl_config_get", "清风配置", "查看清风当前完整配置 JSON（模式、曲线点、AI 目标、风扇偏移、"
                + "环境/体感补偿、夜间档等）。只读。", schema([:], required: []), readOnly: true, idempotent: true),
            descriptor("fanctl_set_mode", "切换调速模式", "切换调速模式。curve 可带 curvePreset（quiet/balanced/aggressive，"
                + "会同时改写曲线点；custom 需在面板拖点）；ai 可带 aiTargetTemp（40–84）；manual 可带 manualPercent（0–100）。"
                + "安全红线（92°C 全速兜底、SSD/电池托底）永远高于此设置。",
                       schema(["mode": modeStr,
                               "curvePreset": ["type": "string", "enum": ["quiet", "balanced", "aggressive"]],
                               "aiTargetTemp": tempNum,
                               "manualPercent": ["type": "number", "minimum": 0, "maximum": 100]],
                              required: ["mode"]),
                       readOnly: false, idempotent: true),
            descriptor("fanctl_set_ai_target", "设置 AI 目标温度", "设置 AI 模式的目标温度（40–84°C）。仅 AI 模式实际生效，"
                + "其他模式只是预存；目标越低风扇越激进、越吵。压不住温度时该用 fanctl_boost 或减负载，而不是抬目标。",
                       schema(["targetTemp": tempNum], required: ["targetTemp"]),
                       readOnly: false, idempotent: true),
            descriptor("fanctl_quiet", "会议静音封顶", "静音承诺：enable=true 时把风扇输出封顶到 capPercent（默认 30%）"
                + "持续 minutes 分钟（默认 30，1–480）；enable=false 提前解除。封顶压不住高温时安全托底（SSD/电池/92°）"
                + "会自动越过它——静音不牺牲安全。",
                       schema(["enable": ["type": "boolean"],
                               "minutes": ["type": "number", "minimum": 1, "maximum": 480],
                               "capPercent": ["type": "number", "minimum": 0, "maximum": 100]],
                              required: ["enable"]),
                       readOnly: false, idempotent: true),
            descriptor("fanctl_boost", "冲刺全速", "临时全速散热：manual 100% 持续 minutes 分钟（默认 15，1–60），"
                + "到期 daemon 自动交还系统调度；end=true 提前结束（回到 auto，如需原模式请再 fanctl_set_mode）。"
                + "会议/静音场景不要用。",
                       schema(["minutes": ["type": "number", "minimum": 1, "maximum": 60],
                               "end": ["type": "boolean"]], required: []),
                       readOnly: false, idempotent: true),
            descriptor("fanctl_stats", "今日战报", "今日战报与历史趋势：平均/最高温度、≥80° 高温累计、调速次数（风扇磨损"
                + "代理）、启停循环抑制次数、平均功耗、过冲峰值。days=1–30，默认 1 只看今天；>1 时给出近 N 天逐日汇总。",
                       schema(["days": ["type": "number", "minimum": 1, "maximum": 30]], required: []),
                       readOnly: true, idempotent: true),
            descriptor("fanctl_diagnose", "只读诊断报告", "运行 fanprobe --report 生成 19 小节固定格式的运行时快照"
                + "（装机版本、硬件画像、状态新鲜度、故障与托底、学习/热模型口径、SMC 直读）。用于「散热是不是出问题了」"
                + "的排查；只读、无需 root、不改任何状态。",
                       schema([:], required: []), readOnly: true, idempotent: true),
        ]
    }

    // MARK: - fanprobe 子进程（live hooks）

    /// 跑 /usr/local/bin/fanprobe --report（只读诊断）。路径与参数都是编译期常量，
    /// 无注入面。读盘纪律沿 4.2.48 selfcheck 的教训：**先旁路读管线到 EOF，
    /// 超时从主路径杀进程**——先 wait 后读会被满输出顶爆 64KB 管线缓冲而互相等死。
    public static func runFanprobeReport(path: String = "/usr/local/bin/fanprobe") -> FanMCPDiagnosis {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failure("未找到 \(path)：fanprobe 未安装（发行包 install.sh 会装）。"
                + "可改用源码构建：swift run -c release --disable-sandbox fanprobe --report")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--report"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return .failure("无法启动 fanprobe：\(error.localizedDescription)")
        }
        var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if readDone.wait(timeout: .now() + 30) == .timedOut {
            p.terminate()
            _ = readDone.wait(timeout: .now() + 5)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return .failure("fanprobe 超过 30s 未完成，已终止（正常情况数秒内出报告；"
                + "若持续超时请检查系统负载）。")
        }
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0, !text.isEmpty else {
            return .failure("fanprobe 退出码 \(p.terminationStatus)，输出 \(text.count) 字节"
                + (text.isEmpty ? "" : "，尾段：" + String(text.suffix(200))))
        }
        // 文本消毒（4.2.4 纪律）：控制字符压平成空格（保留换行/制表），防粘进终端被解释
        let sanitized = String(text.map { ch -> Character in
            if ch == "\n" || ch == "\t" || ch == "\r" { return ch }
            if ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) { return ch }
            return " "
        })
        return .success(sanitized)
    }

    // MARK: - JSON 小工具

    private func isActive(_ until: Date?, now: Date) -> Bool {
        guard let u = until else { return false }
        return u > now
    }

    private func remaining(_ until: Date?, now: Date) -> Any {
        guard let u = until, u > now else { return NSNull() }
        return num(u.timeIntervalSince(now), 0)
    }

    /// Optional 值进 JSON 字典：nil → NSNull（JSONSerialization 不收 Swift nil）
    private func opt(_ v: Any?) -> Any {
        guard let v else { return NSNull() }
        return v
    }

    /// 有限值 → 四舍五入到 digits 位；否则 NSNull（JSONSerialization 不收 NaN/Inf，
    /// 且全链路 NaN 防御是本仓铁律）
    private func num(_ v: Double?, _ digits: Int) -> Any {
        guard let v, v.isFinite else { return NSNull() }
        let scale = pow(10.0, Double(digits))
        return (v * scale).rounded() / scale
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private func pretty(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"内部错误：结果对象不是合法 JSON（已按 NaN 防御过滤，此路径不应触达）\"}"
        }
        return text
    }

    private func jResult(_ id: Any, _ result: [String: Any]) -> Data {
        compact(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func jError(_ id: Any, _ code: Int, _ message: String) -> Data {
        compact(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func jToolResult(_ id: Any, _ text: String, isError: Bool) -> Data {
        compact(["jsonrpc": "2.0", "id": id,
                 "result": ["content": [["type": "text", "text": text]], "isError": isError]])
    }

    /// 未知工具的 -32602 走这里：dispatch 返回带 "__protocol__" 前缀的失败时升级为协议错误
    private func compact(_ obj: [String: Any]) -> Data {
        if JSONSerialization.isValidJSONObject(obj),
           let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            return d
        }
        // 理论不可达（NaN 防御已在 num() 收口）；兜底回一条合法帧而不是炸协议通道
        return Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}".utf8)
    }
}
