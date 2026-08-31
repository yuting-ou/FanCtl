// NotificationService —— 过热/风扇健康/AI 优化通知（从 FanModel 提取）
import Foundation
import UserNotifications
import SMCCore

// 高占用进程（与 FanModel.ProcessUsage 语义一致，独立定义避免循环依赖）
struct ProcessInfo: Identifiable, Equatable {
    let id: String
    let cpu: Double
}

final class NotificationService {
    private let canNotify = Bundle.main.bundleIdentifier != nil

    // 风扇健康状态
    private var fanAnomalySince: [Int: Date] = [:]
    private var lastFanAlertAt: Date = .distantPast

    // 过热状态
    private var hotSince: Date? = nil
    private var lastOverheatNotify = Date.distantPast

    // MARK: - 风扇健康监测

    func checkFanHealth(_ entries: [FanState], controlReason: ControlReason?) {
        guard canNotify else { return }
        // 仅当 daemon 实际控制风扇时才检测：.auto / AI 空闲交还时 targetRPM 是系统自己设定的
        guard controlReason != .aiIdle, controlReason != .auto else {
            fanAnomalySince.removeAll(); return
        }
        if entries.isEmpty { fanAnomalySince.removeAll(); return }
        let now = Date()
        for f in entries {
            guard f.targetRPM > f.minRPM + 150 else { fanAnomalySince[f.id] = nil; continue }
            let stalled = f.actualRPM < 100
            let lagging = abs(f.actualRPM - f.targetRPM) > max(300, f.targetRPM * 0.25)
            guard stalled || lagging else { fanAnomalySince[f.id] = nil; continue }
            guard let since = fanAnomalySince[f.id] else { fanAnomalySince[f.id] = now; continue }
            let need: TimeInterval = stalled ? 30 : 90
            guard now.timeIntervalSince(since) >= need,
                  now.timeIntervalSince(lastFanAlertAt) > 6 * 3600 else { continue }
            lastFanAlertAt = now
            fanAnomalySince[f.id] = nil
            notifyFanIssue(f, stalled: stalled, fanCount: entries.count)
        }
    }

    private func notifyFanIssue(_ f: FanState, stalled: Bool, fanCount: Int) {
        let name = fanCount == 2 ? (f.id == 0 ? "左风扇" : "右风扇") : "风扇 \(f.id + 1)"
        let content = UNMutableNotificationContent()
        content.title = stalled ? "\(name)疑似停转" : "\(name)转速异常"
        content.body = stalled
            ? "目标 \(Int(f.targetRPM)) RPM，实际接近 0。请检查风扇是否被卡住或损坏。"
            : "目标 \(Int(f.targetRPM)) RPM，实际仅 \(Int(f.actualRPM))。可能积灰或轴承老化，建议清灰。"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "fanhealth-\(f.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - 发烧元凶通知

    func checkOverheat(_ temp: Double) {
        guard canNotify, temp > 1 else { return }
        if temp >= 90 {
            if hotSince == nil { hotSince = Date() }
            if let since = hotSince,
               Date().timeIntervalSince(since) >= 30,
               Date().timeIntervalSince(lastOverheatNotify) > 600 {
                lastOverheatNotify = Date()
                notifyOverheat(temp: temp)
            }
        } else if temp < 85 {
            hotSince = nil
        }
    }

    private func notifyOverheat(temp: Double) {
        Task.detached(priority: .utility) {
            let culprits = Self.sampleCPUUsage(limit: 3).map { "\($0.id)（\(Int($0.cpu))%）" }
            let content = UNMutableNotificationContent()
            content.title = "温度过高：\(Int(temp))°C"
            content.body = culprits.isEmpty
                ? "已持续高温 30 秒，风扇正在全力散热"
                : "CPU 占用最高：" + culprits.joined(separator: "、")
            content.sound = .default
            let req = UNNotificationRequest(identifier: "overheat", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    // MARK: - AI 优化通知

    func notifyAutoOptimized(_ r: CurveOptimizer.Result) {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = "清风生成了新的曲线建议"
        c.body = "请打开面板确认后应用：" + r.summary
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "auto-optimize", content: c, trigger: nil))
    }

    // MARK: - CPU 进程采样（共享工具方法）

    nonisolated static func sampleCPUUsage(limit: Int = 5, minCPU: Double = 8) -> [ProcessInfo] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pcpu,comm", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(separator: "\n").dropFirst().compactMap { line -> ProcessInfo? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let cpu = Double(parts[0]), cpu >= minCPU else { return nil }
            let name = String(parts[1]).split(separator: "/").last.map(String.init) ?? String(parts[1])
            return ProcessInfo(id: name, cpu: cpu)
        }.prefix(limit).map { $0 }
    }
}
