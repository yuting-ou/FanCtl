// PanelView —— 面板布局与玻璃卡片样式。
import SwiftUI
import SMCCore

// MARK: - 面板

struct ContentView: View {
    @ObservedObject var model: FanModel
    @AppStorage("menuBarStyle") private var menuBarStyle = "both"
    // v3.4.1：model.monitorTab 由 FanModel 持有（DoD-5a：ps 采样仅在"占用"tab 采样）

    var body: some View {
        // 快照模式：无玻璃（ImageRenderer 离屏无法合成 Liquid Glass），实心卡直出。
        // 运行时（v3.4.2 排版重做）：整面一块液态玻璃 sheet 打底，卡片是玻璃面上的
        // 浅层瓦片（主色低透填充 + 发丝描边）。此前每张卡独立 glassEffect，系统投影
        // 带方向性（光左上影右下），恰好整条落在卡与窗口右缘间 14pt 玻璃条上（左侧
        // 同位置被卡片自身遮住）→ 恒定暗带，视觉"面板偏左"。单一玻璃面后投影被面块
        // 自身吸收，暗带消失；液态玻璃质感保留且更接近系统面板的单一连续表面。
        if snapshotPlainCards {
            panelContent
        } else {
            GlassEffectContainer(spacing: 8) {
                panelContent
                    .background {
                        Color.clear
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
                // daemon 挂时内容较少，固定高度下会留出大片底部空白；
                // 用上下 Spacer 让内容垂直居中，留白均匀分布更自然
                if !model.daemonAlive { Spacer(minLength: 0) }
                header
                temperatureCards
                monitorCard
                fanCard
                controlCard
                boostBar
                if !model.daemonAlive && model.mode != .auto {
                    Label("守护进程未运行，调速不会生效", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .tintedCard(.orange)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
                // 警示条按优先级只显示最高一条：面板固定高度 908 = 警示两行态 906 + 2px，
                // 多条同现会从底部溢出裁剪——恰在最需要警示的状态下警示被切掉。
                // daemon 挂时抑制警示条：「守护进程未运行」标签已覆盖"调速不会生效"语义，
                // 双标签同现 919pt 会裁掉警示——且 daemon 死亡时闭环/对账警示均已失真。
                if model.daemonAlive, let warn = activeWarning {
                    Label(warn.text, systemImage: warn.icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(warn.color)
                        .tintedCard(warn.color)
                        .transition(.opacity)
                }
        }
        .padding(14)
        .frame(width: 340, height: 908, alignment: .top)
        // 固定高度根治"面板跳"：MenuBarExtra 窗口尺寸 = 内容 idealSize，
        // 各模式/刷新瞬间 idealSize 有 1px 浮点差异就会触发窗口重排（表现为"跳"）。
        // 固定总高后窗口 idealSize 恒定，任何内部内容切换都不再改变窗口尺寸。
        // v3.4.1 快照实测收紧 940→908：正常态最满内容 842pt（四模式同高，200pt 槽位固定），
        // 警示条两行态 906pt 为真实最坏情况——908 覆盖它留 2px，警示永不被裁（旧 940 的
        // "938 最大高度"注释来自最热列表瘦身前的旧排版，已失效）。
        // 动画必须无回弹（.smooth）：spring 默认 bounce 0.15，结合下方 .move 过渡
        // 曾导致面板内容溢出边界引发窗口收起（与冲刺/静音按钮同类教训）。
        .animation(.smooth(duration: 0.3), value: model.daemonAlive)
        .animation(.smooth(duration: 0.3), value: model.controlFault)
        // 无入场动画：blur/scale 逐帧离屏渲染在深层级面板上是打开卡顿的根源，
        // 即时出现更跟手（用户已确认宁可不要入场动画）
        .onAppear {
            model.panelVisible = true
        }
        .onDisappear {
            model.panelVisible = false
        }
    }

    // 面板警示条按优先级只显示最高一条：面板固定高度 908 仅容一条两行警示（906pt），
    // 多条同现会从底部溢出裁剪——恰在最需要警示的状态下警示本身被切掉。
    // 优先级：写入失败（设置不生效，用户可行动）> 调速闭环故障 > 配置对账
    private var activeWarning: (text: String, icon: String, color: Color)? {
        if model.configWriteFailed {
            return ("配置写入失败，调速设置不会生效。请以管理员账户运行，或重跑 sudo ./scripts/install.sh",
                    "exclamationmark.triangle.fill", .orange)
        }
        if model.controlFault {
            return (model.faultReason?.displayName ?? "调速闭环异常，已交还系统调度",
                    "exclamationmark.triangle.fill", .red)
        }
        if model.configMismatch, let dm = model.daemonMode {
            let name = dm.rawValue == "curve" ? "曲线" : dm.rawValue == "manual" ? "手动" : dm.rawValue == "ai" ? "AI" : "自动"
            return ("配置未生效：守护进程仍在执行\(name)模式", "exclamationmark.triangle.fill", .orange)
        }
        return nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(LinearGradient(colors: [Color(red: 0.30, green: 0.62, blue: 1.0),
                                                          Color(red: 0.18, green: 0.44, blue: 0.95)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .shadow(color: .blue.opacity(0.4), radius: 3, y: 1)
            Text("清风")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .lineLimit(1).fixedSize()
            Spacer()
            // 元信息行（v3.4.2 去胶囊化）：小字直排省 chrome，图标带语义色、文字次级灰，
            // 悬停有完整说明；环境温度保留右键覆盖菜单。单行高度与旧胶囊行一致（26pt 约束）。
            if let w = model.systemPower {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill").font(.system(size: 9))
                        .foregroundStyle(.yellow)   // 色彩只给图标
                    Text("\(Int(w.rounded()))W").font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: w)
                }
                .help("整机实时功耗（发热根源）")
                .transition(.opacity)
            }
            if let env = model.envTemp {
                HStack(spacing: 3) {
                    Image(systemName: model.envTempOverride != nil ? "thermometer.medium.circle.fill" : "thermometer.medium").font(.system(size: 9))
                    Text("\(Int(env.rounded()))°").font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                .foregroundStyle(model.envTempOverride != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .help(model.envTempOverride != nil ? "手动覆盖: \(Int(model.envTempOverride!))°C。点击可修改" : "环境温度代理：电池/掌托/散热片的有效低值。点击可手动覆盖")
                .contextMenu {
                    Button("自动检测") { model.setEnvTempOverride(nil) }
                    Divider()
                    ForEach([20, 25, 30, 35, 40], id: \ .self) { t in
                        Button("设为 \(t)°C") { model.setEnvTempOverride(Double(t)) }
                    }
                }
                .transition(.opacity)
            }
            HStack(spacing: 4) {
                DaemonStatusDot(alive: model.daemonAlive)
                Text(model.daemonAlive ? "运行中" : "未运行")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.3), value: model.daemonAlive)
            }
            .help(model.daemonAlive ? "守护进程运行中，风扇由 FanCtl 接管" : "守护进程未运行，调速不会生效")
            if snapshotPlainCards {
                // 快照：Menu 桥接 NSMenu 离屏退 🚫 → 等尺寸静态省略号图标
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            } else {
            Menu {
                Text("清风 \(Self.appVersion)")
                Divider()
                statsSection
                Divider()
                Toggle("登录时启动", isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { model.setLoginItem($0) }
                ))
                Toggle("电池供电时自动安静", isOn: Binding(
                    get: { model.batterySaver },
                    set: { model.setBatterySaver($0) }
                ))
                Toggle("环境温度补偿", isOn: Binding(
                    get: { model.envCompensation },
                    set: { model.setEnvCompensation($0) }
                ))
                .help("夏天自动放宽/冬天收紧目标与曲线，让同一设置全年行为一致")
                Toggle("体感补偿（掌托 >40° 加强散热）", isOn: Binding(
                    get: { model.palmCompensation },
                    set: { model.setPalmCompensation($0) }
                ))
                .help("掌托超过 40°C 时自动收紧目标最多 4°C——直接服务体感而非代理指标；安静优先的用户可关闭")
                Toggle("夜间安静档（22:00–8:00）", isOn: Binding(
                    get: { model.quietHours },
                    set: { model.setQuietHours($0) }
                ))
                .help("夜间自动切安静档：曲线用安静预设，AI 目标放宽 +4°")
                Toggle("AI 定期自动优化曲线", isOn: Binding(
                    get: { model.autoOptimize },
                    set: { model.setAutoOptimize($0) }
                ))
                Picker("菜单栏显示", selection: $menuBarStyle) {
                    Text("图标 + 温度").tag("both")
                    Text("仅图标").tag("icon")
                    Text("仅温度").tag("temp")
                }
                Divider()
                Menu("关于清风") {
                    Text("清风 · v\(Self.appVersion)")
                    Text("Apple Silicon 风扇智能调速")
                    Divider()
                    Button("查看运行日志") { Self.revealInFinder(FanCtlPaths.logFile) }
                    Button("打开配置目录") { Self.revealInFinder(FanCtlPaths.configFile) }
                    Button("重置 AI 热经验…") { Self.requestLearnReset() }
                    Divider()
                    Button("卸载方法…") { Self.showUninstallHelp() }
                }
                Divider()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .menuIndicator(.hidden)
            .fixedSize()
            }
        }
    }

    // 版本号单一来源：从 bundle Info.plist 读（与 build.sh 写入的一致，不再硬编码漂移）；
    // 快照裸二进制无 bundle 时回退常量
    static let appVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.6"

    // 今日战报（守护进程累计，菜单里只读展示）
    @ViewBuilder
    private var statsSection: some View {
        if let s = model.stats, s.date == DailyStats.today(), s.tempCount > 0 {
            Text("今日战报")
            Text("最高 \(String(format: "%.1f", s.maxTemp))°C · \(Self.timeFmt.string(from: s.maxTempAt))")
            Text("平均温度 \(String(format: "%.1f", s.avgTemp))°C")
            Text("高温 ≥80°C 累计 \(Self.duration(s.highTempSeconds))")
            Text("风扇累计 \(Self.revolutionText(s.revolutions))")
            if s.speedChanges > 0 {
                Text("调速 \(Int(s.speedChanges)) 次（±3% 以上）")
            }
            if s.aiCyclingGuards > 0 {
                Text("启停抑制 \(Int(s.aiCyclingGuards)) 次（空闲停转试而不可得）")
            }
            if s.overshootPeak >= 3 {
                Text("过冲峰值 +\(Int(s.overshootPeak.rounded()))°（重载超出 AI 目标）")
            }
            if s.quietSeconds > 60 {
                Text("静音/安静时长 \(Self.duration(s.quietSeconds))")
            }
        } else {
            Text("今日战报 · 统计中…")
        }
        if let e = model.aiEffectText {
            Divider()
            Text("AI 曲线效果")
            Text(e)
        }
        if let h = model.thermalHealthText {
            Divider()
            Text("散热健康")
            Text(h)
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func duration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 { return "\(m / 60) 小时 \(m % 60) 分钟" }
        if m >= 1 { return "\(m) 分钟" }
        return "\(Int(seconds)) 秒"
    }

    private static func revolutionText(_ revs: Double) -> String {
        revs >= 10_000 ? String(format: "%.1f 万转", revs / 10_000) : "\(Int(revs)) 转"
    }

    // 在访达中定位日志/配置文件（供“关于”菜单直达诊断）
    private static func revealInFinder(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // 文件尚未生成时退回打开所在目录
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // 重置 AI 热经验：写标志文件，daemon 主循环检测到即清空重学（几秒内生效）
    private static func requestLearnReset() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "重置 AI 热经验"
        alert.informativeText = """
        将清空这台机器积累的风扇风量经验，AI 从零重新学习。
        适合使用环境发生重大变化（如长期换地方、清灰换硅脂）后经验明显不准时。
        重置后约几秒生效，不影响当前调速模式。
        """
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FileManager.default.createFile(atPath: FanCtlPaths.resetLearnFlag.path, contents: Data())
    }

    // 卸载说明：命令行一步到位，避免用户手动清理残留
    private static func showUninstallHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "卸载清风"
        alert.informativeText = """
        在终端执行以下命令即可完全卸载（需输入密码）：

        sudo /Applications/清风.app/Contents/Resources/uninstall.sh

        卸载将停止并移除守护进程、恢复系统风扇调度，并删除：
        • /Library/LaunchDaemons/com.fanctl.daemon.plist
        • /Library/Application Support/FanCtl
        • /Applications/清风.app（需手动拖入废纸篓）
        """
        alert.addButton(withTitle: "复制命令")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            let cmd = "sudo /Applications/清风.app/Contents/Resources/uninstall.sh"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }

    // 温度英雄区（v3.4.2）：CPU/GPU 合入同一张玻璃瓦片——单卡单投影，
    // 消除双卡拼缝与外缘投影暗带；中缝发丝分隔线代替硬分割
    private var temperatureCards: some View {
        HStack(spacing: 0) {
            TempGaugeCard(label: "CPU", symbol: "cpu", temp: model.cpuTemp,
                          history: model.history.suffix(120).map(\.cpu),
                          subTemp: model.cpuAverageTemp)
            Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1).padding(.vertical, 14)
            TempGaugeCard(label: "GPU", symbol: "cpu.fill", temp: model.gpuTemp,
                          history: model.history.suffix(120).map(\.gpu))
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12)))
    }

    // 监测卡：趋势 sparkline / 哪里最热明细，固定高度避免切换时面板尺寸突变
    private var monitorCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // 统一 PanelSegmentedPicker：可点（上轮误用静态快照占位导致点不动的回归已修）
                PanelSegmentedPicker(
                    items: [("趋势", 0), ("最热", 1), ("今日", 2), ("占用", 3)],
                    selection: Binding(get: { model.monitorTab }, set: { model.monitorTab = $0 }))
                Spacer()
                if model.monitorTab == 0, let first = model.history.first {
                    let mins = max(1, Int(Date().timeIntervalSince(first.id) / 60))
                    Text("最近 \(mins) 分钟")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if model.monitorTab == 1 {
                    Text("各部件温度 · 最热在顶")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if model.monitorTab == 2 {
                    Text("今日战报")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if model.monitorTab == 3 {
                    Text("CPU 占用最高 · GPU 温度")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ZStack(alignment: .top) {
                switch model.monitorTab {
                case 1: HotspotList(components: model.components).transition(.opacity)
                case 2: TodayStatsView(stats: model.stats).transition(.opacity)
                case 3: ProcessHogView(processes: model.topProcesses, gpuTemp: model.gpuTemp).transition(.opacity)
                default: TrendChart(samples: model.history).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: MonitorStyle.height, alignment: .top)
            .animation(.smooth(duration: 0.28), value: model.monitorTab)
        }
        .cardStyle()
    }

    private var boostBar: some View {
        // 固定高度容器：三种状态（冲刺中/静音中/平时按钮）高度不一致，
        // 切换时面板尺寸突变会导致 MenuBarExtra 窗口意外收起（与 controlCard 同类 bug）。
        // ZStack + 固定高度让新旧视图在同一空间内交叉过渡，窗口尺寸恒定。
        // 注意：transition 必须使用 .opacity 而非 .move(edge: .top)，
        // 因为 .move 结合 spring 动画会导致内容在过渡期间超出 ZStack 边界，
        // MenuBarExtra 窗口会误判尺寸变化从而收起面板。
        ZStack(alignment: .top) {
            if let end = model.boostEndDate {
                // 冲刺中：倒计时 + 取消（每秒刷新）
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.orange)
                        Text("冲刺中 · 剩余 \(Self.countdown(to: end, now: context.date))")
                            .font(.callout.monospacedDigit().weight(.medium))
                        Spacer()
                        Button("结束") { model.endBoost(restore: true) }
                            .controlSize(.small)
                    }
                }
                .tintedCard(.orange)
                .transition(.opacity)
            } else if let end = model.quietEndDate {
                // 静音承诺中：倒计时 + 提前结束
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        Image(systemName: "moon.fill")
                            .foregroundStyle(.indigo)
                        Text("静音中 · 风扇≤\(Int(model.quietCapPercent))% · 剩余 \(Self.countdown(to: end, now: context.date))")
                            .font(.callout.monospacedDigit().weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer()
                        Button("结束") { model.endQuiet() }
                            .controlSize(.small)
                    }
                }
                .tintedCard(.indigo)
                .transition(.opacity)
            } else {
                // 平时：冲刺（求快）与静音（求静）并列，一对偶
                HStack(spacing: 8) {
                    Button { model.startBoost() } label: {
                        Label("冲刺", systemImage: "bolt.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(LinearGradient(colors: [Color(red: 0.28, green: 0.60, blue: 1.0),
                                                                   Color(red: 0.32, green: 0.42, blue: 0.95)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                            )
                            .shadow(color: .blue.opacity(0.45), radius: 5, y: 1.5)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .controlSize(.large)
                    .help("全速 15 分钟后自动还原")

                    Button { model.startQuiet() } label: {
                        // 对比度修复：淡紫字(.indigo)压淡紫底在浅色模式仅 ~2.5:1，看似禁用；
                        // 文字改深靛蓝（≈7:1），描边加深使胶囊边缘清晰，与实心"冲刺"按钮形成
                        // 主次分明但仍可读的配对
                        Label("静音", systemImage: "moon.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color(red: 0.30, green: 0.26, blue: 0.62))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(.indigo.opacity(0.14))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(.indigo.opacity(0.5))
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .controlSize(.large)
                    .help("会议/录音时压低风扇 30 分钟；高温 92° 仍会兜底保护")
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: 48, alignment: .top)   // 实测：倒计时卡 46pt（快照 --snapshot boost），按钮态 28.5pt
        .animation(.smooth(duration: 0.3), value: model.boostEndDate)
        .animation(.smooth(duration: 0.3), value: model.quietEndDate)
    }

    private static func countdown(to end: Date, now: Date) -> String {
        let remain = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "%d:%02d", remain / 60, remain % 60)
    }

    // 磁贴用超紧凑时长：s/m/h 单字母后缀（"130h"、"1.6h"），完整表述在悬停 full 里
    private static func compactDuration(_ seconds: Double) -> String {
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        let minutes = seconds / 60
        if minutes < 90 { return String(format: "%.0fm", minutes) }
        let hours = minutes / 60
        return String(format: hours >= 10 ? "%.0fh" : "%.1fh", hours)
    }

    // 评测摘要：磁贴行取原始秒数自行格式化；full 为悬停完整版（含峰值/调速次数等磁贴放不下的指标）
    private static func evaluationText(_ m: AIControlMetrics) -> (seconds: Double, highSeconds: Double, full: String) {
        let full = """
        AI 评测（目标 \(Int(m.targetTemp))°，\(m.sampleCount) 个样本）
        时长 \(duration(m.activeSeconds)) · 均温 \(String(format: "%.1f", m.averageTemp))° · 峰值 \(String(format: "%.1f", m.peakTemp))°
        波动 \(String(format: "%.1f", m.temperatureStdDev))° · 最大过冲 +\(Int(m.maxOvershoot.rounded()))° · 平均输出 \(String(format: "%.0f", m.averageOutput))%
        调速 \(m.outputChangeCount) 次 · 超温（≥目标+5°）累计 \(duration(m.highTempSeconds))
        """
        return (m.activeSeconds, m.highTempSeconds, full)
    }

    private var fanCard: some View {
        VStack(spacing: 10) {
            // 决策可解释行：让用户看懂“风扇为何这么转”（守护进程提供的决策因素）。
            // v3.4.1 单一职责：胶囊只说"为什么"（原因标签），不再挂 appliedPercent 数字——
            // 该数字与详情卡的设定值（手动 manualPercent / 曲线当前输出 / AI 协同输出）
            // 同形不同源，曾出现"手动固定转速 24%" vs 详情"100%"的冲突。
            // "转多少"由下方 FanRow 的实际 RPM 与详情卡各自表达。
            if model.daemonAlive, let r = model.controlReason {
                HStack(spacing: 5) {
                    Image(systemName: Self.reasonIcon(r)).font(.system(size: 10, weight: .semibold))
                    Text(r.label).font(.caption2.weight(.medium))
                }
                .foregroundStyle(Self.reasonColor(r))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(Self.reasonColor(r).opacity(0.14)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(r)  // 强制视图身份变化，触发内容转场
                .transition(.opacity)
            }
            ForEach(model.fans, id: \.id) { fan in
                FanRow(fan: fan,
                       name: model.fans.count == 2 ? (fan.id == 0 ? "左风扇" : "右风扇") : "风扇 \(fan.id + 1)",
                       offset: model.offsetForFan(fanIndex: fan.id),
                       onOffsetChange: { model.setFanOffset(fanIndex: fan.id, offset: $0) })
            }
        }
        .cardStyle()
    }

    // 决策因素的图标与色彩：安全兜底红/橙，静音靠/电池绿，常规蓝
    private static func reasonIcon(_ r: ControlReason) -> String {
        switch r {
        case .auto: return "apple.logo"
        case .curve: return "chart.line.uptrend.xyaxis"
        case .ai: return "sparkles"
        case .aiIdle: return "moon.zzz.fill"
        case .manual: return "slider.horizontal.3"
        case .battery: return "battery.50"
        case .night: return "moon.stars.fill"
        case .batteryHot: return "flame.fill"
        case .quiet: return "moon.fill"
        case .ssd: return "internaldrive.fill"
        case .failsafe: return "exclamationmark.triangle.fill"
        }
    }
    private static func reasonColor(_ r: ControlReason) -> Color {
        switch r {
        case .failsafe: return .red
        case .ssd, .batteryHot: return .orange
        case .quiet: return .indigo
        case .battery: return .green
        case .night: return .teal
        case .ai: return .purple
        case .aiIdle: return .teal
        default: return .blue
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSegmentedPicker(items: [("自动", FanMode.auto), ("曲线", FanMode.curve),
                                         ("AI", FanMode.ai), ("手动", FanMode.manual)],
                                 selection: Binding(get: { model.mode }, set: { model.setMode($0) }))

            // 固定高度容器：各模式内容高度一致，窗口尺寸不变，
            // 避免 MenuBarExtra 面板因尺寸突变而意外收起（bug 修复）
            ZStack(alignment: .top) {
                switch model.mode {
                case .curve:
                    curveContent.transition(.opacity)
                case .ai:
                    aiContent.transition(.opacity)
                case .manual:
                    manualContent.transition(.opacity)
                case .auto:
                    autoContent.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            // 固定高度：各模式内容高度统一，窗口尺寸恒定。
            // 注意：切模式时内容必须即时替换（不加 implicit animation），
            // 否则 MenuBarExtra 窗口在动画期间会重排/抖动（"切模式面板跳"根因）。
            .frame(height: 200, alignment: .top)
        }
        .cardStyle()
    }

    private var curveContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSegmentedPicker(items: CurvePreset.allCases.map { ($0.displayName, $0) },
                                 selection: Binding(get: { model.preset }, set: { model.setPreset($0) }))

            // 自定义档：可拖动控制点；其余预设只读展示。
            // 电池档/夜间档覆盖生效时画对应档位曲线，否则橘色输出点会脱离曲线悬空。
            // AI 建议块在场时图表高度 92→52：基础内容 ≈155pt + 建议块 ≈80pt 超过
            // 200pt 槽位，底部的"确认应用/保留当前"按钮会被裁剪点不到（与历史
            // "面板点不动"bug 同类）；压缩图表给建议块让位，确认后自动恢复 92pt
            if model.preset == .custom && !model.batteryOverride && !model.nightOverride {
                EditableCurveChart(points: model.customPoints,
                                   currentTemp: max(model.cpuTemp, model.gpuTemp),
                                   appliedPercent: model.appliedPercent,
                                   live: model.daemonAlive,
                                   onChange: { model.updateCustomPoints($0) },
                                   height: model.pendingAICurve != nil ? 52 : 92)
                // #13: 恢复到均衡预设（自定义模式的初始基准）
                Button {
                    model.updateCustomPoints(CurvePreset.balanced.points)
                } label: {
                    Label("恢复预设", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            } else {
                CurveChart(config: model.batteryOverride
                               ? FanConfig(mode: .curve, curve: model.points(for: .quiet), preset: .quiet)
                               : (model.nightOverride
                                  ? FanConfig(mode: .curve, curve: model.points(for: .quiet), preset: .quiet)
                                  : model.config),
                           currentTemp: max(model.cpuTemp, model.gpuTemp),
                           appliedPercent: model.appliedPercent,
                           live: model.daemonAlive,
                           height: model.pendingAICurve != nil ? 52 : 92)
            }
            
            // 底部提示行：电池覆盖 > AI 结论 > 再优化提示 > 常规；右侧 AI 优化按钮
            HStack(spacing: 6) {
                Text(batteryHint ?? model.aiSummary
                     ?? (model.aiNudge ? "💡 数据已更新，建议重新 AI 优化" : nil)
                     ?? (model.preset == .custom
                                     ? "拖动蓝色控制点自定义曲线 · 当前输出 \(Int(model.appliedPercent))%"
                                     : model.aiPresetCurves.isEmpty
                                     ? "当前输出 \(Int(model.appliedPercent))% · 高温 92°C 自动全速兜底"
                                     : "预设已 AI 个性化 · 当前输出 \(Int(model.appliedPercent))% · 92° 兜底"))
                    .font(.caption2)
                    .foregroundStyle(model.batteryOverride ? AnyShapeStyle(.orange)
                                     : model.aiSummary != nil ? AnyShapeStyle(.purple)
                                     : model.aiNudge ? AnyShapeStyle(.purple)
                                     : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.aiDetail ?? "")
                Spacer(minLength: 4)
                if snapshotPlainCards {
                    // 快照：borderless Button 桥接 AppKit 离屏退 🚫 → 等尺寸静态标签
                    Label("AI 优化", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                } else {
                    Button {
                        model.applyAICurve()
                    } label: {
                        Label("AI 优化", systemImage: "sparkles")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(.purple)
                    .help("分析这台机器的历史温度分布，自动生成专属风扇曲线（纯本地分析，不联网）")
                }
            }
            // 控制点摘要：统一数据条（温度为主值、风量为副值），与 AI 评测条同语言。
            // 建议块在场时让位（200pt 槽位）。
            if model.pendingAICurve == nil {
                statStrip(displayedCurvePoints.map { p in
                    ("\(Int(p.temp))°", "\(Int(p.percent))% 风量", nil)
                })
            }
            if let suggestion = model.pendingAICurve {
                VStack(alignment: .leading, spacing: 6) {
                    Label("新的 AI 曲线建议", systemImage: "sparkles")
                        .font(.caption.weight(.semibold)).foregroundStyle(.purple)
                    Text(suggestion.summary)
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button("保留当前") { model.dismissAICurve() }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button("确认应用") { model.confirmAICurve() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.purple)
                    }
                }
                .padding(8)
                .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    
    // 曲线卡当前实际展示的锚点（与 CurveChart/EditableCurveChart 数据源一致）
    private var displayedCurvePoints: [CurvePoint] {
        if model.preset == .custom && !model.batteryOverride && !model.nightOverride {
            return model.customPoints
        }
        if model.batteryOverride || model.nightOverride {
            return model.points(for: .quiet)
        }
        return model.config.curve
    }

    // 电源感知覆盖时给用户一个明确提示，避免“曲线和实际输出对不上”的困惑
    private var batteryHint: String? {
        model.batteryOverride
            ? "电池供电 · 安静档生效中 · 当前输出 \(Int(model.appliedPercent))%"
            : nil
    }

    private var manualContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 内容在 200pt 固定框内垂直居中，避免顶部拥挤、底部大段留白导致的失衡感
            Spacer(minLength: 0)
            // 大号百分比显示，控制中心风格
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(model.manualPercent))")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.manualPercent)
                Text("%")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.fans.count == 2 {
                    VStack(alignment: .trailing, spacing: 1) {
                        ForEach(model.fans, id: \.id) { fan in
                            Text("\(fan.id == 0 ? "左" : "右") \(Int(fan.targetRPM)) RPM")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "fanblades")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if snapshotPlainCards {
                    // 快照：Slider 桥接 AppKit 离屏退 🚫 → 等尺寸静态轨道
                    GeometryReader { geo in
                        let pct = CGFloat(min(max(model.manualPercent, 0), 100) / 100)
                        let x = geo.size.width * pct
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                            Capsule()
                                .fill(LinearGradient(colors: [.blue, .indigo],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: x, height: 4)
                            Circle().fill(.white).frame(width: 14, height: 14)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                                .offset(x: min(max(x - 7, 0), geo.size.width - 14))
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 20)
                } else {
                    Slider(value: Binding(
                        get: { model.manualPercent },
                        set: { model.setManualPercent($0) }
                    ), in: 0...100, step: 5)
                    .tint(LinearGradient(colors: [.blue, .indigo],
                                         startPoint: .leading, endPoint: .trailing))
                }
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue.opacity(0.85))
            }
            Text("0% = 最低转速 · 100% = 全速 · 高温 92°C 自动全速兜底")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // 快捷档位：拖动之外给一键落点，同时填满 200pt 槽位底部留白。
            // 真 Button（AXPress 可达）；自绘样式，非 borderless（后者快照退 🚫）
            HStack(spacing: 6) {
                ForEach([0.0, 25.0, 50.0, 75.0, 100.0], id: \.self) { step in
                    let active = abs(model.manualPercent - step) < 0.5
                    Button { model.setManualPercent(step) } label: {
                        Text(step == 0 ? "静音" : "\(Int(step))%")
                            .font(.caption2.weight(active ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(active ? Color.white : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(active ? AnyShapeStyle(Color.blue.gradient)
                                             : AnyShapeStyle(Color.secondary.opacity(0.08))))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SegmentedItemButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var autoContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "apple.logo")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("风扇由 macOS 系统调度")
                .font(.callout)
            Text("FanCtl 不介入，与原生行为完全一致")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // 系统调度下的实时转速读数（读 status.json，App 侧不重算控制语义）：
            // 让"不介入"不再是空态——用户能看到系统此刻把风扇开到多少（统一数据条样式）
            if model.daemonAlive && !model.fans.isEmpty {
                statStrip(model.fans.map { fan in
                    (Self.rpmText(fan.actualRPM),
                     fan.id == 0 ? "左风扇 RPM" : "右风扇 RPM", nil)
                })
                .padding(.top, 2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // AI 自动接管：展示实时意图 + 可选目标温度（性能/均衡/静音）
    private var aiContent: some View {
        let cur = max(model.cpuTemp, model.gpuTemp)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.callout).foregroundStyle(.purple.gradient)
                Text("AI 自动接管").font(.callout.weight(.semibold))
                Spacer()
                Text(cur > 1 ? "\(Int(cur))°" : "--")
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(MonitorStyle.color(cur).gradient)
                    .contentTransition(.numericText()).animation(.snappy, value: cur)
            }
            // 实时意图（daemon 单一数据源，与实际控制同源）+ 电池/夜间目标放宽胶囊 + 当前输出。
            // 电池/夜间提示做成行内胶囊（与意图胶囊同行高）：它们是持续状态而非事件，
            // 独立成行会在与其他提示叠加时突破 200pt 槽位（曾最坏 ~249pt，学习状态条被裁）
            HStack(spacing: 6) {
                if let i = model.aiIntent {
                    let s = Self.intentStyle(i)
                    HStack(spacing: 4) {
                        Image(systemName: s.0).font(.caption.weight(.bold))
                        Text(i.label).font(.caption.weight(.medium))
                            .lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(s.1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(s.1.opacity(0.15)))
                    .id(i)
                    .transition(.opacity)
                    // layoutPriority：意图是本行主信息，空间不足时优先完整显示；
                    // 电池/体感/夜间胶囊与"经验"允许被截断（次要状态）
                    .layoutPriority(1)
                } else {
                    Text(model.controlReason == .aiIdle ? "风扇已交还系统" : "AI 状态同步中")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.secondary.opacity(0.12)))
                        .id("pending")
                        .transition(.opacity)
                        .layoutPriority(1)
                }
                if model.onBattery && model.batterySaver {
                    adaptiveChip(icon: "battery.50", text: "电池 +4°", color: .green,
                                 help: "电池供电 · 目标自动放宽 +4°（更安静省电），与曲线\"电池安静档\"同语义")
                }
                if let pc = model.palmComp, pc > 0.5 {
                    adaptiveChip(icon: "hand.raised.fill", text: "体感 -\(Int(pc.rounded()))°", color: .cyan,
                                 help: "掌托 \(Int(model.palmRestTemp ?? 40))°C 超过舒适阈值：目标自动收紧（体感补偿）")
                }
                if model.nightOverride {
                    adaptiveChip(icon: "moon.stars.fill", text: "夜间 +4°", color: .teal,
                                 help: "夜间安静档（22:00–8:00）· AI 目标放宽 +4°，更安静")
                }
                Spacer(minLength: 2)
                if let ln = model.learnedNow {
                    Text("经验 \(Int(ln))%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.purple)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .help("当前温度下，本机经验地图认为稳住温度所需的风量")
                        .contentTransition(.numericText())
                        .animation(.snappy, value: ln)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.aiIntent)
            .animation(.smooth(duration: 0.3), value: model.onBattery && model.batterySaver)
            // v7 曲线+AI 协同可视化：曲线基准（刻度线）vs AI 实际（填充条）
            // 直观展示"曲线=期望转速基准，AI=自适应修正"两层如何共同决定最终转速。
            // AI 空闲交还时隐藏：applied=0% 会显示"AI 放松 −N%"，但交还态没有 AI 决策，标签误导
            if let curve = model.curveTargetPercent, model.controlReason != .aiIdle {
                curveAIComboBar(curve: curve, ai: model.appliedPercent)
                    .transition(.opacity)
            }
            // 单条优先级状态行（200pt 槽位只允许一条事件级提示）：
            //   压不住（学习停滞，最紧急）> 目标推荐（可点按采纳）> 全力散热（黄色预警）
            // 此前 4 个条件块可叠加到 2-3 行，最坏 ~249pt 超出 200pt 槽位，
            // 底部学习状态条被裁剪（违反"底部控件可见"约束）
            if model.targetUnreachable {
                Label("目标 \(Int(model.aiTargetTemp))°C 压不住 · 风扇已满速 · 学习暂停", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.orange.opacity(0.14)))
                    .help("散热已到极限仍压不到目标温度，AI 不会记录饱和输出（学习暂停）。建议改用均衡 76° 或静音 80°。")
                    .transition(.opacity)
            } else if let rec = model.aiRecommendedTarget, abs(rec - model.aiTargetTemp) > 0.5 {
                // #4: AI 目标推荐（首次进入且无学习数据时基于基线温度推荐，点击采纳）
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb").font(.caption2)
                    Text("建议目标 \(Int(rec))°（基于当前温度，点击采纳）")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.purple)
                .contentShape(Rectangle())
                .onTapGesture { model.setAITarget(rec) }
                .transition(.opacity)
            } else if model.aiHighEffort {
                // #12: AI 全力散热预提示（区别于 targetUnreachable：黄色无感叹号）
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").font(.caption.weight(.bold))
                    Text("AI 正在全力散热").font(.caption.weight(.medium))
                }
                .foregroundStyle(.yellow)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.yellow.opacity(0.15)))
                .transition(.opacity)
            }
            // 目标温度选择：越高越安静、越低越凉
            PanelSegmentedPicker(items: [("性能 72°", 72.0), ("均衡 76°", 76.0), ("静音 80°", 80.0)],
                                 selection: Binding(get: { model.aiTargetTemp }, set: { model.setAITarget($0) }))
            // v7 曲线锚定后 AI 仍在自学习：展示学习状态（学习中/稳定/积累）+ 已掌握温度点覆盖
            learningStatus(points: model.learnedPoints,
                           samples: model.learnedSamples,
                           learning: model.learningRecently)
            // 评测摘要：仅在无事件级提示时显示（有提示时优先让位，保证 200pt 内不裁剪）。
            // v3.4.1：单行 run-on（"评测 130 小时 · 均温 55° · …"）拆为 5 个紧凑磁贴——
            // 一行连读 5 指标难扫视；磁贴各占一格、数值/标签分层，悬停仍看完整账本。
            // 磁贴仅 31pt，替换原 14pt 行 +17pt，评测在场时事件行必缺席，槽位余量足够。
            if let m = model.aiMetrics, m.sampleCount > 0, !model.targetUnreachable,
               !model.aiHighEffort,
               model.aiRecommendedTarget == nil || abs(model.aiRecommendedTarget! - model.aiTargetTemp) <= 0.5 {
                let eval = Self.evaluationText(m)
                statStrip([
                    (Self.compactDuration(eval.seconds), "评测", nil),
                    ("\(Int(m.averageTemp.rounded()))°", "均温", nil),
                    (String(format: "%.1f°", m.temperatureStdDev), "波动", nil),
                    ("\(Int(m.averageOutput.rounded()))%", "均输出", nil),
                    (Self.compactDuration(eval.highSeconds), "超温",
                     m.highTempSeconds > 60 ? Color.orange : nil),
                ])
                .help(eval.full)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // v7 曲线+AI 协同可视化（紧凑 2 行）：
    // 一条 0-100% 轨道，紫色填充 = AI 实际输出，灰色刻度线 = 用户曲线基准。
    // 刻度线位置 = "用户期望转速"，填充条到紫色 = "AI 最终输出"，
    // 两者间距 = "AI 自适应修正量"（散热压不住则加码、散热好则放松）。
    // 千位分隔转速文本（"2,858"），与 FanRow 同风格
    private static func rpmText(_ rpm: Double) -> String {
        let n = Int(rpm.rounded())
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // 统一数据条：单容器 + 发丝分隔线（苹果天气/股市同款语言），
    // 替代各处独立小盒子——盒群视觉碎，发丝分隔一体感强
    private func statStrip(_ items: [(value: String, label: String, accent: Color?)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, m in
                VStack(spacing: 1) {
                    Text(m.value)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(m.accent ?? Color(.secondaryLabelColor))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(m.label)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .overlay(alignment: .trailing) {
                    if i < items.count - 1 {
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1).frame(height: 22)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))
    }

    // 自适应状态胶囊：空间足够显示"图标+文字"，不足时降级为纯图标（悬停仍有完整说明）。
    // ViewThatFits 避免"图标+省略号"的尴尬截断（旧 lineLimit(1) 无降级路径）；
    // 两个变体都 fixedSize——压缩由 ViewThatFits 的选择完成，不由布局挤压完成
    private func adaptiveChip(icon: String, text: String, color: Color, help: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(text, systemImage: icon)
                .font(.caption2.weight(.medium)).foregroundStyle(color)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.12)))
            Image(systemName: icon)
                .font(.caption2.weight(.medium)).foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.12)))
        }
        .help(help)
        .transition(.opacity)
    }

    private func curveAIComboBar(curve: Double, ai: Double) -> some View {
        let curveC = min(max(curve, 0), 100)
        let aiC = min(max(ai, 0), 100)
        let diff = aiC - curveC
        let hasDiff = abs(diff) >= 2
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 10)).foregroundStyle(.purple.opacity(0.7))
                Text("曲线 × AI 协同")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if hasDiff {
                    Text((diff > 0 ? "AI 加码 +" : "AI 放松 ") + "\(Int(abs(diff)))%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(diff > 0 ? .orange : .green)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: diff)
                        .transition(.opacity)
                } else {
                    Text("AI 贴合曲线")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("→ \(Int(aiC))%")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.purple)
                    .monospacedDigit().contentTransition(.numericText())
                    .animation(.snappy, value: aiC)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(colors: [.purple, .indigo],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, w * aiC / 100))
                        .shadow(color: .purple.opacity(0.4), radius: 2.5, y: 0.5)
                    if curveC > 2 && curveC < 98 {
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, w * curveC / 100)
                    }
                }
            }
            .frame(height: 7)
            .animation(.snappy(duration: 0.4), value: aiC)
            .animation(.snappy(duration: 0.4), value: curveC)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.purple.opacity(0.05)))
    }

    // AI 意图的图标与色彩（与守护进程 AIIntent 一一对应）
    private static func intentStyle(_ i: AIIntent) -> (String, Color) {
        switch i {
        case .rising: return ("arrow.up.right", .orange)
        case .falling: return ("arrow.down.right", .green)
        case .holding: return ("equal", .blue)
        }
    }

    // AI 学习状态：曲线锚定后 AI 仍持续自学习（EMA 稳态采样），
    // 用"状态点 + 已掌握温度点覆盖条"直观表达"这台机器的热经验正在积累/已建立"。
    // 三种状态：
    //   learning  — 最近 120s 内有稳态采样（绿点脉冲）→ "AI 学习中"
    //   stable    — 已有经验但当前未采样（温度偏离目标/负载变化）→ "AI 已稳定 · 持续微调"
    //   coldStart — 尚无任何已采信经验 → "AI 正在学习散热规律"
    private func learningStatus(points: Int, samples: Int, learning: Bool) -> some View {
        let total = TempHistogram.bucketCount
        let coverage = total > 0 ? min(max(Double(points) / Double(total), 0), 1) : 0
        let state: AILearnState = learning ? .learning : (points > 0 ? .stable : .coldStart)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                LearningDot(state: state)
                Text(state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.color)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.3), value: state)
                Spacer(minLength: 4)
                Text(points > 0 ? "已掌握 \(points)/\(total) 点" : "已积累 \(samples) 样本")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: points)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            // 学习覆盖进度条：已采信温度点 / 全部温度桶（40~96°C）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(state.color.gradient)
                        .frame(width: max(3, geo.size.width * coverage))
                        .shadow(color: state.color.opacity(0.4), radius: 2, y: 0.5)
                }
            }
            .frame(height: 4)
            .animation(.smooth(duration: 0.4), value: coverage)
            .help("AI 持续学习这台机器稳住每个温度所需的风量，并结合你的曲线基准微调。已掌握表示该温度点有足够采样被采信。")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(state.color.opacity(0.06)))
    }
}

// AI 学习状态语义（学习/稳定/冷启动）
private enum AILearnState {
    case learning, stable, coldStart

    var color: Color {
        switch self {
        case .learning: return .green
        case .stable: return .green
        case .coldStart: return .secondary
        }
    }
    var title: String {
        switch self {
        case .learning: return "AI 学习中"
        case .stable: return "AI 已稳定 · 持续微调"
        case .coldStart: return "AI 正在学习散热规律"
        }
    }
}

// 学习状态点：学习中呼吸动效（扩散光晕环 + 辉光中心点）。
// v2.6.1 性能修复：SwiftUI .animation(repeatForever) 与 TimelineView 一样会驱动
// NSHostingView 每帧 SwiftUI 渲染循环（面板高 CPU 的组成部分），
// 改为 NSViewRepresentable + CAShapeLayer 动画（渲染服务器驱动，零 SwiftUI 成本）。
private struct LearningDot: View {
    let state: AILearnState

    var body: some View {
        if state == .learning {
            if snapshotPlainCards {
                // 快照（ImageRenderer 离屏）不支持 NSViewRepresentable，退静态
                ZStack {
                    Circle().stroke(state.color.opacity(0.3), lineWidth: 1.6)
                        .frame(width: 16, height: 16)
                    Circle().fill(state.color).frame(width: 6, height: 6)
                }
            } else {
                BreathingDotNSView(color: NSColor(state.color))
                    .frame(width: 16, height: 16)
            }
        } else {
            ZStack {
                Circle()
                    .fill(state.color.opacity(state == .stable ? 0.22 : 0.30))
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(state.color)
                    .frame(width: 6, height: 6)
                    .shadow(color: state.color.opacity(0.4), radius: 2)
            }
        }
    }
}

// 呼吸动效：扩散环（scale 1→1.7 + 淡出）+ 中心点（scale 0.85→1）循环，CA 层动画
private struct BreathingDotNSView: NSViewRepresentable {
    let color: NSColor
    func makeNSView(context: Context) -> BreathingDotView { BreathingDotView(color: color) }
    func updateNSView(_ nsView: BreathingDotView, context: Context) {
        nsView.setColor(color)
    }
}

final class BreathingDotView: NSView {
    private let ringLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private var animColor: NSColor = .systemGreen

    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(ringLayer)
        layer?.addSublayer(dotLayer)
        applyColor(color)   // 无条件首次配置（guard 会跳过与默认值相等的首次调用）
        start()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    func setColor(_ c: NSColor) {
        guard c != animColor else { return }
        applyColor(c)
    }
    private func applyColor(_ c: NSColor) {
        animColor = c
        ringLayer.strokeColor = c.withAlphaComponent(0.5).cgColor
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.lineWidth = 1.6
        dotLayer.fillColor = c.cgColor
        dotLayer.shadowColor = c.cgColor
        dotLayer.shadowOpacity = 0.7
        dotLayer.shadowRadius = 3
    }

    override func layout() {
        super.layout()
        // v2.6.2：必须同时设置 frame(=bounds)——CAShapeLayer 默认 bounds 为 0，
        // path 坐标相对 layer 原点绘制，bounds 为 0 时原点落在 position(视图中心)，
        // 整个图形平移到右下角被裁剪
        ringLayer.frame = bounds
        dotLayer.frame = bounds
        let r = bounds.midX
        ringLayer.path = CGPath(ellipseIn: CGRect(x: bounds.midX - r, y: bounds.midY - r,
                                                   width: r * 2, height: r * 2), transform: nil)
        dotLayer.path = CGPath(ellipseIn: CGRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6), transform: nil)
        // 层锚点居中，scale 围绕中心
        ringLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        dotLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        dotLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func start() {
        let ring = CABasicAnimation(keyPath: "transform.scale")
        ring.fromValue = 1.0
        ring.toValue = 1.7
        ring.duration = 1.2
        ring.autoreverses = true
        ring.repeatCount = .infinity
        let ringFade = CABasicAnimation(keyPath: "opacity")
        ringFade.fromValue = 0.5
        ringFade.toValue = 0.0
        ringFade.duration = 1.2
        ringFade.autoreverses = true
        ringFade.repeatCount = .infinity
        ringLayer.add(ring, forKey: "breathe-scale")
        ringLayer.add(ringFade, forKey: "breathe-fade")
        let dot = CABasicAnimation(keyPath: "transform.scale")
        dot.fromValue = 0.85
        dot.toValue = 1.0
        dot.duration = 1.2
        dot.autoreverses = true
        dot.repeatCount = .infinity
        dotLayer.add(dot, forKey: "breathe")
    }
}


// 面板统一分段选择器（纯 SwiftUI）：运行时可点、快照可渲染。
// 为什么不用系统 segmented Picker：它桥接 NSSegmentedControl，ImageRenderer 离屏
// 渲染为黄色 🚫；且系统样式与面板玻璃语言不统一。
// 视觉对齐 macOS 系统设置分段控件：中性轨道 + 白色滑块 + 选中项加粗。
// 点击安全性：selection 直接赋值（不包 withAnimation），本视图末尾的 .animation
// 只作用于滑块位移——模式内容交换在该视图子树之外，保持"切模式即时替换"约束，
// 不会触发 MenuBarExtra 窗口重排（历史跳面板根因）。
struct PanelSegmentedPicker<Item: Hashable>: View {
    let items: [(label: String, tag: Item)]
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.1) { item in
                Button {
                    guard selection != item.tag else { return }
                    selection = item.tag
                } label: {
                    PanelSegmentedItem(label: item.label, isActive: selection == item.tag)
                }
                .buttonStyle(SegmentedItemButtonStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .animation(.snappy(duration: 0.22), value: selection)
    }
}

// 分段选择器单项：白色胶囊滑块样式（选中态），与 macOS 系统设置同款语言。
// 必须是真 Button：onTapGesture 不暴露 AXPress（辅助功能无法触发）；
// Button 鼠标/AXPress/键盘全通。纯 SwiftUI，ImageRenderer 快照可渲染。
private struct PanelSegmentedItem: View {
    let label: String
    let isActive: Bool

    var body: some View {
        let fill = isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear
        let shadow = isActive ? Color.black.opacity(0.16) : Color.clear
        return Text(label)
            .font(.caption.weight(isActive ? .semibold : .medium))
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(Capsule().fill(fill).shadow(color: shadow, radius: 2.5, y: 1))
            .contentShape(Capsule())
    }
}

// 无缩放按压反馈：按下轻微降透明度；视觉全由滑块承担
private struct SegmentedItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// 带按压反馈的按钮样式：按下时轻微缩放 + 半透明，松开回弹，让交互更跟手
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// 守护进程状态点：运行中绿点呼吸（v2.6.1 起 CA 层动画，零 SwiftUI 渲染循环）
private struct DaemonStatusDot: View {
    let alive: Bool

    var body: some View {
        if alive {
            if snapshotPlainCards {
                ZStack {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Circle().stroke(.green.opacity(0.3), lineWidth: 1.2).frame(width: 7, height: 7)
                }
            } else {
                PulseDotNSView(color: .systemGreen)
                    .frame(width: 14, height: 14)
            }
        } else {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .shadow(color: .red.opacity(0.5), radius: 3)
        }
    }
}

// 运行状态点：扩散环（scale 1→2 + 淡出）循环，CA 层动画
private struct PulseDotNSView: NSViewRepresentable {
    let color: NSColor
    func makeNSView(context: Context) -> PulseDotView { PulseDotView(color: color) }
    func updateNSView(_ nsView: PulseDotView, context: Context) {
        nsView.setColor(color)
    }
}

final class PulseDotView: NSView {
    private let dotLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private var animColor: NSColor = .systemGreen

    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(ringLayer)
        layer?.addSublayer(dotLayer)
        applyColor(color)   // 无条件首次配置（guard 会跳过与默认值相等的首次调用）
        start()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    func setColor(_ c: NSColor) {
        guard c != animColor else { return }
        applyColor(c)
    }
    private func applyColor(_ c: NSColor) {
        animColor = c
        dotLayer.fillColor = c.cgColor
        dotLayer.shadowColor = c.cgColor
        dotLayer.shadowOpacity = 0.7
        dotLayer.shadowRadius = 3
        ringLayer.strokeColor = c.withAlphaComponent(0.5).cgColor
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.lineWidth = 1.2
    }

    override func layout() {
        super.layout()
        // v2.6.2：同 BreathingDotView，必须设 frame 否则图形偏移被裁剪
        dotLayer.frame = bounds
        ringLayer.frame = bounds
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        dotLayer.path = CGPath(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7), transform: nil)
        dotLayer.position = c
        dotLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.path = CGPath(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7), transform: nil)
        ringLayer.position = c
        ringLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    private func start() {
        let ring = CABasicAnimation(keyPath: "transform.scale")
        ring.fromValue = 1.0
        ring.toValue = 2.0
        ring.duration = 1.6
        ring.autoreverses = true
        ring.repeatCount = .infinity
        ringLayer.add(ring, forKey: "pulse-scale")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0.0
        fade.duration = 1.6
        fade.autoreverses = true
        fade.repeatCount = .infinity
        ringLayer.add(fade, forKey: "pulse-fade")
    }
}

// MARK: - 卡片背景

// v3.4.2：玻璃面上的浅层瓦片——主色低透填充 + 白发丝描边。
// 不再对每张卡独立 glassEffect：系统玻璃投影带方向性，会在卡与窗口右缘间的
// 窄玻璃条上形成恒定暗带（"面板偏左"的根源）；瓦片填充由面块玻璃托底，
// 深浅色自适应（primary = 浅色黑 5% / 深色白 5%），且 ImageRenderer 可渲染
// ——快照与运行时同构，🚫 风险面进一步收窄。
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.primary.opacity(0.05)))
            .overlay(shape.strokeBorder(.white.opacity(0.12)))
    }
}


extension View {
    /// v3.4.1：快照模式下 glassEffect Capsule 退实心材质圆胶囊
    ///（ImageRenderer 离屏无法合成 Liquid Glass，渲染为系统黄色 🚫 占位）。
    @ViewBuilder
    func snapshotCapsule() -> some View {
        if snapshotPlainCards {
            self.background(.regularMaterial, in: Capsule())
        } else {
            self.glassEffect(.regular, in: Capsule())
        }
    }
}

extension View {  // 跨文件使用（TempGaugeCard 等），不能 private
    func cardStyle() -> some View { modifier(CardBackground()) }
    func tintedCard(_ tint: Color) -> some View { modifier(TintedCard(tint: tint)) }
}

// 带色彩渲染的玻璃卡（用于冲刺中 / 告警等需要强调的状态）
private struct TintedCard: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        // 与 CardBackground 同代的着色瓦片（冲刺倒计时/警示条/daemon 挂提示）：
        // 着色填充 + 同色描边，快照与运行时同构
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tint.opacity(0.15)))
            .overlay(shape.strokeBorder(tint.opacity(0.32)))
    }
}

// 迷你趋势折线（自绘 Path，可在 ImageRenderer 离屏渲染）
