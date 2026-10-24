import Foundation
import SMCCore

/// 散热健康趋势的判据与文案（R89 从 FanModel.refreshThermalHealth 下沉）。
///
/// 散热退化趋势：同功耗下的温升随时间漂移（硅脂老化/积灰）。用战报的
/// 均温/平均功耗（°C/W）作代理——数据需积累 2 周以上才有意义。
/// 最近 7 天 vs 之前 7 天，比值变化超 ±15% 才给方向性结论。
/// I/O（读 history/stats）留在 FanModel，以参数注入；本类型纯函数可执行级测试。
public enum ThermalHealthText {

    /// 全判据：输入未过滤的天（本函数自己过滤 `avgPower > 1 && tempCount > 0`，
    /// 与下沉前的调用侧过滤同一条），返回面板文案。
    /// - 不足 2 天有效数据：nil（不展示）
    /// - 2–13 天：积累中提示
    /// - ≥14 天：稳定 / 效率下降（建议清灰换硅脂）/ 效率提升 三态
    public static func text(days: [DailyStats]) -> String? {
        let valid = days.filter { $0.avgPower > 1 && $0.tempCount > 0 }
        guard valid.count >= 14 else {
            return valid.count >= 2
                ? "散热趋势积累中（需约 2 周数据，已 \(valid.count) 天）"
                : nil
        }
        let recent = Array(valid.suffix(7))
        let prior = Array(valid.prefix(valid.count - 7).suffix(7))
        func ratio(_ ds: [DailyStats]) -> Double {
            let p = ds.reduce(0.0) { $0 + $1.avgPower }
            let t = ds.reduce(0.0) { $0 + $1.avgTemp }
            return p > 1 ? t / p : 0
        }
        let r1 = ratio(prior), r2 = ratio(recent)
        guard r1 > 0.01 else { return nil }
        let change = (r2 - r1) / r1
        if change > 0.15 {
            return String(format: "散热效率下降 %.0f%%（%.2f→%.2f °C/W），建议清灰或换硅脂",
                          change * 100, r1, r2)
        } else if change < -0.15 {
            return String(format: "散热效率提升 %.0f%%（%.2f→%.2f °C/W）", -change * 100, r1, r2)
        }
        return String(format: "散热稳定（%.2f °C/W，两周变化 %+.0f%%）", r2, change * 100)
    }
}
