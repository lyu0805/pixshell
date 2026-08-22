import Foundation

/// SFTP 传输执行器：从 SFTPPanel 拆出的传输流程编排（直传 / tar 打包传输）。
/// 只做 IO 与流程；UI 通过回调拿状态文案和「列表已变」通知。面板不再各自实现
/// 上传/下载细节，这个类型后续可直接复用为全局后台传输管理器的执行核。
///
/// 线程语义与拆分前的面板内实现保持一致：SFTPService 的 completion 在哪个线程
/// 回来，onStatus 就在那个线程被调（面板侧负责只做轻量赋值）。
final class SFTPTransferQueue {
    /// 状态文案（上传中/完成/失败等，原 statusLabel.stringValue 的内容）。
    var onStatus: ((String) -> Void)?
    /// 远端列表发生变化（上传/远端解压完成 → 需要刷新远端表格）。
    var onRemoteChanged: (() -> Void)?
    /// 本地列表发生变化（下载/本地解压完成 → 需要刷新本地表格）。
    var onLocalChanged: (() -> Void)?

    private func status(_ s: String) { onStatus?(s) }
    private func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
    private func msg(_ e: Error) -> String { "\(e)" }

    // MARK: - 上传

    /// 打包开关关闭（或单个小文件）：逐项直传上传；目录跳过并在完成文案里提示。
    func uploadDirect(_ urls: [URL], remotePath: String, sftp: SFTPService) {
        var left = urls.count
        var skippedDirs = 0
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                skippedDirs += 1
                left -= 1
                if left == 0 {
                    status(skippedDirs > 0
                        ? "直传完成（\(skippedDirs) 个目录已跳过，请开启「打包传输」）"
                        : "上传完成")
                    onRemoteChanged?()
                }
                continue
            }
            status("上传 \(u.lastPathComponent) …")
            Log.info("直传上传 \(u.path) → \(join(remotePath, u.lastPathComponent))", "sftp")
            sftp.upload(local: u.path, remote: join(remotePath, u.lastPathComponent)) { [weak self] r in
                if case .failure(let e) = r {
                    Log.error("上传失败 \(u.path): \(e)", "sftp")
                    self?.status("上传失败: \(self?.msg(e) ?? "")")
                }
                left -= 1
                if left == 0 {
                    self?.status(skippedDirs > 0
                        ? "直传完成（\(skippedDirs) 个目录已跳过，请开启「打包传输」）"
                        : "上传完成")
                    self?.onRemoteChanged?()
                }
            }
        }
    }

    /// 打包上传：本地 tar.gz → 上传 → 远端解压（解压命令自带临时包清理）。
    /// - ssh：远端一次性命令执行器（交互会话的 exec 通道）。
    func uploadPacked(_ urls: [URL], remotePath: String, sftp: SFTPService,
                      ssh: @escaping (String, @escaping (String) -> Void) -> Void) {
        let st = SFTPTransfer.stamp()
        let localArchive = NSTemporaryDirectory() + "pixshell_up_\(st).tar.gz"
        let remoteArchive = "/tmp/pixshell_up_\(st).tar.gz"
        status("本地打包 \(urls.count) 项 …")
        Log.info("智能打包上传 \(urls.map { $0.lastPathComponent }.joined(separator: ", "))", "sftp")
        if let err = SFTPTransfer.packLocal(archive: localArchive, files: urls) {
            Log.error("本地打包失败: \(err)", "sftp")
            status("打包失败: \(err)")
            return
        }
        status("上传压缩包 …")
        sftp.upload(local: localArchive, remote: remoteArchive) { [weak self] r in
            guard let self = self else { return }
            try? FileManager.default.removeItem(atPath: localArchive)
            if case .failure(let e) = r {
                Log.error("压缩包上传失败: \(e)", "sftp")
                self.status("上传失败: \(self.msg(e))")
                return
            }
            ssh(SFTPTransfer.extractCommand(archive: remoteArchive, into: remotePath)) { [weak self] out in
                guard let self = self else { return }
                let parsed = SFTPTransfer.parseRemoteRC(out)
                if parsed.code != 0 {
                    let detail = parsed.message.isEmpty ? "exit \(parsed.code)" : parsed.message
                    Log.error("远端解压失败: \(detail)", "sftp")
                    self.status("远端解压失败: \(detail)")
                    // 解压失败时 extractCommand 仍会 rm 临时包；刷新以反映可能的部分写入
                    self.onRemoteChanged?()
                    return
                }
                self.status("已上传并解压 \(urls.count) 项")
                Log.info("打包上传完成 → \(remotePath)", "sftp")
                self.onRemoteChanged?()
            }
        }
    }

    // MARK: - 下载

    /// 打包开关关闭：逐项直传下载；目录跳过并在完成文案里提示。
    /// 下载接入 DownloadTasks（状态栏传输指示），与拆分前一致。
    func downloadDirect(_ items: [SFTPEntry], remotePath: String, to destDir: URL, sftp: SFTPService) {
        var left = items.count
        var skippedDirs = 0
        for e in items {
            if e.isDir {
                skippedDirs += 1
                left -= 1
                if left == 0 {
                    status(skippedDirs > 0
                        ? "直传完成（\(skippedDirs) 个目录已跳过，请开启「打包传输」）"
                        : "下载完成")
                    onLocalChanged?()
                }
                continue
            }
            let local = destDir.appendingPathComponent(e.name).path
            status("下载 \(e.name) → \(destDir.lastPathComponent) …")
            Log.info("直传下载 \(join(remotePath, e.name)) → \(local)", "sftp")
            let task = DownloadTasks.shared.start(name: e.name, dest: local)
            sftp.download(remote: join(remotePath, e.name), local: local) { [weak self] r in
                switch r {
                case .success:
                    DownloadTasks.shared.finish(task, ok: true)
                case .failure(let er):
                    Log.error("下载失败 \(local): \(er)", "sftp")
                    DownloadTasks.shared.finish(task, ok: false, detail: self?.msg(er) ?? "")
                    self?.status("下载失败: \(self?.msg(er) ?? "")")
                }
                left -= 1
                if left == 0 {
                    self?.status(skippedDirs > 0
                        ? "直传完成（\(skippedDirs) 个目录已跳过，请开启「打包传输」）"
                        : "下载完成: \(destDir.path)")
                    self?.onLocalChanged?()
                }
            }
        }
    }

    /// 打包下载：远端 tar.gz 打包 → 下载 → 本地解压 → 两端清理。
    func downloadPacked(_ items: [SFTPEntry], remotePath: String, to destDir: URL,
                        sftp: SFTPService,
                        ssh: @escaping (String, @escaping (String) -> Void) -> Void) {
        let st = SFTPTransfer.stamp()
        let remoteArchive = "/tmp/pixshell_dl_\(st).tar.gz"
        let localArchive = NSTemporaryDirectory() + "pixshell_dl_\(st).tar.gz"
        let paths = items.map { join(remotePath, $0.name) }
        status("远端打包 \(items.count) 项 …")
        Log.info("智能打包下载 \(paths.joined(separator: ", "))", "sftp")
        ssh(SFTPTransfer.packCommand(archive: remoteArchive, remotePaths: paths)) { [weak self] out in
            guard let self = self else { return }
            let packed = SFTPTransfer.parseRemoteRC(out)
            if packed.code != 0 {
                let detail = packed.message.isEmpty ? "exit \(packed.code)" : packed.message
                Log.error("远端打包失败: \(detail)", "sftp")
                self.status("远端打包失败: \(detail)")
                ssh("rm -f \(SFTPTransfer.quote(remoteArchive))") { _ in }
                return
            }
            self.status("下载压缩包 …")
            sftp.download(remote: remoteArchive, local: localArchive) { r in
                ssh("rm -f \(SFTPTransfer.quote(remoteArchive))") { _ in }
                switch r {
                case .failure(let e):
                    Log.error("打包下载失败: \(e) 远端输出=\(packed.message)", "sftp")
                    self.status("下载失败: \(self.msg(e))")
                case .success:
                    if let err = SFTPTransfer.extractLocal(archive: localArchive, into: destDir.path) {
                        Log.error("本地解压失败: \(err)", "sftp")
                        self.status("解压失败: \(err)")
                    } else {
                        self.status("已下载并解压 \(items.count) 项 → \(destDir.path)")
                        Log.info("打包下载完成 → \(destDir.path)", "sftp")
                        self.onLocalChanged?()
                    }
                    try? FileManager.default.removeItem(atPath: localArchive)
                }
            }
        }
    }
}
