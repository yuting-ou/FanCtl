import Foundation
import SMCCore

// R81 回归：结束进程必须绑定"进程实例"，不能只凭 pid 发 kill -9。
// 这里用可注入的探针与信号器证明**发信与否由核验决定**；模块隔离不由 mock 证明，
// 另用真实构建验证（见 PROGRESS.md 的预期失败导入输出）。

private func fakeProbe(_ inst: ProcessInstance?) -> ProcessProbe {
    ProcessProbe { _ in inst }
}

/// 记录所有实际发出的信号；空数组 = 一个信号都没发
private final class SignalLog {
    var sent: [(pid: Int, signal: Int32)] = []
    var sender: SignalSender {
        SignalSender { pid, sig in self.sent.append((pid, sig)); return 0 }   // 0 = 成功（errno 约定）
    }
}

private func denialOf(_ r: Result<ProcessInstance, KillDenial>) -> KillDenial? {
    if case .failure(let d) = r { return d }
    return nil
}

func testSpinKillGuardRefusals() {
    group("空转结束进程实例守卫(R81)")

    let base = ProcessInstance(pid: 4242, startSeconds: 1_700_000_000,
                               uid: 501, executablePath: "/usr/bin/true")

    // ① 告警缺实例标识（当前 spinwatch 的真实形态）→ 拒绝且零信号
    let log1 = SignalLog()
    let r1 = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x"),
        probe: fakeProbe(base), sender: log1.sender)
    expectEqual(denialOf(r1), .alertHasNoInstanceIdentity, "缺 startSeconds/uid 必须拒绝")
    expect(log1.sent.isEmpty, "缺实例标识时不得发出任何信号")

    // ② 只给启动时间不给 uid 也算标识不全（uid 缺失不得用 0 兜底）
    let log2 = SignalLog()
    let r2 = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", startSeconds: 1_700_000_000),
        probe: fakeProbe(base), sender: log2.sender)
    expectEqual(denialOf(r2), .alertHasNoInstanceIdentity, "uid 缺失同样拒绝（不猜 0）")
    expect(log2.sent.isEmpty, "uid 缺失时不得发出信号")

    // ③ 进程已退出 → 拒绝且零信号
    let log3 = SignalLog()
    let r3 = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", startSeconds: 1_700_000_000, uid: 501),
        probe: fakeProbe(nil), sender: log3.sender)
    expectEqual(denialOf(r3), .processGone, "pid 不存在时报进程已退出")
    expect(log3.sent.isEmpty, "进程已退出时不得发出信号")

    // ④ **pid 复用**：同 pid、启动时刻不同 → 拒绝且零信号（本守卫存在的理由）
    let reused = ProcessInstance(pid: 4242, startSeconds: 1_700_000_900,
                                 uid: 501, executablePath: "/usr/bin/true")
    let log4 = SignalLog()
    let r4 = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", startSeconds: 1_700_000_000, uid: 501),
        probe: fakeProbe(reused), sender: log4.sender)
    expectEqual(denialOf(r4), .pidReused, "启动时刻对不上=pid 被复用，必须拒绝")
    expect(log4.sent.isEmpty, "pid 复用时不得发出信号")

    // ⑤ uid 不匹配 → 拒绝
    let otherUID = ProcessInstance(pid: 4242, startSeconds: 1_700_000_000,
                                   uid: 0, executablePath: "/usr/bin/true")
    let r5 = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", startSeconds: 1_700_000_000, uid: 501),
        probe: fakeProbe(otherUID), sender: SignalLog().sender)
    expectEqual(denialOf(r5), .uidMismatch, "uid 不一致必须拒绝")

    // ⑥ 可执行路径不匹配 → 拒绝
    let otherExe = ProcessInstance(pid: 4242, startSeconds: 1_700_000_000,
                                   uid: 501, executablePath: "/bin/zsh")
    let r6 = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", exe: "/usr/bin/true",
                         startSeconds: 1_700_000_000, uid: 501),
        probe: fakeProbe(otherExe), sender: SignalLog().sender)
    expectEqual(denialOf(r6), .executableMismatch, "可执行路径不一致必须拒绝")

    // ⑥b（R82 对抗审查）跨 uid 读不到可执行路径：进程在、身份核验不完整 → 失败关闭
    //    （不能落进 .processGone——root 进程活得好好的，"已经不在了"是谎报）
    let noPath = ProcessInstance(pid: 4242, startSeconds: 1_700_000_000,
                                 uid: 0, executablePath: "")
    let log6b = SignalLog()
    let r6b = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", startSeconds: 1_700_000_000, uid: 0),
        probe: fakeProbe(noPath), sender: log6b.sender)
    expectEqual(denialOf(r6b), .instanceUnverifiable, "路径读不到必须报「核验无法完成」")
    expect(log6b.sent.isEmpty, "身份核验不完整时不得发出信号")

    // ⑦ 标识齐全且对得上 → **只向目标实例发一次** SIGKILL
    let log7 = SignalLog()
    let r7 = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", exe: "/usr/bin/true",
                         startSeconds: 1_700_000_000, uid: 501),
        probe: fakeProbe(base), sender: log7.sender)
    expect(denialOf(r7) == nil, "标识齐全时应放行")
    expectEqual(log7.sent.count, 1, "放行时恰好发一个信号")
    expectEqual(log7.sent.first?.pid, 4242, "信号只发给告警指明的 pid")
    expectEqual(log7.sent.first?.signal, Int32(SIGKILL), "默认信号是 SIGKILL")
    expect(SpinKillGuard.canKill(
        SpinAlert(pid: 4242, name: "x", startSeconds: 1_700_000_000, uid: 501),
        probe: fakeProbe(base)), "可结束时按钮才可用")

    // ⑧（R82 对抗审查）发送失败必须保真区分：EPERM = 还活着、只是没权限；
    //    ESRCH 才是"进程已退出"。两者混报会诱导用户以为目标已死。
    let rEperm = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", exe: "/usr/bin/true",
                         startSeconds: 1_700_000_000, uid: 501),
        probe: fakeProbe(base),
        sender: SignalSender { _, _ in Int32(EPERM) })
    expectEqual(denialOf(rEperm), .signalNotDelivered,
                "kill 得 EPERM（如对 root 进程）必须报「未送达」而非「已退出」")
    let rEsrch = SpinKillGuard.execute(
        alert: SpinAlert(pid: 4242, name: "x", exe: "/usr/bin/true",
                         startSeconds: 1_700_000_000, uid: 501),
        probe: fakeProbe(base),
        sender: SignalSender { _, _ in Int32(ESRCH) })
    expectEqual(denialOf(rEsrch), .processGone, "kill 得 ESRCH 才报「进程已退出」")

    // ⑨ 真实数据面：仓库夹具（= spinwatch 4.2.45+ 的输出形态，**带实例标识**）
    //    + **真实 live 探针**。夹具 pid 是样例值（早已退出）→ 必须拒绝且零信号：
    //    带身份也不无脑开火，核验的永远是当下内核事实。
    //    同时断言生产端契约：夹具必须携带身份字段——缺了 = 哨兵回退到旧版，
    //    结束按钮会重新全局失败关闭（那是要修哨兵，不是改这里）。
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixtureURL = root.appendingPathComponent("Sources/fanctltests/Fixtures/spin-alerts.sample.json")
    guard let data = FileManager.default.contents(atPath: fixtureURL.path),
          let report = try? JSONDecoder().decode(SpinReport.self, from: data) else {
        expect(false, "夹具必须能解码，否则本条断言变空气")
        return
    }
    expect(!report.alerts.isEmpty, "夹具里要有告警")
    for a in report.alerts {
        expect(a.startSeconds != nil && a.uid != nil,
               "夹具告警必须携带实例标识（pid \(a.pid)；缺失 = 哨兵脚本回退旧版）")
        let log = SignalLog()
        let denial = denialOf(SpinKillGuard.execute(alert: a, probe: .live, sender: log.sender))
        let denialText = denial.map { "\($0)" } ?? "放行"
        expect(denial != nil, "样例 pid 已不存在，必须被拒：pid \(a.pid) → \(denialText)")
        expect(log.sent.isEmpty, "拒绝时零信号：pid \(a.pid)")
        expect(!SpinKillGuard.canKill(a), "已退出的样例进程不可结束（失败关闭）：pid \(a.pid)")
    }
}
