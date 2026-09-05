# 架构地图（新人一页索引）

> 深度细节都在各文件头注释（含踩坑史），本页只回答"从哪读起"。

## 数据从哪来、谁写 SMC

```
传感器/SMC ──读──▶ fanctld（root，唯一 SMC 写者）──写──▶ status.json ──读──▶ 菜单栏 App
                       ▲                                       │
                config.json（用户意图）────────写────────────────┘
```
- 双进程 + JSON 文件通信的决策记录：README §2（评审过：频率低、可审计、崩溃隔离）
- SMC IOKit 协议层：`SMCCore/SMC.swift`（`SMCIO` 协议 → 测试可注入 MockSMC）
- 风扇读写/强制/交还：`SMCCore/Fans.swift`；传感器发现与热点追踪：同文件 `TemperatureSensors`
- App 永不直连 SMC，展示语义一律以 status.json 为准（单一数据源）

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
