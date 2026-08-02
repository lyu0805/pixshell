import Foundation

// ============================================================================
// 终端语义高亮引擎（从 Electron 老仓库 renderer/app.js 的 decoratePlainChunk /
// HL_LIGHT / HL_DARK 移植）。
//
// 设计要点（与老仓库一致）：
//  1. 只装饰"纯文本段"，远端已有的 ANSI/OSC 转义序列原样保留，绝不破坏。
//     顶层 decorate() 先按转义序列把输入切开，只对非转义片段做染色。
//  2. 占位符法防止重复上色/嵌套：命中的语义片段先替换成私有区占位符
//     U+E000<index>U+E001，后续规则通过 replaceSafe 跳过占位区间，最后统一把
//     占位符展开成 truecolor SGR。这样一段文本里同时含路径/IP/关键词时不会互相
//     吃掉，也不会二次上色。
//  3. 明暗两套 24 位真彩调色板（HL_LIGHT / HL_DARK），十六进制值照搬老仓库最新实现。
//     err/warn/ok 加粗；url 额外带下划线。
//
// 纯逻辑、无 UI 依赖、无第三方依赖。对外入口：SemanticHighlight.decorate(_:dark:)
// ============================================================================

enum SemanticHighlight {

    // MARK: - 调色板（truecolor，照搬老仓库十六进制值）

    /// 前景真彩：#RRGGBB -> ESC[38;2;R;G;Bm
    private static func tc(_ hex: String) -> String {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        let n = Int(h, radix: 16) ?? 0
        let r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255
        return "\u{1b}[38;2;\(r);\(g);\(b)m"
    }
    /// 加粗 + 前景真彩
    private static func tcb(_ hex: String) -> String { "\u{1b}[1m" + tc(hex) }

    // 浅色底(#d4d6dc / 近黑字)：中偏深高彩度色，与近黑正文双向拉开距离。
    private static let HL_LIGHT: [String: String] = [
        "url": "\u{1b}[4m" + tc("#0a6d8c"), // 青 + 下划线：链接
        "path": tc("#1553d6"),              // 蓝：文件/目录路径
        "ip": tc("#0a72a0"),                // 青：IP
        "domain": tc("#0a72a0"),            // 青：域名
        "userhost": tc("#4b3fd0"),          // 靛：user@host
        "port": tc("#1a7d2e"),              // 绿：端口
        "mac": tc("#9127bf"),               // 紫：MAC
        "date": tc("#5f6470"),              // 板岩灰：时间戳（次要）
        "size": tc("#b85c00"),              // 橙：大小/速率
        "num": tc("#5f6470"),               // 板岩灰：数字
        "hex": tc("#9127bf"),               // 紫：hash/十六进制
        "perm": tc("#1a7d2e"),              // 绿：权限位
        "err": tcb("#e00020"),              // 加粗红：错误
        "warn": tcb("#a85a00"),             // 加粗琥珀：警告
        "ok": tcb("#127a34"),               // 加粗绿：成功
        "kw": tc("#b21ab0"),                // 品红：运维关键词
        "str": tc("#0f7a5a"),               // 墨绿：引号字符串
        "delim": tc("#6a6f7a"),             // 灰：括号
    ]

    // 深色底(暗底 / 浅字)：高饱和亮色。
    private static let HL_DARK: [String: String] = [
        "url": "\u{1b}[4m" + tc("#5cd6e8"), // 亮青 + 下划线：链接
        "path": tc("#6aa8ff"),              // 亮蓝：文件/目录路径
        "ip": tc("#4fd0e0"),                // 亮青：IP
        "domain": tc("#4fd0e0"),            // 亮青：域名
        "userhost": tc("#a99bff"),          // 亮靛：user@host
        "port": tc("#5fe08a"),              // 亮绿：端口
        "mac": tc("#ff86d4"),               // 亮品红：MAC
        "date": tc("#9aa0ac"),              // 灰：时间戳（次要）
        "size": tc("#ffb340"),              // 琥珀：大小/速率
        "num": tc("#9aa0ac"),               // 灰：数字
        "hex": tc("#ff86d4"),               // 亮品红：hash/十六进制
        "perm": tc("#5fe08a"),              // 亮绿：权限位
        "err": tcb("#ff5a4d"),              // 加粗亮红：错误
        "warn": tcb("#ffc233"),             // 加粗琥珀：警告
        "ok": tcb("#57e08a"),               // 加粗亮绿：成功
        "kw": tc("#d79bff"),                // 亮紫：运维关键词
        "str": tc("#63d9b0"),               // 亮墨绿：引号字符串
        "delim": tc("#8a90a0"),             // 灰：括号
    ]

    // MARK: - 占位符 / 状态

    // 私有区占位符：SO<index>EO。禁止泄漏到最终输出，replaceSafe 跳过其区间防嵌套。
    private static let SO = "\u{E000}"
    private static let EO = "\u{E001}"

    /// 单次装饰过程的占位符插槽表。
    private final class HLState {
        var slots: [(s: String, kind: String)] = []
        func put(_ s: String, _ kind: String) -> String {
            let i = slots.count
            slots.append((s, kind))
            return SO + "\(i)" + EO
        }
    }

    // MARK: - 预编译正则

    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: p, options: opts)
    }

    // 顶层：切分已有 ANSI/OSC 转义序列（与老仓库 decorateOutput 的 split 正则一致）。
    private static let ansiRe = re(#"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[()][0-9A-B0-2]|\x1b[>=]"#)

    // 占位符匹配（用真实私有区字符构造，避开 ICU 不认 \u{...} 的问题）。
    private static let markerRe = re(SO + #"(\d+)"# + EO)

    // 各识别规则（编号对应老仓库注释）。
    private static let rURL      = re(#"(?:https?|ftp|sftp|ssh|wss?)://[^\s<>"'`]+"#, [.caseInsensitive])
    private static let rWarnStar = re(#"\*{2,}[^*\n]+\*{2,}"#)
    private static let rPerm     = re(#"(?:^|[\s|])([dlsbcps-](?:[r-][w-][xsStT-]){3})(?=[\s|]|$)"#, [.anchorsMatchLines])
    // 注意：ICU 把字符类里未转义的 `[` 当作嵌套集起始，故 `[` 一律写成 `\[`（JS 里是字面量）。
    private static let rPath     = re(#"(?:^|[\s"'`=,:(\[])((?:/(?:[\w.+@$-]+/)+[\w.+@$-]*|/[\w.+@$-]{2,}|(?:~|\$HOME)(?:/[\w.+@$-]+)+))(?=[\s"'`),;:]|$)"#, [.anchorsMatchLines])
    private static let rMAC      = re(#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#)
    private static let rIPv4     = re(#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?::\d{1,5})?\b"#)
    private static let rIPv6Br   = re(#"\[(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}\]:\d{1,5}"#)
    private static let rIPv6     = re(#"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{0,4}\b|\b(?:[0-9A-Fa-f]{1,4}:){1,7}:|::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}\b"#)
    private static let rUserHost = re(#"\b([a-zA-Z_][\w.-]*@[a-zA-Z0-9][\w.-]*\.[a-zA-Z]{2,}|[a-zA-Z_][\w.-]*@[a-zA-Z0-9][\w.-]+)\b"#)
    private static let rDomain   = re(#"\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+(?:com|net|org|io|dev|app|cn|jp|edu|gov|local|internal|lan|test|xyz|cloud|ai|co|me|info|biz|tech)(?::\d{1,5})?\b"#, [.caseInsensitive])
    private static let rPortStar = re(#"\*(?::|\s)\d{2,5}\b"#)
    private static let rPort     = re(#"(?<![0-9A-Fa-f:]):([1-9]\d{0,4})\b"#)
    private static let rDateA    = re(#"\b\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?\b"#)
    private static let rDateB    = re(#"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}(?::\d{2})?\b"#)
    private static let rDateC    = re(#"\b\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?\b"#)
    private static let rSize     = re(#"\b\d+(?:\.\d+)?\s?(?:[KMGTPE]i?B?|[kmgtpe]i?b?)(?:/s)?\b"#)
    private static let rHex0x    = re(#"\b0x[0-9A-Fa-f]{2,}\b"#)
    private static let rHash     = re(#"\b[0-9a-f]{8,40}\b"#, [.caseInsensitive])
    // ── 借鉴 tailspin 的类别（我们原先没覆盖）──────────────────────────
    /// UUID：要排在 hash 规则前面，否则会被 8-40 位 hex 规则先吃掉半截
    private static let rUUID   = re(#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)
    /// HTTP 方法（REST 动词）
    private static let rMethod = re(#"\b(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE|CONNECT)\b"#)
    /// 进程名[pid]：syslog 里到处都是，例如 sshd[1234]
    private static let rProcPid = re(#"\b[a-zA-Z_][\w.-]*\[\d+\]"#)
    /// 时长：12ms / 1.5s / 300µs（数字和单位之间不留空格，避免把 "5 m" 这种误判）
    private static let rDuration = re(#"\b\d+(?:\.\d+)?(?:ns|µs|us|ms|s|m|h)\b"#)
    /// key=value 的 key 部分
    private static let rKey    = re(#"\b[\w.-]+(?==)"#)
    /// 引号字符串：放在最后，内部已被着色的片段不会被整段吞掉
    private static let rQuoted = re(#"\"[^\"\n]{1,200}\"|'[^'\n]{1,200}'"#)

    private static let rHTTP     = re(#"\b(?:HTTP/\d\.\d\s+)?([1-5]\d{2})\b(?=\s|$|[,;)\]}])"#)
    // ── Rust 工具链输出（cargo / rustc）────────────────────────────────────
    // 这些是 Rust 特有的形状，通用的 error/warning 词表覆盖不到或覆盖得太粗：
    /// `error[E0382]:` / `warning[E0170]:` —— 带错误码的诊断头
    private static let rRustDiagCode = re(#"\b(?:error|warning)\[E\d{4}\]"#)
    /// `  --> src/main.rs:12:9` —— 定位行（含文件:行:列）
    private static let rRustArrowLoc = re(#"-->\s+\S+?:\d+:\d+"#)
    /// `thread 'main' panicked at ...`
    private static let rRustPanic    = re(#"thread\s+'[^']*'\s+panicked\s+at"#)
    /// cargo 的进度动词：Compiling / Finished / Running / Fresh / Downloaded…
    private static let rCargoAction  = re(#"^\s*(?:Compiling|Checking|Finished|Running|Fresh|Downloaded|Installing|Updating|Packaging|Uploading|Blocking)\b"#, [.anchorsMatchLines])
    /// `test foo::bar ... ok` / `... FAILED`
    private static let rRustTestOk   = re(#"\.\.\.\s+ok\b"#)
    private static let rRustTestFail = re(#"\.\.\.\s+FAILED\b"#)
    /// `test result: ok. 12 passed; 0 failed`
    private static let rRustTestSum  = re(#"test result:\s+\w+\."#)

    private static let rErrEN    = re(#"\b(?:error|errors|fail(?:ed|ure|ures)?|fatal|critical|exception|denied|refused|panic|traceback|segfault|oom|killed|unable|cannot|can't|not found|no such|permission denied|connection refused|timed?\s*out|timeout|unauthorized|forbidden|invalid|corrupt(?:ed)?|broken|crash(?:ed)?)\b"#, [.caseInsensitive])
    private static let rErrZH    = re(#"(?:错误|失败|异常|崩溃|拒绝|超时|未找到|无权限|权限不足|连接拒绝|致命)"#)
    private static let rWarnEN   = re(#"\b(?:warn(?:ing|ings)?|deprecated|caution|notice|restart required|system restart required)\b"#, [.caseInsensitive])
    private static let rWarnZH   = re(#"(?:警告|注意|弃用|即将过期)"#)
    private static let rOkEN     = re(#"\b(?:ok|okay|success(?:ful(?:ly)?)?|done|ready|passed|complete(?:d)?|enabled|active|running|listening|connected|online|healthy|available)\b"#, [.caseInsensitive])
    private static let rOkZH     = re(#"(?:成功|完成|就绪|已连接|正常|在线|健康)"#)
    private static let rPct9     = re(#"\b(9\d(?:\.\d+)?%)\b"#)
    private static let rPct8     = re(#"\b(8\d(?:\.\d+)?%)\b"#)
    private static let rPct17    = re(#"\b([1-7]?\d(?:\.\d+)?%)\b"#)
    private static let rKw       = re(#"\b(?:sudo|systemctl|journalctl|docker|kubectl|nginx|redis|mysql|postgres|ssh|scp|rsync|chmod|chown|mount|umount|iptables|firewalld|cron|systemd)\b"#)
    private static let rDelim    = re(#"[()\[\]{}]"#)

    // MARK: - 底层正则替换（NSString 保证 UTF-16 偏移一致）

    /// 对整段文本应用一次正则；transform 收到 (整段匹配, 分组数组[0]=整段) 返回替换文本。
    private static func applyRegex(_ text: String, _ regex: NSRegularExpression,
                                   _ transform: (String, [String?]) -> String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var result = ""
        var idx = 0
        for m in matches {
            let r = m.range
            if r.location > idx {
                result += ns.substring(with: NSRange(location: idx, length: r.location - idx))
            }
            let whole = ns.substring(with: r)
            var groups: [String?] = []
            for gi in 0..<m.numberOfRanges {
                let gr = m.range(at: gi)
                groups.append(gr.location == NSNotFound ? nil : ns.substring(with: gr))
            }
            result += transform(whole, groups)
            idx = r.location + r.length
        }
        if idx < ns.length {
            result += ns.substring(with: NSRange(location: idx, length: ns.length - idx))
        }
        return result
    }

    /// 跳过已有占位符区间，只对"未占位"文本片段应用正则（防重复上色 / 防嵌套）。
    private static func replaceSafe(_ str: String, _ regex: NSRegularExpression,
                                    _ transform: (String, [String?]) -> String) -> String {
        let ns = str as NSString
        let markers = markerRe.matches(in: str, range: NSRange(location: 0, length: ns.length))
        if markers.isEmpty { return applyRegex(str, regex, transform) }
        var result = ""
        var idx = 0
        for mm in markers {
            let r = mm.range
            if r.location > idx {
                let sub = ns.substring(with: NSRange(location: idx, length: r.location - idx))
                result += applyRegex(sub, regex, transform)
            }
            result += ns.substring(with: r) // 占位符原样保留
            idx = r.location + r.length
        }
        if idx < ns.length {
            let sub = ns.substring(with: NSRange(location: idx, length: ns.length - idx))
            result += applyRegex(sub, regex, transform)
        }
        return result
    }

    /// NSString 语义的 indexOf（返回 UTF-16 偏移），用于 perm/path 规则里的前缀切分。
    private static func indexOf(_ haystack: String, _ needle: String) -> Int {
        let r = (haystack as NSString).range(of: needle)
        return r.location == NSNotFound ? -1 : r.location
    }

    private static func prefix(_ s: String, _ len: Int) -> String {
        (s as NSString).substring(to: len)
    }

    // MARK: - 单纯文本段装饰（对应老仓库 decoratePlainChunk 的 21 条规则）

    private static func decoratePlainChunk(_ chunk: String, dark: Bool) -> String {
        let st = HLState()
        // kind 直染便捷闭包工厂
        func k(_ kind: String) -> (String, [String?]) -> String { { m, _ in st.put(m, kind) } }

        var s = chunk

        // 规则顺序 = 优先级（占位符机制先匹配者胜）。**更具体的必须排在更泛的前面**，
        // 否则会被泛规则抢走：实测踩过两次 —— "12:30:00" 被裸 IPv6 当成地址、
        // "--> src/main.rs:10:5" 里的 ":10" 被通用 :PORT 当成端口。改顺序前先想清楚这点。

        // 1) URL（含 ftp/ssh/ws）
        s = replaceSafe(s, rURL, k("url"))
        // 2) *** 警告块
        s = replaceSafe(s, rWarnStar, k("warn"))
        // 3) Rust 工具链输出：必须最先，它的形态最具体
        //    （error[E0382] 要整体标红；--> file:line:col 要整体当路径，不能被 :PORT 咬掉）
        s = replaceSafe(s, rRustDiagCode, k("err"))
        s = replaceSafe(s, rRustPanic, k("err"))
        s = replaceSafe(s, rRustArrowLoc, k("path"))
        s = replaceSafe(s, rRustTestFail, k("err"))
        s = replaceSafe(s, rRustTestOk, k("ok"))
        s = replaceSafe(s, rRustTestSum, k("ok"))
        s = replaceSafe(s, rCargoAction, k("kw"))
        // 4) Unix 权限位（ls -l 首列）：p1 为权限串，前导分隔符原样保留
        s = replaceSafe(s, rPerm) { m, g in
            guard let p1 = g[1] else { return st.put(m, "perm") }
            let i = indexOf(m, p1)
            if i <= 0 { return st.put(m, "perm") }
            return prefix(m, i) + st.put(p1, "perm")
        }
        // 5) 绝对路径 / 家目录路径
        s = replaceSafe(s, rPath) { m, g in
            guard let p1 = g[1] else { return st.put(m, "path") }
            let i = indexOf(m, p1)
            if i < 0 { return st.put(m, "path") }
            return prefix(m, i) + st.put(p1, "path")
        }
        // 6) 时间戳：必须排在 IP 之前 —— "12:30:00" 会被裸 IPv6 规则误判成地址
        s = replaceSafe(s, rDateA, k("date"))
        s = replaceSafe(s, rDateB, k("date"))
        s = replaceSafe(s, rDateC, k("date"))
        // 7) MAC
        s = replaceSafe(s, rMAC, k("mac"))
        // 8) IPv4 可选 :端口
        s = replaceSafe(s, rIPv4, k("ip"))
        // 9) [IPv6]:port
        s = replaceSafe(s, rIPv6Br, k("ip"))
        // 10) 裸 IPv6（至少两枚冒号）
        s = replaceSafe(s, rIPv6) { m, _ in
            if (m as NSString).length < 3 || !m.contains(":") { return m }
            let colons = m.filter { $0 == ":" }.count
            if colons < 2 { return m }
            return st.put(m, "ip")
        }
        // 11) user@host
        s = replaceSafe(s, rUserHost, k("userhost"))
        // 12) 域名 / FQDN
        s = replaceSafe(s, rDomain, k("domain"))
        // 13) *:PORT / * PORT
        s = replaceSafe(s, rPortStar, k("port"))
        // 14) 独立 :PORT（1–65535；前不接 hex/冒号）
        s = replaceSafe(s, rPort) { m, g in
            guard let p1 = g[1], let n = Int(p1), n >= 1, n <= 65535 else { return m }
            return st.put(m, "port")
        }
        // 15) 文件大小 / 速率
        s = replaceSafe(s, rSize, k("size"))
        // 16) UUID（必须先于 hash，否则被 8-40 位 hex 规则吃掉半截）/ 十六进制 / hash
        s = replaceSafe(s, rUUID, k("hex"))
        s = replaceSafe(s, rHex0x, k("hex"))
        s = replaceSafe(s, rHash) { m, _ in
            // 纯十进制不当作 hash
            if m.allSatisfy({ $0.isNumber }) { return m }
            return st.put(m, "hex")
        }
        // 17) HTTP 状态码（5xx=err / 4xx=warn / 2xx=ok / 其余=num）
        s = replaceSafe(s, rHTTP) { m, g in
            guard let code = g[1], let n = Int(code) else { return st.put(m, "num") }
            if n >= 500 { return st.put(m, "err") }
            if n >= 400 { return st.put(m, "warn") }
            if n >= 200 && n < 300 { return st.put(m, "ok") }
            return st.put(m, "num")
        }
        // 18) 错误 / 警告（中英）
        s = replaceSafe(s, rErrEN, k("err"))
        s = replaceSafe(s, rErrZH, k("err"))
        s = replaceSafe(s, rWarnEN, k("warn"))
        s = replaceSafe(s, rWarnZH, k("warn"))
        // 19) 成功词（中英）
        s = replaceSafe(s, rOkEN, k("ok"))
        s = replaceSafe(s, rOkZH, k("ok"))
        // 20) 占用百分比：>=90 红 / >=80 琥珀 / 其余灰
        s = replaceSafe(s, rPct9, k("err"))
        s = replaceSafe(s, rPct8, k("warn"))
        s = replaceSafe(s, rPct17, k("num"))
        // 21) 借鉴 tailspin：HTTP 方法 / 进程名[pid] / 时长 / key=value 的 key
        s = replaceSafe(s, rMethod, k("kw"))
        s = replaceSafe(s, rProcPid, k("kw"))
        s = replaceSafe(s, rDuration, k("num"))
        s = replaceSafe(s, rKey, k("kw"))
        // 22) 常见运维关键词
        s = replaceSafe(s, rKw, k("kw"))
        // 23) 引号字符串（放最后：内部已着色的片段不会被整段吞掉）
        s = replaceSafe(s, rQuoted, k("str"))
        // 24) 括号字符轻量着色
        s = replaceSafe(s, rDelim, k("delim"))

        // ── 展开占位符为 truecolor SGR ──
        // 用户在设置里自定义了「高亮文字颜色」→ 整套 token 统一用它（保留下划线/加粗等属性），
        // 没设就用内置的明暗调色板。见 Store/HighlightColors.swift。
        var color = dark ? HL_DARK : HL_LIGHT
        if let hex = HighlightColors.highlightHex {
            let want = tc(hex)
            color = color.mapValues { v in
                // 原值里可能带 ESC[4m(下划线)/ESC[1m(加粗) 前缀，只替换其中的前景色部分
                let attrs = v.replacingOccurrences(of: #"\u{1b}\[38;2;\d+;\d+;\d+m"#,
                                                   with: "", options: .regularExpression)
                return attrs + want
            }
        }
        let reset = "\u{1b}[0m"
        var guardCount = 0
        // slots 内容不含占位符（replaceSafe 已保证匹配不跨占位区），单遍即可；
        // 仍保留循环以对齐老仓库的防御性实现。
        while (s as NSString).range(of: SO).location != NSNotFound && guardCount < 24 {
            guardCount += 1
            s = applyRegex(s, markerRe) { _, g in
                guard let idxStr = g[1], let n = Int(idxStr), n < st.slots.count else { return "" }
                let item = st.slots[n]
                return (color[item.kind] ?? "\u{1b}[1;36m") + item.s + reset
            }
        }
        // 清理任何残留占位符
        s = applyRegex(s, markerRe) { _, _ in "" }
        return s
    }

    // MARK: - 对外入口

    /// 对一段（可能含已有 ANSI 转义的）终端文本注入语义高亮 SGR。
    /// - Parameters:
    ///   - chunk: 原始终端输出片段。
    ///   - dark: true 用深色调色板，false 用浅色调色板。
    /// - Returns: 注入了语义高亮的文本；已有转义序列原样保留，不重复上色。
    static func decorate(_ chunk: String, dark: Bool) -> String {
        if chunk.isEmpty { return chunk }
        // 「普通文字颜色」：给整块先铺一层前景色，高亮 token 之后会各自覆盖回自己的颜色。
        // 只在用户显式设置过时才加，默认一个字节都不多写。
        if let plain = HighlightColors.plainHex {
            return tc(plain) + decorateBody(chunk, dark: dark)
        }
        return decorateBody(chunk, dark: dark)
    }

    private static func decorateBody(_ chunk: String, dark: Bool) -> String {
        let ns = chunk as NSString
        let matches = ansiRe.matches(in: chunk, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return decoratePlainChunk(chunk, dark: dark) }
        var out = ""
        var idx = 0
        for m in matches {
            let r = m.range
            if r.location > idx {
                let plain = ns.substring(with: NSRange(location: idx, length: r.location - idx))
                out += decoratePlainChunk(plain, dark: dark)
            }
            out += ns.substring(with: r) // 转义序列原样保留
            idx = r.location + r.length
        }
        if idx < ns.length {
            out += decoratePlainChunk(ns.substring(with: NSRange(location: idx, length: ns.length - idx)), dark: dark)
        }
        return out
    }
}

// ============================================================================
// 自测样例（main-less；实际运行结果见下方注释，转义符以 <ESC> 代替 \x1b 便于阅读）。
// 用 scratch 独立可执行程序验证过，逻辑与老仓库一致。
//
// 输入: "GET /var/log/syslog 200 OK from 192.168.1.10:8080"
// 输出(dark): 路径 /var/log/syslog 染亮蓝、200 与 OK 染亮绿(加粗)、
//            192.168.1.10:8080 染亮青。例如 200 =>
//            <ESC>[1m<ESC>[38;2;87;224;138m200<ESC>[0m
//
// 输入: "ERROR: connection refused to db.internal.lan CPU 95%"
// 输出(light): ERROR / connection refused 染加粗红、db.internal.lan 染青(domain)、
//            95% 染加粗红(>=90)。
//
// 输入: "-rw-r--r-- 1 root 4.0K 2026-07-26 12:30:00 /etc/hosts"
// 输出: 权限位 -rw-r--r-- 染绿、4.0K 染橙(size)、2026-07-26...染灰(date)、
//            /etc/hosts 染蓝(path)。
//
// 输入: 已含 ANSI 的 "<ESC>[31mred<ESC>[0m /tmp/x" => 前段 <ESC>[31m 原样保留，
//            仅对 " /tmp/x" 追加 path 染色，不破坏已有转义。
// ============================================================================
