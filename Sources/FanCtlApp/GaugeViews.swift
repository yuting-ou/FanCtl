// GaugeViews —— 温度卡/风扇行/迷你趋势线。
import SwiftUI
import SMCCore

struct SparkLine: View {
    let values: [Double]
    let color: Color
    // 可选的 x 位置分数（0~1，与 values 等长）：事件驱动采样下拍间隔不均，
    // 按时间戳映射 x 才不失真；nil = 均匀分布（旧行为）
    var xFractions: [Double]? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if values.count >= 2 {
                let lo = values.min() ?? 0
                let hi = values.max() ?? 1
                let realSpan = hi - lo
                let span = max(realSpan, 1)
                let uniformStep = w / CGFloat(values.count - 1)
                let pts = values.enumerated().map { i, v -> CGPoint in
                    // 温度基本平稳时（波动 < 1.5°C）居中绘制，
                    // 否则等比归一化会把平线钉在底部，误导为“温度降到最低”
                    let norm = realSpan < 1.5 ? 0.5 : CGFloat((v - lo) / span)
                    let x: CGFloat
                    if let f = xFractions, i < f.count, f.count == values.count {
                        x = CGFloat(min(max(f[i], 0), 1)) * w
                    } else {
                        x = CGFloat(i) * uniformStep
                    }
                    return CGPoint(x: x, y: h - norm * (h - 3) - 1.5)
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        p.addLine(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color.gradient,
                            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    // 最新读数光点：带柔和光晕，强化“实时”观感
                    if let last = pts.last {
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .shadow(color: color.opacity(0.7), radius: 3)
                            .position(last)
                    }
                }
            } else {
                Capsule()
                    .fill(color.opacity(0.2))
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

struct TempGaugeCard: View {
    let label: String
    let symbol: String
    let temp: Double
    let history: [Double]
    var subTemp: Double? = nil  // 副值（如 CPU 核心平均），与主值差异>1° 时显示

    private var color: Color { MonitorStyle.color(temp) }   // 与监控 tab 同一温度色彩（凉绿/温橙/烫红），避免同温不同色
    private var statusText: String {
        switch temp {
        case ..<68: return "正常"
        case ..<83: return "温热"
        default: return "偏高"
        }
    }
    // 副值显示条件：有值且与主值差异>1°（差异太小显示无意义）
    private var showSubTemp: Bool {
        guard let s = subTemp, s > 1, temp > 1, abs(temp - s) > 1 else { return false }
        return true
    }

    var body: some View {
        // v3.4.3 均衡排版：三段式固定节奏——表头（状态行）/ 数字区（垂直居中）
        // / 折线（锚底）。副值行占固定 18pt 槽位：CPU 有核心均温、GPU 没有时
        // GPU 槽位留空，两半的表头与折线位置严格对齐，数字区在剩余空间居中，
        // 消除"内容偏左上、GPU 半边空"的失衡（苹果卡片式留白：等距呼吸）。
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(color.gradient)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // 状态胶囊：一眼看出凉/热，色彩与温度区间一致
                if temp > 1 {
                    Text(statusText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.15)))
                        .id(statusText)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(height: 20)
            // 数字区：在表头与折线之间垂直居中（副值 chip 叠加在数字区底部固定槽位）
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(temp > 1 ? "\(Int(temp))" : "--")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(color.gradient)
                        .monospacedDigit()
                        // 主温度也用数字滚动（numericText），与 RPM/功耗/百分比一致，实时读数更"活"。
                        // 由卡片级 .animation(.smooth(0.45)) 驱动，温度小幅变化时平滑滚动而非生硬跳变。
                        .contentTransition(.numericText())
                        // 柔和辉光：让主温度数字从玻璃卡中"浮起"，强化视觉主从
                        .shadow(color: color.opacity(0.35), radius: 4, y: 1)
                    Text("°")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(color.opacity(0.6))
                }
                // 副值固定 18pt 槽位：无副值时也占位，保证两半折线/表头严格对齐
                ZStack(alignment: .leading) {
                    if showSubTemp, let s = subTemp {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(color.opacity(0.5))
                                .frame(width: 4, height: 4)
                            Text("核心均温 \(Int(s))°")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary.opacity(0.5)))
                        .contentTransition(.opacity)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(height: 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            SparkLine(values: history, color: color)
                .frame(height: 26)
                .frame(maxWidth: .infinity)
                .animation(.smooth(duration: 0.4), value: color)
        }
        // v3.4.2：自身不再带卡底——CPU/GPU 两半由调用方合入同一张玻璃瓦片；
        // v3.4.3：13pt 内距与全卡节奏统一（CardBackground 同值）
        .padding(13)
        .animation(.smooth(duration: 0.45), value: temp)
    }
}

struct FanRow: View {
    let fan: FanState
    let name: String
    var offset: Double = 0        // 该风扇的独立偏移（%），0 = 无偏移
    var onOffsetChange: ((Double) -> Void)? = nil   // 用户调整偏移（nil = 不显示偏移控件）

    // 转速在 [min, max] 区间的占比，驱动能量条与百分比
    private var loadFraction: CGFloat {
        let span = max(fan.maxRPM - fan.minRPM, 1)
        return CGFloat(min(max((fan.actualRPM - fan.minRPM) / span, 0), 1))
    }

    var body: some View {
        HStack(spacing: 10) {
            FanSpinner(rpm: fan.actualRPM, tint: .blue)
                .frame(width: 22)

            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(name)
                        .font(.callout)
                    Spacer()
                    Text("\(Int(fan.actualRPM))")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: fan.actualRPM)
                        .shadow(color: .blue.opacity(0.25), radius: 3, y: 0.5)
                    Text("RPM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Int(loadFraction * 100))%")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.blue.opacity(0.85))
                        .frame(width: 30, alignment: .trailing)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: loadFraction)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.secondary.opacity(0.16))
                        Capsule()
                            .fill(LinearGradient(colors: [.blue, .cyan],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * loadFraction))
                            .shadow(color: .blue.opacity(0.45), radius: 2.5, y: 0.5)
                    }
                }
                .frame(height: 5)
                .animation(.snappy(duration: 0.4), value: loadFraction)
            }
            // 独立偏移调节：双风扇散热能力不均/个体噪音差异时微调单侧
            if let onOffsetChange {
                if snapshotPlainCards {
                    // 快照：Menu 桥接 NSMenu 离屏退 🚫 → 等尺寸静态胶囊
                    Text(offset == 0 ? "偏移" : "偏移 \(Int(offset))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(offset == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.secondary.opacity(0.12)))
                } else {
                Menu {
                    ForEach([-20.0, -15, -10, -5, 0, 5, 10, 15, 20], id: \.self) { off in
                        Button(off == 0 ? "无偏移" : (off > 0 ? "\(name) +\(Int(off))%" : "\(name) \(Int(off))%")) {
                            onOffsetChange(off)
                        }
                    }
                } label: {
                    Text(offset == 0 ? "偏移" : "偏移 \(Int(offset))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(offset == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.secondary.opacity(0.12)))
                        .help("该风扇的独立转速偏移（±20%）。安全事件（92° 兜底/SSD 托底）不受偏移影响")
                }
                .menuStyle(.button)
                .fixedSize()
                }
            }
        }
    }
}

// 连续旋转的风扇图标：SF Symbol fanblades.fill 原地平滑旋转。
// v2.6.1 性能修复：TimelineView(.animation) 与 SwiftUI repeatForever 动画都会驱动
// NSHostingView 每帧 SwiftUI 渲染循环（面板打开时 App CPU 27–53%），
// 改为 NSViewRepresentable + CABasicAnimation——旋转由 Core Animation 渲染服务器
// 执行，完全绕开 SwiftUI 更新循环，零主线程成本。
// v2.6.2 视觉回归：自绘螺旋桨叶片方案被用户评为"抽象"，恢复经典风扇符号原地旋转。
// 转速变化时从 presentation layer 取当前相位作动画起点（无缝变速）；
// RPM < 50 时移除动画并半透明，表达"风扇停转"。
struct FanSpinner: View {
    let rpm: Double
    let tint: Color

    var body: some View {
        // 快照模式（ImageRenderer 离屏）不支持 NSViewRepresentable，退回静态图标
        if snapshotPlainCards {
            Image(systemName: "fanblades.fill")
                .font(.title3)
                .foregroundStyle(tint.gradient)
                .opacity(rpm < 50 ? 0.3 : 1.0)
        } else {
            SpinnerNSView(rpm: rpm, tint: tint)
                .frame(width: 24, height: 24)
        }
    }
}

private struct SpinnerNSView: NSViewRepresentable {
    let rpm: Double
    let tint: Color

    func makeNSView(context: Context) -> FanSpinnerView {
        let v = FanSpinnerView()
        v.setRPM(rpm, tint: NSColor(tint))
        return v
    }
    func updateNSView(_ nsView: FanSpinnerView, context: Context) {
        nsView.setRPM(rpm, tint: NSColor(tint))
    }
}

// 风扇原地旋转视图：CALayer.contents 直接承载符号图像（不用 NSImageView——
// 其 layer 渲染不可控，曾被反馈"乱旋转"），CABasicAnimation 持续旋转，渲染服务器驱动。
// 相位自维护（累计角度 + 时间结算），不依赖 presentation layer，杜绝相位跳变。
final class FanSpinnerView: NSView {
    private let iconLayer = CALayer()
    private var currentRPM: Double = -1
    private var animTint: NSColor = .systemBlue
    private var lastAngle: Double = 0        // 当前累计旋转角（弧度）
    private var lastAngleAt = Date()         // 上次结算时刻

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
        updateTint(.systemBlue)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        iconLayer.frame = bounds
    }

    // 模板符号着色（sourceAtop 保留 alpha、替换颜色）
    private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }

    private func updateTint(_ c: NSColor) {
        animTint = c
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let img = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config),
              let tinted = tintedImage(img, color: c) else { return }
        iconLayer.contents = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func setRPM(_ rpm: Double, tint: NSColor) {
        if tint != animTint { updateTint(tint) }
        if iconLayer.frame != bounds { iconLayer.frame = bounds }   // 布局兜底
        // v2.6.2：初始 currentRPM=-1 时即使 rpm=0 也要进入（停转半透明才生效）
        guard abs(rpm - currentRPM) > 1 || currentRPM < 0 else { return }
        let stopped = rpm < 50
        // 先按旧转速结算到此刻的相位，再以新转速续转（无缝、无跳变）。
        // 与动画速率一致：max(rpm/1200, 0.05)（否则 RPM∈[50,60) 时结算慢于动画，
        // 长时间后换挡相位漂移可见）
        if currentRPM >= 50, !stopped {
            let elapsed = Date().timeIntervalSince(lastAngleAt)
            if elapsed > 0, elapsed < 120 {
                let turns = max(currentRPM / 1200.0, 0.05) * elapsed
                lastAngle = (lastAngle + turns * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            }
        }
        currentRPM = rpm
        lastAngleAt = Date()
        iconLayer.opacity = stopped ? 0.3 : 1.0
        guard !stopped else {
            iconLayer.removeAnimation(forKey: "spin")
            return
        }
        // 视觉转速映射：1200 RPM → 1 圈/秒（比真实慢约 20 倍）
        let turnsPerSecond = max(rpm / 1200.0, 0.05)
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = lastAngle
        anim.toValue = lastAngle + Double.pi * 2
        anim.duration = 1.0 / turnsPerSecond
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        iconLayer.add(anim, forKey: "spin")
    }
}



