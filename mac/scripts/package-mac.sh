#!/bin/bash
# 把已构建的 PixShell 可执行文件打包成可双击运行的 macOS .app（ad-hoc 签名）。
# 用法：DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-mac.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
BIN="$ROOT/.build/$CONFIG/PixShell"
APP="$ROOT/dist/PixShell.app"

if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件: $BIN"
  echo "先构建: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build ${CONFIG:+-c $CONFIG}"
  exit 1
fi

echo "打包 $CONFIG 二进制 → $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PixShell"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PixShell</string>
  <key>CFBundleIdentifier</key><string>com.pixshell.mac</string>
  <key>CFBundleName</key><string>PixShell</string>
  <key>CFBundleDisplayName</key><string>PixShell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# ad-hoc 签名（本地运行足够；正式分发需 Developer ID + 公证）
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "codesign 跳过（可右键打开运行）"

echo "完成: $APP"
echo "双击运行，或: open \"$APP\""
