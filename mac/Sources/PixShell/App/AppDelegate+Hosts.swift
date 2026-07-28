import AppKit

// 主机增改删（主机列表现在在连接管理器弹窗里；改动后刷新它）。
extension AppDelegate {
    private func refreshHostUI() { tableView?.reloadData(); connMgr?.reload(); quickConnect?.reload() }

    @objc func addHost() {
        HostEditor.present(over: window, host: nil, password: nil) { [weak self] h, pass in
            self?.store.upsert(h); Keychain.setPassword(pass, for: h.id, label: h.host.isEmpty ? h.name : h.host); self?.refreshHostUI()
        }
    }
    func editHostDirect(_ host: Host) {
        HostEditor.present(over: window, host: host, password: Keychain.password(for: host.id)) { [weak self] h, pass in
            self?.store.upsert(h); Keychain.setPassword(pass, for: h.id, label: h.host.isEmpty ? h.name : h.host); self?.refreshHostUI()
        }
    }
    @objc func editHost() {
        guard let tv = tableView, tv.selectedRow >= 0, tv.selectedRow < store.hosts.count else { return }
        editHostDirect(store.hosts[tv.selectedRow])
    }
    @objc func deleteHost() {
        guard let tv = tableView, tv.selectedRow >= 0, tv.selectedRow < store.hosts.count else { return }
        let host = store.hosts[tv.selectedRow]; store.delete(host.id); Keychain.delete(host.id); refreshHostUI()
    }

    // NSTableView 数据源保留（当前无侧栏表使用；连接管理器用自绘列表）。
    func numberOfRows(in tableView: NSTableView) -> Int { store.hosts.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
}
