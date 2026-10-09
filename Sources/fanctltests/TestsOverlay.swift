// TestsOverlay —— 静音/冲刺窗口的三入口一致性 + pid 越界不崩（R85）
//
// 起因：R83 加了 MCP 这个**第二写入方**，但 App 仍按"我是唯一写入方"行事——
// syncConfigFromDisk 回填了 mode/manualPercent/曲线，唯独不读 quietUntil/boostUntil。
// 后果不是"少显示一个倒计时"：App 每次 saveConfig 都用内存值写回这两个字段，于是
//   · MCP 开的静音被静默取消（面板任何一次操作、或每小时的自动优化都会触发）；
//   · MCP 开的冲刺更糟——boostUntil 被写成 nil 而 mode 仍是 manual 100%，
//     daemon 的到期判定要求 boostUntil != nil，于是永不触发 ⇒ 永久全速。
// 同轮还查出 MCP 的生效判据比 daemon 松（只判 until > now，不看 24h 卫生上限、
// 不看封顶值是否在场），以及 SpinAlert 的 pid 无上限而下游是会 trap 的 Int32(pid)。
//
// 断言分四层：① 判据本体 ② daemon 与 MCP 对同一份盘上 config 必须同结论（正反两臂）
// ③ MCP 不再替 daemon 许兑不了的 SLA、不把"无数据"报成 0 ④ App 的对账纯函数。

import Foundation
import SMCCore

/// 记录实际发出的信号；空数组 = 一个信号都没发（TestsKillGuard 里的同名类是 file-private）
private final class OverlaySignalLog {
    var sent: [(pid: Int, signal: Int32)] = []
    var sender: SignalSender {
        SignalSender { pid, sig in self.sent.append((pid, sig)); return 0 }
    }
}

/// 调 MCP 工具，拆出 content[0].text 里的 JSON。失败路径 payload 为 nil、isError 为真。
private func mcpCall(_ srv: FanMCP, _ name: String, _ argsJSON: String = "{}")
    -> (payload: [String: Any]?, text: String, isError: Bool) {
    let req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\","
        + "\"params\":{\"name\":\"\(name)\",\"arguments\":\(argsJSON)}}"
    guard let out = srv.handle(req),
          let obj = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any],
          let result = obj["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let text = content.first?["text"] as? String else { return (nil, "", true) }
    let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    return (payload, text, result["isError"] as? Bool ?? false)
}

func testOverlayWindowConsistency() {
    group("静音/冲刺窗口三入口同源(R85)")

    // —— ① 判据本体：24h 卫生上限 + "静音必须有封顶值" ——
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let soon = now.addingTimeInterval(600)
    let far = now.addingTimeInterval(25 * 3600)
    expectEqual(OverlayWindow.effective(until: nil, now: now), nil, "没有截止时间 ⇒ nil")
    expectEqual(OverlayWindow.effective(until: soon, now: now), soon, "10 分钟窗口原样有效")
    expectEqual(OverlayWindow.effective(until: far, now: now), nil,
                "超过 24h 的截止视为未设置（只可能来自手改/损坏的 config）")
    expect(OverlayWindow.isActive(until: soon, now: now), "未到期 ⇒ 活跃")
    expect(!OverlayWindow.isActive(until: now.addingTimeInterval(-5), now: now), "已过期 ⇒ 不活跃")
    expect(!OverlayWindow.isActive(until: far, now: now), "异常久远 ⇒ 不活跃（与 daemon 同判据）")

    let noCap = FanConfig(mode: .curve, quietUntil: soon, quietCapPercent: nil,
                          envCompensation: false)
    expect(!OverlayWindow.quietActive(config: noCap, now: now),
           "缺封顶值 ⇒ daemon 根本不封顶，任何入口都不许报「静音中」")
    let withCap = FanConfig(mode: .curve, quietUntil: soon, quietCapPercent: 30,
                            envCompensation: false)
    expect(OverlayWindow.quietActive(config: withCap, now: now), "有窗口 + 有封顶 ⇒ 静音生效")

    let noBoost = FanConfig(mode: .manual, manualPercent: 100, envCompensation: false)
    expect(!OverlayWindow.boostExpired(config: noBoost, now: now), "没有 boostUntil ⇒ 谈不上到期")
    var pastBoost = noBoost; pastBoost.boostUntil = now.addingTimeInterval(-5)
    expect(OverlayWindow.boostExpired(config: pastBoost, now: now), "已过期 ⇒ 到期（daemon 交还 auto）")
    var farBoost = noBoost; farBoost.boostUntil = far
    expect(OverlayWindow.boostExpired(config: farBoost, now: now),
           "异常久远 ⇒ 同样按到期处理（与 ControlEngine 的冲刺兜底一致）")
    var liveBoost = noBoost; liveBoost.boostUntil = soon
    expect(!OverlayWindow.boostExpired(config: liveBoost, now: now), "冲刺进行中 ⇒ 未到期")

    // —— ② daemon 与 MCP 读同一份盘上 config，必须给出同一个结论 ——
    // 正反两臂都要：只有反臂的话，"静音从来就不生效"也能全绿。
    let envDir = engineTestEnv()
    defer {
        try? FileManager.default.removeItem(at: envDir)
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
    }
    let smc = makeFanSMC(); smc.set("Tp01", 80); smc.set("PSTR", 30)
    let clock = FakeClock()
    let col = EngineCollector()
    let engine = makeEngine(smc: smc, clock: clock, collector: col)

    let arms: [(String, Date, Bool)] = [
        ("合法 10 分钟窗口", clock.time().addingTimeInterval(600), true),
        ("异常久远的 48h 窗口", clock.time().addingTimeInterval(48 * 3600), false),
    ]
    for (label, until, shouldCap) in arms {
        ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced,
                                         quietUntil: until, quietCapPercent: 30,
                                         envCompensation: false))
        engine.beat()
        expectEqual(ConfigStore.loadStatus()?.reason == .quiet, shouldCap,
                    "\(label)：daemon 是否按静音封顶")
        // MCP 用默认 hooks（读的就是同一份盘上 config/status），只把时钟对齐引擎
        let mcp = FanMCP(version: "test", hooks: FanMCP.Hooks(now: { clock.time() }))
        let overlay = mcpCall(mcp, "fanctl_status").payload?["overlay"] as? [String: Any]
        expectEqual(overlay?["quietActive"] as? Bool, shouldCap,
                    "\(label)：MCP 与 daemon 同结论（判据同源，不再各算一套）")
    }

    // 生效时剩下的字段才该有值；不生效时残留一个倒计时/封顶值同样是撒谎
    ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced,
                                     quietUntil: clock.time().addingTimeInterval(48 * 3600),
                                     quietCapPercent: 30, envCompensation: false))
    let mcp2 = FanMCP(version: "test", hooks: FanMCP.Hooks(now: { clock.time() }))
    let ov2 = mcpCall(mcp2, "fanctl_status").payload?["overlay"] as? [String: Any]
    expect(ov2?["quietRemainingSeconds"] is NSNull, "不生效的静音不给剩余秒数")
    expect(ov2?["quietCapPercent"] is NSNull, "不生效的静音不给封顶值")
}

func testMCPHonesty() {
    group("MCP 不替 daemon 撒谎(R85)")

    let envDir = engineTestEnv()
    defer {
        try? FileManager.default.removeItem(at: envDir)
        FanCtlPaths.setOverridesForTesting(supportDir: nil, logDir: nil)
    }
    let clock = FakeClock()
    // 用引擎写一份真 status.json 当底座：下面三臂只改 timestamp / 单个传感器值，
    // 其余字段保持真实形态（手搓 DaemonStatus 会漏字段，测的就不是同一条路径了）
    let smc = makeFanSMC(); smc.set("Tp01", 70); smc.set("PSTR", 25)
    let col = EngineCollector()
    let engine = makeEngine(smc: smc, clock: clock, collector: col)
    engine.beat()
    guard let live = ConfigStore.loadStatus() else {
        expect(false, "前提：引擎应已写出 status.json")
        return
    }
    var staleStatus = live; staleStatus.timestamp = clock.time().addingTimeInterval(-600)
    var hostileStatus = live; hostileStatus.sensors.cpuDie = 1e308

    // —— ① 写入成功 ≠ 生效：按实测的 status 新鲜度说话 ——
    // 此前 persist() 无条件回 "daemon 会在下一拍热加载（≤20s）"，而同文件的读路径
    // 对缺 status.json 是失败关闭的——两种口径。daemon 死了也照样许 SLA。
    func noteFor(_ status: DaemonStatus?) -> (note: String?, ok: Bool?) {
        var h = FanMCP.Hooks(now: { clock.time() })
        h.saveConfig = { _ in true }
        h.loadStatus = { status }
        let r = mcpCall(FanMCP(version: "test", hooks: h), "fanctl_set_mode", "{\"mode\":\"curve\"}")
        return (r.payload?["note"] as? String, r.payload?["ok"] as? Bool)
    }
    let fresh = noteFor(live)
    expectEqual(fresh.ok, true, "daemon 新鲜：写入照旧算成功")
    expect(fresh.note?.contains("会在下一拍热加载") == true, "daemon 新鲜 ⇒ 可以承诺下一拍生效")
    let stale = noteFor(staleStatus)
    expectEqual(stale.ok, true, "daemon 陈旧：意图确实落盘了，仍算成功（但要说清楚）")
    expect(stale.note?.contains("600s 未更新") == true, "陈旧必须报实测秒数")
    expect(stale.note?.contains("会在下一拍热加载") == false,
           "陈旧时不得再许「下一拍热加载」这个兑不了的承诺")
    let dead = noteFor(nil)
    expectEqual(dead.ok, true, "daemon 不在：写入本身仍成功")
    expect(dead.note?.contains("读不到 status.json") == true, "daemon 不在要说清设置不会生效")
    expect(dead.note?.contains("会在下一拍热加载") == false, "daemon 不在时不得许生效承诺")

    // —— ② 多天战报：一行数据都没有 ≠ "各项都是 0" ——
    // days=1 本来就失败关闭，多天路径此前却在 `guard let s = today` 之前返回，
    // 于是新装机器问"近 7 天散热如何"会得到均温 0°、调速 0 次——被 AI 读成实测。
    var empty = FanMCP.Hooks(now: { clock.time() })
    empty.loadStats = { nil }
    empty.loadHistory = { [] }
    let none = mcpCall(FanMCP(version: "test", hooks: empty), "fanctl_stats", "{\"days\":7}")
    expect(none.isError, "窗口内零数据 ⇒ 失败关闭，不回一堆 0")
    expect(none.text.contains("不要把这些 0 当成实测"), "失败文案要说清 0 不是实测结果")
    expect(!(none.payload?["totals"] is [String: Any]), "零数据时不许给出 totals")

    // 正臂：有数据时照常汇总（否则"整条路径改死"也能全绿）
    var row = DailyStats(date: "2026-09-17")
    row.tempSeconds = 3600; row.tempSum = 3600 * 55; row.speedChanges = 12; row.revolutions = 400_000
    var withData = empty
    withData.loadHistory = { [row] }
    let some = mcpCall(FanMCP(version: "test", hooks: withData), "fanctl_stats", "{\"days\":7}")
    expect(!some.isError, "有归档数据 ⇒ 正常汇总")
    expectEqual(some.payload?["windowDays"] as? Int, 1, "窗口内实际有 1 天")
    expectEqual((some.payload?["totals"] as? [String: Any])?["avgTemp"] as? Double, 55.0,
                "按秒加权均温 = 55.0（手算：3600*55/3600）")

    // —— ③ 幅度荒谬但 JSON 合法的传感器值不许毁掉整份状态 ——
    // status.json 的 sensors 不走 sanitized()，而 num() 的 isFinite 守卫在乘 scale 之前：
    // 1e308 * 10 = inf ⇒ isValidJSONObject 为假 ⇒ pretty() 退化成"此路径不应触达"，
    // 却仍以 isError:false 交回客户端（整份状态丢失，协议层还报成功）。
    var hHostile = FanMCP.Hooks(now: { clock.time() })
    hHostile.loadStatus = { hostileStatus }
    let poisoned = mcpCall(FanMCP(version: "test", hooks: hHostile), "fanctl_status")
    expect(!poisoned.isError, "越界幅度不该把只读工具变成失败")
    let sensors = poisoned.payload?["sensors"] as? [String: Any]
    expect(sensors?["cpuDie"] is NSNull, "越界幅度 ⇒ 该字段 NSNull（视图显 -），不污染其余字段")
    expect(!poisoned.text.contains("此路径不应触达"), "不许再走到 pretty() 的内部错误兜底")
    expect(sensors?["gpuDie"] is Double, "同段其余字段照常给出数值（没被连坐）")
    expect(poisoned.payload?["mode"] != nil, "整份状态仍在（此前是一个 inf 毁掉整个结果对象）")
}

func testOverlayAdoption() {
    group("App 对账外部窗口(R85)")

    let now = Date(timeIntervalSince1970: 1_790_000_000)
    // 必须带亚秒：App 内存里的 Date 是 `Date().addingTimeInterval(900)` 这种形态，
    // 落盘走 iso8601 会被截到整秒。夹具若取整秒，floor() 前后完全相等，
    // 下面"容差"那条断言就成了空气门（变异把 tolerance 改成 0 也全绿——实测过一次）。
    let appBoost = now.addingTimeInterval(600.7)
    let diskTruncated = Date(timeIntervalSince1970: floor(appBoost.timeIntervalSince1970))
    expect(appBoost != diskTruncated, "前提：夹具确实带亚秒差（否则容差断言无意义）")
    expect(abs(appBoost.timeIntervalSince(diskTruncated)) < OverlaySync.tolerance,
           "前提：这个差值落在容差内（否则测的不是同一件事）")

    var c = FanConfig(mode: .manual, manualPercent: 100, boostUntil: diskTruncated,
                      envCompensation: false)
    var a = OverlaySync.adopt(disk: c, appQuietEnd: nil, appQuietCap: 30,
                              appBoostEnd: appBoost, now: now)
    expectEqual(a.boostEnd, diskTruncated, "采纳盘上的冲刺截止")
    expect(!a.boostIsForeign, "亚秒差属同一段窗口 ⇒ 不是外部写入（否则会清掉冲刺前快照）")
    expect(!a.changed, "同一段窗口 ⇒ App 侧无需改动")

    a = OverlaySync.adopt(disk: c, appQuietEnd: nil, appQuietCap: 30, appBoostEnd: nil, now: now)
    expect(a.boostIsForeign, "App 不知道的冲刺 = 别的入口起的 ⇒ 没有快照可恢复，到期诚实回 auto")
    expect(a.changed, "外部窗口 ⇒ App 侧必须改（否则下次 saveConfig 就把它抹掉）")

    c.boostUntil = now.addingTimeInterval(-5)
    a = OverlaySync.adopt(disk: c, appQuietEnd: nil, appQuietCap: 30,
                          appBoostEnd: now.addingTimeInterval(600), now: now)
    expectEqual(a.boostEnd, nil, "已到期的冲刺不采纳（daemon 已交还，面板不该再显示倒计时）")
    expect(a.changed, "App 内存里还挂着冲刺 ⇒ 要清掉")
    expect(!a.boostIsForeign, "没有生效中的冲刺就谈不上外部与否")

    c = FanConfig(mode: .curve, quietUntil: now.addingTimeInterval(48 * 3600),
                  quietCapPercent: 25, envCompensation: false)
    a = OverlaySync.adopt(disk: c, appQuietEnd: nil, appQuietCap: 30, appBoostEnd: nil, now: now)
    expectEqual(a.quietEnd, nil, "48h 静音不采纳（daemon 视为未设置，显示倒计时就是撒谎）")
    expectEqual(a.quietCapPercent, nil, "没有生效静音就不带封顶值")

    c = FanConfig(mode: .curve, quietUntil: now.addingTimeInterval(600),
                  quietCapPercent: 25, envCompensation: false)
    a = OverlaySync.adopt(disk: c, appQuietEnd: nil, appQuietCap: 30, appBoostEnd: nil, now: now)
    expectEqual(a.quietEnd, now.addingTimeInterval(600), "合法静音采纳")
    expectEqual(a.quietCapPercent ?? -1, 25, "别的入口写的封顶值以磁盘为准（面板要显示真在执行的那个数）")
    expect(a.changed, "外部静音 ⇒ App 侧必须改")

    c.quietCapPercent = nil
    a = OverlaySync.adopt(disk: c, appQuietEnd: nil, appQuietCap: 30, appBoostEnd: nil, now: now)
    expectEqual(a.quietEnd, nil, "缺封顶值的静音不采纳（daemon 不封顶，面板不该显示静音中）")

    // 取消必须双向对称：别的入口解除了静音，App 也得放下
    c = FanConfig(mode: .curve, envCompensation: false)
    a = OverlaySync.adopt(disk: c, appQuietEnd: now.addingTimeInterval(300), appQuietCap: 25,
                          appBoostEnd: nil, now: now)
    expectEqual(a.quietEnd, nil, "别的入口解除静音 ⇒ App 同步放下")
    expect(a.changed, "解除也要触发 App 侧改动（否则面板继续显示已结束的静音）")
    expectEqual(a.quietCapPercent, nil, "静音结束后不留封顶值（否则 App 下次开静音会写回 25 而不是 30）")

    // —— App 侧接线的静态门 ——
    // fanctltests 不依赖 FanCtlApp（SwiftUI 宏插件在 CLT SDK 里缺失，见 BLOCKED.md），
    // 所以上面测的是判据本体，"App 有没有真的去调它"只能钉源码：删掉任一调用点，
    // MCP 设的窗口就重新变成"App 下次 saveConfig 抹掉"，而纯函数测试照样全绿。
    let modelURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/FanCtlApp/FanModel.swift")
    guard let src = try? String(contentsOf: modelURL, encoding: .utf8) else {
        expect(false, "前提：读得到 Sources/FanCtlApp/FanModel.swift（\(modelURL.path)）")
        return
    }
    let calls = src.components(separatedBy: "adoptOverlayFromDisk(").count - 1
    expect(calls >= 3, "adoptOverlayFromDisk 至少 3 处（1 个定义 + 启动对账 + syncConfigFromDisk），实到 \(calls)")
    expect(src.contains("OverlaySync.adopt(disk:"), "App 必须走 SMCCore 的判据，不许自己另算一套")
    expect(src.contains("@Published var quietCapPercent"),
           "封顶值必须可变：别的入口写的 25% 要能显示出来（此前是 let 30，面板永远显示 30）")
    expect(!src.contains("App 是唯一写入方"), "R83 起 App 不再是唯一写入方，这条旧前提不许留在注释里")
}

func testSpinAlertPidBounds() {
    group("空转告警 pid 越界不崩(R85)")

    // pid 此前只判 > 0、无上限（同文件的 ppid/threads/fdCount 都有界），而下游
    // ProcessProbe.live / SignalSender.live / executablePath 用的是**会 trap 的** Int32(pid)。
    // alerts.json 在用户家目录（同 uid 可写），且 canKillSpin 在 PanelView 的 body 里
    // ——每拍都调、不用点按钮 ⇒ 一个越界 pid 就能把常驻菜单栏 App 崩掉。
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    func decode(_ json: String) -> SpinAlert? {
        (try? dec.decode(SpinAlert.self, from: Data(json.utf8)))
    }
    expectEqual(decode("{\"pid\":4242,\"name\":\"x\"}")?.pid, 4242, "正常 pid 照旧解出")
    expectEqual(decode("{\"pid\":10000000,\"name\":\"x\"}")?.pid, 10_000_000, "上限内（含边界）收下")
    expect(decode("{\"pid\":10000001,\"name\":\"x\"}") == nil, "超出上限 ⇒ 整条告警按坏数据丢弃")
    expect(decode("{\"pid\":99999999999,\"name\":\"x\"}") == nil, "越界 pid ⇒ 拒收（进不了 Int32 转换）")
    expect(decode("{\"pid\":0,\"name\":\"x\"}") == nil, "pid 0 照旧拒收")
    expect(decode("{\"pid\":-7,\"name\":\"x\"}") == nil, "负 pid 照旧拒收")
    // 坏元素不拖垮整包（R78 既有纪律）：一条越界不得让同批正常告警消失
    let poolJSON = #"{"schema":"spinwatch/1","alerts":[{"pid":99999999999,"name":"坏"},{"pid":4242,"name":"好"}]}"#
    let pool = (try? dec.decode(SpinReport.self, from: Data(poolJSON.utf8)))?.alerts
    expectEqual(pool?.count, 1, "坏元素被跳过，好元素保留")
    expectEqual(pool?.first?.name, "好", "留下的是那条正常告警")

    // 守卫本体：越界 pid 走**真实**探针/信号器也不许崩，且一个信号都不发
    let huge = SpinAlert(pid: 99_999_999_999, name: "x", exe: "/usr/bin/true",
                         startSeconds: 1_700_000_000, uid: 501)
    expect(ProcessProbe.live.instance(99_999_999_999) == nil, "越界 pid：真实探针返回 nil 而不是 trap")
    expectEqual(SignalSender.live.send(99_999_999_999, SIGKILL), Int32(EINVAL),
                "越界 pid：不发信号，报 EINVAL（不谎报「已退出」）")
    let log = OverlaySignalLog()
    let outcome = SpinKillGuard.execute(alert: huge, probe: .live, sender: log.sender)
    if case .failure = outcome {} else { expect(false, "越界 pid 必须被拒绝") }
    expect(log.sent.isEmpty, "越界 pid：一个信号都不得发出")
    expect(!SpinKillGuard.canKill(huge, probe: .live), "越界 pid：面板按钮禁用（渲染路径不崩）")
}
