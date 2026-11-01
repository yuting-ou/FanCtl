#!/bin/bash
# 覆盖率门（R95）：llvm-cov 挂到自带 harness（无 XCTest 的 executable target）。
# 可行性已实测（2026-11-02，macOS 26B123 + Xcode 工具链）：swift build
# --enable-code-coverage → 直接跑插桩二进制 → llvm-profdata merge → llvm-cov report。
# 两道门槛（行覆盖，llvm-cov report 的 Lines% 列）：
#   ControlEngine.swift   ≥ CE_FLOOR（默认 94.5%；实测 95.37%，余量 0.87pp）
#   SMCCore 模块剔 Driver/ ≥ CORE_FLOOR（默认 94.0%；实测 94.94%，余量 0.94pp）
#   —— Driver/（真 IOKit 落地层）按依赖图设计被 MockSMC 替代，不计入门槛口径；
#     门槛余量 ≤1pp：只防"实质覆盖回退"（删测试/跳路径），不做刷数字的虚荣门。
# 用法：scripts/coverage-gate.sh（门槛可用环境变量临时抬高做变异验证：
#   CE_FLOOR=99 scripts/coverage-gate.sh 应红）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CE_FLOOR="${CE_FLOOR:-94.5}"
CORE_FLOOR="${CORE_FLOOR:-94.0}"

echo "==> 覆盖率插桩构建（debug）..."
swift build --enable-code-coverage

PROF=".build/debug/codecov/fanctltests.profraw"
PDATA=".build/debug/codecov/fanctltests.profdata"
echo "==> 跑插桩测试..."
OUT="$(mktemp)"
if ! LLVM_PROFILE_FILE="$PROF" .build/debug/fanctltests >"$OUT" 2>&1; then
    tail -5 "$OUT"
    echo "ERROR: 测试未全绿，覆盖率门不判定（先修测试）" >&2
    exit 1
fi
grep -E "✅|❌" "$OUT" | tail -1

xcrun llvm-profdata merge -sparse "$PROF" -o "$PDATA"

# 行覆盖 % = llvm-cov report TOTAL 行第 10 列（Regions/Functions/Lines 三组的第三列）
cov() {
    xcrun llvm-cov report .build/debug/fanctltests -instr-profile="$PDATA" "$@" 2>/dev/null \
        | awk '$1=="TOTAL"{print $10}'
}
CE="$(cov Sources/SMCCore/ControlEngine.swift)"
CORE="$(cov --ignore-filename-regex='.*/Driver/.*' Sources/SMCCore)"
echo "ControlEngine.swift 行覆盖: ${CE}（门槛 ${CE_FLOOR}%）"
echo "SMCCore（剔 Driver）行覆盖: ${CORE}（门槛 ${CORE_FLOOR}%）"
if ! awk -v v="$CE" -v f="$CE_FLOOR" 'BEGIN{exit !(v+0>=f+0)}'; then
    echo "❌ ControlEngine.swift 行覆盖 ${CE}% 跌破门槛 ${CE_FLOOR}%" >&2
    exit 1
fi
if ! awk -v v="$CORE" -v f="$CORE_FLOOR" 'BEGIN{exit !(v+0>=f+0)}'; then
    echo "❌ SMCCore 行覆盖 ${CORE}% 跌破门槛 ${CORE_FLOOR}%" >&2
    exit 1
fi
echo "✅ 覆盖率门通过"
