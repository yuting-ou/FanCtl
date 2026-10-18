import Foundation
import SMCCore

/// status.json 是组可写文件，可能损坏或被手改。daemon 写端已有防御，但 App 不能依赖
/// "写端一定正确"——Double→Int 越界在 Swift 是 fatal trap。这里集中 App 侧的数值入口，
/// 纯函数、可被 fanctltests 直接覆盖（此前散在 FanModel 里，只能靠源码静态门）。
public enum StatusDefense {
    /// 主卡温度：非有限/≤0/≥150 一律按"无读数"处理（0 让 UI 显示占位）。
    public static func temperature(_ v: Double) -> Double {
        v.isFinite && v > 0 && v < 150 ? v : 0
    }

    public static func rpm(_ v: Double) -> Double {
        v.isFinite ? min(max(v, 0), 20_000) : 0
    }

    /// 百分比会进 Int() 渲染，必须先钳位。
    public static func percent(_ v: Double) -> Double {
        v.isFinite ? min(max(v, 0), 100) : 0
    }

    /// 每风扇百分比与风扇数组同序；整段缺失时退回单值（旧 daemon 兼容）。
    public static func appliedPercents(_ values: [Double]?, fallback: Double) -> [Double] {
        values.map { $0.map(percent) } ?? [fallback]
    }

    /// 分项温度（均值/SSD/掌托）：无效值显式返回 nil，避免 UI 继续展示陈旧值。
    public static func temperatureReading(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0, v < 150 else { return nil }
        return v
    }

    /// 环境温度代理的有效域更窄（>0 且 <60°C）。
    public static func environmentTemperature(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0, v < 60 else { return nil }
        return v
    }

    /// AI 实际生效目标：只在物理上可能的目标域内展示。
    public static func aiTarget(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 20, v < 100 else { return nil }
        return v
    }

    /// 体感补偿量：>0.5°C 才值得展示，且不超过 4°C。
    public static func palmCompensation(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0.5, v <= 4 else { return nil }
        return v
    }

    /// 整机功耗：0.1W–1000W 之外视为坏读数。
    public static func powerWatts(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0.1, v < 1000 else { return nil }
        return v
    }

    /// 风扇 id 只接受 0..<8：越界 id 会让 fanOffsets[id] 崩溃，或在 App 侧写出天文数组。
    public static func fanStates(from entries: [FanStatusEntry]) -> [FanState] {
        entries.filter { $0.id >= 0 && $0.id < 8 }.map { entry in
            FanState(id: entry.id,
                     actualRPM: rpm(entry.actualRPM),
                     minRPM: rpm(entry.minRPM),
                     maxRPM: rpm(entry.maxRPM),
                     targetRPM: rpm(entry.targetRPM))
        }
    }

    /// 学习点会直接进图表坐标域：坏点（1e300 / NaN / 越界百分比）必须挡在外面。
    public static func learnedPoints(_ points: [ThermalLearn.LearnedPoint])
        -> [ThermalLearn.LearnedPoint] {
        points.filter {
            $0.temp.isFinite && $0.temp > 0 && $0.temp < 150
                && $0.percent.isFinite && $0.percent >= 0 && $0.percent <= 100
                && $0.samples > 0
        }
    }
}
