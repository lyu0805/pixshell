import Foundation

/// 把 PixShell 暴露成 **MCP server**，让支持 MCP 的工具（Claude Code CLI / Claude Desktop / Cursor …）
/// 直接把这个 SSH 客户端当工具用：读终端画面、往终端敲字、执行命令、翻远端目录。
///
/// 为什么走 MCP：桌面 AI 应用和 CLI agent 的**共同**标准接口就是它。做一次注册，所有支持 MCP 的
/// 客户端通吃 —— 这才叫"无缝联动"，而不是每个工具单独适配一遍。
///
/// 实现取巧：MCP over stdio 本质就是**行分隔的 JSON-RPC**，不需要任何 SDK。
/// 这个 python 脚本只做协议壳子，真正干活转手给已经生成好的 `pixshell` 命令
/// （见 AgentCLI），所以两条路径共用同一套桥调用，行为不会漂。
enum AgentMCP {

    static var scriptPath: URL { AgentCLI.binDir.appendingPathComponent("pixshell-mcp") }

    static func install() {
        do {
            try FileManager.default.createDirectory(at: AgentCLI.binDir, withIntermediateDirectories: true)
            let body = script()
            let existing = try? String(contentsOf: scriptPath, encoding: .utf8)
            if existing != body { try body.write(to: scriptPath, atomically: true, encoding: .utf8) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
            Log.info("MCP server 就绪：\(scriptPath.path)", "bridge")
        } catch {
            Log.warn("写 MCP server 失败：\(error.localizedDescription)", "bridge")
        }
    }

    /// Claude Code CLI 的一行注册命令。
    static func claudeCodeCommand() -> String {
        "claude mcp add pixshell -- \(scriptPath.path)"
    }

    /// Claude Desktop 等「配置文件型」客户端的 JSON 片段。
    static func desktopConfigSnippet() -> String {
        """
        {
          "mcpServers": {
            "pixshell": {
              "command": "\(scriptPath.path)"
            }
          }
        }
        """
    }

    private static func script() -> String {
        let appPath = Bundle.main.bundlePath
        let lines: [String] = [
            "#!/usr/bin/env python3",
            "# PixShell MCP server —— 由 App 自动生成，勿手改（下次启动会被覆盖）。",
            "# stdio 上的行分隔 JSON-RPC；**直接 HTTP 调本地桥**（不经过 bash wrapper），",
            "# 每个工具调用 = 1 线程 + 1 HTTP 请求，无子进程，支持高并发。",
            "import json, os, subprocess, sys, time, socket, urllib.request",
            "os.umask(0o077)",
            "",
            "# 日志：MCP server 跑在客户端的子进程里，stderr 通常被吞掉 —— 不写文件就完全没法查。",
            "LOG = os.path.expanduser('~/Library/Application Support/PixShell/logs/agent-mcp.log')",
            "def log(msg):",
            "    try:",
            "        os.makedirs(os.path.dirname(LOG), exist_ok=True)",
            "        if os.path.exists(LOG) and os.path.getsize(LOG) > 2_000_000:",
            "            with open(LOG, 'rb') as f: f.seek(-1_000_000, 2); tail = f.read()",
            "            with open(LOG, 'wb') as f: f.write(tail)",
            "        with open(LOG, 'a', encoding='utf-8') as f:",
            "            f.write('%s [mcp] %s\\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), msg))",
            "        os.chmod(LOG, 0o600)",
            "    except Exception:",
            "        pass",
            "",
            "# 直连桥：端口（可被 PIXSHELL_BRIDGE_PORT 覆盖）+ token 文件 + App 路径（自动拉起用）。",
            "PORT = os.environ.get('PIXSHELL_BRIDGE_PORT', '8766')",
            "BASE = 'http://127.0.0.1:%s/v1/app' % PORT",
            "TOKEN_FILE = os.path.expanduser('~/Library/Application Support/PixShell/agent_token')",
            "APP_PATH = " + jsonQuoted(appPath),
            "",
            "# MCP 客户端对单条工具结果的大小很敏感：一次回几 MB 基本必炸（撑爆上下文/超帧长）。",
            "# 所以这里**统一在协议层截断**，并且明确告诉调用方截了多少、怎么拿更多 —— 绝不闷声截断。",
            "DEFAULT_MAX = 60000",
            "HARD_MAX = 200000",
            "",
            "def clamp(text, max_bytes=DEFAULT_MAX):",
            "    max_bytes = max(1000, min(int(max_bytes or DEFAULT_MAX), HARD_MAX))",
            "    b = text.encode('utf-8', 'replace')",
            "    if len(b) <= max_bytes:",
            "        return text",
            "    # 头尾都留：报错信息经常在末尾，只留头部会把关键行切没",
            "    head = b[: int(max_bytes * 0.6)].decode('utf-8', 'ignore')",
            "    tail = b[-int(max_bytes * 0.35):].decode('utf-8', 'ignore')",
            "    dropped = len(b) - len(head.encode()) - len(tail.encode())",
            "    return (head + '\\n\\n…… [PixShell 截断：略去约 %d 字节，共 %d 字节] ……\\n' % (dropped, len(b))",
            "            + '提示：用 grep/head/tail/sed -n 收窄，或调大 max_bytes（上限 %d）。\\n\\n' % HARD_MAX + tail)",
            "",
            "TOOLS = [",
            "    {\"name\": \"list_sessions\", \"description\": \"列出 PixShell 当前打开的 SSH 会话（拿 session 序号）\",",
            "     \"inputSchema\": {\"type\": \"object\", \"properties\": {}}},",
            "    {\"name\": \"read_screen\", \"description\": \"读终端当前画面。判断状态前先调它\",",
            "     \"inputSchema\": {\"type\": \"object\", \"properties\": {",
            "        \"lines\": {\"type\": \"integer\", \"description\": \"读多少行，默认 200\"},",
            "        \"session\": {\"type\": \"integer\", \"description\": \"会话序号，默认 0\"}}}},",
            "    {\"name\": \"exec_command\", \"description\": \"在已连接的会话上执行一条命令并返回 stdout（不会新建 SSH 连接）。\"",
            "        \"输出有大小上限，超了会被截断；要看大文件请自己在命令里收窄（grep/head/tail/wc），别整个 cat。\",",
            "     \"inputSchema\": {\"type\": \"object\", \"properties\": {",
            "        \"command\": {\"type\": \"string\"}, \"session\": {\"type\": \"integer\"},",
            "        \"max_bytes\": {\"type\": \"integer\", \"description\": \"返回上限字节，默认 60000，最大 200000\"}},",
            "        \"required\": [\"command\"]}},",
            "    {\"name\": \"type_text\", \"description\": \"往终端里敲字（自动回车），用于 vim/top 等交互场景；返回敲完后的画面\",",
            "     \"inputSchema\": {\"type\": \"object\", \"properties\": {",
            "        \"text\": {\"type\": \"string\"}, \"session\": {\"type\": \"integer\"}},",
            "        \"required\": [\"text\"]}},",
            "    {\"name\": \"list_hosts\", \"description\": \"列出 PixShell 里保存的主机\",",
            "     \"inputSchema\": {\"type\": \"object\", \"properties\": {}}},",
            "    {\"name\": \"sftp_list\", \"description\": \"列远端目录\",",
            "     \"inputSchema\": {\"type\": \"object\", \"properties\": {",
            "        \"path\": {\"type\": \"string\"}, \"session\": {\"type\": \"integer\"}}}},",
            "]",
            "",
            "# 桥操作：直接 urllib 调本地桥（无 bash wrapper 子进程）。",
            "# 桥未就绪时自动拉起 App（无头）并等就绪，然后重试一次。",
            "# 返回 (响应 dict, is_error)。",
            "def token():",
            "    try:",
            "        with open(TOKEN_FILE, 'r', encoding='utf-8') as f:",
            "            return f.read().strip()",
            "    except Exception:",
            "        return ''",
            "",
            "def bridge_alive():",
            "    try:",
            "        s = socket.create_connection(('127.0.0.1', int(PORT)), timeout=1); s.close(); return True",
            "    except Exception:",
            "        return False",
            "",
            "def _launch_app():",
            "    try:",
            "        subprocess.Popen(['open', APP_PATH, '--args', '--headless'],",
            "                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)",
            "    except Exception:",
            "        pass",
            "",
            "def _wait_bridge(sec):",
            "    for _ in range(sec * 2):",
            "        if bridge_alive(): return True",
            "        time.sleep(0.5)",
            "    return False",
            "",
            "def call(path, payload=None, query=''):",
            "    url = BASE + '/' + path + (query or '')",
            "    data = json.dumps(payload).encode() if payload is not None else None",
            "    def do():",
            "        req = urllib.request.Request(url, data=data, method='POST' if data else 'GET')",
            "        req.add_header('Authorization', 'Bearer ' + token())",
            "        if data: req.add_header('Content-Type', 'application/json')",
            "        with urllib.request.urlopen(req, timeout=120) as r:",
            "            return json.loads(r.read().decode('utf-8', 'replace'))",
            "    try:",
            "        return do(), False",
            "    except Exception as e:",
            "        if not bridge_alive():",
            "            _launch_app()",
            "            if _wait_bridge(20):",
            "                try:",
            "                    return do(), False",
            "                except Exception as e2:",
            "                    return {'error': '调用 PixShell 桥失败: %s' % e2}, True",
            "        return {'error': '调用 PixShell 桥失败: %s' % e}, True",
            "",
            "def pick(d, *keys):",
            "    if not isinstance(d, dict): return json.dumps(d, ensure_ascii=False)",
            "    if 'error' in d and len(d) == 1: return str(d['error'])",
            "    for k in keys:",
            "        if k in d:",
            "            v = d[k]",
            "            return v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)",
            "    return json.dumps(d, ensure_ascii=False)",
            "",
            "def call_tool(name, a):",
            "    log('tool %s keys=%s' % (name, ','.join(sorted(a.keys()))))",
            "    s = int(a.get('session') or 0)",
            "    if name == 'list_sessions':",
            "        d, e = call('sessions'); return (clamp(pick(d, 'sessions')), e)",
            "    if name == 'list_hosts':",
            "        d, e = call('hosts'); return (clamp(pick(d, 'hosts')), e)",
            "    if name == 'read_screen':",
            "        n = max(1, min(int(a.get('lines') or 200), 2000))   # 行数也钳住，别让 lines=999999 拖垮",
            "        d, e = call('screen', None, '?session=%d&lines=%d' % (s, n)); return (clamp(pick(d, 'text')), e)",
            "    if name == 'exec_command':",
            "        d, e = call('exec', {'session': s, 'cmd': a.get('command', '')}); return (clamp(pick(d, 'output', 'text', 'stdout'), a.get('max_bytes')), e)",
            "    if name == 'type_text':",
            "        d, e = call('shell', {'session': s, 'text': a.get('text', '') + '\\n'})",
            "        if e: return (clamp(pick(d, 'error')), True)",
            "        time.sleep(0.6)",
            "        d2, e2 = call('screen', None, '?session=%d&lines=40' % s); return (clamp(pick(d2, 'text')), e2)",
            "    if name == 'sftp_list':",
            "        d, e = call('sftp/list', {'session': s, 'path': a.get('path', '.')}); return (clamp(pick(d, 'entries')), e)",
            "    return ('未知工具: %s' % name, True)",
            "",
            "# 并发工具调用：MCP 客户端（Claude Code 等）并行发多个 tools/call 时，",
            "# 若主循环同步逐行处理，一个慢 exec 会阻塞后续所有调用（实测：8s exec 让",
            "# 后续快命令等 9s+，正是\"一个调用后另一个排队超时\"的根因）。",
            "# 解法：tools/call 丢进线程并发执行，主循环只读 stdin 分发，谁先完成谁回；",
            "# 响应按 id 关联（MCP 规范允许乱序），stdout 写用锁保护防交错。",
            "# 直连 HTTP 后每工具调用 = 1 线程 + 1 HTTP 请求（无子进程），线程轻量，",
            "# 并发只受桥 + 系统资源限制；信号量仅作极端资源护栏（远超实际需求）。",
            "import threading",
            "WRITE_LOCK = threading.Lock()",
            "# 高并发护栏：256 并发远超任何 MCP 客户端的并行工具调用数，防极端资源耗尽。",
            "MAX_CONCURRENT = 256",
            "CONCURRENT_SEM = threading.Semaphore(MAX_CONCURRENT)",
            "",
            "def reply(rid, result):",
            "    with WRITE_LOCK:",
            "        sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': rid, 'result': result}) + '\\n')",
            "        sys.stdout.flush()",
            "",
            "def reply_error(rid, msg):",
            "    with WRITE_LOCK:",
            "        sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': rid,",
            "            'error': {'code': -32601, 'message': msg}}) + '\\n')",
            "        sys.stdout.flush()",
            "",
            "def handle_tool_call(rid, name, args):",
            "    # 在线程里执行（慢 exec 不阻塞主循环）。信号量限并发上限，远超实际需求。",
            "    if not CONCURRENT_SEM.acquire(timeout=180):",
            "        reply_error(rid, '并发槽已占满（>%d 个工具并行），请稍后重试' % MAX_CONCURRENT)",
            "        return",
            "    try:",
            "        text, is_err = call_tool(name, args)",
            "        reply(rid, {'content': [{'type': 'text', 'text': text}], 'isError': is_err})",
            "    except Exception as e:",
            "        log('tools/call 异常: %s' % e)",
            "        reply(rid, {'content': [{'type': 'text', 'text': '工具调用异常: %s' % e}], 'isError': True})",
            "    finally:",
            "        CONCURRENT_SEM.release()",
            "",
            "def dispatch(msg):",
            "    method, rid = msg.get('method'), msg.get('id')",
            "    if method == 'initialize':",
            "        log('initialize 来自客户端')",
            "        reply(rid, {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}},",
            "                    'serverInfo': {'name': 'pixshell', 'version': '0.1.7'}})",
            "    elif method == 'tools/list':",
            "        reply(rid, {'tools': TOOLS})",
            "    elif method == 'tools/call':",
            "        p = msg.get('params') or {}",
            "        # 并发执行：独立线程跑工具，主循环立即继续读 stdin",
            "        threading.Thread(target=handle_tool_call,",
            "                         args=(rid, p.get('name', ''), p.get('arguments') or {}),",
            "                         daemon=True).start()",
            "    elif method == 'ping':",
            "        reply(rid, {})",
            "    elif rid is not None:",
            "        # 未实现的方法要回错误，不能装死 —— 否则客户端会一直等",
            "        reply_error(rid, 'method not found: %s' % method)",
            "",
            "for raw in sys.stdin:",
            "    raw = raw.strip()",
            "    if not raw:",
            "        continue",
            "    try:",
            "        msg = json.loads(raw)",
            "    except Exception:",
            "        continue",
            "    dispatch(msg)",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// 路径里可能有空格（Application Support），嵌进 python 前要加引号转义。
    /// **不要用 JSONSerialization**：它会把 `/` 转义成 `\/`，而 python 不认这个转义，
    /// 结果字符串里真的多出反斜杠，路径直接失效（实测踩过：No such file or directory '\/Users\/...'）。
    /// python 字符串只需要处理反斜杠和引号两样。
    private static func jsonQuoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
