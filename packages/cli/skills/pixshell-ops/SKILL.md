---
name: pixshell-ops
description: Drive PixShell desktop SSH sessions from Claude Code / Codex / OpenCode via pixshell-cli (hosts, connect, shell, exec, screen, sftp).
---

# PixShell 外部 CLI 运维

当用户要在 **已打开的 PixShell 桌面会话** 上查日志、跑命令、传文件时，用本技能，不要另起无状态的 `ssh`（除非用户明确要求直连）。

## 前置

1. 用户已启动 **PixShell** 桌面端。
2. 设置中已启用 **外部 CLI 集成**（默认开启会监听 `127.0.0.1:8766`）。
3. CLI：仓库内 `node packages/cli/pixshell-cli.js`，或已安装到 PATH 的 `pixshell-cli`。

```bash
# 探测
pixshell-cli health
# 或
node /path/to/pixshell/packages/cli/pixshell-cli.js health
```

环境变量（可选）：

- `PIXSHELL_CLI_PORT`（默认 8766）
- `PIXSHELL_AGENT_TOKEN`（默认读 `~/Library/Application Support/PixShell/agent_token`）

## 工作流

```bash
# 1) 列主机
pixshell-cli hosts --json

# 2) 列已连接会话（拿 session id）
pixshell-cli sessions --json

# 3a) 已有会话：只读执行（不污染终端画面）
pixshell-cli exec --session <id或唯一前缀> --cmd "uname -a && uptime"

# 3b) 需要用户在 GUI 终端里看见输入：
pixshell-cli shell --session <id> --cmd "systemctl status nginx --no-pager"

# 4) 读屏幕缓冲（看交互命令输出）
pixshell-cli screen --session <id> --lines 100

# 5) 若无会话：按 host_id 连接（桌面会开 tab；主机需已「记住密码」）
pixshell-cli connect --host-id <host_id> --json

# 6) SFTP
pixshell-cli sftp list --session <id> --path /var/log
pixshell-cli sftp download --session <id> --remote /var/log/syslog --local ./syslog
pixshell-cli sftp upload --session <id> --local ./fix.conf --remote /tmp/fix.conf
```

## 原则

- **先 `sessions` 确认目标**，再 `exec`/`shell`。破坏性命令先说明风险。
- 诊断优先 **`exec`（只读）**；配置变更若需用户可见再用 `shell`。
- 路由器 / Dropbear：避免并发狂轰；长输出命令加 `head`/`tail`。
- 写文件前备份：`cp f f.bak.$(date +%Y%m%d%H%M%S)`。
- 不要把 `agent_token` 写进仓库或聊天记录。

## 与常见运维 CLI 桥的对应

| 常见字段 | PixShell |
|-----------|----------|
| 本地 CLI 二进制 | `pixshell-cli` |
| 默认端口 8765 | 默认端口 **8766** |
| Token 文件 | Application Support/**PixShell**/agent_token |

命令子命令名保持一致：`hosts` / `connect` / `sessions` / `shell` / `send` / `exec` / `screen` / `sftp`。
