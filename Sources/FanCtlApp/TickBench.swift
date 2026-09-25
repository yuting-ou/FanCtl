import SwiftUI
import AppKit
import SMCCore

// 面板"每拍渲染成本"的离屏量具：FanCtl --tickbench --variant <标签> [--ticks N]
//
// 为什么存在：R50 把"两处隐式动画值不值得撤"停在"没有数字"上——本会话面板开不出来
// （R21：OS 27 不呈现合成点击），而"撤掉观感会变"与"留着烧 CPU"都不能靠感觉判。
// 于是造仪器：真实 status.json 当夹具、逐拍按真机幅度抖动、真窗口离屏托管（走运行时
// 的 glass 路径，不是 ImageRenderer 的降级路径），量每拍进程 CPU 与内存斜率。
//
// 边界：只在启动时**读**一次 /Library/Application Support/FanCtl/*.json，随后所有写盘
// 经 FanCtlPaths 重定向落进临时目录（不会污染用户数据、不会替 daemon 说谎）；
// 被测代码 = 发行代码，变体靠源码切换，不在生产视图里留 if 分支。
enum TickBench {

    /// 种子化抖动：A/B/C/D 四个变体必须吃到**逐拍相同**的输入序列，否则差值不可解释
    private struct Jitter {
        private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 11) & 0x1F_FFFF) / Double(0x2000_00)
        }
        /// 对称抖动：[-amp, +amp]
        mutating func span(_ amp: Double) -> Double { (next() - 0.5) * 2 * amp }
    }

    @MainActor static func run() {
        let args = CommandLine.arguments
        let variant = value(of: "--variant", in: args) ?? "?"
        let ticks = Int(value(of: "--ticks", in: args) ?? "") ?? 30
        let noWindow = args.contains("--no-window")
        // --quiet：计时阶段**不喂新数据**。窗口开着却不掉拍 → 成本是自己续帧的循环，
        // 不能记在"每拍动画"头上；掉到近零 → 成本确实逐拍而来，A/B 差值才有意义。
        let quiet = args.contains("--quiet")
        // --plain：卡片走实心材质（snapshotPlainCards 的降级渲染）。与 A 的差值 = 
        // "每拍重算时 Liquid Glass 到底摊了多少"，不测这一层就只能把 800ms 整个猜给玻璃。
        let plain = args.contains("--plain")
        snapshotPlainCards = plain

        // 覆盖前取真路径（覆盖后 supportDir 指向临时目录）
        let realDir = FanCtlPaths.supportDir
        guard let fixture = try? Data(contentsOf: realDir.appendingPathComponent("status.json")),
              let json = (try? JSONSerialization.jsonObject(with: fixture)) as? [String: Any] else {
            print("TICKBENCH variant=\(variant) ABORT=no-fixture（没有 daemon 写的 status.json 就不测，不做空气门）")
            exit(2)
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fanctl-tickbench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["config.json", "stats.json", "history.json", "ai-learn.json",
                     "ai-metrics.json", "thermal-model.json", "hardware-profile.json"] {
            if let d = try? Data(contentsOf: realDir.appendingPathComponent(name)) {
                try? d.write(to: dir.appendingPathComponent(name))
            }
        }
        FanCtlPaths.setOverridesForTesting(supportDir: dir, logDir: dir)

        let model = FanModel()
        let now = Date()
        // 趋势环要有货：空 SparkLine/Charts 的每拍成本是 0，会让"动画很便宜"成为假绿
        model.history = stride(from: -600.0, through: 0, by: 6).map { off in
            let base = 66 + 8 * sin(off / 90)
            return FanModel.TempSample(id: now.addingTimeInterval(off),
                                       cpu: base, gpu: base - 14)
        }
        model.panelVisible = true   // 走面板可见分支——withAnimation 的守卫条件就在这儿

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: ContentView(model: model).fixedSize())
        host.setFrameSize(host.fittingSize)
        let size = host.bounds.size
        // --no-window：不接窗口服务器。有它才能把"每拍成本"拆成渲染/非渲染两块，
        // 而不是把两块混成一个数（混在一起的数既不能归因也不能复核）。
        if !noWindow {
            // --onscreen：把窗口摆在真实面板的位置（右上角、菜单栏下方）。
            // 离屏坐标可能被 WindowServer 当作"不上屏"→ 不节流、不合并重绘，
            // 那样量出来的每拍成本就没有外部效度。这条对照决定 800ms 是产品事实还是量具假象。
            let onscreen = args.contains("--onscreen")
            var origin = NSPoint(x: -6000, y: -6000)
            if onscreen, let vf = NSScreen.main?.visibleFrame {
                origin = NSPoint(x: vf.maxX - size.width - 8, y: vf.maxY - size.height - 28)
            }
            let w = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.isReleasedWhenClosed = false
            if onscreen { w.makeKeyAndOrderFront(nil) } else { w.orderFront(nil) }
        }

        let statusURL = dir.appendingPathComponent("status.json")
        let pngPath = "/tmp/fanctl-tickbench-\(variant).png"
        var jitter = Jitter()
        var tickIndex = 0
        func tick() {
            tickIndex += 1
            writeTick(fixture: json, jitter: &jitter, at: now.addingTimeInterval(Double(tickIndex)), to: statusURL)
        }
        tick()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))   // 建树 + 字体 + Charts 首布局
        // 趋势环要在计时之前铺好：panelVisible 的 didSet 会从磁盘重载 history，
        // 计时中再塞会被下一拍覆盖——空环等于"图表不收费"的假绿
        func reseedHistory() {
            let t = Date()
            model.history = stride(from: -600.0, through: 0, by: 3).map { off in
                let base = 66 + 8 * sin(off / 90)
                return FanModel.TempSample(id: t.addingTimeInterval(off), cpu: base, gpu: base - 14)
            }
        }
        reseedHistory()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        // 每拍切两段取样（0–250ms 首片 / 750–1000ms 尾片）：首片热、尾片凉 = 一拍算一次；
        // 首尾一样热 = 动画自己续帧的常驻循环。两者处置完全不同，不能只报一个总数。
        var head: [UInt64] = []
        var tail: [UInt64] = []
        var perTick: [UInt64] = []
        var rssSeries: [Int] = []
        let rssStart = residentBytes()
        for i in 1...max(1, ticks) {
            let c0 = cpuMicros()
            if !quiet { tick() }
            let base = Date()
            RunLoop.main.run(until: base.addingTimeInterval(0.25))
            let c1 = cpuMicros()
            RunLoop.main.run(until: base.addingTimeInterval(0.75))
            let c2 = cpuMicros()
            RunLoop.main.run(until: base.addingTimeInterval(1.0))
            let c3 = cpuMicros()
            head.append(c1 &- c0)
            tail.append(c3 &- c2)
            perTick.append(c3 &- c0)
            // 有符号差：中途 RSS 会回落（页缓存/释放），无符号减会回绕成天文数字
            if i % 5 == 0 { rssSeries.append(Int((Int64(residentBytes()) - Int64(rssStart)) / 1024)) }
        }
        let rssEnd = residentBytes()
        capture(host, to: pngPath)   // 跑完再截：渲染自证（真画出东西才谈得上每拍成本）

        let sorted = perTick.sorted()
        let median = sorted[sorted.count / 2]
        let mean = perTick.reduce(0, { $0 &+ $1 }) / UInt64(sorted.count)
        let rssDeltaKB = Int64(truncatingIfNeeded: rssEnd &- rssStart) / 1024
        print("TICKBENCH variant=\(variant) window=\(noWindow ? 0 : 1) quiet=\(quiet ? 1 : 0) plain=\(plain ? 1 : 0) ticks=\(sorted.count) "
            + "median_us=\(median) mean_us=\(mean) max_us=\(sorted.last ?? 0) min_us=\(sorted.first ?? 0) "
            + "head_med_us=\(medianOf(head)) tail_med_us=\(medianOf(tail)) "
            + "rss_delta_kb=\(rssDeltaKB) rss_per_tick_kb=\(rssDeltaKB / Int64(max(1, sorted.count))) "
            + "rss_series_kb=\(rssSeries.map { String($0) }.joined(separator: ",")) "
            + "view=\(Int(size.width))x\(Int(size.height)) png=\(pngPath)")
        exit(0)
    }

    private static func medianOf(_ xs: [UInt64]) -> UInt64 {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    /// 从**原始夹具**派生每一拍（不在上一拍结果上累加，否则温度随机游走、变体间不可比）
    private static func writeTick(fixture: [String: Any], jitter: inout Jitter,
                                  at date: Date, to url: URL) {
        var json = fixture
        var sensors = (json["sensors"] as? [String: Any]) ?? [:]
        let cpu = ((sensors["cpuDie"] as? Double) ?? 66) + jitter.span(0.8)
        let gpu = ((sensors["gpuDie"] as? Double) ?? 52) + jitter.span(0.8)
        sensors["cpuDie"] = cpu
        sensors["gpuDie"] = gpu
        if sensors["cpuAverage"] != nil { sensors["cpuAverage"] = cpu - 9 + jitter.span(1.5) }
        json["sensors"] = sensors
        json["cpuTemp"] = cpu
        json["gpuTemp"] = gpu
        if var fans = (json["fans"] as? [[String: Any]]) {
            for k in fans.indices {
                let lo = (fans[k]["minRPM"] as? Double) ?? 1200
                let hi = (fans[k]["maxRPM"] as? Double) ?? 5400
                let mid = (fans[k]["targetRPM"] as? Double) ?? (lo + hi) / 2
                fans[k]["actualRPM"] = min(hi, max(lo, mid + jitter.span(60)))
            }
            json["fans"] = fans
        }
        if json["appliedPercent"] != nil {
            json["appliedPercent"] = max(0, min(100, ((json["appliedPercent"] as? Double) ?? 50) + jitter.span(1.2)))
        }
        if var pcts = (json["appliedPercents"] as? [Double]) {
            for k in pcts.indices { pcts[k] = max(0, min(100, pcts[k] + jitter.span(1.2))) }
            json["appliedPercents"] = pcts
        }
        if json["powerWatts"] != nil {
            json["powerWatts"] = max(0.2, ((json["powerWatts"] as? Double) ?? 30) + jitter.span(1.5))
        }
        // 合成单调时钟：秒级时间戳逐拍必不同，App 的 timestamp != lastStatusTimestamp 去重
        // 不会把某一拍吞掉（用 Date() 时同秒两拍会丢刷新，成本就被摊平到"看起来更省"）
        json["timestamp"] = iso8601NoFraction.string(from: date)
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        // 原子替换（与 daemon 同形状）：kqueue 收 .rename 后重建监控
        let tmp = url.appendingPathExtension("tick")
        try? data.write(to: tmp)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }

    private static let iso8601NoFraction: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    // MARK: - 量具

    private static func cpuMicros() -> UInt64 {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return 0 }
        return (UInt64(ru.ru_utime.tv_sec) * 1_000_000) + UInt64(ru.ru_utime.tv_usec)
             + (UInt64(ru.ru_stime.tv_sec) * 1_000_000) + UInt64(ru.ru_stime.tv_usec)
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    /// 渲染自证：窗口真的画出了东西（尺寸/像素）才谈得上"每拍成本"
    private static func capture(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
