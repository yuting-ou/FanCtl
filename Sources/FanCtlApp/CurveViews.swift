// CurveViews —— 曲线展示与自定义曲线编辑器。
import SwiftUI
import Charts
import SMCCore

struct CurveChart: View {
    let config: FanConfig
    let currentTemp: Double
    let appliedPercent: Double
    let live: Bool
    var height: CGFloat = 92   // 92 为标准高度；AI 建议块在场时外部压缩（防 200pt 槽位溢出裁掉按钮）

    private var samples: [(temp: Double, percent: Double)] {
        stride(from: 45.0, through: 95.0, by: 1.0).map { ($0, config.percentFor(temp: $0)) }
    }

    var body: some View {
        Chart {
            ForEach(samples, id: \.temp) { s in
                AreaMark(x: .value("温度", s.temp), y: .value("转速", s.percent))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue.opacity(0.22), .blue.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("温度", s.temp), y: .value("转速", s.percent))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            if live, currentTemp > 45, currentTemp < 95 {
                RuleMark(x: .value("当前温度", currentTemp))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("当前温度", currentTemp),
                          y: .value("当前输出", appliedPercent))
                    .foregroundStyle(.orange.opacity(0.22))
                    .symbolSize(95)
                PointMark(x: .value("当前温度", currentTemp),
                          y: .value("当前输出", appliedPercent))
                    .foregroundStyle(.orange)
                    .symbolSize(45)
            }
        }
        .chartXScale(domain: 45...95)
        .chartYScale(domain: 0...105)
        .chartXAxis {
            AxisMarks(values: [50, 60, 70, 80, 90]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let t = value.as(Double.self) {
                        Text("\(Int(t))°").font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let p = value.as(Double.self) {
                        Text("\(Int(p))%").font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.3), value: currentTemp)
        .animation(.smooth(duration: 0.3), value: appliedPercent)
        .animation(.snappy, value: config.curve)
    }
}

// 自定义曲线编辑器：在图上拖动 5 个控制点（温度/转速双向可调）
// 拖动时强制相邻点有序且百分比单调不减，保证曲线合理
struct EditableCurveChart: View {
    let points: [CurvePoint]
    let currentTemp: Double
    let appliedPercent: Double
    let live: Bool
    let onChange: ([CurvePoint]) -> Void
    var height: CGFloat = 92   // 同 CurveChart：AI 建议块在场时外部压缩

    @State private var dragIndex: Int? = nil

    private let xLo = 45.0, xHi = 95.0
    private let yLo = 0.0, yHi = 105.0

    private var samples: [(temp: Double, percent: Double)] {
        stride(from: xLo, through: xHi, by: 1.0).map { ($0, FanConfig.percent(temp: $0, curve: points)) }
    }

    var body: some View {
        Chart {
            ForEach(samples, id: \.temp) { s in
                AreaMark(x: .value("温度", s.temp), y: .value("转速", s.percent))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue.opacity(0.22), .blue.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("温度", s.temp), y: .value("转速", s.percent))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            ForEach(Array(points.enumerated()), id: \.offset) { idx, p in
                PointMark(x: .value("温度", p.temp), y: .value("转速", p.percent))
                    .foregroundStyle(.blue)
                    .symbolSize(dragIndex == idx ? 150 : 95)
            }
            if live, currentTemp >= xLo, currentTemp <= xHi {
                RuleMark(x: .value("当前温度", currentTemp))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("当前温度", currentTemp),
                          y: .value("当前输出", appliedPercent))
                    .foregroundStyle(.orange.opacity(0.22))
                    .symbolSize(115)
                PointMark(x: .value("当前温度", currentTemp),
                          y: .value("当前输出", appliedPercent))
                    .foregroundStyle(.orange)
                    .symbolSize(55)
            }
        }
        .chartXScale(domain: xLo...xHi)
        .chartYScale(domain: yLo...yHi)
        .chartXAxis {
            AxisMarks(values: [50, 60, 70, 80, 90]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let t = value.as(Double.self) {
                        Text("\(Int(t))°").font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let p = value.as(Double.self) {
                        Text("\(Int(p))%").font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { handleDrag($0, proxy: proxy, geo: geo) }
                            .onEnded { _ in dragIndex = nil }
                    )
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.3), value: currentTemp)
        .animation(.smooth(duration: 0.3), value: appliedPercent)
        .animation(.snappy(duration: 0.2), value: dragIndex)
    }

    private func handleDrag(_ value: DragGesture.Value, proxy: ChartProxy, geo: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let plot = geo[anchor]
        // 拖动开始时锁定离触点最近的控制点，之后始终拖动它
        let idx: Int
        if let d = dragIndex {
            idx = d
        } else {
            var best = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (i, p) in points.enumerated() {
                guard let px = proxy.position(forX: p.temp),
                      let py = proxy.position(forY: p.percent) else { continue }
                let dx = Double(value.startLocation.x - (px + plot.minX))
                let dy = Double(value.startLocation.y - (py + plot.minY))
                let dist = dx * dx + dy * dy
                if dist < bestDist { bestDist = dist; best = i }
            }
            idx = best
            dragIndex = best
        }
        // 触点屏幕坐标 → 图表数据坐标
        guard let rawTemp = proxy.value(atX: value.location.x - plot.minX, as: Double.self),
              let rawPct = proxy.value(atY: value.location.y - plot.minY, as: Double.self) else { return }
        var pts = points
        // 温度夹在相邻点之间（至少隔 1°C），首尾点限在域内
        let minTemp = idx > 0 ? pts[idx - 1].temp + 1 : xLo
        let maxTemp = idx < pts.count - 1 ? pts[idx + 1].temp - 1 : xHi
        pts[idx].temp = (min(max(rawTemp, minTemp), maxTemp) * 2).rounded() / 2  // 0.5°C 步进
        // 百分比单调不减，夹在相邻点之间，整体 0~100
        let minPct = idx > 0 ? pts[idx - 1].percent : 0
        let maxPct = idx < pts.count - 1 ? pts[idx + 1].percent : 100
        pts[idx].percent = min(max(rawPct, minPct), maxPct).rounded()
        onChange(pts)
    }
}

