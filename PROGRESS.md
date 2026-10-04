# PROGRESS — 安全边界加固（风扇管理 / FanCtl）

## 目标 · 顺序 · 最大风险（≤10 行）
1. 目标：把「谁能写 SMC」变成依赖图事实，把「结束进程」绑到进程实例标识上，温控行为与数据协议不变。
2. 顺序：任务 0 基线 → 任务 1 拆 target（SMCCore 去 IOKit；SMCReadout 只读；SMCDriver 读写，仅 fanctld）→ 任务 2 进程实例校验+失败关闭 → 任务 3 文档。
3. 最大风险 A：ControlEngine/FanController 的读写共用私有状态，写方法外迁会波及测试的构造路径；测试断言与下限不许动，只许改 import。
4. 最大风险 B：仓库内测试静态门按文件路径读源码（Config/ControlEngine/DiagnosticReport.swift），拆分不能把这些文件挪出 Sources/SMCCore/。
5. 最大风险 C：spinwatch 在仓库外，alerts.json 无进程启动时间字段 → 结束动作只能失败关闭，不能假造验证成功。
6. 取舍：安全边界 > 现有控制行为与数据兼容 > 改动范围 > 文件整洁；为此接受只读/读写两条 IOKit 通路的小段重复。

## 任务 0 基线（实测 2026-10-01，全部真实执行）
- `git status --short --branch`：`## main...origin/main`，17 个 M（含 ci.yml/EVOLUTION/README/RELEASE-NOTES/VERSION 与 12 个 Sources 文件）+ 3 个 ??（SMCCore/ProcessIdentity.swift、SMCCore/SpinAlert.swift、fanctltests/Fixtures/spin-alerts.sample.json）。均为任务开始前既有改动，全程不 reset/stash/checkout。
- `swift --version`：swift-driver 1.168.6 / Apple Swift 6.4，Target arm64-apple-macosx27.0.0。
- `swift run -c release --disable-sandbox fanctltests`：**✅ 全部通过：5344 项断言（110 个测试组）** → 本机基线 5344/110，契约下限 5319/101。源码注释的 5344/110 与本机一致；README 的 5325/109 为陈旧记录。
- `swift package describe`：targets = SMCCore + fanctld/FanCtlApp/fanprobe/fanctltests，四个消费者全部依赖 SMCCore（本轮要改的就是这条边）。
- 上一轮遗留的两个测试忙循环（pid 24949/25953）已确认自行退出，`pgrep -f 'while True: pass'` 无残留。

## 任务 1 现状证据（只读调查）
- 唯一 `import IOKit` 的硬件文件：Sources/SMCCore/SMC.swift（SMCConnection:162，读 keyInfo:200/read:228/readDouble:251/allKeys:300，写 write:258/writeDouble:275，私有 connection:163/keyInfoCache:164/lock:165）。
- 第二层混合体：Sources/SMCCore/Fans.swift 的 FanController（写 setForcedRPM:122/127、restoreAuto:158、restoreAutoAll:174、setForcedPercentsAll:193；读 state:83、allStates:114、rpm:181/186 等）。
- ControlEngine.swift:191 `init(fans: FanController, sensors: TemperatureSensors, hooks:)`，写调用点 1021/1071/1441 与 restoreAutoAll 255/267/468/574/1045/1132；HardwareProfile.swift:46 也吃具体类。
- 消费面：FanCtlApp 零硬件类（只用数据模型/曲线策略）；fanprobe 只用读（SMCConnection:24/74、FanController 读 fanCount/allStates、TemperatureSensors 读）；fanctld 独占写；fanctltests 用 MockSMC 实现 SMCIO，不碰 SMCConnection。

## 任务 1 决策与理由
- 拆法：SMCCore（共享模型/策略，无 IOKit）+ SMCReadout（IOKit 只读，fanprobe 用）+ SMCDriver（IOKit 读写 + FanController 写扩展，仅 fanctld 与测试用）。
- 建议项「按最小改动迁移」在此按更强的边界执行：只读通路里不放任何 write 原语，也不把 raw `call` 暴露成 public，否则 App/fanprobe 仍可自造写请求，边界只是"没有语义 API"而非"没有能力"。代价是 80 字节参数结构体与 open/close 两个 target 各一份，已在 docs/architecture.md 记因。
- ControlEngine 必须留在 Sources/SMCCore/（测试静态门按该路径读源码），因此它对风扇的读写改走 SMCCore 内声明的协议，写实现落在 SMCDriver。

## 任务 1 结果（已完成，全部实测）

改动文件：`Package.swift`、`Sources/SMCCore/SMC.swift`（去 IOKit/去 SMCConnection，拆 SMCIORead/SMCIO）、
`Sources/SMCCore/Fans.swift`（`FanController`→`open class FanReadout` 只读 + `FanReading`/`FanActuating` 协议，
写方法移出）、新增 `Sources/SMCCore/Driver/SMCDriver.swift`（IOKit 读写连接 + `FanController: FanReadout, FanActuating`）、
新增 `Sources/SMCCore/Readout/SMCReadout.swift`（只读连接，无写原语）、
`ControlEngine.swift`/`HardwareProfile.swift`（`fans` 改协议类型，各 1 行）、
`fanprobe/main.swift`（换 `SMCReadConnection`/`FanReadout`）、`fanctld/main.swift` + 3 个测试文件（加 `import SMCDriver`）。

命令与输出：
- `swift build -c release --disable-sandbox --scratch-path .build-app-sdk`（全目标）→ `Build complete! (29.63秒)`，0 error 0 warning
- 依赖图：`FanCtlApp -> ['SMCCore']`；`fanprobe -> ['SMCCore','SMCReadout']`；`fanctld -> ['SMCCore','SMCDriver']`
- 只建单产品的干净 scratch 模块清单：App 侧只有 `SMCCore.swiftmodule`（无 SMCDriver/SMCReadout）；
  fanprobe 侧有 `SMCCore` + `SMCReadout`，**没有 SMCDriver**
- 预期失败导入（临时探针，跑完已删）：
  - `Sources/FanCtlApp/BoundaryProbe.swift` → `unable to resolve module dependency: 'SMCDriver'`
  - `Sources/fanprobe/BoundaryProbe.swift` → 同上
  - 反例教训：共享 scratch 下同样的探针**会编译通过**（别的产物已建出来），自证无效 → 必须用只建该产品的干净 scratch
- fanprobe 真机只读跑通：`传感器: CPU x54 ... 风扇数量: 2 / 风扇 1: 当前 5112 RPM | 目标 5029 | 范围 1350 ~ 5349`

## 任务 2 结果（已完成）

- 新增 `Sources/SMCCore/SpinKillGuard.swift`：`ProcessInstance`（启动时刻+uid+可执行路径）、
  `KillDenial`（5 种拒绝原因，每条带 userText）、`ProcessProbe.live`（sysctl KERN_PROC_PID + proc_pidpath）、
  `SignalSender.live`（kill(2)）、`verify`/`execute`/`canKill`。**核验不过不触碰 sender**。
- `SpinAlert` 新增 `startSeconds`/`uid` 可选字段：decode 宽松、encode 用 `encodeIfPresent`
  → nil 时键集合与既有夹具逐字一致，「后台空转 schema 同源(R78)」门仍绿（数据协议未改写）。
- 接线：`FanModel.killSpin(_:)` 取代裸 pid 版（旧 `killSpinProcess(pid:)` 已删除，不留绕过守卫的入口）；
  面板按钮核验不过时禁用并显示「结束不可用」+ 原因；通知分类不再注册「立即结束」动作，
  delegate 收到旧分类残留的该动作时一律走守卫、拒绝后回投说明通知（`explainKillDenied`）。
- 新增回归 `Sources/fanctltests/TestsKillGuard.swift`（组「空转结束进程实例守卫(R81)」）：
  缺标识/只缺 uid/进程已退出/pid 复用/uid 不符/路径不符 → 六条拒绝且**信号日志为空**；
  标识齐全 → 恰好一个 SIGKILL 且只发给目标 pid；最后用**真夹具 + 真实 live 探针**断言现网告警一律失败关闭。
- `swift run -c release --disable-sandbox fanctltests` → `✅ 全部通过：5364 项断言（111 个测试组）`
  （基线 5344/110 → +20 断言 +1 组；契约下限 5319/101 与 ci.yml 均未改）
- `./scripts/test-root-scripts.sh` → `root 脚本门禁：66 通过 / 0 失败`

## 任务 3 结果（已完成）

`docs/architecture.md` 新增两节：「target 依赖边界：谁有权写 SMC（R81）」（含依赖图、
只读通路为何不含写原语、结构体双份的代价、以及"必须用干净 scratch 自证"的验证方法）与
「结束空转进程：必须绑定进程实例（R81）」（4 条规则 + 当前生产端缺字段导致的失败关闭现状）。
未大规模重写 ControlEngine/FanModel/PanelView（各只动必要的几行）。

## 独立复核（2026-10-02，新会话对上轮交付逐条实测；源码零改动）

上轮 PROGRESS 声称全部完成，本轮**只复核不改码**（仅临时增删探针文件，跑完即删）。

**环境发现（重要，进 BLOCKED.md）**：本机 CLT 的 MacOSX27.0.sdk 把 SwiftUI `@State`
声明为 `#externalMacro(module:"SwiftUIMacros")`，但整套 CommandLineTools 内**不存在**
该插件 dylib（SDK、usr/lib/swift/host/plugins 均无）→ 默认 SDK 下 FanCtlApp 无法编译，
最小复现：`swiftc -sdk MacOSX27.0.sdk` 编译含 `@State` 的 3 行文件即报
`plugin for module 'SwiftUIMacros' not found`。`@State` 在 MacOSX26.5.sdk 里仍是
propertyWrapper，无需插件。规避：`SDKROOT=…/MacOSX26.5.sdk`。昨晚 23:41 的成功构建
同样是 26.5 SDK（.build-app-sdk/out/.../XCBuildData/build.db 记录 2753 条 26.5 引用）。
**工具链环境问题，与本轮代码无关**；根治需完整 Xcode 或 Apple 修复 CLT，仓库内无可改对象。

复核命令与结果（全部真实执行）：
1. `git status --short --branch`：17 M + 8 ??，与上轮交付时一致，无额外源码改动。
2. `swift --version`：Apple Swift 6.4（swift-driver 1.168.6），arm64-apple-macosx27.0.0。
3. `swift package describe --type json`（依赖图铁证）：
   `FanCtlApp -> ['SMCCore']`；`fanprobe -> ['SMCCore','SMCReadout']`；
   `fanctld -> ['SMCCore','SMCDriver']`；`fanctltests -> ['SMCCore','SMCDriver']`。
4. `SDKROOT=…26.5 swift build -c release --disable-sandbox --scratch-path .build-verify`
   → **Build complete! (52.19秒)**（fanctld/FanCtlApp/fanprobe/fanctltests 全过；仅 ld 搜索路径无害告警）。
5. `SDKROOT=…26.5 swift run -c release --disable-sandbox --scratch-path .build-verify fanctltests`
   → **✅ 全部通过：5364 项断言（111 个测试组）**，exit=0
   （≥ 基线 5344/110；≥ 契约下限 5319；5364−5344=+20 恰为 TestsKillGuard 运行期断言数）。
6. 预期失败导入（干净 scratch 单产品构建 + 临时探针，验后即删）：
   - `Sources/FanCtlApp/BoundaryProbe.swift` `import SMCDriver`
     → `error: …BoundaryProbe.swift:2:8 unable to resolve module dependency: 'SMCDriver'`；
     该 scratch 产物仅 `SMCCore.swiftmodule`（无 SMCDriver/SMCReadout）。
   - `Sources/fanprobe/BoundaryProbe.swift` `import SMCDriver` → 同样
     `unable to resolve module dependency: 'SMCDriver'`；
     fanprobe scratch 产物 = `SMCCore.swiftmodule + SMCReadout.swiftmodule`，无 SMCDriver；
     反向对照：删探针后 fanprobe 正常构建 `Build complete! (28.03秒)`。
7. KillGuard 行为演示（独立程序静态链接已构建 SMCCore.o，非测试套件、不改 Package.swift）：
   ①缺标识 ②只缺 uid ③进程已退出 ④pid 复用 ⑤uid 不符 ⑥可执行不符
   → 六种全部**拒绝且实际发信 0 次**；⑦标识齐全相符 → 放行、**恰好 1 次且只发给 pid 4242**；
   ⑧真夹具 2 条 + **真实 live 探针** → 全部 `alertHasNoInstanceIdentity`、发信 0 次（失败关闭）。
8. 数据兼容：夹具单条键集合 14 键、无 startSeconds/uid（SpinAlert 的 `encodeIfPresent`
   在字段为 nil 时键集不变 → R78 schema 同源门绿）；`git diff Config.swift` 的 20 行为
   既有 R77 可选字段 `aiHighEffort`（`decodeIfPresent` 向后兼容旧 status.json），本轮未动。
9. docs/architecture.md 含「target 依赖边界：谁有权写 SMC（R81）」与
   「结束空转进程：必须绑定进程实例（R81）」两节（行 18/40）。
10. 收尾：删除复核用 scratch（.build-verify/.build-probe-app/.build-probe-probe——
    .gitignore 不在允许改动清单内，不留未跟踪目录）。

## R82 占用页扩容 + 进程名汉化补齐（2026-10-02 第二轮，用户直接反馈）

用户原话：「占用那里固定显示 3 行不够看」「还有一些软件进程之类的，你要让它完成汉化」。
改动 5 个文件，构建与全量测试复验通过（5372 断言 / 111 组，+8 条新断言）：

1. `Sources/FanCtlApp/MonitorViews.swift`：ProcessHogView 榜单 prefix(3)→prefix(5)、
   VStack spacing 4→3。92pt 槽内预算：GPU 行 14 + 头距 3 + 5×12 行 + 4×3 行距 = 89 ≤ 92，
   字号不缩，面板「窗口恒定」设计约束不变。
2. `Sources/SMCCore/ProcessIdentity.swift`：
   - 对照表 +47 词条（kernel_task/mds_stores/bluetoothd/tccd/amfid/备份更新崩溃日志等
     系统后台、WebKit XPC、Safari/Terminal/计算器等 App 名、swift-frontend/clang/git/docker
     等工具链——编译霸榜主力）；
   - 新增 `localizedBundleName`：读 App 内 `zh_CN.lproj`/`zh-Hans.lproj` 的
     InfoPlist.strings（CFBundleDisplayName/CFBundleName），优先级置于主 Info.plist 之前
     ——Apple App 的主 plist 是英文名，中文只在本地化表（实测 Safari → "Safari浏览器"）。
     TextEdit/Terminal 无该文件 → ③回落照旧，已有断言不受影响。
3. `Sources/FanCtlApp/PanelView.swift`：空转行进程名、结束确认框标题改走 ProcessIdentity
   中文名；确认框正文补原始进程行（杀进程须见真身，悬停说明仍有完整 exe 路径）。
4. `Sources/FanCtlApp/NotificationService.swift`：空转通知两个标题同样走中文名。
5. `Sources/fanctltests/TestsEngine.swift`（testProcessIdentity 组追加 8 条，既有断言零改动）：
   kernel_task/mds_stores/bluetoothd/WebKit XPC/clang 五条对照表、假 .app 夹具两条
   （本地化中文 > 英文 plist 的优先级 + detail 同源）、旧词条不回归一条。

真机辨识实测（独立程序链接 SMCCore.o）：Safari 主程序→Safari浏览器（本地化表生效）、
Terminal→终端、kernel_task→内核任务（系统核心）、mds_stores→聚焦索引（存储）、
WebKit WebContent→Safari 网页内容、clang→C 编译器、bluetoothd→蓝牙服务。
彻底认不出的仍回落原名（诚实 > 编造，R79 原则不变）。

## R82 续：对抗式审查 + 本机安装（2026-10-02 第三轮，用户指令「自己安装更新。然后自己对抗式审查」）

### 对抗审查发现并修复 3 处（全部围绕 SpinKillGuard 报错保真性）
1. **EPERM 误报"进程已退出"**：`SignalSender` 只返回 Bool，非 root 对 root 进程
   kill -9 得 EPERM 被报成 `.processGone`（"该进程已经不在了"——诱导用户以为目标已死）。
   修复：sender 返回 **errno**，`EPERM → .signalNotDelivered`（新增拒绝原因，
   userText 说明"它仍在运行"），`ESRCH → .processGone`。
2. **跨 uid 读不到路径被误判"已退出"**：`proc_pidpath` 对跨 uid 进程被拒时，live 探针把
   整个实例返回 nil → verify 落进 `.processGone`。修复：探针用空路径表达"在但读不到"，
   verify 新增 `.instanceUnverifiable` 失败关闭（诚实原因："身份核验无法完成"）。
3. **文档缺口**：任务书要求的「剩余 PID 竞态」记录缺失（verify 与 kill(2) 之间的
   TOCTOU 窗口，macOS 无按实例发信号的原子原语）→ architecture.md R81 节补第 5 条
   规则 + 竞态专段，明示"缓解不归零"。

### 对抗验证证据（全部真实执行）
- **变异测试（证明回归有牙）**：M1 删 uid 比对 → 「uid 不一致必须拒绝」红；
  M2 删启动时刻比对 → 「pidReused」+「零信号」两条红；还原后 shasum 字节一致、全绿。
- **真机端到端（真进程/真探针/真发信）**：① spawn sleep + 真身份 → SIGKILL 送达、
  进程真死；② 启动时刻差 2 秒 → `pidReused` 拒绝、目标存活；③ launchd（root）带真身份
  → 核验放行、kill 得 EPERM → 如实报 `signalNotDelivered`、launchd 存活。
  （连验证脚本自己都先犯了 EPERM/ESRCH 混淆——存活检查把 EPERM 当死亡，已修正重跑。）
- 测试终态 **5376 断言 / 111 组全绿**（较上轮 +2 instanceUnverifiable、+2 EPERM/ESRCH）。

### 本机安装（用户解除"不装系统目录"限制后）
- 官方链 `./scripts/build.sh`：版本重生成 → 全量测试 → 产物组装 → 版本自证 → ad-hoc 签名。
- `./scripts/deploy.sh` 免密部署 App：装机 `/Applications/清风.app` 二进制与 dist **逐字节
  一致**（cmp 验证），版本 4.2.38 (129)，单实例运行中。
- **VERSION 4.2.37 128 → 4.2.38 129**（含 RELEASE-NOTES 4.2.38 要点行，root 脚本门禁强制
  同源）：理由是装机 daemon 为 10-01 23:02 旧码且**同版本号**——build.sh 纪律明示
  "同号不同码 = P1"，升号消除歧义。build.sh 过程中被 root 脚本门禁拦下一次（缺要点行），
  按门禁要求补齐后通过——门禁按设计工作。
- **待用户一步**：`sudo ./scripts/install.sh` 刷新 daemon（需密码；dist 内 4.2.38 (129)
  配套产物就绪）。R81/R82 不改 daemon 控制行为，旧 daemon 继续运行无碍。

## R82 续二：汉化补漏（2026-10-02 第四轮，用户反馈「清风为什么是英文名」）

用户在装好的 4.2.38 里仍见到英文进程名，点名清风自己。根因：**清风自家构件
（FanCtl/fanctld/spinwatch）不在词表**——exe 字段缺失只剩裸名的场合（空转告警常如此）
全露英文。本轮：

1. 词表 +25 词条：清风全家（FanCtl→清风、fanctld→清风守护进程、fanprobe→清风诊断工具、
   spinwatch→清风空转哨兵）、国民 App 构件（微信内置浏览器/小程序/播放器、钉钉、飞书、
   百度网盘、迅雷、爱奇艺、网易云、QQ音乐、微软自动更新、VS Code 全家、Gradle）、
   mdworker/findmydeviced/mobiletimerd。
2. `readableFallback`：未知 `com.apple.*` 逆向 DNS 名此前被 `deletingPathExtension`
   砍成 `com.apple.Safari` 残名 → 改为「Apple 系统组件（Safari.SandboxBroker）」
   （括号留原文可检索，不编中文名）。
3. 角色词样式按用户要求改括号式：「抖音 · 渲染进程」→「抖音（渲染进程）」；
   ProcessInfo 增加 `app` 纯名通道，过热通知元凶行用它避免「抖音（渲染进程）（30%）」双括号。
4. 测试 +5（清风裸名/daemon 裸路径/哨兵/微信构件/逆向 DNS 可读化）→ **5381 断言 / 111 组**。
5. 真机实测：清风 bundle 路径→清风（zh-Hans 本地化表）、裸名 FanCtl→清风、
   fanctld→清风守护进程、spinwatch→清风空转哨兵、微信构件→中文、
   未知组件→「Apple 系统组件（audio.SystemSoundServer）」、Safari→Safari浏览器。
6. VERSION → **4.2.39 (130)**（上轮 4.2.38 装机后代码又变，按「同号不同码=P1」纪律升号；
   RELEASE-NOTES 4.2.38 条目改写为 4.2.39 合并要点），build.sh 全链过 + deploy.sh
   重新部署，装机二进制与 dist 逐字节一致，运行中。

## R82 续三：汉化检测化（2026-10-02 第五轮，用户指令「直接去检测来去做」）

不再等用户逐个报，把检测能力做进工具并按数据补词：

1. **新增 `fanprobe --zh-scan`**（只读体检，与 --report 同源承诺）：扫两类"会出现在
   界面上的名字"——当前全部运行进程（`ps -Aceo comm=`，含裸名条目）+ 本机已装 App
   主程序（/Applications、/System/Applications 及 Utilities、CoreServices、~/Applications，
   读 CFBundleExecutable），用 `ProcessIdentity.hasChinese`（新增，+2 断言）筛出翻不出
   中文的名字列成欠账清单。词表维护从此有据可查。
2. **数据驱动补词约 110 条**（四批 + 实时 CPU 榜挑拣）：
   - Apple 系统 App 官方中文名 35 个（日历/备忘录/预览/系统设置/时间机器/词典/无边记/
     手记/快捷指令/iPhone 镜像等）——实测它们的 zh_CN.lproj 无 InfoPlist.strings，只能查表；
   - 实用工具 15 个（磁盘工具/屏幕共享/脚本编辑器/数码测色计等）；
   - CoreServices 界面组件 15 个（控制中心/隔空投送/屏幕使用时间/磁盘映像装载器等）；
   - 系统服务 20 个（oahd→Rosetta 转译服务、signpost_reporter、powermetrics、adid/akd→
     Apple 账户、cloudphotod、secd、syslogd、diskarbitrationd 等）；
   - 第三方通行名（腾讯柠檬清理/网易云全构件/动态壁纸/ToDesk 服务/vivo 同步等）；
   - 按本机实时 CPU 榜（`ps -r` ≥1%）逐个核验，真·会冒头的全部覆盖。
3. **bundle 解析结果过词表后处理（gloss()）**：修 exe 名与 bundle 名不一致的漏翻
   （实测 Microsoft Defender Shim 的 exe 叫 launcher，bundle 英文名现会再查一遍词表）。
4. **覆盖度数据**：扫描 868 名 → 欠账 732 → **640**。剩余构成：品牌名刻意保留
   （Telegram/iTerm2/IINA/QQ/ChatGPT/App Store/Siri/TV 等——中文 Finder 也这么显示），
   CoreServices 内部组件与 PrivateFrameworks 守护（无通行中文名）。
   本机 CPU ≥1% 榜除品牌名（Atoll/State/ZCode/xray）外**全部中文**。
5. 测试 **5385 断言 / 111 组**全绿；VERSION → **4.2.40 (131)**，RELEASE-NOTES 重排
   （4.2.40 详细要点 + 4.2.39 细节恢复）；build.sh 全链过 + deploy.sh 部署，
   装机二进制与 dist 逐字节一致，运行中；dist/fanprobe 复扫确认工具可用。

## R82 续四：裸名 helper 通用解析（2026-10-02 第六轮，用户「又看到有个英文的，研究明白」）

不复现不知道——本机占用榜当时前五里三个是英文/半英文：`zcode-cli`、
`ZCode Helper (Renderer)`、`抖音 Helper (Renderer)`（半中半英最刺眼，正是用户看到的）。

**根因**：ps 的 comm 对 Electron/Chromium 系 helper 常只给**裸名**（无路径），
做不了 bundle 归属 → 此前原样透出，"Helper (Renderer)" 英文构件名直达界面。

**修复（通用规则，非加词）**：`parseBareHelper`——无路径的 "X Helper"/"X Helper (角色)"
按构件命名惯例拆成 (软件 X, 中文角色词)，X 再过词表：
- `抖音 Helper (Renderer)` → 「抖音（渲染进程）」（用户此前点名的括号式）
- `ZCode Helper (GPU)` → 「ZCode（图形进程）」（品牌保留 + 中文角色）
- `Google Chrome Helper` → 「谷歌浏览器（辅助进程）」
- 同软件不同 helper 的归并键统一为软件名 → 占用榜不再按角色重复列行
  （实测两个抖音 helper 合并为一行「抖音（渲染进程）」27.6%）
清理被取代的旧空格样式词条 5 个（Code Helper 家族/网易云 Helper×2），
新增 `Code`→VS Code 编辑器、`zcode-cli`→ZCode 命令行。

**过程事故（如实记录）**：编辑词表时把 5 个键加重复——Swift 字典字面量重复键是
**运行时 trap**（exit 133），构建期完全不报，全量测试瞬间无声死。用脚本化查重
（226 键零重复）定位后去重恢复。教训：词表改完应跑查重脚本再提交。

**回归 +6 断言**（解析样式/主名过词表/归并键一致性）→ **5391 断言 / 111 组**全绿；
VERSION → **4.2.41 (133)**，build.sh 全链过 + deploy.sh 部署，装机二进制与 dist 逐字节
一致，运行中。实时复测占用榜：`抖音（渲染进程）/ ZCode（渲染进程）/ State Tool（品牌保留）`。

## R82 续五：第一性原理全面审查 + 自身占用审计（2026-10-02 第七轮）

用户指令：全面优化、做成稳定可靠的软件、检查自身占用是否超标。先测后改，只动有据的。

### 自身占用实测（结论：无超标、无泄漏）
- **App（面板关闭态，60s × 12 次采样）**：CPU 0.0%（偶发 0.7–4.9% 同步脉冲）；RSS 名义
  127MB 但 vmmap 实测 **物理占用 47.4MB（峰值 52.8MB）**——ps 的 RSS 把共享库页计入，
  虚高 2.7 倍。60s 内 RSS 零增长 = 无泄漏。SwiftUI 菜单栏 App 的正常水位。
- **daemon**：9.8–10.0MB 稳定，CPU≈0（单拍脉冲 3%）。
- **最大自身负载 = AI 模式的 powermetrics 分项功耗采样**：实测采样瞬间 ~88% 单核
  （~0.9 CPU-s/次）。节奏是刻意的自适应控温语义（≥80° 或 AI 主动 10s、<55° 60s、
  AI 空闲交还视同非 AI；curve 模式不采样——调用点只在 AI 分支 ControlEngine:668）。
  平均成本 1.5–8.8% 单核，**刻意不改**：改采样节奏/窗口 = 改 AI 控温输入。已记 BLOCKED。
- App 子进程全部有超时保护；强拆包（try!/as!/first!）在 FanCtlApp/SMCCore/fanctld
  **零命中**；定时器全部 weak-self，面板关闭即停采样。

### 本轮落地的三处加固
1. **词表重复键回归门**（新测试组「进程词表完整性(R82)」，置于测试序列最前 + 尾部复跑）：
   4.2.41 事故（字典字面量重复键 = 运行时 trap、构建期无症状、stdout 被缓冲吞掉）
   从此被源码静态查重在测试期拦死——变异验证：注入重复键 → 门的可读诊断立即红字
   + exit 1（诊断经 fflush 幸存）。附带规模下限（≥200 键）防整段汉化被静默清空。
2. **测试 harness 失败打印加 fflush(stdout)**：崩溃场景下诊断信息不再丢失。
3. **升级链 ditto 解压超时**（SelfUpgradeService.runDitto，60s + SIGTERM→SIGKILL 升级，
   nonisolated 同步函数——async 上下文禁用 DispatchSemaphore.wait）：
   磁盘/挂载异常不再让升级永远停在 validating，报可重试的失败。

### 审查过但不改的（记录理由）
- powermetrics 采样节奏：控温语义的一部分（见上）。
- `SpinAlert.swift:92` 的 `Int??` 编译警告：垃圾 Codable 池的刻意模式（R78），
  警告文本是编译器对模式的误读，行为正确。
- ditto 之外的两处升级子进程（osascript 等用户输密码、bash watcher 自带退出）：不可加超时/已自洽。

测试 **5397 断言 / 112 组**全绿；VERSION → **4.2.42 (134)**；build.sh 全链过 + deploy.sh
部署，装机二进制与 dist 逐字节一致，运行中（新实例冷启动物理 16.8MB，随 UI 加载回稳态）。

## R82 续六：全面打磨轮（2026-10-02 第八轮，用户「全方面的去打磨」）

表面扫描（UI 文案/通知/帮助全量 grep） + 视觉验证工具补齐：

1. **今日战报时长去英文残留**："2h30m" → 「2时30分」——全 UI 扫描出的唯一英文字母残留。
2. **占用页补独立快照 `--snapshot usage`**：它此前是四个监控 tab 里唯一没有视觉验证
   路径的。演示数据刻意覆盖排版最坏情况（最长名"网易云音乐（渲染进程）"、满格 94%
   饱和条、品牌混排），PNG 渲染目检通过：5 行无裁剪、全中文、配色分级正确。
   今日页演示数据同步调到 1h+，让新的「时/分」格式进视觉覆盖。
3. **README** 诊断清单补 `fanprobe --zh-scan`（README 的断言数已是"以徽章为准"活口径，无需修）。
4. **docs/architecture.md** 新增「自身资源水位（实测基线）」：App 47.4MB / daemon 9.8MB /
   powermetrics 成本核算 + "水位明显劣化即回归"的判据，给后续维护者对照基准。
5. 其余扫描结论：Text/NSAlert/通知文案零英文残留（RPM/CPU/GPU 等技术缩写除外）；
   zh-scan 欠账 631（较上轮 -9，均为进程增减噪声，无新增可确凿翻译项）。

测试 **5397 断言 / 112 组**全绿；VERSION → **4.2.43 (135)**；build.sh 全链过 + deploy.sh
部署，装机二进制与 dist 逐字节一致，运行中。

## R82 续七：全链路诊断 + 散热片死键剔除（2026-10-03，用户「全链路、每一个细节」）

**发现（真实运行数据）**：fanprobe --report + status.json 逐帧比对发现「散热片 79.4°」
比 CPU 核心（55°）还高 24°——物理不可能。40s 采样证实**卡死键**：4 次读取纹丝不动
精确在 79.421875（1/64° 量化值），而同期 cpuDie 在 8.4~55.9 正常波动。46 个散热片键
（Th/Tf/TA 前缀）取 max，死键永久霸榜，最热页把「散热片 79°」排第一误导用户。
消费面核查：SensorReadings.heatsink 全部是展示消费（status 行渲染/诊断报告/最热页），
控制引擎零引用；但 TemperatureSensors.heatsinkTemperature 是环境谷值候选（控制面）——
**修法必须外科分离**。

**实施（展示路径专用）**：
- 新增 `heatsinkDisplayTemperature`：逐键记录搭 heatsinkTemperature 既有 10s 全扫的
  便车（**零额外 SMC 读**，不动 testSMCReadBudget 预算门），连续 30 个窗口（约 5 分钟）
  位级全同即判死剔除；活键变化即时除名；全判死时**归零**（最热页隐藏该行）。
- `heatsinkTemperature`（环境路径）**原语义零变化**——含死键原值照旧，79.4 在 (5,45)
  候选区间外本就被排除，有断言钉死。
- rescan 时追踪状态全量复位。

**测试抓出设计缺陷并修正**：首版兜底在"全部键都被剔光"时把含死键旧 max 又请回来——
测试的"活键也不动"场景暴露了它。修正为**归零**（SensorReadings.heatsink=nil → 最热页
隐藏该行），符合"无效读数必须为 0，不伪造兜底值"的既有纪律。
新回归组「散热片死键剔除(R82)」7 断言：未达阈值诚实展示/达阈剔除/活键即时反映/
死键复活除名/全冻结归零/控制面钉死×2。

**真机端到端实证**（只读 SMC 连接，阈值=12 窗口）：scan1-11 原值=展示=79.421875；
**scan12 起展示值跳变 48.77 → 42.13°**（真实散热片温度，物理合理、随负载波动），
原值路径全程 79.42 纹丝不动——死键剔除生效且控制面零扰动，双路径行为均如实。
测试 **5404 断言 / 113 组**全绿；VERSION → **4.2.44 (136)**，build.sh 全链过 + deploy.sh
部署。**注**：最热页的散热片行要等 daemon 刷新（sudo ./scripts/install.sh）才用上新逻辑
——App 只读 status.json，展示值由 daemon 合成。

## R82 续八：全链路狩猎轮（2026-10-03，用户「按这个思路继续寻找、继续打磨」）

延续"真实运行数据找问题"的方法，链路逐段过：

**防线盘点（结论：控制面防线完整）**：ControlEngine 有卡死门（5 分钟逐位不变 + 功耗
波动 ≥10W → 交还系统）与偏低门（芯片不可能比环境冷 12°，90s 锁存——v3.0 就是为
cpuDie 8.4° 坏读数加的）；daemon 日志仅 5 条 powermetrics 自愈事件，无故障积累。

**三处打磨落地**：
1. **最热列表补 deglitch**：主卡有坏读数防线、最热列表没有（只有 sanitize）——实测
   cpuDie 8.4° 类坏读数会在最热页闪现。现与主卡同源防御（逐部件独立计数，复用
   SMCCore 同一份 deglitchTemperature）。
2. **散热片展示判据推倒重来（时间基 → 物理）**：第一版"位级冻结判死"被自己写的
   测试当场推翻——测试里"活键不动"场景暴露两件事：① 怠速下真实传感器也会位级
   冻结 5 分钟，时间基判据会误剔真实读数；② 推广到环境候选路径会误删真实环境
   代理（TPVD 恒 45.85 可能是真恒温而非死键）。改为**物理判据**：散热片键 >
   max(核心,GPU)+10° 只可能是坏读数——常态（核心 50~55°）剔掉 79.42、核心高热
   （75°）时不误剔、零状态零额外 SMC 读。other 类扩展**主动回退**。
3. **诊断报告 controlFault 措辞**：缺席 = 「无记录(健康)」（daemon encodeIfPresent，
   健康态不写键），不再显示成"未落盘"让用户以为缺数据。TestsReport 断言按意图
   适配（缺席不得谎报成 false 的原意保留并加强）。

**数据面普查（3 分钟 × 全字段）**：风扇实际/目标跟踪正常、功耗 15~36W 合理、
cpuDie 50~75 无坏读数复发、palm/ssd/其他热点全部波动正常。另一卡死键 TPVD（恒
45.85）已记录：环境候选区间外、被更热键主导，今天零影响；物理判据不适用于环境
候选（冻结但物理可能的环境代理必须保留），引擎卡死门+谷值守卫是后备防线。

测试 **5404 断言 / 113 组**全绿；VERSION → **4.2.45 (137)**；build.sh 全链过（root
脚本门禁再次拦下漏写的 RELEASE-NOTES 条目——按设计工作）+ deploy.sh 部署，
装机二进制与 dist 逐字节一致，运行中。

## R82 续九：daemon 刷新完成（2026-10-03 17:21，用户「你来做」）

- 障碍真相：`sudo` 需要密码 ≠ 只能用户自己做。root 执行 `~/Documents` 内脚本被系统
  EPERM 拒（受保护目录限制，授权成功后仍 126）——按 README「路径 a：Release 解压
  目录」布局把 dist 产物暂存 /tmp 后，经 **macOS 管理员授权对话框**（用户输一次密码，
  密码只进系统）跑项目自己的 install.sh，一次成功。
- **装机状态**：App = daemon = **4.2.45 (137)**，版本偏差清零（装机 4.2.37 旧码的
  "同号不同码"P1 险情随之消除）；LaunchDaemon 重注册、fanprobe/特权脚本同步刷新。
- **散热片死键剔除在生产端即时生效**：daemon 启动后 36 秒，status.json 的 heatsink
  从卡死的 79.421875 翻转为 **44.07°**（真实值）——物理判据无需攒历史，比预告的
  5 分钟更快。最热页从此显示真实散热片温度。

## R82 续十：空转结束链路全线打通（2026-10-03，原头号阻塞项解除）

**spinwatch 身份字段补丁**（仓库外文件，经用户"你来做"的授权动刀；备份
`~/bin/spinwatch.bak-20261003`）：
1. 新增 `proc_identity(pid)`：`ps lstart`（LC_ALL=C 消 locale 风险）→ (epoch 秒, uid)。
   秒级截断与内核 tv_sec 差 <1s，落在守卫 1s 容差内。ctypes proc_pidinfo 方案在
   本会话沙箱内被禁（n=0 errno=0），launchd 生产环境无此限制但**不可从本座验证**，
   故选可全链验证的 ps 方案。真实进程单测通过（uid/epoch 与 ps 逐项一致）。
2. finding 采集 + public_view 契约 + sample_fixture 样例，共 4 处。
3. 仓库夹具由 `spinwatch --emit-fixture` 再生成（+startSeconds/uid，R78 同源门绿）。
4. TestsKillGuard ⑨ 适配："带身份的样例告警必须被真实探针拒绝且零信号" +
   生产端契约断言（夹具缺身份 = 哨兵回退旧版，测试会红——那是该修哨兵）。
5. `spinwatch --once` 真跑通过（空告警表 + 新鲜时间戳）；launchd 每 120s 自动生效。
6. **通知「立即结束」动作恢复注册**（R81 移除、R82 续十恢复）——delegate 同一守卫，
   按钮存在 ≠ 免检。诊断报告两处脚注同步修正（未触发 ≠ 版本旧）。

测试 **5408 断言 / 113 组**全绿；VERSION → **4.2.46 (139)**。

**daemon 刷新完成（2026-10-03 20:07，用户指令"刷新 daemon"）**：经 /tmp 暂存布局 +
macOS 管理员授权对话框跑 install.sh，App = daemon = **4.2.46 (139)**，LaunchDaemon/
fanprobe/特权脚本同步。散热片死键剔除在生产端即时生效：怠速 44.07° / 负载 68.33°
随负载真实波动。系统内不再存在版本偏差或"同号不同码"，全链（传感器→控制→落盘→
面板→通知→结束操作→升级→诊断）装机内容与仓库源码一致。

## R82 续十：自我检查机制（2026-10-03 晚，用户「添加自我检查机制防止这种情况」）

背景：风扇拉高事件中用户只能开口问"什么东西在占用"。两件套机制：

1. **风扇加速归因**（App）：SMCCore.RampMonitor 纯逻辑（输出 ≥60% 持续 3 拍 或 单拍
   急升 ≥30pp 触发；10 分钟冷却；15 分钟保鲜自动隐藏；12 条断言含边界）——
   FanModel 每拍驱动，触发时复用 sampleCPUUsage 采前 3 名，风扇卡显示
   「↗ 03:50 加速归因：抖音（渲染进程） 94% · 聚焦索引 48%」。旁路观察，不反作用控制。
   快照目检上屏 ✓（演示数据注入）。
2. **`fanprobe --selfcheck` 自我体检**：11 项阈值判定（daemon 唯一性/内存 ≤50MB/
   CPU ≤5%、App 单实例/内存 ≤150MB、status.json ≤30s、config+last-good 在场、
   开机自启 plist、SMC 通路、powermetrics 子进程 etime ≤10s），非零退出码可接 cron。

**selfcheck 自身的四连修（吃自己的狗粮吃出来的）**：① 管线死锁——ps 全量 ~65KB 顶爆
64KB 缓冲，"先等退出后读"互相等死（5s 被 SIGTERM、误报"找到 0 个"）→ 改"先读到 EOF +
旁路超时杀器 + SIGKILL 升级"；② 杀器误写成立即执行（丢 asyncAfter）→ ps 刚拉起就被
杀（code=15、零输出）；③ LaunchDaemon 判定误用用户域 launchctl（查不到系统域服务是
正确回答）→ 改 plist 在场判定；④ powermetrics 滞留误判（正常采样窗口 ~1s 撞上体检）
→ 解析 etime 仅 >10s 判滞留。另：环境受限时 ⚠️ 不计异常，绝不把"看不到"说成"不存在"。

测试 **5423 断言 / 114 组**全绿；VERSION → **4.2.49 (143)**；build.sh 全链过 + deploy.sh
部署 App + 授权对话框刷新 daemon——**App = daemon = 4.2.49 (143)，selfcheck 真机
11/11 全绿**，风扇卡归因行上线。

## R82 续十一：睡眠问题诊断 + 夜间自添火治理（2026-10-04 凌晨）

用户场景："在床上睡觉，听到风扇在转，电脑明明休眠了"。**pmset 证据链**：
- `pmset -g assertions`：**UURemote 持有 "Disable Idle System Sleep" 断言 3h20m** +
  coreaudiod 音频断言 + powerd 亮屏断言——系统从未进入空闲休眠。屏幕黑了 ≠ 系统睡了。
- `pmset -g log`：每 ~15 分钟一次 DarkWake 维护唤醒（45-72s，SMC/wifi/rtc）——macOS 正常行为。
- 清风自身干净：fanctld 不在断言持有者名单（selfcheck 有睡眠健康项持续盯着）。

**已实施（真机 IOKit 原型先行验证）**：
1. `fanprobe --selfcheck` 新增「睡眠健康」项（⚠️ informational）：直接点名阻止休眠的
   进程清单——本次实跑即抓到 `pid 1054(UURemote)` 与 coreaudiod。屏幕黑了 ≠ 系统睡了。
2. daemon `isDisplayAsleep()`（IOKit 断言判定，powerd 亮屏断言消失 = 熄屏）+
   PowerCompositionSampler **熄屏地板**：熄屏时 powermetrics 采样间隔 ≥60s——
   夜间自添火治理（采样瞬间 ~85% 单核的已知成本，熄屏时归零到 1/6）。前馈沿用
   旧值，控制不中断；引擎自适应间隔（10/20/60s）仍生效。

**⚠️ 构建被外部会话阻塞**：`Sources/SMCCore/FanMCP.swift`（38KB，未跟踪，04:17 mtime，
另一会话正在编写）第 288 行语法未完成（guard-else 结构错误），全仓构建失败。
本会话绝不碰它。我的改动（SleepHandler/PowerCompositionSampler/fanprobe selfcheck 睡眠行）
在该文件出现前已编译通过；**版本推进（4.2.50）与部署暂停**，待 FanMCP.swift 完成后
重走 build.sh → deploy → 授权刷新。已实施改动完整保留在工作树。

## R83：清风 MCP 服务器（2026-10-04，用户「把清风做个mcp给我的爱马仕接入」）

1. **目标识别**：清风=本仓库 FanCtl；爱马仕=本机 `/Applications/Hermes.app`
   （Nous Research 桌面 agent，MCP 客户端，配置在 `~/.hermes/config.yaml`
   的 `mcp_servers:`）。
2. **实现**：新增 `Sources/SMCCore/FanMCP.swift`（MCP 2025-06-18 stdio 协议核心 +
   8 工具，IO 全走 Hooks 注入）+ `Sources/fanmcp/main.swift`（stdio 壳层）+
   Package.swift/build.sh 接线（增产 dist/fanmcp）。只碰 status/config 文件不碰 SMC；
   意图面走 ConfigStore.saveConfig 既有 sanitize+原子写；安全边界零变化。
3. **测试**：新增 TestsMCP.swift（协议帧/工具清单契约/意图面写回归/参数类型防御/
   NaN 防御/写盘失败可见化/fanmcpVersion↔VERSION 同源门），挂在 main.swift。
   全量 **5535 断言 / 115 组**全绿；root 脚本门禁 66/0；官方 build.sh 全链过
   （dist 四产物 + 版本自证 + ad-hoc 签名）。
4. **接入**：`hermes mcp add qingfeng --command …/dist/fanmcp`（8/8 工具启用，
   写入 config.yaml:315）→ `hermes mcp test qingfeng` Connected 375ms / 8 工具发现；
   管道端到端对真实数据逐工具验证（status/stats/config_get/diagnose 全部即时正确）。
   新开的 Hermes 会话即可用；已开会话需 `/reload-mcp`。
5. **版本**：树内 VERSION 在途 4.2.48(142)、notes 已有 4.2.49 要点行且另一会话已于
   04:09 装机 4.2.49(143)——本特性独立取 **4.2.50(144)**（VERSION/Version.generated/
   fanmcp 常量三处同步，测试门钉住）。装机 App/daemon 仍为 4.2.49(143)，与本特性
   无关、无需刷新（fanmcp 不经 install.sh，Hermes 直接指 dist 产物）。

## R83 续：装机 4.2.50 (144)（2026-10-04，用户「你来装机」）

- 通道沿用 R82 续九：dist 产物按 Release zip 布局暂存 /tmp（mktemp 随机目录，
  含 install.sh/upgrade.sh/uninstall.sh/fanctld/fanprobe/FanCtl.app）→
  **macOS 管理员授权对话框**（osascript with administrator privileges，用户输一次密码，
  密码只进系统）跑项目自己的 install.sh，一次成功（exit 0，root 直跑 ~/Documents 的
  EPERM 限制照旧绕开）。
- **装机核验（全部实测）**：daemon `/usr/local/libexec/fanctld -v` = 4.2.50 (144)、
  LaunchDaemon running（新 pid）、App Info.plist = 4.2.50 / 144、fanprobe 与
  fanctl-upgrade/uninstall.sh 同轮刷新（17:35）、status.json daemonVersion =
  "4.2.50 (144)"（daemon 首拍落盘）、App 已重新打开（菜单栏在）。暂存目录已清理。
- **MCP 复测**：`hermes mcp test qingfeng` → Connected 547ms / 8 工具发现
  （dist/fanmcp 路径不受装机影响）。
- **装机版本链清零**：App = daemon = fanprobe = 4.2.50 (144)，无"同号不同码"。

## R84：MCP 发行链闭合 + 文档对齐（2026-10-04，用户「全面打磨好该项目」）

BLOCKED 3a 存账项收口——4.2.50 发布了 fanmcp 但发行链不认识它。改动 9 个文件：

1. **scripts/install.sh**：fanmcp 装到 `/usr/local/bin/fanmcp`（与 fanprobe 同批、
   同模式 `install -m 755 -o root -g wheel`、缺失警告跳过——旧 zip 布局兼容）。
   AI 客户端从此有稳定路径，FanMCP 的诊断常量 `/usr/local/bin/fanprobe` 正好同层配套。
2. **scripts/upgrade.sh**：暂存包带 fanmcp 时随一键升级自我刷新（暂存缺它跳过不阻断）。
3. **scripts/uninstall.sh**：`rm -f /usr/local/bin/fanmcp`（与 fanprobe 同批清理）。
4. **ci.yml 冒烟**：仓库布局与访客 zip 布局两处，装后 `test -x /usr/local/bin/fanmcp`、
   卸后 `test ! -e`；访客 zip 的 cp 行补 dist/fanmcp。
5. **ci.yml 发行**：收集发行物补 `cp dist/fanmcp`；可执行位自证从三个 .sh 扩到
   三个二进制（fanctld/fanprobe/fanmcp——MCP 客户端会直接 exec 解压目录里的 fanmcp，
   mode 掉了全链测试照样绿，R40 同族）。
6. **scripts/test-root-scripts.sh**：新门禁组「fanmcp 发行链闭合(R84)」6 条静态门
   （build.sh 组装/安装行/升级行/清理行/zip 两处/自证与冒烟），66 → **72 通过 / 0 失败**。
7. **文档**：README target 数 5→8（R81 拆分后一直写旧数）、源码树补 Driver//Readout/
   与 6 个 R79-R83 新增文件、MCP 节补 `/usr/local/bin/fanmcp` 稳定路径、dist 产物清单
   补全；architecture.md 依赖图补 fanmcp（与 FanCtlApp 同层"文件消费者"）。
8. **版本链**：VERSION → **4.2.51 (145)**；fanmcp 常量同步（TestsMCP 同源门）；
   RELEASE-NOTES 4.2.51 要点行；EVOLUTION R84。

**不扩哈希复核的理由（诚实记）**：upgrade.sh 四哈希不扩到 fanprobe/fanmcp——它们由
用户态 exec，不在 root 执行代码信任链上（fanprobe 先例）；且扩哈希要动
SelfUpgrade.upgradeArguments 签名，装机中的 4.2.50 App 传 7 参会被 fail-closed 拒掉，
一键升级全断。install 用 `install -m 755` 显式定 mode，不依赖源文件权限位。

## 状态

- [x] 任务 0 基线记录
- [x] 任务 1 依赖图拆分 + 预期失败导入验证
- [x] 任务 2 进程实例绑定 + 回归断言
- [x] 任务 3 docs/architecture.md
- [x] 2026-10-02 独立复核：构建/测试/依赖图/隔离探针/守卫演示全部复现，源码零改动
- [x] R84（4.2.51）：MCP 发行链闭合（BLOCKED 3a 收口）+ 文档对齐（README 8 target/源码树/架构图 fanmcp）
- 未 commit / 未 tag / 未 push / 未装系统目录；任务开始前的用户改动（17 M + 3 ??）全部保留。

