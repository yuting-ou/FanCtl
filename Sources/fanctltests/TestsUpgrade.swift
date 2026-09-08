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

    group("一键升级·暂存包校验门")
    func plistData(version: String?, build: String = "58") -> Data {
        var dict: [String: Any] = [:]
        if let v = version {
            dict["CFBundleShortVersionString"] = v
            dict["CFBundleVersion"] = build
        }
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
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
    let injected = SelfUpgrade.authorizationPrompt(tag: "3.9.0\" , do shell script \"pwned")
    expect(!injected.contains("pwned") || !injected.contains("do shell"),
           "注入 tag 不原样进文案（消毒路径）")
}
