// FanControlActions —— 模式切换/冲刺/静音状态机（从 FanModel 提取）
//
// 冲刺（boost）与静音（quiet）是一对偶功能，互斥且各有超时恢复。
// 所有方法通过 FanModel extension 保持在同一类型上，PanelView 无需改动。

import Foundation
import SMCCore

extension FanModel {

    // MARK: - 冲刺模式

    func startBoost() {
        lastUserChange = Date()
        if quietEndDate != nil {
            quietEndDate = nil
            UserDefaults.standard.removeObject(forKey: Self.quietEndKey)
        }
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.boostPrevKey)
        }
        let end = Date().addingTimeInterval(Self.boostDuration)
        UserDefaults.standard.set(end, forKey: Self.boostEndKey)
        boostEndDate = end
        mode = .manual
        manualPercent = 100
        saveConfig()
    }

    func endBoost(restore: Bool) {
        if restore {
            let restored: Bool
            if let data = UserDefaults.standard.data(forKey: Self.boostPrevKey),
               let prev = try? JSONDecoder().decode(FanConfig.self, from: data) {
                lastUserChange = Date()
                mode = prev.mode
                manualPercent = prev.manualPercent
                restored = true
            } else {
                restored = false
            }
            if !restored {
                lastUserChange = Date()
                mode = .auto
                manualPercent = 50
                NSLog("FanCtl: 冲刺快照缺失/损坏，已回退系统自动调度")
            }
            saveConfig()
        }
        boostEndDate = nil
        UserDefaults.standard.removeObject(forKey: Self.boostEndKey)
        UserDefaults.standard.removeObject(forKey: Self.boostPrevKey)
    }

    // MARK: - 静音承诺

    func startQuiet() {
        lastUserChange = Date()
        if boostEndDate != nil { endBoost(restore: true) }
        let end = Date().addingTimeInterval(Self.quietDuration)
        UserDefaults.standard.set(end, forKey: Self.quietEndKey)
        quietEndDate = end
        saveConfig()
    }

    func endQuiet() {
        lastUserChange = Date()
        quietEndDate = nil
        UserDefaults.standard.removeObject(forKey: Self.quietEndKey)
        saveConfig()
    }
}
