import AppKit
import Foundation

/// 软件更新：对接 GitHub Releases（`lyu0805/pixshell`）。
/// - `GET /repos/{owner}/{repo}/releases/latest`
/// - semver 比较；按本机架构匹配 dmg/zip 资产
/// - 可下载到「下载」目录并打开；也可只打开该次 release 页
enum AppUpdate {
    static let repoSlug = "lyu0805/pixshell"
    static var repoURL: URL? { URL(string: "https://github.com/\(repoSlug)") }
    static var releasesURL: URL? { URL(string: "https://github.com/\(repoSlug)/releases") }
    private static var latestAPI: URL? {
        URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")
    }

    /// 一次检查的完整结果
    struct Result: Equatable {
        enum Kind: Equatable {
            case unknown
            case latest(String)
            case updateAvailable(String)
        }
        var kind: Kind
        var releasePageURL: URL?
        var assetName: String?
        var assetDownloadURL: URL?

        var text: String {
            switch kind {
            case .unknown: return "无法获取更新信息"
            case .latest: return "已是最新版本"
            case .updateAvailable(let v): return "发现新版本 \(v)"
            }
        }
        var hasUpdate: Bool {
            if case .updateAvailable = kind { return true }
            return false
        }
        var version: String? {
            switch kind {
            case .updateAvailable(let v), .latest(let v): return v
            case .unknown: return nil
            }
        }
    }

    static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let x = normalize(a).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let y = normalize(b).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }

    private static var preferredAssetHints: [String] {
        #if arch(arm64)
        // macOS ships DMG installer only (no portable zip on Releases)
        return ["mac-arm64.dmg", "darwin-arm64", "macos-arm64", "mac-arm64"]
        #else
        return ["mac-x64.dmg", "darwin-x64", "macos-x64", "mac-amd64", "mac-x64"]
        #endif
    }

    private static func pickAsset(_ assets: [[String: Any]]) -> (name: String, url: URL)? {
        let named: [(String, URL)] = assets.compactMap { a in
            guard let name = a["name"] as? String,
                  let s = a["browser_download_url"] as? String,
                  let u = URL(string: s) else { return nil }
            return (name, u)
        }
        for hint in preferredAssetHints {
            if let hit = named.first(where: { $0.0.lowercased().contains(hint) }) {
                return hit
            }
        }
        if let hit = named.first(where: {
            let n = $0.0.lowercased()
            return n.contains("mac") && (n.hasSuffix(".dmg") || n.hasSuffix(".zip"))
        }) {
            return hit
        }
        return nil
    }

    /// 查询最新 Release；失败 → .unknown（不谎称最新）
    static func check(current: String, completion: @escaping (Result) -> Void) {
        guard let url = latestAPI else {
            completion(Result(kind: .unknown, releasePageURL: nil, assetName: nil, assetDownloadURL: nil))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PixShell/\(current)", forHTTPHeaderField: "User-Agent")
        Log.info("检查更新 current=\(current)", "update")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let e = err {
                    Log.warn("检查更新失败: \(e.localizedDescription)", "update")
                    completion(Result(kind: .unknown, releasePageURL: nil, assetName: nil, assetDownloadURL: nil))
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code), let d = data,
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    Log.warn("检查更新 HTTP \(code)", "update")
                    completion(Result(kind: .unknown, releasePageURL: nil, assetName: nil, assetDownloadURL: nil))
                    return
                }
                let tag = (obj["tag_name"] as? String) ?? (obj["name"] as? String) ?? ""
                let latest = normalize(tag)
                guard !latest.isEmpty else {
                    completion(Result(kind: .unknown, releasePageURL: nil, assetName: nil, assetDownloadURL: nil))
                    return
                }
                let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
                    ?? URL(string: "https://github.com/\(repoSlug)/releases/tag/\(tag.hasPrefix("v") ? tag : "v\(latest)")")
                let assets = obj["assets"] as? [[String: Any]] ?? []
                let picked = pickAsset(assets)
                let kind: Result.Kind = compare(latest, current) > 0
                    ? .updateAvailable(latest)
                    : .latest(latest)
                let result = Result(kind: kind, releasePageURL: page,
                                    assetName: picked?.name, assetDownloadURL: picked?.url)
                Log.info("检查更新结果: \(result.text) asset=\(picked?.name ?? "-")", "update")
                completion(result)
            }
        }.resume()
    }

    /// 下载发行资产到「下载」文件夹，Reveal + open（.dmg 会挂载/打开）
    static func downloadAsset(url: URL, name: String,
                              progress: ((String) -> Void)? = nil,
                              completion: @escaping (URL?, String?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let dest = dir.appendingPathComponent(name)
        progress?("正在下载 \(name)…")
        Log.info("下载更新 → \(dest.path)", "update")
        URLSession.shared.downloadTask(with: url) { tmp, resp, err in
            DispatchQueue.main.async {
                if let e = err {
                    completion(nil, e.localizedDescription)
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code), let tmp else {
                    completion(nil, "下载失败 HTTP \(code)")
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                    NSWorkspace.shared.open(dest)
                    completion(dest, nil)
                } catch {
                    completion(nil, error.localizedDescription)
                }
            }
        }.resume()
    }
}
