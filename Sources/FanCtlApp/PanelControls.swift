// PanelControls —— 面板通用控件（R89 自 PanelView 拆出）：统一分段选择器、
// 按钮样式、daemon 状态点（CA 脉冲动效）、升级菜单区。无 FanModel 依赖面
// （UpgradeMenuSection 只持自备的 SelfUpgradeService）。
import SwiftUI
import SMCCore
import FanCtlAppCore


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
struct SegmentedItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// 带按压反馈的按钮样式：按下时轻微缩放 + 半透明，松开回弹，让交互更跟手
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// 守护进程状态点：运行中绿点呼吸（v2.6.1 起 CA 层动画，零 SwiftUI 渲染循环）
struct DaemonStatusDot: View {
    let alive: Bool

    var body: some View {
        if alive {
            if snapshotPlainCards {
                ZStack {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Circle().stroke(.green.opacity(0.3), lineWidth: 1.2).frame(width: 7, height: 7)
                }
                .frame(width: 14, height: 14)
            } else {
                PulseDotNSView(color: .systemGreen)
                    .frame(width: 14, height: 14)
            }
        } else {
            // 7pt 点放进 14×14 框（与运行态同尺寸）：头部右列整体右锚定，未运行态差点
            // 7pt 会把「⚡功耗 / 🌡环境」两枚胶囊一起左推、点自身横移 3.5pt——daemon
            // 起停一次，头部右列就跳位。两态同框后只剩颜色与光晕在变。
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .frame(width: 14, height: 14)
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

// v3.9 一键升级菜单区：新版本可用时的完整状态机展示。
// 进行中（下载/校验/等授权）显示进度文案且禁止重复点击；
// 失败显示原因并给"重试"；任何时刻保留"打开下载页"手动退路与"跳过此版本"。
struct UpgradeMenuSection: View {
    @ObservedObject var upgrader: SelfUpgradeService
    let tag: String
    let skip: () -> Void

    // 进行中/失败态用 phase.tag（实际下载的版本）——24h 自检若中途刷新
    // updateAvailable，外部 tag 可能已变，文案必须跟实际操作走（审查修复④）；
    // idle 态无 phase.tag，用外部 tag（= updateAvailable，刚刚查到的）
    private var activeTag: String { upgrader.phase.tag ?? tag }

    var body: some View {
        switch upgrader.phase {
        case .idle:
            Button("⬆️ 升级到 \(tag)…") { upgrader.start(tag: tag) }
            Button("跳过此版本") { skip() }
        case .downloading, .validating, .installing:
            let step: String = {
                switch upgrader.phase {
                case .downloading: return "正在下载 \(activeTag)…"
                case .validating: return "正在校验 \(activeTag)…"
                default: return "等待授权安装 \(activeTag)…（若弹窗未出现请先点击面板）"
                }
            }()
            Text(step)
            Button("打开下载页…") { NSWorkspace.shared.open(FanModel.releasesURL) }
        case .failed(_, let reason):
            Text("升级失败：\(reason)")
            Button("重试升级到 \(activeTag)") { upgrader.retry(tag: activeTag) }
            Button("打开下载页…") { NSWorkspace.shared.open(FanModel.releasesURL) }
            Button("跳过此版本") { skip() }
        }
    }

}
