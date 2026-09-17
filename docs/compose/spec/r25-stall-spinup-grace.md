---
feature: r25-stall-spinup-grace
status: delivered
updated: 2026-09-17
branch: compose/r25-stall-spinup
commits: 79c5c4a..9aac9eb
---

# R25 起转宽限（stalled 判据：RPM 上升不判停转）

## Report

**What was built** — `FanFeedbackHealth` 增加物理起转宽限：`lastActualRPM` + `spinUpDeltaRPM=50`。高目标风扇若 `actualRPM` 较上拍上升超过 50，则不判 stalled，滞后路径在试探窗（`risingGrace=false`）下同样把 RPM 斜坡计为响应证据。恒 <100、恒低速不升、升后停住仍按原语义 fault。R24b 自解永在 / streak 3→6→12→24→48 / R24c AND 归零一律未动。版本载体 4.1.3(76)。

**Verification** — `swift run -c release --disable-sandbox fanctltests` → PASS **4592 断言 / 76 组**；`swift build -c release --disable-sandbox --target fanctld --target fanprobe --target SMCCore` → PASS（仅既有 ThermalLearn unused-var 警告）。独立审查（general-1，diff `79c5c4a..9aac9eb`）：Spec compliance 6/6 PASS、Correctness 无 critical、Codebase consistency 无阻塞 → **PASS-WITH-NOTES**。F1（单测 71 原 ramp 预 R25 只累计 4 拍 mismatch、单测门偏弱）已修：ramp 拉长为滞后窗内 200…2800 连续爬升 + 逐步 `expect(!faulted)`，并补独立试探窗 rising RPM 用例。

**Journey log** —
1. Grill 钉死方向：不采用「试探窗全面 risingGrace」（削弱真故障探测）与时间基宽限；只做 RPM 斜坡证据。71 真机教训的正确补丁是区分物理响应，不是收紧或删除自解。
2. 审查证明引擎场景 12 才是预 R25 的真门：85°C balanced 首拍即写满速（smooth 冷启动=raw、shape 首写无限速），旧实现在恒高目标下 stall+4 拍滞后共 5 拍 mismatch → controlFault。单测若 ramp 太短会在进入非滞后区后 `consecutiveFailures` 归零，给出虚假安全感。
3. `lastActualRPM` 必须三条路径都写：热身拍、`record` 评估后全量、`recordCommandOnly`——漏任一条会关掉宽限或留下陈旧基线。
4. Family 清洁路径假故障风险只会下降（只增宽限）；停转注入恒 0 无上升仍被抓住。
5. 真机 dogfood（4.2-A）仍开放：本机 App 仍停在 4.1.3(72)，需部署 76 后观察空闲↔负载时 controlFault 是否从误报变为少报/不报。

## [S1] Problem

4.1.3(71) 真机证伪：空闲停转 → 负载回升时，风扇从 0 起转，`FanFeedbackHealth` 在
`actualRPM < 100` 时无条件 `mismatch`，且试探验证窗 `risingGrace: false` 使 lagging
路径同样不宽限 → 健康风扇被误判「闭环失效」。R24b 用「自解永在 + streak 指数退避」
保证不永久锁存，但**假故障仍在发生**（交还、学习采样中断、controlFault 噪声），
且试探窗内起转斜坡无法与真停转区分。

真故障对照（必须继续抓住）：
- 真停转：`actualRPM` 恒 < 100，不升
- 卡死在低速：`actualRPM` 恒定（如 500），相对高目标严重滞后且不升
- 起转后停住：先升后恒 → 升一旦停止，应回到 mismatch

R24b spec 已将「起转中 vs 真停转」列为 Out of Scope；本 feature 补上该判据。
71 危害场景（健康机空闲↔负载）是预注册回归门。

## [S2] Design

### 决策（Grill 已定）

**RPM 上升即不判 stalled/不计 mismatch**；不采用「试探窗全面 risingGrace」
（会削弱真故障探测），也不采用时间基宽限（需时钟标定、更脆）。

### 契约：`FanFeedbackHealth.record`

1. 新增私有状态 `lastActualRPM: [Int: Double]`（每风扇上次 `actualRPM`）。
2. 新增常量 `public static let spinUpDeltaRPM: Double = 50`
   （RPM 相对上拍上升超过该值 → 认定物理起转中）。
3. 热身拍（`!warmedUp`）与 `recordCommandOnly`：在更新 `lastCommanded` 的同时
   写入 `lastActualRPM`，避免陈旧基线。
4. 高目标风扇（`target > minRPM + 150`）评估：
   - `rpmRising = lastActualRPM[id].map { actual > $0 + spinUpDeltaRPM } ?? false`
   - **停转路径**（`actual < 100`）：
     - `rpmRising` → 不算 stalled，视为起转响应 → `matchedCount += 1`，不 `mismatch`
     - 否则 → `mismatch = true`（真停转语义不变）
   - **滞后路径**（`lagging`）：
     - 原 `risingGrace && (目标较上拍上升)` 保留
     - **新增**：`rpmRising` 同样计为响应证据（`matchedCount += 1`），**即使
       `risingGrace == false`**（试探窗内物理斜坡在升 = 活风扇）
     - 二者皆否 → `mismatch = true`
   - **跟随路径**（未 lagging 且未 stalled）：照旧 `matchedCount += 1`
5. 每拍评估结束后、更新 `lastCommanded` 的同一循环更新 `lastActualRPM`
   （对 `states` 全量写入，含无命令风扇）。
6. `faulted` 锁存 / `faultStreak` / `effectiveRecoverThreshold` / AND 归零 /
   自解路径 **一律不动**（R24b/c 契约保持）。

### 真故障探测不变式（预注册）

| 场景 | 期望 |
|---|---|
| RPM 恒 0 + 高目标（试探或控制拍） | 仍 fault |
| RPM 恒 500 + 高目标 4000，无上升 | 仍 fault |
| RPM 0→200→500→500（停在 500） | 上升拍不 fault；停止上升后按阈值 fault |
| RPM 0→400→900→2000 + 高目标（71 场景） | **不** fault |
| 恒 RPM 2000 + 目标 4500 + `risingGrace:false` | 仍 fault（既有单测） |
| 恒 RPM 2000 + 目标持续上调 + `risingGrace:true` | 不 fault（既有单测） |

### ControlEngine

不改试探协议（30s 固定间隔、`probeVerifyLoops=4`→3 拍验证窗、验证后交还）。
仅语义获益：验证窗内风扇若在爬升，不再被记 mismatch → 试探更易在健康起转上通过。

### 安全红线

高温/SSD/电池兜底在上游 `FanPipeline`，与 feedback 健康正交；本改动只减少
假 `controlFault`，不降低任何红线优先级，不绕过 sensor/write 故障路径。

### 文档同步

- `Fans.swift` 结构注释：起转宽限与 `spinUpDeltaRPM`
- README §5 闭环故障一句：补「起转中 RPM 上升不判停转/不判滞后」
- VERSION：`4.1.3 76`（与 R23/R24 同号递增，不另起未发布的 4.2.0）

## [S3] Out of Scope

- 不改试探间隔退避、不删自解、不收紧 recover 阈值语义（R24b 保持）
- 不做 per-fan `faultStreak` 持久化
- 不做部署/dogfood（真机 4.2-A 仍待作者装机观察；本分支以单测+族扫描为交付闸门）
- 不改 `NotificationService` 的停转通知语义（用户提醒可继续用 `RPM < 100`）
- 不改学习/校准采样门

## Tasks

- [x] T1: `FanFeedbackHealth` 实现 `lastActualRPM` + `spinUpDeltaRPM` 起转宽限 — acceptance: 契约 S2 路径全覆盖；既有 FanFeedbackHealth 单测不改语义仍绿 (covers: S2)
- [x] T2: 单测——71 起转序列不 fault（滞后窗多拍逐步断言）；试探窗 rising RPM 独立用例；恒 0 / 恒低速 / 升后停住仍 fault — acceptance: main.swift 新增用例全过 (covers: S2)
- [x] T3: 引擎场景——空闲 RPM0 → 负载/高目标 → RPM 爬升，controlFault 不应被打上；坏扇恒 0 场景 11 仍通过 — acceptance: TestsEngine 场景 12 过；场景 11 保持 (covers: S2)
- [x] T4: 族扫描清洁路径无新增 feedbackFaulted；停转成员仍 stallCaught — acceptance: TestsFamily 防御段通过（套件内）(covers: S2)
- [x] T5: 文档同步（Fans 注释 + README §5 + VERSION 76）— acceptance: 注释与实现一致 (covers: S2)
- [x] T6: `fanctltests` 全绿 + 非 UI release 编译 — acceptance: 4592 断言 / 76 组；`fanctld`/`fanprobe`/`SMCCore` release 编译过 (covers: S2)
