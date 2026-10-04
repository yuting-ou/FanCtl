import Foundation

// MARK: - 进程"是谁"的中文可读辨识（R79）
//
// 修的问题（作者原话："像清风那个占用选项那里，都是英文的，我看不明白"）：
// 「占用」页此前直接显示进程的**可执行文件名**——swift-frontend / WindowServer /
// 抖音 Helper (Renderer)。开发者认得，日常用户完全看不出"到底是哪个软件在吃我机器"，
// 而清风的存在意义就是让人一眼看懂谁在发热。遂加这一层辨识。
//
// 设计原则（按优先级从高到低，每级都有兜底，绝不把用户抛给英文）：
//
//   1. **本 App / 框架自带的中文名**：App bundle 的 CFBundleDisplayName 优先，
//      其次 CFBundleName，最后 bundle 文件名去掉 .app。这是"这个软件的官方中文名"。
//   2. **helper → 归属 App**：macOS 的 Electron/Chromium 系 App（抖音 / DeepSeek Harness /
//      Hermes …）把真正干活的东西放在 `X.app/Contents/Frameworks/Y Helper.app` 里。
//      看这种进程要报**软件名**（"抖音"），不是"抖音 Helper (Renderer)"这种内部构件名。
//   3. **无 bundle 的系统组件**：WindowServer / coreaudiod 等 Apple 私有进程没有
//      Info.plist 可读，靠一张内置对照表翻成中文（"窗口服务器"）。对不上就原样给，
//      但**绝不猜**——猜错比显示英文更糟。
//
// 关键取舍：**不联网、不猜、可测试**。纯本地读 plist + 一张静态表；
// 英文名查不到中文时保留原值（诚实 > 讨好）。

public enum ProcessIdentity {

    /// 判定一个显示名是否已经"中文化"——`fanprobe --zh-scan`（汉化覆盖度体检）用它
    /// 筛出仍然吐英文的进程名。标准：含 CJK 统一表意文字（含扩展A）即算；
    /// 「Apple 系统组件（…）」这类带中文前缀的也算过（原文留括号是刻意的诚实）。
    public static func hasChinese(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v)      // CJK 基本区
                || (0x3400...0x4DBF).contains(v)      // 扩展 A
        }
    }

    /// 已知无 bundle / 无法自动辨识的系统进程 → 中文对照。
    /// 只收"确实无他法"的：Apple 私有框架、守护进程、XPC 服务。
    /// 故意不做"猜"：对不上就回落原英文名，由用户自己认。
    private static let systemGlossary: [String: String] = [
        // —— macOS 核心合成/图形/窗口 ——
        "WindowServer": "窗口服务器（屏幕合成）",
        "loginwindow": "登录窗口",
        "Dock": "程序坞",
        "Finder": "访达",
        "SystemUIServer": "系统菜单栏",
        "Spotlight": "聚焦搜索",
        "NotificationCenter": "通知中心",
        // —— 音频/媒体 ——
        "coreaudiod": "音频服务",
        "mediaanalysisd": "媒体分析",
        "VTDecoderXPCService": "视频解码器",
        "mediaremoted": "媒体遥控",
        // —— 常见守护/网络/电源 ——
        "launchd": "系统启动守护进程",
        "identityservicesd": "信息(iMessage)服务",
        "sharingd": "隔空投送服务",
        "AirPlayUIAgent": "隔空播放",
        "powerd": "电源管理",
        "configd": "网络配置服务",
        "mDNSResponder": "网络域名解析(Bonjour)",
        "locationd": "定位服务",
        "timed": "时间同步服务",
        "UserEventAgent": "用户事件代理",
        "runningboardd": "应用生命周期管理",
        "syspolicyd": "系统安全策略",
        "opendirectoryd": "目录服务(登录账户)",
        "trustd": "证书信任服务",
        "nesessionmanager": "网络扩展会话管理",
        "energyeagd": "能耗管理",
        "corebrightnessd": "亮度调节",
        "hidd": "人机接口设备(键鼠/触控板)",
        "talagent": "定时任务代理",
        "distnoted": "系统通知分发",
        "cfprefsd": "偏好设置服务",
        "LoggingWidgets": "日志组件",
        // —— 浏览器/开发常见（多实例、常驻后台，用户最常问"这啥"）——
        "Google Chrome": "谷歌浏览器",
        "chrome": "谷歌浏览器",
        "node": "Node.js 运行时",
        "python3": "Python 解释器",
        "python": "Python 解释器",
        "firefox": "Firefox 浏览器",
        "plugin-container": "Firefox 辅助进程",
        "Microsoft Edge": "Edge 浏览器",
        "msedgewebview2": "Edge 网页组件",
        "Code": "VS Code 编辑器",
        "zcode-cli": "ZCode 命令行",
        // —— R82：占用榜高频常客（无 bundle 可归属的系统后台）——
        "kernel_task": "内核任务（系统核心）",
        "mds": "聚焦索引",
        "mds_stores": "聚焦索引（存储）",
        "mdworker_shared": "聚焦索引（扫描）",
        "spotlightknowledged": "聚焦建议",
        "photoanalysisd": "照片分析",
        "photolibraryd": "照片图库",
        "bluetoothd": "蓝牙服务",
        "dasd": "后台任务调度",
        "tccd": "隐私权限管理",
        "amfid": "代码签名验证",
        "XprotectService": "恶意软件防护",
        "cloudd": "iCloud 同步",
        "bird": "iCloud 云盘",
        "fileproviderd": "文件同步服务",
        "nsurlsessiond": "系统网络传输",
        "commcenter": "通信服务",
        "mobileassetd": "系统资源下载",
        "softwareupdated": "系统更新",
        "backupd": "时间机器备份",
        "ReportCrash": "崩溃报告",
        "logd": "系统日志",
        "corespeechd": "语音服务",
        "assistantd": "Siri 服务",
        "universalaccessd": "辅助功能服务",
        "CoreServicesUIAgent": "系统确认框",
        "WallpaperAgent": "墙纸代理",
        // —— Safari/WebKit 的 XPC 构件：路径里是 .xpc 不是 .app，归不了 App，只能查表 ——
        "com.apple.WebKit.WebContent": "Safari 网页内容",
        "com.apple.WebKit.Networking": "Safari 网络进程",
        "com.apple.WebKit.GPU": "Safari 图形进程",
        "com.apple.Safari.SandboxBroker": "Safari 沙盒代理",
        "QuickLookUIService": "快速查看",
        "com.apple.quicklook.ThumbnailsAgent": "快速查看缩略图",
        // —— 常用 App：中文名不在主 Info.plist 里（Apple 自家 App 的 plist 是英文），
        //      又没有 InfoPlist.strings 兜底时（Terminal/计算器实测无此文件）——
        "Terminal": "终端",
        "Calculator": "计算器",
        "Activity Monitor": "活动监视器",
        "Console": "控制台",
        "Photos": "照片",
        "Music": "音乐",
        // —— 开发工具链（编译/构建时霸榜的主力）——
        "swift-frontend": "Swift 编译器",
        "swift": "Swift 工具链",
        "clang": "C 编译器",
        "clang++": "C++ 编译器",
        "ld": "链接器",
        "rustc": "Rust 编译器",
        "java": "Java 运行时",
        "git": "Git 版本控制",
        "git-remote-https": "Git 网络传输",
        "ssh": "SSH 连接",
        "docker": "Docker",
        "com.docker.backend": "Docker 后台服务",
        "ffmpeg": "视频转码 ffmpeg",
        "Electron": "Electron 应用",
        "SourceKitService": "Xcode 代码索引",
        "XCBBuildService": "Xcode 构建服务",
        "GradleDaemon": "Gradle 构建守护进程",
        "Visual Studio Code": "VS Code 编辑器",
                                // —— 本产品自己的构件：exe 字段缺失只剩裸名时也必须显示中文（R82 续，用户点名）——
        "FanCtl": "清风",
        "fanctld": "清风守护进程",
        "fanprobe": "清风诊断工具",
        "spinwatch": "清风空转哨兵",
        // —— 国民级 App 的构件：主 plist 常是英文名、又常常不带 InfoPlist.strings，
        //      空转/占用里以裸名出现时只能靠这张表 ——
        "WeChat": "微信",
        "wechat": "微信",
        "wechatwebencodingservice": "微信 内置浏览器",
        "WeChatAppEx": "微信 小程序",
        "WeChatPlayer": "微信 播放器",
        "WeChatUtility": "微信 工具",
        "WeChatBrowser": "微信 内置浏览器",
        "dingtalk": "钉钉",
        "DingTalk": "钉钉",
        "Lark": "飞书",
        "Feishu": "飞书",
        "BaiduNetdisk": "百度网盘",
        "baidunetdisk": "百度网盘",
        "Thunder": "迅雷",
        "ThunderHelper": "迅雷 辅助进程",
        "iQIYI": "爱奇艺",
        "CloudMusic": "网易云音乐",
        "NeteaseMusic": "网易云音乐",
        "QQMusic": "QQ音乐",
        "Microsoft AutoUpdate": "微软自动更新",
        // —— R82 续补漏：其余高频系统件 ——
        "mdworker": "聚焦索引（扫描）",
        "findmydeviced": "查找服务",
        "mobiletimerd": "时钟服务",
        // —— R82 续二（实测扫描 fanprobe --zh-scan）：Apple 自带 App ——
        // 这些 App 的 zh_CN.lproj 里没有 InfoPlist.strings（实测），Finder 中文名系统另有
        // 来源，我们的 bundle 读取拿不到 → 只能查表。以下是苹果官方简体中文名，非编造。
        "Automator": "自动操作",
        "Books": "图书",
        "Calendar": "日历",
        "Chess": "象棋",
        "Clock": "时钟",
        "Contacts": "通讯录",
        "Dictionary": "词典",
        "FindMy": "查找",
        "Font Book": "字体册",
        "Freeform": "无边记",
        "Games": "Apple 游戏",
        "Home": "家庭",
        "Image Capture": "图像捕捉",
        "Image Playground": "图像乐园",
        "Journal": "手记",
        "Mail": "邮件",
        "Maps": "地图",
        "Messages": "信息",
        "Mission Control": "调度中心",
        "News": "新闻",
        "Notes": "备忘录",
        "Passwords": "密码",
        "Phone": "电话",
        "Podcasts": "播客",
        "Preview": "预览",
        "Reminders": "提醒事项",
        "Shortcuts": "快捷指令",
        "Stickies": "便签",
        "Stocks": "股市",
        "System Settings": "系统设置",
        "Time Machine": "时间机器",
        "Tips": "提示",
        "VoiceMemos": "语音备忘录",
        "Weather": "天气",
        "iPhone Mirroring": "iPhone 镜像",
        // —— 实用工具（/System/Applications/Utilities）——
        "Disk Utility": "磁盘工具",
        "Keychain Access": "钥匙串访问",
        "AirPort Utility": "AirPort 实用工具",
        "Audio MIDI Setup": "音频 MIDI 设置",
        "Bluetooth File Exchange": "蓝牙文件交换",
        "Digital Color Meter": "数码测色计",
        "Magnifier": "放大器",
        "Migration Assistant": "迁移助理",
        "Print Center": "打印中心",
        "Screen Sharing": "屏幕共享",
        "Screenshot": "截屏",
        "Script Editor": "脚本编辑器",
        "System Information": "系统信息",
        "VoiceOver Utility": "VoiceOver 实用工具",
        "ColorSync Utility": "ColorSync 实用工具",
        // —— CoreServices 系统界面组件（可能出现在占用榜）——
        "ControlCenter": "控制中心",
        "ScreenSaverEngine": "屏幕保护",
        "Screen Time": "屏幕使用时间",
        "Game Center": "游戏中心",
        "Certificate Assistant": "证书助理",
        "Keyboard Setup Assistant": "键盘设置助理",
        "DiskImageMounter": "磁盘映像装载器",
        "Installer": "安装器",
        "AddPrinter": "添加打印机",
        "Batteries": "电池",
        "Family": "家人共享",
        "AirDropUI": "隔空投送",
        "Problem Reporter": "问题报告",
        "Apple Diagnostics": "Apple 诊断",
        "Erase Assistant": "抹掉助理",
        // —— 第三方（有通行的中文名才收；Telegram/iTerm2/IINA 等品牌名保持原名，
        //      中文用户也这么叫——诚实 > 讨好，不硬翻品牌）——
        "Tencent Lemon": "腾讯柠檬清理",
        "Xiaomi MiMo": "小米 MiMo",
        "Microsoft Word": "Word 文字处理",
        "Microsoft Excel": "Excel 表格",
        "Microsoft PowerPoint": "PowerPoint 演示文稿",
        "Microsoft Defender Shim": "Microsoft Defender 防护",
        // —— R82 续二第三批（--zh-scan 复扫拾遗）：exe 名与 bundle 名不一致的无空格变体、
        //      以及确实会被用户撞见的服务 ——
        "BluetoothSetupAssistant": "蓝牙设置助理",
        "KeyboardSetupAssistant": "键盘设置助理",
        "Captive Network Assistant": "网络登录助手",
        "AppleScript Utility": "AppleScript 实用工具",
        "AccessibilityUIServer": "辅助功能界面服务",
        "MediaRemoteUI": "媒体播放界面",
        "MediaRemoteUIService": "媒体播放界面",
        "Install Command Line Developer Tools": "安装命令行开发者工具",
        "oahd": "Rosetta 转译服务",
        "syslogd": "系统日志",
        "diskarbitrationd": "磁盘仲裁服务",
        // —— R82 续二第四批（按本机实时 CPU 榜挑出的真·会冒头者）——
        "Dynamic Wallpaper": "动态壁纸",
        "signpost_reporter": "性能标记报告",
        "powermetrics": "功耗度量工具",
        "ToDesk_Service": "ToDesk 服务",
                        "cloudphotod": "云端照片服务",
        "secd": "安全服务",
        "adid": "Apple 账户服务",
        "akd": "Apple 账户认证",
        "analyticsd": "分析服务",
        "PerfPowerServices": "性能功耗服务",
        "VivoSyncService": "vivo 同步服务",
    ]

    /// 进程 → 中文身份。
    ///
    /// - Parameter executable: 进程可执行文件全路径（ps comm），可为空
    /// - Returns: 面向用户的名字。**永不返回空**；认不出来就退回 basename 原文。
    public static func displayName(executable: String) -> String {
        let path = executable.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return "系统进程" }

        // ① 系统对照表优先：这些进程没 bundle 可读，且名字高度稳定
        let base = (path as NSString).lastPathComponent
        if let zh = systemGlossary[base] { return zh }

        // ①′ 裸名 helper（R82 续四）：无路径的 "X Helper (角色)" → 「X（中文角色）」
        if let helper = parseBareHelper(path) {
            let app = gloss(helper.app)
            return helper.role.map { "\(app)（\($0)）" } ?? app
        }

        // ② App/框架 bundle 的中文名（helper → 归属 App 的 Frameworks 容器）
        if let appBundle = appBundlePath(for: path) {
            if let zh = bundleDisplayName(appBundle) { return zh }
        }

        // ③ 兜底：可执行文件名（逆向 DNS 形态做可读化）。至少给的是"它自己"，不是装置名
        return readableFallback(base)
    }

    /// 给「占用」页用的完整身份：软件名 + 它是这个软件的哪个部分（可选）。
    ///
    /// 例：
    ///   /Applications/抖音.app/Contents/Frameworks/抖音 Helper (Renderer).app/Contents/MacOS/抖音 Helper (Renderer)
    ///     → ("抖音", "渲染进程")
    ///   /usr/sbin/coreaudiod → ("音频服务", nil)
    public static func detail(executable: String) -> (app: String, role: String?) {
        let path = executable.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return ("系统进程", nil) }

        let base = (path as NSString).lastPathComponent
        if let zh = systemGlossary[base] { return (zh, nil) }

        // 裸名 helper（R82 续四）：ps 的 comm 对 Electron 系 helper 常只给裸名
        // （"抖音 Helper (Renderer)"），没有路径做不了 bundle 归属 → 按 Chromium 惯例拆开
        if let helper = parseBareHelper(path) { return (gloss(helper.app), helper.role) }

        if let appBundle = appBundlePath(for: path) {
            let name = bundleDisplayName(appBundle) ?? appNameFromBundlePath(appBundle)
            let role = roleOf(base, bundleName: appBundle)
            return (name, role)
        }
        return (readableFallback(base), nil)
    }

    // MARK: - 私有

    /// 认不出时的兜底命名。逆向 DNS 形态（`com.apple.*` 等）此前会被
    /// `deletingPathExtension` 砍成 `com.apple.Safari` 这种残名——改为可读化：
    /// 注明"Apple 系统组件"、括号里保留去掉前缀的原文（可拿去检索，不编造中文名）。
    /// 其余照旧：去扩展名给"它自己"。
    private static func readableFallback(_ base: String) -> String {
        if base.hasPrefix("com.apple.") {
            return "Apple 系统组件（" + base.dropFirst("com.apple.".count) + "）"
        }
        let stripped = (base as NSString).deletingPathExtension
        return stripped.isEmpty ? base : stripped
    }

    /// 这个可执行文件属于哪个 App bundle。
    ///
    /// macOS 的 App 布局惯例（本函数只认这两种确实成立的形态）：
    ///   A. `X.app/Contents/MacOS/<exe>`                        → X.app（主程序）
    ///   B. `X.app/Contents/Frameworks/Y Helper.app/Contents/MacOS/<exe>` → X.app
    ///      —— Electron/Chromium 系（抖音、Hermes、DeepSeek Harness）的真实形态：
    ///        干活的是 Frameworks 里的 helper，但用户认的是**外层那个 App**。
    /// 其余（/usr/bin、各类工具链）返回 nil，由对照表/原名兜底。
    private static func appBundlePath(for exe: String) -> String? {
        guard exe.hasPrefix("/") else { return nil }
        let c = exe.components(separatedBy: "/")
        // 形态 B：X.app/Contents/Frameworks/<Helper>.app/Contents/MacOS/<exe>
        //   注意：外层 X.app 在 Frameworks 之前（Contents 的父目录），不是前一个元素。
        //   初版拼出过 /Applications/抖音.app/Contents/抖音 Helper (Renderer).app
        //   这种不存在的路径 -> 读 plist 失败 -> 静默退回英文名。故往前找最近的 .app 段。
        if let fw = c.firstIndex(of: "Frameworks"),
           fw >= 1, fw + 1 < c.count,
           c[fw + 1].hasSuffix(".app") {
            var i = fw - 1
            while i >= 1, !c[i].hasSuffix(".app") { i -= 1 }
            if i >= 1 { return c[0...i].joined(separator: "/") }
            return nil
        }
        // 形态 A：Contents/MacOS/<exe>
        if let macos = c.firstIndex(of: "Contents"),
           macos >= 1, macos + 2 < c.count,
           c[macos + 1] == "MacOS",
           c[macos - 1].hasSuffix(".app") {
            return c[0...macos - 1].joined(separator: "/")
        }
        return nil
    }

    /// bundle 的中文显示名，官方中文优先：
    /// ① `Resources/zh_CN.lproj(或 zh-Hans.lproj)/InfoPlist.strings` 的 CFBundleDisplayName/CFBundleName
    ///    —— Apple 系 App 的主 Info.plist 写的是英文名，中文名只存在于本地化表
    ///    （实测 Safari 的 zh_CN 表即 "Safari浏览器"；TextEdit/Terminal 无此文件 → ③兜底）；
    /// ② Info.plist 的 CFBundleDisplayName / CFBundleName（国产 App 多直接写中文）；
    /// ③ bundle 文件名去 .app。
    /// 每一步结果都会再过一遍 systemGlossary（gloss()）：exe 裸名与 bundle 名常常不一致
    /// （如 Microsoft Defender Shim 的 exe 叫 launcher），不后处理就会漏翻（R82 续二实测）。
    /// 读 plist 失败任一环都继续往下试，绝不抛。
    private static func bundleDisplayName(_ bundlePath: String) -> String? {
        if let zh = localizedBundleName(bundlePath) { return gloss(zh) }
        let plist = bundlePath + "/Contents/Info.plist"
        guard let d = NSDictionary(contentsOfFile: plist) else {
            return appNameFromBundlePathOptional(bundlePath).map(gloss)
        }
        if let s = d["CFBundleDisplayName"] as? String, !s.isEmpty { return gloss(s) }
        if let s = d["CFBundleName"] as? String, !s.isEmpty { return gloss(s) }
        return appNameFromBundlePathOptional(bundlePath).map(gloss)
    }

    /// 词表后处理：已解析出的名字若恰好命中对照表（键是 exe 名或 bundle 名），翻成中文
    private static func gloss(_ s: String) -> String { systemGlossary[s] ?? s }

    /// 裸名 helper 解析（R82 续四，实测驱动）：ps 的 comm 对 Electron/Chromium 系 helper
    /// 常只给裸名（"抖音 Helper (Renderer)"、"ZCode Helper (GPU)"）——没有路径就做不了
    /// bundle 归属，此前原样透出，"Helper (Renderer)" 英文残留直接进界面。
    /// 按构件命名惯例拆开："X Helper" / "X Helper (角色)" → (软件 X, 中文角色词)，
    /// X 再过一遍词表（gloss）。只认无路径的裸名——有路径的走 bundle 归属那条路。
    private static func parseBareHelper(_ bareName: String) -> (app: String, role: String?)? {
        guard !bareName.hasPrefix("/"), let range = bareName.range(of: " Helper") else { return nil }
        let app = String(bareName[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty else { return nil }
        return (app, roleOf(bareName, bundleName: ""))
    }

    /// 从 App 内部的简体中文本地化表读显示名；两处常见布局（zh_CN / zh-Hans）各试一次。
    /// .strings 是旧式 plist，PropertyListSerialization 可读（XML/二进制/OpenStep 均可）。
    private static func localizedBundleName(_ bundlePath: String) -> String? {
        for lp in ["zh_CN.lproj", "zh-Hans.lproj"] {
            let f = bundlePath + "/Contents/Resources/" + lp + "/InfoPlist.strings"
            guard let data = FileManager.default.contents(atPath: f),
                  let p = try? PropertyListSerialization.propertyList(from: data, format: nil)
                      as? [String: String] else { continue }
            if let s = p["CFBundleDisplayName"], !s.isEmpty { return s }
            if let s = p["CFBundleName"], !s.isEmpty { return s }
        }
        return nil
    }

    private static func appNameFromBundlePathOptional(_ bundlePath: String) -> String? {
        let base = (bundlePath as NSString).lastPathComponent
        guard base.hasSuffix(".app") else { return nil }
        return String(base.dropLast(4))
    }

    private static func appNameFromBundlePath(_ bundlePath: String) -> String {
        appNameFromBundlePathOptional(bundlePath) ?? (bundlePath as NSString).lastPathComponent
    }

    /// helper 进程的角色词。Chromium/Electron 的构件名是英文且对用户无意义，
    /// 翻成"它在干嘛"的一部分：渲染进程、GPU 进程、网络服务……
    /// 认不出返回 nil（拼行时省掉，不要塞一个"未知部件"制造噪音）。
    private static func roleOf(_ exeBase: String, bundleName: String) -> String? {
        let src = (exeBase + " " + bundleName).lowercased()
        let table: [(String, String)] = [
            ("helper (renderer)", "渲染进程"),
            ("helper (gpu)", "图形进程"),
            ("helper (gpu-process)", "图形进程"),
            ("helper (utility)", "工具进程"),
            ("plugin", "插件进程"),
            ("network", "网络进程"),
            ("crashpad", "崩溃上报进程"),
            ("crash handler", "崩溃处理进程"),
            ("helper", "辅助进程"),
        ]
        for (k, v) in table where src.contains(k) { return v }
        return nil
    }
}
