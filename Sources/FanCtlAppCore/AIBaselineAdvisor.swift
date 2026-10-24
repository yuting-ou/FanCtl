import Foundation

/// AI 目标推荐的基线采样与分档（R90 从 FanModel 下沉）。
/// 首次进入 AI 且无学习数据时，采样 30s 基线温度（芯片热点），按均温推荐目标档：
/// 凉 → 性能档（目标低、风扇猛），热 → 静音档（目标高、可接受更热）。
/// 采样状态（aiBaselineTemps / aiModeEnteredAt）与 I/O 留在 FanModel，此处纯函数。
public enum AIBaselineAdvisor {

    /// 基线采样窗（秒）：v3.6.2（F3）推荐产出即停采样——此前 learnedPoints==0 期间
    /// 每 12s 无限追加（学习停滞/daemon 离线时 O(n²) 增长）。
    public static let sampleWindow: TimeInterval = 30

    /// 基线均温 → 推荐目标分档：≤68°→72（性能）；<73°→76（均衡）；否则 80（静音）。
    public static func target(forBaselineAverage avg: Double) -> Double {
        avg <= 68 ? 72 : (avg < 73 ? 76 : 80)
    }

    /// 采样窗满且样本非空 → 推荐目标；nil = 继续采样。
    public static func recommendation(baselineTemps: [Double], enteredAgo: TimeInterval) -> Double? {
        guard enteredAgo >= sampleWindow, !baselineTemps.isEmpty else { return nil }
        return target(forBaselineAverage: baselineTemps.reduce(0, +) / Double(baselineTemps.count))
    }
}
