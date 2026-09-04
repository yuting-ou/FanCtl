import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import SMCCore

// fanctld — 风扇调速守护进程（LaunchDaemon，root 运行）
//
// v2.8 起 main.swift 只保留壳层职责，每拍控制状态机在 SMCCore.ControlEngine
// （可注入测试，fanctltests 用 MockSMC + FakeClock 覆盖 SMC 写入序列）：
//   壳层：SMC 初始化、root 守卫、SIGTERM/SIGINT、看门狗、config.json 文件监控、
//         睡眠/唤醒注册、主循环定时器、日志函数
//   引擎：配置热加载、温度采集与平滑、决策管线、双风扇写入、学习、统计、
//         status.json 写出、自适应间隔
//
// 安全设计：
//   - 收到 SIGTERM/SIGINT 或异常退出前，恢复系统自动调度
//   - 启动时无条件清理 SMC 强制模式残留（崩溃/断电重启后风扇不被钉死）
//   - 看门狗：主循环 >60s 无心跳（单调时钟）判定挂死，写 exit-reason 后 exit(9)，
//     由 launchd KeepAlive 重启、启动清理接管——挂死是唯一让全部安全层同时失效的故障
//   - 温度读取失败连续超过 5 次 → 恢复自动调度；92°C/SSD/电池托底在引擎决策管线内

// 日志自行落盘到配置目录（/var/log 可能被清理类软件删除导致句柄悬空）；
// 每次 open-append-close，文件被删也能自动重建。stderr 交给 launchd 捕获崩溃输出。
// 轮转：超过 512KB 时保留后半段重写（24小时守护长期运行，防日志无界增长）
let LOG_PATH = FanCtlPaths.logFile.path
let LOG_MAX_BYTES: UInt64 = 512 * 1024
let logTimestampFormatter = ISO8601DateFormatter()   // 复用：每次新建开销不小（主队列串行，无竞争）
func log(_ msg: String) {
    let ts = logTimestampFormatter.string(from: Date())
    guard let data = "[\(ts)] \(msg)\n".data(using: .utf8) else { return }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: LOG_PATH),
       let size = attrs[.size] as? UInt64, size > LOG_MAX_BYTES,
       let whole = FileManager.default.contents(atPath: LOG_PATH) {
        // 从中点后的首个换行处截断，保留较新的后半段
        var tail = whole.suffix(whole.count / 2)
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: nl))
        }
        try? (Data("[日志已轮转，保留较新半段]\n".utf8) + tail)
            .write(to: FanCtlPaths.logFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: LOG_PATH)
    }
    if let fh = FileHandle(forWritingAtPath: LOG_PATH) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        FileManager.default.createFile(atPath: LOG_PATH, contents: data,
                                       attributes: [.posixPermissions: 0o664])
    }
}

FanCtlPaths.ensureDirectories()

// v3.4.5（4E）：-v/--version 打印版本退出——排障时回答"跑的是哪个版本的 fanctld"。
// 版本常量在 Version.generated.swift（build.sh 从根目录 VERSION 重生成，单一来源）。
if CommandLine.arguments.contains(where: { $0 == "-v" || $0 == "--version" }) {
    print("fanctld \(fanctldVersion)")
    exit(0)
}

guard getuid() == 0 else {
    log("fanctld 必须以 root 运行（风扇 SMC 写入需要特权）")
    exit(1)
}

let smc: SMCConnection
let fans: FanController
let sensors: TemperatureSensors
do {
    smc = try SMCConnection()
    fans = try FanController(smc: smc)
    sensors = try TemperatureSensors(smc: smc)
} catch {
    log("SMC 初始化失败: \(error)")
    exit(1)
}

guard fans.fanCount > 0 else {
    log("未检测到风扇（FNum=0），退出")
    exit(1)
}

let counts = sensors.sensorCounts
log("启动: fanctld \(fanctldVersion) — 风扇 x\(fans.fanCount), CPU x\(counts.cpu), GPU x\(counts.gpu), SSD x\(counts.nand), 电池 x\(counts.batt), 掌托 x\(counts.palm), 散热片 x\(counts.heatsink), 其他 x\(counts.other)")

// 启动时无条件清理 SMC 强制模式残留：上一实例被 SIGKILL/崩溃/断电终止时
// SMC 可能仍处强制模式（Md=1、Tg=旧值）。若 config.mode == .auto，
// 主循环永不写 SMC（target=nil 走交还分支），残留会永久钉住风扇转速，
// 而 status 却显示"系统自动调度"——与唤醒回调的无条件恢复对齐。
fans.restoreAutoAll()
log("启动: 已恢复系统自动调度（清理异常退出残留的强制模式）")

// 上次异常退出原因（看门狗写入的标记）：让"它为什么自己重启过"可回答
if let data = try? Data(contentsOf: FanCtlPaths.exitReasonFile),
   let reason = String(data: data, encoding: .utf8), !reason.isEmpty {
    log("上次异常退出: \(reason)（看门狗/挂死保护已触发，本次启动已接管）")
    try? FileManager.default.removeItem(at: FanCtlPaths.exitReasonFile)
}

// 当前是否电池供电（电源感知切档用）
func isOnBattery() -> Bool {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
        return false
    }
    return type == kIOPMBatteryPowerKey
}

// 分项功耗采样器（powermetrics，fanctld 模块内）
let powerComposition = PowerCompositionSampler()

// 主循环定时器（引擎通过 hooks.schedule 回到这里）
let loopTimer = DispatchSource.makeTimerSource(queue: .main)
func scheduleNextLoop(interval: TimeInterval) {
    let leeway: DispatchTimeInterval = interval >= 10 ? .milliseconds(500) : .milliseconds(100)
    loopTimer.schedule(deadline: .now() + interval, repeating: .never, leeway: leeway)
}

// 控制引擎（每拍状态机，SMCCore）
let engine = ControlEngine(
    fans: fans, sensors: sensors,
    hooks: ControlEngine.Hooks(
        now: { Date() },
        log: { log($0) },
        schedule: { scheduleNextLoop(interval: $0) },
        onBattery: { isOnBattery() },
        powerComponents: { powerComposition.current() },
        setPowerInterval: { powerComposition.updateInterval($0) }))

// MARK: - 退出时恢复自动调度

var restored = false
func restoreAndExit(_ code: Int32) -> Never {
    if !restored {
        fans.restoreAutoAll()
        restored = true
        engine.shutdownSave()
        log("已恢复系统自动风扇调度，退出")
    }
    exit(code)
}

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
sigtermSource.setEventHandler { restoreAndExit(0) }
sigintSource.setEventHandler { restoreAndExit(0) }
sigtermSource.resume()
sigintSource.resume()

// MARK: - 主循环看门狗
//
// 所有安全层（92° 兜底/SSD/电池托底/故障交还/睡眠回调）都跑在主队列；主队列一旦
// 卡死（SMC 内核调用不返回、未来改动引入的同步阻塞），风扇被钉死在最后的强制值且
// 无人兜底，而 KeepAlive 只管进程退出不管挂起——这是唯一让全部防线同时失效的故障。
// 独立队列看门狗：>60s 无心跳即写 exit-reason 后 exit(9)，由 launchd KeepAlive 重启，
// 启动清理逻辑接管 SMC。心跳用单调时钟（DispatchTime，睡眠期冻结，NTP 阶跃不触发）。
// 故意不在 watchdog 线程摸 SMC（SMCConnection.call 无锁，并发调用未定义）；
// exit 是唯一线程安全的动作。
let watchdogSource = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fanctld.watchdog", qos: .utility))
watchdogSource.schedule(deadline: .now() + 60, repeating: 15.0, leeway: .seconds(1))
watchdogSource.setEventHandler {
    guard !engine.isSuspendedForSleep else { return }
    guard DispatchTime.now() >= engine.heartbeat() + .seconds(60) else { return }
    log("看门狗：主循环超 60s 无心跳，判定挂死，退出交由 launchd 重启")
    try? Data("watchdog-hang（主循环超 60s 无心跳）".utf8)
        .write(to: FanCtlPaths.exitReasonFile, options: .atomic)
    exit(9)
}
watchdogSource.resume()

// MARK: - 睡眠/唤醒安全交接（SleepHandler.swift 封装，回调进引擎）

var powerNotifyPort: IONotificationPortRef? = nil
var powerNotifier: io_object_t = 0
var rootPowerPort: io_connect_t = 0
registerSleepNotification()

// MARK: - DispatchSource 文件监控（替代轮询）

// ConfigWatch.swift 封装了 config.json 监控逻辑
var configSource: DispatchSourceFileSystemObject?
var configPollFallback: DispatchSourceTimer?
// fastConfigApply 防抖：拖动滑块时 App 可能每秒写 config.json 十余次，
// 每次都读传感器+写 SMC 会造成 I/O 风暴。30ms 合并窗口内只执行最后一次。
func scheduleFastApply() {
    fastApplyWorkItem?.cancel()
    let work = DispatchWorkItem {
        engine.beat(fastConfigApply: true)
    }
    fastApplyWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
}
var fastApplyWorkItem: DispatchWorkItem?  // fastConfigApply 防抖合并项
setupConfigWatch()
setupConfigPollFallback()

// MARK: - 启动主循环

loopTimer.setEventHandler { engine.beat() }
loopTimer.resume()
scheduleNextLoop(interval: LOOP_INTERVAL_DEFAULT)

dispatchMain()
