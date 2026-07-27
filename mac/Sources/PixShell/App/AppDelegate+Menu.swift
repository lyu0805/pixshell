import AppKit
import SwiftTerm

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
        sessions[current].ssh?.close()
        sessions[current].connected = false
        stopMonitor(); rebuildTabs(); setStatus("已断开")
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
        for f in [url, user, pass] as [NSTextField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        let grid = NSGridView(numberOfColumns: 2, rows: 0); grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.addRow(with: [NSTextField(labelWithString: "URL"), url])
        grid.addRow(with: [NSTextField(labelWithString: "用户名"), user])
        grid.addRow(with: [NSTextField(labelWithString: "应用密码"), pass])
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        a.accessoryView = grid
        guard a.runModal() == .alertFirstButtonReturn else { return }
        WebDAVBackup.save(.init(url: url.stringValue.trimmingCharacters(in: .whitespaces),
                                username: user.stringValue, password: pass.stringValue))
        alert("已保存", "接下来可用「上传到 WebDAV / 从 WebDAV 恢复」")
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
                for h in b.hosts { self.store.upsert(h) }
                self.connMgr?.reload(); self.quickConnect?.reload()
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
    // 复制/粘贴走 SwiftTerm 自带实现（含选区处理）
    @objc func termCopy() {
        guard sessions.indices.contains(current) else { return }
        sessions[current].termView.copy(self)
    }
    @objc func termPaste() {
        guard sessions.indices.contains(current) else { return }
        sessions[current].termView.paste(self)
    }
    @objc func termClear() {
        guard sessions.indices.contains(current) else { return }
        sessions[current].termView.feed(byteArray: ArraySlice(Array("\u{1b}[2J\u{1b}[H".utf8)))
    }

    // MARK: 代理
    @objc func openProxy() { Log.info("打开代理管理", "ui"); proxyPanel.show(); proxyPanel.superview?.addSubview(proxyPanel) }

    // MARK: 云端同步
    @objc func openBackup() { backupPanel.show(enabled: backupEnabled) }

    // MARK: 设置（终端字号 / 主题 / 语义高亮）
    @objc func openSettings() {
        let a = NSAlert.pix()
        a.messageText = "设置"
        a.addButton(withTitle: "完成")

        let kinds: [Theme.Kind] = [.dark, .light, .ink, .retro]
        let themeBox = NSPopUpButton(); themeBox.addItems(withTitles: kinds.map { $0.display })
        themeBox.selectItem(at: kinds.firstIndex(of: Theme.kind) ?? 0)
        let sizeField = NSTextField(string: String(Int(currentFontSize())))
        sizeField.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
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
        grid.addRow(with: [NSTextField(labelWithString: "高亮文字颜色"), hlRow])
        grid.addRow(with: [NSTextField(labelWithString: "普通文字颜色"), plainWell])
        grid.addRow(with: [NSTextField(labelWithString: ""), hl])
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 186)
        a.accessoryView = grid

        a.beginSheetModal(for: window) { [weak self] _ in
            guard let self = self else { return }
            self.highlightEnabled = (hl.state == .on)
            if let n = Double(sizeField.stringValue) {
                let size = CGFloat(max(9, min(24, n)))
                TermTheme.fontSize = size
                self.setFontSize(size)
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

    // MARK: 软件更新（仅检查 + 打开发行页，不自动安装）
    @objc func checkUpdate() {
        setStatus("检查更新…")
        AppUpdate.check(current: "0.1.1") { [weak self] st in
            guard let self = self else { return }
            self.setStatus(st.text)
            switch st {
            case .updateAvailable(let v):
                let a = NSAlert.pix(); a.messageText = "发现新版本 \(v)"
                a.informativeText = "当前 0.1.0。是否打开发行页下载？"
                a.addButton(withTitle: "打开发行页"); a.addButton(withTitle: "稍后")
                if a.runModal() == .alertFirstButtonReturn, let u = AppUpdate.releasesURL {
                    NSWorkspace.shared.open(u)
                }
            case .latest: self.alert("已是最新", "当前 0.1.0 已是最新版本")
            case .unknown: self.alert("检查更新", "无法获取更新信息（网络或仓库不可达）")
            }
        }
    }

    // MARK: 帮助
    @objc func menuAbout() {
        alert("PixShell 0.1.0", "macOS 原生 SSH / SFTP 客户端\nSwift + AppKit + SwiftTerm + swift-nio-ssh")
    }
    @objc func menuRepo() {
        if let u = URL(string: "https://github.com/") { NSWorkspace.shared.open(u) }
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
