import Foundation
import SMCCore

// MARK: - 分项功耗采样器（powermetrics 后台采样）
//
// 整机 PSTR 无法区分 CPU/GPU 热源；powermetrics（root 可用）按部件给出功耗。
// 低频后台采样（默认 20s 一次、每次 ~1s），结果供 AI 分项快速通路前馈。
// 解析交给 SMCCore.PowerMetricsParser（daemon 与测试共用；v2.6 曾传不存在的
// "-u W" 参数导致本采样器自上线起静默失效——见解析器文件头注释）。

final class PowerCompositionSampler {
    private let lock = NSLock()
    private var cpuPower: Double?
    private var gpuPower: Double?
    private var lastSample = Date.distantPast
    private var samplingInFlight = false
    private var consecutiveFailures = 0
    private var cpuNilStreak = 0         // 单侧连续无有效读数计数（GPU 空载报 0 mW 是
    private var gpuNilStreak = 0         // 常态，旧高值不应无限期滞留污染前馈基线）
    private var failureLogged = false    // 首次失败打一条日志：静默降级可以，静默失效不可以
    private var interval: TimeInterval = 20

    // #6: 自适应采样间隔（高温/AI 模式 → 10s，idle → 60s，默认 20s）
    func updateInterval(_ newInterval: TimeInterval) {
        interval = max(10, min(60, newInterval))
    }

    // 主循环调用（主队列）：低频触发后台采样，立即返回当前已知值
    func current() -> (cpu: Double?, gpu: Double?) {
        let now = Date()
        if now.timeIntervalSince(lastSample) >= interval {
            lastSample = now
            lock.lock()
            let inFlight = samplingInFlight
            if !inFlight { samplingInFlight = true }
            lock.unlock()
            // v2.6.2：in-flight 标志——powermetrics 挂起时不再每 20s 堆积新线程/进程
            if !inFlight {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    let (c, g) = Self.runPowermetrics()
                    var shouldLogFailure = false
                    var failureCount = 0
                    self.lock.lock()
                    if c == nil && g == nil {
                        self.consecutiveFailures += 1
                        if self.consecutiveFailures >= 3 {
                            // 连续失败 3 次后让旧值过期：避免恢复后首个样本产生
                            // 跨长时间窗的假增量（AI 分项前馈误触发）
                            self.cpuPower = nil
                            self.gpuPower = nil
                        }
                        if !self.failureLogged {
                            self.failureLogged = true
                            shouldLogFailure = true
                            failureCount = self.consecutiveFailures
                        }
                    } else {
                        self.consecutiveFailures = 0
                        self.failureLogged = false
                    }
                    // 单侧过期：某侧连续 3 次无有效读数（量化 0/解析失败）即弃用旧值。
                    // 若只靠双侧同时失败，空载 GPU 的陈旧高值会滞留数小时——
                    // GPU 真实回落到 0 后再拉起时，rise 会拿陈旧基线算出假前馈。
                    if let c {
                        self.cpuPower = c
                        self.cpuNilStreak = 0
                    } else {
                        self.cpuNilStreak += 1
                        if self.cpuNilStreak >= 3 { self.cpuPower = nil }
                    }
                    if let g {
                        self.gpuPower = g
                        self.gpuNilStreak = 0
                    } else {
                        self.gpuNilStreak += 1
                        if self.gpuNilStreak >= 3 { self.gpuPower = nil }
                    }
                    self.samplingInFlight = false
                    self.lock.unlock()
                    if shouldLogFailure {
                        log("powermetrics 分项功耗采样失败（连续 \(failureCount) 次），分项前馈不可用")
                    }
                }
            }
        }
        lock.lock(); defer { lock.unlock() }
        return (cpuPower, gpuPower)
    }

    private static func runPowermetrics() -> (cpu: Double?, gpu: Double?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // 注意：powermetrics 没有 "-u"（单位）参数——传了会立即 usage error 退出。
        // 默认输出单位为 mW，由 PowerMetricsParser 按后缀换算为 W。
        p.arguments = ["-s", "cpu_power,gpu_power", "-i", "1000", "-n", "1"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice   // 丢弃 stderr，防管道缓冲阻塞
        var result: (cpu: Double?, gpu: Double?) = (nil, nil)
        let sema = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sema.signal() }
        do { try p.run() } catch { return (nil, nil) }
        // v2.6.2：真超时（5s）——powermetrics 正常 ~1s 退出；挂起时强杀，
        // 不再 waitUntilExit 无限期阻塞后台线程
        if sema.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            p.waitUntilExit()
            return (nil, nil)
        }
        if p.terminationStatus == 0,
           let data = try? outPipe.fileHandleForReading.readToEnd(),
           let out = String(data: data, encoding: .utf8) {
            result = (PowerMetricsParser.watts(in: out, key: "CPU Power:"),
                      PowerMetricsParser.watts(in: out, key: "GPU Power:"))
        }
        return result
    }
}
