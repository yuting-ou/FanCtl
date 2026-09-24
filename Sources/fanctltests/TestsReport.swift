import Foundation
import SMCCore

// DiagnosticReport（R37，fanprobe --report 的渲染层）
// 诊断包是 issue 里的第一手证据——它自己说谎比没有它更糟。所以这里锁三件事：
//   1. 小节数恒定（缺数据必须出声成"—/未知"，不许整段省略：省略＝"报告变短"被读成"没问题"）；
//   2. 不外泄 Swift 的 Optional/NaN/inf 渲染；
//   3. 关键口径（新旧账本、字段是否落盘、装机版本）显式标注。

/// 全空输入：daemon 没跑、没有任何 JSON、App 也没装（陌生机器上"啥都没装"的最坏路径）
private func emptyReportInput() -> DiagnosticReport.Input {
    DiagnosticReport.Input(generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           status: nil, statusAgeSeconds: nil, learn: nil, metrics: nil,
                           ledger: nil, model: nil, stats: nil,
                           configPresent: false, lastGoodPresent: false,
                           exitReason: nil, logReadable: false)
}

/// 满输入：每个小节都有真值可渲染
private func fullReportInput() -> DiagnosticReport.Input {
    var st = DaemonStatus(cpuTemp: 71.5, gpuTemp: 55, mode: .ai, appliedPercent: 62,
                          fans: [FanStatusEntry(id: 0, actualRPM: 2_600, targetRPM: 2_800,
                                                minRPM: 1_400, maxRPM: 5_600)],
                          onBattery: true, batteryOverride: true, reason: .ai, aiIntent: .rising)
    st.loopInterval = 3
    st.controlFault = false
    st.targetUnreachable = true
    st.safetyFloorPercent = 78
    st.baseTargetPercent = 55
    st.curveTargetPercent = 41
    st.nightOverride = false
    st.envTemp = 27.5
    st.powerWatts = 33
    st.aiTargetEffective = 74
    st.palmComp = 1.5
    st.calibrating = false
    st.learnEnvelopeGap = 0.4
    st.thermalModelUsable = true
    st.thermalModelB = 1.2
    st.thermalModelSamples = 312
    st.daemonVersion = "4.2.3 (94)"
    st.hardwareProfile = HardwareProfile(
        modelID: "Mac14,10", chipName: "Apple M2 Pro", osVersion: "26.1",
        fanCount: 1, sensorCounts: .init(cpu: 3, gpu: 1, nand: 2, batt: 3, palm: 1,
                                         heatsink: 4, other: 9),
        hasPowerKey: true, collectedAt: Date(timeIntervalSince1970: 1_690_000_000))

    var learn = ThermalLearn()
    for _ in 0..<7 { learn.record(temp: 70, percent: 50, now: Date(timeIntervalSince1970: 1)) }
    var met = AIControlMetrics(targetTemp: 74)
    met.record(temp: 80, output: 70, seconds: 20)          // 有秒加权分母 → 新口径
    var led = DTLedgerState()                             // 1s 快拍 + 20s 长拍 = 21s
    led.record(temp: 70, output: 50, seconds: 1, dDelta: nil, pDelta: nil,
               slopeRate: nil, now: Date(timeIntervalSince1970: 1))
    led.record(temp: 70, output: 50, seconds: 20, dDelta: nil, pDelta: nil,
               slopeRate: nil, now: Date(timeIntervalSince1970: 2))
    let model = ThermalModel()
    var stats = DailyStats(date: "2026-09-23")
    stats.speedChanges = 1_200
    stats.aiCyclingGuards = 40

    return DiagnosticReport.Input(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000), status: st,
        statusAgeSeconds: 4, learn: learn, metrics: met, ledger: led, model: model,
        stats: stats, configPresent: true, lastGoodPresent: true,
        exitReason: "watchdog: 控制环 90s 无心跳", logReadable: true,
        installedAppVersion: "4.2.2 (93)",
        daemonBinaryInstalledAt: Date(timeIntervalSince1970: 1_699_000_000))
}

func testDiagnosticReport() {
    group("诊断包结构与口径（R37）")

    // ① 行数恒定：空/满/半满三种输入必须同数——任何"按条件省略小节"都会在此红
    let emptyLines = DiagnosticReport.lines(emptyReportInput())
    let fullLines = DiagnosticReport.lines(fullReportInput())
    var halfInput = emptyReportInput()
    halfInput.status = DaemonStatus(cpuTemp: 70, gpuTemp: 55, mode: .auto, appliedPercent: 0,
                                    fans: [])
    let halfLines = DiagnosticReport.lines(halfInput)
    expectEqual(emptyLines.count, DiagnosticReport.sectionCount, "空输入行数=小节数")
    expectEqual(fullLines.count, DiagnosticReport.sectionCount, "满输入行数=小节数")
    expectEqual(halfLines.count, DiagnosticReport.sectionCount, "半满输入行数=小节数")
    expect(DiagnosticReport.sectionCount >= 19, "小节数不得倒退（当前只增不减）")
    for (idx, line) in emptyLines.enumerated() {
        expect(!line.isEmpty, "空输入第 \(idx) 行不得为空串（省略小节=谎报）")
    }

    // ② 渲染卫生：Optional / nil / NaN / inf 一律不得出现在给用户粘的文本里
    for (name, lines) in [("空", emptyLines), ("满", fullLines), ("半", halfLines)] {
        let text = lines.joined(separator: "\n")
        expect(!text.contains("Optional("), "\(name) 输入无 Optional 外泄")
        expect(!text.contains("nil"), "\(name) 输入无 nil 外泄")
        expect(!text.lowercased().contains("nan"), "\(name) 输入无 NaN 外泄")
        expect(!text.lowercased().contains("inf"), "\(name) 输入无 inf 外泄")
        // 诊断包只报状态，不得外泄用户数据文件路径（配置内容/用户目录都不进报告）
        expect(!text.contains("Application Support"), "\(name) 输入不含用户数据目录路径")
    }

    // ③ 缺数据必须"出声"：空输入的每个关键小节都有明确缺态措辞
    let emptyText = emptyLines.joined(separator: "\n")
    expect(emptyText.contains("未运行（无 status.json）"), "空输入报 daemon 未运行")
    expect(emptyText.contains("硬件画像: 未知"), "空输入报硬件画像未知")
    expect(emptyText.contains("controlFault=未落盘"), "空输入把 controlFault 报成未落盘而非 false")
    expect(emptyText.contains("上次异常退出: 无记录"), "空输入的退出原因=无记录")
    expect(emptyText.contains("SMC 可打开: 是（未取读数）"),
           "probeError 缺省只报可打开，不冒充取到了读数")
    expect(emptyText.contains("daemon 缺失") || emptyText.contains("缺失（未装守护进程"),
           "空输入报 daemon 二进制缺失")
    expect(emptyText.contains("App 未找到"), "空输入报 App 版本未找到")
    expect(emptyText.contains("无 status，无从判断"),
           "没解出 status 时不下「daemon 早于某版」的因果结论")
    expect(emptyText.contains("缺（损坏将回出厂默认）"), "无 last-good 时明说会回出厂默认")

    // ④ 装机版本：App 版本串与 daemon 落盘时间都要出现（issue 第一问=什么版本）
    let fullText = fullLines.joined(separator: "\n")
    expect(fullText.contains("4.2.2 (93)"), "满输入含 App 版本串")
    expect(fullText.contains("二进制装于 2023-11-"), "满输入含 daemon 安装时间")
    expect(fullText.contains("daemon 自报 4.2.3 (94)"), "满输入打印 daemon 自报版本")
    expect(fullText.contains("模式 ai"), "满输入含调速模式")
    expect(fullText.contains("fan0: 2600/2800RPM"), "满输入含风扇实际/目标转速")
    expect(fullText.contains("口径 秒加权"), "有秒分母的指标标注为新口径")
    expect(fullText.contains("累计受控"), "dt 账本用「累计」字样与本轮受控区分")
    expect(fullText.contains("电池") && fullText.contains("电池降档 是"), "电源态进报告")

    // ④b R43：可读风扇数 < 画像风扇数 = 有本拍读不到、已交还系统的风扇。
    //     这一行必须把缺口出声——否则"数量 2 · fan0 …"读起来就是台单风扇机器。
    var gapInput = fullReportInput()
    if var st = gapInput.status, var prof = st.hardwareProfile {
        prof.fanCount = 2          // 画像 2 把，fans 仍只有一把（风扇 1 本拍无读数）
        st.hardwareProfile = prof
        gapInput.status = st
    }
    let gapLines = DiagnosticReport.lines(gapInput)
    let gapText = gapLines.joined(separator: "\n")
    expect(gapText.contains("另有 1 把本拍无读数"), "缺口进报告（不再靠读者自己数）")
    expect(!gapText.contains("已交还"),
           "渲染层只报现象：交还是引擎那一拍的判据，快照+旧 daemon 上下不了处置结论")
    expectEqual(gapLines.count, DiagnosticReport.sectionCount, "补这句不长模板（行数恒定契约）")
    expect(!fullText.contains("另有"), "1/1 机器不误报缺口（negative control）")
    // 声明值来自组可写的 status.json：虚高值只能做有界减法，不许拿它枚举区间
    var hostileGapInput = fullReportInput()
    if var st = hostileGapInput.status, var prof = st.hardwareProfile {
        prof.fanCount = 1_000_000
        st.hardwareProfile = prof
        hostileGapInput.status = st
    }
    let hostileGapText = DiagnosticReport.lines(hostileGapInput).joined(separator: "\n")
    expect(!hostileGapText.contains("另有"),
           "画像风扇数虚高 1e6 时不打印缺口（有界判据，渲染层不被 JSON 牵着走）")

    // ⑤ 口径标签必须与 getter 的回退条件同一条：加权秒被钳成 0（sanitized 的产物）时
    //    走的是样本口径除法，标签若仍写"秒加权"就是在给数字镀金
    var legacyInput = fullReportInput()
    var legacyMet = AIControlMetrics(targetTemp: 74)
    legacyMet.record(temp: 80, output: 70, seconds: 20)
    legacyMet.weightedSecondsTotal = 0            // 有样本、无加权分母
    legacyInput.metrics = legacyMet
    let legacyText = DiagnosticReport.text(legacyInput)
    expect(legacyText.contains("口径 样本口径(旧账本)"), "加权分母≤0 时标注为样本口径")
    expect(!legacyText.contains("口径 秒加权"), "样本口径的数字不得被标成秒加权")

    // ⑤b 全 0 与"还没开始统计"必须可分辨：指标换目标档即清零
    var freshInput = fullReportInput()
    freshInput.metrics = AIControlMetrics(targetTemp: 74)       // sampleCount = 0
    let freshText = DiagnosticReport.text(freshInput)
    expect(freshText.contains("本轮尚无样本"), "零样本指标出声，不冒充实测 0")
    expect(!freshText.contains("均温 0.0"), "零样本不得渲染成均温 0.0")

    // ⑥ 非有限值渲染成"—"而不是 0（0 会被读成"真的很低"）；每个数值小节都喂一遍，
    //    黑名单只有配合真实非有限输入才有鉴别力
    var nanInput = fullReportInput()
    var nanStatus = DaemonStatus(cpuTemp: .nan, gpuTemp: 55, mode: .auto,
                                 appliedPercent: .infinity,
                                 fans: [FanStatusEntry(id: 0, actualRPM: .nan, targetRPM: .infinity,
                                                       minRPM: 0, maxRPM: .nan)])
    nanStatus.envTemp = .nan
    nanStatus.powerWatts = .infinity
    nanStatus.sensors = SensorReadings(cpuDie: .nan, cpuAverage: nil, gpuDie: .nan,
                                       ssd: .infinity, palmRest: .nan, heatsink: .nan)
    nanInput.status = nanStatus
    let nanText = DiagnosticReport.text(nanInput)
    expect(nanText.contains("CPU —"), "NaN 温度渲染为—")
    expect(nanText.contains("输出 —%"), "inf 输出渲染为—")
    expect(nanText.contains("环境 —") && nanText.contains("功耗 —W"),
           "环境/功耗的非有限值也走—")
    expect(!nanText.lowercased().contains("nan") && !nanText.lowercased().contains("inf"),
           "整份报告在任何小节都喂了非有限值后仍无 nan/inf 外泄")

    // ⑥b 传感器故障哨兵：daemon 无有效读数时写 cpuDie:0——报成"CPU 0.0"是谎
    var sentinelInput = fullReportInput()
    var sentinel = DaemonStatus(cpuTemp: 0, gpuTemp: 0, mode: .auto, appliedPercent: 0, fans: [])
    sentinel.controlFault = true
    sentinel.faultReason = .sensorUnavailable
    sentinelInput.status = sentinel
    let sentinelText = DiagnosticReport.text(sentinelInput)
    expect(sentinelText.contains("CPU 0(哨兵=无有效读数)"), "哨兵 0 标注为无有效读数")
    expect(!sentinelText.contains("CPU 0.0 "), "不把哨兵 0 当实测温度")

    // ⑦ 多行字符串不得破坏"一小节一行"（退出原因可能带换行）
    var multilineInput = fullReportInput()
    multilineInput.exitReason = "第一行\n第二行"
    let multilineLines = DiagnosticReport.lines(multilineInput)
    expectEqual(multilineLines.count, DiagnosticReport.sectionCount, "换行被压平后行数不变")
    expect(multilineLines.contains(where: { $0 == "上次异常退出: 第一行 第二行" }),
           "退出原因的换行被压成空格")

    // ⑧ 状态新鲜度三态（能否信这份 status 取决于文件多久没写）
    var staleInput = fullReportInput()
    staleInput.statusAgeSeconds = 3_600
    expect(DiagnosticReport.text(staleInput).contains("停更 60 分钟"), "过期状态标注停更时长")
    staleInput.statusAgeSeconds = nil
    expect(DiagnosticReport.text(staleInput).contains("未运行（无 status.json）"),
           "无 status.json 时报未运行")

    // ⑧b 数字来自哪一刻：停更超过 30s 的快照必须在每个数值小节上标出来，
    //     否则读者会把十分钟前的温度当成现在温度去判断"风扇是不是该降速"
    var staleViewInput = fullReportInput()
    staleViewInput.statusAgeSeconds = 600
    let staleLines = DiagnosticReport.lines(staleViewInput)
    expect(staleLines.contains(where: { $0.hasPrefix("温度:") && $0.contains("陈旧快照") }),
           "温度小节带陈旧标记")
    expect(staleLines.contains(where: { $0.hasPrefix("风扇:") && $0.contains("陈旧快照") }),
           "风扇小节带陈旧标记")
    expect(staleLines.contains(where: { $0.hasPrefix("daemon:") && $0.contains("停更 10 分钟") }),
           "停更时长与标记同源（10 分钟）")
    // 版本取自 status.json，停更三小时后打印的自报版本同样是三小时前的——装机行必须同标
    expect(staleLines.contains(where: { $0.hasPrefix("装机:") && $0.contains("陈旧快照") }),
           "装机行也带陈旧标注")

    // 有 status 但没自报版本（旧 daemon / 该值被改）：报"未自报"，不猜版本
    var noVerInput = fullReportInput()
    noVerInput.status?.daemonVersion = nil
    let noVerText = DiagnosticReport.text(noVerInput)
    expect(noVerText.contains("未自报（旧版 daemon，或该值被改/被拒收）"),
           "缺值只说缺值，不断言「daemon 早于 4.2.3」")

    // ⑧b2 App 版本串来自**用户可写**的 bundle（install.sh 把 /Applications/清风.app
    //     chown 给登录用户），必须先消毒再进文本：ANSI 转义会在"把报告粘进终端"时真被
    //     解释，超长/非 ASCII 会把一行小节撑成不可读。拒渲染只出固定标记，不保留原文片段
    var escInput = fullReportInput()
    escInput.installedAppVersion = "\u{001B}[2J已清屏"
    let escLines = DiagnosticReport.lines(escInput)
    expectEqual(escLines.count, DiagnosticReport.sectionCount, "可疑版本串不改变小节数")
    expect(escLines.contains(where: { $0.hasPrefix("装机:") && $0.contains("版本串可疑（已拒绝渲染）") }),
           "含控制字符的 App 版本被拒渲染")
    let escText = escLines.joined(separator: "\n")
    expect(!escText.contains("\u{001B}") && !escText.contains("已清屏"),
           "被拒的原文一个字节都不留在报告里")
    var longInput = fullReportInput()
    longInput.installedAppVersion = String(repeating: "9", count: 65)
    expect(DiagnosticReport.text(longInput).contains("版本串可疑"),
           "超长 App 版本被拒渲染")
    var cjkInput = fullReportInput()
    cjkInput.installedAppVersion = "四其二"
    expect(DiagnosticReport.text(cjkInput).contains("版本串可疑"),
           "非 ASCII 的 App 版本被拒渲染（版本号本就该是 ASCII）")
    expect(DiagnosticReport.sanitizeVersion("4.2.3 (94)") == "4.2.3 (94)",
           "常规版本串照常通过（守卫不是照单全拒）")

    // ⑧b3 其余自由文本出口同样要过消毒：exit-reason.flag 与 SMC 错误串都是**盘上读来**的，
    //       support 目录组可写 → 里面可以是 ANSI 转义或几百 KB 文本
    var hostileInput = fullReportInput()
    let hostileReason = "watchdog \u{001B}[2J" + String(repeating: "z", count: 400)
    hostileInput.exitReason = hostileReason
    hostileInput.probeError = "io_connect \u{0007} 失败"
    let hostileLines = DiagnosticReport.lines(hostileInput)
    let hostileText = hostileLines.joined(separator: "\n")
    expectEqual(hostileLines.count, DiagnosticReport.sectionCount, "敌意文本不改变小节数")
    expect(!hostileText.contains("\u{001B}") && !hostileText.contains("\u{0007}"),
           "整份报告不含 ESC/BEL（控制字符只在原文里，不在输出里）")
    expect(hostileText.contains("已截断，原长 \(hostileReason.count)"),
           "超长退出原因如实报出**输入原长**并截断（\(hostileReason.count) 由构造侧给出，防手算错）")
    // 尾巴是否真被截掉：数 z 的个数（前缀 200 字符里只有 188 个 z，原文有 400 个）。
    // 用计数而不是 `contains(50 个 z)`——前缀本身就含 188 个连续 z，后者会必然假红
    let zCount = hostileText.filter { $0 == "z" }.count
    expect(zCount > 100 && zCount <= 200, "只保留前缀、尾巴不漏进报告（实得 z 数 \(zCount)）")
    expect(DiagnosticReport.text(fullReportInput()).contains("主因 AI 自动接管"),
           "中文标签照常通过（消毒不是照单全拒）")
    // 每一行都必须是"一行"：小节数只数元素，含 \r/\n 的串不会让它变——单独断言
    expect(hostileLines.allSatisfy { !$0.contains("\n") && !$0.contains("\r") },
           "敌意文本不会把任何一行拆成多行（含 CR）")

    // 硬件画像与战报日期同属"盘上读来的文本"（status.json / stats.json 组可写），
    // 两处都曾被漏在消毒之外——这两条就是那个洞的哨兵
    var hostileProfile = fullReportInput()
    hostileProfile.status?.hardwareProfile?.modelID = "Mac14,10\u{001B}]0;pwned\u{0007}"
    let profileText = DiagnosticReport.text(hostileProfile)
    // 只要求"协议字符不在输出里"：可打印载荷（pwned）无法也不该被删——删它等于改硬件画像
    expect(!profileText.contains("\u{001B}") && !profileText.contains("\u{0007}"),
           "硬件画像里的 ESC/BEL 被剥掉（机型标识同样来自可写文件）")
    expect(DiagnosticReport.lines(hostileProfile).allSatisfy { !$0.contains("\n") && !$0.contains("\r") },
           "敌意机型标识不会把画像行拆成多行")
    expect(profileText.contains("硬件画像: Mac14,10"), "画像行主体仍可读出（不是整行丢弃）")
    var hostileDate = fullReportInput()
    hostileDate.stats?.date = "2026-09-23\u{001B}[2J"
    let dateText = DiagnosticReport.text(hostileDate)
    expect(!dateText.contains("\u{001B}"), "战报日期里的控制字符被剥掉")

    // ⑧c 文件在但解不出（损坏或跨版本）：不得说"运行中"，也不得说"无 status.json"
    var undecodableInput = fullReportInput()
    undecodableInput.status = nil
    undecodableInput.statusAgeSeconds = 5
    let undecText = DiagnosticReport.text(undecodableInput)
    expect(undecText.contains("状态文件在但解不出"), "mtime 新但解不出时报解不出")
    expect(!undecText.contains("运行中"), "解不出时不谎报运行中")
    expect(!undecText.contains("未运行（无 status.json）"), "文件确实在场，不报成没有文件")

    // ⑧d 磨损战报的"今天"必须自己声明日期：daemon 停三天不能拿三天前的表称今日
    var oldStatsInput = fullReportInput()
    oldStatsInput.stats?.date = "2020-01-01"
    let oldStatsText = DiagnosticReport.text(oldStatsInput)
    expect(oldStatsText.contains("磨损(陈旧 2020-01-01)"), "非今日战报标陈旧并给出日期")
    expect(oldStatsText.contains("次/采样分"), "磨损速率分母口径写明是采样分（非 AI 受控分）")

    // ⑨ SMC 不可用也要出全小节（诊断包最大的价值恰恰在坏掉的时候）
    var brokenInput = emptyReportInput()
    brokenInput.probeError = "SMC 打不开: io_connect 失败"
    let brokenLines = DiagnosticReport.lines(brokenInput)
    expectEqual(brokenLines.count, DiagnosticReport.sectionCount, "SMC 故障时行数不减")
    expect(brokenLines.joined(separator: "\n").contains("SMC 打不开"), "SMC 错误原文进报告")
    expect(brokenLines.joined(separator: "\n").contains("SMC 可打开: SMC 打不开"),
           "错误出现在「SMC 可打开」小节名下（措辞与小节名一致）")

    // ⑩ passive 机型（无风扇）：数量与措辞都不能假
    var passiveInput = fullReportInput()
    passiveInput.status?.fans = []
    passiveInput.status?.hardwareProfile?.fanCount = 0
    let passiveText = DiagnosticReport.text(passiveInput)
    expect(passiveText.contains("数量 0"), "passive 机型报风扇数 0")
    expect(passiveText.contains("passive"), "passive 机型给出可解释措辞")

    // ⑫ dt 账本口径：天数与快拍占比直接决定"能不能调控制律"，格式化错一位就误导裁决
    expect(fullText.contains("累计受控 0.00 天"), "21s 账本按天渲染到小数点后两位")
    var tenDayInput = fullReportInput()
    var tenLedger = DTLedgerState()
    tenLedger.record(temp: 70, output: 50, seconds: 60, dDelta: nil, pDelta: nil,
                     slopeRate: nil, now: Date(timeIntervalSince1970: 1))   // 60s 标称拍
    tenLedger.nominal = nil
    tenDayInput.ledger = tenLedger
    expect(DiagnosticReport.text(tenDayInput).contains("累计受控 0.00 天"),
           "60s 账本按 86400 除得 0.00 天（除数错成 8640 会变 0.01 立刻显形）")
    expect(fullText.contains("快拍秒占比 4.8%"), "快拍占比按秒加权真实渲染")
    expect(fullText.contains("裁决门槛 ≥7 天且 >5%"), "账本行自带裁决门槛，防读者凭感觉放行")

    // ⑪ 装机落点常量：与 scripts/install.sh 的另一半真相必须逐字相同（漂移即红），
    //     且不受 overrideSupportDir 影响——诊断要读真实装机状态，不能读测试目录
    let dir = engineTestEnv()
    expectEqual(FanCtlPaths.installedDaemonBinary, "/usr/local/libexec/fanctld",
                "daemon 落点常量与安装脚本一致")
    expectEqual(FanCtlPaths.installedAppBundle, "/Applications/清风.app",
                "App 落点常量与安装脚本一致")
    expect(FanCtlPaths.installedDaemonBinary.hasPrefix("/usr/local/libexec/"),
           "daemon 落点常量不随测试目录漂移")
    expect(!FanCtlPaths.installedDaemonBinary.contains(dir.path),
           "daemon 落点常量与 override 目录无关")
}

/// R37 审查（自查发现的 P1）：诊断工具承诺"只读"，而 loadCorruptionAware 在解码失败时
/// 会写 `.corrupted` 备份并轮转删除旧备份——support 目录 root:admin 775 且无 sticky，
/// 登录用户跑一次 fanprobe 就能在 root 的数据目录里造文件、删掉 root 写的证据。
/// 这里锁两件事：只读路径真的零留痕，且 fanprobe 源码不许再退回带副作用的加载器。
func testProbeReadOnlyLoads() {
    group("诊断工具零副作用（R37）")
    let dir = engineTestEnv()
    let fm = FileManager.default
    FanCtlPaths.ensureDirectories()   // 临时目录不会自己出现；缺它则读写全失败=假绿
    // 选 dt-ledger 做样本：它是合成 Codable（类型不符必抛错），不像 learn/metrics 那样
    // 带"尽力抢救"的自定义解码器——损坏分支必须真的走到，断言才有意义
    let ledgerURL = FanCtlPaths.dtLedgerFile
    let garbage = Data("{\"fast\": 42}".utf8)

    func corruptedBackups() -> [String] {
        (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.contains(".corrupted.") } ?? []
    }

    // 只读：坏文件照旧解不出，但目录里不得留下任何备份
    try? garbage.write(to: ledgerURL)
    expect(fm.fileExists(atPath: ledgerURL.path), "前提：坏 dt-ledger 确实落到了盘上")
    expect(ConfigStore.loadDTLedger(readOnly: true) == nil, "只读加载坏 dt-ledger 返回 nil")
    expectEqual(corruptedBackups().count, 0, "只读加载不得在数据目录写损坏备份")

    // 对照（同一份坏数据）：daemon/App 侧的正常加载确实会留痕——证明上一条断言有牙，
    // 而不是"备份机制本身没写成功"造成的假绿
    expect(ConfigStore.loadDTLedger() == nil, "正常加载坏 dt-ledger 同样返回 nil")
    expectEqual(corruptedBackups().count, 1, "正常加载会留损坏备份（对照组，证上一条有牙）")
    try? fm.removeItem(at: ledgerURL)
    for name in corruptedBackups() {
        try? fm.removeItem(atPath: dir.appendingPathComponent(name).path)
    }

    // history 的逐日抢救分支同样要能只读
    let histURL = FanCtlPaths.historyFile
    try? Data("[[{\"bad\":1}],42]".utf8).write(to: histURL)
    expect(fm.fileExists(atPath: histURL.path), "前提：坏 history 确实落到了盘上")
    expect(ConfigStore.loadHistory(readOnly: true).isEmpty, "只读 history 对全坏数据给空表")
    expectEqual(corruptedBackups().count, 0, "只读 history 不写 history.corrupted.*")
    _ = ConfigStore.loadHistory()
    expect(corruptedBackups().contains { $0.hasPrefix("history.corrupted.") },
           "正常 history 加载会留损坏备份（对照组）")
    try? fm.removeItem(at: histURL)
    for name in corruptedBackups() {
        try? fm.removeItem(atPath: dir.appendingPathComponent(name).path)
    }

    // 源码门：fanprobe 是"只读诊断工具"——凡调用有副作用的加载器即红（loadStatus 除外，
    // 它本来就是纯 try? 解码）
    let src = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // fanctltests
        .deletingLastPathComponent()      // Sources
        .appendingPathComponent("fanprobe/main.swift")
    guard let text = try? String(contentsOf: src, encoding: .utf8) else {
        expect(false, "读到 fanprobe 源码做静态门")
        return
    }
    // 白名单式：fanprobe 里每一次 ConfigStore 调用都必须显式只读。点名黑名单不够——
    // 副作用最重的是 loadConfig（ensureDirectories + 备份坏文件 + 回写默认配置 + 刷
    // last-good），它没进黑名单就能悄悄加回来；白名单让"新接一个会写的 loader"默认就红。
    let pureReaders = ["ConfigStore.loadStatus"]     // 纯 try? 解码：无备份、无回写、无建目录
    let offenders = text.split(separator: "\n").filter { line in
        line.contains("ConfigStore.") && !line.contains("readOnly: true")
            && !pureReaders.contains { line.contains($0) }
    }
    let firstOffender = offenders.first.map { String($0.prefix(70)) } ?? "无"
    expectEqual(offenders.count, 0,
                "fanprobe 的 ConfigStore 调用全部只读（越线首行: " + firstOffender + "）")
    expect(!text.contains("ConfigStore.loadConfig"),
           "fanprobe 不得碰 loadConfig（它会建目录/备份/回写默认配置）")
    expect(!text.contains("ensureDirectories") && !text.contains("ConfigStore.save"),
           "fanprobe 不得碰建目录或任何 save 路径")
}

/// R38：`status.daemonVersion` —— 诊断包此前只能靠"App plist + 二进制 mtime"推断装的是
/// 什么版本；这个字段让 daemon 自报。它是**跨进程 JSON 契约**（旧 daemon 不写、新 App 要读），
/// 所以锁四件事：往返不丢、旧档解为 nil、外来值限长限字符集、进变化感知摘要。
func testDaemonVersionField() {
    group("daemon 版本自报（R38）")
    let enc = JSONEncoder()
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    enc.dateEncodingStrategy = .iso8601

    var st = DaemonStatus(cpuTemp: 70, gpuTemp: 55, mode: .ai, appliedPercent: 40, fans: [])
    st.daemonVersion = "4.2.3 (94)"
    guard let data = try? enc.encode(st), let back = try? dec.decode(DaemonStatus.self, from: data)
    else { expect(false, "status 往返可编解码"); return }
    expectEqual(back.daemonVersion, "4.2.3 (94)", "daemonVersion 往返不丢")

    // F9 同族守卫：引擎是用**参数**把版本传进 DaemonStatus 的，而 Optional 存储属性
    // 默认 nil——init 里漏一行赋值不会报错，只会让字段永远为空（v3.6.0 的
    // learnEnvelopeGap 就是这么静默失效了一整版）。上面那条往返走的是属性直赋，
    // 抓不到这种漏赋值，必须再走一次 init 参数。
    let viaInit = DaemonStatus(sensors: SensorReadings(cpuDie: 70, gpuDie: 55), mode: .ai,
                              appliedPercent: 40, fans: [], daemonVersion: "4.2.3 (94)")
    expectEqual(viaInit.daemonVersion, "4.2.3 (94)", "init 参数必须真赋到字段（F9 同族）")

    // 旧 daemon 的 status.json（无此字段）→ nil，而不是崩溃或空串
    let legacy = #"{"cpuTemp":70,"gpuTemp":55,"mode":"ai","appliedPercent":40,"fans":[],"timestamp":"2026-09-23T10:00:00Z"}"#
        .data(using: .utf8)
    expect(legacy != nil, "旧 status 样本可构造")
    if let legacy, let old = try? dec.decode(DaemonStatus.self, from: legacy) {
        expectEqual(old.daemonVersion, nil, "旧 status 无该字段时解为 nil")
    } else {
        expect(false, "旧 status 应能解码")
    }

    // 外来值守卫（status.json 在 root:admin 775 目录，同组用户可写）
    func decoded(_ raw: String) -> String? {
        // 手写 JSON 拼接（不用 raw 串：值前面那个引号会被 #"…"# 的分隔符吃掉，
        // 结果整条 JSON 非法、四个守卫断言全部空过——基线那条就是抓这个的）
        let json = "{\"cpuTemp\":70,\"gpuTemp\":55,\"mode\":\"ai\",\"appliedPercent\":40,"
            + "\"fans\":[],\"timestamp\":\"2026-09-23T10:00:00Z\",\"daemonVersion\":\"" + raw + "\"}"
        guard let d = json.data(using: .utf8) else { return nil }
        return (try? dec.decode(DaemonStatus.self, from: d))?.daemonVersion
    }
    expectEqual(decoded("4.2.3 (94)"), "4.2.3 (94)", "基线：常规版本串可解出")
    // 同一份夹具的常规字段也要解得出——否则三条 nil 期望可能只是"整包 JSON 没解出来"
    let baselineJSON = "{\"cpuTemp\":70,\"gpuTemp\":55,\"mode\":\"ai\",\"appliedPercent\":40,"
        + "\"fans\":[],\"timestamp\":\"2026-09-23T10:00:00Z\",\"daemonVersion\":\"4.2.3 (94)\"}"
    if let base = baselineJSON.data(using: .utf8),
       let baseStatus = try? dec.decode(DaemonStatus.self, from: base) {
        expectClose(baseStatus.cpuTemp, 70, 0.001, "夹具基线：常规字段同批解出（守卫不是靠整包失败蒙对）")
    } else {
        expect(false, "夹具基线：常规 status 应可解码")
    }
    expectEqual(decoded(String(repeating: "9", count: 64)), String(repeating: "9", count: 64),
                "64 字符以内保留")
    expectEqual(decoded(String(repeating: "9", count: 65)), nil, "超长版本串按污染处理")
    expectEqual(decoded("4.2.3\\nrm -rf"), nil, "含控制字符的版本串不收")
    expectEqual(decoded(""), nil, "空串按缺省处理（报告里走未落盘措辞）")

    // 红线：新 status 字段必须进变化感知——只改版本也要判定"有变化"
    var a = st; var b = st
    a.daemonVersion = "4.2.2 (93)"
    b.daemonVersion = "4.2.3 (94)"
    expect(statusChangeSummary(a) != statusChangeSummary(b),
           "仅版本不同也算状态变化（升级后第一拍必须落盘）")
    expect(statusChangeSummary(a).contains("4.2.2 (93)"), "摘要里能看到版本串")
    var noVer = st; noVer.daemonVersion = nil
    expect(statusChangeSummary(noVer) != statusChangeSummary(a),
           "版本从缺到有也算变化（旧 daemon 升到新版）")

    // 接线守卫：fanctld 必须把编译期常量注入 hooks，引擎必须把它带进每一处 status 构造
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    expect(source("Sources/fanctld/main.swift").contains("daemonVersion: fanctldVersion"),
           "fanctld 把编译期版本串注入 Hooks")
    let engine = source("Sources/SMCCore/ControlEngine.swift")
    // 数量对齐而不是钉死 3：钉死只防"删掉一处"，不防"新增一处构造忘了传版本"。
    // 构造点数 == 带版本点数 才是"每个 DaemonStatus 都带版本"这个不变量本身。
    let sites = engine.components(separatedBy: "DaemonStatus(").count - 1
    let wired = engine.components(separatedBy: "daemonVersion: hooks.daemonVersion").count - 1
    expectEqual(sites, 3, "引擎里的 status 构造点数量（常规 + 两个传感器故障分支）")
    expectEqual(wired, sites, "每个 status 构造点都必须带 daemonVersion（漏加即红）")

    // checked-in 占位常量必须与 VERSION 一致：CI 的测试作业走裸 `swift build`（不经
    // build.sh），漂了就等于让测试链上的 daemon 自报一个它从未拥有过的版本号
    let versionLine = source("VERSION").split(separator: "\n").first.map(String.init) ?? ""
    let fields = versionLine.split(separator: " ").map(String.init)
    expectEqual(fields.count, 2, "VERSION 读到两个字段")
    let generated = source("Sources/fanctld/Version.generated.swift")
    if fields.count == 2 {
        expect(generated.contains("let fanctldVersion = \"\(fields[0]) (\(fields[1]))\""),
               "Version.generated.swift 与 VERSION 同步（改号必须先跑 build.sh）")
    }

    // 行为覆盖（文本计数门只能防删，防不了"故障分支实际没写进去"）：
    // 启动即传感器读失败 → 走"sensors 全 0 的最小 status"那条构造，它也必须带版本
    let dir = engineTestEnv()
    ConfigStore.saveConfig(FanConfig(mode: .curve, preset: .balanced, envCompensation: false))
    let smc = makeFanSMC()
    smc.set("PSTR", 30)
    smc.set("Tp01", 0)                     // 温度读失败
    let clock = FakeClock()
    let collector = EngineCollector()
    let faultEngine = makeEngine(smc: smc, clock: clock, collector: collector,
                                 daemonVersion: "9.9.9 (1)")
    faultEngine.beat()
    let written = ConfigStore.loadStatus()
    expectEqual(written?.controlFault, true, "前提：这一拍确实走了传感器故障分支")
    expectEqual(written?.daemonVersion, "9.9.9 (1)", "故障分支的 status 也带自报版本")
    try? FileManager.default.removeItem(at: dir)
}
