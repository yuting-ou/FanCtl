import Foundation
import SMCCore

/// 一份 status.json 投影后的展示值：所有字段都已消毒/钳位，App 只负责赋值。
public struct StatusProjection {
    public var cpuTemp: Double
    public var cpuAverageTemp: Double?
    public var gpuTemp: Double
    public var ssdTemp: Double?
    public var palmRestTemp: Double?
    public var appliedPercent: Double
    public var appliedPercents: [Double]
    public var onBattery: Bool
    public var batteryOverride: Bool
    public var nightOverride: Bool
    public var envTemp: Double?
    public var controlReason: ControlReason?
    public var aiIntent: AIIntent?
    public var curveTargetPercent: Double?
    public var learningRecently: Bool
    public var learnedSamples: Int
    public var hardwareProfile: HardwareProfile?
    public var calibrating: Bool
    public var learnMap: [ThermalLearn.LearnedPoint]
    public var decisionTrace: DecisionTrace?
    public var targetUnreachable: Bool
    public var aiHighEffort: Bool
    /// nil = 旧 daemon 未下发；调用方应保留已有值，不要清零。
    public var learnedPoints: Int?
    public var currentLoopInterval: Double?
    public var controlFault: Bool
    public var faultReason: ControlFaultReason?
    public var aiTargetEffective: Double?
    public var palmComp: Double?
    public var systemPower: Double?
    public var fans: [FanState]
    /// 整数温度桶是否变化（决定面板数字是否走 0.25s 动画）。
    public var changed: Bool
}

/// 把 daemon 的 status 映射成 App 展示值；毛刺剔除状态由本对象持有。
/// 映射与消毒此前散在 FanModel.refreshFromStatus 的 50 行闭包里，无法被测试编译到。
public struct StatusProjector {
    private var lastCpu = 0.0
    private var lastGpu = 0.0
    private var glitchHoldCPU = 0
    private var glitchHoldGPU = 0
    private var zeroHoldCPU = 0
    private var zeroHoldGPU = 0

    public init() {}

    public mutating func project(_ status: DaemonStatus) -> StatusProjection {
        let sensors = status.sensors
        let newCpu = deglitchTemperature(StatusDefense.temperature(sensors.cpuDie),
                                         prev: lastCpu,
                                         glitchHold: &glitchHoldCPU,
                                         zeroHold: &zeroHoldCPU)
        let newGpu = deglitchTemperature(StatusDefense.temperature(sensors.gpuDie),
                                         prev: lastGpu,
                                         glitchHold: &glitchHoldGPU,
                                         zeroHold: &zeroHoldGPU)
        let changed = Int(max(newCpu, newGpu)) != Int(max(lastCpu, lastGpu))
        lastCpu = newCpu
        lastGpu = newGpu

        let applied = StatusDefense.percent(status.appliedPercent)
        return StatusProjection(
            cpuTemp: newCpu,
            cpuAverageTemp: StatusDefense.temperatureReading(sensors.cpuAverage),
            gpuTemp: newGpu,
            ssdTemp: StatusDefense.temperatureReading(sensors.ssd),
            palmRestTemp: StatusDefense.temperatureReading(sensors.palmRest),
            appliedPercent: applied,
            appliedPercents: StatusDefense.appliedPercents(status.appliedPercents,
                                                           fallback: applied),
            onBattery: status.onBattery ?? false,
            batteryOverride: status.batteryOverride ?? false,
            nightOverride: status.nightOverride ?? false,
            envTemp: StatusDefense.environmentTemperature(status.envTemp),
            controlReason: status.reason,
            aiIntent: status.aiIntent,
            curveTargetPercent: status.curveTargetPercent,
            learningRecently: status.learningRecently ?? false,
            learnedSamples: status.learnedSamples ?? 0,
            hardwareProfile: status.hardwareProfile,
            calibrating: status.calibrating ?? false,
            learnMap: StatusDefense.learnedPoints(status.learnMap ?? []),
            decisionTrace: status.decisionTrace?.sanitized(),
            targetUnreachable: status.targetUnreachable ?? false,
            aiHighEffort: status.aiHighEffort ?? false,
            learnedPoints: status.learnedPoints,
            currentLoopInterval: status.loopInterval,
            controlFault: status.controlFault ?? false,
            faultReason: status.faultReason,
            aiTargetEffective: StatusDefense.aiTarget(status.aiTargetEffective),
            palmComp: StatusDefense.palmCompensation(status.palmComp),
            systemPower: StatusDefense.powerWatts(status.powerWatts),
            fans: StatusDefense.fanStates(from: status.fans),
            changed: changed)
    }
}
