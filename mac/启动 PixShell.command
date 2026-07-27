#!/bin/bash
# PixShell mac 一键启动：用完整 Xcode 工具链构建并运行（CLT 的 SwiftPM 有缺陷）。
cd "$(dirname "$0")" || exit 1
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
echo "==> 构建 PixShell (mac) ..."
swift build 2>&1 | tail -6
if [ ! -x .build/debug/PixShell ]; then
  echo "❌ 构建失败"; read -n1 -r -p "按任意键退出..."; exit 1
fi
echo "==> 日志: ~/Library/Application Support/PixShell/logs/pixshell-runtime.log"
echo "==> 启动 PixShell（关闭窗口即退出）"
exec .build/debug/PixShell
