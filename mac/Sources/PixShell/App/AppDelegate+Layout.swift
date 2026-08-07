import AppKit
import SwiftTerm

/// 可拖动窗口的顶栏（点空白处拖窗）。
final class DragBar: NSView { override var mouseDownCanMoveWindow: Bool { true } }

// 五区布局（自绘复刻老仓库）：自定义标题栏(红绿灯+图标+胶囊tab) / 侧栏 | 终端 / 底部坞 / 命令栏 / 状态栏。
extension AppDelegate {
    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "PixShell"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // GPU 优先 + 可回落：仅在非软件兜底路径开 layer 异步绘制；
        // 回落路径仍 wantsLayer（AppKit 控件需要），但不强开 drawsAsynchronously。
        window.contentView?.wantsLayer = true
        if !AppDelegate._gpuUsingFallback {
            window.contentView?.layerContentsRedrawPolicy = .onSetNeedsDisplay
            window.contentView?.layer?.drawsAsynchronously = true
        }
        window.setFrameAutosaveName("PixShell-Main-v4")  // 恢复 800×600 默认；换名避免 v3 的 1024 autosave 覆盖
        window.center()
        installContent()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 构建/重建整个内容视图（供主题切换整窗重绘复用）。会重建所有区域与弹层，
    // 然后把当前会话的终端重新挂回新 termContainer。
    func installContent() {
        let rect = window.contentLayoutRect
        window.isOpaque = false
        window.backgroundColor = .clear

        // ArrowRootView：给整窗铺箭头光标兜底（见 UI/CursorFix.swift —— SwiftTerm 会把指针钉成 I 型）
        // wantsLayer 常开；drawsAsynchronously 仅 GPU 优先路径（软件兜底时关掉，防花屏）
        let root = ArrowRootView(frame: rect)
        root.wantsLayer = true
        if !AppDelegate._gpuUsingFallback {
            root.layerContentsRedrawPolicy = .onSetNeedsDisplay
            root.layer?.drawsAsynchronously = true
        }
        
        // 0. 国画底图层 (仅在水墨主题下可见)
        let bgImgView = NSImageView(frame: rect)
        bgImgView.imageScaling = .scaleProportionallyUpOrDown
        bgImgView.autoresizingMask = [.width, .height]
        if TermTheme.schemeId == "ink_wash" {
            var bgImg: NSImage? = Bundle.module.image(forResource: NSImage.Name("ink_wash_bg"))
            if bgImg == nil, let url = Bundle.module.url(forResource: "ink_wash_bg", withExtension: "jpg", subdirectory: "Assets.xcassets/ink_wash_bg.imageset") {
                bgImg = NSImage(contentsOf: url)
            }
            bgImgView.image = bgImg
            bgImgView.alphaValue = 0.85 // 留出透气感
        } else {
            bgImgView.isHidden = true
        }
        root.addSubview(bgImgView)
        
        // 1. 沉浸式毛玻璃视效底层 (Ambient Blur)
        let blur = NSVisualEffectView(frame: rect)
        blur.material = .windowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        
        // 针对水墨主题，降低 blur 的遮挡感以透出山水画
        if TermTheme.schemeId == "ink_wash" {
            blur.blendingMode = .withinWindow
            blur.material = .hudWindow
            blur.alphaValue = 0.4
        }
        root.addSubview(blur)
        
        // 2. 覆盖一层带透明度的主题底色，确保终端文字对比度
        let tintLayer = CALayer()
        // 水墨主题下降低底色浓度，让底图透出来，呈现宣纸质感
        let tintAlpha: CGFloat = TermTheme.schemeId == "ink_wash" ? 0.3 : 0.6
        tintLayer.backgroundColor = Theme.bg.withAlphaComponent(tintAlpha).cgColor
        tintLayer.frame = rect
        tintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        blur.wantsLayer = true
        blur.layer?.addSublayer(tintLayer)
        
        root.autoresizingMask = [.width, .height]

        let topBar = buildTopBar()
        // 主行：侧栏容器(宽度约束控制，可收到 0) | 拖动分隔条 | 工作区。
        // 不用 NSSplitView：autolayout 下 setPosition(0) 会被侧栏内部约束顶回去，导致"收不起"。
        mainRow = NSView(); mainRow.translatesAutoresizingMaskIntoConstraints = false
        sideWrap = NSView(); sideWrap.translatesAutoresizingMaskIntoConstraints = false
        sideWrap.wantsLayer = true; sideWrap.layer?.masksToBounds = true   // 收起时裁掉内容
        let side = buildSidebar(); side.translatesAutoresizingMaskIntoConstraints = false
        sideWrap.addSubview(side)
        let divider = buildSideDivider()
        let workspace = buildWorkspace()   // 工作区内部：终端 / 命令栏 / 文件命令坞
        mainRow.addSubview(sideWrap); mainRow.addSubview(divider); mainRow.addSubview(workspace)
        sideWidthC = sideWrap.widthAnchor.constraint(equalToConstant: sideCollapsed ? 0 : sidebarWidth)
        monitorWidthC = side.widthAnchor.constraint(equalToConstant: sidebarWidth)  // 内容保持定宽，收起时被裁掉
        NSLayoutConstraint.activate([
            sideWrap.topAnchor.constraint(equalTo: mainRow.topAnchor),
            sideWrap.bottomAnchor.constraint(equalTo: mainRow.bottomAnchor),
            sideWrap.leadingAnchor.constraint(equalTo: mainRow.leadingAnchor),
            sideWidthC,
            side.topAnchor.constraint(equalTo: sideWrap.topAnchor),
            side.bottomAnchor.constraint(equalTo: sideWrap.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: sideWrap.leadingAnchor),
            monitorWidthC,
            divider.leadingAnchor.constraint(equalTo: sideWrap.trailingAnchor),
            divider.topAnchor.constraint(equalTo: mainRow.topAnchor),
            divider.bottomAnchor.constraint(equalTo: mainRow.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),   // 视觉 1pt 细线（拖拽命中区靠光标热区，见 DividerView）
            workspace.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            workspace.trailingAnchor.constraint(equalTo: mainRow.trailingAnchor),
            workspace.topAnchor.constraint(equalTo: mainRow.topAnchor),
            workspace.bottomAnchor.constraint(equalTo: mainRow.bottomAnchor),
        ])
        let statusBar = buildStatusBar()

        for v in [topBar, mainRow!, statusBar] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // 顶栏高度不能写死：标签折到第二行时要跟着长高，否则第二行被裁、压到终端上。
            // 用 >= 保底 38（单行时的高度），实际高度由 tabBar 折行后的内容撑开。
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            mainRow.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            mainRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: mainRow.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.statusH),
        ])
        // 连接管理器弹窗（弹出式窗口，非遮罩）
        connMgr = ConnManager()
        connMgr.hostsProvider = { [weak self] in self?.store.hosts ?? [] }
        connMgr.onConnect = { [weak self] h in self?.openSession(to: h) }
        connMgr.onNew = { [weak self] in self?.addHost() }
        connMgr.onEdit = { [weak self] h in self?.editHostDirect(h) }
        connMgr.onDelete = { [weak self] h in self?.store.delete(h.id); Keychain.delete(h.id) }
        // 右键「复制主机」：同配置另存一份（密码不复制，需重新输入）
        connMgr.onDuplicate = { [weak self] h in
            guard let self = self else { return }
            var copy = h; copy.id = UUID().uuidString; copy.name = h.display + " 副本"
            self.store.upsert(copy); self.quickConnect?.reload()
            Log.info("复制主机 \(h.display) → \(copy.name)", "hosts")
        }
        // 分组：新建（把当前无分组的主机归入）/ 重命名 / 删除（成员移回「默认」）
        connMgr.onCreateGroup = { [weak self] name in
            guard let self = self else { return }
            Log.info("新建分组 \(name)", "hosts")
            for var h in self.store.hosts where h.group.isEmpty {
                h.group = name; self.store.upsert(h)
            }
            self.quickConnect?.reload()
        }
        connMgr.onRenameGroup = { [weak self] old, new in
            guard let self = self else { return }
            Log.info("分组重命名 \(old) → \(new)", "hosts")
            for var h in self.store.hosts where (h.group.isEmpty ? "默认" : h.group) == old {
                h.group = new; self.store.upsert(h)
            }
            self.quickConnect?.reload()
        }
        connMgr.onDeleteGroup = { [weak self] name in
            guard let self = self else { return }
            Log.info("删除分组 \(name)（成员移回默认）", "hosts")
            for var h in self.store.hosts where (h.group.isEmpty ? "默认" : h.group) == name {
                h.group = ""; self.store.upsert(h)
            }
            self.quickConnect?.reload()
        }

        // 系统信息页（独立弹出窗口，不再贴满主窗）
        sysInfo = SysInfoPanel(frame: .zero)
        sysInfo.onClose = { [weak self] in self?.sysInfoWindow?.orderOut(nil) }
        sysInfo.onRefresh = { [weak self] in self?.openSysInfo() }
        monitor.onSysInfo = { [weak self] in self?.openSysInfo() }

        // 密钥管理（独立弹出窗口，对齐 ConnManager）
        keyManager = KeyManager()
        keyManager.onUseKey = { [weak self] path in
            guard let self = self else { return }
            // 「用于此主机」：写回当前会话主机的 keyPath，下次连接就走私钥
            guard self.sessions.indices.contains(self.current) else { self.setStatus("已选密钥 \(path)"); return }
            var h = self.sessions[self.current].host
            h.keyPath = path
            self.store.upsert(h)
            self.sessions[self.current].host = h
            self.setStatus("已把密钥设为 \(h.display) 的登录私钥")
            self.quickConnect?.reload(); self.connMgr?.reload()
        }

        // 主机指纹管理（独立弹出窗口，对齐 KeyManager）
        fingerprintManager = FingerprintManager()

        // AI 工具 SSH 桥接注册（独立弹出窗口，对齐 KeyManager）
        aiSshBridgeManager = AiSshBridgeManager()
        aiSshBridgeManager.bridgePortProvider = { [weak self] in self?.agentBridge?.port }
        aiSshBridgeManager.onStatus = { [weak self] msg in self?.setStatus(msg) }

        // 工具面板（宫格图标）：主机下拉 + 工具 + 下载目录（对齐老仓库 #toolsPanel）
        toolsPanel = ToolsPanel(frame: .zero); toolsPanel.isHidden = true
        toolsPanel.sessionsProvider = { [weak self] in
            guard let self = self else { return [] }
            return self.sessions.enumerated().map { (i, s) in (title: "\(s.host.display) (\(s.host.host))", active: i == self.current) }
        }
        toolsPanel.onSelectSession = { [weak self] i in self?.selectSession(i) }
        toolsPanel.onExec = { [weak self] cmd, done in
            guard let self = self, self.sessions.indices.contains(self.current), let ssh = self.sessions[self.current].ssh else { done(""); return }
            ssh.exec(cmd) { done($0) }
        }
        toolsPanel.onPickDownloadDir = { [weak self] in self?.pickDownloadDir() }
        toolsPanel.onOpenDownloadDir = { [weak self] in
            guard let self = self else { return }
            NSWorkspace.shared.open(self.downloadDir)
        }
        // 结束进程（工具面板进程表）：发 SIGTERM 后自动刷新列表
        toolsPanel.onKill = { [weak self] pid, sig in
            guard let self = self, self.sessions.indices.contains(self.current),
                  let ssh = self.sessions[self.current].ssh else { return }
            Log.info("结束进程 PID \(pid) 信号 \(sig)", "tools")
            ssh.exec("kill -\(sig) \(pid) 2>&1") { out in
                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Log.warn("kill 输出: \(out)", "tools")
                }
                ssh.exec(ToolsPanel.cmdProcess) { list in self.toolsPanel.showProcesses(list) }
            }
        }
        toolsPanel.onClose = { [weak self] in self?.toolsPanel.isHidden = true }
        toolsPanel.setDownloadPath(downloadDir.path)
        root.addSubview(toolsPanel)
        NSLayoutConstraint.activate([
            toolsPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            toolsPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolsPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolsPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // 内置文本编辑器（SFTP 双击文件 → 打开；保存 → 写回远端）
        editorPanel = EditorPanel(frame: .zero)
        editorPanel.onClose = { [weak self] in self?.editorWindow?.orderOut(nil) }
        editorPanel.onSave = { [weak self] text, done in
            guard let self = self else { done("应用已退出"); return }
            let path = self.editingRemotePath
            Log.info("保存远端文件 \(path)（\(text.count) 字符）", "editor")
            guard let sp = self.sftpPanel else { done("SFTP 未就绪"); return }
            sp.saveRemoteFile(path, text: text) { err in
                if let e = err {
                    Log.error("保存失败 \(path): \(e)", "editor")
                    done(e)          // 由编辑器就地显示，不再弹模态框盖住内容
                } else {
                    Log.info("保存成功 \(path)", "editor")
                    self.setStatus("已保存 \((path as NSString).lastPathComponent)")
                    done(nil)
                }
            }
        }
        sftpPanel.onOpenFile = { [weak self] path, text in
            guard let self = self else { return }
            Log.info("打开远端文件 \(path)（\(text.count) 字符）", "editor")
            self.editingRemotePath = path
            self.editorPanel.open(path: path, text: text)
            self.showEditorWindow(title: path)
        }
        // 代理管理面板（菜单 选项 → 代理服务器）
        proxyPanel = ProxyPanel(frame: .zero); proxyPanel.isHidden = true
        proxyPanel.onClose = { [weak self] in self?.proxyPanel.isHidden = true }
        root.addSubview(proxyPanel)
        NSLayoutConstraint.activate([
            proxyPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            proxyPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            proxyPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            proxyPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // 备份选项弹窗（独立 NSWindow，对齐连接管理器尺寸；不再嵌主窗全屏遮罩）
        backupPanel = BackupPanel()
        backupPanel.onSave = { [weak self] set in self?.backupEnabled = set }
        backupPanel.onExport = { [weak self] in self?.exportHosts() }
        backupPanel.onImport = { [weak self] in self?.importHosts() }

        // 侧栏折叠后的「⟩ 侧栏」竖条（点击展开）
        sidebarEdge = buildSidebarEdge(); sidebarEdge.isHidden = !sideCollapsed
        root.addSubview(sidebarEdge)
        NSLayoutConstraint.activate([
            sidebarEdge.centerYAnchor.constraint(equalTo: mainRow.centerYAnchor),
            sidebarEdge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            sidebarEdge.widthAnchor.constraint(equalToConstant: 22),
            sidebarEdge.heightAnchor.constraint(equalToConstant: 96),
        ])

        window.contentView = root
        setSidebarCollapsed(sideCollapsed)   // 侧栏=监控仪表盘，按当前折叠态应用

        updateCliStatus()   // 状态栏 CLI 三态按真实桥状态显示（不写死）

        // 重建后把已有会话的终端重新挂回 + 恢复 tab / 监控；无会话则显示落地页。
        if sessions.indices.contains(current) {
            selectSession(current)
        } else {
            rebuildTabs(); showQuickConnect()
        }
    }

    // MARK: 顶栏（红绿灯留位 + 图标按钮 + 胶囊会话 tab + 右侧图标）
    func buildTopBar() -> NSView {
        let bar = DragBar(); bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.bg.cgColor

        // 左：红绿灯留位(78) + 侧栏折叠 + logo 图标按钮(连接管理器) + 新建
        let sideBtn = IconButton(symbol: "sidebar.left", tooltip: "折叠/展开侧栏", target: self, action: #selector(toggleSidebar))
        let logoBtn = IconButton(symbol: "display", tooltip: "连接管理器", target: self, action: #selector(openConnMgr))
        let addBtn = IconButton(symbol: "plus.app", tooltip: "新建连接", target: self, action: #selector(addHost))

        // 会话 tab 条
        // 标签栏用 FlowView：一行放不下就折到第二行，而不是把标签越挤越窄到看不清字。
        // 超过 2 行的部分靠外层滚动。
        tabBar = FlowView()
        tabBar.hGap = 6
        tabBar.vGap = 4
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        newTabBtn = IconButton(symbol: "plus", tooltip: "快速连接", target: self, action: #selector(newQuickTab))

        // 右：月亮(主题) / 网格 / 汉堡
        let moon = IconButton(symbol: darkTheme ? "moon.fill" : "sun.max.fill", tooltip: "主题", target: self, action: #selector(toggleTheme))
        // 宫格 = 工具面板（路由追踪/进程管理/网络监控/速度测试 + 下载目录），非快速连接
        let grid = IconButton(symbol: "square.grid.2x2", tooltip: "工具", target: self, action: #selector(openTools))
        menuBtn = IconButton(symbol: "line.3.horizontal", tooltip: "菜单", target: self, action: #selector(openMenu))
        let menu = menuBtn!

        let left = NSStackView(views: [sideBtn, logoBtn, addBtn]); left.spacing = 6
        let right = NSStackView(views: [moon, grid, menu]); right.spacing = 6
        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(left); bar.addSubview(tabBar); bar.addSubview(newTabBtn); bar.addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 78), // 红绿灯留位
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tabBar.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 8),
            // 折行后 tabBar 会变高，所以钉上下边而不是居中，让顶栏跟着长高
            tabBar.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            tabBar.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            // FlowView 与 NSStackView 相反：它要**先有确定宽度**才能算折行。
            // 所以这里必须是等式（用 <= 的话宽度不确定，会被压成 0 宽 → 一个标签都画不出来）。
            tabBar.trailingAnchor.constraint(equalTo: newTabBtn.leadingAnchor, constant: -6),
            // ＋ 按钮钉在右侧图标组左边（不再跟着标签跑，否则折行后位置会乱）
            newTabBtn.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -10),
            newTabBtn.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    // MARK: 侧栏 = 服务器监控仪表盘（对齐老仓库）
    func buildSidebar() -> NSView {
        monitor = MonitorSidebar(frame: .zero)
        monitor.onCopyIP = { [weak self] in
            guard let self = self, self.sessions.indices.contains(self.current) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.sessions[self.current].host.host, forType: .string)
        }
        // 状态行按钮：已连接 → 手动断开；已断开 → 重连当前主机；没有会话 → 打开连接管理器选主机。
        monitor.onToggleConnection = { [weak self] in
            guard let self = self else { return }
            guard self.sessions.indices.contains(self.current) else { self.connMgr?.show(); return }
            if self.sessions[self.current].connected { self.menuDisconnect() } else { self.menuReconnect() }
        }
        return monitor
    }

    static let sidebarRail: CGFloat = 26   // 折叠后保留的窄轨（放「⟩ 侧栏」竖条，避免压住终端）

    @objc func toggleSidebar() { setSidebarCollapsed(!sideCollapsed) }
    func setSidebarCollapsed(_ collapsed: Bool) {
        Log.debug("侧栏折叠=\(collapsed)", "ui")
        sideCollapsed = collapsed
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.allowsImplicitAnimation = true
            // 带有轻微回弹的阻尼曲线 (Spring-like)
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.2, 0.3, 1.0)
            
            self.sideWidthC?.animator().constant = collapsed ? Self.sidebarRail : self.sidebarWidth
            // 为了流畅过渡，不要直接隐藏整个 View，而是通过 alpha 值进行物理溶解
            self.sideWrap?.animator().alphaValue = collapsed ? 0.0 : 1.0
            self.sidebarEdge?.animator().alphaValue = collapsed ? 1.0 : 0.0
            
            // 当动画结束时，再将 isHidden 置位以停止响应事件
        } completionHandler: {
            self.sideWrap?.isHidden = collapsed
            self.sidebarEdge?.isHidden = !collapsed
        }
        
        // 提前显示以保证 alpha 动画可见
        if !collapsed {
            self.sideWrap?.isHidden = false
        } else {
            self.sidebarEdge?.isHidden = false
        }
    }

    // 侧栏拖动分隔条：拖动改宽度；拖到 <90 自动收起。
    func buildSideDivider() -> NSView {
        let d = DividerView(); d.translatesAutoresizingMaskIntoConstraints = false
        d.wantsLayer = true; d.layer?.backgroundColor = Theme.border.cgColor
        d.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragSidebar(_:))))
        return d
    }
    @objc func dragSidebar(_ g: NSPanGestureRecognizer) {
        guard let row = mainRow else { return }
        let x = g.location(in: row).x
        if x < 90 { setSidebarCollapsed(true); return }
        if sideCollapsed { setSidebarCollapsed(false) }
        sidebarWidth = min(max(x, 180), 420)
        sideWidthC?.constant = sidebarWidth
        monitorWidthC?.constant = sidebarWidth
    }
    // 连上/断开时统一展开/收起 chrome（对齐老仓库 applyChromeForTab）
    func expandChrome() { setSidebarCollapsed(false); setBottomCollapsed(false) }
    func collapseChrome() { setSidebarCollapsed(true); setBottomCollapsed(true) }

    // 侧栏折叠竖条「⟩ 侧栏」
    func buildSidebarEdge() -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.rounded(Theme.radiusSm, bg: Theme.bg2, border: Theme.border)
        let lab = NSTextField(labelWithString: "⟩\n侧\n栏")
        lab.font = Theme.ui(11, .medium); lab.textColor = Theme.accent
        lab.alignment = .center; lab.maximumNumberOfLines = 0
        lab.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(lab)
        NSLayoutConstraint.activate([
            lab.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            lab.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        v.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(expandSidebarFromEdge)))
        return v
    }
    @objc func expandSidebarFromEdge() { setSidebarCollapsed(false) }

    // MARK: 工作区：终端(上，占满) + 命令栏 + 文件/命令坞(可整体收起)
    // 不用竖向 NSSplitView：坞体高度由约束直接控制，折叠=高度 0（真正消失，终端补位）。
    func buildWorkspace() -> NSView {
        let container = NSView(); container.translatesAutoresizingMaskIntoConstraints = false

        let center = NSView(); center.wantsLayer = true
        center.layer?.backgroundColor = Theme.term.cgColor
        center.translatesAutoresizingMaskIntoConstraints = false
        termContainer = NSView(); termContainer.translatesAutoresizingMaskIntoConstraints = false
        placeholder = NSTextField(labelWithString: "PixShell · 点击左上角 Logo 打开连接管理器，或双击快速连接")
        placeholder.textColor = Theme.muted; placeholder.font = Theme.ui(13)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        center.addSubview(termContainer); termContainer.addSubview(placeholder)
        // 快速连接落地页：覆盖在终端容器之上，无活动会话时显示。
        quickConnect = QuickConnect(frame: .zero); quickConnect.translatesAutoresizingMaskIntoConstraints = false
        quickConnect.hostsProvider = { [weak self] in self?.store.recentHosts ?? [] }
        quickConnect.hasPassword = { Keychain.has($0.id) }
        quickConnect.onConnect = { [weak self] h in self?.openSession(to: h) }
        quickConnect.onEdit = { [weak self] h in self?.editHostDirect(h) }
        quickConnect.onNew = { [weak self] in self?.addHost() }
        quickConnect.onClear = { [weak self] in self?.store.clearRecents() }
        // logo → 应用内本机终端（LocalSession），不弹 Terminal.app
        quickConnect.onLocalTerminal = { [weak self] in self?.openLocalTerminal() }
        // 有会话时从 QC 返回：一键回到当前标签（对齐 Win PreviewMouseLeftButtonDown 收起 QC）
        quickConnect.onBack = { [weak self] in
            guard let self = self else { return }
            if self.sessions.indices.contains(self.current) {
                self.selectSession(self.current)
            } else if !self.sessions.isEmpty {
                self.selectSession(0)
            } else {
                self.quickConnect?.isHidden = true
            }
        }
        center.addSubview(quickConnect)
        NSLayoutConstraint.activate([
            termContainer.topAnchor.constraint(equalTo: center.topAnchor),
            termContainer.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            termContainer.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            termContainer.bottomAnchor.constraint(equalTo: center.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: termContainer.centerXAnchor),
            placeholder.topAnchor.constraint(equalTo: termContainer.topAnchor, constant: 40),
            quickConnect.topAnchor.constraint(equalTo: center.topAnchor),
            quickConnect.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            quickConnect.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            quickConnect.bottomAnchor.constraint(equalTo: center.bottomAnchor),
        ])
        placeholder.isHidden = true   // 落地页取代占位文案

        // 命令栏（在 文件/命令 之上，始终可见，不随坞折叠消失）+ 拖拽条 + 文件/命令坞（可折叠、可拖高）
        // 截图 P0：mac 缺「命令 / 输入 / 历史 / 发送」这一行 —— 之前误并到命令板，落地页/会话页都看不见。
        let cmdBar = buildCommandBar()
        let dockResizer = buildDockResizer()
        let dock = buildBottomDock()
        dock.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(center)
        container.addSubview(cmdBar)
        container.addSubview(dockResizer)
        container.addSubview(dock)
        let centerMin = center.heightAnchor.constraint(greaterThanOrEqualToConstant: 120); centerMin.priority = .defaultHigh
        NSLayoutConstraint.activate([
            center.topAnchor.constraint(equalTo: container.topAnchor),
            center.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            center.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            centerMin,
            cmdBar.topAnchor.constraint(equalTo: center.bottomAnchor),
            cmdBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cmdBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dockResizer.topAnchor.constraint(equalTo: cmdBar.bottomAnchor),
            dockResizer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dockResizer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dockResizer.heightAnchor.constraint(equalToConstant: 4),  // 可拖命中区 4pt（原 1pt 几乎点不到）
            dock.topAnchor.constraint(equalTo: dockResizer.bottomAnchor),
            dock.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// 命令栏：`命令` 标签 + 单行输入 + 历史 + 发送 + 坞折叠开关。对齐 Win MainWindow 命令栏。
    func buildCommandBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.bg.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        let lab = NSTextField(labelWithString: "命令")
        lab.font = Theme.ui(12, .medium); lab.textColor = Theme.muted
        lab.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField()
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = Theme.bg2
        field.textColor = Theme.text
        field.font = Theme.mono(12)
        field.placeholderString = "输入命令，Enter 发送；↑↓ 历史；Tab 补全路径"
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(sendCommandBox)
        field.translatesAutoresizingMaskIntoConstraints = false
        cmdInput = field

        let histBtn = PillButton("历史", style: .secondary, hPad: 12, height: 26,
                                 target: self, action: #selector(showCommandHistory(_:)))
        let sendBtn = PillButton("发送", style: .primary, hPad: 14, height: 26,
                                 target: self, action: #selector(sendCommandBox))
        dockToggleBtn = IconButton(symbol: dockCollapsed ? "chevron.up" : "chevron.down",
                                   tooltip: "隐藏/显示文件/命令",
                                   target: self, action: #selector(toggleDock))

        let right = NSStackView(views: [histBtn, sendBtn, dockToggleBtn!])
        right.orientation = .horizontal; right.spacing = 8; right.alignment = .centerY
        right.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(lab); bar.addSubview(field); bar.addSubview(right)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 40),
            lab.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            lab.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: lab.trailingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 28),
            right.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        // 顶部分隔线
        let sep = NSView(); sep.wantsLayer = true; sep.layer?.backgroundColor = Theme.border.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(sep)
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: bar.topAnchor),
            sep.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
        return bar
    }

    // MARK: 底部坞：单行 [文件][命令] + 文件操作图标(与 tab 平行) / 面板体；整坞可折叠到 0
    func buildBottomDock() -> NSView {
        let dock = NSView(); dock.wantsLayer = true
        dock.layer?.backgroundColor = Theme.bg.cgColor
        dock.layer?.masksToBounds = true   // 折叠到 0 时裁掉内容
        dockView = dock

        // 面板体（先建，供文件操作按钮引用 sftpPanel）
        bottomBody = NSView(); bottomBody.translatesAutoresizingMaskIntoConstraints = false
        sftpPanel = SFTPPanel(frame: .zero); sftpPanel.translatesAutoresizingMaskIntoConstraints = false
        cmdPanel = CommandPanel(frame: .zero); cmdPanel.translatesAutoresizingMaskIntoConstraints = false
        cmdPanel.sessionsProvider = { [weak self] in
            (self?.sessions ?? []).map { (title: $0.title, connected: $0.connected) }
        }
        // 命令板发送：支持 当前会话 / 所有已连接会话 / 指定会话（对齐老仓库 #cmdTarget）
        cmdPanel.onSendTo = { [weak self] text, target in
            guard let self = self else { return }
            let bytes = Array(text.utf8)
            switch target {
            case .current:
                guard self.sessions.indices.contains(self.current) else { return }
                self.sessions[self.current].ssh?.send(bytes)
            case .allConnected:
                for s in self.sessions where s.connected { s.ssh?.send(bytes) }
            case .session(let i):
                guard self.sessions.indices.contains(i) else { return }
                self.sessions[i].ssh?.send(bytes)
            }
            self.cmdHistory.push(text)
        }
        cmdPanel.onShowHistory = { [weak self] v in self?.showCommandHistory(v) }
        // 命令板编辑器 ↑↓ 翻历史：复用 AppDelegate 的 cmdHistory（older/newer）
        cmdPanel.onHistoryNav = { [weak self] current, up in
            guard let self = self else { return current }
            return up ? self.cmdHistory.older(current: current) : self.cmdHistory.newer()
        }
        sftpPanel.onPathChange = { [weak self] p in self?.dockPathLabel?.stringValue = p }
        // P0：SFTP 独立于终端，禁止 onUserNavigate → 终端 cd 联动
        sftpPanel.onUserNavigate = nil
        sftpPanel.proxyProvider = { [weak self] pid in
            guard let self = self, !pid.isEmpty else { return nil }
            return self.proxyStore.list().first { $0.id == pid }
        }
        sftpPanel.execRunner = { [weak self] cmd, done in                            // 智能打包传输要在远端跑 tar
            guard let self = self, self.sessions.indices.contains(self.current),
                  let ssh = self.sessions[self.current].ssh else { done(""); return }
            ssh.exec(cmd) { done($0) }
        }
        sftpPanel.onInsertToCommand = { [weak self] path in                          // 右键「插入命令框」→ 命令板
            guard let self = self, let panel = self.cmdPanel else { return }
            let cur = panel.editor.string
            if cur.isEmpty {
                panel.editor.string = path
            } else if cur.hasSuffix(" ") || cur.hasSuffix("\n") {
                panel.editor.string = cur + path
            } else {
                panel.editor.string = cur + " " + path
            }
            self.window.makeFirstResponder(panel.editor)
            self.showCmds()
        }
        bottomBody.addSubview(sftpPanel); bottomBody.addSubview(cmdPanel)
        for p: NSView in [sftpPanel, cmdPanel] {
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: bottomBody.topAnchor), p.leadingAnchor.constraint(equalTo: bottomBody.leadingAnchor),
                p.trailingAnchor.constraint(equalTo: bottomBody.trailingAnchor), p.bottomAnchor.constraint(equalTo: bottomBody.bottomAnchor),
            ])
        }

        // tab 行：[文件][命令]  + 文件操作图标组（与 tab 同一行；仅「文件」tab 显示）
        filesTab = PillButton("文件", style: .secondary, hPad: 9, height: 20, font: Theme.ui(11, .medium), target: self, action: #selector(showFiles))
        cmdsTab = PillButton("命令", style: .secondary, hPad: 9, height: 20, font: Theme.ui(11, .medium), target: self, action: #selector(showCmds))
        dockPathLabel = NSTextField(labelWithString: "/"); dockPathLabel.font = Theme.mono(10)
        dockPathLabel.textColor = Theme.muted; dockPathLabel.lineBreakMode = .byTruncatingHead
        dockPathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dockPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sp = sftpPanel!
        let backBtn = IconButton(symbol: "chevron.left", tooltip: "上级目录", size: NSSize(width: 26, height: 20), target: sp, action: #selector(SFTPPanel.goUp))
        let refreshBtn = IconButton(symbol: "arrow.clockwise", tooltip: "刷新", size: NSSize(width: 26, height: 20), target: sp, action: #selector(SFTPPanel.refresh))
        let downBtn = IconButton(symbol: "square.and.arrow.down", tooltip: "下载到本地", size: NSSize(width: 26, height: 20), target: sp, action: #selector(SFTPPanel.download))
        let upBtn = IconButton(symbol: "square.and.arrow.up", tooltip: "上传到远端", size: NSSize(width: 26, height: 20), target: sp, action: #selector(SFTPPanel.upload))
        let mkdirBtn = IconButton(symbol: "folder.badge.plus", tooltip: "新建目录", size: NSSize(width: 26, height: 20), target: sp, action: #selector(SFTPPanel.mkdir))
        let delBtn = IconButton(symbol: "trash", tooltip: "删除", size: NSSize(width: 26, height: 20), target: sp, action: #selector(SFTPPanel.del)); delBtn.contentTintColor = Theme.err
        let hideBtn = IconButton(symbol: "sidebar.left", tooltip: "显示/隐藏本地", size: NSSize(width: 26, height: 20), target: sp, action: #selector(SFTPPanel.toggleLocal))
        let flex = NSView(); flex.setContentHuggingPriority(.init(1), for: .horizontal)
        // 机器人 = 与本机 CLI agent 对话（切换左栏 文件/对话）。自绘模板图，跟随主题着色。
        chatBtn = IconButton(symbol: "bubble.left", tooltip: "与本机 agent 对话",
                             size: NSSize(width: 26, height: 20), target: sp, action: #selector(SFTPPanel.toggleChat))
        chatBtn.image = RobotIcon.image(size: 15)
        chatBtn.imageScaling = .scaleNone
        fileOps = NSStackView(views: [backBtn, dockPathLabel, flex, chatBtn, refreshBtn, downBtn, upBtn, mkdirBtn, delBtn, hideBtn])
        fileOps.orientation = .horizontal; fileOps.spacing = 6; fileOps.alignment = .centerY
        fileOps.setContentHuggingPriority(.init(1), for: .horizontal)   // 填满 tab 行剩余宽度

        dockToggleBtn = IconButton(symbol: dockCollapsed ? "chevron.up" : "chevron.down", tooltip: "隐藏/显示文件/命令", target: self, action: #selector(toggleDock))
        let tabs = NSStackView(views: [filesTab, cmdsTab, fileOps, dockToggleBtn!]); tabs.orientation = .horizontal; tabs.spacing = 8; tabs.alignment = .centerY
        tabs.translatesAutoresizingMaskIntoConstraints = false

        dock.addSubview(tabs); dock.addSubview(bottomBody)
        dockHeightC = dock.heightAnchor.constraint(equalToConstant: dockCollapsed ? 0 : dockHeight)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: dock.topAnchor, constant: 4),
            tabs.leadingAnchor.constraint(equalTo: dock.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: dock.trailingAnchor, constant: -10),
            bottomBody.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            bottomBody.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            bottomBody.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
            bottomBody.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
            dockHeightC,
        ])
        dock.isHidden = dockCollapsed
        updateBottomTabs(files: true)
        return dock
    }
    @objc func showFiles() { updateBottomTabs(files: true) }
    @objc func showCmds() { updateBottomTabs(files: false) }
    func updateBottomTabs(files: Bool) {
        (filesTab as? PillButton)?.style = files ? .primary : .secondary
        (cmdsTab as? PillButton)?.style = files ? .secondary : .primary
        sftpPanel?.isHidden = !files
        cmdPanel?.isHidden = files
        fileOps?.isHidden = !files   // 文件操作图标仅「文件」tab 显示
        if files { connectSFTPToActive() }
    }
    func connectSFTPToActive() {
        guard sessions.indices.contains(current) else { return }
        let sess = sessions[current]
        // 本机终端无远端 SFTP
        if sess.host.isLocal { return }
        sftpPanel?.connectIfNeeded(host: sess.host, password: sess.password)
    }

    // MARK: 发送（底栏单行已合并至命令板；历史「运行」统一走 sendCommandText，禁止空 cmdInput）
    @objc func sendCommand() {
        // 无参入口：读命令板编辑器
        sendCommandText(cmdPanel?.editor.string)
    }

    /// 发送文本到当前会话。历史「运行」必须传非空 cmd，避免读未初始化的 cmdInput。
    func sendCommandText(_ raw: String?) {
        var t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty, let input = cmdInput {
            t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !t.isEmpty else { return }
        guard sessions.indices.contains(current) else { setStatus("无活动会话"); return }

        var payload = t
        if CommandParams.hasUnresolved(payload) {
            var values: [String: String] = [:]
            for name in CommandParams.parse(payload) {
                let a = NSAlert.pix(); a.messageText = "参数 \(name)"; a.informativeText = "请输入 ${\(name)} 的值"
                a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
                let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22)); a.accessoryView = tf
                guard a.runModal() == .alertFirstButtonReturn else { return }
                values[name] = tf.stringValue
            }
            payload = CommandParams.render(payload, values: values)
        }

        let sendText: String
        if payload.hasSuffix("\r") {
            sendText = payload
        } else if payload.hasSuffix("\n") {
            sendText = String(payload.dropLast()) + "\r"
        } else {
            sendText = payload + "\r"
        }
        sessions[current].ssh?.send(Array(sendText.utf8))
        let hist = payload.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        cmdHistory.push(hist)
        applyCdSync(for: hist)
        // 清空命令板/残留输入，避免下次空跑
        if let panel = cmdPanel, raw == nil || raw == panel.editor.string {
            panel.editor.string = ""
        }
        cmdInput?.stringValue = ""
    }

    // 底栏高度拖拽条（对齐老仓库 #bottomResizer：拖动改高度并持久化）
    func buildDockResizer() -> NSView {
        let d = HDividerView(); d.translatesAutoresizingMaskIntoConstraints = false
        d.wantsLayer = true; d.layer?.backgroundColor = Theme.border.cgColor
        d.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragDockHeight(_:))))
        return d
    }
    @objc func dragDockHeight(_ g: NSPanGestureRecognizer) {
        guard let host = dockView?.superview else { return }
        // 往上拖 → 坞变高（非翻转视图里向上 dy > 0，所以是 +dy；写成 -dy 会方向相反）
        let dy = g.translation(in: host).y
        let maxH = max(240, host.bounds.height - 220)
        let target = min(max(dockHeight + dy, 200), maxH)
        dockHeight = target
        if !dockCollapsed { dockHeightC?.constant = target }
        g.setTranslation(.zero, in: host)
        if g.state == .ended {
            UserDefaults.standard.set(Double(target), forKey: "pixshell.bottomHeight")
            Log.debug("底栏高度 → \(Int(target))", "ui")
        }
    }

    // 命令栏 ▾/▴：隐藏/显示整个 文件/命令 坞（tab 行 + 面板体一起消失），终端补满。
    @objc func toggleDock() { setBottomCollapsed(!dockCollapsed) }
    func setBottomCollapsed(_ collapsed: Bool) {
        Log.debug("底栏折叠=\(collapsed)", "ui")
        dockCollapsed = collapsed
        dockHeightC?.constant = collapsed ? 0 : dockHeight
        dockView?.isHidden = collapsed
        dockToggleBtn?.image = NSImage(systemSymbolName: collapsed ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        dockToggleBtn?.toolTip = collapsed ? "显示文件/命令" : "隐藏文件/命令"
    }

    /// CLI 状态三态（严格对齐老仓库口径，**别把「桥在监听」写成「已连接/已对接」**）：
    ///   未开启(红) = 桥没在听；已开启(黄) = 本地桥在听但还没有外部请求；已对接(绿) = 5 分钟内有鉴权通过的外部请求
    func updateCliStatus() {
        guard let dot = statusDot, let label = statusLabel else { return }
        let listening = bridgeStatus.running
        let paired = listening && (bridgeStatus.clientIdle.map { $0 < 300 } ?? false)
        if paired {
            dot.setColor(Theme.ok); label.stringValue = "CLI 已对接"
            label.toolTip = "外部 CLI/Agent 已对接 · 127.0.0.1:\(bridgeStatus.port)"
        } else if listening {
            dot.setColor(Theme.warn); label.stringValue = "CLI 已开启"
            label.toolTip = "本地桥监听中，等待外部 CLI/Agent · 127.0.0.1:\(bridgeStatus.port)"
        } else {
            dot.setColor(Theme.err); label.stringValue = "CLI 未开启"
            label.toolTip = "本地桥未启动"
        }
    }

    // MARK: 状态栏（[GitHub] PixShell 版本 · ●CLI 已开启 … ssh2 OK | UTF-8）
    func buildStatusBar() -> NSView {
        let bar = NSView(); bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.statusBg.cgColor
        let sep = NSBox(); sep.boxType = .custom; sep.borderWidth = 0; sep.fillColor = Theme.border
        sep.translatesAutoresizingMaskIntoConstraints = false

        // 品牌前 GitHub 标志 → 点开仓库
        let gh = GitHubMarkButton()
        gh.target = self; gh.action = #selector(menuRepo)
        let brand = NSTextField(labelWithString: "PixShell"); brand.font = Theme.ui(12, .bold); brand.textColor = Theme.text
        let ver = NSTextField(labelWithString: "v0.1.7"); ver.font = Theme.ui(11); ver.textColor = Theme.muted
        statusDot = Dot(Theme.warn, size: 8)
        statusLabel = NSTextField(labelWithString: "CLI 未开启"); statusLabel.font = Theme.ui(11); statusLabel.textColor = Theme.muted
        let leftStack = NSStackView(views: [gh, brand, ver, statusDot, statusLabel])
        leftStack.orientation = .horizontal; leftStack.spacing = 6; leftStack.alignment = .centerY
        leftStack.setCustomSpacing(4, after: gh)
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        statusRight = NSTextField(labelWithString: "就绪  |  UTF-8"); statusRight.font = Theme.ui(11); statusRight.textColor = Theme.muted
        statusRight.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(sep); bar.addSubview(leftStack); bar.addSubview(statusRight)
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: bar.topAnchor), sep.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bar.trailingAnchor), sep.heightAnchor.constraint(equalToConstant: 1),
            leftStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusRight.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            statusRight.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    // MARK: 顶栏动作
    @objc func openConnMgr() { connMgr.show() }
    // ＋/网格 = 打开"快速连接/历史"落地页（而非直接连 SSH）。
    @objc func newQuickTab() { showQuickConnect() }
    func showQuickConnect() {
        guard let qc = quickConnect else { return }
        // 有活动会话时显示返回箭头；无会话（启动/关完最后标签）不显示
        qc.showsBack = !sessions.isEmpty
        qc.reload(); qc.isHidden = false
        qc.superview?.addSubview(qc)   // 置顶于终端之上
        collapseChrome()               // 落地页默认：收起侧栏 + 收起文件/命令坞（对齐老仓库）
    }
    /// 顶栏主题按钮：深色 → 浅色 → 水墨 → 深色 循环（水墨也要能从顶栏摸到）
    @objc func toggleTheme() {
        // 只做 浅 ⇄ 暗 两态切换。"浅"具体是 浅色/水墨/复古 哪一套，由设置里选的那个决定
        // （Theme.lightKind），不再挨个轮一遍。
        applyThemeKind(Theme.dark ? Theme.lightKind : .dark)
    }

    // 系统信息：独立弹出窗口（对齐 ConnManager 模式）
    @objc func openSysInfo() {
        guard sessions.indices.contains(current), let ssh = sessions[current].ssh else {
            Log.warn("系统信息：无活动会话，忽略", "ui"); return
        }
        Log.info("打开系统信息，开始采集", "ui")
        if sysInfoWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 400, height: 320)
            w.appearance = NSAppearance(named: Theme.dark ? .darkAqua : .aqua)
            sysInfo.translatesAutoresizingMaskIntoConstraints = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 560))
            host.autoresizingMask = [.width, .height]
            host.addSubview(sysInfo)
            NSLayoutConstraint.activate([
                sysInfo.topAnchor.constraint(equalTo: host.topAnchor),
                sysInfo.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                sysInfo.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                sysInfo.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            w.contentView = host
            sysInfoWindow = w
        }
        sysInfoWindow?.appearance = NSAppearance(named: Theme.dark ? .darkAqua : .aqua)
        sysInfoWindow?.center()
        sysInfoWindow?.makeKeyAndOrderFront(nil)
        sysInfo.show("采集中…")
        ssh.exec(SysInfoPanel.command) { [weak self] out in
            Log.info("系统信息采集完成（\(out.count) 字节）", "ui")
            self?.sysInfo.show(out)
        }
    }

    // 工具面板（宫格图标）
    /// 顶栏宫格图标：点一下呼出、再点一下收起（老仓库 openToolsPanel 的 willOpen 逻辑）。
    @objc func openTools() {
        if toolsPanel.isOpen { toolsPanel.isHidden = true; return }
        Log.info("打开工具浮窗", "ui")
        toolsPanel.setDownloadPath(downloadDir.path); toolsPanel.show()
        // 强制置顶：addSubview 到最前，避免被终端/其它弹层盖住
        toolsPanel.superview?.addSubview(toolsPanel, positioned: .above, relativeTo: nil)
        toolsPanel.wantsLayer = true
        toolsPanel.layer?.zPosition = 1000
    }
    func pickDownloadDir() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.directoryURL = downloadDir
        guard p.runModal() == .OK, let u = p.url else { return }
        downloadDir = u; toolsPanel.setDownloadPath(u.path)
    }

    // 汉堡菜单：文件 / 查看 / 选项 + 密钥管理器 / 云端同步 / 软件更新 + 帮助
    // 结构 1:1 对齐老仓库 index.html 的 #mainMenu（嵌套子菜单，不摊成一排）。
    @objc func openMenu() {
        let m = NSMenu()
        m.addItem(sub("文件", [
            ("连接管理器…", #selector(openConnMgr)), ("新建连接…", #selector(addHost)),
            ("连接", #selector(menuConnect)), ("断开", #selector(menuDisconnect)), ("重新连接", #selector(menuReconnect)),
            (nil, nil),
            ("导入主机…", #selector(importHosts)), ("导出主机…", #selector(exportHosts)),
        ]))
        m.addItem(sub("查看", [
            ("显示/隐藏侧栏", #selector(toggleSidebar)), ("显示/隐藏底栏", #selector(toggleDock)),
            ("文件面板", #selector(showFiles)), ("命令面板", #selector(showCmds)),
            (nil, nil),
            ("系统信息", #selector(openSysInfo)), ("进程管理", #selector(menuToolProcess)), ("网络监控", #selector(menuToolNetwork)),
        ]))
        m.addItem(sub("选项", [
            ("设置…", #selector(openSettings)), ("代理服务器…", #selector(openProxy)),
        ]))
        m.addItem(.separator())
        m.addItem(item("密钥管理器", #selector(menuKeyMgr)))
        m.addItem(item("主机指纹管理…", #selector(menuFingerprintMgr)))
        // AI 对接：后端 AgentBridge / AgentCLI / AgentMCP 已就绪，汉堡菜单提供一键入口
        m.addItem(sub("AI 对接", [
            ("接入 AI 工具…", #selector(openAIIntegration)),
            ("一键注册 AI 默认 SSH…", #selector(openAiSshBridge)),
            (nil, nil),
            ("复制 CLI 用法", #selector(copyCLIUsage)),
            ("复制 MCP 注册命令", #selector(copyMCPRegister)),
            ("复制 Desktop MCP 配置", #selector(copyMCPDesktop)),
            (nil, nil),
            ("打开 CLI 脚本目录", #selector(openCLIBinDir)),
            ("重新安装 CLI / MCP", #selector(reinstallCLIBridge)),
        ]))
        // Web 主路径：新建连接 → 类型 Web；此处仅调试入口
        m.addItem(item("打开桥接镜像页（调试）…", #selector(openWebSSHEmbedded)))
        m.addItem(sub("云端同步", [
            ("备份选项配置…", #selector(openBackup)),
            (nil, nil),
            ("WebDAV 设置…", #selector(webdavConfigure)),
            ("上传到 WebDAV", #selector(webdavPush)), ("从 WebDAV 恢复", #selector(webdavPull)),
            (nil, nil),
            ("立即导出本地包…", #selector(exportHosts)), ("从本地包导入…", #selector(importHosts)),
        ]))
        m.addItem(item("软件更新", #selector(checkUpdate)))
        m.addItem(.separator())
        m.addItem(sub("帮助", [
            ("关于 PixShell", #selector(menuAbout)),
            ("接入 AI 工具…", #selector(openAIIntegration)),
            ("一键注册 AI 默认 SSH…", #selector(openAiSshBridge)),
            ("打开桥接镜像页（调试）…", #selector(openWebSSHEmbedded)),
            ("在系统浏览器打开桥接页…", #selector(openWebSSHInSystemBrowser)),
            ("项目仓库", #selector(menuRepo)),
        ]))
        if let btn = menuBtn { m.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn) }
    }
    private func item(_ t: String, _ a: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; return i
    }
    private func sub(_ title: String, _ rows: [(String?, Selector?)]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for (t, a) in rows {
            if let t = t, let a = a { menu.addItem(item(t, a)) } else { menu.addItem(.separator()) }
        }
        parent.submenu = menu
        return parent
    }
    @objc func toggleThemeMenu() { toggleTheme() }
    @objc func toggleHighlight() { highlightEnabled.toggle() }
    @objc func fontBigger() { adjustFont(1) }
    @objc func fontSmaller() { adjustFont(-1) }
    private func adjustFont(_ d: CGFloat) {
        for s in sessions {
            let f = s.termView.font
            s.termView.font = NSFont(name: f.fontName, size: max(9, min(22, f.pointSize + d))) ?? f
        }
    }
    func applyTheme(dark: Bool) { applyThemeKind(dark ? .dark : .light) }

    /// 三态主题切换（深色 / 浅色 / 水墨）。水墨走浅色外观。
    /// 文本编辑器的独立窗口。
    ///
    /// 之前是贴满主窗的内嵌浮层（四边钉在 root 上）——既拖不动，也不可能拖到主窗外面，
    /// 而改远端文件时经常需要把它挪开对照终端。所以改成真正的 NSWindow：
    /// 可拖、可缩放、可拖到别的屏幕，关掉只是 orderOut，下次复用同一个窗口（保留尺寸/位置）。
    func showEditorWindow(title: String) {
        if editorWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "编辑器"
            // 标题栏去掉：面板自己的头部已经有文件名+语言徽章+保存/关闭，再顶一条系统标题栏
            // 就是白占一条高度。做法是"内容铺满 + 标题栏透明 + 标题隐藏"：
            // 视觉上没有那条框，但标题栏的**拖拽区**还在，窗口照样能拖、能缩放。
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // 背景任意处也能拖（点在按钮/文本视图上不会误触发，AppKit 会让控件优先）
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false          // 关掉不销毁，否则下次开就是野指针
            w.minSize = NSSize(width: 520, height: 340)
            // 套一层 host：host 用 autoresizing 跟着窗口变，面板再用约束钉在 host 四边。
            // 直接拿"带内部约束的视图"当 contentView，缩放行为不确定（实测会错位）。
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
            host.autoresizingMask = [.width, .height]
            host.addSubview(editorPanel)
            NSLayoutConstraint.activate([
                editorPanel.topAnchor.constraint(equalTo: host.topAnchor),
                editorPanel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                editorPanel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                editorPanel.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            w.contentView = host
            // 红绿灯去掉：头部已经有自己的「关闭」按钮，两套关闭入口很冗余。
            // 保留 .titled 是为了标题栏能拖动窗口，只把三个标准按钮藏起来。
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = true
            }
            w.center()
            // 跟随主题：浅底主题用 aqua，否则标题栏会和内容对不上
            w.appearance = NSAppearance(named: Theme.dark ? .darkAqua : .aqua)
            editorWindow = w
        }
        editorWindow?.title = "编辑器 — " + (title as NSString).lastPathComponent
        editorWindow?.appearance = NSAppearance(named: Theme.dark ? .darkAqua : .aqua)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    func applyThemeKind(_ kind: Theme.Kind) {
        Log.info("切换主题 → \(kind.display)", "ui")
        // installContent() 会重建 editorPanel。若独立编辑器窗口仍持有旧面板，
        // 后续保存/主题状态会指向新旧两个实例；先收起并释放窗口，下一次打开时
        // 再挂载新面板，避免主题切换后的编辑器状态分裂。
        editorWindow?.orderOut(nil)
        editorWindow = nil
        Theme.kind = kind
        NSApp.appearance = NSAppearance(named: Theme.dark ? .darkAqua : .aqua)
        for s in sessions { TermTheme.apply(to: s.termView, dark: Theme.dark) }
        installContent()   // 整窗重建，让自绘 chrome（顶栏/侧栏/坞/状态栏/弹层）也切换配色
    }
}


extension AppDelegate {
    /// 打开密钥管理（菜单 文件 → 密钥管理…）
    @objc func openKeyManager() {
        Log.info("打开密钥管理", "ui")
        keyManager.show()
    }

    /// 打开主机指纹管理（汉堡 / 文件 → 主机指纹管理…）
    @objc func openFingerprintManager() {
        Log.info("打开主机指纹管理", "ui")
        fingerprintManager.show()
    }

    /// 打开 AI 工具 SSH 桥接注册窗（汉堡 / 工具 → 一键注册 AI 默认 SSH…）
    @objc func openAiSshBridge() {
        Log.info("打开 AI 工具 SSH 桥接", "ui")
        // 点开时顺手保证 CLI 在盘上，检测更准
        if let port = agentBridge?.port { AgentCLI.install(port: port) }
        aiSshBridgeManager.show()
    }
}
