#!/bin/bash
# 部署菜单栏 App（无需 sudo）——仅 App 改动时用。
# 原理：/Applications 对 admin 组可写且无 sticky 位，当前用户（admin）可自由增删其中条目。
# 只要 App bundle 归当前用户所有，rm+cp 即可；历史遗留的 root 属主 bundle 用 mv 移走让位（也无需 sudo）。
# 守护进程/SMCCore 变更仍需 sudo ./scripts/install.sh（那才真正需要 root）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="/Applications/清风.app"
DIST_APP="dist/FanCtl.app"

if [[ ! -d "$DIST_APP" ]]; then
    echo "未找到 $DIST_APP，请先运行 ./scripts/build.sh"
    exit 1
fi

echo "==> 关闭运行中的 App..."
pkill -f "清风.app/Contents/MacOS/FanCtl" 2>/dev/null || true
sleep 1

echo "==> 替换 App bundle（无需 sudo）..."
if [[ -d "$APP" ]]; then
    # 首选直接删除（当前用户自有的 bundle）；删不动（历史 root 属主）则移到 /tmp 让位，同样无需 sudo
    if ! rm -rf "$APP" 2>/dev/null; then
        LEGACY="/tmp/清风.app.legacy.$(date +%s)"
        mv "$APP" "$LEGACY"
        echo "   旧的 root 属主 bundle 已移至 $LEGACY（系统会自动清理 /tmp）"
    fi
fi
cp -R "$DIST_APP" "$APP"

echo "==> 启动 App..."
open "$APP" 2>/dev/null || { sleep 2; open "$APP"; }

echo ""
echo "✅ 部署完成（本次无需密码）。属主：$(stat -f '%Su' "$APP")"
echo "   今后仅改 UI 时执行：./scripts/build.sh && ./scripts/deploy.sh"
