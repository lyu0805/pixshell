import Foundation
import CryptoKit
import Security

/// 本地加密凭据存储。密文存 `~/Library/Application Support/PixShell/credentials.dat`（0600），
/// 文件主密钥由系统 Keychain 保护。
///
/// 格式：JSON `{ hostId: "v3.<base64(nonce||ciphertext+tag)>" }`
/// - v3 = AES-GCM（CryptoKit），密钥为系统 Keychain 中的随机 256-bit 密钥
/// - v2 = 旧的可推导密钥格式，仅用于一次迁移
/// - 旧 XOR 值无前缀 → 读时自动迁移并回写
///
enum Keychain {
    private static let fileName = "credentials.dat"
    private static let v3Prefix = "v3."
    private static let v2Prefix = "v2."
    private static let keychainService = "com.pixshell.credentials"
    private static let keychainAccount = "file-encryption-key-v1"
    /// 仅用于解密旧 v2 数据，不能作为新数据的密钥。
    private static let appSalt = "PixShell.v2.creds.aes-gcm"

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PixShell")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Key material

    private static func legacyV2Key() -> SymmetricKey {
        let user = NSUserName()
        let home = NSHomeDirectory()
        let material = "\(appSalt)|\(user)|\(home)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return SymmetricKey(data: Data(digest))
    }

    private static func fileKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            Log.error("无法生成凭据加密密钥，拒绝写入凭据文件", "keychain")
            return nil
        }
        let data = Data(bytes)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return SymmetricKey(data: data) }
        if addStatus == errSecDuplicateItem {
            var existing: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess,
               let existingData = existing as? Data, existingData.count == 32 {
                return SymmetricKey(data: existingData)
            }
        }
        Log.error("无法访问系统凭据密钥，拒绝写入凭据文件", "keychain")
        return nil
    }

    // MARK: - AES-GCM encode / decode

    private static func encodeV3(_ plain: String) -> String? {
        guard let key = fileKey() else { return nil }
        let data = Data(plain.utf8)
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            // combined = nonce(12) + ciphertext + tag(16)
            guard let combined = sealed.combined else {
                return nil
            }
            return v3Prefix + combined.base64EncodedString()
        } catch {
            Log.warn("凭据 AES 加密失败，拒绝写入: \(error.localizedDescription)", "keychain")
            return nil
        }
    }

    private static func decodeAny(_ stored: String) -> String {
        if stored.hasPrefix(v3Prefix) {
            let b64 = String(stored.dropFirst(v3Prefix.count))
            guard let combined = Data(base64Encoded: b64), let key = fileKey() else { return "" }
            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                let plain = try AES.GCM.open(box, using: key)
                return String(data: plain, encoding: .utf8) ?? ""
            } catch {
                Log.warn("凭据 AES 解密失败（将视为无密码）: \(error.localizedDescription)", "keychain")
                return ""
            }
        }
        if stored.hasPrefix(v2Prefix) {
            let b64 = String(stored.dropFirst(v2Prefix.count))
            guard let combined = Data(base64Encoded: b64) else { return "" }
            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                let plain = try AES.GCM.open(box, using: legacyV2Key())
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


    @discardableResult
    private static func saveMap(_ map: [String: String]) -> Bool {
        var encMap: [String: String] = [:]
        for (key, value) in map {
            guard let encoded = encodeV3(value) else {
                Log.error("凭据密钥不可用，跳过写盘", "keychain")
                return false
            }
            encMap[key] = encoded
        }
        guard let data = try? JSONSerialization.data(withJSONObject: encMap, options: [.prettyPrinted]) else {
            return false
        }
        let url = storageURL
        do {
            try data.write(to: url, options: .atomic)
            // 0600：仅当前用户读写
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            Log.warn("凭据写盘失败: \(error.localizedDescription)", "keychain")
            return false
        }
    }

    // MARK: - Public API（兼容老接口）

    private static let lock = NSLock()
    /// 内存缓存解密后的明文 map：连接热路径每次 password() 都全量读文件+解密，
    /// 主线程同步 IO 是 UI 卡顿 P1 来源。首次加载后走内存，写操作时失效刷新。
    private static var cachedPlain: [String: String]?

    /// 读明文 map（缓存优先）：返回 nil 表示首次加载且文件为空/损坏。
    private static func plainMap() -> [String: String]? {
        if let c = cachedPlain { return c }
        let raw = loadRawMap()
        if raw.isEmpty { return nil }
        var plain: [String: String] = [:]
        var needsMigrate = false
        var migrationIsComplete = true
        for (k, v) in raw {
            let pw = decodeAny(v)
            if !pw.isEmpty { plain[k] = pw } else if !v.isEmpty { migrationIsComplete = false }
            if !v.hasPrefix(v3Prefix) { needsMigrate = true }
        }
        if needsMigrate, migrationIsComplete, !plain.isEmpty {
            saveMap(plain)
        }
        cachedPlain = plain
        return plain
    }

    /// 写盘并刷新缓存（写失败返回 false）。
    @discardableResult
    private static func persistMap(_ map: [String: String]) -> Bool {
        let ok = saveMap(map)
        if ok { cachedPlain = map }
        return ok
    }

    @discardableResult
    static func setPassword(_ password: String, for id: String, label hostHint: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let raw = loadRawMap()
        var map = plainMap() ?? [:]
        guard map.count == raw.count || raw.isEmpty else {
            Log.error("凭据文件包含无法解密的条目，拒绝覆盖", "keychain")
            return false
        }
        if password.isEmpty {
            map.removeValue(forKey: id)
        } else {
            map[id] = password
        }
        let saved = persistMap(map)
        _ = hostHint // 保留签名兼容；v3 不再需要 label
        return saved
    }

    static func password(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let pw = plainMap()?[id], !pw.isEmpty else { return nil }
        return pw
    }

    static func has(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(plainMap()?[id]?.isEmpty ?? true)
    }

    static func delete(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        let raw = loadRawMap()
        var map = plainMap() ?? [:]
        guard map.count == raw.count || raw.isEmpty else {
            Log.error("凭据文件包含无法解密的条目，拒绝覆盖", "keychain")
            return
        }
        map.removeValue(forKey: id)
        persistMap(map)
    }
}
