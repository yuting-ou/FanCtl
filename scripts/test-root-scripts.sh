#!/bin/bash
# test-root-scripts.sh — root 脚本门禁回归（无需 root / 不碰真实系统路径）
# 覆盖 R23 P1-A（tag 带 v 必挂）、P1-B（config.json 符号链接）、P2（sha256 fail-open）、
# marker 符号链接、暂存完整性。被 fanctltests 以 Process 调起；也可直接跑：
#   ./scripts/test-root-scripts.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPGRADE="$ROOT/scripts/upgrade.sh"
INSTALL="$ROOT/scripts/install.sh"
TMP="$(mktemp -d /tmp/fanctl-root-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ❌ $1" >&2; }

# 期望 exit code：run_expect <期望码> <说明> <cmd...>
run_expect() {
    local want="$1" msg="$2"; shift 2
    local code=0
    "$@" >/dev/null 2>&1 || code=$?
    if [[ "$code" -eq "$want" ]]; then ok "$msg (exit $code)"; else bad "$msg (exit $code, want $want)"; fi
}

sha256() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

make_stage() {
    # $1=版本串写入 Info.plist；创建合法暂存布局
    local dir="$TMP/stage-$$-$RANDOM"
    mkdir -p "$dir/FanCtl.app/Contents/MacOS"
    printf '%s\n' "$1" > "$dir/.ver"
    cat > "$dir/FanCtl.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$1</string>
</dict></plist>
EOF
    echo "fake-daemon" > "$dir/fanctld"
    echo "fake-app-bin" > "$dir/FanCtl.app/Contents/MacOS/FanCtl"
    echo "$dir"
}

echo "== upgrade.sh 门禁（FANCTL_TEST_GATES_ONLY=1）=="

# --- 暂存完整性 ---
ST="$(make_stage 4.1.3)"
rm -f "$ST/fanctld"
run_expect 2 "缺 fanctld → exit 2" env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST"

ST="$(make_stage 4.1.3)"
rm -rf "$ST/FanCtl.app"
run_expect 2 "缺 FanCtl.app → exit 2" env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST"

run_expect 1 "空暂存参数 → exit 1" env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE"
run_expect 1 "暂存不存在 → exit 1" env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$TMP/no-such-dir"

# --- tag 比对（P1-A 的 shell 层）---
ST="$(make_stage 4.1.3)"
D_SHA=$(sha256 "$ST/fanctld")
A_SHA=$(sha256 "$ST/FanCtl.app/Contents/MacOS/FanCtl")
M="$TMP/marker-ok"

run_expect 0 "tag 与暂存版本一致 → gates-ok" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.3" "$D_SHA" "$A_SHA"

run_expect 3 "P1-A：传 v 前缀 tag（v4.1.3）必拒 — App 侧必须 sanitizeTag" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "v4.1.3" "$D_SHA" "$A_SHA"

run_expect 3 "暂存版本 ≠ 授权版本 → exit 3" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.4" "$D_SHA" "$A_SHA"

# --- sha256 复核 ---
ST="$(make_stage 4.1.3)"
D_SHA=$(sha256 "$ST/fanctld")
A_SHA=$(sha256 "$ST/FanCtl.app/Contents/MacOS/FanCtl")

HASH_A=$(printf 'a%.0s' $(seq 64))
HASH_B=$(printf 'b%.0s' $(seq 64))

run_expect 3 "daemon 哈希不符 → exit 3" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.3" "$HASH_A" "$A_SHA"

run_expect 3 "App 哈希不符 → exit 3" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.3" "$D_SHA" "$HASH_B"

run_expect 0 "双哈希命中 → gates-ok" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.3" "$D_SHA" "$A_SHA"

# 授权后偷换暂存内容 → 哈希门必须红（TOCTOU 复核语义）
ST="$(make_stage 4.1.3)"
D_SHA=$(sha256 "$ST/fanctld")
A_SHA=$(sha256 "$ST/FanCtl.app/Contents/MacOS/FanCtl")
echo "tampered" > "$ST/fanctld"
run_expect 3 "授权后偷换 fanctld → 哈希门 exit 3" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.3" "$D_SHA" "$A_SHA"

# --- marker 符号链接（P2-B / P3-1）---
ST="$(make_stage 4.1.3)"
D_SHA=$(sha256 "$ST/fanctld")
A_SHA=$(sha256 "$ST/FanCtl.app/Contents/MacOS/FanCtl")
VICTIM="$TMP/victim"
echo "keep-me" > "$VICTIM"
MLINK="$TMP/marker-link"
ln -s "$VICTIM" "$MLINK"
run_expect 4 "marker 是符号链接 → exit 4（bootout 前拒）" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$MLINK" "4.1.3" "$D_SHA" "$A_SHA"
if [[ "$(cat "$VICTIM")" == "keep-me" ]]; then
    ok "victim 文件未被截断"
else
    bad "victim 文件被改写：$(cat "$VICTIM")"
fi

# --- 无 tag/sha 时放行（手动兼容路径）---
ST="$(make_stage 4.1.3)"
run_expect 0 "无 tag/sha 参数（手动兼容）→ gates-ok" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST"

echo "== install.sh config.json 符号链接谓词（FANCTL_TEST_CONFIG_GUARD=1）=="

C_DIR="$TMP/cfg"
mkdir -p "$C_DIR"
REGULAR="$C_DIR/config.json"
echo '{}' > "$REGULAR"
LINK="$C_DIR/config-link.json"
ln -s "$REGULAR" "$LINK"
DANGLING="$C_DIR/dangling.json"
ln -s "$C_DIR/nope.json" "$DANGLING"

run_expect 0 "普通 config.json → 会修权限（exit 0）" \
    env FANCTL_TEST_CONFIG_GUARD=1 bash "$INSTALL" "$REGULAR"
run_expect 1 "符号链接 config.json → 跳过（exit 1）P1-B" \
    env FANCTL_TEST_CONFIG_GUARD=1 bash "$INSTALL" "$LINK"
run_expect 1 "悬空符号链接 → 跳过（exit 1）" \
    env FANCTL_TEST_CONFIG_GUARD=1 bash "$INSTALL" "$DANGLING"
run_expect 1 "路径不存在 → 跳过（exit 1）" \
    env FANCTL_TEST_CONFIG_GUARD=1 bash "$INSTALL" "$C_DIR/missing.json"

# upgrade.sh 仍内联 ! -L（自包含可 base64）——静态锁：两处 config 守卫必须在场
if grep -q '! -L "$SUPPORT/config.json"' "$UPGRADE"; then
    ok "upgrade.sh 内联 ! -L config.json 守卫在场（2 处）"
else
    bad "upgrade.sh 丢失 config.json 符号链接守卫"
fi
UP_L=$(grep -c '! -L "$SUPPORT/config.json"' "$UPGRADE" || true)
if [[ "$UP_L" -ge 2 ]]; then ok "upgrade.sh config 守卫出现 ≥2 次（got ${UP_L}）"; else bad "upgrade.sh config 守卫仅 ${UP_L} 次（want ≥2）"; fi

echo "== install.sh bootstrap 失败必须致命（R23 P3）=="
if grep -q 'LaunchDaemon 注册失败' "$INSTALL" && grep -q 'exit 1' "$INSTALL"; then
    ok "install.sh bootstrap 失败有显式报错+exit 1"
else
    bad "install.sh bootstrap 失败路径缺失"
fi

echo "——"
echo "root 脚本门禁：$pass 通过 / $fail 失败"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
exit 0
