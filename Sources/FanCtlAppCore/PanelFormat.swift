import Foundation
import SMCCore

/// 面板/磁贴的展示格式化层（R89 从 PanelView 与 MonitorViews 的私有实现统一收口）。
/// 此前时长/转数/时间格式在两个文件里各写一份（且是**刻意不同的两种变体**：
/// 面板行用完整中文"3 小时 20 分钟"，磁贴用紧凑"3时20分"）——下沉时分立命名，
/// 不强行合一；行为级测试钉住各自的输出，保证替换零漂移。
///
/// 全部纯函数（DateFormatter 静态单例与原实现同款式，主线程使用）。
public enum PanelFormat {

    /// "HH:mm"（战报峰值时刻等）
    public static let timeHM: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 完整中文时长（面板"关于/战报"行）："3 小时 20 分钟" / "5 分钟" / "42 秒"
    public static func durationLong(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        if m >= 60 { return "\(m / 60) 小时 \(m % 60) 分钟" }
        if m >= 1 { return "\(m) 分钟" }
        return "\(Int(seconds)) 秒"
    }

    /// 磁贴紧凑中文时长（今日战报磁贴，R82 续六：中文界面不留 "2h30m" 英文字母时长）：
    /// "3时20分" / "5 分钟" / "42 秒"
    public static func durationCompactCN(_ s: Double) -> String {
        let m = Int(s) / 60
        if m >= 60 { return "\(m / 60)时\(m % 60)分" }
        if m >= 1 { return "\(m) 分钟" }
        return "\(Int(s)) 秒"
    }

    /// 转数完整表述（面板战报行）："1.2 万转" / "358 转"
    public static func revolutionText(_ revs: Double) -> String {
        revs >= 10_000 ? String(format: "%.1f 万转", revs / 10_000) : "\(Int(revs)) 转"
    }

    /// 转数紧凑表述（磁贴，单位由磁贴标题承担）："1.2万" / "358"
    public static func revsCompact(_ r: Double) -> String {
        r >= 10_000 ? String(format: "%.1f万", r / 10_000) : "\(Int(r))"
    }

    /// 倒计时 "m:ss"（冲刺/静音剩余）
    public static func countdown(to end: Date, now: Date) -> String {
        let remain = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "%d:%02d", remain / 60, remain % 60)
    }

    /// 磁贴用超紧凑时长：s/m/h 单字母后缀（"130h"、"1.6h"），完整表述在悬停 full 里
    public static func compactDuration(_ seconds: Double) -> String {
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        let minutes = seconds / 60
        if minutes < 90 { return String(format: "%.0fm", minutes) }
        let hours = minutes / 60
        return String(format: hours >= 10 ? "%.0fh" : "%.1fh", hours)
    }

    /// 千位分隔转速文本（"2,858"），与 FanRow 同风格
    public static func rpmText(_ rpm: Double) -> String {
        let n = Int(rpm.rounded())
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// AI 评测摘要：磁贴行取原始秒数自行格式化；full 为悬停完整版
    /// （含峰值/调速次数等磁贴放不下的指标）
    public static func evaluationText(_ m: AIControlMetrics)
        -> (seconds: Double, highSeconds: Double, full: String) {
        let full = """
        AI 评测（目标 \(Int(m.targetTemp))°，\(m.sampleCount) 个样本）
        时长 \(durationLong(m.activeSeconds)) · 均温 \(String(format: "%.1f", m.averageTemp))° · 峰值 \(String(format: "%.1f", m.peakTemp))°
        波动 \(String(format: "%.1f", m.temperatureStdDev))° · 最大过冲 +\(Int(m.maxOvershoot.rounded()))° · 平均输出 \(String(format: "%.0f", m.averageOutput))%
        调速 \(m.outputChangeCount) 次 · 超温（≥目标+5°）累计 \(durationLong(m.highTempSeconds))
        """
        return (m.activeSeconds, m.highTempSeconds, full)
    }
}
