#!/bin/bash
# Package the SwiftPM PixShell executable into a double-clickable macOS .app.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-mac.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/dist/PixShell.app"
# Optional override for CFBundleShortVersionString (CI tag strip / local release).
VERSION="${VERSION:-0.1.1}"
VERSION="${VERSION#v}"

if [ "$CONFIG" = "release" ]; then
  BUILD_ARGS=(-c release)
elif [ "$CONFIG" = "debug" ]; then
  BUILD_ARGS=()
else
  echo "用法: bash scripts/package-mac.sh [debug|release]" >&2
  exit 2
fi

echo "定位 SwiftPM $CONFIG 输出目录 ..."
BIN_DIR="$(cd "$ROOT" && swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/PixShell"

if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件: $BIN" >&2
  echo "先构建: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build${BUILD_ARGS:+ -c $CONFIG}" >&2
  exit 1
fi

echo "打包 $CONFIG 二进制 → $APP"
python3 - "$APP" <<'PYRM'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
PYRM
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PixShell"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PixShell</string>
  <key>CFBundleIdentifier</key><string>com.pixshell.mac</string>
  <key>CFBundleName</key><string>PixShell</string>
  <key>CFBundleDisplayName</key><string>PixShell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# App icon for Dock / Finder / ⌘Tab (from v0.1.0 packaging assets).
ICON_SRC=""
for cand in \
  "$ROOT/Resources/AppIcon.icns" \
  "$ROOT/build/icon.icns" \
  "$ROOT/../build/icon.icns" \
  "$ROOT/../docs/assets/icon.png"
do
  if [ -f "$cand" ]; then
    ICON_SRC="$cand"
    break
  fi
done
if [ -n "$ICON_SRC" ]; then
  case "$ICON_SRC" in
    *.icns)
      cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
      ;;
    *)
      # Fallback: keep png name recognized only if no icns; prefer icns path above.
      cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
      if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
        echo "警告: 无法写入 AppIcon.icns（源: $ICON_SRC）" >&2
      fi
      ;;
  esac
  echo "已嵌入图标: $ICON_SRC"
else
  echo "警告: 未找到 AppIcon.icns / icon.icns，.app 将无自定义图标" >&2
fi

echo "二进制架构:"
file "$APP/Contents/MacOS/PixShell"

# SwiftPM executable resource accessors resolve bundles from Bundle.main.bundleURL,
# which is the .app root for this wrapper. Keep bundles at the .app root so
# Bundle.module works. This layout is intentionally unsigned for CI artifacts;
# full Developer ID signing/notarization needs a real app target or a resource
# loader/layout refactor. Do not run ad-hoc codesign here because it gives a
# misleading partial-sign result and can fail once root-level bundles exist.

# Copy SwiftPM resource bundles to the .app root to match
# DerivedSources/resource_bundle_accessor.swift.
required_bundles=(
  "PixShell_PixShell.bundle"
  "SwiftTerm_SwiftTerm.bundle"
  "swift-crypto_Crypto.bundle"
  "swift-nio_NIOPosix.bundle"
)
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  name="$(basename "$bundle")"
  echo "复制资源 bundle: $name"
  cp -R "$bundle" "$APP/$name"
done
shopt -u nullglob

for name in "${required_bundles[@]}"; do
  if [ ! -d "$APP/$name" ]; then
    echo "缺少资源 bundle: $APP/$name" >&2
    exit 1
  fi
done

echo "完成: $APP (version ${VERSION})"
echo "资源 bundle 位于 .app 根目录，用于匹配 SwiftPM Bundle.module 查找路径。"
echo "GitHub CI 产物为 unsigned zip；正式分发需独立 App target/资源加载布局后再 Developer ID 签名公证。"
echo "双击运行，或: open \"$APP\""
