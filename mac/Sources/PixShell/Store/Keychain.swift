import Foundation
import CryptoKit

/// 本地加密凭据存储（替代系统 Keychain，避免 ad-hoc/本地签 CDHash 变导致钥匙串弹窗）。
/// 存 `~/Library/Application Support/PixShell/credentials.dat`，权限 0600。
///
/// 格式：JSON `{ hostId: "v2.<base64(nonce||ciphertext+tag)>" }`
/// - v2 = AES-GCM（CryptoKit），密钥 = SHA256(固定盐 + 用户名 + home)
/// - 旧 XOR 值无 `v2.` 前缀 → 读时自动迁移并回写
///
/// 强度对齐 Win DPAPI 意图（本机用户域内不可解明文），不依赖系统钥匙串。
enum Keychain {
    private static let fileName = "credentials.dat"
    private static let v2Prefix = "v2."
    /// 应用固定盐（不是密钥本身；与用户身份一起进 SHA256）
    private static let appSalt = "PixShell.v2.creds.aes-gcm"

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PixShell")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Key material

    /// 派生 256-bit SymmetricKey：固定盐 + 当前用户 + home。
    /// 换用户/换 home 解不开旧密文（符合「本机用户」边界）；同用户重装 app 可解。
    private static func symmetricKey() -> SymmetricKey {
        let user = NSUserName()
        let home = NSHomeDirectory()
        let material = "\(appSalt)|\(user)|\(home)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return SymmetricKey(data: Data(digest))
    }

    // MARK: - AES-GCM encode / decode

    private static func encodeV2(_ plain: String) -> String {
        let key = symmetricKey()
        let data = Data(plain.utf8)
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            // combined = nonce(12) + ciphertext + tag(16)
            guard let combined = sealed.combined else {
                return encodeLegacyXOR(plain) // 极端回落，不应触发
            }
            return v2Prefix + combined.base64EncodedString()
        } catch {
            Log.warn("凭据 AES 加密失败，回落 XOR 掩码: \(error.localizedDescription)", "keychain")
            return encodeLegacyXOR(plain)
        }
    }

    private static func decodeAny(_ stored: String) -> String {
        if stored.hasPrefix(v2Prefix) {
            let b64 = String(stored.dropFirst(v2Prefix.count))
            guard let combined = Data(base64Encoded: b64) else { return "" }
            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                let plain = try AES.GCM.open(box, using: symmetricKey())
                return String(data: plain, encoding: .utf8) ?? ""
            } catch {
                // 可能是用户/home 变了，或文件损坏
                Log.warn("凭据 AES 解密失败（将视为无密码）: \(error.localizedDescription)", "keychain")
                return ""
            }
        }
        // 旧 XOR 格式
        return decodeLegacyXOR(stored)
    }

    // MARK: - Legacy XOR（只读迁移）

    private static let legacyKey: [UInt8] = [
        0x50, 0x69, 0x78, 0x53, 0x68, 0x65, 0x6c, 0x6c,
        0x5f, 0x53, 0x65, 0x63, 0x72, 0x65, 0x74
    ]

    private static func encodeLegacyXOR(_ str: String) -> String {
        let bytes = Array(str.utf8)
        var xored = [UInt8]()
        xored.reserveCapacity(bytes.count)
        for i in 0..<bytes.count {
            xored.append(bytes[i] ^ legacyKey[i % legacyKey.count])
        }
        return Data(xored).base64EncodedString()
    }

    private static func decodeLegacyXOR(_ str: String) -> String {
        guard let data = Data(base64Encoded: str) else { return "" }
        let bytes = Array(data)
        var xored = [UInt8]()
        xored.reserveCapacity(bytes.count)
        for i in 0..<bytes.count {
            xored.append(bytes[i] ^ legacyKey[i % legacyKey.count])
        }
        return String(bytes: xored, encoding: .utf8) ?? ""
    }

    // MARK: - Persist

    private static func loadRawMap() -> [String: String] {
        guard let data = try? Data(contentsOf: storageURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private static func loadMap() -> [String: String] {
        let raw = loadRawMap()
        var plain: [String: String] = [:]
        var needsMigrate = false
        for (k, v) in raw {
            let pw = decodeAny(v)
            if !pw.isEmpty {
                plain[k] = pw
            }
            if !v.hasPrefix(v2Prefix) {
                needsMigrate = true
            }
        }
        if needsMigrate, !plain.isEmpty {
            // 静默升级到 v2，避免旧 XOR 文件长期滞留
            saveMap(plain)
        }
        return plain
    }

    private static func saveMap(_ map: [String: String]) {
        let encMap = map.mapValues { encodeV2($0) }
        guard let data = try? JSONSerialization.data(withJSONObject: encMap, options: [.prettyPrinted]) else {
            return
        }
        let url = storageURL
        do {
            try data.write(to: url, options: .atomic)
            // 0600：仅当前用户读写
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            Log.warn("凭据写盘失败: \(error.localizedDescription)", "keychain")
        }
    }

    // MARK: - Public API（兼容老接口）

    static func setPassword(_ password: String, for id: String, label hostHint: String? = nil) {
        var map = loadMap()
        if password.isEmpty {
            map.removeValue(forKey: id)
        } else {
            map[id] = password
        }
        saveMap(map)
        _ = hostHint // 保留签名兼容；v2 不再需要 label
    }

    static func password(for id: String) -> String? {
        let map = loadMap()
        guard let pw = map[id], !pw.isEmpty else { return nil }
        return pw
    }

    static func has(_ id: String) -> Bool {
        let map = loadMap()
        return !(map[id]?.isEmpty ?? true)
    }

    static func delete(_ id: String) {
        var map = loadMap()
        map.removeValue(forKey: id)
        saveMap(map)
    }
}
