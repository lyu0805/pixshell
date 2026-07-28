import Foundation
import CryptoKit

/// 主机指纹管理：读写 `~/.ssh/known_hosts`。
/// 指纹按 OpenSSH 规则：对 base64 解码后的公钥字节做 SHA256（无 padding base64）/ MD5（冒号 hex）。
enum KnownHosts {

    struct Entry {
        let hosts: String            // 主机名 / IP / 哈希标记
        let keyType: String          // ssh-ed25519 / ssh-rsa / …
        let keyTypeShort: String     // ED25519 / RSA / …
        let fingerprintSHA256: String
        let fingerprintMD5: String
        let rawLine: String          // 删除时按整行精确匹配
        let marker: String?          // @cert-authority / @revoked
    }

    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("known_hosts")
    }

    static func list() -> [Entry] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let e = parse(line) { out.append(e) }
        }
        return out
    }

    /// 删除一条指纹：按 rawLine 精确匹配，去掉所有相同行后写回。
    static func delete(_ entry: Entry) {
        let fm = FileManager.default
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces) != entry.rawLine.trimmingCharacters(in: .whitespaces) }
        let body = kept.joined(separator: "\n")
        // 保持末尾换行（OpenSSH 习惯）
        let final = body.hasSuffix("\n") || body.isEmpty ? body : body + "\n"
        do {
            try final.write(to: path, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            Log.info("删除主机指纹 \(entry.hosts) (\(entry.keyTypeShort))", "known_hosts")
        } catch {
            Log.warn("写 known_hosts 失败: \(error.localizedDescription)", "known_hosts")
        }
    }

    // MARK: - parse

    private static func parse(_ line: String) -> Entry? {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 3 else { return nil }

        var marker: String? = nil
        if tokens[0].hasPrefix("@") {
            marker = tokens.removeFirst()
            guard tokens.count >= 3 else { return nil }
        }

        let hosts = tokens[0]
        let keyType = tokens[1]
        let b64 = tokens[2]
        guard let keyData = Data(base64Encoded: b64) else { return nil }

        let sha = "SHA256:" + base64NoPad(SHA256.hash(data: keyData))
        let md5 = "MD5:" + md5Colon(Insecure.MD5.hash(data: keyData))
        return Entry(
            hosts: hosts,
            keyType: keyType,
            keyTypeShort: shortType(keyType),
            fingerprintSHA256: sha,
            fingerprintMD5: md5,
            rawLine: line,
            marker: marker
        )
    }

    private static func shortType(_ t: String) -> String {
        let lower = t.lowercased()
        if lower.contains("ed25519") { return "ED25519" }
        if lower.contains("ecdsa") { return "ECDSA" }
        if lower.contains("rsa") { return "RSA" }
        if lower.contains("dss") || lower.contains("dsa") { return "DSA" }
        return t.uppercased()
    }

    private static func base64NoPad<D: Digest>(_ d: D) -> String {
        Data(d).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func md5Colon<D: Digest>(_ d: D) -> String {
        Data(d).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
