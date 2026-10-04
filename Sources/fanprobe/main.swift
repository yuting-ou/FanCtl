import Foundation
import SMCCore
import SMCReadout   // 只读通路：本工具的依赖图里没有 SMCDriver，写 SMC 的 API 不存在

// fanprobe — 只读诊断工具：打印温度传感器、风扇状态、daemon 实时状态与 AI 学习进度（无需 root）
// "只读"是硬承诺：任何路径（含 --report 读 JSON）都不得在 /Library/Application Support/FanCtl
// 留下写入痕迹。那里是 root:admin 775 且无 sticky 位——登录用户写得进去，也会连带轮转删掉
// root 写的 .corrupted 备份。故所有加载器一律 readOnly: true。

// R37 `--report`：一条命令产出"陌生人机器上首问的那一串答案"，整段可直接粘进 issue。
// 放在 SMC 探测之前且独立成块：诊断包最大的价值恰恰在"东西坏了"的时候——SMC 打不开、
// daemon 没跑、配置损坏时都必须照样出全小节（缺失项渲染成 —/未知）。
if CommandLine.arguments.contains("--report") {
    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    let status = ConfigStore.loadStatus()
    // 状态新鲜度用文件 mtime 而非 status.timestamp：后者由 daemon 自己写，进程挂死时
    // 两者会分叉，而"这份报告能不能信"取决于文件多久没被写过
    var age: Double?
    if let attrs = try? FileManager.default.attributesOfItem(atPath: FanCtlPaths.statusFile.path),
       let mtime = attrs[.modificationDate] as? Date {
        age = Date().timeIntervalSince(mtime)
    }
    let probeError: String?
    do {
        let c = try SMCReadConnection()
        _ = try FanReadout(smc: c)
        probeError = nil
    } catch {
        probeError = "SMC 打不开：\(error)"
    }
    var exitReason: String? = nil
    if let data = try? Data(contentsOf: FanCtlPaths.exitReasonFile),
       let text = String(data: data, encoding: .utf8), !text.isEmpty {
        exitReason = text
    }
    // 装机版本：读 App 的 Info.plist（纯数据，不 exec 任何二进制）；daemon 侧只能拿到
    // 文件 mtime——版本串要 exec 才读得到，诊断工具不该为此拉起别人的进程
    var appVersion: String? = nil
    let plistURL = URL(fileURLWithPath: FanCtlPaths.installedAppBundle)
        .appendingPathComponent("Contents/Info.plist")
    if let plistData = try? Data(contentsOf: plistURL),
       let plist = (try? PropertyListSerialization.propertyList(from: plistData,
                                                                options: [], format: nil))
        as? [String: Any],
       let short = plist["CFBundleShortVersionString"] as? String, !short.isEmpty {
        let build = plist["CFBundleVersion"] as? String
        if let build, !build.isEmpty {
            appVersion = "\(short) (\(build))"
        } else {
            appVersion = short
        }
    }
    var daemonAt: Date? = nil
    if let attrs = try? FileManager.default.attributesOfItem(
            atPath: FanCtlPaths.installedDaemonBinary) {
        daemonAt = attrs[.modificationDate] as? Date
    }
    let input = DiagnosticReport.Input(
        generatedAt: Date(), status: status, statusAgeSeconds: age,
        learn: ConfigStore.loadLearn(readOnly: true), metrics: ConfigStore.loadAIMetrics(readOnly: true),
        ledger: ConfigStore.loadDTLedger(readOnly: true), model: ConfigStore.loadModel(readOnly: true),
        stats: ConfigStore.loadStats(readOnly: true),
        configPresent: exists(FanCtlPaths.configFile),
        lastGoodPresent: exists(FanCtlPaths.configLastGoodFile),
        exitReason: exitReason,
        logReadable: FileManager.default.isReadableFile(atPath: FanCtlPaths.logFile.path),
        probeError: probeError,
        installedAppVersion: appVersion,
        daemonBinaryInstalledAt: daemonAt)
    print(DiagnosticReport.text(input))
    exit(0)
}

// R82 续 `--zh-scan`：进程名汉化覆盖度体检。扫两份"会出现在清风界面上的名字"——
//   ① 当前全部运行进程的可执行路径（ps 只读列举）
//   ② 本机已装 App（/Applications、/System/Applications、CoreServices、~/Applications）的主程序
// 把现有辨识逻辑翻不出中文的列出来，给词表维护者一张活的欠账清单：
//   `swift run -c release --disable-sandbox fanprobe --zh-scan`
// 只读承诺与 --report 同源：只读 ps 输出与 Info.plist，不写任何文件。
if CommandLine.arguments.contains("--zh-scan") {
    var exes: Set<String> = []

    // ① 运行中的进程（`comm=` 去表头；非 / 开头的相对名也收——空转告警 exe 缺失时走的就是裸名）
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-Aceo", "comm="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    ps.standardError = FileHandle.nullDevice
    if (try? ps.run()) != nil {
        ps.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { exes.insert(t) }
        }
    }

    // ② 已装 App 的主程序（bundle 名 ≠ 进程名，必须读 CFBundleExecutable）
    let scanRoots = ["/Applications", "/System/Applications",
                     "/System/Applications/Utilities",
                     "/System/Library/CoreServices",
                     NSHomeDirectory() + "/Applications"]
    for root in scanRoots {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
        for item in entries where item.pathExtension == "app" {
            let plist = item.appendingPathComponent("Contents/Info.plist")
            guard let d = try? Data(contentsOf: plist),
                  let p = try? PropertyListSerialization.propertyList(from: d, format: nil)
                      as? [String: Any] else { continue }
            let exeName = (p["CFBundleExecutable"] as? String)
                ?? item.deletingPathExtension().lastPathComponent
            exes.insert(item.appendingPathComponent("Contents/MacOS/\(exeName)").path)
        }
    }

    var gaps: [(path: String, shown: String)] = []
    for exe in exes.sorted() {
        let shown = ProcessIdentity.displayName(executable: exe)
        if !ProcessIdentity.hasChinese(shown) {
            gaps.append((exe, shown))
        }
    }
    print("== 汉化覆盖度体检：会出现在界面上的名字共 \(exes.count)，仍无中文的 \(gaps.count) ==")
    for g in gaps {
        print("  \(g.path) → 显示为：\(g.shown)")
    }
    if gaps.isEmpty {
        print("✅ 本机所有进程名/已装 App 主程序都能翻出中文")
    } else {
        print("—— 以上即为词表欠账；能确凿翻译的补进 SMCCore/ProcessIdentity.swift 的 systemGlossary，")
        print("   认不准的保持原名（诚实 > 编造）。")
    }
    exit(0)
}

// R82 续十 `--selfcheck`：清风自我体检——按 docs/architecture.md 的「资源水位实测
// 基线」逐项审计自己的运行时状态。与 --report 的分工：report 说"状态是什么"，
// selfcheck 说"状态正不正常"（有阈值、有判定、非零退出码，可接 cron 无人值守巡检）。
// 只读承诺同源：读文件与 ps 列举，不写任何文件。
if CommandLine.arguments.contains("--selfcheck") {
    var issues = 0
    var total = 0
    func check(_ ok: Bool, _ name: String, _ detail: String) {
        total += 1
        print("  \(ok ? "✅" : "❌") \(name)：\(detail)")
        if !ok { issues += 1 }
    }
    // 同步超时运行（教训同 v3.6.1：沙箱/受限环境下子进程可能永不退出，
    // waitUntilExit 会把整个体检挂死——实测发生过）。
    // **读管线必须先行**：ps 全量输出 ~65KB 恰好顶爆 64KB 管线缓冲，"先等退出后读"
    // 会互相等死（实测：5s 超时被 SIGTERM、输出全空、误报"找到 0 个"）。
    // readDataToEndOfFile 阻塞到 EOF，超时杀器在旁路队列先 SIGTERM、2s 不退 SIGKILL
    // （v3.6.1 同款升级），子进程一死 EOF 解除阻塞。超时 = 环境受限，不可作为证据。
    func runCapture(_ path: String, _ args: [String], timeout: TimeInterval = 5)
        -> (code: Int32, out: String, ran: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", false) }
        let startedAt = Date()
        let killer = DispatchWorkItem {
            if p.isRunning { p.terminate() }
            Thread.sleep(forTimeInterval: 2)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // EOF 解除阻塞
        p.waitUntilExit()
        killer.cancel()
        if Date().timeIntervalSince(startedAt) >= timeout {
            return (p.terminationStatus, "", false)   // 被超时击杀 = 环境受限，不可作为证据
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, text, true)
    }

    // ①② 进程资源水位（ps 的 RSS 含共享库页，阈值按虚高口径放宽；
    //      物理口径见 vmmap 基线：daemon 10MB / App 47MB）
    var daemons: [(pid: String, cpu: Double, rssMB: Double)] = []
    var apps: [(pid: String, rssMB: Double)] = []
    var powermetricsEtime: String? = nil
    let rPs = runCapture("/bin/ps", ["-Aww", "-o", "pid=,pcpu=,rss=,etime=,comm="])
    do {
        let text = rPs.ran ? rPs.out : ""
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard p.count >= 5 else { continue }
            let comm = String(p[4])
            if comm == "/usr/local/libexec/fanctld" {
                daemons.append((String(p[0]), Double(p[1]) ?? 0, (Double(p[2]) ?? 0) / 1024))
            } else if comm == "/Applications/清风.app/Contents/MacOS/FanCtl" {
                apps.append((String(p[0]), (Double(p[2]) ?? 0) / 1024))
            } else if comm == "/usr/bin/powermetrics" {
                // etime 超过 10s 才算滞留（正常采样 ~1s 一次、每次 ~1s——
                // AI 主动控温时每 10s 醒一次，体检撞上在跑的采样是正常态）
                powermetricsEtime = String(p[3])
            }
        }
    }
    // 进程列举被环境拦截时（如受限沙箱内 ps 无法派生）→ ⚠️ 不计异常，
    // 绝不把"看不到"说成"不存在"（那会把运行中的 daemon 误报成未运行）
    if rPs.ran {
        check(daemons.count == 1, "守护进程唯一在跑",
              daemons.count == 1 ? "pid \(daemons[0].pid)" : "找到 \(daemons.count) 个")
        if let d = daemons.first {
            check(d.rssMB <= 50, "daemon 内存 ≤50MB（基线 10MB）", String(format: "%.1fMB", d.rssMB))
            check(d.cpu <= 5, "daemon CPU ≤5%（基线 ≈0%）", String(format: "%.1f%%", d.cpu))
        }
        check(apps.count <= 1, "菜单栏 App 单实例", "找到 \(apps.count) 个")
        if let a = apps.first {
            check(a.rssMB <= 150, "App 内存 ≤150MB（物理基线 47MB，ps 口径虚高）",
                  String(format: "%.1fMB", a.rssMB))
        }
    } else {
        print("  ⚠️ 进程资源水位：当前环境无法列举进程（不计异常）")
    }

    // ③ status.json 新鲜度（daemon 3s 一拍；30s = 连续 10 拍没写 = 异常）
    var statusAge: TimeInterval? = nil
    if let attrs = try? FileManager.default.attributesOfItem(atPath: FanCtlPaths.statusFile.path),
       let mtime = attrs[.modificationDate] as? Date {
        statusAge = Date().timeIntervalSince(mtime)
    }
    check(statusAge.map { $0 <= 30 } == true, "status.json 新鲜（≤30s）",
          statusAge.map { String(format: "%.0fs 前", $0) } ?? "不存在")

    // ④ 配置与回退锚
    check(FileManager.default.fileExists(atPath: FanCtlPaths.configFile.path),
          "config.json 在场", FanCtlPaths.configFile.path)
    check(FileManager.default.fileExists(atPath: FanCtlPaths.configLastGoodFile.path),
          "last-good 备份在场（损坏时可回退）", FanCtlPaths.configLastGoodFile.path)

    // ⑤ 开机自启锚：plist 在场（用户域 launchctl 看不到系统域服务——实测
    // "Could not find service"是正确回答，不能用作判定；进程在场已由 ①覆盖）
    let plistPath = "/Library/LaunchDaemons/com.fanctl.daemon.plist"
    check(FileManager.default.fileExists(atPath: plistPath),
          "开机自启 plist 在场", plistPath)

    // ⑥ SMC 可打开（只读连接）
    do {
        _ = try SMCReadConnection()
        check(true, "SMC 只读通路可打开", "连接就绪")
    } catch {
        check(false, "SMC 只读通路可打开", "\(error)")
    }

    // ⑥b 睡眠健康（R82 续十一，informational ⚠️ 不计清风异常）：
    // 自动休眠被谁阻止——"人在床上、屏幕黑了、风扇在转"的场景里，这行就是答案。
    // 清风自身从不在持有者名单里（daemon 不持任何休眠阻止断言）。
    do {
        let r = runCapture("/usr/bin/pmset", ["-g", "assertions"])
        var holders: [String] = []
        if r.ran {
            for line in r.out.split(separator: "\n") {
                let t = String(line)
                guard t.contains("pid "), t.contains("named:"),
                      t.contains("PreventUserIdleSystemSleep") || t.contains("PreventSystemSleep")
                else { continue }
                let trimmed = t.trimmingCharacters(in: .whitespaces)
                let pidPart = trimmed.split(separator: ":").first.map(String.init) ?? trimmed
                let named = trimmed.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
                holders.append("\(pidPart)（\(named)）")
            }
        }
        if !r.ran {
            print("  ⚠️ 睡眠健康：当前环境无法读取断言（不计异常）")
        } else if holders.isEmpty {
            print("  ✅ 自动休眠无阻碍（当前无进程持有休眠阻止断言）")
        } else {
            print("  ⚠️ 睡眠健康：系统当前**不会自动休眠**——被以下进程阻止（屏幕黑了 ≠ 系统睡了）：")
            for h in holders { print("      · \(h)") }
        }
    }

    // ⑦ powermetrics 采样子进程未卡死（正常 ~1s 一次、每次 ~1s；etime >10s = 卡死）
    var pmStuck = false
    if let e = powermetricsEtime {
        var rest = e; var days = 0
        if let hy = e.firstIndex(of: "-") { days = Int(e[..<hy]) ?? 0; rest = String(e[e.index(after: hy)...]) }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        var sec = parts.last ?? 0
        var mult = 60
        for p in parts.dropLast().reversed() { sec += p * mult; mult *= 60 }
        pmStuck = sec + days * 86400 > 10
    }
    check(!pmStuck, "powermetrics 采样子进程未滞留",
          powermetricsEtime.map { "在跑（etime \($0)，正常窗口 ~1s）" } ?? "无滞留实例")

    print(issues == 0 ? "✅ 自我体检 \(total) 项全部通过" : "❌ \(issues)/\(total) 项异常——对照 docs/architecture.md 资源水位基线排查")
    exit(issues == 0 ? 0 : 1)
}

do {
    let smc = try SMCReadConnection()
    let fans = try FanReadout(smc: smc)
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
    if let learn = ConfigStore.loadLearn(readOnly: true) {
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
    if let s = ConfigStore.loadStats(readOnly: true), s.date == DailyStats.today(), s.tempCount > 0 {
        print("今日: 最高 \(String(format: "%.1f", s.maxTemp))°C · 调速 \(Int(s.speedChanges)) 次 · 启停抑制 \(Int(s.aiCyclingGuards)) 次\(s.overshootPeak >= 3 ? " · 过冲峰值 +\(Int(s.overshootPeak.rounded()))°" : "") · 静音/安静 \(Int(s.quietSeconds / 60)) 分钟")
        // R45：单位串必须与 SMCCore 的同源常量一致。此前这里写死了
        // 一个错的口径名，而分母其实是采样秒（StatsSampler 对每个有效温度样本累加）——
        // 同一个数两个 surface 各说一套，而它是批次 B 控制律延后裁决的读数。
        // 注意：本文件不得再出现口径字面量，也不得在注释里写常量的名字——
        // 接线门按"代码里出现该常量的次数"判，注释凑数不算。
        print("  磨损速率: " + String(format: "%.2f", s.speedChangesPerMinute)
              + " " + DailyStats.wearRateUnit + "（分母=采样秒 tempSeconds；跨日比较看下面的墙钟列）")
        // R53：给出同一份数据的第二个分母（墙钟）。只换说法不改数值：读趋势的人
        // 第一次能看见两个口径差多少，而不是只能信一个数。两个口径各偏一边
        //（采样侧漏时⇒偏高、墙钟侧含停机⇒偏低），所以这里报"区间"而不是"真值"，
        // 倍数由 SMCCore 的纯函数给——安静日为 0 时它返回 nil，避免印出 nan/inf。
        if let wall = s.speedChangesPerWallMinute(now: Date()) {
            var line = "  同一份战报按当日墙钟算: " + String(format: "%.2f", wall)
                + " " + DailyStats.wallWearRateUnit
            if let infl = s.wearRateInflation(now: Date()) {
                line += String(format: "（采样口径 ÷ 墙钟 = %.2f 倍；真值落在两个数之间）", infl)
            } else {
                line += "（倍数不给：今日 0 次调速，或采样侧不足 30 秒）"
            }
            print(line)
        } else {
            print("  墙钟口径不可用（非今日战报，或当日不足 30 秒）")
        }
    }
    // R32：近 14 条归档战报的磨损速率 + 今日（history 未必含今天；裁决看趋势不看单日）
    // 防御性按日期排序：archiveDay 维护有序，但损坏/手改 JSON 不保证；suffix(14) 才是「最近」
    // R54：右列改成**墙钟覆盖率**（当日采样秒 ÷ 86400）= "这天的采样口径能信几成"。行文本由
    // DailyStats.wearTrendRow 给（纯函数、有断言）。分母不足的日子不再整行被滤掉——那恰好是
    // "计数还在涨、分母已经塌了"的最需要看见的一天，现在左列印 `—`、右列给出原因。
    do {
        let now = Date()
        var list = ConfigStore.loadHistory(readOnly: true).sorted { $0.date < $1.date }
        if let s = ConfigStore.loadStats(readOnly: true), s.date == DailyStats.today() {
            if list.last?.date == s.date { list.removeLast() }
            list.append(s)
        }
        let rows = list.suffix(14)
        if !rows.isEmpty {
            print("磨损速率趋势（" + DailyStats.wearRateUnit + " · 墙钟覆盖率；近 14 条归档记录 + 今日"
                  + "。覆盖率低 ⇒ 左列那份速率要按比例打折看）:")
            for d in rows { print(d.wearTrendRow(now: now)) }
        }
    }
    if let m = ConfigStore.loadAIMetrics(readOnly: true), m.sampleCount > 0 {
        print(String(format: "AI 指标: %.1f 分钟 | 平均 %.1f°C | 波动 %.1f°C | 平均输出 %.1f%% | 超温 %.0f 秒",
                     m.activeSeconds / 60, m.averageTemp, m.temperatureStdDev,
                     m.averageOutput, m.highTempSeconds))
    }
    // v3.8 D 项 dt 账本（EVOLUTION R8 预注册裁决；4.1-A3 规则修订见 EVOLUTION R17）：
    //   D 快拍/标称比 = 快拍 D 每秒贡献 ÷ 标称拍 D 每秒贡献。当前律下按构造 ≈3×斜率比
    //   （选择偏差保证 ≥3），该比值只作诊断；裁决 = 快拍秒占比门槛 + VM 危害测试。
    //   P 基线跨桶不等 = 选择偏差的预期表现（4.0.1 起退役"校准线"语义）。
    // 4.0.1（4.1-A1）：账本在独立 dt-ledger.json（生命周期 = 控制律版本，与评测指标解耦）。
    let ledger = ConfigStore.loadDTLedger(readOnly: true)
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
    if let m = ConfigStore.loadModel(readOnly: true) {
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
