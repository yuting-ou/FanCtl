// MonitorViews —— 监控面板共享视觉语言与三个监控视图。
import SwiftUI
import SMCCore

// MARK: - 监控面板共享视觉语言
// 趋势/最热 两个 tab 数据形态不同（时间序/部件排行），但必须说面板同一套设计语言：
// 圆体渐变数字 + 胶囊辉光能量条 + 统一温度配色（与温度卡/风扇行一致）。
enum MonitorStyle {
    static let height: CGFloat = 92

    // 面板签名式数字：圆体 + 半粗 + 等宽（与温度卡大数字同源）
    static func numeral(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    // 统一温度→色彩语义：同一温度在趋势/最热显示同色（凉绿/温橙/烫红）
    static func color(_ t: Double) -> Color {
        switch t {
        case ..<68: return .green
        case ..<83: return .orange
        default: return .red
        }
    }
}

// 统一空态占位（三个监控视图共用，高度/字体/色彩一致）
struct MonitorEmpty: View {
    let text: String
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "hourglass")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: MonitorStyle.height)
    }
}

// 统一水平能量条：胶囊 + 渐变 + 柔和辉光（与风扇行能量条同款）
struct GlowBar: View {
    let fraction: CGFloat
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.16))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                    .shadow(color: color.opacity(0.4), radius: 2.5, y: 0.5)
                    .animation(.smooth(duration: 0.35), value: fraction)
            }
        }
    }
}

// 最近 10 分钟温度趋势：用面板签名式的手绘发光 SparkLine（与温度卡同一渲染原语），
// 右侧附最高/最低刻度，摆脱 Swift Charts “外来图表”观感
struct TrendChart: View {
    let samples: [FanModel.TempSample]

    var body: some View {
        if samples.count < 5 {
            MonitorEmpty(text: "正在收集数据…")
        } else {
            let temps = samples.map(\.temp)
            let hi = temps.max() ?? 0
            let lo = temps.min() ?? 0
            // 趋势色跟随当前（最新）温度，与最热共用同一色彩语义
            let accent = MonitorStyle.color(samples.last?.temp ?? 60)
            // 按时间戳映射 x（事件驱动采样下拍间隔 1~20s 不均，均匀映射会失真斜率）
            let times = samples.map { $0.id.timeIntervalSince1970 }
            let t0 = times.first ?? 0
            let span = max((times.last ?? 0) - t0, 1)
            let fractions = times.map { ($0 - t0) / span }
            HStack(spacing: 8) {
                SparkLine(values: temps, color: accent, xFractions: fractions)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    // 与"最热"行背景呼应，给趋势窗一个淡色轨道
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.secondary.opacity(0.05)))
                // 右侧极值刻度（圆体渐变数字，与面板同源）
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(hi))°").font(MonitorStyle.numeral(11)).foregroundStyle(accent.gradient)
                    Spacer(minLength: 0)
                    Text("\(Int(lo))°").font(MonitorStyle.numeral(11)).foregroundStyle(.secondary)
                }
                .frame(width: 30)
                .padding(.vertical, 2)
            }
            .frame(height: MonitorStyle.height)
        }
    }
}

// “哪里最热”：按 CPU/GPU/SSD/掌托/散热片 展示，按温度排序、最热在顶。
// 设计：部件图标+名称（身份色稳定） · 胶囊辉光热度条（温度色） · 圆体渐变数字
struct HotspotList: View {
    let components: [FanModel.ComponentTempDisplay]

    // 部件身份：图标 + 稳定色（不随温度变，避免“警报器”观感）
    private func icon(_ id: String) -> String {
        switch id {
        case "CPU": return "cpu"
        case "GPU": return "cpu.fill"
        case "SSD": return "internaldrive.fill"
        case "掌托": return "hand.raised.fill"
        case "散热片": return "wind"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        if components.isEmpty {
            MonitorEmpty(text: "暂无传感器数据")
        } else {
            // 固定槽位自适应行高：槽位 92pt 内均分（spacing 占位后每行 ≈16pt），
            // 行内内容用 minimumScaleFactor 兜底——5 部件（散热片/CPU/GPU/掌托/SSD
            // 同时有效）时每行只有 ~16pt，行 padding 压到 1 否则最后一条背景被裁出槽位
            // （旧实现行 padding 4 + 内容 11pt 固定高，4 行 ≈53pt 是上限，5 行必溢出）
            VStack(spacing: 2) {
                ForEach(Array(components.enumerated()), id: \.element.id) { idx, comp in
                    let c = MonitorStyle.color(comp.temp)
                    hotspotRow(idx: idx, comp: comp, color: c)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: components.map(\.id))
        }
    }

    // 单行：图标+名称 · 辉光热度条 · （火焰）温度数字。
    // 名称/数字不换行不压缩布局：数字 minimumScaleFactor 只在 5 行挤压时缩 10%
    private func hotspotRow(idx: Int, comp: FanModel.ComponentTempDisplay, color: Color) -> some View {
        HStack(spacing: 8) {
            // 部件图标 + 名称
            HStack(spacing: 5) {
                Image(systemName: icon(comp.id))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(comp.id)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 58, alignment: .leading)
            // 热度条：40~100°C 映射宽度，统一胶囊辉光能量条
            GlowBar(fraction: (comp.temp - 40) / 60, color: color)
                .frame(height: 5)
            HStack(spacing: 3) {
                if idx == 0 {
                    Image(systemName: "flame.fill").font(.system(size: 8)).foregroundStyle(color)
                        .transition(.scale.combined(with: .opacity))
                }
                Text("\(Int(comp.temp.rounded()))°")
                    .font(MonitorStyle.numeral(idx == 0 ? 14 : 12))
                    .foregroundStyle(color.gradient)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: comp.temp)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        // 行背景：最热第一项用温度色强调，其余用极淡中性色，增强列表层次
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(idx == 0 ? color.opacity(0.10) : .secondary.opacity(0.05))
        )
        .animation(.smooth(duration: 0.35), value: color)
    }
}

// "占用"：谁在发热——CPU 高占用进程榜 + GPU 温度指示。
// CPU 进程占用为实时采样（无需 root）；GPU 无按进程公开 API，故以温度指示 GPU 负载。
// 固定 92pt 高度，与其它 tab 一致，切换不改变面板尺寸。
struct ProcessHogView: View {
    let processes: [FanModel.ProcessUsage]
    let gpuTemp: Double

    private static func cpuColor(_ c: Double) -> Color {
        c >= 80 ? .red : (c >= 40 ? .orange : .blue)
    }

    var body: some View {
        if processes.isEmpty {
            MonitorEmpty(text: "负载较低 · 无高占用进程")
        } else {
            VStack(spacing: 4) {
                // GPU 温度指示行（GPU 按进程占用无公开 API，用温度反映 GPU 忙闲）
                HStack(spacing: 5) {
                    Image(systemName: "cpu.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("GPU").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(gpuTemp > 1 ? "\(Int(gpuTemp))°" : "--")
                        .font(MonitorStyle.numeral(12)).foregroundStyle(MonitorStyle.color(gpuTemp).gradient)
                        .contentTransition(.numericText()).animation(.snappy, value: gpuTemp)
                    Spacer(minLength: 4)
                    Text("GPU 忙 → 温度高")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                // CPU 高占用进程榜（取前 3，避免 92pt 高度里拥挤）
                // 用 enumerated + \.offset 作 id：多个同名进程（如多个 python）会重名，
                // 以进程名为 id 时 ForEach 行为未定义/合并显示
                ForEach(Array(processes.prefix(3).enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 6) {
                        Text(p.id)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("\(Int(p.cpu))%")
                            .font(MonitorStyle.numeral(10))
                            .foregroundStyle(Self.cpuColor(p.cpu))
                            .contentTransition(.numericText()).animation(.snappy, value: p.cpu)
                        GlowBar(fraction: min(p.cpu / 100, 1), color: Self.cpuColor(p.cpu))
                            .frame(width: 44, height: 5)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// “今日”：把战报从菜单纯文字搬到面板，2×2 小磁贴（图标+标题+圆体渐变数值），与面板同语言
struct TodayStatsView: View {
    let stats: DailyStats?

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static func duration(_ s: Double) -> String {
        let m = Int(s) / 60
        if m >= 60 { return "\(m / 60)h\(m % 60)m" }
        if m >= 1 { return "\(m) 分钟" }
        return "\(Int(s)) 秒"
    }
    private static func revs(_ r: Double) -> String {
        r >= 10_000 ? String(format: "%.1f万", r / 10_000) : "\(Int(r))"
    }

    var body: some View {
        if let s = stats, s.date == DailyStats.today(), s.tempCount > 0 {
            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    tile(icon: "thermometer.high", label: "最高", value: "\(Int(s.maxTemp.rounded()))°",
                         sub: Self.timeFmt.string(from: s.maxTempAt), color: MonitorStyle.color(s.maxTemp))
                    tile(icon: "thermometer.medium", label: "均温", value: "\(Int(s.avgTemp.rounded()))°",
                         sub: nil, color: MonitorStyle.color(s.avgTemp))
                }
                HStack(spacing: 8) {
                    tile(icon: "flame", label: "高温累计", value: Self.duration(s.highTempSeconds),
                         sub: "≥80°", color: s.highTempSeconds > 1 ? .orange : .green)
                    tile(icon: "fanblades.fill", label: "风扇转数", value: Self.revs(s.revolutions),
                         sub: "转", color: .blue)
                }
                if s.quietSeconds > 60 {
                    HStack(spacing: 8) {
                        tile(icon: "moon.fill", label: "静音时长", value: Self.duration(s.quietSeconds),
                             sub: nil, color: .indigo)
                        tile(icon: "bolt.fill", label: "平均功耗", value: s.avgPower > 1 ? "\(Int(s.avgPower.rounded()))W" : "--",
                             sub: nil, color: .yellow)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MonitorEmpty(text: "战报统计中，正常用一会儿就有了")
        }
    }

    // 单个磁贴：图标+标题一行，圆体渐变大数值，可选后缀
private func tile(icon: String, label: String, value: String, sub: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color)
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(MonitorStyle.numeral(17)).foregroundStyle(color.gradient)
                if let sub { Text(sub).font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.secondary.opacity(0.1)))
    }
}
