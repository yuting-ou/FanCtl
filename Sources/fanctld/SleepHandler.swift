import Foundation
import IOKit
import IOKit.pwr_mgt
import SMCCore

// MARK: - 睡眠/唤醒安全交接（IOKit 注册与系统消息分发）
//
// 系统入睡时无条件交还风扇控制权给 macOS，唤醒后重新接管。
// 异常唤醒（无前置 WILL_SLEEP）时同样清理 SMC 强制模式残留。
// 实际的交接逻辑（交还/落盘/状态重置/重扫）在 ControlEngine.enterSleep/wake，
// 本文件只负责 IOKit 注册与消息分发。

let MSG_SYSTEM_WILL_SLEEP: UInt32 = 0xE0000280
let MSG_CAN_SYSTEM_SLEEP: UInt32 = 0xE0000270
let MSG_SYSTEM_HAS_POWERED_ON: UInt32 = 0xE0000300

func makeSleepCallback() -> IOServiceInterestCallback {
    return { _, _, messageType, messageArgument in
        switch messageType {
        case MSG_SYSTEM_WILL_SLEEP:
            engine.enterSleep()
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: messageArgument))
        case MSG_CAN_SYSTEM_SLEEP:
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: messageArgument))
        case MSG_SYSTEM_HAS_POWERED_ON:
            engine.wake()
        default:
            break
        }
    }
}


// MARK: - 熄屏判定（R82 续十一：夜间自添火治理）
//
// powerd 在屏幕亮着时持有 "Prevent sleep while display is on" 断言；该断言消失 =
// 熄屏（或合盖）。系统醒着但熄屏（远程工具阻止休眠/挂机）时，我们的分项功耗
// 采样（powermetrics，采样瞬间 ~85% 单核）纯属夜间添火 → 采样间隔拉到 60s 地板。
// 读不到断言时按亮屏处理（宁多采样不少采样，行为保守）。
func isDisplayAsleep() -> Bool {
    var unmanaged: Unmanaged<CFDictionary>? = nil
    guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
          let dict = unmanaged?.takeRetainedValue() as? [AnyHashable: Any] else {
        return false
    }
    for (_, value) in dict {
        guard let arr = value as? [[String: Any]] else { continue }
        for d in arr where (d["AssertType"] as? String ?? "").contains("Prevent") {
            if (d["AssertName"] as? String ?? "").contains("display is on") {
                return false   // powerd 的亮屏断言在场 = 屏幕亮着
            }
        }
    }
    return true
}

func registerSleepNotification() {
    rootPowerPort = IORegisterForSystemPower(nil, &powerNotifyPort, makeSleepCallback(), &powerNotifier)
    if rootPowerPort != 0, let port = powerNotifyPort {
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
    } else {
        // 注册失败时 WILL_SLEEP 的"入睡交还"不可用（退出/SIGTERM 路径仍会恢复）。
        // 看门狗心跳用单调时钟（睡眠期冻结），不会在唤醒时误判挂死而重启；
        // 睡眠残留的强制模式由下次启动的清理逻辑兜底。
        log("警告：睡眠通知注册失败，入睡/唤醒交接不可用")
    }
}
