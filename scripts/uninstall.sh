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
# v3.6.1：bootout 失败被吞时 fanctld 带着强制转速存活且二进制即将被删——
# 无人能再恢复。pkill 兜底确保 SIGTERM 送达（fanctld 信号处理会 restoreAutoAll）
pkill -x fanctld 2>/dev/null || true
sleep 1

echo "==> 关闭菜单栏 App（先注销登录项，再停进程，避免删文件时它还在回写配置）..."
# v3.4.5（4D）：SMAppService 登录项必须在 App 被删除前由 App 自身注销
#（系统无 CLI 反注册接口；不注销会在系统设置→登录项留下死条目）
# R23（P2 修复）：注销必须发生在**控制台用户**的 launchd 域——本脚本以 root 运行，
# 直接执行注销的是 root 会话（没有登记），真用户的登录项删不掉（死条目恰是 4D
# 要防的）。与下方 defaults 清理同法，su 到控制台用户执行。
CU=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo "")
if [[ -n "$CU" && "$CU" != "root" ]]; then
    /usr/bin/su "$CU" -c "/Applications/清风.app/Contents/MacOS/FanCtl --unregister-login-item" 2>/dev/null \
      || /usr/bin/su "$CU" -c "/Applications/FanCtl.app/Contents/MacOS/FanCtl --unregister-login-item" 2>/dev/null || true
fi
pkill -x FanCtl 2>/dev/null || true
sleep 1

echo "==> 删除文件..."
rm -f "$PLIST"
rm -f /usr/local/libexec/fanctld
rm -f /usr/local/bin/fanprobe   # R33：install/upgrade 会装上，卸载必须一并清
rm -rf "/Library/Application Support/FanCtl"
rm -rf /Applications/FanCtl.app "/Applications/清风.app"
rm -f /var/log/fanctld.log
rm -rf /Library/Logs/FanCtl   # v3.4.5（4D）：daemon 自管日志目录（install.sh 创建），旧版漏删

echo "==> 注销菜单栏 App 的登录项（SMAppService）..."
# 已由上方 --unregister-login-item 完成（App 删除前自注销）；若 App 当时不在，
# 提示用户手动检查系统设置残留
echo "    （若曾开启过「登录时启动」，请到 系统设置 → 通用 → 登录项 确认无「清风」残留）"

echo "==> 清理用户偏好（AI 个性化曲线/开关等）..."
# 用实际登录用户身份删，sudo 下直接 defaults 会误删 root 域
CONSOLE_USER=$(stat -f%Su /dev/console)
sudo -u "$CONSOLE_USER" defaults delete com.fanctl.app 2>/dev/null || true

echo "==> 清理用户缓存（趋势历史）..."
CONSOLE_HOME=$(sudo -u "$CONSOLE_USER" sh -c 'echo $HOME')
rm -rf "$CONSOLE_HOME/Library/Caches/com.fanctl.app"

echo ""
echo "✅ 已完全卸载，风扇已交还 macOS 系统调度。"
