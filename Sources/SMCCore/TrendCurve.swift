// TrendCurve —— 趋势图"上屏前"的整理：先剔不可信读数，再做轻度平滑。
//
// 为什么单独一层：真机缓存里曾连续 45 条 cpuDie≈8.4°C 的坏读数（daemon 的
// `StatsSampler.tempPlausible` 会拒绝它们，但 App 的趋势图此前照单全收），
// 一条 8.4°C 就把整张图的 y 轴从 45–74° 拉成 8–74°，正常波动被压成上沿一条线；
// 叠加真机相邻样本中位差 2.97°C 的传感器噪声，看上去就是"地震图"。
//
// 两条纪律：
//   ① 剔除只按"系统自己判定不可信"的判据（与 daemon 统计口径同一谓词），
//      不按"偏离均值太大"——真实尖峰必须留下；
//   ② display 用的平滑值只影响**画线**；坐标标签（hi/lo）始终取**过滤后原始值**的极值，
//      所以"平滑"不会把真实极值抹掉。
import Foundation

public enum TrendCurve {
    /// 上屏整理：时间戳与温度成对过滤、成对保留，返回画线用的（平滑后）序列与真实极值。
    ///
    /// - `rawTemps` / `times` 必须等长；不等长时按较短者截断（防调用方拼错）。
    /// - 过滤：`StatsSampler.tempPlausible`（NaN/Inf、≤1、>125、低于环境 12°C 以上判失真）。
    /// - 平滑：端点收缩的移动平均（窗口 w 时左右各取 w/2，窗口在端点自动缩窄，不平移相位）。
    /// - 返回的 `lo`/`hi` 是**过滤后原始值**的极值（不含平滑），供坐标标签使用；
    ///   全部被过滤时返回空序列与 0/0。
    public static func prepare(rawTemps: [Double], times: [Double], window: Int,
                               envTemp: Double? = nil)
        -> (temps: [Double], times: [Double], lo: Double, hi: Double) {
        let n = min(rawTemps.count, times.count)
        var keptTemps: [Double] = []
        var keptTimes: [Double] = []
        keptTemps.reserveCapacity(n)
        keptTimes.reserveCapacity(n)
        for i in 0..<n where StatsSampler.tempPlausible(rawTemps[i], envTemp: envTemp) {
            keptTemps.append(rawTemps[i])
            keptTimes.append(times[i])
        }
        guard !keptTemps.isEmpty else { return ([], [], 0, 0) }
        let lo = keptTemps.min() ?? 0
        let hi = keptTemps.max() ?? 0
        return (movingAverage(keptTemps, window: window), keptTimes, lo, hi)
    }

    /// 端点收缩的移动平均：i 取 `[i-w/2, i+w/2]` 的均值，端点自动缩窄。
    /// `window <= 1` 或样本不足 2 条时原样返回（不做任何"看起来更平滑"的伪造）。
    public static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > 1 else { return values }
        let half = window / 2
        return values.indices.map { i in
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            return values[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }
}
