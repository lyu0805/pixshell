/**
 * Built-in text editor helpers for PixShell.
 * Pure JS: language guess, lightweight syntax highlight, find/replace, gutter.
 * UX goals aligned with lightweight desktop editors (line numbers, find/replace,
 * font, wrap) — original regex/token HTML implementation (not a third-party port).
 */

const EXT_LANG = {
  js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript',
  ts: 'typescript', tsx: 'typescript',
  html: 'html', htm: 'html', xhtml: 'html',
  css: 'css', scss: 'css', less: 'less',
  json: 'json', jsonc: 'json', json5: 'json',
  xml: 'xml', xsl: 'xml', xsd: 'xml', svg: 'xml',
  md: 'markdown', markdown: 'markdown',
  py: 'python', pyw: 'python',
  sh: 'unixshell', bash: 'unixshell', zsh: 'unixshell', fish: 'unixshell',
  bat: 'windowsbatch', cmd: 'windowsbatch', ps1: 'powershell',
  conf: 'ini', cfg: 'ini', ini: 'ini', toml: 'ini', properties: 'properties',
  yml: 'yaml', yaml: 'yaml',
  java: 'java', kt: 'kotlin', kts: 'kotlin',
  go: 'go', rs: 'rust',
  c: 'c', h: 'c', cpp: 'cplusplus', cc: 'cplusplus', cxx: 'cplusplus', hpp: 'cplusplus',
  cs: 'csharp',
  php: 'php', rb: 'ruby', pl: 'perl', pm: 'perl',
  lua: 'lua', sql: 'sql', r: 'r',
  scala: 'scala', groovy: 'groovy', gradle: 'groovy',
  swift: 'swift', m: 'objectivec',
  dart: 'dart',
  csv: 'csv', tsv: 'csv',
  dockerfile: 'docker',
  makefile: 'makefile', mk: 'makefile',
  tex: 'latex', lt: 'latex',
  hosts: 'hosts', htaccess: 'htaccess',
  log: 'log', txt: 'plaintext', text: 'plaintext',
  vue: 'html', svelte: 'html', nginx: 'ini', service: 'ini',
}

const LANG_LABELS = {
  plaintext: 'Plain Text',
  javascript: 'JavaScript',
  typescript: 'TypeScript',
  python: 'Python',
  java: 'Java',
  c: 'C',
  cplusplus: 'C++',
  csharp: 'C#',
  go: 'Go',
  rust: 'Rust',
  php: 'PHP',
  ruby: 'Ruby',
  perl: 'Perl',
  unixshell: 'Unix Shell',
  shell: 'Unix Shell',
  windowsbatch: 'Windows Batch',
  powershell: 'PowerShell',
  html: 'HTML',
  markup: 'HTML',
  css: 'CSS',
  less: 'Less',
  json: 'JSON',
  xml: 'XML',
  yaml: 'YAML',
  markdown: 'Markdown',
  sql: 'SQL',
  lua: 'Lua',
  kotlin: 'Kotlin',
  scala: 'Scala',
  groovy: 'Groovy',
  docker: 'Docker',
  makefile: 'Makefile',
  ini: 'INI/Conf',
  properties: 'Properties',
  latex: 'LaTeX',
  hosts: 'Hosts',
  htaccess: 'htaccess',
  csv: 'CSV',
  log: 'Log',
  dart: 'Dart',
  r: 'R',
  swift: 'Swift',
  objectivec: 'Objective-C',
  clojure: 'Clojure',
  lisp: 'Lisp',
  fortran: 'Fortran',
  actionscript: 'ActionScript',
  assemblerx86: 'Assembler x86',
}

function createEditorDoc(meta = {}) {
  const path = meta.path || ''
  return {
    id: meta.id || 'doc_' + Date.now().toString(36),
    path,
    remote: !!meta.remote,
    language: meta.language || guessLang(path),
    content: meta.content || '',
    dirty: false,
    encoding: meta.encoding || 'utf-8',
    cursor: { line: 1, col: 1 },
  }
}

function guessLang(filePath) {
  const p = String(filePath || '').toLowerCase()
  const base = p.split(/[\\/]/).pop() || ''
  if (base === 'dockerfile' || base.startsWith('dockerfile.')) return 'docker'
  if (base === 'makefile' || base === 'gnumakefile') return 'makefile'
  if (base === 'hosts') return 'hosts'
  if (base === '.htaccess' || base === 'htaccess') return 'htaccess'
  if (base === '.bashrc' || base === '.zshrc' || base === '.profile' || base === '.bash_profile' || base === '.bash_aliases') return 'unixshell'
  if (base.endsWith('.service') || base.endsWith('.timer') || base === 'nginx.conf') return 'ini'
  const m = base.match(/\.([a-z0-9]+)$/)
  if (!m) return 'plaintext'
  return EXT_LANG[m[1]] || 'plaintext'
}

function listLanguages() {
  return Object.keys(LANG_LABELS).map((id) => ({ id, name: LANG_LABELS[id] }))
}

function langLabel(id) {
  return LANG_LABELS[id] || id || 'Plain Text'
}

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

function protectSpans(html) {
  const slots = []
  // Private Use Area placeholders — won't collide with escaped source or NUL bytes in logs
  const L = ''
  const R = ''
  const out = String(html).replace(/<span\b[^>]*>[\s\S]*?<\/span>/g, (m) => {
    const i = slots.length
    slots.push(m)
    return L + 'SP' + i + R
  })
  return {
    text: out,
    restore(s) {
      return String(s).replace(/SP(\d+)/g, (_, n) => slots[Number(n)] || '')
    },
  }
}


function highlightPlain(text, language) {
  let lang = language === 'shell' ? 'unixshell' : language
  if (!lang || lang === 'plaintext' || lang === 'csv') return escapeHtml(text)

  let h = escapeHtml(text)

  function pass(fn) {
    const p = protectSpans(h)
    h = fn(p.text)
    h = p.restore(h)
  }

  // --- log levels ---
  if (lang === 'log') {
    pass((t) =>
      t.replace(
        /\b(FATAL|CRITICAL|ERROR|ERR|FAIL|FAILED|FAILURE)\b/gi,
        '<span class="tok-err">$1</span>',
      ),
    )
    pass((t) => t.replace(/\b(WARN|WARNING|CAUTION)\b/gi, '<span class="tok-warn">$1</span>'))
    pass((t) => t.replace(/\b(INFO|NOTICE|DEBUG|TRACE)\b/gi, '<span class="tok-info">$1</span>'))
    pass((t) =>
      t.replace(
        /\b(\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\b/g,
        '<span class="tok-num">$1</span>',
      ),
    )
    pass((t) => t.replace(/\b((?:\d{1,3}\.){3}\d{1,3})\b/g, '<span class="tok-num">$1</span>'))
    return h
  }

  // 1) STRINGS FIRST — so // or # inside quotes never become comments
  pass((t) =>
    t.replace(
      /(&quot;(?:[^&]|&(?!quot;))*&quot;|&apos;(?:[^&]|&(?!apos;))*&apos;|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)/g,
      '<span class="tok-str">$1</span>',
    ),
  )
  // simpler fallback if complex failed to match common cases — also plain quotes
  pass((t) =>
    t.replace(/("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)/g, '<span class="tok-str">$1</span>'),
  )

  // 2) COMMENTS (protected regions skip strings)
  if (
    [
      'javascript',
      'typescript',
      'java',
      'c',
      'cplusplus',
      'csharp',
      'go',
      'rust',
      'css',
      'less',
      'php',
      'kotlin',
      'scala',
      'groovy',
      'dart',
      'swift',
      'objectivec',
    ].includes(lang)
  ) {
    pass((t) => t.replace(/(\/\*[\s\S]*?\*\/)/g, '<span class="tok-cmt">$1</span>'))
    pass((t) => t.replace(/(^|[^:])(\/\/[^\n]*)/gm, '$1<span class="tok-cmt">$2</span>'))
  }
  if (
    [
      'python',
      'unixshell',
      'yaml',
      'ini',
      'properties',
      'makefile',
      'hosts',
      'htaccess',
      'ruby',
      'perl',
      'powershell',
      'r',
    ].includes(lang)
  ) {
    pass((t) => t.replace(/(^|[\s;|&(])(#[^\n]*)/gm, '$1<span class="tok-cmt">$2</span>'))
    // shebang at BOF
    pass((t) => t.replace(/^(#![^\n]*)/m, '<span class="tok-cmt">$1</span>'))
  }
  if (lang === 'sql') pass((t) => t.replace(/(--[^\n]*)/g, '<span class="tok-cmt">$1</span>'))
  if (lang === 'html' || lang === 'xml' || lang === 'markup' || lang === 'markdown') {
    pass((t) => t.replace(/(&lt;!--[\s\S]*?--&gt;)/g, '<span class="tok-cmt">$1</span>'))
  }
  if (lang === 'lua') {
    pass((t) => t.replace(/(--\[\[[\s\S]*?\]\]|--[^\n]*)/g, '<span class="tok-cmt">$1</span>'))
  }

  // 3) numbers
  pass((t) =>
    t.replace(/\b(0x[0-9a-fA-F]+|\d+\.?\d*(?:e[+-]?\d+)?)\b/g, '<span class="tok-num">$1</span>'),
  )

  // 4) preprocessor / ini sections
  if (lang === 'c' || lang === 'cplusplus' || lang === 'objectivec') {
    pass((t) =>
      t.replace(
        /(^|\n)(\s*#\s*(?:include|define|ifdef|ifndef|endif|pragma|if|else|elif)\b[^\n]*)/g,
        '$1<span class="tok-prep">$2</span>',
      ),
    )
  }
  if (lang === 'ini' || lang === 'properties') {
    pass((t) => t.replace(/(^|\n)(\[[^\]]+\])/g, '$1<span class="tok-tag">$2</span>'))
  }

  // 5) keywords
  const KW = {
    javascript:
      /\b(const|let|var|function|return|if|else|for|while|class|async|await|import|export|from|new|this|typeof|instanceof|try|catch|finally|throw|switch|case|break|continue|default|null|undefined|true|false|of|in|yield|static|extends|super|delete|void|debugger)\b/g,
    typescript:
      /\b(const|let|var|function|return|if|else|for|while|class|async|await|import|export|from|new|this|type|interface|enum|implements|public|private|protected|readonly|as|typeof|try|catch|true|false|null|undefined|namespace|declare|abstract|keyof|infer)\b/g,
    python:
      /\b(def|class|return|if|elif|else|for|while|import|from|as|with|try|except|finally|raise|None|True|False|lambda|yield|async|await|pass|break|continue|global|nonlocal|assert|in|is|not|and|or|del|match|case)\b/g,
    java: /\b(public|private|protected|class|interface|enum|extends|implements|return|if|else|for|while|new|static|final|void|int|long|boolean|String|try|catch|throw|throws|import|package|this|super|null|true|false|abstract|synchronized|volatile|transient)\b/g,
    c: /\b(int|char|void|return|if|else|for|while|struct|typedef|const|static|unsigned|long|short|float|double|sizeof|enum|extern|volatile|register|union|goto|switch|case|break|continue|default|NULL)\b/g,
    cplusplus:
      /\b(int|char|void|return|if|else|for|while|class|struct|namespace|template|const|static|public|private|protected|new|delete|true|false|nullptr|using|typename|virtual|override|constexpr|auto|throw|try|catch)\b/g,
    csharp:
      /\b(public|private|protected|class|interface|namespace|return|if|else|for|while|new|static|void|int|string|bool|var|using|try|catch|null|true|false|async|await|override|virtual|abstract|get|set|typeof|nameof)\b/g,
    go: /\b(func|return|if|else|for|package|import|var|const|type|struct|interface|map|chan|go|defer|range|nil|true|false|select|case|default|switch|fallthrough|break|continue)\b/g,
    rust: /\b(fn|let|mut|return|if|else|for|while|loop|match|struct|enum|impl|trait|use|pub|mod|const|static|true|false|self|Self|where|async|await|move|ref|crate|super|unsafe|dyn)\b/g,
    php: /\b(function|return|if|else|elseif|foreach|for|while|class|public|private|protected|new|echo|print|namespace|use|try|catch|true|false|null|array|as|switch|case|break|continue|static|final)\b/g,
    ruby: /\b(def|class|module|return|if|elsif|else|end|do|while|for|in|require|include|attr_accessor|true|false|nil|yield|unless|until|begin|rescue|ensure)\b/g,
    perl: /\b(sub|my|our|use|package|if|elsif|else|unless|while|for|foreach|return|print|say|strict|warnings|local|next|last|redo)\b/g,
    unixshell:
      /\b(if|then|else|elif|fi|for|do|done|case|esac|function|export|local|return|while|until|select|in|time|coproc|echo|cd|ls|grep|awk|sed|cat|chmod|chown|sudo|apt|yum|systemctl|service|docker|kubectl|ssh|scp|rsync|source|alias|set|unset|read|printf|test|true|false)\b/g,
    shell:
      /\b(if|then|else|elif|fi|for|do|done|case|esac|function|export|local|return|while|echo|cd)\b/g,
    windowsbatch: /\b(IF|ELSE|FOR|IN|DO|GOTO|CALL|SET|ECHO|REM|EXIT|EQU|NEQ|LSS|LEQ|GTR|GEQ)\b/gi,
    powershell:
      /\b(function|param|if|else|elseif|foreach|for|while|return|switch|begin|process|end|try|catch|finally|\$true|\$false|\$null|filter|workflow|using|class|enum)\b/gi,
    sql: /\b(SELECT|FROM|WHERE|INSERT|UPDATE|DELETE|JOIN|LEFT|RIGHT|INNER|OUTER|AND|OR|NOT|NULL|CREATE|TABLE|INDEX|DROP|ALTER|VALUES|INTO|SET|ORDER|BY|GROUP|HAVING|LIMIT|AS|ON|IN|IS|LIKE|BETWEEN|DISTINCT|UNION|ALL|EXISTS|PRIMARY|KEY|FOREIGN|REFERENCES|VIEW|TRIGGER|PROCEDURE|FUNCTION)\b/gi,
    docker:
      /\b(FROM|RUN|CMD|ENTRYPOINT|ENV|ARG|COPY|ADD|WORKDIR|USER|VOLUME|EXPOSE|LABEL|HEALTHCHECK|SHELL|ONBUILD|STOPSIGNAL|MAINTAINER)\b/g,
    makefile:
      /\b(ifeq|ifneq|ifdef|ifndef|else|endif|include|export|unexport|define|endef|override|private|vpath)\b/g,
    kotlin:
      /\b(fun|val|var|class|object|interface|if|else|when|for|while|return|import|package|null|true|false|suspend|override|data|companion|sealed|inline|reified)\b/g,
    scala:
      /\b(def|val|var|class|object|trait|if|else|for|while|return|import|package|null|true|false|match|case|extends|with|implicit|lazy|yield|type)\b/g,
    groovy: /\b(def|class|if|else|for|while|return|import|package|null|true|false|in|as|trait|switch|case)\b/g,
    lua: /\b(function|local|return|if|then|else|elseif|end|for|while|do|repeat|until|nil|true|false|and|or|not|in)\b/g,
    yaml: /\b(true|false|null|yes|no|on|off)\b/gi,
    dart: /\b(class|void|var|final|const|return|if|else|for|while|import|library|true|false|null|async|await|extends|implements|mixin|typedef|enum|required)\b/g,
    css: /\b(color|background|border|margin|padding|display|flex|grid|position|width|height|font|@media|@import|@keyframes|@font-face|justify-content|align-items|overflow|z-index|opacity|transform|transition)\b/g,
    json: /\b(true|false|null)\b/g,
    ini: /\b(true|false|on|off|yes|no)\b/gi,
    r: /\b(function|if|else|for|while|repeat|in|next|break|TRUE|FALSE|NULL|NA|Inf|NaN|library|require|return|source)\b/g,
    swift:
      /\b(func|var|let|class|struct|enum|protocol|if|else|for|while|return|import|true|false|nil|self|Self|guard|defer|async|await|throws|try|catch|switch|case|default)\b/g,
    objectivec:
      /\b(int|char|void|return|if|else|for|while|self|super|nil|YES|NO|id|instancetype|nonatomic|strong|weak|assign|copy|readonly|readwrite|IBOutlet|IBAction)\b/g,
  }
  const re = KW[lang]
  if (re) pass((t) => t.replace(re, '<span class="tok-kw">$1</span>'))

  // 6) function / call names
  if (['javascript', 'typescript', 'python', 'go', 'rust', 'java', 'c', 'cplusplus'].includes(lang)) {
    pass((t) => t.replace(/\b([A-Za-z_][\w]*)\s*(?=\()/g, '<span class="tok-fn">$1</span>'))
  }

  // 7) markup
  if (lang === 'html' || lang === 'xml' || lang === 'markup') {
    pass((t) => t.replace(/(&lt;\/?[a-zA-Z][\w:-]*)/g, '<span class="tok-tag">$1</span>'))
    pass((t) => t.replace(/\s([a-zA-Z_:][\w:.-]*)(?==)/g, ' <span class="tok-attr">$1</span>'))
  }

  // 8) markdown
  if (lang === 'markdown') {
    pass((t) => t.replace(/(^#{1,6}\s+[^\n]+)/gm, '<span class="tok-kw">$1</span>'))
    pass((t) => t.replace(/(\*\*[^*\n]+\*\*|__[^_\n]+__)/g, '<span class="tok-kw">$1</span>'))
    pass((t) => t.replace(/(`[^`\n]+`)/g, '<span class="tok-str">$1</span>'))
    pass((t) => t.replace(/(\[[^\]]+\]\([^)]+\))/g, '<span class="tok-tag">$1</span>'))
  }

  // 9) punctuation
  pass((t) => t.replace(/([{}()\[\];])/g, '<span class="tok-op">$1</span>'))

  return h
}


function lineCount(text) {
  if (!text) return 1
  return String(text).split(/\n/).length
}

function isProbablyBinary(bufOrStr) {
  if (typeof Buffer !== 'undefined' && Buffer.isBuffer && Buffer.isBuffer(bufOrStr)) {
    const n = Math.min(bufOrStr.length, 8000)
    let bad = 0
    for (let i = 0; i < n; i++) {
      const c = bufOrStr[i]
      if (c === 0) return true
      if (c < 9 || (c > 13 && c < 32)) bad++
    }
    return n > 0 && bad / n > 0.3
  }
  if (typeof bufOrStr === 'string') {
    let bad = 0
    const n = Math.min(bufOrStr.length, 8000)
    for (let i = 0; i < n; i++) {
      const c = bufOrStr.charCodeAt(i)
      if (c === 0) return true
      if (c < 9 || (c > 13 && c < 32)) bad++
    }
    return n > 0 && bad / n > 0.3
  }
  return false
}

function buildLineGutter(text, maxLines = 20000) {
  const n = Math.min(lineCount(text), maxLines)
  let s = ''
  for (let i = 1; i <= n; i++) s += i + '\n'
  if (lineCount(text) > maxLines) s += '…\n'
  return s
}

function buildGutter(text, maxLines) {
  return buildLineGutter(text, maxLines)
}

function cursorFromIndex(text, index) {
  const head = String(text).slice(0, Math.max(0, index))
  const parts = head.split(/\n/)
  return { line: parts.length, col: (parts[parts.length - 1] || '').length + 1 }
}

function indexFromLineCol(text, line, col) {
  const lines = String(text).split(/\n/)
  let idx = 0
  const L = Math.max(1, Math.min(line, lines.length))
  for (let i = 0; i < L - 1; i++) idx += lines[i].length + 1
  idx += Math.max(0, Math.min((col || 1) - 1, (lines[L - 1] || '').length))
  return idx
}

function normalizeFindOpts(opts) {
  if (opts == null) return { caseSensitive: false, regex: false }
  if (typeof opts === 'boolean') return { caseSensitive: opts, regex: false }
  return { caseSensitive: !!opts.caseSensitive, regex: !!opts.regex }
}

function findAll(text, query, opts) {
  if (!query) return []
  const { caseSensitive, regex } = normalizeFindOpts(opts)
  const src = String(text)
  const flags = caseSensitive ? 'g' : 'gi'
  let re
  try {
    re = regex
      ? new RegExp(query, flags)
      : new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flags)
  } catch {
    return []
  }
  const out = []
  let m
  while ((m = re.exec(src))) {
    out.push({ index: m.index, length: m[0].length, text: m[0] })
    if (m[0].length === 0) re.lastIndex++
    if (out.length > 10000) break
  }
  return out
}

function replaceAll(text, query, replacement, opts = {}) {
  const hits = findAll(text, query, opts)
  if (!hits.length) return { text, count: 0 }
  let out = ''
  let last = 0
  for (const h of hits) {
    out += text.slice(last, h.index) + replacement
    last = h.index + h.length
  }
  out += text.slice(last)
  return { text: out, count: hits.length }
}

module.exports = {
  createEditorDoc,
  guessLang,
  listLanguages,
  langLabel,
  highlightPlain,
  lineCount,
  isProbablyBinary,
  buildLineGutter,
  buildGutter,
  cursorFromIndex,
  indexFromLineCol,
  findAll,
  replaceAll,
  protectSpans,
  EXT_LANG,
  LANG_LABELS,
}
