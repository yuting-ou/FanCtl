import Foundation
import SMCCore

/// 版本自检的决策策略：24h 节流、失败重试预算、是否提示新版本。
/// 网络请求与升级执行仍在 App 层；这里只保留可执行测试的纯判定。
public enum UpdateCheckPolicy {
    public static let successInterval: TimeInterval = 24 * 3600
    public static let retryInterval: TimeInterval = 600
    public static let retryTolerance: TimeInterval = 120
    public static let maxRetries = 3

    /// 在途永远阻断；force 只绕过 24h 成功窗口。
    public static func shouldCheck(now: Date, lastSuccess: Date?, force: Bool,
                                   inFlight: Bool,
                                   interval: TimeInterval = successInterval) -> Bool {
        if inFlight { return false }
        if force { return true }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= interval
    }

    /// 失败后下一次重试的延迟；返回 nil = 预算用完，不再挂 timer。
    public static func nextRetryDelay(afterFailure retry: Int) -> TimeInterval? {
        retry < maxRetries ? retryInterval : nil
    }

    /// 命中"比本地新且用户没跳过"才提示。
    public static func availableUpdate(fetchedTag: String?, localVersion: String,
                                       skippedTag: String?) -> String? {
        guard let tag = fetchedTag,
              VersionCheck.isNewer(tag, than: localVersion),
              skippedTag != tag else { return nil }
        return tag
    }
}
