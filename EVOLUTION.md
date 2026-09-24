# EVOLUTION.md — FanCtl 自进化优化器长期记忆

> 人读 + 结构化。每次运行先读它、后写它、随提交走。原则只指导优先级与预警，
> 永不覆盖硬约束与验证闸门。禁止"一直成功所以跳过测试"。

## 目标向量基线（@94e6659，2026-09-05，本机真实数据）

| 轴 | 值 | 来源 |
|---|---|---|
| 过冲 maxOvershoot | +18.8°（峰值 90.8°，135.7h 真机账本） | ai-metrics.json |
| 磨损 | speedChanges 884/今日；调速 312 次/h；cyclingGuards 0 | stats.json + ai-metrics |
| 能耗（SMC 读/分） | 热态控制路径实测 435（预算测试 500 上限） | testSMCReadBudget |
| 热误差 stdDev | 16.17°C（135.7h 全时段，含 spike 相位） | ai-metrics.json |
| 平均输出 | 29.6% | ai-metrics.json |
| 族扫描最坏成员 | 过冲 +42.8°（env33/R1.3 硬件边界）；0 极限环违例 | TestsFamily |
| 断言数 | 4368（v3.8） | fanctltests |
| 学习地图 | 75°→98.1% / 77°→100% / 79°→100% / 81°→98.5%（R8 对账：高温桶在积累，14 点单调，包络 1.43） | ai-learn.json + status.json |

> **基线口径说明（R23 文档对账）**：本表是 @94e6659（2026-09-05）的**冻结参照点**，值不随
> 后续轮次改写（改写即失去基线意义）。两点内部不一致已核：① "断言数 4368（v3.8）"实为
> 09-08 数，@94e6659 当时徽章为 2548——保留原值但标注其来自 v3.8；② 族扫描最坏成员
> 当前实测 +42.5°（env33/R1.3/τ25/A12），较基线 +42.8° 微降。当前实况以 README 顶部
> tests 徽章（每次推送自动更新）与最新成功账本条目为准，勿以本冻结表读"现在"。

## 已证实原则（按 confidence 排序）

- **P1 缓存粒度**（conf: high）[证据 #0-pre：v3.4.1 otherHotspotMax 10s 缓存、#1 电池 3s 控制级]
  环境类（电池/掌托/散热片/otherHotspots）缓存 10s 从不伤控制；芯片热点（cpuTrack）
  只能 top-N 快速路径，不可加 TTL。适用域: SMC 读缓存 @94e6659
- **P2 合并优先**（conf: high，R1/R2 再证实——适用域扩到 App 侧解码路径）[证据 #1A, R1 b38c4a0, R2 8751866]
  给读加缓存前先找同源缓存合并；并行缓存/重复解码过期时刻错开会**翻倍**成本
  （v3.4.1 双 10s 缓存 → 1320 读/分回归；App 30s 同步 history 2 次/周期）。
  适用域: "再加一层缓存"的冲动 + 任何"同文件再读一遍"的调用链 @b38c4a0
- **P3 预算测试防回潮**（conf: high）[证据 #1C：实测 435/预算 500]
  能耗类优化必须配"次数预算回归测试"，否则下一个人会无意加回来。
  适用域: 每拍 IOKit/文件 IO 成本 @afe4b4b
- **P4 稳态门是双刃**（conf: high）[证据 #3A：旧门让 82°+ 桶永远无样本]
  学习/采样门太紧会系统性饿死某些区域（尤其高目标时的高温段）；放开时必须
  配方向上界（+15°）防兜底边缘瞬态。适用域: 学习记录门 @1bc1b80
- **P5 先验修正选安全方向**（conf: high）[证据 #3B]
  修正非单调先验时向上取 max（防欠冷）而非向下；欠冷的代价（过冲撞红线）
  远大于过冷（多噪音）。适用域: ThermalLearn 查表 @1bc1b80
- **P6 后台任务禁止直写共享值类型**（conf: high）[证据 #94e6659 生产段错误]
  DispatchSource/后台队列回调若改 struct 字段，与主队列 inout 访问必竞态
  （DoD-8 注释承诺了但实现缺席——**注释≠实现，必须 grep 验证**）。
  适用域: 所有 NSViewRepresentable/DispatchSource/后台重扫 @94e6659
- **P7 时钟注入一致性**（conf: high）[证据 #94e6659 前置修复]
  用真实时钟盖时间戳 + 测试注入 FakeClock（基准≠now）= 时钟差触发隐藏路径
  （每拍重扫）。测试构造后必须以注入时钟重录全部时间戳。适用域: 测试基建 @94e6659

## 成功账本（accepted）

| 轮 | 杠杆 | 改动 | 改前→改后 | 原则 |
|---|---|---|---|---|
| #0-pre(四批) | SMC 乘数 | other 双缓存合并 + 热态 top-4 | >600（真机等比 >2000）→ 435/预算500 | P2,P3 |
| #0-pre(四批) | 学习图 | 高温饱和门 + 单调查表 | 82°+ 桶 AI 模式恒空 → 可积累；非单调包络 | P4,P5 |
| #0-pre(四批) | 稳定性 | 重扫竞态 + 测试时钟竞态 | 间歇 exit139（8 跑 1 崩）→ 12+10 连绿 | P6,P7 |
| R1 | App IO | freshness 双解码→传参复用 | 12s 兜底路径解码 2→1 次/周期 | P2 |
| R2 | App IO | 30s 同步 days 预载下传 | history.json 解码 2→1 次/周期 | P2 |
| R3 | 磁盘写 | trend 落盘门控 panelVisible | 面板关时 ~0.1-2 写/分 → 0 | P3 |
| R4(v3.6.1) | 控制响应 | prevRawTemp 时序修复（tempChange 死代码复活） | 负载突增轮询间隔 3-10s → 1s（未达兜底区） | 审计驱动 |
| R4(v3.6.1) | 安全 | slew 迟滞带 0/100 豁免 | AI 饱和钉 97% 不可达 → 100 可达（压不住检测复活） | P5 同源 |
| R4(v3.6.1) | 稳定性 | 空扫描防御+SMC 串行化+decay 双清+NaN 防护+ps 协作池逃逸 | 唤醒窗口 5min 离线/并发未定义/幽灵 0 欠冷/潜在 trap/协作池耗尽 全部消除 | P6,P7 同源 |
| R4(v3.6.1) | 诚实度 | 族扫描恢复拍数真计量 + 81 网格断言 + 过冲排除集 | 2 处恒真断言消除；curve 模式不再污染过冲账本 | 测试即契约 |
| R5(v3.6.2) | 权限 | saveConfig root 写入补 group=admin | 自愈重写后 App 不再静默失写 | 信任边界 |
| R5(v3.6.2) | 语义 | reclaim/anchor 确认窗拍数→秒基 | 1s 快拍下确认窗不再缩水 3 倍；dt=3 严格等价 | P7 同源 |
| R5(v3.6.2) | 卫生 | loadModel 可观测 + 备份上限 + horizon 卫生 + 推荐清场 | 静默清零/无界增长/永久封顶 全部闭合 | 静默失败不可以 |
| R6(v3.6.3) | 崩溃面 | 垃圾 Codable 模糊池（确定性种子） | Int(1e308) trap（isFinite 挡不住有限巨值）——静态三轮审查都没发现 | 动态验证补静态盲区 |
| R6(v3.6.3) | 时钟 | F8 主路径 status.timestamp 走 hooks.now() | 仿真/测试时间轴恢复单一来源 | P7 |
| R6(v3.6.3) | 测试网 | 变异测试 30 变异体（杀 28+补洞后杀 2，净 100%） | 4 个盲区闭合：循环论证断言/整点边界/试探协议/周期重申 | P3 同源 |
| R8(v3.8) | 证据生产 | D 项 dt 分桶账本 + 预注册裁决规则 | D 漂移从"猜"变为"7 天后可用真机比值裁决"（P 基线自带校准线） | 控制律须账本支撑 |
| R8(v3.8) | P4 兑现 | 真机高温桶对账 | "82°+ 待积累"悬念闭合：门不饿死（340/288/71/19 样本）；包络 5.8→1.43 | 观察协议 |
| R8(v3.8) | 通用化 | 硬件画像随 status 下发 | 陌生机器 issue 的"机器长什么样"一问即答 | 诊断优先 |
| R8(v3.8) | 稳健性 | 存活判定宽限去抖 | 单拍 rename 竞态不再 UI 闪断；判死 +≈12s | 信任边界 |

## R6 反经验（v3.6.3，动态方法论轮的两起乌龙）

- **变异脚本回滚未提交修复**：campaign 用 `git checkout -- file` 还原变异体，把工作树里
  未提交的 v3.6.3 修复一并回滚——首轮 28 个 KILLED 全部被污染（chaos 测试因 F8 回归
  必然红，任何变异体都"被杀"）。**规则：变异测试必须基于已提交状态；跑 campaign 前
  `git status` 必须干净。**
- **修测试时误删自己的断言**：给 C7 加"风扇跟随"时，替换块把 expectEqual 一起吞了，
  产生无牙假绿 4282。**规则：修改测试代码时，断言行是敏感资产——替换块前后必须
  grep 断言计数不变（或跑变异体验证测试仍有牙）。**
- **方法论账本**：静态（对抗子代理/第一性原理通读）三轮共 30+ 修复，但 Int(1e308) 和
  F8 都是动态方法一轮就抓到的——静态阅读对"有限巨值""默认参数绕过注入"这类
  语义级漏洞天然低敏。**模糊+变异从此纳入常规轮次**（种子确定性，CI 成本 +0）。
  envOffset 蜕变测试的"跨 guard 边界跳变"也提醒：单调性性质必须分段声明。

## R10（v3.9.1 对抗循环轮）：审查→修复→再审的收敛实例

### 本轮形态
"对抗式审查，检查问题、修问题，一直循环"——4 路并行 Explore 子代理被环境取消后，
主代理按预列攻击清单自查；三轮（A 攻击面 → B 修复再审 → C 收敛扫描）后无新 P1/P2
停机。4418 断言（+9），真机三轮部署验证。

### Round A（8 项实锤，P1×1 + P2×2 + P3×5）
- **P1 暂存目录错位**：App 传给特权脚本的是解压根，zip 实际布局是
  `FanCtlUpgrade/FanCtl-{版本}/FanCtl.app` → 首次 App 内自动升级必然 exit 2。
  **教训：dogfood 用手造 stage（FanCtl.app 在根）恰好符合脚本的错误假设——
  端到端验证必须复现真实数据形态（真实 zip 布局），不能手工构造"理应如此"的输入。**
- P2 `osa.waitUntilExit()` 在 @MainActor 同步阻塞主线程（等输密码分钟级）→ 挪 detached。
- P2 脚本 exit 0 且进程存活的边缘路径 phase/started 死锁在 installing → 成功路径复位。
- P3×5：进行中文案 tag 与实际下载 tag 脱钩（24h 自检并发刷新）；
  submit 残留标签阻断下轮升级；URLSession 临时文件生命周期（moveItem 到确定性路径）；
  取消检测 `contains("-128")` 误匹配 -1280（改 `(-128)`）；测试 try! 违反 R8 自家规矩。

### Round B（对修复本身的再审——修复引入了新隐患）
Round A 的 submit 兜底被 fresh-eyes 推翻：asuser submit 的进程域归属无法确认
（若落 system 域 = 菜单栏 App 以 root 跑，权限模型不可接受），且终验"进程=1 但
标签查不到"说明行为不稳定。**设计裁决：root 不做 GUI 拉起**——重启改为"遗言
watcher"：osascript 前以用户态拉 bash 轮询进程，App 被 pkill 后被 launchd 收养
（parent 1 实证），轮询到脚本末尾 touch 的 `.upgrade-done` 标记后以登录用户身份
open（与手动打开同路）。脚本 root 职责收缩为：装文件、bootstrap daemon、归还属主。
实验数据落袋：`launchctl remove` 对运行中 submit 进程=杀掉它（remove 必须在
submit 前）；submit 无 KeepAlive（进程退出即结束，pkill 后 0 重生）；用户临时
目录 700（TOCTOU 换包面封闭）；open 双调用幂等。

### Round C（收敛判定）
watcher 设计 10 角扫描（取消孤儿/标记竞态/超时窗口/收养假设/失败路径/双 watcher/
路径单引号/pkill 误杀/收尾 echo/校验物与安装物一致）——全部 ✓，无新 P1/P2，停机。


#
### R22（工具链轮，版本不变）：macOS 27 适配——SDK 钉住范围从"全局 26.5"收窄到"仅 App 目标"，其余目标跑真实 27 SDK
- **卡点本质（本轮查清，推翻"SDK 正常/异常"的笼统认知）**：27.0 SDK 的 SwiftUICore 把
  @State 从 property wrapper 改成了外部宏（26.5 里是 `@frozen @propertyWrapper struct
  State`；27 里是 `#externalMacro(module:"SwiftUIMacros")`），而 CLT 6.4 只随包
  Observation/Swift/Testing 三个宏插件、缺 SwiftUIMacros（全盘 mdfind+find 无
  dylib；softwareupdate 无新包；swift.org 无 6.4 macOS 工具链；本机无 Xcode）——
  09-11 的全局钉 26.5 workaround 绕的就是这个打包缺陷，App 是唯一受害者。
- **波及面实测**：只有 FanCtlApp 的 6 个文件 import SwiftUI。SMCCore/fanctld/fanprobe/
  fanctltests 与宏无关：27 SDK 下编译干净、**4496 断言全绿**（此前被全局钉住，从未验证过）。
- **改造（scripts/build.sh）**：全局 export SDKROOT → 探测式分目标钉住：① @State 小样例
  编默认 SDK，过 → 不钉（CLT 修复或装 Xcode 后**自动回默认**，workaround 免手删）；
  ② 不过 → 旧代 SDK 从新到旧找第一个可编的（当前 26.5），仅 App 目标钉它，且走独立
  scratch-path（.build-app-sdk）避免与默认构建互相失效缓存；③ daemon/fanprobe/测试
  恒用默认系统 SDK。CI（macos-26 runner 完整 Xcode）探测必过，行为不变。全链路 EXIT=0，
  dist 4.1.2(64) 产物完整、codesign ok。
- **运行时侧印证**：本机 09-10 起跑 macOS 27.0 (26A428)，daemon 硬件档案已记
  osVersion 27.0，SMC 温度/双风扇/powermetrics 通道正常（status/stats 连续落盘）——
  适配无需任何运行时改动（min deploy 26.0 天然兼容 27）。
- **踩坑记录**：新构建系统（.build/out/SwiftBuild 路线）链接产物的 LC_BUILD_VERSION sdk
  字段打的是平台最低值（26.0）**而非所用 SDK**——拿它验证"是否真在 27 SDK 构建"会误判；
  对照实验（plain swiftc 双 SDK 编译打戳 27.0/26.5）确立正确验证法：查前端命令行的
  `-target-sdk-version`。
- **元经验**：workaround 的钉住范围应收窄到"受影响的最小目标集"——全局 env 钉 SDK 宽了
  一个量级，把真实 27 SDK 的编译期契约漂移全挡在盲区里。
- **R22 审查轮（4.1.2(65)，同日对抗审查）**：
  - **P3 修复**：启动恢复有效冲刺/静音直改 `boostEndDate/quietEndDate` 字段、不走
    startBoost/endQuiet 入口 → 字形停在扇叶直到第一拍 status。FanModel init 恢复块尾
    补 `syncMenuBarState()`（R16"新状态字段必须进变化感知清单"的同类缺口）。
  - **build.sh 加固**：SDK 发现循环 `ls|sort` 换 glob+while-read（xcode-select 指向含
    空格路径的 Xcode 时不再词分割炸）；realpath 去重计算。
  - **面板验证受阻（重要环境发现，非代码回归）**：本会话显示会话在场（WindowServer 正常、
    yu 在 console），但合成点击（System Events AXPress 与 CGEvent HID 双路）+激活后，
    MenuBarExtra 面板窗口**创建但永不上屏**（CGWindowList：340×908 layer=101
    onscreen=false）。A/B 对照：4.1.0(62)（B4a 09-12 真机点开过的版本）同症状 →
    **排除 R20/R21 回归**，定性为 OS 27 会话对合成事件的呈现限制（ToDesk 远程在场？）。
    面板开合确认仍悬置，移交用户真点一次图标（空白=回滚门禁的约定不变）。
    **【09-15 已闭环】** 用户真点在 4.1.3(68) 上：CGWindowList 实测面板窗口 onscreen=true
    （340×908）、截屏确认完整内容树渲染（仪表/趋势/AI 卡/学习地图/decisionTrace 行俱在、
    非空白）→ R21 关闭态门禁的 onAppear→panelVisible 翻转在生产路径成立，门禁生效、无回滚。
    此前"开不出"纯属 OS 27 会话对合成点击的呈现限制（A/B 已证非代码回归）。

### R39（4.2.4(95) 收口轮）：诊断包的身份串统一消毒——邻居比新字段更危险
- **选题依据**：R38 审查方点出、我自己记为"已知边界"的那一条——同一行里的 `installedAppVersion` **没有**任何守卫，而它比新加的 daemon 字段更弱：`/Applications/清风.app` 被 `install.sh`/`upgrade.sh` `chown -R` 给登录用户，属主对 `Contents/Info.plist` 有写权限。"同 uid 能否拿到 root"这条问的是提权，这里问的是**让诊断文本本身变成攻击者的输出通道**：`ESC[2J`、`ESC]0;…BEL`（改终端标题）这类字节会随"把报告粘进终端/贴进 issue 后别人再 cat"被解释；一条 100KB 的版本串能把"19 行快照"变成不可读的巨块。R38 只给 daemon 侧解码加了守卫，本轮补上"渲染前最后一道"，并把两处判据写成同一个可测函数。
- **改动**：`DiagnosticReport.sanitizeVersion(_:limit:)`（`Sources/SMCCore/DiagnosticReport.swift:102`）——限长 64、只收 `0x20–0x7e`；装机行的 App 版本走它，可疑值**整体**替换成固定标记「版本串可疑（已拒绝渲染）」，不保留原文任何片段（保留前缀就等于放行前缀）。daemon 自报值继续由解码侧守卫兜底，渲染层再过一次同一函数（双保险不是重复：一个是"落盘契约"，一个是"输出面"）。
- **验证**：4 条新断言（含控制字符 / 超长 / 非 ASCII 三种输入都出固定标记、常规串照过、**被拒原文一个字节都不留在报告里**、小节数不变）。变异验证两轮：① 把 `sanitizeVersion(raw) ?? 标记` 退回 `one(raw)` → 三条断言红；② 把 `one()` 退回"只替换换行" → 三条红（ESC/BEL 泄漏、原长未报、尾巴 400 个 z 全漏进报告）。
- **顺手扩了一格**：审完自己的实现发现"只保 App 版本"是半截活——`exit-reason.flag`、SMC 错误串同样是**盘上读来的文本**（support 目录组可写），于是把出口收到一个 `safeText`（压平换行、控制字符→空格、超 200 截断并报原长）里，`one()` 全线走它；中文标签不受影响（只挡控制字符）。**判据**：可见非 ASCII 是内容，控制字符是协议——协议字符一个都不该出现。

- **为什么不再大动**：更彻底的做法是让 fanprobe 只把 plist 当数据读并校验 bundle 归属（root 或不属主以外一律不信），但那要给只读工具加 `lstat` 判定与新的拒绝路径，收益只是"少一行可疑文本"，不成比例；渲染层消毒是**单点、可测、零副作用**的那一层。
- **本轮自己造的第二个坑（自查抓到，非审查方指出）**：R38 那条"Version.generated.swift 必须等于 VERSION"的断言，配上 build.sh 原有顺序（**先跑回归测试、后重生成**），构成一条自锁死链：`提 VERSION → 跑 build.sh → 测试先红 → 永远走不到重生成`。也就是"新断言把唯一的修复路径挡在身后"。修 = 把重生成移到回归测试之前（`build.sh:51-75`，注释写明理由），并把这条写进失败账本：**加断言前要先看它挡住的是不是自己唯一的出口**。
- **R39 独立审查轮（两路 fresh subagent → 6 修 / 4 证伪 / 2 记为已知边界）**：
  - **修（P1）｜还有两个裸渲染出口**：硬件画像行（`oneLine` 含 sysctl 机型串）与磨损行的 `stats.date` 都是直接拼进文本、不经消毒，而它们同样来自组可写的 `status.json`/`stats.json`——只保 App 版本是半截活。两处收进同一出口，各配哨兵断言（ESC/BEL 不得出现在输出、画像行不得被拆成多行）。
  - **修（P2）｜说明行自己说谎**："只含…上次退出原因**原文**"在消毒后已不成立，改成"控制字符已剥、超长已截断"。
  - **修（P2）｜`build.sh` 的 VERSION 解析无空值守卫**：`read -r A B < VERSION` 拿到空串时会先把空版本写进受版本管理的生成文件，再去跑测试；末尾 dist 自证门用的是同一组变量，空对空照样通过。改为读到空值立即 `exit 1`。
  - **修（P2）｜"三处一致但全是旧号"无门可查**：tag 门只比 `tag == VERSION`。加 release job 的版本单调门——新 tag 必须严格大于已发布最大 tag（`git ls-remote --tags` + `sort -V`）。本地把这段逻辑单独复算过六种输入：递增放行、重发旧号被拒、双位数段（4.10.0 vs 4.2.4）按版本号而非字典序、非版本 tag 混入被忽略、首次发版放行、同号重打放行（见下条边界）。
  - **修（P2）｜README 两处失真**：门槛数字、"build.sh 先跑测试"的旧顺序描述；并补"改 VERSION 须把重写出的 `Version.generated.swift` 一并提交，漏提交 = CI 测试作业直接红"。
  - **修（P3）｜行数断言恒真**：`expectEqual(lines.count, sectionCount)` 数的是数组元素，含 `\r` 不改变它——补 `allSatisfy { 不含 \n 且不含 \r }`。
  - **顺手修的产品措辞**（真机 dogfood 撞见）：`daemon 自报 未自报（…）` 这种叠词——"自报"前缀只在真有值时加。
  - **证伪 4**：`count<=64` 与字节数不一致可绕（过两关者必纯 ASCII）；`probeError` 需单独处理（串里只有字面量键名与 IOReturn 整数，且已被同一出口覆盖）；"重排后 CI 不再覆盖提交自洽"（测试作业不跑 build.sh，读的是检出内容）；"重排 env/SDK 探测有副作用"（`FANCTL_VERSION/BUILD` 全仓零消费者，属既有死码）。
  - **已知边界**：`HardwareProfile.safeStr` 只截 128 字符、不排控制字符（渲染侧已兜住，改解码侧要动 status 契约）；单调门挡不住"删掉 tag+Release 后重打同一号"——触发本次 job 的 tag 本身就在 `ls-remote` 列表里，必须排除才能比对，于是"同号"与"首次发版"两种情形不可区分；那步只剩 `gh release create` 在"同号 Release 仍在"时报错。真要堵死得在发版流程上不做二次同号 tag，不是脚本能判的。
- **R39 交付链事故（第一次 tag 触发就自炸，2m26s 红，无 Release 产出）**：
  - **现象**：`打包 Release 附件` 步骤报 `command substitution: line 10: syntax error near unexpected token '|'`。
  - **根因**：上面那条新加的单调门把管道折行写成**行首续行**（`$( …| sed '…'` 换行 `| grep …）`）。`$( )` 内的换行是命令终止符，下一行以 `|` 开头就是运行时的语法错——发版号越高、代码越新，被挡住的反而自己的链。
  - **为什么本地"验过"还是漏了（这才是要记的）**：我先做的是**把逻辑抄成一行**在 /tmp 复算六种输入——验的是算法，不是将要发出去的那段文本。事后给链加的第一道门（抽出 run 块跑 `bash -n`）**对同一段坏文本仍然返回 0**：bash 对命令替换的内容**延迟到执行时才解析**，`-n` 根本不进去；只有 CI 那层 `bash -e` 才把错误变成退出码。**任何"用 `bash -n` 兜 shell 语法"的门，对 `$( )` 内部的错都是瞎的**。
  - **修**：① `ci.yml:125` 整条管道收回一行，注释钉住原因；② root 门禁新增 4 道（heredoc 前提 / 抽取器非空哨兵 / **静态禁行首续行操作符** / run 块 `bash -n`）——第 3 道才是真正有牙的那一道，前两道防抽取器自己烂掉，第 4 道兜块级失衡；③ 变异检验：把事故原形塞回 `ci.yml` → 门禁 49→48/1 命中，恢复后复绿。
  - **交付姿势**：Release 未创建，按本仓既有账本**重指 tag**（删远端 `v4.2.4` + 在修复提交上重打），不留"同号不同码"的第二现场。
- **记账**：4860 → **4876 断言 / 85 组**（契约门槛双源同步 4870 / 84）；root 门禁 **45 → 49**/0；`build.sh` 全链路 EXIT 0，`dist/fanctld -v` = `fanctld 4.2.4 (95)`。
- **收口**：tag 重指后 CI 全绿，Release `v4.2.4` 已发布并解包验过——发行物恰 6 项（`FanCtl.app fanctld fanprobe install.sh uninstall.sh upgrade.sh`）、bundle 内 `.sh` 数 0、`fanctld -v` = `4.2.4 (95)`、`Info.plist` = 4.2.4/95、发行说明首行与 `- 4.2.4：` 要点行都在、发行物里的 `fanprobe --report` 印出 19 行。`v4.2.4` 的 tag 目标 == 当时的 `origin/main` 尖（`4ea0f64`）。
- **未验到的那条路（记着，别再以为已验）**：新单调门的**拒绝分支**在 runner 上从没跑过。它唯一可达的拒绝形态是"VERSION 与 tag 一起留旧号"（此时"tag == VERSION"那道身份门照过，只有单调门拦得住），但要在真机上复现它就得把一个**已发布且带 Release 的旧号**重新推成 tag——正好是它要保护的那个动作，验它 = 破坏现场。故按已知边界接受：本地只对"抽出来的那段文本"跑过六种输入（递增放行 / 重发旧号被拒 / 双位数段 / 非版本 tag 混入 / 首次发版 / 同号重打放行）。

### R38（4.2.3(94) 契约补一轮）：daemon 自报版本，诊断包不再靠推断
- **选题**：R37 的诊断包把"陌生人机器上首问的那一串问题"收进了一条命令，但它自己的**残余风险第一条**就是"报告不含 daemon 版本串"——只能拿 App plist 版本 + `/usr/local/libexec/fanctld` 的 mtime 推断。真机第一次 dogfood 就撞出这种推断无从判断的形态：App 是 4.2.0(91)、daemon 二进制是 9-21 装的，"到底是 App 新 daemon 旧、还是 daemon 也升过只是被复制过一次"没人能答。杠杆排序里这属于"状态与指标会说谎"，高于交付链，故先做它。
- **改动**（`git diff` 面很小，价值在契约）：`DaemonStatus.daemonVersion: String?`（`Config.swift:404`）由 fanctld 把编译期常量 `fanctldVersion` 经 `ControlEngine.Hooks.daemonVersion`（默认 nil，测试/工具不注入即不落盘）带进**三处**构造：常规拍与两个传感器故障分支（故障态恰恰最需要知道是谁在说话）。诊断包"装机"小节改成三件套：App 版本 + daemon 自报版本 + 二进制落盘时间。
- **红线自查**：新 JSON 字段走 `decodeIfPresent` + 默认 nil ✓；进 `statusChangeSummary`（版本变化的那一拍必须落盘，否则升级后诊断包还报旧版）✓；写盘节奏未变（版本串进程内恒定，只在启动那一拍造成一次差异）✓。解码侧另加**外来值守卫**：限长 64、只收 0x20–0x7e——`status.json` 是 `root:admin 664`、同组可写的文件，不能假设里面的字符串干净（它会进用户粘贴的诊断文本）。
- **测试**（新组 `daemon 版本自报（R38）`，`TestsReport.swift`）：往返不丢 / 旧 status 无字段解为 nil / 超长·含控制字符·空串一律拒 / 仅版本不同也算摘要变化 / **两条 F9 同族守卫**——① 用 `DaemonStatus(..., daemonVersion:)` 的 **init 参数**构造后断言字段非空（属性直赋的往返测试抓不到"init 漏赋值"，而 Optional 存储属性漏赋值是静默的：v3.6.0 的 `learnEnvelopeGap` 就这样整版失效）；② 源码里 `daemonVersion: hooks.daemonVersion` 计数须为 3。
- **本轮自己踩到的两个坑（都是"假绿"）**：
  - 手写 JSON 夹具用了 raw 串 `#"…"#`，值前那个 `"` 与分隔符 `"#` 粘连，导致整条 JSON 非法 → 四条"外来值守卫"断言全部**空过**（它们期望 nil，而解码失败也返回 nil）。加一条"基线：常规版本串可解出"才暴露。教训与 R37 同源：**任何依赖前提成立的断言，前面必须有一条断言证明前提成立**。
  - 变异验证 M-A（删掉 init 里的 `self.daemonVersion = daemonVersion`）**第一次没有打红**——因为往返测试走的是属性直赋。补上 init 参数那条断言后 M-A 立刻红。这是本轮最值钱的一次自我证伪：我以为已经覆盖了 F9 那一类。
- **R38 独立审查轮（两路 fresh subagent，共 10 项 → 6 修 / 3 证伪或已覆盖 / 1 已知边界）**：
  - **修（P1）｜"装机"行没带新鲜度标记**：版本取自 `status.json`，daemon 停三天后再升级，那一行印出的就是三天前的自报版本，与"App 新 daemon 旧"的签名**完全同形**——正是本轮要防的那类谎。修 = `stale` 计算上移到该行之前并附加，测试断言"装机行也带陈旧标注"。
  - **修（P2）｜兜底文案把三种原因说成一种**：`版本未落盘（daemon 早于 4.2.3）` 在"根本没解出 status""该值被外来改写后遭守卫拒收""新版但没接线"三种情况下都会印出，且硬编码了 4.2.3。修 = 三分支措辞：无 status → "无 status，无从判断"；有 status 无值 → "未自报（旧版 daemon，或该值被改/被拒收）"；有值 → "自报 X"（点明是自报）。
  - **修（P2）｜文本计数门挡不住真实失效**：`daemonVersion: hooks.daemonVersion` 数出现次数只能防"删"，防不了"新增构造点漏传"与"传了但没写进去"。修 = ① 改成"构造点数 == 带版本点数"；② **加行为覆盖**：`makeEngine` 可注入版本，冷启动即传感器读失败那一拍走最小 status 分支，断言 `loadStatus()?.daemonVersion == "9.9.9 (1)"`，并带前提断言（`controlFault == true`）防"分支根本没走到"的假绿。变异验证：删掉故障分支的版本 → 两条同时红。
  - **修（P2）｜正向渲染零覆盖**：满输入里没设 `daemonVersion`，诊断包只测过兜底串。修 = 满输入设值并断言打印。
  - **修（P2）｜占位版本可冒充真版本**：CI 的测试作业走裸 `swift build`（不经 build.sh），而 checked-in 的 `Version.generated.swift` 恰好写着上一版真号。修 = 新增一致性断言：该常量必须等于 `VERSION` 前两字段（漂了就红，逼"改号必重生成"）。**没采纳**审查方"占位改 `0.0.0-dev`"的建议——那会让这条门恒红，且真机上"版本未知"的误导并不比现在少。
  - **修（P2）｜notes 同源门可被旧句子骗过**：全文 `grep -qF 4.2.3` 在"文件里任何位置出现这个号"都算过，而警示句里天然有 `4.2.0`/`4.2.1`。修 = 两处（root 门禁 + release job）都只认要点行 `^- <版本>[：:]`，并顺带把要点按版本倒序排齐。变异验证：把要点行改成 `- 4.2.9：` → 门禁红。
  - 证伪/已覆盖：①"写盘会变频繁"——`hooks.daemonVersion` 是进程内常量，摘要只在启动那一拍多判一次，正是设计目的；②"另有绕过解码守卫的路径"——全仓只有 `ConfigStore.loadStatus` 一个解码器，App 的 `FanModel.swift:504` 只是 `O_EVTONLY` 事件监听；③"能注入 shell/AppleScript"——该字段零决策消费者，守卫已排除 0x00–0x1f 与非 ASCII，且 `one()` 再压一次换行。
  - **已知边界（审查方点出、本轮不动）**：同一行里的 `installedAppVersion` **没有**同等守卫——它来自 `/Applications/清风.app/Contents/Info.plist`，而那个 bundle 被 `install.sh` chown 给登录用户，属主可写任意字符串。诊断文本层已有"最多一行"保护（渲染前 `one()` 压平），但**若将来任何代码拿它做判断，必须先补守卫**。另：`fanprobe` 跟随符号链接读 plist/mtime，组内用户可伪造"装于 X"。
- **残余风险（不许静默当已修）**：
  - 版本串是 **daemon 自报**，而 `status.json` 在同组可写目录里——它证明的是"写这份状态的那个二进制自称哪版"，不是"root 落点上的二进制确实是它"。目前没有任何代码拿它做决策（全仓仅诊断包渲染消费），所以伪造只能骗人眼；一旦将来有人用它做升级判断，必须换成"从 root 拥有路径读出的身份"（如 sha256 或 `-v` 实读）。
  - `Version.generated.swift` 与 `VERSION` 的一致性本轮有了断言（漂了就红），但**"改了代码没提 VERSION"仍无机械守卫**——那需要构建期哈希自证，属 plan 之外的投入；发行链靠 tag==VERSION 与 `dist/fanctld -v` 双断言兜。
  - 接线门是**文本计数**（构造点数 == 带版本点数），注释里出现 `DaemonStatus(` 会把它撑红——失败方向是响铃而非静默，可接受；真正的新构造点由 `sites == 3` 那条一起兜。
- **记账**：4836/84 → **4860 断言 / 85 组**（契约门槛双源同步 **4850 / 84**）；root 脚本门禁 45 通过 / 0 失败；变异 8 处（init 漏赋值 / 版本不进摘要 / 去掉限长 / 故障分支漏传 / fanctld 不注入）全部打红后复绿；`./scripts/build.sh` 全链路 EXIT 0，真机 `dist/fanprobe --report` 首行如实报 `daemon 版本未落盘（daemon 早于 4.2.3）`（本机装的仍是旧 daemon）。

### R37（4.2.2(93) 可诊断性轮）：诊断包落地，顺手挖出"只读工具其实会写 root 的数据目录"
- **选题依据**：目的函数里"可诊断性"是陌生人机器上的第一约束——本仓全部调参证据来自一台机器（N=1），而 Release 在往陌生硬件发。R33 就把"fanprobe --report + issue 模板收诊断"记进未修清单，本轮兑现（纯加法、可全自动验证）。
- **做了什么**：① `SMCCore/DiagnosticReport.swift`——纯函数渲染 19 小节定长文本（不碰文件/SMC/时钟，时间戳由调用方注入，所以无权限环境也能全测）；② `fanprobe --report`——副作用（读 JSON、试开 SMC、读 Info.plist 与 daemon mtime）全在薄壳里，且放在 SMC 探测之前：诊断包最大的价值恰恰在"东西坏了"的时候；③ `.github/ISSUE_TEMPLATE/bug_report.yml` 新增必填 `report` 项；④ 发行说明改由仓库 `RELEASE-NOTES.md` 单一来源提供。
- **真机 dogfood 首跑就产出两条硬事实**：本机 App 是 4.2.0(91) 而 `/usr/local/libexec/fanctld` 的 mtime 是 9-21——"装机: App 版本 + daemon 落盘时间"这一行的全部意义就是暴露这种半途；旧 daemon 不写 `controlFault/targetUnreachable/safetyFloorPercent`，所以"未落盘"必须与"—/false"三分，不能混成一个破折号。
- **设计约束（每条都有断言）**：小节数恒定（省略=谎报"没问题"）；非有限值→"—"；传感器哨兵 0→"0(哨兵=无有效读数)"（`ControlEngine` 在 sensorUnavailable/sensorImplausible 两分支直接写 `cpuDie:0`）；缺字段→"未落盘"；加权口径标签与 `weightedSpan` **同一条**判据；停更 >30s 时数值小节逐个带"陈旧快照"；磨损行自带战报日期；不写用户数据目录路径。
- **R37 独立审查轮（两路 fresh subagent，15 项 → 8 修 / 2 证伪 / 5 记为已知边界）**：
  - **修（P1）｜"只读诊断工具"其实会在 root 的数据目录里写文件**：`loadCorruptionAware` 解码失败时调 `backupCorrupted`——新建 `*.corrupted.<ms>.json` **并轮转删除旧备份**。fanprobe 从 v2.x 起就在调这些 loader，而 support 目录是 `root:admin 775` 且**无 sticky 位**：登录用户跑一次 `fanprobe` 就能在 root 的地盘造文件、并删掉 root 写的损坏证据。修法：`readOnly:` 参数贯穿 5 个 loader 与 history 的抢救分支（解码口径一字不动，只关副作用），fanprobe 全部改只读；防回潮 = **白名单式源码门**（黑名单点名 6 个不够——副作用最重的 `loadConfig` 会建目录+备份+回写默认配置，它没进黑名单就能悄悄加回来）+ 行为对照测试（同一份坏数据：正常加载留 1 个备份、只读加载留 0 个）。**这条是自查+两路审查共同撞见的，我自己的计划自审没发现。**
  - **修（P1）｜跨语言常量的"双向锁定"门禁是空的**：`FanCtlPaths.installed{AppBundle,DaemonBinary}` 的注释声称"由 fanctltests 与 root 脚本门禁双向锁定"，实际 Swift 侧那句断言是**常量与测试里同一串字面量自比（恒真）**，从不读脚本，注释还点了个不存在的测试名。后果：改 install/upgrade/uninstall 任一处落点，全部门禁仍绿，而诊断包第 2 行谎报"App 未找到/daemon 缺失"。修 = 新 shell 门把两个常量从源码里抠出来逐字比对三个脚本（变异验证：`libexec`→`bin` 立刻红），注释改为如实描述。
  - **修（P2）｜口径标签会给数字镀金**：`weightedSecondsTotal != nil` 与 getter 的真实回退条件（`>1e-6`；`sanitized()` 把非法值钳成 0）不是同一条 → 走样本口径除法的数字被标成"秒加权"。改成同条件，并加"有样本但加权分母=0"的断言。
  - **修（P2）｜四处措辞会让读者判错**：status 文件在但解不出时报"运行中"（下面八个小节全是"—"）；`age` 未钳负（时钟回拨→"停更 -0 分钟"）；两个"受控"不同寿命（指标换目标档清零、账本不清零）却同名；"今日"无日期守卫（daemon 停三天就拿三天前的战报称今日）；"SMC 直读: 正常"其实只证明能打开、未取读数；热模型归一化只标 b 且"内存≠落盘 = 未加载"的推论方向错（落盘约 60s 节流，差一个窗口是常态）。
  - **修（P2）｜notes 链三处摆设门**：`grep -qF "$MM"` 在 VERSION 读空时是 `grep -qF ""` 恒真；配对门 `grep -- "--report"` 命中的是注释行；发版 step 不校验 tag↔notes 同源（发 4.2.9 贴 4.2.2 的说明照绿）。三处都换成硬门，其中 release job 里 `grep -qF "${GITHUB_REF_NAME#v}" RELEASE-NOTES.md || exit 1`。
  - **证伪｜"BSD `install` 保留源文件 mtime，所以『daemon 装于 X』是构建时刻"**：实测 `install -m 755 src dst`——src mtime=2020-01-01、dst=当场时间，**不保留**。审查方给的"实测"结论是错的，"装于 X"确实就是最后一次装/升级时刻，措辞保留（另把 label 写成"装于"→"最后装/升级于"级别的精确化留作后续，不再动）。
  - **证伪｜issue 模板 maxLength 不够**：GitHub textarea 上限 65535，19 行诊断包约 1–2KB。
  - **已知边界（记档不修）**：`attributesOfItem`/`Data(contentsOf:)` 跟随符号链接 → 组内用户可伪造"装于 X/停更 N 分钟"，但报告文本没有任何代码消费者，伪造只能骗人眼；`/Applications/清风.app` 在 App 侧仍是三处字面量（PanelView 文案 + 升级 watcher 的 `open`），改读常量会把展示文案与 AppleScript 元字符校验搅在一起，单独一轮做；"风扇数量 —"与同行 fan0 明细并存不算矛盾（画像缺失 ≠ 风扇缺失）。
- **记账**：fanctltests 4736/82 → **4836 断言 / 84 组**（契约门槛双源同步 **4830 / 83**）；root 脚本门禁 39 → **45 通过 / 0 失败**；变异验证 8 处（少一节 / 按条件省略 / 去 `isFinite` / 不压平换行 / 口径恒称加权 / 常量漂移 / 只读守卫失效 / 源码白名单越线）全部打红后复绿；`./scripts/build.sh` 全链路 EXIT 0。
- **残余风险（不许静默当已修）**：诊断包仍**不含 daemon 版本串**——读它要 exec，于是退化成"App plist 版本 + daemon mtime"的代理对，两者一致性靠 `install.sh`/`upgrade.sh` 同源安装来保证；`status.json` 没有版本字段，跨版本对照仍需人推（要正解就得给 DaemonStatus 加字段并走一轮 JSON 契约变更）；陌生机器的真实形态分布（passive 机型、无功耗键、传感器全 0、`/usr/local` 用户可写）至今没有第二台机器验证过——这正是本轮做诊断包的原因，也是它本身尚未被验证的证据。

### R36（4.2.0(91) 批次 A）：特权信任根落地 + 发版链第四根因
- **批次 A 做了什么**：把"root 执行的代码"从用户可写的 App bundle 里彻底搬走。三代演进的同一威胁：v3.9 让 root 读 bundle 内 `upgrade.sh`（bundle 被 `chown -R` 给登录用户 → 驻留进程可篡改正文 → 用户下次输密码即提权）；R23 改成构建期 base64 内嵌进二进制（堵住文件面，但**二进制本身还在同一个可写 bundle 里**，换 App 即换被授权内容）；批次 A 定死规范落点 `/usr/local/libexec/fanctl-{upgrade,uninstall}.sh`（root:wheel 755），install.sh 首装、upgrade.sh 每次升级自我刷新，App 侧 exec 前 `lstat` 校验落点身份，**不合规直接拒绝提权，绝不回退内嵌/包内副本**。
- **四道闸（每道都有名字）**：
  1. `SelfUpgrade.privilegedScriptTrusted`（纯函数，Swift 侧 11 条断言）：常规文件 + 非符号链接 + uid 0 + 组/其他无写位。变异验证：删掉写位判据 → 3 红。
  2. `fanctl_dir_trusted`（shell 侧目录面）：落点目录与其父目录都必须 root 拥有且无组/其他写位——Homebrew 机器常把 `/usr/local` 交给登录用户，那种机器上**拒绝安装**而不是装个假安全。负控两支进 root 脚本门禁（用户属主 / 组可写各一）；正例（root 属主 755）需要 root 构造，诚实记档为"仅真机验证"。
  3. 暂存包必须自带两个特权脚本正文，缺即 `exit 2`（"半个升级链"不许往下装）。
  4. 自我刷新必须用 `install`（unlink+新建 inode）而不是 `cp` 原地截断——**bash 边读边执行**，截断自己正在跑的那个 inode 会让后续行错乱。注释钉在代码里，因为它是一个"改小了就静默坏"的坑。
- **内嵌机制作废而非并存**：删 `UpgradeScript.generated.swift`、build.sh 的 base64 生成段、ci.yml 的占位漂移门、bundle 内两份脚本副本。理由：路径信任建立后内嵌只是同一目标的第二套实现，双实现必然分叉（这也是 `chmod 1775` 那条否决的同源理由）。root 脚本门禁新增静态门把它钉死：`build.sh` 出现 `UpgradeScript|embeddedUpgradeScriptBase64` 即红、往 `Contents/Resources` 放脚本即红、ci.yml 的 STAGE 不带 `upgrade.sh` 即红。
- **发版链第四根因（这条链今天一共红了四次）**：`--target` 在 runner 那版 SwiftPM 上**只编译不链接可执行件**——产物目录存在但是空的，本机却会链接（所以本地一直绿、CI 独红，前三次都没能看到这个差别）。修 = 按产物请求（`--product fanctld/fanprobe/FanCtlApp`），构建与 `--show-bin-path` 查询用完全同一组 flags（含 `--scratch-path`）；`artifact()` 的兜底搜索改 `find -L`（SwiftBuild 会把 `.build` 内目录做成指向外部的符号链接，`-type f` 默认不跟随）并修掉两个自摆缺陷：BSD `xargs` 对空输入仍执行一次 `ls -t`（那是在列当前目录）、诊断 `find` 的 `maxdepth 3` 比产物深度更浅（等于什么都没报）。
- **一次性迁移是硬事实**：旧 App 的脚本没有装 root 脚本的逻辑，Release zip 此前也不带 `upgrade.sh` → 4.2.0 必须先手动 `sudo ./install.sh` 一次，此后 App 内升级链自愈。Release 说明与 README/面板卸载指引同步改写。
- **R36 独立审查轮（批次 A 的两路 fresh-subagent）：11 项 → 2 个 P1 成立、3 项 P2、若干 P3，另有 1 项自我撤销**：
  - **P1｜目录信任门自摆死锁**：`upgrade.sh` 里 `fanctl_dir_trusted` 的**定义写在调用之后**。bash 到那一行才注册函数，调用早于定义 → `command not found`（127），而 `if ! fn` 把 127 反成"判真" → 健康机器上也走拒支 `exit 5`，即 **4.2.0 的 App 内一键升级 100% 失败**。39 项 root 门禁当时全绿——因为回归全部走 `FANCTL_TEST_GATES_ONLY=1`，而那块恰好被钩子跳过。修 = 函数上移到任何调用之前；防回潮 = 门禁新增静态门"定义行号 < 首调行号"（两个脚本各一条），并**用行为测试证明钩子本身可达**（`FANCTL_TEST_DIR_TRUST=1` 对 `/usr/local/libexec` 给 0、对用户属主+组可写目录给 1）。教训：**测试后门跳过的代码块 = 零覆盖代码**，凡"为了可测而加的门"必须同时有一条测过"门后那条路"的断言；bash 的顺序解析让 `bash -n` 完全看不出这类错。
  - **P1｜特权脚本正文零校验**：批次 A 后暂存包里的 `upgrade.sh`/`uninstall.sh` 会被 root 装成"将被 root 执行的代码"，但复核只覆盖两份二进制，App 侧也只校验 `FanCtl.app`+`fanctld` 存在 → 同 uid 进程改写暂存正文（分钟级窗口，含用户输密码），或在解压目录预置改过的脚本后静等一次 `sudo ./install.sh`（**无需竞态**），root 就会以 `root:wheel 755` 落地，下次 App 的信任校验全绿放行。**净收益判定：闭住了"换 bundle/换内嵌即换 root 正文"，但同 uid→root 链未断，只是把注入口从二进制挪到一个无摘要的目录。**修 = 两份脚本与两份二进制同等待遇（`SelfUpgrade.upgradeArguments` 7 元契约 + root 侧四哈希复核 + 弹窗前的存在性门），新增行为负控"授权后偷换 upgrade.sh → exit 3"；Swift 侧锁参数顺序（跨语言契约错位=静默升级失败）。**信任根仍缺**（无公证/签名），见下方残余风险——这次的诚实结论是"缩小窗口"，不是"闭链"。
  - **全局测试后门一律限非 root**：`osascript` 的 `do shell script` 会透传调用方环境（实测 `osascript -e 'do shell script "env"'` 能看到注入变量）→ 未限非 root 时，一次 env 注入可让 root 流程"报成功而什么都没装"。三个钩子（gates-only / dir-trust / config-guard）全部加 `EUID -ne 0` 前置，并进门禁静态检查。特权落点 `FANCTL_LIBEXEC_DIR` 覆写**删除**（生产路径写死，plist 的 `ProgramArguments` 与之同源）。
  - **我自己加错的门，撤了**：给自证门加的"产物 mtime 不早于本次构建"当场把自己报红——SwiftPM 以**硬链接**摆放产物，mtime 属于更早那次构建，不是新鲜度证据。撤除并把结论写进注释：跨构建可靠的身份信号只有版本号，所以"改代码必须提 VERSION"是硬规矩；防陈旧件靠"只在 `.build*/` 内找 + 版本自证"。**新加的断言先让它跑一次自己**，跑不过就是断言错不是代码错。
  - **自证门的真实边界（表述降级）**：`Info.plist` 由同一 VERSION 写出再读回 ≈ 恒真，只防"生成/拷贝错位"；有鉴别力的是 `dist/fanctld -v`。README/EVOLUTION 原写"三方对齐"是夸大，已改。
  - 证伪/不修：`/usr/bin/install` 确实是 unlink+新建 inode（"自我刷新不能 cp"成立）；`0$mode` 算术安全；`lstat` 与 `[[ ! -L ]]` 对中间层符号链接可见性一致（攻击者文件必 uid≠0 → 拒）。
- **记账**：4.2.1(92) 承载 R35 全部批次 + 批次 A + R36 修复；契约门槛 4600/79 → **4720/81**（双源同值），实测 **4736 断言 / 82 组**；root 脚本门禁 24 → **39 通过 / 0 失败**。v4.1.4 的 tag 因发版链连红四次从未产出 Release，其内容已含在 4.2.x 里（tag 去留留给作者定）；v4.2.0 已真实发行但**含上述两个 P1**，由 v4.2.1 取代。
- **残余风险（不许静默当已修）**：zip→暂存→root 复核之间仍无信任根（无 Developer ID/公证，plan-4.0 已砍）；`/usr/local` 符号链接种植面靠 `lstat`+目录信任门兜，真正的信任根需要公证或 MDM 分发；App 二进制仍在用户可写 bundle 内（批次 A 只保证"root 执行的代码"不可被用户改，不保证"App 不会被换掉"——换掉 App 的代价从"静默提权"降为"下一次授权装的是攻击者的 App，但仍需用户输密码，且此时攻击者要能改写的是"经哈希复核的暂存内容"这一分钟级窗口）。

### R35（4.1.4(86) 硬化轮）：闭环状态残留 → 数据诚实 → 自愈退化 → 启动退避
- **形态**：作者令"从第一性原理出发自己定计划"。全量通读 74 个受版本控制文件（45 Swift / 18,815 行 + 6 shell + CI + docs）后按目的函数（min 过冲/磨损/能耗/热误差，max 泛化/数据可信/可用性）选题，结论：**最高杠杆不在控制律**（"无 ≥7 天真机账本不动控制律"仍成立，dt 受控时长 ~3 天），而在 R33 未修清单里"状态与指标会说谎"那一类。
- **五修（逐条改前→改后 + 变异证据）**：
  1. **睡醒假 controlFault（B）**：`wake()` 原只复位 stuckDetector/AI 控制器，`WriteHealth`/`FanFeedbackHealth` 带着睡前的故障锁存、`lastCommanded`、`lastActualRPM`、`faultStreak` 进入新会话 → 醒后首拍即可判 mismatch（交还 + 学习采样被排除）。改 = 两者各加 `reset() { self = .init() }`（整值复位；逐字段重置正是 F9"漏一个字段静默失效"的温床）+ `wake()` 调用。**变异**：删 wake 里两行 reset → 引擎断言红（观测面是 `status.controlFault`，非 `F0Md` 写次数——R24b 已证后者不判别）；单元另锁"reset 后首拍是宽限拍"，漏 `warmedUp` 复位会早一拍红。
  2. **history 一次局部损坏抹掉 30 天（C1）**：整表解码失败 → `nil → []` → 下一次 `archiveDay` 用空表覆盖 = 归档全灭。改 = 坏文件仍按既有协议备份，然后逐元素 re-encode 单独解码，坏 1 天丢 1 天，日志"逐日恢复 N/M 天（丢弃 K）"。**变异**：salvage 退化为 `return []` → 5 条红（含"archiveDay 后 3 天俱在"）。
  3. **AI 评测按样本平均偏袒繁忙段（C2）**：`averageTemp/stdDev/averageOutput` 分母是 sampleCount，而自适应 1–20s 拍下"繁忙=快拍=样本多"→ 系统性高估均温与波动（与 v2.6.2 在 `DailyStats.avgTemp` 上用 tempSeconds 修掉的是同一类口径错误）。改 = 新增三个 Optional 秒加权累加器（合成 Codable 对旧文件解出 nil → 自动回退样本口径），分母改 `activeSeconds`。**口径变更记账见下**。**变异**：去掉 sanitized 对加权键的钳位 → 1 红（"加权巨值被钳位"）。
  4. **落盘失败仍清 dirty 旗（C3）**：`enterSleep/shutdownSave` 原先丢弃 save* 返回值 → 入睡/退出那一刻的样本静默丢失。改 = `flushAll()` 失败置脏旗让主循环下个节流周期重试 + 边沿日志 `persistenceFailedLogged`（**静默降级可以，静默失效不可以**）；dirty 旗改 `public private(set)` 供引擎测试观察（同 thermalLearn/aiMetrics 惯例）。**变异**：3 红。测试阶段设计要点：学习发生在落盘之前，必须在"失败日志刚出现"那一拍冻结学习，才能把"保留脏旗"与"清旗后靠新样本重新置脏"两种实现区分开。
  5. **配置损坏自愈抹掉用户意图（D1）+ SMC 启动竞态（D2）**：`loadConfig` 解码成功即滚动写 `config.last-good.json`（同 fd 纪律、同 664/root:admin → **不新增提权面**：能污染它的人本就能直接写 config.json）；损坏时按 **last-good → 默认** 恢复。**变异两处**：移除滚动写 → 7 红；绕过恢复分支 → 5 红。`bootstrapSMC` 进程内有界退避重试 3 次（0/2/8s）替代"一次失败即 exit(1)"（那是 KeepAlive + ThrottleInterval=10 下"每 10s 全量扫描→退出"的静默循环），原因留档 `exit-reason.flag` 由下次启动读出并删除。
- **写盘纪律单实现化**：saveConfig 的 fd 序列（`O_CREAT|O_EXCL` 临时 + `fchmod 664` 穿透 umask + EINTR 重试写 + root 时 `fchown admin` + `rename` 永不跟随符号链接）抽出 `ConfigStore.writeAtomicFD`，last-good 复用同一实现——两处各写一遍正是 R23 修的提权原语重新长回来的地方。
- **验证**：fanctltests **4719 断言 / 81 组全绿**（R34 的 4646/77 → +73 断言 / +4 组，其中两路独立审查追加 +22）；契约门槛双源同步 4550→**4600**、minGroups 75→**79**；`./scripts/build.sh` 全链路 EXIT 0、dist 三产物 codesign ok（App 身份 4.1.4/89）；`test-root-scripts.sh` 24 通过 / 0 失败（含发版链修复新增的多字节邻接静态门，见下）；清掉全部编译代码警告（ThermalLearn `var sortedBase`→`let`；TestsCore `()?` 推断的 `w1`；TestsEngine 从未使用的 `w1`——R34"零代码警告"状态的续作）。
- **顺带抓到一处测试基座说谎（R35 尾巴）**：断言总数在 **4690/4696 之间随机漂移**（12 次跑 3 次低 6）。定位法：临时给 harness 的 `group()` 记累计断言数、多次跑取差分（注意差分归属的是**上一组**，标签会错位）。根因在 `testThermalModel`：`stuck` 模型用**未播种** `Double.random` 喂弱风量样本，`if stuck.b <= 2.5 { …6 条断言… }` 一旦不成立整段**静默不执行**——R29 的 `b>2.5` 诚实门（isMature/预测 nil/可重置）在某次 CI 里根本没跑过，而徽章照样绿。改 = 确定性伪随机序列 `(i*37)%81` + 把 `b≤2.5` 变成**显式断言**、段内 6 条无条件执行 → 6/6 次稳定（当时 4697；审查轮补完回归后 4719）。教训：**测试里的 `if <实现算出的值> { 断言 }` 与"注释描述行为"同罪**——它让覆盖率变成随机数；条件成立与否本身必须是断言。
- **口径变更（跨版本比较失效，必须记账）**：4.1.4 起 AI 评测的均温/波动/均输出为**秒加权**。升级前后窗口的数值不可直接比较（同窗口内始终可比；旧账本文件解码后自动走样本口径）。本文件历史条目里引用的 stdDev/均温数字保持原样不改写——它们是样本口径产物。
- **两条否决（进失败账本）**：support 目录 `chmod 1775`、`fanctld` engine 延迟初始化 + 常驻重试。理由见失败账本 R35 两行。
- **批次 A（提权信任根）未开工，按计划独立发版 4.2.0**：R33 P1 清单里"bundle 内 `uninstall.sh`/`upgrade.sh` 被文档/UI 推 sudo 执行 + App 内嵌 base64 脚本随 `chown -R` 用户可写"**仍开放**——这是本仓当前唯一的同 uid→root 链，需要一次性迁移（旧 App 的内嵌脚本没有装 root 脚本的逻辑，Release zip 此前也不带 `upgrade.sh`），故不与 4.1.4 混发。
- **R35 审查轮（两路独立对抗审查 + 逐条人工核实）**：两路分别攻「数据口径/可靠性」与「提权信任面/文档一致性」→ **8 项成立并修**（4697→**4719 断言**，每处新回归都做过"删掉修复即打红"的变异验证）、**3 项证伪**（把不存在的代码当成缺陷）、1 项记为已知边界：
  - **修①（P1）秒加权在跨版本混合账本上必然给错值**：分母用了 `activeSeconds`（含升级前全部秒），而加权和从 0 起步——旧 ai-metrics.json 载入后第一拍 `record` 就让加权键由 nil 变非 nil，`averageTemp = 新拍加权和 /(旧 604800 秒 + 新秒)`，真机量级给 **0.46°（实际 78°）**，且被 `saveAIMetrics` 持久化、只有换目标档才清零。改 = 第四个可选累加器 `weightedSecondsTotal`（四元组同拍累加、共用一份分母），`weightedSpan` 为 nil 时各视图才回退样本口径。**变异**：分母退回 activeSeconds → 3 红（18.0 vs 78.0）。**我上一轮的"证伪"是错的**：当时只查了"无部分扣减路径"，漏了"nil→0 起点 + 旧秒做分母"这条，见下方证伪①的更正。
  - 修②（P2）last-good 存**消毒后字节**：`refreshLastGoodConfig(FanConfig)` 重编码 `sanitized()` 结果（与 saveConfig 同 options）——"能解码"≠"可用"，组内用户直写 `manualPercent=450` 解码成功，原样进副本等于把越界配置预备成将来的"好消息"。变异：退回原始字节 → 2 红。
  - 修③（P2）last-good **写失败必须留话**：原实现丢弃 `writeAtomicFD` 返回值，磁盘满时"有副本可回"的承诺静默失效。现失败打一条 NSLog；单槽/无代际记为已知边界（多槽是另一个决定，不在本轮扩）。
  - 修④（P2）唤醒保留**故障退避记忆**：`FanFeedbackHealth.resetForWake()` 与 `reset()` 唯一差异是保留 `faultStreak`——streak 是"这把风扇反复故障过"的跨会话判决，不是睡前的瞬时测量；清零等于让 R24b 的 3→48 拍退避在笔记本上每个 sleep/wake 归零重来。安全向核对过：保留 streak 只让解除更慢，期间系统调度兜底，不欠冷。**变异**：resetForWake 退回整值复位 → 2 红。
  - 修⑤（P3）`salvageHistory` **元素级 cast**：原 `as? [[String: Any]]` 是整表转换，数组里混进一个标量/null 就整体失败、好日子全丢——恰在"逐日抢救"最想救的形态上失效。补 `[day, 42, "junk", null, day]` 回归；变异：复现整表语义 → 2 红。
  - 修⑥（P3）临时文件清扫**按家族白名单**：`cleanupStaleConfigTemps` 更名 `cleanupStaleTemps`，判据从 `hasPrefix(".") && contains(".config.")` 改成三条精确前缀（config / config.last-good / exit-reason）——`writeAtomicFD` 泛化后 exit-reason 的临时件原本永不清扫，而旧判据又能误删组内命名的 `.not-ours.config.json`；清扫调用同时**提前到 SMC 引导之前**（否则退避循环根本走不到它）。变异：退回旧判据 → 2 红。
  - 修⑦（P3）`exit-reason.flag` 两处写改走 `writeAtomicFD`（不再绕过 R23/R28 的 fd 纪律）；`loadConfig` 损坏备份改复用 `backupCorrupted`（内联版用秒级时间戳，同秒二次损坏被 O_EXCL 拒写丢证据）；`archiveDay` 不再丢弃 `saveHistory` 返回值（失败打日志）。
  - 修⑧（P3）`b≤2.5` 断言余量：确定性改写只走到"能复现"，审查实测 200 轮 b=2.44 距门槛 0.06——任何常量改动都会让段内 6 条断言静默失踪。轮数 200→1200（b≈0.94，余量 64%）。
  - **更正·证伪①（原判"不成立"，复审推翻）**："污染清洗路径不做秒加权记账"——清洗确实只整体替换 `AIControlMetrics`（无部分扣减路径，这点当时核实无误），但同一处的 `activeSeconds` 跨升级存活恰好构成 P1（见修①）。**教训：证伪一条指控不等于被指控的机制没问题**——我核了"没有部分扣减"，没核"分母与分子的覆盖域是否同段"。
  - 证伪②："FanCtlApp 的 `#if RELEASE` 门失效"——App 目标内 `#if` 出现 **0 次**，合成遥测由 `--snapshot` 参数门控（参数门比构建配置门更难在生产路径误触发）。
  - 证伪③：`install.sh` 的 `.permission-fix-hint` 写点不存在（全仓 grep 无该文件名）。
  - 已知边界（记账不修）：其余六处 root 侧 `Data.write(.atomic)`（status/stats/history/learn/model/ai-metrics）仍是 umask 决定的 mode 且不归组 admin——`.atomic` 的 rename 不跟随符号链接故无 R28 类提权面，差异只在权限位；ENOSPC 下这些路径泄漏的临时件不在清扫面内。
  - **元经验**：11 项指控里 3 项是把不存在的代码当成缺陷（含一处"实测得 nan"的假证据），**但另一路的 P1 恰好推翻我这边的证伪**——独立审查的产出必须逐条核实才能进修复清单，而"核实"要核到机制的覆盖域，不能只核提问的字面。
  - 修①（P2）**last-good 存的是消毒后字节**：原实现把 `Data` 原样滚动进副本，而"能解码"≠"可用"——组内用户直写 `manualPercent=450` 解码成功，就等于把越界配置预备成将来损坏时的"好消息"。现 `refreshLastGoodConfig(FanConfig)` 重编码消毒结果（与 saveConfig 同 options，正常态两份字节一致）。
  - 修②（P3）**salvageHistory 元素级 cast**：原 `as? [[String: Any]]` 是整表转换，数组里混进一个标量/null 就整体失败、好日子全丢——恰在"逐日抢救"最想救的形态上失效。改 `[Any]` + 逐元素 cast；新增 `[day, 42, "junk", null, day]` 回归。
  - 修③（P3）**exit-reason.flag 走 fd 纪律**：两处 `Data.write(.atomic)` 换成 `ConfigStore.writeAtomicFD(mode: 0o644)`（`.atomic` 用进程 umask 建临时文件，且整个 R23/R28 的 `O_EXCL|NOFOLLOW` 面被绕过）。
  - 修④（P3）**b≤2.5 断言的余量**：确定性改写只走到"能复现"，审查实测 200 轮 b=2.44 距门槛 0.06——改任何常量都会让段内 6 条断言静默失踪。轮数 200→1200（b≈0.94，余量 64%）。
  - 证伪①：**"污染清洗路径不做秒加权记账 → stdDev NaN"** 不成立。全仓 `temperatureSum` 的写入点只有 `record()`（六个累加器同拍更新）与 `sanitized()`（成对钳位），AIControlMetrics 只做整体替换（`ControlEngine:191/1082`），没有任何部分扣减路径；且方差走 `sqrt(max(0, …))`、均值分母有 `sampleCount > 0` 守卫。
  - 证伪②：**"FanCtlApp.swift 的 `#if RELEASE` 门失效"** 不成立——仓库内 `#if RELEASE`/`#if DEBUG` 出现 0 次，合成遥测由 `CommandLine.arguments.contains("--snapshot")` 门控（参数门比构建配置门更难在生产路径误触发）。
  - 证伪③：`install.sh` 的 `.permission-fix-hint` 写入不存在（全仓无该文件名的写点）。
  - **元经验**：独立审查的产出必须过"逐条核实"这一关才能进修复清单——本轮 7 项里 3 项是把不存在的代码当成缺陷（含一处"实测得 nan"的假证据）。指控要能被 grep/复现反驳，否则修的是想象。
- **发版链三次翻车（4.1.4(87)→(88)→(89)，同日，同一打包步）**：tag 触发后 Release 作业连着红三次，三个根因互不相关——"修发行链的补丁本身也要走同一条链验证"这条不是口号：
  1. **产物目录硬编码**：`cp: .build/release/fanctld: No such file or directory`。runner 走新构建后端（SwiftBuild），产物在 `.build/out/Products/Release`，`.build/release` 只是旧 llbuild 路线留的兼容副本；**本机两条路径都存在**——于是本地绿、runner 红。
  2. **`$VAR` 紧跟全角标点**：第 1 次修复新加的缺产物守卫又红——`build.sh: line 116: f…: unbound variable`，出处正是 `echo "❌ 缺少产物：$f（SwiftPM …"`。用 `/bin/bash` 3.2.57 配 `LC_ALL/LANG` 取 C/POSIX/ANSI_X3.4-1968/空环境**全部复现不出**（本机 bash 能正确终止变量名），但结论一样：发行路径不赌任何 shell 的多字节邻接行为。修 = 关键消息一律 ASCII、变量一律 `${VAR}`；扫全仓同型另两处（`deploy.sh` 的 `$DIST_APP，`、`install.sh` 的 `$PLIST）`——后者正好落在 LaunchDaemon 注册失败的错误分支里，最需要它开口的时候）；并加**静态门**（`test-root-scripts.sh` 第 24 项，由 `TestsUpgrade.testRootScriptGates` 随每次 `fanctltests` 跑到）。
  3. **"半问" show-bin-path（第 2 次修复自身的不严谨）**：`swift build --show-bin-path` 不带 `--target` 时，runner 答 `.build/arm64-apple-macosx/release`，而 `--target fanctld` 的产物不在那儿；本机恰好相反（答 `.build/out/Products/Release`，与 `--target` 产物同目录）——所以本地又全绿。**问的问题必须与构建的问题同构**：新 `artifact()` 用同一组 flags（含 `--target`、`--scratch-path`、钉住的 `SDKROOT`）问路径，问不到再到对应 scratch 里按 mtime 取同名可执行件（刚编的一定最新），两条都不中即响亮失败。
  - 新增**发行链自证门**：组装完必须能回答"dist 里是不是本次代码"——`dist/fanctld -v`、`Info.plist` 的 `CFBundleShortVersionString/CFBundleVersion` 三方对齐 VERSION，不中即 exit 1。**变异证据**：把期望值改成带 MUTANT 的字面量 → `build.sh` EXIT 1 报 mismatch；恢复 → EXIT 0。它防的是比报错更糟的形态：静默拷进一个陈旧的中间件（R12"同号不同码"的发行版翻版）。
  - 冷编译验证（清空 `.build` 与 `.build-app-sdk`）：三产物分别落在 `.build/out/Products/Release/{fanctld,fanprobe}` 与 `.build-app-sdk/out/Products/Release/FanCtlApp`，自证门通过；4719 断言 / 81 组绿，root 脚本门禁 24/0。
  - build 号 86→87→88→89：每轮 CI 构建的代码状态都与上一同号不同，同号即"同号不同码"。
  - **元经验**：本地绿与 Release 绿之间没有蕴含关系，而且"绿"的粒度要对齐——`swift build` 的产物目录、shell 对多字节邻接的解析、同一命令在不同构建后端下的解释，全都属于发行面。凡只有 CI 才暴露的环节，就该在链上装一个能自证的门（这次是版本三方对齐），而不是等下一次红。
- **真机待验（作者执行，AI 不碰 sudo）**：装 4.1.4 后走一轮睡眠/唤醒，看 status/`fanprobe` 是否仍打 `controlFault`；手工截断一次 config.json，看是否回 last-good 而非出厂默认。

### R34（4.1.3(85) 全面自审 + root 门禁可移植性修复）：测试基座误导性红根修
- **形态**：作者令「从第一性原理出发自己审查、执行、最终检查、做成品」。五路复审（安全提权 / 控制安全 / 数据诚实 / 升级发行 / 性能可靠）+ 基线回归对比。R33 五路阻断项均已在 (84) 修复面内，本轮生产代码无新缺陷。
- **唯一红项根因**：`test-root-scripts.sh` 硬编码 `mktemp -d /tmp/...`——/tmp 只读的受限环境下 mktemp 直接失败，`set -e` 让整个 root 门禁跑不了，红诊断报「输出缺少汇总行」而非真实原因（误导性红，掩盖真实失败点）。修复：暂存跟随 `$TMPDIR`（macOS 惯例），`${TMPDIR:-/tmp}` 保底。负控双向验证：`TMPDIR=/System`（只读）与 unset TMPDIR 均显式报 mktemp 失败，失败点不再被吞成「汇总行缺失」。
- **顺手修**：TestsEngine / ThermalLearn 各一处 `var` 从未变异 → `let`，清掉仅有的 2 处编译代码警告（余为 SwiftPM 官方弃用提示，非本仓代码）。
- **全量验证**：fanctltests 4646 断言 / 77 组全绿（修复前 2 项失败：「root 脚本门禁全绿」「输出缺少通过/失败汇总行」，同根因）。
- **明确不做**：批次 B 控制律延后口径不变（数据不全不调参）；FanCtlApp 内 /tmp 调试快照导出路径未动（用户主动触发的诊断用途，真实机器 /tmp 可写）。

### R33（4.1.3(84) 多维度全面审查 + 阻断项修复）：安全/控制/数据/升级/性能五路对抗审查
- **形态**：作者令「从每个方面出发仔细自查」。五路独立审查（安全提权 / 控制安全 / 数据+测试 / 升级发行+运维 / 性能架构可靠）+ 主代理对账。**未改批次 B 控制律**；安全向欠冷修复按 P5（欠冷更贵）落地。
- **总判**：架构/内存/崩溃面大体健康（性能路 APPROVE）；**安全路 BLOCK、控制安全 BLOCK、数据诚实 BLOCK、发行首装 BLOCK**。下列 P1 已修，其余进账本。
- **本轮已修（P1/高杠杆）**：
  1. **控制安全**：`ThermalModel.predictedPercent` 在 `need≤0` 时返回 **nil**（不再合法 0%——`.some(0)` 会短路 `learned??curve??seed` 静默欠冷）；AI 播种/升温前馈跳过 ≤0 的 learned/curve（优先级不变）。
  2. **发行首装**：`install.sh` 产物根随布局自适应（zip 与仓库树）——原先固定 `../dist` 使 Release 包 `sudo ./install.sh` **永远装不上**。
  3. **发行首装**：`install.sh` 复制后 `xattr -dr com.apple.quarantine`（与 upgrade 对齐，否则 Gatekeeper 拦首次打开）。
  4. **安全**：osascript 路径/提示含 `"` `\` 换行时**拒绝提权**（堵 AppleScript 字符串闭合注入）；watcher 窗 120s→900s（覆盖输密码）。
  5. **卸载完整**：`uninstall.sh` 删除 `/usr/local/bin/fanprobe`。
  6. **测试契约**：CI 断言下限 4400→**4550**（与源码门一致）。
- **验证**：fanctltests **4646 断言 / 77 组全绿**（含 need≤0→nil、learned=0 不短路曲线）。
- **P1 未修（进账本，需架构/信任根，禁止静默当已修）**：
  - 安全：用户可写 bundle 内 `uninstall.sh`/`upgrade.sh` 被文档/UI 推 `sudo` 执行（R23 同类）；App 二进制内嵌脚本仍随 `chown -R` 用户可写（信任根未立）；sha256 校验→`install` 按路径 TOCTOU；`/usr/local` 符号链接种植；config chown/chmod shell check-then-act；损坏备份可把 root 文件泄给 admin 组。
  - 控制安全：env−12 仍最长 90s 盲窗；SSD/battery 70/45 **guard 不进 manual**（仅 78/48/92 红线）；NAND 传感器失效时托底静默关闭；`wake()` 不重置 FanFeedbackHealth（睡醒假 controlFault）；controlBlocked 期间红线非连续写。
  - 数据诚实：history 整文件解码失败即清空 30 天归档；AI `averageTemp/stdDev` 未按时间加权（自适应拍下偏繁忙段）；`learnedPoints` 与 `percent(for:)` 包络范围不一致（展示≠控制）；`speedChangesPerMinute` 分子/分母域不一致。
  - 可靠：save* 返回值被忽略仍清 dirty；非 config 写路径无 EINTR 重试；SMC init 失败 × KeepAlive=10s 崩溃循环；config 损坏自愈写默认值（销毁 last-good）。
  - 运维：issue 模板不收 fanprobe/status；badge 步骤可绿洗红构建；Release zip 无信任根（R23 已知）。
- **方法论**：审查必须按攻击面提问「最坏热后果 / 同 uid 能否 root / 指标会不会说谎 / 首装是否真能装上」；测试失败即语义门有效（seedChoice 曾改过头 max 越权，红测打回只堵 0% 短路）。

### R32（4.1.3(83) dogfood 初裁 + 磨损口径可观测）：80–82 观测收口；批次B控制律仍延后
- **真机证据（82 连跑 ~3 天后，2026-09-21）**：
  - `controlFault` 无锁存；空闲↔负载起转、睡眠/唤醒/电池切换正常（R25 假故障 dogfood 通过）。
  - R31 诊断字段在 status 可用：`thermalModelUsable=false` / `b=1.00` / 样本曾达 288+（与 R29 诚实门一致）。
  - dt 账本受控 **2.95 天**（<7）；快拍秒占比 **9.9%**（>5%）。4.1-E 已预注册关闭「不改秒基」，形式确认未开、不阻塞。
  - `learnEnvelopeGap` 安装前 raw 为 **12.18**（75° raw 87.8 < 73° raw 100，trusted 非单调）；lookup 层 R27 单调包络仍把控制读到 100%（P5 向上取 max）。
  - 磨损速率（R29 口径 `speedChanges/tempSeconds`）近 14 天约 **3.2–16.4 次/受控分**，与日间负载/拍频共变；**无预注册阈值**支撑立刻改死区/拍频。
- **决策（沿 R30）**：批次 B 控制律（舒适带死区/更长拍）**继续延后**。遵守失败账本与「无预注册不动控制律」。继续用 `fanprobe` 趋势 + dogfood，不单日绝对次数裁决。
- **落地（诊断/可观测，零控制律改动）**：
  - `fanprobe`：今日 `speedChangesPerMinute` + 近 14 天磨损速率趋势（按日期排序防脏 history）；热模型文件明细（a/b/样本/采信带/mature）。
  - `build.sh`/`install.sh`/`upgrade.sh`：`dist/fanprobe` + `/usr/local/bin/fanprobe`；自升级路径若暂存包带 fanprobe 则同步安装，未带则跳过不阻断。
  - `DailyStats.speedChangesPerMinute` 补单测（防抖/拍频归一/非有限值）。
- **83 启动即验（osascript 安装）**：日志 `热模型 b=1.00 未收敛（样本 301），已重置辨识` + `清洗 13 个污染桶（环境 31°C）`；重启后内存热模型 `b≈5.8`（样本 4，尚未 mature）——R30 重置对「RLS 协方差坍缩」有效，长跑贴地后须重启才重辨识。包络 gap 降至 **2.4°**（sanitize 洗掉污染桶；**不做数据手术**，继续观察）。风扇实际 RPM 跟随目标；无 controlFault。
- **验证**：fanctltests **4642 断言 / 77 组全绿**；真机 App+daemon+fanprobe 均为 **4.1.3(83)**。
- **独立对抗审查（推送前）**：**APPROVE（无 P1）**。确认 diff 零控制律文件；`speedChangesPerMinute` 单测有牙（删属性 6 断言红）。P2 已修：Release zip / `upgrade.sh` 原先不装 fanprobe——`ci.yml` 发行物补 `dist/fanprobe`，`upgrade.sh` 暂存包带则装、不带则跳过；`install.sh` 缺 fanprobe 时告警。P3 已修：磨损趋势文案改为「近 14 归档日 + 今日实时」（避免 15 行被读成「14 天」）；fanprobe 读 history 先按日期排序。残余：CI 徽章契约下限 workflow 仍 4400、源码门 4550（历史遗留，非本轮引入）；App 内嵌 upgrade 脚本随下次 build.sh 再生成同步。

### R31（4.1.3(82) 观测）：status 热模型诊断 + fanprobe 生效查表
- **背景**：R29/R30 已让 isMature 诚实、启动重置贴地模型；诊断仍要读磁盘 JSON。dt 账本受控仍 <7 天，形式确认未开。
- **改动**：DaemonStatus 可选字段 thermalModelUsable/B/Samples（decodeIfPresent 兼容旧包）；ControlEngine 每拍下发；fanprobe 打印热模型可用性 + percent(for:) 生效查表与 raw 采信桶。
- **决策不变**：磨损控制律延后；dogfood 继续。

### R30（4.1.3(81) 自主决策）：热模型卫生重置；磨损控制律明确延后
- **真机采样（约 20×4s）**：loopInterval 为 3s/10s/20s 混合（AI 空闲已自动拉长），applied 可降到 0（交还）。**不支持**立刻为降 speedChanges 改 AI 死区/拍频——绝对次数受日间高拍时段影响，当前空闲拍并不密。
- **决策**：批次 B 控制律（舒适带死区/更长拍）**延后**；先看 80/81 dogfood 与 `speedChangesPerMinute` 趋势。遵守失败账本与「无预注册不动控制律」。
- **落地**：`ThermalModel.resetIfUnusable`——启动时 `b≤2.5` 且样本≥min 则整模重置并打日志；预测本已 nil，不改控制。与 R29 `isMature` 共同避免假成熟。
- **卫生**：清理已合并的 `.worktrees/r25–r29` 与 compose/tmp 分支。

### R29（4.1.3(80) 批次A 快赢）：诚实化 + 升级门禁 fail-closed + 工程债
- **ThermalModel.isMature**：改为 `sampleCount≥min && b>2.5`（与 predictedPercent 同门）；真机 b=1.0、样本 2500+ 时不得再称「模型成熟」。单测锁收敛模型 mature + b 贴下限 not mature。
- **upgrade.sh fail-closed**：缺 TAG/daemon-sha/app-sha 一律 exit 3，禁止手动路径跳过门禁；test-root-scripts +2 条。
- **install.sh App 属主**：无 SUDO_USER 时取 console 用户 chown，恢复 deploy.sh 免密通道（osascript 安装曾把 App 留在 root:admin）。
- **powermetrics 单侧日志**：仅「曾有分项值 → 过期」才打日志（GPU 空载无效读不再刷屏）。
- **README** 断言文案改引徽章；契约下限 4400/70 → **4550/75**。
- **DailyStats.speedChangesPerMinute**：磨损速率口径（次/受控分钟），供对比不同拍频时段。

### R28（4.1.3(79) 安全 P1）：损坏备份 O_EXCL|O_NOFOLLOW——闭合 admin 组符号链接静默提权
- **全维度巡查发现**：support 目录 `root:admin 775`，损坏备份用路径式 `Data.write` 会跟随符号链接；admin 组进程可预置 `config.corrupted.<epoch>.json` 等链接 + 弄脏 config → root 把任意字节写进链接目标（LaunchDaemon/cron 等），绕过 Authorization Services。saveConfig 已是 fd 纪律，**备份路径是同源原语的漏网实例**。
- **修复**：`FanCtlPaths.writeNewFileExclusive`——`O_CREAT|O_EXCL|O_NOFOLLOW` + `fchmod` + EINTR 重试 write；目标为链接或已存在则失败（只损失备份可观测性，主路径仍回默认配置）。`loadConfig` 与 `loadCorruptionAware` 全部改走该原语。
- **测试**：`testCorruptionBackupNoFollow`——正常新建 / 符号链接拒绝且 victim 未污染 / O_EXCL 拒覆盖 / 损坏 config 回默认。
- **验证**：fanctltests 全绿（合并后计徽章）；真机经 osascript 安装。

### R27（4.1.3(78)）：L1 dogfood 初裁 + L3 集成对抗审查修正
- **L1 初裁（77 真机，安装后 ~15h）**：P1 门通过——启动试探一次交还后 AI 正常，`controlFault` 无永久锁存；睡眠/唤醒/电池切换无异常；包络 trusted 桶**存在** 69°=96.6%>73°=84.3%（修订 R26「无污染」表述）；R26 powermetrics 日志在 77 后无「连续 1 次」刷屏。
- **L3 独立审查**：PASS-WITH-NOTES、无 critical。落地修正：
  - **F1** `FanFeedbackHealth.riseOnlyGraceMaxBeats=12`：滞后路径仅靠 `rpmRising` 的 matched 连续封顶，退化扇无界爬升不再永久算响应。
  - **F2** `StatsSampler.tempPlausible`：有环境时 `temp >= env-12`（与控制偏低门同源）；无环境时 `temp>=15`（排除 cpuDie≈8）；**101.9 热峰保留**（R26 误把真实峰值当坏点）。
  - **F3** ThermalLearn 查表单调化扩到**全温域**（只向上取 max，P5）；`envelopeGap()` 统计口径仍 ≥75° 不改写观察协议。
  - **F4** `record(countsRecover:)`：试探写入拍不计自解进度，避免削弱 3 拍验证窗。
  - **F6** probe 写入成功即 `forcedModeActive=true`，验证失败可无条件 `restoreAutoAll`。
  - **F7** 单侧 powermetrics 连续 3 次无读数时记一条过期日志。
- **验证**：4616 断言 / 76 组全绿。

### R26（4.1.3(77) 细节打磨）：战报温度门 + powermetrics 日志诚实化 + 包络观察关闭
- **数据驱动选题（真机 76 dogfood 快照）**：①学习表 trusted 桶**无**非单调污染（更高温桶输出未显著更低）——4.2-B 关闭，gap=2.09 是冷启动双峰重建非污染，**不手术**；②日志见 powermetrics 反复「连续 1 次」失败（信息量与实现颠倒：首败才打日志、真过期反而静默）；③今日战报 maxTemp≈101.9°C（05:59Z）——控制路径红线另算，但曲线优化器吃 stats 分位数，坏点会污染底座。
- **StatsSampler 温度合理性门**：`tempPlausible` = 有限且 (0,125]°C；门外跳过 maxTemp/高温秒/直方图/均温分母，功耗/转数/调速计数照旧。单测锁门外读数不抬峰值、不进分母、转数仍计。
- **PowerCompositionSampler 日志**：只在「双侧连续 3 次失败 → 分项过期」边沿打日志，恢复时打恢复条；删除首败「连续 1 次」误导文案。静默降级可以，静默失效不可以——但**日志应对准失效边沿**。
- **验证**：fanctltests 全绿（工作树）；安装走 osascript 提权（用户无终端）。

### R25-L2（4.1.3(76) 真机已装 + 变异测试门）：对抗式审查第一层落地
- **升级**：osascript `administrator privileges` 把产物装到 /tmp 后安装（Documents 下 elevatd shell 被 TCC 拒：`Operation not permitted`）。真机 App+daemon 均为 **4.1.3(76)**，fanctld pid 已换新。验收快照：`controlFault=None`，但 fans `targetRPM≈3k` / `actualRPM=0`——正是 R25 目标场景（高目标+停转中），**未见假 controlFault**（dogfood 观察窗仍开放）。
- **L2 定向变异（基线 main@37d22f6，套件 4592→补测后 4595）**：
  | 变异体 | 结果 | 杀手 |
  |---|---|---|
  | M1 stall 路径去掉 rpmRising | 初版 **SURVIVED** → 补「停转区 0→80」用例后 **KILLED** | 新单测 |
  | M2 lagging 路径去掉 rpmRising | KILLED | 引擎场景 12 |
  | M3 recordCommandOnly 不写 lastActualRPM | KILLED | 升后停住 fault |
  | M4 热身拍不写 lastActualRPM | 初版 **SURVIVED** → 与 M1 同门 **KILLED** | 新单测 |
  | M5 spinUpDeltaRPM=10000（永不宽限） | KILLED | 引擎场景 12 |
  | M6 rpmRising 语义反转 | KILLED | 族扫描真停转捕获 |
- **净分：6/6 变异体被杀**（补测后）。教训：**「删除本改动后哪些测试会红」是控制律 PR 的必答题**；M1/M4 存活说明「有 71 场景单测」≠「stalled/热身路径有门」。
- **对抗式审查策略（升级后）**：不做第四轮全库静态扫（边际 < ε）。三层 = L1 真机 dogfood 预注册裁决（主闸门）+ L2 变异门（本轮已闭环）+ L3 等真机数据后再审 23..R25 交互面。

### R25（4.1.3(76)）：起转宽限——stalled 判据区分「起转中」与「真停转」
- **形态**：compose-next（`docs/compose/spec/r25-stall-spinup-grace.md`）。Grill 方向：RPM 上升即不判 stalled/不计 mismatch；**不**做试探窗全面 risingGrace（削弱真故障探测）、**不**做时间基宽限。
- **设计**：`FanFeedbackHealth.lastActualRPM` + `spinUpDeltaRPM=50`。高目标风扇若 `actualRPM` 较上拍上升 >50 → 不算 stalled；滞后路径在 `risingGrace=false`（试探窗）下同样把 RPM 斜坡计为响应。恒 <100 / 恒低速不升 / 升后停住仍 fault。R24b 自解、streak 3→48、R24c AND 归零一律未动。
- **动机**：71 真机证伪后 R24b 只保证「假故障可自解」，空闲停转→负载起转仍会误打 controlFault（交还、学习中断、噪声）。根因是 stalled 与 lagging 在试探窗内无法区分物理爬升与真死扇。
- **测试有效性（审查 F1 收口）**：初版单测 71 ramp（200→4000）在预 R25 下只累计 4 拍 mismatch 后进入非滞后区、`consecutiveFailures` 归零——删宽限单测仍绿。审查指出后把 ramp 拉进滞后窗（200…2800）逐步 `expect(!faulted)`，并补独立试探窗 rising RPM 用例。**引擎场景 12 才是真门**：85°C balanced 首拍即满速（smooth 冷启动=raw、shape 首写无限速），旧实现恒高目标下 stall+4 拍滞后共 5 拍 → controlFault。
- **验证**：fanctltests **4592 断言 / 76 组全绿**；非 UI release 编译过；独立审查 PASS-WITH-NOTES、无 critical。`lastActualRPM` 三路径齐写（热身/record 后全量/recordCommandOnly）。
- **元经验**：① 单测「不 fault」若 ramp 太短会在滞后窗结束后被「跟上」清零计数，必须让有害帧数 ≥ faultThreshold 才构成回归门；② 控制律类改动的审查要问「删除本改动后哪些测试会红」——绿套件本身不能证明门有效；③ 4.2-A dogfood 仍开放：真机此前停在 72，合并 76 后才谈部署观察。

### R24d（4.1.3(75)）：root 脚本门禁可测化——upgrade.sh/install.sh 零测试债务收口
- **动机**：R23 P1-A（tag 带 v → 一键升级 100% exit 3）8 个 Swift 断言全绿仍漏，根因是 shell 层零覆盖；R23 续轮点名「root 脚本纯 shell 逻辑零测试」为基建债。
- **实现**：`upgrade.sh` 加 `FANCTL_TEST_GATES_ONLY=1`（跳过 EUID，只跑授权前门禁后 exit 0，不碰 launchctl/系统路径）；`install.sh` 抽 `fanctl_config_perm_safe` + `FANCTL_TEST_CONFIG_GUARD=1`。`scripts/test-root-scripts.sh` 21 条：暂存完整性 exit2、P1-A v 前缀 exit3、版本不符、sha256 双侧+偷换 TOCTOU、marker 符号链接 exit4+victim 不截断、config 符号链接/悬空/缺失谓词、内联 `! -L` 静态锁、bootstrap 失败致命。由 fanctltests `testRootScriptGates` 以 Process 调起（断言 ≥15 用例、失败数 0，防脚本被掏空）。
- **测试当轮抓到真 bug**：`$TAG（授权…）` 全角括号被 macOS bash 并进变量名 → `set -u` 下 mismatch 路径变成 `TAG\xef: unbound` exit 1（**而非设计的 exit 3**）。生产因 P1-A 修复后恒传匹配 tag，此路径从未触发，潜伏至今。修 `${TAG}`；deploy.sh 同类 `$LEGACY（` 一并修。元经验：**shell 里 `$VAR` 后紧跟全角标点必须写 `${VAR}`**。
- **验证**：test-root-scripts.sh 21/21；fanctltests 4562 断言 / 76 组全绿；UpgradeScript 占位与 upgrade.sh 严格同步。

### R24c（4.1.3(74)）：streak 归零 OR→AND + 封顶单测
- 收口 R24b 审查记账：多风扇 `matched` 原为 OR，一坏一好机上健康扇会顶掉坏扇退避。改为**全部高目标风扇均 matched（AND）**才归零；空命令拍不归零（恢复进度 ≠ 跟随证据）。
- 补 streak=1..6 阈值序列单测（锁 3/6/12/24/48/48 封顶）与双风扇 AND 回归。4558 断言 / 75 组全绿。

### R24b（4.1.3(73)）：非锁存退避——振荡抑制改走「自解永在 + streak 指数退避」
- **形态**：compose-next 规格化交付（`docs/compose/spec/r24-nonallocking-backoff.md`）。承接 71 回退后的振荡待办，不再删自解、不再收紧试探判据。
- **设计**：`FanFeedbackHealth.faultStreak` 每进入新一轮 fault +1；`effectiveRecoverThreshold = 3 << min(streak-1, 4)` → 3/6/12/24/48；自解（交还/匹配计拍）永在 → **结构上不可能永久锁存**；仅非 faulted 且 `matched` 时 streak 归零（空拍自解不归零）。ControlEngine 试探协议保持 72 状态（30s 固定）。
- **测试有效性自抓（审查前）**：场景 11 原断言 `handbacks≥2 && takeovers≥2` 在永久锁存下**恒真**（30s 试探协议本身就翻转 F0Md）——改为观测 `status.controlFault` 曾变回非 true（自解真发生）+ 自解后 `appliedPercent>0`（恢复接管）。教训：engine 级「不锁存」测试勿只数 Md 写。
- **独立审查**：fresh subagent 扫 `181f542..e24351d`，7/7 验收 PASS、无 critical。记账：faultStreak 不持久化（重启回 3 拍）；多风扇 matched 为 OR（健康扇可顶掉 streak，弱化但不引入锁存）；stalled(<100) 仍无视 rising grace（71 同源，靠自解兜底）。
- **验证**：4533 断言 / 75 组全绿；非 UI release 编译过。真机部署观察留给作者（盯空闲↔负载时 controlFault 自清）。

### R24（4.1.3(71)）：累计改动独立对抗审查 + 真机回退——振荡修复被证伪，回退控制律、保留独立安全/基建修复
- **形态**：应作者令"大胆做、做完再审稳"。测试基建加第二道契约门槛（distinct group 数≥70，防循环刷量掩盖覆盖损失——断言总数可被 `expectPersonalityOrdered` 这类循环虚高）；再起一路独立审查 agent 扫 `git diff 31f69f7..HEAD`（66 提交），专攻安全链/控制律/跨进程组合的集成 bug。
- **独立审查抓到 R23 振荡修复的两个 P1/P2 组合洞**：P1-1 试探 `probeOK` 写 Md=1 却不置 `forcedModeActive`，交还/退避全锁在 `if forcedModeActive` 里 → 第 2 轮起不交还、健康风扇被钉强制 RPM；P2-1 恢复唯一证据 `matched` 沿用 `target>min+150` 高门槛 → 凉机/夜间锁存后试探只命令低目标 → matched 恒 false → 死锁。我按此修（probeOK 置位 + 恢复侧接受低目标跟随）。
- **真机部署又证伪整个振荡方案（决定性）**：71 部署后本机（健康双风扇）在"空闲停转→负载回升"时，试探验证窗（3 拍、`risingGrace:false` 严格）内风扇从 0 起转来不及跟上高/兜底目标 → **误判"闭环失效"→ faulted；而 R23 删了"空拍自解"→ 误 faulted 永久锁存**，cpuTemp 77° 仍挂 controlFault、daemon 不接管（系统 EC 兜底不致过热，但假故障失控）。根因：**"空拍自解"这个被 R23 当作振荡元凶删掉的机制，实为"试探误判"的隐性兜底**——真坏风扇与"起转中的健康风扇"在 3 拍严格窗内无法区分，收紧恢复判据把二者一起锁死。振荡（仅真坏风扇触发、P2）远小于"健康机器假故障锁存"（P1 级失控）。
- **决策：回退控制律改动**（Fans.record 恢复"交还/匹配都计恢复"原语义、ControlEngine 删 forcedModeActive 置位/退避/feedbackProbeFails），回到已知良好行为；振荡重新列为待办，需"区分起转中(实际在上升) vs 真停转(恒<100)"的稳妥设计 + 真机时序数据，不再冒进。**保留**独立且安全的修复：saveConfig/升级链安全链（R23 P1，与振荡无关）、decisionTrace/AIControlMetrics/learnMap 消毒、通知 per-fan 冷却、图标相位、styleOverride、EINTR 重试、marker 早期守卫、sha256 注释更正、CI 占位防漂移步、测试 group 第二门槛。回退对应测试（恢复"交还3拍解除"、删场景11）。
- **元经验（本轮最重）**：① 删一个"看着是 bug 的机制"前，必须问它在兜什么——"空拍自解"同时兜着"试探误判恢复"，删了它振荡没了但假故障锁存；② 控制律改动的验证不能只靠单测/族扫描的"坏风扇"抽象模型，**真机的"空闲↔负载"起停时序**才是试探协议的试金石——部署后观察真机控制态是必需闸门，不是可选；③ 独立审查 + 真机部署两道闸叠加才逼出真相：agent 抓到 P1-1/P2-1（我修了），真机又抓到"修的方向本身错了"（回退）——"大胆做"必须配"做完真机验证"，否则错误修复比原 bug 更糟。
- **验证**：回退后 4525 断言全绿、ASan/TSan 0 报告、三目标编译；真机 71→（回退重建）复测 controlFault 清除、风扇恢复跟随。

### R23（4.1.3(66)）：全量对抗审查轮——三路静态 + 双消毒器 + 真机/部署/文档对账，修 20+ 项含 2 个 P1 提权原语
- **形态**：应作者令"全量对抗式审查，各种审查都用上"。三路并行静态审查（daemon 核心 / App+脚本+CI / 文档声明对账）+ 动态（ASan/TSan/fuzz 既有）+ 真机对账（fanprobe vs status.json）+ 部署对账（六处版本串）+ 元审查（文档可验证声明逐条核）。
- **P1 提权原语 ×2（都源于"root 执行/修改用户可写路径"信任边界误设，非逻辑 bug）**：
  ① **saveConfig 的 chmod/chown 按路径跟随符号链接**：support 目录 root:admin 775，组内用户可在 rename→setAttributes 窗口把 config.json 换成 `ln -s /etc/sudoers`，让 root 把 sudoers 改 664 = 本地提权。改 fd 级：O_EXCL 建临时文件 + **fchmod 强制 664**（再审抓出：open 的 mode 受 umask 掩码，022 会削成 644 重新引入 v3.6.2 的"App 失去写权限"bug）+ fchown 走 fd + rename 替换符号链接本身永不跟随。
  ② **升级链 root 执行用户可写的包内 upgrade.sh**：驻留进程篡改 Contents/Resources/upgrade.sh → 用户下次例行升级输密码即静默 root。改：脚本正文构建期 base64 内嵌进二进制（build.sh 生成 UpgradeScript.generated.swift，占位文件同 4E 纪律），经 `echo|base64 -d|bash -s` 直交 root（b64 字母表对 AppleScript/shell 双层引号天然安全，无 check-then-exec 竞态）；并 App 弹窗前算暂存 daemon/App 二进制 sha256 随命令传入，upgrade.sh 在 bootout 前重算比对（闭合"授权确认后偷换暂存包"TOCTOU）；完成标记移到 /tmp 随机路径且比对内容=授权版本（原"用户可写目录里文件存在即完成"可预置伪造）。
- **P2 修复（控制/观测/发行）**：NaN 转速污染持久化链（FanState 读侧 isFinite 门，非有限=读失败抛错走 allStates 跳过）；曲线/偏移数组长度无上限→每拍排序拖爆看门狗（sanitized 加 ≤64/≤8 上限）；校准退出/超时边沿未重置 AI 控制器（lastTemp 冻结→首拍 D 项按分钟级温漂猛打，reset 与模式切换对齐含 aiIdleActive）；fanCount==0 shell 层 exit(1) 使 B1 passive 语义成死代码（改继续运行，passive 低频重探）；ThermalLearn 包络钳位对 NaN 穿透（Swift max/min 对 NaN 比较恒 false 原样返回，实测坐实，改 isFinite→nil）；uninstall 登录项注销在 root 域执行达不成 4D 目的（su 到控制台用户）；CI test job 全目标直编绕开 R22 SDK 探测（改只编非 UI 目标）+ release job 缺 tag==VERSION 断言（补，防"打 tag 忘 bump→全体老用户 404"）。
- **P3 批**：损坏 config 备份无保留上限（补 ≤5）；F0A 前缀误入掌托表（F0Ac 是风扇 RPM，起停瞬态 0~119 污染环境谷值，删）；升级失败重试"一次"实为无限链（封顶 3）；deploy pkill -f 误杀面（改 -x）；codesign 失败静默吞（改致命）；探测临时目录泄漏（加 trap）；断言契约下限 2499→4400（原可砍 44% 测试仍发绿，harness+CI 同步）；install bootstrap 失败无声退出（补中间态告警+恢复路径）。
- **文档对账修正**：SECURITY "v3.1.0"（落后 10 版，去硬编码改引用 Releases）；CONTRIBUTING "~2415 断言"（与自家 CI 下限冲突，去硬编码）；**README "macOS 26 已放弃 Intel" 是外部可证伪的事实错误**（26 是最后支持 Intel 的版本，放弃 Intel 的是 27；arm64-only 是发行约束非 OS 约束，已改口径并消解与 CONTRIBUTING/代码 Intel 通路的三方矛盾）；§2 补 dt-ledger.json、§4.3 深凉 −12°/常规 −8° 绑定纠正、snapshot 清单补 ai/label、源码构建安装路径死路。
- **未修项（定性记账，非遗漏）**：① ~~风扇物理故障"夺回↔交还"8 拍振荡~~ **→ R23 续轮已修（4.1.3(70)）**：根因确认为 `FanFeedbackHealth.record` 把"交还期无命令"也算恢复进度 → faulted 在 3 空拍后自解 → 走正常分支立即重申、绕开 30s 试探节流形成振荡。修法：(a) `record` 只认"高目标命令且真实跟随"（新增 `matched` 信号）为恢复证据，无命令空拍保持 faulted 锁存，恢复改由 30s 试探协议作唯一入口；(b) ControlEngine 试探间隔按连续失败指数退避（30s→…→封顶 30<<6≈32min），坏风扇重试频率随失败递减、任一真实跟随归零。验证：FanFeedbackHealth 单测锁"空拍不解除/真实跟随才解除"、引擎场景 11 端到端锁"controlFault 锁存 + 至少交还一次"、族扫描交还次数未失控（max 2）；4533 全绿、ASan/TSan 0 报告。② ~~R21 关闭态门禁 onAppear 生效前提悬置~~ **→ 已由用户真点闭环**（窗口 onscreen=true、内容树完整非空白）。③ MenuBarLabel 仍随 App body 每拍重算（MenuBarState 挡住了内容光栅、没挡 body 求值；实测 0.55% CPU 可接受，不动）。
- **元经验**：① 安全审查的富矿是"root 信任边界建立在用户可写文件上"——本轮两个 P1 同根，"同源"≠"同完整性"；② 修复再审真抓到了新引入的 bug（umask 掩码 open mode），印证"改完必再审"；③ 消毒器/对账不是走过场：TSan 复现了 v3.4.5 锁纪律的漏网方法（writeDouble），文档对账揪出外部可证伪的事实错误；④ 历史测量值不自洽时（R20 4.8% vs 8.0%）标注存疑优于静默改数。
- **R23 续轮（4.1.3(67)，第二轮三路对抗审查：审我自己 R23 改动 + UI 视图层 + 测试有效性）**：
  - **P1-A（我引入的确定性回归）**：升级链传给 root 脚本的是带 `v` 前缀的原始 tag（`v4.1.3`），而 Info.plist 版本无 v（`4.1.3`），脚本 `[[ STAGED_VER != TAG ]]` → 每次一键升级输完密码后 100% exit 3；且我新加的 CI `tag==v${VERSION}` 断言恰恰保证了这个前缀必然出现。修：App 侧统一传 `sanitizeTag(tag)`（剥 v）给脚本与 watcher 比对。8 个新断言全绿也拦不住——因为没有任何测试覆盖 root 脚本的 tag 比对（见下"未修：脚本侧零测试"）。
  - **P1-B（P1 修复只做了一半）**：`upgrade.sh`/`install.sh` 里 `chown/chmod config.json` 仍按路径操作、跟随符号链接——与 saveConfig 刚消灭的同款提权原语，却留在每轮升级必执行的 root 脚本里（$SUPPORT 是 root:admin 775 无 sticky，`-f` 测试也跟随链接挡不住）。修：加 `[[ ! -L ]]` 守卫拒绝符号链接（三处）。
  - **P2-B（我把 marker 挪 /tmp 引入的新面）**：`osascript -e` 全文进 `ps`，任意本地用户 grep 即得 marker 随机路径 → 抢建符号链接 → root `printf > marker` 跟随截断任意 root 文件。修：marker 挪回 App 私有 700 暂存目录 + root 写前 `[[ -L ]]` 拒绝。
  - **P2-A（fail-open）**：App 侧 `sha256Hex ?? ""` 在暂存二进制不可读时传空串→脚本 `-n` 判假静默跳过复核。修：读不到哈希即拒绝升级（fail-closed，弹窗前）。**残余（记账不修）**：整链无信任根（zip 无固定摘要、二进制仅 ad-hoc 签名不验签），"哈希前偷换暂存内容"仍无解——根治需 Developer ID 验签，属 plan 明确砍掉的公证/签名范围，接受为已知残余风险。
  - **F1（UI 审查 P2）**：`decisionTrace` 是全链路唯一未消毒直通视图 `Int()` 的 status.json 字段，坏文件超大有限值（JSON 合法、解码器不拒）→ `Int(1e300)` fatal trap 崩常驻 App。修：加 `DecisionTrace.sanitized()`（与 learnMap/appliedPercent 同口径，非有限/≥1e6→nil）。同族 aiMetrics/stats/learnedNow 的视图 `Int()` 记为 P3 待办。
  - **测试有效性（变异审查）**：saveConfig 的 fchmod/rename/符号链接语义此前零回归质（双次历史回归区！）→ 补 `testSaveConfigPermissions`（断言 mode==664 穿透 umask + rename 替换链接不跟随 victim）；个性序断言 `>=` 允许三档压平（~816 条"绿量"掩盖）→ 补"中间温区至少一处真实分叉 ≥5%"；我上轮写的 `fanOffsets ?? 0 <= 8` 是弱断言 → 改精确 prefix(8)。**未修记账**：root 脚本（upgrade.sh/install.sh）纯 shell 逻辑仍零测试、checks 计数可被"循环虚高/合并虚低"双向失真、54 处 try! 违背自订 R8 纪律——列测试基建债。
  - **元经验（续）**：① 修安全 bug 时"同款原语的其它实例"要全局搜（P1-B：daemon 侧修了、root 脚本两处漏了）；② 给"授权后复核"这类安全机制加测试要测到 shell 层，纯 Swift 单测给了虚假安全感（P1-A 全绿仍漏）；③ 自己引入的"改进"（marker 挪 /tmp）要按威胁模型重推它开的新面（ps 泄露 argv 是本轮才想到的攻击者能力）。
- **R23 细节打磨（4.1.3(68)，第二轮审查的 P3 记账项收口）**：F2 无效温度读数不清 `hotSince` → 跨传感器故障期误报"已持续高温 30 秒"（清零判定基准）；F4 风扇健康 6h 冷却由全局单值改 per-fan（否则左风扇报警后右风扇被压 6h、且 anomalySince 不清零致 6h 后发过期事件）；F5 风扇图标停转时 model transform 从未提交 → removeAnimation 后 presentation 跳回旧值"弹"一下（停转切换也结算相位 + model 对齐 lastAngle）；变异审查点名的测试质量：`expect(true,...)` 恒真断言改实质（错误类型 + 绝不写 Tg）、补 F0A 掌托误计回归测试、补损坏 config 备份 ≤5 测试（预置 7 个不同秒戳避免碰撞空转）；CI test job 补回 App 目标编译校验（此前只编非 UI 目标，PR 阶段丢失 SelfUpgradeService/视图的编译覆盖）。**未收口（记账）**：F1 同族 aiMetrics/stats 视图 Int() 需先确认 loadStats/loadAIMetrics 是否已消毒再定（避免重复改）；F6 面板重开陈旧进程榜、F7 快照覆写实时 defaults、F8 学习地图 temp x 域/GPU 死传感器 0 值折线——均为展示层 P3，留后续。4521 断言全绿、ASan/TSan 0 报告。
- **R23 细节打磨（续，4.1.3(69)，把上条"留后续"清空）**：F1 同族核实——DailyStats.sanitized 已钳标量（视图 stats Int() 本就安全），AIControlMetrics 无消毒 → 补 `sanitized()`（temp/secs 双口径钳位）+ loadAIMetrics 套用（合法 JSON 的 1e300 不被解码器拒、视图 Int 会 trap）；F8 learnMap filter 补温度区间（isFinite 挡不住超大有限值撑爆 x 域）+ GPU/CPU sparkline 过滤 ≤1 死传感器读数（全死则样本<2、不画，比假跳水诚实）；F6 stopCPUSampling 清空 topProcesses（重开先空后新鲜，不拿旧榜冒充实时）；F7 快照 label 改 `styleOverride` 显式传值，不再覆写共享 menuBarStyle 键（消除常驻 App 标签闪现 + 中途被杀丢设置）；P3-4 NaN 抛错键名指向真正异常的键；P3-2 启动清扫 >1h 的 `.config.json.<uuid>` 残留（年龄门槛规避跨进程在途竞态）；文档：EVOLUTION 基线表加"冻结锚点"口径注（4368/+42.8 保留原值不篡改、标注当前 4521/+42.5）、README §3 源码树补全 18 SMCCore 文件+fanctld 拆分。**再审自抓**：cleanupStaleConfigTemps 插入时漏了 loadStatus 签名行 → 编译门红（改完必编译再次奏效）。4521 全绿、ASan/TSan 0 报告。

### R21（4.1.2(64)）：R20 修复复验失败 → 根因修正——风暴主体是"关着的面板整树每拍重评"
- **复验推翻 R20 验收**：4.1.1(63) 进程（跑 2d6h）实测均值 **3.9%**（129 CPU 分/3291 分），
  瞬时突发 50%。"0.23%"验收拍在 daemon 空闲期（20s 拍、温度稳），从未在 AI 控制态
  （~2s 拍）下测量——"根除"结论下早了。
- **根因修正（sample 8s 堆栈实锤）**：ImageRenderer 只是放大器之一；主体是 MenuBarExtra
  的 label 与关着的面板共享整个 FanModel——status 每拍落盘 → refreshFromStatus 无条件
  赋值近 30 个 @Published → objectWillChange 全对象失效 → ① label 每拍重算（本机
  menuBarStyle=icon，温度数字根本不在场，纯浪费）；② MenuBarExtra(.window) 关闭不销毁
  视图树，整面板 body 每拍重评（Liquid Glass vImage 卷积 + Charts 布局；CGDrawingLayer
  光栅 539/6745 样本，主线程 ~50%）。
- **修复（仅 FanCtlApp）**：① MenuBarState 量化小状态对象——label 单独订阅，按
  menuBarStyle 可见部分去重（icon 态只有字形/警示色变化才发布），display 恒真值、
  发布与否另判；② ContentView 关闭态门禁——!panelVisible 时渲染 340×908 占位
  （窗口 idealSize 不变），onAppear/onDisappear 上移到外层容器（旧连线挂 panelContent，
  分支切换会丢"重新打开"事件）；与 R3 落盘门同源哲学。
- **验收（这次在风暴触发态下测）**：4×yes 负载 + 温度 65-74° 波动 90s，标签步进正常
  （AX name 实测 70°→74°→67°），App CPU 0.27s/90s = **0.3%**；8s sample
  CGDrawingLayer/sizeThatFits 风暴签名**归零**（此前 539/361）。4496 断言绿。
- **无头盲区记录**：本机当前无显示会话（list_displays 空），面板打开交互无法截屏/AX 验证
  ——对照实验证明 4.1.1 在无头下同样开不出窗口，故 NO WINDOW 不是门禁回归；门禁的
  onAppear 机制与生产已验证的连线位置等价，但**需用户下次手动开面板确认一次**（空白=回归，回滚）。
- **元经验**：① 验收窗必须覆盖病灶触发态——"2 分钟采样突发消失"（空闲期）≠"根除"；
  ② 换渲染实现前先数"谁在观察同一个 publisher"——全对象 objectWillChange 的成本在
  观察者的树上，不在渲染方法里；③ 快照通道临时覆写用户 defaults 必须用后恢复
  （menuBarStyle 同域污染）。

### R20（4.1.1 全方位打磨轮）：菜单栏 CPU 根除 + 快照矩阵三修
- **菜单栏 CPU 根除（R19 记账的 4.2 首项提前兑现）**：MenuBarLabel 原生视图直出替代
  ImageRenderer 离屏渲染——旧缓存键 Int(温度) 被控制期噪声频繁翻转，每次翻转 ~0.3s
  主线程离屏渲染 + 菜单栏图层 CA 交换。实机验收：4.1.0(62) 均值 4.8%（23:37 CPU/4h54m，
  0.3-0.5s 突发每 10-20s）→ 4.1.1(63) 均值 0.23%，突发消失，**~20× 降幅**。
  （R23 对账存疑：23:37 CPU 分 ÷ 294 分 = 8.0%，与标称 4.8% 算术不符——要么百分比、
  要么括号内原始测量值有一处记错，历史测量无法复现，保留原文待作者回查原始采样。
  不影响结论方向：R21 已独立复测 4.1.1 在控制态仍 3.9%，"根除"结论已被推翻。）
  新增 `--snapshot label` 像素验证通道（常态/高温警示两态并排）。
- **13 快照矩阵目检 → 三修两撤**：
  ① warn 横幅去 `sudo ./scripts/install.sh` 仓库路径（对 Release 用户是死路）→
    "请以管理员身份重新安装清风"；② dead 态语义诚实：守护进程停更时 AI 卡不再断言
    "自动接管"（标题→"AI 控制 · 数据停更" + 控制卡整体 opacity 0.55，高度守恒）；
    ③ 学习地图 Y 轴顶刻度 "100" 裁切 → Chart 加 4pt 顶白。
  撤销两条目检怀疑：GPU 卡留白是有意设计（不伪造副值，代码注释已记）；掌托图标
  已有 help tooltip。**教训：目检结论必须过代码核实再进修复清单。**
- 代码层扫描干净（TODO/单位惯例/全角/硬编码版本零问题）；4496 断言全绿；
  改动仅限 FanCtlApp → deploy.sh 免密通道部署，无需 sudo。

### R19（4.1-B/E 裁决轮）：包络自愈确认 + 秒基议题关闭 → 4.1 实质工作全部完成
- **B 包络收口裁决（提前关闭：D 截断使输入终局）**：
  - 证据 1（旧图）：envelopeGap 1.43 → 0.326（09-09→09-11），10 天单调收敛 77%
    ——自愈机制有效，无需数据手术；旧图在 9 月下旬窗口打开前被 D 的授权重置
    截断（输入终局，继续等待无新信息）。
  - 证据 2（新图）：D 重置后 envelopeGap=0 零污染起步（75°/77° 桶 100% 为合法
    饱和学习，单调包络之内）。
  - 裁决：**自愈确认、关闭议题、无数据手术**。标注：旧图截断值 0.326 未到精确 0；
    未来若出现非单调污染，同款观察协议重启。
- **E 秒基裁决（VM 危害测试决定性，议题关闭：不改秒基）**：
  - 实现：AITuning.dSecondsBase 开关（默认 false = 生产零变化；秒基 =
    `kD·clampedSlope`，dt=3 严格等价、每秒推力恒定）。
  - 等价性门槛（R17 规则原文）：纯 3s 拍两律 300 拍逐拍严格相等，零分岐 ✅。
  - 危害测试（混合 dt + 守卫 1s 窗，3000 拍闭环，同负载 schedule）：
    **现行 过冲 +13.0° / 调速 454 / 翻转 61 / RMS 74.92 vs 秒基 +13.0° / 467 / 53 /
    75.13**——过冲零差异、调速次数现行反而少 13 次、翻转差 15%（阈 50%）。
  - 预注册三条触发条件（+1.5° / +20% / +50%）全不满足 → **不改秒基**。
    机理：快拍期 D 超推力（3×）方向与需求一致（陡变期恰需强 D），被负载动态
    掩盖——R4 当年"理论漂移存在但可能无实际影响"的跳过直觉被证实。
  - **门槛重估（公开记录，非绕过）**：A2 定的"受控 ≥7 天占比确认"在危害测试
    "无差异"结论面前失去裁决意义——占比不再影响任何决策，7 天等待的唯一产出
    是确认一个不改变任何行为的数字（仪式性门槛）。形式确认（10 月账本攒满后
    fanprobe 读一次占比）保留为背景数据。R17 元经验的对称面：**门槛在裁决结构
    变化后要重审其目的，否则预注册会退化为仪式**。
- 4.1 状态：A ✅ B ✅ C ✅ D ✅ E ✅ F ✅ —— **4.1 全部闭环**。
- **F + B4a 首验收 ✅（09-12 06:51，v4.1.0(62)）**：tag v4.1.0 → CI Release（资产
  FanCtl-v4.1.0.zip，解包纯净度验证：FanCtl-4.1.0/ 子目录布局 ✓ 零脚本残留 ✓
  版本串 4.1.0/62 ✓）→ AI 端到端驱动升级：清 updateLastCheckAt 加速检查 → AX 驱动
  面板"更多→⬆️ 升级到 v4.1.0…" → 用户一次授权弹窗 → 下载 3.26MB→解包校验→安装
  →watcher 以登录用户重启 App——**全程 App 内完成，v3.9 建成的链路首次真实使用成功**。
  升级实测三项：①watcher 重启 ✓（App pid 更替、面板正常）；②App 归还登录用户 ✓；
  ③**dt-ledger 跨升级存活 ✓**（A1 解耦在真实升级场景成立，受控 11.4h 无损）。
  升级启动清洗 9 个中温桶（D 后重学表的重载日产物，低桶 0%/高桶 98-100% 合理存活）
  ——sanitize 按设计工作，持续观察。
- **4.2 首项（P2，本轮实测发现）**：菜单栏 App 周期性 CPU 突发——平均 ~3.5%
  （17h 烧 36 CPU 分钟）。根因：MenuBarLabel 缓存键用 Int(temp)，AI 控制期温度
  噪声 ±0.5° 使整数位频繁翻转 → 每次翻转触发 ImageRenderer 全量离屏渲染
  （主线程 ~0.3s）+ 菜单栏图层 CA 交换。采样定位链：ps 突发 → 10s sample →
  主线程 1508/8636 样本在 CA::Transaction::flush → FanCtl 帧锁定 render。
  修法候选：原生 Label 替代 ImageRenderer（零离屏渲染，像素微变）/ 缓存键 2°
  量化（减半翻转，最保守）。下一轮带 UI 验证周期做。


### R18（4.1-B/C/D 轮）：负载锚定评估 + 真机冷启动首验通过
- **C 负载锚定评估（裁决：机制保留，参数不动）**：
  - 前提修正：plan-4.0 B5「功耗直方图已满 30 天」为误记——powerHistogram 字段实际
    仅 **8 天**覆盖（09-04 起，history 30 条中 22 条是字段上线前数据）；"30 天"出处
    是 powerSum/powerCount 老口径。**计划前提也要对数据核实，"满 30 天"差点没被查。**
  - 门控前提在真机成立：7 天滚动功耗 P50 = 15.2→14.0W（Δ1.2W < ±max(2W,15%) 门槛）
    → "负载未变"条件常态成立；温度 P50 下移 1.8°（51.5→49.7）而 ≥80° 占比持平
    （0.4%）→ 门控此刻处于武装状态（重新应用优化器则锚点下移限 0.25°/周期）。
  - 裁决：v3.3 锚定门控按设计工作，参数不动；功耗直方图满 30 天真实覆盖（约
    10 月初）后如现反常再议。观察项：门控只在手动重新应用优化器时触发。
- **D 真机冷启动 dogfood（裁决：通过，保留重学表）**——B2 立项理由（迁移韧性）
  的首次真机闭环：
  - 09-11 13:29 重置学习表（备份 `ai-learn.json.pre-4.1D-backup`，15 桶 1361 样本，
    保留到 4.1-F）→ **观察期 2m07s / 9 个稳态样本 → 接管**。低负载下系统停转风扇，
    反解 0% 入表（真实物理非交还伪影）；稳态门逐拍通过。
  - **"校准中"恰好 1 次、"校准超时" 0 次**——R16 超时 latch 真机无重入循环。
  - 接管后 2.5h：公式种子起步正常（启停循环抑制 60min→2h 退避按既有设计武装）、
    无安全覆盖事件、学习按 B2 设计由 AI 控制期补齐（3→39 样本 / 6 采信桶，
    71-77° 桶来自真实负载期）——"校准只负责起步，负载期桶自己补齐"的分工真机成立。
  - fan0/fan1 采样偏差取数不足：观察期系统停转（双扇 0 RPM），单点无差异信息
    → 未决观察项，留给未来自然冷启动。
  - 交叉收益：新图 envelopeGap=0（零污染起步）；旧图重置前 0.326（自愈趋势
    1.43→0.326 已成立）——B（包络裁决）两证据齐，9 月下旬按窗口出正式结论
    （记账 D 干预事件：旧图观察对象已被重置）。


### R17（4.1-A 裁决前置轮）：dt 账本解耦 + 预注册规则两处证伪 + 裁决口径定版
- 4.1 计划 v1 的数据盘点（真机实测）触发三个发现，全部在**动用账本数据裁决之前**修复/修订：
- **A1 生命周期缺陷（代码证实）**：dt 账本挂在 AIControlMetrics 里，评测指标在用户
  切换目标档位时整体重置（init 比对 + 运行中 aiMetricsUserTarget 漂移两处）→ 账本
  清零陪葬，"账本 ≥7 天"门槛按正常使用习惯结构性不可达。修复 = 独立持久化
  **dt-ledger.json**（DTLedgerState，startedAt 注入时钟），生命周期 = 控制律版本，
  无自动重置（控制律结构变更时手动删除重攒）。**不迁移 legacy 数据**：修订后的
  裁决口径需要 slopeWeightedSum（legacy 没有），原始比值口径已被证伪——自 4.0.1
  重新起算。
- **A3-① P 校准线前提证伪（解析）**：pDelta = kP·clampedError·dtNom → 每秒贡献
  = kP·clampedError/3，"三桶基线应相等" ⟺ 各桶平均 clampedError 相等——而分桶
  本身就按拍长选不同的 operating regime（长拍≈舒适区 P≈0；快拍陡爬≈饱和
  anti-windup 跳 P≈0；真机 4.33/2.68/0.66 是物理不是 bug）。**P 校准线退役**。
- **A3-② 预注册规则死分支（解析）**：D 快/标称比 = (斜率比)×(dt 比)，dt 比按构造
  ≈3、斜率比由选择偏差保证 ≥1 → **"≈1 → 关闭议题"分支不可达**，规则照原文执行
  会无条件得出"改秒基"。修订：账本新增 slopeWeightedSum（Σ|slopeRate|·dt，只认
  D 出力拍）→ I_D = dAbsSum/slopeWeightedSum 把两个因子分离。VM 复现测试锁定：
  **I_D 比 = 3.00 精确**（纯 dt 效应），P 线跨桶结构性不等复现——真机 7.28 ≈
  3×2.4 的分解成立。
- **A2 口径定版**：裁决门槛 = 受控时长（三桶 seconds 之和）≥ 7 天 且 快拍秒占比
  >5%（当前 10.9% 已达标，但账本自 4.0.1 重起算）。裁决方法 = 快拍占比确认 +
  **VM 危害测试**（同轨迹对比现行律 vs 秒基律的过冲/极限环/调速次数），账本只供
  暴露度，不再供比值裁决。
- 自审修正（计划 v1→v2）：①"账本 0.83 天 = 重置痕迹"未证实（30% 受控占比的
  duty-cycle 同样解释）——结构性缺陷靠代码证实，不靠这段推测；②计划原定"账本字段
  相关性检验"不可执行（账本无逐拍数据）→ VM 复现法替代，反而多产出 I_D 工具。
- 元经验：**预注册规则在启用前也要过对抗审查**——R8 写规则时"P 恒定"与"≈1 关闭"
  两个前提都没被推演到分桶选择偏差这一层；预注册防的是"看数据后合理化"，防不了
  "写规则时的盲区"，规则自身的审查要单独一轮。


### R16（4.0 审查修复轮）：超时假退出 + FNum 自愈 + calibrating 变化感知 + 4.0 首次送达
- 全量对抗审查（B1-B3 diff 逐行 + 4452 断言本机复跑 + 实机部署取证）→ 三项修复 + 一项衍生：
- **P1 交付缺口（R12 L1 复发）**：本机 daemon/App = 3.9.1(59)（构建于 B1 commit 前 41 分钟），
  三个语义变更批次零真实机器在跑；VERSION 未提号 → main 构建物与 Release v3.9.1 同号不同码。
  修复 = **4.0.0(60) 载体 + 端到端部署**。
- **P2 校准超时假退出**：超时分支置 `calibrating=false`，但顶部门控每拍重算
  `calibrationDue`——同条件下一拍拉回、窗口重置，45 分钟超时接管实为 45 分钟重试；
  稳态样本永不增长的负载形态下 AI 永不接管，日志每 45 分钟自相矛盾一对。次级：超时检查嵌在
  fan0 有效性守卫内，观察期风扇读取全失败时永不可达。修复 = `calibrationTimedOut` latch
  （门控排除；切离 AI / 重置学习数据解除）+ 超时检查移出守卫。测试缺口实锤：B2 三场景无一
  覆盖超时路径 → 补 ④超时接管+latch 持续+切离重臂 ⑤风扇读取全失败期超时仍可达。
- **P2/P3 passive 误判**：fanCount 是 init 一次性 `let`，FNum 启动瞬时失败把有扇机器永久钉在
  无风扇语义——B1 前该故障走 controlFault 响亮路径，B1 后变成安静的错误语义（后果类别
  变差）。修复 = fanCount 可重探（`rescanFanCountIfNeeded`，fanCount==0 期间 30s 节流重读
  FNum，invalidateFanLimits 复位节流），恢复即翻正 + 硬件画像同步更正 + 边沿日志；降级窗口
  ≤30s 而非进程生命期。
- **衍生发现（新断言逼出）**：`calibrating` 不在 statusChangeSummary 里——校准进出/超时接管
  那一拍 summary 不变 → 状态不落盘，App 的校准中提示翻转要等 10s 心跳，回归断言也被陈旧
  文件骗过。修复 = calibStr 进 summary（与 learnEnvelopeGap/palmComp 同型补齐）。
- 方法论：(1) 注释断言「稳态门照旧（Goodhart：不放宽任何门）」被逐行核对证伪——观察期采样的
  风量门换了语义（calibPct 自传恒通过 + 有意省略 >5% 低饱和门，0% 是系统真实平衡非交还
  伪影）。**注释描述实际行为，不许复用口号。** (2) 新断言不仅验证修复本身，还暴露观测契约：
  状态字段必须参与变化感知，否则测试和 App 一起被陈旧 status 文件骗——新 UI 状态字段落地时
  同步进 summary 应成为清单项。


### R14（B2 收尾）：HIL 冷启动对比——"不劣化"确认 + 观察期负载保真修正
- 首版 HIL 观察期用 20W 轻载、控制期 45-60W——**观察桶与接管后遇到的温度带
  不重叠**，learned 查表命中率≈0，对比退化成"两个几乎相同的轨迹"（假通过）。
  修正：观察期与控制期共用同一条负载轨迹（真实场景 = 用户在当前负载下开启 AI）。
  修正后：过冲 +3.2°→+3.3°（容差内），带内 486→480（-1.2% 容差内），调速 66→86
  （提前量增加——有表可查时 AI 更快从经验起步，调速频度上升是"起步更积极"的
  代价，换来的是收敛路径不更差）。4446 断言全绿。
- **HIL 教训**："不劣化"验证必须让观察条件覆盖控制条件（同负载/同温度带），
  否则差异被稀释成假通过。与 R10"dogfood 输入形态=真实输入形态"同源。


### R15（B3）：研究项抓到真实数据层缺陷——学习查表采信域
- 校准播种 × 81 族扫描首跑：1 成员（env28/R1.3/τ25/A28）过冲 +1.7° 超容差。
  机制：ThermalLearn 单侧查表 `case (true,false): result = output[lo]` 把 43°
  观察桶的平衡风量平推到 76° 夺回点——**欠冷却方向的错误播种**。
- 修复 = 查表采信域（lookupBandWidth=10°，单侧出带 → nil → 退回曲线/公式种子），
  对齐 ThermalModel v2.7"样本带外返回 nil"先例。修复后全族 0 劣化。
- 方法论：**研究项的价值 = 让"低风险路径"暴露在它本不会遇到的输入组合下**。
  用户机（13 桶跨 50-86°）永远触不到这条路径；只有"观察期刚播种的稀表"会。
  冷启动特性 + 泛化研究组合才抓得到——单看任何一个都看不见。
- 崩溃教训重现（R8）：测试强解包 percent(for:)! 撞上新 nil 契约 → exit133 全
  输出丢失，靠 .ips 崩溃报告定位（testThermalLearn）。测试断言改为显式 nil 契约。

## R13（4.0 启动）：计划审查方法论复用 + B1 落地

- **计划基线**：docs/plan-4.0.md（v2）——主题"从 N=1 到 N=任何人"，五批次
  （B1 冷却分级 / B2 冷启动校准 / B3 泛化边界研究 / B4 发行链 / B5 数据裁决）。
  计划审查五轴（范围/验证/Goodhart/时序/回滚）修正 v1 四处：砍学习数据导入
  （移植即污染）、无风扇降为诚实表达、验证边界诚实化、notarization 标注阻塞。
- **B1 已落地**：daemon 门控（fanCount==0 → 各模式语义化为 auto，复用 boost
  过期同源路径零新状态）+ App 诚实提示（画像透传 FanModel + controlCard 提示行）
  + 零风扇三场景断言（AI/manual 语义化且不写扇/有风扇零误伤/日志一次）。4430 断言。
- 快照验证：ai/auto 渲染正常，窗口守恒未破。


### R13 续（B2 落地中的方法论收获）
- **"同号不同码"的镜像**：**"断言绿 ≠ 语义对"**——校准采样器首版编译过、嵌套
  合法、位置"看起来对"，但因嵌在 targetPercent 分支里（auto 期 nil）整段死代码。
  大函数里插块必须用行尾括号深度机检层级，不许目测缩进。
- 跨层协作陷阱：学习表落盘有 60s 节流门（statsAccumSeconds），测试用 FakeClock
  跑拍必须把"行为时间"与"持久化时间"两个时钟都对齐——单对齐一个是假绿。
- 成熟度语义教训：UI 口径（learnedBucketCount=采信桶）与工程口径（sampleTotal）
  不是一回事；空表冷启动 45 分钟只会产 1 个桶——单桶 × 桶数阈值 = 永不成熟。

## R12（v3.9.1 遗留清点轮）：跑完审查之后查"审查之外"

### 转向
连续三轮审查+fuzz+mutation 后用户要求"再跑一遍看遗留"——审查的对象从代码换成
**发布状态本身**。清点面：脏文件/临时目录/残留引用/文档断言数/版本身份/发行资产。

### 抓到（L1-L4）
- **L1 版本身份污染（P1 级发布事故）**：Round A/B 修复（含暂存目录错位 P1）只
  存在 main 分支——git tag v3.9.0 与 Release 资产都指向修复前 commit；VERSION 未
  提版号 → 本机 3.9.0(58) 与 Release 3.9.0 **同号不同码**，"看版本号辨代码"失效。
  实证：下载 v3.9.0 资产解包，内嵌 upgrade.sh 含 3 处 submit 残留（Round B 前脚本）。
  **修复 = v3.9.1(59) 作为正式载体重发 Release，资产纯净度解包验证。**
- L2 同根（无版本号的修复）；L3 README 断言数为成文时点值（无害）；L4 /tmp 检查
  残留（已清）。

### 教训
1. **修复合进 main ≠ 修复送达用户**。发版后的每一轮修复必须以提版号+重发 Release
   收尾——审查循环的 DoD 不含"发版载体"就等于把 P1 留在了用户下载页上。
2. tag rebase 后重指 → 两个 tag run 并发，第二个 `gh release create` 撞
   "already exists" 红。处置：删 Release 重跑转绿（资产内容等价，仅父历史不同）。
3. README 章节重编号的 python 陷阱连续两轮复现：`replace("## 9. ", ...)` 会吃掉
   下一个同号标题——**重编号必须锚定含版本号的完整标题行**，并在脚本里断言
   重编号后的完整序列。

## R11 补充（2026-09-09）：动态方法论覆盖升级模块
- **模糊性质测试**（500 轮确定性 LCG）：四条全局性质——输出白名单/URL 契约
  （https+host+路径前缀）/授权文案无元字符/幂等性。首轮运行自家 fuzz 当场抓到
  **测试自身的 bug**：`rangeOfCharacter(from:).inverted` 语义反转，中文文案必然
  命中——模糊框架第一战抓的是写模糊测试的人，框架有效性自证。
- **变异测试 7 变异体全杀**：去 isASCII / 段数 4→5 / 长度 24→48 / 版本门
  相等→原串比较 / 删 fanctld 在场检查 / https→http / 文案兜底→回显原串。
  净得分 100%，无盲区。方法论纪律遵守：campaign 基于**已提交**状态（R6 乌龙
  教训），变异后 `git checkout` 还原 + `git diff` 确认干净。
- **运行态对账**：本机 App 内嵌 upgrade.sh 与 HEAD diff 一致（watcher 版），
  daemon 心跳 fresh——部署链无漂移。

### 元经验
1. **修复本身是新的攻击面**：Round A 修好的 submit 兜底就是 Round B 的 P1 候选。
   "修完再审"不是仪式——每一轮的修复必须进下一轮的攻击清单。
2. **特权脚本里 root 的职责边界**：root 只做必须 root 的事；"root 帮用户做
   方便的事"（重启 GUI）每一次都翻车（open 静默失败/submit 域存疑）。
3. dogfood 输入形态必须等于真实输入形态（P1 的掩盖事故）。
4. launchctl 语义实测记录：remove 运行中标签=杀进程；submit 默认不重生。

## R9（v3.9 一键升级轮）：把"看见更新"推进为"完成更新"

### 动机（部署链路的最后一公里）
v3.6 版本自检只到"菜单提示 + 打开下载页"，安装仍要用户 sudo install.sh——
2026-09-08 用户明确拒绝该分工："我要的是你自己去升级。麻烦到我，不像是给我提升效率"。
部署摩擦本身就是产品缺陷。同日 osascript admin-dialog 模式真机预演成功（dist→/tmp +
路径修补 + 一次授权弹窗完成 3.7→3.8），本轮把该流程产品化。

### 安全设计（特权面三层收窄，全部测试锁定）
1. **tag 消毒 = 唯一收窄点**：sanitizeTag 只放行 ASCII 数字+点（≤4 段 ≤24 字符），
   下载 URL、osascript 命令串、授权弹窗文案三处共用一份消毒；16+ 注入对抗样本
   （分号/反引号/路径穿越/换行/非 ASCII 数字/超长/空段）全部断言拒绝。
2. **root 执行的代码与 App 同源**：upgrade.sh 内嵌 App Resources（build.sh 打包），
   绝不从网上下载脚本；下载物（zip）只作为数据被安装。
3. **校验门在授权弹窗之前**：暂存包 Info.plist 版本与 Release tag **严格相等**
   （哪怕暂存包版本更新也不放行）+ fanctld 在场；失败根本到不了 osascript。

### 关键实现决策
- **osascript 场景无 SUDO_USER**：upgrade.sh 用 `stat -f%Su /dev/console` 取登录用户
  归还 App 属主——保住免密 deploy.sh 通道（v3.8 部署时 App 归 root 的直接教训）。
- **quarantine 防御性清理**：URLSession 下载不自动加 xattr，但 root 复制后仍执行
  `xattr -dr com.apple.quarantine`（未公证 bundle + quarantine = Gatekeeper 拦截）。
- **重启语义**：脚本 pkill 旧 App → 装新 → `launchctl asuser <uid> open` 重启；
  等待授权的旧进程被杀是设计内终点（Task 随进程死亡），不是错误路径。
- **取消授权 = 静默回退**（osascript -128 → idle），只有真失败才进 failed 态给重试。
- zip 顶层目录名随版本变化（FanCtl-{版本}/），布局探测不假设具体名字，只找
  "含 FanCtl.app 的目录"。

### 本轮教训
1. **`Character.isNumber` 对非 ASCII 数字（Nd 类，如 ٣）返回 true**——URL/路径消毒
   必须用 `isASCII && isNumber`；"看着像数字"不等于"是 [0-9]"。新测试当轮抓到。
2. **struct 无构造器模式匹配**：`if case let Failure(msg) = error` 只适用 enum
   associated value；对 struct 报 "pattern variable binding cannot appear in an
   expression"。用 `if let f = error as? Failure`。
3. `defaults read <相对路径>` 按域名解释而非文件——验证脚本一律绝对路径。

## R8（v3.8 兑现轮）：审计收敛 → 证据生产

### 转向依据
v3.6.1–v3.7 连续四轮审计驱动（4323 断言 + fuzz/mutation 净 100% + 消毒器零报告），
第五轮静态审查边际收益 < ε（收敛停机条件）。产品的差异化功能（学习系统）反而是
唯一从未被长期验证的部分 → 本轮从"找 bug"转向"让仪表产出可裁决的证据"。

### P2 对账（真机 ai-learn.json / ai-metrics.json，2026-09-08）
- **P4 高温门兑现**：75°/77°/79°/81° 桶分别 340/288/71/19 样本——门不饿死高温段，
  83°+ 无样本是机器没去（目标 72° 下峰值 81.3°），不是门的问题。与基线"82°+ 待积累"
  的悬念闭合。
- **包络健康度 5.8 → 1.43**：高温段旧非单调数据正被新样本洗净，观察协议继续。
- 评测账本随用户目标切换已重置（76→72），当前窗口 maxOvershoot 11.1°（旧窗口 18.8°）。

### D 项 dt 账本（预注册裁决规则——先于数据写下，防事后合理化）
- 背景（R4 跳过项 1）：dDelta = kD·clampedSlope·(1/dtNom)，clampedSlope=slopeRate·dt
  → dDelta = 3·kD·slopeRate（每拍与 dt 无关）但**每秒推力 ∝ 1/dt**。1s 快拍
  （v3.6.1 修复 tempChange 后真实发生）下 D 每秒推力是标称 3s 的 3 倍。
- 账本：ai-metrics 按拍长分桶累计 |P|/|D| 生效增量（快<1.5s/标称 1.5–4.5s/长>4.5s）。
  P 每秒贡献与 dt 无关 → **P 基线跨桶相等是账本自身校准线，不等先修账本再裁决**。
- **裁决规则**：账本 ≥7 天且快拍秒占比 >5% 时召开裁决——D 快拍/标称比 ≈1（漂移无
  实际影响）→ 永久关闭议题；≥2 且绝对影响可见 → 下一轮把 D 改秒基，VirtualMachine
  验证 3s 拍严格等价 + HIL 对比。中间态：继续积累。禁止在无账本数据时动控制律。

### 硬件画像（N=1 通用化第一块砖）
全部调参/验证/反经验来自一台机器，而 Releases 在向陌生机器分发。失败账本最重一条
"硬件问题不是算法问题"的前提是分得清这台机器长什么样。daemon 启动采集（机型/芯片/
OS/风扇数/传感器计数/功耗键）随 status 下发 + fanprobe 打印；画像只描述机器，
**不做学习数据移植**（机器特异，移植即污染）。

### 存活去抖（R4 跳过项 2 兑现）
下线判定需连续 2 次死观测，上线立即生效。权衡：假"活"= 多显示一轮旧数据；
假"死"= 清空用户正看着的决策状态。12s 轮询下判死延迟 +≈12s，值得。

### 本轮教训
1. **测试里禁止 `!`/`try!` 强解包**：两次 exit133 SIGTRAP——预期失败必须走 expect
   断言消息，guard 先绑定再断言。崩溃会吞掉全部测试输出（stdout 丢失），比红断言
   难排查一个量级。
2. **decodeIfPresent 只对"键缺失"返回 nil，键存在但类型错配照样抛错**。诊断类载体
   （画像）应逐字段 try? 降级——一条损坏字段拖垮整个 status 解码 = App 在最需要状态
   的时刻误判 daemon 离线（v3.6.3 reason 枚举同源教训）。
3. **Swift `??` 右结合**：`Int?? ?? nil ?? 0` 得 Int?，必须 `(a ?? nil) ?? 0`。
4. 分桶完备性契约锁"Σ桶样本=总样本"而非算术假设（首拍 dt=0 被 record 守卫跳过）。

## R7（v3.7 信任三角轮）计划审查的收获

计划三遍自审（数据流/可用性/结构）在执行前修掉 5 个真问题：daemon 只发采样点会让
冻结丢精度（改 App 直读 ai-learn.json）、边界锚点不该硬编码（继承用户曲线）、
"最优解"是过度承诺（改"快照"）、learnMap 每拍编码打穿写盘节流（样本数变化才重算）、
P2 feedforward 字段接口成本被低估（砍成六字段纯转述）。执行中又抓到 F9（Optional
init 参数静默吞值）——审查计划本身也是审查。UI 教训：Charts 无约束高度会溢出固定
卡片画到卡外；折叠展开是用户主动行为，卡片显式长高不违反"窗口恒定"（那条守的是
切模式动画）。

## R5 反经验（v3.6.2，我自己的事故）

- **测试进程写穿真实配置**：v3.6.1 的 tempChange 测试块漏调 engineTestEnv()，
  块内 `ConfigStore.saveConfig(...)` 把默认 curve 配置写进真实 /Library config.json，
  daemon 热加载后用户从 AI 模式被静默切到 curve（当日发现并恢复）。
  **规则：引擎级测试凡触碰 ConfigStore 必须先 engineTestEnv()；评审测试代码时
  把"这条测试动了哪些真实文件"当必查项**——测试的副作用审计和实现的副作用审计同等重要。

## R4（v3.6.1 对抗式审查轮）审查覆盖与跳过项账本

38 项指控（4 路并行 Explore 攻击面审查）→ 逐条人工核实：25 项修复、3 项按红线跳过、其余为夸大/不可达（如 App 侧 aiTargetEffective/palmComp 已有自清，仅 envTemp 真残留）。**跳过项（勿再试，除非新数据）**：
1. AI D 项 dt 归一化（kD·slope/dtNom ∝ 1/dt 漂移）——数学上确认与 P 项不一致，但改动即变控制行为，须真机 HIL 数据支撑；仿真调参在固定 3s 拍下两种口径重合，无数据判优劣。等 learnEnvelopeGap/真机数据账本积累后再议。
2. daemonAlive 单拍翻转零去抖——rename 竞态单次读失败现实概率低，属稳健性加固非缺陷。
3. CurveOptimizer 混合 tempSum 语义窗——v2.6.2 已 4 个版本，30 天保留期内旧数据早已轮出，暴露面趋零。

## 失败账本（反经验）

| 轮 | 假设 | 预测 | 实际 | 为何失败 | 何时不要再试 |
|---|---|---|---|---|---|
| #0-pre(UI) | 合并 CPU/GPU 成单瓦片消除投影暗带 | 更对称 | 用户否决（要回双独立玻璃卡原样） | 用户审美以 v3.4 原版为准绳 | UI 观感类改动先出对照图给用户挑，别自主"优化"结构 |
| #0-pre(UI) | thickMaterial 托盘吸收投影 | 观感更干净 | 用户否决（要原生液态玻璃） | 材质观感是硬性偏好不是参数 | 同上 |
| #0-pre(外部审计轮) | τ 自适应可压过冲 | 过冲↓ | 真机数据 +18.8° 在硬件散热极限内（族最坏 +42.8° 是 env33/R1.3 物理边界） | 硬件问题不是算法问题 | **永远不要**再动控制律追过冲，除非换机型后 maxOvershoot 突破物理预期 |
| #0-pre(v2.6 网络教训) | ①快拖滑块时反馈失配判故障 ②review 发现迟滞接线静默失败 | — | P0/P1 级误判 | 快拍语义与接线验证缺失 | 任何"快速路径"改动必须配引擎级拍序列测试；接线改动必须 grep 验证落点 |
| R35(计划期) | support 目录 `chmod 1775`（sticky）可堵住组内换文件 | 消 R23 剩余竞态面 | **未实施——解析否决** | `rename(2)` 的 S_ISVTX 检查落在**目标文件**上，而 config.json 恒 root 所有 → 非 root 的 App 把自己临时文件 rename 覆盖它必 EPERM，**App 唯一写配置通道全断**；`config.corrupted.*`"保留 5 个"上限也会因删不掉 root 备份而静默失效 | 不要再给 support 目录加 sticky。跨进程换文件的安全已由 fd 纪律覆盖（`O_CREAT\|O_EXCL\|O_NOFOLLOW` + `fchmod` + rename 永不跟随） |
| R35(计划期) | SMC init 失败改「engine 延迟初始化 + 常驻重试」 | 消 10s 重启循环 | **未实施——不成比例** | `engine` 从 `let` 改 `var` 会波及 ConfigWatch / SleepHandler / 看门狗（无 engine 时 heartbeat 语义要重定义），而真实故障形态只是"开机瞬间 IOKit 未就绪" | 启动竞态用进程内有界退避（0/2/8s）覆盖即可，不要为此重构 daemon 生命周期 |

| R39 | 给构建脚本加一条"生成物必须等于 VERSION"的断言，顺序照旧（测试在前、重生成在后） | 防住版本漂移 | **自锁死**：改 VERSION 后 build.sh 必红，而能改写生成物的正是被挡住的那一步；本地 `./scripts/build.sh` 第一次跑就撞上 | 任何"由构建脚本自我修复的不一致"都不许做成前置测试断言；要么把重生成排在断言之前，要么只在 CI 上查 |
| R37(审查轮) | 采信审查方"BSD `install` 保留源文件 mtime\"的实测结论 → 要把"daemon 装于 X"改成构建时刻 | 该字段谎报安装时间 | 本机 `install -m 755 src dst` 实测：src=2020-01-01、dst=当场时间，**不保留**；mtime 就是最后一次装/升级 | 审查给的"实测"必须是**自己能重跑的命令**；涉及系统调用语义的指控，先在同一台机器上重跑一遍再改代码 |
| R39(交付链) | 把新 CI 门的逻辑**抄成一行**在 /tmp 复算六种输入，就算"这段 shell 验过了" | 六种输入全绿 ⇒ 发版链安全 | v4.2.4 第一次 tag 触发即红（`command substitution: line 10: syntax error near unexpected token '\|'`），Release 未创建、tag 白推 | 复算的是**算法**不是**将要发出去的那段文本**；YAML 里折行的 shell 与本地一行版语义相同、语法待遇不同 | 改 `.github/workflows/**` 里的 shell，只认"对文件里那份原文跑检查"；手抄一份重写来验等于没验 |
| R39(交付链) | 用 `bash -n` 抽出 run 块做语法门，就能兜住这类折行错 | 一道静态门覆盖所有 shell 语法 | **对同一段坏文本 `bash -n` 返回 0**——命令替换的内容要到执行时才解析，`-n` 不进去；没有 `set -e` 时整脚本退出码还是 0 | bash 的 `-n` 只解析它当时能定界的语法；`$( )` 内是延迟解析域 | 不要把 `bash -n` 当 shell 语法的完备门。要兜 `$( )` 内错，只能**静态禁掉危险形状**（行首续行操作符）或真的执行（发行步骤不许执行） |

## 策略元经验

- 能耗/SMC/文件 IO 类假设：可全自动验证、常落地 → **优先选**。
- 控制律类假设：多需真机数据或升级给人 → 只在账本有明确数据支撑时选。
- UI 观感类：用户已钉死参考标准（v3.4 双玻璃卡）→ **默认不碰**，除非用户点名。
- 审计驱动（读代码+真实运行数据找杠杆）成功率远高于直觉驱动。
- 每轮必须给改前→改后数字；接线上一次教训：grep 验证替换真实落点。
- R1-R3 全部落在 App 侧展示数据链：daemon 核心路径（ControlEngine 每拍）的剩余候选
  （Calendar 构造等）单点收益 ε 级、验证成本高 → **收敛停机**，符合"下一轮预期收益 < ε"。
- goal 细节陷阱：`swift build ... | grep -c && 跑测试` 的 shell 短路会让测试静默跳过——
  验证命令必须独立成句跑（R3 曾踩）。
