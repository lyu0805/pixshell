using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace PixShell.UI;

// ============================================================================
// 编辑器语法支持：按扩展名探测语言 + 轻量正则语法高亮。
// 1:1 移植 mac UI/EditorSyntax.swift。**不变式**：Highlight() 只返回"哪些区间该
// 涂什么颜色"，从不触碰/改写传入的文本——调用方（EditorWindow）负责把返回的
// spans 应用成 Run 的 Foreground，文本内容本身逐字节不变。
// ============================================================================

/// <summary>编辑器支持的语言种类（由文件名/扩展名探测得到）。</summary>
public enum EditorLang
{
    Swift, Js, Ts, Json, Yaml, Python, Shell, C, Go, Rust, Html, Css, Markdown, Ini, Sql, Xml, Plain
}

public static class EditorSyntax
{
    /// <summary>语言徽标显示名（配合头部 Badge）。</summary>
    public static string DisplayName(EditorLang lang) => lang switch
    {
        EditorLang.Swift => "Swift",
        EditorLang.Js => "JavaScript",
        EditorLang.Ts => "TypeScript",
        EditorLang.Json => "JSON",
        EditorLang.Yaml => "YAML",
        EditorLang.Python => "Python",
        EditorLang.Shell => "Shell",
        EditorLang.C => "C/C++",
        EditorLang.Go => "Go",
        EditorLang.Rust => "Rust",
        EditorLang.Html => "HTML",
        EditorLang.Css => "CSS",
        EditorLang.Markdown => "Markdown",
        EditorLang.Ini => "INI/Conf",
        EditorLang.Sql => "SQL",
        EditorLang.Xml => "XML",
        _ => "Plain Text",
    };

    // MARK: - 语言探测

    /// <summary>按文件名探测语言：先看是否是无扩展名的特殊文件（Dockerfile/Makefile 等），
    /// 再按最后一段扩展名匹配。大小写不敏感。</summary>
    public static EditorLang Detect(string path)
    {
        var full = (path ?? "").Replace('\\', '/');
        var slash = full.LastIndexOf('/');
        var baseName = (slash >= 0 ? full[(slash + 1)..] : full).ToLowerInvariant();

        if (baseName == "dockerfile" || baseName.StartsWith("dockerfile.")) return EditorLang.Shell;
        if (baseName == "makefile" || baseName == "gnumakefile") return EditorLang.Shell;
        if (baseName is ".bashrc" or ".zshrc" or ".bash_profile" or ".profile") return EditorLang.Shell;

        var dot = baseName.LastIndexOf('.');
        if (dot <= 0) return EditorLang.Plain; // 没有扩展名，或者整个文件名就是".xxx"（隐藏文件）
        var ext = baseName[(dot + 1)..];
        return ext switch
        {
            "sh" or "bash" or "zsh" => EditorLang.Shell,
            "py" => EditorLang.Python,
            "js" or "mjs" or "cjs" => EditorLang.Js,
            "ts" or "tsx" => EditorLang.Ts,
            "json" => EditorLang.Json,
            "yml" or "yaml" => EditorLang.Yaml,
            "conf" or "ini" or "cfg" or "toml" => EditorLang.Ini,
            "c" or "h" or "cpp" or "hpp" => EditorLang.C,
            "go" => EditorLang.Go,
            "rs" => EditorLang.Rust,
            "swift" => EditorLang.Swift,
            "html" or "htm" => EditorLang.Html,
            "css" or "scss" => EditorLang.Css,
            "md" => EditorLang.Markdown,
            "sql" => EditorLang.Sql,
            "xml" => EditorLang.Xml,
            _ => EditorLang.Plain,
        };
    }

    // MARK: - 语法高亮

    /// <summary>超过该大小（约 180KB）跳过高亮，直接返回空 span 列表——大文件保护。</summary>
    private const int MaxHighlightBytes = 180_000;

    /// <summary>一段"该涂色"的区间：[Start, Start+Length) 内的字符统一涂 ColorHex。</summary>
    public readonly record struct HighlightSpan(int Start, int Length, string ColorHex);

    /// <summary>对源码做轻量正则语法高亮，返回涂色区间列表（不改文本）。
    /// 优先级：字符串 &gt; 注释 &gt; 数字 &gt; 关键字 &gt; 类型（大写标识符启发式），
    /// 已涂色区间不会被后来者覆盖（对齐 mac occupied 掩码）。</summary>
    public static List<HighlightSpan> Highlight(string text, EditorLang lang, bool dark)
    {
        var spans = new List<HighlightSpan>();
        if (lang == EditorLang.Plain || string.IsNullOrEmpty(text)) return spans;
        if (Encoding.UTF8.GetByteCount(text) > MaxHighlightBytes) return spans;

        var length = text.Length;
        var occupied = new bool[length];
        var palette = dark ? SyntaxColors.Dark : SyntaxColors.Light;

        void Paint(List<(int start, int len)> ranges, string color)
        {
            foreach (var (start, len) in ranges)
            {
                if (start < 0 || len <= 0 || start + len > length) continue;
                var free = true;
                for (var i = start; i < start + len; i++) if (occupied[i]) { free = false; break; }
                if (!free) continue;
                spans.Add(new HighlightSpan(start, len, color));
                for (var i = start; i < start + len; i++) occupied[i] = true;
            }
        }

        var spec = Spec(lang);
        if (spec.StringPattern != null) Paint(Find(text, spec.StringPattern), palette.String);
        if (spec.BlockComment != null) Paint(Find(text, spec.BlockComment), palette.Comment);
        if (spec.LineComment != null) Paint(Find(text, spec.LineComment), palette.Comment);
        if (spec.NumberPattern != null) Paint(Find(text, spec.NumberPattern), palette.Number);
        if (spec.Keywords.Count > 0)
        {
            var opts = spec.CaseInsensitiveKeywords ? RegexOptions.IgnoreCase : RegexOptions.None;
            Paint(Find(text, KeywordPattern(spec.Keywords), opts), palette.Keyword);
        }
        if (spec.TypeHeuristic) Paint(Find(text, TypeHeuristicPattern), palette.Type);

        // 各语言专属结构（标签名/小节标题/标题行等），复用同一套 occupied 掩码。
        switch (lang)
        {
            case EditorLang.Css:
                Paint(Find(text, @"@[a-zA-Z-]+"), palette.Keyword);
                Paint(Find(text, @"#[0-9a-fA-F]{3,8}\b"), palette.Number);
                break;
            case EditorLang.Html:
            case EditorLang.Xml:
                Paint(Find(text, @"</?[A-Za-z][\w:.-]*"), palette.Type);
                Paint(Find(text, @"(?<=\s)[a-zA-Z_:][\w:.-]*(?=\s*=)"), palette.Keyword);
                break;
            case EditorLang.Ini:
                Paint(Find(text, @"^\s*\[[^\]]+\]", RegexOptions.Multiline), palette.Type);
                break;
            case EditorLang.Rust:
                // Rust 特有的几样东西，通用正则覆盖不到，单独上色（对齐 mac）：
                Paint(Find(text, @"#!?\[[^\]]*\]"), palette.Comment);                      // 属性 #[derive(...)] / #![no_std]
                Paint(Find(text, @"'(?:[a-z_][a-zA-Z0-9_]*|static)\b(?!')"), palette.Type);  // 生命周期 'a / 'static（别吃掉字符字面量）
                Paint(Find(text, @"\b[a-zA-Z_][\w]*!(?=\s*[\(\[{])"), palette.Keyword);  // 宏调用 println!/vec!
                Paint(Find(text, "r#*\"[^\"]*\"#*"), palette.String);                       // 原始字符串 r"..." / r#"..."#
                Paint(Find(text, @"\b[A-Z][A-Za-z0-9_]*\b"), palette.Type);                 // 类型/trait 名（大驼峰）
                break;
            case EditorLang.Markdown:
                Paint(Find(text, @"^#{1,6}[ \t]+.*$", RegexOptions.Multiline), palette.Keyword);
                Paint(Find(text, @"\*\*[^*\n]+\*\*|__[^_\n]+__"), palette.Keyword);
                Paint(Find(text, @"\[[^\]]*\]\([^)]*\)"), palette.Type);
                break;
        }

        return spans;
    }

    /// <summary>Foreground 未被任何 span 覆盖的默认文本色（palette.text）。</summary>
    public static string DefaultTextColor(bool dark) => (dark ? SyntaxColors.Dark : SyntaxColors.Light).Text;

    private static List<(int, int)> Find(string text, string pattern, RegexOptions options = RegexOptions.None)
    {
        var result = new List<(int, int)>();
        Regex re;
        try { re = new Regex(pattern, options); }
        catch { return result; }
        foreach (Match m in re.Matches(text))
            if (m.Length > 0) result.Add((m.Index, m.Length));
        return result;
    }

    // MARK: - 正则片段（原子构件，各语言按需拼装；内容逐字符对齐 mac 版的 raw 正则）

    private const string StrDouble = @"""(?:\\.|[^""\\\n])*""";
    private const string StrSingle = @"'(?:\\.|[^'\\\n])*'";
    private const string StrBacktick = @"`(?:\\.|[^`\\])*`";
    private const string NumDefault = @"\b0[xX][0-9a-fA-F]+\b|\b\d+\.?\d*(?:[eE][+-]?\d+)?\b";
    private const string CmtBlockC = @"/\*[\s\S]*?\*/";
    private const string CmtLineSlash = @"//[^\n]*";
    private const string CmtLineHash = @"#[^\n]*";
    private const string CmtLineHashSemi = @"[#;][^\n]*";
    private const string CmtLineDash = @"--[^\n]*";
    private const string CmtHtml = @"<!--[\s\S]*?-->";
    private const string TypeHeuristicPattern = @"\b[A-Z][A-Za-z0-9_]*\b";

    private static string KeywordPattern(IReadOnlyList<string> words) => @"\b(?:" + string.Join("|", words) + @")\b";

    // MARK: - 各语言的 token 规格

    private sealed class LangSpec
    {
        public string? BlockComment;
        public string? LineComment;
        public string? StringPattern;
        public string? NumberPattern;
        public IReadOnlyList<string> Keywords = System.Array.Empty<string>();
        public bool CaseInsensitiveKeywords;
        public bool TypeHeuristic;
    }

    private static LangSpec Spec(EditorLang lang)
    {
        const string dqsq = StrDouble + "|" + StrSingle;
        const string dqsqbq = dqsq + "|" + StrBacktick;
        return lang switch
        {
            EditorLang.Swift => new LangSpec { BlockComment = CmtBlockC, LineComment = CmtLineSlash, StringPattern = dqsq, NumberPattern = NumDefault, Keywords = SwiftKeywords, TypeHeuristic = true },
            EditorLang.Js => new LangSpec { BlockComment = CmtBlockC, LineComment = CmtLineSlash, StringPattern = dqsqbq, NumberPattern = NumDefault, Keywords = JsKeywords, TypeHeuristic = true },
            EditorLang.Ts => new LangSpec { BlockComment = CmtBlockC, LineComment = CmtLineSlash, StringPattern = dqsqbq, NumberPattern = NumDefault, Keywords = TsKeywords, TypeHeuristic = true },
            EditorLang.Json => new LangSpec { StringPattern = dqsq, NumberPattern = NumDefault, Keywords = new[] { "true", "false", "null" } },
            EditorLang.Yaml => new LangSpec { LineComment = CmtLineHash, StringPattern = dqsq, NumberPattern = NumDefault, Keywords = YamlKeywords, CaseInsensitiveKeywords = true },
            EditorLang.Python => new LangSpec { LineComment = CmtLineHash, StringPattern = dqsq, NumberPattern = NumDefault, Keywords = PythonKeywords, TypeHeuristic = true },
            EditorLang.Shell => new LangSpec { LineComment = CmtLineHash, StringPattern = dqsqbq, NumberPattern = NumDefault, Keywords = ShellKeywords },
            EditorLang.C => new LangSpec { BlockComment = CmtBlockC, LineComment = CmtLineSlash, StringPattern = dqsq, NumberPattern = NumDefault, Keywords = CKeywords, TypeHeuristic = true },
            EditorLang.Go => new LangSpec { BlockComment = CmtBlockC, LineComment = CmtLineSlash, StringPattern = dqsqbq, NumberPattern = NumDefault, Keywords = GoKeywords, TypeHeuristic = true },
            EditorLang.Rust => new LangSpec { BlockComment = CmtBlockC, LineComment = CmtLineSlash, StringPattern = dqsq, NumberPattern = NumDefault, Keywords = RustKeywords, TypeHeuristic = true },
            EditorLang.Html => new LangSpec { BlockComment = CmtHtml, StringPattern = dqsq },
            EditorLang.Xml => new LangSpec { BlockComment = CmtHtml, StringPattern = dqsq },
            EditorLang.Css => new LangSpec { BlockComment = CmtBlockC, StringPattern = dqsq, NumberPattern = NumDefault, Keywords = CssKeywords },
            EditorLang.Markdown => new LangSpec { StringPattern = @"`[^`\n]+`" },
            EditorLang.Ini => new LangSpec { LineComment = CmtLineHashSemi, StringPattern = dqsq, NumberPattern = NumDefault, Keywords = IniKeywords, CaseInsensitiveKeywords = true },
            EditorLang.Sql => new LangSpec { BlockComment = CmtBlockC, LineComment = CmtLineDash, StringPattern = StrSingle, NumberPattern = NumDefault, Keywords = SqlKeywords, CaseInsensitiveKeywords = true },
            _ => new LangSpec(),
        };
    }

    // MARK: - 关键字表（按语言，尽量覆盖常见控制流/声明关键字，逐条对齐 mac 版）

    private static readonly string[] SwiftKeywords = {
        "func", "var", "let", "class", "struct", "enum", "protocol", "if", "else", "for", "while",
        "return", "import", "true", "false", "nil", "self", "Self", "guard", "defer", "async", "await",
        "throws", "try", "catch", "switch", "case", "default", "in", "is", "as", "where", "public",
        "private", "internal", "fileprivate", "open", "static", "final", "override", "init", "deinit",
        "extension", "typealias", "associatedtype", "inout", "mutating", "nonmutating", "lazy", "weak",
        "unowned", "rethrows", "repeat", "continue", "break", "fallthrough",
    };
    private static readonly string[] JsKeywords = {
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "class", "async",
        "await", "import", "export", "from", "new", "this", "typeof", "instanceof", "try", "catch",
        "finally", "throw", "switch", "case", "break", "continue", "default", "null", "undefined",
        "true", "false", "of", "in", "yield", "static", "extends", "super", "delete", "void", "debugger",
    };
    private static readonly string[] TsKeywords = CombineTs();
    private static string[] CombineTs()
    {
        var extra = new[] { "type", "interface", "enum", "implements", "public", "private", "protected", "readonly", "as", "namespace", "declare", "abstract", "keyof", "infer" };
        var all = new List<string>(JsKeywords);
        all.AddRange(extra);
        return all.ToArray();
    }
    private static readonly string[] PythonKeywords = {
        "def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "with",
        "try", "except", "finally", "raise", "None", "True", "False", "lambda", "yield", "async",
        "await", "pass", "break", "continue", "global", "nonlocal", "assert", "in", "is", "not", "and",
        "or", "del", "match", "case",
    };
    private static readonly string[] ShellKeywords = {
        "if", "then", "else", "elif", "fi", "for", "do", "done", "case", "esac", "function", "export",
        "local", "return", "while", "until", "select", "in", "time", "echo", "cd", "source", "alias",
        "set", "unset", "read", "printf", "test", "true", "false",
    };
    private static readonly string[] CKeywords = {
        "int", "char", "void", "return", "if", "else", "for", "while", "struct", "typedef", "const",
        "static", "unsigned", "long", "short", "float", "double", "sizeof", "enum", "extern", "volatile",
        "register", "union", "goto", "switch", "case", "break", "continue", "default", "NULL", "class",
        "template", "namespace", "public", "private", "protected", "new", "delete", "true", "false",
        "nullptr", "using", "virtual", "override", "constexpr", "auto", "throw", "try", "catch", "bool",
    };
    private static readonly string[] GoKeywords = {
        "func", "return", "if", "else", "for", "package", "import", "var", "const", "type", "struct",
        "interface", "map", "chan", "go", "defer", "range", "nil", "true", "false", "select", "case",
        "default", "switch", "fallthrough", "break", "continue",
    };
    private static readonly string[] RustKeywords = {
        "fn", "let", "mut", "return", "if", "else", "for", "while", "loop", "match", "struct", "enum",
        "impl", "trait", "use", "pub", "mod", "const", "static", "true", "false", "self", "Self",
        "where", "async", "await", "move", "ref", "crate", "super", "unsafe", "dyn",
        // 之前漏掉的：控制流 / 类型 / 常见前奏词（与 mac UI/EditorSyntax.swift 保持一致）
        "in", "as", "break", "continue", "type", "extern", "box", "yield", "union", "macro_rules",
        "Ok", "Err", "Some", "None", "Result", "Option", "Vec", "String", "Box", "Rc", "Arc",
        "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize",
        "f32", "f64", "bool", "char", "str",
    };
    private static readonly string[] CssKeywords = {
        "color", "background", "border", "margin", "padding", "display", "flex", "grid", "position",
        "width", "height", "font", "justify-content", "align-items", "overflow", "z-index", "opacity",
        "transform", "transition",
    };
    private static readonly string[] IniKeywords = { "true", "false", "yes", "no", "on", "off" };
    private static readonly string[] YamlKeywords = { "true", "false", "null", "yes", "no", "on", "off" };
    private static readonly string[] SqlKeywords = {
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN", "LEFT", "RIGHT", "INNER",
        "OUTER", "AND", "OR", "NOT", "NULL", "CREATE", "TABLE", "INDEX", "DROP", "ALTER", "VALUES",
        "INTO", "SET", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "AS", "ON", "IN", "IS", "LIKE",
        "BETWEEN", "DISTINCT", "UNION", "ALL", "EXISTS", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
        "VIEW", "TRIGGER", "PROCEDURE", "FUNCTION",
    };
}

// MARK: - 语法配色（明/暗两套，贴近常见代码编辑器的配色习惯，颜色值逐条对齐 mac 版）

internal sealed class SyntaxPalette
{
    public required string Text;
    public required string Comment;
    public required string String;
    public required string Number;
    public required string Keyword;
    public required string Type;
}

internal static class SyntaxColors
{
    public static readonly SyntaxPalette Light = new()
    {
        Text = "#1c1c1e", Comment = "#6b7280", String = "#c4380d",
        Number = "#1c00cf", Keyword = "#9b2393", Type = "#3900a0",
    };
    public static readonly SyntaxPalette Dark = new()
    {
        Text = "#f7f7fa", Comment = "#7f8c98", String = "#fc6a5d",
        Number = "#d0bf69", Keyword = "#fc5fa3", Type = "#5dd8ff",
    };
}
