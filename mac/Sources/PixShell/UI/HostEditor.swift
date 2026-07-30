import AppKit

/// 新建/编辑主机的表单（以 NSAlert + 附件视图形式弹出为 sheet）。
enum HostEditor {
    static func present(over window: NSWindow, host: Host?, password: String?,
                        completion: @escaping (Host, String) -> Void) {
        let alert = NSAlert.pix()
        alert.messageText = host == nil ? "新建连接" : "编辑连接"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let form = HostFormView(host: host, password: password)
        alert.accessoryView = form
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            completion(form.buildHost(base: host), form.password)
        }
    }
}

final class HostFormView: NSView {
    private let typePopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let webUrlField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let groupField = NSTextField()
    private let keyPathField = NSTextField()
    private let keyPathButton = NSButton(title: "选择…", target: nil, action: nil)
    private var hostLabel: NSTextField?
    private var webUrlLabel: NSTextField?
    private var webUrlRow: NSGridCell?
    private var grid: NSGridView!

    init(host: Host?, password: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 310))
        // 连接类型：SSH / RDP / Web。
        // Web = 应用内 WKWebView：可填外部 https（noVNC/面板），或留空 URL 走本地桥 WebSSH。
        typePopup.addItems(withTitles: ["SSH", "RDP（远程桌面）", "Web（应用内页面/终端）"])
        if host?.isWebSSH == true { typePopup.selectItem(at: 2) }
        else if host?.isRdp == true { typePopup.selectItem(at: 1) }
        else { typePopup.selectItem(at: 0) }
        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))
        nameField.stringValue = host?.name ?? ""
        // 若历史把完整 URL 写在 host，编辑时回填到 URL 框
        if let existing = host, existing.isWebSSH, let u = existing.resolvedWebURL {
            webUrlField.stringValue = existing.webUrl.isEmpty ? u.absoluteString : existing.webUrl
            hostField.stringValue = (existing.host.hasPrefix("http://") || existing.host.hasPrefix("https://"))
                ? (u.host ?? "") : existing.host
        } else {
            hostField.stringValue = host?.host ?? ""
            webUrlField.stringValue = host?.webUrl ?? ""
        }
        portField.stringValue = String(host?.port ?? 22)
        userField.stringValue = host?.username ?? "root"
        passField.stringValue = password ?? ""
        groupField.stringValue = host?.group ?? ""
        keyPathField.stringValue = host?.keyPath ?? ""
        keyPathField.placeholderString = "留空则使用密码登录"
        webUrlField.placeholderString = "https://…/vnc  （noVNC / 面板；留空=本地桥 WebSSH）"

        keyPathButton.target = self
        keyPathButton.action = #selector(chooseKeyFile(_:))
        keyPathButton.translatesAutoresizingMaskIntoConstraints = false
        keyPathField.translatesAutoresizingMaskIntoConstraints = false
        keyPathField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let keyRow = NSStackView(views: [keyPathField, keyPathButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 6
        keyRow.translatesAutoresizingMaskIntoConstraints = false

        let hostLab = NSTextField(labelWithString: "主机")
        hostLab.alignment = .right
        hostLabel = hostLab
        let urlLab = NSTextField(labelWithString: "URL")
        urlLab.alignment = .right
        webUrlLabel = urlLab

        let rows: [(NSTextField, NSView)] = [
            (NSTextField(labelWithString: "类型"), typePopup),
            (NSTextField(labelWithString: "名称"), nameField),
            (hostLab, hostField),
            (urlLab, webUrlField),
            (NSTextField(labelWithString: "端口"), portField),
            (NSTextField(labelWithString: "用户名"), userField),
            (NSTextField(labelWithString: "密码"), passField),
            (NSTextField(labelWithString: "分组"), groupField),
            (NSTextField(labelWithString: "私钥"), keyRow),
        ]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        self.grid = grid
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        for (lab, view) in rows {
            lab.alignment = .right
            lab.translatesAutoresizingMaskIntoConstraints = false
            view.translatesAutoresizingMaskIntoConstraints = false
            if view !== keyRow {
                view.widthAnchor.constraint(equalToConstant: 270).isActive = true
            }
            grid.addRow(with: [lab, view])
        }
        // URL 行索引 3（类型0 名称1 主机2 URL3）
        webUrlRow = grid.cell(atColumnIndex: 1, rowIndex: 3)
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        applyTypeUI(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    var password: String { passField.stringValue }

    /// 切到 RDP 且端口还是 SSH 默认 22 → 顺手改成 3389；
    /// 切回 SSH/Web 且端口是 3389 → 改回 22。
    /// Web：露出 URL 行（noVNC/外部页）；SSH/RDP 藏 URL。
    @objc private func typeChanged(_ sender: NSPopUpButton) {
        let p = Int(portField.stringValue.trimmingCharacters(in: .whitespaces))
        let idx = sender.indexOfSelectedItem
        if idx == 1, p == 22 { portField.stringValue = "3389" }
        else if (idx == 0 || idx == 2), p == 3389 { portField.stringValue = "22" }
        applyTypeUI(animated: true)
    }

    private func applyTypeUI(animated: Bool) {
        let isWeb = typePopup.indexOfSelectedItem == 2
        // URL 行：Web 显示，其它隐藏（row 仍占位用 isHidden）
        webUrlField.isHidden = !isWeb
        webUrlLabel?.isHidden = !isWeb
        if isWeb {
            hostLabel?.stringValue = "主机"
            hostField.placeholderString = "可选；或把完整 URL 只填在 URL 框"
            if userField.stringValue == "root" || userField.stringValue.isEmpty {
                // 外部 Web 常不需要 SSH 用户；不强制改已填内容
            }
        } else {
            hostField.placeholderString = ""
        }
        // 缩表单高度：Web 多一行
        let h: CGFloat = isWeb ? 310 : 274
        if abs(frame.height - h) > 1 {
            setFrameSize(NSSize(width: frame.width, height: h))
            if animated, let alert = enclosingAlert() {
                // NSAlert accessory 变高时尽量刷新
                needsLayout = true
                alert.window.layoutIfNeeded()
            }
        }
    }

    private func enclosingAlert() -> NSAlert? {
        var r: NSView? = self
        while let v = r {
            if let a = v.window?.windowController as? NSAlert { return a }
            r = v.superview
        }
        return nil
    }

    // 私钥文件选择：只选文件、显示隐藏文件（否则 ~/.ssh 这类点开头目录默认不可见）。
    @objc private func chooseKeyFile(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.title = "选择私钥文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.directoryURL = (try? sshDir.checkResourceIsReachable()) == true ? sshDir : FileManager.default.homeDirectoryForCurrentUser
        if let win = self.window {
            panel.beginSheetModal(for: win) { [weak self] resp in
                guard resp == .OK, let url = panel.url else { return }
                self?.keyPathField.stringValue = url.path
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url { keyPathField.stringValue = url.path }
        }
    }

    func buildHost(base: Host?) -> Host {
        var h = base ?? Host()
        h.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        var hostVal = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        var urlVal = webUrlField.stringValue.trimmingCharacters(in: .whitespaces)
        // 主机框误填完整 URL → 归一到 webUrl
        if urlVal.isEmpty,
           let u = URL(string: hostVal),
           let scheme = u.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           u.host != nil {
            urlVal = hostVal
            hostVal = u.host ?? ""
        }
        h.host = hostVal
        h.webUrl = urlVal
        h.port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22
        let u = userField.stringValue.trimmingCharacters(in: .whitespaces)
        h.group = groupField.stringValue.trimmingCharacters(in: .whitespaces)
        h.keyPath = keyPathField.stringValue.trimmingCharacters(in: .whitespaces)
        switch typePopup.indexOfSelectedItem {
        case 1: h.connectionType = 200   // RDP
        case 2: h.connectionType = 400   // Web（外部页 或 本地桥终端）
        default: h.connectionType = 100  // SSH
        }
        if h.connectionType == 400 {
            h.username = u.isEmpty ? "web" : u
            if h.osId.isEmpty { h.osId = "web" }
            // 外部 URL 且没名称 → 用 host 当显示名
            if h.name.isEmpty, let web = h.resolvedWebURL {
                h.name = web.host ?? "Web"
            }
        } else {
            h.username = u.isEmpty ? "root" : u
            h.webUrl = ""   // 非 Web 不留 webUrl，避免脏数据
        }
        return h
    }
}
