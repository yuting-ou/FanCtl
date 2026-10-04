# 架构地图（新人一页索引）

> 深度细节都在各文件头注释（含踩坑史），本页只回答"从哪读起"。

## 数据从哪来、谁写 SMC

```
传感器/SMC ──读──▶ fanctld（root，唯一 SMC 写者）──写──▶ status.json ──读──▶ 菜单栏 App
                       ▲                                       │
                config.json（用户意图）────────写────────────────┘
```
- 双进程 + JSON 文件通信的决策记录：README §2（评审过：频率低、可审计、崩溃隔离）
- SMC 协议层（无 IOKit、无写实现）：`SMCCore/SMC.swift`——`SMCIORead`（读）+ `SMCIO`（读+写），
  测试侧 `MockSMC` 实现 `SMCIO` 即可驱动全部控制编排断言
- 风扇只读语义：`SMCCore/Fans.swift` 的 `FanReadout`；传感器发现与热点追踪：同文件 `TemperatureSensors`
- App 永不直连 SMC，展示语义一律以 status.json 为准（单一数据源）

## target 依赖边界：谁有权写 SMC（R81）

"唯一 SMC 写者"以前只是运行事实（App 恰好没调用），现在由 SwiftPM 依赖图强制：

```
SMCCore（共享：值类型/协议面/配置模型/控制策略/ControlEngine，**不含 IOKit**）
   ├── SMCDriver  = Sources/SMCCore/Driver/   IOKit 读写连接 + FanController 写实现
   │                 └─ 只被 fanctld（root 守护进程）与 fanctltests 依赖
   └── SMCReadout = Sources/SMCCore/Readout/  IOKit 只读连接，**整个模块没有写原语**
                     └─ 只被 fanprobe 依赖
FanCtlApp → 仅 SMCCore（拿不到任何硬件通路，连只读连接都不依赖）
fanmcp   → 仅 SMCCore（MCP 服务器：温度/转速转述 status.json，意图写 config.json——
           与 FanCtlApp 同层的"文件消费者"，依赖图里没有 Driver/Readout，结构上碰不到硬件）
```

- 引擎侧解耦：`ControlEngine.fans` 的类型是 SMCCore 里的协议 `FanActuating`（声明读写面），
  唯一实体 `FanController` 在 SMCDriver——所以 App/fanprobe 既拿不到实现、也构造不出对象。
- 只读通路里 `writeKey` 命令码与 raw `call` 都不存在，不是"没暴露 API"而是"没有能力"。
  代价：80 字节 `SMCParamStruct` 在 Driver/Readout 各一份，两处由
  `// SMCParamStruct layout:` 标记，改一处必须改两处。
- 验证方式（不是 grep）：在 FanCtlApp 与 fanprobe 各放一个 `import SMCDriver` 探针，
  在**只建该产品的干净 scratch** 下均报 `unable to resolve module dependency: 'SMCDriver'`；
  共享 scratch 下会因别的产物已建出来而蒙对，别用那种方式自证。

## 结束空转进程：必须绑定进程实例（R81）

哨兵 2 分钟扫一次、通知能躺几小时，而 **pid 会复用**——只凭 pid `kill -9` 会杀错人。
规则落在 `SMCCore/SpinKillGuard.swift`，面板与通知两条路径共用：

1. 告警必须自带实例标识 `startSeconds`（操作系统报告的进程启动时刻）+ `uid`；缺任一 → 拒。
2. 发信号前重新向内核取事实（`sysctl KERN_PROC_PID` + `proc_pidpath`）：进程没了 → 拒；
   启动时刻对不上 → 判 pid 复用，拒；uid 或可执行路径对不上 → 拒。
3. 全对上才发**一个** SIGKILL，且只发给告警指明的 pid。
4. 被拒时把原因原样说给用户（面板 NSAlert / 通知回投），不许静默失败。
5. 发送失败按 errno 保真区分（R82 审查修复）：`EPERM` = 目标**还活着**、只是清风没有
   权限（它属于其他用户/系统）→ 报「信号未送达」；`ESRCH` = 进程已退出 → 报「无需结束」。
   原先 kill 失败一律误报"进程已退出"，会诱导用户以为目标已死。

**剩余竞态（如实记录，不声称归零）**：macOS 没有"按进程实例投递信号"的原子原语，
`kill(2)` 只认 pid——核验（取内核实例事实）与发信号之间存在理论窗口：该 pid 在这两步
之间退出并被复用，信号会落到新进程上。缓解是"先核验、通过后立即单发一个信号"
（窗口压到微秒级），但数学上不为零。彻底归零需要 Apple 提供按实例的信号接口；
`proc_pidinfo 校验 + kill` 组合是当前最强可用校验。

**当前生产端（仓库外的 `~/bin/spinwatch`）不输出这两个字段** → 结束动作对所有告警
**失败关闭**：面板按钮显示「结束不可用」，通知侧不再注册「立即结束」动作。
告警展示与证据链保持只读可用。解锁步骤见 `BLOCKED.md`。

## 自身资源水位（实测基线，4.2.42，回归对照用）

自身占用是本软件的硬承诺（风扇软件自己不该是发热源）。2026-10-02 实测基线：

- **App（面板关闭态）**：物理占用 **47.4MB**（峰值 52.8MB；`ps rss` 的 ~127MB 是共享库页
  虚高，对照请用 `vmmap --summary` 的 Physical footprint）；CPU ≈0%，偶发 <5% 同步脉冲。
  60s 采样零增长 = 无泄漏。判泄漏看趋势，不看单点。
- **daemon**：9.8–10.0MB，CPU ≈0%（单拍脉冲 ~3%）。
- **AI 模式的 powermetrics 分项采样**是最大自身负载：采样瞬间 ~88% 单核（~0.9 CPU-s/次），
  节奏自适应（≥80° 或 AI 主动 10s、<55° 60s、AI 空闲交还视同非 AI；curve 模式不采样——
  调用点只在 ControlEngine AI 分支）。平均 1.5–8.8% 单核。**改采样节奏/窗口 = 改 AI 输入**，
  动前必须过 HIL（成本核算见 BLOCKED.md）。

水位明显劣化（内存持续增长、关闭面板后 CPU 不归零、采样成本翻倍）即视为回归。

## 决策管线优先级（低 → 高）

`FanPipeline.decide`（纯函数，daemon 与测试共用同一份代码）：
1. 基础模式：auto（交还系统）/ curve（曲线查表）/ ai（AI 控制器）/ manual
2. 静音封顶（会议 quietUntil）
3. SSD 托底（70°→60%、78°→100%）、电池托底（45°→60%、48°→100%）
4. 高温兜底（raw ≥92°→100%）——永远最后覆盖，任何用户意图不得压低
体感补偿（palmComp）与 环境补偿（envOff）是基础目标上的修正量，不改变优先级链。

## 两套学习机制的分工

| 机制 | 文件 | 学什么 | 用在哪 |
|---|---|---|---|
| 非参数查表 | `ThermalLearn.swift` | 稳态 (温度→风量)，2°C 桶 × 场景 | 夺回种子/升温前馈 |
| 参数辨识 | `ThermalModel.swift` | T = env + a·P − b·fan（RLS） | 外推预测（与查表取大者） |
采样纪律（daemon 把关）：只记稳态拍、排除 manual/安全覆盖/限速过渡态。
闭环不变式：学习数据落在真实热物理曲线上（偏好无法污染物理）。

## AI 模式 = 自适应预测控制（不是神经网络）

`FanAIController.swift`：增量 PD + 三路功耗前馈 + 空闲交还/夺回 + 曲线锚定（v9 探测式）+
启停循环抑制（v2.9.2）+ 指数退避（v3.1）。积分作用保证稳态自校正，学习只提升瞬态。

## 安全红线清单（任何改动不得压低）

1. raw ≥92° → 全速（`FanPipeline.failsafeTemp`）
2. SSD 78° 危急 → 100%（含 manual）；70° 警告 → 60%（curve/ai）
3. 电池 48° 危急 → 100%（含 manual）；45° 警告 → 60%（curve/ai）
4. 传感器连续 5 拍失败 / 卡死 / 偏低失真 → 交还系统（`.sensorUnavailable/.sensorImplausible`）
5. 退出/睡眠/看门狗重启 → 无条件恢复系统调度
6. 运行时上界：AI 有效目标 ≤84°（低于兜底释放线 88°，防振荡）

## 时间语义约定

自适应循环 1~20s；**"每拍"参数按 3s 标称拍标定，按秒的计时用秒**（`LearningGate`、idle 交还）。
改任何每拍参数先想间隔漂移。参考 `ControlEngine` 注释。

## 改参数前该看哪

1. 本文件 + 对应文件头注释（踩坑史）
2. `TestsFamily.swift`：81 成员参数化 HIL 扫描——调参前先重跑，确认不破全族鲁棒性
3. `TestsAI.swift` VirtualMachine：单点闭环（防极限环/过冲）
4. `fanctltests` 全绿是合并底线（断言数 ≥ 契约下限，实际数以 tests 徽章为准）
