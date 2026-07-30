import AppKit

/// 远端目录树节点（懒加载子目录）。children==nil 表示未加载。
final class SFTPNode {
    let path: String
    let name: String
    var children: [SFTPNode]? = nil
    var loading = false
    init(path: String, name: String) { self.path = path; self.name = name }
}

/// SFTP 文件面板（自绘复刻老仓库「文件」：工具条 + 远端目录树 + 图标明细列表）。
/// 布局：[← 路径 …… 刷新 下载 上传 隐藏本地] / [本地(可隐藏) | 远端目录树 | 远端明细(文件名/大小/类型/修改时间)]。
/// 双击目录进入；图标区分目录(黄folder)/文件/链接。
final class SFTPPanel: NSView, NSTableViewDataSource, NSTableViewDelegate,
                      NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    // 本地
    private var localPath: URL
    private var localEntries: [URL] = []
    private let localTable = NSTableView()
    private let localPathLabel = NSTextField(labelWithString: "")
    // 远端
    private var sftp: SFTPService?
    private var remotePath = "/"
    private var remoteEntries: [SFTPEntry] = []
    private let remoteTable = NSTableView()
    private let remoteTree = NSOutlineView()
    private var treeRoot = SFTPNode(path: "/", name: "/")
    private let statusLabel = NSTextField(labelWithString: "")
    private var connectedHostId: String?
    var onPathChange: ((String) -> Void)?   // 当前远端路径变化 → 通知坞行的路径标签
    var onOpenFile: ((String, String) -> Void)?   // 双击文件 → (远端路径, 文本内容) 交给编辑器
    var onUserNavigate: ((String) -> Void)?       // 用户在 SFTP 里进目录 → 可反向 cd 终端
    var onInsertToCommand: ((String) -> Void)?    // 右键「插入命令框」
    /// 远端执行命令（打包传输 / chmod 需要，宿主注入当前会话的 ssh.exec）
    var execRunner: ((String, @escaping (String) -> Void) -> Void)?
    /// 按 proxyId 取代理配置（宿主注入），保证 SFTP 与 SSH 走同一条链路
    var proxyProvider: ((String) -> ProxyConfig?)?
    /// 打包传输开关（默认开，UserDefaults 持久化）
    private static let packKey = "pixshell.sftp.packTransfer"
    var packTransferEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.packKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.packKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.packKey) }
    }
    private lazy var chmodWindow = ChmodWindow()

    /// 当前远端目录（命令框 cd 同步用）
    var currentRemotePath: String { remotePath }

    /// 外部（命令框 cd）驱动切目录
    func navigate(to path: String) {
        guard sftp != nil else { return }
        remotePath = path.isEmpty ? "/" : path
        reloadRemote()
    }

    // 本地隐藏控制
    private var localCol: NSView!
    private var localWidthC: NSLayoutConstraint!
    var localHidden = true   // 默认隐藏本地：远端目录树+明细占满（对齐参考图）
    /// 左栏两种模式：本地文件浏览 / 与本机 CLI agent 对话。默认文件。
    enum LocalMode { case files, chat }
    private(set) var localMode: LocalMode = .files
    private var localBody: NSView!          // 文件表 与 对话面板 的容器
    private var localFilesScroll: NSScrollView!
    let agentChat = AgentChatView(frame: .zero)

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm"; return f
    }()
    private let folderColor = NSColor(srgbRed: 0.91, green: 0.74, blue: 0.29, alpha: 1) // 参考图黄色文件夹

    override init(frame frameRect: NSRect) {
        localPath = FileManager.default.homeDirectoryForCurrentUser
        super.init(frame: frameRect)
        build()
        reloadLocal()
        applyLocalHidden()
        registerForDraggedTypes([.fileURL])   // 拖文件到面板 → 上传（老仓库 §5）
    }

    // MARK: 拖拽上传
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sftp != nil ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sftp != nil,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        uploadItems(urls)   // 走智能打包：多项/目录/大文件自动 tar
        return true
    }

    // MARK: 键盘：F5 刷新 / F2 重命名 / Delete 删除
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 96:  refresh()          // F5
        case 120: ctxRename()        // F2
        case 51, 117: ctxDelete()    // Delete / Fn+Delete
        default: super.keyDown(with: event)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 连接
    /// 连接世代：快速重连/回落时作废旧 completion，避免 NIO 失败回调冲掉已成功的 OpenSSH 会话。
    private var connectGeneration: UInt64 = 0
    /// 是否已完成握手（list/download 等可立即用）；连接中时 bridge 会等 ready 回调。
    private var sftpReady = false
    private var connectWaiters: [(Result<Void, Error>) -> Void] = []

    func connectIfNeeded(host: Host, password: String?) {
        if connectedHostId == host.id, sftp != nil, sftpReady { return }
        // 同主机正在连：复用，不打断
        if connectedHostId == host.id, sftp != nil, !sftpReady { return }
        beginConnect(host: host, password: password)
    }

    /// 强制按当前凭据重连（切换会话密码后用）。
    func reconnect(host: Host, password: String?) {
        beginConnect(host: host, password: password)
    }

    private func beginConnect(host: Host, password: String?) {
        sftp?.close()
        sftp = nil
        sftpReady = false
        connectedHostId = host.id
        connectGeneration &+= 1
        let gen = connectGeneration
        onPathChange?("连接中…")
        statusLabel.stringValue = "SFTP 连接 \(host.subtitle) …"
        let creds = SSHCredentials(host: host.host, port: host.port, username: host.username,
                                   password: password,
                                   keyPath: host.keyPath.isEmpty ? nil : host.keyPath,
                                   proxy: proxyProvider?(host.proxyId))
        // 与终端会话保持一致：RSA/DSA/加密私钥等 NIO 无法加载的类型，直接交给
        // 系统 OpenSSH。否则文件列表会先等待 NIO 连接超时约两分钟才开始回落。
        let keyRequiresOpenSSH = !host.keyPath.isEmpty
            && SSHPrivateKeyLoader.load(path: host.keyPath) == nil
        if keyRequiresOpenSSH {
            Log.info("私钥不受 NIO 支持，SFTP 直接使用 OpenSSH", "sftp")
            let primary = OpenSSHSFTPSession()
            sftp = primary
            primary.connect(creds) { [weak self] result in
                guard let self = self, gen == self.connectGeneration else { return }
                switch result {
                case .success:
                    self.markConnected(primary, label: "OpenSSH")
                case .failure(let error):
                    self.sftp?.close(); self.sftp = nil
                    self.sftpReady = false
                    self.onPathChange?("远端未连接")
                    self.statusLabel.stringValue = "SFTP 失败: \(self.msg(error))"
                    Log.error("OpenSSH SFTP 失败：\(error.localizedDescription)", "sftp")
                    self.finishWaiters(.failure(error))
                }
            }
            return
        }
        // 先试 NIO（零进程、快）；算法/子系统失败再回落系统 OpenSSH。
        let primary = NIOSFTPSession()
        sftp = primary
        primary.connect(creds) { [weak self] result in
            guard let self = self, gen == self.connectGeneration else { return }
            switch result {
            case .success:
                self.markConnected(primary, label: "NIO")
            case .failure(let e):
                Log.warn("NIO SFTP 失败，回落 OpenSSH：\(e.localizedDescription)", "sftp")
                self.statusLabel.stringValue = "SFTP 回落系统 ssh…"
                let fallback = OpenSSHSFTPSession()
                self.sftp = fallback
                fallback.connect(creds) { [weak self] r2 in
                    guard let self = self, gen == self.connectGeneration else { return }
                    switch r2 {
                    case .success:
                        self.markConnected(fallback, label: "OpenSSH")
                    case .failure(let e2):
                        self.sftp?.close(); self.sftp = nil
                        self.sftpReady = false
                        self.onPathChange?("远端未连接")
                        self.statusLabel.stringValue = "SFTP 失败: \(self.msg(e2))"
                        Log.error("SFTP 双路径均失败 NIO=\(e.localizedDescription) OpenSSH=\(e2.localizedDescription)", "sftp")
                        self.finishWaiters(.failure(e2))
                    }
                }
            }
        }
    }

    private func markConnected(_ session: SFTPService, label: String) {
        sftpReady = true
        statusLabel.stringValue = "SFTP 已连接 (\(label))"
        Log.info("SFTP 已连接 backend=\(label)", "sftp")
        finishWaiters(.success(()))
        session.home { [weak self] r in
            guard let self = self else { return }
            if case .success(let h) = r { self.remotePath = h }
            self.rebuildTree()
            self.reloadRemote()
            self.runSelfTestIfNeeded()
        }
    }

    private func finishWaiters(_ result: Result<Void, Error>) {
        let ws = connectWaiters
        connectWaiters.removeAll()
        for w in ws { w(result) }
    }

    /// 等当前 SFTP 握手完成（bridge 用，避免 connectIfNeeded 后立刻 list 撞 notConnected）。
    func whenReady(_ done: @escaping (Result<Void, Error>) -> Void) {
        if sftpReady, sftp != nil {
            done(.success(())); return
        }
        if sftp == nil {
            done(.failure(SFTPError.notConnected)); return
        }
        connectWaiters.append(done)
        // 保险：30s 仍未就绪则失败，避免 bridge 永久挂起
        let gen = connectGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, gen == self.connectGeneration, !self.sftpReady else { return }
            let pending = self.connectWaiters
            self.connectWaiters.removeAll()
            for w in pending { w(.failure(SFTPError.connectFailed("SFTP 连接超时"))) }
        }
    }

    func disconnect() {
        connectGeneration &+= 1
        sftp?.close(); sftp = nil; connectedHostId = nil
        sftpReady = false
        finishWaiters(.failure(SFTPError.notConnected))
        remoteEntries = []; remoteTable.reloadData()
        treeRoot = SFTPNode(path: "/", name: "/"); remoteTree.reloadData()
        onPathChange?("远端未连接")
    }

    // MARK: 布局（工具按钮不在这里——已上移到坞的 文件/命令 行，见 AppDelegate+Layout）
    private func build() {
        wantsLayer = true; layer?.backgroundColor = Theme.bg.cgColor

        // 本地列
        let localHead = NSTextField(labelWithString: "本地"); localHead.font = Theme.ui(11, .bold); localHead.textColor = Theme.muted
        localPathLabel.font = Theme.mono(10); localPathLabel.textColor = Theme.muted; localPathLabel.lineBreakMode = .byTruncatingHead
        configFileTable(localTable)
        let localScroll = scroll(localTable)
        localFilesScroll = localScroll
        // 「文件 / 对话」的切换入口不在这里 —— 放在坞的图标行、刷新按钮旁边（那颗机器人图标），
        // 见 AppDelegate+Layout.buildBottomDock。这里只保留标题行。
        let localHeadRow = NSStackView(views: [localHead, localPathLabel, NSView()])
        localHeadRow.spacing = 8; localHeadRow.alignment = .centerY

        // 文件表 / 对话面板叠在同一个容器里，切模式只改 isHidden
        localBody = NSView(); localBody.translatesAutoresizingMaskIntoConstraints = false
        localBody.addSubview(localScroll); localBody.addSubview(agentChat)
        agentChat.isHidden = true
        NSLayoutConstraint.activate([
            localScroll.topAnchor.constraint(equalTo: localBody.topAnchor),
            localScroll.bottomAnchor.constraint(equalTo: localBody.bottomAnchor),
            localScroll.leadingAnchor.constraint(equalTo: localBody.leadingAnchor),
            localScroll.trailingAnchor.constraint(equalTo: localBody.trailingAnchor),
            agentChat.topAnchor.constraint(equalTo: localBody.topAnchor),
            agentChat.bottomAnchor.constraint(equalTo: localBody.bottomAnchor),
            agentChat.leadingAnchor.constraint(equalTo: localBody.leadingAnchor),
            agentChat.trailingAnchor.constraint(equalTo: localBody.trailingAnchor),
        ])

        let localStack = NSStackView(views: [localHeadRow, localBody])
        localStack.orientation = .vertical; localStack.spacing = 3; localStack.alignment = .leading
        localCol = localStack
        localCol.translatesAutoresizingMaskIntoConstraints = false
        localBody.widthAnchor.constraint(equalTo: localCol.widthAnchor).isActive = true
        localHeadRow.widthAnchor.constraint(equalTo: localCol.widthAnchor).isActive = true

        // 远端目录树
        remoteTree.headerView = nil
        remoteTree.rowHeight = 22
        remoteTree.indentationPerLevel = 12
        remoteTree.backgroundColor = Theme.bg2
        remoteTree.usesAutomaticRowHeights = false
        let treeCol = NSTableColumn(identifier: .init("tree")); treeCol.title = ""; remoteTree.addTableColumn(treeCol)
        remoteTree.outlineTableColumn = treeCol
        remoteTree.dataSource = self; remoteTree.delegate = self
        remoteTree.target = self; remoteTree.action = #selector(treeClicked)
        let treeScroll = scroll(remoteTree); treeScroll.hasVerticalScroller = true

        // 远端明细
        configFileTable(remoteTable)
        let remoteScroll = scroll(remoteTable)

        // 树 | 明细
        let treeWrap = NSView(); treeWrap.translatesAutoresizingMaskIntoConstraints = false; treeWrap.addSubview(treeScroll)
        NSLayoutConstraint.activate([
            treeScroll.topAnchor.constraint(equalTo: treeWrap.topAnchor), treeScroll.bottomAnchor.constraint(equalTo: treeWrap.bottomAnchor),
            treeScroll.leadingAnchor.constraint(equalTo: treeWrap.leadingAnchor), treeScroll.trailingAnchor.constraint(equalTo: treeWrap.trailingAnchor),
            treeWrap.widthAnchor.constraint(equalToConstant: 160),
        ])
        let remoteBody = NSStackView(views: [treeWrap, remoteScroll]); remoteBody.spacing = 8; remoteBody.alignment = .top
        remoteBody.translatesAutoresizingMaskIntoConstraints = false
        remoteScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        // 本地 | 远端
        let cols = NSStackView(views: [localCol, remoteBody]); cols.spacing = 10; cols.alignment = .top
        cols.translatesAutoresizingMaskIntoConstraints = false
        localWidthC = localCol.widthAnchor.constraint(equalToConstant: 240)
        localWidthC.isActive = true

        statusLabel.font = Theme.ui(10); statusLabel.textColor = Theme.muted

        addSubview(cols); addSubview(statusLabel)
        NSLayoutConstraint.activate([
            cols.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            cols.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cols.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cols.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            localCol.topAnchor.constraint(equalTo: cols.topAnchor),
            localCol.bottomAnchor.constraint(equalTo: cols.bottomAnchor),
            remoteBody.topAnchor.constraint(equalTo: cols.topAnchor),
            remoteBody.bottomAnchor.constraint(equalTo: cols.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @objc func toggleLocal() { localHidden.toggle(); applyLocalHidden() }

    /// 进对话前左栏是不是收着的 —— 退出对话要**原样还回去**：
    /// 本来只有远端就回到只有远端，本来是远端+本地就回到远端+本地。
    private var localHiddenBeforeChat: Bool?

    /// 坞里的机器人按钮：点一下进对话，再点一下退出并恢复原来的界面。
    @objc func toggleChat() {
        if localMode == .chat {
            // 退出：先回文件模式，再把左栏的显示/隐藏还原成进来之前那样
            setLocalMode(.files)
            if let before = localHiddenBeforeChat, before != localHidden {
                localHidden = before
                applyLocalHidden()
            }
            localHiddenBeforeChat = nil
        } else {
            localHiddenBeforeChat = localHidden   // 记住原样，退出时还原
            setLocalMode(.chat)
        }
    }

    /// 是否正处于对话模式（宿主据此给按钮上高亮）。
    var isChatMode: Bool { localMode == .chat }

    func setLocalMode(_ m: LocalMode) {
        localMode = m
        // 对话要占地方；左栏收着的话先展开（退出时由 toggleChat 还原）
        if m == .chat, localHidden { localHidden = false; applyLocalHidden() }
        let chat = (localMode == .chat)
        agentChat.isHidden = !chat
        localFilesScroll.isHidden = chat
        localPathLabel.isHidden = chat          // 对话模式下路径由 agentChat 自己显示
        if chat { agentChat.workingDirectory = localPath }
    }
    private func applyLocalHidden() {
        localCol.isHidden = localHidden
        localWidthC.isActive = !localHidden
    }

    private func configFileTable(_ t: NSTableView) {
        let name = NSTableColumn(identifier: .init("name")); name.title = "文件名"; name.width = 240; name.minWidth = 140
        let size = NSTableColumn(identifier: .init("size")); size.title = "大小"; size.width = 74
        let type = NSTableColumn(identifier: .init("type")); type.title = "类型"; type.width = 56
        let mtime = NSTableColumn(identifier: .init("mtime")); mtime.title = "修改时间"; mtime.width = 128
        [name, size, type, mtime].forEach { t.addTableColumn($0) }
        t.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        t.usesAlternatingRowBackgroundColors = true
        t.rowHeight = 22
        t.dataSource = self; t.delegate = self
        t.doubleAction = #selector(rowDoubleClicked(_:)); t.target = self
        t.gridStyleMask = []
        t.backgroundColor = Theme.bg2
        t.allowsMultipleSelection = true            // ⌘ 多选 / Shift 连选（老仓库 §5）
        t.menu = makeContextMenu(remote: t === remoteTable)
    }

    // MARK: 右键菜单（打开/下载/上传/重命名/新建目录/删除/复制路径/插入命令框/打包传输/文件权限）
    private func makeContextMenu(remote: Bool) -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        func add(_ t: String, _ a: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; m.addItem(i); return i
        }
        if remote {
            _ = add("打开 / 进入", #selector(ctxOpen))
            _ = add("下载", #selector(download))
            m.addItem(.separator())
            _ = add("上传到此目录…", #selector(upload))
            _ = add("新建目录…", #selector(mkdir))
            _ = add("重命名…", #selector(ctxRename))
            _ = add("删除", #selector(ctxDelete))
            m.addItem(.separator())
            let pack = add("打包传输", #selector(ctxTogglePackTransfer))
            pack.tag = 9001
            _ = add("文件权限…", #selector(ctxChmod))
            m.addItem(.separator())
            _ = add("复制路径", #selector(ctxCopyPath))
            _ = add("插入命令框", #selector(ctxInsertToCommand))
            m.addItem(.separator())
            _ = add("刷新", #selector(refresh))
        } else {
            _ = add("上传", #selector(upload))
            let pack = add("打包传输", #selector(ctxTogglePackTransfer))
            pack.tag = 9001
            m.addItem(.separator())
            _ = add("复制路径", #selector(ctxCopyPath))
            _ = add("刷新", #selector(refresh))
        }
        return m
    }

    @objc private func ctxTogglePackTransfer() {
        packTransferEnabled.toggle()
        statusLabel.stringValue = packTransferEnabled ? "已开启打包传输" : "已关闭打包传输（直传）"
        Log.info("打包传输 → \(packTransferEnabled ? "开" : "关")", "sftp")
    }

    // 右键菜单打开前：刷新「✓ 打包传输」勾选态
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == 9001 || item.action == #selector(ctxTogglePackTransfer) {
            item.state = packTransferEnabled ? .on : .off
            item.title = packTransferEnabled ? "✓ 打包传输" : "打包传输"
        }
    }

    @objc private func ctxChmod() {
        let items = targetRemoteEntries()
        guard !items.isEmpty else { statusLabel.stringValue = "先选远端文件"; return }
        let paths = items.map { join(remotePath, $0.name) }
        // 多项时以第一项权限为初值（勾选可再改）
        let mode = items.first?.perms ?? 0o755
        chmodWindow.onDone = { [weak self] msg in
            self?.statusLabel.stringValue = msg
            self?.reloadRemote()
        }
        chmodWindow.show(paths: paths, mode: mode, execRunner: execRunner)
    }

    /// 右键/选中的远端条目（优先 clickedRow，其次多选）
    private func targetRemoteEntries() -> [SFTPEntry] {
        var rows = Set(remoteTable.selectedRowIndexes)
        let clicked = remoteTable.clickedRow
        if clicked >= 0, !rows.contains(clicked) { rows = [clicked] }
        return rows.sorted().compactMap { remoteEntries.indices.contains($0) ? remoteEntries[$0] : nil }
    }

    @objc private func ctxOpen() {
        guard let e = targetRemoteEntries().first else { return }
        if e.isDir { remotePath = join(remotePath, e.name); reloadRemote(); onUserNavigate?(remotePath) }
        else { openRemoteFile(e) }
    }
    @objc private func ctxRename() {
        guard let sftp = sftp, let e = targetRemoteEntries().first else { return }
        let name = prompt("重命名「\(e.name)」为", preset: e.name)
        guard !name.isEmpty, name != e.name else { return }
        sftp.rename(from: join(remotePath, e.name), to: join(remotePath, name)) { [weak self] r in
            if case .failure(let er) = r { self?.statusLabel.stringValue = "重命名失败: \(self?.msg(er) ?? "")" }
            else { self?.reloadRemote() }
        }
    }
    @objc private func ctxDelete() {
        guard let sftp = sftp else { return }
        let items = targetRemoteEntries(); guard !items.isEmpty else { return }
        let a = NSAlert.pix(); a.messageText = "删除 \(items.count) 项？"
        a.informativeText = items.prefix(6).map { $0.name }.joined(separator: "\n")
        a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var left = items.count
        for e in items {
            sftp.remove(join(remotePath, e.name)) { [weak self] r in
                if case .failure(let er) = r { self?.statusLabel.stringValue = "删除失败: \(self?.msg(er) ?? "")" }
                left -= 1
                if left == 0 { self?.reloadRemote() }
            }
        }
    }
    @objc private func ctxCopyPath() {
        let paths = targetRemoteEntries().map { join(remotePath, $0.name) }
        let text = paths.isEmpty ? remotePath : paths.joined(separator: " ")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "已复制路径"
    }
    @objc private func ctxInsertToCommand() {
        let paths = targetRemoteEntries().map { join(remotePath, $0.name) }
        onInsertToCommand?(paths.isEmpty ? remotePath : paths.joined(separator: " "))
    }
    private func scroll(_ doc: NSView) -> NSScrollView {
        let s = NSScrollView(); s.documentView = doc; s.hasVerticalScroller = true
        s.drawsBackground = true; s.backgroundColor = Theme.bg2
        s.rounded(Theme.radiusSm, border: Theme.border)
        s.translatesAutoresizingMaskIntoConstraints = false
        // 低优先级最小高度：坞折叠到 0 时可让位，避免约束冲突。
        let minH = s.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        minH.priority = .defaultLow; minH.isActive = true
        return s
    }

    // MARK: 数据
    private func reloadLocal() {
        localPathLabel.stringValue = localPath.path
        var items: [URL] = []
        if let list = try? FileManager.default.contentsOfDirectory(at: localPath, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            items = list.sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bd = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if ad != bd { return ad }
                return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
            }
        }
        localEntries = items
        localTable.reloadData()
    }
    private func reloadRemote() {
        guard let sftp = sftp else { return }
        onPathChange?(remotePath)
        sftp.listDirectory(remotePath) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let entries):
                self.remoteEntries = entries.sorted { a, b in
                    if a.isDir != b.isDir { return a.isDir }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                self.remoteTable.reloadData()
            case .failure(let e):
                self.statusLabel.stringValue = "列目录失败: \(self.msg(e))"
            }
        }
    }

    // MARK: 目录树（懒加载）
    private func rebuildTree() {
        treeRoot = SFTPNode(path: "/", name: "/")
        remoteTree.reloadData()
        loadChildren(treeRoot) { [weak self] in
            self?.remoteTree.expandItem(self?.treeRoot)
        }
    }
    private func loadChildren(_ node: SFTPNode, done: (() -> Void)? = nil) {
        guard let sftp = sftp, node.children == nil, !node.loading else { done?(); return }
        node.loading = true
        sftp.listDirectory(node.path) { [weak self] result in
            guard let self = self else { return }
            node.loading = false
            if case .success(let entries) = result {
                node.children = entries.filter { $0.isDir }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .map { SFTPNode(path: self.join(node.path, $0.name), name: $0.name) }
            } else {
                node.children = []
            }
            self.remoteTree.reloadItem(node === self.treeRoot ? nil : node, reloadChildren: true)
            done?()
        }
    }
    @objc private func treeClicked() {
        let row = remoteTree.clickedRow
        guard row >= 0, let node = remoteTree.item(atRow: row) as? SFTPNode else { return }
        remotePath = node.path
        reloadRemote()
        onUserNavigate?(remotePath)   // 反向同步终端 cd
    }

    // MARK: 交互
    @objc private func rowDoubleClicked(_ sender: NSTableView) {
        if sender === localTable {
            let row = localTable.clickedRow
            guard row >= 0, row < localEntries.count else { return }
            let url = localEntries[row]
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { localPath = url; reloadLocal() }
        } else {
            let row = remoteTable.clickedRow
            guard row >= 0, row < remoteEntries.count else { return }
            let e = remoteEntries[row]
            if e.isDir {
                remotePath = join(remotePath, e.name); reloadRemote()
                onUserNavigate?(remotePath)          // 反向同步终端 cd
            } else {
                openRemoteFile(e)                    // 双击文件 → 编辑器
            }
        }
    }

    /// 下载到临时文件后读文本，交给编辑器（老仓库：SFTP 双击 → sftpRead → showEditorModal）
    private func openRemoteFile(_ e: SFTPEntry, overridePath: String? = nil) {
        guard let sftp = sftp else { return }
        if e.size > 4 * 1024 * 1024 { statusLabel.stringValue = "文件过大（>4MB），请先下载"; return }
        let remote = overridePath ?? join(remotePath, e.name)
        let tmp = NSTemporaryDirectory() + "pixshell_edit_" + e.name
        statusLabel.stringValue = "打开 \(e.name) …"
        sftp.download(remote: remote, local: tmp) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .failure(let err): self.statusLabel.stringValue = "打开失败: \(self.msg(err))"
            case .success:
                guard let text = (try? String(contentsOfFile: tmp, encoding: .utf8))
                        ?? (try? String(contentsOfFile: tmp, encoding: .isoLatin1)) else {
                    self.statusLabel.stringValue = "不是文本文件"; return
                }
                self.statusLabel.stringValue = ""
                self.onOpenFile?(remote, text)
            }
        }
    }

    /// 直接按路径打开远端文件到编辑器（供菜单/调试钩子调用）
    func openPathForEdit(_ remote: String) {
        guard sftp != nil else { statusLabel.stringValue = "远端未连接"; return }
        let name = (remote as NSString).lastPathComponent
        openRemoteFile(SFTPEntry(name: name, isDir: false, size: 0, mtime: Date(), perms: 0),
                       overridePath: remote)
    }

    // MARK: 供本地桥调用（不动 UI，直接走当前 SFTP 连接）
    func listForBridge(_ path: String, done: @escaping (Result<[SFTPEntry], Error>) -> Void) {
        whenReady { [weak self] ready in
            guard let self = self else { return }
            if case .failure(let e) = ready { done(.failure(e)); return }
            guard let sftp = self.sftp else {
                done(.failure(SFTPError.notConnected)); return
            }
            sftp.listDirectory(path.isEmpty ? self.remotePath : path) { done($0) }
        }
    }
    func downloadForBridge(remote: String, local: String, done: @escaping (String?) -> Void) {
        whenReady { [weak self] ready in
            guard let self = self else { return }
            if case .failure(let e) = ready { done(e.localizedDescription); return }
            guard let sftp = self.sftp else { done("SFTP 未连接"); return }
            sftp.download(remote: remote, local: local) { r in
                if case .failure(let e) = r { done(e.localizedDescription) } else { done(nil) }
            }
        }
    }
    func uploadForBridge(local: String, remote: String, done: @escaping (String?) -> Void) {
        whenReady { [weak self] ready in
            guard let self = self else { return }
            if case .failure(let e) = ready { done(e.localizedDescription); return }
            guard let sftp = self.sftp else { done("SFTP 未连接"); return }
            sftp.upload(local: local, remote: remote) { r in
                if case .failure(let e) = r { done(e.localizedDescription) } else { done(nil); self.reloadRemote() }
            }
        }
    }

    /// 编辑器保存 → 写回远端
    func saveRemoteFile(_ remote: String, text: String, done: @escaping (String?) -> Void) {
        guard let sftp = sftp else { done("远端未连接"); return }
        let tmp = NSTemporaryDirectory() + "pixshell_save_" + (remote as NSString).lastPathComponent
        do { try text.write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { done(error.localizedDescription); return }
        sftp.upload(local: tmp, remote: remote) { [weak self] r in
            switch r {
            case .success: done(nil); self?.reloadRemote()
            case .failure(let e): done(self?.msg(e) ?? "上传失败")
            }
        }
    }
    @objc func goUp() {
        guard remotePath != "/" else { return }
        remotePath = (remotePath as NSString).deletingLastPathComponent
        if remotePath.isEmpty { remotePath = "/" }
        reloadRemote()
    }
    /// 上传：单个小文件直传；多选 / 目录 / ≥8MB 走本地 tar 打包 → 上传 → 远端解压（老仓库 native-102）
    @objc func upload() {
        guard sftp != nil else { statusLabel.stringValue = "先连接远端"; return }
        // 本地栏已选 → 用之；否则弹文件选择器（支持多选 + 目录）
        var urls: [URL] = []
        if !localHidden {
            urls = localTable.selectedRowIndexes.compactMap { localEntries.indices.contains($0) ? localEntries[$0] : nil }
        }
        if urls.isEmpty {
            let p = NSOpenPanel()
            p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
            guard p.runModal() == .OK, !p.urls.isEmpty else { return }
            urls = p.urls
        }
        uploadItems(urls)
    }

    /// 上传一组本地项（拖拽/选择共用）
    func uploadItems(_ urls: [URL]) {
        guard let sftp = sftp, !urls.isEmpty else { return }
        let autoNeed = urls.count > 1 || urls.contains { u in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue { return true }
            let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return UInt64(sz) >= SFTPTransfer.packThreshold
        }
        // 打包传输关：全部直传；开：多项/目录/大文件走 tar
        let needPack = packTransferEnabled && autoNeed
        if !needPack {
            uploadDirect(urls, sftp: sftp)
            return
        }
        guard let ssh = execRunner else { statusLabel.stringValue = "需要 SSH 会话才能打包上传"; return }
        let st = SFTPTransfer.stamp()
        let localArchive = NSTemporaryDirectory() + "pixshell_up_\(st).tar.gz"
        let remoteArchive = "/tmp/pixshell_up_\(st).tar.gz"
        statusLabel.stringValue = "本地打包 \(urls.count) 项 …"
        Log.info("智能打包上传 \(urls.map { $0.lastPathComponent }.joined(separator: ", "))", "sftp")
        if let err = SFTPTransfer.packLocal(archive: localArchive, files: urls) {
            Log.error("本地打包失败: \(err)", "sftp"); statusLabel.stringValue = "打包失败: \(err)"; return
        }
        statusLabel.stringValue = "上传压缩包 …"
        sftp.upload(local: localArchive, remote: remoteArchive) { [weak self] r in
            guard let self = self else { return }
            try? FileManager.default.removeItem(atPath: localArchive)
            if case .failure(let e) = r {
                Log.error("压缩包上传失败: \(e)", "sftp")
                self.statusLabel.stringValue = "上传失败: \(self.msg(e))"; return
            }
            ssh(SFTPTransfer.extractCommand(archive: remoteArchive, into: self.remotePath)) { out in
                let parsed = SFTPTransfer.parseRemoteRC(out)
                if parsed.code != 0 {
                    let detail = parsed.message.isEmpty ? "exit \(parsed.code)" : parsed.message
                    Log.error("远端解压失败: \(detail)", "sftp")
                    self.statusLabel.stringValue = "远端解压失败: \(detail)"
                    // 解压失败时 extractCommand 仍会 rm 临时包；刷新以反映可能的部分写入
                    self.reloadRemote()
                    return
                }
                self.statusLabel.stringValue = "已上传并解压 \(urls.count) 项"
                Log.info("打包上传完成 → \(self.remotePath)", "sftp")
                self.reloadRemote()
            }
        }
    }
    /// 下载：打包开关开且（多选/目录/≥8MB）走远端 tar；否则逐项直传
    @objc func download() {
        guard let sftp = sftp else { statusLabel.stringValue = "远端未连接"; return }
        let items = targetRemoteEntries()
        guard !items.isEmpty else { statusLabel.stringValue = "先选远端文件"; return }
        let destDir = localHidden ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first! : localPath

        let needPack = packTransferEnabled && SFTPTransfer.shouldPack(items)
        if !needPack {
            downloadDirect(items, to: destDir, sftp: sftp)
            return
        }
        packedDownload(items, to: destDir)
    }

    /// 关闭打包时：逐项直传上传（目录跳过并提示）
    private func uploadDirect(_ urls: [URL], sftp: SFTPService) {
        var left = urls.count
        var skippedDirs = 0
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                skippedDirs += 1
                left -= 1
                if left == 0 {
                    statusLabel.stringValue = skippedDirs > 0
                        ? "直传完成（\(skippedDirs) 个目录已跳过，请开启「打包传输」）"
                        : "上传完成"
                    reloadRemote()
                }
                continue
            }
            statusLabel.stringValue = "上传 \(u.lastPathComponent) …"
            Log.info("直传上传 \(u.path) → \(join(remotePath, u.lastPathComponent))", "sftp")
            sftp.upload(local: u.path, remote: join(remotePath, u.lastPathComponent)) { [weak self] r in
                if case .failure(let e) = r {
                    Log.error("上传失败 \(u.path): \(e)", "sftp")
                    self?.statusLabel.stringValue = "上传失败: \(self?.msg(e) ?? "")"
                }
                left -= 1
                if left == 0 {
                    self?.statusLabel.stringValue = skippedDirs > 0
                        ? "直传完成（\(skippedDirs) 个目录已跳过，请开启「打包传输」）"
                        : "上传完成"
                    self?.reloadRemote()
                }
            }
        }
    }

    /// 关闭打包时：逐项直传下载（目录跳过并提示）
    private func downloadDirect(_ items: [SFTPEntry], to destDir: URL, sftp: SFTPService) {
        var left = items.count
        var skippedDirs = 0
        for e in items {
            if e.isDir {
                skippedDirs += 1
                left -= 1
                if left == 0 {
                    statusLabel.stringValue = skippedDirs > 0
                        ? "直传完成（\(skippedDirs) 个目录已跳过，请开启「打包传输」）"
                        : "下载完成"
                    reloadLocal()
                }
                continue
            }
            let local = destDir.appendingPathComponent(e.name).path
            statusLabel.stringValue = "下载 \(e.name) → \(destDir.lastPathComponent) …"
            Log.info("直传下载 \(join(remotePath, e.name)) → \(local)", "sftp")
            let task = DownloadTasks.shared.start(name: e.name, dest: local)
            sftp.download(remote: join(remotePath, e.name), local: local) { [weak self] r in
                switch r {
                case .success:
                    DownloadTasks.shared.finish(task, ok: true)
                case .failure(let er):
                    Log.error("下载失败 \(local): \(er)", "sftp")
                    DownloadTasks.shared.finish(task, ok: false, detail: self?.msg(er) ?? "")
                    self?.statusLabel.stringValue = "下载失败: \(self?.msg(er) ?? "")"
                }
                left -= 1
                if left == 0 {
                    self?.statusLabel.stringValue = skippedDirs > 0
                        ? "直传完成（\(skippedDirs) 个目录已跳过，请开启「打包传输」）"
                        : "下载完成: \(destDir.path)"
                    self?.reloadLocal()
                }
            }
        }
    }

    /// 远端打包 → 下载 → 本地解压 → 两端清理
    private func packedDownload(_ items: [SFTPEntry], to destDir: URL) {
        guard let sftp = sftp, let ssh = execRunner else { statusLabel.stringValue = "需要 SSH 会话才能打包"; return }
        let st = SFTPTransfer.stamp()
        let remoteArchive = "/tmp/pixshell_dl_\(st).tar.gz"
        let localArchive = NSTemporaryDirectory() + "pixshell_dl_\(st).tar.gz"
        let paths = items.map { join(remotePath, $0.name) }
        statusLabel.stringValue = "远端打包 \(items.count) 项 …"
        Log.info("智能打包下载 \(paths.joined(separator: ", "))", "sftp")
        ssh(SFTPTransfer.packCommand(archive: remoteArchive, remotePaths: paths)) { [weak self] out in
            guard let self = self else { return }
            let packed = SFTPTransfer.parseRemoteRC(out)
            if packed.code != 0 {
                let detail = packed.message.isEmpty ? "exit \(packed.code)" : packed.message
                Log.error("远端打包失败: \(detail)", "sftp")
                self.statusLabel.stringValue = "远端打包失败: \(detail)"
                self.execRunner?("rm -f \(SFTPTransfer.quote(remoteArchive))") { _ in }
                return
            }
            self.statusLabel.stringValue = "下载压缩包 …"
            sftp.download(remote: remoteArchive, local: localArchive) { r in
                self.execRunner?("rm -f \(SFTPTransfer.quote(remoteArchive))") { _ in }
                switch r {
                case .failure(let e):
                    Log.error("打包下载失败: \(e) 远端输出=\(packed.message)", "sftp")
                    self.statusLabel.stringValue = "下载失败: \(self.msg(e))"
                case .success:
                    if let err = SFTPTransfer.extractLocal(archive: localArchive, into: destDir.path) {
                        Log.error("本地解压失败: \(err)", "sftp")
                        self.statusLabel.stringValue = "解压失败: \(err)"
                    } else {
                        self.statusLabel.stringValue = "已下载并解压 \(items.count) 项 → \(destDir.path)"
                        Log.info("打包下载完成 → \(destDir.path)", "sftp")
                        self.reloadLocal()
                    }
                    try? FileManager.default.removeItem(atPath: localArchive)
                }
            }
        }
    }
    @objc func refresh() { reloadLocal(); reloadRemote() }
    @objc func mkdir() {
        guard let sftp = sftp else { return }
        let name = prompt("新建远端目录名"); guard !name.isEmpty else { return }
        sftp.makeDirectory(join(remotePath, name)) { [weak self] r in
            if case .failure(let e) = r { self?.statusLabel.stringValue = "新建失败: \(self?.msg(e) ?? "")" } else { self?.reloadRemote() }
        }
    }
    @objc func del() {
        let row = remoteTable.selectedRow
        guard row >= 0, row < remoteEntries.count, let sftp = sftp else { return }
        let e = remoteEntries[row]
        sftp.remove(join(remotePath, e.name)) { [weak self] r in
            if case .failure(let er) = r { self?.statusLabel.stringValue = "删除失败: \(self?.msg(er) ?? "")" } else { self?.reloadRemote() }
        }
    }

    // MARK: 传输自测（保留）
    private func runSelfTestIfNeeded() {
        guard ProcessInfo.processInfo.environment["PIXSHELL_SFTP_SELFTEST"] == "1", let sftp = sftp else { return }
        let content = "pixshell-sftp-selftest-roundtrip"
        let up = NSTemporaryDirectory() + "pix_up.txt"; let down = NSTemporaryDirectory() + "pix_down.txt"
        try? content.data(using: .utf8)?.write(to: URL(fileURLWithPath: up))
        let remote = join(remotePath, "pix_sftp_selftest.txt")
        print("SFTP_SELFTEST_RESULT: UPLOAD_START remote=\(remote)")
        sftp.upload(local: up, remote: remote) { [weak self] r in
            guard let self = self else { return }
            if case .failure(let e) = r { print("SFTP_SELFTEST_RESULT: UPLOAD_FAIL \(self.msg(e))"); return }
            sftp.download(remote: remote, local: down) { r2 in
                if case .failure(let e) = r2 { print("SFTP_SELFTEST_RESULT: DOWNLOAD_FAIL \(self.msg(e))"); return }
                let got = (try? String(contentsOfFile: down, encoding: .utf8)) ?? ""
                print("SFTP_SELFTEST_RESULT: \(got == content ? "PASS" : "FAIL got=\(got)")")
                sftp.remove(remote) { _ in }; self.reloadRemote()
            }
        }
    }

    // MARK: 辅助
    private func join(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }
    private func msg(_ e: Error) -> String { "\(e)" }
    private func humanSize(_ n: UInt64) -> String {
        if n == 0 { return "" }
        let u = ["B", "K", "M", "G", "T"]; var v = Double(n); var i = 0
        while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n)B" : String(format: "%.1f%@", v, u[i])
    }
    private func prompt(_ title: String, preset: String) -> String {
        let a = NSAlert.pix(); a.messageText = title; a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        tf.stringValue = preset
        a.accessoryView = tf; a.window.initialFirstResponder = tf
        return a.runModal() == .alertFirstButtonReturn ? tf.stringValue : ""
    }
    private func prompt(_ title: String) -> String {
        let a = NSAlert.pix(); a.messageText = title; a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22)); a.accessoryView = tf
        return a.runModal() == .alertFirstButtonReturn ? tf.stringValue : ""
    }
    private func icon(dir: Bool, link: Bool) -> NSImage? {
        let sym = dir ? "folder.fill" : (link ? "arrow.up.forward.square.fill" : "doc.fill")
        let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        return img
    }

    // 通用：图标+文本 名称单元格
    private func nameCell(_ text: String, dir: Bool, link: Bool) -> NSView {
        let cell = NSTableCellView()
        let iv = NSImageView(); iv.image = icon(dir: dir, link: link)
        iv.contentTintColor = dir ? folderColor : (link ? Theme.accent : Theme.muted)
        iv.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField(labelWithString: text); tf.font = Theme.ui(12); tf.textColor = dir ? Theme.text : Theme.text
        tf.lineBreakMode = .byTruncatingTail; tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv); cell.addSubview(tf); cell.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 14), iv.heightAnchor.constraint(equalToConstant: 14),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    private func textCell(_ text: String, color: NSColor? = nil) -> NSView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text); tf.font = Theme.ui(11); tf.textColor = color ?? Theme.muted
        tf.lineBreakMode = .byTruncatingTail; tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf); cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: NSTableViewDataSource / Delegate（文件明细，view-based）
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === localTable ? localEntries.count : remoteEntries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let colId = tableColumn?.identifier.rawValue ?? "name"
        if tableView === localTable {
            let url = localEntries[row]
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = rv?.isDirectory ?? false
            switch colId {
            case "name": return nameCell(url.lastPathComponent, dir: isDir, link: false)
            case "size": return textCell(isDir ? "" : humanSize(UInt64(rv?.fileSize ?? 0)))
            case "type": return textCell(isDir ? "目录" : "文件")
            default:     return textCell(rv?.contentModificationDate.map { df.string(from: $0) } ?? "")
            }
        } else {
            let e = remoteEntries[row]
            let link = (e.perms & 0xF000) == 0xA000
            switch colId {
            case "name": return nameCell(e.name, dir: e.isDir, link: link)
            case "size": return textCell(e.isDir ? "" : humanSize(e.size))
            case "type": return textCell(e.isDir ? "目录" : (link ? "链接" : "文件"), color: e.isDir ? Theme.accent : Theme.muted)
            default:     return textCell(e.mtime.timeIntervalSince1970 > 0 ? df.string(from: e.mtime) : "")
            }
        }
    }

    // MARK: NSOutlineViewDataSource / Delegate（远端目录树）
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? SFTPNode) ?? treeRoot
        if item == nil { return 1 } // 根
        return node.children?.count ?? 0
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return treeRoot }
        guard let node = item as? SFTPNode, let kids = node.children, kids.indices.contains(index) else { return treeRoot }
        return kids[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SFTPNode else { return false }
        return node.children == nil || !(node.children?.isEmpty ?? true)
    }
    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SFTPNode else { return nil }
        return nameCell(node.name, dir: true, link: false)
    }
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SFTPNode else { return }
        if node.children == nil { loadChildren(node) }
    }
}
