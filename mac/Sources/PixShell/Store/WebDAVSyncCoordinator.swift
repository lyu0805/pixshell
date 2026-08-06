import Foundation

/// WebDAV 多设备双向同步：ETag 防覆盖 + 每台设备保存上次同步基线 + 三方合并。
/// 密码仍只在本机 Keychain，不进入备份包。
final class WebDAVSyncCoordinator {
    static let enabledKey = "pixshell.webdav.autoSync"
    static let intervalKey = "pixshell.webdav.syncInterval"
    private static let baseKey = "pixshell.webdav.syncBase"

    var makeLocalBundle: (() -> BackupBundle)?
    var applyMergedBundle: ((BackupBundle) -> Void)?
    var statusChanged: ((String) -> Void)?

    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var syncing = false
    private var retrying = false

    static let logChanged = Notification.Name("PixShellWebDAVSyncLogChanged")
    private static let logKey = "pixshell.webdav.syncLog"

    static var logLines: [String] { UserDefaults.standard.stringArray(forKey: logKey) ?? [] }
    private static func appendLog(_ message: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
        var lines = logLines
        lines.append("[\(formatter.string(from: Date()))] \(message)")
        if lines.count > 100 { lines.removeFirst(lines.count - 100) }
        UserDefaults.standard.set(lines, forKey: logKey)
        NotificationCenter.default.post(name: logChanged, object: nil)
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); newValue ? start() : stop() }
    }
    var interval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: Self.intervalKey)
        return value > 0 ? max(30, value) : 300
    }

    func start() {
        stopTimer()
        guard enabled, WebDAVBackup.load() != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sync(reason: "定时") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.sync(reason: "启动") }
    }

    func stop() { debounce?.cancel(); debounce = nil; stopTimer() }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    func localDidChange() {
        guard enabled, !syncing else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync(reason: "本地修改") }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func sync(reason: String = "手动") {
        guard enabled, !syncing, let config = WebDAVBackup.load(), let local = makeLocalBundle?() else { return }
        syncing = true
        Self.appendLog("开始同步（\(reason)）")
        statusChanged?("WebDAV 同步中…")
        WebDAVBackup.fetchRaw(config) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.finish(error: error)
            case .success(let response):
                if response.status == 404 {
                    Self.appendLog("远端备份不存在，准备创建")
                    self.upload(local, config: config, etag: nil, createOnly: true)
                    return
                }
                guard let data = response.data, let remote = try? BackupBundle.decode(data) else {
                    self.finish(error: NSError(domain: "PixShell", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "远端备份格式无效"])); return
                }
                let base = self.loadBase()
                let merged = self.merge(local: local, remote: remote, base: base)
                Self.appendLog("已下载并合并：主机 \(merged.bundle.hosts.count)，快捷命令 \(merged.bundle.quickCommands.count)，冲突 \(merged.conflicts)")
                if !self.sameContent(merged.bundle, local) { self.applyMergedBundle?(merged.bundle) }
                if self.sameContent(merged.bundle, remote) {
                    self.saveBase(merged.bundle)
                    self.finish(message: merged.conflicts == 0 ? "WebDAV 已同步" : "WebDAV 已同步（\(merged.conflicts) 个冲突保留本机版本）")
                } else {
                    self.upload(merged.bundle, config: config, etag: response.etag, createOnly: false,
                                conflictCount: merged.conflicts)
                }
            }
        }
        Log.info("WebDAV 双向同步触发：\(reason)", "backup")
    }

    private func upload(_ bundle: BackupBundle, config: WebDAVBackup.Config, etag: String?,
                        createOnly: Bool, conflictCount: Int = 0) {
        do {
            let data = try bundle.encoded()
            Self.appendLog(createOnly ? "正在创建远端备份" : "正在上传合并结果")
            WebDAVBackup.putRaw(config, data: data, etag: etag, createOnly: createOnly) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.retrying = false; self.saveBase(bundle)
                    self.finish(message: conflictCount == 0 ? "WebDAV 已同步" : "WebDAV 已同步（\(conflictCount) 个冲突保留本机版本）")
                case .failure(let error) where (error as NSError).code == 412 && !self.retrying:
                    // ETag 已变化：另一设备抢先上传，重新下载并合并一次。
                    Self.appendLog("检测到另一设备已更新，重新下载合并")
                    self.syncing = false; self.retrying = true; self.sync(reason: "并发重试")
                case .failure(let error): self.retrying = false; self.finish(error: error)
                }
            }
        } catch { finish(error: error) }
    }

    private func finish(message: String) { syncing = false; Self.appendLog(message); statusChanged?(message); Log.info(message, "backup") }
    private func finish(error: Error) {
        syncing = false
        let message = "WebDAV 同步失败：\(error.localizedDescription)"
        Self.appendLog(message)
        statusChanged?(message); Log.error(message, "backup")
    }

    private func loadBase() -> BackupBundle? {
        guard let data = UserDefaults.standard.data(forKey: Self.baseKey) else { return nil }
        return try? BackupBundle.decode(data)
    }
    private func saveBase(_ bundle: BackupBundle) {
        if let data = try? bundle.encoded() { UserDefaults.standard.set(data, forKey: Self.baseKey) }
        UserDefaults.standard.set(Date(), forKey: "pixshell.webdav.lastSync")
    }
    private func sameContent(_ a: BackupBundle, _ b: BackupBundle) -> Bool {
        a.hosts == b.hosts && a.quickCommands == b.quickCommands && a.settings == b.settings
    }

    private func merge(local: BackupBundle, remote: BackupBundle, base: BackupBundle?) -> (bundle: BackupBundle, conflicts: Int) {
        var conflicts = 0
        let hosts = mergeRecords(local.hosts, remote.hosts, base?.hosts ?? [], id: { $0.id }, conflicts: &conflicts)
        let commands = mergeRecords(local.quickCommands, remote.quickCommands, base?.quickCommands ?? [], id: { $0.id }, conflicts: &conflicts)
        let settings = mergeSettings(local.settings, remote.settings, base?.settings ?? [:], conflicts: &conflicts)
        return (BackupBundle.make(hosts: hosts, quick: commands, settings: settings), conflicts)
    }

    private func mergeRecords<T: Equatable>(_ local: [T], _ remote: [T], _ base: [T],
                                             id: (T) -> String, conflicts: inout Int) -> [T] {
        let lm = Dictionary(uniqueKeysWithValues: local.map { (id($0), $0) })
        let rm = Dictionary(uniqueKeysWithValues: remote.map { (id($0), $0) })
        let bm = Dictionary(uniqueKeysWithValues: base.map { (id($0), $0) })
        var order = local.map(id); for key in remote.map(id) where !order.contains(key) { order.append(key) }
        return order.compactMap { key in
            let l = lm[key], r = rm[key], b = bm[key]
            if l == r { return l }
            if l == b { return r }
            if r == b { return l }
            conflicts += 1
            return l ?? r
        }
    }

    private func mergeSettings(_ local: [String: String], _ remote: [String: String], _ base: [String: String],
                               conflicts: inout Int) -> [String: String] {
        var result: [String: String] = [:]
        for key in Set(local.keys).union(remote.keys).union(base.keys) {
            let l = local[key], r = remote[key], b = base[key]
            if l == r { result[key] = l }
            else if l == b { result[key] = r }
            else if r == b { result[key] = l }
            else { conflicts += 1; result[key] = l ?? r }
        }
        return result
    }
}
