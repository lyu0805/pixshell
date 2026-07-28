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
  <!-- macOS 15+ 本地网络隐私：裸二进制连 192.168.x 会 errno 65 No route to host；
       .app + 这条 usage description 才会弹出「本地网络」授权，SSH/SFTP 才能通。 -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>PixShell 需要访问局域网以连接 SSH/SFTP 主机（例如 192.168.x.x）。</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_ssh._tcp</string>
    <string>_sftp-ssh._tcp</string>
  </array>
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
# Bundle.module works.
#
# Ad-hoc codesign（本地开发必须）：macOS 15+ 本地网络 TCC 按 code signature
# 身份记忆授权。完全 unsigned 的 .app 每次身份不稳，弹窗授权后仍可能失败。
# 正式分发再换 Developer ID + 公证；CI zip 可仍 unsigned。

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

# SwiftPM 资源包默认没有 Info.plist，codesign 会报「bundle format unrecognized /
# unsealed contents present in the bundle root」。给每个 .bundle 注入最小 BNDL plist，
# 身份才能稳定，macOS 15 本地网络 TCC 才记得住「允许」。
inject_bundle_plist() {
  local bundle="$1"
  local base id
  base="$(basename "$bundle" .bundle)"
  id="com.pixshell.res.${base//_/-}"
  # 扁平 bundle（无 Contents/）+ 根级 Info.plist，是 codesign 接受的 resource bundle 形态
  if [ ! -f "$bundle/Info.plist" ] && [ ! -f "$bundle/Contents/Info.plist" ]; then
    cat > "$bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${id}</string>
  <key>CFBundleName</key><string>${base}</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
PLIST
    echo "已注入 bundle Info.plist: $base"
  fi
}

shopt -s nullglob
for bundle in "$APP"/*.bundle; do
  inject_bundle_plist "$bundle"
done
shopt -u nullglob

# Ad-hoc 签名：稳定 TCC 身份（本地网络授权能记住）。
#
# SwiftPM Bundle.module 要求 *.bundle 在 .app 根（与 Contents 同级）。
# 这会让 codesign 报「unsealed contents present in the bundle root」，
# 无法对 .app 做完整 seal。对策：
#   1) 先在临时路径给 Mach-O 单独 ad-hoc 签，再放进 .app（避免从 bundle 内签被父级连坐）
#   2) 每个 *.bundle 单独签
#   3) .app 级签名允许失败；本地网络 TCC 主要跟主可执行文件身份走
if command -v codesign >/dev/null 2>&1; then
  echo "ad-hoc codesign（稳定本地网络 TCC 身份）…"
  sign_ok=1

  # 主可执行：拷到 /tmp 再签，再写回（绕过 .app 根 unsealed 连坐）
  tmp_bin="$(mktemp -t PixShell.XXXXXX)"
  cp "$APP/Contents/MacOS/PixShell" "$tmp_bin"
  chmod +x "$tmp_bin"
  if codesign --force --sign - --timestamp=none --identifier com.pixshell.mac "$tmp_bin" 2>/tmp/pixshell-codesign.err; then
    cp "$tmp_bin" "$APP/Contents/MacOS/PixShell"
    chmod +x "$APP/Contents/MacOS/PixShell"
    echo "主可执行 ad-hoc 签名 OK (id=com.pixshell.mac)"
  else
    echo "警告: 可执行文件签名失败" >&2
    cat /tmp/pixshell-codesign.err >&2 || true
    sign_ok=0
  fi
  rm -f "$tmp_bin"

  shopt -s nullglob
  for bundle in "$APP"/*.bundle; do
    [ -e "$bundle" ] || continue
    if ! codesign --force --sign - --timestamp=none "$bundle" 2>/tmp/pixshell-codesign.err; then
      echo "警告: bundle 签名失败: $bundle" >&2
      cat /tmp/pixshell-codesign.err >&2 || true
      sign_ok=0
    else
      echo "bundle 签名 OK: $(basename "$bundle")"
    fi
  done
  shopt -u nullglob

  # .app 级：根上有 SwiftPM bundle，完整 seal 通常会失败；试一下不阻断。
  if codesign --force --sign - --timestamp=none "$APP" 2>/tmp/pixshell-codesign.err; then
    echo ".app 级 ad-hoc 签名 OK"
  else
    echo "提示: .app 级签名跳过（根级 SwiftPM .bundle 导致 unsealed；主二进制已单独签）" >&2
    head -5 /tmp/pixshell-codesign.err >&2 || true
  fi

  echo "---- codesign -dv (main binary) ----"
  codesign -dv --verbose=2 "$APP/Contents/MacOS/PixShell" 2>&1 | head -20 || true
  echo "---- codesign -dv (.app, may be unsigned) ----"
  codesign -dv --verbose=2 "$APP" 2>&1 | head -10 || true
  if [ "$sign_ok" = 1 ]; then
    echo "ad-hoc codesign 完成（主二进制+资源 bundle；TCC 身份应可记住本地网络授权）"
  else
    echo "警告: 部分签名失败，本地网络仍可能 errno 65" >&2
  fi
else
  echo "警告: 无 codesign，跳过 ad-hoc 签名" >&2
fi

echo "完成: $APP (version ${VERSION})"
echo "资源 bundle 在 .app 根（SwiftPM Bundle.module）+ 已注入 Info.plist 可 ad-hoc 签。"
echo "本地网络：Info.plist usage + NWBrowser 弹窗 + 帮助「一键打开授权设置」。"
echo "双击运行，或: open \"$APP\""
