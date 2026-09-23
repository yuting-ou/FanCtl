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

echo "==> 运行回归测试（失败则中断构建；默认系统 SDK）..."
swift run -c release --disable-sandbox fanctltests

# 版本单一来源（4B）：根目录 VERSION 文件 = "主版本 build号"。
# App（Info.plist）与 daemon（fanctld -v）都从这里读，消除 README/脚本/二进制三处硬编码漂移。
# v3.6 修正顺序：必须先重生成 Version.generated.swift 再编译——原顺序（先编译后生成）
# 导致 daemon 二进制永远带着上一轮的版本号（fanctld -v 滞后一班）。
read -r APP_VERSION BUILD_NUMBER < "$ROOT/VERSION"
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

# 内嵌升级脚本正文（R23 P1 修复）：upgrade.sh base64 进 App 二进制——被授权执行的
# 内容与二进制同源同版，root 不再读用户可写的包内副本（篡改包内脚本=静默提权通道）。
# 提交的占位文件供裸 swift build 使用；打包构建时严格同步（与 4E 版本常量同一纪律）。
# R23 再审（P3-1）：base64 失败/空必须红——否则静默产生空常量，发行版要到用户点升级才炸。
_UPGRADE_B64="$(base64 -i "$ROOT/scripts/upgrade.sh" | tr -d '\n')"
if [ -z "$_UPGRADE_B64" ]; then
    echo "❌ upgrade.sh 内嵌失败（base64 为空——文件不可读？）" >&2
    exit 1
fi
cat > "$ROOT/Sources/FanCtlApp/UpgradeScript.generated.swift" <<EOF
// 由 scripts/build.sh 从 scripts/upgrade.sh 重新生成（勿手改）。
// 占位值供裸 \`swift build\` 使用；打包构建时与 upgrade.sh 严格同步（R23 P1 修复：
// 被授权执行的脚本正文内嵌进二进制，root 不再读用户可写的包内副本）。
let embeddedUpgradeScriptBase64 = "$_UPGRADE_B64"
EOF

echo "==> 编译 release（非 UI 目标：默认系统 SDK）..."
# 显式写 --scratch-path：构建与 artifact() 的查询必须是**同一组 flags**（v89 的教训），
# 不把默认落点交给环境或未来的 SwiftPM 默认值
swift build -c release --disable-sandbox --scratch-path "$ROOT/.build" --target fanctld
swift build -c release --disable-sandbox --scratch-path "$ROOT/.build" --target fanprobe

# ---------------------------------------------------------------------------
# 产物定位（R35 发版链，两次翻车后定的纪律）：必须与构建问**同一组 flags**。
# CI 实测：不带 --target 的 --show-bin-path 给 .build/<triple>/release，而 --target
# fanctld 的产物不在那里；本机反过来两条路都存在——硬编码目录或"半问"都会翻车。
# 三级策略：① 带 --target 问 show-bin-path；② 不中则在 scratch 里按 mtime 找同名
# 可执行件（刚编的一定最新）；③ 还不中 → 响亮失败。消息一律 ASCII：CI 上
# "$f（全角" 曾被 bash 吞进变量名报 unbound variable（见 EVOLUTION R35 发版链）。
# show-bin-path 的 stderr 收集处（诊断用）：走 TMPDIR，不用固定文件名——
# /tmp 里固定名会被他用户预置符号链接（R28 同族的面）
SBP_ERR=$(mktemp "${TMPDIR:-/tmp}/fanctl-sbp.XXXXXX")
# 同一 EXIT trap 里并列清理：bash 的 trap 是覆盖语义，另起一条会把第 21 行的
# _PROBE_DIR 回收顶掉（那样探测临时目录就会泄漏）
trap 'rm -rf "$_PROBE_DIR"; rm -f "$SBP_ERR"' EXIT

artifact() {  # $1=SwiftPM 目标名 $2=产物文件名 $3=scratch 目录 $4=SDKROOT（可空）
    local target="$1" name="$2" scratch="$3" sdk="$4" p found
    if [ -n "$sdk" ]; then
        p=$(SDKROOT="$sdk" swift build -c release --disable-sandbox --scratch-path "$scratch" \
            --target "$target" --show-bin-path 2>"$SBP_ERR" || true)
    else
        p=$(swift build -c release --disable-sandbox --scratch-path "$scratch" \
            --target "$target" --show-bin-path 2>"$SBP_ERR" || true)
    fi
    if [ -n "$p" ] && [ -f "$p/$name" ]; then printf '%s\n' "$p/$name"; return 0; fi
    # 回退搜索用 -L（跟随符号链接）：SwiftBuild 后端会把 .build 里的目录做成指向
    # scratch 外的链接，find 默认不跟随 → -type f 一个都不命中（CI 第四红的根因假设）。
    # 排除 dist：那里有上一轮的产物副本，宁缺不"静默拷陈旧件"（自证门也拦不住同号陈旧件）。
    found=$(find -L "$ROOT" -name "$name" -type f -perm +111 2>/dev/null \
        | grep -v -e "^$ROOT/Sources" -e "^$ROOT/dist" | xargs -0 ls -t 2>/dev/null | head -1 || true)
    if [ -n "$found" ] && [ -f "$found" ]; then printf '%s\n' "$found"; return 0; fi
    # 彻底找不到：把现场打全——这是发行链的"最后一次提问"，信息要给足
    echo "DIAG show-bin-path rc/stderr:" >&2
    sed -n '1,6p' "$SBP_ERR" >&2 || true
    echo "DIAG scratch=$scratch target=$target name=$name" >&2
    ls -l "$scratch" 2>&1 | head -20 >&2 || true
    find "$ROOT" -maxdepth 3 -name "$name*" 2>/dev/null | head -20 >&2 || true
    return 1
}

if [ -n "$APP_SDKROOT" ]; then
    # 钉住 SDK 的 App 构建走独立 scratch——避免与默认 SDK 构建互相失效缓存反复全量重编
    echo "==> 编译 release（App 目标：${APP_SDKROOT} ）..."
    APP_SCRATCH="$ROOT/.build-app-sdk"
    SDKROOT="$APP_SDKROOT" swift build -c release --disable-sandbox \
        --scratch-path "$APP_SCRATCH" --target FanCtlApp
else
    echo "==> 编译 release（App 目标：默认系统 SDK）..."
    APP_SCRATCH="$ROOT/.build"
    swift build -c release --disable-sandbox --scratch-path "$APP_SCRATCH" --target FanCtlApp
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
# 随包携带卸载脚本，App“关于”菜单可指引用户一键卸载
cp "$ROOT/scripts/uninstall.sh" "$APP/Contents/Resources/uninstall.sh"
chmod +x "$APP/Contents/Resources/uninstall.sh"
# v3.9 一键升级：特权安装过程内嵌进 App（root 执行的脚本必须与 App 同源发布，
# 绝不从网上下载脚本）；SelfUpgradeService 经 osascript 调它
cp "$ROOT/scripts/upgrade.sh" "$APP/Contents/Resources/upgrade.sh"
chmod +x "$APP/Contents/Resources/upgrade.sh"

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
# 发行链自证（R35）：组装完必须能回答"dist 里到底是不是本次代码"——
# 产物定位失败的最坏形态不是报错，而是静默拷进一个陈旧的中间件（同号不同码）。
# daemon 自己报的版本与 App 的 Info.plist 都对齐 VERSION 才算过。
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
