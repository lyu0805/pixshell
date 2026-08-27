import Foundation

/// 把 PixShell 注册为 Claude Code / Codex / OpenCode 等 AI 工具的默认交互式 SSH 引擎。
///
/// 做法（不碰系统 `/usr/bin/ssh`）：
/// 1. 在 `~/Library/Application Support/PixShell/bin/pixshell-ssh` 写包装脚本；
/// 2. 软链 `~/.local/bin/ssh` → 该脚本（仅当目标不存在或已是我们自己的链）；
/// 3. 写 marker 文件记录注册状态。
///
/// 包装脚本优先走 AgentBridge 交互会话（`pixshell` CLI），桥未就绪时回落真正的 `/usr/bin/ssh`。
enum AiSshBridge {

    // MARK: - Paths

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PixShell", isDirectory: true)
    }
    static var binDir: URL { supportDir.appendingPathComponent("bin", isDirectory: true) }
    static var wrapperPath: URL { binDir.appendingPathComponent("pixshell-ssh") }
    static var markerPath: URL { supportDir.appendingPathComponent("ai-ssh-registered") }
    static var envSnippetPath: URL { supportDir.appendingPathComponent("ai-ssh.env") }
    static var localBinDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
    }
    static var localSshLink: URL { localBinDir.appendingPathComponent("ssh") }

    /// 脚本内唯一标记，用于识别「是我们写的包装 / 软链」，取消注册时只动自己的。
    static let magic = "PixShell-AI-SSH-BRIDGE-v1"

    // MARK: - Detected AI tools

    struct Tool: Equatable {
        let id: String
        let display: String
        /// 可执行文件路径（CLI）；没有 CLI 但有配置/App 时可为 nil。
        let path: String?
        let kind: Kind
        enum Kind: String { case cli, app, config }
    }

    /// 扫描本机已装 AI 工具（CLI / 常见配置目录 / App bundle）。
    static func detectTools() -> [Tool] {
        var out: [Tool] = []
        let cliSpecs: [(id: String, display: String, exe: String)] = [
            ("claude", "Claude Code", "claude"),
            ("codex", "Codex", "codex"),
            ("grok", "Grok", "grok"),
            ("opencode", "OpenCode", "opencode"),
            ("cursor", "Cursor", "cursor"),
            ("windsurf", "Windsurf", "windsurf"),
            ("ollama", "Ollama", "ollama"),
        ]
        for s in cliSpecs {
            if let p = which(s.exe) {
                out.append(Tool(id: s.id, display: s.display, path: p, kind: .cli))
            }
        }
        // App / 配置兜底：CLI 没在 PATH 里，但装了桌面端也算「已检测到」
        let home = NSHomeDirectory()
        let extras: [(id: String, display: String, paths: [String])] = [
            ("claude", "Claude Code", [
                "\(home)/.claude",
                "\(home)/Library/Application Support/Claude",
                "/Applications/Claude.app",
            ]),
            ("codex", "Codex", [
                "\(home)/.codex",
                "\(home)/Library/Application Support/Codex",
                "\(home)/Library/Application Support/com.openai.codex",
                "/Applications/Codex.app",
            ]),
            ("opencode", "OpenCode", [
                "\(home)/.opencode",
                "\(home)/Library/Application Support/ai.opencode.desktop",
            ]),
            ("cursor", "Cursor", [
                "\(home)/.cursor",
                "/Applications/Cursor.app",
            ]),
            ("windsurf", "Windsurf", [
                "\(home)/.windsurf",
                "/Applications/Windsurf.app",
            ]),
            ("ollama", "Ollama", [
                "\(home)/.ollama",
                "/Applications/Ollama.app",
                "/usr/local/bin/ollama",
                "/opt/homebrew/bin/ollama",
            ]),
            ("grok", "Grok", [
                "\(home)/.grok",
                "\(home)/.grok/bin/grok",
            ]),
        ]
        let have = Set(out.map(\.id))
        let fm = FileManager.default
        for e in extras where !have.contains(e.id) {
            if e.paths.contains(where: { fm.fileExists(atPath: $0) }) {
                out.append(Tool(id: e.id, display: e.display, path: e.paths.first { fm.fileExists(atPath: $0) }, kind: .app))
            }
        }
        // 稳定排序：按 display
        return out.sorted { $0.display.localizedStandardCompare($1.display) == .orderedAscending }
    }

    // MARK: - Status

    enum Status: Equatable {
        case registered(wrapper: String, link: String?)
        case notRegistered
        /// 用户自己的 ~/.local/bin/ssh 占位，我们没动过。
        case blocked(existing: String)

        var isRegistered: Bool {
            if case .registered = self { return true }
            return false
        }
    }

    static func status() -> Status {
        let fm = FileManager.default
        let wrapperOK = isOurWrapper(at: wrapperPath.path)
        let link = localSshLink.path
        if fm.fileExists(atPath: link) {
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link) {
                if dest == wrapperPath.path || isOurWrapper(at: dest) {
                    return .registered(wrapper: wrapperPath.path, link: link)
                }
            }
            // 普通文件：看是否我们写的
            if isOurWrapper(at: link) {
                return .registered(wrapper: link, link: link)
            }
            // 别人的东西
            if wrapperOK || fm.fileExists(atPath: markerPath.path) {
                // marker 在但 link 不是我们的 → 异常态，仍报 blocked
            }
            return .blocked(existing: link)
        }
        if wrapperOK, fm.fileExists(atPath: markerPath.path) {
            return .registered(wrapper: wrapperPath.path, link: nil)
        }
        return .notRegistered
    }

    static func isRegistered() -> Bool { status().isRegistered }

    // MARK: - Register / Unregister

    struct Result {
        let ok: Bool
        let message: String
    }

    /// 一键注册。`bridgePort` 用于顺手刷新 `pixshell` CLI（可 nil）。
    @discardableResult
    static func register(bridgePort: Int? = nil) -> Result {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: localBinDir, withIntermediateDirectories: true)

            // 顺手保证 agent CLI 在盘上
            if let port = bridgePort {
                AgentCLI.install(port: port)
            } else if fm.fileExists(atPath: AgentCLI.scriptPath.path) {
                // 已有就不动
            } else {
                AgentCLI.install(port: AgentBridge.defaultPort)
            }

            let body = wrapperScript()
            try body.write(to: wrapperPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath.path)

            // env 片段：给用户/工具 source 用，不自动改 shell rc
            let envBody = """
            # \(magic) — source 此文件可把 PixShell SSH 桥接放进当前 shell
            # 由 PixShell 自动生成，勿手改（重新注册会覆盖）
            export PATH=\"$HOME/.local/bin:$PATH\"
            export GIT_SSH_COMMAND=\"\(wrapperPath.path)\"
            export PIXSHELL_SSH=\"\(wrapperPath.path)\"
            """
            try envBody.write(to: envSnippetPath, atomically: true, encoding: .utf8)

            // 软链 ~/.local/bin/ssh
            let link = localSshLink
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if existing != wrapperPath.path {
                    try fm.removeItem(at: link)
                }
            } else if fm.fileExists(atPath: link.path) {
                if isOurWrapper(at: link.path) {
                    try fm.removeItem(at: link)
                } else {
                    return Result(ok: false,
                                  message: "\(link.path) 已存在且不是 PixShell 包装，已跳过（不覆盖用户文件）。请手动处理后再注册。")
                }
            }
            if !fm.fileExists(atPath: link.path) {
                try fm.createSymbolicLink(at: link, withDestinationURL: wrapperPath)
            }

            let marker = """
            \(magic)
            registered_at=\(ISO8601DateFormatter().string(from: Date()))
            wrapper=\(wrapperPath.path)
            link=\(link.path)
            """
            try marker.write(to: markerPath, atomically: true, encoding: .utf8)

            let tools = detectTools()
            let toolLine = tools.isEmpty
                ? "未检测到本机 AI CLI（仍已注册全局 ssh 包装，装好工具后即生效）。"
                : "已覆盖检测到的工具：\(tools.map(\.display).joined(separator: "、"))。"
            Log.info("AI SSH 桥接已注册 wrapper=\(wrapperPath.path) link=\(link.path)", "bridge")
            return Result(ok: true, message: "已注册为 AI 默认 SSH 工具。\(toolLine)\n包装：\(wrapperPath.path)\n软链：\(link.path)")
        } catch {
            Log.warn("AI SSH 注册失败：\(error.localizedDescription)", "bridge")
            return Result(ok: false, message: "注册失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    static func unregister() -> Result {
        let fm = FileManager.default
        var notes: [String] = []
        // 只删我们的软链 / 我们写的 ssh 文件
        let link = localSshLink.path
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link) {
            if dest == wrapperPath.path || isOurWrapper(at: dest) {
                try? fm.removeItem(atPath: link)
                notes.append("已移除 \(link)")
            } else {
                notes.append("保留 \(link)（不是我们的软链）")
            }
        } else if fm.fileExists(atPath: link), isOurWrapper(at: link) {
            try? fm.removeItem(atPath: link)
            notes.append("已移除 \(link)")
        }
        if fm.fileExists(atPath: wrapperPath.path), isOurWrapper(at: wrapperPath.path) {
            try? fm.removeItem(at: wrapperPath)
            notes.append("已移除包装脚本")
        }
        try? fm.removeItem(at: markerPath)
        try? fm.removeItem(at: envSnippetPath)
        if notes.isEmpty { notes.append("无需清理（本来就未注册）") }
        Log.info("AI SSH 桥接已取消：\(notes.joined(separator: "; "))", "bridge")
        return Result(ok: true, message: notes.joined(separator: "\n"))
    }

    // MARK: - Internals

    private static func isOurWrapper(at path: String) -> Bool {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return s.contains(magic)
    }

    /// 在 PATH + 常见用户目录里找可执行文件（GUI 进程 PATH 通常比登录 shell 窄）。
    static func which(_ name: String) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        dirs += [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.grok/bin",
            "\(home)/.opencode/bin",
            "\(home)/.codex/bin",
            "\(home)/.cursor/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        var seen = Set<String>()
        for d in dirs {
            if seen.contains(d) { continue }
            seen.insert(d)
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 生成 `pixshell-ssh`：优先 AgentBridge 交互会话，否则回落 `/usr/bin/ssh`。
    private static func wrapperScript() -> String {
        // 多行 bash：每行保持同样缩进，避免 Swift 多行字面量 indent 问题 —— 用数组 join。
        let pix = AgentCLI.scriptPath.path
        let lines: [String] = [
            "#!/bin/bash",
            "# \(magic)",
            "# PixShell AI 默认 SSH 引擎 —— 由 App 自动生成，勿手改（重新注册会覆盖）。",
            "# 目标：让 Claude Code / Codex / OpenCode 等调用 ssh 时走 PixShell 已连接的交互会话，",
            "# 而不是每条指令都 /usr/bin/ssh 单次重连。桥未就绪时透明回落系统 ssh。",
            "set -euo pipefail",
            "umask 077",
            "REAL_SSH=\"/usr/bin/ssh\"",
            "PIXSHELL=\"\(pix)\"",
            "TOKEN_FILE=\"$HOME/Library/Application Support/PixShell/agent_token\"",
            "LOG=\"$HOME/Library/Application Support/PixShell/logs/ai-ssh.log\"",
            "mkdir -p \"$(dirname \"$LOG\")\" 2>/dev/null || true",
            "[ ! -e \"$LOG\" ] || chmod 600 \"$LOG\" 2>/dev/null || true",
            "log() { printf '%s [ai-ssh] %s\\n' \"$(date '+%Y-%m-%dT%H:%M:%S')\" \"$*\" >>\"$LOG\" 2>/dev/null || true; }",
            "",
            "# 解析粗略目标：user@host / -p port；其余原样转给回落 ssh。",
            "# 只认「纯主机连接」（可能带 -p 端口/或直接跟命令）。会改变连接语义的参数",
            "# （-L/-R/-D 隧道、-N、-i 密钥、-F config、-J 跳板、-o 任何选项）一律走系统 ssh，不进桥。",
            "ARGS=( \"$@\" )",
            "HOST=\"\"; USER=\"\"; PORT=\"\"; CMDCOUNT=0; CMD_JOINED=\"\"; SAW_DOUBLE=0; WANT_TTY=0; REAL_ONLY=0",
            "i=0",
            "while [ $i -lt ${#ARGS[@]} ]; do",
            "  a=\"${ARGS[$i]}\"",
            "  case \"$a\" in",
            "    --) SAW_DOUBLE=1; i=$((i+1)); while [ $i -lt ${#ARGS[@]} ]; do CMD_JOINED=\"${CMD_JOINED:+$CMD_JOINED }${ARGS[$i]}\"; CMDCOUNT=$((CMDCOUNT+1)); i=$((i+1)); done; break ;;",
            "    -p) i=$((i+1)); PORT=\"${ARGS[$i]:-}\" ;;",
            "    -p*) PORT=\"${a#-p}\" ;;",
            "    -L*|-R*|-D*|-N|-W) REAL_ONLY=1 ;;",
            "    -i) REAL_ONLY=1 ;;",
            "    -o|-F|-J) REAL_ONLY=1 ;;",
            "    -Q|-T|-O|-E|-G|-V) REAL_ONLY=1 ;;",
            "    -t|-tt) WANT_TTY=1 ;;",
            "    -*) ;;",
            "    *)",
            "      if [ -z \"$HOST\" ]; then",
            "        if [[ \"$a\" == *@* ]]; then USER=\"${a%%@*}\"; HOST=\"${a#*@}\"; else HOST=\"$a\"; fi",
            "        # HOST 已定，剩余非 - 参数一律当作远端命令，累加到 CMD_JOINED",
            "      else",
            "        CMD_JOINED=\"${CMD_JOINED:+$CMD_JOINED }$a\"; CMDCOUNT=$((CMDCOUNT+1))",
            "      fi",
            "      ;;",
            "  esac",
            "  i=$((i+1))",
            "done",
            "",
            "fallback() {",
            "  log \"fallback real ssh host=${HOST:-?} argc=$#\"",
            "  exec \"$REAL_SSH\" \"$@\"",
            "}",
            "",
            "# 无 host / 显式要走系统 / 检测到隧道密钥跳板等非纯主机连接：直接回落系统 ssh",
            "if [ -z \"$HOST\" ]; then fallback \"$@\"; fi",
            "if [ \"${PIXSHELL_SSH_FORCE_REAL:-0}\" = 1 ]; then fallback \"$@\"; fi",
            "if [ \"$REAL_ONLY\" = 1 ]; then fallback \"$@\"; fi",
            "",
            "# 桥健康？",
            "bridge_ok() {",
            "  [ -x \"$PIXSHELL\" ] || return 1",
            "  [ -r \"$TOKEN_FILE\" ] || return 1",
            "  # pixshell 自己读 token；这里只探 sessions 是否通",
            "  out=\"$(\"$PIXSHELL\" sessions 2>/dev/null || true)\"",
            "  echo \"$out\" | grep -q '\"ok\"[[:space:]]*:[[:space:]]*true\\|sessions\\|\\[' 2>/dev/null",
            "}",
            "",
            "if ! bridge_ok; then",
            "  log \"bridge not ready → real ssh $HOST\"",
            "  fallback \"$@\"",
            "fi",
            "",
            "# ---- 走 PixShell 交互桥 ----",
            "log \"bridge route user=${USER:-} host=$HOST port=${PORT:-} remote_cmd=$CMDCOUNT\"",
            "",
            "# 有远端命令：优先直连已存主机（无头自动建会话），主机不在列表则沿用当前会话，再失败回落系统 ssh",
            "# bash set -u 陷阱：空数组 ${#arr[@]} 会返回 1，${arr[*]} 会 undef 报错。",
            "# 一律用「已初始化变量 + 计数 + 安全展开」，任何路径都不碰未初始化数组。",
            "if [ \"$CMDCOUNT\" -gt 0 ]; then",
            "  CMD=\"$CMD_JOINED\"",
            "  # user@host 里的 user 剥掉，hostid 按名/IP/ID 匹配",
            "  TARGET=\"$HOST\"",
            "  # pixshell 可能输出 JSON 错误而退出码仍 0（field 助手兜底打印），所以用输出内容判定，不只看出错码",
            "  OUT=\"$(\"$PIXSHELL\" ssh \"$TARGET\" \"$CMD\" 2>&1)\"",
            "  if [ -n \"$OUT\" ] && ! echo \"$OUT\" | grep -q '\"ok\"[[:space:]]*:[[:space:]]*false'; then printf '%s\\n' \"$OUT\"; exit 0; fi",
            "  # ssh 子命令失败（主机不在已存列表/连接失败）→ 沿用当前会话 exec，仍失败则回落系统 ssh",
            "  OUT2=\"$(\"$PIXSHELL\" exec \"$CMD\" 2>&1)\"",
            "  if [ -n \"$OUT2\" ] && ! echo \"$OUT2\" | grep -q '\"ok\"[[:space:]]*:[[:space:]]*false'; then printf '%s\\n' \"$OUT2\"; exit 0; fi",
            "  log \"pixshell route failed（host=$HOST）→ real ssh\"",
            "  fallback \"$@\"",
            "fi",
            "",
            "# 纯交互：把说明打到 stderr，stdin 逐行 type 进当前会话，并定期 screen",
            "if [ -t 0 ] || [ \"$WANT_TTY\" = 1 ]; then",
            "  echo \"PixShell AI SSH · 已接入交互会话（目标 $HOST）。\" >&2",
            "  echo \"提示：在 PixShell 里先连上对应主机；输入空行 + Ctrl-D 结束。\" >&2",
            "  \"$PIXSHELL\" screen 30 2>/dev/null || true",
            "  while IFS= read -r line || [ -n \"$line\" ]; do",
            "    \"$PIXSHELL\" type \"$line\" >/dev/null || { log \"type failed\"; fallback \"$@\"; }",
            "  done",
            "  exit 0",
            "fi",
            "",
            "# 非 tty 又无远端命令：回落真实 ssh（scp/git 等更稳）",
            "fallback \"$@\"",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}
