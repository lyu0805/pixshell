import AppKit
import SwiftTerm

// 系统菜单栏 + 全局快捷键（老仓库 hotkeys2 的原生对应）。
// 之前完全没有菜单栏 —— mac 应用必须有，且这是「查看/选项」等动作的键盘入口。
extension AppDelegate {

    func buildMainMenu() {
        let main = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(mi("关于 PixShell", #selector(menuAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(mi("设置…", #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 PixShell", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 PixShell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 文件
        let fileItem = NSMenuItem(); let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(mi("连接管理器…", #selector(openConnMgr), "l"))
        fileMenu.addItem(mi("新建连接…", #selector(addHost), "n"))
        fileMenu.addItem(mi("快速连接", #selector(newQuickTab), "t"))
        fileMenu.addItem(mi("密钥管理…", #selector(openKeyManager), "k"))
        fileMenu.addItem(mi("主机指纹管理…", #selector(openFingerprintManager)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(mi("断开", #selector(menuDisconnect)))
        fileMenu.addItem(mi("重新连接", #selector(menuReconnect), "r"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(mi("导入主机…", #selector(importHosts)))
        fileMenu.addItem(mi("导出主机…", #selector(exportHosts)))
        fileItem.submenu = fileMenu; main.addItem(fileItem)

        // 编辑：输入框聚焦时走 NSTextField/NSTextView；否则复制/粘贴/全选走终端
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(mi("剪切", #selector(termCut), "x"))
        editMenu.addItem(mi("复制", #selector(termCopy), "c"))
        editMenu.addItem(mi("粘贴", #selector(termPaste), "v"))
        editMenu.addItem(mi("全选", #selector(termSelectAll), "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(mi("清屏", #selector(termClear), "k"))
        editItem.submenu = editMenu; main.addItem(editItem)

        // 查看
        let viewItem = NSMenuItem(); let viewMenu = NSMenu(title: "查看")
        viewMenu.addItem(mi("系统信息", #selector(openSysInfo), "i"))
        viewMenu.addItem(mi("工具面板", #selector(openTools), "j"))
        viewMenu.addItem(.separator())
        let side = mi("显示/隐藏侧栏", #selector(toggleSidebar), "s")
        side.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(side)
        viewMenu.addItem(mi("显示/隐藏底栏", #selector(toggleDock), "b"))
        let focusCmd = mi("聚焦命令框", #selector(focusCommandBox), ";")
        focusCmd.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(focusCmd)
        let focusTerm = mi("聚焦终端", #selector(focusTerminal), "`")
        focusTerm.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(focusTerm)
        viewMenu.addItem(.separator())
        viewMenu.addItem(mi("文件面板", #selector(showFiles), "1"))
        viewMenu.addItem(mi("命令面板", #selector(showCmds), "2"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(mi("进程管理", #selector(menuToolProcess)))
        viewMenu.addItem(mi("网络监控", #selector(menuToolNetwork)))
        viewMenu.addItem(.separator())
        let bigger = mi("放大字号", #selector(fontBigger), "+")
        let smaller = mi("缩小字号", #selector(fontSmaller), "-")
        viewMenu.addItem(bigger); viewMenu.addItem(smaller)
        viewMenu.addItem(mi("切换主题", #selector(toggleTheme)))
        viewItem.submenu = viewMenu; main.addItem(viewItem)

        // 会话（多标签切换）
        let sesItem = NSMenuItem(); let sesMenu = NSMenu(title: "会话")
        let next = mi("下一个标签", #selector(nextTab), "}")
        let prev = mi("上一个标签", #selector(prevTab), "{")
        sesMenu.addItem(next); sesMenu.addItem(prev)
        sesMenu.addItem(.separator())
        for i in 1...9 {
            let it = mi("第 \(i) 个标签", #selector(selectTabByIndex(_:)), "\(i)")
            it.keyEquivalentModifierMask = [.control]
            it.tag = i - 1
            sesMenu.addItem(it)
        }
        sesMenu.addItem(.separator())
        sesMenu.addItem(mi("关闭当前标签", #selector(closeCurrentTab), "w"))
        sesItem.submenu = sesMenu; main.addItem(sesItem)

        // 工具 / AI SSH 注册（Web 连接主入口在「新建连接 → 类型 Web」，不在菜单硬开）
        let toolsItem = NSMenuItem(); let toolsMenu = NSMenu(title: "工具")
        toolsMenu.addItem(mi("工具面板", #selector(openTools)))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(mi("接入 AI 工具…", #selector(openAIIntegration)))
        toolsMenu.addItem(mi("一键注册 AI 默认 SSH…", #selector(openAiSshBridge)))
        toolsItem.submenu = toolsMenu; main.addItem(toolsItem)

        // 云端同步 / 帮助
        let helpItem = NSMenuItem(); let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(mi("接入 AI 工具…", #selector(openAIIntegration)))
        helpMenu.addItem(mi("一键注册 AI 默认 SSH…", #selector(openAiSshBridge)))
        helpMenu.addItem(.separator())
        helpMenu.addItem(mi("授权本地网络…", #selector(menuLocalNetworkAuth)))
        helpMenu.addItem(mi("打开本地网络设置", #selector(menuOpenLocalNetworkSettings)))
        helpMenu.addItem(.separator())
        // 开发者：桥接镜像页 / 外开浏览器仅调试，主路径是「新建连接 → Web」
        helpMenu.addItem(mi("打开桥接镜像页（调试）…", #selector(openWebSSHEmbedded)))
        helpMenu.addItem(mi("在系统浏览器打开桥接页…", #selector(openWebSSHInSystemBrowser)))
        helpMenu.addItem(.separator())
        helpMenu.addItem(mi("备份选项配置…", #selector(openBackup)))
        helpMenu.addItem(.separator())
        helpMenu.addItem(mi("项目仓库", #selector(menuRepo)))
        helpItem.submenu = helpMenu; main.addItem(helpItem)

        NSApp.mainMenu = main
    }

    private func mi(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: 焦点模型（老仓库交互文档 §6：⌃; 命令框 / ⌃` 终端 / Esc 从命令框回终端）
    @objc func focusCommandBox() {
        // 底栏命令框已合并：焦点落到命令板编辑器
        if let ed = cmdPanel?.editor {
            window.makeFirstResponder(ed)
            showCmds()
        } else if let f = cmdInput {
            window.makeFirstResponder(f)
        }
    }
    @objc func focusTerminal() {
        guard sessions.indices.contains(current) else { return }
        window.makeFirstResponder(sessions[current].contentView)
    }

    // MARK: 标签快捷键
    @objc func nextTab() {
        guard !sessions.isEmpty else { return }
        selectSession((current + 1) % sessions.count)
    }
    @objc func prevTab() {
        guard !sessions.isEmpty else { return }
        selectSession((current - 1 + sessions.count) % sessions.count)
    }
    @objc func selectTabByIndex(_ sender: NSMenuItem) {
        guard sessions.indices.contains(sender.tag) else { return }
        selectSession(sender.tag)
    }
    @objc func closeCurrentTab() {
        guard sessions.indices.contains(current) else { return }
        closeSession(current)
    }
}


extension AppDelegate {
    /// 「接入 AI 工具」：把 MCP / CLI 两种接法摆出来，一键复制。
    /// 故意**不**替用户去改 Claude Desktop 的配置文件 —— 那是他自己的配置，
    /// 我们只给现成片段，改不改由他决定。
    @objc func openAIIntegration() {
        // 点菜单时顺手确保 CLI/MCP 脚本在盘上（App 启动已装过，这里幂等）
        if let port = agentBridge?.port { AgentCLI.install(port: port) }
        AgentMCP.install()
        let a = NSAlert.pix()
        a.messageText = "接入 AI 工具"
        let bridgeLine: String = {
            if bridgeStatus.running {
                let paired = bridgeStatus.clientIdle.map { $0 < 300 } ?? false
                return paired
                    ? "本地桥：已对接 · 127.0.0.1:\(bridgeStatus.port)"
                    : "本地桥：已开启 · 127.0.0.1:\(bridgeStatus.port)（等外部 CLI/Agent）"
            }
            return "本地桥：未开启（点「重新安装 CLI / MCP」可再拉起）"
        }()
        a.informativeText = """
        PixShell 已经把自己开放给本机的 AI 工具了，两条路都在跑同一条**已连接的 SSH 会话**，不会每条指令都重连。

        \(bridgeLine)

        ① MCP（推荐，桌面 AI 应用 / 支持 MCP 的客户端都吃这套）
           Claude Code CLI 注册：
           \(AgentMCP.claudeCodeCommand())

           Claude Desktop 等配置文件型客户端，把这段并进它的 MCP 配置：
        \(AgentMCP.desktopConfigSnippet())

        ② 命令行（任何终端里的 agent / 脚本 / 定时任务）
           已软链到 ~/.local/bin，直接敲：
           pixshell screen 50
           pixshell exec "systemctl status nginx"
           pixshell type "vim /etc/hosts"

        工具：list_sessions / read_screen / exec_command / type_text / list_hosts / sftp_list
        大输出会自动截断并说明截了多少（避免 MCP 大负载失败），需要更多用 grep/head 收窄或调 max_bytes。
        """
        a.addButton(withTitle: "复制 MCP 注册命令")
        a.addButton(withTitle: "复制 Desktop 配置")
        a.addButton(withTitle: "关闭")
        let r = a.runModal()
        let pb = NSPasteboard.general
        if r == .alertFirstButtonReturn {
            pb.clearContents(); pb.setString(AgentMCP.claudeCodeCommand(), forType: .string)
            setStatus("已复制 MCP 注册命令")
        } else if r == .alertSecondButtonReturn {
            pb.clearContents(); pb.setString(AgentMCP.desktopConfigSnippet(), forType: .string)
            setStatus("已复制 Desktop MCP 配置")
        }
    }

    /// 汉堡「AI 对接」一键项：复制 CLI 用法说明（含路径，不含 token）。
    @objc func copyCLIUsage() {
        if let port = agentBridge?.port { AgentCLI.install(port: port) }
        let text = AgentCLI.promptPreamble()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("已复制 CLI 用法")
    }

    @objc func copyMCPRegister() {
        AgentMCP.install()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentMCP.claudeCodeCommand(), forType: .string)
        setStatus("已复制 MCP 注册命令")
    }

    @objc func copyMCPDesktop() {
        AgentMCP.install()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentMCP.desktopConfigSnippet(), forType: .string)
        setStatus("已复制 Desktop MCP 配置")
    }

    /// 帮助菜单：再触发本地网络授权；「我已允许」必须真的重连，否则按钮等于摆设。
    @objc func menuLocalNetworkAuth() {
        LocalNetworkAuth.presentGrantHelp(from: window) { [weak self] in
            guard let self else { return }
            self.setStatus("本地网络授权后重连…")
            self.reconnectCurrent()
        }
    }

    @objc func menuOpenLocalNetworkSettings() {
        _ = LocalNetworkAuth.openSystemSettings()
        // 打开设置同时再扫一次 Bonjour，尽量弹出系统授权框
        LocalNetworkAuth.requestAuthorizationIfNeeded(force: true, bypassDebounce: true)
        setStatus("已打开系统设置 · 本地网络（请打开 PixShell 开关后重连）")
    }

    @objc func openCLIBinDir() {
        if let port = agentBridge?.port { AgentCLI.install(port: port) }
        AgentMCP.install()
        NSWorkspace.shared.open(AgentCLI.binDir)
        setStatus("已打开 \(AgentCLI.binDir.path)")
    }

    @objc func reinstallCLIBridge() {
        if agentBridge == nil || agentBridge?.isRunning != true {
            startAgentBridge()
        }
        if let port = agentBridge?.port { AgentCLI.install(port: port) }
        AgentMCP.install()
        updateCliStatus()
        setStatus("已重新安装 CLI / MCP（端口 \(agentBridge?.port ?? 0)）")
    }

    /// 调试：应用内打开桥接镜像页（绑定当前会话，不走 host_id）。
    /// 主路径是「新建连接 → 类型 Web → 连接」（见 openWebHostSession）。
    @objc func openWebSSHEmbedded() {
        if agentBridge == nil || agentBridge?.isRunning != true {
            startAgentBridge()
        }
        guard let bridge = agentBridge else {
            setStatus("本地桥未启动，无法打开桥接镜像")
            return
        }
        // 绑定「当前原生会话」索引：Web 页轮询 /stream 读的就是它；无会话时仍可开空页。
        let bindSession: Int? = sessions.isEmpty ? nil : {
            // 若当前已是 Web 标签，绑到它镜像的前一个原生会话；否则绑 current
            let cur = max(0, current)
            if sessions.indices.contains(cur), sessions[cur].isWebSSH {
                return sessions.enumerated().reversed().first(where: { !$0.element.isWebSSH })?.offset
            }
            return cur
        }()

        func tryOpen(attempt: Int) {
            guard bridge.isRunning, let url = bridge.webSSHURL(session: bindSession) else {
                if attempt >= 6 {
                    setStatus("本地桥未就绪，稍后重试桥接镜像")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    tryOpen(attempt: attempt + 1)
                }
                return
            }
            // 占位 TerminalView：Web 标签不渲染它，但 TermSession 构造仍要一份（与其它路径一致）
            let dummy = TerminalView(frame: .zero)
            dummy.terminalDelegate = self
            let web = WebSSHView(frame: termContainer.bounds)
            let host = Host.webSSHTerminal(sessionIndex: bindSession)
            let sess = TermSession(host: host, termView: dummy, webSSHView: web)
            sess.title = host.display
            sessions.append(sess)
            selectSession(sessions.count - 1)
            web.load(url: url)
            setStatus("已打开桥接镜像页 · 127.0.0.1:\(bridge.port)")
            Log.info("桥接镜像 session=\(bindSession.map(String.init) ?? "-")", "webssh")
        }
        tryOpen(attempt: 0)
    }

    /// 兼容旧 selector 名：一律走应用内嵌。
    @objc func openWebSSH() { openWebSSHEmbedded() }

    /// 开发者/调试：在系统浏览器打开桥接页（**不**作为主入口；仅帮助菜单深处）。
    @objc func openWebSSHInSystemBrowser() {
        if agentBridge == nil || agentBridge?.isRunning != true {
            startAgentBridge()
        }
        guard let bridge = agentBridge else {
            setStatus("本地桥未启动")
            return
        }
        func tryOpen(attempt: Int) {
            if bridge.isRunning, let url = bridge.webSSHURL(session: sessions.isEmpty ? nil : max(0, current)) {
                NSWorkspace.shared.open(url)
                setStatus("已在系统浏览器打开桥接页（调试）· :\(bridge.port)")
                Log.info("调试外开桥接页 \(url.absoluteString.replacingOccurrences(of: bridge.currentToken, with: "***"))", "bridge")
                return
            }
            if attempt >= 6 {
                setStatus("本地桥未就绪")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                tryOpen(attempt: attempt + 1)
            }
        }
        tryOpen(attempt: 0)
    }
}
