#!/bin/bash
# 安装 FanCtl（需要 sudo）：
#   - fanctld → /usr/local/libexec/，注册为 LaunchDaemon 开机自启
#   - FanCtl.app → /Applications/
#   - 创建配置目录（admin 组可写，App 无需特权即可改配置；v2.8 起组由 staff 收紧为 admin）
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "请用 sudo 运行: sudo ./scripts/install.sh"
    exit 1
fi

cd "$(dirname "$0")/.."
DIST="$(pwd)/dist"
PLIST=/Library/LaunchDaemons/com.fanctl.daemon.plist
SUPPORT="/Library/Application Support/FanCtl"

if [[ ! -f "$DIST/fanctld" || ! -d "$DIST/FanCtl.app" ]]; then
    echo "未找到构建产物，请先运行 ./scripts/build.sh"
    exit 1
fi

echo "==> 停止旧服务（如有）..."
launchctl bootout system "$PLIST" 2>/dev/null || true

echo "==> 安装守护进程..."
mkdir -p /usr/local/libexec
install -m 755 -o root -g wheel "$DIST/fanctld" /usr/local/libexec/fanctld

echo "==> 创建配置与日志目录..."
mkdir -p "$SUPPORT"
mkdir -p /Library/Logs/FanCtl
# v2.8: 组收紧 staff(所有本地用户) → admin——此前任何本地用户可删除 status/学习数据；
# 安装者必是 admin（需 sudo），App 用户即 admin，组写权限语义不变
chown root:admin "$SUPPORT"
chmod 775 "$SUPPORT"
chown root:wheel /Library/Logs/FanCtl
chmod 755 /Library/Logs/FanCtl
# 已有配置/日志文件则保留权限一致
# R23（P1-B）：config.json 属性操作按路径会跟随符号链接，加 `! -L` 拒绝（同 upgrade.sh）
[[ -f "$SUPPORT/config.json" && ! -L "$SUPPORT/config.json" ]] && chown root:admin "$SUPPORT/config.json" && chmod 664 "$SUPPORT/config.json" || true
[[ -f "/Library/Logs/FanCtl/fanctld.log" ]] && chown root:wheel "/Library/Logs/FanCtl/fanctld.log" || true
[[ -f "/Library/Logs/FanCtl/fanctld.err.log" ]] && chown root:wheel "/Library/Logs/FanCtl/fanctld.err.log" || true
[[ -f "/Library/Logs/FanCtl/fanctld.out.log" ]] && chown root:wheel "/Library/Logs/FanCtl/fanctld.out.log" || true

echo "==> 注册 LaunchDaemon..."
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.fanctl.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/fanctld</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/Library/Logs/FanCtl/fanctld.out.log</string>
    <key>StandardErrorPath</key>
    <string>/Library/Logs/FanCtl/fanctld.err.log</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <false/>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
# R23（P3）：bootstrap 失败此前被 set -e 无声吞退——此刻 daemon 已 bootout、二进制已装、
# App 未装，处于"调速无人管"中间态且无提示。显式报错并给恢复路径。
if ! launchctl bootstrap system "$PLIST"; then
    echo "❌ LaunchDaemon 注册失败（plist=$PLIST）。风扇调速当前无人接管——" >&2
    echo "   排查后重跑 sudo ./scripts/install.sh；或先手动恢复系统调度：launchctl kickstart -k system/com.fanctl.daemon" >&2
    exit 1
fi

echo "==> 安装菜单栏 App..."
# v3.6.1：升级时先停旧实例——不杀则旧进程持有已删除的 bundle 继续运行，
# 出现双菜单栏图标且新旧实例互踩 config.json
pkill -x FanCtl 2>/dev/null || true
sleep 1
rm -rf "/Applications/清风.app" /Applications/FanCtl.app
cp -R "$DIST/FanCtl.app" "/Applications/清风.app"
# 把 App bundle 属主改回实际登录用户（非 root）：此后仅改 UI 时可用 ./scripts/deploy.sh 免密替换，
# 无需再 sudo（守护进程仍归 root，与此无关）
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    chown -R "$SUDO_USER:staff" "/Applications/清风.app"
fi

# 确保守护进程已生成配置文件并放开组写权限（App 需要写它）
sleep 2
if [[ -f "$SUPPORT/config.json" && ! -L "$SUPPORT/config.json" ]]; then
    chown root:admin "$SUPPORT/config.json"
    chmod 664 "$SUPPORT/config.json"
fi

echo ""
echo "✅ 安装完成！"
echo "   - 守护进程已启动并设为开机自启（日志: /Library/Logs/FanCtl/）"
echo "   - 菜单栏 App: /Applications/清风.app（可手动打开，或设为登录启动项）"
echo ""
echo "现在打开 App: open /Applications/清风.app"
