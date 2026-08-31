import Foundation

// MARK: - 传感器物理一致性门（卡死检测，纯逻辑，daemon 与测试共用）
//
// 读失败（连续 5 拍）与读数跳变（deglitch）之外的三类传感器故障模式：卡死
// （stuck-at）——SMC/I2C 故障常表现为温度钉死在某个值而非读零，全链路看起来
// "一切正常"，92° 兜底对它完全失明。
//
// 物理判据：温度与功耗强耦合，真实传感器存在 LSB 抖动——功耗波动 ≥10W 的窗口内
// 热点读数纹丝不动（逐位相等）持续数分钟，物理上不成立。两个条件同时满足才判定：
//   1. 窗口 ≥ minDuration（默认 5 分钟，几十拍）
//   2. 窗口内功耗最大最小差 ≥ minPowerSwing（10W，远超 PSTR ±2W 噪声）
// 任一不满足即不可能误报：负载平稳时功耗差不够、读数真实时必然抖动。
// 无功耗键的机型（powerWatts nil）无法做物理互检，检测器保持惰性。
//
// 恢复条件：读数发生任何变化（故障锁存期间持续监视）——卡死的传感器一旦"动了"
// 说明读数通道恢复，解除故障并重新接管。方向安全：误判的代价是交还系统调度
// （macOS 自己的风扇策略兜底），漏判的代价是 92° 兜底失明。

public struct StuckSensorDetector {
    public static let minDuration: TimeInterval = 300   // 5 分钟
    public static let minPowerSwing = 10.0              // W

    public private(set) var faulted = false
    public private(set) var stuckTemp: Double = 0

    private var windowStart: Date? = nil
    private var minPower = Double.infinity
    private var maxPower = -Double.infinity

    public init() {}

    /// 每拍喂入原始热点读数与整机功耗。返回 true = 本拍刚确认卡死（边沿事件）。
    /// 故障锁存期间继续喂入：读数一旦变化，自动解除 faulted（恢复沿，调用方比对
    /// 前后 faulted 即可感知）。
    @discardableResult
    public mutating func record(rawTemp: Double, powerWatts: Double?, now: Date) -> Bool {
        // 故障期间：监视复活信号
        if faulted {
            if rawTemp != stuckTemp {
                faulted = false
                resetWindow()
                stuckTemp = rawTemp
                windowStart = now
                trackPower(powerWatts)
            }
            return false
        }

        // 读数移动 → 新窗口（窗口以"读数完全不变"为前提）
        if rawTemp != stuckTemp || windowStart == nil {
            stuckTemp = rawTemp
            windowStart = now
            minPower = .infinity
            maxPower = -Double.infinity
        }
        trackPower(powerWatts)

        if let ws = windowStart,
           now.timeIntervalSince(ws) >= Self.minDuration,
           maxPower - minPower >= Self.minPowerSwing {
            faulted = true
            return true
        }
        return false
    }

    /// 强制复位（睡眠唤醒等控制上下文重置时调用）
    public mutating func reset() {
        faulted = false
        resetWindow()
        stuckTemp = 0
    }

    private mutating func resetWindow() {
        windowStart = nil
        minPower = .infinity
        maxPower = -Double.infinity
    }

    private mutating func trackPower(_ powerWatts: Double?) {
        guard let p = powerWatts, p.isFinite, p >= 0 else { return }
        minPower = min(minPower, p)
        maxPower = max(maxPower, p)
    }
}
