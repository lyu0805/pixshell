#!/bin/bash
# 修复并安装：永远装到 APFS 用户目录，避免 /Volumes/d (NTFS) 上 npm ENOENT
set -e
SOURCE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$HOME/Library/Application Support/PixShell/app"

echo "=========================================="
echo "  PIXSHELL — 安装依赖"
echo "=========================================="
echo "源码: $SOURCE"
echo "运行: $RUNTIME"
echo "Node: $(node -v 2>/dev/null || echo missing)"
echo ""

if ! command -v node >/dev/null 2>&1; then
  echo "[错误] 未找到 node"
  read -r -p "按回车退出..."
  exit 1
fi

mkdir -p "$RUNTIME"

echo "[1/3] 同步源码 → APFS 运行目录 ..."
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude node_modules \
    --exclude .npm-cache \
    --exclude .git \
    "$SOURCE/" "$RUNTIME/"
else
  rm -rf "$RUNTIME/packages" "$RUNTIME/package.json" 2>/dev/null || true
  cp -R "$SOURCE/package.json" "$RUNTIME/"
  cp -R "$SOURCE/start.js" "$RUNTIME/" 2>/dev/null || true
  cp -R "$SOURCE/packages" "$RUNTIME/"
  cp -R "$SOURCE/scripts" "$RUNTIME/" 2>/dev/null || true
  cp -R "$SOURCE/prototypes" "$RUNTIME/" 2>/dev/null || true
fi

cd "$RUNTIME"
mkdir -p .npm-cache
export npm_config_cache="$RUNTIME/.npm-cache"

echo "[2/3] npm install (cache=$npm_config_cache) ..."
npm install --cache "$npm_config_cache" --no-fund --no-audit

echo "[3/3] 写回启动指针 ..."
# pointer file on source volume for convenience
echo "$RUNTIME" > "$SOURCE/.runtime-path" 2>/dev/null || true

echo ""
echo "完成。"
echo "启动: node \"$SOURCE/start.js\""
echo "  或双击「启动 PixShell.command」"
echo "实际运行目录: $RUNTIME"
read -r -p "按回车关闭..."
