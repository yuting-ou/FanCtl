// MenuBarState —— 菜单栏标签的解耦量化状态（4.1.2，EVOLUTION R21）。
//
// 根因（2026-09-14 实机取证，进程 = 4.1.1(63)）：4.1.1 用原生视图替换 ImageRenderer
// 只移除了"翻转时 0.3s 离屏渲染"这一层；MenuBarExtra 的 label 仍观察整个 FanModel，
// 而 AI 控制态 status.json 约每 2s 一拍，refreshFromStatus 无条件赋值近 30 个
// @Published → objectWillChange 全对象失效 → 每拍 label 重算 + 关着的面板整树 body
// 重评（sample 证据：MenuBarExtraLayout.sizeThatFits 高频、CGDrawingLayer/RenderBox
// 全量光栅、Liquid Glass vImage 卷积，主线程 ~50%）。
// 本对象只在"显示内容真的变了"时发布。显示内容随 menuBarStyle 而不同（本机实测
// 长期为 icon——温度数字根本不在场，整数翻转更不该发布），所以去重按可见部分做。
// 观察规则：新 UI 若给菜单栏加显示要素，必须同时并入 Display 与本文件的可见性判据。
import Foundation
import Combine

final class MenuBarState: ObservableObject {
    struct Display: Equatable {
        var tempBucket: Int = -1   // -1 = 显示 "--"（无有效温度）
        var boostActive = false
        var quietActive = false
        var warnLevel = 0          // 0 无 | 1 橙 | 2 红（按显示整数值判级，与数字同源）
    }

    // 真值始终最新（样式切换瞬间视图重算即可读到正确显示），发布与否另判。
    private(set) var display = Display()

    // 主线程调用（与 FanModel 同一线程约定：status 事件/定时器均派发回主队列）
    func update(temp: Double, boost: Bool, quiet: Bool, style: String) {
        let bucket = temp > 1 ? Int(temp) : -1
        let old = display
        var next = Display(tempBucket: bucket, boostActive: boost, quietActive: quiet)
        next.warnLevel = bucket >= 88 ? 2 : (bucket >= 78 ? 1 : 0)
        let visibleChanged: Bool
        switch style {
        case "icon":   // 只有字形与警示色在场上
            visibleChanged = (next.boostActive, next.quietActive, next.warnLevel)
                != (old.boostActive, old.quietActive, old.warnLevel)
        case "temp":   // 温度数字 + 警示色（字形不显示）
            visibleChanged = (next.tempBucket, next.warnLevel) != (old.tempBucket, old.warnLevel)
        default:       // both
            visibleChanged = next != old
        }
        if visibleChanged { objectWillChange.send() }
        display = next
    }
}
