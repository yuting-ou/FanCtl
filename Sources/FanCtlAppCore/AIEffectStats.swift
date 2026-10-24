import Foundation
import SMCCore

/// AI 效果卡的聚合与文案（R89 从 FanModel 下沉，此前只有源码静态门守——"文本门残留"
/// 最典型的一块）。口径纪律是 R55/R57 审查的产物，现在由执行级测试钉住：
/// - 过滤与天数同走 `tempCount > 0` + `isUsableDay`——天数砍了、均温没砍，就是
///   「启用 3 天 · 均温 45°→61°」里两个数各自数不同的日子（R57 P1）；
/// - 天数被砍到 0 时不给"均温已变"的结论卡（「启用 0 天 · 均温 45°→61°」是自相矛盾
///   的谎，R57 P2）——这条留在调用方 reoptimizeState 的天数门里；
/// - 时间加权口径与 v2.6.2 起的 avgTemp 一致；旧数据无 tempSeconds 时回退
///   "样本数×3s"估算（v2.6 前守护进程固定 3s 一拍），不复活固定 3s 假设。
public enum AIEffectStats {

    /// 基线 vs 启用后的一览。值的采集（UserDefaults 基线、天数判定）在调用方。
    public struct AIEffect: Equatable {
        public let days: Int
        public let beforeAvg: Double
        public let afterAvg: Double
        public let beforeHot: Double
        public let afterHot: Double

        public init(days: Int, beforeAvg: Double, afterAvg: Double,
                    beforeHot: Double, afterHot: Double) {
            self.days = days
            self.beforeAvg = beforeAvg
            self.afterAvg = afterAvg
            self.beforeHot = beforeHot
            self.afterHot = afterHot
        }
    }

    /// 时间加权均温与高温占比；没有可用天返回 nil（调用方据此不给结论）。
    /// now 与天数判定必须共用调用方同一次注入的时刻（"自己挑一把让天数变好看的尺"
    /// 是 R57 审查 P3-1 堵掉的形状洞）。
    public static func aggregate(_ days: [DailyStats], now: Date) -> (avg: Double, hot: Double)? {
        // R57 审查 P1：过滤必须与 dataDayCount 同一条 isUsableDay
        let valid = days.filter { $0.tempCount > 0 && $0.isUsableDay(now: now) }
        guard !valid.isEmpty else { return nil }
        let tempSum = valid.reduce(0.0) { $0 + $1.tempSum }
        let hotSeconds = valid.reduce(0.0) { $0 + $1.highTempSeconds }
        // 时间加权口径（与 v2.6.2 起的 avgTemp/直方图一致）；旧数据无 tempSeconds
        // 时回退"样本数×3s"估算（v2.6 前守护进程固定 3s 一拍）。
        let secs = valid.reduce(0.0) { $0 + $1.tempSeconds }
        if secs > 0 { return (tempSum / secs, hotSeconds / secs) }
        let cnt = valid.reduce(0.0) { $0 + $1.tempCount }
        return (tempSum / cnt, hotSeconds / (cnt * 3.0))
    }

    /// 面板效果卡文案；effect 为 nil 时返回 nil（不展示半张卡）。
    public static func effectText(_ e: AIEffect?) -> String? {
        guard let e else { return nil }
        let dAvg = e.beforeAvg - e.afterAvg
        let arrow = dAvg >= 0 ? "↓" : "↑"
        return "启用 \(e.days) 天 · 均温 \(Int(e.beforeAvg.rounded()))°→\(Int(e.afterAvg.rounded()))°（\(arrow)\(abs(Int(dAvg.rounded())))°）· 高温 \(Int((e.beforeHot * 100).rounded()))%→\(Int((e.afterHot * 100).rounded()))%"
    }
}
