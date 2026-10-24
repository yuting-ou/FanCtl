import Foundation
import SMCCore

/// App 用户意图 → config.json 的单一构造入口。
/// 这些"只有窗口生效时才写对应字段"的规则散落时很难被测试，现在收敛成纯函数：
/// 静音截止与封顶同生共死、电池/夜间曲线只在开关打开时下发、零偏移不落盘。
public enum FanConfigIntent {
    public static func make(
        mode: FanMode,
        manualPercent: Double,
        curve: [CurvePoint],
        preset: CurvePreset,
        batterySaver: Bool,
        quietCurve: [CurvePoint],
        quietUntil: Date?,
        quietCapPercent: Double,
        aiTargetTemp: Double,
        fanOffsets: [Double],
        boostUntil: Date?,
        envCompensation: Bool,
        quietHours: Bool,
        nightCurve: [CurvePoint],
        envTempOverride: Double?,
        palmCompensation: Bool
    ) -> FanConfig {
        FanConfig(mode: mode,
                  manualPercent: manualPercent,
                  curve: curve,
                  preset: preset,
                  batteryPreset: batterySaver ? .quiet : nil,
                  batteryCurve: batterySaver ? quietCurve : nil,
                  quietUntil: quietUntil,
                  quietCapPercent: quietUntil != nil ? quietCapPercent : nil,
                  aiTargetTemp: aiTargetTemp,
                  fanOffsets: fanOffsets.allSatisfy { $0 == 0 } ? nil : fanOffsets,
                  boostUntil: boostUntil,
                  envCompensation: envCompensation,
                  quietHours: quietHours,
                  nightCurve: quietHours ? nightCurve : nil,
                  envTempOverride: envTempOverride,
                  palmCompensation: palmCompensation)
    }

    /// 风扇偏移的单一钳位真值 ±20%（R89 收口：此前 max(-20, min(20,)) 在 FanModel 的
    /// init / syncConfigFromDisk / setFanOffset 三处各写一份，改限要改三处）。
    public static func clampOffset(_ v: Double) -> Double {
        max(-20, min(20, v))
    }
}
