#!/bin/bash
# Build a simple UDZO .dmg from dist/PixShell.app
# Usage:
#   bash scripts/make-dmg.sh [app-path] [output-dmg-path]
# Env:
#   VERSION   default 1.7.5 (or from Info.plist)
#   ARCH      arm64|x64|x86_64  (default: uname -m mapped)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/PixShell.app}"
VERSION="${VERSION:-}"
ARCH_IN="${ARCH:-}"

if [ ! -d "$APP" ]; then
  echo "找不到 .app: $APP" >&2
  echo "先运行: bash scripts/package-mac.sh release" >&2
  exit 1
fi

if [ -z "$VERSION" ]; then
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  fi
fi
VERSION="${VERSION:-1.7.5}"
VERSION="${VERSION#v}"

if [ -z "$ARCH_IN" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH_IN=arm64 ;;
    x86_64|amd64)  ARCH_IN=x64 ;;
    *)             ARCH_IN="$(uname -m)" ;;
  esac
fi
case "$ARCH_IN" in
  x86_64|amd64) ARCH_LABEL=x64 ;;
  arm64|aarch64) ARCH_LABEL=arm64 ;;
  x64) ARCH_LABEL=x64 ;;
  *) ARCH_LABEL="$ARCH_IN" ;;
esac

OUT_DIR="$ROOT/dist/artifacts"
mkdir -p "$OUT_DIR"

DEFAULT_DMG="$OUT_DIR/PixShell-${VERSION}-mac-${ARCH_LABEL}.dmg"
DMG="${2:-$DEFAULT_DMG}"
STAGE="$ROOT/dist/.dmg-stage-$$"
VOLNAME="PixShell ${VERSION}"

cleanup() {
  rm -rf "$STAGE" 2>/dev/null || true
  # detach any leftover mount of our volname (best-effort)
  true
}
trap cleanup EXIT

rm -rf "$STAGE"
mkdir -p "$STAGE"
# KeepParent layout: PixShell.app at volume root
ditto "$APP" "$STAGE/PixShell.app"

# Optional Applications shortcut for drag-install UX
ln -sf /Applications "$STAGE/Applications"

rm -f "$DMG"
# Create compressed read-only DMG
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG"

echo "完成 DMG: $DMG"
ls -lh "$DMG"
file "$DMG"
