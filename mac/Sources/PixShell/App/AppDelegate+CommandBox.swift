import AppKit

// 命令框交互（对齐老仓库 docs/ui/interaction-logic.md §2 §3）：
//   Enter 发送 · ↑↓ 历史 · Tab 远端路径补全 · ${参数} 弹框 · 发送后焦点保持在命令框
//   cd 命令 → 同步 SFTP 目录（settings.syncDirWithSftp 默认开）→ 状态栏显示同步路径
extension AppDelegate: NSTextFieldDelegate {

    // MARK: 键盘：↑↓ 历史 / Tab 补全
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === cmdInput else { return false }
        let currentString = cmdInput?.stringValue ?? ""
        switch sel {
        case #selector(NSResponder.moveUp(_:)):
            cmdInput?.stringValue = cmdHistory.older(current: currentString)
            moveCaretToEnd(textView); return true
        case #selector(NSResponder.moveDown(_:)):
            cmdInput?.stringValue = cmdHistory.newer()
            moveCaretToEnd(textView); return true
        case #selector(NSResponder.insertTab(_:)):
            completeRemotePath(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            focusTerminal(); return true          // Esc：从命令框回到终端
        default:
            return false
        }
    }
    private func moveCaretToEnd(_ tv: NSTextView) {
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }

    /// Tab 补全：把最后一个 token 当远端路径前缀，用 ls 列同级候选。
    func completeRemotePath() {
        guard let cmdInput = cmdInput else { return }
        guard sessions.indices.contains(current), let ssh = sessions[current].ssh else { return }
        let text = cmdInput.stringValue
        guard let lastSpace = text.lastIndex(of: " ") else { return }   // 第一个 token 是命令名，不补路径
        let prefixPart = String(text[..<text.index(after: lastSpace)])
        let token = String(text[text.index(after: lastSpace)...])
        // 拆出目录与待补名
        let dir: String, stub: String
        if let slash = token.lastIndex(of: "/") {
            dir = String(token[..<slash]).isEmpty ? "/" : String(token[..<token.index(after: slash)])
            stub = String(token[token.index(after: slash)...])
        } else {
            dir = sftpPanel?.currentRemotePath ?? "."
            stub = token
        }
        let quoted = dir.replacingOccurrences(of: "'", with: "'\\''")
        ssh.exec("ls -1ap '\(quoted)' 2>/dev/null") { [weak self] out in
            guard let self = self else { return }
            let names = out.split(separator: "\n").map(String.init)
                .filter { $0 != "./" && $0 != "../" && (stub.isEmpty || $0.hasPrefix(stub)) }
            guard !names.isEmpty else { return }
            if names.count == 1 {
                let joined = token.contains("/") ? dir + names[0] : names[0]
                self.cmdInput.stringValue = prefixPart + joined
            } else {
                // 多候选：补到公共前缀，并把候选打到状态栏
                let common = self.commonPrefix(names)
                if common.count > stub.count {
                    let joined = token.contains("/") ? dir + common : common
                    self.cmdInput?.stringValue = prefixPart + joined
                }
                self.setStatus(names.prefix(8).joined(separator: "  "))
            }
        }
    }
    private func commonPrefix(_ list: [String]) -> String {
        guard var p = list.first else { return "" }
        for s in list.dropFirst() {
            while !s.hasPrefix(p), !p.isEmpty { p.removeLast() }
        }
        return p
    }

    // MARK: 发送
    @objc func sendCommandBox() {
        // 底栏命令框已合并到命令板：有 cmdInput 走旧路径，否则委托 sendCommandText
        if cmdInput == nil {
            sendCommandText(cmdPanel?.editor.string)
            if let ed = cmdPanel?.editor { window.makeFirstResponder(ed) }
            return
        }
        guard let cmdInput = cmdInput else { return }
        var text = cmdInput.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard sessions.indices.contains(current) else { setStatus("无活动会话"); return }

        // ${参数} → 逐个弹框取值
        if CommandParams.hasUnresolved(text) {
            var values: [String: String] = [:]
            for name in CommandParams.parse(text) {
                guard let v = askParam(name) else { return }   // 取消则整条放弃
                values[name] = v
            }
            text = CommandParams.render(text, values: values)
        }

        sessions[current].ssh?.send(Array((text + "\r").utf8))
        cmdHistory.push(text)
        applyCdSync(for: text)
        cmdInput.stringValue = ""
        window.makeFirstResponder(cmdInput)   // 发送后焦点留在命令框（底栏 UX）
    }

    private func askParam(_ name: String) -> String? {
        let a = NSAlert.pix(); a.messageText = "参数 \(name)"; a.informativeText = "请输入 ${\(name)} 的值"
        a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22)); a.accessoryView = tf
        a.window.initialFirstResponder = tf
        return a.runModal() == .alertFirstButtonReturn ? tf.stringValue : nil
    }

    /// cd 命令 → 同步 SFTP 目录 + 状态栏
    func applyCdSync(for command: String) {
        guard syncDirWithSftp, CommandSync.shouldSyncCd(command), let sp = sftpPanel else { return }
        let next = CommandSync.applyCd(sp.currentRemotePath, command)
        sp.navigate(to: next)
        setStatus("同步目录 \(next)")
    }

    /// SFTP 里进目录 → 可选把 cd 写回终端（反向同步）
    func syncTerminalCd(to path: String) {
        guard syncDirWithSftp, sessions.indices.contains(current) else { return }
        sessions[current].ssh?.send(Array("cd '\(path.replacingOccurrences(of: "'", with: "'\\''"))'\r".utf8))
    }

    // MARK: 历史弹出（命令栏「历史」按钮）
    @objc func showCommandHistory(_ sender: Any) {
        let prefix = cmdPanel?.editor.string ?? ""
        let items = cmdHistory.filter(prefix: prefix, limit: 100)
        guard !items.isEmpty else { setStatus("暂无历史命令"); return }
        
        let vc = CommandHistoryVC()
        vc.items = items
        
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        
        vc.onSelect = { [weak self] cmd in
            self?.cmdPanel?.editor.string = cmd
            if let ed = self?.cmdPanel?.editor {
                self?.window.makeFirstResponder(ed)
            }
            pop.close()
        }
        vc.onRun = { [weak self] cmd in
            // 直接把历史文本交给 sendCommandText，禁止走空的 cmdInput
            self?.cmdPanel?.editor.string = cmd
            if let ed = self?.cmdPanel?.editor {
                self?.window.makeFirstResponder(ed)
            }
            self?.sendCommandText(cmd)
            pop.close()
        }

        vc.onCopy = { [weak self] cmd in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            self?.setStatus("已复制到剪贴板")
            pop.close()
        }
        vc.onDelete = { [weak self] cmd in
            self?.cmdHistory.remove(item: cmd)
            self?.setStatus("已删除记录")
        }
        vc.onClear = { [weak self] in
            self?.cmdHistory.clear()
            self?.setStatus("历史记录已清空")
            pop.close()
        }
        
        let targetView = (sender as? NSView)
        if let v = targetView {
            pop.show(relativeTo: v.bounds, of: v, preferredEdge: .maxY)
        }
    }
}
