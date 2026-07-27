import Cocoa

public struct AppUpdate {
    static let repoSlug = "lyu0805/pixshell"
    static var releasesURL: URL? { URL(string: "https://github.com/\(repoSlug)/releases") }
    private static var latestAPI: URL? { URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") }

    public struct Status {
        public let hasUpdate: Bool
        public let text: String
        public let version: String?
        public let htmlURL: URL?
    }

    public static func check(current: String, completion: @escaping (Status) -> Void) {
        guard let url = latestAPI else {
            completion(Status(hasUpdate: false, text: "更新检查失败 (无效的 URL)", version: nil, htmlURL: nil))
            return
        }

        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PixShell/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                DispatchQueue.main.async {
                    completion(Status(hasUpdate: false, text: "检查失败: \(err.localizedDescription)", version: nil, htmlURL: nil))
                }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                DispatchQueue.main.async {
                    completion(Status(hasUpdate: false, text: "当前已是最新版本 (\(current))", version: nil, htmlURL: nil))
                }
                return
            }

            let remoteVer = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let htmlStr = json["html_url"] as? String
            let html = htmlStr.flatMap { URL(string: $0) } ?? releasesURL

            DispatchQueue.main.async {
                if remoteVer != current {
                    completion(Status(hasUpdate: true, text: "发现新版本 \(tag)", version: tag, htmlURL: html))
                } else {
                    completion(Status(hasUpdate: false, text: "已是最新版本 \(current)", version: nil, htmlURL: html))
                }
            }
        }.resume()
    }
}
