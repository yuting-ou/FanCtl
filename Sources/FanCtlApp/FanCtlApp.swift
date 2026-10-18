import SwiftUI
import Charts
import ServiceManagement
import UserNotifications
import SMCCore
import FanCtlAppCore

// FanCtl 菜单栏 App
// macOS 26 Liquid Glass 风格面板：玻璃卡片分组 + 实时曲线图，自适应深/浅色。
// 数据链：daemon 读 SMC 写 status.json，App 只读 status.json 展示（不直连 SMC）；
// 模式切换写 config.json 交给守护进程执行（单一数据源）。

// Liquid Glass 在 ImageRenderer 离屏渲染下无法正确合成（文字/材质会丢失），
// 快照模式下改用实心材质渲染卡片，仅用于验证布局；运行时仍为玻璃。
nonisolated(unsafe) var snapshotPlainCards = false

@main
struct FanCtlApp: App {
    @StateObject private var model: FanModel
    // R80：系统对 UNUserNotificationCenter.delegate 是**弱引用**。不在这儿持强的话
    // delegate 出 init 即释放，表现为"分类注册了、按钮也在，点了永远不回调"。
    private let spinDelegate: SpinActionDelegate?

    init() {
        // v3.4.5（4D）：卸载入口——SMAppService 登录项在 App 被删除后无法反注册
        //（无系统 CLI），卸载脚本在 pkill/删文件前用本参数让 App 自行注销。
        if CommandLine.arguments.contains("--unregister-login-item") {
            if Bundle.main.bundleIdentifier != nil {
                try? SMAppService.mainApp.unregister()
                print("已注销「登录时启动」项")
            }
            exit(0)
        }
        // R51：面板每拍渲染成本量具（离屏真窗口，只读真夹具、写盘落临时目录）
        if CommandLine.arguments.contains("--tickbench") {
            TickBench.run()   // 内部 exit
        }
        // 调试用：离屏渲染面板到 PNG（验证 UI 无需手动点开菜单栏）
        if CommandLine.arguments.contains("--snapshot") {
            snapshotPlainCards = true
            let model = FanModel()
            model.panelVisible = true  // 刷新面板专属数据（热点/战报）
            // 注入模拟历史数据，预览趋势图效果
            let now = Date()
            model.history = stride(from: -600.0, through: 0, by: 6).map { offset in
                let base = 68 + 8 * sin(offset / 90)
                let cpu = base + Double.random(in: -1...1)
                let gpu = base - 12 + 6 * sin(offset / 70) + Double.random(in: -1...1)
                return FanModel.TempSample(id: now.addingTimeInterval(offset), cpu: cpu, gpu: gpu)
            }
            model.systemPower = 38          // 预览功耗胶囊
            // R82 续十：风扇卡「加速归因」行预览（真数据快照验证用）
            model.rampAttribution = "抖音（渲染进程） 94% · 聚焦索引 48% · ZCode（图形进程） 37%"
            model.rampAttributionAt = Date()
            model.controlReason = .curve    // 预览决策可解释行
            model.daemonAlive = true        // 快照下无真实 daemon，手动置真以渲染决策行
            // 预览今日战报磁贴
            var demoStats = DailyStats(date: DailyStats.today())
            demoStats.maxTemp = 91; demoStats.maxTempAt = now
            demoStats.tempSum = 62 * 1200; demoStats.tempCount = 1200
            demoStats.highTempSeconds = 4500; demoStats.revolutions = 128000
            model.stats = demoStats
            // 可选指定模式预览：--snapshot auto|curve|manual（仅渲染，不写配置）
            // v2.6.2：先处理子视图快照分支（custom 会被 FanMode(rawValue:) 劫持成 .custom 模式，
            // 导致整面 custom 快照永远不可达——见下方 switch）
            let lastArg = CommandLine.arguments.last(where: {
                !$0.hasPrefix("-") && !$0.contains("=")
                    && !["warn", "boost", "dead", "lens", "dark"].contains($0)
            })

            // 排版实测用：--snapshot warn <mode> 强制最长警示条在场，量最坏情况总高
            if CommandLine.arguments.contains("warn") { model.configWriteFailed = true }
            // 排版实测：--snapshot lens 预览决策透镜行与学习地图有数据态（布局最坏情况）
            if CommandLine.arguments.contains("lens") {
                model.decisionTrace = DecisionTrace(target: 72, temp: 78, error: 6,
                                                    learned: 63, idle: false,
                                                    hysteresisHold: true, guardSeconds: 900)
                model.learnMap = stride(from: 50, through: 90, by: 5).map {
                    ThermalLearn.LearnedPoint(temp: Double($0), percent: min(95, Double($0) - 20),
                                              samples: 3 + $0 % 4)
                }
            }
            // 排版实测用：--snapshot boost <mode> 预览冲刺倒计时态（boostBar 最高态）
            if CommandLine.arguments.contains("boost") { model.boostEndDate = now.addingTimeInterval(900) }
            // 排版实测用：--snapshot dead <mode> 预览 daemon 挂态（双标签同现最坏情况）
            if CommandLine.arguments.contains("dead") { model.daemonAlive = false }
            // 排版实测：--snapshot scene=<名[,名…]> <mode> 把面板推到只有真机数据才会出现的形态。
            // 整套 UI 的视觉对齐必须逐屏量——默认屏盖不到静音倒计时、监控四个 tab、曲线编辑器、
            // 空转告警行、无风扇提示、电池/夜间覆盖、AI 状态行的四个分支、另两条警示、冷启动空态。
            let scene = CommandLine.arguments.first(where: { $0.hasPrefix("scene=") })
                .map { String($0.dropFirst(6)) } ?? ""
            applySnapshotScene(scene, to: model, now: now)
            if lastArg == "hotspots" || lastArg == "today" || lastArg == "usage" || lastArg == "custom" || lastArg == "label" {
                renderStandaloneViews(lastArg)
                exit(0)
            }
            var suffix = ""
            if let m = lastArg, let forced = FanMode(rawValue: m) {
                model.mode = forced
                suffix = "-\(m)"
                // 让预览的决策胶囊与强制模式一致（避免 manual 预览却显“按曲线调速”）
                switch forced {
                case .auto: model.controlReason = .auto
                case .curve: model.controlReason = .curve
                case .ai: model.controlReason = .ai; model.aiIntent = .rising
                case .manual: model.controlReason = .manual
                }
            }
            // 单独渲染子视图（面板内是另一个 tab / 预设，整面快照盖不到）
            func renderStandalone<V: View>(_ view: V, to name: String) {
                let wrapped = view.padding(12).frame(width: 320).background(.white)
                let r = ImageRenderer(content: wrapped)
                r.scale = 2
                if let img = r.nsImage,
                   let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: name))
                }
            }
            // v2.6.2：子视图快照分支提前处理（custom 会被 FanMode(rawValue:) 劫持成
            // .custom 模式，导致整面 custom 快照永远不可达）
            func renderStandaloneViews(_ arg: String?) {
                switch arg {
                case "hotspots":
                    renderStandalone(HotspotList(components: model.components)
                                        .frame(height: MonitorStyle.height, alignment: .top),
                                     to: "/tmp/fanctl-snapshot-hotspots.png")
                case "today":
                    renderStandalone(TodayStatsView(stats: model.stats)
                                        .frame(height: MonitorStyle.height, alignment: .top),
                                     to: "/tmp/fanctl-snapshot-today.png")
                case "usage":
                    // R82 续六：占用页此前是唯一没有独立快照的监控 tab——5 行紧凑排版 +
                    // 中文进程名 + 满格能量条只能靠真机肉眼验收。补上演示数据
                    // （混合长名/短名/高占用饱和，覆盖排版最坏情况）。
                    model.topProcesses = [
                        FanModel.ProcessUsage(id: "抖音（渲染进程）", app: "抖音", cpu: 94.6),
                        FanModel.ProcessUsage(id: "功耗度量工具", app: "功耗度量工具", cpu: 48.7),
                        FanModel.ProcessUsage(id: "ZCode（图形进程）", app: "ZCode", cpu: 37.0),
                        FanModel.ProcessUsage(id: "网易云音乐（渲染进程）", app: "网易云音乐", cpu: 25.1),
                        FanModel.ProcessUsage(id: "谷歌浏览器", app: "谷歌浏览器", cpu: 17.7),
                    ]
                    model.gpuTemp = 63
                    renderStandalone(ProcessHogView(processes: model.topProcesses, gpuTemp: model.gpuTemp)
                                        .frame(height: MonitorStyle.height, alignment: .top),
                                     to: "/tmp/fanctl-snapshot-usage.png")
                case "custom":
                    renderStandalone(EditableCurveChart(points: model.customPoints,
                                                        currentTemp: max(model.cpuTemp, model.gpuTemp),
                                                        appliedPercent: model.appliedPercent,
                                                        live: model.daemonAlive,
                                                        onChange: { _ in }),
                                     to: "/tmp/fanctl-snapshot-custom.png")
                case "label":
                    // 4.1.1：菜单栏标签像素验证（常温/高温警示两态并排）。
                    // 4.1.2（R21）：标签改为订阅 MenuBarState。
                    // R23 打磨 F7：渲染样式经 styleOverride 显式传 both，不再覆写共享
                    // menuBarStyle 键（原做法会让常驻 App 标签闪现 + 中途被杀丢用户设置）。
                    let normalState = MenuBarState()
                    normalState.update(temp: 62, boost: false, quiet: false, style: "both")
                    let warmState = MenuBarState()
                    warmState.update(temp: 82, boost: false, quiet: false, style: "both")
                    renderStandalone(VStack(spacing: 10) { MenuBarLabel(state: normalState, styleOverride: "both")
                                                         MenuBarLabel(state: warmState, styleOverride: "both") }
                                        .background(.white),
                                     to: "/tmp/fanctl-snapshot-label.png")
                default:
                    break
                }
            }
            // 排版实测的场景开关：只改内存里的模型字段（tab3 会顺带拉起一次只读 /bin/ps
            // 采样——monitorTab 的 didSet 行为，与真机切到「占用」tab 同一条路）。
            // 每个名字对应一个"默认屏看不见"的 UI 形态，供逐屏量网格。
            // **拼错或未知的场景名一律 exit(2)**：静默忽略会照样写出一张 PNG，
            // 而那张图其实是默认屏——量具说谎比没有量具更糟。
            func applySnapshotScene(_ spec: String, to m: FanModel, now: Date) {
                // cold 先跑：它清 history/stats/进程榜，若排在 tab2/tab3 之后会把
                // 刚填进去的夹具抹掉，而文件名仍写着那两个 tab。
                let tokens = spec.split(separator: ",").map(String.init)
                for s in (tokens.filter { $0 == "cold" } + tokens.filter { $0 != "cold" }) {
                    switch String(s) {
                    case "digits":       // 度数符号字距的最坏两位：1（右余白最大）与 0（圆右缘）
                        m.cpuTemp = 81; m.gpuTemp = 90
                        m.cpuAverageTemp = 74
                        m.history = [FanModel.TempSample(id: now, cpu: 81, gpu: 90),
                                     FanModel.TempSample(id: now.addingTimeInterval(-6), cpu: 80, gpu: 89)]
                    case "quiet":        // boostBar 第三态：静音倒计时卡
                        m.quietEndDate = now.addingTimeInterval(1800)
                        m.quietCapPercent = FanModel.defaultQuietCapPercent
                    case "tab1", "tab2", "tab3":   // 监控卡卡内正文（最热/今日/占用）
                        m.monitorTab = s == "tab1" ? 1 : (s == "tab2" ? 2 : 3)
                        if s == "tab3" {
                            // 占用页要有进程才画得满（面板打开时才真采样，快照里没有）；
                            // 混长名/短名/饱和占用，覆盖这一屏的排版最坏情况。
                            m.topProcesses = [
                                FanModel.ProcessUsage(id: "抖音（渲染进程）", app: "抖音", cpu: 94.6),
                                FanModel.ProcessUsage(id: "功耗度量工具", app: "功耗度量工具", cpu: 48.7),
                                FanModel.ProcessUsage(id: "ZCode（图形进程）", app: "ZCode", cpu: 37.0),
                                FanModel.ProcessUsage(id: "网易云音乐（渲染进程）", app: "网易云音乐", cpu: 25.1),
                                FanModel.ProcessUsage(id: "谷歌浏览器", app: "谷歌浏览器", cpu: 17.7),
                            ]
                            m.gpuTemp = 63
                        }
                    case "editcurve":    // 自定义档：可拖控制点 + 恢复预设 + 锚点条
                        // 显式清覆盖：真机此刻若挂着夜间/电池安静档，曲线会被换成安静档、
                        // 控制点根本不在屏上（4.2.55 逐屏量时踩到：夹具名不副实）。
                        m.preset = .custom
                        m.batteryOverride = false; m.nightOverride = false
                    case "nightcustom":  // 自定义档 + 夜间覆盖（画安静档曲线的那一屏）
                        m.preset = .custom
                        m.quietHours = true; m.nightOverride = true
                    case "spin":         // 后台空转告警行（AI 卡状态链链首，带按钮）
                        m.spinAlerts = [SpinAlert(pid: 4242, ppid: 1, name: "Foo Helper",
                                                  cpu: 94.6, peak: 99, heldSeconds: 620,
                                                  fdCount: 0, exe: "/usr/libexec/foo",
                                                  confidence: "高")]
                    case "nofan":        // 无风扇机型的诚实边界行（模式选择保留但明示）
                        m.hardwareProfile = HardwareProfile(
                            modelID: "Mac17,1", chipName: "Apple M5", osVersion: "26.1.0",
                            fanCount: 0,
                            sensorCounts: HardwareProfile.SensorCountSummary(
                                cpu: 1, gpu: 0, nand: 1, batt: 1, palm: 1, heatsink: 0, other: 0),
                            hasPowerKey: true, collectedAt: now)
                    case "battery":      // 电池安静档覆盖（曲线卡提示行 + 画 quiet 曲线）
                        m.onBattery = true; m.batterySaver = true; m.batteryOverride = true
                    case "night":        // 夜间安静档覆盖
                        m.quietHours = true; m.nightOverride = true
                    case "palm":         // 体感补偿胶囊（AI 卡 chips 行）
                        m.palmCompensation = true; m.palmComp = 3; m.palmRestTemp = 42
                    case "unreachable":  // AI 状态链：目标压不住
                        m.targetUnreachable = true
                    case "calibrate":    // AI 状态链：校准观察期
                        m.calibrating = true
                    case "higheffort":   // AI 状态链：全力散热
                        m.aiHighEffort = true
                    case "rec":          // AI 状态链：推荐目标（可点采纳）
                        m.aiRecommendedTarget = 79
                    case "fault":        // 警示条第二优先级：调速闭环故障
                        m.controlFault = true; m.faultReason = .smcWriteFailed
                    case "mismatch":     // 警示条第三优先级：配置未对账
                        m.configMismatch = true; m.daemonMode = .curve
                    case "envover":      // 环境温度被手动覆盖（头部图标换色 + 换 symbol）
                        m.envTempOverride = 35
                    case "cold":         // 空态/冷启动：一切读数与学习数据缺席
                        m.history = []; m.stats = nil; m.components = []; m.topProcesses = []
                        m.learnMap = []; m.learnedPoints = 0; m.learnedSamples = 0
                        m.aiMetrics = nil; m.learnedNow = nil; m.decisionTrace = nil
                        m.curveTargetPercent = nil; m.aiIntent = nil; m.rampAttribution = nil
                    case "singlefan":    // 单风扇机器的命名分支（"风扇 1" 而非"左风扇"）
                        guard !m.fans.isEmpty else {
                            FileHandle.standardError.write(Data("scene=singlefan 无风扇可读\n".utf8))
                            break
                        }
                        m.fans = [m.fans[0]]
                    case "metrics":      // AI 评测磁贴（与透镜行互斥，故先撤透镜）
                        m.decisionTrace = nil
                        var met = AIControlMetrics(targetTemp: 76)
                        met.activeSeconds = 468_000; met.sampleCount = 1200
                        met.temperatureSum = 79_200; met.temperatureSquaredSum = 5_260_000
                        met.peakTemp = 88.4; met.maxOvershoot = 4.2
                        met.highTempSeconds = 900
                        met.outputSum = 84_000; met.outputChangeCount = 318
                        met.outputChangeMagnitude = 12_600
                        m.aiMetrics = met
                    case "suggest":      // AI 曲线建议块（曲线卡最坏高度）
                        // 日键走 en_US_POSIX：这是机器可读键，非公历日历下会拼出乱码串
                        let dayFmt = DateFormatter()
                        dayFmt.dateFormat = "yyyy-MM-dd"
                        dayFmt.locale = Locale(identifier: "en_US_POSIX")
                        let days = (0..<3).map { i -> DailyStats in
                            var d = DailyStats(date: dayFmt.string(
                                from: now.addingTimeInterval(-Double(i) * 86_400)))
                            d.maxTemp = 90 - Double(i); d.maxTempAt = now
                            d.tempSum = (64 + Double(i)) * 1200; d.tempCount = 1200
                            d.highTempSeconds = 3600 - Double(i) * 600
                            // 直方图堆在热尾（桶宽 2°C、起点 40°C ⇒ 第 21 桶起 = 82°C+），
                            // 与 maxTemp 90 / highTempSeconds 同一口径。判据写成显式下界：
                            // 原来的 `b > 20 && b < 34` 上界恒真（bucketCount=28），是空气条件。
                            d.tempHistogram = (0..<TempHistogram.bucketCount).map { b in
                                Double(b >= 21 ? 900 : 40)
                            }
                            return d
                        }
                        m.pendingAICurve = CurveOptimizer.optimize(days: days)
                        if m.pendingAICurve == nil {
                            FileHandle.standardError.write(Data("scene=suggest 优化器返回 nil（夹具不足以出建议，这张图不是建议块）\n".utf8))
                        }
                    default:
                        FileHandle.standardError.write(Data("未知 scene 名：\(s)（可用：quiet/tab1/tab2/tab3/editcurve/nightcustom/spin/nofan/battery/night/palm/unreachable/calibrate/higheffort/rec/fault/mismatch/envover/cold/singlefan/metrics/suggest/digits）\n".utf8))
                        exit(2)
                    }
                }
            }
            let dark = CommandLine.arguments.contains("dark")
            if dark { suffix += "-dark" }
            if CommandLine.arguments.contains("warn") { suffix += "-warn" }
            if CommandLine.arguments.contains("boost") { suffix += "-boost" }
            if CommandLine.arguments.contains("dead") { suffix += "-dead" }
            if !scene.isEmpty { suffix += "-\(scene.replacingOccurrences(of: ",", with: "+"))" }
            let wallpaper = dark
                ? LinearGradient(
                    colors: [Color(red: 0.05, green: 0.06, blue: 0.12),
                             Color(red: 0.11, green: 0.08, blue: 0.19),
                             Color(red: 0.18, green: 0.10, blue: 0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                : LinearGradient(
                    colors: [Color(red: 0.16, green: 0.20, blue: 0.46),
                             Color(red: 0.42, green: 0.26, blue: 0.56),
                             Color(red: 0.88, green: 0.55, blue: 0.42)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            let panel = ContentView(model: model)
                .fixedSize()
                .padding(26)
                .background(wallpaper)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: panel)
            renderer.scale = 2
            if let img = renderer.nsImage,
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/fanctl-snapshot\(suffix).png"))
            }
            exit(0)
        }

        // R80：常驻启动路径才建模型并接通知动作。显式赋值 _model（不在 init 里读
        // @StateObject 的 wrappedValue——那里可能拿到另一个实例，杀进程会打到空模型上）。
        let m = FanModel()
        _model = StateObject(wrappedValue: m)
        if NotificationService.canNotifyBundled {
            let d = SpinActionDelegate(model: m)
            spinDelegate = d
            // 系统对 delegate 是弱引用：不存进 self 就当场释放，按钮点了没回调
            UNUserNotificationCenter.current().delegate = d
            NotificationService.registerCategories()   // 幂等，重复启动不会堆分类
        } else {
            spinDelegate = nil   // 非 bundle 环境（swift run）发不出通知，也不碰 UNUserNotificationCenter
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuBarLabel(state: model.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - R80 通知动作回调（立即结束 / 忽略）

/// 空转告警通知的按钮回调。通知侧**只有这条路径**会杀进程：action 带
/// `.authenticationRequired`，系统先要 Touch ID/密码才把 response 交下来，
/// 等价于面板侧 `confirmKillSpin` 的二次确认；除此以外任何地方都不自动杀。
final class SpinActionDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let model: FanModel

    init(model: FanModel) {
        self.model = model
    }

    /// 挂上 delegate 后，App 处于活跃态时系统不再自行展示通知。这里显式给回
    /// 挂接前的可见行为（横幅+声音），否则过热/风扇健康通知会静默回归。
    /// 参数类型照 SDK 头 `willPresentNotification:(UNNotification *)` 写；写成
    /// `UNNotificationRequest` 会"近似匹配"而根本不成为实现（编译器只给 warning）。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 分支用的三个字符串（分类 id / 动作 id / userInfo 键）全部取
    /// `NotificationService` 的常量，与注册处同源，不在这里重打一遍。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let content = response.notification.request.content
        guard content.categoryIdentifier == NotificationService.spinCategory else { return }
        switch response.actionIdentifier {
        case NotificationService.spinKillAction:
            // R81：新注册的分类里已经没有这个动作，但通知中心会保留旧版分类，
            // 所以仍可能收到。**一律交守卫复核**：核不过就不发信号，并把原因说给用户。
            guard let pid = content.userInfo[NotificationService.spinPidKey] as? Int else { return }
            let alert = SpinAlert(
                pid: pid, name: "pid \(pid)",
                exe: content.userInfo[NotificationService.spinExeKey] as? String,
                startSeconds: content.userInfo[NotificationService.spinStartKey] as? Double,
                uid: content.userInfo[NotificationService.spinUidKey] as? Int)
            Task { @MainActor in
                if case .failure(let denial) = model.killSpin(alert) {
                    NotificationService.explainKillDenied(pid: pid, denial: denial)
                }
            }
        case NotificationService.spinIgnoreAction:
            break   // 忽略=什么都不做，进程继续跑
        default:
            break   // 点通知本体/关闭（default、dismiss）一律不动进程
        }
    }
}

// MARK: - 菜单栏标签（实时温度 + 按温度变色）

struct MenuBarLabel: View {
    // 4.1.2（R21）：只订阅量化后的显示状态，不再观察整 FanModel——status 控制态
    // 每 ~2s 一拍全对象 objectWillChange，观察整模型 = 每拍重算标签并连累
    // MenuBarExtra 宿主布局/光栅（sample 实锤：MenuBarExtraLayout.sizeThatFits 高频）。
    // 整数温度桶/字形/警示色档不变 → 不发布 → 标签零开销。
    @ObservedObject var state: MenuBarState
    @AppStorage("menuBarStyle") private var storedStyle = "both"  // both | icon | temp
    // R23 打磨 F7：快照通道需强制 both，但直接写 @AppStorage 的键会经 KVO 让常驻 App
    // 的菜单栏标签在渲染窗口内闪现 both、且中途被杀会永久改掉用户设置。改为显式覆盖，
    // 不触碰共享 defaults 域。
    var styleOverride: String? = nil

    var body: some View {
        let style = styleOverride ?? storedStyle
        let d = state.display
        // 图标随状态变：冲刺→闪电、静音→月亮、常态→扇叶（一眼知道当前模式）
        let glyph = d.boostActive ? "bolt.fill"
                  : (d.quietActive ? "moon.fill" : "fanblades.fill")
        let warnColor: Color? = d.warnLevel >= 2 ? .red : (d.warnLevel == 1 ? .orange : nil)
        // 4.1.1（R20）：原生视图直出，禁用 ImageRenderer（旧实现每次缓存键翻转
        // ~0.3s 主线程离屏渲染 + 菜单栏图层 CA 交换）。.primary 自动适配菜单栏明暗。
        HStack(spacing: 2.5) {
            if style != "temp" {
                Image(systemName: glyph)
                    .font(.system(size: 11.5, weight: .medium))
            }
            if style != "icon" {
                Text(d.tempBucket >= 0 ? "\(d.tempBucket)°" : "--")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(warnColor ?? .primary)
    }
}

