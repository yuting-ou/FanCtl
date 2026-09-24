#!/bin/bash
# 卸载 FanCtl（需要 sudo）：停止服务、恢复系统风扇调度、删除所有安装文件
set -euo pipefail

# R40 删除前缀守卫。本脚本以 root 跑，而"登录用户的家目录"是**问出来的**
# （`sudo -u $USER sh -c 'echo $HOME'`）：问失败时它是空串，拼出来的删除目标就退化成
# `/Library/Caches/com.fanctl.app`——即 root 在文件系统根下删东西。宁可留一个缓存目录
# 让卸载报告看得见，也不拿可能为空/为 / 的前缀去 `rm -rf`。
fanctl_cache_target() {
    local h="$1"
    [[ -n "$h" && "$h" == /* && "$h" != "/" && -d "$h" ]] || return 1
    printf '%s/Library/Caches/com.fanctl.app\n' "$h"
}
# FANCTL_TEST_CACHE_TARGET=1（仅非 root 生效）：对 $1 求"将删路径"，可信则打印并退 0，
# 否则退 1。放在 EUID 检查之前，好让 scripts/test-root-scripts.sh 无 root 真跑这段。
if [[ $EUID -ne 0 && "${FANCTL_TEST_CACHE_TARGET:-}" == "1" ]]; then
    if fanctl_cache_target "${1:-}"; then exit 0; else exit 1; fi
fi

if [[ $EUID -ne 0 ]]; then
    echo "请用 sudo 运行: sudo $0"
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
# 批次 A：root 执行脚本与 daemon 同处，卸载必须一并清掉（残留=可被再次执行的死代码）
rm -f /usr/local/libexec/fanctl-upgrade.sh /usr/local/libexec/fanctl-uninstall.sh
# 旧版（<4.2.0）把脚本副本装在 bundle 内，bundle 已删即无残留；此处兼容显式清理
rm -f "/Applications/清风.app/Contents/Resources/uninstall.sh" \
      "/Applications/清风.app/Contents/Resources/upgrade.sh"
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
CONSOLE_HOME=$(sudo -u "$CONSOLE_USER" sh -c 'echo $HOME' 2>/dev/null || true)
# R40：删除目标必须过 fanctl_cache_target（绝对路径、非空、非 /、目录真实存在）才允许 rm。
# 问不到就跳过并在收尾提示里留下手动路径——留一个没人要的缓存目录，比拿空前缀去 rm -rf 好。
if CACHE_TARGET=$(fanctl_cache_target "$CONSOLE_HOME"); then
    rm -rf "$CACHE_TARGET"
else
    echo "⚠️ 拿不到可信的登录用户家目录（CONSOLE_USER=${CONSOLE_USER:-<空>}，HOME=${CONSOLE_HOME:-<空>}）" >&2
    echo "   已跳过用户缓存清理；要手动清的话是 ~/Library/Caches/com.fanctl.app" >&2
fi

echo ""
echo "✅ 已完全卸载，风扇已交还 macOS 系统调度。"
