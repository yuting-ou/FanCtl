import Foundation
import SMCCore

/// 高占用进程条目：占用页与过热通知共用同一语义（此前 App 内有两份同名/同形类型）。
public struct ProcessUsage: Identifiable, Equatable, Sendable {
    public let id: String
    public let app: String
    public let cpu: Double

    public init(id: String, app: String, cpu: Double) {
        self.id = id
        self.app = app
        self.cpu = cpu
    }
}

/// `/bin/ps -Aceo pcpu,comm -r` 输出的纯解析器。
/// 进程名归并（同一软件的多个 helper 相加）与展示标签曾埋在采样函数里，无法单测；
/// 拆出来后 spwan 进程只负责取字节，解析规则可被 fixture 覆盖。
public enum ProcessUsageParser {
    /// - Parameter detail: 把可执行路径映射成（软件名, 角色）。生产传
    ///   `ProcessIdentity.detail`，测试可注入确定性映射。
    public static func parse(
        _ output: String,
        limit: Int = 5,
        minCPU: Double = 8,
        detail: (String) -> (app: String, role: String?)
    ) -> [ProcessUsage] {
        struct Raw { let app: String; let role: String?; let cpu: Double }
        struct Merged { let app: String; var cpu: Double; var role: String? }

        var raws: [Raw] = []
        for line in output.split(separator: "\n").dropFirst() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let cpu = Double(parts[0]), cpu.isFinite, cpu >= minCPU else { continue }
            let d = detail(String(parts[1]))
            raws.append(Raw(app: d.app, role: d.role, cpu: cpu))
        }

        // 按软件名归并：同一软件不同 Frameworks 下的 helper 要并成一份；
        // 角色词取第一个看到的（归并后只表达"这软件在忙"）。
        var dict: [String: Merged] = [:]
        for r in raws {
            if var m = dict[r.app] {
                m.cpu += r.cpu
                if m.role == nil { m.role = r.role }
                dict[r.app] = m
            } else {
                dict[r.app] = Merged(app: r.app, cpu: r.cpu, role: r.role)
            }
        }

        return dict.values
            .sorted { $0.cpu > $1.cpu }
            .prefix(max(0, limit))
            .map { m in
                let label: String
                if let role = m.role, !role.isEmpty {
                    label = "\(m.app)（\(role)）"
                } else {
                    label = m.app
                }
                return ProcessUsage(id: label, app: m.app, cpu: m.cpu)
            }
    }
}
