import AppKit
import SwiftTerm

/// 设置页中的管理入口。先关闭设置 sheet，再打开对应管理界面，避免多个模态层叠。
private final class SettingsHubActionTarget: NSObject {
    weak var app: AppDelegate?
    weak var alert: NSAlert?

    init(app: AppDelegate, alert: NSAlert) {
        self.app = app
        self.alert = alert
    }

    @objc func open(_ sender: NSButton) {
        if let alert, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
        guard let app else { return }
        DispatchQueue.main.async {
            switch sender.tag {
            case 1: app.openProxy()
            case 2: app.openKeyManager()
            case 3: app.openFingerprintManager()
            case 4: app.openAIIntegration()
            case 5: app.openBackup()
            case 6: app.webdavConfigure()
            case 7: app.checkUpdate()
            default: break
            }
        }
    }
}

// 汉堡菜单各项的实现（文件 / 查看 / 选项 / 云端同步 / 帮助）。
// 结构对齐老仓库 index.html #mainMenu；此处只放动作，菜单构建在 AppDelegate+Layout。
extension AppDelegate {

    // MARK: 文件
    @objc func menuConnect() {
        if sessions.indices.contains(current), !sessions[current].connected {
            menuReconnect(); return
        }
        connMgr.show()   // 没有活动会话 → 打开连接管理器选主机
    }
    @objc func menuDisconnect() {
        guard sessions.indices.contains(current) else { return }
        let sess = sessions[current]
        sess.userInitiatedClose = true
        sess.autoReconnectWorkItem?.cancel()
        sess.autoReconnectWorkItem = nil
        sess.ssh?.close()
        sess.connected = false
        clearSessionSidePanels()   // P1：断开即清 SFTP + 系统信息
        rebuildTabs(); setStatus("已断开")
    }
    /// 重新连接：**原地复用当前标签**（见 reconnectCurrent 注释——旧实现会多开一个标签页）。
    @objc func menuReconnect() { reconnectCurrent() }

    /// 导入本地备份包（老仓库 bundle v1；也兼容老的纯 [Host] 数组）
    @objc func importHosts() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url,
              let data = try? Data(contentsOf: url) else { return }
        applyBundle(data, source: url.lastPathComponent)
    }

    /// 把备份包数据应用到本地（主机 + 快捷命令）
    func applyBundle(_ data: Data, source: String) {
        if let b = try? BackupBundle.decode(data) {
            for h in b.hosts { store.upsert(h) }
            connMgr?.reload(); quickConnect?.reload()
            Log.info("导入备份包 \(source)：主机 \(b.hosts.count) / 快捷命令 \(b.quickCommands.count)", "backup")
            alert("导入完成", "主机 \(b.hosts.count) 台，快捷命令 \(b.quickCommands.count) 条\n（密码不在备份包内，需重新输入）")
            return
        }
        if let list = try? JSONDecoder().decode([Host].self, from: data) {   // 兼容旧格式
            for h in list { store.upsert(h) }
            connMgr?.reload(); quickConnect?.reload()
            alert("导入完成", "已导入/更新 \(list.count) 台主机")
            return
        }
        alert("导入失败", "不是 PixShell 备份包")
    }

    /// 自动同步应用完整快照。replaceAll 才能同步另一设备上的删除；密码仍保留在本机 Keychain。
    func applySyncedBundle(_ bundle: BackupBundle) {
        store.replaceAll(bundle.hosts)
        cmdPanel?.applySyncedCommands(bundle.quickCommands)
        if let value = bundle.settings["highlight"] { highlightEnabled = value == "1" }
        if let value = bundle.settings["syncDirWithSftp"] { syncDirWithSftp = value == "1" }
        if let value = bundle.settings["fontSize"], let number = Double(value) {
            TermTheme.fontSize = CGFloat(max(9, min(24, number)))
            setFontSize(TermTheme.fontSize)
        }
        if let value = bundle.settings["colorScheme"] { TermTheme.schemeId = value }
        connMgr?.reload(); quickConnect?.reload(); cmdPanel?.reload()
        Log.info("应用 WebDAV 合并结果：主机 \(bundle.hosts.count) / 快捷命令 \(bundle.quickCommands.count)", "backup")
    }

    /// 当前配置打包（密码不入包，对齐老仓库）
    func currentBundle() -> BackupBundle {
        let hosts = store.hosts.map { h -> Host in var c = h; c.osId = h.osId; return c }
        let settings: [String: String] = [
            "theme": Theme.dark ? "dark" : "light",
            "colorScheme": TermTheme.schemeId,
            "fontSize": String(Int(TermTheme.fontSize)),
            "highlight": highlightEnabled ? "1" : "0",
            "syncDirWithSftp": syncDirWithSftp ? "1" : "0",
        ]
        return BackupBundle.make(hosts: hosts, quick: QuickCommandStore().commands, settings: settings)
    }

    /// 导出本地备份包（bundle v1）
    @objc func exportHosts() {
        let p = NSSavePanel(); p.nameFieldStringValue = "pixshell-backup.json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try currentBundle().encoded().write(to: url)
            Log.info("导出备份包 → \(url.path)", "backup")
            alert("导出完成", url.path)
        } catch { alert("导出失败", error.localizedDescription) }
    }

    /// WebDAV：配置 + 上传 / 下载
    @objc func webdavConfigure() {
        let cur = WebDAVBackup.load()
        let a = NSAlert.pix(); a.messageText = "WebDAV 备份"
        a.informativeText = "填写完整文件 URL 与应用密码（如坚果云 https://dav.jianguoyun.com/dav/pixshell/backup.json）"
        a.addButton(withTitle: "保存"); a.addButton(withTitle: "取消")
        let url = NSTextField(string: cur?.url ?? "")
        let user = NSTextField(string: cur?.username ?? "")
        let pass = NSSecureTextField(string: cur?.password ?? "")
        let interval = NSPopUpButton()
        let intervalValues: [TimeInterval] = [60, 300, 900, 1800]
        interval.addItems(withTitles: ["1 分钟", "5 分钟", "15 分钟", "30 分钟"])
        let currentInterval = webdavSync.interval
        interval.selectItem(at: intervalValues.enumerated().min(by: {
            abs($0.element - currentInterval) < abs($1.element - currentInterval)
        })?.offset ?? 1)
        for f in [url, user, pass] as [NSTextField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        let grid = NSGridView(numberOfColumns: 2, rows: 0); grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.addRow(with: [NSTextField(labelWithString: "URL"), url])
        grid.addRow(with: [NSTextField(labelWithString: "用户名"), user])
        grid.addRow(with: [NSTextField(labelWithString: "应用密码"), pass])
        grid.addRow(with: [NSTextField(labelWithString: "自动检查"), interval])
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 132)
        a.accessoryView = grid
        guard a.runModal() == .alertFirstButtonReturn else { return }
        WebDAVBackup.save(.init(url: url.stringValue.trimmingCharacters(in: .whitespaces),
                                username: user.stringValue, password: pass.stringValue))
        UserDefaults.standard.set(intervalValues[max(0, interval.indexOfSelectedItem)],
                                  forKey: WebDAVSyncCoordinator.intervalKey)
        if backupEnabled.contains("webdav") {
            webdavSync.enabled = true
            webdavSync.sync(reason: "配置更新")
        }
        backupPanel?.refreshConfigurationState()
        setStatus(backupEnabled.contains("webdav")
                  ? "WebDAV 配置已保存，双向同步已启用"
                  : "WebDAV 配置已保存；在备份选项中启用后自动同步")
    }
    @objc func webdavPush() {
        guard let c = WebDAVBackup.load(), !c.url.isEmpty else { webdavConfigure(); return }
        WebDAVBackup.push(c, bundle: currentBundle()) { [weak self] err in
            if let e = err { self?.alert("上传失败", e) } else { self?.alert("上传完成", "备份已推送到 WebDAV") }
        }
    }
    @objc func webdavPull() {
        guard let c = WebDAVBackup.load(), !c.url.isEmpty else { webdavConfigure(); return }
        WebDAVBackup.pull(c) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .failure(let e): self.alert("下载失败", e.localizedDescription)
            case .success(let b):
                self.applySyncedBundle(b)
                self.alert("恢复完成", "主机 \(b.hosts.count) 台（备份时间 \(b.exportedAt)）")
            }
        }
    }

    // MARK: 查看 —— 工具（复用工具面板执行）
    /// 进程管理 / 网络监控：结果渲染成结构化表格（非纯文本）
    @objc func menuToolProcess() {
        openTools()
        guard sessions.indices.contains(current), let ssh = sessions[current].ssh else { return }
        toolsPanel.showRunning("进程管理")
        ssh.exec(ToolsPanel.cmdProcess) { [weak self] out in
            Log.info("进程管理输出 \(out.count) 字节", "tools")
            self?.toolsPanel.showProcesses(out)
        }
    }
    @objc func menuToolNetwork() {
        openTools()
        guard sessions.indices.contains(current), let ssh = sessions[current].ssh else { return }
        toolsPanel.showRunning("网络监控")
        ssh.exec(ToolsPanel.cmdNetwork) { [weak self] out in
            Log.info("网络监控输出 \(out.count) 字节", "tools")
            self?.toolsPanel.showNetwork(out)
        }
    }

    // MARK: 选项
    @objc func menuCustomAccel() {
        guard sessions.indices.contains(current) else { openConnMgr(); return }
        editHostDirect(sessions[current].host)
    }
    /// 汉堡菜单「密钥管理器」。
    /// 早期没有独立密钥管理界面时，这里退而求其次开的是连接管理器/主机编辑 ——
    /// 现在有 KeyManager 了（生成/复制公钥/用于此主机/删除），必须开它，
    /// 否则点「密钥管理器」弹出来的是连接管理器，名实不符。
    @objc func menuKeyMgr() { openKeyManager() }
    /// 汉堡菜单「主机指纹管理…」。
    @objc func menuFingerprintMgr() { openFingerprintManager() }
    // 剪切/复制/粘贴/全选：输入框（任意 NSTextField / NSTextView / field editor）聚焦时
    // 必须走系统文本动作；绝不能因菜单 target=self 把内容硬塞进终端。
    // Esc 取消：命令框走 cancelOperation → 回终端（见 AppDelegate+CommandBox）；其它输入框走 field editor 默认 cancel。
    @objc func termCut() {
        // 终端无剪切语义；仅输入框聚焦时转发系统 cut
        guard textEditingFocused() else { return }
        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
    }
    @objc func termCopy() {
        if textEditingFocused() {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            return
        }
        guard sessions.indices.contains(current) else { return }
        sessions[current].termView.copy(self)
    }
    @objc func termPaste() {
        if textEditingFocused() {
            // 优先系统粘贴（覆盖选区、保留多行）；命令框单行再做换行压平兜底
            if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return }
            _ = pasteIntoCommandBoxIfFocused()
            return
        }
        guard sessions.indices.contains(current) else { return }
        sessions[current].termView.paste(self)
    }
    @objc func termClear() {
        guard sessions.indices.contains(current) else { return }
        sessions[current].termView.feed(byteArray: ArraySlice(Array("\u{1b}[2J\u{1b}[H".utf8)))
    }

    /// 当前（主窗或 keyWindow）是否正在编辑文本：NSTextView / NSTextField / field editor。
    /// 含命令板、命令框、SFTP 重命名、各弹窗输入框。
    func textEditingFocused() -> Bool {
        let candidates: [NSResponder?] = [
            NSApp.keyWindow?.firstResponder,
            window?.firstResponder,
        ]
        for fr in candidates {
            guard let fr else { continue }
            // field editor / 多行编辑器
            if fr is NSTextView { return true }
            if fr is NSTextField { return true }
        }
        // 命令板 / 命令框显式判定（field editor 有时挂在 window 上）
        return pasteTargetIsCommandBox()
    }

    /// 当前第一响应者是否是命令板编辑器 / 底栏命令框（含其内部 field editor）。
    private func pasteTargetIsCommandBox() -> Bool {
        let wins: [NSWindow?] = [window, NSApp.keyWindow]
        for w in wins {
            guard let w, let fr = w.firstResponder else { continue }
            if let ed = cmdPanel?.editor {
                if fr === ed { return true }
                // NSTextField / NSTextView 编辑时 firstResponder 经常是内部 field editor
                if let tv = fr as? NSTextView, tv.delegate as AnyObject? === ed { return true }
                if let v = fr as? NSView, v.isDescendant(of: ed) { return true }
                if let scroll = ed.enclosingScrollView, let v = fr as? NSView, v.isDescendant(of: scroll) { return true }
            }
            if let input = cmdInput {
                if fr === input { return true }
                if let v = fr as? NSView, v.isDescendant(of: input) { return true }
                // field editor 属于 window，用 currentEditor 判断
                if let fe = input.currentEditor(), fr === fe { return true }
            }
        }
        return false
    }

    /// 命令输入聚焦时：把剪贴板文本插入命令框，返回 true 表示已处理。
    @discardableResult
    private func pasteIntoCommandBoxIfFocused() -> Bool {
        guard pasteTargetIsCommandBox() else { return false }
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        guard !clip.isEmpty else { return true }

        if let ed = cmdPanel?.editor, window.firstResponder.map({ fr -> Bool in
            if fr === ed { return true }
            if let v = fr as? NSView, let scroll = ed.enclosingScrollView { return v.isDescendant(of: scroll) || v.isDescendant(of: ed) }
            return false
        }) == true {
            // 多行粘贴：整段进编辑器（保留换行，用户可再点发送）
            if ed.shouldChangeText(in: ed.selectedRange(), replacementString: clip) {
                ed.replaceCharacters(in: ed.selectedRange(), with: clip)
                ed.didChangeText()
            } else {
                // 兜底：直接改 string + 光标到末尾
                let ns = ed.string as NSString
                let sel = ed.selectedRange()
                ed.string = ns.replacingCharacters(in: sel, with: clip)
                let loc = sel.location + (clip as NSString).length
                ed.setSelectedRange(NSRange(location: loc, length: 0))
            }
            return true
        }
        if let input = cmdInput {
            let fe = input.currentEditor()
            if window.firstResponder === input || window.firstResponder === fe {
                let ns = input.stringValue as NSString
                let sel = fe?.selectedRange ?? NSRange(location: ns.length, length: 0)
                // 单行框：换行压成空格，避免把多行命令拆飞
                let oneLine = clip.replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                input.stringValue = ns.replacingCharacters(in: sel, with: oneLine)
                let loc = sel.location + (oneLine as NSString).length
                fe?.selectedRange = NSRange(location: loc, length: 0)
                return true
            }
        }
        // firstResponder 判定没命中但命令板可见：仍优先塞进命令板（用户说的是「命令输入框」）
        if let ed = cmdPanel?.editor, cmdPanel?.isHidden == false {
            let ns = ed.string as NSString
            let sel = ed.selectedRange()
            let range = sel.length >= 0 ? sel : NSRange(location: ns.length, length: 0)
            ed.string = ns.replacingCharacters(in: range, with: clip)
            let loc = range.location + (clip as NSString).length
            ed.setSelectedRange(NSRange(location: loc, length: 0))
            window.makeFirstResponder(ed)
            return true
        }
        return false
    }

    // MARK: 代理
    @objc func openProxy() { Log.info("打开代理管理", "ui"); proxyPanel.show(); proxyPanel.superview?.addSubview(proxyPanel) }

    // MARK: 云端同步
    @objc func openBackup() {
        // 独立弹窗；尺寸约连接管理器，不再盖住主窗底栏
        backupPanel.show(enabled: backupEnabled)
    }

    // MARK: 设置（终端字号 / 主题 / 语义高亮）
    @objc func openSettings() {
        let a = NSAlert.pix()
        a.messageText = "设置"
        a.addButton(withTitle: "完成")
        a.addButton(withTitle: "取消")

        let kinds: [Theme.Kind] = [.dark, .light, .ink, .retro]
        let themeBox = NSPopUpButton(); themeBox.addItems(withTitles: kinds.map { $0.display })
        themeBox.selectItem(at: kinds.firstIndex(of: Theme.kind) ?? 0)
        let sizeField = NSTextField(string: String(Int(currentFontSize())))
        sizeField.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        let historyField = NSTextField(string: String(cmdPanel?.parameterHistoryLimit ?? 50))
        historyField.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        let hl = NSButton(checkboxWithTitle: "终端语义高亮", target: nil, action: nil)
        hl.state = highlightEnabled ? .on : .off

        // 自定义高亮/普通文字颜色：留空(=跟随主题)是默认值，改了才覆盖
        let hlWell = NSColorWell(); hlWell.color = HighlightColors.highlight ?? Theme.accent
        let plainWell = NSColorWell(); plainWell.color = HighlightColors.plain ?? Theme.text
        self.settingsHlWell = hlWell
        self.settingsPlainWell = plainWell
        for w in [hlWell, plainWell] {
            w.translatesAutoresizingMaskIntoConstraints = false
            w.widthAnchor.constraint(equalToConstant: 52).isActive = true
            w.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let resetColors = PillButton("恢复默认", style: .secondary, hPad: 10, height: 22,
                                     font: Theme.ui(11, .medium), target: self, action: #selector(resetHighlightColors))
        let hlRow = NSStackView(views: [hlWell, resetColors]); hlRow.spacing = 8; hlRow.alignment = .centerY

        // 终端配色方案（TermSchemes 32 套 + 「跟随主题」）
        let schemeBox = NSPopUpButton()
        schemeBox.addItem(withTitle: "跟随主题（内置）")
        for s in TermSchemes.all { schemeBox.addItem(withTitle: s.name) }
        if !TermTheme.schemeId.isEmpty,
           let idx = TermSchemes.all.firstIndex(where: { $0.id == TermTheme.schemeId }) {
            schemeBox.selectItem(at: idx + 1)
        }

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.addRow(with: [NSTextField(labelWithString: "主题"), themeBox])
        grid.addRow(with: [NSTextField(labelWithString: "终端配色"), schemeBox])
        grid.addRow(with: [NSTextField(labelWithString: "终端字号"), sizeField])
        grid.addRow(with: [NSTextField(labelWithString: "参数历史数量（1–500）"), historyField])
        grid.addRow(with: [NSTextField(labelWithString: "高亮文字颜色"), hlRow])
        grid.addRow(with: [NSTextField(labelWithString: "普通文字颜色"), plainWell])
        grid.addRow(with: [NSTextField(labelWithString: ""), hl])

        let hubTarget = SettingsHubActionTarget(app: self, alert: a)
        func hubButton(_ title: String, _ tag: Int) -> NSButton {
            let b = PillButton(title, style: .secondary, hPad: 10, height: 24,
                               font: Theme.ui(11), target: hubTarget, action: #selector(SettingsHubActionTarget.open(_:)))
            b.tag = tag
            return b
        }
        let connectionTools = NSStackView(views: [
            hubButton("代理服务器", 1), hubButton("密钥管理", 2), hubButton("主机指纹", 3)
        ])
        connectionTools.spacing = 6
        let serviceTools = NSStackView(views: [
            hubButton("AI 对接", 4), hubButton("备份", 5),
            hubButton("WebDAV", 6), hubButton("软件更新", 7)
        ])
        serviceTools.spacing = 6
        grid.addRow(with: [NSTextField(labelWithString: "连接与安全"), connectionTools])
        grid.addRow(with: [NSTextField(labelWithString: "集成与维护"), serviceTools])
        grid.frame = NSRect(x: 0, y: 0, width: 440, height: 280)
        a.accessoryView = grid

        a.beginSheetModal(for: window) { [weak self] resp in
            _ = hubTarget // 保持按钮 target 到 sheet 关闭
            guard let self = self else { return }
            // 仅「完成」落盘；「取消」直接丢弃
            guard resp == .alertFirstButtonReturn else { return }
            self.highlightEnabled = (hl.state == .on)
            if let n = Double(sizeField.stringValue) {
                let size = CGFloat(max(9, min(24, n)))
                TermTheme.fontSize = size
                self.setFontSize(size)
            }
            if let n = Int(historyField.stringValue) {
                self.cmdPanel?.setParameterHistoryLimit(n)
            }
            // 配色方案：0 = 跟随主题
            let si = schemeBox.indexOfSelectedItem
            TermTheme.schemeId = (si <= 0) ? "" : TermSchemes.all[si - 1].id
            Log.info("设置：配色=\(TermTheme.schemeId.isEmpty ? "跟随主题" : TermTheme.schemeId) 字号=\(Int(TermTheme.fontSize)) 高亮=\(self.highlightEnabled)", "ui")
            // 自定义文字颜色（和取色器当前值一致才写；与主题色相同视为"跟随主题"）
            HighlightColors.highlight = (hlWell.color == Theme.accent) ? nil : hlWell.color
            HighlightColors.plain = (plainWell.color == Theme.text) ? nil : plainWell.color
            for s in self.sessions { TermTheme.apply(to: s.termView, dark: Theme.dark) }
            let wantKind = kinds[max(0, themeBox.indexOfSelectedItem)]
            // 选的是浅色系的某一套 → 同时把它定为"我的浅色"，之后顶栏按钮就在它和深色之间切。
            if wantKind != .dark { Theme.lightKind = wantKind }
            if wantKind != Theme.kind { self.applyThemeKind(wantKind) }
        }
    }
    func currentFontSize() -> CGFloat {
        sessions.indices.contains(current) ? sessions[current].termView.font.pointSize : 13
    }
    func setFontSize(_ s: CGFloat) {
        for sess in sessions {
            let f = sess.termView.font
            sess.termView.font = NSFont(name: f.fontName, size: s) ?? f
        }
    }

    // MARK: 软件更新（对接 GitHub Releases：比较 + 匹配资产下载 / 打开该次发行页）
    @objc func checkUpdate() {
        setStatus("检查更新…")
        AppUpdate.check(current: "1.7.5") { [weak self] result in
            guard let self = self else { return }
            self.setStatus(result.text)
            switch result.kind {
            case .updateAvailable(let v):
                let a = NSAlert.pix()
                a.messageText = "发现新版本 \(v)"
                var info = "当前 1.7.5，来源 GitHub Releases（lyu0805/pixshell）。"
                if let name = result.assetName {
                    info += "\n匹配资产：\(name)"
                }
                a.informativeText = info
                if result.assetDownloadURL != nil {
                    a.addButton(withTitle: "下载并打开")
                }
                a.addButton(withTitle: "打开发行页")
                a.addButton(withTitle: "稍后")
                let r = a.runModal()
                if result.assetDownloadURL != nil {
                    if r == .alertFirstButtonReturn, let u = result.assetDownloadURL, let name = result.assetName {
                        self.setStatus("正在下载 \(name)…")
                        AppUpdate.downloadAsset(url: u, name: name, progress: { [weak self] s in self?.setStatus(s) }) { [weak self] dest, err in
                            if let err {
                                self?.setStatus("下载失败")
                                self?.alert("下载失败", err)
                            } else if let dest {
                                self?.setStatus("已下载 \(dest.lastPathComponent)")
                            }
                        }
                    } else if r == .alertSecondButtonReturn {
                        NSWorkspace.shared.open(result.releasePageURL ?? AppUpdate.releasesURL!)
                    }
                } else if r == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(result.releasePageURL ?? AppUpdate.releasesURL!)
                }
            case .latest:
                self.alert("已是最新", "当前 1.7.5 已是最新版本（GitHub Releases）")
            case .unknown:
                let a = NSAlert.pix()
                a.messageText = "检查更新"
                a.informativeText = "无法获取更新信息（网络或仓库不可达）。可手动打开 GitHub 发行页。"
                a.addButton(withTitle: "打开发行页"); a.addButton(withTitle: "关闭")
                if a.runModal() == .alertFirstButtonReturn, let u = AppUpdate.releasesURL {
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }

    // MARK: 帮助
    @objc func menuAbout() {
        alert("PixShell 1.7.5", "macOS 原生 SSH / SFTP 客户端\nSwift + AppKit + SwiftTerm + swift-nio-ssh\nhttps://github.com/lyu0805/pixshell")
    }
    @objc func menuRepo() {
        if let u = AppUpdate.repoURL { NSWorkspace.shared.open(u) }
    }

    // MARK: 通用
    func alert(_ title: String, _ msg: String) {
        let a = NSAlert.pix(); a.messageText = title; a.informativeText = msg
        a.addButton(withTitle: "好"); a.beginSheetModal(for: window, completionHandler: nil)
    }
}


extension AppDelegate {
    /// 恢复"跟随主题"的文字配色。
    @objc func resetHighlightColors() {
        HighlightColors.highlight = nil
        HighlightColors.plain = nil
        settingsHlWell?.color = Theme.accent
        settingsPlainWell?.color = Theme.text
        setStatus("文字颜色已恢复跟随主题")
    }
}
