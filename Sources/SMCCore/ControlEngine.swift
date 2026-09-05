import Foundation
import Dispatch

// MARK: - 控制引擎（fanctld 主循环的每拍状态机，daemon 与测试共用）
//
// 此前主循环是 fanctld main.swift 的顶层脚本 + ~40 个全局变量：纯函数虽已提取到
// SMCCore 并被 fanctltests 覆盖，但"接线"（force 旁路/排除条件/故障协议/边沿日志）
// 零测试覆盖——v2.6/v2.7 的 bug 几乎全部出在这一层。本类型把全部主循环状态与
// 每拍逻辑收拢为可注入的引擎：SMC 用 SMCIO 协议注入 MockSMC，文件 IO 走 ConfigStore
// （FanCtlPaths.setOverridesForTesting 重定向到临时目录），时间/日志/调度/电源/功耗
// 采样以 Hooks 闭包注入。fanctltests 用 FakeClock + MockSMC 真实跑拍、断言 SMC 写入
// 序列——引擎测试覆盖的就是被执行的那份代码。
//
// main.swift 只保留壳层：SMC 初始化、root 守卫、信号、看门狗、文件监控、睡眠注册、
// 定时器与日志函数，全部通过 Hooks/公开方法与引擎交互。

// 自适应循环间隔边界（秒）与写入节流（原 fanctld 顶层常量，随引擎迁入）
public let RPM_DEADBAND = 40.0           // 目标变化小于此值不重写，减少 SMC 写入
public let REASSERT_LOOPS = 20           // 每 N 循环强制重写一次（防睡眠唤醒后 SMC 复位强制模式）

public let LOOP_INTERVAL_MIN: TimeInterval = 1.0
public let LOOP_INTERVAL_DEFAULT: TimeInterval = 3.0
public let LOOP_INTERVAL_STABLE: TimeInterval = 5.0
public let LOOP_INTERVAL_COOL: TimeInterval = 10.0
public let LOOP_INTERVAL_IDLE: TimeInterval = 20.0

public final class ControlEngine {

    // MARK: - 环境注入（生产由 main.swift 接线，测试用 Mock/Fake）

    public struct Hooks {
        /// 当前时间（beat 内所有时间语义的单一来源，测试注入 FakeClock）
        public let now: () -> Date
        /// 日志（生产接 log()，测试收集到内存）
        public let log: (String) -> Void
        /// 安排下一拍（0 = 立即；生产接主队列定时器，引擎只负责算间隔）
        public let schedule: (TimeInterval) -> Void
        /// 是否电池供电
        public let onBattery: () -> Bool
        /// 分项功耗当前值（powermetrics 采样器）
        public let powerComponents: () -> (cpu: Double?, gpu: Double?)
        /// 分项功耗采样间隔自适应
        public let setPowerInterval: (TimeInterval) -> Void

        public init(now: @escaping () -> Date,
                    log: @escaping (String) -> Void,
                    schedule: @escaping (TimeInterval) -> Void,
                    onBattery: @escaping () -> Bool,
                    powerComponents: @escaping () -> (cpu: Double?, gpu: Double?),
                    setPowerInterval: @escaping (TimeInterval) -> Void) {
            self.now = now
            self.log = log
            self.schedule = schedule
            self.onBattery = onBattery
            self.powerComponents = powerComponents
            self.setPowerInterval = setPowerInterval
        }
    }

    public let hooks: Hooks
    public let fans: FanController
    public let sensors: TemperatureSensors

    // MARK: - 主循环状态（自 main.swift 逐字段迁入，语义不变）

    public private(set) var config: FanConfig
    public private(set) var lastConfigMTime: Date   // ConfigWatch 事件去重读（跨模块）
    var controller = FanCurveController()
    public private(set) var aiController = AIController()
    public private(set) var thermalLearn: ThermalLearn
    public private(set) var aiMetrics: AIControlMetrics
    var aiMetricsUserTarget: Double? = nil   // 评测的用户目标基准（有效目标随环境/夜间漂移，不能用作重置判据）
    var thermalModel: ThermalModel
    var learnDirty = false
    var modelDirty = false
    var envCompLogged = false
    var lastAIOutput: Double? = nil
    var lastAIIntent: AIIntent? = nil
    var prevSmoothedTemp: Double? = nil
    var prevBaseTarget: Double? = nil
    var lastLearnAt: Date? = nil
    var prevRawTemp: Double = 0
    var aiIdleActive = false
    var lastWrittenRPM: [Int: Double] = [:]
    var forcedModeActive = false
    var writeHealth = WriteHealth()
    var feedbackHealth = FanFeedbackHealth()
    var tempFailCount = 0
    var loopCount = 0
    var lastOnBattery: Bool? = nil
    var failsafeActive = false
    var ssdGuardActive = false
    var ssdCriticalActive = false
    var batteryGuardActive = false
    var batteryCriticalActive = false
    var currentLoopInterval: TimeInterval = LOOP_INTERVAL_DEFAULT
    var statsAccumSeconds: Double = 0
    var lastLoopStart: Date? = nil
    var lastStatusSummary: String = ""
    var forceWriteCounter: Int = 0
    var lastStatusWrite: Date = .distantPast
    var lastStatus: DaemonStatus?
    var targetUnreachable = false
    var targetUnreachableSince: Date? = nil
    var targetUnreachableLogged = false
    var boostExpiredLogged = false
    var lastProbeTime = Date.distantPast
    var probeVerifyLoops = 0
    var stuckDetector = StuckSensorDetector()       // v2.8 传感器卡死一致性门
    var belowAmbientSeconds = 0.0                    // v3.0 读数偏低门（秒制，累计钳顶 90）
    var belowAmbientFaulted = false                  // 偏低门锁存：≥90s 触发、衰减到 0 才解除
    var lastPlausibleEnvTemp: Double? = nil         // 读数偏低期谷值会被"贴近芯片"检查判 nil，保留最近合理值
    var aiCyclingGuardActive = false                // 启停循环抑制边沿日志
    var prevStatsAppliedPercent: Double? = nil      // 调速次数统计的上一拍输出
    var statsKeeper: StatsSampler

    // MARK: - 看门狗心跳（跨线程读：主队列写、watchdog 队列读，锁保护）

    private let watchdogLock = NSLock()
    private var heartbeatValue = DispatchTime.now()
    private var suspended = false

    /// 看门狗心跳（watchdog 线程读）
    public func heartbeat() -> DispatchTime {
        watchdogLock.lock(); defer { watchdogLock.unlock() }
        return heartbeatValue
    }
    /// 看门狗判挂死依据之一：主循环是否声明挂起（watchdog 线程读）
    public var isSuspendedForSleep: Bool {
        watchdogLock.lock(); defer { watchdogLock.unlock() }
        return suspended
    }
    private func touchHeartbeat() {
        watchdogLock.lock()
        heartbeatValue = DispatchTime.now()
        watchdogLock.unlock()
    }

    // MARK: - 初始化（含启动清洗/衰减/战报恢复，原 main.swift 启动段迁入）

    public init(fans: FanController, sensors: TemperatureSensors, hooks: Hooks) {
        self.fans = fans
        self.sensors = sensors
        self.hooks = hooks
        self.config = ConfigStore.loadConfig().sanitized()
        self.lastConfigMTime = ConfigStore.configModificationDate() ?? .distantPast
        self.thermalLearn = ConfigStore.loadLearn() ?? ThermalLearn()
        let cfgUserTarget = config.aiTargetTemp ?? 76
        self.aiMetrics = ConfigStore.loadAIMetrics() ?? AIControlMetrics(targetTemp: cfgUserTarget,
                                                                         userTargetTemp: cfgUserTarget)
        // 评测账本跨启动重置判据：持久化的"用户目标"（v2.9 起单独存，
        // targetTemp 已改为随环境/夜间漂移的有效目标，不能再用作比对）
        let savedUserTarget = aiMetrics.userTargetTemp ?? aiMetrics.targetTemp
        if abs(savedUserTarget - cfgUserTarget) > 0.5 {
            self.aiMetrics = AIControlMetrics(targetTemp: cfgUserTarget, userTargetTemp: cfgUserTarget)
        }
        self.aiMetricsUserTarget = cfgUserTarget
        self.thermalModel = ConfigStore.loadModel() ?? ThermalModel()

        // 启动时清洗历史污染数据——阈值随启动时的环境估计修正（v2.9）：
        // 原判据隐含 25°C 室温，热带/夏季重载下 65°/55% 是合法物理，
        // 旧实现在每次启动时把它清零重学，学习永远无法稳定。
        // 用户显式设置 envTempOverride 时不信任代理，清洗与其余 envOff 同口径
        let startupEnv = config.envTempOverride ?? sensors.ambientEstimate(now: hooks.now())
        let cleanedBuckets = thermalLearn.sanitizeCorruptedBuckets(envTemp: startupEnv)
        if cleanedBuckets > 0 {
            learnDirty = true
            hooks.log("热经验学习: 清洗 \(cleanedBuckets) 个污染桶"
                + (startupEnv.map { String(format: "（环境 %.0f°C，阈值已随环境修正）", $0) } ?? "（低温<75°C 但学到>80%输出，疑似手动模式残留）"))
        }
        // 启动时时间衰减：超过 14 天未更新的桶样本数减半
        let decayedBuckets = thermalLearn.decayStaleBuckets()
        if decayedBuckets > 0 {
            learnDirty = true
            hooks.log("热经验学习: 衰减 \(decayedBuckets) 个过时桶（>14天未更新，样本数减半）")
        }
        // 每日统计：停机跨天先归档旧战报
        let restored = StatsSampler.restore(saved: ConfigStore.loadStats(), now: hooks.now())
        if let stale = restored.toArchive {
            ConfigStore.archiveDay(stale)
            hooks.log("归档停机前战报: \(stale.date)")
        }
        self.statsKeeper = restored.sampler
    }

    // MARK: - 睡眠/唤醒/退出交接（原 SleepHandler 内联逻辑迁入）

    /// 系统入睡（主队列调用）：交还调度 + 落盘全部学习/统计状态
    public func enterSleep() {
        setSuspended(true)
        if forcedModeActive {
            fans.restoreAutoAll()
            forcedModeActive = false
            lastWrittenRPM.removeAll()
            hooks.log("系统入睡：已交还自动调度")
        }
        ConfigStore.saveStats(statsKeeper.stats)
        ConfigStore.saveLearn(thermalLearn)
        ConfigStore.saveModel(thermalModel)
        ConfigStore.saveAIMetrics(aiMetrics)
    }

    /// 系统唤醒（主队列调用）：清理残留状态、重扫传感器、立即跑一拍
    public func wake() {
        setSuspended(false)
        fans.invalidateFanLimits()   // v3.4.1：唤醒重读风扇 Mn/Mx（固件可能重置）
        fans.restoreAutoAll()
        controller.invalidateTemp()
        controller.clearOutput()
        aiController.reset()
        forcedModeActive = false
        lastWrittenRPM.removeAll()
        aiIdleActive = false
        prevRawTemp = 0
        prevSmoothedTemp = nil
        prevBaseTarget = nil
        currentLoopInterval = LOOP_INTERVAL_DEFAULT
        lastLoopStart = nil
        stuckDetector.reset()
        belowAmbientSeconds = 0
        belowAmbientFaulted = false
        lastPlausibleEnvTemp = nil
        // 唤醒残留状态清理（v2.8 审查 P3）：故障计数/试探期/压不住/冲刺超时日志
        // 都属于"上一次清醒会话"的上下文，带着它们进入新会话会误触发或漏报
        tempFailCount = 0
        probeVerifyLoops = 0
        lastProbeTime = .distantPast
        targetUnreachable = false
        targetUnreachableSince = nil
        targetUnreachableLogged = false
        boostExpiredLogged = false
        sensors.rescanAllSensors()
        hooks.schedule(0)
        hooks.log("系统唤醒：重新接管")
    }

    /// 退出前落盘（SIGTERM/看门狗外的正常退出路径）
    public func shutdownSave() {
        ConfigStore.saveStats(statsKeeper.stats)
        ConfigStore.saveLearn(thermalLearn)
        ConfigStore.saveModel(thermalModel)
        ConfigStore.saveAIMetrics(aiMetrics)
    }

    private func setSuspended(_ value: Bool) {
        watchdogLock.lock()
        suspended = value
        if !value { heartbeatValue = DispatchTime.now() }   // 唤醒即重置心跳，防误判挂死
        watchdogLock.unlock()
    }

    // MARK: - 每拍主逻辑（原 runControlLoop 逐行迁入）

    public func beat(fastConfigApply: Bool = false) {
        touchHeartbeat()   // 看门狗心跳：主队列仍在处理事件即为存活信号
        if isSuspendedForSleep { return }
        let loopStart = hooks.now()
        // 计算本拍实际经过时间（正常拍）。fastConfigApply 不推进时间基准，
        // 因此 AI dt 和统计采样反映的是真实控制周期，不受配置抖动干扰。
        let actualInterval: TimeInterval
        if !fastConfigApply {
            if let last = lastLoopStart {
                let elapsed = loopStart.timeIntervalSince(last)
                // 钳制：睡眠唤醒/时钟跳变后 elapsed 可能极大，限制到合理范围。
                // 上界 20s 对齐 idle 最大间隔（AIController 内部另有 [0.5,15] 钳制），
                // 统计秒数与 LearningGate 的 °C/s 语义在 idle 长拍下保持精确。
                actualInterval = min(max(elapsed, 0.5), 20.0)
            } else {
                actualInterval = currentLoopInterval
            }
            lastLoopStart = loopStart
        } else {
            actualInterval = currentLoopInterval
        }
        if !fastConfigApply { loopCount += 1 }

        // AI 热经验重置请求
        if FileManager.default.fileExists(atPath: FanCtlPaths.resetLearnFlag.path) {
            thermalLearn = ThermalLearn()
            learnDirty = true
            try? FileManager.default.removeItem(at: FanCtlPaths.resetLearnFlag)
            hooks.log("AI 热经验已重置，将从零重新积累")
        }

        // 1. 热加载配置
        let mtime = ConfigStore.configModificationDate() ?? .distantPast
        if mtime != lastConfigMTime {
            lastConfigMTime = mtime
            let newConfig = ConfigStore.loadConfig().sanitized()
            if newConfig != config {
                // 任何模式切换都重置 shape() 状态：
                // shape() 的 maxStepDown=6%/拍 是为同模式内的平滑过渡设计的，
                // 模式切换时旧 lastAppliedPercent 会拖累新目标（如 manual 100% → curve 30%，
                // shape 每拍只降 6%，需 12 拍≈36s 才到位）。clearOutput 让新模式从目标值直接起步。
                if newConfig.mode != config.mode {
                    controller.clearOutput()
                    hooks.log("模式切换 \(config.mode.rawValue)→\(newConfig.mode.rawValue)，重置 shape() 状态")
                }
                if newConfig.mode == .ai && config.mode != .ai {
                    aiController.reset()
                    lastAIOutput = nil
                    lastAIIntent = nil
                    aiIdleActive = false
                }
                // AI 目标温度变化：只重置评测指标（aiMetricsUserTarget 基准在下个评测拍生效），
                // 不清空学习数据（v2.9）。物理依据："稳住温度 T 需要多少风量"是散热系统
                // 的静态属性，与目标设定无关——闭环平衡点上输出与温度一一对应；
                // 目标变化只改变 ±4° 学习采样窗口。旧实现清空全部热经验（含 curve 模式
                // 积累的、与目标无关的数据），用户在 72/76/80 档位间切换一次就损失数周学习。
                if let oldTarget = config.aiTargetTemp, let newTarget = newConfig.aiTargetTemp,
                   abs(oldTarget - newTarget) > 0.5 {
                    hooks.log("AI 目标温度变化 \(oldTarget)→\(newTarget)，评测指标将在下次 AI 评测时重置（学习数据保留）")
                }
                config = newConfig
                hooks.log("配置已更新: mode=\(config.mode.rawValue) manual=\(Int(config.manualPercent))%"
                    + (config.fanOffsets != nil ? " offsets=\(config.fanOffsets!)" : "")
                    + (config.aiTargetTemp != nil ? " target=\(Int(config.aiTargetTemp!))°C" : ""))
            }
        }

        // 冲刺超时兜底：App 崩溃/退出后 config 保持 manual 100% 无限持续
        // （冲刺结束时间只存在 App 的 UserDefaults，daemon 读不到）。
        // boostUntil 过期 → 本拍起视为 auto 交还系统，直到 App 恢复并写入新配置。
        // 不修改 config 本身：App 重启后 init 仍能按 UserDefaults 恢复冲刺前状态。
        var effectiveConfig = config
        if let until = config.boostUntil, hooks.now() >= until, config.mode == .manual {
            effectiveConfig.mode = .auto
            if !boostExpiredLogged {
                hooks.log("冲刺超时已过，交还系统调度（等待 App 恢复）")
                boostExpiredLogged = true
            }
        } else {
            boostExpiredLogged = false
        }

        // 2. 读温度（完整传感器集合）
        let sensorReadings = sensors.sensorReadings()
        let rawTemp = sensorReadings.maxTemp

        if !rawTemp.isFinite || rawTemp <= 1 {
            tempFailCount += 1
            if tempFailCount >= 5 {
                if forcedModeActive {
                    hooks.log("温度读取连续失败，恢复系统自动调度并进入安全故障状态")
                    fans.restoreAutoAll()
                    forcedModeActive = false
                    lastWrittenRPM.removeAll()
                }
            } else {
                hooks.log("温度读取失败（第 \(tempFailCount) 次），暂不改变当前风扇输出")
            }
            if var status = lastStatus {
                status.timestamp = hooks.now()
                status.controlFault = true
                status.faultReason = .sensorUnavailable
                // 故障期决策主因不可信：沿用上一拍 reason 会显示"appliedPercent=0 却按曲线调速"
                status.reason = nil
                status.aiIntent = nil
                status.appliedPercent = forcedModeActive ? status.appliedPercent : 0
                status.appliedPercents = forcedModeActive ? status.appliedPercents : nil
                ConfigStore.saveStatus(status)
                lastStatus = status
            } else {
                // 启动即温度故障（无上一拍状态）：构造最小状态写出，
                // 否则 App 只能看到旧/缺失 status，无法感知传感器故障
                let s = DaemonStatus(sensors: SensorReadings(cpuDie: 0, gpuDie: 0),
                                     mode: config.mode, appliedPercent: 0, fans: [],
                                     timestamp: hooks.now(),
                                     controlFault: true, faultReason: .sensorUnavailable)
                ConfigStore.saveStatus(s)
                lastStatus = s
            }
            scheduleNext(interval: LOOP_INTERVAL_DEFAULT)
            return
        }
        tempFailCount = 0

        // 温度平滑
        guard let temp = controller.smooth(rawTemp: rawTemp) else {
            // v2.6.2：坏读 hold 拍（最多 3 拍，间隔最长 20s → 60s 无 status 更新）也写一次
            // 最小 status（旧值 + 新时间戳），否则 App 的 30s 存活阈值会误判 daemon 下线
            if var status = lastStatus {
                status.timestamp = hooks.now()
                ConfigStore.saveStatus(status)
                lastStatus = status
            }
            scheduleNext(interval: currentLoopInterval)
            return
        }

        // 3. 计算并应用目标
        let onBattery = hooks.onBattery()
        let powerWatts = sensors.systemPowerWatts
        if onBattery != lastOnBattery {
            if lastOnBattery != nil {
                hooks.log(onBattery ? "切换到电池供电" : "切换到电源供电")
            }
            lastOnBattery = onBattery
        }

        // v8 环境温度 + 夜间判断（上移到合理性门之前：偏低门需要环境参照）。
        // 谷值（物理量测）与 override（用户设定）分开取：偏低门参照只用谷值——
        // override 偏高 13°+ 时会把正常空闲芯片误判失真（审查 P2-2）
        let valleyEnv = sensors.ambientEstimate(now: hooks.now(), cpu: rawTemp)
        let envTemp = config.envTempOverride ?? valleyEnv
        // 读数偏低期 rawTemp 失真会让谷值的"贴近芯片"检查判 nil——保留最近合理谷值给偏低门
        if let e = valleyEnv { lastPlausibleEnvTemp = e }
        let hour = Calendar.current.component(.hour, from: hooks.now())
        let nightActive = hour >= 22 || hour < 8
        if let env = envTemp, config.envCompensation {
            let off = FanPipeline.envOffset(envTemp: env, enabled: true)
            if abs(off) >= 1, !envCompLogged {
                hooks.log("环境温度补偿: 环境 \(String(format: "%.0f", env))°C → 偏移 \(String(format: "%+.1f", off))°")
                envCompLogged = true
            }
        }

        // v2.8/v3.0 传感器物理一致性门（两类故障模式）：
        //   卡死门：功耗波动 ≥10W 而热点读数 5 分钟逐位不变——真实传感器必有 LSB 抖动；
        //   偏低门（v3.0）：芯片（发热源）不可能比环境冷 12°C——实测出现过 cpuDie 8.4° vs
        //     环境 30.5°；当 max 恰好取到偏低读数时 AI 会误判冰凉停转风扇、92° 兜底失明。
        // 计时按秒累计/衰减（对称消抖 90s）——按拍计数在 idle 20s 间隔下确认窗会膨胀到
        // 600s（审查 P1）；fast apply 拍不计时（currentLoopInterval 会虚增，且用户拖动
        // 滑块期间冻结判定无副作用）。判失真 → 交还系统，读数恢复 90s 后自动接管。
        let wasStuck = stuckDetector.faulted
        if stuckDetector.record(rawTemp: rawTemp, powerWatts: powerWatts, now: hooks.now()) {
            hooks.log("温度传感器疑似卡死: \(String(format: "%.1f", rawTemp))°C 持续 \(Int(StuckSensorDetector.minDuration / 60)) 分钟无任何变化而功耗波动 ≥\(Int(StuckSensorDetector.minPowerSwing))W，交还系统调度")
        }
        if wasStuck && !stuckDetector.faulted {
            hooks.log("温度读数恢复变化，传感器卡死解除，重新接管")
        }
        if let env = valleyEnv ?? lastPlausibleEnvTemp, env.isFinite, env > 5, rawTemp < env - 12 {
            if !fastConfigApply { belowAmbientSeconds = min(90, belowAmbientSeconds + actualInterval) }
        } else if !fastConfigApply {
            belowAmbientSeconds = max(0, belowAmbientSeconds - actualInterval)
        }
        // 双阈值锁存（审查 N1/N2）：≥90s 触发、衰减到 0 才解除。累计钳顶 90 使恢复
        // 恒为 90s 合理读数（否则恢复延迟 = 故障时长，长故障后"读数已好仍挂故障横幅"）；
        // 锁存消除边界抖动的逐拍 Md/状态翻转。
        if !belowAmbientFaulted, belowAmbientSeconds >= 90 {
            belowAmbientFaulted = true
            hooks.log("温度读数低于环境 12°C 持续 90s，判定读数失真，交还系统调度")
        }
        if belowAmbientFaulted, belowAmbientSeconds <= 0 {
            belowAmbientFaulted = false
            hooks.log("温度读数恢复合理区间 90s，偏低失真解除，重新接管")
        }
        if stuckDetector.faulted || belowAmbientFaulted {
            if forcedModeActive {
                fans.restoreAutoAll()
                forcedModeActive = false
                lastWrittenRPM.removeAll()
            }
            if var status = lastStatus {
                status.timestamp = hooks.now()
                status.controlFault = true
                status.faultReason = .sensorImplausible
                status.reason = nil
                status.aiIntent = nil
                status.appliedPercent = forcedModeActive ? status.appliedPercent : 0
                status.appliedPercents = forcedModeActive ? status.appliedPercents : nil
                ConfigStore.saveStatus(status)
                lastStatus = status
            } else {
                let s = DaemonStatus(sensors: SensorReadings(cpuDie: 0, gpuDie: 0),
                                     mode: config.mode, appliedPercent: 0, fans: [],
                                     timestamp: hooks.now(),
                                     controlFault: true, faultReason: .sensorImplausible)
                ConfigStore.saveStatus(s)
                lastStatus = s
            }
            scheduleNext(interval: LOOP_INTERVAL_DEFAULT)
            return
        }

        var aiPercent: Double? = nil
        var aiIntent: AIIntent? = nil
        var curveTargetPercent: Double? = nil  // 当前温度下用户曲线的期望值（AI 模式展示"曲线基准"）
        var guardArmedThisBeat = false         // v3.1 启停抑制本拍武装（战报计数用）
        var overshootNow: Double? = nil        // v3.2 本拍温度超出 AI 有效目标的量（战报过冲峰值用）
        // AI 实际控制的"目标温度"（电池+省电时控制器会放宽 +4°）。学习窗口与"压不住"检测
        // 都必须以它为准，否则会与控制器真实目标错位（电池省电下误判"压不住"/误挡学习）。
        // v8：环境补偿（夏天放宽/冬天收紧）+ 夜间安静档（+4° 更安静）叠加在用户目标之上
        // v2.6.2：目标钳位 ≤ failsafeRelease−4（84°）——环境+夜间+电池全叠可把目标推到
        // 89°C 以上(高于兜底释放线 88°),AI 在 88–92° 区间保持低转速会触发
        // "低转↔92° 全速↔88° 释放↔低转"的周期性振荡,学习窗口与"压不住"检测也全部失真
        let envOff = FanPipeline.envOffset(envTemp: envTemp, enabled: config.envCompensation)
        // v3.3 体感补偿：掌托超阈值（>40°）→ 适度收紧（AI 目标降低、曲线查表右移）。
        // 掌托数据用本拍已读的传感器读数；无效/低于阈值 → 0（零噪声代价）
        let palmComp = FanPipeline.palmComp(palmRest: sensorReadings.palmRest,
                                            enabled: effectiveConfig.palmCompensation)
        let aiTargetEff = effectiveConfig.mode == .ai
            ? max(60, min(FanPipeline.failsafeReleaseTemp - 4,
                  AIController.effectiveTarget(config.aiTargetTemp ?? 76, onBattery: onBattery,
                                               batterySaver: config.batteryPreset != nil)
                    + envOff
                    + (nightActive && config.quietHours ? 4 : 0)
                    - palmComp))
            : (config.aiTargetTemp ?? 76)
        // 静音承诺生效判定（hoist：AI 空闲交还抑制与评测排除共用同一判定）
        let quietActive = config.quietUntil != nil && config.quietCapPercent != nil
            && hooks.now() < config.quietUntil!
        if effectiveConfig.mode == .ai {
            aiController.tuning.targetTemp = aiTargetEff
            // 曲线插值：AI 的期望转速基准（v9 曲线锚定/种子/前馈共用）。fastConfigApply 也计算，
            // 保证 UI 能持续展示"曲线基准 vs AI 实际"的协同关系。
            // 查表温度减 envOff：与曲线模式的实际执行语义一致（曲线模式按 temp-envOff 查表），
            // 否则夏天 AI 稳态锚定值会高于用户曲线真正会执行的输出，"曲线基准"UI 刻度也失真。
            // 曲线源用 activeCurve（电池档 > 夜间档 > 基础曲线，与 decide() 的选择链一致）：
            // 电池省电时目标放宽 +4°（工作点更热），基础曲线在更热温度上期望值反而更高，
            // 用基础曲线锚定会把 AI 稳态拉向高转速——与省电意图正相反；夜间安静档同理。
            let anchorCurve = FanPipeline.activeCurve(config: effectiveConfig,
                                                      onBattery: onBattery, nightActive: nightActive)
            let curvePct = FanConfig.percent(temp: temp - envOff, curve: anchorCurve)
            curveTargetPercent = curvePct
            if fastConfigApply {
                aiPercent = lastAIOutput
                aiIntent = lastAIIntent
            } else {
                // 学习查表与参数模型互补：模型成熟（≥30 样本）时用其外推预测，
                // 与查表取较大者（模型能覆盖查表没见过的温度/负载组合）
                let learnedPct = thermalLearn.percent(for: temp, onBattery: onBattery,
                                                      powerWatts: powerWatts)
                let modelPct = thermalModel.predictedPercent(for: envTemp ?? 25,
                                                             power: powerWatts ?? 0,
                                                             targetTemp: aiTargetEff)
                let feedPct: Double? = {
                    switch (learnedPct, modelPct) {
                    case let (l?, m?): return max(l, m)
                    case let (l?, nil): return l
                    case let (nil, m?): return m
                    case (nil, nil): return nil
                    }
                }()
                let components = hooks.powerComponents()
                aiPercent = aiController.step(temp: temp,
                                              learned: feedPct,
                                              curvePercent: curvePct,
                                              powerWatts: powerWatts,
                                              cpuPower: components.cpu,
                                              gpuPower: components.gpu,
                                              allowRelease: !quietActive,
                                              dt: actualInterval)
                lastAIOutput = aiPercent
                lastAIIntent = aiController.intent(temp: temp)
                aiIntent = lastAIIntent
            }
        }
        // v2.9.2/v3.1 启停循环抑制边沿日志（释放后快速被夺回 = 被动平衡高于夺回线）
        if aiController.cyclingGuardArmed != aiCyclingGuardActive {
            guardArmedThisBeat = aiController.cyclingGuardArmed
            aiCyclingGuardActive = aiController.cyclingGuardArmed
            let gmin = Int(aiController.currentGuardSeconds / 60)
            let gtext = gmin >= 120 ? "\(gmin / 60) 小时" : "\(gmin) 分钟"
            hooks.log(aiCyclingGuardActive
                ? "AI: 检测到停转-启转循环（被动热浸泡平衡高于夺回线），抑制期内保持最低转速稳定运行（\(gtext)后重试交还）"
                : "AI: 启停循环抑制解除，恢复空闲交还评估")
        }

        let nandTemp = sensorReadings.ssd ?? 0
        let battTemp = sensors.batteryTemperature
        let decision = FanPipeline.decide(config: effectiveConfig, smoothedTemp: temp, rawTemp: rawTemp,
                                          nandTemp: nandTemp, onBattery: onBattery,
                                          aiPercent: aiPercent, now: hooks.now(),
                                          nightActive: nightActive,
                                          envTemp: envTemp,
                                          palmComp: palmComp,
                                          wasSSDGuardActive: ssdGuardActive,
                                          wasSSDCriticalActive: ssdCriticalActive,
                                          wasFailsafeActive: failsafeActive,
                                          battTemp: battTemp,
                                          wasBatteryGuardActive: batteryGuardActive,
                                          wasBatteryCriticalActive: batteryCriticalActive)

        var reason = decision.reason
        // AI 空闲交还判定：AI 模式下 aiPercent 为 nil（AI 主动交还）且没有被托底/兜底覆盖
        let aiIdleNow = effectiveConfig.mode == .ai && aiPercent == nil && reason == .ai
        if aiIdleNow { reason = .aiIdle }

        // 边沿日志（状态翻转才打）
        if aiIdleNow != aiIdleActive {
            if aiIdleNow {
                hooks.log("AI: 持续低负载，交还系统调度（风扇有机会降转/停转）")
            } else {
                if effectiveConfig.mode == .ai {
                    hooks.log("AI: 负载回升，重新接管风扇")
                }
            }
            aiIdleActive = aiIdleNow
        }

        if decision.ssdGuard != ssdGuardActive {
            ssdGuardActive = decision.ssdGuard
            hooks.log(ssdGuardActive
                ? "SSD 高温托底触发: NAND \(String(format: "%.1f", nandTemp))°C"
                : "SSD 温度回落: NAND \(String(format: "%.1f", nandTemp))°C")
        }
        ssdCriticalActive = decision.ssdCriticalActive
        if decision.batteryGuard != batteryGuardActive {
            batteryGuardActive = decision.batteryGuard
            hooks.log(batteryGuardActive
                ? "电池高温托底触发: \(String(format: "%.1f", battTemp))°C"
                : "电池温度回落: \(String(format: "%.1f", battTemp))°C")
        }
        batteryCriticalActive = decision.batteryCriticalActive
        if decision.failsafeActive != failsafeActive {
            failsafeActive = decision.failsafeActive
            hooks.log(failsafeActive
                ? "高温兜底触发: \(String(format: "%.1f", rawTemp))°C ≥ \(Int(FanPipeline.failsafeTemp))°C，全速运行"
                : "高温兜底解除: \(String(format: "%.1f", rawTemp))°C")
        }

        let targetPercent = decision.targetPercent

        // 一次性读取所有风扇状态
        let fanStates = fans.allStates()
        // 验证期（probeVerifyLoops > 0）用严格检查（无升速宽限），探测真实故障。
        // fastConfigApply 拍只更新命令基线不计数：快速下拖时限速行程在数百 ms 内走完
        // 而 RPM 物理回落需 1-3s，逐拍计 mismatch 会稳定误判闭环失效（v2.8 审查 P1）
        if fastConfigApply {
            feedbackHealth.recordCommandOnly(states: fanStates, commandedRPM: lastWrittenRPM)
        } else {
            feedbackHealth.record(states: fanStates, commandedRPM: lastWrittenRPM,
                                  risingGrace: probeVerifyLoops <= 0)
        }
        var writtenRPM: [Int: Double] = [:]
        var appliedPercents: [Double] = []
        var appliedPercent = 0.0

        if let baseTarget = targetPercent {
            // 升降速限速作用于最终 applied 输出（shapedBase）：
            //   - 曲线模式：shape() = 升降速限速 + 死区，平滑曲线查表的阶跃。
            //   - AI 模式：slew() = 纯升降速限速（无死区）。AI 控制器本身是平滑积分 PD，
            //     不能再叠加死区（死区会吞噬其 1-4% 微调、与 PD 叠加会因相位 lag 振荡），
            //     但同样要遵守"缓慢升降"规律，故用 slew() 与曲线共用同一套 maxStepUp/maxStepDown。
            let shapedBase: Double
            if effectiveConfig.mode == .ai {
                // AI 模式同样遵守"缓慢升降"规律：经 slew() 加升降速限速（无死区，避免吞噬 PD 微调）。
                // shape() 的死区在 AI 下禁用（会与 PD 叠加振荡），故用纯限速的 slew()，与曲线共用同一套 maxStepUp/maxStepDown。
                // 安全事件（SSD/电池/兜底）force 跳过限速；AI 空闲夺回时 last 已清、直接到位，负载突增响应不滞后。
                shapedBase = controller.slew(target: baseTarget,
                                             force: decision.ssdGuard || decision.batteryGuard || decision.failsafeActive,
                                             hysteresis: effectiveConfig.mode == .ai ? 4 : 0)
            } else {
                shapedBase = controller.shape(target: baseTarget,
                                              force: decision.ssdGuard || decision.batteryGuard || decision.failsafeActive)
            }

            // 计算每个风扇的独立百分比（基础值 + 独立偏移）
            // 双风扇共享散热片（气流串联），降低任一风扇都减少总散热能力。
            // 实测 Apple Silicon 上 CPU/GPU 同 die 温差 <5°C，自动协同无意义；
            // Intel MBP 上 fan 0/1 物理映射未经 Apple 确认，错降热侧风扇风险 > 噪音收益。
            // 用户如有特殊需求可用 fanOffsets 手动调整（钳位 ±20%）。
            // 偏移量用 st.id（SMC 风扇 ID）索引：fanOffsets[0] 对应风扇 0，fanOffsets[1] 对应风扇 1。
            // 若用 enumerated index i，当某个风扇状态读取失败被 compactMap 跳过时，
            // fanStates[0].id 可能是 1（风扇 0 失败），偏移会用错风扇——
            // 风扇 1 拿了风扇 0 的偏移，违反用户配置意图。
            // percents 仍按 fanStates 顺序构建（与 appliedPercents 语义一致：appliedPercents[i] 对应 fans[i]）。
            // 安全事件（SSD 托底/电池托底/高温兜底）时偏移不叠加：100% 兜底是硬件安全红线，
            // 偏移 -20 会把 100% 削成 80%，静默削弱散热保护。force 已跳过限速，
            // 偏移也必须一并旁路，才能保证"瞬时写满目标"的语义完整。
            let safetyActive = decision.ssdGuard || decision.batteryGuard || decision.failsafeActive
            var percents: [Double] = []
            for st in fanStates {
                if safetyActive {
                    percents.append(shapedBase)
                } else {
                    let offset = config.offsetForFan(index: st.id)
                    let fanPct = max(0, min(100, shapedBase + offset))
                    percents.append(fanPct)
                }
            }
            appliedPercents = percents

            // fanStates 为空时说明 SMC 读取全部失败但风扇存在，不能设置 appliedPercent
            // （否则 status.json 会显示一个未实际施加的虚假值，与 controlFault=true 矛盾）。
            // 保持 appliedPercent=0（初始值），让 App 通过 controlFault 判断调速失效。
            if !fanStates.isEmpty {
                appliedPercent = shapedBase
            }

            // 热经验学习（仅正常拍、基础模式决策时）
            // 排除 .manual：手动模式的输出是用户意图，不反映"该温度需要多少风量"的热物理，
            // 记入会污染学习数据（如散热测试 100% 会让 AI 切回后每次升温前馈都拉回 100%）
            // 记录 baseTarget（决策原始输出）而非 shapedBase（限速后）：
            //   shapedBase 受 controller.shape 降速限速影响（每拍最多降 6%），
            //   从 manual=100% 切到 AI 时 shapedBase 会长时间卡在高位，
            //   若记录 shapedBase 会把"限速过渡态"误学为"该温度的稳态需求"，
            //   形成 AI 夺回→learned=高位→output=高位→shape 死区不变→继续记录高位的正反馈锁死。
            //   baseTarget 才是"该温度真正需要多少风量"的判断（曲线插值/AI 控制律输出）。
            // 稳态判定（6 个条件，阈值按秒标定见 LearningGate）：
            //   1. 温度稳定（<0.12°C/s）
            //   2. 风量稳定（baseTarget 变化 <1%/s）：确保 PID 已收敛
            //   3. baseTarget ≈ shapedBase（差值 <3%）：slew()/shape() 没在限速，说明系统真正达到了平衡
            //      AI 模式经 slew() 限速，斜坡期两者不恒等、学习被抑制（正是期望：只记稳态）；
            //      曲线模式 shape() 可能限速，同样不记录（因为热平衡是 shapedBase 达成的，不是 baseTarget）
            //   4. 温度在目标附近（AI 模式）：|temp - target| ≤ 4°C
            //      只在 AI 成功控制温度时才学习，过冲/过冷时 output 不反映"稳态需求"。
            //      curve/battery 模式无目标概念，不检查此条件。
            //   5. baseTarget 不在极低（>5%）：0% 是交还后的默认值，不反映真实需求
            // v3.4.5（3A）：高温饱和门——AI 模式、温度高于目标、输出饱和（≥90%）时
            // 也记录："压不住时的真实需求上限"恰是过冲区间（目标+4°以上）最值钱的先验，
            // 旧门（|temp−target|≤4 且 baseTarget<95）让该区域永远学不到（82°+ 桶空）。
            // 低温饱和（<5%）仍排除：0% 是交还默认值；温度上界（目标+15°）防御
            // 兜底边缘的极端瞬态；稳态门（LearningGate）继续生效排除瞬态采样。
            let overTargetSaturated = effectiveConfig.mode == .ai
                && temp > aiTargetEff
                && temp <= aiTargetEff + 15
                && baseTarget >= 90
            let tempNearTarget = effectiveConfig.mode != .ai
                || abs(temp - aiTargetEff) <= 4.0
                || overTargetSaturated
            let baseTargetNotSaturated = baseTarget > 5 && (baseTarget < 95 || overTargetSaturated)
            // v2.7: 稳态判定阈值改按秒标定（LearningGate）——每拍语义在自适应间隔下严格度漂移
            if !fastConfigApply, let prevT = prevSmoothedTemp,
               let prevBase = prevBaseTarget,
               LearningGate.isSteady(temp: temp, prevTemp: prevT,
                                     baseTarget: baseTarget, prevBase: prevBase,
                                     shapedBase: shapedBase, dt: actualInterval),
               tempNearTarget, baseTargetNotSaturated,
               (reason == .curve || reason == .ai || reason == .battery),
               !decision.nightOverride,   // 夜间目标/曲线不同，样本语义与白天不一致，跳过
               !decision.ssdGuard, !decision.batteryGuard, !decision.failsafeActive,
               !writeHealth.faulted, !feedbackHealth.faulted, !fanStates.isEmpty {
                thermalLearn.record(temp: temp, percent: baseTarget, onBattery: onBattery,
                                    powerWatts: powerWatts)
                // v8 散热参数辨识：同一稳态样本喂线性模型（环境 + a·功耗 − b·风量 ≈ 温度）。
                // 环境代理不可用时模型无法学习（跳过，不影响查表学习）
                if let env = envTemp, let pw = powerWatts {
                    thermalModel.update(env: env, power: pw, percent: baseTarget, temp: temp)
                    modelDirty = true
                }
                lastLearnAt = hooks.now()
                learnDirty = true
            }
            // 仅正常拍推进 prevSmoothedTemp/prevBaseTarget，避免 fastConfigApply 污染稳态判定基准
            if !fastConfigApply {
                prevSmoothedTemp = temp
                prevBaseTarget = baseTarget
            }

            // AI 目标温度"压不住"检测：
            // 风扇持续满速(≥98%) 且温度高于目标+4°C（离开学习窗口）时，热经验学习必然停滞
            // （饱和输出 baseTarget≥95 被过滤 + 温度高于 target+4 也不满足学习窗口）。
            // 这是用户目标设得过激进（如性能72°C 在当前负载下硬件压不到）的典型特征，
            // 持续 60s 判定、状态切换时各打一次日志，避免刷屏。
            if effectiveConfig.mode == .ai, !fastConfigApply {
                let target = aiTargetEff
                let saturated = shapedBase >= 98
                let aboveWindow = temp > target + 4
                if saturated && aboveWindow {
                    if targetUnreachableSince == nil { targetUnreachableSince = hooks.now() }
                    if hooks.now().timeIntervalSince(targetUnreachableSince!) >= 60, !targetUnreachableLogged {
                        targetUnreachable = true
                        targetUnreachableLogged = true
                        hooks.log("AI 目标 \(Int(target))°C 压不住：当前 \(String(format: "%.1f", temp))°C 仍高于目标+4°，风扇已满速。")
                        hooks.log("  学习已停滞（饱和输出+温度离开学习窗口）。建议提高目标温度（均衡76°或静音80°）再观察。")
                    }
                } else {
                    targetUnreachableSince = nil
                    if targetUnreachableLogged {
                        targetUnreachable = false
                        targetUnreachableLogged = false
                        hooks.log("AI 目标温度可达成，恢复正常学习")
                    }
                }
            }

            // 闭环故障（SMC 写入连续失败 / 风扇实际转速持续不跟随）：
            // 交还系统调度并保持——此前 faulted 后下一拍 mustReassert 立即重新写回，
            // 形成"交还→夺回"每 ~6 拍一轮的振荡（restoreAutoAll 清空 lastWrittenRPM 后
            // 反馈检查单拍即清零 fault），Md 翻转还会打断 EC 的升速斜坡自我延长。
            // v2.6.2 试探协议（写-验证-交还，30s 时间基准）：
            //   1. 试探拍：写入目标（SMC 保持强制模式）→ 验证期 3 拍让风扇物理爬升，
            //      feedbackHealth.record 用 lastWrittenRPM 检查跟随；
            //   2. 连续 3 拍匹配 → fault 解除 → 恢复正常控制；
            //   3. 验证失败 → 交还系统，30s 后再试探。
            // 此前 probe 后不交还，SMC 被钉在过期强制 RPM 上（status 却报"已交还"），
            // 且周期按拍数（idle 20s/拍时 6 分钟才探一次）。
            let controlBlocked = writeHealth.faulted || feedbackHealth.faulted
            if controlBlocked {
                let probeDue = hooks.now().timeIntervalSince(lastProbeTime) >= 30
                if probeDue, probeVerifyLoops <= 0 {
                    lastProbeTime = hooks.now()
                    var probeOK = !fanStates.isEmpty
                    for (i, st) in fanStates.enumerated() {
                        do {
                            let pct = i < percents.count ? percents[i] : shapedBase
                            let rpm = fans.rpm(forPercent: pct, state: st)
                            try fans.setForcedRPM(state: st, rpm: rpm)
                            lastWrittenRPM[st.id] = rpm
                        } catch {
                            probeOK = false
                            hooks.log("故障试探写入失败: \(error)")
                        }
                    }
                    writeHealth.record(loopSuccess: probeOK)
                    if probeOK {
                        probeVerifyLoops = 3   // 验证期：保持强制模式，让风扇爬升并接受 record 检查
                        hooks.log("故障试探写入成功，进入跟随验证（3 拍）…")
                    }
                }
                if probeVerifyLoops > 0 {
                    // 验证期拍：不重写、不交还，feedbackHealth.record（拍首已调用）
                    // 用 lastWrittenRPM 检查风扇是否跟随；3 拍后仍 faulted → 下拍交还
                    probeVerifyLoops -= 1
                } else {
                    if forcedModeActive {
                        fans.restoreAutoAll()
                        forcedModeActive = false
                        lastWrittenRPM.removeAll()
                        hooks.log(feedbackHealth.faulted
                            ? "风扇实际 RPM 持续未跟随目标，调速闭环失效，已交还系统调度"
                            : "风扇写入连续失败，调速闭环失效，已交还系统调度")
                    }
                    appliedPercent = 0
                    appliedPercents = []
                }
            } else {
                let mustReassert = !forcedModeActive || loopCount % REASSERT_LOOPS == 0
                var loopWriteFailed = false
                // fanStates 为空但 targetPercent 非 nil 时，说明 SMC 读取全部失败（风扇状态严格读取
                // 后失败风扇被跳过）或风扇键缺失，不能当作"写入成功"——
                // 否则 writeHealth 永远不会 fault，形成静默故障。
                if fanStates.isEmpty {
                    loopWriteFailed = true
                    hooks.log("风扇状态读取全部失败（\(fans.fanCount) 个风扇），记为写入失败")
                }
                for (i, st) in fanStates.enumerated() {
                    do {
                        let pct = i < percents.count ? percents[i] : shapedBase
                        let rpm = fans.rpm(forPercent: pct, state: st)
                        let lastRPM = lastWrittenRPM[st.id] ?? -1e9
                        if mustReassert || abs(lastRPM - rpm) > RPM_DEADBAND {
                            try fans.setForcedRPM(state: st, rpm: rpm)
                            lastWrittenRPM[st.id] = rpm
                        }
                        writtenRPM[st.id] = lastWrittenRPM[st.id]
                    } catch {
                        loopWriteFailed = true
                        hooks.log("风扇 \(st.id) 写入失败: \(error)")
                    }
                }
                // 执行链可观测性：连续写失败超阈值 → 闭环已失效，交还系统并上报，
                // 避免 daemon"以为在控制"而风扇实际无人管的静默故障
                writeHealth.record(loopSuccess: !loopWriteFailed)
                forcedModeActive = true
            }

            // AI 评测只记录真实接管、无安全覆盖、无静音封顶、反馈健康的样本。
            // v2.9：排除静音封顶期——会议中 temp 高而输出被 cap 30% 的样本会让
            // "均温/超温/平均输出"系统性变差，用户会误判 AI 退化；
            // 过冲/超温基准改用有效目标（环境/夜间/电池叠加后），否则夏天凭空多算超温
            if effectiveConfig.mode == .ai, !fastConfigApply, !quietActive, !decision.ssdGuard,
               !decision.batteryGuard, !decision.failsafeActive,
               !writeHealth.faulted, !feedbackHealth.faulted, !fanStates.isEmpty,
               let output = decision.targetPercent {
                let userTarget = config.aiTargetTemp ?? 76
                if aiMetricsUserTarget != userTarget {
                    aiMetrics = AIControlMetrics(targetTemp: aiTargetEff, userTargetTemp: userTarget)
                    aiMetricsUserTarget = userTarget
                }
                aiMetrics.targetTemp = aiTargetEff   // 过冲/超温基准用有效目标（环境/夜间/电池叠加后）
                aiMetrics.userTargetTemp = userTarget
                aiMetrics.record(temp: temp, output: output, seconds: actualInterval)
            }
            // v3.2 过冲观察：与 aiMetrics 同一排除集（静音封顶是用户意图而非控制失效，
            // 安全覆盖/闭环故障期的温度不反映 AI 控制质量——混入会让 τ 自适应的
            // 数据门槛被会议日/故障日误触发）；空闲交还拍 max(0, …) = 0 自然无贡献
            if !quietActive, !writeHealth.faulted, !feedbackHealth.faulted, !fanStates.isEmpty {
                overshootNow = max(0, temp - aiTargetEff)
            }
        } else {
            // auto / AI 空闲交还：只在状态切换时恢复一次
            if forcedModeActive {
                fans.restoreAutoAll()
                forcedModeActive = false
                lastWrittenRPM.removeAll()
                controller.clearOutput()
                if reason != .aiIdle {
                    hooks.log("切换到系统自动调度")
                }
            }
            // 不在 AI 主动调速时，清除"目标压不住"状态（避免切出 AI 后残留 stale 标志）
            if targetUnreachableLogged {
                targetUnreachable = false
                targetUnreachableLogged = false
            }
            targetUnreachableSince = nil
        }

        // 4. 每日统计累计（用实际循环间隔，自适应后不再固定 3s）
        let fanEntries = fanStates.map { st -> FanStatusEntry in
            FanStatusEntry(id: st.id, actualRPM: st.actualRPM,
                           targetRPM: writtenRPM[st.id] ?? st.targetRPM,
                           minRPM: st.minRPM, maxRPM: st.maxRPM)
        }
        // v2.8 调速次数：|输出Δ|≥3% 记一次（风扇寿命代理指标，战报展示）
        let speedChanged = prevStatsAppliedPercent.map { abs(appliedPercent - $0) >= 3 } ?? false
        if !fastConfigApply {
            statsAccumSeconds += actualInterval
            if let archived = statsKeeper.record(temp: rawTemp,
                                                 totalRPM: fanStates.reduce(0) { $0 + $1.actualRPM },
                                                 seconds: actualInterval, now: hooks.now(),
                                                 powerWatts: powerWatts,
                                                 reason: reason,
                                                 speedChange: speedChanged,
                                                 cyclingGuard: guardArmedThisBeat,
                                                 overshoot: overshootNow) {
                ConfigStore.archiveDay(archived)
            }
            prevStatsAppliedPercent = appliedPercent
            // 约每 60 秒落盘一次（自适应间隔下用累计秒数判断，不依赖 loopCount）
            if statsAccumSeconds >= 60 {
                statsAccumSeconds = 0
                ConfigStore.saveStats(statsKeeper.stats)
                if learnDirty {
                    ConfigStore.saveLearn(thermalLearn)
                    learnDirty = false
                }
                if modelDirty {
                    ConfigStore.saveModel(thermalModel)
                    modelDirty = false
                }
                ConfigStore.saveAIMetrics(aiMetrics)
            }
        }
        // 无条件更新 prevRawTemp：fastConfigApply 期间温度也在变化，
        // 不更新会导致下次正常循环 tempChange=|raw-prevRaw| 偏大（包含 fastConfigApply 期间变化），
        // 被 computeNextInterval 误判为"温度快速变化"，强制使用 LOOP_INTERVAL_MIN（1s），
        // 增加能耗和 SMC 访问。更新后 tempChange 只反映两次循环间的真实变化。
        prevRawTemp = rawTemp

        // 5. 写完整状态（含所有传感器数据，App 无需直读 SMC）
        //    变化感知：稳态时温度/RPM 可能仅微小波动，无实质变化时跳过磁盘写入，
        //    避免每 3–5s 唤醒 App 解析 JSON。最多 10s 心跳保证 App 不超过 10s 无更新。
        let loopIntervalToReport = currentLoopInterval
        // v2.6.2：故障期 reason 置 nil——appliedPercent=0 却显示"按曲线调速"是自相矛盾
        let faultActive = writeHealth.faulted || feedbackHealth.faulted || stuckDetector.faulted
        let status = DaemonStatus(
            sensors: sensorReadings,
            mode: effectiveConfig.mode,
            appliedPercent: appliedPercent,
            appliedPercents: appliedPercents.isEmpty ? nil : appliedPercents,
            fans: fanEntries,
            onBattery: onBattery,
            batteryOverride: decision.batteryOverride,
            reason: faultActive ? nil : reason,
            aiIntent: (effectiveConfig.mode == .ai && reason != .aiIdle && !faultActive) ? aiIntent : nil,
            loopInterval: loopIntervalToReport,
            controlFault: faultActive ? true : nil,
            faultReason: stuckDetector.faulted ? .sensorImplausible
                : (feedbackHealth.faulted ? .fanFeedbackMismatch
                   : (writeHealth.faulted ? .smcWriteFailed : nil)),
            baseTargetPercent: decision.baseTargetPercent,
            safetyFloorPercent: decision.safetyFloorPercent,
            curveTargetPercent: curveTargetPercent,
            learningRecently: lastLearnAt.map { hooks.now().timeIntervalSince($0) < 120 } ?? false,
            learnedPoints: thermalLearn.learnedBucketCount,
            learnedSamples: thermalLearn.sampleTotal,
            targetUnreachable: (effectiveConfig.mode == .ai && targetUnreachable) ? true : nil,
            powerWatts: powerWatts,
            // v2.6.2：直接用 decision.nightOverride(此前用 reason == .night,静音封顶在场时
            // reason 变 .quiet 但夜间仍生效,标记会丢失);AI 模式夜间(+4°)同样标记,
            // 高优先级覆盖(SSD/电池/兜底)时清除
            nightOverride: (nightActive && config.quietHours
                            && (decision.nightOverride || effectiveConfig.mode == .ai)
                            && !decision.ssdGuard && !decision.batteryGuard
                            && !decision.failsafeActive) ? true : nil,
            envTemp: envTemp,
            aiTargetEffective: effectiveConfig.mode == .ai ? aiTargetEff : nil,
            palmComp: palmComp > 0.5 ? palmComp : nil,
            // v3.6（方向二·数据裁判）：高温段包络健康度——AI 模式在当前温度下报告
            // （88° 等过冲区旧数据被新样本洗净后 →0；观察协议见 EVOLUTION.md）
            learnEnvelopeGap: (effectiveConfig.mode == .ai) ? thermalLearn.envelopeGap() : nil
        )

        let summary = statusChangeSummary(status)
        let now = hooks.now()
        let heartbeatDue = now.timeIntervalSince(lastStatusWrite) >= 10
        // #8: 每 3 正常拍即使 summary 未变也强制写一次，保证 App deglitch 能检测到 daemon 存活
        if !fastConfigApply { forceWriteCounter += 1 }
        let forceWrite = !fastConfigApply && forceWriteCounter >= 3
        // v3.4.5（2A）：删除 `fastConfigApply ||` 短路——statusChangeSummary 已含
        // appliedPercent(s)/mode/reason，输出一变 summary 必变本就会写；App 对自己
        // 写的 config 有乐观 UI，fast 拍无条件写盘只造成拖滑块时 ~10 次/秒的
        // 全量 JSON 编码+原子写。fast-apply 后调度的 2s 跟进正常拍仍会把 RPM
        // 物理爬升反映到 status。
        if summary != lastStatusSummary || heartbeatDue || forceWrite {
            ConfigStore.saveStatus(status)
            lastStatusSummary = summary
            lastStatusWrite = now
            if !fastConfigApply { forceWriteCounter = 0 }
        }
        // 即使变化感知跳过磁盘写入，也保留内存中的最新状态，供传感器故障路径立即标注原因。
        lastStatus = status

        // 6. 计算下一循环间隔并重排定时器
        if !fastConfigApply {
            let nextInterval = computeNextInterval(
                rawTemp: rawTemp, targetPercents: appliedPercents.isEmpty ? nil : appliedPercents,
                fanStates: fanStates, onBattery: onBattery)
            scheduleNext(interval: nextInterval)
            // #6: 自适应功耗采样间隔（高温/AI 主动控温 → 10s，凉机 → 60s，默认 20s）。
            // AI 空闲交还后（aiIdleActive）风扇归系统调度，分项功耗只喂 AI 前馈，
            // 此期间高频采样纯属浪费电——按非 AI 对待；温度 <55°C 时不分模式一律 60s
            if rawTemp >= 80 || (effectiveConfig.mode == .ai && !aiIdleActive) {
                hooks.setPowerInterval(10)
            } else if rawTemp < 55 {
                hooks.setPowerInterval(60)
            } else {
                hooks.setPowerInterval(20)
            }
        } else {
            // fastConfigApply 刚写了目标 RPM，但风扇物理加速/减速需要 1-3s。
            // 立即调度一次 2s 跟进循环，让 actualRPM 的变化快速反映到 status.json，
            // 而不是等下一个正常循环（稳态时可能 5-20s 后）。
            scheduleNext(interval: 2.0)
        }
    }

    // MARK: - 自适应循环间隔计算（原 main.swift 顶层函数迁入）

    private func computeNextInterval(rawTemp: Double, targetPercents: [Double]?,
                                     fanStates: [FanState], onBattery: Bool) -> TimeInterval {
        // 高温兜底/SSD 托底/电池托底活跃时保持短间隔快速响应
        if failsafeActive || ssdGuardActive || batteryGuardActive { return LOOP_INTERVAL_MIN }

        let tempChange = abs(rawTemp - prevRawTemp)
        let hot = rawTemp >= 80
        let warm = rawTemp >= 70

        // 温度快速变化（2 拍温差 > 3°C，对应 >1°C/s）
        if tempChange > 3 { return LOOP_INTERVAL_MIN }
        // 温度在变（温差 > 1°C）
        if tempChange > 1 { return LOOP_INTERVAL_DEFAULT }
        // 温度高（≥80°C）即使稳定也保持中间隔监控
        if hot { return LOOP_INTERVAL_DEFAULT }
        // 电池供电 + 安静档 + 温度不高 → 拉长间隔省电
        if onBattery && config.batteryPreset != nil && !warm { return LOOP_INTERVAL_COOL }
        // 风扇在最低转速 + 温度凉爽（<60°C）→ 长间隔
        // 注意：fanStates 为空时 allSatisfy 返回 true（空真命题），需显式排除
        // targetPercents（appliedPercents）按 fanStates 顺序构建，索引 i 对应 fanStates[i]，
        // 不能用 st.id 索引——当某个风扇状态读取失败被 compactMap 跳过时，
        // fanStates[0].id 可能是 1，targets[1] 会越界（targets.count=1）导致 allAtMin 永远 false，
        // 即使所有可用风扇都在最低转速也不会进入 LOOP_INTERVAL_IDLE，浪费能耗。
        let allAtMin = !fanStates.isEmpty && fanStates.enumerated().allSatisfy { (i, _) in
            guard let targets = targetPercents, i < targets.count else { return false }
            return targets[i] < 5  // 百分比 <5% 视为最低转速
        }
        if allAtMin && rawTemp < 55 { return LOOP_INTERVAL_IDLE }
        // 负载结束回落期：温度已降但输出仍高位（>25%）时保持短间隔。
        // 否则 10s 长间隔 × 降速限速 6%/拍 → 80%→0% 需 ~140s，风扇在任务结束后长时间不安静；
        // 短间隔让降速限速尽快到位（参数按 3s 标称拍调校）
        if let lastOut = controller.lastAppliedPercent, lastOut > 25 { return LOOP_INTERVAL_DEFAULT }
        // 温度温和（<70°C）且稳定
        if !warm { return LOOP_INTERVAL_COOL }
        // 默认稳态间隔
        return LOOP_INTERVAL_STABLE
    }

    private func scheduleNext(interval: TimeInterval) {
        currentLoopInterval = interval
        hooks.schedule(interval)
    }
}
