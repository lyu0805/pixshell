#!/bin/bash
# winx —— 给 Windows 下命令，**完全走 SMB 文件通道，不开 SSH**。
#
# 背景：那台机器的防火墙会在若干次连接后拦掉 SSH，表现为随机超时/空输出，
# 排查时分不清是命令失败还是连接被拦。C$ 已经挂在 /private/tmp/win146，
# 读写文件不经过 SSH，所以改成投递任务文件 + 等结果文件。
#
# 用法：winx.sh '<cmd 命令>'        例：winx.sh 'dotnet build C:\PixShell-win'
#      winx.sh --status            看 agent 活着没
set -uo pipefail

ROOT=/private/tmp/win146/_pixagent
IN="$ROOT/in"; OUT="$ROOT/out"

if [ "${1:-}" = "--status" ]; then
    if [ -f "$ROOT/ready.txt" ]; then
        echo "agent ready 文件存在；最近日志："
        tail -3 "$ROOT/agent.log" 2>/dev/null || echo "(无日志)"
    else
        echo "agent 未就绪（$ROOT/ready.txt 不存在）"
    fi
    exit 0
fi

CMD="${1:-}"
[ -n "$CMD" ] || { echo "用法: winx.sh '<命令>'" >&2; exit 2; }
TIMEOUT="${WINX_TIMEOUT:-300}"

mkdir -p "$IN" "$OUT" 2>/dev/null
ID="j$(date +%s)$RANDOM"

# 先写临时名再改名：避免 agent 读到只写了一半的任务文件
printf '%s' "$CMD" > "$IN/.$ID.tmp"
mv "$IN/.$ID.tmp" "$IN/$ID.job"

# 只等 .done（agent 保证 .out 写完才创建它）
waited=0
while [ ! -f "$OUT/$ID.done" ]; do
    sleep 0.3
    waited=$((waited + 1))
    if [ $((waited * 3 / 10)) -ge "$TIMEOUT" ]; then
        echo "[winx] 等待超时 ${TIMEOUT}s —— agent 可能没在跑，用 winx.sh --status 看看" >&2
        rm -f "$IN/$ID.job"
        exit 1
    fi
done

cat "$OUT/$ID.out" 2>/dev/null
rm -f "$OUT/$ID.out" "$OUT/$ID.done" 2>/dev/null
