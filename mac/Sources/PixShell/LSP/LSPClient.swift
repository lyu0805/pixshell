import Foundation

/// rust-analyzer 最小 LSP 客户端（stdio JSON-RPC）。
///
/// 只在编辑器打开 .rs 文件时启用（见 EditorPanel）。协议只实现我们需要的子集：
///   initialize → initialized → didOpen（全量）→ didChange（全量替换）→
///   收 publishDiagnostics（错误/警告）→ 请求 hover / completion / definition。
/// 所有 IO 在专用串行队列跑，回调切回主线程。
///
/// 关键约束：
///   - 帧格式走标准 LSP：`Content-Length: N\r\n\r\n<body N 字节>`。JSON body 里的换行
///     必须原样保留 —— 绝不能按行切（早期按行切会读半帧导致解析错乱）。
///   - rust-analyzer 没找到/启动失败 → 优雅降级：编辑器照常工作，只是无 LSP 能力。
///   - 位置是 UTF-16 code unit（LSP 规范），用 NSString 偏移换算。
final class LSPClient {

    struct Diagnostic {
        let range: NSRange
        let message: String
        let isError: Bool
    }

    typealias DiagnosticsHandler = ([Diagnostic]) -> Void
    typealias HoverHandler = (String?) -> Void
    typealias CompletionHandler = ([(label: String, detail: String)]) -> Void
    typealias DefinitionHandler = ((line: Int, character: Int)?) -> Void

    private let queue = DispatchQueue(label: "pixshell.lsp")
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    /// 挂起请求：(msg, done, retries)。msg 空（握手类）不做 -32801 重试。
    private var pending = [Int: (msg: [String: Any], done: (Data) -> Void, retries: Int)]()
    private var ready = false
    private var documentUri = ""
    /// 当前文档全文（didOpen/didChange 时更新），诊断换算偏移用。
    private var documentText = ""
    private var docVersion = 0

    /// 诊断回调（主线程）
    var onDiagnostics: DiagnosticsHandler?
    /// LSP 就绪/降级回调（主线程）：false = rust-analyzer 不可用
    var onReadyChange: ((Bool) -> Void)?

    /// 探测 rust-analyzer 可执行文件（常见位置 + PATH）。
    static func locate() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/usr/local/bin/rust-analyzer",
            "/opt/homebrew/bin/rust-analyzer",
            "\(home)/.cargo/bin/rust-analyzer",
            "\(home)/.local/bin/rust-analyzer",
            "\(home)/bin/rust-analyzer",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = "\(dir)/rust-analyzer"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// 启动 rust-analyzer 并完成握手（全量打开一份文档）。
    func start(rootPath: String, uri: String, text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let exe = LSPClient.locate() else {
                DispatchQueue.main.async { self.onReadyChange?(false) }
                return
            }
            let p = Process()
            let out = Pipe(); let inp = Pipe(); let err = Pipe()
            p.executableURL = URL(fileURLWithPath: exe)
            // 新版 rust-analyzer（≥1.97）默认 stdio，传 --stdio 反而报 unexpected flag 退出。
            // 旧版需要 --stdio —— 只在显式配置时补（默认不传，兼容新老两代）。
            p.arguments = []
            p.standardOutput = out
            p.standardInput = inp
            p.standardError = err
            // PATH 注入：rust-analyzer 需要 cargo/rustc 来加载 workspace，
            // GUI 进程的 PATH 比登录 shell 窄（~/.cargo/bin 常不在），不注入会
            // "Failed to run cargo metadata: No such file or directory"。
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            var pathExtra = "/usr/local/bin:/opt/homebrew/bin"
            if let rustup = env["RUSTUP_HOME"] {
                pathExtra += ":\(rustup)/toolchains"
            }
            if let c = env["CARGO_HOME"] {
                pathExtra += ":\(c)/bin"
            }
            pathExtra += ":\(home)/.cargo/bin:\(home)/.rustup/toolchains"
            env["PATH"] = (env["PATH"] ?? "") + ":" + pathExtra
            p.environment = env
            err.fileHandleForReading.readabilityHandler = { _ in } // 丢弃 stderr（日志走文件）
            do { try p.run() } catch {
                DispatchQueue.main.async { self.onReadyChange?(false) }
                return
            }
            self.process = p
            self.stdinPipe = inp
            self.documentUri = uri
            self.documentText = text
            self.docVersion = 1
            let fh = out.fileHandleForReading
            self.stdoutHandle = fh
            fh.readabilityHandler = { [weak self] h in
                guard let self else { return }
                let data = h.availableData
                guard !data.isEmpty else { return }
                self.buffer.append(data)
                self.drain()
            }
            // initialize → initialized → didOpen
            self.send(method: "initialize", params: [
                "processId": ProcessInfo.processInfo.processIdentifier,
                "rootUri": "file://\(rootPath)",
                "capabilities": [
                    "textDocument": [
                        "hover": ["contentFormat": ["plaintext", "markdown"]],
                        "completion": ["completionItem": ["documentationFormat": ["plaintext"]]],
                        "definition": ["linkSupport": false],
                        "publishDiagnostics": ["relatedInformation": false],
                    ],
                ],
            ]) { [weak self] _ in
                guard let self else { return }
                self.send(method: "initialized", params: [:], expectsResponse: false)
                self.send(method: "textDocument/didOpen", params: [
                    "textDocument": ["uri": uri, "languageId": "rust", "version": 1, "text": text],
                ], expectsResponse: false)
                self.ready = true
                DispatchQueue.main.async { self.onReadyChange?(true) }
            }
        }
    }

    /// 全文变更（编辑器防抖后调用；全量替换最稳，rust-analyzer 完全支持）。
    func didChange(text: String) {
        queue.async { [weak self] in
            guard let self, self.ready, !self.documentUri.isEmpty else { return }
            self.docVersion += 1
            self.documentText = text
            self.send(method: "textDocument/didChange", params: [
                "textDocument": ["uri": self.documentUri, "version": self.docVersion],
                "contentChanges": [["text": text]],
            ], expectsResponse: false)
        }
    }

    func hover(uri: String, line: Int, character: Int, _ done: @escaping HoverHandler) {
        request("textDocument/hover", params: [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character],
        ]) { [weak self] data in
            guard let self else { done(nil); return }
            let value = self.parseHover(data)
            DispatchQueue.main.async { done(value) }
        }
    }

    func completion(uri: String, line: Int, character: Int, _ done: @escaping CompletionHandler) {
        request("textDocument/completion", params: [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character],
        ]) { [weak self] data in
            guard let self else { done([]); return }
            let items = self.parseCompletion(data)
            DispatchQueue.main.async { done(items) }
        }
    }

    func definition(uri: String, line: Int, character: Int, _ done: @escaping DefinitionHandler) {
        request("textDocument/definition", params: [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character],
        ]) { [weak self] data in
            guard let self else { done(nil); return }
            let pos = self.parseDefinition(data)
            DispatchQueue.main.async { done(pos) }
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.ready = false
            self.send(method: "shutdown", params: [:], expectsResponse: false)
            self.send(method: "exit", params: [:], expectsResponse: false)
            try? self.stdinPipe?.fileHandleForWriting.close()
            self.stdoutHandle?.readabilityHandler = nil
            self.process?.terminate()
            self.process = nil
            self.pending.removeAll()
        }
    }

    // MARK: - 帧收发

    private func send(method: String, params: [String: Any], expectsResponse: Bool = true,
                      _ onResponse: ((Data) -> Void)? = nil) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if expectsResponse {
            let id = nextId; nextId += 1
            msg["id"] = id
            if let onResponse { pending[id] = (msg: [:], done: onResponse, retries: 0) }
        }
        write(msg)
    }

    private func request(_ method: String, params: [String: Any], _ done: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self, self.ready else { done(Data()); return }
            let id = self.nextId; self.nextId += 1
            let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            self.pending[id] = (msg: msg, done: done, retries: 0)
            self.write(msg)
            // 10s 超时：不响应时回调空结果，避免挂起泄漏。
            // -32801 重试会把 pending 换新 id，旧 id 超时不会误伤新请求。
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                if let entry = self.pending.removeValue(forKey: id) {
                    entry.done(Data())
                }
            }
        }
    }

    private func write(_ obj: [String: Any]) {
        guard let fh = stdinPipe?.fileHandleForWriting else { return }
        do {
            let body = try JSONSerialization.data(withJSONObject: obj)
            var head = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)!
            head.append(body)
            fh.write(head)
        } catch { Log.warn("LSP 发送失败：\(error.localizedDescription)", "lsp") }
    }

    /// 从缓冲区按 Content-Length 帧解析。帧不完整就等更多数据。
    private func drain() {
        while true {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            guard let lenLine = header.split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                let len = Int(lenLine.split(separator: ":").last!.trimmingCharacters(in: .whitespaces))
            else { return }
            let bodyStart = headerEnd.upperBound
            guard buffer.count >= bodyStart + len else { return }
            let body = Data(buffer[bodyStart..<(bodyStart + len)])
            buffer.removeSubrange(0..<(bodyStart + len))
            handleFrame(body)
        }
    }

    private func handleFrame(_ body: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
        if let id = obj["id"] as? Int, let entry = pending.removeValue(forKey: id) {
            // -32801 ContentModified：rust-analyzer 首轮分析/文档更新窗口会拒绝位置请求
            // （VS Code 等客户端同样自动重试）。重发（新 id），最多 3 次，间隔 250ms。
            if !entry.msg.isEmpty, entry.retries < 3,
               let error = obj["error"] as? [String: Any],
               let code = error["code"] as? Int, code == -32801 {
                var msg = entry.msg
                let newId = nextId; nextId += 1
                msg["id"] = newId
                pending[newId] = (msg: msg, done: entry.done, retries: entry.retries + 1)
                queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.write(msg) }
                return
            }
            // 请求的响应：result 可能为 null（如 hover 无内容）→ 空 Data 表示"无结果"
            if let result = obj["result"],
               let data = try? JSONSerialization.data(withJSONObject: result) { entry.done(data) }
            else { entry.done(Data()) }
            return
        }
        guard let method = obj["method"] as? String else { return }
        if method == "textDocument/publishDiagnostics",
           let params = obj["params"] as? [String: Any] {
            let items = (params["diagnostics"] as? [[String: Any]]) ?? []
            let text = documentText  // 队列内读取，安全
            DispatchQueue.main.async { [weak self] in
                self?.publishDiagnostics(items, text: text)
            }
        }
    }

    /// LSP 行/列（UTF-16 code unit）→ NSString 偏移。行超界返回 NSNotFound。
    private func utf16Offset(line: Int, character: Int, in ns: NSString) -> Int {
        var offset = 0
        var l = 0
        while l < line && offset < ns.length {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: offset, length: ns.length - offset))
            if r.location == NSNotFound { return NSNotFound }
            offset = r.location + 1
            l += 1
        }
        guard offset <= ns.length else { return NSNotFound }
        return min(offset + character, ns.length)
    }

    private func publishDiagnostics(_ items: [[String: Any]], text: String) {
        let ns = text as NSString
        var diags: [Diagnostic] = []
        for d in items {
            guard let range = d["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let line = start["line"] as? Int,
                  let ch = start["character"] as? Int,
                  let end = range["end"] as? [String: Any],
                  let endLine = end["line"] as? Int,
                  let endCh = end["character"] as? Int,
                  let message = d["message"] as? String else { continue }
            let severity = (d["severity"] as? Int) ?? 2 // 1=Error 2=Warning
            let loc = utf16Offset(line: line, character: ch, in: ns)
            let endLoc = utf16Offset(line: endLine, character: endCh, in: ns)
            guard loc != NSNotFound, endLoc >= loc, endLoc <= ns.length else { continue }
            diags.append(Diagnostic(range: NSRange(location: loc, length: endLoc - loc),
                                    message: message, isError: severity <= 1))
        }
        onDiagnostics?(diags)
    }

    // MARK: - 响应解析

    private func parseHover(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // contents 可能是 MarkupContent {kind,value} 或 MarkedString[] / string
        if let markup = obj["contents"] as? [String: Any], let value = markup["value"] as? String {
            return value
        }
        if let s = obj["contents"] as? String { return s }
        if let arr = obj["contents"] as? [Any] {
            var parts: [String] = []
            for a in arr {
                if let s = a as? String { parts.append(s) }
                else if let m = a as? [String: Any], let v = m["value"] as? String { parts.append(v) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        return nil
    }

    private func parseCompletion(_ data: Data) -> [(label: String, detail: String)] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let items: [[String: Any]]
        if let arr = obj["items"] as? [[String: Any]] { items = arr }
        else { items = [] }
        return items.prefix(50).map { item in
            let label = (item["label"] as? String) ?? ""
            let detail = (item["detail"] as? String) ?? ""
            return (label, detail)
        }
    }

    private func parseDefinition(_ data: Data) -> (line: Int, character: Int)? {
        // 新版 rust-analyzer 返回 Location[]（裸数组）；老版可能返回单条 Location 或 {locations:[…]}
        if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let first = arr.first, let range = first["range"] as? [String: Any],
           let start = range["start"] as? [String: Any],
           let line = start["line"] as? Int, let ch = start["character"] as? Int {
            return (line, ch)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // 单条 Location {uri, range:{start}}
        if let range = obj["range"] as? [String: Any], let start = range["start"] as? [String: Any],
           let line = start["line"] as? Int, let ch = start["character"] as? Int {
            return (line, ch)
        }
        // 老式 {locations:[…]}
        if let arr = obj["locations"] as? [[String: Any]],
           let first = arr.first, let range = first["range"] as? [String: Any],
           let start = range["start"] as? [String: Any],
           let line = start["line"] as? Int, let ch = start["character"] as? Int {
            return (line, ch)
        }
        return nil
    }
}
