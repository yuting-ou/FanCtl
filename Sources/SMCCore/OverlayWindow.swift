// OverlayWindow —— 静音承诺 / 冲刺这两段时间窗口的**唯一判据**，以及 App 的双入口对账。
//
// daemon（ControlEngine）、App 面板、MCP 三个入口都要回答同一个问题："此刻这段窗口
// 生效吗、还剩多久"。各写一份必然漂移，R83 加 MCP 时两头都漂了：
//
// ① MCP 只判 `until > now`，而 daemon 的 saneHorizon 把超过 24h 的截止时间整个视为
//    未设置、静音还额外要求封顶值在场 ⇒ config 里一个 48h 的 quietUntil（手改/损坏）
//    daemon 根本不封顶，MCP 却回 quietActive=true，同一份 JSON 里 mode 还是 auto。
// ② App 的 syncConfigFromDisk 回填了 mode/manualPercent/曲线，唯独不读 quietUntil/
//    boostUntil（旧注释写着"App 是唯一写入方"，R83 起不再成立）⇒ MCP 设的静音被 App
//    下一次 saveConfig 静默取消；冲刺更糟——App 把 boostUntil 写成 nil 而 mode 仍是
//    manual 100%，daemon 的到期判定要求 boostUntil != nil，于是再也不触发，
//    "冲刺 15 分钟"变成永久全速（ControlEngine 的冲刺超时兜底注释预言的正是这个形态）。

import Foundation

public enum OverlayWindow {
    /// 截止时间卫生上限（v3.6.2 F5 同值）：正常写入是 15/30 分钟，
    /// 超过 24h 的 horizon 只可能来自手改/损坏的 config.json。
    public static let maxHorizon: TimeInterval = 24 * 3600

    /// 消毒后的截止时间。nil = 视为未设置（本来没有，或异常久远）。
    public static func effective(until: Date?, now: Date) -> Date? {
        guard let d = until else { return nil }
        return d.timeIntervalSince(now) > maxHorizon ? nil : d
    }

    /// 此刻是否落在窗口内（已过期的截止时间 = 不活跃）。
    public static func isActive(until: Date?, now: Date) -> Bool {
        guard let d = effective(until: until, now: now) else { return false }
        return now < d
    }

    /// 静音是否真的在封顶：daemon 侧额外要求封顶值在场（ControlEngine 的 quietActive）。
    /// 缺 cap 时 daemon 不封顶，任何入口都不该报"静音中"。
    public static func quietActive(config: FanConfig, now: Date) -> Bool {
        isActive(until: config.quietUntil, now: now) && config.quietCapPercent != nil
    }

    /// 冲刺是否已到期/被判无效（daemon 对这种形态是"本拍起视为 auto 交还系统"）。
    public static func boostExpired(config: FanConfig, now: Date) -> Bool {
        config.boostUntil != nil && !isActive(until: config.boostUntil, now: now)
    }
}

/// App 从磁盘对账静音/冲刺窗口的结果。纯数据，判据全在 `OverlaySync.adopt`。
public struct OverlayAdoption: Equatable {
    /// 应当展示的静音截止（nil = 没有生效中的静音）
    public var quietEnd: Date?
    /// 生效中静音的封顶百分比（仅 quietEnd != nil 时有值）
    public var quietCapPercent: Double?
    /// 应当展示的冲刺截止（nil = 没有生效中的冲刺）
    public var boostEnd: Date?
    /// 磁盘上这段冲刺不是 App 起的那一段 ⇒ App 手里没有"冲刺前快照"，
    /// 到期只能诚实回 auto（与 MCP 的 boost end=true 同一语义）
    public var boostIsForeign: Bool
    /// App 侧状态是否需要改动（决定是否刷标签字形、写 UserDefaults）
    public var changed: Bool

    public init(quietEnd: Date?, quietCapPercent: Double?, boostEnd: Date?,
                boostIsForeign: Bool, changed: Bool) {
        self.quietEnd = quietEnd
        self.quietCapPercent = quietCapPercent
        self.boostEnd = boostEnd
        self.boostIsForeign = boostIsForeign
        self.changed = changed
    }
}

public enum OverlaySync {
    /// 一秒容差：config.json 走 iso8601（**秒精度**）往返，App 内存里的 Date 带亚秒，
    /// 严格相等会把 App 自己刚写的窗口误判成"外部写入"，从而清掉自己的冲刺快照。
    public static let tolerance: TimeInterval = 1.0

    /// 以磁盘为准对账：磁盘是 daemon 正在用的事实，App 只做镜像。
    /// 已过期的窗口一律不采纳（daemon 已按 auto/不封顶处理，App 不该再显示倒计时）；
    /// App 自己起的过期冲刺由调用方的快照恢复路径处理，不经过这里。
    public static func adopt(disk: FanConfig,
                             appQuietEnd: Date?, appQuietCap: Double?,
                             appBoostEnd: Date?, now: Date) -> OverlayAdoption {
        let quietOn = OverlayWindow.quietActive(config: disk, now: now)
        let quietEnd = quietOn ? disk.quietUntil : nil
        let cap = quietOn ? disk.quietCapPercent : nil
        let boostEnd = OverlayWindow.isActive(until: disk.boostUntil, now: now) ? disk.boostUntil : nil

        let capDiffers: Bool
        if let c = cap, let a = appQuietCap { capDiffers = abs(c - a) > 0.5 }
        else { capDiffers = cap != nil || appQuietCap != nil }

        return OverlayAdoption(
            quietEnd: quietEnd,
            quietCapPercent: cap,
            boostEnd: boostEnd,
            boostIsForeign: boostEnd != nil && !sameInstant(boostEnd, appBoostEnd),
            changed: !sameInstant(quietEnd, appQuietEnd)
                || !sameInstant(boostEnd, appBoostEnd)
                || (quietEnd != nil && capDiffers))
    }

    /// 两个时刻是否指同一秒（含 nil 情形）
    public static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return abs(x.timeIntervalSince(y)) <= tolerance
        default: return false
        }
    }
}
