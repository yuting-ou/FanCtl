// PanelEffects —— AI 状态视觉原子（R89 自 PanelView 拆出）：学习状态语义、
// 学习状态点（CA 呼吸动效）、学习地图 Charts 散点图、决策透镜悬停完整解释。
import SwiftUI
import Charts
import SMCCore

// AI 学习状态语义（学习/稳定/冷启动）
enum AILearnState {
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
struct LearningDot: View {
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

// 学习地图图：温度→风量散点+折线，点径=置信度（样本数归一）
struct LearnMapView: View {
    let points: [ThermalLearn.LearnedPoint]

    var body: some View {
        let valid = points.filter { $0.samples > 0 && $0.percent.isFinite && $0.temp.isFinite }
                          .sorted { $0.temp < $1.temp }
        let maxSamples = max(valid.map(\.samples).max() ?? 1, 1)
        Chart(valid) { p in
            LineMark(x: .value("温度", p.temp), y: .value("风量", p.percent))
                .foregroundStyle(.secondary.opacity(0.5))
                .interpolationMethod(.catmullRom)
            PointMark(x: .value("温度", p.temp), y: .value("风量", p.percent))
                .symbolSize(p.samples >= ThermalLearn.minSamples
                            ? 40 + 90 * Double(p.samples) / Double(maxSamples) : 30)
                .foregroundStyle(Color.accentColor.opacity(0.9))
        }
        .chartXAxis {
            AxisMarks(values: [50, 60, 70, 80, 90]) { v in
                AxisValueLabel { if let x = v.as(Int.self) { Text("\(x)°").font(.system(size: 8)) } }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { v in
                AxisValueLabel { if let y = v.as(Int.self) { Text("\(y)").font(.system(size: 8)) } }
            }
        }
        .chartYScale(domain: 0...100)
        // 顶刻度"100"标签中心在绘图区顶边上，字身一半悬出 frame 被裁（快照审查 R20）
        // ——留 4pt 顶白容纳标签
        .padding(.top, 4)
        .help("每个点是 AI 采信的一个温度档：位置=该温度下的稳态风量，点越大=样本越多越可信。虚线期的非单调包络修正已计入。")
    }
}

extension DecisionTrace {
    // 透镜完整解释（悬停文案）——与引擎语义一一对应，不引入新语义
    var explanation: String {
        var lines: [String] = []
        if let t = target, let cur = temp {
            lines.append("AI 目标 \(Int(t.rounded()))°C（环境/夜间/电池叠加后的有效目标），当前芯片 \(Int(cur.rounded()))°C")
        }
        if let l = learned {
            lines.append("经验查表：这台机器稳住当前温度需要约 \(Int(l.rounded()))% 风量")
        } else {
            lines.append("当前温度尚无采信经验（AI 正用曲线基准与积分控制）")
        }
        if idle == true { lines.append("空闲交还：温度持续低于目标，风扇交还系统调度（可能停转）") }
        if hysteresisHold == true { lines.append("迟滞保持：微小波动被带宽吸收，本拍未写入新转速（决策在演化）") }
        if let g = guardSeconds, g > 0 { lines.append("启停抑制：\(Int(g / 60)) 分钟内不交还，防止停转-启转循环磨损轴承") }
        return lines.joined(separator: "\n")
    }
}
