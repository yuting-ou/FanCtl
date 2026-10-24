import Foundation

/// daemon 下线清态策略（R90 下沉）：**哪些字段清、哪些刻意不清**的单一真值。
///
/// 此前这份策略只活在 FanModel.clearDaemonState 的注释里（R86 把四份分叉的清态块
/// 收成一处，但"为什么清这 22 个、不清那 12 个"没有可执行的表达）。现在：
/// - `clearedProjectionFields`：StatusProjection（status.json 派生）里的**语义态**——
///   徽章/意图/故障/覆盖标记。daemon 不在跑，它们指向的状态就不存在，留着会画出
///   "夜间生效中 × 守护进程未运行"这类自相矛盾的面板。
/// - `clearedPanelFields`：非 status 投影、但同样随 daemon 生死的面板态
///   （部件行/经验值由 syncPanelData 独立回填；daemonMode/configMismatch 来自对账路径）。
/// - `keptReadingFields`：**读数**（温度/转速/功耗/硬件画像）。死态显示停更的最后读数
///   （面板降饱和半透明表达"数据停更"）是有意设计——清成 0 反而是在撒谎。
/// - `changed` 是投影元数据（温度桶是否变化），不参与清态。
///
/// 执行级测试用 Mirror 钉死三组字段的并集 == StatusProjection 的全部字段：
/// **新增投影字段必须在此分类**（清/留读数），不分类即红——策略不再只活在注释里。
public enum DaemonOfflinePolicy {

    public static let clearedProjectionFields: Set<String> = [
        "controlReason", "aiIntent", "controlFault", "faultReason",
        "targetUnreachable", "aiHighEffort", "curveTargetPercent", "currentLoopInterval",
        "learnMap", "decisionTrace", "learningRecently",
        "envTemp", "systemPower", "aiTargetEffective", "palmComp", "calibrating",
        "nightOverride", "batteryOverride",
    ]

    public static let clearedPanelFields: Set<String> = [
        "components", "learnedNow", "daemonMode", "configMismatch",
    ]

    public static let keptReadingFields: Set<String> = [
        "cpuTemp", "cpuAverageTemp", "gpuTemp", "ssdTemp", "palmRestTemp",
        "appliedPercent", "appliedPercents", "onBattery",
        "learnedSamples", "learnedPoints", "hardwareProfile", "fans",
    ]

    /// 清态全集 = 22（18 个投影语义态 + 4 个面板态）；FanModel.clearDaemonState
    /// 的函数体必须与这份清单一一对应（TestsCore 有接线门钉住）。
    public static var clearedFields: Set<String> {
        clearedProjectionFields.union(clearedPanelFields)
    }
}
