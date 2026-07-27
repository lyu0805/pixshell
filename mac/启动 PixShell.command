#!/bin/bash
# PixShell mac one-click launch: build with full Xcode toolchain, then run the real SwiftPM output binary.
set -euo pipefail
cd "$(dirname "$0")" || exit 1
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
LOG_DIR="$HOME/Library/Application Support/PixShell/logs"
LOG="$LOG_DIR/build.log"
mkdir -p "$LOG_DIR"

echo "==> 构建 PixShell (mac) ..."
if ! swift build 2>&1 | tee "$LOG"; then
  echo "❌ 构建失败，完整日志: $LOG"
  read -n1 -r -p "按任意键退出..."
  exit 1
fi

BIN_DIR="$(swift build --show-bin-path)"
BIN="$BIN_DIR/PixShell"
if [ ! -x "$BIN" ]; then
  echo "❌ 找不到构建产物: $BIN"
  echo "完整日志: $LOG"
  read -n1 -r -p "按任意键退出..."
  exit 1
fi

echo "==> 构建日志: $LOG"
echo "==> 运行产物: $BIN"
echo "==> 运行日志: ~/Library/Application Support/PixShell/logs/pixshell-runtime.log"
echo "==> 启动 PixShell（关闭窗口即退出）"
exec "$BIN"
