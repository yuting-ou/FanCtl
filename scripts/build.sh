#!/bin/bash
# 构建 FanCtl：编译 release 二进制并组装 FanCtl.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"

echo "==> 运行回归测试（失败则中断构建）..."
swift run -c release --disable-sandbox fanctltests

echo "==> 编译 release 版本..."
swift build -c release --disable-sandbox

# 版本单一来源（4B）：根目录 VERSION 文件 = "主版本 build号"。
# App（Info.plist）与 daemon（fanctld -v）都从这里读，消除 README/脚本/二进制三处硬编码漂移。
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

BIN="$ROOT/.build/release"
rm -rf "$DIST"
mkdir -p "$DIST"

# 守护进程二进制
cp "$BIN/fanctld" "$DIST/fanctld"

# 组装菜单栏 App bundle
APP="$DIST/FanCtl.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FanCtlApp" "$APP/Contents/MacOS/FanCtl"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# 随包携带卸载脚本，App“关于”菜单可指引用户一键卸载
cp "$ROOT/scripts/uninstall.sh" "$APP/Contents/Resources/uninstall.sh"
chmod +x "$APP/Contents/Resources/uninstall.sh"

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
