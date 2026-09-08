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
}


// MARK: - R11 模糊/性质测试（v3.6.3 方法论首次覆盖升级模块）
// 静态审查写得出 16+ 对抗样本，但组合空间是无限的——用确定性 LCG 随机串扫
// sanitizeTag/assetURL/authorizationPrompt 的四条全局性质，锁定"任何输入下"的行为。

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

