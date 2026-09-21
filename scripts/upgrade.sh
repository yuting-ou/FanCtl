#!/bin/bash
# upgrade.sh — 清风 App 内一键升级的特权安装过程（v3.9.0）
# R23（P1 修复）起由 App 内嵌正文执行（build.sh 把本文件 base64 进二进制，
# 经 echo|base64 -d|bash -s 管道直交 root），不再从用户可写的 App bundle 读取——
# 关闭"驻留进程篡改包内脚本 → 用户例行升级输密码即被静默提权"的通道。
# 调起签名：bash -s -- <暂存目录> [标记文件] [授权版本tag] [daemon哈希] [App二进制哈希]
# 暂存目录由 App 侧（用户态）准备好并已通过 SelfUpgrade.validateStaged 校验门；
# 后三个参数缺省时退化为旧行为（手动兼容），提供时 root 侧在动手前复核——
# 关闭"授权弹窗确认之后偷换暂存包"的 TOCTOU（校验与安装同在 root 时间线）。
set -euo pipefail

# FANCTL_TEST_GATES_ONLY=1：无 root 回归钩子——跳过 EUID 检查，只执行下方授权前
# 门禁（暂存完整性 / tag 比对 / sha256 复核 / marker 符号链接）后退出 0，绝不触碰
# launchctl/文件系统安装路径。scripts/test-root-scripts.sh 靠它锁 P1-A/P1-B/P2/marker。
if [[ $EUID -ne 0 && "${FANCTL_TEST_GATES_ONLY:-}" != "1" ]]; then
    echo "此脚本须以管理员身份运行（由 App 的升级流程调起）" >&2
    exit 1
fi

STAGING="${1:-}"
if [[ -z "$STAGING" || ! -d "$STAGING" ]]; then
    echo "用法: upgrade.sh <暂存目录> [标记文件] [tag] [daemon-sha256] [appbin-sha256]" >&2
    exit 1
fi
if [[ ! -d "$STAGING/FanCtl.app" || ! -f "$STAGING/fanctld" ]]; then
    echo "暂存包不完整（缺 FanCtl.app 或 fanctld）" >&2
    exit 2
fi
MARKER="${2:-$STAGING/.upgrade-done}"
TAG="${3:-}"
SHA_DAEMON="${4:-}"
SHA_APPBIN="${5:-}"

# root 侧复核（在 bootout 之前——不匹配则原状退出，运行中的 daemon/App 不受扰动）
# R29：门禁 fail-closed——TAG/双哈希为必填。App 自动升级恒传齐；手动/社交工程路径
# 若缺参数则拒绝安装，禁止「跳过校验仍 root 动手」。
if [[ -z "$TAG" || -z "$SHA_DAEMON" || -z "$SHA_APPBIN" ]]; then
    echo "缺少授权 tag 或二进制哈希参数，拒绝升级（fail-closed）" >&2
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

# R23 审查（P3-1）：marker 已是符号链接时在 bootout 之前快速失败——否则装完 daemon、
# 杀完旧 App、替换完 bundle 才在末尾守卫 exit 4，语义是"系统已升级却回报失败、新 App
# 无人重启"。末尾写前的守卫仍保留（防"检查后、写入前"抢建链接的 TOCTOU 跟随截断）。
if [[ -L "$MARKER" ]]; then
    echo "完成标记是符号链接，拒绝升级（防跟随截断）" >&2
    exit 4
fi

if [[ "${FANCTL_TEST_GATES_ONLY:-}" == "1" ]]; then
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
mkdir -p /usr/local/libexec
install -m 755 -o root -g wheel "$STAGING/fanctld" /usr/local/libexec/fanctld
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
