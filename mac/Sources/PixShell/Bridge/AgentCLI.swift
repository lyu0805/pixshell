import Foundation

/// 给本机 agent 用的 `pixshell` 命令行封装。
///
/// 目的：让 AI **像人一样直接操作这个软件** —— 读终端画面、往 shell 里敲字、跑命令、翻远端目录。
/// 底层就是已有的本地桥（127.0.0.1，token 鉴权，见 Bridge/AgentBridge.swift），
/// 而桥用的是**当前已经连上的那条 SSH 会话**，所以 agent 每发一条指令**不会**新建一次 SSH 连接
/// —— 这正是"无头调用、不用每条指令都重连"想要的效果。
///
/// **token 不进 prompt**：脚本自己去读 `agent_token` 文件。
/// 如果把 token 写进给 agent 的提示词里，它会被一起发到模型服务商那边去，没必要冒这个险。
enum AgentCLI {

    static var binDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PixShell/bin", isDirectory: true)
    }
    static var scriptPath: URL { binDir.appendingPathComponent("pixshell") }

    /// 启动时写一次（内容变了会覆盖）。失败只记日志，不影响 App。
    static func install(port: Int) {
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            let body = script(port: port)
            let existing = try? String(contentsOf: scriptPath, encoding: .utf8)
            if existing != body {
                try body.write(to: scriptPath, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
            Log.info("agent CLI 就绪：\(scriptPath.path)", "bridge")
            AgentMCP.install()     // 同时生成 MCP server（桌面 AI 应用/支持 MCP 的客户端走它）
            linkIntoPath()         // 软链到 ~/.local/bin，终端里直接 `pixshell` 就能用
        } catch {
            Log.warn("写 agent CLI 失败：\(error.localizedDescription)", "bridge")
        }
    }

    /// 软链到 `~/.local/bin`（用户自己的 bin，不需要 sudo，通常已在 PATH 里）。
    /// 这样任何终端里的 agent / 脚本 / 定时任务直接敲 `pixshell exec …` 就行，不用写长路径。
    /// 只在目标不存在、或已经是指向我们自己的旧软链时才写 —— 绝不覆盖用户自己放的同名文件。
    private static func linkIntoPath() {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for src in [scriptPath, AgentMCP.scriptPath] {
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: dst.path) {
                if existing == src.path { continue }          // 已经指向我们，不动
                try? fm.removeItem(at: dst)                    // 指向旧位置的我们自己的链，更新它
            } else if fm.fileExists(atPath: dst.path) {
                Log.warn("~/.local/bin/\(src.lastPathComponent) 已存在且不是我们的软链，跳过（不覆盖用户文件）", "bridge")
                continue
            }
            do { try fm.createSymbolicLink(at: dst, withDestinationURL: src) }
            catch { Log.warn("软链 \(dst.path) 失败：\(error.localizedDescription)", "bridge") }
        }
    }

    /// 拼给 agent 的说明。只给路径和用法，不给 token。
    static func promptPreamble() -> String {
        """
        你可以直接操作我正在用的 SSH 客户端 PixShell —— 用这个命令：

            \(scriptPath.path) <子命令>

        可用子命令：
          sessions              列出当前会话（拿 session 序号，通常是 0）
          screen [行数]          读终端当前画面（默认 200 行）——**先读它再判断**
          exec  <命令>           在当前会话上执行一条命令并拿到 stdout
          type  <文本>           往终端里"敲字"（会自动补回车，等同人手输入）
          hosts                 列出已保存的主机
          ssh <主机名|ID> [命令] 直连一台已保存主机（无头自动建会话），可带一条命令执行
          sftp-ls [远端路径]     列远端目录
          pwd / cd <目录> / ls [前缀]   远端路径 pwd/cd/ls（ls 支持前缀补全，目录尾带 /）

        要点：
        - 默认跑在 `ssh` 直连的会话上；不指定主机时用**已经连着的那条 SSH 会话**，不会为每条命令新建连接。
        - 只读信息优先用 `exec`；需要交互（比如 vim、要确认的提示、top）时用 `type` + `screen` 轮流看。
        - 破坏性操作（rm、覆盖写、重启服务等）**先问我**，不要自己执行。
        """
    }

    private static func script(port: Int) -> String {
        // 每行都保持同样缩进（Swift 多行字面量要求），python 助手一律写成单行，
        // 避免行首顶格导致 "insufficient indentation" 编译错。
        // 桥不通时自动拉起自己（App 路径在生成时注入，用户挪动 App 后下次启动会重写）。
        // 只有 bundle（.app）路径才有意义：debug 裸二进制注入的是目录，open 会失败，让它走名字兜底。
        let rawPath = Bundle.main.bundlePath.replacingOccurrences(of: "\\", with: "\\\\")
        let appPath = rawPath.hasSuffix(".app") ? rawPath : ""
        let lines = [
            "#!/bin/bash",
            "# PixShell agent CLI —— 由 App 自动生成，勿手改（下次启动会被覆盖）。",
            "# 走本地桥操作**当前已连接**的 SSH 会话；token 从文件读，不出现在命令行/提示词里。",
            "# 桥没在听时会自动后台拉起 App（无头模式，无头调用不需要先手动打开软件）。",
            "set -euo pipefail",
            "PORT=\"\(port)\"",
            "APP_PATH='\(appPath)'",
            "TOKEN_FILE=\"$HOME/Library/Application Support/PixShell/agent_token\"",
            "LOG=\"$HOME/Library/Application Support/PixShell/logs/agent-cli.log\"",
            "log() { printf '%s [cli] %s\\n' \"$(date '+%Y-%m-%dT%H:%M:%S')\" \"$*\" >>\"$LOG\" 2>/dev/null || true; }",
            "# 日志滚动：超过 2MB 就砍掉前一半，别让它无限长",
            "if [ -f \"$LOG\" ] && [ \"$(wc -c <\"$LOG\" 2>/dev/null || echo 0)\" -gt 2097152 ]; then tail -c 1048576 \"$LOG\" >\"$LOG.tmp\" && mv \"$LOG.tmp\" \"$LOG\"; fi",
            "# 拉起 App：**无头模式**（--headless）后台跑桥，不弹窗、无 Dock 图标。",
            "# 路径优先：bundle 路径（生成时注入）→ 按名字 → 常见安装位置，逐个试到 open 成功。",
            "launch_app() {",
            "  log \"桥未就绪，自动拉起 PixShell（无头）\"",
            "  if [ -n \"$APP_PATH\" ] && [ -d \"$APP_PATH\" ]; then open \"$APP_PATH\" --args --headless >/dev/null 2>&1 && return 0; fi",
            "  open -a PixShell --args --headless >/dev/null 2>&1 && return 0",
            "  for p in \"$HOME/Applications/PixShell.app\" /Applications/PixShell.app; do",
            "    [ -d \"$p\" ] && open \"$p\" --args --headless >/dev/null 2>&1 && return 0",
            "  done",
            "  return 1",
            "}",
            "# 等待桥就绪：/v1/health 有 HTTP 响应（哪怕是 401，因为没带 token）就算桥在听。",
            "# 参数：最大等待秒数。返回 0=就绪 1=超时。",
            "wait_bridge() {",
            "  local i sec=\"$1\"",
            "  for i in $(seq 1 $((sec * 2))); do",
            "    code=$(curl -s -o /dev/null -m 1 -w '%{http_code}' \"http://127.0.0.1:$PORT/v1/health\" 2>/dev/null || true)",
            "    [ \"$code\" != \"000\" ] && return 0",
            "    sleep 0.5",
            "  done",
            "  return 1",
            "}",
            "# token 缺失（App 从没跑过/被删过）→ 先拉起再等 token 生成",
            "if [ ! -r \"$TOKEN_FILE\" ]; then",
            "  launch_app; wait_bridge 15 || true",
            "  [ -r \"$TOKEN_FILE\" ] || { echo \"找不到 token：$TOKEN_FILE（已尝试拉起 PixShell，仍未生成）\" >&2; log \"找不到 token：$TOKEN_FILE\"; exit 1; }",
            "fi",
            "TOKEN=\"$(cat \"$TOKEN_FILE\")\"",
            "BASE=\"http://127.0.0.1:$PORT/v1/app\"",
            "# 桥探测：不通就拉起 App 并最多等 20 秒，再不行才报错",
            "code=$(curl -s -o /dev/null -m 1 -w '%{http_code}' \"http://127.0.0.1:$PORT/v1/health\" 2>/dev/null || true)",
            "if [ \"$code\" = \"000\" ]; then launch_app; wait_bridge 20 || { echo \"PixShell 桥未就绪（已自动拉起，等待超时）\" >&2; log \"等待桥就绪超时\"; exit 1; }; fi",
            "SESSION=\"${PIXSHELL_SESSION:-0}\"",
            "post() { r=$(curl -sS -m 60 -w '\\n%{http_code}' -X POST -H \"Authorization: Bearer $TOKEN\" -H 'Content-Type: application/json' -d \"$2\" \"$BASE/$1\"); c=${r##*$'\\n'}; b=${r%$'\\n'*}; [ \"$c\" = 200 ] || log \"POST $1 HTTP=$c body=${b:0:200}\"; printf '%s' \"$b\"; }",
            "get() { r=$(curl -sS -m 60 -w '\\n%{http_code}' -H \"Authorization: Bearer $TOKEN\" \"$BASE/$1\"); c=${r##*$'\\n'}; b=${r%$'\\n'*}; [ \"$c\" = 200 ] || log \"GET $1 HTTP=$c body=${b:0:200}\"; printf '%s' \"$b\"; }",
            "# 从返回 JSON 里挑第一个存在的字段打印；挑不到就原样打印整个 JSON",
            "field() { python3 -c 'import json,sys; d=json.load(sys.stdin); ks=[k for k in sys.argv[1:] if isinstance(d,dict) and k in d]; v=d[ks[0]] if ks else d; print(v if isinstance(v,str) else json.dumps(v,ensure_ascii=False))' \"$@\"; }",
            "mkjson() { python3 -c 'import json,sys; print(json.dumps({\"session\":int(sys.argv[1]),sys.argv[2]:sys.argv[3]}))' \"$@\"; }",
            "# 会话级远端当前目录状态（pwd/cd/ls 补全）。每会话独立；文件不存在时默认 /。",
            "PWD_FILE=\"$HOME/Library/Application Support/PixShell/pwd.$SESSION\"",
            "cwd_cur() { [ -r \"$PWD_FILE\" ] && cat \"$PWD_FILE\" || echo /; }",
            "cwd_set() { printf '%s' \"$1\" >\"$PWD_FILE\" 2>/dev/null || true; }",
            "# 列目录/补全候选。参数可为完整路径或前缀；空=当前目录。输出每行一个：目录尾加 / 。",
            "sf_ls() {",
            "  local p=\"${1:-}\"",
            "  local cur=\"\" pre=\"\"",
            "  case \"$p\" in",
            "    '') cur=\"$(cwd_cur)\"; pre=\"\" ;;",
            "    *'/') cur=\"$p\"; pre=\"\" ;;",
            "    /*) cur=\"${p%/*}\"; pre=\"${p##*/}\"; [ -n \"$cur\" ] || cur=/ ;;",
            "    *) cur=\"$(cwd_cur)\"; pre=\"$p\" ;;",
            "  esac",
            "  case \"$cur\" in /*) ;; *) cur=\"$(cwd_cur)/$cur\" ;; esac",
            "  cur=$(python3 -c 'import os,sys;print(os.path.normpath(sys.argv[1]))' \"$cur\" 2>/dev/null || echo \"$cur\")",
            "  post sftp/list \"$(mkjson \"$SESSION\" path \"$cur\")\" | python3 -c \"",
            "import json,sys",
            "d=json.load(sys.stdin)",
            "pre=sys.argv[1] if len(sys.argv)>1 else ''",
            "for e in d.get('entries',[]) or []:",
            "  n=e.get('name','')",
            "  if pre and not n.startswith(pre): continue",
            "  print(n+'/' if e.get('isDir') else n)",
            "\" \"$pre\"",
            "}",
            "# 执行远程命令。exec 是 bash 内建（exec 命令会替换 shell 进程），不能直接用，包一层。",
            "do_exec() { post exec \"$(mkjson \"$SESSION\" cmd \"$*\")\" | field output text stdout; }",
            "# 按名称或 ID 挑主机。hosts 返回 {ok,hosts:[...]}。匹配不到就报错退出。",
            "hostid() {",
            "  python3 - \"$1\" <<'PY'",
            "import json,urllib.request,sys,os",
            "tok=open(os.path.expanduser('~/Library/Application Support/PixShell/agent_token')).read().strip()",
            "req=urllib.request.Request('http://127.0.0.1:8766/v1/app/hosts',headers={'Authorization':'Bearer '+tok})",
            "d=json.load(urllib.request.urlopen(req,timeout=10))['hosts']",
            "q=sys.argv[1].lower()",
            "hit=[h for h in d if q in (h.get('id') or '').lower() or q in (h.get('name') or '').lower() or q in (h.get('host') or '').lower()]",
            "print(hit[0]['id'] if hit else '')",
            "PY",
            "}",
            "cmd=\"${1:-help}\"; shift || true",
            "log \"调用 cmd=$cmd session=$SESSION args=$*\"",
            "case \"$cmd\" in",
            "  sessions) get sessions ;;",
            "  hosts) get hosts ;;",
            "  screen) get \"screen?session=$SESSION&lines=${1:-200}\" | field text ;;",
            "  exec)",
            "    [ $# -ge 1 ] || { echo '用法: pixshell exec <命令>' >&2; exit 2; }",
            "    do_exec \"$*\" ;;",
            "  type)",
            "    [ $# -ge 1 ] || { echo '用法: pixshell type <文本>' >&2; exit 2; }",
            "    post shell \"$(mkjson \"$SESSION\" text \"$*\")\" >/dev/null; sleep 0.6",
            "    get \"screen?session=$SESSION&lines=40\" | field text ;;",
            "  sftp-ls) post sftp/list \"$(mkjson \"$SESSION\" path \"${1:-.}\")\" | field entries ;;",
            "  pwd) echo \"$(cwd_cur)\" ;;",
            "  cd)",
            "    [ $# -ge 1 ] || { echo '用法: pixshell cd <目录>' >&2; exit 2; }",
            "    tarpath=\"$1\"; case \"$tarpath\" in /*) ;; *) tarpath=\"$(cwd_cur)/$tarpath\" ;; esac",
            "    target=$(python3 -c 'import os,sys;print(os.path.normpath(sys.argv[1]))' \"$tarpath\" 2>/dev/null || echo \"$tarpath\")",
            "    R=$(post sftp/list \"$(mkjson \"$SESSION\" path \"$target\")\")",
            "    if echo \"$R\" | grep -q '\"ok\":true'; then cwd_set \"$target\"; echo \"$target\"; else echo \"目录无效：$(echo \"$R\" | field error)\" >&2; fi ;;",
            "  ls) sf_ls \"${1:-}\" ;;",
            "  ssh|connect)",
            "    [ $# -ge 1 ] || { echo '用法: pixshell ssh <主机名|ID> [命令]' >&2; exit 2; }",
            "    HID=$(hostid \"$1\"); [ -n \"$HID\" ] || { echo \"没找到主机：$1（用 pixshell hosts 看列表）\" >&2; exit 2; }; shift",
            "    R=$(post connect \"$(mkjson 0 hostId \"$HID\")\")",
            "    echo \"$R\" | grep -q '\"ok\":true' || { echo \"连接失败：$(echo \"$R\" | field error)\" >&2; exit 2; }",
            "    S=$(echo \"$R\" | field session); [ -n \"$S\" ] && [ \"$S\" != \"0\" ] && SESSION=\"$S\" || :",
            "    # 已连接（同主机已开会话）时 connect 不建新会话，沿用 SESSION；否则用返回的 session",
            "    if [ $# -ge 1 ]; then do_exec \"$*\"; else echo \"已连接：$(echo \"$R\" | field title)（session ${SESSION:-0}）\"; fi ;;",
            "  *)",
            "    echo 'pixshell <子命令>'",
            "    echo '  sessions          列出会话'",
            "    echo '  screen [行数]      读终端画面（默认 200 行）'",
            "    echo '  exec <命令>        在当前会话执行并拿 stdout'",
            "    echo '  type <文本>        往终端敲字（自动回车），随后回显 40 行画面'",
            "    echo '  hosts             列出已保存主机'",
            "    echo '  ssh <主机名|ID> [命令] 直连已保存主机（无头自动建会话），可带命令执行'",
            "    echo '  sftp-ls [路径]     列远端目录'",
            "    echo '  pwd                显示当前远端目录'",
            "    echo '  cd <目录>          切换当前远端目录'",
            "    echo '  ls [前缀|路径]     列目录 / 补全候选（目录尾带 /）'",
            "    echo '环境变量 PIXSHELL_SESSION 可指定会话序号（默认 0）。' ;;",
            "esac",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}
