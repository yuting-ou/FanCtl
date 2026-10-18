import Foundation
import SMCCore

/// 趋势图采样点。`temp` 是两条曲线的上包络，与历史实现保持一致。
public struct TrendSample: Identifiable, Codable, Equatable, Sendable {
    public let id: Date
    public let cpu: Double
    public let gpu: Double
    public var temp: Double { max(cpu, gpu) }

    public init(id: Date, cpu: Double, gpu: Double) {
        self.id = id
        self.cpu = cpu
        self.gpu = gpu
    }
}

/// 固定容量环形缓冲：O(1) 追加，满了自动淘汰最旧元素。
public struct RingBuffer<Element> {
    private var buffer: [Element?]
    private var head = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be > 0")
        self.capacity = capacity
        buffer = [Element?](repeating: nil, count: capacity)
    }

    public mutating func append(_ element: Element) {
        buffer[(head + count) % capacity] = element
        if count < capacity {
            count += 1
        } else {
            head = (head + 1) % capacity
        }
    }

    public var elements: [Element] {
        (0..<count).map { buffer[(head + $0) % capacity]! }
    }

    public var isEmpty: Bool { count == 0 }
}

/// 趋势历史的采样节奏、落盘节奏与容量真值。
/// 这些数字此前是 FanModel 内部常量，只能靠源码文本门守；现在由执行级测试覆盖。
public enum TrendHistoryPolicy {
    public static let window: TimeInterval = 10 * 60
    public static let capacity = 200
    /// 200 点铺满 600s 窗 = 3s/点（按趋势环自己的信息率采样，不跟 daemon 拍频）。
    public static let sampleSeconds: TimeInterval = 3
    /// 面板可见时按时间落盘；与拍频解耦，最坏丢失窗口恒定 30s。
    public static let saveSeconds: TimeInterval = 30

    /// 入环前必须同时过：非占位值、与 daemon 统计同一可信谓词、到达采样节奏。
    public static func shouldAppend(hottest: Double, envTemp: Double?,
                                    now: Date, lastAppend: Date,
                                    interval: TimeInterval = sampleSeconds) -> Bool {
        hottest > 1
            && StatsSampler.tempPlausible(hottest, envTemp: envTemp)
            && now.timeIntervalSince(lastAppend) >= interval
    }

    /// 趋势文件唯一消费者是面板；面板长关时不写盘。
    public static func shouldPersist(now: Date, lastSave: Date,
                                     panelVisible: Bool,
                                     interval: TimeInterval = saveSeconds) -> Bool {
        panelVisible && now.timeIntervalSince(lastSave) >= interval
    }
}

/// 趋势历史的 JSON 落盘/恢复（路径由调用方注入，便于测试）。
public struct TrendHistoryStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load(now: Date = Date(),
                     window: TimeInterval = TrendHistoryPolicy.window,
                     capacity: Int = TrendHistoryPolicy.capacity) -> RingBuffer<TrendSample> {
        var ring = RingBuffer<TrendSample>(capacity: capacity)
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? JSONDecoder().decode([TrendSample].self, from: data) else {
            return ring
        }
        let cutoff = now.addingTimeInterval(-window)
        for sample in samples where sample.id >= cutoff {
            ring.append(sample)
        }
        return ring
    }

    public func persist(_ samples: [TrendSample]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
