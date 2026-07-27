import Cocoa

/// 对齐版本更新，直接跳转到 Release 页面
public struct AppUpdate {
    static let repoSlug = "lyu0805/pixshell"
    static var releasesURL: URL? { URL(string: "https://github.com/\(repoSlug)/releases") }

    public static func checkUpdate(silent: Bool = false) {
        if let url = releasesURL {
            NSWorkspace.shared.open(url)
        }
    }
}
