import Foundation

public struct AIControlMetrics: Codable, Equatable {
    public var targetTemp: Double
    // v2.9：用户设定的目标温度（持久化，跨启动比对用）。targetTemp 现在存的是
    // "有效目标"（环境/夜间/电池叠加后，随时间漂移），不能再用作"用户是否换档"的判据——
    // 否则夜间会话（有效目标 +4°）后每次重启都会误重置评测账本。
    public var userTargetTemp: Double?
    public var activeSeconds: Double
    public var sampleCount: Int
    public var temperatureSum: Double
    public var temperatureSquaredSum: Double
    public var peakTemp: Double
    public var maxOvershoot: Double
    public var highTempSeconds: Double
    public var outputSum: Double
    public var outputChangeCount: Int
    public var outputChangeMagnitude: Double
    public var lastOutput: Double?
    public var updatedAt: Date

    public init(targetTemp: Double, userTargetTemp: Double? = nil) {
        self.targetTemp = targetTemp; self.userTargetTemp = userTargetTemp
        self.activeSeconds = 0; self.sampleCount = 0
        self.temperatureSum = 0; self.temperatureSquaredSum = 0; self.peakTemp = 0
        self.maxOvershoot = 0; self.highTempSeconds = 0; self.outputSum = 0
        self.outputChangeCount = 0; self.outputChangeMagnitude = 0; self.lastOutput = nil
        self.updatedAt = Date()
    }

    public mutating func record(temp: Double, output: Double, seconds: Double) {
        guard temp.isFinite, output.isFinite, seconds.isFinite, seconds > 0 else { return }
        let t = max(0, min(150, temp)), p = max(0, min(100, output)), dt = min(seconds, 60)
        activeSeconds += dt; sampleCount += 1; temperatureSum += t
        temperatureSquaredSum += t * t; peakTemp = max(peakTemp, t)
        maxOvershoot = max(maxOvershoot, t - targetTemp)
        if t >= targetTemp + 5 { highTempSeconds += dt }
        outputSum += p
        if let last = lastOutput, abs(p - last) >= 2 {
            outputChangeCount += 1; outputChangeMagnitude += abs(p - last)
        }
        lastOutput = p; updatedAt = Date()
    }

    public var averageTemp: Double { sampleCount > 0 ? temperatureSum / Double(sampleCount) : 0 }
    public var temperatureStdDev: Double {
        guard sampleCount > 0 else { return 0 }
        return sqrt(max(0, temperatureSquaredSum / Double(sampleCount) - averageTemp * averageTemp))
    }
    public var averageOutput: Double { sampleCount > 0 ? outputSum / Double(sampleCount) : 0 }
}
