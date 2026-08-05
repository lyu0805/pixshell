using System;
using System.Collections.Generic;
using System.IO;
using PixShell.Logging;

namespace PixShell.Bridge;

/// <summary>
/// 给本机 AI 工具用的两个入口（对齐 mac Bridge/AgentCLI.swift + Bridge/AgentMCP.swift）：
///
///  1. `pixshell.cmd` —— 命令行封装，终端里的 agent / 脚本 / 计划任务直接敲。
///  2. `pixshell-mcp.py` —— **MCP server**，Claude Desktop / Claude Code CLI / Cursor 等
///     支持 MCP 的客户端一次注册就能把这个 SSH 客户端当工具用。
///
/// 两者都打到本地桥（127.0.0.1，见 Bridge/AgentBridge.cs），而桥用的是**当前已经连上的那条
/// SSH 会话** —— 所以 agent 每发一条指令**不会**新建 SSH 连接。
///
/// **token 不进 prompt**：脚本自己去读 `agent_token` 文件。写进给模型的提示词里，
/// 它会被一并发到模型服务商那边，没必要冒这个险。
/// </summary>
public static class AgentCLI
{
    public static string BinDir => Path.Combine(HostStore.AppDir, "bin");
    public static string CmdPath => Path.Combine(BinDir, "pixshell.cmd");
    /// <summary>同一个脚本两用：带 <c>--mcp</c> 跑 MCP server，否则当命令行用。
    /// 少一个文件、少一层进程，两条路径共用同一份桥调用，行为不会漂。</summary>
    public static string PyPath => Path.Combine(BinDir, "pixshell.py");

    /// <summary>启动时写一次（内容变了才覆盖）。失败只记日志，不影响 App。</summary>
    public static void Install(int port)
    {
        try
        {
            Directory.CreateDirectory(BinDir);
            WriteIfChanged(CmdPath, CmdScript(port));
            WriteIfChanged(PyPath, PyScript(port));
            Log.Info($"agent CLI / MCP 就绪：{BinDir}", "bridge");
        }
        catch (Exception ex) { Log.Warn($"写 agent CLI/MCP 失败：{ex.Message}", "bridge"); }
    }

    private static void WriteIfChanged(string path, string body)
    {
        var old = File.Exists(path) ? File.ReadAllText(path) : null;
        if (old != body) File.WriteAllText(path, body);
    }

    /// <summary>拼给对话面板里 agent 的说明。只给命令和用法，**不给 token**
    /// （token 写进提示词会被一并发到模型服务商那边，没必要冒这个险）。</summary>
    public static string PromptPreamble() =>
        "你可以直接操作我正在用的 SSH 客户端 PixShell —— 用这个命令：\n\n" +
        "    \"" + CmdPath + "\" <子命令>\n\n" +
        "可用子命令：\n" +
        "  sessions              列出当前会话（拿 session 序号，通常是 0）\n" +
        "  screen [行数]          读终端当前画面（默认 200 行）——**先读它再判断**\n" +
        "  exec  <命令>           在当前会话上执行一条命令并拿到 stdout\n" +
        "  type  <文本>           往终端里\"敲字\"（会自动补回车，等同人手输入）\n" +
        "  hosts                 列出已保存的主机\n" +
        "  sftp-ls [远端路径]     列远端目录\n\n" +
        "要点：\n" +
        "- 这些都跑在**已经连着的那条 SSH 会话**上，不会为每条命令新建连接。\n" +
        "- 只读信息优先用 exec；需要交互（vim、要确认的提示、top）时用 type + screen 轮流看。\n" +
        "- 破坏性操作（rm、覆盖写、重启服务等）**先问我**，不要自己执行。";

    /// <summary>Claude Code CLI 的一行注册命令。</summary>
    public static string ClaudeCodeCommand() => $"claude mcp add pixshell -- python \"{PyPath}\" --mcp";

    /// <summary>Claude Desktop 等「配置文件型」客户端的 JSON 片段。</summary>
    public static string DesktopConfigSnippet() =>
        "{\n" +
        "  \"mcpServers\": {\n" +
        "    \"pixshell\": {\n" +
        "      \"command\": \"python\",\n" +
        $"      \"args\": [\"{PyPath.Replace("\\", "\\\\")}\", \"--mcp\"]\n" +
        "    }\n" +
        "  }\n" +
        "}";

    // =====================================================================
    // pixshell.cmd —— 批处理外壳，实际逻辑交给内嵌的 python（Windows 自带 curl，但拼 JSON 还是 python 省事）
    // =====================================================================
    private static string CmdScript(int port)
    {
        var lines = new List<string>
        {
            "@echo off",
            "REM PixShell agent CLI —— 由 App 自动生成，勿手改（下次启动会被覆盖）。",
            "REM 走本地桥操作**当前已连接**的 SSH 会话；token 从文件读，不出现在命令行/提示词里。",
            "setlocal",
            "REM Windows 控制台默认代码页会把中文输出成乱码；脚本本身是 UTF-8，这里把两头都对齐。",
            "chcp 65001 >nul 2>&1",
            "set PYTHONIOENCODING=utf-8",
            $"set PIXSHELL_PORT={port}",
            $"python \"%~dp0pixshell.py\" %*",
            "set \"PIXSHELL_EXIT=%ERRORLEVEL%\"",
            "endlocal & exit /b %PIXSHELL_EXIT%",
        };
        return string.Join("\r\n", lines) + "\r\n";
    }

    // =====================================================================
    // MCP server（stdio 上的行分隔 JSON-RPC，不需要任何 SDK）
    // 直接内含桥调用，不再多绕一层批处理 —— Windows 下少一层进程更稳。
    // =====================================================================
    private static string PyScript(int port)
    {
        // 桥不通时自动后台拉起 App：exe 路径在生成时注入（App 自己知道自己在哪）。
        var appExe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "PixShell.exe");
        var lines = new List<string>
        {
            "#!/usr/bin/env python3",
            "# PixShell MCP server —— 由 App 自动生成，勿手改（下次启动会被覆盖）。",
            "# stdio 行分隔 JSON-RPC；直接打本地桥，跑在**已连接**的 SSH 会话上，不会每条指令都重连。",
            "# 桥没在听时会自动后台拉起 App（无头调用不需要先手动打开软件）。",
            "import json, os, sys, time, urllib.request, subprocess",
            "",
            "# 日志：这个脚本跑在**独立进程**里（MCP 由客户端拉起，CLI 由终端拉起），",
            "# stderr 常被吞掉 —— 不写文件就等于没法查。踩过：ssh-keygen/.bat 出问题时无迹可寻。",
            "LOG = os.path.join(os.environ.get('APPDATA', ''), 'PixShell', 'logs', 'agent-cli.log')",
            "def log(msg):",
            "    try:",
            "        os.makedirs(os.path.dirname(LOG), exist_ok=True)",
            "        if os.path.exists(LOG) and os.path.getsize(LOG) > 2_000_000:",
            "            with open(LOG, 'rb') as f: f.seek(-1_000_000, 2); tail = f.read()",
            "            with open(LOG, 'wb') as f: f.write(tail)",
            "        with open(LOG, 'a', encoding='utf-8') as f:",
            "            f.write('%s [%s] %s\\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), 'mcp' if '--mcp' in sys.argv else 'cli', msg))",
            "    except Exception:",
            "        pass",
            "",
            $"PORT = os.environ.get('PIXSHELL_BRIDGE_PORT', os.environ.get('PIXSHELL_PORT', '{port}'))",
            "BASE = 'http://127.0.0.1:%s/v1/app' % PORT",
            "TOKEN_FILE = os.path.join(os.environ.get('APPDATA', ''), 'PixShell', 'agent_token')",
            "APP_EXE = " + System.Text.Json.JsonSerializer.Serialize(appExe),
            "",
            "# ---- 并发基础设施：线程局部错误状态 + 加锁写 stdout（MCP 多线程用） ----",
            "import threading",
            "_WRITE_LOCK = threading.Lock()",
            "_tl = threading.local()",
            "def _get_last_error():",
            "    return getattr(_tl, 'last_error', False)",
            "def reply(rid, result):",
            "    with _WRITE_LOCK:",
            "        sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': rid, 'result': result}) + '\\n')",
            "        sys.stdout.flush()",
            "",
            "# ---- 桥未就绪 → 自动后台拉起 App（无头调用无需先手动打开软件） ----",
            "def bridge_alive():",
            "    import socket",
            "    try:",
            "        s = socket.create_connection(('127.0.0.1', int(PORT)), timeout=1); s.close(); return True",
            "    except Exception:",
            "        return False",
            "",
            "def launch_app():",
            "    try:",
            "        DETACHED = getattr(subprocess, 'DETACHED_PROCESS', 0) | getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0)",
            "        # --headless：无头模式后台跑桥，不弹窗（无头调用不需要先手动打开软件）。",
            "        subprocess.Popen([APP_EXE, '--headless'], close_fds=True, creationflags=DETACHED)",
            "        return True",
            "    except Exception as e:",
            "        log('拉起 PixShell 失败: %s' % e)",
            "        return False",
            "",
            "def ensure_bridge(wait_sec=20):",
            "    if bridge_alive(): return True",
            "    log('桥未就绪，自动拉起 PixShell')",
            "    if not launch_app(): return False",
            "    end = time.time() + wait_sec",
            "    while time.time() < end:",
            "        if bridge_alive(): return True",
            "        time.sleep(0.5)",
            "    log('等待桥就绪超时')",
            "    return False",
            "",
            "# MCP 客户端对单条工具结果的大小很敏感：一次回几 MB 基本必炸（撑爆上下文/超帧长）。",
            "# 统一在协议层截断，并明确告诉调用方截了多少、怎么拿更多 —— 绝不闷声截断。",
            "DEFAULT_MAX = 60000",
            "HARD_MAX = 200000",
            "",
            "def clamp(text, max_bytes=None):",
            "    mb = max(1000, min(int(max_bytes or DEFAULT_MAX), HARD_MAX))",
            "    b = text.encode('utf-8', 'replace')",
            "    if len(b) <= mb:",
            "        return text",
            "    head = b[: int(mb * 0.6)].decode('utf-8', 'ignore')",
            "    tail = b[-int(mb * 0.35):].decode('utf-8', 'ignore')",
            "    dropped = len(b) - len(head.encode()) - len(tail.encode())",
            "    note = '\\n\\n…… [PixShell 截断：略去约 %d 字节，共 %d 字节] ……\\n' % (dropped, len(b))",
            "    note += '提示：用 grep/head/tail/findstr 收窄，或调大 max_bytes（上限 %d）。\\n\\n' % HARD_MAX",
            "    return head + note + tail",
            "",
            "def token():",
            "    try:",
            "        with open(TOKEN_FILE, 'r', encoding='utf-8') as f:",
            "            return f.read().strip()",
            "    except Exception:",
            "        return ''",
            "",
            "def call(path, payload=None, query=''):",
            "    url = BASE + '/' + path + query",
            "    data = json.dumps(payload).encode() if payload is not None else None",
            "    def set_err(v):",
            "        _tl.last_error = v",
            "    def do():",
            "        req = urllib.request.Request(url, data=data, method='POST' if data else 'GET')",
            "        req.add_header('Authorization', 'Bearer ' + token())",
            "        if data: req.add_header('Content-Type', 'application/json')",
            "        with urllib.request.urlopen(req, timeout=120) as r:",
            "            return json.loads(r.read().decode('utf-8', 'replace'))",
            "    try:",
            "        result = do(); set_err(False); return result",
            "    except urllib.error.HTTPError as e:",
            "        body = e.read().decode('utf-8', 'replace')[:300]",
            "        log('HTTP %s %s response_bytes=%d' % (e.code, path, len(body.encode('utf-8', 'replace'))))",
            "        set_err(True); return {'error': 'HTTP %s: %s' % (e.code, body)}",
            "    except Exception as e:",
            "        # 桥不通 → 自动后台拉起 App 并等桥就绪，然后重试一次",
            "        if ensure_bridge(20):",
            "            try: result = do(); set_err(False); return result",
            "            except urllib.error.HTTPError as e2:",
            "                b2 = e2.read().decode('utf-8', 'replace')[:300]",
            "                log('重试 HTTP %s %s response_bytes=%d' % (e2.code, path, len(b2.encode('utf-8', 'replace'))))",
            "                set_err(True); return {'error': 'HTTP %s: %s' % (e2.code, b2)}",
            "            except Exception as e2:",
            "                log('重试后仍失败 %s: %s' % (path, e2))",
            "                set_err(True); return {'error': '调用 PixShell 桥失败: %s（已自动拉起 App，仍失败）' % e2}",
            "        log('调用桥异常 %s: %s' % (path, e))",
            "        set_err(True); return {'error': '调用 PixShell 桥失败: %s（已尝试自动拉起 App）' % e}",
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
            "TOOLS = [",
            "    {'name': 'list_sessions', 'description': '列出 PixShell 当前打开的 SSH 会话（拿 session 序号）',",
            "     'inputSchema': {'type': 'object', 'properties': {}}},",
            "    {'name': 'read_screen', 'description': '读终端当前画面。判断状态前先调它',",
            "     'inputSchema': {'type': 'object', 'properties': {",
            "        'lines': {'type': 'integer', 'description': '读多少行，默认 200，上限 2000'},",
            "        'session': {'type': 'integer', 'description': '会话序号，默认 0'}}}},",
            "    {'name': 'exec_command', 'description': '在已连接的会话上执行命令并返回 stdout（不会新建 SSH 连接）。'",
            "        '输出有大小上限，超了会截断；看大文件请自己收窄（grep/head/tail），别整个 cat。',",
            "     'inputSchema': {'type': 'object', 'properties': {",
            "        'command': {'type': 'string'}, 'session': {'type': 'integer'},",
            "        'max_bytes': {'type': 'integer', 'description': '返回上限字节，默认 60000，最大 200000'}},",
            "        'required': ['command']}},",
            "    {'name': 'type_text', 'description': '往终端里敲字（自动回车），用于 vim/top 等交互场景；返回敲完后的画面',",
            "     'inputSchema': {'type': 'object', 'properties': {",
            "        'text': {'type': 'string'}, 'session': {'type': 'integer'}}, 'required': ['text']}},",
            "    {'name': 'list_hosts', 'description': '列出 PixShell 里保存的主机',",
            "     'inputSchema': {'type': 'object', 'properties': {}}},",
            "    {'name': 'sftp_list', 'description': '列远端目录',",
            "     'inputSchema': {'type': 'object', 'properties': {",
            "        'path': {'type': 'string'}, 'session': {'type': 'integer'}}}},",
            "]",
            "",
            "def call_tool(name, a):",
            "    log('tool %s keys=%s' % (name, ','.join(sorted(a.keys()))))",
            "    s = int(a.get('session') or 0)",
            "    if name == 'list_sessions': return clamp(pick(call('sessions'), 'sessions'))",
            "    if name == 'list_hosts':    return clamp(pick(call('hosts'), 'hosts'))",
            "    if name == 'read_screen':",
            "        n = max(1, min(int(a.get('lines') or 200), 2000))",
            "        return clamp(pick(call('screen', None, '?session=%d&lines=%d' % (s, n)), 'text'))",
            "    if name == 'exec_command':",
            "        r = call('exec', {'session': s, 'cmd': a.get('command', '')})",
            "        return clamp(pick(r, 'output', 'text', 'stdout'), a.get('max_bytes'))",
            "    if name == 'type_text':",
            "        first = call('shell', {'session': s, 'text': a.get('text', '') + '\\n'})",
            "        if _get_last_error(): return clamp(pick(first, 'error'))",
            "        import time; time.sleep(0.6)",
            "        return clamp(pick(call('screen', None, '?session=%d&lines=40' % s), 'text'))",
            "    if name == 'sftp_list':",
            "        return clamp(pick(call('sftp/list', {'session': s, 'path': a.get('path', '.')}), 'entries'))",
            "    _tl.last_error = True; return '未知工具: %s' % name",
            "",
            "def cli(argv):",
            "    log('调用 subcommand=%s argc=%d' % (argv[0] if argv else 'help', max(0, len(argv)-1)))",
            "    # token 缺失（App 从没跑过）→ 先拉起等 token 生成，再继续",
            "    if not token() and ensure_bridge(15) and not token():",
            "        print('找不到 token：%s（已尝试拉起 PixShell，仍未生成）' % TOKEN_FILE)",
            "        return 1",
            "    # 命令行模式：给终端里的 agent / 脚本 / 计划任务用",
            "    c = argv[0] if argv else 'help'",
            "    rest = argv[1:]",
            "    s = int(os.environ.get('PIXSHELL_SESSION', '0'))",
            "    if c == 'sessions': print(pick(call('sessions'), 'sessions'))",
            "    elif c == 'hosts': print(pick(call('hosts'), 'hosts'))",
            "    elif c == 'screen':",
            "        n = int(rest[0]) if rest else 200",
            "        print(pick(call('screen', None, '?session=%d&lines=%d' % (s, n)), 'text'))",
            "    elif c == 'exec':",
            "        print(pick(call('exec', {'session': s, 'cmd': ' '.join(rest)}), 'output', 'text', 'stdout'))",
            "    elif c == 'type':",
            "        first = call('shell', {'session': s, 'text': ' '.join(rest) + '\\n'})",
            "        if _get_last_error(): print(pick(first, 'error')); return 1",
            "        import time; time.sleep(0.6)",
            "        print(pick(call('screen', None, '?session=%d&lines=40' % s), 'text'))",
            "    elif c == 'sftp-ls':",
            "        print(pick(call('sftp/list', {'session': s, 'path': rest[0] if rest else '.'}), 'entries'))",
            "    else:",
            "        print('pixshell <子命令>')",
            "        print('  sessions          列出会话')",
            "        print('  screen [行数]      读终端画面（默认 200 行）')",
            "        print('  exec <命令>        在当前会话执行并拿 stdout')",
            "        print('  type <文本>        往终端敲字（自动回车），随后回显 40 行画面')",
            "        print('  hosts             列出已保存主机')",
            "        print('  sftp-ls [路径]     列远端目录')",
            "        print('环境变量 PIXSHELL_SESSION 可指定会话序号（默认 0）。')",
            "    return 1 if _get_last_error() else 0",
            "",
            "# MCP 模式：token 缺失（App 从没跑过）→ 先拉起等 token 生成",
            "if not token() and ensure_bridge(15) and not token():",
            "    log('找不到 token：%s（已尝试拉起 PixShell，仍未生成）' % TOKEN_FILE)",
            "",
            "if '--mcp' not in sys.argv[1:]:",
            "    raise SystemExit(cli(sys.argv[1:]))",
            "",
            "# 并发工具调用：主循环同步逐行处理时，一个慢 exec 阻塞后续所有调用（同 mac 修复）。",
            "# 解法：tools/call 丢线程并发执行，主循环只读 stdin 分发；错误状态用线程局部避免竞态；",
            "# stdout 写用锁保护防交错。响应按 id 关联，MCP 允许乱序。",
            "# 直连 HTTP（无 bash wrapper 子进程），每工具 = 1 线程 + 1 HTTP；信号量仅作资源护栏。",
            "MAX_CONCURRENT = 256",
            "_CONCURRENT_SEM = threading.Semaphore(MAX_CONCURRENT)",
            "def handle_tool_call(rid, name, args):",
            "    if not _CONCURRENT_SEM.acquire(timeout=180):",
            "        with _WRITE_LOCK:",
            "            sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32000, 'message': '并发槽已占满'}}) + '\\n')",
            "            sys.stdout.flush()",
            "        return",
            "    try:",
            "        text = call_tool(name, args)",
            "        reply(rid, {'content': [{'type': 'text', 'text': text}], 'isError': _get_last_error()})",
            "    except Exception as e:",
            "        log('tools/call 异常: %s' % e)",
            "        reply(rid, {'content': [{'type': 'text', 'text': '工具调用异常: %s' % e}], 'isError': True})",
            "    finally:",
            "        _CONCURRENT_SEM.release()",
            "",
            "for raw in sys.stdin:",
            "    raw = raw.strip()",
            "    if not raw: continue",
            "    try: msg = json.loads(raw)",
            "    except Exception: continue",
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
            "        with _WRITE_LOCK:",
            "            sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': rid,",
            "                'error': {'code': -32601, 'message': 'method not found: %s' % method}}) + '\\n')",
            "            sys.stdout.flush()",
            "",
        };
        return string.Join("\n", lines);
    }
}
