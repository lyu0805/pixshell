import AppKit

// ============================================================================
// 编辑器语法支持：按扩展名探测语言 + 轻量正则语法高亮。
// 对齐老仓库 packages/editor/src/index.js 的 guessLang / highlightPlain，
// 但实现方式不同：老版本拼 HTML 字符串染色，这里直接在 NSAttributedString 上
// 加 .foregroundColor 属性，天然保证「返回值 .string 与输入逐字节一致」——
// 全程只调用 addAttribute/removeAttribute，从不触碰字符内容。
// ============================================================================

/// 编辑器支持的语言种类（由文件名/扩展名探测得到）。
enum EditorLang: String {
    case swift, js, ts, json, yaml, python, shell, c, go, rust, html, css, markdown, ini, sql, xml, plain

    /// 语言徽标显示名（配合头部 Badge）。
    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .js: return "JavaScript"
        case .ts: return "TypeScript"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .python: return "Python"
        case .shell: return "Shell"
        case .c: return "C/C++"
        case .go: return "Go"
        case .rust: return "Rust"
        case .html: return "HTML"
        case .css: return "CSS"
        case .markdown: return "Markdown"
        case .ini: return "INI/Conf"
        case .sql: return "SQL"
        case .xml: return "XML"
        case .plain: return "Plain Text"
        }
    }
}

enum EditorSyntax {

    // MARK: - 语言探测

    /// 按文件名探测语言：先看是否是无扩展名的特殊文件（Dockerfile/Makefile 等），
    /// 再按最后一段扩展名匹配。大小写不敏感。
    static func detect(path: String) -> EditorLang {
        let base = (path as NSString).lastPathComponent.lowercased()
        if base == "dockerfile" || base.hasPrefix("dockerfile.") { return .shell }
        if base == "makefile" || base == "gnumakefile" { return .shell }
        if base == ".bashrc" || base == ".zshrc" || base == ".bash_profile" || base == ".profile" { return .shell }

        guard let dotIdx = base.lastIndex(of: "."), dotIdx != base.startIndex else { return .plain }
        let ext = String(base[base.index(after: dotIdx)...])
        switch ext {
        case "sh", "bash", "zsh": return .shell
        case "py": return .python
        case "js", "mjs", "cjs": return .js
        case "ts", "tsx": return .ts
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "conf", "ini", "cfg", "toml": return .ini
        case "c", "h", "cpp", "hpp": return .c
        case "go": return .go
        case "rs": return .rust
        case "swift": return .swift
        case "html", "htm": return .html
        case "css", "scss": return .css
        case "md": return .markdown
        case "sql": return .sql
        case "xml": return .xml
        default: return .plain
        }
    }

    // MARK: - 语法高亮

    /// 超过该大小（约 180KB）跳过高亮，直接返回纯文本属性串——大文件保护。
    private static let maxHighlightBytes = 180_000

    /// 对源码做轻量正则语法高亮。**不变式**：返回值的 `.string` 与 `text` 逐字节相同——
    /// 本函数从头到尾只用 addAttribute/removeAttribute 给已构造好的属性串上色，
    /// 从不调用任何会改变字符内容的方法。
    static func highlight(_ text: String, lang: EditorLang, dark: Bool) -> NSAttributedString {
        let palette = dark ? SyntaxColors.dark : SyntaxColors.light
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: Theme.mono(12), .foregroundColor: palette.text]
        )
        guard lang != .plain, !text.isEmpty, text.utf8.count <= maxHighlightBytes else { return result }

        let length = (text as NSString).length
        guard length > 0 else { return result }
        // 已染色区间掩码：字符串/注释优先「占坑」，后面的数字/关键字/类型不会覆盖它们。
        var occupied = [Bool](repeating: false, count: length)

        func find(_ pattern: String, _ options: NSRegularExpression.Options = []) -> [NSRange] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
            return re.matches(in: text, options: [], range: NSRange(location: 0, length: length)).map { $0.range }
        }
        func paint(_ ranges: [NSRange], _ color: NSColor) {
            for r in ranges {
                guard r.location != NSNotFound, r.length > 0,
                      r.location >= 0, r.location + r.length <= length else { continue }
                var free = true
                for i in r.location..<(r.location + r.length) where occupied[i] { free = false; break }
                guard free else { continue }
                result.addAttribute(.foregroundColor, value: color, range: r)
                for i in r.location..<(r.location + r.length) { occupied[i] = true }
            }
        }

        let s = spec(for: lang)
        // 优先级：字符串 > 注释 > 数字 > 关键字 > 类型（大写标识符启发式）。
        // 字符串必须最先占坑，否则字符串里的 // # -- 会被误判成注释起点。
        if let sp = s.stringPattern { paint(find(sp), palette.string) }
        if let bc = s.blockComment { paint(find(bc), palette.comment) }
        if let lc = s.lineComment { paint(find(lc), palette.comment) }
        if let np = s.numberPattern { paint(find(np), palette.number) }
        if !s.keywords.isEmpty {
            let opts: NSRegularExpression.Options = s.caseInsensitiveKeywords ? [.caseInsensitive] : []
            paint(find(keywordPattern(s.keywords), opts), palette.keyword)
        }
        if s.typeHeuristic { paint(find(typeHeuristicPattern), palette.type) }

        // 各语言专属结构（标签名/小节标题/标题行等），复用同一套 occupied 掩码。
        switch lang {
        case .css:
            paint(find(#"@[a-zA-Z-]+"#), palette.keyword)
            paint(find(#"#[0-9a-fA-F]{3,8}\b"#), palette.number)
        case .html, .xml:
            paint(find(#"</?[A-Za-z][\w:.-]*"#), palette.type)
            paint(find(#"(?<=\s)[a-zA-Z_:][\w:.-]*(?=\s*=)"#), palette.keyword)
        case .ini:
            paint(find(#"^\s*\[[^\]]+\]"#, [.anchorsMatchLines]), palette.type)
        case .rust:
            // Rust 特有的几样东西，通用正则覆盖不到，单独上色：
            paint(find(#"#!?\[[^\]]*\]"#), palette.comment)            // 属性 #[derive(...)] / #![no_std]
            paint(find(#"'(?:[a-z_][a-zA-Z0-9_]*|static)\b(?!')"#), palette.type)  // 生命周期 'a / 'static（别吃掉字符字面量）
            paint(find(#"\b[a-zA-Z_][\w]*!(?=\s*[\(\[{])"#), palette.keyword)  // 宏调用 println!/vec!
            paint(find(##"r#*"[^"]*"#*"##), palette.string)              // 原始字符串 r"..." / r#"..."#（外层用 ## 定界，否则和内容里的 "# 撞车）
            paint(find(#"\b[A-Z][A-Za-z0-9_]*\b"#), palette.type)      // 类型/trait 名（大驼峰）
        case .markdown:
            paint(find(#"^#{1,6}[ \t]+.*$"#, [.anchorsMatchLines]), palette.keyword)
            paint(find(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#), palette.keyword)
            paint(find(#"\[[^\]]*\]\([^)]*\)"#), palette.type)
        default:
            break
        }

        return result
    }

    // MARK: - 正则片段（原子构件，各语言按需拼装）

    private static let strDouble = #""(?:\\.|[^"\\\n])*""#
    private static let strSingle = #"'(?:\\.|[^'\\\n])*'"#
    private static let strBacktick = #"`(?:\\.|[^`\\])*`"#
    private static let numDefault = #"\b0[xX][0-9a-fA-F]+\b|\b\d+\.?\d*(?:[eE][+-]?\d+)?\b"#
    private static let cmtBlockC = #"/\*[\s\S]*?\*/"#
    private static let cmtLineSlash = #"//[^\n]*"#
    private static let cmtLineHash = #"#[^\n]*"#
    private static let cmtLineHashSemi = #"[#;][^\n]*"#
    private static let cmtLineDash = #"--[^\n]*"#
    private static let cmtHTML = #"<!--[\s\S]*?-->"#
    private static let typeHeuristicPattern = #"\b[A-Z][A-Za-z0-9_]*\b"#

    private static func keywordPattern(_ words: [String]) -> String {
        "\\b(?:" + words.joined(separator: "|") + ")\\b"
    }

    // MARK: - 各语言的 token 规格

    private struct LangSpec {
        var blockComment: String? = nil
        var lineComment: String? = nil
        var stringPattern: String? = nil
        var numberPattern: String? = nil
        var keywords: [String] = []
        var caseInsensitiveKeywords: Bool = false
        var typeHeuristic: Bool = false
    }

    private static func spec(for lang: EditorLang) -> LangSpec {
        let dqsq = strDouble + "|" + strSingle
        let dqsqbq = dqsq + "|" + strBacktick
        switch lang {
        case .swift:
            return LangSpec(blockComment: cmtBlockC, lineComment: cmtLineSlash, stringPattern: dqsq,
                             numberPattern: numDefault, keywords: swiftKeywords, typeHeuristic: true)
        case .js:
            return LangSpec(blockComment: cmtBlockC, lineComment: cmtLineSlash, stringPattern: dqsqbq,
                             numberPattern: numDefault, keywords: jsKeywords, typeHeuristic: true)
        case .ts:
            return LangSpec(blockComment: cmtBlockC, lineComment: cmtLineSlash, stringPattern: dqsqbq,
                             numberPattern: numDefault, keywords: tsKeywords, typeHeuristic: true)
        case .json:
            return LangSpec(stringPattern: dqsq, numberPattern: numDefault, keywords: ["true", "false", "null"])
        case .yaml:
            return LangSpec(lineComment: cmtLineHash, stringPattern: dqsq, numberPattern: numDefault,
                             keywords: yamlKeywords, caseInsensitiveKeywords: true)
        case .python:
            return LangSpec(lineComment: cmtLineHash, stringPattern: dqsq, numberPattern: numDefault,
                             keywords: pythonKeywords, typeHeuristic: true)
        case .shell:
            return LangSpec(lineComment: cmtLineHash, stringPattern: dqsqbq, numberPattern: numDefault,
                             keywords: shellKeywords)
        case .c:
            return LangSpec(blockComment: cmtBlockC, lineComment: cmtLineSlash, stringPattern: dqsq,
                             numberPattern: numDefault, keywords: cKeywords, typeHeuristic: true)
        case .go:
            return LangSpec(blockComment: cmtBlockC, lineComment: cmtLineSlash, stringPattern: dqsqbq,
                             numberPattern: numDefault, keywords: goKeywords, typeHeuristic: true)
        case .rust:
            return LangSpec(blockComment: cmtBlockC, lineComment: cmtLineSlash, stringPattern: dqsq,
                             numberPattern: numDefault, keywords: rustKeywords, typeHeuristic: true)
        case .html:
            return LangSpec(blockComment: cmtHTML, stringPattern: dqsq, keywords: [])
        case .xml:
            return LangSpec(blockComment: cmtHTML, stringPattern: dqsq, keywords: [])
        case .css:
            return LangSpec(blockComment: cmtBlockC, stringPattern: dqsq, numberPattern: numDefault, keywords: cssKeywords)
        case .markdown:
            return LangSpec(stringPattern: #"`[^`\n]+`"#, keywords: [])
        case .ini:
            return LangSpec(lineComment: cmtLineHashSemi, stringPattern: dqsq, numberPattern: numDefault,
                             keywords: iniKeywords, caseInsensitiveKeywords: true)
        case .sql:
            return LangSpec(blockComment: cmtBlockC, lineComment: cmtLineDash, stringPattern: strSingle,
                             numberPattern: numDefault, keywords: sqlKeywords, caseInsensitiveKeywords: true)
        case .plain:
            return LangSpec()
        }
    }

    // MARK: - 关键字表（按语言，尽量覆盖常见控制流/声明关键字）

    private static let swiftKeywords = [
        "func", "var", "let", "class", "struct", "enum", "protocol", "if", "else", "for", "while",
        "return", "import", "true", "false", "nil", "self", "Self", "guard", "defer", "async", "await",
        "throws", "try", "catch", "switch", "case", "default", "in", "is", "as", "where", "public",
        "private", "internal", "fileprivate", "open", "static", "final", "override", "init", "deinit",
        "extension", "typealias", "associatedtype", "inout", "mutating", "nonmutating", "lazy", "weak",
        "unowned", "rethrows", "repeat", "continue", "break", "fallthrough",
    ]
    private static let jsKeywords = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "class", "async",
        "await", "import", "export", "from", "new", "this", "typeof", "instanceof", "try", "catch",
        "finally", "throw", "switch", "case", "break", "continue", "default", "null", "undefined",
        "true", "false", "of", "in", "yield", "static", "extends", "super", "delete", "void", "debugger",
    ]
    private static let tsKeywords = jsKeywords + [
        "type", "interface", "enum", "implements", "public", "private", "protected", "readonly", "as",
        "namespace", "declare", "abstract", "keyof", "infer",
    ]
    private static let pythonKeywords = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "with",
        "try", "except", "finally", "raise", "None", "True", "False", "lambda", "yield", "async",
        "await", "pass", "break", "continue", "global", "nonlocal", "assert", "in", "is", "not", "and",
        "or", "del", "match", "case",
    ]
    private static let shellKeywords = [
        "if", "then", "else", "elif", "fi", "for", "do", "done", "case", "esac", "function", "export",
        "local", "return", "while", "until", "select", "in", "time", "echo", "cd", "source", "alias",
        "set", "unset", "read", "printf", "test", "true", "false",
    ]
    private static let cKeywords = [
        "int", "char", "void", "return", "if", "else", "for", "while", "struct", "typedef", "const",
        "static", "unsigned", "long", "short", "float", "double", "sizeof", "enum", "extern", "volatile",
        "register", "union", "goto", "switch", "case", "break", "continue", "default", "NULL", "class",
        "template", "namespace", "public", "private", "protected", "new", "delete", "true", "false",
        "nullptr", "using", "virtual", "override", "constexpr", "auto", "throw", "try", "catch", "bool",
    ]
    private static let goKeywords = [
        "func", "return", "if", "else", "for", "package", "import", "var", "const", "type", "struct",
        "interface", "map", "chan", "go", "defer", "range", "nil", "true", "false", "select", "case",
        "default", "switch", "fallthrough", "break", "continue",
    ]
    private static let rustKeywords = [
        "fn", "let", "mut", "return", "if", "else", "for", "while", "loop", "match", "struct", "enum",
        "impl", "trait", "use", "pub", "mod", "const", "static", "true", "false", "self", "Self",
        "where", "async", "await", "move", "ref", "crate", "super", "unsafe", "dyn",
        // 之前漏掉的：控制流 / 类型 / 常见前奏词
        "in", "as", "break", "continue", "type", "extern", "box", "yield", "union", "macro_rules",
        "Ok", "Err", "Some", "None", "Result", "Option", "Vec", "String", "Box", "Rc", "Arc",
        "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize",
        "f32", "f64", "bool", "char", "str",
    ]
    private static let cssKeywords = [
        "color", "background", "border", "margin", "padding", "display", "flex", "grid", "position",
        "width", "height", "font", "justify-content", "align-items", "overflow", "z-index", "opacity",
        "transform", "transition",
    ]
    private static let iniKeywords = ["true", "false", "yes", "no", "on", "off"]
    private static let yamlKeywords = ["true", "false", "null", "yes", "no", "on", "off"]
    private static let sqlKeywords = [
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN", "LEFT", "RIGHT", "INNER",
        "OUTER", "AND", "OR", "NOT", "NULL", "CREATE", "TABLE", "INDEX", "DROP", "ALTER", "VALUES",
        "INTO", "SET", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "AS", "ON", "IN", "IS", "LIKE",
        "BETWEEN", "DISTINCT", "UNION", "ALL", "EXISTS", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
        "VIEW", "TRIGGER", "PROCEDURE", "FUNCTION",
    ]
}

// MARK: - 语法配色（明/暗两套，贴近常见代码编辑器的配色习惯）

private struct SyntaxPalette {
    let text: NSColor
    let comment: NSColor
    let string: NSColor
    let number: NSColor
    let keyword: NSColor
    let type: NSColor
}

private enum SyntaxColors {
    static let light = SyntaxPalette(
        text: Theme.c("#1c1c1e"),
        comment: Theme.c("#6b7280"),
        string: Theme.c("#c4380d"),
        number: Theme.c("#1c00cf"),
        keyword: Theme.c("#9b2393"),
        type: Theme.c("#3900a0")
    )
    static let dark = SyntaxPalette(
        text: Theme.c("#f7f7fa"),
        comment: Theme.c("#7f8c98"),
        string: Theme.c("#fc6a5d"),
        number: Theme.c("#d0bf69"),
        keyword: Theme.c("#fc5fa3"),
        type: Theme.c("#5dd8ff")
    )
}
