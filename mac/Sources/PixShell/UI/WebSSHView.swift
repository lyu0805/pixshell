import AppKit
import WebKit

/// 应用内 Web 容器（WKWebView）。
/// - 本地桥：`http://127.0.0.1:<port>/webssh?token=…`（仅回环）
/// - 外部页：noVNC / 控制面板等 http(s)（`allowExternalHosts=true`，同站可跳转）
/// **禁止** NSWorkspace 外开系统浏览器。
final class WebSSHView: NSView, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView!
    private var lastURL: URL?
    private let statusLabel = NSTextField(labelWithString: "Web 页面加载中…")
    /// true = 允许非回环 http(s)（外部 Web/VNC）；false = 仅 127.0.0.1/localhost（本地桥 token 页）
    var allowExternalHosts: Bool = false
    /// 外部模式下优先放行的 host（起始 URL 的 host）；同站跳转（登录→vnc）也放行同 registrable 粗匹配
    var allowedHost: String? = nil

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // 媒体/WebSocket 给 noVNC；不在这里限制 host，策略在 decidePolicy
        if #available(macOS 12.3, *) {
            cfg.mediaTypesRequiringUserActionForPlayback = []
        }
        let wv = WKWebView(frame: bounds, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        webView = wv
        addSubview(wv)

        statusLabel.font = Theme.ui(12)
        statusLabel.textColor = Theme.muted
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// 加载 Web 页（桥或外部）；失败时状态字可见。
    func load(url: URL) {
        lastURL = url
        if allowedHost == nil, let h = url.host, !h.isEmpty {
            allowedHost = h
        }
        statusLabel.isHidden = false
        statusLabel.stringValue = "Web 页面加载中…"
        statusLabel.textColor = Theme.muted
        // 日志抹掉 token
        let safe = url.absoluteString.replacingOccurrences(
            of: #"[?&]token=[^&]*"#, with: "?token=***", options: .regularExpression)
        Log.info("内嵌 Web 加载 \(safe) external=\(allowExternalHosts)", "webssh")
        webView.load(URLRequest(url: url))
    }

    func reload() {
        if let u = lastURL { load(url: u) }
        else { webView.reload() }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLabel.isHidden = false
        statusLabel.textColor = Theme.err
        statusLabel.stringValue = "加载失败：\(error.localizedDescription)"
        Log.warn("内嵌 Web 导航失败: \(error.localizedDescription)", "webssh")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusLabel.isHidden = false
        statusLabel.textColor = Theme.err
        statusLabel.stringValue = "连接失败：\(error.localizedDescription)"
        Log.warn("内嵌 Web 预导航失败: \(error.localizedDescription)", "webssh")
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel); return
        }
        let host = (url.host ?? "").lowercased()
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host.isEmpty
        let okScheme = url.scheme == "http" || url.scheme == "https" || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data"
        if !okScheme {
            Log.warn("内嵌 Web 拦截 scheme: \(url.absoluteString)", "webssh")
            decisionHandler(.cancel); return
        }
        if allowExternalHosts {
            // 外部 Web/VNC：放行 http(s)/about/blob；优先同 allowedHost，也放行回环（极少）
            if loopback || host.isEmpty {
                decisionHandler(.allow); return
            }
            if let allow = allowedHost?.lowercased(), !allow.isEmpty {
                // 同 host 或子域（cdn.okshk.com ← okshk.com 粗放行：后缀匹配）
                if host == allow || host.hasSuffix("." + allow) || allow.hasSuffix("." + host) {
                    decisionHandler(.allow); return
                }
                // 同 eTLD+1 粗匹配：取最后两段
                if sameSite(host, allow) {
                    decisionHandler(.allow); return
                }
            }
            // 无 allowedHost 时：首次外链即放行并锁定 host
            if allowedHost == nil || allowedHost?.isEmpty == true {
                allowedHost = host
                decisionHandler(.allow); return
            }
            Log.warn("内嵌 Web 拦截跨站: \(url.absoluteString) allow=\(allowedHost ?? "-")", "webssh")
            decisionHandler(.cancel)
            return
        }
        // 本地桥模式：仅回环
        if loopback {
            decisionHandler(.allow)
        } else {
            Log.warn("内嵌 Web 拦截外链: \(url.absoluteString)", "webssh")
            decisionHandler(.cancel)
        }
    }

    private func sameSite(_ a: String, _ b: String) -> Bool {
        func base(_ h: String) -> String {
            let parts = h.split(separator: ".")
            if parts.count >= 2 { return parts.suffix(2).joined(separator: ".") }
            return h
        }
        return base(a) == base(b)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank → 同页打开（仍受 decidePolicy 约束）；noVNC 有时弹新窗
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
