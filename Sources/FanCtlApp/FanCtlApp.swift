import SwiftUI
import Charts
import ServiceManagement
import UserNotifications
import SMCCore

// FanCtl 菜单栏 App
// macOS 26 Liquid Glass 风格面板：玻璃卡片分组 + 实时曲线图，自适应深/浅色。
// 数据链：daemon 读 SMC 写 status.json，App 只读 status.json 展示（不直连 SMC）；
// 模式切换写 config.json 交给守护进程执行（单一数据源）。

// Liquid Glass 在 ImageRenderer 离屏渲染下无法正确合成（文字/材质会丢失），
// 快照模式下改用实心材质渲染卡片，仅用于验证布局；运行时仍为玻璃。
nonisolated(unsafe) var snapshotPlainCards = false

@main
struct FanCtlApp: App {
    @StateObject private var model = FanModel()

    init() {
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
            model.controlReason = .curve    // 预览决策可解释行
            model.daemonAlive = true        // 快照下无真实 daemon，手动置真以渲染决策行
            // 预览今日战报磁贴
            var demoStats = DailyStats(date: DailyStats.today())
            demoStats.maxTemp = 91; demoStats.maxTempAt = now
            demoStats.tempSum = 62 * 1200; demoStats.tempCount = 1200
            demoStats.highTempSeconds = 540; demoStats.revolutions = 128000
            model.stats = demoStats
            // 可选指定模式预览：--snapshot auto|curve|manual（仅渲染，不写配置）
            // v2.6.2：先处理子视图快照分支（custom 会被 FanMode(rawValue:) 劫持成 .custom 模式，
            // 导致整面 custom 快照永远不可达——见下方 switch）
            let lastArg = CommandLine.arguments.last
            // 排版实测用：--snapshot warn <mode> 强制最长警示条在场，量最坏情况总高
            if CommandLine.arguments.contains("warn") { model.configWriteFailed = true }
            // 排版实测用：--snapshot boost <mode> 预览冲刺倒计时态（boostBar 最高态）
            if CommandLine.arguments.contains("boost") { model.boostEndDate = now.addingTimeInterval(900) }
            // 排版实测用：--snapshot dead <mode> 预览 daemon 挂态（双标签同现最坏情况）
            if CommandLine.arguments.contains("dead") { model.daemonAlive = false }
            if lastArg == "hotspots" || lastArg == "today" || lastArg == "custom" {
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
                case "custom":
                    renderStandalone(EditableCurveChart(points: model.customPoints,
                                                        currentTemp: max(model.cpuTemp, model.gpuTemp),
                                                        appliedPercent: model.appliedPercent,
                                                        live: model.daemonAlive,
                                                        onChange: { _ in }),
                                     to: "/tmp/fanctl-snapshot-custom.png")
                default:
                    break
                }
            }
            let dark = CommandLine.arguments.contains("dark")
            if dark { suffix += "-dark" }
            if CommandLine.arguments.contains("warn") { suffix += "-warn" }
            if CommandLine.arguments.contains("boost") { suffix += "-boost" }
            if CommandLine.arguments.contains("dead") { suffix += "-dead" }
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
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - 菜单栏标签（实时温度 + 按温度变色）

struct MenuBarLabel: View {
    @ObservedObject var model: FanModel
    @AppStorage("menuBarStyle") private var style = "both"  // both | icon | temp

    var body: some View {
        let temp = max(model.cpuTemp, model.gpuTemp)
        // 图标随状态变：冲刺→闪电、静音→月亮、常态→扇叶（一眼知道当前模式）
        let glyph = model.boostEndDate != nil ? "bolt.fill"
                  : (model.quietEndDate != nil ? "moon.fill" : "fanblades.fill")
        Image(nsImage: Self.cachedRender(temp: temp, style: style, glyph: glyph))
    }

    // 图标只依赖整数温度、样式、状态符号：同帧直接复用，避免每 2 秒离屏重渲染
    private static var cache: (key: String, image: NSImage)?

    @MainActor
    static func cachedRender(temp: Double, style: String, glyph: String) -> NSImage {
        let key = "\(temp > 1 ? Int(temp) : -1)-\(style)-\(glyph)"
        if let c = cache, c.key == key { return c.image }
        let image = render(temp: temp, style: style, glyph: glyph)
        cache = (key, image)
        return image
    }

    // 低温用模板图（自动适配浅/深菜单栏）；高温渲染彩色非模板图警示
    @MainActor
    static func render(temp: Double, style: String = "both", glyph: String = "fanblades.fill") -> NSImage {
        let warnColor: Color? = temp >= 88 ? .red : (temp >= 78 ? .orange : nil)
        let label = HStack(spacing: 2.5) {
            if style != "temp" {
                Image(systemName: glyph)
                    .font(.system(size: 11.5, weight: .medium))
            }
            if style != "icon" {
                Text(temp > 1 ? "\(Int(temp))°" : "--")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(warnColor ?? .black)
        .frame(height: 16)

        let renderer = ImageRenderer(content: label)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = (warnColor == nil)
        return image
    }
}

