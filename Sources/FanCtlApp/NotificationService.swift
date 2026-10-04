// NotificationService —— 过热/风扇健康/AI 优化通知（从 FanModel 提取）
import Foundation
import UserNotifications
import SMCCore

// 高占用进程（与 FanModel.ProcessUsage 语义一致，独立定义避免循环依赖）
// id = 面板展示标签（角色词走括号式，用户指定）；app = 纯软件名（通知元凶行用它，
// 避免「抖音（渲染进程）（30%）」这种双括号套娃）
struct ProcessInfo: Identifiable, Equatable {
    let id: String
    let app: String
    let cpu: Double
}

final class NotificationService {
    private let canNotify = Bundle.main.bundleIdentifier != nil

    // v3.4.5（4E）：通知权限懒请求——不再 App 启动即弹系统授权框（首次启动
    // 观感突兀且用户尚未理解通知价值）。首个通知事件发生前请求一次。
    private var authorizationRequested = false

    /// 事件前请求授权：首次调用发起系统弹窗，此后幂等。授权被拒时通知静默
    /// 失效（add 无害），行为与启动即请求一致。
    private func ensureAuthorized() {
        guard canNotify, !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // 风扇健康状态
    private var fanAnomalySince: [Int: Date] = [:]
    private var lastFanAlertAt: [Int: Date] = [:]   // R23 打磨 F4：per-fan 冷却——原全局单值会让左风扇报警后右风扇即使早已满足判据也被压 6h（且其 anomalySince 不清零，6h 后发的是过期事件）

    // 过热状态
    private var hotSince: Date? = nil
    private var lastOverheatNotify = Date.distantPast

    // MARK: - 风扇健康监测

    func checkFanHealth(_ entries: [FanState], controlReason: ControlReason?) {
        guard canNotify else { return }
        // 仅当 daemon 实际控制风扇时才检测：.auto / AI 空闲交还时 targetRPM 是系统自己设定的
        guard controlReason != .aiIdle, controlReason != .auto else {
            fanAnomalySince.removeAll(); return
        }
        if entries.isEmpty { fanAnomalySince.removeAll(); return }
        let now = Date()
        for f in entries {
            guard f.targetRPM > f.minRPM + 150 else { fanAnomalySince[f.id] = nil; continue }
            let stalled = f.actualRPM < 100
            let lagging = abs(f.actualRPM - f.targetRPM) > max(300, f.targetRPM * 0.25)
            guard stalled || lagging else { fanAnomalySince[f.id] = nil; continue }
            guard let since = fanAnomalySince[f.id] else { fanAnomalySince[f.id] = now; continue }
            let need: TimeInterval = stalled ? 30 : 90
            guard now.timeIntervalSince(since) >= need,
                  now.timeIntervalSince(lastFanAlertAt[f.id] ?? .distantPast) > 6 * 3600 else { continue }
            lastFanAlertAt[f.id] = now
            fanAnomalySince[f.id] = nil
            ensureAuthorized()
            notifyFanIssue(f, stalled: stalled, fanCount: entries.count)
        }
    }

    private func notifyFanIssue(_ f: FanState, stalled: Bool, fanCount: Int) {
        let name = fanCount == 2 ? (f.id == 0 ? "左风扇" : "右风扇") : "风扇 \(f.id + 1)"
        let content = UNMutableNotificationContent()
        content.title = stalled ? "\(name)疑似停转" : "\(name)转速异常"
        content.body = stalled
            ? "目标 \(Int(f.targetRPM)) RPM，实际接近 0。请检查风扇是否被卡住或损坏。"
            : "目标 \(Int(f.targetRPM)) RPM，实际仅 \(Int(f.actualRPM))。可能积灰或轴承老化，建议清灰。"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "fanhealth-\(f.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - 发烧元凶通知

    func checkOverheat(_ temp: Double) {
        guard canNotify else { return }
        // R23 打磨 F2：temp≤1（传感器毛刺被采信为 0）此前直接 return，既不设也不清
        // hotSince → 一次 91° 尖峰把 hotSince 停在故障前，数分钟后新的 90° 尖峰首拍即
        // 满足"持续 30s"→ 发出失实的"已持续高温 30 秒"。无效读数须清零判定基准。
        guard temp > 1 else { hotSince = nil; return }
        if temp >= 90 {
            if hotSince == nil { hotSince = Date() }
            if let since = hotSince,
               Date().timeIntervalSince(since) >= 30,
               Date().timeIntervalSince(lastOverheatNotify) > 600 {
                lastOverheatNotify = Date()
                ensureAuthorized()
                notifyOverheat(temp: temp)
            }
        } else if temp < 85 {
            hotSince = nil
        }
    }

    private func notifyOverheat(temp: Double) {
        Task.detached(priority: .utility) {
            let culprits = Self.sampleCPUUsage(limit: 3).map { "\($0.app)（\(Int($0.cpu))%）" }
            let content = UNMutableNotificationContent()
            content.title = "温度过高：\(Int(temp))°C"
            content.body = culprits.isEmpty
                ? "已持续高温 30 秒，风扇正在全力散热"
                : "CPU 占用最高：" + culprits.joined(separator: "、")
            content.sound = .default
            let req = UNNotificationRequest(identifier: "overheat", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    // MARK: - 后台空转进程（R78，spinwatch 发现 → 清风提醒）

    /// 后台空转告警。标题/正文把**证据**直接给足，用户不用再打开终端复现：
    /// 置信度高（二进制没了/一个文件都不开）时标题就用"确定在白烧 CPU"的语气，
    /// 低置信度（还有文件活动，可能在干正事）用中性语气，不制造狼来了。
    func notifySpinner(_ a: SpinAlert) {
        guard canNotify else { return }
        ensureAuthorized()
        let cpuText = a.cpu.map { "\(Int($0.rounded()))%" } ?? "高占用"
        // R82：标题给中文辨识名（exe 缺失时用哨兵原始名兜底）；正文证据链不变
        let who = ProcessIdentity.displayName(executable: a.exe ?? a.name)
        let title: String
        if a.isHighConfidence {
            title = "\(who) 在白烧 CPU（\(cpuText)）"
        } else {
            title = "\(who) 占用 \(cpuText) 且持续 \(a.heldText)"
        }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = a.evidenceText + "\npid \(a.pid) · 面板「占用」上方可查看完整证据"
        c.sound = .default
        // R80：挂上分类；R81：**不再挂「立即结束」动作**——见 registerCategories
        c.categoryIdentifier = NotificationService.spinCategory
        // delegate 分支要靠 pid 定位结束哪个进程；请求 identifier 是去重键，不当数据载体。
        // 实例标识（启动时刻/uid/可执行路径）有就带上，没有就是"不可结束"的根因。
        var info: [String: Any] = [NotificationService.spinPidKey: a.pid]
        if let s = a.startSeconds { info[NotificationService.spinStartKey] = s }
        if let u = a.uid { info[NotificationService.spinUidKey] = u }
        if let e = a.exe { info[NotificationService.spinExeKey] = e }
        c.userInfo = info
        // 同一 pid 只保留最新一条：空转进程反复出现时通知中心不该被同一 pid 刷屏
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "spinner-\(a.pid)", content: c, trigger: nil))
    }

    // MARK: - AI 优化通知

    func notifyAutoOptimized(_ r: CurveOptimizer.Result) {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = "清风生成了新的曲线建议"
        c.body = "请打开面板确认后应用：" + r.summary
        ensureAuthorized()
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "auto-optimize", content: c, trigger: nil))
    }

    // MARK: - R80 通知动作（立即结束 / 忽略）

    /// 分类 id：空转告警专用。**必须与 delegate 里 add(UNNotificationCategory) 的同名一致**，
    /// 两边各写一份字符串就会静默失效（通知落不到这个分类，按钮不出现）。
    static let spinCategory = "SPIN_ALERT"

    /// 动作 id：注册处与 delegate 分支处只认这两个常量（同 spinCategory 一样三处同源）。
    static let spinKillAction = "spin.kill"
    static let spinIgnoreAction = "spin.ignore"

    /// userInfo 键：delegate 取回 pid 的唯一载体。请求 identifier 是"同一 pid 只留最新"
    /// 的去重键，不复用做数据传递。
    static let spinPidKey = "pid"
    static let spinStartKey = "startSeconds"
    static let spinUidKey = "uid"
    static let spinExeKey = "exe"

    /// 注册分类。App 启动时调一次（幂等）。
    ///
    /// R81 曾移除「立即结束」动作：当时告警生产端（spinwatch）不携带实例标识，
    /// 任何通知侧结束请求都只能被拒，必然失败的红按钮不如不给。
    /// R82 续十：哨兵已升级为每条告警携带 startSeconds/uid（4.2.45+ 契约），
    /// 动作恢复注册——delegate 收到后**仍然**走 SpinKillGuard 现场核验
    /// （身份缺失/进程退出/pid 复用/uid 或路径不符 → 拒绝并回投原因通知），
    /// 按钮存在 ≠ 免检。旧版分类被通知中心缓存时同样安全（同一守卫）。
    static func registerCategories() {
        guard canNotifyBundled else { return }
        let kill = UNNotificationAction(
            identifier: spinKillAction, title: "立即结束", options: [.destructive])
        let ignore = UNNotificationAction(
            identifier: spinIgnoreAction, title: "忽略", options: [])
        let cat = UNNotificationCategory(
            identifier: spinCategory,
            actions: [kill, ignore],
            intentIdentifiers: [],
            options: [.customDismissAction])
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            UNUserNotificationCenter.current().setNotificationCategories(
                existing.union([cat]))
        }
    }

    /// 把"为什么这次没给你杀掉"回投成一条通知——通知侧没有弹窗，这是唯一的反馈通道。
    static func explainKillDenied(pid: Int, denial: KillDenial) {
        guard canNotifyBundled else { return }
        let c = UNMutableNotificationContent()
        c.title = "结束动作已取消（pid \(pid)）"
        c.body = denial.userText
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "spinner-denied-\(pid)",
                                  content: c, trigger: nil))
    }

    /// delegate 是否可用的**无状态**判据：通知中心需要 bundle id 才投得出去。
    static var canNotifyBundled: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: - CPU 进程采样（共享工具方法）

    /// 「占用」页 + 过热通知共用。
    ///
    /// R79：`id` 从"进程可执行文件名"改成**用户能看懂的中文软件名**。
    /// 原实现给的是 `swift-frontend` / `WindowServer` / `抖音 Helper (Renderer)` ——
    /// 日常用户完全看不出是哪个软件在吃机器，而这一页的标题就叫"谁在发热"。
    ///
    /// 两步处理，缺一不可：
    ///   ① 辨识：经 `ProcessIdentity.detail()` 把可执行路径翻成 (软件名, 角色词)，
    ///      ("抖音", "渲染进程") / ("音频服务", nil)。纯本地读 plist + 内置对照表，不联网。
    ///   ② 归并：Electron 系 App（抖音/Hermes/DeepSeek Harness）会同时冒出
    ///      Renderer/GPU/Utility 好几个进程，逐条列会让前三名被同一个软件占满，
    ///      用户看不出"它总共吃了多少"。故按**软件名**相加后再取前 N。
    nonisolated static func sampleCPUUsage(limit: Int = 5, minCPU: Double = 8)
        -> [ProcessInfo] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pcpu,comm", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return [] }
        // v3.6.1：4s 强杀兜底——readDataToEndOfFile 无超时，ps 挂起时永久阻塞
        //（上层 in-flight 标志的"4s 过期"只是允许新任务进来，线程本身从未被释放）
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: killer)
        defer { killer.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        // ① 先解析成"软件名"（中文）+ 原始占用，一条原始行一条
        struct Raw { let app: String; let role: String?; let cpu: Double }
        var raws: [Raw] = []
        for line in out.split(separator: "\n").dropFirst() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let cpu = Double(parts[0]), cpu >= minCPU else { continue }
            let path = String(parts[1])
            let d = ProcessIdentity.detail(executable: path)
            raws.append(Raw(app: d.app, role: d.role, cpu: cpu))
        }

        // ② 按软件名归并：同一软件的多个 helper 进程占用相加。
        // 角色词取第一个看到的（归并后只表达"这软件在忙"，细分角色让位），
        // 归并键是"软件名"而非路径——同一软件不同 Frameworks 下的 helper 要并成一份。
        struct Merged { let app: String; var cpu: Double; var role: String? }
        var order: [String] = []          // 首次出现顺序（保底，纯排序前不用）
        var dict: [String: Merged] = [:]
        for r in raws {
            if dict[r.app] == nil { order.append(r.app) }
            if var m = dict[r.app] {
                m.cpu += r.cpu
                if m.role == nil { m.role = r.role }
                dict[r.app] = m
            } else {
                dict[r.app] = Merged(app: r.app, cpu: r.cpu, role: r.role)
            }
        }

        return dict.values
            .sorted { $0.cpu > $1.cpu }
            .prefix(limit)
            .map { m -> ProcessInfo in
                // 角色词用全角括号缀在软件名后（用户指定样式）：「抖音（渲染进程）」
                let label: String
                if let role = m.role, !role.isEmpty {
                    label = "\(m.app)（\(role)）"
                } else {
                    label = m.app
                }
                return ProcessInfo(id: label, app: m.app, cpu: m.cpu)
            }
    }
}
