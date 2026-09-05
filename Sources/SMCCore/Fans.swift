import Foundation

// MARK: - 风扇控制
// Apple Silicon 风扇键：
//   FNum       风扇数量 (ui8)
//   F{n}Ac     当前转速 (flt, RPM)
//   F{n}Mn     最低转速 (flt)
//   F{n}Mx     最高转速 (flt)
//   F{n}Tg     目标转速 (flt)
//   F{n}Md     模式 (ui8): 0=系统自动, 1=强制手动
// Intel 老平台没有 F{n}Md，用 FS! 位掩码 (ui16) 切换手动模式。

public struct FanState {
    public let id: Int
    public let actualRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double

    public init(id: Int, actualRPM: Double, minRPM: Double, maxRPM: Double, targetRPM: Double) {
        self.id = id
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
    }
}

public final class FanController {
    private let smc: SMCIO
    public let fanCount: Int
    private let hasModeKey: Bool  // F0Md 存在 → Apple Silicon 风格
    // v3.4.1 Mn/Mx 静态缓存（硬件常量；唤醒时由 ControlEngine.wake 调 invalidateFanLimits，
    // rescanAllSensors 是 TemperatureSensors 的方法触达不到这里——引擎层接线更干净）
    var cachedFanLimits: [Int: (min: Double, max: Double)] = [:]

    /// 清空风扇 Mn/Mx 静态缓存（唤醒/固件异常防御时调用）
    public func invalidateFanLimits() {
        cachedFanLimits.removeAll()
    }

    public init(smc: SMCIO) throws {
        self.smc = smc
        let fnum = (try? smc.readDouble("FNum")) ?? 0
        // 防御 NaN/Inf/超大值导致 Int() trap：
        // - NaN/Inf: isFinite 守卫拦截
        // - 1e20 等超大有限值: 先 min(fnum, 100) 钳位再转 Int
        // - 负值/零: > 0 守卫拦截
        self.fanCount = (fnum.isFinite && fnum > 0) ? Int(min(fnum, 100)) : 0
        self.hasModeKey = smc.keyExists("F0Md")
    }

    // 严格读取：任一键失败即抛错。此前用 try? + ?? 0 兜底，state(of:) 永不抛错，
    // 导致 allStates() 恒返回全部风扇、fanctld 的 fanStates.isEmpty 安全网成为死代码；
    // 且 Mn/Mx 读失败(0) 时 rpm(forPercent:) 恒为 0，会把 92°C 兜底的 100% 也写成 Tg=0，
    // 散热红线被静默击穿。严格化后失败风扇被 allStates 跳过，daemon 走写入失败路径上报。
    public func state(of fan: Int) throws -> FanState {
        // Ac/Tg 每拍新鲜读（转速与目标是控制反馈）；Mn/Mx 走静态缓存
        let limits: (min: Double, max: Double)
        if let c = cachedFanLimits[fan] {
            limits = c
        } else {
            limits = (try smc.readDouble("F\(fan)Mn"), try smc.readDouble("F\(fan)Mx"))
            // 防御：Mn/Mx 无效（读失败兜 0 / 固件异常）不缓存，下次重读
            if limits.max > limits.min, limits.max > 0, limits.min >= 0 {
                cachedFanLimits[fan] = limits
            }
        }
        return FanState(id: fan,
                 actualRPM: try smc.readDouble("F\(fan)Ac"),
                 minRPM: limits.min,
                 maxRPM: limits.max,
                 targetRPM: try smc.readDouble("F\(fan)Tg"))
    }

    public func allStates() -> [FanState] {
        (0..<fanCount).compactMap { id in
            guard let st = try? state(of: id) else { return nil }
            return st
        }
    }

    // 强制指定转速（需要 root）
    public func setForcedRPM(fan: Int, rpm: Double) throws {
        try setForcedRPM(state: try state(of: fan), rpm: rpm)
    }

    // 用已读取的 FanState 写入目标转速（不再重读 SMC，给主循环复用）
    public func setForcedRPM(state st: FanState, rpm: Double) throws {
        // 防御：min/max 无效（读失败返回 0）时禁止写入——否则任意百分比映射为 0，
        // 会把 92°C 兜底的 100% 也写成 Tg=0（风扇停转），安全红线被静默击穿。
        // 调用方（daemon 写入循环）捕获此错误后走 writeHealth 故障路径。
        guard st.maxRPM > st.minRPM, st.maxRPM > 0, st.minRPM >= 0 else {
            throw SMCError.smcResult("F\(st.id)Mx", 0xFD)
        }
        let clamped = max(st.minRPM, min(st.maxRPM, rpm))
        if hasModeKey {
            try smc.writeDouble("F\(st.id)Md", value: 1)
            try smc.writeDouble("F\(st.id)Tg", value: clamped)
        } else {
            // Intel: 置 FS! 对应位后写 F{n}Tg
            // 读取失败时不能默认 0，否则会清除其他风扇的强制位
            // v3.6.1：id ≥ 16 时 1 << id 溢出 UInt16——强制位静默写丢（set）或
            // UInt16(65536) runtime trap（restore，root 崩溃循环）。SMC FS! 只有 16 位
            guard st.id < 16 else {
                throw SMCError.smcResult("FS! ", 0xFE)
            }
            guard let raw = try? smc.readDouble("FS! ") else {
                throw SMCError.keyNotFound("FS! ")
            }
            // 防御：SMC 损坏/异常固件可能返回负值或 ≥65536，UInt16() 对越界值
            // precondition trap 会使 root daemon 崩溃（其余 SMC 数值路径都有显式钳位）
            let mask = raw.isFinite ? max(0, min(65535, raw)) : 0
            try smc.writeDouble("FS! ", value: Double(UInt16(mask) | (1 << st.id)))
            try smc.writeDouble("F\(st.id)Tg", value: clamped)
        }
    }

    // 交还系统自动调度（需要 root）
    public func restoreAuto(fan: Int) throws {
        if hasModeKey {
            try smc.writeDouble("F\(fan)Md", value: 0)
        } else {
            // v3.6.1：同 setForcedRPM——fan ≥ 16 时 UInt16(1 << fan) runtime trap
            guard fan < 16 else {
                throw SMCError.smcResult("FS! ", 0xFE)
            }
            guard let raw = try? smc.readDouble("FS! ") else {
                throw SMCError.keyNotFound("FS! ")
            }
            let mask = raw.isFinite ? max(0, min(65535, raw)) : 0
            try smc.writeDouble("FS! ", value: Double(UInt16(mask) & ~UInt16(1 << fan)))
        }
    }

    public func restoreAutoAll() {
        for i in 0..<fanCount {
            try? restoreAuto(fan: i)
        }
    }

    // 百分比 → RPM（0% = 最低转速，100% = 最高转速）
    public func rpm(forPercent pct: Double, fan: Int) throws -> Double {
        rpm(forPercent: pct, state: try state(of: fan))
    }

    // 用已读取的 FanState 计算 RPM（纯计算，不读 SMC）
    public func rpm(forPercent pct: Double, state st: FanState) -> Double {
        let p = max(0, min(100, pct)) / 100.0
        return st.minRPM + p * (st.maxRPM - st.minRPM)
    }

    // 批量设置所有风扇的强制百分比（支持独立偏移后每个风扇百分比不同）
    // percents 数组按风扇索引对应，数量不足时用第一个值填充
    public func setForcedPercentsAll(_ percents: [Double], states: [FanState]) throws {
        for (i, st) in states.enumerated() {
            let pct = i < percents.count ? percents[i] : (percents.first ?? 50)
            let rpm = self.rpm(forPercent: pct, state: st)
            try setForcedRPM(state: st, rpm: rpm)
        }
    }

    // 计算所有风扇的 RPM（给 setForcedPercentsAll 复用，避免重复读状态）
    public func rpms(forPercents percents: [Double], states: [FanState]) -> [Double] {
        states.enumerated().map { i, st in
            let pct = i < percents.count ? percents[i] : (percents.first ?? 50)
            return rpm(forPercent: pct, state: st)
        }
    }
}

// MARK: - 写入健康（控制闭环执行链可观测性）

// 连续 SMC 写入失败 = 调速闭环失效（daemon 以为在控制、风扇实际归系统管），
// 是最危险的静默故障。连续失败超阈值置 fault：daemon 交还自动并上报 status，
// App 据此告警；一次成功写入即清除。
public struct WriteHealth: Equatable {
    public static let faultThreshold = 5
    public private(set) var consecutiveFailures = 0
    public private(set) var faulted = false

    public init() {}

    public mutating func record(loopSuccess: Bool) {
        if loopSuccess {
            consecutiveFailures = 0
            faulted = false
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= Self.faultThreshold { faulted = true }
        }
    }
}

// 写入成功后仍需验证风扇实际 RPM 是否跟上目标，避免“SMC 接受写入但风扇未响应”的静默故障。
// v8 修复：
//   1. 升速宽限：目标正在上升（刚下令提速）时风扇物理爬升需 1-3s，滞后是预期而非故障，
//      该风扇不计入 mismatch——否则高温兜底/SSD 危急的瞬时全速（LOOP_INTERVAL_MIN=1s，
//      爬升 >5 拍）会被误判"闭环失效"，UI 报假故障且阻塞学习采样。
//   2. 故障锁存：faulted 后需连续 recoverThreshold 拍"匹配或无命令"才解除。此前单拍无命令
//      （restoreAutoAll 清空 lastWrittenRPM）即清零 fault，daemon 下一拍 mustReassert 立即
//      重新写回，形成"交还→夺回"每 ~6 拍一轮的振荡，Md 翻转还打断 EC 升速斜坡自我延长。
public struct FanFeedbackHealth: Equatable {
    public static let faultThreshold = 5
    public static let recoverThreshold = 3      // 故障后连续匹配拍数，达到才解除
    public private(set) var consecutiveFailures = 0
    public private(set) var faulted = false
    private var recoverCount = 0
    private var lastCommanded: [Int: Double] = [:]
    // v2.6.2 启动宽限：daemon 重启后首拍 lastCommanded 为空，升速宽限失效，
    // 从 auto 接管到新目标时风扇爬升会被误判故障——首拍只记录命令不计数
    private var warmedUp = false

    public init() {}

    public mutating func record(states: [FanState], commandedRPM: [Int: Double],
                                risingGrace: Bool = true) {
        if !warmedUp {
            warmedUp = true
            for st in states {
                if let cmd = commandedRPM[st.id] { lastCommanded[st.id] = cmd }
            }
            return
        }
        var mismatch = false
        for st in states {
            guard let target = commandedRPM[st.id] else { continue }
            guard target > st.minRPM + 150 else { continue }
            let stalled = st.actualRPM < 100
            if stalled {
                mismatch = true
                continue
            }
            let lagging = abs(st.actualRPM - target) > max(300, target * 0.35)
            if lagging {
                // 升速宽限：本拍目标高于上拍 → 风扇在物理追赶中，滞后不判故障。
                // daemon 的故障试探验证期传 risingGrace: false——probe 目标通常高于
                // 旧值，若仍宽限则验证永远"通过"，探测不到真实故障
                let rising = risingGrace && (lastCommanded[st.id].map { target > $0 + 50 } ?? false)
                if !rising { mismatch = true }
            }
        }
        // 记录本拍命令（无命令的交还期保留旧值，重新接管时首拍目标高于旧值会走宽限）
        for st in states {
            if let cmd = commandedRPM[st.id] { lastCommanded[st.id] = cmd }
        }
        if mismatch {
            consecutiveFailures += 1
            recoverCount = 0
            if consecutiveFailures >= Self.faultThreshold { faulted = true }
        } else if faulted {
            // 锁存：交还（无命令）或匹配都算恢复进度，连续达标才解除，
            // 避免"交还→单拍即恢复→立即夺回"的振荡
            recoverCount += 1
            if recoverCount >= Self.recoverThreshold {
                faulted = false
                consecutiveFailures = 0
                recoverCount = 0
            }
        } else {
            consecutiveFailures = 0
        }
    }
    /// 仅更新命令基线（fastConfigApply 拍专用，不计 mismatch）：
    /// 拖动滑块时 App 每秒可写十余次 config，30ms 防抖后连发 fast apply 拍——
    /// shape/slew 的 6-8%/拍 限速是"每次调用"语义，数百 ms 内目标即可走完全程，
    /// 而实际 RPM 物理回落需 1-3s。若在 fast 拍上照常计 mismatch，快速下拖会
    /// 稳定触发"闭环失效"误判（连续 5 拍 → 交还+试探循环）。命令基线仍需更新
    /// （升速宽限的 rising 判定依赖 lastCommanded），跟随评估交给 2s 后的正常拍。
    public mutating func recordCommandOnly(states: [FanState], commandedRPM: [Int: Double]) {
        for st in states {
            if let cmd = commandedRPM[st.id] { lastCommanded[st.id] = cmd }
        }
    }
}

// MARK: - 温度传感器
// Apple Silicon 的温度键不固定（随芯片代际变化），启动时扫描全部键：
//   Tp** → CPU 核心温度 (flt)
//   Tg** → GPU 温度 (flt)
//   TH** → NAND/SSD 温度 (flt)
//   TB** → 电池温度 (flt)
// 取有效范围内 (1~120°C) 的最大值作为热点温度。

public final class TemperatureSensors {
    private let smc: SMCIO
    /// SMC 读计数（非原子、仅供测试在单线程下观测缓存效果；生产无读者零成本）
    public private(set) var smcReadCount = 0
    // 测试注入时钟：TTL 缓存（电池控制缓存/展示缓存）基于真实时间在快节奏测试里
    // 永不过期——生产保持 { Date() }，测试注入 FakeClock 与被测时间轴同步
    public var clock: () -> Date = { Date() }
    private var cpuKeys: [String]
    private var gpuKeys: [String]
    private var nandKeys: [String]
    private var battKeys: [String]
    private var palmRestKeys: [String]  // 掌托/键盘附近（体感温度）
    private var heatsinkKeys: [String]  // 散热片/风道
    private var otherHotKeys: [String]  // 其他未归类但温度较高的传感器
    private let powerKey: String?   // 整机功耗键（PSTR=系统总功率，部分机型无）
    private var lastScanTime: Date = .distantPast
    private let scanInterval: TimeInterval = 300  // 5 分钟重扫一次，应对休眠唤醒/动态变化

    // 热点追踪：每拍只读每个分类最热的 N 个键（而非全量遍历），
    // 距上次全量扫描超过重扫间隔时重扫（发现迁移到未追踪键的新热点）。
    // 物理依据：CPU/GPU 核心热时间常数 1-5s，top-4 足以覆盖突变。
    // v3.4.5（1B）：删除"追踪键 ≥65° 就全扫"分支——持续负载下该条件每拍恒真，
    // 54 键整组每拍全扫（~324 读/分），15s 重扫间隔在热态形同虚设。
    // 热态改为"top-N 追踪 + 5s 短重扫"：热态每拍 4 读，迁移热点 ≤5s 内被发现
    // （相对 92° 兜底与 1-5s 热时间常数，5s 发现延迟安全）。
    private struct HotspotTrack {
        var topKeys: [String] = []   // 上轮扫描最热的至多 N 个键（按热度降序）
        var values: [Double] = []    // 对应的最近读数
        var lastFullScan: Date = .distantPast
        var lastAverage: Double = 0  // 上次全扫所有有效传感器的平均值（全扫时更新，快速路径沿用）
    }
    private var cpuTrack = HotspotTrack()
    private var gpuTrack = HotspotTrack()
    private var nandTrack = HotspotTrack()
    private let hotspotRescanInterval: TimeInterval = 15      // 冷态全扫间隔
    private let hotspotHotRescanInterval: TimeInterval = 5    // 热态（追踪键≥65°）全扫间隔
    private let hotspotRescanTemp = 65.0
    private let hotspotTrackCount = 4

    // 展示类传感器（掌托/散热片/其他热点）不参与控制决策，缓存 10s 读取一次即可，
    // 避免每拍遍历所有非关键传感器
    private var cachedPalmRest: (value: Double, time: Date) = (0, .distantPast)
    private var cachedHeatsink: (value: Double, time: Date) = (0, .distantPast)
    private var cachedOtherHotspots: ([String: Double], Date) = ([:], .distantPast)
    private var cachedOtherMax: (value: Double, time: Date) = (0, .distantPast)   // v3.4.1 otherHotspotMax 缓存
    /// otherHotKeys 全量读轮次计数（测试观测缓存效果；生产无读者）
    public private(set) var otherMaxScanCount = 0
    private var cachedBattery: (value: Double, time: Date) = (0, .distantPast)   // 控制输入级短缓存（电池托底+环境代理同源）
    private let displayCacheTTL: TimeInterval = 10
    private let controlCacheTTL: TimeInterval = 3

    // 环境谷值追踪（抗热浸泡内生性）：电池/掌托是底盘温度，随负载热浸泡上升——
    // 直接取瞬时"有效低值"会把负载误当室温，重载时环境补偿退化成"负载补偿"
    // （目标被无谓放宽，与室温无关）。物理依据：底盘只有在接近空闲时才趋近室温，
    // 因此环境估计取"长窗口最低值"：候选下探立即跟随；上漂以极慢泄漏速率
    // （0.5°C/小时，对应天气级室温变化）跟随——负载的小时级热浸泡不抬高谷值。
    private var ambientValley: Double = 0
    private var ambientValleyAt: Date = .distantPast          // 谷值上次更新（泄漏速率积分用）
    private var lastAmbientCandidateAt: Date = .distantPast   // 最近一次有效候选（长时间无候选才重置）
    private let ambientRisePerSec = 0.5 / 3600.0

    public init(smc: SMCIO) throws {
        self.smc = smc
        self.cpuKeys = []
        self.gpuKeys = []
        self.nandKeys = []
        self.battKeys = []
        self.palmRestKeys = []
        self.heatsinkKeys = []
        self.otherHotKeys = []
        self.powerKey = ["PSTR", "PDTR"].first { smc.keyExists($0) }
        rescanAllSensorsBlocking()   // 首扫必须同步：后续读取依赖分类结果
    }

    // 重新扫描所有传感器（定期调用，或唤醒后调用）
    // v3.4.1 DoD-8：rescan 拆拍化。同步版（rescanAllSensorsBlocking）保留给
    // 初始化路径（首扫必须同步——后续读取依赖分类结果）；周期重扫/唤醒走
    // rescanAllSensors()：后台队列执行，完成后主队列原子替换分类。
    // 削峰原理：~110 键 × 每键 2 次 IOKit 往返（枚举+验证读）≈ 1-2s 主队列阻塞，
    // 每周期重扫都在控制环中间插进 2s 停顿；后台化后主队列零阻塞。
    // 线程安全：分类数组替换回主队列（daemon 全局状态本就主队列约定）。
    private let rescanQueue = DispatchQueue(label: "fanctld.rescan", qos: .utility)
    private var rescanInFlight = false
    private var rescanRequestedAt: Date = .distantPast

    /// 周期/唤醒重扫：后台化（首扫用 rescanAllSensorsBlocking）
    public func rescanAllSensors() {
        if rescanInFlight { return }
        rescanInFlight = true
        rescanRequestedAt = clock()
        let capturedClock = clock
        rescanQueue.async { [weak self] in
            guard let self else { return }
            self.rescanAllSensorsBlocking(clockOverride: capturedClock)
            DispatchQueue.main.async { [weak self] in
                self?.rescanInFlight = false
            }
        }
    }

    /// 同步全量扫描（初始化 / 测试 / 后台队列内部使用）
    ///
    /// v3.4.5 竞态修复：本函数从后台队列（rescanAllSensors）调用时，此前直接在
    /// 后台线程写 self.cpuKeys/cpuTrack/cached* 等值类型字段——与主队列控制拍的
    /// trackedMax(&cpuTrack)/cachedMax(&cachedPalmRest) 排他访问并发 → 段错误
    ///（DoD-8 注释宣称"分类替换回主队列"但代码未实现）。现在后台只构建局部值，
    /// 字段替换统一回主队列原子执行（主线程调用时同步执行，init 语义不变）。
    public func rescanAllSensorsBlocking(clockOverride: (() -> Date)? = nil) {
        let now = clockOverride?() ?? clock()
        let all = (try? smc.allKeys()) ?? []
        // v3.6.1：瞬时 SMC 故障防御——allKeys() 抛错时 `?? []` 会把空结果当合法扫描，
        // 把全部分类替换为空且 lastScanTime 前移 300s：唤醒窗口 IOKit 瞬时失败一次
        // 即控制离线最长 5 分钟（所有温度读 0 → sensorUnavailable 交还系统）。
        // 空扫描直接放弃，保留旧分类与旧时间戳，下次重扫自然重试
        guard !all.isEmpty else { return }
        // 按前缀分类的辅助函数
        func floatKeys(prefixes: [String]) -> [String] {
            all.filter { k in
                prefixes.contains { k.hasPrefix($0) }
            }.filter { k in
                guard let v = try? smc.read(k), v.dataType == "flt ",
                      let d = v.doubleValue else { return false }
                return d >= 0 && d < 120
            }
        }
        // CPU/GPU/NAND/电池
        var newCpu = floatKeys(prefixes: ["Tp"])
        var newGpu = floatKeys(prefixes: ["Tg"])
        let newNand = floatKeys(prefixes: ["TH", "TS"])
        let newBatt = floatKeys(prefixes: ["TB"])

        // 掌托/键盘体感：Ts0P/Ts1P/W0PR/W0PT/TB0T 等
        let newPalm = floatKeys(prefixes: ["Ts", "W0P", "F0A"])
        // 散热片/风道：Th0p/Th1p/Tf0s/Tf1s/TA0P 等
        let newHeatsink = floatKeys(prefixes: ["Th", "Tf", "TA"])

        // 兜底：老 Intel 平台
        if newCpu.isEmpty {
            newCpu = ["TC0P", "TC0D", "TC0E", "TC0F", "TC1C", "TC2C"].filter { smc.keyExists($0) }
        }
        if newGpu.isEmpty {
            newGpu = ["TG0P", "TG0D", "TG0F"].filter { smc.keyExists($0) }
        }

        // 其他未归类但可能的温度键（T 开头 + 数字，排除已归类的前缀）
        let knownPrefixes: Set<String> = ["Tp", "Tg", "TH", "TS", "TB", "Ts", "W0P", "F0A", "Th", "Tf", "TA"]
        let newOther = all.filter { k in
            guard k.hasPrefix("T") && k.count == 4 else { return false }
            // 排除已知分类
            let prefix = String(k.prefix(2))
            if knownPrefixes.contains(prefix) { return false }
            // 必须是 flt 类型
            guard let v = try? smc.read(k), v.dataType == "flt ",
                  let d = v.doubleValue, d >= 0 && d < 120 else { return false }
            return true
        }

        func apply() {
            cpuKeys = newCpu
            gpuKeys = newGpu
            nandKeys = newNand
            battKeys = newBatt
            palmRestKeys = newPalm
            heatsinkKeys = newHeatsink
            otherHotKeys = newOther

            lastScanTime = now
            // 重置热点追踪，强制下次读取时全量扫描
            cpuTrack = HotspotTrack()
            gpuTrack = HotspotTrack()
            nandTrack = HotspotTrack()
            // 展示缓存也失效
            cachedPalmRest = (0, .distantPast)
            cachedHeatsink = (0, .distantPast)
            cachedOtherHotspots = ([:], .distantPast)
            cachedOtherMax = (0, .distantPast)
            cachedBattery = (0, .distantPast)
            let total = cpuKeys.count + gpuKeys.count + nandKeys.count + battKeys.count
                        + palmRestKeys.count + heatsinkKeys.count + otherHotKeys.count
            NSLog("fanctld: 传感器扫描完成 — CPU:\(cpuKeys.count) GPU:\(gpuKeys.count) SSD:\(nandKeys.count) 电池:\(battKeys.count) 掌托:\(palmRestKeys.count) 散热片:\(heatsinkKeys.count) 其他:\(otherHotKeys.count) 总计:\(total)")
        }
        // 主线程（init/测试主流程）→ 同步应用（init 后续读取立即依赖分类结果）；
        // 后台队列（rescanAllSensors 周期重扫）→ 回主队列原子替换，消除与控制拍
        // inout 访问的排他性冲突（真数据竞态，段错误根因）
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.sync { apply() }
        }
    }

    // 注意：checkRescan 不能在有 inout 参数激活的方法内部调用。
    // rescanAllSensors() 会写入 cachedPalmRest/cpuTrack 等属性，
    // 若这些属性正被 inout 访问（如 cachedMax(&cachedPalmRest)），
    // 会触发 Swift 排他性冲突导致 daemon 崩溃。
    // 因此 checkRescan 只在无 inout 激活的入口点调用。
    private func checkRescan() {
        if clock().timeIntervalSince(lastScanTime) > scanInterval {
            rescanAllSensors()
        }
    }

    // 全量扫描一组键，返回有效读数及对应键（按温度降序）
    private func fullScan(_ keys: [String]) -> [(key: String, temp: Double)] {
        var results: [(String, Double)] = []
        for k in keys {
            if let v = try? smc.readDouble(k), v > 1, v < 120 {
                results.append((k, v))
            }
        }
        return results.sorted { $0.1 > $1.1 }
    }

    // 热点追踪读取：常规拍只读 top-N 热键；按上次全扫时的温度档位选择重扫间隔
    // （热态 5s / 冷态 15s），确保负载迁移到未追踪键的新热点能被发现。
    // 注意：调用方必须在 inout 激活前调用 checkRescan()
    private func trackedMax(_ keys: [String], track: inout HotspotTrack) -> Double {
        guard !keys.isEmpty else { return 0 }
        let now = clock()
        let rescanInterval: TimeInterval =
            track.values.contains(where: { $0 >= hotspotRescanTemp })
            ? hotspotHotRescanInterval : hotspotRescanInterval
        let needFullScan = track.topKeys.isEmpty
            || now.timeIntervalSince(track.lastFullScan) > rescanInterval

        if needFullScan {
            let sorted = fullScan(keys)
            track.topKeys = Array(sorted.prefix(hotspotTrackCount).map { $0.key })
            track.values = Array(sorted.prefix(hotspotTrackCount).map { $0.temp })
            track.lastFullScan = now
            // 全扫时顺便计算平均值：sorted 已含全部有效读数（按降序排列不影响求和）
            // 快速路径无法求平均（只读 top 2），沿用上次全扫的值
            if !sorted.isEmpty {
                track.lastAverage = sorted.reduce(0.0) { $0 + $1.temp } / Double(sorted.count)
            }
            return sorted.first?.temp ?? 0
        }

        // 快速路径：只读追踪的 top 键
        var maxVal = 0.0
        var newValues: [Double] = []
        for k in track.topKeys {
            if let v = try? smc.readDouble(k), v > 1, v < 120 {
                maxVal = max(maxVal, v)
                newValues.append(v)
            } else {
                newValues.append(0)
            }
        }
        track.values = newValues
        // 追踪键全部读失败 → 下次全量重扫
        if maxVal <= 0 { track.topKeys = [] }
        return maxVal
    }

    // 无追踪的全量读取（电池等低频分类，键通常很少）
    // 注意：调用方必须在 inout 激活前调用 checkRescan()
    private func maxTemp(_ keys: [String]) -> Double {
        smcReadCount += keys.count
        var m = 0.0
        for k in keys {
            if let v = try? smc.readDouble(k), v > 1, v < 120 {
                m = max(m, v)
            }
        }
        return m
    }

    // 带 TTL 缓存的读取（TTL 可选：控制输入用短缓存，展示类用长缓存）
    private func cachedMax(_ keys: [String], cache: inout (value: Double, time: Date),
                           ttl: TimeInterval? = nil) -> Double {
        let interval = ttl ?? displayCacheTTL
        let now = clock()
        if now.timeIntervalSince(cache.time) < interval, cache.time != .distantPast {
            return cache.value
        }
        let v = maxTemp(keys)
        cache = (v, now)
        return v
    }

    public var cpuTemperature: Double { checkRescan(); return trackedMax(cpuKeys, track: &cpuTrack) }
    // CPU 核心平均温度（全扫时更新，快速路径沿用上次值）。用于 UI 对比其他软件的"核心平均"显示。
    // 控制决策仍用 cpuTemperature（热点 max），不使用此值。
    public var cpuAverageTemperature: Double { checkRescan(); _ = trackedMax(cpuKeys, track: &cpuTrack); return cpuTrack.lastAverage }
    public var gpuTemperature: Double { checkRescan(); return trackedMax(gpuKeys, track: &gpuTrack) }
    public var nandTemperature: Double { checkRescan(); return trackedMax(nandKeys, track: &nandTrack) }
    // 电池温度：3s 控制级缓存——电池托底与环境代理同读此值，每拍最多读一次
    // （电池热质量大，秒级温度变化远小于托底滞回带宽，短缓存不引入控制风险）
    public var batteryTemperature: Double { checkRescan(); return cachedMax(battKeys, cache: &cachedBattery, ttl: controlCacheTTL) }
    public var palmRestTemperature: Double { checkRescan(); return cachedMax(palmRestKeys, cache: &cachedPalmRest) }
    public var heatsinkTemperature: Double { checkRescan(); return cachedMax(heatsinkKeys, cache: &cachedHeatsink) }
    // v3.4.1：走展示缓存——otherHotKeys 可达 ~110 个键，此前每拍全量读是
    // 全项目最大的 IOKit 乘数浪费（3150 万拍/年 × 110 ≈ 35 亿次调用）。
    // otherHotspotReadings()（明细展示）本来就缓存 10s；max 用于环境谷值候选与
    // envTemp 展示，10s 语义一致。
    // v3.4.5（1A 合并回归）：两个入口共享同一次扫描——两套 10s 缓存过期时刻错开，
    // 每 10s 至多 2×110 全扫（~1320 次/分）。现在 max 与明细由同一份读数原子派生，
    // 时间戳恒等，10s 窗口内至多 1 次全扫。
    public var otherHotspotMax: Double {
        checkRescan()
        refreshOtherHotspotsIfNeeded()
        return cachedOtherMax.0
    }

    // 环境温度代理（环境补偿的输入）——谷值追踪版，语义见 ambientEstimate(now:)。
    public var envTemperature: Double? {
        ambientEstimate(now: Date())
    }

    // 环境谷值估计（now 参数化便于测试注入）。返回 nil = 环境补偿应关闭。
    // cpu 传入调用方本拍已读的芯片热点（如 rawTemp），避免重复 SMC 读；nil 则内部读取。
    // 规则：电池/掌托/散热片/其他热点中落在 (5, 45)°C 的候选取最低值；
    // 谷值 = 长窗口最低值（下探即跟随，上漂 0.5°C/h 泄漏）；候选全部贴近芯片温度
    // （热浸泡，≥ cpu−3）或持续 >1h 无候选时返回 nil（宁可关闭补偿不虚构低温）。
    public func ambientEstimate(now: Date, cpu: Double? = nil) -> Double? {
        checkRescan()
        let candidates = [batteryTemperature, palmRestTemperature,
                          heatsinkTemperature, otherHotspotMax]
            .filter { $0 > 5 && $0 < 45 }
        if candidates.isEmpty {
            // 瞬时读失败不清谷值（传感器抖动）；持续无候选超过 1h 才判代理失效
            if ambientValley > 5, now.timeIntervalSince(lastAmbientCandidateAt) < 3600 {
                return ambientValley
            }
            ambientValley = 0
            return nil
        }
        lastAmbientCandidateAt = now
        let candidate = candidates.min()!
        if ambientValley <= 5 {
            ambientValley = candidate
        } else {
            // 泄漏上漂（单次积分封顶 1h：睡眠唤醒后的超大时间差不会一拍涨满）
            if ambientValleyAt != .distantPast {
                let elapsed = min(max(now.timeIntervalSince(ambientValleyAt), 0), 3600)
                ambientValley += elapsed * ambientRisePerSec
            }
            if candidate < ambientValley { ambientValley = candidate }
        }
        ambientValleyAt = now
        let cpuValue = cpu ?? cpuTemperature
        if cpuValue > 5, ambientValley >= cpuValue - 3 { return nil }
        return ambientValley
    }

    // 其他热点明细（key→temp），只收集高于 45°C 的有意义热点（缓存 10s）
    public func otherHotspotReadings() -> [String: Double] {
        refreshOtherHotspotsIfNeeded()
        return cachedOtherHotspots.0
    }

    /// 1A 合并扫描：otherHotspotMax 与 otherHotspotReadings 的唯一数据来源。
    /// 一次遍历 otherHotKeys 同时派生 max（1..120 有效读数，与 maxTemp 语义一致）
    /// 与 >45°C 明细字典；两份缓存同时间戳写入，10s 窗口内至多一次全扫。
    /// 注意：本函数不走 checkRescan()（两个调用方语义不同），由调用方先行调用。
    private func refreshOtherHotspotsIfNeeded() {
        let now = clock()   // 注入时钟，与其它 TTL 缓存一致（测试可控）
        if now.timeIntervalSince(cachedOtherMax.1) < displayCacheTTL,
           cachedOtherMax.1 != .distantPast {
            return
        }
        smcReadCount += otherHotKeys.count
        var dict: [String: Double] = [:]
        var m = 0.0
        for k in otherHotKeys {
            guard let v = try? smc.readDouble(k), v > 1, v < 120 else { continue }
            m = max(m, v)
            if v > 45, v < 110 { dict[k] = v }
        }
        otherMaxScanCount += 1
        cachedOtherMax = (m, now)
        cachedOtherHotspots = (dict, now)
    }

    // 转换为 SMCCore.SensorReadings（供 status.json 写入）
    // 注意：控制决策（高温兜底/读失败检测）依赖原始值——读数无效必须保持 0，
    // 不能伪造兜底值（如 45°），否则 daemon 的 rawTemp≤1 安全链失效：
    // 传感器真全挂时会按虚构温度"控制"且兜底不触发。展示层兜底由 App 自行处理。
    public func sensorReadings() -> SensorReadings {
        checkRescan()
        // 一次 trackedMax 调用同时更新 max 和 lastAverage，避免重复 SMC 读
        let cpuMax = trackedMax(cpuKeys, track: &cpuTrack)
        let cpuAvg = cpuTrack.lastAverage
        // v3.4.5（2B）：GPU 读数先落本地变量——三元两侧各写一次 gpuTemperature
        // 会在 gpu ≤1°C（读失败）时对 gpuKeys 做两次全量 trackedMax 扫描
        let gpuT = gpuTemperature
        let gpu = gpuT > 1 ? gpuT : cpuMax
        let palm = palmRestTemperature > 1 ? palmRestTemperature : nil
        let hs = heatsinkTemperature > 1 ? heatsinkTemperature : nil
        // nandTemperature 同为无 TTL 的 trackedMax：先落本地防同拍双读
        let nandT = nandTemperature
        return SensorReadings(
            cpuDie: cpuMax,
            cpuAverage: cpuAvg > 0 ? cpuAvg : nil,
            gpuDie: gpu,
            ssd: nandT > 1 ? nandT : nil,
            palmRest: palm,
            heatsink: hs,
            otherHotspots: otherHotspotReadings()
        )
    }

    // 按部件归类的温度（CPU/GPU/SSD/电池/掌托/散热片），供"哪里最热"语义化展示：
    // 比裸传感器键（Tp1q 等）易读，只返回有效读数（>1°C）的部件
    public struct ComponentTemp: Identifiable {
        public let id: String       // "CPU"/"GPU"/"SSD"/"电池"/"掌托"/"散热片"
        public let temp: Double
        public init(id: String, temp: Double) { self.id = id; self.temp = temp }
    }

    public func componentTemperatures() -> [ComponentTemp] {
        [("CPU", cpuTemperature), ("GPU", gpuTemperature),
         ("SSD", nandTemperature), ("电池", batteryTemperature),
         ("掌托", palmRestTemperature), ("散热片", heatsinkTemperature)]
            .filter { $0.1 > 1 }
            .map { ComponentTemp(id: $0.0, temp: $0.1) }
            .sorted { $0.temp > $1.temp }
    }

    // 整机功耗（W）；无可用键或读数异常返回 nil（UI 隐藏）
    // v3.4.1：PSTR 走 2s 控制级缓存——同拍内统计/学习/status 多处读只付 1 次成本；
    // 跨拍时缓存已过期（拍间隔 ≥1s > 2s 只在 fast-apply 同拍复现），语义不变
    private var cachedPower: (value: Double?, time: Date) = (nil, .distantPast)

    public var systemPowerWatts: Double? {
        let now = clock()
        if now.timeIntervalSince(cachedPower.1) < 2, cachedPower.1 != .distantPast {
            return cachedPower.0
        }
        let v: Double? = {
            guard let key = powerKey, let w = try? smc.readDouble(key),
                  w > 0.1, w < 1000 else { return nil }
            return w
        }()
        cachedPower = (v, now)
        return v
    }

    public var sensorCounts: (cpu: Int, gpu: Int, nand: Int, batt: Int, palm: Int, heatsink: Int, other: Int) {
        (cpuKeys.count, gpuKeys.count, nandKeys.count, battKeys.count,
         palmRestKeys.count, heatsinkKeys.count, otherHotKeys.count)
    }

    // 当前最热的前 N 个传感器（所有分类合并），供"哪里最热"明细展示
    public struct SensorReading: Identifiable {
        public let id: String       // SMC 键名，如 Tp01
        public let kind: String     // "CPU" / "GPU" / "SSD" / "电池" / "掌托" / "散热片" / "其他"
        public let temp: Double
    }

    public func hottestSensors(count: Int = 8) -> [SensorReading] {
        checkRescan()
        var readings: [SensorReading] = []
        for (keys, kind) in [(cpuKeys, "CPU"), (gpuKeys, "GPU"),
                             (nandKeys, "SSD"), (battKeys, "电池"),
                             (palmRestKeys, "掌托"), (heatsinkKeys, "散热片"),
                             (otherHotKeys, "其他")] {
            for k in keys {
                if let v = try? smc.readDouble(k), v > 1, v < 120 {
                    readings.append(SensorReading(id: k, kind: kind, temp: v))
                }
            }
        }
        return Array(readings.sorted { $0.temp > $1.temp }.prefix(count))
    }
}
