#!/bin/bash
# upgrade.sh — 清风 App 内一键升级的特权安装过程（v3.9.0）
# 由 App 经 osascript "with administrator privileges" 调起：
#   bash <App>.app/Contents/Resources/upgrade.sh <暂存目录>
# 暂存目录由 App 侧（用户态）准备好并已通过 SelfUpgrade.validateStaged 校验门：
#   <staging>/FanCtl.app  <staging>/fanctld
# 本脚本只做安装动作，不做下载、不做校验（校验在用户态完成，失败根本不会走到这里）。
# 与 install.sh 的差异：不用 SUDO_USER（osascript 场景没有），App 归属按控制台用户归还；
# 结尾自动重启菜单栏 App，旧实例先杀。
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "此脚本须以管理员身份运行（由 App 的升级流程调起）" >&2
    exit 1
fi

STAGING="${1:-}"
if [[ -z "$STAGING" || ! -d "$STAGING" ]]; then
    echo "用法: upgrade.sh <暂存目录>" >&2
    exit 1
fi
if [[ ! -d "$STAGING/FanCtl.app" || ! -f "$STAGING/fanctld" ]]; then
    echo "暂存包不完整（缺 FanCtl.app 或 fanctld）" >&2
    exit 2
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

echo "==> 配置/日志目录权限对齐..."
mkdir -p "$SUPPORT" /Library/Logs/FanCtl
chown root:admin "$SUPPORT"; chmod 775 "$SUPPORT"
chown root:wheel /Library/Logs/FanCtl; chmod 755 /Library/Logs/FanCtl
[[ -f "$SUPPORT/config.json" ]] && chown root:admin "$SUPPORT/config.json" && chmod 664 "$SUPPORT/config.json" || true

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
[[ -f "$SUPPORT/config.json" ]] && chown root:admin "$SUPPORT/config.json" && chmod 664 "$SUPPORT/config.json" || true

echo "==> 重启菜单栏 App..."
if [[ "$LOGIN_USER" != "root" && -n "$LOGIN_USER" ]]; then
    LOGIN_UID=$(id -u "$LOGIN_USER")
    # root 上下文起用户态 GUI 进程：asuser 切进该用户 bootstrap 域。
    # 实测（v3.9.0 dogfood）：`asuser ... open -a` 静默失败（open 依赖的用户会话
    # LaunchServices 在该上下文不可达），`sudo -u user open` 同败。可靠路径 =
    # asuser + launchctl submit 拉起 MachServices 注册的 bundle：
    #   ① asuser open（标准做法，多数场景可用）
    #   ② asuser submit 直启二进制（open 不可达时的兜底，App 自带 LSUIElement 托盘；
    #     submit 无 KeepAlive，进程退出即结束，不残留常驻标签）
    #   ③ 两者都败不算安装失败——daemon 已升级完成，App 由用户手动 open
    # 实测语义（v3.9.0 dogfood）：对运行中的 submit 进程 launchctl remove 会直接
    # 杀掉它——因此 remove 只放在 submit 之前清残留（此刻 pkill 已杀掉旧进程，
    # 无副作用；不清则残留标签令本次 submit "already exists" 失败）。
    if ! /bin/launchctl asuser "$LOGIN_UID" /usr/bin/open -a "/Applications/清风.app" 2>/dev/null; then
        /bin/launchctl asuser "$LOGIN_UID" /bin/launchctl remove \
            "com.fanctl.app.upgrade-relaunch" 2>/dev/null || true
        /bin/launchctl asuser "$LOGIN_UID" /bin/launchctl submit \
            -l "com.fanctl.app.upgrade-relaunch" \
            -p "/Applications/清风.app/Contents/MacOS/FanCtl" 2>/dev/null || true
    fi
fi

echo "✅ 升级完成: $(/usr/local/libexec/fanctld -v)"
