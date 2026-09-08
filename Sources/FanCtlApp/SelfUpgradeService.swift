import Foundation
import SMCCore

// SelfUpgradeService — 一键升级的副作用编排（v3.9.0）
// 状态机：idle → downloading → validating → installing（等授权+装）→ 成功=进程被脚本杀掉重启；
// 任何失败回 .failed(reason)（菜单给"重试"），用户取消授权回 idle。
// 特权边界：本服务只准备"暂存包"（用户态 /tmp），root 干什么由 App 内嵌的 upgrade.sh 决定，
// 下载物仅作为数据被安装（校验门 SelfUpgrade.validateStaged 在授权弹窗之前执行）。

@MainActor
final class SelfUpgradeService: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading(tag: String)
        case validating(tag: String)
        case installing(tag: String)          // osascript 弹窗在场，等用户输密码
        case failed(tag: String, reason: String)

        var tag: String? {
            switch self {
            case .idle: return nil
            case .downloading(let t), .validating(let t), .installing(let t),
                 .failed(let t, _): return t
            }
        }
        /// 正在进行中（菜单不可再点第二次）
        var inFlight: Bool {
            if case .idle = self { return false }
            if case .failed = self { return false }
            return true
        }
    }

    @Published private(set) var phase: Phase = .idle

    // 防重入：同一时刻只允许一条升级链（Task 创建前检查，创建后置位）
    private var started = false

    func start(tag: String) {
        guard !started else { return }
        started = true
        phase = .downloading(tag: tag)
        Task.detached(priority: .utility) { [weak self] in
            await self?.run(tag: tag)
        }
    }

    /// 重试：清掉失败态再走一遍
    func retry(tag: String) {
        guard !started else { return }
        if case .failed = phase { phase = .downloading(tag: tag); started = true
            Task.detached(priority: .utility) { [weak self] in await self?.run(tag: tag) }
        }
    }

    private func run(tag: String) async {
        do {
            guard let url = SelfUpgrade.assetURL(forTag: tag) else {
                throw Failure("无法构造下载地址（tag 异常: \(tag)）")
            }
            // 1) 下载（URLSession 下载到临时文件，~3MB 资产）
            let (tmpURL, resp) = try await URLSession.shared.download(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                throw Failure("下载失败（HTTP \(code)）")
            }
            // 审查加固：download(from:) 的临时文件在返回后由系统择机清理——
            // 立即移到确定性路径（同卷 rename，瞬时），不等 detached 任务去碰它
            let zipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FanCtlUpgrade-release.zip")
            try? FileManager.default.removeItem(at: zipURL)
            try FileManager.default.moveItem(at: tmpURL, to: zipURL)
            // 2) 解压到独立暂存目录（确定性路径，失败残留下次 rm -rf 重建）；
            //    detached 任务返回含 FanCtl.app 的顶层目录（zip 内布局契约 = ci.yml：
            //    FanCtl-{版本}/，内含 FanCtl.app + fanctld），校验段直接复用
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("FanCtlUpgrade", isDirectory: true)
            phase = .validating(tag: tag)
            let appDir: URL = try await Task.detached(priority: .utility) {
                let fm = FileManager.default
                try? fm.removeItem(at: staging)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zipURL.path, staging.path]
                let pipe = Pipe()
                p.standardError = pipe
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    let msg = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    throw Failure("解压失败: \(msg.suffix(120))")
                }
                let entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                guard let inner = entries.first(where: {
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: $0.path, isDirectory: &isDir)
                    return isDir.boolValue && fm.fileExists(
                        atPath: $0.appendingPathComponent("FanCtl.app").path)
                }) else {
                    throw Failure("压缩包布局不符合预期（未找到 FanCtl.app）")
                }
                return inner.appendingPathComponent("FanCtl.app", isDirectory: true)
            }.value
            // 3) 校验门：版本严格相等 + fanctld 在场（root 动手前最后一道闸）
            let innerDir = appDir.deletingLastPathComponent()
            let plistData = try? Data(contentsOf: appDir.appendingPathComponent("Contents/Info.plist"))
            let hasDaemon = FileManager.default.fileExists(
                atPath: innerDir.appendingPathComponent("fanctld").path)
            if let err = SelfUpgrade.validateStaged(appInfoPlistData: plistData,
                                                    hasDaemonBinary: hasDaemon, tag: tag) {
                throw Failure(err.rawValue)
            }
            // 4) 授权 + 安装（osascript 弹原生密码框；本 App 会被脚本 pkill 并重启，
            //    本 Task 随进程死亡——这是设计内的终点，不是错误）。
            //    审查修复①：传 innerDir（含 FanCtl.app 的顶层目录）而非解压根——
            //    zip 布局是 staging/FanCtl-{版本}/FanCtl.app，传根目录会让脚本
            //    exit 2"暂存包不完整"（真机 dogfood 手造 stage 恰好掩盖过此 bug）。
            //    审查修复②：waitUntilExit 同步阻塞调用线程，osascript 等用户输
            //    密码可能数分钟——绝不能在 MainActor 上等，整段放 detached。
            guard let script = Bundle.main.path(forResource: "upgrade", ofType: "sh") else {
                throw Failure("App 内缺内嵌升级脚本（打包问题）")
            }
            phase = .installing(tag: tag)
            // 遗言 watcher（R10 设计裁决）：重启不能由 root 做——root 上下文 open
            // 实测静默失败，submit 域归属存疑（system 域=菜单栏 App root 运行，不可接受）。
            // 改为 osascript 前以用户态拉起独立 shell：App 被 pkill 后该进程被 launchd
            // 收养（parent 1），轮询到脚本末尾 touch 的完成标记后以登录用户身份 open——
            // 与手动打开完全同路。120s 超时自杀防孤儿堆积；取消授权时 watcher 空转到
            // 超时退出（标记永不存在，无副作用）。
            let doneFlag = innerDir.appendingPathComponent(".upgrade-done")
            try? FileManager.default.removeItem(at: doneFlag)
            let watcherScript = """
            for i in $(seq 1 120); do
                [ -f '\(doneFlag.path)' ] && sleep 1 && open '/Applications/清风.app' && exit 0
                sleep 1
            done
            exit 1
            """
            let watcher = Process()
            watcher.executableURL = URL(fileURLWithPath: "/bin/bash")
            watcher.arguments = ["-c", watcherScript]
            try? watcher.run()
            let quotedScript = script.replacingOccurrences(of: "'", with: "'\\''")
            let quotedStage = innerDir.path.replacingOccurrences(of: "'", with: "'\\''")
            let prompt = SelfUpgrade.authorizationPrompt(tag: tag)
            let appleScript =
                "do shell script \"bash '\(quotedScript)' '\(quotedStage)'\" with administrator privileges with prompt \"\(prompt)\""
            let (osaStatus, osaErr) = try await Task.detached(priority: .userInitiated) {
                let osa = Process()
                osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                osa.arguments = ["-e", appleScript]
                let errPipe = Pipe()
                osa.standardError = errPipe
                try osa.run()
                osa.waitUntilExit()
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                return (osa.terminationStatus, msg)
            }.value
            if osaStatus != 0 {
                if osaErr.contains("(-128)") {
                    // 用户取消授权：不算失败，菜单安静回到可升级态
                    //（带括号匹配，防 -1280 类错误码误判为取消）
                    phase = .idle
                    started = false
                    return
                }
                throw Failure("安装未完成: \(osaErr.suffix(160))")
            }
            // 走到这里说明脚本没杀掉本进程（pkill 失败的边缘）——必须复位菜单态：
            // 若进程随即被杀，复位无副作用；若存活，UI 不得永久卡"等待授权"
            //（审查修复③：原实现 started/phase 永不复位，菜单死锁在 installing）。
            // 重启由 watcher 负责（watcher open 对存活实例 = 激活，无副作用）
            phase = .idle
            started = false
        } catch {
            if let f = error as? Failure {
                phase = .failed(tag: tag, reason: f.msg)
            } else {
                phase = .failed(tag: tag, reason: "\(error)")
            }
            started = false
        }
    }

    private struct Failure: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
        init(_ msg: String) { self.msg = msg }
    }
}
