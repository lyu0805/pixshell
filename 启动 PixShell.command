#!/bin/bash
# 一键启动：源码可在 NTFS，运行在 APFS
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
echo "=========================================="
echo "  PIXSHELL"
echo "=========================================="
echo "目录: $ROOT"
echo ""

if ! command -v node >/dev/null 2>&1; then
  echo "[错误] 未找到 node"
  read -r -p "按回车退出..."
  exit 1
fi

exec node "$ROOT/start.js"
