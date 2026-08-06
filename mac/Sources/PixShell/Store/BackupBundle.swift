import Foundation

/// 备份包（格式 1:1 对齐老仓库 packages/sync/src/index.js 的 exportBundle/importBundle）：
/// `{ version:1, exportedAt, hosts(**不含密码**), settings, quickCommands }`
struct BackupBundle: Codable, Equatable {
    var version: Int = 1
    var exportedAt: String
    var hosts: [Host]
    var settings: [String: String]
    var quickCommands: [QuickCommand]

    static func make(hosts: [Host], quick: [QuickCommand], settings: [String: String]) -> BackupBundle {
        let f = ISO8601DateFormatter()
        return BackupBundle(version: 1, exportedAt: f.string(from: Date()),
                            hosts: hosts, settings: settings, quickCommands: quick)
    }

    func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
    static func decode(_ data: Data) throws -> BackupBundle {
        let object = try JSONSerialization.jsonObject(with: data)
        let normalized = try normalizeKeys(object)
        let normalizedData = try JSONSerialization.data(withJSONObject: normalized)
        let b = try JSONDecoder().decode(BackupBundle.self, from: normalizedData)
        guard b.version == 1 else { throw NSError(domain: "PixShell", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "不支持的备份包版本 \(b.version)"]) }
        return b
    }

    private static func normalizeKeys(_ value: Any, preserveDictionaryKeys: Bool = false) throws -> Any {
        if let dictionary = value as? [String: Any] {
            if preserveDictionaryKeys {
                return dictionary
            }
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                let normalizedKey = key.prefix(1).lowercased() + String(key.dropFirst())
                guard result[normalizedKey] == nil else {
                    throw NSError(domain: "PixShell", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "备份包包含重复字段 \(normalizedKey)"])
                }
                result[normalizedKey] = try normalizeKeys(child, preserveDictionaryKeys: normalizedKey == "settings")
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.map { try normalizeKeys($0) }
        }
        return value
    }
}

/// WebDAV 备份（坚果云等）：PUT/GET 一个 JSON 文件，Basic 认证。
/// 老仓库对 WebDAV 也是「保存服务商地址 + 应用密码」的方式，这里直接实现真实上传/下载。
enum WebDAVBackup {
    struct Config: Codable, Equatable {
        var url: String        // 形如 https://dav.jianguoyun.com/dav/pixshell/backup.json
        var username: String
        var password: String   // 应用密码
    }

    private static let key = "pixshell.webdav"
    /// 只检查非敏感配置是否存在，不读取 Keychain，避免为了刷新 UI 徽章触发授权弹窗。
    static var isConfigured: Bool {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return false }
        return !config.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func load() -> Config? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        guard var c = try? JSONDecoder().decode(Config.self, from: d) else { return nil }
        if let kp = Keychain.password(for: "webdav-backup-password"), !kp.isEmpty {
            c.password = kp
        } else if !c.password.isEmpty {
            save(c)
        }
        return c
    }
    static func save(_ c: Config) {
        guard Keychain.setPassword(c.password, for: "webdav-backup-password") else {
            Log.error("WebDAV 凭据保存失败，跳过配置写入", "backup")
            return
        }
        var safe = c
        safe.password = ""
        if let d = try? JSONEncoder().encode(safe) { UserDefaults.standard.set(d, forKey: key) }
    }

    private static func request(_ c: Config, method: String, body: Data?) -> URLRequest? {
        guard let u = URL(string: c.url) else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = 30
        let token = Data("\(c.username):\(c.password)".utf8).base64EncodedString()
        r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        return r
    }

    struct RawResponse {
        let data: Data?
        let etag: String?
        let status: Int
    }

    /// 双向同步使用的原始 GET，返回 ETag；404 作为正常的“远端尚无备份”返回。
    static func fetchRaw(_ c: Config, completion: @escaping (Result<RawResponse, Error>) -> Void) {
        guard let req = request(c, method: "GET", body: nil) else {
            completion(.failure(NSError(domain: "PixShell", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "URL 无效"]))); return
        }
        URLSession.shared.dataTask(with: req) { data, resp, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let http = resp as? HTTPURLResponse else {
                    completion(.failure(NSError(domain: "PixShell", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "WebDAV 未返回 HTTP 响应"]))); return
                }
                let result = RawResponse(data: data, etag: http.value(forHTTPHeaderField: "ETag"), status: http.statusCode)
                if (200...299).contains(http.statusCode) || http.statusCode == 404 { completion(.success(result)) }
                else { completion(.failure(NSError(domain: "PixShell", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))) }
            }
        }.resume()
    }

    /// 带 If-Match / If-None-Match 的条件上传，防止另一台设备刚写入的数据被覆盖。
    static func putRaw(_ c: Config, data: Data, etag: String?, createOnly: Bool,
                       completion: @escaping (Result<RawResponse, Error>) -> Void) {
        guard var req = request(c, method: "PUT", body: data) else {
            completion(.failure(NSError(domain: "PixShell", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "URL 无效"]))); return
        }
        if createOnly { req.setValue("*", forHTTPHeaderField: "If-None-Match") }
        else if let etag, !etag.isEmpty { req.setValue(etag, forHTTPHeaderField: "If-Match") }
        URLSession.shared.dataTask(with: req) { responseData, resp, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let http = resp as? HTTPURLResponse else {
                    completion(.failure(NSError(domain: "PixShell", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "WebDAV 未返回 HTTP 响应"]))); return
                }
                let result = RawResponse(data: responseData, etag: http.value(forHTTPHeaderField: "ETag"), status: http.statusCode)
                if (200...299).contains(http.statusCode) { completion(.success(result)) }
                else { completion(.failure(NSError(domain: "PixShell", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))) }
            }
        }.resume()
    }

    /// 上传备份包；completion 传 nil 表示成功
    static func push(_ c: Config, bundle: BackupBundle, completion: @escaping (String?) -> Void) {
        do {
            let data = try bundle.encoded()
            guard let req = request(c, method: "PUT", body: data) else { completion("URL 无效"); return }
            Log.info("WebDAV 上传 \(c.url)（\(data.count) 字节）", "backup")
            URLSession.shared.dataTask(with: req) { _, resp, err in
                DispatchQueue.main.async {
                    if let e = err { Log.error("WebDAV 上传失败: \(e)", "backup"); completion(e.localizedDescription); return }
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if (200...299).contains(code) { Log.info("WebDAV 上传成功 \(code)", "backup"); completion(nil) }
                    else { Log.error("WebDAV 上传 HTTP \(code)", "backup"); completion("HTTP \(code)") }
                }
            }.resume()
        } catch { completion(error.localizedDescription) }
    }

    /// 下载备份包
    static func pull(_ c: Config, completion: @escaping (Result<BackupBundle, Error>) -> Void) {
        guard let req = request(c, method: "GET", body: nil) else {
            completion(.failure(NSError(domain: "PixShell", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "URL 无效"]))); return
        }
        Log.info("WebDAV 下载 \(c.url)", "backup")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let e = err { Log.error("WebDAV 下载失败: \(e)", "backup"); completion(.failure(e)); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code), let d = data else {
                    Log.error("WebDAV 下载 HTTP \(code)", "backup")
                    completion(.failure(NSError(domain: "PixShell", code: code,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]))); return
                }
                do { completion(.success(try BackupBundle.decode(d))) }
                catch { Log.error("备份包解析失败: \(error)", "backup"); completion(.failure(error)) }
            }
        }.resume()
    }
}
