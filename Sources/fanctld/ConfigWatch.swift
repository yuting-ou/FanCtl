import Foundation
import SMCCore

// MARK: - 配置文件监控（DispatchSource 事件驱动）
//
// DispatchSource 监听 config.json 变更 + 10s 兜底轮询。
// 原子写（rename）后原 fd 失效，需重建监控。
// mtime 基准与挂起状态读自 ControlEngine（引擎在 beat 内实际重载配置并更新 mtime）。

func setupConfigWatch() {
    configSource?.cancel()
    configSource = nil
    let configFD = open(FanCtlPaths.configFile.path, O_EVTONLY)
    if configFD >= 0 {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: configFD, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler {
            if engine.isSuspendedForSleep { return }
            let newMTime = ConfigStore.configModificationDate() ?? .distantPast
            if newMTime != engine.lastConfigMTime {
                scheduleFastApply()
                reestablishConfigWatch()
            }
        }
        source.setCancelHandler { close(configFD) }
        source.resume()
        configSource = source
    } else {
        log("警告：无法打开 config.json 监控，退化为轮询模式")
    }
}

func reestablishConfigWatch() {
    configSource?.cancel()
    configSource = nil
    let fd = open(FanCtlPaths.configFile.path, O_EVTONLY)
    guard fd >= 0 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { reestablishConfigWatch() }
        return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
    source.setEventHandler {
        if engine.isSuspendedForSleep { return }
        let newMTime = ConfigStore.configModificationDate() ?? .distantPast
        if newMTime != engine.lastConfigMTime {
            scheduleFastApply()
            reestablishConfigWatch()
        }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    configSource = source
    // 注意：此处不更新 lastConfigMTime。
    // lastConfigMTime 只应由引擎 beat 在实际重载配置后更新。
}

func setupConfigPollFallback() {
    configPollFallback?.cancel()
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 10, repeating: 10.0, leeway: .milliseconds(500))
    t.setEventHandler {
        if engine.isSuspendedForSleep { return }
        let mtime = ConfigStore.configModificationDate() ?? .distantPast
        if mtime != engine.lastConfigMTime {
            scheduleFastApply()
        }
    }
    t.resume()
    configPollFallback = t
}
