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
    while IFS= read -r _d; do
        _real="$(cd "$_d" 2>/dev/null && pwd -P)" || continue
        [ "$_real" = "$_def" ] && continue
        if SDKROOT="$_real" swiftc -typecheck "$_PROBE" >/dev/null 2>&1; then
            APP_SDKROOT="$_real"
            break
        fi
    done < <(printf '%s\n' "$(dirname "$_def_sdk")"/MacOSX[0-9]*.[0-9]*.sdk 2>/dev/null | sort -Vr)
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

echo "==> 编译 release（非 UI 目标：默认系统 SDK）..."
swift build -c release --disable-sandbox --target fanctld
swift build -c release --disable-sandbox --target fanprobe

if [ -n "$APP_SDKROOT" ]; then
    # 钉住 SDK 的 App 构建走独立 scratch——避免与默认 SDK 构建互相失效缓存反复全量重编
    echo "==> 编译 release（App 目标：${APP_SDKROOT} ）..."
    APP_BIN="$ROOT/.build-app-sdk/release"
    SDKROOT="$APP_SDKROOT" swift build -c release --disable-sandbox \
        --scratch-path "$ROOT/.build-app-sdk" --target FanCtlApp
else
    echo "==> 编译 release（App 目标：默认系统 SDK）..."
    APP_BIN="$ROOT/.build/release"
    swift build -c release --disable-sandbox --target FanCtlApp
fi

BIN="$ROOT/.build/release"
rm -rf "$DIST"
mkdir -p "$DIST"

# 守护进程二进制
cp "$BIN/fanctld" "$DIST/fanctld"

# 组装菜单栏 App bundle
APP="$DIST/FanCtl.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_BIN/FanCtlApp" "$APP/Contents/MacOS/FanCtl"
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

# ad-hoc 签名（本机运行足够）
codesign --force --sign - "$APP" 2>/dev/null || true
codesign --force --sign - "$DIST/fanctld" 2>/dev/null || true

echo "==> 构建完成:"
echo "    $DIST/fanctld"
echo "    $APP"
echo ""
echo "下一步执行安装: sudo ./scripts/install.sh"
