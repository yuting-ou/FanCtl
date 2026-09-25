#!/bin/bash
# test-root-scripts.sh — root 脚本门禁回归（无需 root / 不碰真实系统路径）
# 覆盖 R23 P1-A（tag 带 v 必挂）、P1-B（config.json 符号链接）、P2（sha256 fail-open）、
# marker 符号链接、暂存完整性。被 fanctltests 以 Process 调起；也可直接跑：
#   ./scripts/test-root-scripts.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPGRADE="$ROOT/scripts/upgrade.sh"
INSTALL="$ROOT/scripts/install.sh"
# 暂存跟随 $TMPDIR（macOS 惯例）：/tmp 只读的受限环境下 mktemp 直接失败，
# set -e 让整个门禁跑不了，红得误导（报「输出缺少汇总行」而非真实原因）（R34）
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fanctl-root-tests.XXXXXX")"
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
    # 批次 A：暂存包必须自带 root 执行脚本正文（upgrade.sh 缺即 exit 2）
    echo "#!/bin/bash" > "$dir/upgrade.sh"
    echo "#!/bin/bash" > "$dir/uninstall.sh"
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
# 批次 A：暂存的**特权脚本正文**也在 root 侧复核之列（它们会被装成 root 执行代码）
U_SHA=$(sha256 "$ST/upgrade.sh")
N_SHA=$(sha256 "$ST/uninstall.sh")
M="$TMP/marker-ok"

run_expect 0 "tag 与暂存版本一致 → gates-ok" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.3" "$D_SHA" "$A_SHA" "$U_SHA" "$N_SHA"

run_expect 3 "R29 fail-closed：缺 tag/哈希 → exit 3（不得跳过门禁）" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M"

run_expect 3 "R29 fail-closed：仅有 marker 无 tag → exit 3" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "" "$D_SHA" "$A_SHA" "$U_SHA" "$N_SHA"

run_expect 3 "P1-A：传 v 前缀 tag（v4.1.3）必拒 — App 侧必须 sanitizeTag" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "v4.1.3" "$D_SHA" "$A_SHA" "$U_SHA" "$N_SHA"

run_expect 3 "暂存版本 ≠ 授权版本 → exit 3" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.4" "$D_SHA" "$A_SHA" "$U_SHA" "$N_SHA"

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
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.3" "$D_SHA" "$A_SHA" "$U_SHA" "$N_SHA"

# 授权后偷换暂存内容 → 哈希门必须红（TOCTOU 复核语义）
ST="$(make_stage 4.1.3)"
D_SHA=$(sha256 "$ST/fanctld")
A_SHA=$(sha256 "$ST/FanCtl.app/Contents/MacOS/FanCtl")
echo "tampered" > "$ST/fanctld"
run_expect 3 "授权后偷换 fanctld → 哈希门 exit 3" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$M" "4.1.3" "$D_SHA" "$A_SHA" "$U_SHA" "$N_SHA"

# --- marker 符号链接（P2-B / P3-1）---
ST="$(make_stage 4.1.3)"
D_SHA=$(sha256 "$ST/fanctld")
A_SHA=$(sha256 "$ST/FanCtl.app/Contents/MacOS/FanCtl")
VICTIM="$TMP/victim"
echo "keep-me" > "$VICTIM"
MLINK="$TMP/marker-link"
ln -s "$VICTIM" "$MLINK"
run_expect 4 "marker 是符号链接 → exit 4（bootout 前拒）" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$ST" "$MLINK" "4.1.3" "$D_SHA" "$A_SHA" "$U_SHA" "$N_SHA"
if [[ "$(cat "$VICTIM")" == "keep-me" ]]; then
    ok "victim 文件未被截断"
else
    bad "victim 文件被改写：$(cat "$VICTIM")"
fi

# --- 无 tag/sha 时放行（手动兼容路径）---
ST="$(make_stage 4.1.3)"
run_expect 3 "无 tag/sha 参数 → fail-closed exit 3（R29 取消手动兼容跳过门禁）" \
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
echo "== shell 展开的多字节邻接（R35 发版链）=="
# v4.1.4 首次发版在 CI 红于 build.sh："$f（全角括号" 报 unbound variable（bash 把紧跟
# 变量名的多字节吞进名字；本地 bash 3.2 + 各 locale 都复现不出，但不值得拿发版赌）。
# 规则：非 ASCII 紧跟展开的一律写 ${VAR}——扫全 scripts/*.sh 的非注释行。
mb_hits=$(perl -ne 'print "$ARGV:$.: $_" if /^\s*(?!#).*\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/' \
    "$ROOT"/scripts/*.sh 2>/dev/null || true)
if [[ -z "$mb_hits" ]]; then
    ok '无 $VAR 紧跟非 ASCII 的展开（发行路径不赌 locale）'
else
    bad "存在 \$VAR 紧跟非 ASCII 的展开："
    printf '%s\n' "$mb_hits" >&2
fi

echo "== 批次 A：特权脚本落点与自我刷新（R36）=="
if grep -q 'fanctl-\${_s}\.sh' "$INSTALL" && grep -q 'fanctl-\${_s}\.sh' "$UPGRADE"; then
    ok "install.sh 与 upgrade.sh 都把特权脚本装成 fanctl-{upgrade,uninstall}.sh"
else
    bad "特权脚本落点缺失（install/upgrade 之一未装 fanctl-*.sh）"
fi
if grep -q 'fanctl_dir_trusted' "$INSTALL" && grep -q 'fanctl_dir_trusted' "$UPGRADE"; then
    ok "两个 root 脚本都装目录信任门（落点必须 root 拥有且组/其他不可写）"
else
    bad "目录信任门缺失（可被装进用户可写目录=提权面）"
fi
if grep -q 'upgrade.sh' "$ROOT/.github/workflows/ci.yml" \
   && grep -qE 'cp scripts/upgrade\.sh "\$STAGE/"' "$ROOT/.github/workflows/ci.yml"; then
    ok "发行 zip 携带 upgrade.sh（首装/升级都能刷新 root 脚本）"
else
    bad "ci.yml 的 STAGE 未带 upgrade.sh——批次 A 后 App 升级链会断"
fi
if grep -qE 'cp "\$ROOT/scripts/(uninstall|upgrade)\.sh" "\$APP/Contents/Resources' "$ROOT/scripts/build.sh"; then
    bad "build.sh 仍把特权脚本复制进 App bundle（用户可写的 root 执行代码）"
else
    ok "build.sh 不再往 App bundle 里放特权脚本副本"
fi
if grep -q 'UpgradeScript\|embeddedUpgradeScriptBase64' "$ROOT/scripts/build.sh"; then
    bad "build.sh 仍生成内嵌脚本常量（该机制已随批次 A 作废，留着=双实现分叉）"
else
    ok "内嵌 base64 机制已整体作废（build.sh 无残留）"
fi
# 行为面：暂存包缺 upgrade.sh / uninstall.sh → 必须 exit 2（缺链路组件宁可不装）
_stage_no_scripts=$(make_stage "4.2.0")
rm -f "$_stage_no_scripts/upgrade.sh"
_sha_d=$(sha256 "$_stage_no_scripts/fanctld")
_sha_a=$(sha256 "$_stage_no_scripts/FanCtl.app/Contents/MacOS/FanCtl")
run_expect 2 "暂存包缺 upgrade.sh → exit 2（拒绝半个升级链）" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$_stage_no_scripts" "$_stage_no_scripts/.m" 4.2.0 "$_sha_d" "$_sha_a" "deadbeef" "deadbeef"
# 目录信任谓词（无 root 可测的安全向两支：普通用户属主 / 组可写）
_trust_dir="$TMP/trust-user"
mkdir -p "$_trust_dir"
run_expect 1 "谓词：登录用户属主的目录 → 不可信" \
    env FANCTL_TEST_DIR_TRUST=1 bash "$INSTALL" "$_trust_dir"
chmod 775 "$_trust_dir" 2>/dev/null || true
run_expect 1 "谓词：组可写目录 → 不可信（root 代码落点必须无组写位）" \
    env FANCTL_TEST_DIR_TRUST=1 bash "$INSTALL" "$_trust_dir"
# 正例（root 属主 + 755）需要 root 才能构造，诚实记档为"仅真机验证"，不在门禁里假称已测

echo "== R36 审查轮修复的防回潮门 =="
# (1) 函数**定义必须先于调用**：R36 的 P1 就是这个（调用早于定义 → bash 报
#     "command not found"（127），`if ! fn` 把 127 反成判真 → 健康机器上拒支 exit 5，
#     App 内一键升级 100% 失败；而测试钩子恰好跳过那块，32 项门全绿）。
for f in "$INSTALL" "$UPGRADE"; do
    def_line=$(grep -n '^fanctl_dir_trusted() {' "$f" | head -1 | cut -d: -f1 || true)
    call_line=$(grep -n 'if ! fanctl_dir_trusted' "$f" | head -1 | cut -d: -f1 || true)
    if [[ -z "$call_line" ]]; then
        bad "$(basename "$f") 找不到目录信任调用（门被删了？）"
    elif [[ -z "$def_line" || "$def_line" -gt "$call_line" ]]; then
        bad "$(basename "$f")：fanctl_dir_trusted 定义(:$def_line) 必须先于调用(:$call_line)"
    else
        ok "$(basename "$f")：信任谓词定义先于调用（bash 顺序解析，错序即静默死锁）"
    fi
done
# (2) 全局测试后门必须限非 root：osascript 的 do shell script 会透传调用方环境
if grep -q 'FANCTL_TEST_GATES_ONLY' "$UPGRADE" && \
   ! grep -qE '^if \[\[ "\$\{FANCTL_TEST_GATES_ONLY' "$UPGRADE"; then
    ok "upgrade.sh 的 gates-only 后门带非 root 前置条件"
else
    bad "upgrade.sh 的 gates-only 后门未限非 root（root 运行中可被 env 注入跳过实装）"
fi
for h in FANCTL_TEST_DIR_TRUST FANCTL_TEST_CONFIG_GUARD; do
    if grep -qE "\[\[ .*EUID -ne 0.*$h" "$INSTALL" "$UPGRADE"; then
        ok "后门 $h 要求非 root"
    else
        bad "后门 $h 未限非 root"
    fi
done
# (3) 落点路径不得由 env 决定（plist 里 ProgramArguments 是硬编码绝对路径）
if grep -q 'FANCTL_LIBEXEC_DIR' "$INSTALL" || grep -q 'FANCTL_LIBEXEC_DIR' "$UPGRADE"; then
    bad "仍存在 FANCTL_LIBEXEC_DIR 覆写（env 能把 root 代码装到别处而 plist 仍指死路径）"
else
    ok "特权落点写死 /usr/local/libexec（无 env 漂移面）"
fi
# (4) 行为面：暂存的 upgrade.sh 在授权后被换掉 → 哈希门必须 exit 3
_stage_tamper=$(make_stage "4.2.0")
_td=$(sha256 "$_stage_tamper/fanctld"); _ta=$(sha256 "$_stage_tamper/FanCtl.app/Contents/MacOS/FanCtl")
_tu=$(sha256 "$_stage_tamper/upgrade.sh"); _tn=$(sha256 "$_stage_tamper/uninstall.sh")
printf 'evil\n' > "$_stage_tamper/upgrade.sh"   # 授权后被偷换（App 传的是换前的哈希）
run_expect 3 "暂存 upgrade.sh 授权后被换掉 → 哈希门 exit 3（正文也是 root 执行代码）" \
    env FANCTL_TEST_GATES_ONLY=1 bash "$UPGRADE" "$_stage_tamper" "$_stage_tamper/.m" 4.2.0 \
        "$_td" "$_ta" "$_tu" "$_tn"

echo "== 发行说明与诊断入口（R37）=="
if grep -q -- "--notes-file RELEASE-NOTES.md" "$ROOT/.github/workflows/ci.yml"; then
    ok "Release 说明来自仓库文件（不再依赖 tag 批注——CI 上会退化成 commit message）"
else
    bad "ci.yml 未使用 --notes-file（发行说明可能丢迁移警示）"
fi
if [[ -f "$ROOT/RELEASE-NOTES.md" ]] && grep -q "sudo ./install.sh" "$ROOT/RELEASE-NOTES.md"; then
    ok "RELEASE-NOTES.md 在场且含首装/迁移指引"
else
    bad "RELEASE-NOTES.md 缺失或没有 sudo ./install.sh 指引"
fi
# 说明里必须点名本版的完整版本号（只提旧系列 = 迁移警示过期；发 4.2.9 贴 4.2.2 的
# 说明也在此红）。V 为空时必须直接判负——`grep -qF ""` 是恒真，空串会把这道门变成摆设。
V=$(head -1 "$ROOT/VERSION" | awk '{print $1}')
# 必须命中"本版变更要点"里那条 bullet（`- <版本>：`）——全文匹配会被旧版警示行蒙过
V_RE=${V//./\.}
if [[ -n "$V" ]] && grep -qE "^- ${V_RE}[：:]" "$ROOT/RELEASE-NOTES.md" 2>/dev/null; then
    ok "RELEASE-NOTES.md 有本版要点行 - ${V}："
else
    bad "RELEASE-NOTES.md 缺要点行 - ${V:-<VERSION 读空>}：（说明与 tag 会不同源）"
fi
# 配对门要命中代码本身而不是注释：`--report` 三个字符在注释里也算数
if grep -q 'contains("--report")' "$ROOT/Sources/fanprobe/main.swift" \
   && grep -q "id: report" "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml"; then
    ok "诊断入口成对存在（fanprobe --report 分支 ↔ issue 模板要求它）"
else
    bad "诊断入口脱节：fanprobe 的 --report 分支或 issue 模板必填项缺失"
fi

echo "== 装机落点常量与脚本同源（R37 审查 P1）=="
# Swift 侧的两个常量只被 fanprobe 用来"报装了什么样子的机器"，写错不会崩，但会让诊断包
# 第 2 行谎报 App 未找到/daemon 缺失——正是 issue 的第一问。此处与 install/upgrade/uninstall
# 里的字面量逐字比对，任何一侧漂移即红（Swift 测试里那句"与脚本一致"只是常量自比，锁不住）。
SW_DAEMON=$(grep -o 'installedDaemonBinary = "[^"]*"' "$ROOT/Sources/SMCCore/Config.swift" | cut -d'"' -f2)
SW_APP=$(grep -o 'installedAppBundle = "[^"]*"' "$ROOT/Sources/SMCCore/Config.swift" | cut -d'"' -f2)
if [[ -n "$SW_DAEMON" ]] && grep -qF -- "$SW_DAEMON" "$ROOT/scripts/install.sh" \
   && grep -qF -- "$SW_DAEMON" "$ROOT/scripts/upgrade.sh" \
   && grep -qF -- "$SW_DAEMON" "$ROOT/scripts/uninstall.sh"; then
    ok "daemon 落点常量与三个 root 脚本同源：${SW_DAEMON}"
else
    bad "daemon 落点常量（${SW_DAEMON:-读空}）与 install/upgrade/uninstall 字面量不一致"
fi
if [[ -n "$SW_APP" ]] && grep -qF -- "$SW_APP" "$ROOT/scripts/install.sh" \
   && grep -qF -- "$SW_APP" "$ROOT/scripts/upgrade.sh"; then
    ok "App 落点常量与安装/升级脚本同源：${SW_APP}"
else
    bad "App 落点常量（${SW_APP:-读空}）与 install/upgrade 字面量不一致"
fi

echo "== 发行脚本可执行位（R40 事故：变异工具自己剥掉了它）=="
# 本轮写在 /tmp 的 python 变异脚本用 shutil.copyfile 备份、shutil.move 还原——copyfile **不保留
# mode**，于是 install/uninstall/upgrade 三个脚本在提交里从 100755 静默掉到 100644。后果不在本地
# （本地还能 bash 起来），而在发行链：build.sh 用 cp 原样带进 zip、CI 从 git 记录复原 mode，
# 于是首装用户按 README 敲 `sudo ./install.sh` 直接 permission denied。全部测试当时照样绿。
SH_EXE_FAIL=""
for f in install uninstall upgrade build deploy test-root-scripts; do
    [[ -x "$ROOT/scripts/$f.sh" ]] || SH_EXE_FAIL="$SH_EXE_FAIL $f.sh(工作树)"
done
if [[ -z "$SH_EXE_FAIL" ]]; then
    ok "六个 shell 入口在工作树里都可执行（cp 进 zip 才带得走 mode）"
else
    bad "缺可执行位：$SH_EXE_FAIL"
fi
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    GITMODE_FAIL=""
    for f in install uninstall upgrade build deploy test-root-scripts; do
        m=$(git -C "$ROOT" ls-tree HEAD -- "scripts/$f.sh" | awk '{print $1}')
        # 查不到 = 还没入库（发行物里不会有它）；不是 100755 = CI checkout 出来不可执行
        [[ "$m" != "100755" ]] && GITMODE_FAIL="$GITMODE_FAIL $f.sh(${m:-未入库})"
    done
    if [[ -z "$GITMODE_FAIL" ]]; then
        ok "git 记录里这些脚本的 mode 均为 100755（CI checkout 复原的就是它）"
    else
        bad "git 记录的 mode 不对：$GITMODE_FAIL —— chmod 之后要 commit，否则 runner 上仍是 644"
    fi
else
    ok "非 git 环境（或无 HEAD），跳过 mode 入库检查"
fi

echo "== 装机/卸载落点的跟随面（R40，依据是实测不是文档）=="
# BSD 命令行工具对"路径本身是符号链接"的处理互不一致，而 root 装机/卸载正好全用它们。
# 这里把语义钉成回归断言：哪天 macOS 改了语义，这些门会红——那时该重估的是守卫本身，
# 而不是留着三道永远用不上的检查（R37 的 mtime 乌龙就是"没测就采信"的代价）。
S="$TMP/r40"; mkdir -p "$S/srcA" "$S/v1/inner" "$S/v2/inner" "$S/v4/inner"
printf 'A\n' > "$S/srcA/leaf"; : > "$S/v1/inner/keep"; : > "$S/v2/inner/keep"
: > "$S/v4/inner/keep"
ln -s "$S/v1" "$S/l1"; ln -s "$S/v2" "$S/l2"; ln -s "$S/v4" "$S/l4"
cp -R "$S/srcA" "$S/l1"
if [[ -e "$S/v1/srcA/leaf" ]]; then
    ok "实测：cp -R 跟随指向目录的符号链接落点 ⇒ root 会写进链接指向处（守卫动因）"
else
    bad "cp -R 语义与实测记录不符（不再跟随）——R40 守卫的前提要重估，别把门留着当装饰"
fi
printf 'B\n' > "$S/payload"
: > "$S/plain2"; ln -s "$S/plain2" "$S/l2b"
install -m 644 "$S/payload" "$S/l2b"
if [[ ! -L "$S/l2b" && "$(cat "$S/plain2")" == "B" ]]; then
    bad "install 跟随了符号链接（victim 被改写）——二进制落点必须补目录信任门"
elif [[ -L "$S/l2b" ]]; then
    bad "install 未替换符号链接（语义又变了）"
else
    ok "实测：install 不跟随，先 unlink 再新建 inode（故 /usr/local/bin 不构成 root 写入面）"
fi
# 观察量选择：把 victim 的组改成"我属于、但它现在不是"的那个组，跟随与否才可辨。
# 本机（主组 staff + 属于 admin）与 CI runner 同形；只有一个组的机器上退化成"只验链接本体"，
# 这里显式说明而不是悄悄放宽断言（R38 的 F9 教训：假绿比红更贵）。
PRIM=$(id -gn); GRP_ALT=""
for g in admin staff; do
    if id -nG | grep -qw "$g" && [[ "$g" != "$PRIM" ]]; then GRP_ALT="$g"; break; fi
done
mkdir -p "$S/v3a/inner" "$S/v3b/inner"; : > "$S/v3a/inner/keep"; : > "$S/v3b/inner/keep"
ln -s "$S/v3a" "$S/l3"; ln -s "$S/v3b" "$S/l3h"
if [[ -n "$GRP_ALT" ]]; then
    chown -R "$(id -un):$GRP_ALT" "$S/l3" 2>/dev/null || true
    LC_=$(stat -f "%Sg" "$S/l3"); VC=$(stat -f "%Sg" "$S/v3a/inner/keep")
    chown -R -H "$(id -un):$GRP_ALT" "$S/l3h" 2>/dev/null || true
    VL=$(stat -f "%Sg" "$S/v3b/inner/keep")
    if [[ "$LC_" == "$GRP_ALT" && "$VC" != "$GRP_ALT" && "$VL" == "$GRP_ALT" ]]; then
        ok "实测：chown -R 默认不跟随（链接本体被改、目标树未动；-H 对照组跟随生效）"
    else
        bad "chown 跟随语义与实测记录不符（链接=${LC_} 默认后目标=${VC} -H 后目标=${VL}，期望 ${GRP_ALT} 只出现在链接与 -H 之后）"
    fi
else
    chown -R "$(id -un):$PRIM" "$S/l3" 2>/dev/null || true
    ok "chown 跟随面降级验证：本机只有主组 ${PRIM}，无法构造可辨组，退化为「不报错」检查"
fi
xattr -w com.apple.quarantine "0081;0000;T;0" "$S/v4/inner/keep" 2>/dev/null || true
xattr -dr com.apple.quarantine "$S/l4" 2>/dev/null || true
if xattr -p com.apple.quarantine "$S/v4/inner/keep" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$S/v4" 2>/dev/null || true
    if ! xattr -p com.apple.quarantine "$S/v4/inner/keep" >/dev/null 2>&1; then
        ok "实测：xattr -dr 不跟随命令行符号链接（直路删除正对照生效）"
    else
        bad "xattr 两条路径都删不掉标记——测试夹具失效，别把它当语义结论"
    fi
else
    bad "xattr -dr 跟随了符号链接（root 可被诱导清掉他处 quarantine = Gatekeeper 绕过面）"
fi
rm -rf "$S/l1"
[[ -d "$S/v1" ]] && ok "实测：rm -rf 符号链接（无尾斜杠）只删链接，目标树完好" \
                 || bad "rm -rf 无尾斜杠竟跟着删了目标树"
mkdir -p "$S/v5/inner"; : > "$S/v5/inner/keep"; ln -s "$S/v5" "$S/l5"
rm -rf "$S/l5/"
if [[ ! -d "$S/v5" ]]; then
    ok "实测：rm -rf 链接**带尾斜杠**会跟随并毁掉目标树 ⇒ root 脚本禁止对用户可写路径加尾斜杠"
else
    bad "rm -rf 尾斜杠未跟随（语义已变）——下方那条反模式扫描门可以放宽，但要先确认"
fi

# --- 谓词行为（走脚本自己的测试钩子，不在此手抄一份判断）---
probe_app() {   # $1=脚本 $2=路径 ⇒ 0 放行 / 非 0 拒绝
    FANCTL_TEST_APP_TARGET=1 bash "$1" "$2" >/dev/null 2>&1
}
mkdir -p "$S/p/realdir"; ln -s "$S/p/realdir" "$S/p/linkdir"
ln -s "$S/p/nowhere" "$S/p/linkdangling"; : > "$S/p/plainfile"
for f in "$INSTALL" "$UPGRADE"; do
    # linkdir/ 与 linkdir// 是 R40 审查轮抓到的形状：`test -L path/` 会跟随，
    # 不剥尾斜杠就说"可用落点"——正是守卫要拦的那种
    if probe_app "$f" "$S/p/absent" && probe_app "$f" "$S/p/realdir" \
       && ! probe_app "$f" "$S/p/linkdir" && ! probe_app "$f" "$S/p/linkdir/" \
       && ! probe_app "$f" "$S/p/linkdir//" && ! probe_app "$f" "$S/p/linkdangling" \
       && ! probe_app "$f" "$S/p/plainfile" && ! probe_app "$f" "/"; then
        ok "$(basename "$f")：App 落点谓词七情形全对（放行 absent/真目录；拒 链接/链接带尾斜杠/双尾斜杠/断链/文件/根）"
    else
        bad "$(basename "$f")：App 落点谓词判错（见 fanctl_app_target_ok）"
    fi
done

# --- 卸载删除前缀：问不到家目录时绝不 rm -rf ---
# 守卫会 cd -P 归一化，所以期望值也按归一化后的真实路径比（/tmp → /private/tmp 这类）
REAL_HOME=$(cd "$S/p/realdir" && pwd -P)
UN_OK=$(FANCTL_TEST_CACHE_TARGET=1 bash "$ROOT/scripts/uninstall.sh" "$S/p/realdir" 2>/dev/null || true)
REJ=0
for bad_home in "" "/" "relative/path" "$S/p/notexist" "/." "//" "/Users"; do
    FANCTL_TEST_CACHE_TARGET=1 bash "$ROOT/scripts/uninstall.sh" "$bad_home" >/dev/null 2>&1 || REJ=$((REJ+1))
done
if [[ "$UN_OK" == "$REAL_HOME/Library/Caches/com.fanctl.app" && "$REJ" -eq 7 ]]; then
    ok "卸载删除前缀：真实家目录拼出归一化路径，7 种坏前缀（空/根/相对/不存在/. 写法/双斜杠/单层）一律拒绝"
else
    bad "卸载删除前缀失守（放行值=[$UN_OK] 期望 [$REAL_HOME/Library/Caches/com.fanctl.app]，拒绝数=$REJ/7）"
fi

# 卸载侧接线：谓词有牙 ≠ 调用点真的用它（钩子在调用点之前就 exit，只测谓词会留假绿）
UNSCR="$ROOT/scripts/uninstall.sh"
if grep -q 'rm -rf "\$CACHE_TARGET"' "$UNSCR" \
   && ! grep -qF 'rm -rf "$CONSOLE_HOME/Library' "$UNSCR"; then
    ok "uninstall.sh：缓存删除走守卫值，旧的「直接拼 \${CONSOLE_HOME}」形态已不存在"
else
    bad "uninstall.sh：缓存删除又回到未守卫的拼接（空前缀会让 root 在文件系统根下 rm -rf）"
fi

# --- 接线与顺序（谓词有牙 ≠ 装机路径真的用上它）---
for f in "$INSTALL" "$UPGRADE"; do
    def_line=$(grep -n '^fanctl_app_target_ok() {' "$f" | head -1 | cut -d: -f1 || true)
    pre_line=$(grep -nE '^[[:space:]]*if ! fanctl_app_target_ok "/Applications' "$f" | head -1 | cut -d: -f1 || true)
    boot_line=$(grep -n 'launchctl bootout' "$f" | head -1 | cut -d: -f1 || true)
    cp_line=$(grep -n '^cp -R .*"/Applications/清风.app"$' "$f" | head -1 | cut -d: -f1 || true)
    # ERE 里裸 [[ 会被当字符集起点，必须转义（不转义=永不匹配=这道门假红，比假绿好但仍是废门）
    guard_line=$(grep -nE '^[[:space:]]*if[[:space:]]+\[\[[[:space:]]+-L[[:space:]]+"/Applications/清风\.app"' "$f" | head -1 | cut -d: -f1 || true)
    post_line=$(grep -n '拷贝后 App 落点不对' "$f" | head -1 | cut -d: -f1 || true)
    if [[ -n "$def_line" && -n "$pre_line" && "$def_line" -lt "$pre_line" \
          && -n "$boot_line" && "$pre_line" -lt "$boot_line" \
          && -n "$cp_line" && -n "$post_line" && "$cp_line" -lt "$post_line" \
          && -n "$guard_line" && "$cp_line" -lt "$guard_line" && "$guard_line" -lt "$post_line" ]]; then
        ok "$(basename "$f")：预检在 bootout 之前、复验在 cp -R 之后（拒绝时不会把人留在半装状态）"
    else
        bad "$(basename "$f")：App 落点守卫接线错序/失效（定义:${def_line} 预检:${pre_line} bootout:${boot_line} cp:${cp_line} 复验判定:${guard_line} 复验文案:${post_line}）"
    fi
done
if grep -qE 'rm -rf "[^"]*/"' "$INSTALL" "$UPGRADE" "$ROOT/scripts/uninstall.sh"; then
    bad "root 脚本里出现「rm -rf 带尾斜杠」形态（会跟随符号链接并毁掉目标树）"
else
    ok "三个 root 脚本无「rm -rf 带尾斜杠」形态"
fi

# 用户可见提示不能写死仓库布局：Release zip 里脚本与 App 同级，指 "./scripts/install.sh"
# 等于给了一个不存在的命令（本轮实测发行包时撞见）
if grep -nE 'echo .*scripts/(install|uninstall|upgrade)\.sh' "$INSTALL" "$UPGRADE" "$ROOT/scripts/uninstall.sh" >"$TMP/layout_hints.txt" 2>/dev/null; then
    bad "提示里写死了仓库布局路径（zip 布局下不存在 scripts/）：$(head -1 "$TMP/layout_hints.txt" | cut -c1-120)"
else
    ok "用户可见提示一律按调用路径回显（两种布局都成立）"
fi

echo "== CI workflow 内联 shell 语法预检（R39 发版链自炸）=="
# v4.2.4 第一次 tag 触发就被自己新加的门炸红。真机现象：`command substitution: line 10:
# syntax error near unexpected token '|'`——**`bash -n` 对这段写法返回 0**（命令替换的内容
# 要到执行时才解析），只有 CI 的 `bash -e` 才把它变成退出码。所以两道门都要：
#   ① 静态禁"行首续行操作符"（`| && ||` 打头的一行）——本次事故的确切形状；
#   ② 抽出 run 块跑 bash -n——兜 if/fi 失衡这类块级错（它兜不住 ①，故 ① 不可省）。
WF="$ROOT/.github/workflows/ci.yml"
# R54（独立审查 P4）：断言数契约门槛有**两个源**——`fanctltests` 的 minAssertions 与 ci.yml 的
# `-lt N`。历史上每次都靠人记着同步，而漏改一个**不会让任何东西变红**（本地全绿、CI 拿旧下限，
# 门形同虚设）。所以把"两源同值"本身做成一条门。
MA=$(grep -oE '^let minAssertions = [0-9]+' "$ROOT/Sources/fanctltests/main.swift" | grep -oE '[0-9]+')
CF=$(grep -oE '"\$N" -lt [0-9]+' "$WF" | grep -oE '[0-9]+')
if [[ -n "$MA" && -n "$CF" && "$MA" == "$CF" ]]; then
    ok "断言数契约门槛双源同值：$MA = fanctltests = ci.yml"
else
    bad "断言数契约门槛双源不一致：fanctltests=[$MA] ci.yml=[$CF] —— 发版必须同值"
fi
BLOCKS="$TMP/ci-run-blocks.sh"
# 抽取器按"块内容 = run: 缩进 +2"切行；heredoc 会让这个约定失效，先钉住前提
if grep -qE '<<-?[[:space:]]*["(a-zA-Z]' "$WF"; then
    bad "ci.yml 出现 heredoc：run 块抽取器会截断，先改抽取器再放行"
else
    ok "ci.yml 无 heredoc：run 块抽取前提成立"
fi
awk '
    {
        if (inblk) {
            if ($0 ~ /^ *$/) { print ""; next }
            if (match($0, /[^ ]/) - 1 > ind) { print substr($0, ind + 3); next }
            inblk = 0
        }
        if ($0 ~ /^ *run: *\| *$/) { inblk = 1; ind = match($0, /[^ ]/) - 1 }
    }
' "$WF" > "$BLOCKS"
NBLK=$(grep -cE '^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$' "$WF" || true)
if [[ "$NBLK" -ge 3 ]] && grep -q 'set -o pipefail' "$BLOCKS" && grep -q 'gh release create' "$BLOCKS"; then
    ok "抽出 $NBLK 个 run 块（首块与发行块都在场，抽取器没掏空）"
else
    bad "run 块抽取异常：声明 $NBLK 个，抽取内容缺关键标记（抽取器失效 = 门会假绿）"
fi
# ① 行首续行操作符：$( ) 内换行 = 命令终止符，下一行以操作符开头即运行时语法错误
if grep -nE '^[[:space:]]*(\|\||\||&&)[[:space:]]' "$BLOCKS" >"$TMP/leadops.txt" 2>/dev/null; then
    bad "run 块里有行首续行操作符（bash -n 查不出，CI 上必炸）：$(tr '\n' ' ' < "$TMP/leadops.txt" | cut -c1-160)"
else
    ok "无行首续行操作符（管道续行一律写在行尾）"
fi
# ② 块级语法
if bash -n "$BLOCKS" 2>"$BLOCKS.err"; then
    ok "全部 run 块 bash -n 通过（块级语法）"
else
    bad "run 块语法错误：$(head -2 "$BLOCKS.err" | tr '\n' ' ')"
fi

echo "root 脚本门禁：$pass 通过 / $fail 失败"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
exit 0
