import Foundation

/// 软件更新检查（对齐老仓库 packages/app/main/app-update.js 的判定口径）：
/// 走 GitHub Releases API 取 latest，比较语义化版本，只做「检查 + 告知 + 打开发行页」，
/// **不自动下载安装**（原生包需签名/公证，自动替换风险高）。
enum AppUpdate {
    static let repoSlug = "pixshell/pixshell"     // 与老仓库 REPO_SLUG 对齐；换仓库改这里
    static var releasesURL: URL? { URL(string: "https://github.com/\(repoSlug)/releases") }
    private static var latestAPI: URL? { URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") }

    enum Status: Equatable {
        case unknown, latest, updateAvailable(String)
        var text: String {
            switch self {
            case .unknown: return "无法获取更新信息"
            case .latest: return "已是最新版本"
            case .updateAvailable(let v): return "发现新版本 \(v)"
            }
        }
    }

    /// 版本号归一：去掉前缀 v、只保留数字段
    static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
    }

    /// 语义化比较：a > b 返回 1，a < b 返回 -1，相等 0（缺失段按 0 补）
    static func compare(_ a: String, _ b: String) -> Int {
        let x = normalize(a).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let y = normalize(b).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }

    /// 查询最新版本；网络/解析失败一律回 .unknown（不打扰用户）
    static func check(current: String, completion: @escaping (Status) -> Void) {
        guard let url = latestAPI else { completion(.unknown); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PixShell/\(current)", forHTTPHeaderField: "User-Agent")
        Log.info("检查更新 current=\(current)", "update")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let e = err { Log.warn("检查更新失败: \(e.localizedDescription)", "update"); completion(.unknown); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code), let d = data,
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    Log.warn("检查更新 HTTP \(code)", "update"); completion(.unknown); return
                }
                let tag = (obj["tag_name"] as? String) ?? (obj["name"] as? String) ?? ""
                let latest = normalize(tag)
                guard !latest.isEmpty else { completion(.unknown); return }
                let result: Status = compare(latest, current) > 0 ? .updateAvailable(latest) : .latest
                Log.info("检查更新结果: \(result.text)", "update")
                completion(result)
            }
        }.resume()
    }
}
