#!/bin/bash
# 卸载 FanCtl（需要 sudo）：停止服务、恢复系统风扇调度、删除所有安装文件
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "请用 sudo 运行: sudo ./scripts/uninstall.sh"
    exit 1
fi

PLIST=/Library/LaunchDaemons/com.fanctl.daemon.plist

echo "==> 停止守护进程（退出时会自动恢复系统风扇调度）..."
launchctl bootout system "$PLIST" 2>/dev/null || true
sleep 1

echo "==> 关闭菜单栏 App（先停进程，避免删文件时它还在回写配置）..."
pkill -x FanCtl 2>/dev/null || true
sleep 1

echo "==> 删除文件..."
rm -f "$PLIST"
rm -f /usr/local/libexec/fanctld
rm -rf "/Library/Application Support/FanCtl"
rm -rf /Applications/FanCtl.app "/Applications/清风.app"
rm -f /var/log/fanctld.log

echo "==> 清理用户偏好（AI 个性化曲线/开关等）..."
# 用实际登录用户身份删，sudo 下直接 defaults 会误删 root 域
CONSOLE_USER=$(stat -f%Su /dev/console)
sudo -u "$CONSOLE_USER" defaults delete com.fanctl.app 2>/dev/null || true

echo "==> 清理用户缓存（趋势历史）..."
CONSOLE_HOME=$(sudo -u "$CONSOLE_USER" sh -c 'echo $HOME')
rm -rf "$CONSOLE_HOME/Library/Caches/com.fanctl.app"

echo ""
echo "✅ 已完全卸载，风扇已交还 macOS 系统调度。"
