# BLOCKED — 本轮做不了/需要外部配合的事

## 1. 「结束进程」链路：**已全线打通**（2026-10-03，原头号阻塞项解除）

- 哨兵 `~/bin/spinwatch` 已升级为每条告警携带进程实例标识（startSeconds/uid，
  `ps lstart` C-locale 读取，秒级截断 < 守卫 1s 容差）；脚本改动前备份于
  `~/bin/spinwatch.bak-20261003`。仓库夹具由 `spinwatch --emit-fixture` 再生成，
  键集合与 SpinAlert.CodingKeys 同源门绿；守卫回归组适配"带身份的样例告警必须被
  真实探针拒绝且零信号"。
- 面板「结束」按钮对**新告警**可用（守卫现场核验：进程退出/pid 复用/uid 或路径
  不符 → 拒绝并说明）；通知「立即结束」动作已恢复注册（同一守卫，按钮存在 ≠ 免检）。
- 历史告警（旧格式、无身份）仍失败关闭——属正确行为，待哨兵下一轮覆盖。

## 1b. daemon 版本偏差——**已清零**（2026-10-03 20:07，经管理员授权对话框完成）

- App = daemon = **4.2.46 (139)**，fanprobe/fanctld/特权脚本同步刷新。散热片展示值
  在生产 daemon 上即时生效（怠速 44° / 负载 68° 随负载波动，物理合理）。
  至此系统内不再有任何版本偏差或"同号不同码"。

**历史存档（2026-10-01 → 10-03，已解决）**：原 BLOCKED 的根因是告警只有 pid、无实例字段，
消费端据此全面失败关闭。解除路径＝生产端补 startSeconds/uid（本机已做）＋消费端守卫
（早已就绪）＋通知动作恢复。字段表与接入步骤留档于 git 历史与本文件旧版；
回滚哨兵：`cp ~/bin/spinwatch.bak-20261003 ~/bin/spinwatch`（回滚后告警回到无身份形态，
结束动作自动回到失败关闭——两个方向都是设计好的行为）。

## 2. 无法在本轮做的验证

- **CLT 27.0 SDK 缺 SwiftUI 宏插件**（2026-10-02 复核确认，**项目早已适配**）：本机
  `/Library/Developer/CommandLineTools` 的 MacOSX27.0.sdk 把 `@State` 声明为
  `#externalMacro(module:"SwiftUIMacros")` 但不带插件 dylib → 裸 `swift build` 编译
  FanCtlApp 报 `plugin for module 'SwiftUIMacros' not found`。`scripts/build.sh` 自
  2026-09-11 起自动探测并只把 App 目标钉到可用的旧 SDK（daemon/测试用默认 SDK），
  **官方构建链不受影响**；只有绕过 build.sh 直接 `swift build` 全包时才需手动
  `SDKROOT=…/MacOSX26.5.sdk`。根治（默认 SDK 恢复可用）需完整 Xcode 或 Apple 修复 CLT。
- **守护进程已刷新（2026-10-03 17:21，经 macOS 管理员授权对话框完成）**：装机 daemon
  `/usr/local/libexec/fanctld` 与 App 均为 **4.2.45 (137)**，版本偏差清零。过程备注：
  root 执行 `~/Documents` 内脚本被系统 EPERM 拒绝（受保护目录限制，非密码问题）——
  按 README「Release 解压目录」布局把 dist 产物暂存 /tmp 后走 install.sh 解决。
  此前遗留的"同号不同码"险情（装机 4.2.37 码 vs 源码 4.2.45 码）随之消除。
- **UI 按钮的实机点击仍未验证**：上轮"不得安装系统目录"的限制本轮已由用户解除，
  App 已实际部署；但通知中心按钮/面板交互仍需人在真机上点。**守卫本体**已完成真机
  端到端验证（2026-10-02）：真实 spawn 的 sleep 进程带真身份 → SIGKILL 实际送达真死；
  启动时刻差 2 秒 → `pidReused` 拒绝且目标存活；对 root 进程（launchd）带真身份 →
  核验放行、kill 得 EPERM → 如实报 `signalNotDelivered`（不再谎报"已退出"）。
- **通知侧「立即结束」按钮的实机点击**：同上，且本轮该动作已按失败关闭原则从分类里移除，
  没有可点的东西。恢复条件见上文接入步骤第 3 条。

## 3a. CI 发行 zip 未携带 fanmcp——**已闭合（2026-10-04，R84 / 4.2.51）**

- Release zip 收集 + 可执行位自证、install.sh 装到 `/usr/local/bin/fanmcp`、
  upgrade.sh 随一键升级自我刷新、uninstall.sh 卸载清理、CI 冒烟（仓库布局 + 访客
  zip 布局）装/卸断言、root 脚本门禁 +6 条防回潮门（66 → 72）——全部落地并验证。
  README/架构地图同步补 fanmcp 位置与稳定路径。

## 3. 已知但未处理（超出本轮"安全边界加固"范围）

- **AI 模式下 powermetrics 采样的自身功耗成本（量化后刻意保留）**：分项功耗前馈是
  AI 控温的输入之一，采样瞬间 ~88% 单核（~0.9 CPU-s/次）；节奏绑定控温语义自适应
  （热/主动 10s ≈ 平均 8.8% 单核，凉 60s ≈ 1.5%，AI 空闲交还视同非 AI；curve 模式不采样）。
  降低成本的候选（缩短 powermetrics 采样窗口 -i 200、拉长热档间隔）都会改变 AI 的输入
  质量 = 改控温行为，超出"保持控制行为不变"的边界。若用户接受轻微前馈噪声可再议。

- 无。本轮范围内的取舍都记在 PROGRESS.md；未列出的即已完成。

## 4. R85（2026-10-09）核实成立、本轮未修的事项

详细证据与修法见 `EVOLUTION.md` 的「R85 交接口」，此处只列**需要谁动手**：

1. **发版要作者点头**：VERSION 已是 4.2.52(146)、测试 5607/119 全绿、root 门禁 73/73、
   build.sh 出四件套、CI 的打包与可执行位自证已在本地照跑一遍通过——但 **git tag 与
   GitHub Release 仍停在 v4.2.35（2026-09-29）**，R77–R85 的内容一件都没发出去。
   影响是可验的：App 的"检查更新"读 `releases/latest`（FanModel.swift:503），
   老用户永远看不到 4.2.36 之后的版本；访客下载 Latest 拿到的是没有 R81 安全边界拆分、
   没有进程实例守卫、没有 fanmcp 的旧包。推 tag 会触发 release job **公开发版**，
   且 2026-10-01 那轮作者曾把发版步骤叫停过 ⇒ 按自治边界（sudo 与公开发版之外的
   动作自决，公开发版摆事实后停等）没有自己推。
2. **root 安装面跟随符号链接（要动 root 脚本 + 其字面量门禁，留下一轮）**：
   `install.sh` / `upgrade.sh` 用 `install -m 755 -o root -g wheel "$DIST/fanmcp"` 装
   fanprobe/fanmcp，而 `install` **会跟随源符号链接**（/tmp 实测：链接指向的文件内容
   被复制成 0755 新文件）。staging 目录用户可写、本仓威胁模型自己就包含同 uid 竞态
   ⇒ 同 uid 进程把 fanmcp 换成指向 root-only 文件的符号链接，root 就会把该文件内容
   复制成全局可读的 `/usr/local/bin/fanmcp`（越权读取）。R84 记的"不扩哈希复核"
   理由只覆盖**执行**面，没覆盖这条**读取**面。
3. **SMCReadout / SMCDriver 两份 80 字节布局无防漂移门**：当前逐行相同（本轮 diff 过），
   但 fanctltests 不依赖 SMCReadout，改一处不改另一处不会红。
4. **本机安装偏差**：装机 App 与 daemon 都是 **4.2.50(144)**，仓库是 4.2.52(146)；
   `/usr/local/bin/fanmcp` 仍不存在（install.sh 需 root，永不自做）。
   4.2.51 是脚本/CI/文档轮（Swift 侧只差版本串），4.2.52 的 Swift 改动集中在
   SMCCore + App，daemon 侧只有 ControlEngine 的判据搬家（行为不变）——
   要不要为它弹一次 root 授权，归作者。Hermes 的 MCP 目前指向
   `~/Documents/风扇管理/dist/fanmcp`（build.sh 原地覆盖，路径不断，实测可用）；
   R84 给的稳定落点 `/usr/local/bin/fanmcp` 要等第 4 条装完才能切。
