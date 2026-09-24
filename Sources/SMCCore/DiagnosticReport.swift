// DiagnosticReport — 只读诊断包（fanprobe --report）：把"陌生人机器上首问的那一串问题"
// 压成一段可直接粘进 issue 的纯文本。
//
// 为什么存在：本项目的调参/验证全部来自一台机器（EVOLUTION 的 N=1 问题），而 Release
// 在往陌生硬件分发。issue 里的"风扇不转/很吵/温度高"没有机器画像与运行时状态就只能猜。
// 一条命令产出一份结构化快照，比让用户逐段截图可靠得多。
//
// 设计约束（都被 fanctltests 锁住，改动前先看测试）：
//   1. **固定行数**：每个小节恒出一行，缺数据写"—/未知"，绝不整段省略——省略会让
//      "报告变短"被误读成"没问题"，也让行数断言失去鉴别力。
//   2. **不外泄 Optional/nil**：Swift 的 `\(Optional)` 会打印 "Optional(x)"，这里一律
//      经 map/reducing 成字符串；测试里对整份文本做黑名单断言。
//   3. **纯函数**：不读文件、不碰 SMC、不看时钟（时间由调用方注入），所以能在无权限
//      环境里完整测试；副作用（读 JSON、跑 SMC）留在 fanprobe 的薄壳里。
//   4. **只含只读信息**：不含路径列表以外任何可被利用的本地细节（无用户名、无路径枚举）。

import Foundation

public enum DiagnosticReport {
    /// 小节数（含表头）。fanprobe 与测试都以此为准：改动导致行数变化时必须同步此值，
    /// 否则行数断言会红——这是故意的，防止有人"顺手"按条件省略小节。
    public static let sectionCount = 19

    public struct Input {
        public var generatedAt: Date
        public var status: DaemonStatus?
        /// status.json 的新鲜度（秒）；nil = 文件不存在/不可读
        public var statusAgeSeconds: Double?
        public var learn: ThermalLearn?
        public var metrics: AIControlMetrics?
        public var ledger: DTLedgerState?
        public var model: ThermalModel?
        public var stats: DailyStats?
        public var configPresent: Bool
        public var lastGoodPresent: Bool
        public var exitReason: String?
        public var logReadable: Bool
        /// SMC 直读失败时的错误串（正常为 nil）——报告在 SMC 不可用时也必须出全小节
        public var probeError: String?
        /// 已装 App 的版本串 "4.2.2 (93)"；nil = /Applications/清风.app 缺失或 plist 不可读
        public var installedAppVersion: String?
        /// daemon 二进制的最后写入时间（≈ 最后一次装/升级时间）；nil = 文件不存在
        public var daemonBinaryInstalledAt: Date?

        public init(generatedAt: Date, status: DaemonStatus?, statusAgeSeconds: Double?,
                    learn: ThermalLearn?, metrics: AIControlMetrics?, ledger: DTLedgerState?,
                    model: ThermalModel?, stats: DailyStats?, configPresent: Bool,
                    lastGoodPresent: Bool, exitReason: String?, logReadable: Bool,
                    probeError: String? = nil, installedAppVersion: String? = nil,
                    daemonBinaryInstalledAt: Date? = nil) {
            self.generatedAt = generatedAt; self.status = status
            self.statusAgeSeconds = statusAgeSeconds
            self.learn = learn; self.metrics = metrics; self.ledger = ledger
            self.model = model; self.stats = stats
            self.configPresent = configPresent; self.lastGoodPresent = lastGoodPresent
            self.exitReason = exitReason; self.logReadable = logReadable
            self.probeError = probeError
            self.installedAppVersion = installedAppVersion
            self.daemonBinaryInstalledAt = daemonBinaryInstalledAt
        }
    }

    /// 统一的时间戳格式：机器可读、跨 locale 稳定（en_US_POSIX，防非公历日历错乱）
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f
    }()

    /// 只到"日"的戳（与 DailyStats.date 同形态 yyyy-MM-dd），用于判战报是不是今天
    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func n(_ v: Double?, _ fmt: String = "%.1f") -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: fmt, v)
    }
    private static func n(_ v: Int?) -> String { v.map(String.init) ?? "—" }
    /// 温度渲染：`0` 是传感器无有效读数时 daemon 写的**哨兵**（ControlEngine 在
    /// sensorUnavailable/sensorImplausible 两分支直接构造 cpuDie:0, gpuDie:0），
    /// 照原样出数等于把"读不到"报成"冰点级低温"——诊断包最坏的一种谎。
    private static func t(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        if v <= 1 { return "0(哨兵=无有效读数)" }
        return String(format: "%.1f", v)
    }
    private static func b(_ v: Bool?, yes: String, no: String) -> String {
        guard let v else { return "—" }
        return v ? yes : no
    }
    /// 身份类字符串（版本串）的消毒：**限长 + 只收可打印 ASCII**。
    /// 两个来源都不该被无条件信任——daemon 侧已在 `DaemonStatus` 解码时过滤（那道管"落盘的
    /// JSON"），这里管"渲染前最后一道"，因为它要挡的是 App 侧：`/Applications/清风.app`
    /// 被安装脚本 chown 给登录用户，`CFBundleShortVersionString` 想写什么写什么，其中
    /// `\x1b[2J` 这类 ANSI 转义会在"用户把报告粘进终端/issue"时真的被解释。
    /// 拒渲染时报错值被整体替换成固定标记，不保留任何原文（保留前缀就等于放行前缀）。
    public static func sanitizeVersion(_ s: String?, limit: Int = 64) -> String? {
        guard let s, !s.isEmpty, s.count <= limit else { return nil }
        return s.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e } ? s : nil
    }
    /// 所有"从盘上读来的自由文本"的统一出口：压平换行、剥掉控制字符（含 ESC/ BEL——
    /// 这些会在"fanprobe 直接 print 到终端"与"把报告粘进终端"时被真的解释）、限长（超长只留前缀 + 截断标记，
    /// 否则一个 200KB 的 exit-reason.flag 就能把 19 行快照变成不可读巨块）。
    /// 非 ASCII 的**可见**字符保留：中文小节标签本来就带中文。
    static func safeText(_ s: String, limit: Int = 200) -> String {
        // 控制字符换成空格而不是删掉：`a\nb` 删成 `ab` 会把两个词焊在一起
        let kept = s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : String($0) }
        var out = kept.joined()
        if out.count > limit {
            out = String(out.prefix(limit)) + "…（已截断，原长 " + String(s.count) + "）"
        }
        return out
    }
    /// 版本类字段（App plist / daemon 自报）的唯一出口：缺失给指定措辞，可疑给固定标记
    private static func versionOr(_ s: String?, missing: String) -> String {
        guard let s, !s.isEmpty else { return missing }
        return sanitizeVersion(s).map { one($0) } ?? "版本串可疑（已拒绝渲染）"
    }
    /// 把可选字符串安全收成一行（去换行，防破坏"一行一小节"结构）
    private static func one(_ s: String?, fallback: String = "—") -> String {
        guard let s, !s.isEmpty else { return fallback }
        let flat = safeText(s).trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? fallback : flat
    }

    /// 生成报告行（每小节恰一行）。刻意写成"一行一个 let"：把多段 `+` 嵌进单个
    /// append 表达式会让 swiftc 类型推断超时（实测），拆开既好读也好排错。
    public static func lines(_ i: Input) -> [String] {
        let s = i.status
        var out: [String] = []
        out.append("清风诊断包 v1 · 生成于 \(stamp.string(from: i.generatedAt))")

        // 版本必须是第二行：issue 的第一问永远是"你装的什么版本"。daemon 二进制没有
        // 可低成本读出的版本串（读它要 exec），所以用"App plist 版本 + daemon 落盘时间"
        // 这对组合——两者不一致（App 新、daemon 旧）正是升级半途失败的特征。
        // 新鲜度必须也管这一行：版本取自 status.json，daemon 停三天后再升级，这里印出的
        // 就是三天前的自报版本——与"App 新 daemon 旧"的签名完全同形
        let stale: String = ((i.statusAgeSeconds ?? 0) > 30 && s != nil) ? "（陈旧快照）" : ""
        // App 版本来自用户可写的 bundle，必须先消毒：可疑值不保留任何片段，只出固定标记
        let appVer = versionOr(i.installedAppVersion,
                               missing: "未找到（\(FanCtlPaths.installedAppBundle)）")
        let daemonWhen: String = i.daemonBinaryInstalledAt.map { "二进制装于 " + stamp.string(from: $0) }
            ?? "二进制缺失（未装守护进程，或落点不可读）"
        // 版本是 daemon **自报**（取自同组可写、未经校验的 status.json）。缺值的原因至少三种
        // （旧版没这字段 / 压根没解出 status / 外来值被守卫拒收），兜底文案不许写成因果断言
        let daemonVer: String
        if s == nil {
            daemonVer = "无 status，无从判断"
        } else if let raw = s?.daemonVersion {
            daemonVer = sanitizeVersion(raw).map { "自报 " + one($0) } ?? "版本串可疑（已拒绝渲染）"
        } else {
            daemonVer = "未自报（旧版 daemon，或该值被改/被拒收）"
        }
        out.append("装机: App " + appVer
                   + " · daemon " + daemonVer + " · " + daemonWhen + stale)

        let profile: String = s.flatMap { $0.hardwareProfile }?.oneLine
            ?? "未知（daemon 未运行或状态未落盘）"
        out.append("硬件画像: " + one(profile))

        // 新鲜度取自文件 mtime，"能不能信下面的数字"取决于它；但 status 解不解得出
        // 是另一件事——文件在、解不出时若仍报"运行中"，下面八个小节的"—"就没法解释
        let daemonLine: String
        if let rawAge = i.statusAgeSeconds {
            let age = max(0, rawAge)                 // 时钟回拨不给负数
            if s == nil {
                daemonLine = "状态文件在但解不出（损坏或跨版本），最后写入 "
                    + String(format: "%.0f", age) + " 秒前"
            } else if age <= 30 {
                daemonLine = "运行中（状态 " + String(format: "%.0f", age) + " 秒前）"
            } else {
                daemonLine = "停更 " + String(format: "%.0f", age / 60) + " 分钟（可能已退出/休眠）"
            }
        } else {
            daemonLine = "未运行（无 status.json）"
        }
        out.append("daemon: " + daemonLine + " · 轮询 " + n(s?.loopInterval, "%.0f") + "s")

        let modeLine: String = "调速: 模式 " + one(s?.mode.rawValue)
            + " · 主因 " + one(s?.reason?.label)
            + " · 输出 " + n(s?.appliedPercent, "%.0f") + "%"
            + " · 意图 " + one(s?.aiIntent?.label)
        out.append(modeLine + stale)

        // "为什么这么吵/这么安静"九成落在这一行：电源、夜间、目标叠加后的生效值
        let powerLine: String = "电源与目标: " + b(s?.onBattery, yes: "电池", no: "市电")
            + " · 电池降档 " + b(s?.batteryOverride, yes: "是", no: "否")
            + " · 夜间安静 " + b(s?.nightOverride, yes: "是", no: "否")
            + " · 生效目标 " + n(s?.aiTargetEffective) + "°"
            + " · 曲线期望 " + n(s?.curveTargetPercent, "%.0f") + "%"
            + " · 体感补偿 " + n(s?.palmComp) + "°"
            + " · 冷启动校准 " + b(s?.calibrating, yes: "是", no: "否")
            + "（— = 该字段未落盘，daemon 版本偏旧）"
        out.append(powerLine + stale)

        let faultLine: String = "故障: controlFault="
            + (s?.controlFault.map { $0 ? "true" : "false" } ?? "未落盘")
            + " 原因 " + one(s?.faultReason?.rawValue)
            + " · 压不住目标 " + b(s?.targetUnreachable, yes: "是", no: "否")
            + " · 安全托底 " + n(s?.safetyFloorPercent, "%.0f") + "%"
            + " · 基础目标 " + n(s?.baseTargetPercent, "%.0f") + "%"
            + "（未落盘/— = daemon 版本早于该字段）"
        out.append(faultLine + stale)

        let tempLine: String = "温度: CPU " + t(s?.cpuTemp)
            + " · GPU " + t(s?.gpuTemp)
            + " · SSD " + t(s.flatMap { $0.sensors.ssd })
            + " · 掌托 " + t(s.flatMap { $0.sensors.palmRest })
            + " · 散热片 " + t(s.flatMap { $0.sensors.heatsink })
            + " · 环境 " + t(s?.envTemp)
            + " · 功耗 " + n(s?.powerWatts) + "W"
        out.append(tempLine + stale)

        let fanText: String
        if let fans = s?.fans, !fans.isEmpty {
            fanText = fans.map { "fan\($0.id): " + n($0.actualRPM, "%.0f") + "/"
                + n($0.targetRPM, "%.0f") + "RPM（量程 " + n($0.minRPM, "%.0f")
                + "–" + n($0.maxRPM, "%.0f") + "）" }.joined(separator: " · ")
        } else {
            fanText = "未知（无 status 或风扇数为 0=passive 机型）"
        }
        let fanNumber: String = s.flatMap { $0.hardwareProfile }.map { String($0.fanCount) } ?? "—"
        // R43：可读风扇数 < 画像风扇数 = 有本拍读不到的风扇，这一行必须把缺口出声——
        // 否则"数量 2 · fan0 …"在报告里读起来就是台单风扇机器。
        // 只报现象、不下处置结论：交还是引擎那一拍用 live fanCount 做的判据，这里拿的是
        // status 快照（且旧 daemon 根本不交还、交还写也可能失败），说"已交还"就是越界镀金。
        // 声明值来自组可写的 status.json，只做有界减法、不枚举区间。
        let gapText: String = {
            guard let st = s, !st.fans.isEmpty, let declared = st.hardwareProfile?.fanCount else { return "" }
            let gap = declared - st.fans.count
            return (gap > 0 && gap <= 16) ? " · 另有 " + String(gap) + " 把本拍无读数" : ""
        }()
        out.append("风扇: 数量 " + fanNumber + " · " + fanText + gapText + stale)

        let confLine: String = "配置: config.json " + (i.configPresent ? "在" : "缺")
            + " · last-good " + (i.lastGoodPresent ? "在（损坏时可回退）" : "缺（损坏将回出厂默认）")
        out.append(confLine)

        let learn = i.learn
        let learnLine: String = "热经验: 样本 " + n(learn.map { $0.sampleTotal })
            + " · 采信点 " + n(learn.map { $0.learnedBucketCount })
            + " · 包络健康度 " + n(s?.learnEnvelopeGap, "%.1f") + "°（→0=已自愈）"
        out.append(learnLine)

        let modelLine: String = "热模型: 可用 " + b(s?.thermalModelUsable, yes: "是", no: "否")
            + " · 内存 b " + n(s?.thermalModelB, "%.2f")
            + " · 落盘 a=" + n(i.model.map { $0.a }, "%.2f")
            + " b=" + n(i.model.map { $0.b }, "%.2f")
            + " 样本 " + n(i.model.map { $0.sampleCount })
            + "（a/b 均为归一化值=物理×50；内存每拍更新、落盘约 60s 一次，"
            + "差一个落盘窗口属正常；只有落盘读不到文件才是未加载/刚重置）"
        out.append(modelLine)

        let met = i.metrics
        // 口径标注必须与 averageTemp/… 的回退条件**同一条**（weightedSecondsTotal>1e-6，
        // 见 ControlMetrics.weightedSpan）：sanitized() 会把非法值钳成 0，"键存在"不等于
        // "走的是加权分支"——按 != nil 判就会给样本口径的数字贴上秒加权标签。
        let span = met.flatMap { $0.weightedSecondsTotal }.map { $0 > 1e-6 } ?? false
        let caliber: String = span ? "秒加权" : "样本口径(旧账本)"
        // 指标随目标档位切换清零（每档一份账本），"全 0"与"还没开始统计"必须可分辨
        let metLine: String
        if let met, met.sampleCount == 0 {
            metLine = "AI 评测: 本轮尚无样本（换目标档即清零；数字未起算，非实测为 0）"
        } else {
            metLine = "AI 评测: 本轮受控 " + n(met.map { $0.activeSeconds / 60 }, "%.1f")
                + " 分钟（换目标档清零） · 均温 " + n(met?.averageTemp)
                + " · 波动 " + n(met?.temperatureStdDev)
                + " · 均输出 " + n(met?.averageOutput, "%.0f") + "%"
                + " · 过冲 +" + n(met?.maxOvershoot)
                + " · 口径 " + caliber
        }
        out.append(metLine)

        let led = i.ledger
        let ledgerLine: String = "dt 账本: 累计受控 " + n(led.map { $0.totalSeconds / 86400 }, "%.2f") + " 天"
            + " · 快拍秒占比 " + n(led.flatMap { $0.fastSecondsShare }.map { $0 * 100 }, "%.1f") + "%"
            + "（裁决门槛 ≥7 天且 >5%）"
        out.append(ledgerLine)

        let st = i.stats
        // stats.json 是"某一天"的战报：daemon 停了三天就会拿三天前的表报"今日"，
        // 所以日期必须出现在行内，并与报告生成时刻比对
        let statsWhen: String
        if let d = st?.date {
            // 日期串同样来自可写的 stats.json：只用于比较的原样比，进文本的先消毒
            statsWhen = d == dayStamp.string(from: i.generatedAt) ? "今日 \(one(d))" : "陈旧 \(one(d))"
        } else {
            statsWhen = "无战报"
        }
        let wearLine: String = "磨损(\(statsWhen)): 调速 " + n(st?.speedChanges, "%.0f") + " 次"
            + " · 速率 " + n(st?.speedChangesPerMinute, "%.2f") + " " + DailyStats.wearRateUnit
            + " · 启停抑制 " + n(st?.aiCyclingGuards, "%.0f") + " 次"
        out.append(wearLine)

        out.append("上次异常退出: " + one(i.exitReason, fallback: "无记录"))
        out.append("日志: /Library/Logs/FanCtl " + (i.logReadable ? "可读" : "不可读（权限）"))
        out.append("SMC 可打开: " + one(i.probeError, fallback: "是（未取读数）"))
        out.append("说明: 只含运行时状态与上次退出原因（控制字符已剥、超长已截断）；不读配置内容、不含用户"
                   + "名；温度/转速均为 daemon 落盘快照，非本命令实时采样。")
        return out
    }

    public static func text(_ i: Input) -> String { lines(i).joined(separator: "\n") }
}
