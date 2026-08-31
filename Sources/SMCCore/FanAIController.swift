import Foundation

// MARK: - AI 自动接管控制器（纯逻辑，守护进程与仿真共享）
//
// 与「智能加强(曲线)」的本质区别：
//   - 曲线模式 = 静态查表：当前温度 → 固定百分比，不看温度怎么变。
//   - AI 模式 = 目标导向的预测控制：盯目标温度 + 强趋势前馈，自动收敛到
//     “能压住目标温度的最低转速”，对任意散热能力的机器都收敛到目标（积分作用自适应）。
//
// 控制律（速度式 PD，本身含积分作用）：每拍 output += kP·clampedError·dt_nom + kD·clampedSlope·(1/dt_nom)，clamp[0,100]
//   误差 error = 平滑温度 − 目标温度      （正=偏热，需加速）
//   斜率 slope = 本拍温度 − 上拍温度      （正=正在升温 → 前馈提前加速，不等烫了才反应）
// dt_nom = dt / 3.0（标称拍长 3s），使 kP/kD 的物理语义不随自适应间隔变化：
//   P 项按时间线性缩放（间隔越长推动越大），D 项按斜率速率缩放（短间隔斜率小但增益大，保持同等前馈强度）。
// 增量式（output 作为积分状态）使"持续偏差"持续推动输出，自然收敛到 error≈0；
// 这也意味着稳态温度已对任意散热能力自适应（无需额外"学习"回路）。
//
// v3 增强（噪声抑制 + 冷启动前馈）：
//   1. 斜率死区（slopeDeadband=0.15°C/s）：|斜率率|<阈值时 D 项归零。传感器 ±0.3°C 抖动
//      会被 kD=8 放大成 ~2.4%/拍 的输出波动——死区在噪声带内静默 D 项，消除稳态风扇抖动。
//   2. 舒适温区（comfortBand=2°C）：目标附近不追逐每一丝温度波动，避免不必要的风扇爬升。
//      10 拍后漂移 2.5%——死区让目标±1° 内的微偏差不再积累，输出稳定不爬。
//   3. 无学习数据时的主动前馈：升温段（slopeRate>死区）无 learned 时按温度距目标距离
//      预估需求（>5°→60%, >2°→35%, 其余→20%），冷启动期间也有合理前馈力度，
//      不必从 0 靠积分爬坡——减少升温过冲窗口。
//
// 关于趋势前馈强度 kD：闭环热仿真（含测量噪声）扫描证实，kD=8 在“负载陡升过冲”与
// “稳态风扇抖动”之间最优：相比 kD=5 把散热差机器的过冲从 ≈88° 压到 ≈83°，而稳态抖动几乎不增。
//
// v2 增强（学习 + 空闲交还）：
//   1. 学习前馈：daemon 持续记录稳态 (温度, 输出) 对（ThermalLearn，落盘），学会
//      “这台机器稳住每个温度要多少风量”。step(temp:learned:) 接收当前温度的学习值：
//        - 首拍/空闲夺回：以学习值播种（取代硬编码公式，从经验直接起步）
//        - 升温段（slope>0.5）：输出直接抬到不低于学习值——“负载起来直接拉转速”，
//          不必靠积分从低位慢慢爬，PD 在其上细调
//   2. 空闲交还：持续 2 分钟低于目标−8° 且输出已在低位 → 判定无需干预，step 返回 nil，
//      daemon 把风扇交还系统调度——低负载时 macOS 可以把风扇降转甚至停转，
//      避免强制模式压在最低转速空转。夺回条件：被动升温破目标（温度 ≥ 目标，连续
//      2 拍确认）或涨幅 ≥0.8°/拍单拍抢跑。夺回线=目标是关键：实测 Apple Silicon
//      停转被动平衡温度可达 74-75°，"被动不破目标"才是风扇该不该转的物理判据；
//      近 10 分钟内夺回过则释放门槛翻倍，抑制边界工况的拍打。
//      交还期间安全红线不受影响：管线对 nil 输出照常执行 SSD 托底与 92° 兜底
//      （config.mode 仍是 .ai），且风扇本就归系统调度，无保护缺口。
//      静音会议期间 daemon 传 allowRelease=false：系统接管的风扇行为不确定，会议中不放。

public struct AITuning: Equatable {
    public var targetTemp: Double = 76   // 目标温度带中心（Apple Silicon 该温度下性能满血且不烫手）
    public var kP: Double = 1.5          // 比例：每偏离目标 1°C，每标称拍(3s)调整 %（dt 归一化后物理语义恒定）
    public var kD: Double = 8.0          // 微分/前馈：每 1°C/标称拍 趋势调整 %（仿真选出的压过冲最优值）
    public var slopeDeadband: Double = 0.15  // °C/s 斜率死区：带内不触发 D 项（滤传感器噪声被微分放大）
    public var comfortBand: Double = 2.0     // °C 舒适温区：目标±2° 内不积累 P 项（防稳态微偏差积分漂移）
    // v7 曲线锚定 → v9 探测式阶梯：稳态时每隔 anchorProbeSeconds 向用户曲线迈一小步。
    // 原连续拉取（3%/拍）与 PD 的目标温度构成"两个设定点抢一个执行器"：
    // 曲线期望偏离物理需求超过带宽容忍（±comfortBand×b ≈ ±10pp 输出）时，
    // 锚定把温度拉出舒适带 → P 回推 → 回带再拉，形成 ~100s 周期的输出锯齿（极限环），
    // 风扇周期性变矩（用户关注的寿命问题的 AI 模式翻版）。
    // 也不能用"连续拉取 + 贴带沿刹车"：热时间常数（数十秒）>> 控制拍（3s），
    // 温度响应严重滞后，门控触发前输出已冲过带沿对应值（超调 ≈ 拉速 × τ ≈ 40pp）。
    // 探测式：小步（1.5% ≈ 0.3°C 温度效应）+ 长间隔（≈ τ，每步效果充分显现），
    // |error| ≥ comfortBand − anchorInnerMargin 即停步。
    //   曲线差距 ≤ 带宽容忍 → 完整收敛到曲线（调曲线直接改变 AI 稳态）
    //   差距更大 → 停在带内沿对应值（下拉时温度骑上沿=更安静，上拉骑下沿=更冷）
    // 曲线保留为"期望方向"，物理带宽为界——两个设定点不再抢执行器。
    public var anchorStepPercent: Double = 1.5   // %：每步最大幅度
    public var anchorProbeSeconds: Double = 25   // s：探测间隔（≈热时间常数，让每步效果显现）
    public var anchorInnerMargin: Double = 1.0   // °C：带内安全区半宽（|error| ≥ band−margin 停步）
    // 锚定保持时间：温度离开舒适区后保持 N 拍不执行锚定，防 PD 收敛耦合振荡。
    // 物理依据：5 拍 × 3s = 15s 冷却窗口，PD kP=1.5 在 2° 误差下每拍推动 ~3%，
    // 15s 足以让 PD 独立收敛到舒适区而不被锚定拉回。
    public var anchorHoldTicks: Int = 5
    // 双通路功耗前馈：信号（真实负载 30W 突增）与噪声（PSTR/PDTR ±2W）幅度差 15 倍，
    // 单一 EMA 必然顾此失彼——EMA(α=0.4) 单拍只捕获 40% 增量，30W 突增被压到 12W。
    // 分两路并行处理：
    //   - 快速通路（raw 增量）：捕捉负载 onset，1 拍到位，绕过 EMA 延迟
    //   - 慢速通路（EMA 增量）：捕捉渐变负载，多拍累积，抑制单拍噪声
    // 两路 max 合并（不叠加），避免快速通路触发时慢速通路再叠加导致过度前馈。
    public var powerRiseThreshold: Double = 4.0 // W：慢速通路 EMA 增量阈值（噪声 EMA 后 ≤0.8W，5 倍裕度）
    public var powerRiseGain: Double = 0.6      // %/W：慢速通路前馈增益
    public var powerRiseMaxBoost: Double = 18.0 // %：慢速通路单拍前馈上限
    public var powerFastThreshold: Double = 15.0 // W：快速通路 raw 增量阈值（远超 3σ≈6W 噪声）
    public var powerFastGain: Double = 0.7       // %/W：快速通路前馈增益
    public var powerFastMaxBoost: Double = 15.0  // %：快速通路单拍前馈上限（避免拉满）
    // v8 分项功耗快速通路（powermetrics 后台采样提供）：
    // 整机 PSTR 把 CPU/GPU 混在一起，无法区分热源；分项（CPU/GPU 各自）阈值更低——
    // GPU 负载突变时整机前馈可能不触发，分项通路能提前数秒介入。
    // 与整机快速通路 max 合并（不叠加），避免双计。
    public var componentPowerThreshold: Double = 8.0  // W：分项 raw 增量阈值
    public var componentPowerGain: Double = 0.7       // %/W：分项前馈增益
    public var componentPowerMaxBoost: Double = 12.0  // %：分项单拍前馈上限
    // 空闲交还参数（时间阈值以秒计：自适应循环间隔下拍长可变，秒语义才恒定）
    public var idleReleaseBelow: Double = 8    // 温度持续低于 目标−8° 才候选交还
    public var idleHoldSeconds: Double = 120   // 需连续清凉 120s（≈2 分钟）
    public var idleDeepBelow: Double = 12      // 深凉快速通道：≤ 目标−12° 时信心足，
    public var idleDeepHoldSeconds: Double = 30 // 只需连续 30s 即交还，缩短空转窗口
    public var idleMaxOutput: Double = 15      // 且输出已到低位（控制器自己也认为不需要风）
    public var idleReclaimAbove: Double = 0    // 交还后温度 ≥ 目标 才夺回（与释放线 8° 滞回）。
                                               // 语义：被动升温不破目标 = 风扇不该转；只有被动散热
                                               // 压不住目标才接管。实测停转被动平衡温度可达 74-75°，
                                               // 夺回线若低于目标（如 target−3）在该机器上必然极限环
    public var idleReclaimHold: Int = 2        // 夺回条件需连续 2 拍成立（滤单拍毛刺；交还期间
                                               // 系统调度兜着，夺回晚几秒无安全风险）
    public var idleReclaimSlopePerSec: Double = 0.27  // 或涨幅 ≥0.27°/s → 负载突增夺回
    public var idleReclaimGraceSeconds: Double = 60   // 释放后 60s 宽限：斜率夺回暂停——停转瞬态
                                               // 升温（冲向被动平衡温度）与负载 onset 同形，不宽限则
                                               // 每次交还都被自己的瞬态夺回（线上实测 3s 拍打）。
                                               // 过线夺回（被动破目标）不受宽限限制，真负载兜得住
    public var flapWindowSeconds: Double = 600 // 振荡冷却窗口（10 分钟）
    public var idleHoldAfterFlapSeconds: Double = 240 // 窗口内夺回过 → 释放需连续 240s 清凉（防拍打）
    // v2.9.2 启停循环抑制：实测（2026-08，暖环境 30.5° + ~27W 负载）深凉快速通道
    // （≤目标−12° 只需 30s，绕过防拍打冷却窗）会在"被动热浸泡平衡温度高于夺回线"的
    // 机器上形成 停转→浸泡→夺回→冷却→再停转 的极限环（周期 ~110s，日志 2 天 261 次）。
    // 每次 0→2000+RPM 启停是轴承的最高磨损事件。判据：释放后 ≤ cyclingDetectSeconds
    // 即被夺回（过线或斜率夺回都算——斜率误武装的代价是"最低转速多保持几小时"
    // （几乎无害），漏武装的代价是极限环持续（真实磨损），不对称故都武装）→
    // 进入 cyclingGuardSeconds 抑制期：不交还，保持 AI 最低输出。
    // v3.1 指数退避：抑制期过后重试仍循环 → 抑制期翻倍（30 分钟 → 4h 封顶），
    // 最坏情况的无效试探从 48 次/天降到 ~6 次/天；可持续释放归位。
    public var cyclingDetectSeconds: Double = 240
    public var cyclingGuardSeconds: Double = 1800      // 基础抑制期（30 分钟）
    public var cyclingBackoffMaxMul: Double = 8        // 指数退避上限（1800×8 = 4 小时）
    public init() {}
}

// AI 当前意图（可解释性）：由 daemon 随 status.json 写出，App 只读展示。
// 单一数据源：此前 App 用自己的采样重算意图，与 daemon 实际决策可能不一致（已废弃双轨）。
public enum AIIntent: String, Codable {
    case rising    // 正在升温 → 提前加速
    case falling   // 温度回落 → 收敛降噪
    case holding   // 稳态 → 维持目标温度

    public var label: String {
        switch self {
        case .rising: return "AI 预判升温 · 提前加速"
        case .falling: return "AI 温度回落 · 收敛降噪"
        case .holding: return "AI 维持目标温度"
        }
    }
}

public struct AIController {
    // 电池+省电开关时目标温度放宽值：更热的目标带 = 更低的风扇输出 = 省电，
    // 与曲线模式"电池切安静档"同一设计意图的 AI 版表达
    public static let batteryTargetBoost = 4.0

    // 电源感知的有效目标：电池供电且开启"电池供电时自动安静"才放宽
    public static func effectiveTarget(_ base: Double, onBattery: Bool,
                                       batterySaver: Bool) -> Double {
        onBattery && batterySaver ? base + batteryTargetBoost : base
    }

    public var tuning: AITuning
    public private(set) var output: Double = 0   // 累积输出（增量控制的积分状态）
    public private(set) var idleReleased = false // 空闲交还中（step 返回 nil）
    private var lastTemp: Double?
    private var lastPowerWatts: Double?
    private var lastCpuPower: Double?      // v8 分项功耗（powermetrics）前馈状态
    private var lastGpuPower: Double?
    private var smoothedPowerWatts: Double?  // 功耗 EMA 平滑值（抑制 PSTR 传感器 ±2W 噪声）
    private var lastSlopeRate: Double = 0        // 最近一拍的温度变化率（°C/s），供 intent() 使用
    private var idleSeconds: Double = 0
    private var reclaimTicks = 0          // 夺回条件连续成立拍数
    private var secondsSinceReclaim = Double.infinity   // 距上次夺回（振荡冷却用）
    private var graceSeconds = Double.infinity          // 距释放（斜率夺回宽限用）
    private var ticksSinceComfortExit: Int = 0  // 距上次离开舒适区的拍数（锚定保持用）
    private var secondsSinceAnchorStep: Double = .infinity  // 距上次锚定步进（探测节奏用；infinity=从未步进，允许立即首步）
    // v2.9.2 启停循环抑制状态
    private var secondsSinceRelease: Double = .infinity // 距上次释放（循环判定用）
    private var cyclingGuardRemaining: Double = 0       // 抑制期倒计时
    private var cyclingBackoffMul: Double = 1           // v3.1 退避倍率（连续循环翻倍，可持续释放归位）
    public private(set) var cyclingGuardArmed = false   // 抑制是否武装中（引擎边沿日志用）
    public private(set) var currentGuardSeconds: Double = 0 // 最近一次武装的抑制时长（日志/测试用）

    public init(tuning: AITuning = AITuning()) { self.tuning = tuning }

    // 输入平滑温度，返回 AI 判定的目标百分比；nil = AI 认为无需干预，交还系统调度。
    // 后续仍会过守护进程的限速/死区/兜底。
    // - learned: 当前温度学到的稳态输出（ThermalLearn），无数据传 nil
    // - curvePercent: 当前温度在用户曲线上的插值（冷启动基准，无学习数据时用此替代硬编码）
    // - powerWatts: 整机实时功耗；仅功耗快速上升时作为前馈，提前覆盖温度尚未爬升的热惯性窗口
    // - cpuPower/gpuPower: 分项功耗（powermetrics 低频采样，daemon 后台提供）。
    //   任一部件 raw 增量超阈值即触发分项快速通路——整机前馈区分不了热源，
    //   GPU 突增时整机可能不触发，分项通路提前数秒介入。
    // - allowRelease: 是否允许空闲交还（静音会议期间 daemon 禁止）
    // - dt: 本拍实际时长（秒）。PD 增量按拍（主动控制时 daemon 固定 3s），
    //   交还相关计时按秒（自适应间隔下拍长可变，秒语义恒定）
    public mutating func step(temp: Double, learned: Double? = nil,
                              curvePercent: Double? = nil,
                              powerWatts: Double? = nil,
                              cpuPower: Double? = nil,
                              gpuPower: Double? = nil,
                              allowRelease: Bool = true, dt: Double = 3.0) -> Double? {
        // 防御：非有限值（NaN/Inf，理论上传感器已过滤）不更新状态，避免一个坏值永久污染
        guard temp.isFinite else { return idleReleased ? nil : output }
        // 钳制 dt：系统睡眠唤醒后可能传入超大值，导致 P 项瞬间冲到 100
        // NaN dt 穿透 min/max（NaN 比较恒 false），导致 output 变 NaN 传播到 SMC。
        // 退回标称拍长 3s（保守降级，P/D 项语义不变）
        let dt = dt.isFinite ? min(max(dt, 0.5), 15.0) : 3.0
        let prev = lastTemp
        lastTemp = temp
        // 功耗 EMA 平滑：PSTR/PDTR 传感器有 ±2W 噪声，单拍增量会频繁误触发前馈。
        // EMA(α=0.4) 抑制高频噪声，同时保留趋势信息（2-3 拍内真实负载上升仍可检出）。
        // 增量用平滑值计算：smoothed_prev → smoothed_curr，毛刺被两侧平滑抵消。
        // 注意：rawRise 必须在 lastPowerWatts 更新为当前 validPower **之前** 计算，
        // 否则 rawRise 恒为 0（快速通路永远失效）。
        let validPower = powerWatts.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let prevSmoothed = smoothedPowerWatts ?? validPower ?? 0
        let currSmoothed: Double
        if let vp = validPower {
            currSmoothed = prevSmoothed + 0.4 * (vp - prevSmoothed)
        } else {
            currSmoothed = prevSmoothed  // 无读数时保持上次平滑值
        }
        smoothedPowerWatts = currSmoothed
        let powerRise = max(0, currSmoothed - prevSmoothed)
        // 快速通路 raw 增量：用本拍原始功耗 − 上拍原始功耗（更新 lastPowerWatts 之前）
        let rawRise = (validPower != nil && lastPowerWatts != nil)
            ? max(0, validPower! - lastPowerWatts!) : 0
        if let validPower { lastPowerWatts = validPower }
        // v8 分项快速通路：CPU/GPU 各自 raw 增量（先算后更新 lastCpuPower/lastGpuPower）。
        // powermetrics 采样是低频的（daemon 20s 一次），增量反映"上次采样以来的变化"，
        // 采样缺失（nil）时保持旧值，避免把"未更新"误判成"下降"。
        // 追踪放在 idle 分支之前：空闲交还可持续数分钟~小时，若期间基线冻结，
        // 夺回后首拍 cpuRise 会是"与空闲前的跨时长差值"，产生一次假前馈（≤12%，有界但语义错）。
        // 期间持续更新基线后，active 时的增量始终是"上一个采样间隔"的干净信号。
        let cpuRise = (cpuPower != nil && lastCpuPower != nil)
            ? max(0, cpuPower! - lastCpuPower!) : 0
        let gpuRise = (gpuPower != nil && lastGpuPower != nil)
            ? max(0, gpuPower! - lastGpuPower!) : 0
        if let cp = cpuPower, cp.isFinite, cp >= 0 { lastCpuPower = cp }
        if let gp = gpuPower, gp.isFinite, gp >= 0 { lastGpuPower = gp }
        let slope = temp - (prev ?? temp)
        let slopeRate = slope / max(dt, 0.1)
        lastSlopeRate = slopeRate
        if secondsSinceReclaim < .infinity { secondsSinceReclaim += dt }
        if secondsSinceAnchorStep < .infinity { secondsSinceAnchorStep += dt }

        // 空闲交还中：等夺回条件，不推进积分（温度低于目标，积分只会无意义下沉）
        if idleReleased {
            if graceSeconds < .infinity { graceSeconds += dt }
            if secondsSinceRelease < .infinity { secondsSinceRelease += dt }
            // 静音会议中途激活（allowRelease 转 false）→ 强制夺回：
            // 会议期间的风扇必须受静音封顶约束，不能留在行为不确定的系统调度里
            let over = temp >= tuning.targetTemp - tuning.idleReclaimAbove
            let inGrace = graceSeconds <= tuning.idleReclaimGraceSeconds
            let surging = slopeRate >= tuning.idleReclaimSlopePerSec && !inGrace
            reclaimTicks = over ? reclaimTicks + 1 : 0
            // 斜率夺回单拍生效但避开释放宽限期（停转瞬态与负载同形）；
            // 温度过线仍需连续 2 拍（慢爬升可能是停转后的平衡温升，要确认）
            if !allowRelease || surging || reclaimTicks >= tuning.idleReclaimHold {
                idleReleased = false
                idleSeconds = 0
                reclaimTicks = 0
                secondsSinceReclaim = 0
                // v2.9.2/v3.1 循环判定：释放后短时间内即被夺回 = 停转不可持续（被动热浸泡
                // 平衡高于夺回线）→ 武装抑制期（指数退避），期间保持最低转速不交还。
                // 静音激活（!allowRelease）引起的夺回是模式切换而非热振荡：不武装，
                // 但长释放（>判定窗）被会议截断同样证明"停转可持续"→ 退避归位（审查 P3-1）。
                if secondsSinceRelease <= tuning.cyclingDetectSeconds, allowRelease {
                    currentGuardSeconds = tuning.cyclingGuardSeconds * cyclingBackoffMul
                    cyclingGuardRemaining = currentGuardSeconds
                    cyclingGuardArmed = true
                    cyclingBackoffMul = min(cyclingBackoffMul * 2, tuning.cyclingBackoffMaxMul)
                } else if secondsSinceRelease > tuning.cyclingDetectSeconds {
                    cyclingBackoffMul = 1   // 可持续释放（间隔超过判定窗）：环境已变，退避归位
                }
                secondsSinceRelease = .infinity
                graceSeconds = .infinity
                // 夺回即从经验起步：负载来了直接给出"已知需要的风量"
                // 优先学习值 → 曲线插值（用户期望的先验）→ 公式种子
                output = learned ?? curvePercent ?? seedOutput(for: temp)
                return output
            }
            return nil
        }

        guard prev != nil else {
            // 首拍无历史斜率：优先学习值播种，退回曲线插值，最后退回公式起点
            output = learned ?? curvePercent ?? seedOutput(for: temp)
            return checkIdleRelease(temp: temp, allowRelease: allowRelease, dt: dt)
        }

        let error = temp - tuning.targetTemp
        // dt 归一化：以 3s 为标称拍长，P 项随实际时间线性缩放，D 项按变化率保持等强度。
        // 这样自适应间隔（1–10s）下控制器行为一致，不会因长拍而过冲或短拍而无力。
        let dtNom = dt / 3.0

        // 斜率死区：±slopeDeadband °C/s 内视为平稳，不触发 D 项（消除传感器噪声被微分放大）
        let clampedSlope = abs(slopeRate) < tuning.slopeDeadband ? 0 : slope
        // 舒适温区：目标±comfortBand °C 内不积累 P 项（避免微小偏差导致积分持续漂移）
        // 注意用 <= 而非 <：error=1.0 时 abs(1.0)<=1.0 为 true，归零 P 项。
        // 用 < 会让恰好 +1°C 的点落在死区外，P 项每拍 +2.5% 持续 windup（仿真证实 77°C 稳态 10 拍从 76% 爬到 99%）
        let clampedError = abs(error) <= tuning.comfortBand ? 0 : error
        // 锚定保持计数：离开舒适区时重置，进入后逐拍递增
        if abs(error) > tuning.comfortBand {
            ticksSinceComfortExit = 0
        } else {
            ticksSinceComfortExit += 1
        }

        // anti-windup：output 饱和时跳过同向 P 项（不继续向上推已饱和的 output）。
        // 仿真证实：88°C 保持 10 拍后降温，P 项（正，error>0）持续抵消 D 项（负，slope<0），
        // 导致 output 在温度已降到 84°C 时仍维持 100%。跳过同向 P 项后，降温段 output
        // 随 D 项快速下降，温度回到目标附近时 output 不再卡在高位。
        let pDelta = tuning.kP * clampedError * dtNom
        let dDelta = tuning.kD * clampedSlope * (1.0 / dtNom)
        var delta = dDelta
        if (output < 100 || pDelta <= 0) && (output > 0 || pDelta >= 0) {
            delta += pDelta
        }
        output = min(100, max(0, output + delta))

        // v9 曲线锚定（探测式阶梯，替代 v7 连续拉取）：误差和斜率都归零（稳态）时，
        // 每隔 anchorProbeSeconds 向用户曲线迈一小步（≤ anchorStepPercent）。
        // 双向：output 高于曲线则降、低于曲线则升（调曲线直接改变 AI 稳态方向）；
        // learned 不参与锚定（避免污染的历史学习把 output 钉在高位）。
        // 方向性带沿门控（HIL 对抗测试证实对称门控有缺陷）：
        //   拉向上（diff>0，加强散热，温度下降）→ 只需远离带底（error > −innerEdge）
        //   拉向下（diff<0，减弱散热，温度上升）→ 只需远离带顶（error < +innerEdge）
        // 拉向曲线的温度效应总是把温度推向带中心，被挡侧是唯一危险方向。
        // 这也修复了增量 PD 的"轨迹依赖落点"：PD 稳态是一族均衡（带内任意 |error|≤2
        // 且斜率归零的点都冻结），落点可能停在热侧/冷侧；方向性门控让锚定在任何
        // 落点都能向曲线方向修正，只以"不把温度拉出舒适带"为界（两个设定点不再抢执行器）。
        // 曲线差距 ≤ 带宽容忍（innerEdge/b）→ 完整收敛到曲线；差距更大 → 停在带内沿。
        if clampedError == 0 && clampedSlope == 0
           && ticksSinceComfortExit >= tuning.anchorHoldTicks, let cp = curvePercent {
            let diff = cp - output
            let innerEdge = tuning.comfortBand - tuning.anchorInnerMargin
            let safeUp = error > -innerEdge    // 拉向上（降温）：温度会向带底走，需留裕量
            let safeDown = error < innerEdge   // 拉向下（升温）：温度会向带顶走，需留裕量
            if abs(diff) > 0.5, diff > 0 ? safeUp : safeDown,
               secondsSinceAnchorStep >= tuning.anchorProbeSeconds {
                let step = min(tuning.anchorStepPercent, abs(diff))
                output += (diff > 0 ? step : -step)
                secondsSinceAnchorStep = 0
            }
        }

        // 升温前馈：温度正在快速上升（超出斜率死区）→ 一步抬到经验水平
        // 优先级：学习值 > 曲线插值 > 按温度距目标距离预估
        //   学习值是"这台机器稳住该温度实际需要的风量"——最精确
        //   曲线插值是"用户期望的风量"——冷启动时最合理的先验
        //   硬编码预估是最后的兜底（无曲线数据时）
        // 冷却段不抬（learned 是稳态保持值，PD 自然收敛，避免无谓拉高）
        // learned 上限 80%：即使学习数据被污染（如未清洗到的异常高值），
        //   单次前馈也不会直接拉满 100%，PD 仍可在其上细调
        if slopeRate > tuning.slopeDeadband {
            let raw: Double = learned ?? curvePercent ?? (error > 5 ? 60 : (error > 2 ? 35 : 20))
            let feedforward = min(raw, 80)
            if feedforward > output { output = feedforward }
        }

        // 功耗突增早于芯片温度上升数秒出现。双通路设计：
        //   - 快速通路（raw 增量 > 15W）：远超 3σ 噪声（≈6W），1 拍捕捉真实负载 onset
        //   - 慢速通路（EMA 增量 > 8W）：噪声经 EMA 后 <3W，捕捉渐变负载多拍累积
        // 两路 max 合并（不叠加）：快速通路触发时（raw 突增）慢速通路必然也在响应
        // （EMA 增量 ≈ raw × 0.4），max 避免双计；纯渐变负载下快速通路不触发，慢速通路持续加成。
        // rawRise 已在前面计算（必须在 lastPowerWatts 更新之前）。
        let slowBoost: Double
        if powerRise > tuning.powerRiseThreshold {
            slowBoost = min(tuning.powerRiseMaxBoost,
                            (powerRise - tuning.powerRiseThreshold) * tuning.powerRiseGain)
        } else {
            slowBoost = 0
        }
        let fastBoost: Double
        if rawRise > tuning.powerFastThreshold {
            fastBoost = min(tuning.powerFastMaxBoost,
                            (rawRise - tuning.powerFastThreshold) * tuning.powerFastGain)
        } else {
            fastBoost = 0
        }
        // v8 分项快速通路：cpuRise/gpuRise 已在 step 入口计算（idle 分支之前，
        // 保证空闲期间基线持续刷新，夺回后增量为干净的"上一间隔"信号）
        let componentBoost = max(
            cpuRise > tuning.componentPowerThreshold
                ? min(tuning.componentPowerMaxBoost,
                      (cpuRise - tuning.componentPowerThreshold) * tuning.componentPowerGain) : 0,
            gpuRise > tuning.componentPowerThreshold
                ? min(tuning.componentPowerMaxBoost,
                      (gpuRise - tuning.componentPowerThreshold) * tuning.componentPowerGain) : 0)
        let totalBoost = max(slowBoost, fastBoost, componentBoost)
        if totalBoost > 0 {
            output = min(100, output + totalBoost)
        }

        return checkIdleRelease(temp: temp, allowRelease: allowRelease, dt: dt)
    }

    // 空闲交还判定：持续清凉 + 输出已低位 → 累计秒数交还；任何一条不满足立即清零。
    // 释放门槛三档：深凉 30s（停转平衡温度远低于夺回线，无振荡风险，绕过冷却）；
    // 振荡冷却窗口内 240s（打断极限环）；常规 120s。
    // v2.9.2：深凉路径的"无振荡风险"前提在暖环境 + 中低负载下不成立（实测极限环）——
    // 抑制期内不交还，返回当前低输出（风扇稳定最低转速），倒计时走完再试一次释放。
    private mutating func checkIdleRelease(temp: Double, allowRelease: Bool, dt: Double) -> Double? {
        if cyclingGuardRemaining > 0 {
            cyclingGuardRemaining = max(0, cyclingGuardRemaining - dt)
            if cyclingGuardRemaining == 0 { cyclingGuardArmed = false }
            return output   // 抑制期：保持当前低输出（最低转速稳定运行）
        }
        if allowRelease, output <= tuning.idleMaxOutput,
           temp <= tuning.targetTemp - tuning.idleReleaseBelow {
            idleSeconds += dt
            let needed: Double
            if temp <= tuning.targetTemp - tuning.idleDeepBelow {
                needed = tuning.idleDeepHoldSeconds
            } else if secondsSinceReclaim < tuning.flapWindowSeconds {
                needed = tuning.idleHoldAfterFlapSeconds
            } else {
                needed = tuning.idleHoldSeconds
            }
            if idleSeconds >= needed {
                idleReleased = true
                graceSeconds = 0   // 开启斜率夺回宽限计时
                secondsSinceRelease = 0
                return nil
            }
        } else {
            idleSeconds = 0
        }
        return output
    }

    // 首拍/夺回种子：偏离目标越远起点越高；学习数据充足时调用方优先用 learned
    private func seedOutput(for temp: Double) -> Double {
        min(100, max(0, (temp - tuning.targetTemp) * tuning.kP * 4 + 30))
    }

    // AI 当前意图：daemon 每正常拍计算一次写入 status.json（App 只读，不重算）
    // 用变化率（°C/s）判定，在自适应间隔下语义恒定（0.2°C/s ≈ 3s 拍 0.6°C）
    public func intent(temp: Double) -> AIIntent {
        guard lastTemp != nil else { return .holding }
        if lastSlopeRate > 0.2 { return .rising }
        if lastSlopeRate < -0.2 { return .falling }
        return .holding
    }

    // 切回/切出/唤醒：清空积分与空闲状态，下次进入重新起步
    public mutating func reset() {
        output = 0
        lastTemp = nil
        lastPowerWatts = nil
        lastCpuPower = nil
        lastGpuPower = nil
        smoothedPowerWatts = nil
        lastSlopeRate = 0
        idleReleased = false
        idleSeconds = 0
        reclaimTicks = 0
        secondsSinceReclaim = .infinity
        graceSeconds = .infinity
        ticksSinceComfortExit = 0
        secondsSinceAnchorStep = .infinity
        secondsSinceRelease = .infinity
        cyclingGuardRemaining = 0
        cyclingBackoffMul = 1
        currentGuardSeconds = 0
        cyclingGuardArmed = false
    }
}
