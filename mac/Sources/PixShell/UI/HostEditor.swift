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
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let groupField = NSTextField()
    private let keyPathField = NSTextField()
    private let keyPathButton = NSButton(title: "选择…", target: nil, action: nil)

    init(host: Host?, password: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 274))
        // 连接类型：SSH（默认）/ RDP。RDP 主机连接时拉起系统远程桌面，不建 SSH 会话。
        typePopup.addItems(withTitles: ["SSH", "RDP（远程桌面）"])
        typePopup.selectItem(at: (host?.isRdp ?? false) ? 1 : 0)
        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))
        nameField.stringValue = host?.name ?? ""
        hostField.stringValue = host?.host ?? ""
        portField.stringValue = String(host?.port ?? 22)
        userField.stringValue = host?.username ?? "root"
        passField.stringValue = password ?? ""
        groupField.stringValue = host?.group ?? ""
        keyPathField.stringValue = host?.keyPath ?? ""
        keyPathField.placeholderString = "留空则使用密码登录"

        keyPathButton.target = self
        keyPathButton.action = #selector(chooseKeyFile(_:))
        keyPathButton.translatesAutoresizingMaskIntoConstraints = false
        keyPathField.translatesAutoresizingMaskIntoConstraints = false
        keyPathField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let keyRow = NSStackView(views: [keyPathField, keyPathButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 6
        keyRow.translatesAutoresizingMaskIntoConstraints = false

        let rows: [(String, NSView)] = [
            ("类型", typePopup),
            ("名称", nameField), ("主机", hostField), ("端口", portField),
            ("用户名", userField), ("密码", passField), ("分组", groupField),
            ("私钥", keyRow),
        ]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        for (label, view) in rows {
            view.translatesAutoresizingMaskIntoConstraints = false
            if view !== keyRow {
                view.widthAnchor.constraint(equalToConstant: 250).isActive = true
            }
            let lab = NSTextField(labelWithString: label)
            lab.alignment = .right
            grid.addRow(with: [lab, view])
        }
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    var password: String { passField.stringValue }

    /// 切到 RDP 且端口还是 SSH 默认 22 → 顺手改成 3389；切回 SSH 且端口是 3389 → 改回 22。
    @objc private func typeChanged(_ sender: NSPopUpButton) {
        let p = Int(portField.stringValue.trimmingCharacters(in: .whitespaces))
        if sender.indexOfSelectedItem == 1, p == 22 { portField.stringValue = "3389" }
        else if sender.indexOfSelectedItem == 0, p == 3389 { portField.stringValue = "22" }
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
        h.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        h.port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22
        let u = userField.stringValue.trimmingCharacters(in: .whitespaces)
        h.username = u.isEmpty ? "root" : u
        h.group = groupField.stringValue.trimmingCharacters(in: .whitespaces)
        h.keyPath = keyPathField.stringValue.trimmingCharacters(in: .whitespaces)
        h.connectionType = typePopup.indexOfSelectedItem == 1 ? 200 : 100
        return h
    }
}
