#!/bin/bash
# 构建 FanCtl：编译 release 二进制并组装 FanCtl.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"

# ---------------------------------------------------------------------------
# macOS 27 工具链适配（2026-09-11 发现，2026-09-15 改造）
# 27.0 SDK 把 @State 改成了外部宏（#externalMacro(module: "SwiftUIMacros")），
# 而 CLT 6.4 未随包该宏插件（全盘实测无 libSwiftUIMacros.dylib）→ App 目标在
# 27 SDK 下无法编译；26.x SDK 里 @State 仍是普通 property wrapper，不受影响。
# 非 UI 目标（SMCCore/fanctld/fanprobe/fanctltests）不 import SwiftUI——实测在
# 27 SDK 下编译通过、4496 断言全绿，因此始终用真实系统 SDK 构建（适配主体）。
# 策略（自动探测，无需手删）：用 @State 小样例探默认 SDK；能过 → 不钉
# （CLT 修复或装了完整 Xcode 后自动回到全默认）；不能过 → 在更旧 SDK 里从新到旧
# 找第一个可编样例的，仅 App 目标钉它（≥ 部署目标 macOS 26）。
# ---------------------------------------------------------------------------
_PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$_PROBE_DIR"' EXIT   # R23：探测失败/中途退出也回收临时目录（原仅成功路径清理）
_PROBE="$_PROBE_DIR/swiftui-state-probe.swift"
cat > "$_PROBE" <<'SWIFT'
import SwiftUI
@available(macOS 26.0, *)
struct Probe: View {
    @State private var n = 0
    var body: some View { Text("\(n)") }
}
SWIFT
APP_SDKROOT=""
if ! env -u SDKROOT swiftc -typecheck "$_PROBE" >/dev/null 2>&1; then
    _def_sdk="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
    _def="$(cd "$_def_sdk" 2>/dev/null && pwd -P)"
    # glob 直接展开（引号前缀容忍空格路径），while-read 逐行防词分割；跳过默认 SDK 本体
    _sdklist="$(mktemp "${TMPDIR:-/tmp}/fanctl-sdklist.XXXXXX")" # R34: 临时文件替代 process substitution（/dev/fd 在受限环境打不开）
    printf '%s\n' "$(dirname "$_def_sdk")"/MacOSX[0-9]*.[0-9]*.sdk 2>/dev/null | sort -Vr > "$_sdklist"
    while IFS= read -r _d; do
        _real="$(cd "$_d" 2>/dev/null && pwd -P)" || continue
        [ "$_real" = "$_def" ] && continue
        if SDKROOT="$_real" swiftc -typecheck "$_PROBE" >/dev/null 2>&1; then
            APP_SDKROOT="$_real"
            break
        fi
    done < "$_sdklist"; rm -f "$_sdklist"
    [ -n "$APP_SDKROOT" ] || { echo "❌ 默认 SDK 与更旧 SDK 均无法编译 SwiftUI @State（SwiftUIMacros 插件缺失？），App 目标无法构建" >&2; exit 1; }
    echo "⚠️ 默认 SDK 缺 SwiftUIMacros 宏插件（CLT 打包缺陷），App 目标钉到 ${APP_SDKROOT} ；daemon/测试仍用默认 SDK"
fi
rm -rf "$_PROBE_DIR"

# 版本单一来源（4B）：根目录 VERSION 文件 = "主版本 build号"。
# App（Info.plist）与 daemon（fanctld -v）都从这里读，消除 README/脚本/二进制三处硬编码漂移。
# v3.6 修正顺序：必须先重生成 Version.generated.swift 再编译——原顺序（先编译后生成）
# 导致 daemon 二进制永远带着上一轮的版本号（fanctld -v 滞后一班）。
read -r APP_VERSION BUILD_NUMBER < "$ROOT/VERSION"
# 空值必须在**改写任何受版本管理文件之前**中止：重生成排在回归测试之前（R39），
# 若 VERSION 畸形（少字段/空行），先写坏 Version.generated.swift 再报错等于污染工作树；
# 而末尾的 dist 自证门用的是同一组变量，空对空照样"通过"，兜不住这一步。
if [[ -z "$APP_VERSION" || -z "$BUILD_NUMBER" ]]; then
    echo "ERROR: VERSION 文件畸形（期望 '主版本 build号' 两字段）: [$APP_VERSION] [$BUILD_NUMBER]" >&2
    exit 1
fi
export FANCTL_VERSION="$APP_VERSION"
export FANCTL_BUILD="$BUILD_NUMBER"

# daemon 版本常量（4E）：从 VERSION 重生成，与 App plist 同源。
# 提交的占位文件供裸 swift build/test 使用；打包构建时严格同步。
cat > "$ROOT/Sources/fanctld/Version.generated.swift" <<EOF
// 由 scripts/build.sh 从根目录 VERSION 重新生成（勿手改）。
// 占位值供裸 \`swift build\` / \`swift test\` 使用；打包构建时与 VERSION 严格同步（4B 单一来源）。
import Foundation

let fanctldVersion = "$APP_VERSION ($BUILD_NUMBER)"
EOF

# R39：重生成必须排在回归测试**之前**。fanctltests 里有一条"Version.generated.swift
# 必须等于 VERSION"的一致性断言（R38 审查轮加的），而"提了 VERSION、还没跑 build.sh"
# 恰好就是它要红的那个状态——放在测试之后就变成：改号 ⇒ 构建自锁死，永远走不到重生成那一步。
echo "==> 运行回归测试（失败则中断构建；默认系统 SDK）..."
swift run -c release --disable-sandbox fanctltests

# 批次 A（4.2.0）：不再把特权脚本 base64 内嵌进 App 二进制——二进制住在被
# chown 给登录用户的 bundle 里，"内嵌"只是把篡改面从包内文件挪到包本身。
# root 执行代码的规范落点改到 /usr/local/libexec/fanctl-{upgrade,uninstall}.sh
# （root:wheel 755，install.sh 首装、upgrade.sh 每次升级自我刷新）。

echo "==> 编译 release（非 UI 目标：默认系统 SDK）..."
# 两条纪律（v4.1.4 发版连红四次换来的）：
#   ① 按**产物**请求（--product），不按目标——runner 那版 SwiftPM 的 `--target` 只编译
#      不链接可执行件，产物目录存在但是空的，本地却会链接（于是本地一直绿）；
#   ② 构建与 artifact() 的查询用**完全同一组 flags**（含显式 --scratch-path），
#      不把默认落点交给环境或未来的 SwiftPM 默认值。
swift build -c release --disable-sandbox --scratch-path "$ROOT/.build" --product fanctld
swift build -c release --disable-sandbox --scratch-path "$ROOT/.build" --product fanprobe

# ---------------------------------------------------------------------------
# 产物定位（R35 发版链，两次翻车后定的纪律）：必须与构建问**同一组 flags**。
# CI 实测：不带 --target 的 --show-bin-path 给 .build/<triple>/release，而 --target
# fanctld 的产物不在那里；本机反过来两条路都存在——硬编码目录或"半问"都会翻车。
# 三级策略：① 带 --product 问 show-bin-path；② 不中则在工作树里按 mtime 找同名可执行件
# （刚编的一定最新，且排除 Sources/dist 以免选中源码或上一轮副本）；
# ③ 还不中 → 打全现场后失败。消息一律 ASCII：CI 上 "$f（全角" 曾被 bash 吞进变量名
# 报 unbound variable（见 EVOLUTION R35 发版链）。
# show-bin-path 的 stderr 收集处（诊断用）：走 TMPDIR，不用固定文件名——
# /tmp 里固定名会被他用户预置符号链接（R28 同族的面）
SBP_ERR=$(mktemp "${TMPDIR:-/tmp}/fanctl-sbp.XXXXXX")
# 同一 EXIT trap 里并列清理：bash 的 trap 是覆盖语义，另起一条会把第 21 行的
# _PROBE_DIR 回收顶掉（那样探测临时目录就会泄漏）
trap 'rm -rf "$_PROBE_DIR"; rm -f "$SBP_ERR"' EXIT

artifact() {  # $1=SwiftPM 产物名 $2=产物文件名 $3=scratch 目录 $4=SDKROOT（可空）
    local product="$1" name="$2" scratch="$3" sdk="$4" p found
    if [ -n "$sdk" ]; then
        p=$(SDKROOT="$sdk" swift build -c release --disable-sandbox --scratch-path "$scratch" \
            --product "$product" --show-bin-path 2>"$SBP_ERR" || true)
    else
        p=$(swift build -c release --disable-sandbox --scratch-path "$scratch" \
            --product "$product" --show-bin-path 2>"$SBP_ERR" || true)
    fi
    if [ -n "$p" ] && [ -f "$p/$name" ]; then printf '%s\n' "$p/$name"; return 0; fi
    # 回退搜索用 -L（跟随符号链接）：SwiftBuild 后端会把 .build 里的目录做成指向
    # scratch 外的链接，find 默认不跟随 → -type f 一个都不命中（CI 第四红的根因假设）。
    # 只在工作树的两个构建目录里找：整树搜会把 dist（上一轮产物副本）与源码树里的同名件
    # 一起选中——宁缺也不"静默拷陈旧件"（同号陈旧件版本自证门也拦不住，靠的是下面的 mtime）。
    # -n 判空后再喂 xargs：BSD xargs 对空输入仍会执行一次 `ls -t`，那是在列当前目录
    found=""
    hits=$(find -L "$ROOT/.build" "$ROOT/.build-app-sdk" -name "$name" -type f \
        -perm +111 2>/dev/null || true)
    if [ -n "$hits" ]; then
        found=$(printf '%s\n' "$hits" | xargs ls -t 2>/dev/null | head -1 || true)
    fi
    if [ -n "$found" ] && [ -f "$found" ]; then printf '%s\n' "$found"; return 0; fi
    # 彻底找不到：把现场打全——这是发行链的"最后一次提问"，信息要给足
    echo "DIAG show-bin-path rc/stderr:" >&2
    sed -n '1,6p' "$SBP_ERR" >&2 || true
    echo "DIAG scratch=$scratch product=$product name=$name" >&2
    ls -l "$scratch" 2>&1 | head -20 >&2 || true
    # 不设 maxdepth：v90 的诊断因深度太浅（产物在 4 层以下）等于什么都没报
    find "$ROOT" -name "$name" -type f 2>/dev/null | head -20 >&2 || true
    return 1
}

if [ -n "$APP_SDKROOT" ]; then
    # 钉住 SDK 的 App 构建走独立 scratch——避免与默认 SDK 构建互相失效缓存反复全量重编
    echo "==> 编译 release（App 目标：${APP_SDKROOT} ）..."
    APP_SCRATCH="$ROOT/.build-app-sdk"
    SDKROOT="$APP_SDKROOT" swift build -c release --disable-sandbox \
        --scratch-path "$APP_SCRATCH" --product FanCtlApp
else
    echo "==> 编译 release（App 目标：默认系统 SDK）..."
    APP_SCRATCH="$ROOT/.build"
    swift build -c release --disable-sandbox --scratch-path "$APP_SCRATCH" --product FanCtlApp
fi

rm -rf "$DIST"
mkdir -p "$DIST"

FANCTLD_BIN=$(artifact fanctld fanctld "$ROOT/.build" "") \
    || { echo "ERROR: cannot locate fanctld under $ROOT/.build" >&2; exit 1; }
FANPROBE_BIN=$(artifact fanprobe fanprobe "$ROOT/.build" "") \
    || { echo "ERROR: cannot locate fanprobe under $ROOT/.build" >&2; exit 1; }
APP_EXEC_BIN=$(artifact FanCtlApp FanCtlApp "$APP_SCRATCH" "$APP_SDKROOT") \
    || { echo "ERROR: cannot locate FanCtlApp under $APP_SCRATCH" >&2; exit 1; }
echo "==> 产物 $FANCTLD_BIN"
echo "==> 产物 $FANPROBE_BIN"
echo "==> 产物 $APP_EXEC_BIN"

cp "$FANCTLD_BIN" "$DIST/fanctld"
cp "$FANPROBE_BIN" "$DIST/fanprobe"

# 组装菜单栏 App bundle
APP="$DIST/FanCtl.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_EXEC_BIN" "$APP/Contents/MacOS/FanCtl"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# 批次 A：特权脚本随发行物根目录分发（与 install.sh 同级），由 install.sh 装进
# /usr/local/libexec、由 upgrade.sh 每次升级自我刷新；App bundle 内不再携带
# root 执行代码的副本（bundle 被 chown 给登录用户，放进包里=用户可写的特权代码）。
cp "$ROOT/scripts/upgrade.sh" "$DIST/upgrade.sh"
chmod +x "$DIST/upgrade.sh"
cp "$ROOT/scripts/uninstall.sh" "$DIST/uninstall.sh"
chmod +x "$DIST/uninstall.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>CFBundleExecutable</key>
    <string>FanCtl</string>
    <key>CFBundleIdentifier</key>
    <string>com.fanctl.app</string>
    <key>CFBundleName</key>
    <string>清风</string>
    <key>CFBundleDisplayName</key>
    <string>清风</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# 中文本地化：Finder/程序坞只认对应语言的 InfoPlist.strings，否则显示英文文件名
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
CFBundleDisplayName = "清风";
CFBundleName = "清风";
STRINGS
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
CFBundleDisplayName = "清风";
CFBundleName = "清风";
STRINGS

# ad-hoc 签名（本机运行足够）。R23（P3）：失败必须红——此前 `|| true` 把签名失败
# 静默吞掉，可能让未签名二进制混进 dist/ 发行资产，装机后才在 Gatekeeper/升级链炸。
# 发行链自证（R35/R36）。能回答的是"拷进 dist 的是不是本次构建刚产出的那一份"：
#   ① daemon 自己报的版本 == VERSION（二进制内常量，非恒真）——版本号是唯一
#      跨构建可靠的身份信号，因此每次改代码必须提 VERSION（同号不同码 = P1）；
#   ③ App 的 Info.plist 两字段 == VERSION（由本脚本写出，只防"生成/拷贝错位"，
#      单看它接近恒真——别把它当独立证据，见 EVOLUTION R36）。
# 产物定位失败的最坏形态不是报错，而是静默拷进一个陈旧的中间件（同号不同码）。
# daemon 自己报的版本与 App 的 Info.plist 都对齐 VERSION 才算过。
# （不设 mtime 门：实测 SwiftPM 以硬链接摆放产物，mtime 属于更早那次构建——
#   R36 加过这道、当场自己报红，故撤除。防陈旧件靠的是"只在 .build*/ 里找 + 版本自证"。）
DAEMON_V=$("$DIST/fanctld" -v 2>/dev/null || true)
if [ "$DAEMON_V" != "fanctld ${APP_VERSION} (${BUILD_NUMBER})" ]; then
    echo "ERROR: dist/fanctld version mismatch: got [$DAEMON_V] want [fanctld ${APP_VERSION} (${BUILD_NUMBER})]" >&2
    exit 1
fi
PLIST_V=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
PLIST_B=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
if [ "$PLIST_V" != "$APP_VERSION" ] || [ "$PLIST_B" != "$BUILD_NUMBER" ]; then
    echo "ERROR: Info.plist version mismatch: got [$PLIST_V / $PLIST_B] want [$APP_VERSION / $BUILD_NUMBER]" >&2
    exit 1
fi

codesign --force --sign - "$APP"
codesign --force --sign - "$DIST/fanctld"
codesign --force --sign - "$DIST/fanprobe"

echo "==> 构建完成:"
echo "    $DIST/fanctld"
echo "    $DIST/fanprobe"
echo "    $APP"
echo ""
echo "下一步执行安装: sudo ./scripts/install.sh"
