#!/bin/bash
# snapshot-checks.sh —— 面板快照量具的机器化（R90）。R87 立的纪律是"整套 UI 逐屏量，
# 量具先要无法说谎"；R89 的 A/A/B 对照是手工跑的，本轮收进脚本：
#
#   snapshot-checks.sh run <outdir> [binary]    渲染全部 25 个变体到 outdir（默认+label+23 场景）
#   snapshot-checks.sh compare <A1> <A2> [B] [B2]   噪声底（A/A）与可选的改动对照（A/B；
#                                               B 也双跑时噪声底=max(A/A,B/B)——单对噪声
#                                               估计方差大，cold 类活数据场景实测 A/A 在
#                                               1.6%~4.8% 间跳，薄估计会造成假红）
#   snapshot-checks.sh ci [binary]              CI 模式（干净机器）：全渲染双跑 +
#                                               label/cold 字节一致 + 未知场景必须 exit(2)
#
# 用法（视觉/重构轮的完整流程）：
#   ./scripts/snapshot-checks.sh run /tmp/s/base1        # 改动前第 1 遍
#   ./scripts/snapshot-checks.sh run /tmp/s/base2        # 改动前第 2 遍（噪声底）
#   …改动 + ./scripts/build.sh…
#   ./scripts/snapshot-checks.sh run /tmp/s/after
#   ./scripts/snapshot-checks.sh compare /tmp/s/base1 /tmp/s/base2 /tmp/s/after
#
# 为什么对照要带噪声底：默认快照注入 Double.random 趋势夹具 + 本机 daemon 活数据，
# 同一二进制两遍渲染也有百分之几的像素差（R89 实测 3.5–7.5%）；label（纯静态）为 0。
# 方法论（R90 实测教训）：B 组要与基线**尽量同时间窗**渲染——本机有活 daemon 时，
# 温度/RPM/配置随时间漂移，隔半小时的"跨时间对照"会把活数据漂移误判成回归
# （cold 实测：同二进制隔时对照 5%、同时间窗对照 1.6%）。
# 判据 = A/B 差异 ≤ max(噪声底×1.5, 噪声底+3pp)——+3pp 余量是实测教训：只剩活 RPM
# 一类数据的低噪声场景（cold）方差肥尾，单样本噪声底会低估；label 必须逐字节一致
# ——结构性回归（卡片缺失/布局位移）会远超噪声底。
#
# CI 模式为什么不做像素对照：runner 上没有"改动前"的二进制，跨机器的 golden 图又会随
# SDK/SwiftUI 版本漂移（假红比没有门更糟）。CI 守的是量具契约本身：全部变体可渲染、
# 纯静态场景双跑字节一致（防不确定性渗入）、未知场景名必须 exit(2) 不许静默出默认屏。
set -o pipefail

SCENES="quiet tab1 tab2 tab3 editcurve nightcustom spin nofan battery night palm unreachable calibrate higheffort rec fault mismatch envover cold singlefan metrics suggest digits"
DEFAULT_BIN="dist/FanCtl.app/Contents/MacOS/FanCtl"

render_all() {  # $1 = binary  $2 = outdir
    local bin="$1" out="$2"
    mkdir -p "$out"
    "$bin" --snapshot || return 1
    cp /tmp/fanctl-snapshot.png "$out/default.png" || return 1
    "$bin" --snapshot label || return 1
    cp /tmp/fanctl-snapshot-label.png "$out/label.png" || return 1
    for s in $SCENES; do
        "$bin" --snapshot "scene=$s" 2>>"$out/errors.log" || { echo "scene=$s 渲染失败"; return 1; }
        [ -f "/tmp/fanctl-snapshot-$s.png" ] || { echo "scene=$s 未产出 PNG（场景清单漂移？）"; return 1; }
        cp "/tmp/fanctl-snapshot-$s.png" "$out/$s.png" || return 1
    done
    local n; n=$(ls "$out"/*.png | wc -l | tr -d ' ')
    [ "$n" = "25" ] || { echo "变体数 $n ≠ 25（场景面与脚本漂移，量具在说谎）"; return 1; }
}

case "$1" in
run)
    # $2 = 输出目录，$3 = 可选二进制（默认 dist 产物）
    render_all "${3:-$DEFAULT_BIN}" "$2" || exit 1
    echo "✅ 25 个变体已渲染到 $2"
    ;;
compare)
    A1="$2"; A2="$3"; B="${4:-}"; B2="${5:-}"
    [ -d "$A1" ] && [ -d "$A2" ] || { echo "用法: $0 compare <A1> <A2> [B] [B2]"; exit 1; }
    python3 - "$A1" "$A2" "$B" "$B2" <<'PYEOF'
import sys, os
from PIL import Image, ImageChops
a1, a2, b, b2 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def diff(pa, pb):
    a = Image.open(pa).convert('RGB'); img = Image.open(pb).convert('RGB')
    if a.size != img.size: return None
    d = ImageChops.difference(a, img)
    return sum(1 for p in d.getdata() if p != (0, 0, 0)) / (a.size[0] * a.size[1])
fails = 0
print(f'{"变体":16s} {"噪声底":>9s} {"A/B 差异":>9s}   判定')
for f in sorted(os.listdir(a1)):
    if not f.endswith('.png'): continue
    aa = diff(f'{a1}/{f}', f'{a2}/{f}')
    bb = diff(f'{b2}/{f}', f'{b2}/{f}') if b2 and os.path.exists(f'{b2}/{f}') else 0.0
    ab = diff(f'{a1}/{f}', f'{b}/{f}') if b and os.path.exists(f'{b}/{f}') else None
    ab2 = diff(f'{a2}/{f}', f'{b}/{f}') if b and os.path.exists(f'{b}/{f}') else None
    if aa is None or (b and (ab is None or ab2 is None)):
        print(f'{f:16s} 尺寸不一致'); fails += 1; continue
    noise = max(aa, bb)
    verdict = '—'
    if b:
        cross = max(ab, ab2)
        ok = cross <= max(noise * 1.5, noise + 0.03) and (f != 'label.png' or cross == 0.0)
        verdict = 'OK' if ok else 'FAIL'
        if not ok: fails += 1
        ab = cross
    print(f'{f:16s} {noise*100:8.3f}% {("%8.3f%%" % (ab*100)) if ab is not None else "     —  "}   {verdict}')
print('FAILS:', fails)
sys.exit(1 if fails else 0)
PYEOF
    ;;
ci)
    # $2 = 可选二进制（默认 dist 产物）
    BIN="${2:-$DEFAULT_BIN}"
    [ -x "$BIN" ] || { echo "二进制不存在: $BIN"; exit 1; }
    T="$(mktemp -d)"
    trap 'rm -rf "$T"' EXIT
    echo "== 双跑渲染 =="
    render_all "$BIN" "$T/r1" || exit 1
    render_all "$BIN" "$T/r2" || exit 1
    echo "== 纯静态变体双跑必须字节一致 =="
    fail=0
    for f in label cold; do
        if cmp -s "$T/r1/$f.png" "$T/r2/$f.png"; then
            echo "  ✓ $f 双跑字节一致"
        else
            echo "  ✗ $f 双跑不一致（不确定性渗入了静态场景——本地有活 daemon 时改用 compare 模式）"
            fail=1
        fi
    done
    echo "== 未知场景名必须 exit(2)（量具不许说谎） =="
    if "$BIN" --snapshot scene=nonexistent >/dev/null 2>"$T/err.txt"; then
        echo "  ✗ 未知场景静默 exit 0（产出了其实是默认屏的 PNG）"; fail=1
    else
        rc=$?
        if [ "$rc" = "2" ] && grep -q "未知 scene" "$T/err.txt"; then
            echo "  ✓ exit 2 + stderr 说明"
        else
            echo "  ✗ 退出码 $rc 或报错形态不对"; fail=1
        fi
    fi
    [ "$fail" = "0" ] && echo "✅ 快照量具契约（CI 模式）全绿" || echo "❌ 快照量具契约红"
    exit $fail
    ;;
*)
    sed -n '2,12p' "$0"; exit 2 ;;
esac
