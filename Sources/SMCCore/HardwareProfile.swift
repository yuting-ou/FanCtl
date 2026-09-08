import Foundation

/// v3.8 硬件画像（N=1 通用化第一块砖）：首次接触陌生机器时，issue 里最先需要的
/// 事实——机型、OS、芯片、风扇数、传感器计数、有无功耗键。全部是"读一次就定"的
/// 慢变量（进程生命周期内不变），随 status.json 下发 + fanprobe 打印。
/// 注意边界：画像只描述机器，不含学习数据——学习数据是机器特异的，移植即污染
///（EVOLUTION 策略元经验：硬件问题不是算法问题，先分清这台机器长什么样）。
public struct HardwareProfile: Codable, Equatable {
    public var modelID: String?          // sysctl hw.model（如 Mac16,7）；拿不到为 nil
    public var chipName: String?         // sysctl machdep.cpu.brand_string
    public var osVersion: String?        // e.g. "26.1.0"
    public var fanCount: Int
    public var sensorCounts: SensorCountSummary
    public var hasPowerKey: Bool         // 整机功耗键（PSTR/PDTR）存在性——决定功耗前馈可用
    public var collectedAt: Date

    public struct SensorCountSummary: Codable, Equatable {
        public var cpu: Int, gpu: Int, nand: Int, batt: Int, palm: Int, heatsink: Int, other: Int
        public init(cpu: Int, gpu: Int, nand: Int, batt: Int, palm: Int, heatsink: Int, other: Int) {
            self.cpu = cpu; self.gpu = gpu; self.nand = nand; self.batt = batt
            self.palm = palm; self.heatsink = heatsink; self.other = other
        }
    }

    public init(modelID: String?, chipName: String?, osVersion: String?,
                fanCount: Int, sensorCounts: SensorCountSummary,
                hasPowerKey: Bool, collectedAt: Date) {
        self.modelID = modelID; self.chipName = chipName; self.osVersion = osVersion
        self.fanCount = fanCount; self.sensorCounts = sensorCounts
        self.hasPowerKey = hasPowerKey; self.collectedAt = collectedAt
    }

    // MARK: - sysctl 只读采集（静态函数便于测试时了解实现，不 mock 系统本身）

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// 真实采集入口。任何单源失败只降级该字段（nil / false / 0），画像整体照常
    /// 产出——诊断价值优先于完备性。时钟由调用方注入（P7：生产传 hooks.now()）。
    public static func collect(fans: FanController, sensors: TemperatureSensors,
                               now: Date) -> HardwareProfile {
        let counts = sensors.sensorCounts
        return HardwareProfile(
            modelID: sysctlString("hw.model"),
            chipName: sysctlString("machdep.cpu.brand_string"),
            osVersion: sysctlString("kern.osproductversion"),
            fanCount: fans.fanCount,
            sensorCounts: SensorCountSummary(cpu: counts.cpu, gpu: counts.gpu, nand: counts.nand,
                                             batt: counts.batt, palm: counts.palm,
                                             heatsink: counts.heatsink, other: counts.other),
            hasPowerKey: sensors.hasPowerKey,
            collectedAt: now)
    }

    /// 一行摘要（fanprobe / 日志友好）
    public var oneLine: String {
        let model = modelID ?? "?"
        let chip = chipName ?? "?"
        return "\(model) / \(chip) / macOS \(osVersion ?? "?") / 风扇x\(fanCount)"
            + " / 功耗键\(hasPowerKey ? "有" : "无")"
            + " / 传感器 CPU\(sensorCounts.cpu) GPU\(sensorCounts.gpu) SSD\(sensorCounts.nand)"
            + " 电池\(sensorCounts.batt) 掌托\(sensorCounts.palm) 散热片\(sensorCounts.heatsink) 其他\(sensorCounts.other)"
    }

    /// 读出侧防御（垃圾 Codable 池惯例）：画像纯诊断载体，任何字段损坏/类型错配
    /// 只降级该字段，绝不拖垮整个 status.json 解码（v3.6.3 reason 枚举前向兼容同源：
    /// App 在最需要状态的时刻误判 daemon 离线是最坏路径）。数值域出界归 0，超长字符串截断。
    private enum CodingKeys: String, CodingKey {
        case modelID, chipName, osVersion, fanCount, sensorCounts, hasPowerKey, collectedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func safeStr(_ key: CodingKeys) -> String? {
            let raw: String?? = try? c.decodeIfPresent(String.self, forKey: key)
            guard let s = raw ?? nil else { return nil }
            return s.count <= 128 ? s : String(s.prefix(128))
        }
        self.modelID = safeStr(.modelID)
        self.chipName = safeStr(.chipName)
        self.osVersion = safeStr(.osVersion)
        let rawFan: Int?? = try? c.decodeIfPresent(Int.self, forKey: .fanCount)
        let fan = (rawFan ?? nil) ?? 0
        self.fanCount = (fan >= 0 && fan <= 100) ? fan : 0
        let rawCounts: SensorCountSummary?? =
            try? c.decodeIfPresent(SensorCountSummary.self, forKey: .sensorCounts)
        self.sensorCounts = (rawCounts ?? nil)
            ?? SensorCountSummary(cpu: 0, gpu: 0, nand: 0, batt: 0, palm: 0, heatsink: 0, other: 0)
        let rawPower: Bool?? = try? c.decodeIfPresent(Bool.self, forKey: .hasPowerKey)
        self.hasPowerKey = (rawPower ?? nil) ?? false
        let rawDate: Date?? = try? c.decodeIfPresent(Date.self, forKey: .collectedAt)
        self.collectedAt = (rawDate ?? nil) ?? Date(timeIntervalSince1970: 0)
    }
}
