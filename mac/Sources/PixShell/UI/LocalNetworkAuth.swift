import AppKit
import Foundation
import Network

/// macOS 15+「本地网络」隐私（TCC）：
/// - **不能**静默写入授权（无 MDM / 无 Full Disk Access 改 TCC.db 的产品路径）。
/// - **能**做的 best-effort：
///   1. 启动时用 NWBrowser 扫 `_ssh._tcp`，触发系统「允许 PixShell 查找并连接到本地网络上的设备？」弹窗
///   2. **仅**经「帮助 → 授权本地网络…」手动打开帮助 sheet / 系统设置（**禁止**在会话失败时自动弹）
///   3. 要求以 `dist/PixShell.app` 启动（有 bundle id + usage description）；裸 binary 没有稳定 TCC 身份
///
/// 注意：用户点「允许」后本进程内重连即可；若点了「不允许」必须去系统设置手动开。
/// errno 65 / No route 也常见于主机离线，自动 sheet 会反复挡屏——会话失败只写终端/状态栏。
enum LocalNetworkAuth {
    private static let promptedKey = "pixshell.localNetwork.prompted"
    private static var browser: NWBrowser?
    private static var holdTimer: Timer?

    /// 启动后异步触发一次系统本地网络授权弹窗（幂等：每个用户配置只主动扫一次，
    /// 除非 `force`；仅帮助菜单等显式用户动作可 force）。
    static func requestAuthorizationIfNeeded(force: Bool = false) {
        if !force, UserDefaults.standard.bool(forKey: promptedKey) { return }
        UserDefaults.standard.set(true, forKey: promptedKey)

        // 必须在主线程启 NWBrowser；扫完几秒后释放，避免常驻。
        DispatchQueue.main.async {
            // 已有在扫就别叠
            if browser != nil, !force { return }
            browser?.cancel()
            browser = nil

            let params = NWParameters()
            params.includePeerToPeer = true
            let desc = NWBrowser.Descriptor.bonjour(type: "_ssh._tcp", domain: nil)
            let b = NWBrowser(for: desc, using: params)
            browser = b
            b.stateUpdateHandler = { state in
                switch state {
                case .failed(let err):
                    Log.info("本地网络探测 failed: \(err)", "net")
                case .ready:
                    Log.info("本地网络探测 ready", "net")
                case .cancelled:
                    Log.info("本地网络探测 cancelled", "net")
                default:
                    Log.info("本地网络探测 state=\(state)", "net")
                }
            }
            b.browseResultsChangedHandler = { _, _ in
                // 结果本身不重要——目的是触发 TCC 弹窗。
            }
            b.start(queue: .main)
            Log.info("已发起本地网络授权探测（NWBrowser _ssh._tcp）", "net")

            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
                b.cancel()
                if browser === b { browser = nil }
            }
        }
    }

    /// 打开「系统设置 → 隐私与安全性 → 本地网络」。多 URL 兜底，覆盖 13/14/15。
    @discardableResult
    static func openSystemSettings() -> Bool {
        let candidates = [
            // macOS 13+ System Settings deep link（Sequoia 本地网络页）
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.Settings.extension?Privacy_LocalNetwork",
            // 退到隐私总页
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for s in candidates {
            if let u = URL(string: s), NSWorkspace.shared.open(u) {
                Log.info("已打开系统设置本地网络：\(s)", "net")
                return true
            }
        }
        // 最后一招：open 命令
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"]
        try? task.run()
        return true
    }

    /// **仅手动入口**（帮助菜单「授权本地网络…」）：再触发一次探测 + 弹 sheet。
    /// 一键路径 = 开系统设置本地网络页 + 同时再扫 Bonjour 触发系统弹窗（无法静默写 TCC）。
    /// 禁止在 `didCloseWith` / 网络错误路径自动调用——主机离线也会 errno 65。
    static func presentGrantHelp(from window: NSWindow?, onRetry: (() -> Void)? = nil) {
        requestAuthorizationIfNeeded(force: true)

        let a = NSAlert.pix()
        a.messageText = "需要「本地网络」权限"
        a.informativeText = """
        macOS 不能被 App 静默授权局域网，只能你点一次「允许」。

        【一键】会同时：
        1. 打开「系统设置 → 隐私与安全性 → 本地网络」
        2. 再触发一次系统授权弹窗（若尚未决定）

        打开 PixShell 开关后，点「我已允许，立即重连」。
        请用 dist/PixShell.app 启动（已 ad-hoc 签名），授权才能记住。
        """
        a.addButton(withTitle: "一键打开授权设置")
        a.addButton(withTitle: "我已允许，立即重连")
        a.addButton(withTitle: "取消")
        let handler: (NSApplication.ModalResponse) -> Void = { resp in
            switch resp {
            case .alertFirstButtonReturn:
                // 一键：设置页 + 再要一次系统弹窗
                _ = openSystemSettings()
                requestAuthorizationIfNeeded(force: true)
            case .alertSecondButtonReturn:
                requestAuthorizationIfNeeded(force: true)
                onRetry?()
            default:
                break
            }
        }
        if let window {
            a.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(a.runModal())
        }
    }

    /// 无回调重载已合并到带默认参数的 presentGrantHelp(from:onRetry:)。

    /// 错误文本是否像「本地网络未授权伪装成的 No route」。
    static func looksLikeLocalNetworkBlock(_ error: Error?) -> Bool {
        let raw = "\(error.map { "\($0)" } ?? "") \(error?.localizedDescription ?? "")".lowercased()
        return raw.contains("no route to host")
            || raw.contains("errno: 65")
            || raw.contains("nioconnectionerror")
            || raw.contains("host is down")
    }
}
