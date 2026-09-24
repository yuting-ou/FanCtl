#!/bin/bash
# upgrade.sh — 清风 App 内一键升级的特权安装过程（v3.9.0）
# 执行位置的演进（同一条威胁：root 执行的代码不能住在用户可写的地方）：
#   v3.9：读 App bundle 内副本 → 驻留进程可篡改 bundle（被 chown 给登录用户）= 提权道；
#   R23：正文 base64 内嵌进 App 二进制 → 内容不再依赖包内文件，但**二进制本身**仍在
#        用户可写的 bundle 里，替换 App 即可换掉被授权的脚本正文；
#   批次 A（4.2.0）：规范落点 /usr/local/libexec/fanctl-upgrade.sh，root:wheel 755，
#        由 install.sh 首装、每次升级自我刷新；App 侧 exec 前先 lstat 校验
#        （常规文件 + root 拥有 + 组/其他无写位），不合规即拒绝提权，绝不回退包内副本。
# 调起签名（7 个必填参数，App 侧由 SelfUpgrade.upgradeArguments 生成同一顺序）：
#   bash 落点 <暂存目录> <标记文件> <授权版本tag> <fanctld哈希> <App二进制哈希> <upgrade.sh哈希> <uninstall.sh哈希>
# 暂存目录由 App（用户态）准备并已过 SelfUpgrade.validateStaged 与特权脚本存在性门；
# 四个哈希在 root 动手前复核——关闭"授权确认之后偷换暂存包"的 TOCTOU。
# 批次 A 后暂存包里两份**脚本正文**也会被装成 root 执行代码，故与两份二进制同等待遇：
# 不复核就是"把注入口从二进制挪到一个无摘要、路径公开、root 主动 install 的目录"。
set -euo pipefail

# ---------------------------------------------------------------------------
# 目录信任谓词（批次 A）：root 要往某目录写"将被 root 执行的代码"之前，该目录必须
# root 拥有且组/其他无写位——否则同 uid 进程可预置同名文件或符号链接，下次授权即
# 执行攻击者代码（R23/R28 修文件面，这里修目录面）。
# **定义必须先于任何调用**：bash 解析到函数定义那一行才注册它，调用早于定义会得到
# 127 "command not found"，而 `if ! fn` 把 127 反成判真 → 健康机器也走拒支。
# R36 审查 P1 就是这个：4.2.0 的目录信任门写在调用之后，App 内一键升级 100% 失败，
# 而回归门禁全绿（测试钩子恰好跳过那块）。顺序由 test-root-scripts.sh 静态门锁住。
# ---------------------------------------------------------------------------
fanctl_dir_trusted() {
    local d="$1" st owner mode
    [[ -d "$d" && ! -L "$d" ]] || return 1
    st=$(/usr/bin/stat -f "%u %p" "$d" 2>/dev/null) || return 1
    owner="${st%% *}"; mode="${st##* }"
    [[ "$owner" == "0" ]] || return 1
    [[ $(( 0$mode & 0022 )) -eq 0 ]]
}

# 全局测试后门一律要求**非 root**：osascript 的 do shell script 会透传调用方环境
# （实测 `osascript -e 'do shell script "env"'` 里能看到注入变量），root 运行中任何
# "跳过实装只跑门禁"的后门都必须失效——否则会留下"报成功而什么都没装"的状态。
GATES_ONLY=0
if [[ $EUID -ne 0 && "${FANCTL_TEST_GATES_ONLY:-}" == "1" ]]; then GATES_ONLY=1; fi

# 无 root 谓词回归钩子（0=可信，1=不可信）。root 属主的正例无法在无 root 下构造，
# 诚实记档为"仅真机验证"。
if [[ $EUID -ne 0 && "${FANCTL_TEST_DIR_TRUST:-}" == "1" ]]; then
    fanctl_dir_trusted "${1:-}"
    exit $?
fi

# R40 App 落点谓词（与 install.sh 同源同语义，实测依据见 install.sh 的注释块）：
# BSD `cp -R src dst` 会**跟随**指向目录的 dst 符号链接（实测），而 `/Applications` 是
# root:admin 组可写、无 sticky——落点被换成链接时，root 会把 bundle 写进链接指向的目录，
# 而随后的 `chown -R`（默认不跟随，实测）不会把树交还给用户。判据：不存在放行；
# 存在则必须"真实目录且非符号链接"。
fanctl_app_target_ok() {
    local p="$1"
    # 尾斜杠会让 `-L` 跟随链接（`test -L link/` 为假），先剥掉再判；"/" 与空串一律拒
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    [[ -z "$p" || "$p" == "/" ]] && return 1
    [[ -L "$p" ]] && return 1                       # 含断链：一律拒绝
    [[ -e "$p" ]] || return 0                       # 不存在：允许新建
    [[ -d "$p" ]]                                   # 只允许覆盖真实目录
}
if [[ $EUID -ne 0 && "${FANCTL_TEST_APP_TARGET:-}" == "1" ]]; then
    fanctl_app_target_ok "${1:-}"
    exit $?
fi

# 无 root 回归钩子（仅非 root 生效）：跳过 EUID 检查，只跑下方授权前门禁
# （暂存完整性 / tag 比对 / 四哈希复核 / marker 符号链接）后退出 0，绝不触碰
# launchctl 与文件系统安装路径。scripts/test-root-scripts.sh 靠它锁 P1-A/P1-B/P2/marker。
if [[ $EUID -ne 0 && $GATES_ONLY -eq 0 ]]; then
    echo "此脚本须以管理员身份运行（由 App 的升级流程调起）" >&2
    exit 1
fi

STAGING="${1:-}"
if [[ -z "$STAGING" || ! -d "$STAGING" ]]; then
    echo "用法: upgrade.sh <暂存目录> [标记文件] [tag] [daemon-sha256] [appbin-sha256]" >&2
    exit 1
fi
# 批次 A：暂存包必须自带特权脚本正文（升级即自我刷新 root 侧脚本）；缺即拒装，
# 不带着"下次没有可执行链路"的状态往下走
if [[ ! -d "$STAGING/FanCtl.app" || ! -f "$STAGING/fanctld"
      || ! -f "$STAGING/upgrade.sh" || ! -f "$STAGING/uninstall.sh" ]]; then
    echo "暂存包不完整（缺 FanCtl.app / fanctld / upgrade.sh / uninstall.sh）" >&2
    exit 2
fi
MARKER="${2:-$STAGING/.upgrade-done}"
TAG="${3:-}"
SHA_DAEMON="${4:-}"
SHA_APPBIN="${5:-}"
SHA_UPGRADE="${6:-}"
SHA_UNINSTALL="${7:-}"

# root 侧复核（在 bootout 之前——不匹配则原状退出，运行中的 daemon/App 不受扰动）
# R29：门禁 fail-closed——TAG/双哈希为必填。App 自动升级恒传齐；手动/社交工程路径
# 若缺参数则拒绝安装，禁止「跳过校验仍 root 动手」。
if [[ -z "$TAG" || -z "$SHA_DAEMON" || -z "$SHA_APPBIN"
      || -z "$SHA_UPGRADE" || -z "$SHA_UNINSTALL" ]]; then
    echo "缺少授权 tag 或四个哈希参数，拒绝升级（fail-closed）" >&2
    exit 3
fi
STAGED_VER=$(plutil -extract CFBundleShortVersionString raw \
    "$STAGING/FanCtl.app/Contents/Info.plist" 2>/dev/null || true)
if [[ "$STAGED_VER" != "$TAG" ]]; then
    echo "暂存包版本 ${STAGED_VER} ≠ 授权版本 ${TAG}（授权后被篡改？）" >&2
    exit 3
fi
actual=$(/usr/bin/shasum -a 256 "$STAGING/fanctld" | awk '{print $1}')
if [[ "$actual" != "$SHA_DAEMON" ]]; then
    echo "暂存 daemon 二进制哈希不符（授权后被篡改？）" >&2
    exit 3
fi
actual=$(/usr/bin/shasum -a 256 "$STAGING/FanCtl.app/Contents/MacOS/FanCtl" | awk '{print $1}')
if [[ "$actual" != "$SHA_APPBIN" ]]; then
    echo "暂存 App 二进制哈希不符（授权后被篡改？）" >&2
    exit 3
fi
# 两份特权脚本正文：它们会被装成 root 执行代码，与二进制同等复核
actual=$(/usr/bin/shasum -a 256 "$STAGING/upgrade.sh" | awk '{print $1}')
if [[ "$actual" != "$SHA_UPGRADE" ]]; then
    echo "暂存 upgrade.sh 哈希不符（授权后被篡改？）" >&2
    exit 3
fi
actual=$(/usr/bin/shasum -a 256 "$STAGING/uninstall.sh" | awk '{print $1}')
if [[ "$actual" != "$SHA_UNINSTALL" ]]; then
    echo "暂存 uninstall.sh 哈希不符（授权后被篡改？）" >&2
    exit 3
fi

# R23 审查（P3-1）：marker 已是符号链接时在 bootout 之前快速失败——否则装完 daemon、
# 杀完旧 App、替换完 bundle 才在末尾守卫 exit 4，语义是"系统已升级却回报失败、新 App
# 无人重启"。末尾写前的守卫仍保留（防"检查后、写入前"抢建链接的 TOCTOU 跟随截断）。
if [[ -L "$MARKER" ]]; then
    echo "完成标记是符号链接，拒绝升级（防跟随截断）" >&2
    exit 4
fi

# 目录信任门（批次 A）：落点必须 root 拥有且组/其他不可写；放在 bootout 之前——
# 不合规就原状退出，绝不"先停服务再报错"。落点在生产路径写死（不给 env 留漂移：
# plist 里的 ProgramArguments 也硬编码同一绝对路径，两者必须一致）。
LIBEXEC=/usr/local/libexec
if [[ $GATES_ONLY -eq 0 ]]; then
    mkdir -p "$LIBEXEC"
    if ! fanctl_dir_trusted "$LIBEXEC" || ! fanctl_dir_trusted "$(dirname "$LIBEXEC")"; then
        echo "拒绝升级：${LIBEXEC} 或其父目录不是 root 拥有且组/其他不可写" >&2
        exit 5
    fi
    # R40：App 落点预检也放在 bootout 之前——不合规就原状退出，绝不停掉服务再报错。
    # 与目录信任门同理：这一支只在真实升级里跑（gates-only 模式跳过），所以无 root 侧的
    # 覆盖由两半拼成——谓词本身用 FANCTL_TEST_APP_TARGET 钩子行为测，"它排在 bootout 之前"
    # 由 test-root-scripts.sh 的顺序门锁住。缺任何一半都会假绿。
    if ! fanctl_app_target_ok "/Applications/清风.app"; then
        echo "拒绝升级：/Applications/清风.app 不是真实目录（符号链接或异类文件）——" >&2
        echo "   root 的 cp -R 会跟随它把 bundle 写进链接指向的目录。请删掉该条目后重试" >&2
        echo "   （daemon 与风扇调度此刻完全没动：ls -lOd /Applications/清风.app）" >&2
        exit 5
    fi
fi

if [[ $GATES_ONLY -eq 1 ]]; then
    echo "gates-ok"
    exit 0
fi

PLIST=/Library/LaunchDaemons/com.fanctl.daemon.plist
SUPPORT="/Library/Application Support/FanCtl"

# 登录用户 = 控制台当前用户（osascript 场景无 SUDO_USER，用 stat 取 console 属主；
# 取不到时退回 root——App 不可写但功能仍在，下次 sudo install.sh 会修正归属）
LOGIN_USER=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo root)
[[ "$LOGIN_USER" == "root" || -z "$LOGIN_USER" ]] && LOGIN_USER=root

echo "==> 停止旧守护进程..."
launchctl bootout system "$PLIST" 2>/dev/null || true

echo "==> 安装守护进程..."
mkdir -p "$LIBEXEC"
install -m 755 -o root -g wheel "$STAGING/fanctld" "$LIBEXEC/fanctld"
# 自我刷新：root 执行脚本随每次升级更新。必须用 install（unlink+新建 inode）而不是
# cp 原地覆盖——bash 是边读边执行的，截断自己正在跑的那个 inode 会让后续行错乱。
for _s in upgrade uninstall; do
    install -m 755 -o root -g wheel "$STAGING/${_s}.sh" "$LIBEXEC/fanctl-${_s}.sh"
done
# R32：诊断工具与 daemon 同步升级（暂存包未带 fanprobe 时跳过，不阻断升级）
if [[ -f "$STAGING/fanprobe" ]]; then
    mkdir -p /usr/local/bin
    install -m 755 -o root -g wheel "$STAGING/fanprobe" /usr/local/bin/fanprobe
fi

echo "==> 配置/日志目录权限对齐..."
mkdir -p "$SUPPORT" /Library/Logs/FanCtl
chown root:admin "$SUPPORT"; chmod 775 "$SUPPORT"
chown root:wheel /Library/Logs/FanCtl; chmod 755 /Library/Logs/FanCtl
[[ -f "$SUPPORT/config.json" && ! -L "$SUPPORT/config.json" ]] && chown root:admin "$SUPPORT/config.json" && chmod 664 "$SUPPORT/config.json" || true

echo "==> 注册 LaunchDaemon..."
if [[ ! -f "$PLIST" ]]; then
    # 首装场景（用户从旧 App 升上来但 plist 不在）：补写标准 plist
    cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.fanctl.daemon</string>
    <key>ProgramArguments</key><array><string>/usr/local/libexec/fanctld</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>/Library/Logs/FanCtl/fanctld.out.log</string>
    <key>StandardErrorPath</key><string>/Library/Logs/FanCtl/fanctld.err.log</string>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><false/>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST"; chmod 644 "$PLIST"
fi
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl kickstart -k system/com.fanctl.daemon 2>/dev/null || true

echo "==> 安装菜单栏 App..."
pkill -x FanCtl 2>/dev/null || true
sleep 1
rm -rf "/Applications/清风.app" /Applications/FanCtl.app
cp -R "$STAGING/FanCtl.app" "/Applications/清风.app"
# R40 复验（实测依据见 install.sh 的注释块）：预检与 cp 之间的窗口只能缩短、不能关死
#（/Applications 无 sticky，admin 组随时可换条目）。撞上时如实中止，且**不写重启标记**——
# 那一刻的状态是"daemon 已升级并 bootstrap（风扇受控、红线照旧）、App 未就位"，
# 把一个可能落在别处的 root 属主 bundle 交给 watcher 去 open 是不可接受的。
if [[ -L "/Applications/清风.app" || ! -d "/Applications/清风.app/Contents/MacOS" ]]; then
    echo "❌ 拷贝后 App 落点不对（被并发换成符号链接，或 bundle 结构不完整）——中止，未写重启标记。" >&2
    echo "   守护进程已升级并在跑（风扇调速正常），只有菜单栏 App 未就位：" >&2
    echo "   删掉 /Applications/清风.app 这个条目后再走一次升级，或用发行包里的 install.sh" >&2
    exit 6
fi
# 清掉下载链路的 quarantine 属性（App 经 URL 下载解压自带 com.apple.quarantine，
# 不清则 Gatekeeper 对未公证 bundle 拦截；本 bundle 由用户主动授权安装，与右键打开等价）
xattr -dr com.apple.quarantine "/Applications/清风.app" 2>/dev/null || true
chown -R "$LOGIN_USER:staff" "/Applications/清风.app" 2>/dev/null || true

sleep 2
[[ -f "$SUPPORT/config.json" && ! -L "$SUPPORT/config.json" ]] && chown root:admin "$SUPPORT/config.json" && chmod 664 "$SUPPORT/config.json" || true

# 重启菜单栏 App 不在本脚本做（R10 设计裁决）：root 上下文 open 实测静默失败、
# submit 的进程域归属存疑（菜单栏 App 若落 system 域等于 root 运行，不可接受）。
# 重启由 App 启动的用户态 watcher 负责——它轮询本标记（被 launchd 收养（App 已
# pkill）后以登录用户身份 open，与手动打开完全同路）。R23：标记写授权版本作内容
# （watcher 比对内容而非仅存在性），且 App 侧把标记放其私有 700 暂存目录内的随机
# 路径（非 /tmp，避免 argv→ps 泄露路径后被抢建符号链接）。R23 再审（P2-B）：root
# 的 `> marker` 会跟随符号链接，故写前显式拒绝符号链接（同 uid 抢建兜底）。
if [[ -L "$MARKER" ]]; then
    echo "完成标记是符号链接，拒绝写入（防跟随截断）" >&2
    exit 4
fi
if [[ -n "$TAG" ]]; then
    printf '%s' "$TAG" > "$MARKER"
else
    touch "$MARKER"
fi

echo "✅ 升级完成: $(/usr/local/libexec/fanctld -v)"
