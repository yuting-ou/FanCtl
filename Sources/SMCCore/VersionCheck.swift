// VersionCheck — 版本语义比较（纯函数，daemon 不用、App 更新检查与测试共用）
//
// v3.6（方向一·进化传播链）：App 低频查询 GitHub Releases latest，与本地版本比较。
// 本文件只放纯比较逻辑；网络部分在 FanCtlApp.UpdateChecker（无第三方依赖，Foundation 自足）。

public enum VersionCheck {

    /// 解析版本字符串为数值段：v3.6.0 → [3,6,0]；"3.6" → [3,6,0]（缺段补 0）；
    /// 非数字/垃圾段按 0 计（防御外部输入，GitHub tag 可能带任意后缀）。
    static func segments(_ version: String) -> [Int] {
        var parts = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })   // 容忍 tag 的 v 前缀
            .split(separator: ".")
            .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        return parts
    }

    /// latest 是否比 current 更新（语义逐段比较，缺段补 0）。相等/倒退返回 false。
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let l = segments(latest)
        let c = segments(current)
        for i in 0..<3 {
            if l[i] != c[i] { return l[i] > c[i] }
        }
        return false
    }
}