// TestsChecklists —— 清单接线门（R92）：把"清单纪律"升级为"接线门"
//
// 背景：R16/R22 两次同类事故——新增状态字段漏进某张清单（变化感知摘要/唤醒复位/
// 落盘管道），静默失效到下次人肉发现。R77 已给 wake() 建了"抠取↔声明"双向门，
// 但声明清单是手写的：新增字段若**既没复位也没声明**，双向比对不红（默认放行）。
// R90 的 DaemonOfflinePolicy 证明了另一半拼图：Mirror 字段全集对账能让
// "未表态的新字段"自动红。
//
// 本文件三张门共用同一形状（默认拒绝）：
//   Mirror 全集 V（自动含未来新增字段）
//   == 覆盖集（源码抠取，反映真实实现）
//   ∪ 豁免集（显式登记，每条带理由——新增字段默认不豁免，必须主动表态）
//
// 三张门：
//   A. wake 复位完备性（ControlEngine 存储属性全集 vs wake() 赋值集 ∪ 跨会话豁免）
//   B. 持久化对账（ConfigStore.load* 全集 vs save* 覆盖 + flushAll/节流双写点）
//   C. statusChangeSummary 变化感知完备性（DaemonStatus 字段全集 vs 摘要引用 ∪ 豁免）
//
// 边沿日志去重不建独立门：其字段（xxxLogged/lastXxx 边沿记忆）没有独立清单结构
// （分散在各字段的 `if x != lastX` 模式），失效症状是重复日志（可见、无安全后果），
// 已通过门 A 的豁免登记间接钉住"哪些是边沿字段"。

import Foundation
import SMCCore

// MARK: - 共用：源码抠取器（先例：testWakeSessionResetCoverage / test-root-scripts.sh）

/// 读仓库相对路径的源文件。读不到（工作目录非仓库根）按 R77 惯例判红而非静默跳过
/// ——静默跳过等于当轮没有门。
private func repoSource(_ rel: String) -> String? {
    try? String(contentsOfFile: rel, encoding: .utf8)
}

/// 去掉行尾注释（保守：仅当 "//" 不处于字符串字面量内才截断）。
/// M3 变异实测抓到的假绿形态：`let verStr = "-" // s.daemonVersion`——行不是注释行，
/// 但行尾注释里的 s.xxx 仍被正则匹配成"已覆盖"。M2 教训的姊妹形态：
/// 整行注释不算覆盖，行尾注释同样不算。
private func strippingTrailingComment(_ line: String) -> String {
    var inString = false
    var escaped = false
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if escaped { escaped = false; i += 1; continue }
        if c == "\\" && inString { escaped = true; i += 1; continue }
        if c == "\"" { inString.toggle() }
        if c == "/", !inString, i + 1 < chars.count, chars[i + 1] == "/" {
            // 截断的同时去掉注释前导空白，保持缩进语义：`    } // x` → `    }`
            var end = i
            while end > 0, chars[end - 1] == " " || chars[end - 1] == "\t" { end -= 1 }
            return String(chars[0..<end])
        }
        i += 1
    }
    return line
}

/// 抠取某方法体内被赋值/被调用成员的名字集（R77 抠取器的通用化）。
/// 认两种形态：`x = …`（直接字段复位）与 `x.method(…)`（子对象委托复位/调用）；
/// 跳过注释/guard/if/let/var 行与局部变量。
private func extractedMembers(of funcSignature: String, in src: String) -> Set<String>? {
    let lines = src.components(separatedBy: "\n")
    guard let startIdx = lines.firstIndex(where: { $0.contains(funcSignature) }) else { return nil }
    var body: [String] = []
    var i = startIdx + 1
    while i < lines.count, strippingTrailingComment(lines[i]) != "    }" {   // 函数体到第一个 4 空格缩进 "}" 为止
        body.append(lines[i]); i += 1
    }
    var names = Set<String>()
    for line in body {
        // 先剥行尾注释再认成员：注释里的 x = / x. 不得冒充复位（M3 教训统一适用）
        let t = strippingTrailingComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("//") || t.hasPrefix("guard") || t.hasPrefix("if")
            || t.hasPrefix("let") || t.hasPrefix("var") { continue }
        let name: String?
        if let eq = t.firstIndex(of: "=") {
            name = String(t[t.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        } else if let dot = t.firstIndex(of: ".") {
            name = String(t[t.startIndex..<dot]).trimmingCharacters(in: .whitespaces)
        } else {
            name = nil
        }
        if let n = name,
           n.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
            names.insert(n)
        }
    }
    return names
}

// MARK: - 门 A：wake 复位完备性

/// 跨会话合法保留的字段（豁免登记——每条对应"为什么睡眠边界不需要清它"）。
/// 新增字段默认不豁免：要么进 wake() 复位（源码抠取自动认到），要么来这里显式表态。
private let crossSessionKept: [String: String] = [
    // 依赖注入（let）：不属于状态
    "hooks": "let 注入依赖",
    "watchdogLock": "let 锁对象本身",
    // 配置域：热加载重读，快照跨会话有效
    "config": "配置快照，热加载语义",
    "lastConfigMTime": "配置 mtime 去重基准，跨会话有效",
    "aiMetricsUserTarget": "配置域（用户目标基准），随 config 热加载对齐",
    // 持久化状态：enterSleep/flushAll 已落盘，跨会话语义本就成立
    "thermalLearn": "持久化学习表，enterSleep 落盘",
    "thermalModel": "持久化热模型，enterSleep 落盘",
    "aiMetrics": "持久化评测，enterSleep 落盘",
    "dtLedger": "持久化 dt 账本，enterSleep 落盘",
    "shadowFF": "持久化影子账本，enterSleep 落盘",
    "statsKeeper": "持久化每日统计，enterSleep 落盘",
    "hardwareProfile": "慢变量，进程内采集一次不变",
    // 落盘脏旗：enterSleep flush 失败时必须保留跨会话重试（R35 语义）
    "learnDirty": "落盘重试脏旗",
    "modelDirty": "落盘重试脏旗",
    "dtLedgerDirty": "落盘重试脏旗",
    "shadowFFDirty": "落盘重试脏旗",
    // 单调缓存：唤醒后首拍必然重算覆盖，残留无害
    "lastAIOutput": "上一拍 AI 输出缓存，首拍重算",
    "lastAIIntent": "上一拍意图缓存，首拍重算",
    "prevStatsAppliedPercent": "调速统计上一拍输出，首拍重算",
    "lastLearnMapSamples": "学习图节流缓存（P3），样本数未变则缓存仍有效",
    "lastLearnMap": "学习图节流缓存（P3），同上",
    "lastLearnAt": "最近学习时间戳，120s 窗口按真实时钟自然过期",
    "lastFeedTrust": "R89 信任门边沿日志记忆（跨会话少打一条日志，无控制后果）",
    "loopCount": "节流计数器（REASSERT 用），累计语义",
    "lastOnBattery": "电池边沿记忆，醒来首拍重判（IOPSCopy 每拍真实读）",
    "statsAccumSeconds": "统计累计器，累计语义",
    "lastStatusSummary": "变化感知摘要缓存，醒来首拍与旧摘要比对→必写盘（有益）",
    "forceWriteCounter": "写盘节流计数，累计语义",
    "lastStatusWrite": "写盘节流时间戳，累计语义",
    // 刻意保留：R77 已论证（App 陈旧判定依赖最后一帧）
    "lastStatus": "刻意保留：App 离线判定靠最后一帧（>30s 判死）",
    // 安全边沿：残留方向是保守侧（decide 的 was* 用释放线，醒来温度低于释放线即解除）
    "failsafeActive": "安全边沿残留=用释放线判退，保守侧无害",
    "ssdGuardActive": "同上（SSD 托底释放线）",
    "ssdCriticalActive": "同上（SSD 危急释放线）",
    "batteryGuardActive": "同上（电池托底释放线）",
    "batteryCriticalActive": "同上（电池危急释放线）",
    // 一次性边沿日志标志：跨会话少打日志，无控制后果
    "persistenceFailedLogged": "边沿日志一次性标志",
    "envCompLogged": "边沿日志一次性标志",
    "passiveModeLogged": "边沿日志一次性标志",
    "horizonWarned": "一次性告警 Set（防刷屏），跨会话少告警无害",
    // 校准域：观察窗按墙钟（睡眠计入超时=既有设计，4.0 B2 已有行为测试）
    "calibrating": "校准观察期状态（4.0 B2 语义，睡眠计入观察窗）",
    "calibratingStartedAt": "同上（超时基准）",
    "calibrationSamples": "同上（观察期样本计数）",
    "calibrationTimedOut": "超时 latch：解除时机=离开 AI 模式/重置学习（4.0 审查定案）",
    // 看门狗私有域：wake() 经 setSuspended(false) 复位（非直接赋值形态）
    "heartbeatValue": "wake 经 setSuspended(false) 重置心跳",
    "suspended": "wake 经 setSuspended(false) 置 false",
]

func testWakeChecklistCompleteness() {
    group("唤醒复位完备性门(R92)")
    var envDirs: [URL] = []
    envDirs.append(engineTestEnv())
    ConfigStore.saveConfig(FanConfig(mode: .ai, preset: .balanced, envCompensation: false))
    let smc = makeFanSMC(); smc.set("Tp01", 60); smc.set("PSTR", 30)
    let clock = FakeClock(); let col = EngineCollector()
    seedLearnTable()

    // ① Mirror 全集：ControlEngine 的全部存储属性（let/var 都列，自动含新增字段）
    let engine = makeEngine(smc: smc, clock: clock, collector: col)
    engine.enterSleep()
    engine.wake()
    let mirrorFields = Set(Mirror(reflecting: engine).children.compactMap(\.label))
    expect(mirrorFields.count >= 70,
           "Mirror 抠出 \(mirrorFields.count) 个存储属性，不应少于 70（Mirror 失效要判红）")

    // ② 覆盖集：wake() 源码实际赋值/委托复位的成员
    guard let src = repoSource("Sources/SMCCore/ControlEngine.swift") else {
        expect(false, "读不到 Sources/SMCCore/ControlEngine.swift——完备性门未执行")
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
        for d in envDirs { try? FileManager.default.removeItem(at: d) }
        return
    }
    guard let wakeAssigned = extractedMembers(of: "public func wake()", in: src) else {
        expect(false, "ControlEngine.swift 里找不到 wake()（函数被改名？）")
        return
    }
    expect(wakeAssigned.count >= 20,
           "wake() 抠出 \(wakeAssigned.count) 个成员，不应少于 20（抠取器失效要判红）")

    // ③ 完备性（本门的核心牙）：全集 == 复位集 ∪ 豁免集。
    // 新增字段既没进 wake() 也没登记豁免 → 第一条红；登记了豁免但字段不存在（改名/删除）
    // → 第二条红。默认拒绝，不靠人肉记忆。
    let exempt = Set(crossSessionKept.keys)
    let unclassified = mirrorFields.subtracting(wakeAssigned).subtracting(exempt).sorted()
    expect(unclassified.isEmpty,
           "ControlEngine 新字段未表态（既不在 wake() 复位集也不在豁免登记）：\(unclassified)。要么在 wake() 里复位它，要么在 crossSessionKept 登记豁免理由")
    let staleExempt = exempt.subtracting(mirrorFields).subtracting(wakeAssigned).sorted()
    expect(staleExempt.isEmpty,
           "豁免登记里出现已不存在的字段（字段被删/改名要连登记一起改）：\(staleExempt)")

    FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
    for d in envDirs { try? FileManager.default.removeItem(at: d) }
}

// MARK: - 门 B：持久化对账（load* ↔ save* + 双写点）

func testPersistenceChecklist() {
    group("持久化对账门(R92)")
    guard let engineSrc = repoSource("Sources/SMCCore/ControlEngine.swift") else {
        expect(false, "读不到 Sources/SMCCore/ControlEngine.swift——持久化门未执行")
        return
    }
    let lines = engineSrc.components(separatedBy: "\n")
    // 行内真实代码（去注释）：被注释掉的 save/load 调用不算数——M2 变异实测抓到的
    // 假绿形态：注释行里的 `ConfigStore.saveShadowFF(` 仍会被正则匹配到；
    // M3 变异又抓到行尾注释形态——统一先剥行尾注释再过滤
    let codeLines = lines
        .map { strippingTrailingComment($0) }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    // ① load 全集：init 里所有 ConfigStore.loadXxx 调用（新增持久化状态自动进此集）
    // 注意 range 必须在**同一字符串**上取值（line 的 range 索引 engineSrc 是未定义行为）
    var loadCalls = Set<String>()
    for line in codeLines {
        guard let r = line.range(of: "ConfigStore\\.load[A-Za-z]+\\(\\)",
                                 options: .regularExpression) else { continue }
        loadCalls.insert(String(line[r]))
    }
    expect(loadCalls.count >= 6,
           "抠出 \(loadCalls.count) 个 load 调用，不应少于 6（抠取器失效要判红）")
    // ② save 全集：全文件所有 ConfigStore.saveXxx 调用
    var saveCalls = Set<String>()
    for line in codeLines {
        guard let r = line.range(of: "ConfigStore\\.save[A-Za-z]+\\(",
                                 options: .regularExpression) else { continue }
        // 归一化形如 "ConfigStore.saveLearn(" → "ConfigStore.saveLearn()"
        saveCalls.insert(String(line[r]).replacingOccurrences(of: "(", with: "()"))
    }
    // ③ 每个 load 都要有对应 save：load(X) 的状态必须存在落盘点，否则数据只进不出。
    // 例外：loadConfig 是"意图输入"通道——daemon 对 config 只读（写入方是 App/MCP，
    // 损坏自愈重写在 ConfigStore.loadConfig 内部），不属于 daemon 侧状态持久化
    let loadsWithoutSave = loadCalls
        .filter { $0 != "ConfigStore.loadConfig()" }
        .map { $0.replacingOccurrences(of: "load", with: "save") }
        .filter { !saveCalls.contains($0) }.sorted()
    expect(loadsWithoutSave.isEmpty,
           "有加载无落盘的持久化状态（load↔save 失配）：\(loadsWithoutSave)")

    // ④ 双写点之一（flushAll）：入睡/退出全量落盘 6 个持久化文件
    guard let fStart = codeLines.firstIndex(where: { $0.contains("private func flushAll()") }) else {
        expect(false, "flushAll 定位失败"); return
    }
    var flushSaves = Set<String>()
    var i = fStart + 1
    while i < codeLines.count, codeLines[i] != "    }" {
        if let r = codeLines[i].range(of: "ConfigStore\\.save[A-Za-z]+\\(",
                                      options: .regularExpression) {
            flushSaves.insert(String(codeLines[i][r]).replacingOccurrences(of: "(", with: "()"))
        }
        i += 1
    }
    let expectedFlush: Set<String> = ["ConfigStore.saveStats()", "ConfigStore.saveLearn()",
                                      "ConfigStore.saveModel()", "ConfigStore.saveAIMetrics()",
                                      "ConfigStore.saveDTLedger()", "ConfigStore.saveShadowFF()"]
    expect(flushSaves == expectedFlush,
           "flushAll 应全量落盘 6 个持久化文件（缺 \(expectedFlush.subtracting(flushSaves).sorted()) 多 \(flushSaves.subtracting(expectedFlush).sorted())）")

    // ⑤ 双写点之二（beat 60s 节流段）：同样覆盖全部 6 个（saveStats 的条件写在行内，
    //    learn/model/dtLedger/shadowFF 带 dirty 门——dirty 门是"只在有增量时写"的节流，
    //    不算缺写点；判定标准=段内出现该 save 调用）
    guard let tStart = codeLines.firstIndex(where: { $0.contains("statsAccumSeconds >= 60") }) else {
        expect(false, "beat 节流段（statsAccumSeconds >= 60）定位失败"); return
    }
    var beatSaves = Set<String>()
    var j = tStart
    while j < codeLines.count {
        let t = codeLines[j]
        if let r = t.range(of: "ConfigStore\\.save[A-Za-z]+\\(",
                           options: .regularExpression) {
            beatSaves.insert(String(t[r]).replacingOccurrences(of: "(", with: "()"))
        }
        // 段尾：回到 statsAccumSeconds 块的 8 空格缩进闭括号
        if j > tStart, t == "            }" { break }
        j += 1
    }
    let missingThrottle = expectedFlush.subtracting(beatSaves).sorted()
    expect(missingThrottle.isEmpty,
           "beat 60s 节流段缺少持久化写点：\(missingThrottle)")
}

// MARK: - 门 C：statusChangeSummary 变化感知完备性

/// 变化感知摘要的显式豁免（每条理由=为什么"该字段单独变化时可以不吃一次写盘"）。
/// 先例：R46 对 loopInterval/thermalModelB 的豁免论证、R38 daemonVersion 反例（必须进）。
private let summaryExempt: [String: String] = [
    "timestamp": "10s 心跳保证 App 存活判定的写盘频率",
    "loopInterval": "诊断量，粒度每拍都可能变（R46 豁免先例）",
    "learnedSamples": "慢观察量：样本只增不减，粒度已由 learnedPoints 覆盖",
    "learnMap": "28 桶大数组：v3.7 P3 节流自身管理重发时机，入摘要会让节流失效",
    "decisionTrace": "诊断trace：主导量 temp/target 已各自在摘要（error 是其派生）",
    "hardwareProfile": "进程内不变的慢变量，仅启动首拍变化，10s 心跳足够",
    "thermalModelUsable": "模型诊断量（R46 豁免先例同族）",
    "thermalModelB": "模型辨识系数，R46 明确豁免",
    "thermalModelSamples": "模型样本计数，慢观察量",
    "thermalFeedTrusted": "信任门内部诊断量（R89），翻转罕见",
    "thermalModelFalsified": "证伪计数（R89），只增罕见",
    // R93：daemon 生命周期内恒为常量（init 默认参数=当前代际），不随拍变化；
    // 跨版本变化的那一刻 daemonVersion 同拍必变（R38 已进摘要）——单独纳入只会
    // 让每拍摘要变长，不会让任何一拍提前落盘
    "schemaVersion": "schema 代际常量（R93）；跨版本时 daemonVersion 同拍必变",
    "sensors.cpuAverage": "展示用慢变量（核心均温），取整噪声不敏感",
    "sensors.otherHotspots": "动态键字典：主热点已由 cpuDie/gpuDie 通道覆盖",
]

func testStatusSummaryChecklist() {
    group("变化感知完备性门(R92)")
    // ① Mirror 全集：DaemonStatus 顶层 + sensors 展开一层
    let status = DaemonStatus(sensors: SensorReadings(cpuDie: 70, gpuDie: 60),
                              mode: .curve, appliedPercent: 50,
                              fans: [], timestamp: Date())
    var fields = Set(Mirror(reflecting: status).children.compactMap(\.label))
    fields.subtract(["sensors"])   // sensors 展开为子字段登记
    for child in Mirror(reflecting: status.sensors).children {
        if let l = child.label { fields.insert("sensors.\(l)") }
    }
    expect(fields.count >= 44,
           "DaemonStatus 全集抠出 \(fields.count) 个字段，不应少于 44（37 顶层 + 7 sensors 子字段；Mirror 失效要判红）")

    // ② 覆盖集：statusChangeSummary 源码里实际引用的 s.xxx / s.sensors.xxx。
    // 两个独立正则：一级名（s.mode / s.fans.map 都归到字段名 mode/fans——
    // 方法调用 .map/.rawValue 不可能出现在 s. 后第一个词位，天然被过滤）
    // 与 sensors 展开（s.sensors.ssd → sensors.ssd）
    guard let src = repoSource("Sources/SMCCore/Config.swift") else {
        expect(false, "读不到 Sources/SMCCore/Config.swift——变化感知门未执行")
        return
    }
    let lines = src.components(separatedBy: "\n")
    guard let startIdx = lines.firstIndex(where: { $0.contains("public func statusChangeSummary") }) else {
        expect(false, "Config.swift 里找不到 statusChangeSummary（改名？）")
        return
    }
    var body = ""
    var i = startIdx + 1
    // 跳过注释：整行注释与行尾注释里的 `s.xxx` 引用都不算覆盖
    // （M2 整行注释形态 + M3 行尾注释形态，两次变异实测的教训）
    while i < lines.count, strippingTrailingComment(lines[i]) != "}" {
        let code = strippingTrailingComment(lines[i])
        if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body += code + "\n"
        }
        i += 1
    }
    var covered = Set<String>()
    let nsBody = body as NSString
    // 词边界后行断言：`fanParts.joined` / `percs.map` 这类"尾字母 s 的局部变量"
    // 不得被当成 s. 引用（R92 首轮实测抓到的假阳性形态）
    if let topRegex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])s\\.([A-Za-z][A-Za-z0-9]*)"),
       let subRegex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])s\\.sensors\\.([A-Za-z][A-Za-z0-9]*)") {
        subRegex.enumerateMatches(in: body, range: NSRange(location: 0, length: nsBody.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: body) else { return }
            covered.insert("sensors." + String(body[r]))
        }
        topRegex.enumerateMatches(in: body, range: NSRange(location: 0, length: nsBody.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: body) else { return }
            covered.insert(String(body[r]))
        }
    }
    covered.subtract(["sensors"])   // sensors 已展开为子字段，顶层名不算引用
    expect(covered.count >= 25,
           "摘要抠出 \(covered.count) 个引用字段，不应少于 25（抠取器失效要判红）")

    // ③ 完备性（核心牙）：全集 == 摘要引用 ∪ 豁免。
    // R16/R22 两次事故的形状：新 status 字段没进摘要也没表态 → 本门第一条红。
    let exempt = Set(summaryExempt.keys)
    let uncovered = fields.subtracting(covered).subtracting(exempt).sorted()
    expect(uncovered.isEmpty,
           "DaemonStatus 字段未进变化感知摘要也未豁免：\(uncovered)。字段单独变化时那一拍不落盘，App 最长陈旧 10s（心跳）。要么进 statusChangeSummary，要么在 summaryExempt 登记理由")
    let stale = exempt.subtracting(fields).sorted()
    expect(stale.isEmpty, "豁免登记里出现已不存在的字段：\(stale)")

    // ④ 引用有效性：摘要引用的必须是真实字段（防拼写错误静默丢通道）
    let ghost = covered.subtracting(fields).sorted()
    expect(ghost.isEmpty, "摘要引用了 DaemonStatus 不存在的字段（拼写错误=通道静默失效）：\(ghost)")
}
