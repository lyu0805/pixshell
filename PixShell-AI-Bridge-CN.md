# PixShell MCP / CLI 使用说明（给 AI agent）

这份说明是 PixShell 本地 SSH/SFTP 桥的操作契约，面向 Claude Code、Codex、Cursor、OpenCode 以及其他能调用 MCP 或本地命令的 AI agent。不要凭经验猜 session、端口或工具语义；先按本文的启动顺序确认状态。

> 本文对应 macOS 版 PixShell 当前实现。App 启动后会自动生成 CLI 和 MCP server；生成文件会随 App 更新覆盖，不要直接编辑生成文件。

## 给 AI 的硬规则

1. **先确认会话，再执行命令。** MCP 先调用 `list_sessions`；CLI 先运行 `pixshell sessions`。不要默认假设 session 一定存在。只有确认目标主机和 `connected=true` 后，才使用返回的 session 编号。
2. **判断交互终端状态先读屏。** MCP 使用 `read_screen`，CLI 使用 `pixshell screen 40`。空画面不等于连接正常，也不等于命令失败。
3. **只读查询和一次性命令优先使用 exec。** MCP 使用 `exec_command`，CLI 使用 `pixshell exec`。它通过独立 exec channel 执行，不会把命令输入交互终端画面。
4. **需要 PTY 交互时才使用 type_text。** vim、top、交互式确认、需要观察提示符的操作使用 `type_text` 后紧接 `read_screen`；不要用 `type_text` 代替普通状态查询。
5. **断线恢复后必须重新确认位置。** 如果画面出现“SSH 交互连接曾中断”或“上下文全部丢失”等提示，断开后的第一次 `type_text` 可能只触发重连，不发送原始输入。此时先 `read_screen`，再用 `exec_command` 执行 `pwd && hostname && whoami`，确认新 shell 的位置和身份后，重新发送原输入。
6. **不要把 exec 和交互 shell 混为一谈。** `exec_command` 的工作目录、shell 状态和交互画面不是可靠的同一上下文；需要持续的交互状态就用 `type_text` + `read_screen`。
7. **大输出必须主动收窄。** 优先远端执行 `grep`、`head`、`tail`、`sed -n`、`wc`；不要直接 `cat` 大文件。需要完整结果时，使用 `write_artifact=true`，再用 `read_artifact` 分块读取。
8. **并发响应按 JSON-RPC id 配对。** 多个 MCP 调用可能并行执行，返回顺序不保证。不要把“先返回”当成“先发起”的结果。
9. **破坏性操作先询问用户。** `rm`、覆盖写文件、批量改权限、重启服务、修改防火墙/网络/系统配置、停止进程和重启主机等操作，执行前必须得到明确确认。
10. **不要索要或传播 token。** MCP token 由本机脚本从 `~/Library/Application Support/PixShell/agent_token` 读取；token 不需要出现在 prompt、命令参数、日志、回复或文档中。

## 快速开始

### 让 Claude Code 使用 MCP

App 启动后生成 MCP server。直接把下面命令注册到 Claude Code（路径中的空格必须保留）：

```bash
claude mcp add pixshell -- "$HOME/Library/Application Support/PixShell/bin/pixshell-mcp"
```

注册后，在新的 Claude Code 会话中按以下顺序操作：

```text
list_sessions
read_screen(session=<上一步确认的 session>, lines=40)
exec_command(session=<session>, command="pwd && hostname && whoami")
```

### 直接使用 CLI

优先使用软链接：

```bash
pixshell sessions
pixshell screen 40
pixshell exec "pwd && hostname && whoami"
```

如果 `pixshell` 不在 PATH，使用绝对路径：

```bash
"$HOME/Library/Application Support/PixShell/bin/pixshell" sessions
```

App 启动时会尝试生成并更新以下文件：

```text
~/Library/Application Support/PixShell/bin/pixshell
~/Library/Application Support/PixShell/bin/pixshell-mcp
~/.local/bin/pixshell                  # 若目标不存在或已是 PixShell 自己的软链接
~/.local/bin/pixshell-mcp               # 同上
```

不需要 sudo。若 `~/.local/bin/pixshell` 已经是用户自己的文件，PixShell 不会覆盖它。

## CLI 命令

CLI 默认操作 `PIXSHELL_SESSION=0`。有多个会话时，必须先 `pixshell sessions`，然后显式指定：

```bash
PIXSHELL_SESSION=2 pixshell screen 40
PIXSHELL_SESSION=2 pixshell exec "uname -a"
```

### 会话和主机

| 命令 | 用途 | 关键行为 |
| --- | --- | --- |
| `pixshell sessions` | 列出当前会话 | 返回 session 编号、主机、用户、连接状态；不含密码/私钥 |
| `pixshell hosts` | 列出已保存主机 | 只读；用于查找 `ssh` 的主机名、ID 或地址 |
| `pixshell ssh <主机名|ID> [命令]` | 连接已保存主机 | 无头建立/复用 SSH 会话；带命令时连接后执行该命令 |
| `pixshell connect <主机名|ID> [命令]` | `ssh` 的别名 | 语义相同 |

示例：

```bash
pixshell hosts
pixshell ssh staging
pixshell ssh host-id-123 "uname -a"
```

`ssh`/`connect` 使用 PixShell 已保存的凭据，不会把密码写入命令行。连接成功后以桥返回的 session 为准，不要假设一定是 0。

### 读取画面和执行命令

```bash
pixshell screen                 # 默认 200 行
pixshell screen 40              # 只看最近 40 行
pixshell exec "systemctl status nginx --no-pager"
pixshell type "vim /etc/hosts"  # 自动追加回车，返回约 40 行画面
```

- `exec` 适合 `pwd`、状态查询、日志过滤、编译、脚本等一次性命令。
- `type` 模拟向 PTY 手工输入，自动追加回车，并等待片刻后返回画面；它适合 vim/top/确认提示，不适合替代普通 `exec`。
- `type` 的输出只是随后读取到的画面，不是命令 stdout 的可靠边界；需要机器可解析结果时用 `exec`。

### 远端目录和 SFTP

CLI 的 `pwd/cd/ls` 是 CLI 自己维护的远端目录状态，基于 SFTP 列目录；它不等价于改变交互 shell 的当前目录。

```bash
pixshell pwd
pixshell cd /var/log
pixshell ls
pixshell ls sys
pixshell sftp-ls /var/log
pixshell sftp-upload ./local.txt /tmp/remote.txt
pixshell sftp-download /tmp/remote.txt ./downloaded.txt
```

| 命令 | 参数 | 说明 |
| --- | --- | --- |
| `sftp-ls [远端路径]` | 默认 `.` | 通过独立 SFTP 连接列目录 |
| `sftp-upload <本地路径> <远端路径>` | 两个路径必填 | 上传本地文件，返回远端路径 |
| `sftp-download <远端路径> [本地路径]` | 远端必填 | 下载到本地；本地路径省略时由桥生成临时目标 |
| `pwd` | 无 | 显示 CLI 记录的远端目录 |
| `cd <目录>` | 目录必填 | 先验证目录，再更新 CLI 记录 |
| `ls [前缀|路径]` | 可选 | 列目录或按前缀补全，目录名以 `/` 结尾 |

SFTP 是独立连接。SFTP 失败不代表交互 shell 一定失败，也不要把 SFTP 的目录状态当成交互 shell 的 `cwd`。

## MCP 工具

MCP 是 stdio 上的逐行 JSON-RPC。支持 `initialize`、`tools/list`、`tools/call`、`ping`。生成的 server 文件为：

```text
~/Library/Application Support/PixShell/bin/pixshell-mcp
```

调用工具时，除非特别说明，`session` 默认是 0；但可靠流程仍然是先 `list_sessions`，再使用真实返回的 session。

### `list_sessions`

列出当前会话。无参数。

```json
{"name":"list_sessions","arguments":{}}
```

返回包含 `session`、`title`、`host`、`username`、`connected`、`active` 等字段的列表。`active` 只在当前会话仍连接时为真。先调用它获取稳定的数组下标；不要自己递增或缓存跨 App 重启的 session 编号。

### `read_screen`

读取交互 PTY 最近画面，适合确认提示符、命令结果和重连提示。

参数：

| 参数 | 类型 | 默认/上限 |
| --- | --- | --- |
| `session` | integer | 默认 0；建议使用 `list_sessions` 返回值 |
| `lines` | integer | 默认 200；范围 1–2000 |

```json
{"name":"read_screen","arguments":{"session":0,"lines":40}}
```

返回文本画面。无效或已断开的普通 session 通常返回 404；若断线后有一次性上下文重置提示，合法的已断 session 仍可先读到该提示。

### `exec_command`

通过独立 exec channel 执行一次性命令并返回 stdout。它不会把命令输入交互画面，也不会为每条命令重新建立 SSH transport；桥会复用当前会话并在死会话时尝试自动重连。

参数：

| 参数 | 类型 | 默认/上限 |
| --- | --- | --- |
| `command` | string | 必填 |
| `session` | integer | 默认 0 |
| `timeout` | integer | 毫秒；不传约 30000；长任务可传如 300000 |
| `max_bytes` | integer | 默认返回上限 60000；最大 200000 |
| `write_artifact` | boolean | 默认 false；完整结果落本机 artifact |
| `artifact_name` | string | 可选；artifact 文件名 |

```json
{"name":"exec_command","arguments":{"session":0,"command":"grep -n 'error' /var/log/app.log | tail -50","timeout":60000,"max_bytes":20000}}
```

结果通常包含 `stdout`/`output` 和 `timedOut`。输出超过上限会保留头尾并明确提示截断。不要因为 stdout 为空就立即认定命令失败：先检查 `timedOut`、错误文本和 `read_screen`；需要完整结果时使用 artifact。

死 session 的 exec 会尝试原地重连，session 下标不变。若 session 编号越界，桥返回 410；重连仍失败时应重新 `list_sessions`、检查 bridge 状态并重试，不要盲目创建大量新会话。

### `read_artifact`

分块读取 `exec_command(write_artifact=true)` 产生的本地文件。

| 参数 | 类型 | 默认/上限 |
| --- | --- | --- |
| `name` | string | 必填；使用返回路径的 basename |
| `offset` | integer | 默认 0；按字节偏移，不得为负 |
| `max_bytes` | integer | 默认 60000；最大 1 MB |

```json
{"name":"read_artifact","arguments":{"name":"exec-abc123.out","offset":0,"max_bytes":60000}}
```

返回中会标记 artifact 路径、总大小、偏移和本次读取大小。按 offset 继续读取，直到覆盖所需范围。

### `type_text`

向交互 PTY 写入文本，自动追加一个换行，等待短暂时间后返回约 40 行画面。适合 vim、top、交互确认和需要保留 PTY 状态的操作。

```json
{"name":"type_text","arguments":{"session":0,"text":"echo READY"}}
```

`type_text` 不是 `exec_command` 的替代品。若 SSH 刚断线或被半死探针判定后重建，第一次调用可能只触发重连并返回上下文重置提示，本次文本不会发送；此时按硬规则先 `read_screen`，再 `exec_command("pwd && hostname && whoami")` 确认位置，最后重新发送。

### `list_hosts`

列出 PixShell 已保存主机。无参数；返回主机 ID、名称、地址、端口、用户和分组，不返回密码或私钥。

```json
{"name":"list_hosts","arguments":{}}
```

### `connect`

连接已保存的 SSH 主机并返回 session 编号，供 `exec_command`/`type_text`/`read_screen`/`sftp_*` 使用。`host` 可传 **主机ID、地址(IP/域名) 或 名称**，三者都接受；多个名称包含匹配时需用 list_hosts 查精确 ID。同一主机重复连接会复用现有会话并返回相同 session。

```json
{"name":"connect","arguments":{"host":"debian12"}}
```

当前没有任何会话时（`list_sessions` 返回空）必须先调用本工具建立会话，不要对 session 0 反复尝试。没有保存凭据的主机会返回明确错误（先在有头界面连接一次以保存密码/私钥）。

### `sftp_list`

通过独立 SFTP 连接列远端目录。

```json
{"name":"sftp_list","arguments":{"session":0,"path":"/var/log"}}
```

`path` 默认由客户端传入的当前路径或 `.` 处理。它只列目录，不改变交互 shell 的当前目录。

### `sftp_upload`

上传本地文件到远端。

```json
{"name":"sftp_upload","arguments":{"session":0,"local_path":"./build/app.tar.gz","remote_path":"/tmp/app.tar.gz"}}
```

`local_path` 是运行 AI/MCP 客户端这台机器上的路径，`remote_path` 是 SSH 主机上的路径。成功返回远端路径；失败返回明确错误。

### `sftp_download`

下载远端文件到本地。

```json
{"name":"sftp_download","arguments":{"session":0,"remote_path":"/var/log/app.log","local_path":"./app.log"}}
```

`remote_path` 是远端路径；`local_path` 可省略，省略时桥会选择临时路径并返回它。不要把两个路径写反。

### `bridge_status`

检查本地 PixShell 桥是否在线、实际端口和 artifact 目录。

```json
{"name":"bridge_status","arguments":{}}
```

桥只监听 `127.0.0.1`，请求使用本地 Bearer token。端口优先取 `PIXSHELL_BRIDGE_PORT`，其次取 `~/Library/Application Support/PixShell/agent_port`，最后回落到 47866。AI 不需要直接请求 HTTP，也不需要读取或打印 token；优先使用 MCP 工具或 `pixshell` CLI。

## Session 生命周期和恢复

### 正常流程

```text
list_sessions
  → 选择 connected=true 的 session
  → read_screen 确认画面
  → exec_command 执行只读/一次性命令
  → 若需要交互，type_text 后 read_screen
```

同一 session 会复用 SSH transport，不是每条命令重新登录。不同 session 可以并行；同一 session 的桥内部有并发保护，但 MCP 返回顺序仍不保证。

### 连接断开

- `exec_command` 会尝试对死 session 原地重连。
- 交互 PTY 断线后，第一次 `type_text` 可能只触发重连并抑制发送，避免把本应在旧嵌套 shell 执行的命令误发到新 shell。
- 看到重置提示后，必须重新确认 `pwd`、`hostname`、`whoami`；原先通过 `ssh` 进入的嵌套上下文、目录和临时 shell 状态都不能假设还在。
- 不要连续盲发多次 `type_text`，否则会把多条命令误排到新 shell。
- 普通 `screen` 在没有一次性提示时，死 session 可能返回 404；这表示需要恢复/重建会话，不是“远端命令没有输出”。

## 错误和排障

### 常见错误

| 现象 | 含义 | 正确处理 |
| --- | --- | --- |
| `当前没有已连接会话` | CLI 自动解析不到可用 session | 先 `pixshell sessions`，必要时 `pixshell ssh <主机>` |
| session 越界 / HTTP 410 | session 编号不存在 | 重新 `list_sessions`，不要猜编号 |
| screen HTTP 404 | session 不存在或已断且无提示 | 检查 `list_sessions`、`bridge_status`，重新连接 |
| shell HTTP 503 | 交互写入时重连失败 | 先读屏/检查桥，再稍后重试；不要假设文本已发送 |
| `timedOut=true` | 命令或建立 exec channel 超时 | 收窄命令、提高 timeout、检查网络；不要把空 stdout 当成功 |
| MCP 调用桥失败 | 本地桥未响应、token/端口不匹配或 App 正在启动 | 先 `bridge_status`；脚本会尝试拉起无头 App 并等待约 20 秒 |
| 输出被截断 | MCP 返回上限生效 | 远端用 grep/head/tail/sed 收窄，或 artifact 分块 |
| CLI 找不到命令 | `~/.local/bin` 不在 PATH 或脚本未生成 | 使用绝对路径，启动 App 后检查 `~/Library/Application Support/PixShell/bin` |

### 推荐排查顺序

```bash
pixshell sessions
pixshell screen 40
pixshell hosts
pixshell exec "pwd && hostname && whoami"
```

如果桥本身有问题，再检查：

```bash
pixshell-mcp  # 这是 stdio MCP server，不要直接当普通命令期待人类可读输出
ls -l "$HOME/Library/Application Support/PixShell/bin/"
ls -l "$HOME/Library/Application Support/PixShell/agent_port" "$HOME/Library/Application Support/PixShell/agent_token"
```

不要把 token 内容贴到聊天、日志或 issue。MCP server 的本地日志默认在：

```text
~/Library/Application Support/PixShell/logs/agent-mcp.log
```

CLI 日志默认在：

```text
~/Library/Application Support/PixShell/logs/agent-cli.log
```

## MCP 注册配置

### Claude Code

```bash
claude mcp add pixshell -- "$HOME/Library/Application Support/PixShell/bin/pixshell-mcp"
```

### 配置文件型 MCP 客户端

将以下对象合并到客户端的 MCP 配置中；不要把 token 写入配置：

```json
{
  "mcpServers": {
    "pixshell": {
      "command": "/Users/你的用户名/Library/Application Support/PixShell/bin/pixshell-mcp"
    }
  }
}
```

如果用户名或路径不同，使用 App 实际生成的 `AgentMCP` 路径。配置 `command` 指向 MCP server，而不是指向 Bash CLI；CLI 和 MCP 是两条不同入口。

## 最小正确示例

### MCP agent

```text
1. 调用 list_sessions。
2. 选择 connected=true 的 session，例如 0。
3. 调用 read_screen(session=0, lines=40)。
4. 调用 exec_command(session=0, command="pwd && hostname && whoami")。
5. 如果用户要求操作 vim 或交互确认，调用 type_text(session=0, text="...")，随后调用 read_screen(session=0, lines=40)。
6. 如果出现连接重置提示，先重复第 3、4 步确认新 shell，再重新发送第 5 步文本。
```

### CLI agent

```bash
pixshell sessions
PIXSHELL_SESSION=0 pixshell screen 40
PIXSHELL_SESSION=0 pixshell exec "pwd && hostname && whoami"
PIXSHELL_SESSION=0 pixshell type "echo READY"
```

以上示例只做状态确认和输出，不包含破坏性操作。任何修改远端状态的命令都必须按用户授权范围执行。
