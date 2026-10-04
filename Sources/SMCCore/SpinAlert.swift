import Foundation

/// 后台空转告警（R78）——由 `spinwatch`（独立哨兵脚本，~/bin/spinwatch）发现，
/// 写入 `~/.spinwatch/alerts.json`，清风读它并弹**带 App 图标**的通知。
///
/// 为什么必须走清风而不是脚本自己弹：`osascript display notification` 是系统通用通知，
/// 图标是 Script Editor、语气也和产品不一致；清风本来就有 UNUserNotification 通道与
/// 通知授权，用户看到的每一条提醒都应该是同一副面孔。
///
/// 分工遵循本项目既有的跨进程模式（reset-learn.flag：App 写旗标 → daemon 消费）：
/// 这里是反向 —— 哨兵（CLI，无 UI）只负责发现与写文件，清风负责提醒与操作。
///
/// 这是本项目与 Python 脚本之间**唯一的跨语言契约**，键名双端必须一致：
/// `spinwatch --emit-fixture` 产出样例，`fanctltests` 解码它并断言键集合相同
/// （见 TestsEngine 的「后台空转 schema 同源(R78)」组）。任一侧单方面改键名 → 红。
public struct SpinAlert: Codable, Equatable, Identifiable {
    public var pid: Int
    public var ppid: Int?
    public var name: String
    public var command: String?
    public var cpu: Double?             // 当前占用率（%）
    public var peak: Double?            // 本轮观察到的峰值（%）
    public var heldSeconds: Double?     // 已持续多久（秒）
    public var fdCount: Int?            // 打开的文件数；0 = 一个文件都不开（强异常信号）
    public var threads: Int?
    public var exe: String?             // 可执行文件路径（可能已不在磁盘上）
    public var exeKnown: Bool?          // false = 看不出路径（shell -c 之类），不是"文件丢了"
    public var exeOnDisk: Bool?         // false = 二进制已不在磁盘上（App 从 DMG 运行、DMG 被弹出）
    public var orphan: Bool?            // 父进程已死（被 launchd 收养）
    public var confidence: String?      // 置信度：高/中高/中/低（哨兵的措辞，透传不裁决）

    // MARK: R81 进程实例标识（结束动作的前置条件；生产端目前不提供 → 结束一律失败关闭）
    //
    // 只有 pid 不足以安全地 kill：pid 会复用。这两个字段是"还是当初那个进程"的证据，
    // 由哨兵从操作系统读取后随告警一起写出。缺失即视为不可信（见 SpinKillGuard）。
    // 注意：**不进 encode 的键集合**在字段为 nil 时保持不变——夹具与 CodingKeys 的
    // 同源门（TestsEngine「后台空转 schema 同源(R78)」）按 encode 反推键集合比对。
    public var startSeconds: Double?    // 进程启动时刻（秒，since 1970；内核报告）
    public var uid: Int?                // 进程属主 uid

    public var id: Int { pid }

    public init(pid: Int, ppid: Int? = nil, name: String, command: String? = nil,
                cpu: Double? = nil, peak: Double? = nil, heldSeconds: Double? = nil,
                fdCount: Int? = nil, threads: Int? = nil, exe: String? = nil,
                exeKnown: Bool? = nil, exeOnDisk: Bool? = nil, orphan: Bool? = nil,
                confidence: String? = nil,
                startSeconds: Double? = nil, uid: Int? = nil) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.command = command
        self.cpu = cpu; self.peak = peak; self.heldSeconds = heldSeconds
        self.fdCount = fdCount; self.threads = threads; self.exe = exe
        self.exeKnown = exeKnown; self.exeOnDisk = exeOnDisk; self.orphan = orphan
        self.confidence = confidence
        self.startSeconds = startSeconds
        self.uid = uid
    }

    // MARK: - 读出侧防御（垃圾 Codable 池惯例）

    /// 逐字段降级：任何字段损坏/类型错配只丢该字段，绝不拖垮整份解码 ——
    /// App 在最需要知道"谁在空转"的时刻整份读失败是最坏路径（同
    /// HardwareProfile 的理由）。数值域出界归 0，超长字符串截断。
    private enum CodingKeys: String, CodingKey {
        case pid, ppid, name, command, cpu, peak, heldSeconds, fdCount, threads
        case exe, exeKnown, exeOnDisk, orphan, confidence
        case startSeconds, uid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func safeStr(_ key: CodingKeys, _ limit: Int) -> String? {
            let raw: String?? = try? c.decodeIfPresent(String.self, forKey: key)
            guard let s = raw ?? nil else { return nil }
            return s.count <= limit ? s : String(s.prefix(limit))
        }
        func safeInt(_ key: CodingKeys, _ lo: Int, _ hi: Int) -> Int? {
            let raw: Int?? = try? c.decodeIfPresent(Int.self, forKey: key)
            guard let v = raw ?? nil else { return nil }
            return (v >= lo && v <= hi) ? v : nil
        }
        func safeDouble(_ key: CodingKeys, _ lo: Double, _ hi: Double) -> Double? {
            let raw: Double?? = try? c.decodeIfPresent(Double.self, forKey: key)
            guard let v = raw ?? nil, v.isFinite else { return nil }
            return (v >= lo && v <= hi) ? v : nil
        }
        func safeBool(_ key: CodingKeys) -> Bool? {
            let raw: Bool?? = try? c.decodeIfPresent(Bool.self, forKey: key)
            return raw ?? nil
        }

        // pid 是主键，必须存在且为正；缺失/非法时整条告警无意义，直接抛（调用方按坏数据处理）
        guard let pidRaw: Int?? = try? c.decodeIfPresent(Int.self, forKey: .pid),
              let pid = pidRaw ?? nil, pid > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.pid],
                                                    debugDescription: "pid 缺失或非正数"))
        }
        self.pid = pid
        self.ppid = safeInt(.ppid, 0, 10_000_000)
        self.name = safeStr(.name, 64) ?? "未知进程"
        self.command = safeStr(.command, 400)
        self.cpu = safeDouble(.cpu, 0, 10_000)
        self.peak = safeDouble(.peak, 0, 10_000)
        self.heldSeconds = safeDouble(.heldSeconds, 0, 3_652_000)   // 最多 42 天
        self.fdCount = safeInt(.fdCount, 0, 1_000_000)
        self.threads = safeInt(.threads, 0, 10_000)
        self.exe = safeStr(.exe, 400)
        self.exeKnown = safeBool(.exeKnown)
        self.exeOnDisk = safeBool(.exeOnDisk)
        self.orphan = safeBool(.orphan)
        self.confidence = safeStr(.confidence, 16)
        // R81 实例标识：缺失/坏值一律留 nil（不猜 0——0 是 root 的合法 uid）
        self.startSeconds = safeDouble(.startSeconds, 1, 4_102_444_800)   // 上界到 2100 年
        self.uid = safeInt(.uid, 0, 2_000_000)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        try c.encodeIfPresent(ppid, forKey: .ppid)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(cpu, forKey: .cpu)
        try c.encodeIfPresent(peak, forKey: .peak)
        try c.encodeIfPresent(heldSeconds, forKey: .heldSeconds)
        try c.encodeIfPresent(fdCount, forKey: .fdCount)
        try c.encodeIfPresent(threads, forKey: .threads)
        try c.encodeIfPresent(exe, forKey: .exe)
        try c.encodeIfPresent(exeKnown, forKey: .exeKnown)
        try c.encodeIfPresent(exeOnDisk, forKey: .exeOnDisk)
        try c.encodeIfPresent(orphan, forKey: .orphan)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        // 生产端没给就不写键：nil 时键集合与既有夹具完全一致（schema 同源门）
        try c.encodeIfPresent(startSeconds, forKey: .startSeconds)
        try c.encodeIfPresent(uid, forKey: .uid)
    }

    // MARK: - 展示辅助

    /// "已持续"的人话。哨兵按秒上报，App 侧统一成人可读。
    public var heldText: String {
        guard let s = heldSeconds, s > 0 else { return "刚刚" }
        let i = Int(s)
        if i < 60 { return "\(i) 秒" }
        if i < 3600 { return "\(i / 60) 分钟" }
        if i < 86400 { return "\(i / 3600) 小时" }
        return "\(i / 86400) 天"
    }

    /// 高置信度 = 哨兵判断"绝不可能在干正事"（二进制没了 / 一个文件都不开）。
    /// UI 用它决定语气：高置信度用醒目的警示色，低置信度用中性色。
    public var isHighConfidence: Bool {
        confidence == "高" || confidence == "中高"
    }

    /// 通知正文：把证据拼成人话。只放**判得准**的事实，不放推测。
    public var evidenceText: String {
        var parts: [String] = []
        if let cpu { parts.append("CPU \(Int(cpu.rounded()))%") }
        parts.append("已持续 \(heldText)")
        if let fd = fdCount, fd == 0 { parts.append("没打开任何文件") }
        if let ok = exeOnDisk, ok == false { parts.append("程序已不在磁盘上") }
        if orphan == true { parts.append("父进程已死") }
        if let c = confidence { parts.append("置信度\(c)") }
        return parts.joined(separator: " · ")
    }
}

/// 数组逐个解时用来"跳过坏元素"的占位：能吃掉任意 JSON 值（标量/数组/对象），
/// 存在意义就是把 unkeyed container 的游标推过那个坏元素，好继续解下一条。
private struct AnyJSON: Decodable {
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.singleValueContainer() else { return }
        if c.decodeNil() { return }
        // 逐个试：哪种类型解得通就消费哪种（不 ?? 链式叠加，那样类型检查器会超时）
        if (try? c.decode(Bool.self)) != nil { return }
        if (try? c.decode(Int.self)) != nil { return }
        if (try? c.decode(Double.self)) != nil { return }
        if (try? c.decode(String.self)) != nil { return }
        if (try? c.decode([AnyJSON].self)) != nil { return }
        _ = try? c.decode([String: AnyJSON].self)
    }
}

/// 告警文件（`~/.spinwatch/alerts.json`）的顶层结构。
public struct SpinReport: Codable, Equatable {
    public var schema: String?
    public var updatedAt: Date?
    public var alerts: [SpinAlert]

    public init(alerts: [SpinAlert], updatedAt: Date? = nil, schema: String? = nil) {
        self.alerts = alerts; self.updatedAt = updatedAt; self.schema = schema
    }

    /// 逐字段防御，同 SpinAlert：单字段坏只丢字段；alerts 数组**单条**坏只跳过该条，
    /// 其余照常返回 —— 一条脏数据不该让整份告警从面板上消失。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func safeStr(_ key: CodingKeys, _ limit: Int) -> String? {
            let raw: String?? = try? c.decodeIfPresent(String.self, forKey: key)
            guard let s = raw ?? nil else { return nil }
            return s.count <= limit ? s : String(s.prefix(limit))
        }
        self.schema = safeStr(.schema, 32)
        let rawDate: Date?? = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.updatedAt = rawDate ?? nil
        // 数组逐个解：坏元素跳过而不是整包失败（[SpinAlert] 整体解一损俱损）
        var parsed: [SpinAlert] = []
        if var a = try? c.nestedUnkeyedContainer(forKey: .alerts) {
            while !a.isAtEnd {
                if let ok = try? a.decode(SpinAlert.self) {
                    parsed.append(ok)
                } else {
                    _ = try? a.decode(AnyJSON.self)   // 跳过这个坏元素，继续下一个
                }
            }
        }
        self.alerts = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(schema, forKey: .schema)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encode(alerts, forKey: .alerts)
    }

    private enum CodingKeys: String, CodingKey {
        case schema, updatedAt, alerts
    }
}

/// 告警文件路径 + 测试注入点（沿用 FanCtlPaths.setOverridesForTesting 的惯例：
/// 测试不碰用户真实的 ~/.spinwatch）。
public enum SpinAlertsPath {
    private static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".spinwatch/alerts.json")
    private static var overrideURL: URL?

    public static var file: URL { overrideURL ?? defaultURL }

    /// 测试注入；传 nil 恢复默认
    public static func setOverrideForTesting(_ url: URL?) { overrideURL = url }

    /// 加载并解码。文件不存在/为空/JSON 坏/整份不可解码 → nil
    /// （"读不到"与"读到了但没告警"由 alerts 数组是否为空区分，语义不能混）。
    /// 时钟策略由调用方通过 dec 注入（P7：生产传 .iso8601，与 status.json 一致）。
    public static func load(decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()) -> SpinReport? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(SpinReport.self, from: data)
    }
}
