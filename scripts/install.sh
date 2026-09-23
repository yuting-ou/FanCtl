#!/bin/bash
# 安装 FanCtl（需要 sudo）：
#   - fanctld → /usr/local/libexec/，注册为 LaunchDaemon 开机自启
#   - FanCtl.app → /Applications/
#   - 创建配置目录（admin 组可写，App 无需特权即可改配置；v2.8 起组由 staff 收紧为 admin）
set -euo pipefail

# 可单测谓词（R23 P1-B）：config.json 仅在「普通文件且非符号链接」时才允许 root
# chown/chmod——按路径操作会跟随链接，把权限/属主打到任意目标上。
# FANCTL_TEST_CONFIG_GUARD=1：无 root 回归钩子，对 $1 求谓词后退出（0=会修权限，1=跳过）。
fanctl_config_perm_safe() {
    local p="$1"
    [[ -f "$p" && ! -L "$p" ]]
}
if [[ $EUID -ne 0 && "${FANCTL_TEST_CONFIG_GUARD:-}" == "1" ]]; then
    fanctl_config_perm_safe "${1:-}"
    exit $?
fi

# R36（批次 A）目录信任谓词：root 要往某个目录里写"将被 root 执行的代码"之前，
# 必须确认这个目录不是用户可写的——否则同 uid 进程把它换成符号链接或预置同名文件，
# 下次授权即等于执行攻击者代码（R23/R28 修的是文件面，这里是目录面）。
# 判据：真实目录（非符号链接）+ 属主 uid 0 + 组/其他写位为 0。
fanctl_dir_trusted() {
    local d="$1" st owner mode
    [[ -d "$d" && ! -L "$d" ]] || return 1
    st=$(/usr/bin/stat -f "%u %p" "$d" 2>/dev/null) || return 1
    owner="${st%% *}"; mode="${st##* }"
    [[ "$owner" == "0" ]] || return 1
    [[ $(( 0$mode & 0022 )) -eq 0 ]]
}

# FANCTL_TEST_DIR_TRUST=1（仅非 root 生效）：对 $1 求谓词后退出（0=可信，1=不可信）。
# 安全向两支可无 root 测（普通用户属主、组可写）；"root 属主正例"无法无 root 构造，
# 诚实记档为仅真机验证。限非 root 是因为 osascript 会透传调用方环境（R36 实测），
# root 运行中任何测试后门都必须失效。
if [[ $EUID -ne 0 && "${FANCTL_TEST_DIR_TRUST:-}" == "1" ]]; then
    fanctl_dir_trusted "${1:-}"
    exit $?
fi

if [[ $EUID -ne 0 ]]; then
    echo "请用 sudo 运行: sudo ./scripts/install.sh"
    exit 1
fi

# R33：产物根随布局自适应——仓库树是 scripts/../dist；Release zip 是 install.sh 与
# FanCtl.app/fanctld/fanprobe 同级。原先固定 cd .. + dist/ 导致 zip 首装永远找不到产物。
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$_SCRIPT_DIR/fanctld" && -d "$_SCRIPT_DIR/FanCtl.app" ]]; then
    DIST="$_SCRIPT_DIR"
elif [[ -f "$_SCRIPT_DIR/../dist/fanctld" && -d "$_SCRIPT_DIR/../dist/FanCtl.app" ]]; then
    DIST="$(cd "$_SCRIPT_DIR/../dist" && pwd)"
else
    echo "未找到构建产物（fanctld + FanCtl.app）。仓库内请先 ./scripts/build.sh；Release 包请在解压目录执行。" >&2
    exit 1
fi
PLIST=/Library/LaunchDaemons/com.fanctl.daemon.plist
SUPPORT="/Library/Application Support/FanCtl"

if [[ ! -f "$DIST/fanctld" || ! -d "$DIST/FanCtl.app" ]]; then
    echo "未找到构建产物，请先运行 ./scripts/build.sh"
    exit 1
fi

echo "==> 停止旧服务（如有）..."
launchctl bootout system "$PLIST" 2>/dev/null || true

echo "==> 安装守护进程..."
# 目录信任门（批次 A）：/usr/local 与 /usr/local/libexec 必须 root 拥有且组/其他不可写。
# Homebrew 机器常把 /usr/local 交给登录用户——那种机器上"把 root 执行的代码放进去"
# 等于给同 uid 进程留一条提权道，宁可拒绝安装也不装个假安全。
LIBEXEC=/usr/local/libexec   # 生产路径写死：plist 的 ProgramArguments 硬编码同一绝对路径，两者不许漂移
mkdir -p "$LIBEXEC"
if ! fanctl_dir_trusted "$LIBEXEC" || ! fanctl_dir_trusted "$(dirname "$LIBEXEC")"; then
    echo "❌ 拒绝安装：${LIBEXEC} 或其父目录不是 root 拥有且组/其他不可写。" >&2
    echo "   这是 root 执行代码的落点，被用户可写就成了提权面。修归属后重试：" >&2
    echo "   sudo chown root:wheel $(dirname "$LIBEXEC") "$LIBEXEC" && sudo chmod 755 $(dirname "$LIBEXEC") "$LIBEXEC"" >&2
    exit 1
fi
install -m 755 -o root -g wheel "$DIST/fanctld" "$LIBEXEC/fanctld"
# 批次 A：特权脚本正文住在 root 拥有路径，App 只 exec、不再携带可被篡改的副本。
# 缺脚本 = 升级链路装不起来，宁可不装（fail-closed，绝不"跳过这步继续"）。
for _s in upgrade uninstall; do
    if [[ ! -f "$DIST/${_s}.sh" ]]; then
        echo "❌ 发行物缺 ${_s}.sh（无法安装 root 执行脚本）——请用 ./scripts/build.sh 重新构建或重新下载 Release 包" >&2
        exit 1
    fi
    install -m 755 -o root -g wheel "$DIST/${_s}.sh" "$LIBEXEC/fanctl-${_s}.sh"
done
# R32：诊断工具上 PATH（只读，无 root 运行需求）
mkdir -p /usr/local/bin
if [[ -f "$DIST/fanprobe" ]]; then
    install -m 755 -o root -g wheel "$DIST/fanprobe" /usr/local/bin/fanprobe
else
    echo "⚠️ dist/fanprobe 缺失——跳过诊断工具安装（请用 ./scripts/build.sh 重新构建）" >&2
fi

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
# R23（P1-B）：config.json 属性操作按路径会跟随符号链接，经 fanctl_config_perm_safe 拒绝
if fanctl_config_perm_safe "$SUPPORT/config.json"; then
    chown root:admin "$SUPPORT/config.json"
    chmod 664 "$SUPPORT/config.json"
fi
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
    echo "❌ LaunchDaemon 注册失败（plist=${PLIST}）。风扇调速当前无人接管——" >&2
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
# R33：与 upgrade.sh 对齐——未公证 bundle + quarantine = Gatekeeper 拦首次打开
xattr -dr com.apple.quarantine "/Applications/清风.app" 2>/dev/null || true
# 把 App bundle 属主改回实际登录用户（非 root）：此后仅改 UI 时可用 ./scripts/deploy.sh 免密替换，
# 无需再 sudo（守护进程仍归 root，与此无关）。
# R29：osascript 升级无 SUDO_USER——与 upgrade.sh 同源取 console 用户，否则
# App 属主停在 root:admin，deploy.sh 免密通道失效。
APP_OWNER="${SUDO_USER:-}"
if [[ -z "$APP_OWNER" || "$APP_OWNER" == "root" ]]; then
    APP_OWNER=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo root)
fi
if [[ -n "$APP_OWNER" && "$APP_OWNER" != "root" ]]; then
    chown -R "$APP_OWNER:staff" "/Applications/清风.app"
fi

# 确保守护进程已生成配置文件并放开组写权限（App 需要写它）
sleep 2
if fanctl_config_perm_safe "$SUPPORT/config.json"; then
    chown root:admin "$SUPPORT/config.json"
    chmod 664 "$SUPPORT/config.json"
fi

echo ""
echo "✅ 安装完成！"
echo "   - 守护进程已启动并设为开机自启（日志: /Library/Logs/FanCtl/）"
echo "   - 菜单栏 App: /Applications/清风.app（可手动打开，或设为登录启动项）"
echo ""
echo "现在打开 App: open /Applications/清风.app"
