import Foundation

/// 本地加密凭据存储（替代 Keychain，彻底避免 macOS ad-hoc 签名每次变动引发的“系统钥匙串频繁弹窗”）。
/// 存储于 `~/Library/Application Support/PixShell/credentials.dat`
enum Keychain {
    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PixShell")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.dat")
    }

    private static func loadMap() -> [String: String] {
        guard let data = try? Data(contentsOf: storageURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict.mapValues { decode($0) }
    }

    private static func saveMap(_ map: [String: String]) {
        let encMap = map.mapValues { encode($0) }
        if let data = try? JSONSerialization.data(withJSONObject: encMap, options: [.prettyPrinted]) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    // 简单 XOR + Base64 掩码（防止文本明文，且零弹窗）
    private static let secretKey: [UInt8] = [0x50, 0x69, 0x78, 0x53, 0x68, 0x65, 0x6c, 0x6c, 0x5f, 0x53, 0x65, 0x63, 0x72, 0x65, 0x74]

    private static func encode(_ str: String) -> String {
        let bytes = Array(str.utf8)
        var xored = [UInt8]()
        for i in 0..<bytes.count {
            xored.append(bytes[i] ^ secretKey[i % secretKey.count])
        }
        return Data(xored).base64EncodedString()
    }

    private static func decode(_ str: String) -> String {
        guard let data = Data(base64Encoded: str) else { return "" }
        let bytes = Array(data)
        var xored = [UInt8]()
        for i in 0..<bytes.count {
            xored.append(bytes[i] ^ secretKey[i % secretKey.count])
        }
        return String(bytes: xored, encoding: .utf8) ?? ""
    }

    // MARK: - Public API (完全兼容老接口)

    static func setPassword(_ password: String, for id: String, label hostHint: String? = nil) {
        var map = loadMap()
        if password.isEmpty {
            map.removeValue(forKey: id)
        } else {
            map[id] = password
        }
        saveMap(map)
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
