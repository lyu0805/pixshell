using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace PixShell.Highlight;

/// <summary>
/// 终端输出语义高亮 —— 1:1 移植自 mac Highlight/SemanticHighlight.swift（后者又移植自老仓库）。
/// Windows 端此前**完全没有**这个能力，是两端一处真实的功能差；补上后
/// 「自定义高亮/普通文字颜色」「cargo 输出着色」才有宿主可挂。
///
/// 做法：把识别到的片段先换成**私有区占位符**（SO&lt;index&gt;EO），后续规则跳过占位区，
/// 因此不会重复上色 / 嵌套；最后一次性展开成 truecolor SGR。
/// 已有的 ANSI/OSC 转义序列原样保留，只对"纯文本段"着色。
/// </summary>
public static class SemanticHighlight
{
    // ── 调色板（truecolor，照搬老仓库十六进制值）──────────────────────────
    private static string Tc(string hex)
    {
        var h = hex.TrimStart('#');
        var n = Convert.ToInt32(h, 16);
        return $"\u001b[38;2;{(n >> 16) & 255};{(n >> 8) & 255};{n & 255}m";
    }
    private static string Tcb(string hex) => "\u001b[1m" + Tc(hex);

    /// 浅色底：中偏深高彩度色，与近黑正文双向拉开距离。
    private static readonly Dictionary<string, string> HlLight = new()
    {
        ["url"] = "\u001b[4m" + Tc("#0a6d8c"), ["path"] = Tc("#1553d6"),
        ["ip"] = Tc("#0a72a0"), ["domain"] = Tc("#0a72a0"), ["userhost"] = Tc("#4b3fd0"),
        ["port"] = Tc("#1a7d2e"), ["mac"] = Tc("#9127bf"), ["date"] = Tc("#5f6470"),
        ["size"] = Tc("#b85c00"), ["num"] = Tc("#5f6470"), ["hex"] = Tc("#9127bf"),
        ["perm"] = Tc("#1a7d2e"), ["err"] = Tcb("#e00020"), ["warn"] = Tcb("#a85a00"),
        ["ok"] = Tcb("#127a34"), ["kw"] = Tc("#b21ab0"), ["delim"] = Tc("#6a6f7a"),
        ["str"] = Tc("#0f7a5a"),
    };

    /// 深色底：高饱和亮色。
    private static readonly Dictionary<string, string> HlDark = new()
    {
        ["url"] = "\u001b[4m" + Tc("#5cd6e8"), ["path"] = Tc("#6aa8ff"),
        ["ip"] = Tc("#ff5a4d"), ["domain"] = Tc("#ff5a4d"), ["userhost"] = Tc("#a99bff"),
        ["port"] = Tc("#5fe08a"), ["mac"] = Tc("#ff86d4"), ["date"] = Tc("#ff5a4d"),
        ["size"] = Tc("#ffb340"), ["num"] = Tc("#9aa0ac"), ["hex"] = Tc("#ff86d4"),
        ["perm"] = Tc("#5fe08a"), ["err"] = Tcb("#ff5a4d"), ["warn"] = Tcb("#ffc233"),
        ["ok"] = Tcb("#57e08a"), ["kw"] = Tc("#d79bff"), ["delim"] = Tc("#8a90a0"),
        ["str"] = Tc("#63d9b0"),
    };

    // ── 占位符 ──────────────────────────────────────────────────────────
    private const string SO = "\uE000";
    private const string EO = "\uE001";

    private sealed class State
    {
        public readonly List<(string S, string Kind)> Slots = new();
        public string Put(string s, string kind) { Slots.Add((s, kind)); return SO + (Slots.Count - 1) + EO; }
    }

    private static Regex Re(string p, RegexOptions o = RegexOptions.None) => new(p, o | RegexOptions.Compiled);

    // 顶层：切分已有 ANSI/OSC 转义序列
    private static readonly Regex AnsiRe = Re(@"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[()][0-9A-B0-2]|\x1b[>=]");
    private static readonly Regex MarkerRe = Re(SO + @"(\d+)" + EO);

    // ── 各识别规则（编号对应老仓库注释）──────────────────────────────────
    private static readonly Regex RUrl = Re(@"(?:https?|ftp|sftp|ssh|wss?)://[^\s<>""'`]+", RegexOptions.IgnoreCase);
    private static readonly Regex RWarnStar = Re(@"\*{2,}[^*\n]+\*{2,}");
    private static readonly Regex RPerm = Re(@"(?:^|[\s|])([dlsbcps-](?:[r-][w-][xsStT-]){3})(?=[\s|]|$)", RegexOptions.Multiline);
    private static readonly Regex RPath = Re(@"(?:^|[\s""'`=,:(\[])((?:/(?:[\w.+@$-]+/)+[\w.+@$-]*|/[\w.+@$-]{2,}|(?:~|\$HOME)(?:/[\w.+@$-]+)+))(?=[\s""'`),;:]|$)", RegexOptions.Multiline);
    private static readonly Regex RMac = Re(@"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b");
    private static readonly Regex RIPv4 = Re(@"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?::\d{1,5})?\b");
    private static readonly Regex RIPv6Br = Re(@"\[(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}\]:\d{1,5}");
    private static readonly Regex RIPv6 = Re(@"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{0,4}\b|\b(?:[0-9A-Fa-f]{1,4}:){1,7}:|::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}\b");
    private static readonly Regex RUserHost = Re(@"\b([a-zA-Z_][\w.-]*@[a-zA-Z0-9][\w.-]*\.[a-zA-Z]{2,}|[a-zA-Z_][\w.-]*@[a-zA-Z0-9][\w.-]+)\b");
    private static readonly Regex RDomain = Re(@"\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+(?:com|net|org|io|dev|app|cn|jp|edu|gov|local|internal|lan|test|xyz|cloud|ai|co|me|info|biz|tech)(?::\d{1,5})?\b", RegexOptions.IgnoreCase);
    private static readonly Regex RPortStar = Re(@"\*(?::|\s)\d{2,5}\b");
    private static readonly Regex RPort = Re(@"(?<![0-9A-Fa-f:]):([1-9]\d{0,4})\b");
    private static readonly Regex RDateA = Re(@"\b\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?\b");
    private static readonly Regex RDateB = Re(@"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}(?::\d{2})?\b");
    private static readonly Regex RDateC = Re(@"\b\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?\b");
    private static readonly Regex RSize = Re(@"\b\d+(?:\.\d+)?\s?(?:[KMGTPE]i?B?|[kmgtpe]i?b?)(?:/s)?\b");
    private static readonly Regex RHex0x = Re(@"\b0x[0-9A-Fa-f]{2,}\b");
    private static readonly Regex RHash = Re(@"\b[0-9a-f]{8,40}\b", RegexOptions.IgnoreCase);
    // ── 借鉴 tailspin（github.com/bensadeh/tailspin）的类别 ──────────────
    private static readonly Regex RUuid = Re(@"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b");
    private static readonly Regex RMethod = Re(@"\b(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE|CONNECT)\b");
    private static readonly Regex RProcPid = Re(@"\b[a-zA-Z_][\w.-]*\[\d+\]");
    private static readonly Regex RDuration = Re(@"\b\d+(?:\.\d+)?(?:ns|µs|us|ms|s|m|h)\b");
    private static readonly Regex RKey = Re(@"\b[\w.-]+(?==)");
    private static readonly Regex RQuoted = Re("\"[^\"\n]{1,200}\"|'[^'\n]{1,200}'");

    private static readonly Regex RHttp = Re(@"\b(?:HTTP/\d\.\d\s+)?([1-5]\d{2})\b(?=\s|$|[,;)\]}])");

    // ── Rust 工具链输出（cargo / rustc）────────────────────────────────
    private static readonly Regex RRustDiagCode = Re(@"\b(?:error|warning)\[E\d{4}\]");
    private static readonly Regex RRustArrowLoc = Re(@"-->\s+\S+?:\d+:\d+");
    private static readonly Regex RRustPanic = Re(@"thread\s+'[^']*'\s+panicked\s+at");
    private static readonly Regex RCargoAction = Re(@"^\s*(?:Compiling|Checking|Finished|Running|Fresh|Downloaded|Installing|Updating|Packaging|Uploading|Blocking)\b", RegexOptions.Multiline);
    private static readonly Regex RRustTestOk = Re(@"\.\.\.\s+ok\b");
    private static readonly Regex RRustTestFail = Re(@"\.\.\.\s+FAILED\b");
    private static readonly Regex RRustTestSum = Re(@"test result:\s+\w+\.");

    private static readonly Regex RErrEn = Re(@"\b(?:error|errors|fail(?:ed|ure|ures)?|fatal|critical|exception|denied|refused|panic|traceback|segfault|oom|killed|unable|cannot|can't|not found|no such|permission denied|connection refused|timed?\s*out|timeout|unauthorized|forbidden|invalid|corrupt(?:ed)?|broken|crash(?:ed)?)\b", RegexOptions.IgnoreCase);
    // 中文词：\b 对 CJK 无效，须用 Unicode 属性前后夹紧（只认独立词，防"正常范围/异常子串"误亮）。
    private static readonly string ZhW = @"\p{IsCJKUnifiedIdeographs}";
    private static readonly Regex RErrZh = Re($@"(?<!{ZhW})(?:错误|异常|崩溃|拒绝|超时|未找到|无权限|权限不足|连接拒绝|致命)(?!{ZhW})");
    private static readonly Regex RWarnEn = Re(@"\b(?:warn(?:ing|ings)?|deprecated|caution|notice|restart required|system restart required)\b", RegexOptions.IgnoreCase);
    private static readonly Regex RWarnZh = Re($@"(?<!{ZhW})(?:警告|注意|弃用|即将过期)(?!{ZhW})");
    private static readonly Regex ROkEn = Re(@"\b(?:ok|okay|success(?:ful(?:ly)?)?|done|ready|passed|complete(?:d)?|enabled|active|running|listening|connected|online|healthy|available)\b", RegexOptions.IgnoreCase);
    private static readonly Regex ROkZh = Re($@"(?<!{ZhW})(?:完成|就绪|已连接|正常|在线|健康)(?!{ZhW})");
    private static readonly Regex RPct9 = Re(@"\b(9\d(?:\.\d+)?%)");
    private static readonly Regex RPct8 = Re(@"\b(8\d(?:\.\d+)?%)");
    private static readonly Regex RPct17 = Re(@"\b([1-7]?\d(?:\.\d+)?%)");
    private static readonly Regex RKw = Re(@"\b(?:sudo|systemctl|journalctl|docker|kubectl|nginx|redis|mysql|postgres|ssh|scp|rsync|chmod|chown|mount|umount|iptables|firewalld|cron|systemd)\b");
    private static readonly Regex RDelim = Re(@"[()\[\]{}]");

    // ── 底层替换 ────────────────────────────────────────────────────────
    private static string ApplyRegex(string text, Regex re, Func<Match, string> transform)
    {
        var ms = re.Matches(text);
        if (ms.Count == 0) return text;
        var sb = new StringBuilder(text.Length + 64);
        int idx = 0;
        foreach (Match m in ms)
        {
            if (m.Index > idx) sb.Append(text, idx, m.Index - idx);
            sb.Append(transform(m));
            idx = m.Index + m.Length;
        }
        if (idx < text.Length) sb.Append(text, idx, text.Length - idx);
        return sb.ToString();
    }

    /// <summary>跳过已有占位符区间，只对"未占位"文本片段应用正则（防重复上色 / 防嵌套）。</summary>
    private static string ReplaceSafe(string str, Regex re, Func<Match, string> transform)
    {
        var markers = MarkerRe.Matches(str);
        if (markers.Count == 0) return ApplyRegex(str, re, transform);
        var sb = new StringBuilder(str.Length + 64);
        int idx = 0;
        foreach (Match mm in markers)
        {
            if (mm.Index > idx) sb.Append(ApplyRegex(str.Substring(idx, mm.Index - idx), re, transform));
            sb.Append(mm.Value);   // 占位符原样保留
            idx = mm.Index + mm.Length;
        }
        if (idx < str.Length) sb.Append(ApplyRegex(str.Substring(idx), re, transform));
        return sb.ToString();
    }

    // ── 纯文本段装饰（老仓库 decoratePlainChunk 的 21 条规则）────────────
    private static string DecoratePlainChunk(string chunk, bool dark)
    {
        var st = new State();
        Func<Match, string> K(string kind) => m => st.Put(m.Value, kind);

        var s = chunk;
        // 规则顺序 = 优先级（占位符机制先匹配者胜）。**更具体的必须排在更泛的前面**，
        // 否则会被泛规则抢走：实测踩过两次 —— "12:30:00" 被裸 IPv6 当成地址、
        // "--> src/main.rs:10:5" 里的 ":10" 被通用 :PORT 当成端口。改顺序前先想清楚这点。
        s = ReplaceSafe(s, RUrl, K("url"));                                   // 1) URL
        s = ReplaceSafe(s, RWarnStar, K("warn"));                             // 2) *** 警告块
        // 3) Rust 工具链输出：最具体，必须最先
        s = ReplaceSafe(s, RRustDiagCode, K("err"));
        s = ReplaceSafe(s, RRustPanic, K("err"));
        s = ReplaceSafe(s, RRustArrowLoc, K("path"));
        s = ReplaceSafe(s, RRustTestFail, K("err"));
        s = ReplaceSafe(s, RRustTestOk, K("ok"));
        s = ReplaceSafe(s, RRustTestSum, K("ok"));
        s = ReplaceSafe(s, RCargoAction, K("kw"));
        s = ReplaceSafe(s, RPerm, m =>                                        // 4) 权限位
        {
            var p1 = m.Groups[1].Success ? m.Groups[1].Value : null;
            if (p1 == null) return st.Put(m.Value, "perm");
            var i = m.Value.IndexOf(p1, StringComparison.Ordinal);
            return i <= 0 ? st.Put(m.Value, "perm") : m.Value.Substring(0, i) + st.Put(p1, "perm");
        });
        s = ReplaceSafe(s, RPath, m =>                                        // 5) 绝对/家目录路径
        {
            var p1 = m.Groups[1].Success ? m.Groups[1].Value : null;
            if (p1 == null) return st.Put(m.Value, "path");
            var i = m.Value.IndexOf(p1, StringComparison.Ordinal);
            return i < 0 ? st.Put(m.Value, "path") : m.Value.Substring(0, i) + st.Put(p1, "path");
        });
        // 6) 时间戳：必须排在 IP 之前 —— "12:30:00" 会被裸 IPv6 规则误判成地址
        s = ReplaceSafe(s, RDateA, K("date"));
        s = ReplaceSafe(s, RDateB, K("date"));
        s = ReplaceSafe(s, RDateC, K("date"));
        s = ReplaceSafe(s, RMac, K("mac"));                                   // 7) MAC
        s = ReplaceSafe(s, RIPv4, K("ip"));                                   // 8) IPv4[:port]
        s = ReplaceSafe(s, RIPv6Br, K("ip"));                                 // 9) [IPv6]:port
        s = ReplaceSafe(s, RIPv6, m =>                                        // 10) 裸 IPv6（≥2 冒号）
            m.Value.Length < 3 || m.Value.Count(ch => ch == ':') < 2 ? m.Value : st.Put(m.Value, "ip"));
        s = ReplaceSafe(s, RUserHost, K("userhost"));                         // 11) user@host
        s = ReplaceSafe(s, RDomain, K("domain"));                             // 12) 域名
        s = ReplaceSafe(s, RPortStar, K("port"));                             // 13) *:PORT
        s = ReplaceSafe(s, RPort, m =>                                        // 14) 独立 :PORT
            int.TryParse(m.Groups[1].Value, out var n) && n >= 1 && n <= 65535 ? st.Put(m.Value, "port") : m.Value);
        s = ReplaceSafe(s, RSize, K("size"));                                 // 15) 大小/速率
        s = ReplaceSafe(s, RUuid, K("hex"));                                  // 16) UUID 必须先于 hash
        s = ReplaceSafe(s, RHex0x, K("hex"));
        s = ReplaceSafe(s, RHash, m => m.Value.All(char.IsDigit) ? m.Value : st.Put(m.Value, "hex"));
        s = ReplaceSafe(s, RHttp, m =>                                        // 17) HTTP 状态码
        {
            if (!int.TryParse(m.Groups[1].Value, out var n)) return st.Put(m.Value, "num");
            if (n >= 500) return st.Put(m.Value, "err");
            if (n >= 400) return st.Put(m.Value, "warn");
            if (n >= 200 && n < 300) return st.Put(m.Value, "ok");
            return st.Put(m.Value, "num");
        });
        s = ReplaceSafe(s, RErrEn, K("err"));                                 // 18) 错误/警告
        s = ReplaceSafe(s, RErrZh, K("err"));
        s = ReplaceSafe(s, RWarnEn, K("warn"));
        s = ReplaceSafe(s, RWarnZh, K("warn"));
        s = ReplaceSafe(s, ROkEn, K("ok"));                                   // 19) 成功词
        s = ReplaceSafe(s, ROkZh, K("ok"));
        s = ReplaceSafe(s, RPct9, K("err"));                                  // 20) 占用百分比
        s = ReplaceSafe(s, RPct8, K("warn"));
        s = ReplaceSafe(s, RPct17, K("num"));
        s = ReplaceSafe(s, RMethod, K("kw"));                                 // 21) 借鉴 tailspin
        s = ReplaceSafe(s, RProcPid, K("kw"));
        s = ReplaceSafe(s, RDuration, K("num"));
        s = ReplaceSafe(s, RKey, K("kw"));
        s = ReplaceSafe(s, RKw, K("kw"));                                     // 22) 运维关键词
        s = ReplaceSafe(s, RQuoted, K("str"));                                // 23) 引号字符串（放最后）
        s = ReplaceSafe(s, RKw, K("kw"));
        s = ReplaceSafe(s, RQuoted, K("str"));
        s = ReplaceSafe(s, RDelim, K("delim"));

        var color = dark ? HlDark : HlLight;
        var custom = HighlightColors.HighlightHex;
        if (!string.IsNullOrEmpty(custom))
        {
            var want = Tc(custom!);
            color = color.ToDictionary(kv => kv.Key,
                kv => Regex.Replace(kv.Value, @"\x1b\[38;2;\d+;\d+;\d+m", "") + want);
        }
        const string reset = "\u001b[0m";
        int guard = 0;
        while (s.Contains(SO) && guard++ < 24)
        {
            s = ApplyRegex(s, MarkerRe, m =>
            {
                if (!int.TryParse(m.Groups[1].Value, out var n) || n >= st.Slots.Count) return "";
                var item = st.Slots[n];
                return (color.TryGetValue(item.Kind, out var c) ? c : "\u001b[1;31m") + item.S + reset;
            });
        }
        return ApplyRegex(s, MarkerRe, _ => "");
    }

    public static string Decorate(string chunk, bool dark, ref bool activeColor)
    {
        if (string.IsNullOrEmpty(chunk)) return chunk;
        var plain = HighlightColors.PlainHex;
        return string.IsNullOrEmpty(plain) ? DecorateBody(chunk, dark, ref activeColor) : Tc(plain!) + DecorateBody(chunk, dark, ref activeColor);
    }


    private static string DecorateBody(string chunk, bool dark, ref bool activeColor)
    {
        var ms = AnsiRe.Matches(chunk);
        if (ms.Count == 0)
        {
            if (activeColor) return chunk;
            return DecoratePlainChunk(chunk, dark);
        }
        var sb = new StringBuilder(chunk.Length + 64);
        int idx = 0;
        foreach (Match m in ms)
        {
            if (m.Index > idx)
            {
                var plain = chunk.Substring(idx, m.Index - idx);
                if (activeColor)
                {
                    sb.Append(plain);
                }
                else
                {
                    sb.Append(DecoratePlainChunk(plain, dark));
                }
            }

            var ansi = m.Value;
            if (ansi == "\u001b[0m" || ansi == "\u001b[39m" || ansi == "\u001b[49m" || ansi == "\u001b[0;39m")
            {
                activeColor = false;
            }
            else if (ansi.Contains("m"))
            {
                activeColor = true;
            }

            // 强制将 37m (前景色白) 转换为 TrueColor 的纯白，这样既能保证“红底白字”清晰可见，又不会破坏 47m (背景色白) 对应调色板的浅灰
            if (ansi == "\u001b[37m")
            {
                ansi = "\u001b[38;2;255;255;255m";
            }
            else if (ansi == "\u001b[0;37m")
            {
                ansi = "\u001b[0m\u001b[38;2;255;255;255m";
            }

            // 拦截 2K/0K/K (清除行)，必须前置 0m 以避免背景色溢出成“黑条/彩条”
            if (ansi == "\u001b[2K" || ansi == "\u001b[K" || ansi == "\u001b[0K")
            {
                ansi = "\u001b[0m" + ansi;
                activeColor = false;
            }
            sb.Append(ansi);
            idx = m.Index + m.Length;
        }
        if (idx < chunk.Length)
        {
            var plain = chunk.Substring(idx, chunk.Length - idx);
            if (activeColor)
            {
                sb.Append(plain);
            }
            else
            {
                sb.Append(DecoratePlainChunk(plain, dark));
            }
        }
        return sb.ToString();
    }

}
