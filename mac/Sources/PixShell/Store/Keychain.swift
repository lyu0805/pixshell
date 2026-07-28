import Foundation
import Security

/// 密码存 macOS Keychain（generic password），按主机 id 关联，不落 JSON 明文。
///
/// **弹窗根因：** ad-hoc 签名每次 CDHash 变，系统认为「另一应用」访问 item，
/// `SecItemCopyMatching` 就反复要登录钥匙串密码。
/// **对策：**
/// 1. 写入时挂 `SecAccess`，把当前可执行文件标为可信应用；
/// 2. 读取成功后立刻用当前二进制 **重绑 ACL**（用户点过允许后下一轮尽量不再问）；
/// 3. 打包脚本应使用稳定本地 codesign 身份（见 package-mac.sh），跨启动 CDHash 一致。
enum Keychain {
    private static let service = "com.pixshell.ssh"

    // MARK: - Public

    static func setPassword(_ password: String, for id: String, label hostHint: String? = nil) {
        let base = baseQuery(account: id)
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }

        var add = base
        add[kSecValueData as String] = password.data(using: .utf8) ?? Data()
        add[kSecAttrLabel as String] = displayLabel(id: id, hostHint: hostHint)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let access = makeAccess(label: displayLabel(id: id, hostHint: hostHint)) {
            add[kSecAttrAccess as String] = access
        }
        let st = SecItemAdd(add as CFDictionary, nil)
        if st != errSecSuccess {
            // Access 对象在部分系统上 SecItemAdd 会拒；降级无 ACL 再写，读成功后再 rebind
            var plain = base
            plain[kSecValueData as String] = password.data(using: .utf8) ?? Data()
            plain[kSecAttrLabel as String] = displayLabel(id: id, hostHint: hostHint)
            plain[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(plain as CFDictionary, nil)
        }
    }

    static func password(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let st = SecItemCopyMatching(query as CFDictionary, &out)
        guard st == errSecSuccess else { return nil }

        var secret: Data?
        var label: String?
        if let dict = out as? [String: Any] {
            secret = dict[kSecValueData as String] as? Data
            label = dict[kSecAttrLabel as String] as? String
        } else if let data = out as? Data {
            secret = data
        }
        guard let data = secret, let pw = String(data: data, encoding: .utf8), !pw.isEmpty else { return nil }

        // 用户刚授权成功：用当前二进制重写 ACL，避免下次再弹
        rebindAccess(account: id, password: pw, label: label)
        return pw
    }

    /// 是否已存密码（只探测存在性、不取密文，避免无谓弹窗——供 UI 徽章）。
    static func has(_ id: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: "uifu", // kSecUseAuthenticationUIFail
        ]
        // 字符串 "uifu" 是 kSecUseAuthenticationUIFail 的 CFString 值
        let st = SecItemCopyMatching(query as CFDictionary, nil)
        // interaction not allowed 也说明 item 在，只是不能静默解密
        return st == errSecSuccess || st == errSecInteractionNotAllowed
    }

    static func delete(_ id: String) {
        SecItemDelete(baseQuery(account: id) as CFDictionary)
    }

    // MARK: - Internals

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func displayLabel(id: String, hostHint: String?) -> String {
        if let h = hostHint, !h.isEmpty { return "PixShell SSH \(h)" }
        return "PixShell SSH \(id.prefix(8))"
    }

    private static func executablePath() -> String? {
        if let url = Bundle.main.executableURL { return url.path }
        return CommandLine.arguments.first
    }

    /// 创建允许本应用解密的 SecAccess。
    private static func makeAccess(label: String) -> SecAccess? {
        var trusted: [SecTrustedApplication] = []
        var seen = Set<String>()
        func addPath(_ path: String) {
            guard !path.isEmpty, !seen.contains(path) else { return }
            seen.insert(path)
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app {
                trusted.append(app)
            }
        }
        if let path = executablePath() { addPath(path) }
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            addPath((bundlePath as NSString).appendingPathComponent("Contents/MacOS/PixShell"))
        }

        var access: SecAccess?
        let st: OSStatus
        if trusted.isEmpty {
            st = SecAccessCreate(label as CFString, nil, &access)
        } else {
            st = SecAccessCreate(label as CFString, trusted as CFArray, &access)
        }
        guard st == errSecSuccess else { return nil }
        return access
    }

    /// 读成功后 update/重建，把当前可执行文件写进 ACL。
    private static func rebindAccess(account: String, password: String, label: String?) {
        let base = baseQuery(account: account)
        let lbl = label ?? displayLabel(id: account, hostHint: nil)
        var update: [String: Any] = [
            kSecValueData as String: password.data(using: .utf8) ?? Data(),
            kSecAttrLabel as String: lbl,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let access = makeAccess(label: lbl) {
            update[kSecAttrAccess as String] = access
        }
        let up = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if up == errSecSuccess { return }

        SecItemDelete(base as CFDictionary)
        var add = base
        add.merge(update) { _, new in new }
        _ = SecItemAdd(add as CFDictionary, nil)
    }
}
