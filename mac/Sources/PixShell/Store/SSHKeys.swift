import Foundation

/// SSH 密钥管理（对应老仓库 config.json 的 `secret_key_list`）。
///
/// 生成/读指纹一律调用系统 `ssh-keygen`，不自己实现密钥生成 ——
/// 那是安全关键代码，标准工具生成的密钥格式也最通用（OpenSSH 新格式 + .pub）。
enum SSHKeys {

    /// 生成失败的原因（String 不能直接当 Error 用）。
    struct GenError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct KeyInfo {
        let path: String          // 私钥路径
        let name: String          // 文件名
        let type: String          // ED25519 / RSA / ECDSA…
        let bits: String          // 位数（ssh-keygen 报告）
        let fingerprint: String   // SHA256:…
        let comment: String
        let hasPublic: Bool       // 是否存在同名 .pub
        let encrypted: Bool       // 私钥是否带口令
    }

    static var sshDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// 扫描 ~/.ssh 下的私钥。判定方式：有同名 .pub，或文件头是 PEM/OPENSSH 私钥标记。
    static func list() -> [KeyInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sshDir.path) else { return [] }
        var out: [KeyInfo] = []
        for n in names.sorted() {
            if n.hasSuffix(".pub") || n == "known_hosts" || n == "config" || n == "authorized_keys" { continue }
            if n.hasPrefix(".") { continue }
            let p = sshDir.appendingPathComponent(n).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { continue }
            let pubPath = p + ".pub"
            let hasPub = fm.fileExists(atPath: pubPath)
            let head = (try? String(contentsOfFile: p, encoding: .utf8))?.prefix(120) ?? ""
            let looksPrivate = head.contains("PRIVATE KEY")
            guard hasPub || looksPrivate else { continue }
            let info = inspect(path: p, hasPublic: hasPub)
            out.append(info)
        }
        return out
    }

    /// 用 `ssh-keygen -l` 读指纹/类型/位数；失败也要给一条能显示的记录。
    private static func inspect(path: String, hasPublic: Bool) -> KeyInfo {
        let name = (path as NSString).lastPathComponent
        let head = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // OpenSSH 新格式加密私钥里没有 "ENCRYPTED" 字样，靠 ssh-keygen -y 是否要口令来判断代价太大，
        // 这里用两种常见标记做保守判断，仅用于界面提示。
        let encrypted = head.contains("ENCRYPTED") || head.contains("bcrypt")
        // -l 优先读 .pub（不会要口令）；没有 .pub 再读私钥。
        let target = hasPublic ? path + ".pub" : path
        let out = run("/usr/bin/ssh-keygen", ["-l", "-f", target])
        // 形如：256 SHA256:xxxx comment (ED25519)
        var bits = "-", fp = "-", comment = "", type = "-"
        let parts = out.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 3 {
            bits = parts[0]
            fp = parts[1]
            let rest = parts.count > 2 ? parts[2...].joined(separator: " ") : ""
            if let open = rest.lastIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
                type = String(rest[rest.index(after: open)..<close])
                comment = String(rest[rest.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            } else {
                comment = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return KeyInfo(path: path, name: name, type: type, bits: bits, fingerprint: fp,
                       comment: comment, hasPublic: hasPublic, encrypted: encrypted)
    }

    enum KeyType: String, CaseIterable {
        case ed25519 = "ed25519"
        case rsa4096 = "rsa-4096"
        case ecdsa256 = "ecdsa-256"

        var display: String {
            switch self {
            case .ed25519:  return "Ed25519（推荐，短快现代）"
            case .rsa4096:  return "RSA 4096（兼容性最好，老服务器用）"
            case .ecdsa256: return "ECDSA P-256"
            }
        }
        var args: [String] {
            switch self {
            case .ed25519:  return ["-t", "ed25519"]
            case .rsa4096:  return ["-t", "rsa", "-b", "4096"]
            case .ecdsa256: return ["-t", "ecdsa", "-b", "256"]
            }
        }
    }

    /// 生成新密钥。成功返回私钥路径，失败返回错误信息。
    /// passphrase 传空串表示不加口令（`-N ""`）。
    static func generate(name: String, type: KeyType, comment: String, passphrase: String) -> Result<String, GenError> {
        let fm = FileManager.default
        try? fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let safe = name.trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty, !safe.contains("/"), !safe.hasPrefix(".") else {
            return .failure(GenError(message: "文件名不合法"))
        }
        let path = sshDir.appendingPathComponent(safe).path
        if fm.fileExists(atPath: path) { return .failure(GenError(message: "已存在同名密钥：\(safe)")) }

        var args = type.args
        args += ["-f", path, "-N", passphrase]
        if !comment.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-C", comment.trimmingCharacters(in: .whitespaces)]
        }
        let out = run("/usr/bin/ssh-keygen", args)
        guard fm.fileExists(atPath: path) else {
            return .failure(GenError(message: out.isEmpty ? "ssh-keygen 执行失败" : out))
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        Log.info("生成密钥 \(safe)（\(type.rawValue)）", "keys")
        return .success(path)
    }

    /// 读公钥内容（用于"复制公钥"，粘到服务器 authorized_keys）。
    static func publicKeyText(_ info: KeyInfo) -> String? {
        let pub = info.path + ".pub"
        if let s = try? String(contentsOfFile: pub, encoding: .utf8) { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        // 没有 .pub 就从私钥派生（私钥带口令时会失败，返回 nil 交给调用方提示）
        let out = run("/usr/bin/ssh-keygen", ["-y", "-f", info.path])
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("ssh-") || t.hasPrefix("ecdsa-") ? t : nil
    }

    /// 删除私钥 + 对应 .pub。
    static func delete(_ info: KeyInfo) {
        try? FileManager.default.removeItem(atPath: info.path)
        try? FileManager.default.removeItem(atPath: info.path + ".pub")
        Log.info("删除密钥 \(info.name)", "keys")
    }

    // MARK: - 跑外部命令
    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // ssh-keygen 在需要口令时会去读 tty；这里显式切断输入，避免卡住
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return "无法执行 \(exe): \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
