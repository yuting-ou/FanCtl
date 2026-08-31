// PanelView —— 面板布局与玻璃卡片样式。
import SwiftUI
import SMCCore

// MARK: - 面板

struct ContentView: View {
    @ObservedObject var model: FanModel
    @AppStorage("menuBarStyle") private var menuBarStyle = "both"
    @State private var monitorTab = 0  // 0 = 趋势，1 = 热点

    var body: some View {
        GlassEffectContainer(spacing: 8) {
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
                // 警示条按优先级只显示最高一条：面板固定高度（正常态 938/940 仅 2px 余量），
                // 三条同现 ≈160px 会从底部溢出裁剪——恰在最需要警示的状态下警示被切掉
                if let warn = activeWarning {
                    Label(warn.text, systemImage: warn.icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(warn.color)
                        .tintedCard(warn.color)
                        .transition(.opacity)
                }
            }
        }
        .padding(14)
        .frame(width: 340, height: 940, alignment: .top)
        // 固定高度根治"面板跳"：MenuBarExtra 窗口尺寸 = 内容 idealSize，
        // 各模式/刷新瞬间 idealSize 有 1px 浮点差异就会触发窗口重排（表现为"跳"）。
        // 固定总高后窗口 idealSize 恒定，任何内部内容切换都不再改变窗口尺寸。
        // 940 覆盖正常模式最大高度（938）留 2px 余量；daemon 挂时底部留白属异常态，可接受。
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

    // 面板警示条按优先级只显示最高一条：面板固定高度（正常态 938/940 仅 2px 余量），
    // 三条同现 ≈160px 会从底部溢出裁剪——恰在最需要警示的状态下警示本身被切掉。
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
            Spacer()
            // 整机功耗胶囊（发热的“因”，有传感器才显）
            if let w = model.systemPower {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill").font(.system(size: 9))
                    Text("\(Int(w.rounded())) W").font(.caption.monospacedDigit().weight(.medium))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: w)
                }
                .foregroundStyle(.yellow)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())
                .help("整机实时功耗（发热根源）")
                .transition(.opacity)
            }
            // 环境温度胶囊（环境补偿的输入，v8）
            if let env = model.envTemp {
                HStack(spacing: 3) {
                    Image(systemName: model.envTempOverride != nil ? "thermometer.medium.circle.fill" : "thermometer.medium").font(.system(size: 9))
                    Text("环境 \(Int(env.rounded()))°").font(.caption.monospacedDigit().weight(.medium))
                }
                .foregroundStyle(model.envTempOverride != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .glassEffect(.regular, in: Capsule())
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
            HStack(spacing: 5) {
                DaemonStatusDot(alive: model.daemonAlive)
                Text(model.daemonAlive ? "运行中" : "未运行")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.3), value: model.daemonAlive)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
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

    private var temperatureCards: some View {
        HStack(spacing: 10) {
            TempGaugeCard(label: "CPU", symbol: "cpu", temp: model.cpuTemp,
                          history: model.history.suffix(120).map(\.cpu),
                          subTemp: model.cpuAverageTemp)
            TempGaugeCard(label: "GPU", symbol: "cpu.fill", temp: model.gpuTemp,
                          history: model.history.suffix(120).map(\.gpu))
        }
    }

    // 监测卡：趋势 sparkline / 哪里最热明细，固定高度避免切换时面板尺寸突变
    private var monitorCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $monitorTab) {
                    Text("趋势").tag(0)
                    Text("最热").tag(1)
                    Text("今日").tag(2)
                    Text("占用").tag(3)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if monitorTab == 0, let first = model.history.first {
                    let mins = max(1, Int(Date().timeIntervalSince(first.id) / 60))
                    Text("最近 \(mins) 分钟")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if monitorTab == 1 {
                    Text("各部件温度 · 最热在顶")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if monitorTab == 2 {
                    Text("今日战报")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if monitorTab == 3 {
                    Text("CPU 占用最高 · GPU 温度")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ZStack(alignment: .top) {
                switch monitorTab {
                case 1: HotspotList(components: model.components).transition(.opacity)
                case 2: TodayStatsView(stats: model.stats).transition(.opacity)
                case 3: ProcessHogView(processes: model.topProcesses, gpuTemp: model.gpuTemp).transition(.opacity)
                default: TrendChart(samples: model.history).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: MonitorStyle.height, alignment: .top)
            .animation(.smooth(duration: 0.28), value: monitorTab)
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
                        Label("静音", systemImage: "moon.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(.indigo.opacity(0.16))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(.indigo.opacity(0.35))
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
        .frame(height: 54, alignment: .top)
        .animation(.smooth(duration: 0.3), value: model.boostEndDate)
        .animation(.smooth(duration: 0.3), value: model.quietEndDate)
    }

    private static func countdown(to end: Date, now: Date) -> String {
        let remain = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "%d:%02d", remain / 60, remain % 60)
    }

    // 评测摘要文案：时长 <90 分钟显示分钟、否则换算小时（账本可达数千分钟/数十小时）。
    // display 为单行紧凑版；full 为悬停完整版（含峰值/调速次数等一行放不下的指标）
    private static func evaluationText(_ m: AIControlMetrics) -> (display: String, full: String) {
        func compact(_ seconds: Double) -> String {
            if seconds < 90 { return String(format: "%.0f 秒", seconds) }
            let minutes = seconds / 60
            if minutes < 90 { return String(format: "%.0f 分", minutes) }
            return String(format: "%.1f 小时", minutes / 60)
        }
        let display = "评测 \(compact(m.activeSeconds)) · 均温 \(Int(m.averageTemp.rounded()))°" +
            " · 波动 \(String(format: "%.1f", m.temperatureStdDev))°" +
            " · 输出 \(Int(m.averageOutput.rounded()))%" +
            " · 超温 \(compact(m.highTempSeconds))"
        let full = """
        AI 评测（目标 \(Int(m.targetTemp))°，\(m.sampleCount) 个样本）
        时长 \(duration(m.activeSeconds)) · 均温 \(String(format: "%.1f", m.averageTemp))° · 峰值 \(String(format: "%.1f", m.peakTemp))°
        波动 \(String(format: "%.1f", m.temperatureStdDev))° · 最大过冲 +\(Int(m.maxOvershoot.rounded()))° · 平均输出 \(String(format: "%.0f", m.averageOutput))%
        调速 \(m.outputChangeCount) 次 · 超温（≥目标+5°）累计 \(duration(m.highTempSeconds))
        """
        return (display, full)
    }

    private var fanCard: some View {
        VStack(spacing: 10) {
            // 决策可解释行：让用户看懂“风扇为何这么转”（守护进程提供的决策因素）
            if model.daemonAlive, let r = model.controlReason {
                HStack(spacing: 5) {
                    Image(systemName: Self.reasonIcon(r)).font(.system(size: 10, weight: .semibold))
                    Text(r.label).font(.caption2.weight(.medium))
                    Spacer()
                    // auto 模式下我们不控风扇（输出为 0），显示百分比会与风扇实际转速矛盾，故仅非 auto 时显示
                    if r != .auto {
                        Text("\(Int(model.appliedPercent))%")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: model.appliedPercent)
                    }
                }
                .foregroundStyle(Self.reasonColor(r))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(Self.reasonColor(r).opacity(0.14)))
                .id(r)  // 强制视图身份变化，触发内容转场
                .transition(.opacity)
            }
            ForEach(model.fans, id: \.id) { fan in
                FanRow(fan: fan,
                       name: model.fans.count == 2 ? (fan.id == 0 ? "左风扇" : "右风扇") : "风扇 \(fan.id + 1)",
                       now: model.lastRefresh,
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
            Picker("模式", selection: Binding(
                get: { model.mode },
                set: { model.setMode($0) }
            )) {
                Text("自动").tag(FanMode.auto)
                Text("曲线").tag(FanMode.curve)
                Text("AI").tag(FanMode.ai)
                Text("手动").tag(FanMode.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
            Picker("预设", selection: Binding(
                get: { model.preset },
                set: { model.setPreset($0) }
            )) {
                ForEach(CurvePreset.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

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
                Slider(value: Binding(
                    get: { model.manualPercent },
                    set: { model.setManualPercent($0) }
                ), in: 0...100, step: 5)
                .tint(LinearGradient(colors: [.blue, .indigo],
                                     startPoint: .leading, endPoint: .trailing))
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue.opacity(0.85))
            }
            Text("0% = 最低转速 · 100% = 全速 · 高温 92°C 自动全速兜底")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                    }
                    .foregroundStyle(s.1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(s.1.opacity(0.15)))
                    .id(i)
                    .transition(.opacity)
                    // lineLimit(1)：电池+夜间+意图+经验四胶囊同现时 340pt 内放不下，
                    // 无限制会换行撑高 ~14pt → aiContent 超 200pt 槽位裁剪底部学习条
                    .lineLimit(1)
                } else {
                    Text(model.controlReason == .aiIdle ? "风扇已交还系统" : "AI 状态同步中")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.secondary.opacity(0.12)))
                        .id("pending")
                        .transition(.opacity)
                        .lineLimit(1)
                }
                if model.onBattery && model.batterySaver {
                    Label("电池 +4°", systemImage: "battery.50")
                        .font(.caption2.weight(.medium)).foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(.green.opacity(0.12)))
                        .help("电池供电 · 目标自动放宽 +4°（更安静省电），与曲线\"电池安静档\"同语义")
                        .transition(.opacity)
                        .lineLimit(1)
                }
                if model.nightOverride {
                    Label("夜间 +4°", systemImage: "moon.stars.fill")
                        .font(.caption2.weight(.medium)).foregroundStyle(.teal)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(.teal.opacity(0.12)))
                        .help("夜间安静档（22:00–8:00）· AI 目标放宽 +4°，更安静")
                        .transition(.opacity)
                        .lineLimit(1)
                }
                Spacer()
                if let ln = model.learnedNow {
                    Text("经验 \(Int(ln))%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.purple)
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
            Picker("", selection: Binding(get: { model.aiTargetTemp }, set: { model.setAITarget($0) })) {
                Text("性能 72°").tag(72.0)
                Text("均衡 76°").tag(76.0)
                Text("静音 80°").tag(80.0)
            }
            .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            // v7 曲线锚定后 AI 仍在自学习：展示学习状态（学习中/稳定/积累）+ 已掌握温度点覆盖
            learningStatus(points: model.learnedPoints,
                           samples: model.learnedSamples,
                           learning: model.learningRecently)
            // 评测摘要：仅在无事件级提示时显示（有提示时优先让位，保证 200pt 内不裁剪）。
            // v2.9.1：单行 300pt 装不下长账本（"评测 3727 分钟 · … · 超温 5080s"直接截断，
            // 尾部指标不可见）——时长智能换算小时/分钟 + 压缩文案 + 悬停查看完整数据。
            // 不能改成两行：aiContent 在 200pt 固定槽位内已占满（约 199pt），加行必裁底部。
            if let m = model.aiMetrics, m.sampleCount > 0, !model.targetUnreachable,
               !model.aiHighEffort,
               model.aiRecommendedTarget == nil || abs(model.aiRecommendedTarget! - model.aiTargetTemp) <= 0.5 {
                let eval = Self.evaluationText(m)
                Text(eval.display)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .minimumScaleFactor(0.8)
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

private struct CardBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        let base = content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        if snapshotPlainCards {
            base.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12)))
        } else {
            base.glassEffect(.regular, in: shape)
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
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        let base = content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        if snapshotPlainCards {
            base.background(tint.opacity(0.18), in: shape)
                .overlay(shape.strokeBorder(tint.opacity(0.35)))
        } else {
            base.glassEffect(.regular.tint(tint.opacity(0.22)), in: shape)
        }
    }
}

// 迷你趋势折线（自绘 Path，可在 ImageRenderer 离屏渲染）
