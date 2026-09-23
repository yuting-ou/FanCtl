// TestsUpgrade — 一键升级纯逻辑（SMCCore.SelfUpgrade）回归（v3.9.0）
// 副作用层（SelfUpgradeService/upgrade.sh）不可纯逻辑断言，由真机 dogfood 覆盖；
// 本文件锁：tag 消毒（注入面收窄）、资产 URL 契约、暂存包校验门全路径、授权文案。

import Foundation
import SMCCore

func testSelfUpgrade() {
    group("一键升级·tag 消毒")
    // 合法形态
    expectEqual(SelfUpgrade.sanitizeTag("3.9.0"), "3.9.0", "纯数字三段")
    expectEqual(SelfUpgrade.sanitizeTag("v3.9.0"), "3.9.0", "v 前缀剥除")
    expectEqual(SelfUpgrade.sanitizeTag("V3.9.0"), "3.9.0", "大写 V 前缀剥除")
    expectEqual(SelfUpgrade.sanitizeTag("3.9"), "3.9", "两段")
    expectEqual(SelfUpgrade.sanitizeTag("4.0.0.1"), "4.0.0.1", "四段封顶内")
    expectEqual(SelfUpgrade.sanitizeTag(" 3.9.0\n"), "3.9.0", "首尾空白容忍")
    expectEqual(SelfUpgrade.sanitizeTag("0.0.1"), "0.0.1", "全零段合法")

    // 注入面/垃圾（全部必须 nil——这些串可能进 URL 与 shell 两处）
    expect(SelfUpgrade.sanitizeTag("") == nil, "空串拒绝")
    expect(SelfUpgrade.sanitizeTag("   ") == nil, "纯空白拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.0; rm -rf /") == nil, "命令注入拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.0 && curl evil") == nil, "命令拼接拒绝")
    expect(SelfUpgrade.sanitizeTag("../../../etc") == nil, "路径穿越拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.0/..") == nil, "路径段拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.0 beta") == nil, "空格后缀拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.0-rc1") == nil, "连字符后缀拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.0+build") == nil, "加号后缀拒绝")
    expect(SelfUpgrade.sanitizeTag("3..9") == nil, "空段拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.") == nil, "尾点空段拒绝")
    expect(SelfUpgrade.sanitizeTag("abc") == nil, "非数字段拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.0.1.2") == nil, "五段超限拒绝")
    expect(SelfUpgrade.sanitizeTag(String(repeating: "1", count: 25) + ".0") == nil, "超长拒绝")
    expect(SelfUpgrade.sanitizeTag("3.9.0\n; echo pwned") == nil, "换行注入拒绝")
    expect(SelfUpgrade.sanitizeTag("٣.٩") == nil, "非 ASCII 数字拒绝")
    // R10 审查补强：前缀/边界/前导零
    expect(SelfUpgrade.sanitizeTag("v") == nil, "裸 v 前缀拒绝")
    expect(SelfUpgrade.sanitizeTag("vv3.9") == nil, "双 v 前缀拒绝（剥一层后非数字）")
    expect(SelfUpgrade.sanitizeTag("0") == "0", "单 0 合法（版本 0）")
    expect(SelfUpgrade.sanitizeTag("00.1") == "00.1", "前导零放行（URL 安全，无需归一）")
    expect(SelfUpgrade.sanitizeTag(String(repeating: "1", count: 24)) == String(repeating: "1", count: 24),
           "24 字符边界放行")
    expect(SelfUpgrade.sanitizeTag(String(repeating: "1", count: 25)) == nil, "25 字符边界拒绝")
    expect(SelfUpgrade.sanitizeTag("３.９") == nil, "全角数字拒绝")

    group("一键升级·资产 URL 契约")
    // 契约 = ci.yml release job：FanCtl-v{X.Y.Z}.zip（实测 v3.7.0 资产名核对）
    expectEqual(SelfUpgrade.assetURL(forTag: "v3.9.0")?.absoluteString,
                "https://github.com/yuting-ou/FanCtl/releases/download/v3.9.0/FanCtl-v3.9.0.zip",
                "URL 与 Release 资产命名严格一致")
    expectEqual(SelfUpgrade.assetURL(forTag: "3.9.0")?.absoluteString,
                "https://github.com/yuting-ou/FanCtl/releases/download/v3.9.0/FanCtl-v3.9.0.zip",
                "无 v 前缀归一后同 URL")
    expect(SelfUpgrade.assetURL(forTag: "3.9; rm -rf /") == nil, "注入 tag 不得产生 URL")
    expect(SelfUpgrade.assetURL(forTag: "") == nil, "空 tag 不得产生 URL")
    expect(SelfUpgrade.assetURL(forTag: "3.9.0")?.scheme == "https", "强制 HTTPS")
    expect(SelfUpgrade.assetURL(forTag: "3.9.0")?.host == "github.com", "host 锁定 github.com（R10）")

    group("一键升级·暂存包校验门")
    func plistData(version: String?, build: String = "58") -> Data {
        var dict: [String: Any] = [:]
        if let v = version {
            dict["CFBundleShortVersionString"] = v
            dict["CFBundleVersion"] = build
        }
        // R8 规矩：测试禁 try!。字典→XML 序列化对 [String:Any] 理论不失败，
        // 但按纪律显式处理失败路径（失败=测试 harness 缺陷，走断言而非 trap）
        do {
            return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        } catch {
            expect(false, "plistData 构造失败（harness 缺陷）: \(error)")
            return Data()
        }
    }
    // 批次 A：特权脚本正文必须在弹窗前就验在场（缺则这次升级刷新不了 root 侧链路）
    expect(SelfUpgrade.stagedMissingPrivilegedScripts(hasUpgradeScript: true,
                                                      hasUninstallScript: true) == nil,
           "两份特权脚本俱在 → 放行")
    expect(SelfUpgrade.stagedMissingPrivilegedScripts(hasUpgradeScript: false,
                                                      hasUninstallScript: true)
           == .missingPrivilegedScripts, "缺 upgrade.sh → 弹窗前拒")
    expect(SelfUpgrade.stagedMissingPrivilegedScripts(hasUpgradeScript: true,
                                                      hasUninstallScript: false)
           == .missingPrivilegedScripts, "缺 uninstall.sh → 弹窗前拒")
    expect(SelfUpgrade.validateStaged(appInfoPlistData: nil, hasDaemonBinary: true,
                                      tag: "v3.9.0") == .missingApp, "缺 App 拒绝")
    expect(SelfUpgrade.validateStaged(appInfoPlistData: plistData(version: "3.9.0"),
                                      hasDaemonBinary: false,
                                      tag: "v3.9.0") == .missingDaemon, "缺 fanctld 拒绝")
    expect(SelfUpgrade.validateStaged(appInfoPlistData: Data("garbage".utf8),
                                      hasDaemonBinary: true,
                                      tag: "v3.9.0") == .unreadablePlist, "plist 垃圾拒绝")
    expect(SelfUpgrade.validateStaged(appInfoPlistData: plistData(version: "3.8.0"),
                                      hasDaemonBinary: true,
                                      tag: "v3.9.0") == .versionMismatch, "版本不符拒绝")
    expect(SelfUpgrade.validateStaged(appInfoPlistData: plistData(version: "4.0.0"),
                                      hasDaemonBinary: true,
                                      tag: "v3.9.0") == .versionMismatch, "更新版本也拒绝（严格相等）")
    expect(SelfUpgrade.validateStaged(appInfoPlistData: plistData(version: "3.9.0-beta"),
                                      hasDaemonBinary: true,
                                      tag: "v3.9.0") == .versionMismatch, "带后缀版本拒绝")
    expect(SelfUpgrade.validateStaged(appInfoPlistData: plistData(version: nil),
                                      hasDaemonBinary: true,
                                      tag: "v3.9.0") == .unreadablePlist, "plist 缺版本键拒绝")
    expect(SelfUpgrade.validateStaged(appInfoPlistData: plistData(version: "3.9.0"),
                                      hasDaemonBinary: true,
                                      tag: "v3.9.0") == nil, "版本相等+二进制在场放行")
    // tag 形态带 v 前缀时校验用归一形态（plist 里永远是无 v 的纯版本）
    expect(SelfUpgrade.validateStaged(appInfoPlistData: plistData(version: "3.9"),
                                      hasDaemonBinary: true,
                                      tag: "v3.9") == nil, "v 前缀 tag 归一后放行")

    group("一键升级·授权文案")
    let prompt = SelfUpgrade.authorizationPrompt(tag: "v3.9.0")
    expect(prompt.contains("3.9.0"), "授权文案含版本号")
    expect(prompt.contains("管理员"), "授权文案说明需要管理员")
    expect(!prompt.contains(";") && !prompt.contains("`"), "授权文案不含 shell 元字符")
    // R10 审查：原断言 `!a || !b` 是弱断言（两者同现才失败）；非法 tag 必须
    // 走固定兜底词，精确锁定完整文案
    let injected = SelfUpgrade.authorizationPrompt(tag: "3.9.0\" , do shell script \"pwned")
    expectEqual(injected, SelfUpgrade.authorizationPrompt(tag: "垃圾tag"),
                "非法 tag 落到同一固定兜底文案")
    expectEqual(injected, "清风升级到 v新版本：需要管理员授权替换系统守护进程与菜单栏 App",
                "兜底文案精确匹配（含 v 新版本 拼接形态）")

    // R23（P1）：暂存二进制 sha256 助手——root 侧复核的数据源，必须与系统 shasum 一致。
    group("一键升级·暂存哈希")
    do {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanctl-sha-\(UUID().uuidString)")
        try? Data("abc".utf8).write(to: f)
        expectEqual(SelfUpgrade.sha256Hex(of: f),
                    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                    "sha256(\"abc\") 命中已知向量")
        try? FileManager.default.removeItem(at: f)
        expect(SelfUpgrade.sha256Hex(of: f) == nil, "文件不可读 → nil（跳过门，与旧行为一致）")
    }
}


// MARK: - R11 模糊/性质测试（v3.6.3 方法论首次覆盖升级模块）
// 静态审查写得出 16+ 对抗样本，但组合空间是无限的——用确定性 LCG 随机串扫
// sanitizeTag/assetURL/authorizationPrompt 的四条全局性质，锁定"任何输入下"的行为。

/// 批次 A（4.2.0）：root 执行脚本落点的可信判据——App 侧 exec 前的唯一闸门，
/// 判错方向就是"把提权面当可信放行"，故每一支都要有牙。
func testPrivilegedScriptTrust() {
    group("特权脚本信任判据(R36)")
    func ok(_ reg: Bool, _ link: Bool, _ uid: Int, _ mode: Int) -> Bool {
        SelfUpgrade.privilegedScriptTrusted(isRegularFile: reg, isSymlink: link,
                                            ownerUID: uid, modeBits: mode)
    }
    // 正例：root 拥有、755/750/700（组与其他无写位）
    expect(ok(true, false, 0, 0o755), "root:wheel 755 常规文件 → 可信")
    expect(ok(true, false, 0, 0o750), "750 → 可信")
    expect(ok(true, false, 0, 0o700), "700 → 可信")
    // 拒绝面：任一条件不满足都必须拒
    expect(!ok(true, false, 501, 0o755), "非 root 属主（登录用户）→ 拒")
    expect(!ok(true, false, 0, 0o775), "组可写 → 拒（admin 组内进程可换正文）")
    expect(!ok(true, false, 0, 0o764), "组有写位的其他形态 → 拒")
    expect(!ok(true, false, 0, 0o757), "其他可写 → 拒")
    expect(!ok(true, true, 0, 0o755), "符号链接 → 拒（哪怕属主是 root）")
    expect(!ok(false, false, 0, 0o755), "非常规文件（目录/fifo）→ 拒")
    // 参数顺序 = App↔upgrade.sh 的跨语言契约；写错一位就是"哈希永远对不上"的静默升级失败
    expectEqual(SelfUpgrade.upgradeArguments(stage: "S", marker: "M", tag: "4.2.0",
                                             shaDaemon: "d", shaAppBinary: "a",
                                             shaUpgradeScript: "u", shaUninstallScript: "n"),
                ["S", "M", "4.2.0", "d", "a", "u", "n"],
                "升级参数 7 元顺序（与 upgrade.sh 的位置解析一致）")
    // 落点常量：文案与脚本侧的安装路径必须同字（漂移=App 校验了个不存在的路径）
    expectEqual(SelfUpgrade.privilegedUpgradeScript, "/usr/local/libexec/fanctl-upgrade.sh",
                "升级脚本落点常量")
    expectEqual(SelfUpgrade.privilegedUninstallScript, "/usr/local/libexec/fanctl-uninstall.sh",
                "卸载脚本落点常量")
    // 文案要同时穿过 AppleScript 双引号串与 sh 单引号串两层——两层元字符一起锁
    // （"$`\ 与换行任一在场都能闭合字符串再拼命令；中文正文本身无害）
    let hint = SelfUpgrade.privilegedScriptHint
    expect(!hint.contains(where: { $0 == "\"" || $0 == "\\" || $0 == "\n" || $0 == "\r"
                                  || $0 == "$" || $0 == "`" || $0 == "'" }),
           "迁移提示无 AppleScript/sh 双层元字符")
    // 进 shell 命令行的是路径常量本身（未加引号）：必须纯 ASCII 且无空白/shell 元字符
    let pathUnsafe: Set<Character> = ["\"", "\\", "'", "$", "`", ";", "&", "|", "|", " ", "\n", "\r"]
    expect(SelfUpgrade.privilegedUpgradeScript.allSatisfy { $0.isASCII }
           && !SelfUpgrade.privilegedUpgradeScript.contains(where: { pathUnsafe.contains($0) }),
           "升级脚本路径常量对 AppleScript/sh 两层都安全")
}

func testSelfUpgradeFuzz() {
    group("一键升级·模糊性质（500 轮 × 确定性种子）")
    // 字母表刻意混入：shell 元字符、路径段、Unicode 数字、空白、引号、合法字符
    let alphabet = Array("0123456789.vV;`$&|><\\\n\r\t '/\"(){}٣٣３abc-+_~*?!#")
    func randomString(_ rng: inout FuzzRNG) -> String {
        let len = rng.pick(31)
        return String((0..<len).map { _ in alphabet[rng.pick(alphabet.count)] })
    }
    var violations: [String] = []
    var accepted = 0
    for round in 0..<500 {
        var rng = FuzzRNG(0x5E1F &+ UInt64(round) &* 0x1000193)
        let s = randomString(&rng)
        let tag = SelfUpgrade.sanitizeTag(s)
        // P1: 输出白名单——nil 或 纯 [0-9.] 且 ≤24 字符且 ≤4 个非空段
        if let t = tag {
            accepted += 1
            if t.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.").inverted) != nil {
                violations.append("r\(round): 输出含白名单外字符 \(t.debugDescription)")
            }
            if t.count > 24 { violations.append("r\(round): 输出超长 \(t.count)") }
            let segs = t.split(separator: ".", omittingEmptySubsequences: false)
            if !(1...4).contains(segs.count) || segs.contains(where: { $0.isEmpty }) {
                violations.append("r\(round): 输出段结构非法 \(t.debugDescription)")
            }
        }
        // P2: URL 契约——非 nil 必为固定 host/https 的资产模式
        if let url = SelfUpgrade.assetURL(forTag: s) {
            if url.scheme != "https" { violations.append("r\(round): scheme \(url.scheme ?? "?")") }
            if url.host != "github.com" { violations.append("r\(round): host \(url.host ?? "?")") }
            if !url.path.hasPrefix("/yuting-ou/FanCtl/releases/download/") {
                violations.append("r\(round): path 漂移 \(url.path)")
            }
        }
        // P3: 授权文案任意输入下无 shell/AppleScript 元字符
        // （rangeOfCharacter 不加 inverted：语义=找到集合内字符；inverted 会变成
        //  "含任何其他字符"，中文文案必然命中——首轮运行被自家 fuzz 当场抓住）
        let prompt = SelfUpgrade.authorizationPrompt(tag: s)
        if prompt.rangeOfCharacter(from: CharacterSet(charactersIn: ";`\"\\")) != nil {
            violations.append("r\(round): 文案含元字符（输入 \(s.debugDescription)）")
        }
        // P4: 幂等性（蜕变性质）——sanitize(sanitize(x)) == sanitize(x)
        if let t1 = tag, let t2 = SelfUpgrade.sanitizeTag(t1), t1 != t2 {
            violations.append("r\(round): 非幂等 \(t1) → \(t2)")
        }
    }
    // 采样健康度：合法串概率低但必须非零（否则接受路径在本轮完全没被测到）
    expect(accepted > 0, "500 轮应有合法串命中（采样健康度）")
    expect(violations.isEmpty, "模糊性质违例: \(violations.prefix(5))")
}

// R24 脚本基建债收口：root 脚本门禁此前零回归（P1-A 全绿仍漏 v 前缀）。
// 以 Process 调 scripts/test-root-scripts.sh（无 root、gates-only 钩子），
// 把 upgrade.sh 的 tag/sha/marker 门与 install.sh 的 config 符号链接谓词锁进同一 CI 门。
func testRootScriptGates() {
    group("root 脚本门禁")
    let here = URL(fileURLWithPath: #filePath)
    // Sources/fanctltests/TestsUpgrade.swift → 仓库根
    let root = here
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = root.appendingPathComponent("scripts/test-root-scripts.sh")
    expect(FileManager.default.isExecutableFile(atPath: script.path)
           || FileManager.default.fileExists(atPath: script.path),
           "test-root-scripts.sh 在场：\(script.path)")
    guard FileManager.default.fileExists(atPath: script.path) else { return }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [script.path]
    proc.currentDirectoryURL = root
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = out
    do {
        try proc.run()
    } catch {
        expect(false, "无法启动 test-root-scripts.sh: \(error)")
        return
    }
    proc.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    expect(proc.terminationStatus == 0,
           "root 脚本门禁全绿（exit \(proc.terminationStatus)）\n\(text.suffix(800))")
    // 解析 "root 脚本门禁：N 通过 / M 失败" —— 禁止 0 通过的空跑假绿
    if let line = text.split(separator: "\n").last(where: { $0.contains("通过") && $0.contains("失败") }) {
        let nums = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if nums.count >= 2 {
            expect(nums[0] >= 15, "门禁用例数 ≥15（got \(nums[0])）——防脚本被掏空")
            expect(nums[1] == 0, "失败数必须为 0（got \(nums[1])）")
        } else {
            expect(false, "无法解析门禁计数行: \(line)")
        }
    } else {
        expect(false, "输出缺少「通过/失败」汇总行")
    }
}

