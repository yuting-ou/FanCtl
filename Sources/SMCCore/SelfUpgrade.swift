// SelfUpgrade — App 一键升级的纯决策逻辑（v3.9.0，daemon 不用）
//
// v3.9（升级自动化）：v3.6 的版本自检只"看见"新版本（打开下载页），
// 本模块把它推进到"拿到并装上"。分工：
//   - 本文件：纯逻辑——下载 URL 构造（含 tag 消毒防注入）、暂存包校验门。可单测。
//   - scripts/upgrade.sh（App Resources 内嵌）：唯一的特权安装过程，仓库作者物，
//     不从网上下载脚本（root 执行的代码必须与 App 同源）。
//   - FanCtlApp.SelfUpgradeService：副作用编排——下载 zip → 解压 → 调本模块校验
//     → osascript 管理员授权执行内嵌脚本 → 脚本负责杀旧 App/装 daemon/重启新 App。
//
// 安全门（缺一不可）：
//   1. 下载只走固定 HTTPS 模式（github.com/yuting-ou/FanCtl/releases/download/…），
//      tag 必须通过 sanitizeTag（数字+点），杜绝路径/命令注入进 URL 与 shell。
//   2. 特权脚本是 App bundle 内嵌资源，不是下载物——被授权执行的内容先于本次下载就存在。
//   3. 暂存包校验门：解压出的 FanCtl.app 的 Info.plist 版本必须与 Release tag 严格
//      相等、fanctld 二进制必须存在——防止误装残缺包或错版本包（root 替换系统文件前最后一道闸）。

import Foundation

public enum SelfUpgrade {

    public enum StagedError: String, Equatable {
        case missingApp = "暂存包缺 FanCtl.app"
        case unreadablePlist = "暂存包 Info.plist 不可读"
        case missingDaemon = "暂存包缺 fanctld 二进制"
        case versionMismatch = "暂存包版本与 Release tag 不符"
    }

    /// tag 消毒：只接受 "3.9" / "v3.9.0" 形态（去 v 前缀后全为数字+点，≤4 段，≤24 字符）。
    /// 其余（空、空白、路径段、命令字符、GitHub API 可能返回的任意后缀）一律 nil。
    /// URL 与 shell 两处都用它把关——这是注入面唯一的收窄点。
    public static func sanitizeTag(_ tag: String) -> String? {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        guard !t.isEmpty, t.count <= 24 else { return nil }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        // 只收 ASCII 数字：Character.isNumber 对阿拉伯-印度数字（٣ 等 Nd 类）也 true，
        // 会原样进 URL（百分号编码变形）——URL 段必须纯 [0-9.]
        for p in parts where p.isEmpty || !p.allSatisfy({ $0.isASCII && $0.isNumber }) { return nil }
        return t
    }

    /// Release 资产下载 URL（契约 = ci.yml release job：FanCtl-v{X.Y.Z}.zip）。
    /// 非法 tag 返回 nil，调用方按"下载失败"处理。
    public static func assetURL(forTag tag: String) -> URL? {
        guard let v = sanitizeTag(tag) else { return nil }
        return URL(string: "https://github.com/yuting-ou/FanCtl/releases/download/v\(v)/FanCtl-v\(v).zip")
    }

    /// 暂存包校验门（root 替换前的最后一道闸）。
    /// `appInfoPlistData` = 解压出的 FanCtl.app/Contents/Info.plist 原始数据（nil = 缺 App）；
    /// `hasDaemonBinary` = 暂存目录是否存在 fanctld 文件。
    /// 版本门是"严格相等"而非"更新"——装哪个版本由用户确认过的 Release tag 唯一决定，
    /// 暂存包里夹带别的版本（哪怕更新）也不放行。
    public static func validateStaged(appInfoPlistData: Data?, hasDaemonBinary: Bool,
                                      tag: String) -> StagedError? {
        guard let data = appInfoPlistData else { return .missingApp }
        guard hasDaemonBinary else { return .missingDaemon }
        guard let plist = (try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)) as? [String: Any],
              let staged = plist["CFBundleShortVersionString"] as? String
        else { return .unreadablePlist }
        guard staged == sanitizeTag(tag) else { return .versionMismatch }
        return nil
    }

    /// osascript 授权弹窗的 prompt 文案（放这里与 URL/校验同源，测试可锁定非空与含版本号）。
    /// 非法 tag 用固定兜底词——文案会嵌进 AppleScript 字符串字面量，原样透传非法 tag
    /// 等于把注入面从 URL 扩到 osascript（消毒必须在此收口，不能指望上游）。
    public static func authorizationPrompt(tag: String) -> String {
        let v = sanitizeTag(tag) ?? "新版本"
        return "清风升级到 v\(v)：需要管理员授权替换系统守护进程与菜单栏 App"
    }
}
