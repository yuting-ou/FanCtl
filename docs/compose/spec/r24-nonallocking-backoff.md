---
feature: r24-nonallocking-backoff
status: delivered
updated: 2026-09-16
branch: compose/r24-nonallocking-backoff
commits: 181f542..e24351d
---

# R24 非锁存退避（保留自解 + 故障 streak 指数退避）

## Report

**What was built** — 在 `FanFeedbackHealth` 内落地非锁存指数退避：保留「交还/匹配都计恢复」的自解路径（结构上不可能永久锁存），新增 `faultStreak` 使解除阈值按 3→6→12→24→48 退避；仅在非 faulted 且本拍真实 `matched` 时归零 streak。ControlEngine 试探协议保持 4.1.3(72) 回退后状态（30s 固定间隔、无 probe 间隔退避）。坏风扇重接管频率指数下降；健康风扇假故障首 3 拍即解，确认跟随后回 3 拍基准。README/Fans/ControlEngine 注释与实现语义对齐。

**Verification** — `swift run -c release --disable-sandbox fanctltests` → PASS 4533 断言 / 75 组（≥70 门槛）；`swift build -c release --disable-sandbox --target fanctld --target fanprobe --target SMCCore` → PASS。独立审查（fresh subagent，diff `181f542..e24351d`）Spec compliance 7/7 PASS、Correctness 无 critical、Codebase consistency 无问题 → Overall PASS。

**Journey log** —
1. 71 真机证伪「删自解」方案后，振荡待办的正确方向不是收紧恢复判据，而是**保留自解 + 让重接管间隔有界增长**——假故障代价封顶在 48 拍，真坏风扇振荡频率递减。
2. 引擎级「不锁存」测试勿只数 Md 写：30s 试探协议在永久锁存下同样翻转 F0Md，`handbacks≥2 && takeovers≥2` 恒真。有效探针是 `status.controlFault` 曾变回非 true（自解真发生）+ 自解后 `appliedPercent>0`。本 feature 审查前自抓并修掉该假绿。
3. `faultStreak` 纯内存、daemon 重启归零；多风扇 `matched` 为 OR——一坏一好机上健康扇会顶掉 streak，振荡抑制弱化但不会重新引入永久锁存。记账，未做 per-fan。
4. 真机部署观察仍是控制律改动的必需闸门（71 教训）；本 feature 交付闸门为全量单测/族扫描绿 + 独立审查，部署后请盯「空闲↔负载」时 controlFault 是否自清。

## [S1] Problem

4.1.3(71) 的振荡修复被真机证伪：试探验证窗 3 拍严格判据把「空闲停转→负载起转」的健康风扇误判为闭环失效，而当时删掉的「空拍自解」导致误 faulted **永久锁存**（controlFault 恒真、daemon 不接管）。回退后回到已知良好行为，但真坏风扇的「交还↔夺回」振荡（~6 拍一轮、Md 翻转打断 EC 升速斜坡）仍是未修待办。

核心张力：
- 自解（交还/匹配都计恢复）是假故障的隐性兜底，删掉会 P1 失控；
- 自解又让坏风扇在 fault 解除后立刻 `mustReassert` 重申，形成振荡。

需要一个**结构上不可能永久锁存**、同时把坏风扇重接管频率压到可接受范围的方案。

## [S2] Design

### 决策

在 `FanFeedbackHealth` 内实现**非锁存指数退避**，不改 ControlEngine 试探协议（仍 30s 固定间隔），不删自解路径。

### 契约

1. **恢复语义不变**：`faulted` 后，交还（无命令）或匹配都计 `recoverCount`；连续达标才解除。
2. **解除阈值随故障 streak 退避**：
   - 新增 `faultStreak`：每进入一轮新 `faulted`（`consecutiveFailures >= faultThreshold && !faulted`）时 +1。
   - `effectiveRecoverThreshold = recoverThreshold << min(max(faultStreak - 1, 0), recoverMaxShift)`
   - 序列：3 → 6 → 12 → 24 → 48（`recoverThreshold=3`，`recoverMaxShift=4`），封顶 48 拍。
3. **自解永不移除**：need 有上限 → 结构上不可能永久锁存。首次/低 streak 假故障最多 3 拍即解（保住 71 真机教训）。
4. **streak 归零条件**：仅在**非 faulted** 且本拍 `matched == true` 时清零。空拍自解不归零（避免坏风扇每轮立刻回到 3 拍基准）；健康风扇重新接管后一旦真实跟随即归零。
5. **`matched` 不门控恢复**：升速追赶中（rising grace 分支）与高目标已跟上都算 matched；恢复仍走原「无 mismatch 即 +1」路径。
6. **ControlEngine 不变**：`controlBlocked` / 30s probe / `probeVerifyLoops` / handback 语义保持 72 回退后状态。振荡抑制完全由解除阈值增长完成。

### 安全性质

| 性质 | 保障 |
|---|---|
| 不可能永久锁存 | 自解路径永在 + need 封顶 48 |
| 假故障不长期阻塞 | 首故障 3 拍解除；确认跟随立即归零 |
| 坏风扇振荡有界 | streak 增长使重接管间隔指数拉长 |
| 不触碰安全红线 | 高温/SSD/电池兜底在 ControlEngine 上游，与 feedback fault 正交 |

### 文档同步

- `Fans.swift` 文件头/结构注释反映退避与「自解永在」设计。
- README 闭环故障描述从「连续 3 拍匹配才解除」改为「首故障 3 拍，反复故障指数退避至 48 拍；自解路径永在」。

## [S3] Out of Scope

- 不改试探验证窗判据（risingGrace:false 3 拍）——71 证伪后明确不再冒进收紧恢复判据。
- 不实现「区分起转中 vs 真停转」的 stall 语义重设计（仍 `actualRPM < 100` 即 mismatch）。
- 不改 ControlEngine probe 间隔退避（那是 R23 已回退方案）。
- 不做真机部署验收（本 feature 以全量单测/族扫描绿为交付闸门；真机观察留给作者部署后）。
- 不做 per-fan faultStreak 持久化（内存 struct，重启归零；多风扇 matched 为 OR）。

## Tasks

- [x] T1: 落地 FanFeedbackHealth 非锁存退避（faultStreak / effectiveRecoverThreshold / matched 归零）— acceptance: 单测覆盖 3→6→12 退避、空拍自解保留、跟随归零 (covers: S2)
- [x] T2: 引擎场景 11 端到端锁「坏风扇长跑 controlFault 自清 + 恢复接管 + handbacks≥2 且 takeovers≥2」（不永久锁存/不卡强制）— acceptance: fanctltests 场景 11 通过 (covers: S2; depends: T1)
- [x] T3: 文档同步（Fans 注释 + README 闭环故障段 + ControlEngine 试探协议注释）— acceptance: README 与实现语义一致，无「固定 3 拍」过时表述 (covers: S2)
- [x] T4: 全量回归 + 编译门 — acceptance: `swift run -c release --disable-sandbox fanctltests` 全绿；非 UI 目标 release 编译通过 (covers: S2; depends: T1,T2,T3)
