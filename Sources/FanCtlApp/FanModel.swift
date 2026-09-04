// FanModel —— 菜单栏 App 数据模型：
// 数据源：守护进程写的 status.json（事件驱动，DispatchSource 监听）+ config.json 用户意图
// 不再直连 SMC：所有温度/风扇/功耗/传感器数据均由 root 守护进程采集后写入共享文件，
// App 只做展示与配置写入——避免与 daemon 抢 SMC 资源，降低能效。
import Foundation
import SwiftUI
import ServiceManagement
import UserNotifications
import SMCCore

// MARK: - 环形缓冲（固定容量 O(1) 追加，消除 removeAll 线性扫描）

struct RingBuffer<T> {
    private var buffer: [T?]
    private var head = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [T?](repeating: nil, count: capacity)
    }

    mutating func append(_ element: T) {
        buffer[(head + count) % capacity] = element
        if count < capacity {
            count += 1
        } else {
            head = (head + 1) % capacity
        }
    }

    var elements: [T] {
        (0..<count).map { buffer[(head + $0) % capacity]! }
    }

    var isEmpty: Bool { count == 0 }

    mutating func removeAll() {
        head = 0; count = 0
        buffer = [T?](repeating: nil, count: capacity)
    }
}

// MARK: - 数据模型

@MainActor
final class FanModel: ObservableObject {
    @Published var cpuTemp: Double = 0
    @Published var cpuAverageTemp: Double? = nil  // CPU 核心平均（对比其他软件用，仅展示）
    @Published var gpuTemp: Double = 0
    @Published var ssdTemp: Double? = nil
    @Published var palmRestTemp: Double? = nil
    @Published var fans: [FanState] = []
    @Published var lastRefresh = Date()
    @Published var mode: FanMode = .curve
    @Published var manualPercent: Double = 50
    @Published var preset: CurvePreset = .balanced
    @Published var aiTargetTemp: Double = 76
    @Published var daemonAlive = false
    @Published var appliedPercent: Double = 0
    @Published var appliedPercents: [Double] = []     // 双风扇独立百分比
    @Published var curveTargetPercent: Double? = nil  // AI 模式下当前温度的曲线期望基准（v7 曲线锚定）
    @Published var fanOffsets: [Double] = [0, 0]       // 双风扇独立偏移
    @Published var history: [TempSample] = []
    @Published var boostEndDate: Date? = nil
    @Published var quietEndDate: Date? = nil
    let quietCapPercent: Double = 30
    @Published var systemPower: Double? = nil
    @Published var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @Published var batterySaver = false
    @Published var onBattery = false
    @Published var batteryOverride = false
    @Published var controlReason: ControlReason? = nil
    @Published var aiIntent: AIIntent? = nil
    @Published var learnedPoints = 0
    @Published var controlFault = false        // SMC 写入持续失败、调速闭环失效
    @Published var faultReason: ControlFaultReason? = nil
    @Published var learnedNow: Double? = nil   // 当前温度的经验稳态输出（学习具象化）
    @Published var learningRecently: Bool = false  // 最近 120s 内是否记录过热经验样本
    @Published var learnedSamples: Int = 0        // 累计学习样本总数
    @Published var targetUnreachable = false       // AI 目标温度压不住（持续满速+温度高于目标窗口）
    @Published var components: [ComponentTempDisplay] = []
    @Published var currentLoopInterval: Double? = nil
    @Published var topProcesses: [ProcessUsage] = []   // 高占用进程榜（"占用" tab，仅面板可见时采样）
    // daemon 实际执行模式（status.json 单一数据源）与 App 写入意图的对账：
    // 配置写入失败/权限异常时 UI 显示的模式与实际执行不一致，据此展示警示
    @Published var daemonMode: FanMode? = nil
    @Published var configMismatch = false
    @Published var configWriteFailed = false   // config.json 写入失败（权限/目录缺失），面板警示
    // v8 环境温度补偿（默认开启）与夜间安静档（22:00–8:00 自动切安静）
    @Published var envCompensation = true
    @Published var palmCompensation = false
    @Published var quietHours = false
    @Published var palmComp: Double? = nil        // daemon 下发的体感补偿量（单一数据源）
    @Published var nightOverride = false       // 夜间安静档当前是否生效（daemon 判定）
    @Published var envTemp: Double? = nil      // 环境温度代理（status 下发，展示用）
    @Published var envTempOverride: Double? = nil  // 环境温度手动覆盖（nil=自动代理）
    @Published var aiTargetEffective: Double? = nil  // daemon 实际生效的 AI 目标（环境/夜间/电池叠加后）
    @Published var aiHighEffort: Bool = false      // AI 正在全力散热（满速 ≥20s 且高于目标+2°）
    @Published var aiRecommendedTarget: Double? = nil  // AI 首次进入时基于基线温度推荐的目标

    @Published var panelVisible = false {
        didSet {
            if panelVisible && !oldValue {
                syncPanelData()  // 开面板立即同步，不等下一拍事件
                startCPUSamplingIfNeeded()  // v3.4.1：仅"占用"tab 需要 ps 采样
                // v3.0：写入失败警示的探针恢复——用户重跑 install.sh 修好权限后，
                // 开面板即重写一次配置，成功则清除警示（否则警示挂到下次改设置）
                if configWriteFailed { saveConfig() }
            } else if !panelVisible {
                stopCPUSampling()   // 面板关闭立即停止采样，避免无谓耗电
            }
        }
    }
    @Published var monitorTab = 0   // 0=趋势 1=最热 2=今日 3=占用（App 侧持有，PanelView 绑定）
    {
        didSet {
            // v3.4.1：离开/进入"占用"tab 即停/启 ps 子进程采样（DoD-5a）
            if panelVisible {
                if monitorTab == 3 { startCPUSamplingIfNeeded() } else { stopCPUSampling() }
            }
        }
    }
    // "占用"进程榜采样定时器：仅面板打开时运行，3s 一拍，关闭即停
    private var cpuSampleTimer: Timer?
    // 面板长开时只读文件数据（学习/评测/战报）的低频刷新间隔
    private var lastPanelFileSync = Date.distantPast
    /// v3.4.1：仅当面板可见且停在"占用"tab 时才启动 ps 子进程采样（DoD-5a）
    private func startCPUSamplingIfNeeded() {
        guard panelVisible, monitorTab == 3 else { return }
        cpuSampleTimer?.invalidate()
        sampleTopProcesses()
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.sampleTopProcesses() }
        }
        t.tolerance = 1.0
        cpuSampleTimer = t
    }
    private func stopCPUSampling() {
        cpuSampleTimer?.invalidate()
        cpuSampleTimer = nil
    }
    // v3.4.5（2D）：ps 采样防重入——ps 子进程若挂起，readDataToEndOfFile 会永久
    // 阻塞 detached 任务，3s 定时器继续叠加新 Task + Process（句柄无上界累积）。
    // in-flight 标志 + 4s 强制过期（3s 采样周期的兜底释放），复制 daemon 侧
    // PowerCompositionSampler 的同型防护。
    @MainActor private var psSamplingInFlight = false
    @MainActor private var psSamplingSince = Date.distantPast

    @MainActor private func sampleTopProcesses() {
        if psSamplingInFlight,
           Date().timeIntervalSince(psSamplingSince) < 4 {
            return   // 上一次采样仍在途（≤4s 强制过期兜底），跳过本拍避免堆积
        }
        psSamplingInFlight = true
        psSamplingSince = Date()
        // ps 采样涉及子进程，放后台线程执行，再切回主线程更新，避免阻塞 UI
        let owner = self
        Task.detached(priority: .utility) {
            let usage = NotificationService.sampleCPUUsage()
            await MainActor.run {
                owner.topProcesses = usage
                owner.psSamplingInFlight = false
            }
        }
    }
    private var historyBuffer = RingBuffer<TempSample>(capacity: 200)
    private var aiHighEffortSince: Date? = nil    // AI 满速开始时间（#12 预提示）
    private var aiBaselineTemps: [Double] = []    // AI 模式进入后前 30s 温度采样（#4 推荐）
    private var aiModeEnteredAt: Date? = nil      // 进入 AI 模式的时间
    @Published var stats: DailyStats? = nil
    @Published var customPoints: [CurvePoint] = CurvePreset.balanced.points

    struct TempSample: Identifiable, Codable {
        let id: Date
        let cpu: Double
        let gpu: Double
        var temp: Double { max(cpu, gpu) }
    }

    // 部件温度显示模型（从 daemon 传来的传感器数据转换）
    struct ComponentTempDisplay: Identifiable {
        let id: String
        let temp: Double
    }

    // 高占用进程（“谁在发热”面板用）
    typealias ProcessUsage = ProcessInfo

    private static let historyWindow: TimeInterval = 10 * 60

    private static let historyFile: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.fanctl.app/trend-history.json")
    }()
    private var historySaveCounter = 0

    private static func loadHistoryBuffer() -> RingBuffer<TempSample> {
        var ring = RingBuffer<TempSample>(capacity: 200)
        guard let data = try? Data(contentsOf: historyFile),
              let samples = try? JSONDecoder().decode([TempSample].self, from: data) else { return ring }
        let cutoff = Date().addingTimeInterval(-historyWindow)
        for s in samples where s.id >= cutoff { ring.append(s) }
        return ring
    }

    private func persistHistory() {
        let dir = Self.historyFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(historyBuffer.elements) {
            try? data.write(to: Self.historyFile, options: .atomic)
        }
    }
    static let boostDuration: TimeInterval = 15 * 60
    static let quietDuration: TimeInterval = 30 * 60
    static let boostEndKey = "boostEndDate"
    static let boostPrevKey = "boostPrevConfig"
    static let quietEndKey = "quietEndDate"
    private static let customCurveKey = "customCurvePoints"
    private static let aiPresetsKey = "aiPresetCurves"
    private static let aiBaselineKey = "aiBaseline"
    private static let autoOptimizeKey = "autoOptimizeEnabled"
    private static let fanOffsetsKey = "fanOffsets"
    private static let envCompensationKey = "envCompensation"
    private static let quietHoursKey = "quietHours"
    private static let palmCompensationKey = "palmCompensation"

    var config: FanConfig {
        let offsets = fanOffsets.allSatisfy { $0 == 0 } ? nil : fanOffsets
        return FanConfig(mode: mode, manualPercent: manualPercent,
                  curve: points(for: preset),
                  preset: preset,
                  batteryPreset: batterySaver ? .quiet : nil,
                  batteryCurve: batterySaver ? points(for: .quiet) : nil,
                  quietUntil: quietEndDate,
                  quietCapPercent: quietEndDate != nil ? quietCapPercent : nil,
                  aiTargetTemp: aiTargetTemp,
                  fanOffsets: offsets,
                  boostUntil: boostEndDate,
                  envCompensation: envCompensation,
                  quietHours: quietHours,
                  nightCurve: quietHours ? points(for: .quiet) : nil,
                  envTempOverride: envTempOverride,
                  palmCompensation: palmCompensation)
    }

    func points(for p: CurvePreset) -> [CurvePoint] {
        p == .custom ? customPoints : (aiPresetCurves[p] ?? p.points)
    }

    // 文件监控 Sources
    private var statusSource: DispatchSourceFileSystemObject?
    private var statusFD: Int32 = -1
    private var configSource: DispatchSourceFileSystemObject?
    private var configFD: Int32 = -1
    private var pendingSave: DispatchWorkItem?
    private var statusRefreshWorkItem: DispatchWorkItem?  // saveConfig 后主动触发 status 刷新
    var lastUserChange = Date.distantPast
    private var lastSeenConfigMTime: Date? = nil
    // v2.6.2:App 自己 saveConfig 后的 mtime——sync 时跳过自写回声,
    // 不再用 3s lastUserChange 守卫(它会吞掉窗口内的外部修改且不回试)
    private var lastOwnConfigMTime: Date? = nil
    private let notifications = NotificationService()  // #1: 通知逻辑提取到独立类
    // 毛刺剔除：status.json 原子写，个别异常读（≤1 或较上一拍骤降>30°C）多为写瞬间截断，
    // 一律沿用上一拍有效值，不采信异常值（防止 prev 被置 0 后 deglitch 失效、兜底被破坏）。
    private var lastStatusTimestamp: Date = .distantPast
    // 毛刺剔除 hold 计数：与 daemon smooth() 的 glitchMaxHold=3 对齐——
    // 连续 3 拍仍"骤降>30°C"则采信（真实大幅降温，如负载结束），
    // 此前无 hold 计数会永久钉在旧温度，菜单栏/过热通知长期失真
    // v2.6.2:CPU/GPU 独立计数（此前共享,一个传感器毛刺会消耗另一个的 hold 额度）;
    // raw<=1(daemon 传感器故障写 0)也加 hold——持续写 0 时应采信并显示故障,
    // 而不是永远沿用旧温度(旧值 ≥90° 时 checkOverheat 每 10 分钟误发高温通知)
    private var glitchHoldCPU = 0
    private var glitchHoldGPU = 0
    private var zeroHoldCPU = 0
    private var zeroHoldGPU = 0

    init() {
        FanCtlPaths.ensureDirectories()
        historyBuffer = Self.loadHistoryBuffer()

        // 退出前落盘趋势历史
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persistHistory() }
            }

        // 加载配置
        let cfg = ConfigStore.loadConfig()
        mode = cfg.mode
        manualPercent = cfg.manualPercent
        preset = cfg.preset ?? .balanced
        batterySaver = cfg.batteryPreset != nil
        envCompensation = UserDefaults.standard.object(forKey: Self.envCompensationKey) as? Bool ?? cfg.envCompensation
        palmCompensation = UserDefaults.standard.object(forKey: Self.palmCompensationKey) as? Bool ?? cfg.palmCompensation
        quietHours = UserDefaults.standard.object(forKey: Self.quietHoursKey) as? Bool ?? cfg.quietHours
        if let t = cfg.aiTargetTemp { aiTargetTemp = t }
        if let offsets = cfg.fanOffsets, offsets.count >= 2 {
            fanOffsets = [
                max(-20, min(20, offsets[0])),
                max(-20, min(20, offsets.count > 1 ? offsets[1] : 0))
            ]
        } else if let offsets = cfg.fanOffsets, offsets.count == 1 {
            fanOffsets = [max(-20, min(20, offsets[0])), 0]
        } else {
            fanOffsets = [0, 0]
        }

        // 恢复自定义曲线
        if let data = UserDefaults.standard.data(forKey: Self.customCurveKey),
           let pts = try? JSONDecoder().decode([CurvePoint].self, from: data), pts.count >= 2 {
            customPoints = pts
        } else if preset == .custom, cfg.curve.count >= 2 {
            customPoints = cfg.curve
        }

        // 恢复 AI 个性化预设
        if let data = UserDefaults.standard.data(forKey: Self.aiPresetsKey),
           let dict = try? JSONDecoder().decode([String: [CurvePoint]].self, from: data) {
            var m: [CurvePreset: [CurvePoint]] = [:]
            for (k, v) in dict {
                if let p = CurvePreset(rawValue: k), v.count >= 2 { m[p] = v }
            }
            aiPresetCurves = m
        }

        // 恢复风扇偏移
        if let data = UserDefaults.standard.data(forKey: Self.fanOffsetsKey),
           let offs = try? JSONDecoder().decode([Double].self, from: data), offs.count >= 1 {
            fanOffsets = [offs[0], offs.count > 1 ? offs[1] : 0]
        }

        // v3.4.5（4E）：通知权限改为事件前请求——不再启动即弹系统授权框
        //（首次启动观感突兀，且用户尚未理解通知的价值）。首个过热/风扇健康
        // 事件发生时由 NotificationService.ensureAuthorized() 懒请求。

        // 恢复冲刺状态
        if let end = UserDefaults.standard.object(forKey: Self.boostEndKey) as? Date {
            if end > Date() {
                boostEndDate = end
            } else {
                endBoost(restore: true)
            }
        }

        // 恢复静音承诺。冲刺与静音互斥（startBoost/startQuiet 内部互清），
        // 但崩溃残留可能两者同时有效：冲刺优先，静音残留直接清除
        if let end = UserDefaults.standard.object(forKey: Self.quietEndKey) as? Date, end > Date() {
            if boostEndDate == nil {
                quietEndDate = end
            } else {
                UserDefaults.standard.removeObject(forKey: Self.quietEndKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.quietEndKey)
        }

        // 开机对账：config.json 与 App 状态同步
        if cfg.curve != points(for: preset)
            || (batterySaver && cfg.batteryCurve != points(for: .quiet))
            || cfg.fanOffsets != (fanOffsets.allSatisfy{$0==0} ? nil : fanOffsets) {
            saveConfig()
        }

        lastSeenConfigMTime = ConfigStore.configModificationDate()

        // 开始监控 status.json 和 config.json
        setupStatusWatch()
        setupConfigWatch()

        // 首次立即读取一次
        refreshFromStatus()

        // 兜底定时器：每 12s 检查一次 status 新鲜度（防止 DispatchSource 丢事件）。
        // daemon 稳态最长 10s 心跳，idle 状态下间隔 20s（status 每 20s 更新一次）。
        // 存活阈值 30s = 20s idle 间隔 + 10s 余量（系统调度延迟容错）；
        // 12s 轮询足够及时且减少唤醒。
        let fallback = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStatusFreshness()
            }
        }
        fallback.tolerance = 3.0
    }

    // MARK: - 文件监控（DispatchSource 事件驱动）

    private func setupStatusWatch() {
        statusSource?.cancel()
        statusSource = nil
        // 注意：此处绝不能 eager close(statusFD)——旧 source 的 cancelHandler 是异步执行的，
        // close 后 open() 会复用同一 fd 号，旧 cancelHandler 会把新 watch 的 fd 关掉，
        // 事件驱动在第一次事件后就死亡（退化为 12s 兜底轮询）。
        // fd 的关闭完全交给各自 source 的 cancelHandler（捕获局部 fd 常量）。

        let path = FanCtlPaths.statusFile.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            statusFD = -1
            // 文件不存在，1s 后重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.setupStatusWatch() }
            return
        }
        statusFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // 原子写 rename 后需要重建监控；延迟 30ms 等写入完全落盘
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.refreshFromStatus()
                self.setupStatusWatch()
            }
        }
        // 关键：cancelHandler 必须捕获局部 fd 常量，而非 self.statusFD。
        // 因为 cancelHandler 异步执行时 self.statusFD 已被下一次 setupStatusWatch 更新为新 fd，
        // 关闭它会断开新 source 的监控，导致 UI 更新退化为 12s 兜底轮询。
        source.setCancelHandler { close(fd) }
        source.resume()
        statusSource = source
    }

    private func setupConfigWatch() {
        configSource?.cancel()
        configSource = nil
        // 同 setupStatusWatch：不能 eager close，fd 只由 cancelHandler 关闭（fd 号复用竞态）

        let path = FanCtlPaths.configFile.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            configFD = -1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.setupConfigWatch() }
            return
        }
        configFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.syncConfigFromDisk()
                self.setupConfigWatch()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configSource = source
    }

    private func checkStatusFreshness() {
        if let status = ConfigStore.loadStatus() {
            let age = Date().timeIntervalSince(status.timestamp)
            let wasAlive = daemonAlive
            // 存活阈值 30s：daemon idle 间隔可达 20s（LOOP_INTERVAL_IDLE），
            // status.json 在 idle 状态下每 20s 更新一次（10s 心跳检查只在 runControlLoop 中）。
            // 阈值需 > 20s + 系统调度余量，避免 idle 状态下误判 daemon 死了。
            daemonAlive = age < 30
            // v3.5.1（R1，P2 合并优先）：本函数已解码一次 status，刷新直接传参复用——
            // 旧路径 refreshFromStatus() 会再次读盘解码同一文件（12s 兜底每周期 2 次解码）。
            if !wasAlive && daemonAlive {
                // daemon 重新上线（如重启后），立即刷新
                refreshFromStatus(preloaded: status)
            } else if daemonAlive && status.timestamp != lastStatusTimestamp {
                refreshFromStatus(preloaded: status)
            } else if wasAlive && !daemonAlive {
                // daemon 刚下线：立即清除过期决策状态，避免 UI 长时间显示
                // 过期的 controlReason/aiIntent/controlFault（下次 refreshFromStatus 最多 12s 后）
                controlReason = nil
                aiIntent = nil
                controlFault = false
                faultReason = nil
                targetUnreachable = false
                curveTargetPercent = nil
                components = []
                learnedNow = nil
                daemonMode = nil
                configMismatch = false
                envTemp = nil
                systemPower = nil
                aiTargetEffective = nil
                palmComp = nil
            }
        } else {
            // status.json 不存在或无法读取：daemon 下线（含刚下线需清除状态）
            if daemonAlive {
                controlReason = nil
                aiIntent = nil
                controlFault = false
                faultReason = nil
                targetUnreachable = false
                curveTargetPercent = nil
                components = []
                learnedNow = nil
                daemonMode = nil
                configMismatch = false
                envTemp = nil
                systemPower = nil
                aiTargetEffective = nil
                palmComp = nil
            }
            daemonAlive = false
        }
        // 冲刺/静音到期检查
        if let end = boostEndDate, Date() >= end { endBoost(restore: true) }
        if let end = quietEndDate, Date() >= end { endQuiet() }
        maybeAutoOptimize()
    }

    // 从 status.json 刷新 UI 状态。preloaded：调用方已解码的同一文件内容
    // （12s 兜底/文件事件路径传入，省一次读盘+全量 JSON 解码；nil = 自读）
    private func refreshFromStatus(preloaded: DaemonStatus? = nil) {
        guard let status = preloaded ?? ConfigStore.loadStatus() else {
            daemonAlive = false
            controlReason = nil
            aiIntent = nil
            currentLoopInterval = nil
            controlFault = false
            faultReason = nil
            targetUnreachable = false
            curveTargetPercent = nil
            daemonMode = nil
            configMismatch = false
            aiTargetEffective = nil
            palmComp = nil
            return
        }
        lastStatusTimestamp = status.timestamp
        daemonAlive = Date().timeIntervalSince(status.timestamp) < 30
        if !daemonAlive {
            controlReason = nil
            aiIntent = nil
            controlFault = false
            faultReason = nil
            targetUnreachable = false
            curveTargetPercent = nil
            daemonMode = nil
            configMismatch = false
            aiTargetEffective = nil
            palmComp = nil
            return
        }

        // 配置对账：daemon 实际执行模式 vs App 写入意图。
        // 写入失败/权限异常/daemon 未跟上时置警示（用户操作 2s 内属正常传播延迟，不告警）
        daemonMode = status.mode
        configMismatch = status.mode != mode && Date().timeIntervalSince(lastUserChange) > 2

        let sensors = status.sensors
        // 数值防御：status.json 损坏/手改可含超大有限值或异常 RPM，
        // Double→Int 越界在 Swift 是 fatal trap（daemon 侧有全套防御，App 侧此前为零）
        let newCpu = deglitchTemperature(sanitizeTemp(sensors.cpuDie), prev: cpuTemp,
                              glitchHold: &glitchHoldCPU, zeroHold: &zeroHoldCPU)
        let newGpu = deglitchTemperature(sanitizeTemp(sensors.gpuDie), prev: gpuTemp,
                              glitchHold: &glitchHoldGPU, zeroHold: &zeroHoldGPU)

        let changed = Int(max(newCpu, newGpu)) != Int(max(cpuTemp, gpuTemp))
        let assign = {
            self.cpuTemp = newCpu
            self.cpuAverageTemp = sensors.cpuAverage.flatMap { $0.isFinite && $0 > 0 && $0 < 150 ? $0 : nil }
            self.gpuTemp = newGpu
            self.ssdTemp = sensors.ssd.flatMap { $0.isFinite && $0 > 0 && $0 < 150 ? $0 : nil }
            self.palmRestTemp = sensors.palmRest.flatMap { $0.isFinite && $0 > 0 && $0 < 150 ? $0 : nil }
            self.appliedPercent = (status.appliedPercent.isFinite
                ? max(0, min(100, status.appliedPercent)) : 0)   // 钳位防 Int() trap
            self.appliedPercents = status.appliedPercents?.map { $0.isFinite ? $0 : 0 } ?? [self.appliedPercent]
            self.onBattery = status.onBattery ?? false
            self.batteryOverride = status.batteryOverride ?? false
            self.nightOverride = status.nightOverride ?? false
            if let env = status.envTemp, env.isFinite, env > 0, env < 60 { self.envTemp = env }
            self.controlReason = status.reason
            self.aiIntent = status.aiIntent
            self.curveTargetPercent = status.curveTargetPercent
            self.learningRecently = status.learningRecently ?? false
            self.learnedSamples = status.learnedSamples ?? 0
            self.targetUnreachable = status.targetUnreachable ?? false
            if let pts = status.learnedPoints { self.learnedPoints = pts }
            self.currentLoopInterval = status.loopInterval
            self.controlFault = status.controlFault ?? false
            self.faultReason = status.faultReason
            self.aiTargetEffective = status.aiTargetEffective.flatMap {
                $0.isFinite && $0 > 20 && $0 < 100 ? $0 : nil
            }
            self.palmComp = status.palmComp.flatMap { $0.isFinite && $0 > 0.5 && $0 <= 4 ? $0 : nil }
            self.systemPower = status.powerWatts.flatMap { $0.isFinite && $0 > 0.1 && $0 < 1000 ? $0 : nil }
        }
        if panelVisible && changed {
            withAnimation(.snappy(duration: 0.25)) { assign() }
        } else {
            assign()
        }

        // #12: AI 全力散热预提示：满速 ≥20s 且温度高于目标+2°C。
        // 判据用 daemon 下发的有效目标（环境/夜间/电池叠加后）——用用户原始目标会在
        // 夏天/夜间/电池场景产生假阳性（实际 AI 在其有效目标附近从容工作）
        let effAITarget = aiTargetEffective ?? aiTargetTemp
        if mode == .ai && appliedPercent >= 99 && max(cpuTemp, gpuTemp) > effAITarget + 2
           && !targetUnreachable {
            if aiHighEffortSince == nil { aiHighEffortSince = Date() }
            if Date().timeIntervalSince(aiHighEffortSince!) >= 20 { aiHighEffort = true }
        } else {
            aiHighEffortSince = nil
            aiHighEffort = false
        }

        // #4: AI 目标推荐：首次进入 AI 且无学习数据时采样 30s 基线温度
        if mode == .ai && learnedPoints == 0, let entered = aiModeEnteredAt {
            let hot = max(cpuTemp, gpuTemp)
            if hot > 1 { aiBaselineTemps.append(hot) }
            if Date().timeIntervalSince(entered) >= 30 && !aiBaselineTemps.isEmpty {
                let avg = aiBaselineTemps.reduce(0, +) / Double(aiBaselineTemps.count)
                aiRecommendedTarget = avg <= 68 ? 72 : (avg < 73 ? 76 : 80)
            }
        }

        // 转换风扇状态（数值防御：异常 RPM 不入 UI，避免 Int() trap）
        var fanStates: [FanState] = []
        for entry in status.fans {
            fanStates.append(FanState(id: entry.id,
                                      actualRPM: safeRPM(entry.actualRPM),
                                      minRPM: safeRPM(entry.minRPM),
                                      maxRPM: safeRPM(entry.maxRPM),
                                      targetRPM: safeRPM(entry.targetRPM)))
        }
        let rpmOld = fans.map { Int($0.actualRPM / 10) }
        let rpmNew = fanStates.map { Int($0.actualRPM / 10) }
        if rpmNew != rpmOld {
            if panelVisible {
                withAnimation(.snappy(duration: 0.25)) { self.fans = fanStates }
            } else {
                self.fans = fanStates
            }
        }

        // v3.4.1：lastRefresh 仅面板可见时更新（唯一消费者 FanRow.now 已随 DoD-5c
        // 移除；保留发布供未来 UI 计时使用，但不再每拍无谓触发 objectWillChange）
        if panelVisible { lastRefresh = Date() }

        // 历史采样
        let hottest = max(cpuTemp, gpuTemp)
        if hottest > 1 {
            historyBuffer.append(TempSample(id: Date(), cpu: cpuTemp, gpu: gpuTemp))
            // #7: RingBuffer 自动淘汰最旧元素，O(1) 追加，无 removeAll 线性扫描
            historySaveCounter += 1
            if historySaveCounter >= 30 {
                historySaveCounter = 0
                persistHistory()
            }
        }

        // 检查风扇健康（用已消毒的 fanStates，原始 entries 可能含超大值 → Int() trap）
        notifications.checkFanHealth(fanStates, controlReason: controlReason)

        // 发烧元凶检测
        notifications.checkOverheat(hottest)

        // 面板可见时同步额外数据
        if panelVisible {
            syncPanelDataFromSensors(sensors)
            history = historyBuffer.elements
            // 低频（30s）刷新只读文件数据：面板长开数小时后"经验/评测/战报/AI 效果"
            // 此前停留在打开瞬间的值，与实时学习/统计脱节
            if Date().timeIntervalSince(lastPanelFileSync) > 30 {
                lastPanelFileSync = Date()
                // v3.5.1（R2，P2 合并优先）：history.json（30 天全量，贵的那个）解码一次
                // 向下传参；旧路径 loadDaysWithToday 每周期被调 3 次。stats 直读保持
                // "今日零样本显示今日空态"语义（days.last 会退化成昨天数据）。
                stats = ConfigStore.loadStats()
                let days = loadDaysWithToday(preloadedStats: stats)
                learnedPoints = ConfigStore.loadLearn()?.learnedBucketCount ?? 0
                let hot = max(cpuTemp, gpuTemp)
                learnedNow = hot > 1 ? (ConfigStore.loadLearn()?.percent(for: hot) ?? nil) : nil
                aiMetrics = ConfigStore.loadAIMetrics()
                refreshAIStatus(preloadedDays: days)
                refreshThermalHealth(preloadedDays: days)
            }
        }
    }

    // status.json 数值防御：非有限/越界值不进入 UI（daemon 侧有防御，App 侧此前为零）
    private func sanitizeTemp(_ v: Double) -> Double {
        v.isFinite && v > 0 && v < 150 ? v : 0
    }
    private func safeRPM(_ v: Double) -> Double {
        v.isFinite ? min(max(v, 0), 20_000) : 0
    }

    // deglitch 已提取到 SMCCore (deglitchTemperature)，供 App 与测试共用

    // 面板专属数据同步
    private func syncPanelData() {
        history = historyBuffer.elements
        if let status = ConfigStore.loadStatus() {
            syncPanelDataFromSensors(status.sensors)
        }
        stats = ConfigStore.loadStats()
        learnedPoints = ConfigStore.loadLearn()?.learnedBucketCount ?? 0
        let hot = max(cpuTemp, gpuTemp)
        learnedNow = hot > 1 ? (ConfigStore.loadLearn()?.percent(for: hot) ?? nil) : nil
        aiMetrics = ConfigStore.loadAIMetrics()
        refreshAIStatus()
        refreshThermalHealth()
    }

    private func syncPanelDataFromSensors(_ sensors: SensorReadings) {
        // 组装部件温度列表（无效读数 ≤1 不显示，传感器失效时不展示 0° 行）
        var comps: [ComponentTempDisplay] = []
        if sensors.cpuDie > 1 { comps.append(ComponentTempDisplay(id: "CPU", temp: sanitizeTemp(sensors.cpuDie))) }
        if sensors.gpuDie > 1 { comps.append(ComponentTempDisplay(id: "GPU", temp: sanitizeTemp(sensors.gpuDie))) }
        if let ssd = sensors.ssd, ssd > 1 { comps.append(ComponentTempDisplay(id: "SSD", temp: sanitizeTemp(ssd))) }
        if let palm = sensors.palmRest, palm > 1 { comps.append(ComponentTempDisplay(id: "掌托", temp: sanitizeTemp(palm))) }
        if let hs = sensors.heatsink, hs > 1 { comps.append(ComponentTempDisplay(id: "散热片", temp: sanitizeTemp(hs))) }
        components = comps.sorted { $0.temp > $1.temp }
    }

    // 从磁盘同步配置（外部修改时）
    private func syncConfigFromDisk() {
        guard let mtime = ConfigStore.configModificationDate(), mtime != lastSeenConfigMTime else { return }
        lastSeenConfigMTime = mtime
        // 自己写入的回声直接忽略（App 是唯一写入方，外部修改立即可见）
        if mtime == lastOwnConfigMTime { return }
        let cfg = ConfigStore.loadConfig()
        if cfg.mode != mode {
            // 模式变更不带动画，避免面板尺寸突变
            mode = cfg.mode
        }
        if abs(cfg.manualPercent - manualPercent) > 0.5 { manualPercent = cfg.manualPercent }
        if let p = cfg.preset, p != preset { preset = p }
        if (cfg.batteryPreset != nil) != batterySaver { batterySaver = cfg.batteryPreset != nil }
        if let t = cfg.aiTargetTemp, abs(t - aiTargetTemp) > 0.5 { aiTargetTemp = t }
        if cfg.envCompensation != envCompensation {
            envCompensation = cfg.envCompensation
            UserDefaults.standard.set(cfg.envCompensation, forKey: Self.envCompensationKey)
        }
        if cfg.quietHours != quietHours {
            quietHours = cfg.quietHours
            UserDefaults.standard.set(cfg.quietHours, forKey: Self.quietHoursKey)
        }
        if cfg.palmCompensation != palmCompensation {
            palmCompensation = cfg.palmCompensation
            UserDefaults.standard.set(cfg.palmCompensation, forKey: Self.palmCompensationKey)
        }
        if let offsets = cfg.fanOffsets {
            let o0 = offsets.count > 0 ? max(-20, min(20, offsets[0])) : 0
            let o1 = offsets.count > 1 ? max(-20, min(20, offsets[1])) : 0
            if fanOffsets != [o0, o1] { fanOffsets = [o0, o1] }
        }
        // 自定义曲线回填：外部修改 config.json（或 AI 优化落盘）后 App 侧展示与实际一致，
        // 否则下次 saveConfig 会用 App 侧陈旧状态覆盖 daemon 正在用的曲线
        if cfg.preset == .custom, cfg.curve.count >= 2, cfg.curve != customPoints {
            customPoints = cfg.curve
            persistCustomPoints()
        }
    }

    // MARK: 风扇健康监测

    func setMode(_ newMode: FanMode) {
        // 无变化直接返回：SwiftUI 分段 Picker 点击当前已选中的段也会触发 setter，
        // 冲刺期间点"手动"（当前就是手动）会被当成模式切换而静默取消冲刺
        if newMode == mode { return }
        // 防止 Picker 在程序性修改 mode 后回写旧值（SwiftUI 已知行为）：
        // startBoost 设 lastUserChange + mode=.manual，Picker 可能在同一 RunLoop 内
        // 用缓存的旧选中值（如 .ai）触发 set 回调，把 mode 改回并清除冲刺状态。
        // 0.5s 窗口内冲刺/静音活跃时，忽略与冲刺/静音冲突的模式切换。
        if boostEndDate != nil, newMode != .manual,
           Date().timeIntervalSince(lastUserChange) < 0.5 { return }
        if quietEndDate != nil, newMode == .manual,
           Date().timeIntervalSince(lastUserChange) < 0.5 { return }
        lastUserChange = Date()
        if boostEndDate != nil { endBoost(restore: false) }
        pendingAICurve = nil   // 切模式后旧的待确认 AI 建议失效
        mode = newMode
        // #4: 进入 AI 模式时开始基线采样，切出时清空
        if newMode == .ai {
            aiModeEnteredAt = Date()
            aiBaselineTemps = []
            aiRecommendedTarget = nil
        } else {
            aiModeEnteredAt = nil
            aiBaselineTemps = []
            aiRecommendedTarget = nil
        }
        saveConfig()
    }

    func setAITarget(_ temp: Double) {
        lastUserChange = Date()
        aiTargetTemp = temp
        saveConfig()
    }

    func setPreset(_ newPreset: CurvePreset) {
        lastUserChange = Date()
        aiSummary = nil
        aiDetail = nil
        // 待确认的 AI 曲线建议只对产生它的档位有效，切换预设时清掉避免残留
        pendingAICurve = nil
        if newPreset == .custom, UserDefaults.standard.data(forKey: Self.customCurveKey) == nil {
            customPoints = points(for: preset)
            persistCustomPoints()
        }
        withAnimation(.snappy) { preset = newPreset }
        saveConfig()
    }

    // 设置单风扇偏移
    func setFanOffset(fanIndex: Int, offset: Double) {
        lastUserChange = Date()
        let clamped = max(-20, min(20, offset))
        while fanOffsets.count <= fanIndex { fanOffsets.append(0) }
        fanOffsets[fanIndex] = clamped
        if let data = try? JSONEncoder().encode(fanOffsets) {
            UserDefaults.standard.set(data, forKey: Self.fanOffsetsKey)
        }
        saveConfig()
    }

    // 指定风扇的当前偏移（UI 展示用；fan.id 可能因 SMC 读失败而跳跃，用 id 索引）
    func offsetForFan(fanIndex: Int) -> Double {
        guard fanIndex >= 0, fanIndex < fanOffsets.count else { return 0 }
        return fanOffsets[fanIndex]
    }

    // MARK: AI 曲线优化

    @Published var aiSummary: String? = nil
    var aiDetail: String? = nil
    @Published var aiPresetCurves: [CurvePreset: [CurvePoint]] = [:]
    @Published var aiEffectText: String? = nil
    @Published var aiMetrics: AIControlMetrics? = nil
    @Published var pendingAICurve: CurveOptimizer.Result? = nil
    @Published var aiNudge = false
    @Published var autoOptimize = UserDefaults.standard.bool(forKey: FanModel.autoOptimizeKey)
    private var lastAutoOptCheck = Date.distantPast

    private struct AIBaseline: Codable { var date: String; var avgTemp: Double; var hotRatio: Double }
    // v2.9：优化器热压力基线（与 AIBaseline 解耦——反漂移闸门必须用优化器自己的
    // 直方图口径比对，AIBaseline.hotRatio 是全天聚合口径，混用会错判"变热/变凉"）
    private struct AIOptimizeHot: Codable { var hotRatio: Double; var powerP50: Double? }
    private static let aiOptimizerHotKey = "aiOptimizerHotRatio"
    private struct AIEffect { let days: Int; let beforeAvg: Double; let afterAvg: Double; let beforeHot: Double; let afterHot: Double }

    func applyAICurve() { applyAICurve(auto: false) }

    @discardableResult
    func applyAICurve(auto: Bool) -> Bool {
        lastUserChange = Date()
        lastAutoOptCheck = Date()
        let days = loadDaysWithToday()
        // v2.9 反漂移：传入上次应用的曲线与优化器热压力基线，优化器据此限幅锚点下移
        let previousCurves = aiPresetCurves.isEmpty ? nil : aiPresetCurves
        let prevState = UserDefaults.standard.data(forKey: FanModel.aiOptimizerHotKey)
            .flatMap { try? JSONDecoder().decode(AIOptimizeHot.self, from: $0) }
        guard let r = CurveOptimizer.optimize(days: days,
                                              previous: previousCurves,
                                              previousHotRatio: prevState?.hotRatio,
                                              previousPowerP50: prevState?.powerP50) else {
            if !auto { aiSummary = "数据积累中，正常使用约半小时后再试"; aiDetail = nil }
            return false
        }
        if auto {
            pendingAICurve = r
            aiSummary = "发现新的 AI 曲线建议，请确认后应用"
            aiDetail = r.detail
            return true
        }
        applyCurveResult(r, days: days, notify: false)
        return true
    }

    func confirmAICurve() {
        guard let r = pendingAICurve else { return }
        pendingAICurve = nil
        applyCurveResult(r, days: loadDaysWithToday(), notify: true)
    }

    func dismissAICurve() {
        pendingAICurve = nil
        aiSummary = "已保留当前曲线"
    }

    private func applyCurveResult(_ r: CurveOptimizer.Result, days: [DailyStats], notify: Bool) {
        // 持久化优化器基线（热压力 + 负载中位数，下次反漂移闸门的比对口径）
        if let data = try? JSONEncoder().encode(AIOptimizeHot(hotRatio: r.hotRatio, powerP50: r.powerP50)) {
            UserDefaults.standard.set(data, forKey: FanModel.aiOptimizerHotKey)
        }
        if let ag = Self.aggregate(days) {
            saveBaseline(AIBaseline(date: DailyStats.today(), avgTemp: ag.avg, hotRatio: ag.hot))
        }
        withAnimation(.snappy) {
            aiPresetCurves = r.presetCurves
            if preset == .custom { customPoints = r.points }
        }
        persistAIPresets()
        if preset == .custom { persistCustomPoints() }
        aiSummary = r.summary
        aiDetail = r.detail
        aiNudge = false
        saveConfig()
        if notify { notifications.notifyAutoOptimized(r) }
    }

    private func maybeAutoOptimize() {
        guard autoOptimize, mode == .curve else { return }
        guard Date().timeIntervalSince(lastUserChange) > 5,
              Date().timeIntervalSince(lastAutoOptCheck) > 3600 else { return }
        lastAutoOptCheck = Date()
        let st = reoptimizeState()
        if loadBaseline() == nil || st.afterDays >= 3 {
            _ = applyAICurve(auto: true)
        }
    }

    func setAutoOptimize(_ on: Bool) {
        autoOptimize = on
        UserDefaults.standard.set(on, forKey: Self.autoOptimizeKey)
        if on { lastAutoOptCheck = .distantPast; maybeAutoOptimize() }
    }

    // MARK: AI 效果与基准快照

    private func loadDaysWithToday(preloadedStats: DailyStats? = nil) -> [DailyStats] {
        var days = ConfigStore.loadHistory()
        if let s = preloadedStats ?? ConfigStore.loadStats(), s.tempCount > 0 {
            days.removeAll { $0.date == s.date }
            days.append(s)
        }
        return days
    }

    private static func aggregate(_ days: [DailyStats]) -> (avg: Double, hot: Double)? {
        let valid = days.filter { $0.tempCount > 0 }
        guard !valid.isEmpty else { return nil }
        let tempSum = valid.reduce(0.0) { $0 + $1.tempSum }
        let hotSeconds = valid.reduce(0.0) { $0 + $1.highTempSeconds }
        // 时间加权口径（与 v2.6.2 起的 avgTemp/直方图一致）；旧数据无 tempSeconds
        // 时回退"样本数×3s"估算（v2.6 前守护进程固定 3s 一拍）。
        // 此前恒用 tempCount×3——正是 v2.6.2 在统计层消灭掉的固定 3s 假设
        let secs = valid.reduce(0.0) { $0 + $1.tempSeconds }
        if secs > 0 { return (tempSum / secs, hotSeconds / secs) }
        let cnt = valid.reduce(0.0) { $0 + $1.tempCount }
        return (tempSum / cnt, hotSeconds / (cnt * 3.0))
    }

    private func saveBaseline(_ b: AIBaseline) {
        if let d = try? JSONEncoder().encode(b) { UserDefaults.standard.set(d, forKey: Self.aiBaselineKey) }
    }
    private func loadBaseline() -> AIBaseline? {
        guard let d = UserDefaults.standard.data(forKey: Self.aiBaselineKey) else { return nil }
        return try? JSONDecoder().decode(AIBaseline.self, from: d)
    }

    // v3.5.1（R2，P2 合并优先）：preloadedDays 传入调用方已读的 days 快照，
    // 避免 30s 同步里 history.json+stats.json 被重复解码（原每周期 3 次 loadDaysWithToday）
    private func reoptimizeState(preloadedDays: [DailyStats]? = nil) -> (afterDays: Int, effect: AIEffect?) {
        guard let b = loadBaseline() else { return (0, nil) }
        let after = (preloadedDays ?? loadDaysWithToday()).filter { $0.date > b.date }
        guard let ag = Self.aggregate(after) else { return (after.count, nil) }
        return (after.count, AIEffect(days: after.count, beforeAvg: b.avgTemp,
                                      afterAvg: ag.avg, beforeHot: b.hotRatio, afterHot: ag.hot))
    }

    private func refreshAIStatus(preloadedDays: [DailyStats]? = nil) {
        let st = reoptimizeState(preloadedDays: preloadedDays)
        aiNudge = st.afterDays >= 3
        if let e = st.effect {
            let dAvg = e.beforeAvg - e.afterAvg
            let arrow = dAvg >= 0 ? "↓" : "↑"
            aiEffectText = "启用 \(e.days) 天 · 均温 \(Int(e.beforeAvg.rounded()))°→\(Int(e.afterAvg.rounded()))°（\(arrow)\(abs(Int(dAvg.rounded())))°）· 高温 \(Int((e.beforeHot*100).rounded()))%→\(Int((e.afterHot*100).rounded()))%"
        } else {
            aiEffectText = nil
        }
    }

    private func persistAIPresets() {
        var dict: [String: [CurvePoint]] = [:]
        for (k, v) in aiPresetCurves { dict[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.aiPresetsKey)
        }
    }

    func updateCustomPoints(_ pts: [CurvePoint]) {
        lastUserChange = Date()
        aiSummary = nil
        aiDetail = nil
        customPoints = pts
        persistCustomPoints()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveConfig() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func persistCustomPoints() {
        if let data = try? JSONEncoder().encode(customPoints) {
            UserDefaults.standard.set(data, forKey: Self.customCurveKey)
        }
    }

    func setManualPercent(_ pct: Double) {
        lastUserChange = Date()
        manualPercent = pct
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveConfig() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func saveConfig() {
        if ConfigStore.saveConfig(config) {
            configWriteFailed = false
            lastSeenConfigMTime = ConfigStore.configModificationDate()
            lastOwnConfigMTime = lastSeenConfigMTime
            // 主动触发一次延迟 status 刷新：daemon 30ms 防抖 + 处理 ≈ 100ms 后写 status.json，
            // 250ms 后读取可确保拿到最新状态，不依赖 DispatchSource 事件（原子写可能丢事件）。
            // 每次 saveConfig 取消前一个刷新定时器，避免重复刷新。
            statusRefreshWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refreshFromStatus()
            }
            statusRefreshWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            // v2.9.2：写入失败不再静默——配置目录 v2.8 起收紧为 admin 组，
            // 标准用户账户运行 App 时调速设置会静默失效，必须让用户看见
            configWriteFailed = true
            NSLog("FanCtl: 配置写入失败，请检查是否已运行安装脚本")
        }
    }

    // 冲刺/静音已提取到 FanControlActions.swift（FanModel extension）

    // MARK: 电池安静档

    func setBatterySaver(_ enabled: Bool) {
        lastUserChange = Date()
        batterySaver = enabled
        saveConfig()
    }

    // MARK: v8 环境补偿 / 夜间安静档

    func setPalmCompensation(_ on: Bool) {
        lastUserChange = Date()
        palmCompensation = on
        UserDefaults.standard.set(on, forKey: Self.palmCompensationKey)
        saveConfig()
    }

    func setEnvCompensation(_ on: Bool) {
        lastUserChange = Date()
        envCompensation = on
        UserDefaults.standard.set(on, forKey: Self.envCompensationKey)
        saveConfig()
    }

    func setQuietHours(_ on: Bool) {
        lastUserChange = Date()
        quietHours = on
        UserDefaults.standard.set(on, forKey: Self.quietHoursKey)
        saveConfig()
    }

    func setEnvTempOverride(_ value: Double?) {
        lastUserChange = Date()
        envTempOverride = value
        saveConfig()
    }

    // MARK: v8 散热健康趋势

    // 散热退化趋势：同功耗下的温升随时间漂移（硅脂老化/积灰）。
    // 用 30 天战报的 均温/平均功耗（°C/W）作代理——数据需积累 2 周以上才有意义。
    // 最近 7 天 vs 之前 7 天，比值上升 >15% 提示清灰/换硅脂。
    @Published var thermalHealthText: String? = nil

    func refreshThermalHealth(preloadedDays: [DailyStats]? = nil) {
        let days = (preloadedDays ?? loadDaysWithToday()).filter { $0.avgPower > 1 && $0.tempCount > 0 }
        guard days.count >= 14 else {
            thermalHealthText = days.count >= 2
                ? "散热趋势积累中（需约 2 周数据，已 \(days.count) 天）"
                : nil
            return
        }
        let recent = Array(days.suffix(7))
        let prior = Array(days.prefix(days.count - 7).suffix(7))
        func ratio(_ ds: [DailyStats]) -> Double {
            let p = ds.reduce(0.0) { $0 + $1.avgPower }
            let t = ds.reduce(0.0) { $0 + $1.avgTemp }
            return p > 1 ? t / p : 0
        }
        let r1 = ratio(prior), r2 = ratio(recent)
        guard r1 > 0.01 else { thermalHealthText = nil; return }
        let change = (r2 - r1) / r1
        if change > 0.15 {
            thermalHealthText = String(format: "散热效率下降 %.0f%%（%.2f→%.2f °C/W），建议清灰或换硅脂",
                                       change * 100, r1, r2)
        } else if change < -0.15 {
            thermalHealthText = String(format: "散热效率提升 %.0f%%（%.2f→%.2f °C/W）", -change * 100, r1, r2)
        } else {
            thermalHealthText = String(format: "散热稳定（%.2f °C/W，两周变化 %+.0f%%）", r2, change * 100)
        }
    }

    // MARK: 登录启动

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            NSLog("FanCtl: 登录项设置失败: \(error)")
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}
