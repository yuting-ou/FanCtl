# 清风 · 发行说明

> CI 的 release job 会把本文件正文作为 GitHub Release 的说明文字（`--notes-file`）。
> 为什么不用 tag 批注：`actions/checkout` 检出 tag 时建的是 **lightweight** 引用，
> `git tag -l --format='%(contents)'` 会退化成 commit message（v4.2.1 实测如此），
> 迁移警示就丢了。放在仓库里还能被门禁静态检查（版本号与警示必须在场）。

## 安装 / 升级

1. 下载本 Release 的 `FanCtl-vX.Y.Z.zip` 并解压；
2. 在解压目录执行 `sudo ./install.sh`（需要密码：安装守护进程与菜单栏 App）；
3. 菜单栏出现「清风」即完成；建议在面板菜单里打开「登录时启动」。

## 从旧版升级要注意的

- **4.2.x 起，特权脚本住在 root 拥有路径**：`/usr/local/libexec/fanctl-upgrade.sh`
  与 `fanctl-uninstall.sh`。从 4.1.x 升上来需要**先手动 `sudo ./install.sh` 一次**
  （旧版 App 的升级脚本没有安装这两个文件的逻辑）；此后 App 内一键升级会自我刷新它们。
- **4.2.0 的 App 内一键升级不可用**（目录信任门有个"函数定义晚于调用"的缺陷，升级会
  稳定失败，不影响已装功能）。装了 4.2.0 请直接用 `sudo ./install.sh` 升到 4.2.1+。
- **卸载**：`sudo /usr/local/libexec/fanctl-uninstall.sh`（4.2.0 之前的机器改用
  `sudo "/Applications/清风.app/Contents/Resources/uninstall.sh"`）。
- **出问题请先跑诊断包**：`swift run -c release --disable-sandbox fanprobe --report`
  或发行包外的 `fanprobe --report`，把整段输出贴进 issue（无需 root，只读）。

## 本版变更要点

- 4.2.3：`status.json` 新增 daemon 自报版本（`daemonVersion`），诊断包的"装机"小节从此能
  直接回答"这台机器上跑的 daemon 是哪一版"——此前只能靠 App plist 版本与二进制 mtime 推断，
  遇到"App 已升级、daemon 留在旧版"的半途状态无从判断。旧 daemon（或该值被改/被拒收）不写
  此字段，报告只说"未自报"，不猜版本。解码侧限长 64 且只收可打印 ASCII——这个文件在同组可写目录。
- 4.2.2：诊断包 `fanprobe --report`（一条命令产出陌生人机器上首问的全部信息，issue 模板已
  设为必填）；`fanprobe` 改真只读——以前它以登录用户身份读坏 JSON 时会在 root 的数据目录里
  写 `.corrupted` 备份并顺带轮转删除旧备份，现在这条写路径在诊断工具里彻底关掉；发行说明
  改由本文件提供并加"说明与 tag 同源"硬门。
- 4.2.1：修 4.2.0 的两个 P1——App 内一键升级必然失败（信任门函数顺序）、暂存的 root
  执行脚本正文未纳入哈希复核（同 uid 可在授权窗口内换正文）。
- 4.2.0：批次 A 特权信任根（root 执行代码只住 root 拥有、组不可写路径）；睡醒不再误报
  闭环故障；`history.json` 逐日抢救；AI 评测改按秒加权；配置损坏回 last-good；
  SMC 启动瞬时失败改为进程内退避重试。
