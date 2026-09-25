import SwiftUI
import AppKit
import SMCCore

// 面板"每拍渲染成本"的离屏量具：FanCtl --tickbench --variant <标签> [--ticks N]
//                                              [--no-window | --onscreen] [--quiet] [--plain]
//
// 为什么存在：R50 把"两处隐式动画值不值得撤"停在"没有数字"上——本会话面板开不出来
//（R21：OS 27 不呈现合成点击），而"撤掉观感会变"与"留着烧 CPU"都不能靠感觉判。
//
// 使用规矩（R51 用真数据换来的两条）：
// ① **绝对值只认 `--onscreen`**：离屏窗口不被 WindowServer 按刷新率合并重绘，实测把每拍
//    成本放大约 2.2×（上屏 327/387/419ms vs 离屏 830/942/833ms）。A/B 差值两种形态都可用。
// ② 量具**不许留下用户态副作用**：面板可见会写 ~/Library/Caches/<bundle>/trend-history.json、
//    会消费 UserDefaults 里的冲刺/静音承诺、高温夹具会真发过热通知。历史教训：R51 首版
//    只重定向了 FanCtlPaths（/Library 侧），漏掉这三条，真的把合成温度写进了用户的趋势缓存。
//    现在启动前快照、退出前还原，并把夹具温度钳在通知阈值以下。
enum TickBench {

    /// 种子化抖动：各变体必须吃到**逐拍相同**的输入序列，否则差值不可解释
    private struct Jitter {
        private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 11) & 0x1F_FFFF) / Double(0x2000_00)
        }
        mutating func span(_ amp: Double) -> Double { (next() - 0.5) * 2 * amp }
    }

    /// 用户态快照：量具跑完原样放回（缺失记为 nil，还原时删键）
    private struct UserState {
        var trend: Data?
        var trendExisted = false
        var defaults: [String: Any?] = [:]
    }

    private static let trendURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fanctl.app/trend-history.json")
    }()
    private static let ownedDefaultsKeys = ["boostEndDate", "boostPrevConfig", "quietEndDate"]

    private static func snapshotUserState() -> UserState {
        var s = UserState()
        s.trendExisted = FileManager.default.fileExists(atPath: trendURL.path)
        s.trend = try? Data(contentsOf: trendURL)
        for k in ownedDefaultsKeys { s.defaults[k] = UserDefaults.standard.object(forKey: k) }
        return s
    }

    private static func restoreUserState(_ s: UserState) {
        if s.trendExisted {
            if let d = s.trend { try? d.write(to: trendURL, options: .atomic) }
        } else {
            try? FileManager.default.removeItem(at: trendURL)
        }
        for (k, v) in s.defaults {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        UserDefaults.standard.synchronize()
    }

    @MainActor static func run() {
        let args = CommandLine.arguments
        let rawVariant = value(of: "--variant", in: args) ?? "?"
        // variant 会拼进文件路径：只留安全字符并截断（同用户下的符号链接/`..` 面）
        let variant = String(rawVariant.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }.prefix(24))
        let ticks = Int(value(of: "--ticks", in: args) ?? "") ?? 30
        let noWindow = args.contains("--no-window")
        // --quiet：计时阶段**不喂新数据**。窗口开着却不掉拍 → 成本是自己续帧的循环，
        // 不能记在"每拍动画"头上；掉到近零 → 成本确实逐拍而来，A/B 差值才有意义。
        let quiet = args.contains("--quiet")
        // --plain：卡片走实心材质（snapshotPlainCards 的降级渲染）。与 A 的差值 =
        // "每拍重算时 Liquid Glass 到底摊了多少"。
        let plain = args.contains("--plain")
        let onscreen = args.contains("--onscreen")
        snapshotPlainCards = plain

        let userState = snapshotUserState()
        func finish(_ line: String, code: Int32) -> Never {
            restoreUserState(userState)
            print(line)
            exit(code)
        }

        // 覆盖前取真路径（覆盖后 supportDir 指向临时目录）
        let realDir = FanCtlPaths.supportDir
        guard let fixture = try? Data(contentsOf: realDir.appendingPathComponent("status.json")),
              let json = (try? JSONSerialization.jsonObject(with: fixture)) as? [String: Any] else {
            finish("TICKBENCH variant=\(variant) ABORT=no-fixture（没有 daemon 写的 status.json 就不测，不做空气门）",
                   code: 2)
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fanctl-tickbench-\(UUID().uuidString)")
        // 0700：目录里是从真实 /Library 复制来的 config/history/画像，不能让同机他用户读
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        for name in ["config.json", "stats.json", "history.json", "ai-learn.json",
                     "ai-metrics.json", "thermal-model.json"] {
            if let d = try? Data(contentsOf: realDir.appendingPathComponent(name)) {
                try? d.write(to: dir.appendingPathComponent(name))
            }
        }
        FanCtlPaths.setOverridesForTesting(supportDir: dir, logDir: dir)

        let model = FanModel()
        let now = Date()
        model.history = stride(from: -600.0, through: 0, by: 6).map { off in
            let base = 66 + 8 * sin(off / 90)
            return FanModel.TempSample(id: now.addingTimeInterval(off), cpu: base, gpu: base - 14)
        }
        model.panelVisible = true   // 走面板可见分支——withAnimation 的守卫条件就在这儿

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: ContentView(model: model).fixedSize())
        host.setFrameSize(host.fittingSize)
        let size = host.bounds.size
        // --no-window：不接窗口服务器。有它才能把"每拍成本"拆成渲染/非渲染两块。
        if !noWindow {
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
        let pngPath = dir.appendingPathComponent("panel.png").path
        var jitter = Jitter()
        var tickIndex = 0
        var lastWrittenTemp = 0.0
        func tick() {
            tickIndex += 1
            lastWrittenTemp = writeTick(fixture: json, jitter: &jitter,
                                        at: now.addingTimeInterval(Double(tickIndex)), to: statusURL)
        }
        tick()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))   // 建树 + 字体 + Charts 首布局

        // 每拍切两段取样（0–250ms 首片 / 750–1000ms 尾片）：首片热、尾片凉 = 一拍算一次；
        // 首尾一样热 = 动画自己续帧的常驻循环。计时起点放在**写盘之后**——否则量具自己的
        // JSON 序列化与 rename 会被记进"首片"，那是量具烧的不是面板烧的。
        var head: [UInt64] = []
        var tail: [UInt64] = []
        var perTick: [UInt64] = []
        var rssSeries: [Int] = []
        guard let rssStart = residentBytes() else {
            finish("TICKBENCH variant=\(variant) ABORT=task-info-failed（读不到自身内存，不出数）", code: 3)
        }
        for i in 1...max(1, ticks) {
            tick()
            let base = Date()
            guard let c0 = cpuMicros() else {
                finish("TICKBENCH variant=\(variant) ABORT=getrusage-failed（差值会回绕成巨值，不出数）", code: 3)
            }
            RunLoop.main.run(until: base.addingTimeInterval(0.25))
            let c1 = cpuMicros() ?? c0
            RunLoop.main.run(until: base.addingTimeInterval(0.75))
            let c2 = cpuMicros() ?? c1
            RunLoop.main.run(until: base.addingTimeInterval(1.0))
            guard let c3 = cpuMicros() else {
                finish("TICKBENCH variant=\(variant) ABORT=getrusage-failed", code: 3)
            }
            head.append(c1 &- c0)
            tail.append(c3 &- c2)
            perTick.append(c3 &- c0)
            // 有符号差：中途 RSS 会回落，无符号减会回绕成天文数字
            if i % 5 == 0, let r = residentBytes() { rssSeries.append(Int((Int64(r) - Int64(rssStart)) / 1024)) }
        }
        let rssEnd = residentBytes() ?? rssStart
        capture(host, to: pngPath)

        let sorted = perTick.sorted()
        let median = sorted[sorted.count / 2]
        let mean = perTick.reduce(0, { $0 &+ $1 }) / UInt64(sorted.count)
        let rssDeltaKB = Int64(truncatingIfNeeded: rssEnd &- rssStart) / 1024
        // 自证两件事：数据真进了模型（model_temp ≈ written_temp，否则整轮在量静态树）、
        // 图有货（history_count，否则"图表不收费"是假绿）。形态写进同一行，便于复核。
        finish("TICKBENCH variant=\(variant) window=\(noWindow ? 0 : 1) onscreen=\(onscreen ? 1 : 0) "
               + "quiet=\(quiet ? 1 : 0) plain=\(plain ? 1 : 0) ticks=\(sorted.count) "
               + "median_us=\(median) mean_us=\(mean) max_us=\(sorted.last ?? 0) min_us=\(sorted.first ?? 0) "
               + "head_med_us=\(medianOf(head)) tail_med_us=\(medianOf(tail)) "
               + "rss_delta_kb=\(rssDeltaKB) rss_per_tick_kb=\(rssDeltaKB / Int64(max(1, sorted.count))) "
               + "rss_series_kb=\(rssSeries.map { String($0) }.joined(separator: ",")) "
               + "view=\(Int(size.width))x\(Int(size.height)) history_count=\(model.history.count) "
               + "model_temp=\(String(format: "%.2f", model.cpuTemp)) written_temp=\(String(format: "%.2f", lastWrittenTemp)) "
               + "domain=\(Bundle.main.bundleIdentifier ?? "none") png=\(pngPath)", code: 0)
    }

    // MARK: - 夹具逐拍改写

    /// 从**原始夹具**派生每一拍（不在上一拍结果上累加，否则温度随机游走、变体间不可比）。
    /// 返回本拍写进去的 CPU 温度，供调用方与模型值对账。
    @discardableResult
    private static func writeTick(fixture: [String: Any], jitter: inout Jitter,
                                  at date: Date, to url: URL) -> Double {
        var json = fixture
        var sensors = (json["sensors"] as? [String: Any]) ?? [:]
        // 钳在 80° 以下：checkOverheat 是面板可见路径上的真通知（含首次授权弹窗），
        // 量具不该因为"机器当时很热"就去弹用户
        let cpu = min(80, ((sensors["cpuDie"] as? Double) ?? 66) + jitter.span(0.8))
        let gpu = min(80, ((sensors["gpuDie"] as? Double) ?? 52) + jitter.span(0.8))
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
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return cpu }
        // 原子替换（与 daemon 同形状）：kqueue 收 .rename 后重建监控
        let tmp = url.appendingPathExtension("tick")
        try? data.write(to: tmp)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
        return cpu
    }

    private static let iso8601NoFraction: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    // MARK: - 量具

    private static func medianOf(_ xs: [UInt64]) -> UInt64 {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    private static func cpuMicros() -> UInt64? {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return nil }
        return (UInt64(ru.ru_utime.tv_sec) * 1_000_000) + UInt64(ru.ru_utime.tv_usec)
             + (UInt64(ru.ru_stime.tv_sec) * 1_000_000) + UInt64(ru.ru_stime.tv_usec)
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : nil
    }

    /// 渲染自证：窗口真的画出了东西（尺寸/像素）才谈得上"每拍成本"
    private static func capture(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
