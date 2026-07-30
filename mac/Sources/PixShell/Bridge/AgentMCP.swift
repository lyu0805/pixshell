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
        let cli = AgentCLI.scriptPath.path
        let lines: [String] = [
            "#!/usr/bin/env python3",
            "# PixShell MCP server —— 由 App 自动生成，勿手改（下次启动会被覆盖）。",
            "# stdio 上的行分隔 JSON-RPC；真正干活转给 pixshell 命令，两条路径共用同一套桥调用。",
            "import json, os, subprocess, sys, time",
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
            "    except Exception:",
            "        pass",
            "",
            "CLI = " + jsonQuoted(cli),
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
            "def run_cli(args, session=None, max_bytes=DEFAULT_MAX):",
            "    env = None",
            "    if session is not None:",
            "        import os",
            "        env = dict(os.environ); env['PIXSHELL_SESSION'] = str(session)",
            "    try:",
            "        p = subprocess.run([CLI] + args, capture_output=True, text=True, timeout=120, env=env)",
            "        out = p.stdout.strip() or p.stderr.strip()",
            "        if p.returncode != 0: log('pixshell 退出码 %d args=%s out=%s' % (p.returncode, args, out[:300]))",
            "        return clamp(out or '(无输出)', max_bytes)",
            "    except Exception as e:",
            "        log('调用 pixshell 异常: %s' % e)",
            "        return '调用 pixshell 失败: %s' % e",
            "",
            "def call_tool(name, a):",
            "    log('tool %s args=%s' % (name, json.dumps(a, ensure_ascii=False)[:300]))",
            "    s = a.get('session')",
            "    if name == 'list_sessions': return run_cli(['sessions'])",
            "    if name == 'list_hosts':    return run_cli(['hosts'])",
            "    if name == 'read_screen':",
            "        n = max(1, min(int(a.get('lines') or 200), 2000))   # 行数也钳住，别让 lines=999999 拖垮",
            "        return run_cli(['screen', str(n)], s)",
            "    if name == 'exec_command':  return run_cli(['exec', a.get('command', '')], s, a.get('max_bytes'))",
            "    if name == 'type_text':     return run_cli(['type', a.get('text', '')], s)",
            "    if name == 'sftp_list':     return run_cli(['sftp-ls', a.get('path', '.')], s)",
            "    return '未知工具: %s' % name",
            "",
            "def reply(rid, result):",
            "    sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': rid, 'result': result}) + '\\n')",
            "    sys.stdout.flush()",
            "",
            "for raw in sys.stdin:",
            "    raw = raw.strip()",
            "    if not raw:",
            "        continue",
            "    try:",
            "        msg = json.loads(raw)",
            "    except Exception:",
            "        continue",
            "    method, rid = msg.get('method'), msg.get('id')",
            "    if method == 'initialize':",
            "        log('initialize 来自客户端')",
            "        reply(rid, {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}},",
            "                    'serverInfo': {'name': 'pixshell', 'version': '0.1.3'}})",
            "    elif method == 'tools/list':",
            "        reply(rid, {'tools': TOOLS})",
            "    elif method == 'tools/call':",
            "        p = msg.get('params') or {}",
            "        text = call_tool(p.get('name', ''), p.get('arguments') or {})",
            "        reply(rid, {'content': [{'type': 'text', 'text': text}]})",
            "    elif method == 'ping':",
            "        reply(rid, {})",
            "    elif rid is not None:",
            "        # 未实现的方法要回错误，不能装死 —— 否则客户端会一直等",
            "        sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': rid,",
            "            'error': {'code': -32601, 'message': 'method not found: %s' % method}}) + '\\n')",
            "        sys.stdout.flush()",
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
