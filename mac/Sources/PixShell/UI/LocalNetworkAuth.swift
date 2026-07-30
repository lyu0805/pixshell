import AppKit
import Foundation
import Network
import Security

/// macOS 15+「本地网络」隐私（TCC）：
/// - **不能**静默写入授权（无 MDM / 无 Full Disk Access 改 TCC.db 的产品路径）。
/// - **能**做的 best-effort：
///   1. 启动时用 NWBrowser 扫 `_ssh._tcp`，触发系统「允许 PixShell 查找并连接到本地网络上的设备？」弹窗
///   2. **仅**经「帮助 → 授权本地网络…」手动打开帮助 sheet / 系统设置（**禁止**在会话失败时自动弹）
///   3. 要求以 `dist/PixShell.app` 启动（有 bundle id + usage description）；裸 binary 没有稳定 TCC 身份
///
/// 注意：用户点「允许」后本进程内重连即可；若点了「不允许」必须去系统设置手动开。
/// errno 65 / No route 也常见于主机离线，自动 sheet 会反复挡屏——会话失败只写终端/状态栏。
///
/// P0：ad-hoc 重装后 CDHash 变 → TCC 授权丢，但旧 `prompted` 仍为 true 会跳过 NWBrowser。
/// 故 prompted 按代码身份（CDHash / 可执行文件 mtime+size）键控；身份变则再探一次。
enum LocalNetworkAuth {
    /// 旧布尔键：仅迁移用，不再单独作为 skip 条件。
    private static let promptedKey = "pixshell.localNetwork.prompted"
    /// 已探测过的代码身份；与 `currentCodeIdentityKey()` 相等才 skip。
    private static let promptedIdentityKey = "pixshell.localNetwork.promptedIdentity"
    private static var browser: NWBrowser?
    private static var holdTimer: Timer?
    /// 进程内 force 探测节流（帮助菜单可 bypass）。
    private static var lastForceProbeAt: Date?
    private static let forceProbeMinInterval: TimeInterval = 30

    /// 当前可执行文件身份：优先 CDHash，回落 main executable mtime+size。
    static func currentCodeIdentityKey() -> String {
        if let cd = cdHashIdentity() { return cd }
        return executableFallbackIdentity()
    }

    private static func cdHashIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var infoCF: CFDictionary?
        // kSecCodeInfoUnique：稳定唯一标识；kSecCodeInfoCdHashes：CDHash 数组
        guard SecCodeCopySigningInformation(staticCode, [], &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else { return nil }

        if let unique = info[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty {
            return "cd:" + unique.map { String(format: "%02x", $0) }.joined()
        }
        // CdHashes 可能是 [Data]
        if let hashes = info[kSecCodeInfoCdHashes as String] as? [Data],
           let first = hashes.first, !first.isEmpty {
            return "cd:" + first.map { String(format: "%02x", $0) }.joined()
        }
        // 个别系统上可能是 CFArray of CFData
        if let arr = info[kSecCodeInfoCdHashes as String] as? NSArray {
            for item in arr {
                if let d = item as? Data, !d.isEmpty {
                    return "cd:" + d.map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        return nil
    }

    private static func executableFallbackIdentity() -> String {
        let url = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ProcessInfo.processInfo.arguments.first ?? "")
        guard !url.path.isEmpty else { return "fb:unknown" }
        do {
            let vals = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals.contentModificationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let size = vals.fileSize.map { String($0) } ?? "0"
            return "fb:\(url.lastPathComponent):\(mtime):\(size)"
        } catch {
            // 再退：path 字符串 hash
            return "fb:\(url.path.hashValue)"
        }
    }

    /// 启动后异步触发一次系统本地网络授权弹窗（幂等：同一代码身份只主动扫一次，
    /// 除非 `force`；仅帮助菜单等显式用户动作可 force + bypassDebounce）。
    static func requestAuthorizationIfNeeded(force: Bool = false, bypassDebounce: Bool = false) {
        let identity = currentCodeIdentityKey()
        let stored = UserDefaults.standard.string(forKey: promptedIdentityKey)

        if !force {
            // 身份已探过 → skip
            if stored == identity { return }
            // 迁移：旧 prompted=true 但无 identity → 仍再探一次（重装/CDHash 变的 P0 场景）
            // 有 identity 且不等 → 也探
        } else if !bypassDebounce {
            // force 路径进程内 30s 节流（帮助菜单 bypass）
            if let last = lastForceProbeAt,
               Date().timeIntervalSince(last) < forceProbeMinInterval {
                Log.info("本地网络 force 探测节流中（<\(Int(forceProbeMinInterval))s）", "net")
                return
            }
        }

        if force {
            lastForceProbeAt = Date()
        }
        // 写入当前身份；顺带清旧布尔键，避免以后误用
        UserDefaults.standard.set(identity, forKey: promptedIdentityKey)
        UserDefaults.standard.removeObject(forKey: promptedKey)

        // 必须在主线程启 NWBrowser；扫完几秒后释放，避免常驻。
        DispatchQueue.main.async {
            // 已有在扫就别叠（force 允许重开）
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
            Log.info("已发起本地网络授权探测（NWBrowser _ssh._tcp）id=\(identity) force=\(force)", "net")

            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
                b.cancel()
                if browser === b { browser = nil }
            }
        }
    }

    /// 会话失败像本地网络拦截时：静默 force 再探一次（带 30s 节流）。**不**弹 sheet。
    static func reprobeOnLikelyBlock() {
        Log.info("疑似本地网络拦截 → 静默 re-probe", "net")
        requestAuthorizationIfNeeded(force: true, bypassDebounce: false)
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
        // 帮助菜单：绕过 30s 节流
        requestAuthorizationIfNeeded(force: true, bypassDebounce: true)

        let a = NSAlert.pix()
        a.messageText = "需要「本地网络」权限"
        a.informativeText = """
        macOS 不能被 App 静默授权局域网，只能你点一次「允许」。

        【一键】会同时：
        1. 打开「系统设置 → 隐私与安全性 → 本地网络」
        2. 再触发一次系统授权弹窗（若尚未决定）

        打开 PixShell 开关后，点「我已允许，立即重连」会立刻重连当前主机。
        请用 dist/PixShell.app 启动（稳定 codesign 身份），授权才能跨更新记住。
        """
        a.addButton(withTitle: "一键打开授权设置")
        a.addButton(withTitle: "我已允许，立即重连")
        a.addButton(withTitle: "取消")
        let handler: (NSApplication.ModalResponse) -> Void = { resp in
            switch resp {
            case .alertFirstButtonReturn:
                // 一键：设置页 + 再要一次系统弹窗（不关 sheet 后的重连；用户开完开关再点第二钮）
                _ = openSystemSettings()
                requestAuthorizationIfNeeded(force: true, bypassDebounce: true)
            case .alertSecondButtonReturn:
                requestAuthorizationIfNeeded(force: true, bypassDebounce: true)
                // 必须真的重连：调用方（帮助菜单）传入 reconnectCurrent；无回调则至少再探
                if let onRetry {
                    onRetry()
                } else {
                    Log.warn("presentGrantHelp 无 onRetry——重连未执行", "net")
                }
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
