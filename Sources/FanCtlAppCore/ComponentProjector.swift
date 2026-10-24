import Foundation
import SMCCore

/// 部件温度行的投影（R89 从 FanModel.syncPanelDataFromSensors 下沉）。
///
/// 与主卡 StatusProjector 同一份 deglitch 纪律（SMCCore.deglitchTemperature 纯函数）：
/// status.json 原子写瞬间个别读会截断（实测 cpuDie 8.4° vs 环境 30.5° 的坏读曾连发
/// 45 拍），主卡有防、最热列表没有 → 同份数据两个视图两种防线（R82 续七的教训）。
/// 逐部件独立 hold 计数（deglitchTemperature 的参数化惯例）；行消失时该部件状态清零。
public struct ComponentProjector {

    /// 部件温度显示模型（从 daemon 传来的传感器数据转换；按温度降序展示）。
    public struct ComponentTempDisplay: Identifiable, Equatable {
        public let id: String
        public let temp: Double
        public init(id: String, temp: Double) {
            self.id = id
            self.temp = temp
        }
    }

    /// 逐部件 deglitch 状态：glitch/zero 连续挡拍数 + 上一拍有效值
    private var holds: [String: (glitch: Int, zero: Int, prev: Double)] = [:]

    public init() {}

    /// 组装部件温度列表：坏读数经 deglitch（≤1 或骤降>30° 挡 3 拍），仍无效则该行
    /// 消失（原语义：传感器失效时不展示 0° 行）。
    public mutating func project(_ sensors: SensorReadings) -> [ComponentTempDisplay] {
        var comps: [ComponentTempDisplay] = []
        func add(_ id: String, _ raw: Double?) {
            guard let raw, raw.isFinite else { holds[id] = nil; return }
            var g = holds[id] ?? (0, 0, raw)
            let shown = deglitchTemperature(StatusDefense.temperature(raw), prev: g.prev,
                                            glitchHold: &g.glitch, zeroHold: &g.zero)
            guard shown > 1 else { holds[id] = nil; return }
            holds[id] = (g.glitch, g.zero, shown)
            comps.append(ComponentTempDisplay(id: id, temp: shown))
        }
        add("CPU", sensors.cpuDie)
        add("GPU", sensors.gpuDie)
        add("SSD", sensors.ssd)
        add("掌托", sensors.palmRest)
        add("散热片", sensors.heatsink)
        return comps.sorted { $0.temp > $1.temp }
    }
}
