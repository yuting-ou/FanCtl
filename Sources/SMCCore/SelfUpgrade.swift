// SelfUpgrade — App 一键升级的纯决策逻辑（v3.9.0，daemon 不用）
//
// v3.9（升级自动化）：v3.6 的版本自检只"看见"新版本（打开下载页），
// 本模块把它推进到"拿到并装上"。分工：
//   - 本文件：纯逻辑——下载 URL 构造（含 tag 消毒防注入）、暂存包校验门。可单测。
//   - /usr/local/libexec/fanctl-upgrade.sh（root:wheel 755）：唯一的特权安装过程，
//     由 install.sh 首装、每次升级自我刷新；App 只 exec，不携带也不内嵌其正文。
//   - FanCtlApp.SelfUpgradeService：副作用编排——下载 zip → 解压 → 调本模块校验
//     → lstat 校验 root 脚本落点 → osascript 管理员授权执行该脚本 → 脚本负责杀旧
//     App/装 daemon/刷新自身/重启新 App。
//
// 安全门（缺一不可）：
//   1. 下载只走固定 HTTPS 模式（github.com/yuting-ou/FanCtl/releases/download/…），
//      tag 必须通过 sanitizeTag（数字+点），杜绝路径/命令注入进 URL 与 shell。
//   2. root 执行的代码只住在 root 拥有、组不可写的路径（批次 A / 4.2.0）。
//      此前两版都在让用户可写的东西替 root 决定行为：v3.9 读 bundle 内脚本，
//      R23 把正文内嵌进 App 二进制——而二进制本身也在被 chown 给登录用户的
//      bundle 里，换掉 App 就换掉了"被授权执行的内容"。现落点固定为
//      /usr/local/libexec/fanctl-upgrade.sh，exec 前由 privilegedScriptTrusted 把关。
//   3. 暂存包校验门：解压出的 FanCtl.app 的 Info.plist 版本必须与 Release tag 严格
//      相等、fanctld 二进制必须存在——防止误装残缺包或错版本包。
//   4. root 侧复核（R23，闭合授权后 TOCTOU）：App 在弹窗前算好暂存 daemon/App 二进制
//      的 sha256 随授权命令传入，upgrade.sh 在动系统文件之前重算比对；版本/哈希任一
//      不符即 exit 3，原运行环境零扰动。校验与安装同在 root 时间线，"确认后偷换"
//      只剩脚本自身执行的毫秒窗口。

import Foundation
import CryptoKit

public enum SelfUpgrade {

    /// root 执行脚本的规范落点（install.sh 装、upgrade.sh 每次升级自我刷新）
    public static let privilegedUpgradeScript = "/usr/local/libexec/fanctl-upgrade.sh"
    public static let privilegedUninstallScript = "/usr/local/libexec/fanctl-uninstall.sh"

    /// 落点缺失/不合规时的用户文案（批次 A 是一次性迁移：旧 App 没有装 root 脚本的
    /// 逻辑，所以从 4.2.0 起必须先手动装一次；此后升级链自愈）。
    /// 固定 ASCII 文案——它会进 AppleScript 字符串字面量，不得含用户可控内容。
    public static let privilegedScriptHint =
        "升级链路未就绪：未找到受信的升级脚本，请以管理员身份重新安装清风一次"

    /// root 执行脚本的可信判据（纯函数，测试可锁定）：必须是常规文件（非符号链接、
    /// 非目录）、属主 uid 0、且组/其他没有写位。守的是"我要 exec 的那个文件本身"；
    /// 目录面的信任（/usr/local 与 libexec 是否用户可写）由脚本侧 fanctl_dir_trusted 守。
    /// 不合规即拒绝提权——**绝不回退到 bundle 内副本或内嵌正文**（那是被本批次关掉的通道）。
    public static func privilegedScriptTrusted(isRegularFile: Bool, isSymlink: Bool,
                                               ownerUID: Int, modeBits: Int) -> Bool {
        guard !isSymlink, isRegularFile else { return false }
        guard ownerUID == 0 else { return false }
        return modeBits & 0o022 == 0
    }

    public enum StagedError: String, Equatable {
        case missingApp = "暂存包缺 FanCtl.app"
        case unreadablePlist = "暂存包 Info.plist 不可读"
        case missingDaemon = "暂存包缺 fanctld 二进制"
        case versionMismatch = "暂存包版本与 Release tag 不符"
        case missingPrivilegedScripts = "暂存包缺特权脚本（upgrade.sh / uninstall.sh）"
    }

    /// 批次 A 追加的门（授权弹窗**之前**判，不是 root 侧事后拒）：暂存包必须自带两份
    /// root 执行脚本正文。缺任一份即意味这次升级无法刷新 root 侧链路——若等用户输完
    /// 密码才被 upgrade.sh 的 exit 2 拒掉，代价是"打了密码还留下半迁移状态"。
    /// 与 validateStaged 分两个函数而非塞进同一个：前者的输入是 plist 数据，后者只是
    /// 存在性判断，合并会让调用方为了喂参数去做无谓的读取。
    public static func stagedMissingPrivilegedScripts(hasUpgradeScript: Bool,
                                                      hasUninstallScript: Bool) -> StagedError? {
        guard hasUpgradeScript, hasUninstallScript else { return .missingPrivilegedScripts }
        return nil
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

    /// 授权脚本的参数顺序（App ↔ upgrade.sh 的跨语言契约，两侧共用一份定义）。
    /// 7 项全必填：upgrade.sh 侧 fail-closed，少任一项即 exit 3 拒绝动手。
    /// 两份**脚本正文**的哈希与两份二进制同等待遇：批次 A 后它们会被 root 装成
    /// "将被 root 执行的代码"，不复核就等于把注入口留在一个无摘要、路径公开的目录。
    public static func upgradeArguments(stage: String, marker: String, tag: String,
                                        shaDaemon: String, shaAppBinary: String,
                                        shaUpgradeScript: String,
                                        shaUninstallScript: String) -> [String] {
        [stage, marker, tag, shaDaemon, shaAppBinary, shaUpgradeScript, shaUninstallScript]
    }

    /// 暂存二进制文件的 sha256 十六进制（R23：授权命令携带，upgrade.sh root 侧复核）。
    /// 文件不可读返回 nil。R23 审查（P3-4）：调用方 SelfUpgradeService 已改为 fail-CLOSED
    /// ——nil 即拒绝升级、不弹窗（"读不到=无法校验完整性=不装"）。**新调用方切勿把 nil
    /// 当"跳过该门"传空串给脚本**（脚本 `-n` 判空会静默跳门，正是被堵死的旁路）。
    public static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
