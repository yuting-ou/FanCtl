import Foundation
import Darwin

// MARK: - 空转告警的「结束进程」守卫（R81）
//
// 为什么要有这个文件：`kill -9 <pid>` 只凭 pid 就发信号，而 **pid 会被复用**。
// 哨兵 2 分钟才扫一次、告警在通知中心里可以躺几小时——用户点「立即结束」的那一刻，
// 那个 pid 完全可能已经是另一个进程（甚至系统进程）。杀错的代价由用户承担，
// 所以"是不是同一个进程实例"必须在发信号前重新核验，核验不过就**失败关闭**。
//
// 实例标识取操作系统报告的进程启动时刻（kern_proc 的 p_starttime）+ 真实 uid +
// 可执行路径。三者都对上，才认为"还是它"。

/// 操作系统视角下的一个进程实例（pid 单独不足以定位实例，必须带启动时刻）
public struct ProcessInstance: Equatable {
    public let pid: Int
    /// 进程启动时刻（秒，since 1970）；由内核给出，不受用户态时钟回拨影响
    public let startSeconds: Double
    public let uid: Int
    public let executablePath: String

    public init(pid: Int, startSeconds: Double, uid: Int, executablePath: String) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.uid = uid
        self.executablePath = executablePath
    }
}

/// 拒绝发信号的原因——每一条都要能原样说给用户听
public enum KillDenial: Error, Equatable {
    /// 告警里没有实例标识字段（或字段损坏）：**当前 spinwatch 就是这种**，
    /// 生产端不在本仓库，见 BLOCKED.md 的接入清单。
    case alertHasNoInstanceIdentity
    /// pid 已经不存在了
    case processGone
    /// 同 pid 但启动时刻不同 = 进程已被换掉（pid 复用）
    case pidReused
    /// uid 与告警记录不一致
    case uidMismatch
    /// 进程在，但可执行路径读不到（跨 uid 权限）：身份核验不完整，失败关闭
    /// （R82 对抗审查：原先探针把这种情况整个报 nil → 被误判"进程已退出"）
    case instanceUnverifiable
    /// 可执行路径与告警记录不一致
    case executableMismatch
    /// 信号未送达：进程属于其他用户/系统（EPERM）或其他发送失败——
    /// 它**还活着**，与"已经退出"必须分开说（R82 对抗审查发现：原先 kill 失败
    /// 一律误报"进程已退出"，会诱导用户以为目标已死）。
    case signalNotDelivered

    public var userText: String {
        switch self {
        case .alertHasNoInstanceIdentity:
            return "这条告警没有携带进程启动时间/uid，无法确认现在这个 pid 还是当时那个进程，"
                 + "清风不会仅凭 pid 发信号。请让哨兵（spinwatch）在告警里补 startSeconds 与 uid。"
        case .processGone:
            return "该进程已经不在了，无需结束。"
        case .pidReused:
            return "这个 pid 已经被另一个进程复用（启动时刻对不上），结束动作已取消——"
                 + "否则杀掉的是现在占着这个 pid 的无辜进程。"
        case .uidMismatch:
            return "该 pid 现在的属主与告警记录不一致，结束动作已取消。"
        case .instanceUnverifiable:
            return "该进程还在，但清风读不到它的可执行路径（多半属于其他用户或系统），"
                 + "身份核验无法完成，结束动作已取消。"
        case .executableMismatch:
            return "该 pid 现在的可执行文件与告警记录不一致，结束动作已取消。"
        case .signalNotDelivered:
            return "结束动作已尝试但信号未送达：该进程多半属于其他用户或系统（清风没有权限），"
                 + "它**仍在运行**。系统进程请用 sudo，或重启对应的 App。"
        }
    }
}

/// 进程探针：默认走 sysctl(KERN_PROC_PID) 读内核事实；测试注入假表。
public struct ProcessProbe {
    public let instance: (_ pid: Int) -> ProcessInstance?
    public init(instance: @escaping (_ pid: Int) -> ProcessInstance?) {
        self.instance = instance
    }

    public static let live = ProcessProbe { pid in
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0, size > 0, info.kp_proc.p_pid == Int32(pid) else { return nil }
        let start = Double(info.kp_proc.p_starttime.tv_sec)
            + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        guard start > 0 else { return nil }
        let uid = Int(info.kp_eproc.e_ucred.cr_uid)
        // proc_pidpath 对跨 uid 进程可能被拒：进程明明在，只是读不到路径。
        // 不能把整个实例报成 nil（verify 会误判"进程已退出"）——用空串表达
        // "读不到"，由 verify 落到 .instanceUnverifiable 失败关闭（R82 对抗审查）。
        let path = Self.executablePath(pid: pid) ?? ""
        return ProcessInstance(pid: pid, startSeconds: start, uid: uid, executablePath: path)
    }

    /// 可执行路径：libproc 的 proc_pidpath（受限时返回 nil → 调用侧按"核验不了就拒"处理）
    static func executablePath(pid: Int) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN
        let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}

/// 信号发送器：唯一真正 kill 的地方，测试注入替身以证明"没核验就不发"。
/// 闭包返回 **errno**（0 = 成功）：kill 失败的原因必须保真——EPERM（没有权限，
/// 进程还活着）与 ESRCH（进程没了）是两回事，混成一句"进程已退出"会误导用户
/// （R82 对抗审查：非 root 对 root 进程 kill -9 必得 EPERM，原先被报成 processGone）。
public struct SignalSender {
    public let send: (_ pid: Int, _ signal: Int32) -> Int32
    public init(send: @escaping (_ pid: Int, _ signal: Int32) -> Int32) { self.send = send }

    public static let live = SignalSender { pid, signal in
        if kill(Int32(pid), signal) == 0 { return 0 }
        return Int32(errno)
    }
}

public enum SpinKillGuard {
    /// 只核验、不发信号。UI 用它决定「结束」按钮是否可用与提示文案。
    public static func verify(alert: SpinAlert, probe: ProcessProbe = .live)
        -> Result<ProcessInstance, KillDenial> {
        // ① 告警必须自带实例标识：缺字段/字段损坏 = 无法区分 pid 复用，直接拒
        guard let start = alert.startSeconds, start > 0,
              let uid = alert.uid, uid >= 0 else {
            return .failure(.alertHasNoInstanceIdentity)
        }
        // ② 现场重新取内核事实（sysctl 说没有 = 真没了）
        guard let now = probe.instance(alert.pid) else { return .failure(.processGone) }
        // ③ 启动时刻对不上 = pid 已被复用（允许 1 秒以内的取整差）
        if abs(now.startSeconds - start) > 1.0 { return .failure(.pidReused) }
        if now.uid != uid { return .failure(.uidMismatch) }
        // ④ 可执行路径读不到（跨 uid 权限）= 身份核验不完整 → 失败关闭；
        //    读得到则必须一致
        if now.executablePath.isEmpty { return .failure(.instanceUnverifiable) }
        if let exe = alert.exe, !exe.isEmpty, exe != now.executablePath {
            return .failure(.executableMismatch)
        }
        return .success(now)
    }

    /// 核验通过才发信号。**任何失败分支都不触碰 sender**。
    /// 注意剩余竞态（无法在 macOS 上原子地"按实例"发信号）：verify 与 kill(2) 之间
    /// 理论上存在 pid 被回收复用的窗口——这是内核按 pid 投递信号的固有限制，
    /// 本守卫把它压到最小（先核验、后单发、只发一个信号），不声称归零，见 architecture.md。
    public static func execute(alert: SpinAlert, signal: Int32 = SIGKILL,
                               probe: ProcessProbe = .live,
                               sender: SignalSender = .live) -> Result<ProcessInstance, KillDenial> {
        switch verify(alert: alert, probe: probe) {
        case .failure(let denial):
            return .failure(denial)
        case .success(let instance):
            let err = sender.send(instance.pid, signal)
            switch err {
            case 0: return .success(instance)
            case Int32(ESRCH): return .failure(.processGone)   // 核验后、发信前的窗口里退出了
            default: return .failure(.signalNotDelivered)      // EPERM 等：目标还活着，只是没杀成
            }
        }
    }

    /// 这条告警当前能不能安全结束（UI 用来禁用按钮）
    public static func canKill(_ alert: SpinAlert, probe: ProcessProbe = .live) -> Bool {
        if case .success = verify(alert: alert, probe: probe) { return true }
        return false
    }
}
