// PanelView —— 面板布局与玻璃卡片样式（R89 起：模式内容在 PanelModes、通用控件在
// PanelControls、AI 状态原子在 PanelEffects、卡片样式在 PanelCards，本文件是骨架与头部/卡片编排）。
import SwiftUI
import SMCCore
import FanCtlAppCore

// MARK: - 面板

struct ContentView: View {
    // v3.7 学习地图展开态：展开时 AI 卡显式长高（用户主动 ≠ 模式切换动画，
    // "窗口恒定"守的是切模式；无约束 Charts 会溢出 216pt 卡画到卡外）
    @State var learnMapExpanded = CommandLine.arguments.contains("lens")
    @ObservedObject var model: FanModel
    @AppStorage("menuBarStyle") private var menuBarStyle = "both"
    // v3.4.1：model.monitorTab 由 FanModel 持有（DoD-5a：ps 采样仅在"占用"tab 采样）

    var body: some View {
        // 4.1.2（R21）关闭态门禁：MenuBarExtra(.window) 关着时并不销毁视图树，status
        // 控制态每拍（~2s）objectWillChange → 整树 body 重评（玻璃融合 vImage 卷积 +
        // Charts 布局，sample 实锤的 CPU 风暴主体）——关着时没有任何观看者。关闭态
        // 只留同尺寸占位（340×908，窗口 idealSize 不变；固定高度防"跳"的口径同下），
        // 窗口出现 → onAppear 置 panelVisible → 真实树才建立。
        Group {
            if model.panelVisible || snapshotPlainCards {
                // 快照模式：无玻璃（ImageRenderer 离屏无法合成 Liquid Glass），实心卡直出。
                // 运行时：GlassEffectContainer 把各卡的独立玻璃融合成连续液态玻璃面
                // （用户定调的原生观感）。⚠️ z 序教训：glassEffect 只能作为内容链上的
                // 修饰符（玻璃在内容后），放进 .background{Color.clear.glassEffect()} 会被
                // 容器合成到内容之上盖住全部内容（9f0ffee 修过一次）。
                if snapshotPlainCards {
                    panelContent
                } else {
                    GlassEffectContainer(spacing: 8) {
                        panelContent
                    }
                }
            } else {
                Color.clear.frame(width: 340, height: 908)
            }
        }
        // 开关把手挂在外层容器：分支切换（占位↔真实树）不影响开关连线
        .onAppear {
            model.panelVisible = true
        }
        .onDisappear {
            model.panelVisible = false
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
        // 4.1.2（R21）：onAppear/onDisappear 移至 body 外层容器——关闭态分支换成
        // 占位视图后，旧连线随 panelContent 消失会永远丢失"重新打开"事件。
    }

    // 面板警示条按优先级只显示最高一条：面板固定高度 908 仅容一条两行警示（906pt），
    // 多条同现会从底部溢出裁剪——恰在最需要警示的状态下警示本身被切掉。
    // 优先级：写入失败（设置不生效，用户可行动）> 调速闭环故障 > 配置对账
    private var activeWarning: (text: String, icon: String, color: Color)? {
        if model.configWriteFailed {
            // 文案不引导仓库路径（sudo ./scripts/install.sh 只对有源码的人有意义，
            // 对 Release 用户是死路）；"重新安装"对两类受众都成立且两行高度内放得下
            return ("配置写入失败，调速设置不会生效。请以管理员身份重新安装清风",
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
                        // R52：头部功耗胶囊不再挂 numericText 转场/每拍补间。`w` 是每拍抖动的
                        // 原始 Double（±1W 常态），而这里在**面板根节点**——转场一开就是整面
                        // 重栅格（--tickbench 实测：只抖功耗 867ms/拍 vs 只抖转速 164ms/拍，
                        // 火焰图差在 render_contents/Glyphs/vImage 整树那一支）。
                        // 等宽直读保证宽度不跳，与 R47/R49 对转速、功耗占比的处置同族同法。
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
                // v3.6（方向一）：新版本提示——只在查到更新且未被跳过时出现。
                // v3.9 起一键升级：下载→校验→管理员授权安装→自动重启全程 App 内完成，
                // 用户只面对一次 macOS 授权弹窗；失败/不想自动装仍保留"打开下载页"退路。
                if let tag = model.updateAvailable {
                    UpgradeMenuSection(upgrader: model.upgrader, tag: tag,
                                       skip: { model.skipUpdateVersion() })
                    Divider()
                }
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
            Text("最高 \(String(format: "%.1f", s.maxTemp))°C · \(PanelFormat.timeHM.string(from: s.maxTempAt))")
            Text("平均温度 \(String(format: "%.1f", s.avgTemp))°C")
            Text("高温 ≥80°C 累计 \(PanelFormat.durationLong(s.highTempSeconds))")
            Text("风扇累计 \(PanelFormat.revolutionText(s.revolutions))")
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
                Text("静音/安静时长 \(PanelFormat.durationLong(s.quietSeconds))")
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

    // 时长/转数/倒计时/评测摘要等格式化已收口 FanCtlAppCore.PanelFormat
    // （R89：与 MonitorViews 的私有重复实现合一，输出有执行级断言钉住零漂移）

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

    // MARK: - 后台空转（R78，spinwatch 发现 → 清风提醒与操作）

    /// 空转行的悬停说明：把**证据**给全，让用户能自己判断"该不该杀"。
    /// 只放哨兵判得准的事实（句柄数、二进制在不在、父进程死活），不放推测。
    func spinAlertHelp(_ a: SpinAlert) -> String {
        var lines: [String] = [a.evidenceText, "pid \(a.pid)"]
        if let exe = a.exe { lines.append(exe) }
        if model.spinAlerts.count > 1 {
            lines.append("另有 \(model.spinAlerts.count - 1) 个进程也在空转（本行只显示占用最高的一个）")
        }
        lines.append("")
        lines.append("由 spinwatch（~/bin/spinwatch）发现，每 2 分钟巡检一次。")
        return lines.joined(separator: "\n")
    }

    /// 「结束」按钮的提示文案：可点时说明后果，不可点时把**拒绝原因**直接说给用户。
    func killSpinHelp(_ spin: SpinAlert) -> String {
        if let denial = model.killSpinDenial(spin) { return denial.userText }
        return "强制结束该进程（等同 kill -9）。清风会先复核它还是当初那个进程。"
    }

    /// 「结束」按钮的二次确认 + 拒绝反馈。**必须确认**：kill -9 会让对方立刻死，
    /// 未保存的工作直接丢，而"空转"只是哨兵的判断，误杀正当事的代价由用户承担。
    /// R81：确认之后还要过进程实例核验（SpinKillGuard），核验不过不发信号。
    func confirmKillSpin(_ spin: SpinAlert) {
        NSApp.activate(ignoringOtherApps: true)
        // R82：确认框给中文辨识名，原始名放正文——杀进程的事，用户该看清"是谁"
        let spinName = ProcessIdentity.displayName(executable: spin.exe ?? spin.name)
        let ask = NSAlert()
        ask.messageText = "强制结束 \(spinName)（pid \(spin.pid)）？"
        ask.informativeText = """
        进程：\(spin.exe ?? spin.name)
        它会立即被强制结束，等同在终端执行 kill -9，未保存的工作会丢失。

        如果你正在用它，请点"取消"。
        """
        ask.addButton(withTitle: "强制结束")
        ask.addButton(withTitle: "取消")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        if case .failure(let denial) = model.killSpin(spin) {
            let fail = NSAlert()
            fail.messageText = "结束动作已取消"
            fail.informativeText = denial.userText
            fail.addButton(withTitle: "好")
            fail.runModal()
        }
    }

    // 卸载说明：命令行一步到位，避免用户手动清理残留
    private static func showUninstallHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "卸载清风"
        alert.informativeText = """
        在终端执行以下命令即可完全卸载（需输入密码）：

        sudo /usr/local/libexec/fanctl-uninstall.sh

        卸载将注销登录项、停止并移除守护进程、恢复系统风扇调度，并删除：
        • /Library/LaunchDaemons/com.fanctl.daemon.plist
        • /Library/Application Support/FanCtl
        • /Applications/清风.app
        • /usr/local/libexec/fanctld 与两个特权脚本
        • /Library/Logs/FanCtl（守护进程日志）

        若上面这条路径不存在（4.2.0 之前装的），改用：
        sudo "/Applications/清风.app/Contents/Resources/uninstall.sh"
        """
        alert.addButton(withTitle: "复制命令")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            let cmd = "sudo \(SelfUpgrade.privilegedUninstallScript)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }

    private var temperatureCards: some View {
        HStack(spacing: 12) {   // 与面板纵向卡间距 12 对齐，横竖节奏统一
            TempGaugeCard(label: "CPU", symbol: "cpu", temp: model.cpuTemp,
                          history: model.history.suffix(120).map(\.cpu).filter { $0 > 1 },
                          subTemp: model.cpuAverageTemp)
            TempGaugeCard(label: "GPU", symbol: "cpu.fill", temp: model.gpuTemp,
                          history: model.history.suffix(120).map(\.gpu).filter { $0 > 1 })
        }
    }

    // 监测卡右上角的 tab 说明（单一来源，四个 tab 同一条 Text 同一种排版）
    private var monitorTabHint: String? {
        switch model.monitorTab {
        case 0:
            guard let first = model.history.first else { return nil }
            return "最近 \(max(1, Int(Date().timeIntervalSince(first.id) / 60))) 分钟"
        case 1: return "各部件温度 · 最热在顶"
        case 2: return "今日战报"
        case 3: return "CPU 占用最高 · GPU 温度"
        default: return nil
        }
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
                if let hint = monitorTabHint {
                    // 单行钉死：占用页文案最长（"CPU 占用最高 · GPU 温度"），此前折成两行，
                    // 把卡内正文整体下移 14pt——四个 tab 的说明必须占同一行高，
                    // 否则切 tab 时正文会跳。缩到 0.8 兜底，不换行。
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            ZStack(alignment: .top) {
                switch model.monitorTab {
                case 1: HotspotList(components: model.components).transition(.opacity)
                case 2: TodayStatsView(stats: model.stats).transition(.opacity)
                case 3: ProcessHogView(processes: model.topProcesses, gpuTemp: model.gpuTemp).transition(.opacity)
                default: TrendChart(samples: model.history, envTemp: model.envTemp).transition(.opacity)
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
                        Text("冲刺中 · 剩余 \(PanelFormat.countdown(to: end, now: context.date))")
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
                        Text("静音中 · 风扇≤\(Int(model.quietCapPercent))% · 剩余 \(PanelFormat.countdown(to: end, now: context.date))")
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

    // 磁贴/评测摘要格式化在 FanCtlAppCore.PanelFormat（compactDuration/evaluationText）

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
                .padding(.horizontal, panelChipHInset).padding(.vertical, 5)
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
            // R82 续十：加速归因行——"风扇为什么在转"的自动答案。15 分钟保鲜，
            // 过期自动隐藏（负载早变了，旧答案会误导）。判定与格式化有测试。
            if let attr = model.rampAttribution, let at = model.rampAttributionAt,
               Date().timeIntervalSince(at) < RampMonitor.freshWindow {
                let t = Calendar.current.dateComponents([.hour, .minute], from: at)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(String(format: "%02d:%02d 加速归因：%@", t.hour ?? 0, t.minute ?? 0, attr))
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 不是多余的 2pt：上行风扇图标是 24pt 框里的 fanblades，墨迹落在 31pt；
                // 本行 arrow.up.right 的墨迹在 28pt。按框对齐会两行箭头/叶片左端差 3pt，
                // 这 2pt 把它抹平（快照实测 28→30 vs 31）。
                .padding(.horizontal, 2)
                .transition(.opacity)
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
            // 4.0 B1 诚实表达：无风扇机器（硬件画像 fanCount=0）上曲线/AI/手动
            // 无物理对象——模式选择保留（用户意志），但明示边界而非静默空转。
            // fixedSize 防文案撑高打破"窗口恒定"守恒。
            if model.hardwareProfile?.fanCount == 0 {
                Text("此机型无风扇（passive cooling），调速由 macOS 管理")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            // v3.7：AI 卡新增透镜行+地图折叠区（~36pt），槽位 200→216pt；
            // 地图展开时再长高 ~110pt（图表+冻结按钮），动画平滑
            .frame(height: learnMapExpanded ? 326 : 216, alignment: .top)
            .animation(.smooth(duration: 0.3), value: learnMapExpanded)
            // dead 态统一降饱和：各模式内容（意图胶囊/曲线读数/滑块值）都是停更的
            // 最后状态，半透明诚实表达"数据停更"（快照审查 R20；opacity 不改高度）
            .opacity(model.daemonAlive ? 1 : 0.55)
        }
        .cardStyle()
    }
}
