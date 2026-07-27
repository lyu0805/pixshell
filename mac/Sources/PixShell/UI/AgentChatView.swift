import AppKit

/// 与**本机 CLI agent** 对话的面板（挂在 SFTP 面板左栏，与「本地文件」互为两种模式）。
///
/// 用途：一边看着远端目录，一边让本机的 agent 帮忙想命令/解释报错/生成脚本，
/// 不用切出去开另一个终端。工作目录取当前本地路径，agent 因此能看到你正在浏览的那批文件。
///
/// 走**非交互一次性调用**（`claude -p` / `codex exec`），不维持长驻会话：
/// 一次问答一个进程，好取消、不会有半死不活的子进程挂在后台。代价是没有多轮上下文，
/// 所以下面把最近几轮对话拼进 prompt 里当作简易上下文。
final class AgentChatView: NSView {

    /// 支持的本机 agent。命令行形态在 `argv(for:)` 里，新增一个 agent 只改那里。
    enum Agent: String, CaseIterable {
        case claude, codex
        var display: String { self == .claude ? "Claude" : "Codex" }
        var exe: String { rawValue }
    }

    private let agentPopup = NSPopUpButton()
    private var transcript: NSTextView!
    private var transcriptScroll: NSScrollView!
    private let input = NSTextField()
    private var sendBtn: PillButton!
    private let spinner = NSProgressIndicator()

    private var running: Process?
    /// 最近几轮对话，拼进下一次 prompt 当简易上下文（一次性调用没有服务端会话）。
    private var history: [(role: String, text: String)] = []
    private static let historyKeep = 6

    /// 工作目录（= SFTP 面板当前本地路径）。宿主在切目录时更新它。
    var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser {
        didSet { cwdLabel.stringValue = workingDirectory.path }
    }
    private let cwdLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        agentPopup.addItems(withTitles: Agent.allCases.map { $0.display })
        agentPopup.font = Theme.ui(11)
        agentPopup.translatesAutoresizingMaskIntoConstraints = false
        // 本机没装的 agent 直接禁掉，别让用户点了才发现
        for (i, a) in Agent.allCases.enumerated() where Self.which(a.exe) == nil {
            agentPopup.item(at: i)?.isEnabled = false
            agentPopup.item(at: i)?.title = a.display + "（未安装）"
        }
        if let firstUsable = Agent.allCases.firstIndex(where: { Self.which($0.exe) != nil }) {
            agentPopup.selectItem(at: firstUsable)
        }

        cwdLabel.font = Theme.mono(9.5); cwdLabel.textColor = Theme.muted
        cwdLabel.lineBreakMode = .byTruncatingHead
        cwdLabel.stringValue = workingDirectory.path
        cwdLabel.toolTip = "agent 的工作目录（跟随左栏本地路径）"

        let ts: NSScrollView
        (ts, transcript) = ScrollableText.make(font: Theme.mono(11), editable: false,
                                               bg: Theme.bg2, border: Theme.border)
        transcriptScroll = ts

        input.placeholderString = "问点什么…（⏎ 发送）"
        input.font = Theme.ui(11)
        input.target = self
        input.action = #selector(send)
        input.translatesAutoresizingMaskIntoConstraints = false

        sendBtn = PillButton("发送", style: .primary, hPad: 10, height: 22,
                             font: Theme.ui(11, .semibold), target: self, action: #selector(send))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let head = NSStackView(views: [agentPopup, spinner, NSView()])
        head.spacing = 6; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        let inputRow = NSStackView(views: [input, sendBtn])
        inputRow.spacing = 6; inputRow.alignment = .centerY
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        let v = NSStackView(views: [head, cwdLabel, ts, inputRow])
        v.orientation = .vertical; v.spacing = 4; v.alignment = .leading
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
            head.widthAnchor.constraint(equalTo: v.widthAnchor),
            cwdLabel.widthAnchor.constraint(equalTo: v.widthAnchor),
            ts.widthAnchor.constraint(equalTo: v.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: v.widthAnchor),
        ])

        if Agent.allCases.allSatisfy({ Self.which($0.exe) == nil }) {
            append("系统", "本机没找到 claude / codex 命令。装好并确保在 PATH 里就能用了。")
            input.isEnabled = false; sendBtn.isEnabled = false
        } else {
            append("系统", "工作目录 = 左栏本地路径。一次一问一答（非交互模式）。")
        }
    }

    // MARK: 发送 / 取消

    @objc private func send() {
        // 正在跑就当"停止"用
        if let p = running {
            Log.info("用户取消 agent 调用 pid=\(p.processIdentifier)", "agent")
            p.terminate(); running = nil
            finishRunning()
            append("系统", "已取消。")
            return
        }
        let q = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard let agent = selectedAgent() else { return }

        input.stringValue = ""
        append("我", q)
        history.append((role: "user", text: q))

        let prompt = buildPrompt(q)
        Log.info("agent 提问 \(agent.display) cwd=\(workingDirectory.path) prompt=\(prompt.count) 字", "agent")
        startRunning()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let out = Self.run(agent: agent, prompt: prompt, cwd: self.workingDirectory) { [weak self] proc in
                DispatchQueue.main.async { self?.running = proc }
            }
            DispatchQueue.main.async {
                self.finishRunning()
                let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.info("agent 返回 \(agent.display) \(text.count) 字\(text.isEmpty ? "（空！检查 agent 是否需要登录/额度）" : "")", "agent")
                let shown = text.isEmpty ? "（没有输出）" : text
                self.append(agent.display, shown)
                self.history.append((role: "assistant", text: shown))
                if self.history.count > Self.historyKeep {
                    self.history.removeFirst(self.history.count - Self.historyKeep)
                }
            }
        }
    }

    /// 把最近几轮 + "你可以操作本软件"的说明拼成 prompt。
    /// 一次性调用没有服务端会话，上下文只能这么带。
    private func buildPrompt(_ q: String) -> String {
        var s = AgentCLI.promptPreamble() + "\n\n"
        let prior = history.dropLast()   // 最后一条就是本次提问
        guard !prior.isEmpty else { return s + "现在的问题：" + q }
        s += "以下是我们之前的对话，供你参考上下文：\n"
        for h in prior {
            s += (h.role == "user" ? "我：" : "你：") + h.text + "\n"
        }
        s += "\n现在的问题：" + q
        return s
    }

    private func selectedAgent() -> Agent? {
        let i = agentPopup.indexOfSelectedItem
        guard Agent.allCases.indices.contains(i) else { return nil }
        let a = Agent.allCases[i]
        guard Self.which(a.exe) != nil else {
            append("系统", "\(a.display) 没装或不在 PATH 里。")
            return nil
        }
        return a
    }

    private func startRunning() {
        spinner.startAnimation(nil)
        sendBtn.title = "停止"
        sendBtn.style = .danger
    }
    private func finishRunning() {
        running = nil
        spinner.stopAnimation(nil)
        sendBtn.title = "发送"
        sendBtn.style = .primary
    }

    private func append(_ who: String, _ text: String) {
        let head = NSAttributedString(string: "\(who)\n", attributes: [
            .font: Theme.ui(11, .semibold),
            .foregroundColor: who == "我" ? Theme.accent : (who == "系统" ? Theme.muted : Theme.ok),
        ])
        let body = NSAttributedString(string: text + "\n\n", attributes: [
            .font: Theme.mono(11), .foregroundColor: Theme.text,
        ])
        transcript.textStorage?.append(head)
        transcript.textStorage?.append(body)
        transcript.scrollToEndOfDocument(nil)
    }

    // MARK: 跑 CLI

    /// 非交互调用：`claude -p <prompt>` / `codex exec <prompt>`。
    /// stdin 切到 /dev/null —— agent 拿不到 tty 就不会尝试进交互模式卡住。
    private static func run(agent: Agent, prompt: String, cwd: URL,
                            onStart: (Process) -> Void) -> String {
        guard let exe = which(agent.exe) else { return "找不到 \(agent.exe)" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = argv(for: agent, prompt: prompt)
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.error("agent 启动失败 \(exe): \(error.localizedDescription)", "agent")
            return "启动失败：\(error.localizedDescription)"
        }
        Log.info("agent 进程 pid=\(p.processIdentifier) exe=\(exe)", "agent")
        onStart(p)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            Log.warn("agent 退出码 \(p.terminationStatus)（非 0，输出可能是错误信息）", "agent")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func argv(for agent: Agent, prompt: String) -> [String] {
        switch agent {
        case .claude: return ["-p", prompt]
        case .codex:  return ["exec", prompt]
        }
    }

    /// 在 PATH（含常见用户目录）里找可执行文件。GUI 进程的 PATH 通常比登录 shell 窄，得自己补。
    private static func which(_ name: String) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        dirs += ["\(home)/.local/bin", "\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for d in dirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
