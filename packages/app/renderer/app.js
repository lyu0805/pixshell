/* native-113 */
(function(){try{const p=String((typeof process!=='undefined'&&process.platform)||navigator.platform||'');document.body&&document.body.classList&&(document.body.classList.toggle('win',/Win/i.test(p)||/Windows/i.test(navigator.userAgent||'')),document.body.classList.toggle('is-mac',/Mac|Darwin/i.test(p)),document.body.classList.toggle('darwin',/Mac|Darwin/i.test(p)));}catch(_){}})();
/**
 * PixShell frontend — native fsApi SSH, real layout & interactions.
 * No mock. No "bridge OK".
 */
;(() => {
  const api = window.fsApi
  const hasApi = typeof api !== 'undefined'

  /** 多国语言等宽回退：用户选的拉丁 mono + CJK/Emoji 系统字体 */
  const MONO_I18N_FALLBACK =
    '"SF Mono", ui-monospace, Menlo, Monaco, Consolas, "Cascadia Mono", "Cascadia Code", ' +
    '"Sarasa Mono SC", "Noto Sans Mono CJK SC", "Noto Sans Mono CJK TC", "Noto Sans Mono CJK JP", "Noto Sans Mono CJK KR", ' +
    '"Source Han Mono SC", "WenQuanYi Micro Hei Mono", ' +
    '"PingFang SC", "Hiragino Sans GB", "Hiragino Kaku Gothic ProN", "Yu Gothic UI", "Malgun Gothic", ' +
    '"Microsoft YaHei UI", "Microsoft JhengHei UI", "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", monospace'

  const DEFAULT_TERM_FONT_FAMILY =
    'JetBrains Mono, Cascadia Code, Source Code Pro, ' + MONO_I18N_FALLBACK

  function withMonoI18n(family) {
    const base = String(family || '').trim()
    if (!base) return DEFAULT_TERM_FONT_FAMILY
    // 已含 CJK / 多国回退则不重复追加
    if (/PingFang|Noto Sans Mono CJK|Sarasa|YaHei|JhengHei|Hiragino|Malgun|Source Han Mono|WenQuanYi|Noto Color Emoji/i.test(base)) {
      return base
    }
    // 去掉末尾裸 monospace 再拼完整回退
    const cleaned = base.replace(/,?\s*monospace\s*$/i, '').trim()
    return cleaned + ', ' + MONO_I18N_FALLBACK
  }

  const $ = (id) => document.getElementById(id)

  /** Always-on file log via main (repo/logs + userData/logs). Never throw. */
  function rlog(level, tag, msg, extra) {
    try {
      if (hasApi && typeof api.logWrite === 'function') {
        api.logWrite(level || 'info', tag || 'ui', String(msg || ''), extra)
      } else {
        const fn = level === 'error' ? console.error : level === 'warn' ? console.warn : console.log
        fn.call(console, '[rlog]', tag, msg, extra || '')
      }
    } catch (_) {}
  }
  window.addEventListener('error', (ev) => {
    rlog('error', 'window', ev.message || 'error', {
      file: ev.filename,
      line: ev.lineno,
      col: ev.colno,
      stack: ev.error && ev.error.stack,
    })
  })
  window.addEventListener('unhandledrejection', (ev) => {
    const r = ev.reason
    rlog('error', 'unhandledrejection', r && r.message ? r.message : String(r), {
      stack: r && r.stack,
    })
  })

  const state = {
    hosts: [],
    settings: {},
    quick: [],
    tabs: [], // {id,type,hostId,title,sessionId,status,sftpPath,buffer?}
    activeTabId: null,
    activeHostId: null,
    filter: '',
    mgrFilter: '',
    mgrSelectedId: null,
    selectedSftp: null,
    selectedSftpList: [],
    history: [],
    histIndex: -1,
    draft: '',
    bottom: 'files', // files | cmds
    bottomCollapsed: false,
    sideCollapsed: false,
    editHostId: null,
    monTimer: null,
    netSpark: [],
    pingSpark: [],
    selectedProcPid: null,
    activeCmdGroup: null,
    selectedChipCmd: null,
    cmdEditorCollapsed: false,
    _reconnectInflight: false,
    _connectInflightHostId: null,
    appVersion: '',
    updateInfo: null,
    updateStatus: 'checking', // checking | latest | update-available | none | error | unknown
    _updateCheckInflight: null,
  }

  const passwordVault = new Map()
  const keyVault = new Map()
  const termBuffers = new Map() // sessionId -> string
  const MAX_BUF = 500000
  let term = null
  let fitAddon = null
  let _termAppearanceGen = 0
  let switching = false
  let ttyLine = ''

  // ── utils ──────────────────────────────────────────────
  function toast(msg, err) {
    const el = $('toast')
    if (!el) {
      console.log(msg)
      return
    }
    el.textContent = msg
    el.classList.toggle('err', !!err)
    el.hidden = false
    clearTimeout(toast._t)
    toast._t = setTimeout(() => { el.hidden = true }, 3200)
  }

  /**
   * Electron 不支持 window.prompt / confirm —— 全部走自建弹窗。
   * @returns {Promise<string|null>} null=取消
   */
  /**
   * @returns {Promise<string|{value:string,remember:boolean}|null>}
   * password + rememberPassword → {value,remember}; else string; cancel → null
   */
  function askPrompt(message, defaultValue = '', opts = {}) {
    return new Promise((resolve) => {
      let mask = document.getElementById('askPromptMask')
      if (!mask) {
        mask = document.createElement('div')
        mask.id = 'askPromptMask'
        mask.className = 'modal-mask'
        mask.innerHTML = `<div class="modal" style="min-width:400px;max-width:92vw">
          <div class="modal-title" id="askPromptTitle">输入</div>
          <div class="modal-body">
            <p id="askPromptMsg" style="margin:0 0 10px;white-space:pre-wrap;color:var(--text)"></p>
            <input id="askPromptInput" type="text" class="thin-input" style="width:100%;height:28px;box-sizing:border-box" />
            <label class="pw-remember" id="askPromptRememberWrap" hidden>
              <input type="checkbox" id="askPromptRemember" checked />
              <span>记住密码（保存到本机）</span>
            </label>
          </div>
          <div class="modal-actions">
            <button type="button" class="cmd-btn" id="askPromptCancel">取消</button>
            <button type="button" class="cmd-btn primary" id="askPromptOk">确定</button>
          </div>
        </div>`
        document.body.appendChild(mask)
      }
      const input = mask.querySelector('#askPromptInput')
      const msg = mask.querySelector('#askPromptMsg')
      const title = mask.querySelector('#askPromptTitle')
      const remWrap = mask.querySelector('#askPromptRememberWrap')
      const rem = mask.querySelector('#askPromptRemember')
      msg.textContent = message || ''
      title.textContent = opts.title || '输入'
      input.type = opts.password ? 'password' : 'text'
      input.value = defaultValue == null ? '' : String(defaultValue)
      input.placeholder = opts.placeholder || ''
      const showRem = !!(opts.password && opts.rememberPassword !== false)
      if (remWrap) {
        remWrap.hidden = !showRem
        if (showRem) remWrap.removeAttribute('hidden')
        else remWrap.setAttribute('hidden', '')
      }
      if (rem) rem.checked = opts.rememberDefault !== false
      mask.hidden = false
      mask.removeAttribute('hidden')
      setTimeout(() => {
        input.focus()
        input.select?.()
      }, 30)

      const finish = (val) => {
        mask.hidden = true
        mask.setAttribute('hidden', '')
        input.onkeydown = null
        ok.onclick = null
        cancel.onclick = null
        mask.onclick = null
        if (val === null) return resolve(null)
        if (showRem) resolve({ value: val, remember: !!(rem && rem.checked) })
        else resolve(val)
      }
      const ok = mask.querySelector('#askPromptOk')
      const cancel = mask.querySelector('#askPromptCancel')
      ok.onclick = () => finish(input.value)
      cancel.onclick = () => finish(null)
      mask.onclick = (e) => {
        if (e.target === mask) finish(null)
      }
      input.onkeydown = (e) => {
        if (e.key === 'Enter') {
          e.preventDefault()
          finish(input.value)
        } else if (e.key === 'Escape') {
          e.preventDefault()
          finish(null)
        }
      }
    })
  }

  /** @returns {Promise<boolean>} */
  function askConfirm(message, opts = {}) {
    return new Promise((resolve) => {
      let mask = document.getElementById('askConfirmMask')
      if (!mask) {
        mask = document.createElement('div')
        mask.id = 'askConfirmMask'
        mask.className = 'modal-mask ask-confirm-mask'
        mask.innerHTML = `<div class="modal ask-confirm-modal" role="alertdialog" aria-modal="true" aria-labelledby="askConfirmTitle" aria-describedby="askConfirmMsg">
          <div class="modal-title ask-confirm-title" id="askConfirmTitle">
            <span class="ask-confirm-ico" aria-hidden="true">!</span>
            <span id="askConfirmTitleText">确认</span>
          </div>
          <div class="modal-body ask-confirm-body">
            <p id="askConfirmMsg" class="ask-confirm-msg"></p>
          </div>
          <div class="modal-actions ask-confirm-actions">
            <button type="button" class="cmd-btn" id="askConfirmCancel">取消</button>
            <button type="button" class="cmd-btn ask-confirm-ok" id="askConfirmOk">确定删除</button>
          </div>
        </div>`
        document.body.appendChild(mask)
      }
      const title = String(opts.title || '确认')
      const danger =
        opts.danger !== false &&
        /删除|清空|断开|覆盖|丢失|不可恢复|remove|delete|destroy/i.test(title + ' ' + (message || ''))
      const okLabel = opts.okText || (danger ? '确定删除' : '确定')
      const cancelLabel = opts.cancelText || '取消'
      mask.classList.toggle('is-danger', !!danger)
      mask.querySelector('#askConfirmMsg').textContent = message || ''
      const titleText = mask.querySelector('#askConfirmTitleText')
      if (titleText) titleText.textContent = title
      else mask.querySelector('#askConfirmTitle').textContent = title
      const ok = mask.querySelector('#askConfirmOk')
      const cancel = mask.querySelector('#askConfirmCancel')
      ok.textContent = okLabel
      cancel.textContent = cancelLabel
      ok.classList.toggle('ask-confirm-ok', true)
      ok.classList.toggle('primary', !danger)
      // 提到最前，避免被连接管理器/编辑器盖住
      mask.style.zIndex = '20000'
      mask.hidden = false
      mask.removeAttribute('hidden')
      // 居中固定，不跟 float-modal-mask 混用
      mask.classList.remove('float-modal-mask')
      mask.classList.add('ask-confirm-mask')
      setTimeout(() => {
        try {
          ;(danger ? cancel : ok).focus()
        } catch (_) {}
      }, 30)
      const finish = (v) => {
        mask.hidden = true
        mask.setAttribute('hidden', '')
        ok.onclick = null
        cancel.onclick = null
        mask.onclick = null
        window.removeEventListener('keydown', onKey)
        resolve(v)
      }
      const onKey = (e) => {
        if (e.key === 'Escape') {
          e.preventDefault()
          finish(false)
        } else if (e.key === 'Enter' && !danger) {
          e.preventDefault()
          finish(true)
        }
      }
      window.addEventListener('keydown', onKey)
      ok.onclick = () => finish(true)
      cancel.onclick = () => finish(false)
      mask.onclick = (e) => {
        if (e.target === mask) finish(false)
      }
    })
  }
  function esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
  }
  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, `'\\''`) + "'"
  }
  function joinRemote(base, name) {
    if (!name || name === '.') return base || '.'
    if (name === '..') {
      if (!base || base === '.' || base === '/') return base === '/' ? '/' : '.'
      const parts = String(base).replace(/\/+$/, '').split('/')
      parts.pop()
      const j = parts.join('/')
      return j === '' ? (String(base).startsWith('/') ? '/' : '.') : j
    }
    if (name.startsWith('/')) return name
    if (!base || base === '.') return name
    if (base === '/') return '/' + name
    return base.replace(/\/+$/, '') + '/' + name
  }
  function formatMemHuman(mb) {
    const m = Number(mb) || 0
    if (m >= 1024) {
      const g = m / 1024
      // match reference: 3.5G/4 style (trim trailing .0)
      const s = g >= 10 ? g.toFixed(0) : g.toFixed(1).replace(/\.0$/, '')
      return s + 'G'
    }
    if (m >= 1) return (m >= 10 ? m.toFixed(0) : m.toFixed(1).replace(/\.0$/, '')) + 'M'
    if (m > 0) return Math.max(1, Math.round(m * 1024)) + 'K'
    return '0'
  }
  function levelClass(pct) {
    const p = Number(pct) || 0
    if (p >= 90) return 'crit'
    if (p >= 70) return 'hi'
    return ''
  }
  function setMetricBar(barId, pctId, sizeId, pct, sizeText, kind) {
    const bar = $(barId)?.parentElement // .lm-bar
    const fill = $(barId)
    const pctEl = $(pctId)
    const sizeEl = sizeId ? $(sizeId) : null
    const raw = Number(pct)
    const p = Math.min(100, Math.max(0, Number.isFinite(raw) ? raw : 0))
    if (fill) fill.style.width = p + '%'
    if (pctEl) {
      // show 1 decimal when < 10 so 0.3% isn't rounded to 0%
      const txt = p < 10 && p > 0 ? p.toFixed(1) : String(Math.round(p))
      pctEl.textContent = txt + '%'
    }
    if (sizeEl) sizeEl.textContent = sizeText || ''
    if (bar) {
      bar.classList.remove('hi', 'crit')
      const lv = levelClass(p)
      if (lv) bar.classList.add(lv)
    }
  }
  function formatSize(n) {
    const x = Number(n) || 0
    if (x < 1024) return x + ' B'
    if (x < 1048576) return (x / 1024).toFixed(1) + ' K'
    if (x < 1073741824) return (x / 1048576).toFixed(1) + ' M'
    return (x / 1073741824).toFixed(2) + ' G'
  }
  function formatTime(ms) {
    if (!ms) return ''
    const d = new Date(ms)
    const p = (n) => String(n).padStart(2, '0')
    return `${d.getFullYear()}/${p(d.getMonth() + 1)}/${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
  }
  function currentTab() {
    return state.tabs.find((t) => t.id === state.activeTabId) || null
  }
  function currentHost() {
    const tab = currentTab()
    const id = tab?.hostId || state.activeHostId
    return state.hosts.find((h) => h.id === id) || null
  }
  function sessionTab() {
    // Prefer active tab when it owns a live/reconnecting session; else first connected.
    // Include reconnecting so SFTP/monitor helpers keep the same tab binding across auto-reconnect.
    const t = currentTab()
    if (t?.sessionId && (t.status === 'connected' || t.status === 'reconnecting' || t.status === 'connecting')) {
      return t
    }
    return (
      state.tabs.find((x) => x.sessionId && x.status === 'connected') ||
      state.tabs.find((x) => x.sessionId && x.status === 'reconnecting') ||
      t
    )
  }

  // ── terminal ───────────────────────────────────────────
  function initTerm() {
    const Terminal = window.Terminal
    const FitCtor = window.FitAddon?.FitAddon || window.FitAddon
    if (!Terminal) {
      $('xtermHost').innerHTML = '<div style="color:var(--muted);padding:12px">xterm 未加载</div>'
      return
    }
    const s = state.settings || {}
    const cursorStyle = ['block', 'underline', 'bar'].includes(s.cursorStyle) ? s.cursorStyle : 'block'
    term = new Terminal({
      cursorBlink: s.cursorBlink !== false,
      cursorStyle,
      fontSize: Number(s.fontSize) || 13,
      fontFamily: withMonoI18n(s.fontFamily || DEFAULT_TERM_FONT_FAMILY),
      theme: buildLocalFallbackTheme(s),
      scrollback: 10000,
      allowProposedApi: true,
      convertEol: false,
      drawBoldTextInBrightColors: s.drawBoldTextInBrightColors !== false,
      minimumContrastRatio: Number(s.minimumContrastRatio) > 0 ? Number(s.minimumContrastRatio) : 4.5,
      fontWeight: s.fontWeight || 'normal',
      fontWeightBold: s.fontWeightBold || 'bold',
    })
    if (FitCtor) {
      fitAddon = new FitCtor()
      term.loadAddon(fitAddon)
    }
    term.open($('xtermHost'))
    fitAddon?.fit()
    try { ensureTermScrollbar() } catch (_) {}
    bindTermHostResize()
    // 仅用本地 fallback 先铺底；完整配色等 loadAll 注入 settings 后再 apply，
    // 避免「空 settings 的异步 apply」在 loadAll 之后才完成、把正确主题盖暗。
    try {
      paintTermBackgroundDom((buildLocalFallbackTheme(s) || {}).background || '#1e1f29')
    } catch (_) {}
    try {
      ensureTermScrollbar()
    } catch (_) {}
    const xh = $('xtermHost')
    if (xh && !xh.dataset.ctxBound) {
      xh.dataset.ctxBound = '1'
      xh.addEventListener('contextmenu', (e) => {
        e.preventDefault()
        showTermContextMenu(e.clientX, e.clientY)
      })
    }
    window.addEventListener('resize', () => {
      try {
        applyTermFontScale()
      } catch (_) {}
      fitAddon?.fit()
      const t = sessionTab()
      if (t?.sessionId && hasApi) api.resize(t.sessionId, term.cols, term.rows)
    })
    term.onData((data) => {
      const t = sessionTab()
      if (t?.sessionId && hasApi) api.write(t.sessionId, data)
      if (state.settings.syncDirWithSftp === true && typeof data === 'string') {
        for (const ch of data) {
          if (ch === '\r' || ch === '\n') {
            if (ttyLine.trim()) handleCdLine(ttyLine)
            ttyLine = ''
          } else if (ch === '\x7f' || ch === '\b') ttyLine = ttyLine.slice(0, -1)
          else if (ch >= ' ' || ch === '\t') {
            ttyLine += ch
            if (ttyLine.length > 400) ttyLine = ttyLine.slice(-400)
          }
        }
      }
    })
    if (!hasApi) {
      term.writeln('\x1b[31m未在 Electron 中启动。请运行: node start.js\x1b[0m')
    } else {
      term.writeln('\x1b[90mPixShell · 点击左上角 Logo 打开连接管理器，或双击快速连接\x1b[0m')
      api.sshReady().then((r) => {
        if ($('statusSsh2')) {
          $('statusSsh2').textContent = r.ssh2
            ? 'ssh2 · ' + (r.architecture || 'native')
            : 'ssh2 缺失'
        }
        if (!r.ssh2) {
          term.writeln('\x1b[31m[SSH] ssh2 未加载: ' + (r.error || '') + '\x1b[0m')
          toast('ssh2 未加载 — 无法 SSH', true)
        }
      })
    }
  }

  function buildLocalFallbackTheme(s) {
    // 仅在用户明确锁定且与主题兼容时使用 override，避免暗色首屏吃到浅灰粘滞底
    const mode = (s && s.theme === 'light') ? 'light' : 'dark'
    let bg = '#1e1f29'
    if (s && s.termBgUserSet === true) {
      const raw = String(s.termBgOverride || s.termBg || '').trim()
      if (raw && raw[0] === '#') {
        const lum = colorLuminance(raw)
        const ok = mode === 'light' ? lum > 70 : (lum >= 0 && lum < 120)
        if (ok) bg = raw
      }
    } else if (mode === 'light') {
      bg = '#d4d6dc'
    }
    return {
      background: bg,
      foreground: mode === 'light' ? '#0b0b0d' : '#f8f8f2',
      cursor: '#bbbbbb',
      cursorAccent: bg,
      selectionBackground: '#44475a',
      black: '#000000',
      red: '#ff3b30',
      green: '#50fa7b',
      yellow: '#f1fa8c',
      blue: '#bd93f9',
      magenta: '#ff79c6',
      cyan: '#8be9fd',
      white: '#bbbbbb',
      brightBlack: '#555555',
      brightRed: '#ff5555',
      brightGreen: '#50fa7b',
      brightYellow: '#f1fa8c',
      brightBlue: '#bd93f9',
      brightMagenta: '#ff79c6',
      brightCyan: '#8be9fd',
      brightWhite: '#ffffff',
    }
  }

  async function loadSchemeList() {
    if (!hasApi || !api.listSchemes) return []
    try {
      const r = await api.listSchemes()
      return r?.schemes || []
    } catch (_) {
      return []
    }
  }

  async function fetchSchemeTheme(id) {
    if (!hasApi || !api.getScheme) return null
    try {
      const r = await api.getScheme(id)
      if (r?.xterm) return r.xterm
      if (r?.scheme) {
        const s = r.scheme
        return {
          background: s.background,
          foreground: s.foreground,
          cursor: s.cursor,
          cursorAccent: s.background,
          selectionBackground: s.selectionBackground,
          black: s.black,
          red: s.red,
          green: s.green,
          yellow: s.yellow,
          blue: s.blue,
          magenta: s.magenta,
          cyan: s.cyan,
          white: s.white,
          brightBlack: s.brightBlack,
          brightRed: s.brightRed,
          brightGreen: s.brightGreen,
          brightYellow: s.brightYellow,
          brightBlue: s.brightBlue,
          brightMagenta: s.brightMagenta,
          brightCyan: s.brightCyan,
          brightWhite: s.brightWhite,
        }
      }
    } catch (_) {}
    return null
  }

  /**
   * 终端字号：以设置 fontSize 为基准，随面板尺寸温和缩放（全屏变大、极小略缩）。
   * 逻辑与 packages/terminal/src/appearance-policy.js resolveTermFontPx 一致。
   */
  function resolveTermFontPxLocal(baseFont, hostW, hostH) {
    // 字号即所见：直接用设置里的字号（仅 8–36 夹取防越界），不再按面板尺寸缩放。
    // 之前的面板缩放 + 封顶 20 会让「设置-终端字号」形同虚设：改了看不出变化、
    // 设成 >20 被砍回 20。用户明确要求该设置生效，故一律用字面值。
    const base = Math.max(8, Math.min(36, Number(baseFont) || 13))
    return { px: base, scale: 1 }
  }

  function applyTermFontScale() {
    if (!term) return
    const base = Math.max(8, Math.min(36, Number(state.settings?.fontSize) || 13))
    const host = $('xtermHost')
    let w = host?.clientWidth || 0
    let h = host?.clientHeight || 0
    // host 折叠/隐藏时不要改字号（日志曾出现 w=1 h=1 → 字几乎消失）
    if (w < 40 || h < 40) {
      try {
        fitAddon?.fit()
      } catch (_) {}
      return
    }
    const { px, scale } = resolveTermFontPxLocal(base, w, h)
    const prev = Number(term.options?.fontSize) || 0
    try {
      term.options.fontSize = px
      if (typeof term.setOption === 'function') term.setOption('fontSize', px)
    } catch (_) {
      try {
        term.options.fontSize = px
      } catch (__) {}
    }
    state._termFontScaled = px
    try {
      fitAddon?.fit()
    } catch (_) {}
    try {
      if (typeof term.refresh === 'function' && term.rows > 0) {
        term.refresh(0, Math.max(0, term.rows - 1))
      }
    } catch (_) {}
    if (prev !== px) {
      try {
        rlog('info', 'term', 'font-scale', {
          base,
          px,
          scale: Math.round(scale * 100) / 100,
          mode: 'panel-scale',
          w,
          h,
        })
      } catch (_) {}
    }
    try {
      const t = sessionTab()
      if (t?.sessionId && hasApi && term.cols && term.rows) {
        api.resize(t.sessionId, term.cols, term.rows)
      }
    } catch (_) {}
  }

  function bindTermHostResize() {
    const host = $('xtermHost')
    if (!host || host.dataset.roBound) return
    host.dataset.roBound = '1'
    if (typeof ResizeObserver === 'function') {
      const ro = new ResizeObserver(() => {
        try {
          applyTermFontScale()
        } catch (_) {
          try {
            fitAddon?.fit()
          } catch (__) {}
        }
      })
      ro.observe(host)
      state._termHostRo = ro
    }
  }

  /** 强制 xterm 视口显示纵向滚动条（mac 默认 overlay 几乎看不见） */
  function ensureTermScrollbar() {
    try {
      document.querySelectorAll('.xterm .xterm-viewport').forEach((vp) => {
        vp.style.overflowY = 'scroll'
        vp.style.overflowX = 'hidden'
        // 非 overlay：尽量常显
        try {
          vp.style.scrollbarWidth = 'thin'
          vp.style.scrollbarGutter = 'stable'
        } catch (_) {}
      })
      const host = $('xtermHost')
      if (host) {
        host.classList.add('has-term-scroll')
      }
    } catch (_) {}
  }

  /** Hard-clear xterm viewport + scrollback so a closed tab cannot leak into the next session. */
  function hardResetTerminalViewport() {
    try {
      if (typeof term?.reset === 'function') term.reset()
      else if (typeof term?.clear === 'function') term.clear()
    } catch (_) {}
    try {
      // Explicit erase screen + scrollback + home
      term?.write?.('\x1b[2J\x1b[3J\x1b[H')
    } catch (_) {}
    try {
      if (typeof term?.scrollToTop === 'function') term.scrollToTop()
    } catch (_) {}
  }

  function clearTermSessionVisual(sid, { resetViewport = false } = {}) {
    if (sid) {
      try { termBuffers.delete(sid) } catch (_) {}
      try { termBuffers.set(sid, '') } catch (_) {}
    }
    if (resetViewport) hardResetTerminalViewport()
  }

  function repaintActiveTermBuffer() {
    if (!term) return
    const t = sessionTab()
    const sid = t && t.sessionId
    if (!sid || !termBuffers.has(sid)) return
    const raw = termBuffers.get(sid) || ''
    if (!raw) return
    try {
      // 保留缓冲，重写屏幕：reset 会丢历史，改用 clear + write 尾部
      const MAX = 120000
      const slice = raw.length > MAX ? raw.slice(-MAX) : raw
      term.clear()
      term.write(slice)
    } catch (_) {}
  }


  function colorLuminance(hex) {
    const n = parseInt(String(hex || '').replace('#', '').slice(0, 6), 16)
    if (isNaN(n)) return -1
    const r = (n >> 16) & 255
    const g = (n >> 8) & 255
    const b = n & 255
    return 0.299 * r + 0.587 * g + 0.114 * b
  }

  /** 浅色 override 不能进暗色终端（反之亦然）；否则暗色首屏被 #c1c5cd 压成发灰，要点设置 forceScheme 才恢复 */
  function resolveTermBgOverride(s, themeMode, { forceSchemeBackground = false } = {}) {
    if (forceSchemeBackground) return ''
    const userSet = s && s.termBgUserSet === true
    if (!userSet) return ''
    const raw = String((s && (s.termBgOverride || s.termBg)) || '').trim()
    if (!raw || raw[0] !== '#') return ''
    const mode = themeMode === 'light' ? 'light' : 'dark'
    const lum = colorLuminance(raw)
    if (lum < 0) return ''
    // 暗色主题：拒绝浅色/中灰 override（历史浅色模式粘住的 #c1c5cd / #e5e5ea 等）
    if (mode === 'dark' && lum >= 120) return ''
    // 浅色主题：拒绝纯黑/深色 override，避免浅色 UI 下终端黑成一团
    if (mode === 'light' && lum <= 70) return ''
    return raw
  }

  function scrubIncompatibleTermBgOverride(settings, themeMode, { persist = false } = {}) {
    const s = settings || state.settings || {}
    const mode = themeMode === 'light' ? 'light' : (themeMode === 'dark' ? 'dark' : (s.theme === 'light' ? 'light' : 'dark'))
    const raw = String(s.termBgOverride || s.termBg || '').trim()
    if (!raw) return false
    const lum = colorLuminance(raw)
    const bad =
      (mode === 'dark' && lum >= 120) ||
      (mode === 'light' && lum >= 0 && lum <= 70) ||
      // 历史默认浅灰，不是用户「暗色背景」意图
      (mode === 'dark' && ['#c1c5cd', '#e5e5ea', '#b8b8c2', '#d4d6dc', '#ececf1'].includes(raw.toLowerCase()))
    if (!bad) return false
    try {
      delete s.termBgOverride
      delete s.termBg
      s.termBgUserSet = false
      if (settings) Object.assign(settings, s)
      if (state.settings) {
        delete state.settings.termBgOverride
        delete state.settings.termBg
        state.settings.termBgUserSet = false
      }
    } catch (_) {}
    if (persist && hasApi && api.saveSettings) {
      try { api.saveSettings(state.settings).catch(() => {}) } catch (_) {}
    }
    return true
  }

  function paintTermBackgroundDom(bg) {
    const color = String(bg || '#0f1419')
    try {
      document.documentElement.style.setProperty('--term', color)
    } catch (_) {}
    const host = $('xtermHost')
    if (host) {
      host.style.background = color
      host.style.backgroundColor = color
    }
    // xterm 视口层有时盖住 canvas 间隙，必须同步
    document.querySelectorAll('.xterm-viewport, .xterm-screen, .xterm').forEach((el) => {
      try {
        el.style.backgroundColor = color
      } catch (_) {}
    })
  }

  async function applyTerminalAppearance(opts = {}) {
    if (!term) return
    const gen = ++_termAppearanceGen
    const s = { ...(state.settings || {}), ...(opts.settingsPatch || {}) }
    const fontFamily = withMonoI18n(s.fontFamily || DEFAULT_TERM_FONT_FAMILY)
    const cursorStyle = ['block', 'underline', 'bar'].includes(s.cursorStyle) ? s.cursorStyle : 'block'
    const cursorBlink = s.cursorBlink !== false
    try {
      term.options.fontFamily = fontFamily
      term.options.cursorStyle = cursorStyle
      term.options.cursorBlink = cursorBlink
      term.options.drawBoldTextInBrightColors = s.drawBoldTextInBrightColors !== false
      term.options.minimumContrastRatio = Number(s.minimumContrastRatio) > 0 ? Number(s.minimumContrastRatio) : 4.5
      if (s.fontWeight) term.options.fontWeight = s.fontWeight
      if (s.fontWeightBold) term.options.fontWeightBold = s.fontWeightBold
      // 保证可滚历史够长，滚动条才有意义
      if (Number(s.scrollback) > 0) term.options.scrollback = Number(s.scrollback)
      else if (!term.options.scrollback || term.options.scrollback < 1000) term.options.scrollback = 10000
    } catch (_) {}

    const schemeId = opts.schemeId || s.colorScheme || 'dracula'
    let theme = (await fetchSchemeTheme(schemeId)) || buildLocalFallbackTheme(s)
    theme = { ...(theme || {}) }
    // 背景优先级：
    // 1) 显式 ignoreOverride / 换配色时清掉 override → 用方案背景
    // 2) termBgOverride（右键设背景）压过方案
    // 3) 否则方案 background
    const uiTheme = (state?.settings?.theme === 'light' || s.theme === 'light') ? 'light' : 'dark'
    // 每次 apply 都 scrub：防止内存/磁盘粘滞浅灰在暗色路径复活
    try {
      scrubIncompatibleTermBgOverride(state.settings, uiTheme, { persist: true })
      if (state.settings) {
        s.termBgOverride = state.settings.termBgOverride
        s.termBg = state.settings.termBg
        s.termBgUserSet = state.settings.termBgUserSet
      }
    } catch (_) {}
    // 暗色且用户未锁定自定义背景：等同点开设置 forceScheme，首屏即用方案底
    const autoForceDark = uiTheme === 'dark' && s.termBgUserSet !== true
    const forceSchemeBg = !!opts.forceSchemeBackground || autoForceDark
    // 暗/浅色与 override 亮度不兼容时丢弃（修：暗色被浅灰 override 粘住，要点设置才正常）
    const override = resolveTermBgOverride(s, uiTheme, { forceSchemeBackground: forceSchemeBg })
    if (override) {
      theme.background = override
      theme.cursorAccent = override
    } else if (theme.background) {
      theme.cursorAccent = theme.cursorAccent || theme.background
    }
    // 规范化：xterm 需要完整 16 色对象，缺字段用 fallback 补
    const fb = buildLocalFallbackTheme({ termBg: theme.background })
    theme = { ...fb, ...theme, background: theme.background || fb.background }

    // 适配浅色模式：浅灰底 + 高对比深字。较早的中灰 #b8b8c2 太暗，把暗色高亮色压得
    // 与近黑正文难以区分（用户反馈「浅色看不出高亮」）；抬亮一档到 #d4d6dc，仍是明显
    // 灰底不刺眼，同时给高亮色留出彩度与亮度空间。
    if (state?.settings?.theme === 'light') {
      theme.background = '#d4d6dc'
      theme.foreground = '#0b0b0d'
      theme.cursor = '#0055d4'
      theme.cursorAccent = '#d4d6dc'
      theme.selectionBackground = 'rgba(0, 85, 212, 0.28)'
      theme.black = '#0b0b0d'
      theme.red = '#b00014'
      theme.green = '#0b6b2c'
      theme.yellow = '#9a4200'
      theme.blue = '#0b4db8'
      theme.magenta = '#6b2f9a'
      theme.cyan = '#0a6a78'
      theme.white = '#3a3a42'
      theme.brightBlack = '#4a4a52'
      theme.brightRed = '#d4001f'
      theme.brightGreen = '#0d8a38'
      theme.brightYellow = '#b84f00'
      theme.brightBlue = '#0d5fd4'
      theme.brightMagenta = '#8538c0'
      theme.brightCyan = '#0c8496'
      theme.brightWhite = '#0b0b0d'
    }

    // 保证前景/背景对比：绝不能同色（否则黑屏无字）
    if (!theme.foreground) theme.foreground = '#f8f8f2'
    if (!theme.background) theme.background = '#1e1f29'
    const lum = colorLuminance
    try {
      const bgLum = lum(theme.background)
      const fgLum = lum(theme.foreground)
      // 暗色模式：抬前景 + 抬低对比 ANSI（ciapre 等 vintage 方案字/色本身偏暗）
      if (uiTheme === 'dark' || bgLum < 90) {
        // 只在前景真的暗到读不清时才顶成近白，否则保留方案自身前景（避免所有方案都变一个样）。
        // 图例可读性由下方 minimumContrastRatio(>=7) 兜底，无需强行统一颜色。
        if (fgLum < 130) theme.foreground = '#f2f2f7'
        if (theme.cursor && lum(theme.cursor) < 120) theme.cursor = '#f2f2f7'
        if (theme.white && lum(theme.white) < 150) theme.white = '#e4e4ea'
        if (theme.brightWhite && lum(theme.brightWhite) < 200) theme.brightWhite = '#f7f7fa'
        if (theme.brightBlack && lum(theme.brightBlack) < 110) theme.brightBlack = '#a0a0a8'
        if (theme.black && lum(theme.black) < 70) theme.black = '#8a8a92'
        // 常规 8 色过暗时混一点浅色，避免 ls/git 等着色几乎看不见
        const boost = (hex, minLum, mix = 0.42) => {
          const L = lum(hex)
          if (L < 0 || L >= minLum) return hex
          const n = parseInt(String(hex).replace('#', '').slice(0, 6), 16)
          if (isNaN(n)) return hex
          const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255
          const R = Math.round(r + (255 - r) * mix)
          const G = Math.round(g + (255 - g) * mix)
          const B = Math.round(b + (255 - b) * mix)
          return '#' + [R, G, B].map((x) => x.toString(16).padStart(2, '0')).join('')
        }
        // 错误/警告优先：强制高饱和红 + 琥珀（参考常见 SSH 终端醒目告警色）
        // 不要只做同等 boost，否则 vintage 方案的 red 仍偏暗
        theme.red = '#ff2d20'
        theme.brightRed = '#ff453a'
        theme.yellow = '#ffcc00'
        theme.brightYellow = '#ffd426'
        // 只轻提亮过暗的着色（保留方案色相个性）；亮度由 minimumContrastRatio 兜底。
        for (const k of ['green', 'blue', 'magenta', 'cyan']) {
          if (theme[k]) theme[k] = boost(theme[k], 95, 0.2)
        }
        for (const k of ['brightGreen', 'brightBlue', 'brightMagenta', 'brightCyan']) {
          if (theme[k]) theme[k] = boost(theme[k], 120, 0.14)
        }
      }
      if (Math.abs(bgLum - lum(theme.foreground)) < 55) {
        theme.foreground = bgLum > 140 ? '#0b0b0d' : '#f2f2f7'
      }
      // 浅色模式已在上方强制高对比；此处兜底
      if (uiTheme === 'light' && bgLum > 140 && lum(theme.foreground) > 90) {
        theme.foreground = '#0b0b0d'
      }
    } catch (_) {}

    // 若在 await 期间又有更新的 apply，丢弃本次
    if (gen !== _termAppearanceGen) return

    // 字体未就绪时 xterm 会用错误 metrics 画「发虚/偏暗」字形；等 ready 再设 family
    try {
      if (document.fonts && document.fonts.ready) {
        await Promise.race([
          document.fonts.ready,
          new Promise((r) => setTimeout(r, 800)),
        ])
      }
      if (gen !== _termAppearanceGen) return
      if (document.fonts && fontFamily) {
        const primary = String(fontFamily).split(',')[0].trim().replace(/^["']|["']$/g, '')
        if (primary) {
          try {
            await Promise.race([
              document.fonts.load(`16px "${primary}"`),
              new Promise((r) => setTimeout(r, 600)),
            ])
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (gen !== _termAppearanceGen) return

    try {
      term.options.fontFamily = fontFamily
      term.options.theme = { ...theme }
      // 暗色默认抬高对比（ciapre 等方案靠 MCR 把着色字拉亮）；浅色 ≥4.5
      const mcr = Number(s.minimumContrastRatio)
      if (uiTheme === 'dark') {
        term.options.minimumContrastRatio = mcr >= 7 ? mcr : 7
      } else {
        term.options.minimumContrastRatio = mcr > 0 ? mcr : 4.5
      }
    } catch (_) {
      try {
        if (typeof term.setOption === 'function') {
          term.setOption('theme', { ...theme })
          term.setOption('fontFamily', fontFamily)
        }
      } catch (__) {}
    }

    state._activeTermTheme = theme
    paintTermBackgroundDom(theme.background)

    try {
      if (typeof term.refresh === 'function' && term.rows > 0) {
        term.refresh(0, Math.max(0, term.rows - 1))
      }
    } catch (_) {}
    try {
      ensureTermScrollbar()
    } catch (_) {}

    // 仅当 host 有有效尺寸时缩放字号（避免 w=1 h=1 把字压没）
    try {
      const host = $('xtermHost')
      if (host && host.clientWidth > 40 && host.clientHeight > 40) {
        applyTermFontScale()
      } else {
        fitAddon?.fit()
      }
    } catch (_) {
      try {
        fitAddon?.fit()
      } catch (__) {}
    }
    paintTermBackgroundDom(theme.background)
    try {
      ensureTermScrollbar()
    } catch (_) {}

    try {
      repaintActiveTermBuffer()
    } catch (_) {}

    try {
      rlog('info', 'term', 'appearance', {
        scheme: schemeId,
        bg: theme.background,
        fg: theme.foreground,
        override: override || null,
        forceSchemeBg,
        font: term.options.fontSize,
      })
    } catch (_) {}
  }


  function updateTermPreview(theme, fontFamily, fontSize) {
    const body = $('termPreviewBody')
    const wrap = $('termPreview')
    if (!body || !wrap) return
    const t = theme || state._activeTermTheme || buildLocalFallbackTheme(state.settings)
    wrap.style.background = t.background || '#1e1f29'
    body.style.background = t.background || '#1e1f29'
    body.style.color = t.foreground || '#f8f8f2'
    body.style.fontFamily = withMonoI18n(fontFamily || state.settings.fontFamily || DEFAULT_TERM_FONT_FAMILY)
    body.style.fontSize = (fontSize || state.settings.fontSize || 13) + 'px'
    const cur = t.cursor || '#bbb'
    body.innerHTML =
      `<span style="color:${t.green || '#50fa7b'}">user@host</span>` +
      `<span style="color:${t.foreground || '#eee'}">:</span>` +
      `<span style="color:${t.blue || '#bd93f9'}">~/proj</span>` +
      `<span style="color:${t.foreground || '#eee'}">$ ls -la</span>\n` +
      `<span style="color:${t.brightBlack || '#666'}">drwxr-xr-x</span> ` +
      `<span style="color:${t.cyan || '#8be9fd'}">src</span>  ` +
      `<span style="color:${t.yellow || '#f1fa8c'}">README.md</span>\n` +
      `<span style="color:${t.red || '#ff5555'}">err</span> ` +
      `<span style="color:${t.magenta || '#ff79c6'}">warn</span> ` +
      `<span style="color:${t.green || '#50fa7b'}">ok</span> ` +
      `<span style="background:${cur};color:${t.background || '#000'}"> </span>`
  }

  /**
   * 终端实时标记（运维向可读性增强：路径/IP/端口/时间/状态词等）
   * 只装饰纯文本段，保留远端已有 ANSI；默认无底色、亮前景。
   * 开关：settings.termLiveHighlight
   */
  function decorateOutput(raw) {
    if (raw == null) return ''
    const text = typeof raw === 'string' ? raw : String(raw)
    if (!text) return text
    const s = state.settings || {}
    if (s.termLiveHighlight === false) return text
    // 拆分已有 ANSI / OSC 序列，只装饰纯文本段
    const parts = text.split(/(\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[()][0-9A-B0-2]|\x1b[>=])/)
    let out = ''
    for (const part of parts) {
      if (!part) continue
      if (part.charCodeAt(0) === 0x1b) {
        out += part
        continue
      }
      // 全量装饰：严重级别词由 decoratePlainChunk 内的规则 17 统一上色，
      // 不再做前置替换（前置替换会短路整段装饰，导致同行的路径/IP 丢失高亮）。
      out += decoratePlainChunk(part)
    }
    return out
  }

  // 语义高亮色板：明暗各一套「定制 truecolor」，与配色方案解耦。
  // 之前「主题联动」(用方案 16 色 + minimumContrastRatio) 在浅色模式失败——多数方案是
  // 暗色向的淡彩，浅底上被 MCR 补成灰暗色，与近黑正文难分。改成手调 24 位真彩：
  //  · 浅色(底 #d4d6dc / 近黑字)：中偏深高彩度色，亮度+色相双向拉开与黑字的距离；
  //  · 深色(暗底 / 浅字)：高饱和亮色。
  // 关键角色(err/warn/ok)加粗以进一步凸显。tc()=前景真彩，tcb()=加粗+真彩。
  const _tc = (h) => {
    const n = parseInt(h.slice(1), 16)
    return '\x1b[38;2;' + ((n >> 16) & 255) + ';' + ((n >> 8) & 255) + ';' + (n & 255) + 'm'
  }
  const _tcb = (h) => '\x1b[1m' + _tc(h)
  const HL_LIGHT = {
    url: '\x1b[4m' + _tc('#0a6d8c'), // 青 + 下划线：链接
    path: _tc('#1553d6'),           // 蓝：文件/目录路径
    ip: _tc('#0a72a0'),             // 青：IP
    domain: _tc('#0a72a0'),         // 青：域名
    userhost: _tc('#4b3fd0'),       // 靛：user@host
    port: _tc('#1a7d2e'),           // 绿：端口
    mac: _tc('#9127bf'),            // 紫：MAC
    date: _tc('#5f6470'),           // 板岩灰：时间戳（次要）
    size: _tc('#b85c00'),           // 橙：大小/速率
    num: _tc('#5f6470'),            // 板岩灰：数字
    hex: _tc('#9127bf'),            // 紫：hash/十六进制
    perm: _tc('#1a7d2e'),           // 绿：权限位
    err: _tcb('#e00020'),           // 加粗红：错误
    warn: _tcb('#a85a00'),          // 加粗琥珀：警告
    ok: _tcb('#127a34'),            // 加粗绿：成功
    kw: _tc('#b21ab0'),             // 品红：运维关键词
    delim: _tc('#6a6f7a'),          // 灰：括号
  }
  const HL_DARK = {
    url: '\x1b[4m' + _tc('#5cd6e8'), // 亮青 + 下划线：链接
    path: _tc('#6aa8ff'),           // 亮蓝：文件/目录路径
    ip: _tc('#4fd0e0'),             // 亮青：IP
    domain: _tc('#4fd0e0'),         // 亮青：域名
    userhost: _tc('#a99bff'),       // 亮靛：user@host
    port: _tc('#5fe08a'),           // 亮绿：端口
    mac: _tc('#ff86d4'),            // 亮品红：MAC
    date: _tc('#9aa0ac'),           // 灰：时间戳（次要）
    size: _tc('#ffb340'),           // 琥珀：大小/速率
    num: _tc('#9aa0ac'),            // 灰：数字
    hex: _tc('#ff86d4'),            // 亮品红：hash/十六进制
    perm: _tc('#5fe08a'),           // 亮绿：权限位
    err: _tcb('#ff5a4d'),           // 加粗亮红：错误
    warn: _tcb('#ffc233'),          // 加粗琥珀：警告
    ok: _tcb('#57e08a'),            // 加粗亮绿：成功
    kw: _tc('#d79bff'),             // 亮紫：运维关键词
    delim: _tc('#8a90a0'),          // 灰：括号
  }

  function decoratePlainChunk(chunk) {
    // 私有区占位，禁止 <<Hn>> 泄漏；replaceSafe 跳过已占位区间防嵌套
    const slots = []
    const SO = ''
    const EO = ''
    const put = (s, kind) => {
      const i = slots.length
      slots.push({ s, kind })
      return SO + i + EO
    }
    const replaceSafe = (str, re, kindOrFn) => {
      const markerRe = new RegExp(SO + '(\\d+)' + EO, 'g')
      const full = String(str)
      const parts = []
      let m
      let idx = 0
      markerRe.lastIndex = 0
      while ((m = markerRe.exec(full))) {
        if (m.index > idx) parts.push({ t: full.slice(idx, m.index), mark: false })
        parts.push({ t: m[0], mark: true })
        idx = m.index + m[0].length
      }
      if (idx < full.length) parts.push({ t: full.slice(idx), mark: false })
      if (!parts.length) parts.push({ t: full, mark: false })
      return parts
        .map((p) => {
          if (p.mark) return p.t
          if (typeof kindOrFn === 'function') return p.t.replace(re, kindOrFn)
          return p.t.replace(re, (mm) => put(mm, kindOrFn))
        })
        .join('')
    }

    let s = String(chunk)
    // ── 顺序：长/特殊优先，避免被短规则拆碎 ──
    // 1) URL（含 ftp/ssh/ws）
    s = replaceSafe(s, /(?:https?|ftp|sftp|ssh|wss?):\/\/[^\s<>"'`]+/gi, 'url')
    // 2) *** 警告块
    s = replaceSafe(s, /\*{2,}[^*\n]+\*{2,}/g, 'warn')
    // 3) Unix 权限位（ls -l 首列）
    s = replaceSafe(s, /(?:^|[\s|])([dlsbcps-](?:[r-][w-][xsStT-]){3})(?=[\s|]|$)/gm, (m, p1) => {
      const i = m.indexOf(p1)
      if (i <= 0) return put(m, 'perm')
      return m.slice(0, i) + put(p1, 'perm')
    })
    // 4) 绝对路径 / 家目录路径（至少两段或明确文件名）
    s = replaceSafe(
      s,
      /(?:^|[\s"'`=,:([])((?:\/(?:[\w.+@$-]+\/)+[\w.+@$-]*|\/[\w.+@$-]{2,}|(?:~|\$HOME)(?:\/[\w.+@$-]+)+))(?=[\s"'`),;:]|$)/gm,
      (m, p1) => {
        const i = m.indexOf(p1)
        if (i < 0) return put(m, 'path')
        return m.slice(0, i) + put(p1, 'path')
      },
    )
    // 5) MAC
    s = replaceSafe(s, /\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b/g, 'mac')
    // 6) IPv4 可选 :端口
    s = replaceSafe(
      s,
      /\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?::\d{1,5})?\b/g,
      'ip',
    )
    // 7) [IPv6]:port
    s = replaceSafe(s, /\[(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}\]:\d{1,5}/g, 'ip')
    // 8) 裸 IPv6（至少两枚冒号）
    s = replaceSafe(
      s,
      /\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{0,4}\b|\b(?:[0-9A-Fa-f]{1,4}:){1,7}:|::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}\b/g,
      (m) => {
        if (m.length < 3 || !m.includes(':')) return m
        const colons = (m.match(/:/g) || []).length
        if (colons < 2) return m
        return put(m, 'ip')
      },
    )
    // 9) user@host
    s = replaceSafe(
      s,
      /\b([a-zA-Z_][\w.-]*@[a-zA-Z0-9][\w.-]*\.[a-zA-Z]{2,}|[a-zA-Z_][\w.-]*@[a-zA-Z0-9][\w.-]+)\b/g,
      'userhost',
    )
    // 10) 域名 / FQDN
    s = replaceSafe(
      s,
      /\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+(?:com|net|org|io|dev|app|cn|jp|edu|gov|local|internal|lan|test|xyz|cloud|ai|co|me|info|biz|tech)(?::\d{1,5})?\b/gi,
      'domain',
    )
    // 11) *:PORT / * PORT
    s = replaceSafe(s, /\*(?::|\s)\d{2,5}\b/g, 'port')
    // 12) 独立 :PORT（1–65535；前不接 hex/冒号）
    s = replaceSafe(s, /(?<![0-9A-Fa-f:]):([1-9]\d{0,4})\b/g, (m, p1) => {
      const n = parseInt(p1, 10)
      if (!Number.isFinite(n) || n < 1 || n > 65535) return m
      return put(m, 'port')
    })
    // 13) 时间戳
    s = replaceSafe(
      s,
      /\b\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?\b/g,
      'date',
    )
    s = replaceSafe(
      s,
      /\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}(?::\d{2})?\b/g,
      'date',
    )
    s = replaceSafe(s, /\b\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?\b/g, 'date')
    // 14) 文件大小 / 速率
    s = replaceSafe(s, /\b\d+(?:\.\d+)?\s?(?:[KMGTPE]i?B?|[kmgtpe]i?b?)(?:\/s)?\b/g, 'size')
    // 15) 十六进制 / hash
    s = replaceSafe(s, /\b0x[0-9A-Fa-f]{2,}\b/g, 'hex')
    s = replaceSafe(s, /\b[0-9a-f]{8,40}\b/gi, (m) => {
      if (/^\d+$/.test(m)) return m
      return put(m, 'hex')
    })
    // 16) HTTP 状态码
    s = replaceSafe(s, /\b(?:HTTP\/\d\.\d\s+)?([1-5]\d{2})\b(?=\s|$|[,;)\]}])/g, (m, code) => {
      const n = parseInt(code, 10)
      if (n >= 500) return put(m, 'err')
      if (n >= 400) return put(m, 'warn')
      if (n >= 200 && n < 300) return put(m, 'ok')
      return put(m, 'num')
    })
    // 17) 错误 / 警告（中英）
    s = replaceSafe(
      s,
      /\b(?:error|errors|fail(?:ed|ure|ures)?|fatal|critical|exception|denied|refused|panic|traceback|segfault|oom|killed|unable|cannot|can't|not found|no such|permission denied|connection refused|timed?\s*out|timeout|unauthorized|forbidden|invalid|corrupt(?:ed)?|broken|crash(?:ed)?)\b/gi,
      'err',
    )
    s = replaceSafe(s, /(?:错误|失败|异常|崩溃|拒绝|超时|未找到|无权限|权限不足|连接拒绝|致命)/g, 'err')
    s = replaceSafe(
      s,
      /\b(?:warn(?:ing|ings)?|deprecated|caution|notice|restart required|system restart required)\b/gi,
      'warn',
    )
    s = replaceSafe(s, /(?:警告|注意|弃用|即将过期)/g, 'warn')
    // 18) 成功词
    s = replaceSafe(
      s,
      /\b(?:ok|okay|success(?:ful(?:ly)?)?|done|ready|passed|complete(?:d)?|enabled|active|running|listening|connected|online|healthy|available)\b/gi,
      'ok',
    )
    s = replaceSafe(s, /(?:成功|完成|就绪|已连接|正常|在线|健康)/g, 'ok')
    // 19) 占用百分比
    s = replaceSafe(s, /\b(9\d(?:\.\d+)?%)\b/g, 'err')
    s = replaceSafe(s, /\b(8\d(?:\.\d+)?%)\b/g, 'warn')
    s = replaceSafe(s, /\b([1-7]?\d(?:\.\d+)?%)\b/g, 'num')
    // 20) 常见运维关键词
    s = replaceSafe(
      s,
      /\b(?:sudo|systemctl|journalctl|docker|kubectl|nginx|redis|mysql|postgres|ssh|scp|rsync|chmod|chown|mount|umount|iptables|firewalld|cron|systemd)\b/g,
      'kw',
    )
    // 21) 括号字符轻量着色（delimiter 可见性）
    s = replaceSafe(s, /[()[\]{}]/g, 'delim')

    // 语义高亮：按当前明暗模式选定制真彩色板（见上方 HL_LIGHT / HL_DARK）。
    const color = state?.settings?.theme === 'light' ? HL_LIGHT : HL_DARK
    const reset = '\x1b[0m'
    let guard = 0
    const expandRe = new RegExp(SO + '(\\d+)' + EO, 'g')
    while (expandRe.test(s) && guard++ < 24) {
      expandRe.lastIndex = 0
      s = s.replace(expandRe, (_, n) => {
        const item = slots[Number(n)]
        if (!item) return ''
        return (color[item.kind] || '\x1b[1;36m') + item.s + reset
      })
    }
    s = s.replace(new RegExp(SO + '\\d+' + EO, 'g'), '')
    return s
  }


  function appendBuf(sessionId, text) {
    let b = termBuffers.get(sessionId) || ''
    b += text
    if (b.length > MAX_BUF) b = b.slice(-MAX_BUF)
    termBuffers.set(sessionId, b)
  }

  function writeActive(sessionId, text) {
    const painted = decorateOutput(text)
    appendBuf(sessionId, painted)
    if (switching || !term) return
    const t = currentTab()
    // term tab with matching sessionId, or active term tab still connecting with same id
    if (t && t.type === 'term' && t.sessionId === sessionId) {
      term.write(painted)
      return
    }
    // fallback: if only one term tab holds this sessionId, still paint
    const owner = state.tabs.find((x) => x.sessionId === sessionId && x.type === 'term')
    if (owner && owner.id === state.activeTabId) term.write(painted)
  }

  /** SSH 连接动画（替代终端 Connecting 文本） */
  let _connectOverlayTimer = null
  let _connectOverlayToken = 0
  let _connectOverlaySessionId = null

  function showConnectOverlay(user, host, port, sessionId) {
    const el = $('connectOverlay')
    if (!el) return
    if (_connectOverlayTimer) {
      clearTimeout(_connectOverlayTimer)
      _connectOverlayTimer = null
    }
    const token = ++_connectOverlayToken
    _connectOverlaySessionId = sessionId || null
    el.dataset.token = String(token)
    el.classList.remove('is-ok', 'is-fail')
    el.hidden = false
    el.removeAttribute('hidden')
    if ($('connectOverlayTitle')) $('connectOverlayTitle').textContent = '正在连接'
    if ($('connectOverlaySub')) {
      $('connectOverlaySub').textContent = (user || 'root') + '@' + (host || '') + ':' + (port || 22)
    }
    // 安全阀：超过 readyTimeout+缓冲 仍未 hide 则强制关掉，避免“失败也一直转”
    _connectOverlayTimer = setTimeout(() => {
      if (el.dataset.token === String(token) && !el.hidden) {
        if ($('connectOverlayTitle')) $('connectOverlayTitle').textContent = '连接超时'
        el.classList.add('is-fail')
        hideConnectOverlay(false, { reason: 'watchdog' })
      }
    }, 45000)
  }

  /**
   * 关掉连接动画。失败立即关；成功短闪“已连接”。
   * 用 token 取消过期 timer，避免 hide(true) 的延迟把新一轮连接动画误关，
   * 或失败后仍残留遮罩。
   */
  function hideConnectOverlay(ok, opts) {
    opts = opts || {}
    const el = $('connectOverlay')
    if (!el) return
    if (_connectOverlayTimer) {
      clearTimeout(_connectOverlayTimer)
      _connectOverlayTimer = null
    }
    const token = el.dataset.token || String(_connectOverlayToken)
    if (ok) {
      el.classList.remove('is-fail')
      el.classList.add('is-ok')
      if ($('connectOverlayTitle')) $('connectOverlayTitle').textContent = '已连接'
      _connectOverlayTimer = setTimeout(() => {
        if (el.dataset.token !== token) return
        el.hidden = true
        el.setAttribute('hidden', '')
        el.classList.remove('is-ok', 'is-fail')
        _connectOverlaySessionId = null
      }, 220)
    } else {
      // 失败 / 取消 / 关 tab：立刻拿掉遮罩，绝不卡死 UI
      if (opts.showFail && $('connectOverlayTitle')) {
        $('connectOverlayTitle').textContent = opts.title || '连接失败'
        el.classList.add('is-fail')
      }
      el.hidden = true
      el.setAttribute('hidden', '')
      el.classList.remove('is-ok', 'is-fail')
      _connectOverlaySessionId = null
    }
  }
  function updateBrandForSession() {
    const hasLive = (state.tabs || []).some((t) => t.status === 'connected' && t.sessionId)
    document.body.classList.toggle('is-session', !!hasLive)
    const btn = $('btnConnMgr')
    if (btn) btn.title = hasLive ? '连接管理器（切换主机）' : '连接管理器'
    // 版本号固定在状态栏左下（CLI 上方），不放标题栏
    const verEl = $('appVersion')
    if (verEl && !verEl.dataset.locked) {
      // 主进程可覆盖；默认用构建注入 / package 版本
      const v = state.appVersion || verEl.textContent.replace(/^PixShell\s*/i, '').trim() || '0.1.0'
      verEl.textContent = String(v).replace(/^PixShell\s*/i, '')
    }
  }

  function setAppVersionLabel(version) {
    const v = String(version || '').trim().replace(/^PixShell\s*/i, '')
    if (!v) return
    state.appVersion = v
    const verEl = $('appVersion')
    if (verEl) {
      // 侧栏品牌区只显示版本号；名称在 .sidebar-brand-name
      verEl.textContent = v
      verEl.dataset.locked = '1'
    }
    const nameEl = document.querySelector('.sidebar-brand-name')
    if (nameEl) nameEl.textContent = 'PixShell'
    paintBrandUpdateDot()
  }

  const PIXSHELL_REPO_URL = 'https://github.com/lyu0805/pixshell'
  const PIXSHELL_RELEASES_URL = 'https://github.com/lyu0805/pixshell/releases'

  function paintBrandUpdateDot() {
    const brand = $('sidebarBrand')
    const dot = $('brandUpdateDot')
    const st = state.updateStatus || 'checking'
    const info = state.updateInfo || null
    const ver = state.appVersion || ($('appVersion')?.textContent || '0.1.0')
    if (dot) {
      dot.dataset.state = st
      dot.classList.remove('on', 'off', 'err', 'warn')
      if (st === 'latest') dot.classList.add('on')
      else if (st === 'update-available') dot.classList.add('off')
      else if (st === 'error') dot.classList.add('err')
      else if (st === 'checking' || st === 'none' || st === 'unknown') dot.classList.add('warn')
    }
    if (brand) {
      let tip = 'PixShell ' + ver
      if (st === 'update-available' && info?.latestVersion) {
        tip = `有新版本 ${info.latestVersion}（当前 ${ver}）· 点击打开发行页`
      } else if (st === 'latest') {
        tip = `已是最新版本 ${ver} · 点击打开发行页`
      } else if (st === 'checking') {
        tip = `PixShell ${ver} · 正在检查更新…`
      } else if (st === 'none') {
        tip = `PixShell ${ver} · 暂无发行版 · 点击打开仓库发行页`
      } else if (st === 'error') {
        tip = `PixShell ${ver} · 更新检查失败 · 点击打开发行页`
      } else {
        tip = `PixShell ${ver} · 点击打开发行页`
      }
      brand.title = tip
      brand.setAttribute('aria-label', tip)
    }
  }

  async function openPixShellReleases() {
    try {
      if (hasApi && typeof api.openReleases === 'function') {
        const r = await api.openReleases()
        if (r && r.ok) return true
      }
      if (hasApi && typeof api.openExternal === 'function') {
        await api.openExternal(PIXSHELL_RELEASES_URL)
        return true
      }
    } catch (_) {}
    try {
      window.open(PIXSHELL_RELEASES_URL, '_blank', 'noopener,noreferrer')
      return true
    } catch (_) {
      return false
    }
  }

  async function openPixShellRepo() {
    try {
      if (hasApi && typeof api.openRepo === 'function') {
        const r = await api.openRepo()
        if (r && r.ok) return true
      }
      if (hasApi && typeof api.openExternal === 'function') {
        await api.openExternal(PIXSHELL_REPO_URL)
        return true
      }
    } catch (_) {}
    try {
      window.open(PIXSHELL_REPO_URL, '_blank', 'noopener,noreferrer')
      return true
    } catch (_) {
      return false
    }
  }

  async function checkAppUpdate(opts = {}) {
    const silent = !!opts.silent
    if (!hasApi || typeof api.checkForUpdate !== 'function') {
      state.updateStatus = 'unknown'
      state.updateInfo = null
      paintBrandUpdateDot()
      if (!silent) toast('当前环境无法检查更新', true)
      return null
    }
    if (state._updateCheckInflight) return state._updateCheckInflight
    state.updateStatus = state.updateStatus === 'update-available' ? state.updateStatus : 'checking'
    paintBrandUpdateDot()
    state._updateCheckInflight = (async () => {
      try {
        const r = await api.checkForUpdate()
        state.updateInfo = r || null
        if (!r) {
          state.updateStatus = 'error'
        } else if (r.updateAvailable) {
          state.updateStatus = 'update-available'
        } else if (r.status === 'latest' || (r.ok && r.latestVersion && !r.updateAvailable)) {
          state.updateStatus = 'latest'
        } else if (r.status === 'none') {
          // 仓库尚无发行版：视为当前已是最新（绿灯），避免误报红灯
          state.updateStatus = 'latest'
        } else if (r.ok === false || r.status === 'error') {
          state.updateStatus = 'error'
        } else {
          state.updateStatus = r.status || 'unknown'
        }
        if (r?.currentVersion) setAppVersionLabel(r.currentVersion)
        else paintBrandUpdateDot()
        return r
      } catch (e) {
        state.updateStatus = 'error'
        state.updateInfo = {
          ok: false,
          status: 'error',
          error: String(e && e.message || e),
          message: '检查更新失败',
        }
        paintBrandUpdateDot()
        if (!silent) toast('检查更新失败: ' + (e && e.message ? e.message : e), true)
        return state.updateInfo
      } finally {
        state._updateCheckInflight = null
        paintBrandUpdateDot()
      }
    })()
    return state._updateCheckInflight
  }

  async function runSoftwareUpdate({ fromMenu = false } = {}) {
    if (!hasApi) {
      toast('请用 node start.js 启动 Electron', true)
      return
    }
    toast(fromMenu ? '正在检查软件更新…' : '正在检查更新…')
    const info = (await checkAppUpdate({ silent: true })) || state.updateInfo
    if (!info) {
      toast('检查更新失败', true)
      return
    }
    if (info.ok === false && info.status === 'error') {
      toast(info.message || ('检查更新失败: ' + (info.error || '')), true)
      try { await openPixShellReleases() } catch (_) {}
      return
    }
    if (!info.updateAvailable) {
      if (info.status === 'none') {
        toast(info.message || '暂无发行版，已打开发行页')
        await openPixShellReleases()
        return
      }
      toast(info.message || `已是最新版本 ${info.currentVersion || state.appVersion || ''}`.trim())
      return
    }
    // 有新版本 → 自动下载（无安装包则打开页面）
    toast(`发现新版本 ${info.latestVersion || ''}，开始下载…`.trim())
    try {
      if (typeof api.downloadUpdate !== 'function') {
        await openPixShellReleases()
        toast('已打开发行页，请手动下载更新')
        return
      }
      const r = await api.downloadUpdate(info)
      if (r?.downloaded) {
        toast(r.message || `已下载 ${r.name || '安装包'}`)
        return
      }
      if (r?.skipped && r.reason === 'latest') {
        toast(r.message || '已是最新版本')
        return
      }
      if (r?.skipped && r.reason === 'no-asset') {
        toast(r.message || '暂无当前平台安装包，已打开发行页')
        return
      }
      if (r?.ok === false) {
        toast(r.message || ('下载失败: ' + (r.error || '')), true)
        await openPixShellReleases()
        return
      }
      toast(r?.message || '更新处理完成')
    } catch (e) {
      toast('下载更新失败: ' + (e && e.message ? e.message : e), true)
      try { await openPixShellReleases() } catch (_) {}
    }
  }

  function handleCdLine(line) {
    // Terminal typed `cd` → refresh SFTP browser to same path (SFTP list, not shell ls)
    const t = sessionTab()
    if (!t || !/^cd(?:\s+|$)/.test(line.trim())) return
    if (state.settings.syncDirWithSftp === false) return
    const mm = line.trim().match(/^cd\s*(.*)$/)
    if (!mm) return
    let target = (mm[1] || '').trim().replace(/^['"]|['"]$/g, '')
    if (target.startsWith('-') && target !== '-') return
    let next
    if (!target || target === '~' || target === '~/') next = '/root' // best-effort; user can open /
    else if (target.startsWith('/')) next = target
    else next = (typeof sftpJoin === 'function' ? sftpJoin : joinRemote)(t.sftpPath || '/', target)
    if (next === t.sftpPath) return
    t.sftpPath = next
    setTimeout(() => refreshSftp(), 350)
  }

  // ── tabs ───────────────────────────────────────────────
  function renderTabs() {
    const root = $('tabs')
    if (!root) return
    root.innerHTML =
      state.tabs
        .map((t) => {
          const active = t.id === state.activeTabId ? 'active' : ''
          const conn = t.status === 'connected' ? 'connected' : ''
          return `<div class="tab ${active} ${conn}" data-id="${esc(t.id)}" draggable="true">
            <span class="dot"></span>
            <span>${esc(t.title)}</span>
            <button type="button" class="close" data-close="${esc(t.id)}">×</button>
          </div>`
        })
        .join('') + `<button type="button" class="tab-add" id="tabAdd">+</button>`
    root.querySelectorAll('.tab[data-id]').forEach((node) => {
      node.addEventListener('click', (e) => {
        if (e.target.closest('[data-close]')) return
        switchTab(node.dataset.id)
      })
      node.addEventListener('dragstart', (e) => {
        e.dataTransfer.setData('text/plain', node.dataset.id)
        e.dataTransfer.effectAllowed = 'copyMove'
      })
      node.addEventListener('dragend', (e) => {
        // 如果拖放被阻止或释放到窗口外，dropEffect 是 none
        if (e.dataTransfer.dropEffect === 'none' || e.clientY > window.innerHeight || e.clientY < 0 || e.clientX < 0 || e.clientX > window.innerWidth) {
          if (hasApi && api.newMainWindow) {
             api.newMainWindow()
          }
        }
      })
    })
    root.querySelectorAll('[data-close]').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation()
        closeTab(btn.dataset.close)
      })
    })
    const add = $('tabAdd')
    if (add) add.onclick = () => openQuickConnectTab()
    try { fillCmdTargets() } catch (_) {}
  }

  function showContent(mode) {
    // mode: term | quick | tool | sysinfo | hosts
    if (typeof restorePageHostBrowserId === 'function') restorePageHostBrowserId()
    const setH = (id, hide) => {
      const el = $(id)
      if (!el) return
      el.hidden = hide
      if (hide) el.setAttribute('hidden', '')
      else el.removeAttribute('hidden')
    }
    setH('xtermHost', mode !== 'term')
    setH('quickConnect', mode !== 'quick')
    setH('toolHost', mode !== 'tool')
    setH('sysInfoHost', mode !== 'sysinfo')
    const hb = $('hostBrowser')
    if (hb && !hb.closest('#connMgrModal')) {
      hb.hidden = mode !== 'hosts'
      if (mode !== 'hosts') hb.setAttribute('hidden', '')
      else hb.removeAttribute('hidden')
    }
  }

  function setChromeCompact(compact) {
    const center = document.querySelector('.work-center')
    state.chromeCompact = !!compact
    if (!center) return
    center.classList.toggle('chrome-compact', !!compact)
    if (compact) {
      center.style.gridTemplateRows = ''
      setBottomCollapsed(true)
    } else {
      const bh = (state.settings && state.settings.layout && state.settings.layout.bottomHeight) || 200
      if (state.bottomCollapsed) {
        center.style.gridTemplateRows = '1fr var(--cmd-h) 0 0'
      } else {
        center.style.gridTemplateRows = '1fr var(--cmd-h) 4px ' + bh + 'px'
        document.documentElement.style.setProperty('--bottom-h', bh + 'px')
      }
    }
    try { fitAddon && fitAddon.fit && fitAddon.fit() } catch (_) {}
  }

  function applyChromeForTab(tab) {
    if (!tab) return
    if (tab.type === 'quick' || tab.type === 'hosts') {
      setSidebarCollapsed(true)
      setChromeCompact(true)
      return
    }
    if (tab.type === 'tool' || tab.type === 'sysinfo' || tab.type === 'process' || tab.type === 'network' || tab.type === 'route') {
      setChromeCompact(true)
      return
    }
    setChromeCompact(false)
    if (tab.type === 'term' && tab.sessionId && tab.status === 'connected') {
      setSidebarCollapsed(false)
      setBottomCollapsed(false)
    }
  }

  async function switchTab(id) {
    const tab = state.tabs.find((t) => t.id === id)
    if (!tab) return
    state.activeTabId = id
    if (tab.hostId) state.activeHostId = tab.hostId
    switching = true
    try {
      if (tab.type === 'term') {
        showContent('term')
        if (tab.sessionId) {
          const has = termBuffers.has(tab.sessionId)
          const buf = has ? (termBuffers.get(tab.sessionId) || '') : ''
          hardResetTerminalViewport()
          if (buf) {
            const step = 8000
            for (let bi = 0; bi < buf.length; bi += step) term?.write(buf.slice(bi, bi + step))
          } else if (!has) {
            termBuffers.set(tab.sessionId, '')
          }
        } else {
          hardResetTerminalViewport()
        }
        fitAddon?.fit()
        if (tab.sessionId && hasApi) {
          try {
            await api.resize(tab.sessionId, term?.cols || 80, term?.rows || 24)
          } catch (_) {}
        }
        await refreshSftp()
        if (tab.sessionId && tab.status === 'connected') startMonitor()
      } else if (tab.type === 'hosts') {
        showContent('hosts')
        renderHostBrowser()
      } else if (tab.type === 'quick') {
        showContent('quick')
        renderQuickConnect()
      } else if (tab.type === 'process' || tab.type === 'network' || tab.type === 'route') {
        showContent('tool')
        await renderToolTab(tab)
      } else if (tab.type === 'sysinfo') {
        showContent('sysinfo')
        await fillSysInfo(tab)
      }
      applyChromeForTab(tab)
    } finally {
      switching = false
    }
    renderTabs()
    renderStatus()
  }


  // ── 主机列表（独立页，非快速连接历史） ─────────────────
  function restorePageHostBrowserId() {
    document.querySelectorAll('#connMgrModal #hostBrowser, #connMgrListMount').forEach((el) => {
      if (el.id === 'hostBrowser') el.id = 'connMgrListMount'
    })
    const page = document.getElementById('hostBrowserPage')
    if (page) page.id = 'hostBrowser'
    const mains = [...document.querySelectorAll('.host-browser')].filter(
      (el) => !el.closest('#connMgrModal') && !el.closest('#floatRoot') && !el.closest('.modal'),
    )
    if (mains.length) {
      const main = mains[0]
      if (main.id !== 'hostBrowser') main.id = 'hostBrowser'
    }
  }

  function ensureConnMgrListMount() {
    const mask = $('connMgrModal')
    const mgrBody = mask?.querySelector('.conn-mgr-body')
    if (!mgrBody) return null
    // 绝不能把列表塞进 <table>：会触发表格匿名盒修复，文字竖排叠成一团
    const table = mgrBody.querySelector('table.conn-table')
    if (table) {
      table.hidden = true
      table.style.display = 'none'
      table.setAttribute('aria-hidden', 'true')
    }
    const tbody = $('connMgrBody')
    if (tbody) {
      tbody.hidden = true
      tbody.style.display = 'none'
    }
    let mount = document.getElementById('connMgrListMount')
    if (mount && mount.parentElement !== mgrBody) {
      // 从 table 内错误挂载点挪到 .conn-mgr-body
      try {
        mount.remove()
      } catch (_) {}
      mount = null
    }
    if (!mount) {
      mount = document.createElement('div')
      mount.id = 'connMgrListMount'
      mount.className = 'host-browser conn-mgr-list-mount'
      mgrBody.appendChild(mount)
    }
    mount.hidden = false
    mount.style.display = 'flex'
    mount.style.flex = '1 1 auto'
    mount.style.minHeight = '0'
    mount.style.overflow = 'auto'
    mount.style.position = 'relative'
    mount.style.flexDirection = 'column'
    return mount
  }

  async function openConnMgr() {
    // 默认：独立桌面窗（可拖任意屏幕，不挡 SSH）
    restorePageHostBrowserId()
    // 关掉页内旧浮层（若有）
    try {
      showModal('connMgrModal', false)
    } catch (_) {}
    if (hasApi && typeof api.openFloatWindow === 'function') {
      const r = await openIndependentFloat({
        kind: 'conn-mgr',
        id: 'conn-mgr',
        title: '连接管理器',
        width: 560,
        height: 480,
        init: {
          hosts: (state.hosts || []).map((h) => ({
            id: h.id,
            name: h.name,
            host: h.host,
            port: h.port,
            username: h.username,
            group: h.group,
            deleted: h.deleted,
          })),
        },
      })
      if (r && r.ok) return
    }
    // 兜底：无 Electron 时用页内浮层
    const mask = $('connMgrModal')
    if (!mask) {
      const exist = state.tabs.find((t) => t.type === 'hosts')
      if (exist) {
        switchTab(exist.id)
        return
      }
      const tab = {
        id: 'tab_hosts_' + Date.now().toString(36),
        type: 'hosts',
        title: '主机列表',
        status: 'idle',
        hostId: null,
        sessionId: null,
        sftpPath: '/',
      }
      state.tabs.push(tab)
      switchTab(tab.id)
      return
    }
    mask.classList.add('float-modal-mask')
    showModal('connMgrModal', true)
    const win = mask.querySelector('.modal')
    if (win && typeof enableModalDrag === 'function') {
      enableModalDrag(win, { kind: 'conn-mgr', title: '连接管理器' })
    }
    const mount = ensureConnMgrListMount()
    if (mount) renderHostBrowserInto(mount)
    else if (typeof renderConnMgr === 'function') renderConnMgr()
  }

  function renderHostBrowserInto(root) {
    if (!root) return
    if (!state.hbCollapsed) state.hbCollapsed = new Set()
    const q = (state.hostBrowserFilter || '').toLowerCase()
    let list = state.hosts.filter((h) => !h.deleted)
    if (q) {
      list = list.filter(
        (h) =>
          (h.name || '').toLowerCase().includes(q) ||
          (h.host || '').toLowerCase().includes(q) ||
          (h.group || '').toLowerCase().includes(q) ||
          (h.username || '').toLowerCase().includes(q),
      )
    }
    const groups = new Map()
    for (const h of list) {
      const g = ((h.group || '默认') + '').trim() || '默认'
      if (!groups.has(g)) groups.set(g, [])
      groups.get(g).push(h)
    }
    const groupNames = [...groups.keys()].sort((a, b) => {
      if (a === '默认') return 1
      if (b === '默认') return -1
      return a.localeCompare(b, 'zh')
    })
    const rowHtml = (h) => {
      const title = h.name || h.host || '未命名'
      const user = h.username || 'root'
      const host = h.host || '-'
      const port = h.port || 22
      const hasPw = !!(h.password || passwordVault.get(h.id))
      const sel = h.id === state.activeHostId || h.id === state.mgrSelectedId ? ' selected' : ''
      const letter = String(title).trim().charAt(0).toUpperCase() || 'S'
      // 纯 flex 横排一行，禁止嵌套 table 相关类，避免竖排叠字
      return `<article class="hb-row${sel}" data-id="${esc(h.id)}" tabindex="0" role="button" title="双击连接">
        <div class="qc-avatar hb-row-avatar" aria-hidden="true">${hostAvatarImg(h)}</div>
        <div class="hb-row-main">
          <div class="hb-row-title">${esc(title)}</div>
          <div class="hb-row-sub">${esc(user)}@${esc(host)}:${esc(port)}</div>
        </div>
        <div class="hb-row-meta">
          <span class="qc-pill">${esc(port)}</span>
          <span class="qc-pill ${hasPw ? 'ok' : 'muted'}">${hasPw ? '密' : '无密'}</span>
        </div>
        <div class="hb-row-actions">
          <button type="button" class="cmd-btn primary" data-hb="connect" data-id="${esc(h.id)}">连接</button>
          <button type="button" class="cmd-btn" data-hb="edit" data-id="${esc(h.id)}">编辑</button>
          <button type="button" class="cmd-btn" data-hb="del" data-id="${esc(h.id)}">删除</button>
        </div>
      </article>`
    }
    let htmlOut = `<div class="hb-toolbar">
      <button type="button" class="mini-btn" data-hb-act="new">新建主机</button>
      <button type="button" class="mini-btn" data-hb-act="new-group">新建分组</button>
      <button type="button" class="mini-btn" data-hb-act="expand">全部展开</button>
      <button type="button" class="mini-btn" data-hb-act="collapse">全部折叠</button>
      <button type="button" class="mini-btn" data-hb-act="refresh">刷新</button>
      <input type="search" class="thin-input hb-filter" placeholder="搜索主机…" style="width:160px;margin-left:4px" value="${esc(state.hostBrowserFilter || '')}" />
      <span class="sb-spacer"></span>
      <span class="hb-count">${list.length} 台 · ${groupNames.length} 组</span>
    </div><div class="hb-body"><div class="hb-groups">`
    if (!list.length) {
      htmlOut += '<div class="hb-empty">暂无主机。点「新建主机」添加。</div>'
    } else {
      for (const g of groupNames) {
        const items = groups.get(g) || []
        const collapsed = state.hbCollapsed.has(g)
        htmlOut += `<section class="hb-group${collapsed ? ' collapsed' : ''}" data-group="${esc(g)}">
          <button type="button" class="hb-group-head" data-hb-group="${esc(g)}">
            <span class="hb-group-arrow">${collapsed ? '▶' : '▼'}</span>
            <img class="hb-group-ico px-ico" src="./icons/dir_icon.png" alt="" />
            <span class="hb-group-name">${esc(g)}</span>
            <span class="hb-group-count">${items.length}</span>
          </button>
          <div class="hb-group-body">${items.map(rowHtml).join('')}</div>
        </section>`
      }
    }
    htmlOut += '</div></div>'
    root.innerHTML = htmlOut
    const paint = () => renderHostBrowserInto(root)
    root.querySelector('[data-hb-act="new"]')?.addEventListener('click', () => openHostModal(null))
    root.querySelector('[data-hb-act="new-group"]')?.addEventListener('click', async () => {
      const g = await askPrompt('新分组名称', '新分组', { title: '新建分组' })
      if (!g) return
      openHostModal(null)
      if ($('fGroup')) $('fGroup').value = g
    })
    root.querySelector('[data-hb-act="expand"]')?.addEventListener('click', () => {
      state.hbCollapsed = new Set()
      paint()
    })
    root.querySelector('[data-hb-act="collapse"]')?.addEventListener('click', () => {
      state.hbCollapsed = new Set(groupNames)
      paint()
    })
    root.querySelector('[data-hb-act="refresh"]')?.addEventListener('click', async () => {
      if (hasApi) {
        state.hosts = (await api.loadHosts()) || state.hosts
        for (const h of state.hosts) {
          if (h.password) passwordVault.set(h.id, h.password)
        }
      }
      paint()
    })
    root.querySelector('.hb-filter')?.addEventListener('input', (e) => {
      state.hostBrowserFilter = e.target.value
      paint()
    })
    root.querySelectorAll('[data-hb-group]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const g = btn.getAttribute('data-hb-group')
        if (!g) return
        if (state.hbCollapsed.has(g)) state.hbCollapsed.delete(g)
        else state.hbCollapsed.add(g)
        paint()
      })
    })
    root.querySelectorAll('[data-hb]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation()
        const id = btn.getAttribute('data-id')
        const act = btn.getAttribute('data-hb')
        if (act === 'connect') {
          showModal('connMgrModal', false)
          await connectHost(id)
        }
        if (act === 'edit') openHostModal(id)
        if (act === 'del') {
          if (!(await askConfirm('确定删除该主机？此操作可在「显示已删除」中找回（若已软删）。', { title: '删除主机', danger: true, okText: '确定删除' }))) return
          state.hosts = state.hosts.filter((h) => h.id !== id)
          passwordVault.delete(id)
          await persistHosts()
          paint()
          renderQuickConnect()
          try { renderConnMgr() } catch (_) {}
        }
      })
    })
    root.querySelectorAll('.hb-row[data-id]').forEach((el) => {
      const id = el.getAttribute('data-id')
      el.addEventListener('click', (e) => {
        if (e.target.closest('button')) return
        state.activeHostId = id
        state.mgrSelectedId = id
        root.querySelectorAll('.hb-row.selected').forEach((x) => x.classList.remove('selected'))
        el.classList.add('selected')
      })
      el.addEventListener('dblclick', (e) => {
        if (e.target.closest('button')) return
        e.preventDefault()
        showModal('connMgrModal', false)
        connectHost(id)
      })
    })
  }

  function renderHostBrowser() {
    restorePageHostBrowserId()
    const root = $('hostBrowser')
    if (!root) return
    renderHostBrowserInto(root)
  }


  function openQuickConnectTab() {
    const tab = {
      id: 'tab_' + Date.now().toString(36),
      type: 'quick',
      title: '新标签页',
      status: 'idle',
      hostId: null,
      sessionId: null,
      sftpPath: '/',
    }
    state.tabs.push(tab)
    switchTab(tab.id)
  }

  /**
   * 从快速连接/新标签页连上 SSH 后，关掉空闲的「新标签页」，避免每次手关。
   * 不关 term/tool 等；不触发 closeTab 的「无标签再开一个 quick」。
   */
  function dismissIdleQuickTabs(opts = {}) {
    const keepId = opts.keepId || null
    const before = (state.tabs || []).length
    const removed = []
    state.tabs = (state.tabs || []).filter((t) => {
      if (!t || t.type !== 'quick') return true
      if (keepId && t.id === keepId) return true
      removed.push(t.id)
      return false
    })
    if (!removed.length) return 0
    // 若当前 active 被删，切到 keep 或最后一个 term
    if (removed.includes(state.activeTabId)) {
      const prefer =
        (keepId && state.tabs.find((t) => t.id === keepId)) ||
        state.tabs.find((t) => t.type === 'term' && t.status === 'connected') ||
        state.tabs.find((t) => t.type === 'term') ||
        state.tabs.at(-1) ||
        null
      state.activeTabId = prefer ? prefer.id : null
    }
    try {
      renderTabs()
      if (state.activeTabId) {
        // 不 await：只刷新 chrome，避免打断 connect 后续
        const t = state.tabs.find((x) => x.id === state.activeTabId)
        if (t) applyChromeForTab(t)
      }
    } catch (_) {}
    rlog('info', 'tabs', 'dismiss-quick', { removed: removed.length, left: state.tabs.length, before })
    return removed.length
  }

  /**
   * Only the interactive shell tab owns the SSH transport.
   * sysinfo / process / network / route tabs borrow the same sessionId for IPC —
   * closing them must NOT disconnect (that was killing the shell when × 系统信息).
   */
  function tabOwnsSshSession(tab) {
    return !!(tab && tab.sessionId && tab.type === 'term')
  }

  async function closeTab(id) {
    const tab = state.tabs.find((t) => t.id === id)
    if (!tab) return
    const sid = tab.sessionId
    // 关 SSH 标签时立刻收掉连接动画，避免“关不掉还在转”
    if (
      tab.type === 'term' &&
      (tab.status === 'connecting' ||
        tab.status === 'reconnecting' ||
        (sid && _connectOverlaySessionId && sid === _connectOverlaySessionId) ||
        (sid && !$('connectOverlay')?.hidden))
    ) {
      hideConnectOverlay(false, { reason: 'close-tab' })
    }
    const wasActive = state.activeTabId === id
    const isOwner = tabOwnsSshSession(tab)
    // 关掉 term 标签时硬清视口，避免二次连接仍显示旧输出（ping 历史等）
    if (tab.type === 'term' && term && (wasActive || isOwner)) {
      hardResetTerminalViewport()
    }
    if (sid && hasApi && isOwner) {
      // 不阻塞 UI：disconnect 卡死也不能拖住关标签
      const disc = Promise.resolve()
        .then(() => api.disconnect(sid))
        .catch((e) => console.warn('[disconnect cleanup]', e))
      try {
        await Promise.race([disc, timeout])
      } catch (_) {}
      clearTermSessionVisual(sid, { resetViewport: false })
      // Clear borrowed sessionId on sibling tool/sysinfo tabs so they don't look "live"
      for (const t of state.tabs) {
        if (t.id !== id && t.sessionId === sid) {
          t.sessionId = null
          if (t.status === 'connected' || t.status === 'reconnecting') t.status = 'closed'
        }
      }
    } else if (sid && isOwner) {
      clearTermSessionVisual(sid, { resetViewport: false })
    }
    state.tabs = state.tabs.filter((t) => t.id !== id)
    // 若已无任何 connecting 标签，再兜底关一次动画
    if (!state.tabs.some((t) => t.status === 'connecting' || t.status === 'reconnecting')) {
      hideConnectOverlay(false, { reason: 'close-tab-cleanup' })
    }
    if (state.activeTabId === id) {
      const next = state.tabs.at(-1)
      state.activeTabId = next?.id || null
      if (next) await switchTab(next.id)
      else {
        openQuickConnectTab()
      }
    } else renderTabs()
    if (!state.tabs.some((t) => t.sessionId && t.status === 'connected')) stopMonitor()
    updateBrandForSession()
  }

  // ── connect ────────────────────────────────────────────
  function normalizeHost(h) {
    if (!h || typeof h !== 'object') return h
    // import / 旧数据字段兼容: hostname/user_name/user/ip
    const host = String(h.host || h.hostname || h.ip || '').trim()
    const username = String(h.username || h.user || h.user_name || 'root').trim()
    const port = Number(h.port) || 22
    return { ...h, host, username, port }
  }

  function newSessionId() {
    return 'ssh_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
  }

  /**
   * External CLI (AI agent) events from main process.
   * Creates / updates terminal tabs when pixshell-cli connect runs.
   */
  function handleCliEvent(msg) {
    if (!msg || !msg.type) return
    if (msg.type === 'cli-connect' || msg.type === 'cli-connected') {
      const sessionId = msg.sessionId
      if (!sessionId) return
      let tab = state.tabs.find((t) => t.sessionId === sessionId)
      if (!tab) {
        tab = {
          id: 'tab_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
          type: 'term',
          hostId: msg.hostId || null,
          title: msg.title || `${msg.username || ''}@${msg.host || ''}` || 'CLI',
          sessionId,
          status: msg.type === 'cli-connected' ? 'connected' : 'connecting',
          sftpPath: '/',
        }
        state.tabs.push(tab)
        if (!termBuffers.has(sessionId)) termBuffers.set(sessionId, '')
        switchTab(tab.id)
        if (msg.type === 'cli-connect') {
          writeActive(sessionId, `\x1b[90m[CLI] 正在连接 ${msg.username || ''}@${msg.host || ''}…\x1b[0m\r\n`)
        }
      } else {
        tab.status = msg.type === 'cli-connected' ? 'connected' : tab.status
        if (msg.hostId) tab.hostId = msg.hostId
        if (msg.title) tab.title = msg.title
      }
      if (msg.type === 'cli-connected') {
        tab.status = 'connected'
        writeActive(
          sessionId,
          `\x1b[32m[CLI] 已连接 ${msg.username || ''}@${msg.host || ''}:${msg.port || 22}\x1b[0m\r\n`,
        )
        updateSyncDot(true)
        if (tab.id === state.activeTabId) startMonitor()
      }
      if (msg.hostId) state.activeHostId = msg.hostId
      renderTabs()
      renderStatus()
    }
  }

  async function connectHost(hostId, passwordOverride, opts = {}) {
    if (!opts.forceNew && state._connectInflightHostId && state._connectInflightHostId === hostId) {
      rlog('warn', 'connect', 'ignored duplicate', { hostId })
      return toast('正在连接中…')
    }
    state._connectInflightHostId = hostId
    rlog('info', 'connect', 'start', { hostId, forceNew: !!opts.forceNew })
    const _clearConnectInflight = () => {
      if (state._connectInflightHostId === hostId) state._connectInflightHostId = null
    }
    try {
    const raw = state.hosts.find((x) => x.id === hostId)
    if (!raw) return toast('主机不存在', true)
    if (!hasApi) return toast('请用 node start.js 启动 Electron', true)

    const h = normalizeHost(raw)
    // 写回规范化字段，避免后续 host/username 为空
    if (h.host) {
      raw.host = h.host
      raw.username = h.username
      raw.port = h.port
    }

    state.activeHostId = hostId
    if (!opts.forceNew) {
      // 仅复用「已连接且有 sessionId」的会话；connecting/error 允许重试
      const exist = state.tabs.find(
        (t) => t.hostId === hostId && t.type === 'term' && t.status === 'connected' && t.sessionId,
      )
      if (exist) {
        await switchTab(exist.id)
        try {
          dismissIdleQuickTabs({ keepId: exist.id })
        } catch (_) {}
        return
      } else if (!opts.reuseTabId) {
        // 如果未指明重用，且没有活跃会话，则尝试复用当前主机的已关闭标签页
        const dead = state.tabs.find(
          (t) => t.hostId === hostId && t.type === 'term' && (t.status === 'closed' || t.status === 'error')
        )
        if (dead) opts.reuseTabId = dead.id
      }
    }

    // 私钥：内存 vault > 主机字段内容 > 路径读文件
    let privateKey = h.privateKey || keyVault.get(h.id) || ''
    const keyPath = String(h.privateKeyPath || h.keyPath || '').trim()
    if (!privateKey && keyPath && api.readTextFile) {
      try {
        const kr = await api.readTextFile(keyPath)
        if (kr?.ok && kr.text) {
          privateKey = kr.text
          keyVault.set(h.id, privateKey)
        }
      } catch (_) {}
    }
    if (privateKey) keyVault.set(h.id, privateKey)

    // 密码：显式 override > vault > 主机字段（导入后通常为空）
    let pw =
      passwordOverride != null && passwordOverride !== ''
        ? passwordOverride
        : passwordVault.get(h.id) || h.password || ''
    if (typeof pw !== 'string') pw = String(pw || '')

    // RDP 类型不走 SSH
    if (Number(h.connectionType) === 200) {
      try {
        await api.launchRdp({ host: h.host, username: h.username, port: h.port || 3389 })
        toast('已启动 RDP: ' + h.host)
      } catch (e) {
        toast('RDP 失败: ' + (e.message || e), true)
      }
      return
    }

    if (!pw && !privateKey && !keyPath) {
      const entered = await askPrompt(
        '请输入密码\n' + (h.username || 'root') + '@' + h.host + ':' + (h.port || 22),
        '',
        { title: 'SSH 密码', password: true, rememberPassword: true, placeholder: '输入密码' },
      )
      if (entered === null) return
      if (entered && typeof entered === 'object') {
        pw = entered.value || ''
        if (pw) {
          passwordVault.set(h.id, pw)
          if (entered.remember) {
            h.password = pw
            h.rememberPassword = true
            const idx = state.hosts.findIndex((x) => x.id === h.id)
            if (idx >= 0) {
              state.hosts[idx].password = pw
              state.hosts[idx].rememberPassword = true
              try { await persistHosts() } catch (_) {}
            }
          }
        }
      } else {
        pw = entered || ''
        if (pw) passwordVault.set(h.id, pw)
      }
    }
    if (pw) passwordVault.set(h.id, pw)
    // 有 keyPath 时允许只把路径交给 engine 加载
    if (!pw && !privateKey && !keyPath) return toast('需要密码或私钥', true)
    if (!h.host) return toast('主机地址为空', true)

    // 代理：host.proxy 或 settings.proxyList 按 proxyId 匹配
    let proxy = h.proxy || null
    if (!proxy && h.proxyId && state.settings?.proxyList?.length) {
      proxy = state.settings.proxyList.find((p) => p.id === h.proxyId) || null
    }

    // 关键前分配 sessionId：onData/onStatus 在 await connect 期间就能命中 tab
    const sessionId = newSessionId()
    let tab
    if (opts.reuseTabId) {
      tab = state.tabs.find((x) => x.id === opts.reuseTabId)
    }
    if (tab) {
      // Drop previous session association/buffer before reusing the tab chrome
      if (tab.sessionId && tab.sessionId !== sessionId) {
        try { termBuffers.delete(tab.sessionId) } catch (_) {}
      }
      tab.hostId = hostId
      tab.title = h.name || h.host
      tab.host = h.host
      tab.status = 'connecting'
      tab.sessionId = sessionId
      state.activeTabId = tab.id
    } else {
      tab = {
        id: 'tab_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 5),
        type: 'term',
        hostId,
        title: h.name || h.host,
        host: h.host,
        status: 'connecting',
        sessionId,
        sftpPath: '/',
      }
      state.tabs.push(tab)
      state.activeTabId = tab.id
    }
    // 新会话：硬清视口与缓冲，避免复用标签时闪出上一次会话残留
    clearTermSessionVisual(sessionId, { resetViewport: true })
    renderTabs()
    showContent('term')
    fitAddon?.fit()
    showConnectOverlay(h.username, h.host, h.port || 22, sessionId)
    renderStatus()

    let ready
    try {
      ready = await api.sshReady()
    } catch (e) {
      tab.status = 'error'
      hideConnectOverlay(false, { reason: 'sshReady-throw', showFail: true, title: '连接失败' })
      writeActive(sessionId, `\x1b[31m[SSH] sshReady 异常: ${e.message || e}\x1b[0m\r\n`)
      toast('sshReady 异常', true)
      renderTabs()
      return
    }
    if (!ready?.ssh2) {
      tab.status = 'error'
      hideConnectOverlay(false, { reason: 'no-ssh2', showFail: true, title: '连接失败' })
      writeActive(sessionId, `\x1b[31m[SSH] ssh2 未加载: ${ready?.error || ''}\x1b[0m\r\n`)
      toast('ssh2 未加载', true)
      renderTabs()
      return
    }

    // 与 engine.connect / preload fsApi.connect 契约对齐
    const payload = {
      sessionId,
      host: h.host,
      port: h.port || 22,
      username: h.username || 'root',
      password: pw || undefined,
      privateKey: privateKey || undefined,
      privateKeyPath: !privateKey && keyPath ? keyPath : undefined,
      passphrase: h.passphrase || undefined,
      hostId: h.id,
      cols: term?.cols || 120,
      rows: term?.rows || 30,
      term: state.settings.termType || 'xterm-256color',
      proxy: proxy || undefined,
    }

    let res
    try {
      res = await api.connect(payload)
    } catch (e) {
      tab.status = 'error'
      hideConnectOverlay(false, { reason: 'connect-throw-ipc', showFail: true, title: '连接失败' })
      writeActive(sessionId, `\x1b[31m[SSH 异常] ${e.message || e}\x1b[0m\r\n`)
      toast('SSH 异常: ' + (e.message || e), true)
      renderTabs()
      renderStatus()
      return
    }

    if (!res?.ok) {
      tab.status = 'error'
      hideConnectOverlay(false, { reason: 'connect-fail', showFail: true, title: '连接失败' })
      if (res?.sessionId) tab.sessionId = res.sessionId
      writeActive(tab.sessionId, `\x1b[31m[SSH 失败] ${res?.error || 'unknown'}\x1b[0m\r\n`)
      writeActive(tab.sessionId, `\x1b[90m检查: 主机/端口/用户名/密码或私钥；网络；是否需要代理\x1b[0m\r\n`)
      toast('SSH 失败: ' + (res?.error || ''), true)
      renderTabs()
      renderStatus()
      return
    }

    // sessionId 以服务端返回为准（通常与预分配一致）
    const sid = res.sessionId || sessionId
    if (sid !== tab.sessionId) {
      const oldBuf = termBuffers.get(tab.sessionId) || ''
      tab.sessionId = sid
      termBuffers.set(sid, (termBuffers.get(sid) || '') + oldBuf)
      if (sessionId !== sid) termBuffers.delete(sessionId)
    } else {
      tab.sessionId = sid
    }
    tab.status = 'connected'
    hideConnectOverlay(true)
    // 禁止清空 buffer —— 连接期间 onData 的 shell 输出必须保留
    // 连上后展开侧栏/底栏（快速连接页默认是收起的）
    setSidebarCollapsed(false)
    setBottomCollapsed(false)
    updateBrandForSession()
    try {
      applyTermFontScale()
    } catch (_) {
      fitAddon?.fit()
    }
    try {
      await api.resize(tab.sessionId, term?.cols || 80, term?.rows || 24)
    } catch (_) {}
    renderTabs()
    renderStatus()
    updateSyncDot(true)
    if ($('lmIp')) $('lmIp').textContent = h.host
    try {
      await refreshSftp({ retries: 5, ensureFiles: true })
    } catch (e) {
      console.error('refreshSftp', e)
      try { rlog('error', 'sftp', 'refresh after connect', { err: e && e.message }) } catch (_) {}
    }
    // SFTP 子系统有时晚于 shell ready，再补一次
    setTimeout(() => {
      refreshSftp({ retries: 3, ensureFiles: true }).catch((e) => console.warn('[sftp auto-refresh]', e))
    }, 1200)
    try {
      startMonitor()
    } catch (_) {}
    toast('已连接 ' + h.host)
    // 记入快速连接历史（此前 recentHosts 只读不写，历史永远为空）
    try { recordRecentHost(hostId) } catch (_) {}
    // 读取服务器系统，自动把头像换成对应发行版 logo（异步，不阻塞连接流程）
    detectHostOs(hostId, tab.sessionId).catch((e) => console.warn('[detectHostOs]', e))
    // 连上后自动关掉启动时/快速连接留下的「新标签页」
    try {
      dismissIdleQuickTabs({ keepId: tab.id })
    } catch (eDismiss) {
      try {
        rlog('warn', 'tabs', 'dismiss-quick-fail', { err: eDismiss && eDismiss.message })
      } catch (_) {}
    }
    rlog('info', 'connect', 'done ok', { hostId, sessionId: tab.sessionId })
    } catch (e) {
      rlog('error', 'connect', e && e.message ? e.message : String(e), { hostId, stack: e && e.stack })
      try {
        const t = state.tabs.find((x) => x.hostId === hostId && x.status === 'connecting')
        if (t) t.status = 'error'
      } catch (_) {}
      hideConnectOverlay(false, { reason: 'connect-throw', showFail: true, title: '连接异常' })
      try {
        renderTabs()
        renderStatus()
      } catch (_) {}
      toast('连接异常: ' + (e && e.message ? e.message : e), true)
      // 不 rethrow：避免未处理 Promise 把后续 UI 弄死
    } finally {
      _clearConnectInflight()
    }
  }

  async function disconnectActive() {
    const t = sessionTab()
    if (!t?.sessionId) return toast('无会话')
    hideConnectOverlay(false, { reason: 'disconnect-active' })
    const sid = t.sessionId
    // 保留 hostId/title，便于侧栏「重连」而不必关标签
    const disc = Promise.resolve()
      .then(() => api.disconnect(sid))
      .catch((e) => console.warn('[disconnect cleanup]', e))
    try {
      await Promise.race([disc, new Promise((r) => setTimeout(r, 2500))])
    } catch (_) {}
    t.status = 'closed'
    t.sessionId = null
    updateSyncDot(false)
    setConnStateLabel('reconnect')
    stopMonitor()
    renderTabs()
    renderStatus()
    updateBrandForSession()
    toast('已断开（标签保留，可点重连）')
  }

  async function doReconnect() {
    if (state._reconnectInflight) {
      rlog('warn', 'reconnect', 'ignored: already inflight')
      return
    }
    state._reconnectInflight = true
    rlog('info', 'reconnect', 'start')
    try {
    // Prefer dead/live term tab; fall back to any tab with hostId
    let t =
      state.tabs.find((x) => x.type === 'term' && (x.status === 'closed' || x.status === 'error') && x.hostId) ||
      state.tabs.find((x) => x.type === 'term' && (x.sessionId || x.hostId)) ||
      sessionTab() ||
      currentTab()
    if (!t) {
      const hid = state.activeHostId || state.mgrSelectedId
      if (hid) return await connectHost(hid, passwordVault.get(hid), { forceNew: true, fromReconnect: true, reuseTabId: t?.id })
      return toast('无会话可重连', true)
    }
    updateConnectionStatusFromTab()
    if (t.sessionId && hasApi) {
      toast('重连中…')
      t.status = 'reconnecting'
      setConnStateLabel('busy')
      renderTabs()
      renderStatus()
      const r = await api.reconnect(t.sessionId)
      if (r?.ok) {
        const old = t.sessionId
        const sid = r.sessionId || old
        // engine keeps same sessionId on reconnect; only migrate buffer if id changed
        if (old && sid && old !== sid) {
          const prev = termBuffers.get(old) || ''
          termBuffers.set(sid, (termBuffers.get(sid) || '') + prev)
          termBuffers.delete(old)
        }
        t.sessionId = sid
        t.status = 'connected'
        if (!termBuffers.has(t.sessionId)) termBuffers.set(t.sessionId, '')
        toast('已重连')
        renderTabs()
        renderStatus()
        startMonitor()
        try {
          await refreshSftp()
        } catch (_) {}
        return
      }
      toast('重连失败: ' + (r?.error || ''), true)
      t.status = 'closed'
      renderStatus()
    }
    const hostId = t.hostId || state.activeHostId
    if (hostId) {
      await connectHost(hostId, passwordVault.get(hostId), { forceNew: true, fromReconnect: true, reuseTabId: t.id })
      return
    }
    toast('无主机可重连', true)
    } catch (e) {
      rlog('error', 'reconnect', e && e.message ? e.message : String(e), { stack: e && e.stack })
      toast('重连异常: ' + (e && e.message ? e.message : e), true)
    } finally {
      state._reconnectInflight = false
      try { renderStatus() } catch (_) {}
    }
  }

  // ── SFTP (WinSCP-style pure SFTP — never shell ls as source of truth) ──
  /** Absolute remote path join for SFTP only */
  function sftpJoin(base, name) {
    const b = !base || base === '.' ? '/' : String(base)
    if (!name || name === '.') return b
    if (name === '..') {
      if (b === '/') return '/'
      const parts = b.replace(/\/+$/, '').split('/')
      parts.pop()
      return parts.join('/') || '/'
    }
    if (String(name).startsWith('/')) return name.replace(/\/{2,}/g, '/')
    const left = b.replace(/\/+$/, '') || ''
    return (left === '' ? '' : left) + '/' + name
  }

  async function navigateSftp(tab, nextPath, { syncShell } = {}) {
    // Pure SFTP navigation. Optional shell cd is side-effect only (not used for listing).
    tab.sftpPath = nextPath || '/'
    await refreshSftp()
    if (syncShell && state.settings.syncDirWithSftp === true && tab.sessionId && hasApi) {
      try {
        // SFTP/shell 分离: await api.write(tab.sessionId, 'cd ' + shellQuote(tab.sftpPath) + '\n')
      } catch (_) {}
    }
  }

  async function refreshSftp(opts = {}) {
    const tab = sessionTab()
    const body = $('sftpBody')
    const tree = $('sftpTree')
    if (!body) {
      try { rlog('warn', 'sftp', 'no sftpBody') } catch (_) {}
      return
    }
    // 仅连接成功等场景传 ensureFiles，避免用户在「命令」面板时被 refreshSftp 强切走
    if (opts.ensureFiles) {
      try {
        setBottom('files')
        setBottomCollapsed(false)
      } catch (_) {}
    } else {
      // 列表刷新时若底栏被藏，只展开，不改 files/cmds 选择
      try {
        if (state.bottomCollapsed) setBottomCollapsed(false)
      } catch (_) {}
    }

    if (!tab?.sessionId || !hasApi) {
      body.innerHTML = '<tr class="empty"><td colspan="6">连接主机后通过 SFTP 列出远程文件</td></tr>'
      if (tree) tree.innerHTML = ''
      if ($('sftpPath')) $('sftpPath').textContent = '-'
      return
    }
    // Always absolute path for SFTP protocol
    let remotePath = tab.sftpPath || '/'
    if (!remotePath || remotePath === '.') remotePath = '/'
    if (!String(remotePath).startsWith('/')) remotePath = '/' + remotePath
    tab.sftpPath = remotePath

    body.innerHTML = '<tr class="empty"><td colspan="6">SFTP 读取中…</td></tr>'
    if ($('sftpPath')) $('sftpPath').textContent = remotePath

    const maxTry = Math.max(1, Number(opts.retries) || 5)
    let res = null
    let lastErr = ''
    for (let attempt = 1; attempt <= maxTry; attempt++) {
      try {
        res = await api.sftpList(tab.sessionId, remotePath)
      } catch (e) {
        lastErr = e && e.message ? e.message : String(e)
        res = { ok: false, error: lastErr }
      }
      if (res?.ok) break
      lastErr = (res && res.error) || lastErr || 'list 失败'
      try {
        rlog('warn', 'sftp', 'list retry', { attempt, maxTry, path: remotePath, err: lastErr })
      } catch (_) {}
      if (attempt < maxTry) await new Promise((r) => setTimeout(r, 400 * attempt))
    }
    if (!res?.ok) {
      body.innerHTML = `<tr class="empty"><td colspan="6">SFTP: ${esc(lastErr || 'list 失败')}</td></tr>`
      try {
        rlog('error', 'sftp', 'list fail', { path: remotePath, err: lastErr, sessionId: tab.sessionId })
      } catch (_) {}
      return
    }
    tab.sftpPath = res.path || remotePath
    if ($('sftpPath')) $('sftpPath').textContent = tab.sftpPath

    const entries = (res.entries || []).slice().sort((a, b) => {
      const ad = !!(a.isDir || a.isDirectory)
      const bd = !!(b.isDir || b.isDirectory)
      if (ad !== bd) return ad ? -1 : 1
      return String(a.name || '').localeCompare(String(b.name || ''))
    })
    tab._sftpEntries = entries
    try {
      rlog('info', 'sftp', 'list ok', { path: tab.sftpPath, n: entries.length })
    } catch (_) {}

    if (!entries.length) {
      body.innerHTML = '<tr class="empty"><td colspan="6">空目录</td></tr>'
    } else {
      body.innerHTML = entries
        .map((e) => {
          const isDir = !!(e.isDir || e.isDirectory)
          const name = e.name
          const ico = isDir
            ? '<img class="px-ico" src="./icons/dir_icon.png" alt="" />'
            : '<img class="px-ico" src="./icons/com_E_icons_file_icon.png" alt="" />'
          return `<tr class="${isDir ? 'dir' : 'file'}" data-name="${esc(name)}" data-dir="${isDir ? 1 : 0}" data-full="${esc(e.fullPath || '')}" data-size="${isDir ? 0 : Number(e.size) || 0}">
          <td class="name col-name">${ico}<span class="sftp-name-text">${esc(name)}</span></td>
          <td class="col-size">${isDir ? '' : formatSize(e.size)}</td>
          <td class="col-type">${isDir ? '目录' : e.isSymlink ? '链接' : '文件'}</td>
          <td class="col-mtime">${esc(formatTime(e.modifyTime))}</td>
          <td class="col-perm">${esc(e.rights || '')}</td>
          <td class="col-user">${esc(e.owner ?? '')}</td>
        </tr>`
        })
        .join('')
    }

    // Left tree: path breadcrumb + subdirs (SFTP only)
    if (tree) {
      const cur = tab.sftpPath || '/'
      const parts = cur === '/' ? [] : cur.replace(/^\/+/, '').split('/').filter(Boolean)
      let acc = ''
      let html = `<div class="tree-item${cur === '/' ? ' active' : ''}" data-path="/">/</div>`
      for (const part of parts) {
        acc += '/' + part
        const active = acc === cur ? ' active' : ''
        html += `<div class="tree-item${active}" data-path="${esc(acc)}" style="padding-left:${Math.min(12 + parts.indexOf(part) * 8, 48)}px">${esc(part)}</div>`
      }
      for (const d of entries.filter((x) => x.isDir || x.isDirectory).slice(0, 200)) {
        const pth = sftpJoin(cur, d.name)
        html += `<div class="tree-item" data-path="${esc(pth)}" style="padding-left:16px"><img class="px-ico" src="./icons/dir_icon.png" alt="" />${esc(d.name)}</div>`
      }
      tree.innerHTML = html
      tree.querySelectorAll('.tree-item').forEach((el) => {
        el.onclick = async () => {
          await navigateSftp(tab, el.dataset.path, { syncShell: false })
        }
      })
    }

    state.selectedSftp = null
    state.selectedSftpList = []
    body.querySelectorAll('tr[data-name]').forEach((row) => {
      row.addEventListener('click', (ev) => {
        const item = {
          name: row.dataset.name,
          isDir: row.dataset.dir === '1',
          fullPath: row.dataset.full || '',
          size: Number(row.dataset.size) || 0,
        }
        if (ev.metaKey || ev.ctrlKey) {
          row.classList.toggle('selected')
        } else if (ev.shiftKey && state.selectedSftp) {
          const rows = [...body.querySelectorAll('tr[data-name]')]
          const aIdx = rows.findIndex((r) => r.dataset.name === state.selectedSftp.name)
          const bIdx = rows.indexOf(row)
          if (aIdx >= 0 && bIdx >= 0) {
            const lo = Math.min(aIdx, bIdx)
            const hi = Math.max(aIdx, bIdx)
            rows.forEach((r, i) => r.classList.toggle('selected', i >= lo && i <= hi))
          } else {
            body.querySelectorAll('tr').forEach((r) => r.classList.remove('selected'))
            row.classList.add('selected')
          }
        } else {
          body.querySelectorAll('tr').forEach((r) => r.classList.remove('selected'))
          row.classList.add('selected')
        }
        const selected = [...body.querySelectorAll('tr.selected[data-name]')].map((r) => ({
          name: r.dataset.name,
          isDir: r.dataset.dir === '1',
          fullPath: r.dataset.full || '',
          size: Number(r.dataset.size) || 0,
        }))
        state.selectedSftpList = selected
        state.selectedSftp = selected[selected.length - 1] || item
      })
      row.addEventListener('dblclick', async () => {
        if (row.dataset.dir === '1') {
          await navigateSftp(tab, sftpJoin(tab.sftpPath, row.dataset.name), { syncShell: false })
        } else {
          state.selectedSftp = {
            name: row.dataset.name,
            isDir: false,
            fullPath: row.dataset.full || sftpJoin(tab.sftpPath, row.dataset.name),
          }
          await sftpCtxAction('open')
        }
      })
    })
  }

  // ── monitor ────────────────────────────────────────────
  function startMonitor() {
    stopMonitor()
    // routers: default 8s; settings may override (min 4s to avoid channel thrash)
    let sec = Number(state.settings.monitorIntervalSec) || 8
    if (sec < 4) sec = 4
    collectMonitorOnce()
    state.monTimer = setInterval(collectMonitorOnce, sec * 1000)
  }
  function stopMonitor() {
    if (state.monTimer) clearInterval(state.monTimer)
    state.monTimer = null
    state._monInflight = false
  }
  async function collectMonitorOnce() {
    const tab = sessionTab()
    if (!tab?.sessionId || !hasApi) return
    // never pile overlapping monitor IPC on one tab (dropbear MaxSessions)
    if (state._monInflight) return
    state._monInflight = true
    let r
    try {
      r = await api.monitor(tab.sessionId)
    } catch (e) {
      console.warn('monitor', e)
      state._monInflight = false
      return
    }
    state._monInflight = false
    if (!r?.ok || !r.data) return
    if (r.skipped && !Object.keys(r.data || {}).length) return
    const d = r.data
    // empty skipped tick with last data still paints
    if (!d || (d.cpu == null && !d.mem && !d.load && r.skipped)) return

    // Remote host identity — always prefer the configured connection host
    // over the IP detected by the remote monitor script (which may pick a
    // different NIC / subnet than the one the user actually connects to).
    if ($('lmIp')) {
      const hostIp = (currentHost() && currentHost().host) || (currentTab() && currentTab().host) || ''
      if (hostIp && hostIp !== '-') {
        $('lmIp').textContent = hostIp
      } else {
        // fallback: use monitor-detected IP if no configured host
        const monIp = String(d.ip || '').trim()
        const isLoop = !monIp || monIp === '127.0.0.1' || monIp === '::1' || monIp.startsWith('127.')
        if (!isLoop) $('lmIp').textContent = monIp
      }
    }
    if ($('monLoad')) $('monLoad').textContent = d.load || '-'
    if ($('monUptime')) $('monUptime').textContent = d.uptime || '-'

    const cpu = (() => {
      const n = parseFloat(String(d.cpu ?? '').replace(/%/g, '').trim())
      return Number.isFinite(n) ? n : 0
    })()
    setMetricBar('lmCpuBar', 'monCpu', 'monCpuSize', cpu, '', 'cpu')

    // mem: "pct usedMB totalMB" — accept decimal pct
    const memParts = String(d.mem || '').trim().split(/\s+/)
    const memPct = (() => {
      const n = parseFloat(memParts[0])
      return Number.isFinite(n) ? n : 0
    })()
    const memUsed = Number(memParts[1]) || 0
    const memTotal = Number(memParts[2]) || 0
    const memSize =
      memTotal > 0 ? formatMemHuman(memUsed) + '/' + formatMemHuman(memTotal).replace(/[MG]$/, (x) => x) : ''
    // compact like 3.5G/4G
    let memSizeTxt = memSize
    if (memTotal >= 1024 && memUsed >= 0) {
      const ug = memUsed / 1024
      const tg = memTotal / 1024
      const us = ug >= 10 ? ug.toFixed(0) : ug.toFixed(1).replace(/\.0$/, '')
      const ts = tg >= 10 ? tg.toFixed(0) : tg.toFixed(1).replace(/\.0$/, '')
      memSizeTxt = us + 'G/' + ts
    } else if (memTotal > 0) {
      memSizeTxt = formatMemHuman(memUsed) + '/' + formatMemHuman(memTotal)
    }
    setMetricBar('lmMemBar', 'monMem', 'monMemSize', memPct, memSizeTxt, 'mem')

    const sw = String(d.swap || '').trim().split(/\s+/)
    const swPct = (() => {
      const n = parseFloat(sw[0])
      return Number.isFinite(n) ? n : 0
    })()
    const swUsed = Number(sw[1]) || 0
    const swTotal = Number(sw[2]) || 0
    let swSizeTxt = ''
    if (swTotal >= 1024) {
      const ug = swUsed / 1024
      const tg = swTotal / 1024
      const us = ug >= 10 ? ug.toFixed(0) : ug.toFixed(1).replace(/\.0$/, '')
      const ts = tg >= 10 ? tg.toFixed(0) : tg.toFixed(1).replace(/\.0$/, '')
      swSizeTxt = us + 'G/' + ts
    } else if (swTotal > 0) {
      swSizeTxt = formatMemHuman(swUsed) + '/' + formatMemHuman(swTotal)
    } else {
      swSizeTxt = '0'
    }
    // monSwap id is lm-pct inside swap bar
    setMetricBar('lmSwapBar', 'monSwap', 'monSwapSize', swPct, swSizeTxt, 'swap')

    // TOP processes table — memory absolute (22.4M), cpu number (2.3)
    const pl = $('lmProcList')
    if (pl) {
      const lines = String(d.procs || '').split(/\n/).filter(Boolean).slice(0, 12)
      if (!lines.length) {
        pl.innerHTML = '<tr><td colspan="3" class="lm-empty">无</td></tr>'
      } else {
        pl.innerHTML = lines
          .map((line) => {
            const parts = line.split('\t')
            let mem = (parts[0] || '-').trim()
            let cpu2 = (parts[1] || '-').trim()
            let name = (parts[2] || parts[parts.length - 1] || '-').trim()
            // normalize cpu: strip trailing % for display like reference (2.3)
            cpu2 = String(cpu2).replace(/%/g, '')
            // mem already like 22.4M from collector
            if (mem === '' || mem === '0%') mem = '-'
            return `<tr title="${esc(name)}"><td class="col-mem">${esc(mem)}</td><td class="col-cpu">${esc(cpu2)}</td><td>${esc(name)}</td></tr>`
          })
          .join('')
      }
    }

    // Disks (remote df)
    const dl = $('lmDiskList')
    if (dl) {
      const lines = String(d.disks || '').split(/\n/).filter(Boolean)
      dl.innerHTML = lines.length
        ? lines
            .map((line) => {
              const [mp, size, used, avail, pct] = line.split('\t')
              const p = parseInt(pct, 10) || 0
              return `<tr><td title="${esc(mp)}">${esc(mp)}</td><td>${esc(avail)}/${esc(size)} <span class="disk-bar" style="width:${Math.min(60, p * 0.6)}px"></span></td></tr>`
            })
            .join('')
        : '<tr><td colspan="2" class="lm-empty">-</td></tr>'
    }

    // Net counters (remote /proc/net/dev) → rate + spark
    const netLine = String(d.netdev || '').trim()
    if (netLine) {
      const parts = netLine.split(/\s+/)
      const ifc = parts[0] || ''
      const rx = Number(parts[1]) || 0
      const tx = Number(parts[2]) || 0
      if ($('lmNetIf')) $('lmNetIf').textContent = ifc
      const fmt = (n) => {
        if (n < 1024) return n + 'B'
        if (n < 1048576) return (n / 1024).toFixed(0) + 'K'
        if (n < 1073741824) return (n / 1048576).toFixed(1) + 'M'
        return (n / 1073741824).toFixed(2) + 'G'
      }
      const prev = state._netPrev
      let dRx = 0
      let dTx = 0
      if (prev && prev.if === ifc) {
        dRx = Math.max(0, rx - prev.rx)
        dTx = Math.max(0, tx - prev.tx)
      }
      state._netPrev = { if: ifc, rx, tx }
      // show per-interval rate if we have delta, else total
      if ($('lmNetUp')) $('lmNetUp').textContent = '↑' + (prev ? fmt(dTx) + '/s' : fmt(tx))
      if ($('lmNetDown')) $('lmNetDown').textContent = '↓' + (prev ? fmt(dRx) + '/s' : fmt(rx))
      state.netSpark.push(dRx + dTx)
      if (state.netSpark.length > 40) state.netSpark.shift()
      drawSpark('netSpark', state.netSpark, '#43a047')
    }

    // Real gateway ping from REMOTE host (not local, not SSH RTT)
    let ms = parseFloat(d.pingMs)
    if (!Number.isFinite(ms)) {
      // fallback: do not fake with local ssh RTT; show -
      if ($('lmPing')) {
        $('lmPing').textContent = d.pingTarget ? '- ms' : '-'
      }
    } else {
      ms = Math.round(ms)
      if ($('lmPing')) {
        $('lmPing').textContent = ms + 'ms' + (d.pingTarget ? ' ' + d.pingTarget : '')
      }
      state.pingSpark.push(ms)
      if (state.pingSpark.length > 40) state.pingSpark.shift()
      drawSpark('pingSpark', state.pingSpark, '#1e88e5')
    }
    // Do NOT force green here — session may already be closed; status comes from onStatus/renderStatus
    try {
      updateConnectionStatusFromTab()
    } catch (_) {}
  }
  function drawSpark(canvasId, data, color) {
    const c = $(canvasId)
    if (!c || !data.length) return
    const ctx = c.getContext('2d')
    const w = c.width
    const h = c.height
    ctx.clearRect(0, 0, w, h)
    const max = Math.max(...data, 1)
    ctx.strokeStyle = color
    ctx.lineWidth = 1
    ctx.beginPath()
    data.forEach((v, i) => {
      const x = (i / (data.length - 1 || 1)) * w
      const y = h - (v / max) * (h - 4) - 2
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    })
    ctx.stroke()
  }
  /**
   * Sidebar connection control button (#btnConnToggle / #connStateText):
   *  - connected → 文案「已连接」，点击 = 断开
   *  - disconnected/idle → 文案「未连接」或「已断开」，点击 = 连接/重连
   *  - connecting/reconnecting → 「连接中…/重连中…」，禁用
   * mode: 'connected' | 'disconnected' | 'idle' | 'busy'
   */
  function setConnStateLabel(mode) {
    // 兼容旧调用：'status'≈connected/idle 由 updateSyncDot 细化；'reconnect'→disconnected；'busy'
    const btn = $('btnConnToggle')
    const txt = $('connStateText')
    const lab = $('connStateLabel') // 旧节点（若残留）
    const head = document.querySelector('.sidebar-head')
    let m = mode
    if (m === 'reconnect') m = 'disconnected'
    if (m === 'status') {
      // 保持当前按钮语义，不瞎改；由 updateSyncDot/updateConnectionStatusFromTab 设准
      m = btn?.dataset.mode || 'idle'
    }
    const busy = m === 'busy'
    const connected = m === 'connected'
    const disconnected = m === 'disconnected'
    const idle = m === 'idle' || (!connected && !disconnected && !busy)

    if (btn) {
      btn.dataset.mode = connected ? 'connected' : disconnected ? 'disconnected' : busy ? 'busy' : 'idle'
      btn.classList.toggle('is-connected', connected)
      btn.classList.toggle('is-disconnected', disconnected)
      btn.classList.toggle('is-idle', idle && !busy)
      btn.classList.toggle('is-busy', busy)
      btn.disabled = busy
      if (connected) {
        btn.title = '点击断开 SSH'
        if (txt) {
          txt.textContent = '已连接'
          txt.style.color = ''
        }
      } else if (busy) {
        btn.title = '连接进行中…'
        // 文案由调用方写入 连接中/重连中
      } else if (disconnected) {
        btn.title = '点击重新连接'
        if (txt && !/连接中|重连中/.test(txt.textContent || '')) {
          txt.textContent = '已断开'
          txt.style.color = ''
        }
      } else {
        btn.title = '点击连接主机'
        if (txt && !/连接中|重连中/.test(txt.textContent || '')) {
          txt.textContent = '未连接'
          txt.style.color = ''
        }
      }
    }
    // 旧 label：断开时可点（兜底）
    if (lab) {
      lab.textContent = disconnected ? '重新连接' : '连接状态'
      lab.classList.toggle('is-reconnect', disconnected)
      lab.title = disconnected ? '点击重新连接 SSH' : 'SSH 连接状态'
    }
    if (head) head.classList.toggle('can-reconnect', disconnected)
  }

  function updateSyncDot(on) {
    // SSH 连接状态：已连接绿灯 / 断开红灯 / 未知灰灯 + 按钮文案
    const d = $('syncDot')
    const connected = on === true
    const disconnected = on === false
    if (d) {
      d.classList.toggle('on', connected)
      d.classList.toggle('err', disconnected)
      if (!connected && !disconnected) d.classList.remove('on', 'err')
    }
    const txt = $('connStateText')
    if (txt) {
      txt.textContent = connected ? '已连接' : disconnected ? '已断开' : '未连接'
      txt.style.color = ''
    }
    setConnStateLabel(connected ? 'connected' : disconnected ? 'disconnected' : 'idle')
  }

  function updateConnectionStatusFromTab() {
    const tab = currentTab() || sessionTab()
    const st = tab?.status
    if (st === 'connected') {
      updateSyncDot(true)
    } else if (st === 'connecting' || st === 'reconnecting') {
      const d = $('syncDot')
      if (d) d.classList.remove('on', 'err')
      const txt = $('connStateText')
      if (txt) {
        txt.textContent = st === 'reconnecting' ? '重连中…' : '连接中…'
        txt.style.color = ''
      }
      setConnStateLabel('busy')
    } else if (st === 'error' || st === 'closed') {
      updateSyncDot(false)
    } else {
      const hasLive = (state.tabs || []).some(
        (t) => t.type === 'term' && t.status === 'connected' && t.sessionId,
      )
      if (hasLive) updateSyncDot(true)
      else {
        const d = $('syncDot')
        if (d) d.classList.remove('on', 'err')
        const deadTerm = (state.tabs || []).find(
          (t) => t.type === 'term' && t.hostId && (t.status === 'closed' || t.status === 'error'),
        )
        const txt = $('connStateText')
        if (txt) {
          txt.textContent = deadTerm ? '已断开' : '未连接'
          txt.style.color = ''
        }
        setConnStateLabel(deadTerm ? 'disconnected' : 'idle')
        if (d && deadTerm) d.classList.add('err')
      }
    }
  }

  /** 侧栏「已连接/未连接」按钮：手动断连或连接/重连 */
  async function onConnToggleClick(e) {
    if (e) {
      e.preventDefault?.()
      e.stopPropagation?.()
    }
    const btn = $('btnConnToggle')
    if (!btn || btn.disabled || btn.classList.contains('is-busy') || btn.dataset.busy === '1') return
    const mode = btn.dataset.mode || 'idle'
    btn.dataset.busy = '1'
    try {
      if (mode === 'connected') {
        await disconnectActive()
      } else {
        // 未连接 / 已断开 → 优先重连死会话，否则连当前主机，再否则打开连接管理器
        const dead =
          (state.tabs || []).find(
            (t) => t.type === 'term' && t.hostId && (t.status === 'closed' || t.status === 'error'),
          ) || null
        if (dead) {
          await doReconnect()
        } else if (state.activeHostId || state.mgrSelectedId) {
          const id = state.activeHostId || state.mgrSelectedId
          await connectHost(id, passwordVault.get(id))
        } else {
          try {
            showModal('connMgrModal', true)
            renderConnMgr()
          } catch (_) {
            toast('请先在连接管理器选择主机', true)
          }
        }
      }
    } finally {
      btn.dataset.busy = ''
      try {
        updateConnectionStatusFromTab()
        renderStatus()
      } catch (_) {}
    }
  }

  async function onConnStateLabelActivate(e) {
    // 兼容旧入口：统一走 toggle
    return onConnToggleClick(e)
  }

  // ── tool tabs: process / network / route ───────────────
  async function openToolTab(type) {
    const host = currentHost()
    const tabS = sessionTab()
    if (!tabS?.sessionId) return toast('请先连接主机', true)
    const name = host?.name || host?.host || 'session'
    const titles = { process: '进程', network: '网络', route: '路由' }
    const tab = {
      id: 'tab_' + Date.now().toString(36),
      type,
      title: `${titles[type] || type}-${name}`,
      hostId: tabS.hostId,
      sessionId: tabS.sessionId,
      status: 'connected',
      sftpPath: tabS.sftpPath,
    }
    state.tabs.push(tab)
    await switchTab(tab.id)
  }

  async function renderToolTab(tab) {
    const bar = $('toolToolbar')
    const body = $('toolBody')
    if (!bar || !body) return
    if (tab.type === 'process') {
      bar.innerHTML = `<button type="button" class="mini-btn" id="toolRefresh">刷新</button>
        <button type="button" class="mini-btn" id="toolKill">结束进程</button>
        <span class="inline-lab" id="toolHint">选中后结束</span>`
      body.innerHTML = '<div class="lm-empty">加载中…</div>'
      $('toolRefresh').onclick = () => fillProcessTable(tab, body)
      $('toolKill').onclick = async () => {
        if (!state.selectedProcPid) return toast('请选中进程')
        if (!(await askConfirm('结束 PID ' + state.selectedProcPid + ' ?', { title: '结束进程' }))) return
        await api.kill(tab.sessionId, state.selectedProcPid, 'TERM')
        toast('已发送 SIGTERM')
        fillProcessTable(tab, body)
      }
      await fillProcessTable(tab, body)
    } else if (tab.type === 'network') {
      bar.innerHTML = `<button type="button" class="mini-btn" id="toolRefresh">刷新</button>`
      body.innerHTML = '<div class="lm-empty">加载中…</div>'
      $('toolRefresh').onclick = () => fillNetworkTable(tab, body)
      await fillNetworkTable(tab, body)
    } else if (tab.type === 'route') {
      bar.innerHTML = `<input id="routeTarget" class="thin-input" value="1.1.1.1" style="width:160px" />
        <button type="button" class="mini-btn" id="toolRefresh">Ping/Trace</button>`
      body.innerHTML = '<pre id="routeOut" style="padding:12px;font:12px var(--mono),monospace;white-space:pre-wrap">点击 Ping/Trace</pre>'
      $('toolRefresh').onclick = async () => {
        const host = $('routeTarget').value.trim() || '1.1.1.1'
        $('routeOut').textContent = '探测中…'
        const ping = await api.exec(tab.sessionId, `ping -c 4 -W 2 ${shellQuote(host)} 2>&1`)
        const tr = await api.exec(
          tab.sessionId,
          `traceroute -n -w 1 -q 1 -m 12 ${shellQuote(host)} 2>&1 || tracepath ${shellQuote(host)} 2>&1`,
        )
        $('routeOut').textContent =
          '=== PING ===\n' +
          (ping.stdout || ping.stderr || '') +
          '\n\n=== TRACE ===\n' +
          (tr.stdout || tr.stderr || '')
      }
    }
  }

  async function fillProcessTable(tab, body) {
    const r = await api.processes(tab.sessionId)
    if (!r?.ok) {
      body.innerHTML = `<div class="lm-empty">${esc(r?.error || 'fail')}</div>`
      return
    }
    body.innerHTML = `<table class="tool-table"><thead><tr>
      <th>PID</th><th>用户</th><th>内存</th><th>CPU</th><th>名称 | 命令行</th><th>位置</th>
    </tr></thead><tbody>
    ${(r.rows || [])
      .map(
        (row) => `<tr data-pid="${esc(row.pid)}">
      <td>${esc(row.pid)}</td><td>${esc(row.user)}</td><td>${esc(row.mem)}</td>
      <td>${esc(row.cpu)}</td><td>${esc(row.name)} | ${esc(row.command)}</td>
      <td>${esc(row.location || '')}</td></tr>`,
      )
      .join('')}
    </tbody></table>`
    body.querySelectorAll('tr[data-pid]').forEach((tr) => {
      tr.onclick = () => {
        body.querySelectorAll('tr').forEach((x) => x.classList.remove('selected'))
        tr.classList.add('selected')
        state.selectedProcPid = tr.dataset.pid
      }
    })
  }

  async function fillNetworkTable(tab, body) {
    const r = await api.network(tab.sessionId)
    if (!r?.ok) {
      body.innerHTML = `<div class="lm-empty">${esc(r?.error || 'fail')}</div>`
      return
    }
    body.innerHTML = `<table class="tool-table"><thead><tr>
      <th>PID</th><th>名称</th><th>监听IP</th><th>端口</th><th>协议</th><th>状态</th>
    </tr></thead><tbody>
    ${(r.rows || [])
      .map(
        (row) => `<tr>
      <td>${esc(row.pid)}</td><td>${esc(row.name)}</td><td>${esc(row.listenIp)}</td>
      <td>${esc(row.port)}</td><td>${esc(row.proto)}</td><td>${esc(row.state)}</td></tr>`,
      )
      .join('')}
    </tbody></table>`
  }

  function formatBytesHuman(n) {
    const v = Number(n)
    if (!Number.isFinite(v) || v < 0) return '-'
    if (v < 1024) return v + ' B'
    if (v < 1024 * 1024) return (v / 1024).toFixed(1).replace(/\.0$/, '') + ' KB'
    if (v < 1024 * 1024 * 1024) return (v / 1024 / 1024).toFixed(1).replace(/\.0$/, '') + ' MB'
    if (v < 1024 * 1024 * 1024 * 1024) return (v / 1024 / 1024 / 1024).toFixed(2).replace(/\.00$/, '') + ' GB'
    return (v / 1024 / 1024 / 1024 / 1024).toFixed(2) + ' TB'
  }

  function formatKbHuman(kb) {
    return formatBytesHuman(Number(kb) * 1024)
  }

  function siRow(label, value) {
    return `<tr><th>${esc(label)}</th><td>${esc(value == null || value === '' ? '-' : String(value))}</td></tr>`
  }

  async function fillSysInfo(tab) {
    const host = $('sysInfoHost') || $('infoOut')?.parentElement
    const out = $('infoOut')
    if (!out) return
    const sid = tab.sessionId || sessionTab()?.sessionId
    if (!sid) {
      const view = $('sysInfoView')
      if (view) view.innerHTML = '<div class="lm-empty">未连接</div>'
      else out.textContent = '未连接'
      if ($('sysInfoHint')) $('sysInfoHint').textContent = '未连接'
      return
    }
    // structured container
    let wrap = $('sysInfoPanel')
    if (!wrap) {
      if (host) {
        host.innerHTML =
          '<div class="sysinfo-toolbar"><button type="button" class="mini-btn" id="btnSysInfoRefresh">刷新</button><span class="sysinfo-hint" id="sysInfoHint">采集中…</span></div><div id="sysInfoView" class="sysinfo-view"></div><pre id="infoOut" hidden></pre>'
        wrap = $('sysInfoView')
        const btn = $('btnSysInfoRefresh')
        if (btn) btn.onclick = () => fillSysInfo(tab)
      } else {
        out.textContent = '加载中…'
      }
    } else {
      wrap.innerHTML = '<div class="lm-empty">采集中…</div>'
      if ($('sysInfoHint')) $('sysInfoHint').textContent = '采集中…'
    }
    wrap = $('sysInfoView') || out

    let r
    try {
      if (api.sysinfo) r = await api.sysinfo(sid)
      else {
        // fallback multi-exec for older preload
        r = { ok: false, error: 'sysinfo API 不可用' }
      }
    } catch (e) {
      r = { ok: false, error: e.message || String(e) }
    }

    if (!r?.ok || !r.data) {
      const msg = r?.error || '采集失败'
      if (wrap.id === 'sysInfoView') wrap.innerHTML = `<div class="lm-empty">${esc(msg)}</div>`
      else wrap.textContent = msg
      if ($('sysInfoHint')) $('sysInfoHint').textContent = '失败'
      return
    }
    const d = r.data
    const memUsed = d.memUsedKb ? formatKbHuman(d.memUsedKb) : ''
    const memTotal = d.memTotalKb ? formatKbHuman(d.memTotalKb) : ''
    const memLine =
      memTotal && d.memPct != null
        ? `${d.memPct}%  ${memUsed} / ${memTotal}`
        : d.mem || '-'
    const swUsed = d.swapUsedKb ? formatKbHuman(d.swapUsedKb) : ''
    const swTotal = d.swapTotalKb ? formatKbHuman(d.swapTotalKb) : ''
    const swLine =
      Number(d.swapTotalKb) > 0
        ? `${d.swapPct || 0}%  ${swUsed} / ${swTotal}`
        : '无'

    const cpuPctRows = [
      ['用户', d.cpuUser],
      ['系统', d.cpuSystem],
      ['Nice', d.cpuNice],
      ['空闲', d.cpuIdle],
      ['IO等待', d.cpuIowait],
      ['硬中断', d.cpuIrq],
      ['软中断', d.cpuSoftirq],
      ['Steal', d.cpuSteal],
    ]
      .filter((x) => x[1] !== '' && x[1] != null)
      .map(([k, v]) => siRow(k, (v != null ? v : '-') + '%'))
      .join('')

    const cpuTable =
      (d.cpuRows || []).length > 0
        ? `<table class="tool-table sysinfo-table"><thead><tr>
            <th>#</th><th>型号</th><th>MHz</th><th>缓存</th><th>BogoMIPS</th>
          </tr></thead><tbody>
          ${d.cpuRows
            .map(
              (row) => `<tr>
            <td>${esc(row.id)}</td><td>${esc(row.model || d.cpuModel || '-')}</td>
            <td>${esc(row.mhz || '-')}</td><td>${esc(row.cache || '-')}</td>
            <td>${esc(row.bogomips || '-')}</td></tr>`,
            )
            .join('')}
          </tbody></table>`
        : `<table class="tool-table sysinfo-kv"><tbody>${siRow('型号', d.cpuModel)}${siRow('逻辑核数', d.cpuCount)}</tbody></table>`

    const netTable =
      (d.netRows || []).length > 0
        ? `<table class="tool-table sysinfo-table"><thead><tr>
            <th>网卡</th><th>IPv4</th><th>MAC</th><th>接收</th><th>发送</th>
          </tr></thead><tbody>
          ${d.netRows
            .map(
              (row) => `<tr>
            <td>${esc(row.name)}</td><td>${esc(row.ip || '-')}</td><td>${esc(row.mac || '-')}</td>
            <td>${esc(row.rx !== '' && row.rx != null ? formatBytesHuman(row.rx) : '-')}</td>
            <td>${esc(row.tx !== '' && row.tx != null ? formatBytesHuman(row.tx) : '-')}</td></tr>`,
            )
            .join('')}
          </tbody></table>`
        : '<div class="lm-empty">无网卡数据</div>'

    const diskTable =
      (d.disks || []).length > 0
        ? `<table class="tool-table sysinfo-table"><thead><tr>
            <th>挂载点</th><th>文件系统</th><th>容量</th><th>已用</th><th>可用</th><th>使用率</th>
          </tr></thead><tbody>
          ${d.disks
            .map(
              (row) => `<tr>
            <td>${esc(row.mount)}</td><td>${esc(row.fs || '-')}</td>
            <td>${esc(row.size)}</td><td>${esc(row.used)}</td>
            <td>${esc(row.avail)}</td><td>${esc(row.pct)}</td></tr>`,
            )
            .join('')}
          </tbody></table>`
        : '<div class="lm-empty">无磁盘数据</div>'

    const loadTxt =
      d.load1 || d.load
        ? d.load1
          ? `${d.load1} / ${d.load5 || '-'} / ${d.load15 || '-'}`
          : d.load
        : '-'

    const html = `
      <div class="sysinfo-grid">
        <section class="sysinfo-card">
          <h3>基本信息</h3>
          <table class="tool-table sysinfo-kv"><tbody>
            ${siRow('主机名', d.hostname)}
            ${siRow('操作系统', d.osPretty)}
            ${siRow('内核', (d.kernelName || '') + ' ' + (d.kernelRelease || ''))}
            ${siRow('架构', d.machine)}
            ${siRow('运行时间', d.uptimeHuman || d.uptime)}
            ${siRow('负载 (1/5/15)', loadTxt)}
            ${siRow('主 IP', d.ip)}
            ${siRow('uname', d.unameA)}
          </tbody></table>
        </section>
        <section class="sysinfo-card">
          <h3>内存 / 交换</h3>
          <table class="tool-table sysinfo-kv"><tbody>
            ${siRow('内存', memLine)}
            ${siRow('交换', swLine)}
            ${siRow('CPU 忙碌', d.cpuBusy != null && d.cpuBusy !== '' ? d.cpuBusy + '%' : '-')}
            ${siRow('逻辑 CPU', d.cpuCount || (d.cpuRows || []).length || '-')}
          </tbody></table>
          ${cpuPctRows ? `<h4 class="sysinfo-sub">CPU 时间占比（启动累计）</h4><table class="tool-table sysinfo-kv"><tbody>${cpuPctRows}</tbody></table>` : ''}
        </section>
        <section class="sysinfo-card sysinfo-wide">
          <h3>处理器</h3>
          ${cpuTable}
        </section>
        <section class="sysinfo-card sysinfo-wide">
          <h3>网卡</h3>
          ${netTable}
        </section>
        <section class="sysinfo-card sysinfo-wide">
          <h3>磁盘</h3>
          ${diskTable}
        </section>
      </div>`

    if (wrap.id === 'sysInfoView') {
      wrap.innerHTML = html
    } else if (host) {
      host.innerHTML =
        '<div class="sysinfo-toolbar"><button type="button" class="mini-btn" id="btnSysInfoRefresh">刷新</button><span class="sysinfo-hint" id="sysInfoHint">完成</span></div><div id="sysInfoView" class="sysinfo-view"></div><pre id="infoOut" hidden></pre>'
      $('sysInfoView').innerHTML = html
      const btn = $('btnSysInfoRefresh')
      if (btn) btn.onclick = () => fillSysInfo(tab)
    } else {
      wrap.innerHTML = html
    }
    if ($('sysInfoHint')) $('sysInfoHint').textContent = '已更新 · ' + new Date().toLocaleTimeString()
  }

  // ── hosts / conn mgr ───────────────────────────────────

  function openHostListTab() {
    openConnMgr()
  }

  function renderConnMgr() {
    // 列表模式：统一走 host-browser 抽屉，不再渲染 table 行（table 会把 flex 行挤成竖排叠字）
    restorePageHostBrowserId()
    const mount = ensureConnMgrListMount()
    if (mount) {
      // 同步工具栏搜索到 host browser 过滤
      if ($('mgrFilter') && state.mgrFilter != null) {
        state.hostBrowserFilter = state.mgrFilter
      }
      renderHostBrowserInto(mount)
      return
    }
    // 无 mount 时的兜底（极老 DOM）
    const body = $('connMgrBody')
    if (!body) return
    body.innerHTML =
      '<tr><td colspan="5" class="empty">列表挂载失败 — 请完全退出后重启 PixShell</td></tr>'
  }

  // ── 服务器头像：默认软件 logo；连上并读到系统后换成对应发行版 logo ──
  const OS_ICON_MAP = {
    ubuntu: 'ubuntu', kubuntu: 'ubuntu', xubuntu: 'ubuntu', pop: 'ubuntu', elementary: 'ubuntu',
    debian: 'debian', raspbian: 'debian', devuan: 'debian',
    centos: 'centos', rhel: 'redhat', redhat: 'redhat', fedora: 'fedora',
    rocky: 'rocky', almalinux: 'almalinux', alma: 'almalinux',
    alpine: 'alpine', arch: 'arch', manjaro: 'arch', endeavouros: 'arch',
    opensuse: 'opensuse', 'opensuse-leap': 'opensuse', 'opensuse-tumbleweed': 'opensuse', suse: 'opensuse', sles: 'opensuse',
    amzn: 'amazon', amazon: 'amazon', ol: 'oracle', oracle: 'oracle',
    kali: 'kali', linuxmint: 'mint', mint: 'mint',
  }
  function osIconFile(osId) {
    const k = String(osId || '').toLowerCase().trim()
    if (!k) return ''
    if (OS_ICON_MAP[k]) return OS_ICON_MAP[k]
    if (k.includes('ubuntu')) return 'ubuntu'
    if (k.includes('debian')) return 'debian'
    if (k.includes('cent')) return 'centos'
    if (k.includes('rhel') || k.includes('red hat') || k.includes('redhat')) return 'redhat'
    if (k.includes('fedora')) return 'fedora'
    if (k.includes('rocky')) return 'rocky'
    if (k.includes('alma')) return 'almalinux'
    if (k.includes('alpine')) return 'alpine'
    if (k.includes('arch')) return 'arch'
    if (k.includes('suse')) return 'opensuse'
    if (k.includes('amazon') || k === 'amzn') return 'amazon'
    if (k.includes('kali')) return 'kali'
    return 'linux' // 已知 linux 但发行版不明 → 通用企鹅
  }
  function hostAvatarSrc(h) {
    const f = osIconFile(h && h.osId)
    return f ? './icons/os/' + f + '.svg' : './icons/logo.svg'
  }
  /** 头像内 <img>：填满头像块；未连接/未知系统 → 软件 logo */
  function hostAvatarImg(h) {
    return '<img class="host-os-icon" src="' + esc(hostAvatarSrc(h)) + '" alt="" draggable="false" />'
  }

  /** 连接成功后把主机记入快速连接历史（去重、置顶、上限 30） */
  function recordRecentHost(hostId) {
    if (!hostId) return
    const s = state.settings || (state.settings = {})
    const prev = Array.isArray(s.recentHosts) ? s.recentHosts.filter((x) => x !== hostId) : []
    prev.unshift(hostId)
    s.recentHosts = prev.slice(0, 30)
    if (hasApi && api.saveSettings) api.saveSettings(s).catch((e) => console.warn('[recentHosts save]', e))
    try { renderQuickConnect() } catch (_) {}
  }

  /** 连上后读取服务器系统，自动把头像换成对应发行版 logo（持久化到主机） */
  async function detectHostOs(hostId, sessionId) {
    if (!hasApi || !api.sysinfo || !sessionId || !hostId) return
    let r
    try { r = await api.sysinfo(sessionId) } catch (_) { return }
    const d = (r && r.ok && r.data) || null
    if (!d) return
    const osId = String(d.osId || '').toLowerCase().trim()
    if (!osId) return
    const h = state.hosts.find((x) => x.id === hostId)
    if (!h) return
    const pretty = d.osPretty && d.osPretty !== '-' ? d.osPretty : ''
    if (h.osId === osId && h.osPretty === pretty) return // 无变化
    h.osId = osId
    if (pretty) h.osPretty = pretty
    try { await persistHosts() } catch (_) {}
    try { renderQuickConnect() } catch (_) {}
    try { renderConnMgr() } catch (_) {}
    try { renderHostBrowser && renderHostBrowser() } catch (_) {}
    // 通知已打开的浮窗连接管理器刷新头像
    try { api.floatToFloat && api.floatToFloat({ type: 'hosts-updated', hosts: state.hosts }) } catch (_) {}
  }

  function renderQuickConnect() {
    // 快速连接 = 仅历史记录，完整服务器列表在「主机列表」页
    const root = $('qcList')
    if (!root) return
    const recent = state.settings.recentHosts || []
    const ordered = recent.map((id) => state.hosts.find((h) => h.id === id)).filter(Boolean)
    const head = $('quickConnect')?.querySelector('.qc-head span')
    if (head) head.textContent = `快速连接（历史 · ${ordered.length}）`
    if (!ordered.length) {
      root.innerHTML = `
        <div class="qc-empty">
          <div class="qc-empty-title">暂无连接历史</div>
          <div class="qc-empty-desc">连接过的主机会出现在这里，点击卡片即可快速连上。</div>
          <div class="qc-empty-actions">
            <button type="button" class="cmd-btn primary" id="qcOpenHosts">打开连接管理器</button>
            <button type="button" class="cmd-btn" id="qcNewHost">新建连接</button>
          </div>
        </div>`
      $('qcOpenHosts')?.addEventListener('click', () => openConnMgr())
      $('qcNewHost')?.addEventListener('click', () => openHostModal(null))
      return
    }
    root.innerHTML = `<div class="qc-grid">${ordered
      .map((h, idx) => {
        const title = h.name || h.host || '未命名'
        const user = h.username || 'root'
        const host = h.host || '-'
        const port = h.port || 22
        const group = h.group || '默认'
        const hasPw = !!(h.password || passwordVault.get(h.id))
        const sel = h.id === state.activeHostId ? ' selected' : ''
        const letter = String(title).trim().charAt(0).toUpperCase() || 'S'
        return `<article class="qc-card${sel}" data-id="${esc(h.id)}" tabindex="0" role="button" title="双击或点「连接」">
          <div class="qc-card-top">
            <div class="qc-avatar" aria-hidden="true">${hostAvatarImg(h)}</div>
            <div class="qc-card-titlewrap">
              <div class="qc-card-title">${esc(title)}</div>
              <div class="qc-card-sub mono">${esc(user)}@${esc(host)}</div>
            </div>
            <span class="qc-badge">${esc(group)}</span>
          </div>
          <div class="qc-card-meta">
            <span class="qc-pill">端口 ${esc(port)}</span>
            <span class="qc-pill ${hasPw ? 'ok' : 'muted'}">${hasPw ? '已记住密码' : '需输入密码'}</span>
            <span class="qc-pill muted">#${idx + 1}</span>
          </div>
          <div class="qc-card-actions">
            <button type="button" class="cmd-btn primary qc-connect" data-id="${esc(h.id)}">连接</button>
            <button type="button" class="cmd-btn qc-edit" data-id="${esc(h.id)}">编辑</button>
          </div>
        </article>`
      })
      .join('')}</div>`

    root.querySelectorAll('.qc-card').forEach((el) => {
      const id = el.dataset.id
      const select = () => {
        state.activeHostId = id
        state.mgrSelectedId = id
        root.querySelectorAll('.qc-card.selected').forEach((x) => x.classList.remove('selected'))
        el.classList.add('selected')
      }
      el.addEventListener('click', (e) => {
        if (e.target.closest('button')) return
        select()
      })
      el.addEventListener('dblclick', (e) => {
        e.preventDefault()
        select()
        connectHost(id)
      })
      el.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          select()
          connectHost(id)
        }
      })
    })
    root.querySelectorAll('.qc-connect').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation()
        const id = btn.dataset.id
        state.activeHostId = id
        connectHost(id)
      })
    })
    root.querySelectorAll('.qc-edit').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation()
        openHostModal(btn.dataset.id)
      })
    })
  }

  // ── command board ──────────────────────────────────────
  function getQuickList() {
    if (state.quick?.length) return state.quick
    return [
      { name: 'df -h', command: 'df -h\n', group: '系统' },
      { name: 'free -m', command: 'free -m\n', group: '系统' },
      { name: 'uptime', command: 'uptime\n', group: '系统' },
      { name: 'ps aux', command: 'ps aux --sort=-%cpu | head -30\n', group: '系统' },
      { name: 'ss -lntp', command: 'ss -lntp\n', group: '网络' },
      { name: 'docker ps', command: 'docker ps\n', group: 'docker' },
    ]
  }


  // ── 快捷命令：选项面板 + 右键菜单 ─────────────────────
  let _cmdEditIndex = -1 // index in full getQuickList / state.quick

  function ensureQuickMutable() {
    if (!Array.isArray(state.quick) || !state.quick.length) {
      state.quick = getQuickList().map((q) => ({ ...q }))
    }
    return state.quick
  }

  async function persistQuickList() {
    ensureQuickMutable()
    if (hasApi && api.saveQuick) {
      try {
        await api.saveQuick(state.quick)
      } catch (e) {
        toast('保存快捷命令失败: ' + (e && e.message ? e.message : e), true)
        return false
      }
    }
    try {
      renderCmdBoard()
    } catch (_) {}
    return true
  }

  function openCmdOptionsPanel() {
    showModal('cmdOptModal', true)
    makeModalFloatDraggable('cmdOptModal', { title: '命令板选项', halfW: 260 })
    paintCmdOptList()
  }

  function paintCmdOptList() {
    const box = $('cmdOptList')
    if (!box) return
    const list = ensureQuickMutable()
    if (!list.length) {
      box.innerHTML = '<div class="cmd-hist-empty">暂无命令，点「新建命令」添加</div>'
      return
    }
    box.innerHTML = list
      .map((q, i) => {
        return (
          '<div class="cmd-opt-row" data-i="' +
          i +
          '">' +
          '<span class="cmd-opt-name" title="' +
          esc((q.command || '').trim()) +
          '">[' +
          esc(q.group || '默认') +
          '] ' +
          esc(q.name || '未命名') +
          '</span>' +
          '<button type="button" class="mini-btn" data-cmd-act="edit" data-i="' +
          i +
          '">编辑</button>' +
          '<button type="button" class="mini-btn" data-cmd-act="send" data-i="' +
          i +
          '">发送</button>' +
          '<button type="button" class="mini-btn" data-cmd-act="del" data-i="' +
          i +
          '">删除</button>' +
          '</div>'
        )
      })
      .join('')
    box.querySelectorAll('[data-cmd-act]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation()
        const i = Number(btn.getAttribute('data-i'))
        const act = btn.getAttribute('data-cmd-act')
        const list2 = ensureQuickMutable()
        const q = list2[i]
        if (!q) return
        if (act === 'edit') openCmdEditModal(i)
        else if (act === 'send') {
          showModal('cmdOptModal', false)
          await sendQuick(q)
        } else if (act === 'del') {
          if (!(await askConfirm('删除命令「' + (q.name || '') + '」？', { title: '删除快捷命令', danger: true })))
            return
          list2.splice(i, 1)
          await persistQuickList()
          paintCmdOptList()
        }
      })
    })
  }

  function openCmdEditModal(index) {
    ensureQuickMutable()
    _cmdEditIndex = index
    const q =
      index >= 0 && state.quick[index]
        ? state.quick[index]
        : { name: '', group: state.activeCmdGroup || '默认分类', command: '' }
    if ($('cmdEditName')) $('cmdEditName').value = q.name || ''
    if ($('cmdEditGroup')) $('cmdEditGroup').value = q.group || '默认分类'
    if ($('cmdEditBody')) $('cmdEditBody').value = (q.command || '').replace(/\n$/, '')
    showModal('cmdEditModal', true)
    makeModalFloatDraggable('cmdEditModal', { title: '编辑快捷命令', halfW: 240 })
  }

  async function saveCmdEditModal() {
    const name = ($('cmdEditName')?.value || '').trim() || '未命名'
    const group = ($('cmdEditGroup')?.value || '').trim() || '默认分类'
    let command = $('cmdEditBody')?.value || ''
    if (command && !command.endsWith('\n')) command += '\n'
    ensureQuickMutable()
    const row = { name, group, command }
    if (_cmdEditIndex >= 0 && _cmdEditIndex < state.quick.length) state.quick[_cmdEditIndex] = row
    else state.quick.push(row)
    await persistQuickList()
    showModal('cmdEditModal', false)
    toast('已保存命令')
    if (!$('cmdOptModal')?.hidden) paintCmdOptList()
  }

  function showCmdChipContextMenu(x, y, index) {
    removeCtx()
    const list = ensureQuickMutable()
    const q = list[index]
    if (!q) return
    const menu = document.createElement('div')
    menu.className = 'ctx-menu'
    menu.style.left = Math.max(4, x) + 'px'
    menu.style.top = Math.max(4, y) + 'px'
    const items = [
      ['send', '发送'],
      ['edit', '编辑'],
      ['copy', '复制命令'],
      ['dup', '复制为新命令'],
      ['del', '删除'],
    ]
    menu.innerHTML = items
      .map(([a, lab]) => '<button type="button" class="ctx-item" data-act="' + a + '">' + lab + '</button>')
      .join('')
    document.body.appendChild(menu)
    bindCtxDismiss()
    menu.querySelectorAll('[data-act]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation()
        const act = btn.getAttribute('data-act')
        removeCtx()
        if (act === 'send') await sendQuick(q)
        else if (act === 'edit') openCmdEditModal(index)
        else if (act === 'copy') {
          try {
            await navigator.clipboard.writeText((q.command || '').replace(/\n$/, ''))
            toast('已复制')
          } catch (_) {
            toast('复制失败', true)
          }
        } else if (act === 'dup') {
          ensureQuickMutable()
          state.quick.splice(index + 1, 0, {
            name: (q.name || '命令') + ' 副本',
            group: q.group,
            command: q.command,
          })
          await persistQuickList()
          toast('已复制为新命令')
        } else if (act === 'del') {
          if (!(await askConfirm('删除「' + (q.name || '') + '」？', { title: '删除', danger: true }))) return
          ensureQuickMutable()
          state.quick.splice(index, 1)
          await persistQuickList()
        }
      })
    })
  }

  function renderCmdBoard() {
    const list = getQuickList()
    const groups = []
    for (const q of list) {
      const g = q.group || '默认分类'
      if (!groups.includes(g)) groups.push(g)
    }
    if (!state.activeCmdGroup) state.activeCmdGroup = groups[0]
    const bar = document.createElement('div')
    bar.className = 'cmd-group-bar'
    bar.innerHTML = groups
      .map(
        (g) =>
          `<button type="button" class="cmd-group-chip ${g === state.activeCmdGroup ? 'active' : ''}" data-g="${esc(g)}"><img class="px-ico" src="./icons/dir_icon.png" alt="" />${esc(g)}</button>`,
      )
      .join('')
    const chips = $('cmdChips')
    if (!chips) return
    const parent = chips.parentElement
    let existing = parent.querySelector('.cmd-group-bar')
    if (existing) existing.remove()
    parent.insertBefore(bar, chips)
    bar.querySelectorAll('[data-g]').forEach((b) => {
      b.onclick = () => {
        state.activeCmdGroup = b.dataset.g
        renderCmdBoard()
      }
    })
    const items = list.filter((q) => (q.group || '默认分类') === state.activeCmdGroup)
    chips.innerHTML = items
      .map(
        (q, i) =>
          `<button type="button" class="cmd-chip" data-i="${i}" title="${esc((q.command || '').trim())}">${esc(q.name)} <span class="gear">⚙</span></button>`,
      )
      .join('')
    chips.querySelectorAll('.cmd-chip').forEach((btn) => {
      const localI = Number(btn.dataset.i)
      const q = items[localI]
      const fullList = ensureQuickMutable()
      const fullI = fullList.findIndex(
        (x) => x === q || (x.name === q.name && x.command === q.command && (x.group || '默认分类') === (q.group || '默认分类')),
      )
      btn.onclick = (ev) => {
        if (ev.target && ev.target.classList && ev.target.classList.contains('gear')) {
          ev.preventDefault()
          ev.stopPropagation()
          openCmdEditModal(fullI >= 0 ? fullI : -1)
          return
        }
        state.selectedChipCmd = q
        chips.querySelectorAll('.cmd-chip').forEach((b) => b.classList.toggle('selected', b === btn))
        if ($('cmdEditor')) $('cmdEditor').value = (q.command || '').replace(/\n$/, '')
      }
      btn.ondblclick = () => sendQuick(q)
      btn.oncontextmenu = (ev) => {
        ev.preventDefault()
        ev.stopPropagation()
        state.selectedChipCmd = q
        chips.querySelectorAll('.cmd-chip').forEach((b) => b.classList.toggle('selected', b === btn))
        showCmdChipContextMenu(ev.clientX, ev.clientY, fullI >= 0 ? fullI : 0)
      }
    })
    fillCmdTargets()
  }

  /** 已连接的 SSH 终端标签（可接收快捷命令） */
  function listConnectedTermTabs() {
    return (state.tabs || []).filter(
      (t) => t && t.type === 'term' && t.sessionId && t.status === 'connected',
    )
  }

  function tabSendLabel(t) {
    if (!t) return '会话'
    const h = (state.hosts || []).find((x) => x.id === t.hostId)
    const name = (t.title || h?.name || h?.host || '').trim()
    const host = (t.host || h?.host || '').trim()
    if (name && host && name !== host) return name + ' · ' + host
    return name || host || t.sessionId || t.id || '会话'
  }

  /** 刷新「发送到」下拉：当前 / 全部 / 各已连接会话 */
  function fillCmdTargets() {
    const sel = $('cmdTarget')
    if (!sel) return
    const prev = sel.value || 'current'
    const tabs = listConnectedTermTabs()
    const opts = [
      { value: 'current', label: '当前会话' },
      { value: 'all', label: '所有已连接会话' + (tabs.length ? '（' + tabs.length + '）' : '') },
    ]
    for (const t of tabs) {
      opts.push({ value: 'tab:' + t.id, label: tabSendLabel(t) })
    }
    sel.innerHTML = opts
      .map((o) => '<option value="' + esc(o.value) + '">' + esc(o.label) + '</option>')
      .join('')
    if (opts.some((o) => o.value === prev)) sel.value = prev
    else sel.value = 'current'
  }

  function resolveCmdTargetTabs() {
    const v = String($('cmdTarget')?.value || 'current')
    if (v === 'all') return listConnectedTermTabs()
    if (v.startsWith('tab:')) {
      const id = v.slice(4)
      const t = (state.tabs || []).find((x) => x.id === id)
      return t && t.sessionId && t.status === 'connected' ? [t] : []
    }
    // current
    const t = sessionTab()
    if (t?.sessionId && (t.status === 'connected' || t.status === 'reconnecting')) return [t]
    const live = listConnectedTermTabs()
    return live.length ? [live[0]] : []
  }

  async function sendQuick(q) {
    if (!q) return
    let cmd = q.command || ''
    if (cmd.includes('${')) {
      const names = [...cmd.matchAll(/\$\{([a-zA-Z0-9_]+)\}/g)].map((m) => m[1])
      const uniq = [...new Set(names)]
      for (const n of uniq) {
        const v = await askPrompt('参数 ' + n, '', { title: '命令参数' })
        if (v === null) return
        cmd = cmd.split('${' + n + '}').join(v)
      }
    }
    if (!hasApi || typeof api.write !== 'function') return toast('SSH 不可用', true)
    const targets = resolveCmdTargetTabs()
    if (!targets.length) return toast('请先连接主机', true)
    if (!cmd.endsWith('\n')) cmd += '\n'
    let ok = 0
    const fails = []
    for (const tab of targets) {
      try {
        const r = await api.write(tab.sessionId, cmd)
        if (r && r.ok === false) fails.push(tabSendLabel(tab) + ': ' + (r.error || 'fail'))
        else ok++
      } catch (e) {
        fails.push(tabSendLabel(tab) + ': ' + (e && e.message ? e.message : e))
      }
    }
    const label = q.name || cmd.trim().slice(0, 24)
    if (fails.length && !ok) toast('发送失败: ' + fails[0], true)
    else if (fails.length) toast('已发送 ' + ok + '/' + targets.length + ' · ' + label + '（部分失败）', true)
    else if (targets.length > 1) toast('已发送到 ' + ok + ' 个会话: ' + label)
    else toast('已发送: ' + label)
  }

  async function sendCommand() {
    const input = $('cmd')
    let raw = input.value
    if (!raw.trim()) return
    const tab = sessionTab()
    if (!tab?.sessionId) {
      toast('请先连接主机', true)
      return
    }
    state.history = [raw, ...state.history.filter((h) => h !== raw)].slice(0, 500)
    state.histIndex = -1
    const data = raw.endsWith('\n') ? raw : raw + '\n'
    await api.write(tab.sessionId, data)
    if (state.settings.syncDirWithSftp === true && /^\s*cd\b/.test(raw)) handleCdLine(raw)
    if (state.settings.commandInput?.cleanAfterSend !== false) input.value = ''
    input.focus()
  }

  // ── status / hosts persist ─────────────────────────────
  function renderStatus() {
    try { fillCmdTargets() } catch (_) {}
    const tab = currentTab()
    // 底栏不再显示「SSH 已连接 …」（侧栏已有连接状态）；statusHost 永久隐藏
    const sh = $('statusHost')
    if (sh) {
      sh.hidden = true
      sh.setAttribute('hidden', '')
      sh.textContent = ''
    }
    updateConnectionStatusFromTab()
    updateBrandForSession()
    // 左下角 statusLine 专用于外部 CLI 状态（异步刷新，不覆盖）
    refreshCliStatusBar()
    const ban = $('reconnectBanner')
    if (ban) ban.classList.toggle('show', tab?.status === 'reconnecting')
  }

  function detectPlatformClass() {
    const uaPlat = (navigator.userAgentData && navigator.userAgentData.platform) || ''
    const plat = navigator.platform || ''
    if (/mac/i.test(uaPlat) || /Mac|iPhone|iPod|iPad/.test(plat)) return 'is-mac'
    return 'is-win'
  }

  function applyBodyChromeClasses(theme) {
    const m = theme === 'light' ? 'light' : 'dark'
    const plat = detectPlatformClass()
    document.body.className = [m === 'light' ? 'theme-light' : 'theme-dark', plat].join(' ')
    document.documentElement.style.colorScheme = m
    // keep native window chrome in sync if host supports it
    try {
      document.querySelector('meta[name="color-scheme"]')?.setAttribute('content', m)
    } catch (_) {}
  }

  function setThemeMode(mode, { persist = true } = {}) {
    const m = mode === 'light' ? 'light' : 'dark'
    state.settings = state.settings || {}
    state.settings.theme = m
    // 主题切换时清掉与当前明暗不兼容的终端背景粘滞，避免暗色被浅灰 override 盖住
    scrubIncompatibleTermBgOverride(state.settings, m, { persist: false })
    applyBodyChromeClasses(m)
    // 主窗背景色同步，避免 titlebar 露深色/白边
    try {
      if (hasApi && typeof api.setWindowBackground === 'function') {
        api.setWindowBackground(m === 'light' ? '#ececf1' : '#181825')
      }
    } catch (_) {}
    const btn = $('btnThemeToggle')
    if (btn) {
      btn.textContent = m === 'light' ? '☀' : '☾'
      btn.title = m === 'light' ? '切换到深色主题' : '切换到浅色主题'
    }
    if ($('setThemeMode')) $('setThemeMode').value = m
    // 切主题后强制走方案底色（等同点一次设置预览），保证暗色首屏可读
    applyTerminalAppearance({ forceSchemeBackground: m === 'dark' }).catch((e) =>
      console.warn('[apply terminal appearance]', e),
    )
    if (persist && hasApi && api.saveSettings) api.saveSettings(state.settings).catch((e) => console.warn('[save theme]', e))
  }

  async function loadAll() {
    if (!hasApi) {
      state.hosts = []
      state.settings = {}
      return
    }
    const rawHosts = (await api.loadHosts()) || []
    state.hosts = rawHosts.map((h) => {
      if (!h || typeof h !== 'object') return h
      return {
        ...h,
        host: String(h.host || h.hostname || h.ip || '').trim(),
        username: String(h.username || h.user || h.user_name || 'root').trim(),
        port: Number(h.port) || 22,
      }
    })
    // 恢复已保存密码到内存 vault（避免每次重输）
    for (const h of state.hosts) {
      if (h && h.id && h.password) passwordVault.set(h.id, String(h.password))
    }
    state.settings = (await api.loadSettings()) || {}
    if (state.settings.syncDirWithSftp == null) state.settings.syncDirWithSftp = false
    if (!state.settings.colorScheme) state.settings.colorScheme = 'dracula'
    // 迁移：旧版 termBgOverride 粘住导致换配色/暗色发灰 — 默认不视为用户锁定
    if (state.settings.termBgUserSet == null) {
      state.settings.termBgUserSet = false
    }
    try {
      const ov = String(state.settings.termBgOverride || '').toLowerCase()
      const stickyLight = ['#c1c5cd', '#e5e5ea', '#b8b8c2', '#d4d6dc', '#ececf1', '#1e1e2e', '#2e3440']
      if (stickyLight.includes(ov) || (ov && ov === String(state.settings.termBg || '').toLowerCase() && colorLuminance(ov) >= 120)) {
        delete state.settings.termBgOverride
        delete state.settings.termBg
        state.settings.termBgUserSet = false
      }
    } catch (_) {}
    // 按当前主题再 scrub 一次（暗色拒绝浅灰 override）
    scrubIncompatibleTermBgOverride(state.settings, state.settings.theme || 'dark', { persist: true })
    if (!state.settings.cursorStyle) state.settings.cursorStyle = 'block'
    if (state.settings.cursorBlink == null) state.settings.cursorBlink = true
    if (!state.settings.termType) state.settings.termType = 'xterm-256color'
    if (state.settings.editorSyntaxHl === undefined) state.settings.editorSyntaxHl = true
    if (state.settings.editorWordWrap === undefined) state.settings.editorWordWrap = false
    if (state.settings.termLiveHighlight === undefined) state.settings.termLiveHighlight = true
    if (state.settings.drawBoldTextInBrightColors === undefined) state.settings.drawBoldTextInBrightColors = true
    if (!state.settings.fontFamily) {
      state.settings.fontFamily = DEFAULT_TERM_FONT_FAMILY
    }
    setThemeMode(state.settings.theme || 'dark')
    try {
      state.quick = (await api.loadQuick()) || []
    } catch (_) {
      state.quick = []
    }
    if (state.settings.layout?.sidebarWidth) {
      document.documentElement.style.setProperty('--sidebar-w', state.settings.layout.sidebarWidth + 'px')
    }
    if (state.settings.layout?.bottomHeight) {
      document.documentElement.style.setProperty('--bottom-h', state.settings.layout.bottomHeight + 'px')
    }
    try {
      // 暗色首屏直接走方案底 + 对比抬升，不依赖「先点设置」
      const bootForce = (state.settings?.theme || 'dark') !== 'light'
      await applyTerminalAppearance({ forceSchemeBackground: bootForce })
    } catch (e) {
      console.warn('[loadAll appearance]', e)
    }
    // 下一帧再刷一次，避免首屏 canvas 在 layout 未稳定时用错误对比度栅格化
    try {
      requestAnimationFrame(() => {
        const bootForce = (state.settings?.theme || 'dark') !== 'light'
        applyTerminalAppearance({ forceSchemeBackground: bootForce }).catch((e) =>
          console.warn('[loadAll appearance rAF]', e),
        )
      })
    } catch (_) {}
    try {
      applyCmdEditorCollapsed(!!(state.settings && state.settings.cmdEditorCollapsed))
    } catch (_) {}
    // 版本号
    try {
      if (hasApi && typeof api.getAppVersion === 'function') {
        const vr = await api.getAppVersion()
        if (vr?.version) setAppVersionLabel(vr.version)
      }
    } catch (_) {}
  }

  async function persistHosts() {
    if (!hasApi) return
    let r
    try {
      r = await api.saveHosts(state.hosts)
    } catch (e) {
      try { rlog('error', 'hosts', 'saveHosts throw', { err: e && e.message }) } catch (_) {}
      toast('保存主机失败: ' + (e && e.message ? e.message : e), true)
      throw e
    }
    if (r && (r.warning || Number(r.strippedPasswords) > 0)) {
      const n = Number(r.strippedPasswords) || 0
      const msg =
        r.warning ||
        ('safeStorage 不可用：已拒绝落盘 ' + n + ' 个密码')
      try { rlog('warn', 'hosts', msg, { strippedPasswords: n }) } catch (_) {}
      toast(msg, true)
    }
    return r
  }

  // ── modals ─────────────────────────────────────────────

  function ensureProxyList() {
    state.settings = state.settings || {}
    if (!Array.isArray(state.settings.proxyList)) state.settings.proxyList = []
    return state.settings.proxyList
  }

  function proxyLabel(p) {
    if (!p) return ''
    return `${p.name || p.host || 'proxy'} (${(p.type || 'socks5').toUpperCase()} ${p.host || ''}:${p.port || ''})`
  }

  function fillProxySelect(selectedId) {
    const sel = $('fProxyId')
    if (!sel) return
    const list = ensureProxyList()
    const cur = selectedId != null ? selectedId : sel.value
    sel.innerHTML = '<option value="">不使用代理</option>' + list.map((p) => {
      const id = p.id || ''
      return `<option value="${esc(id)}">${esc(proxyLabel(p))}</option>`
    }).join('')
    if (cur && list.some((p) => p.id === cur)) sel.value = cur
    else sel.value = ''
  }

  function renderProxyTable(bodyId, selectedId) {
    const body = $(bodyId)
    if (!body) return
    const list = ensureProxyList()
    if (!list.length) {
      body.innerHTML = '<tr><td colspan="5" class="empty">暂无代理，点「添加代理」</td></tr>'
      return
    }
    body.innerHTML = list.map((p) => {
      const sel = p.id === selectedId ? ' class="selected"' : ''
      const auth = p.username ? '是' : '—'
      return `<tr data-proxy-id="${esc(p.id)}"${sel}>
        <td>${esc(p.name || p.host || '—')}</td>
        <td>${esc((p.type || 'socks5').toUpperCase())}</td>
        <td>${esc(p.host || '')}</td>
        <td>${esc(p.port || '')}</td>
        <td>${auth}</td>
      </tr>`
    }).join('')
    body.querySelectorAll('tr[data-proxy-id]').forEach((tr) => {
      tr.addEventListener('click', () => {
        state._proxySelectedId = tr.getAttribute('data-proxy-id')
        body.querySelectorAll('tr.selected').forEach((x) => x.classList.remove('selected'))
        tr.classList.add('selected')
        const sel = $('fProxyId')
        if (sel) sel.value = state._proxySelectedId || ''
      })
    })
  }

  function showProxyEditBox(proxy) {
    const box = $('proxyEditBox')
    if (!box) return
    box.hidden = false
    box.removeAttribute('hidden')
    state._proxyEditingId = proxy ? proxy.id : null
    if ($('proxyEditLegend')) $('proxyEditLegend').textContent = proxy ? '编辑代理' : '添加代理'
    if ($('pxName')) $('pxName').value = proxy?.name || ''
    if ($('pxType')) $('pxType').value = proxy?.type || 'socks5'
    if ($('pxHost')) $('pxHost').value = proxy?.host || ''
    if ($('pxPort')) $('pxPort').value = proxy?.port || 1080
    if ($('pxUser')) $('pxUser').value = proxy?.username || ''
    if ($('pxPass')) $('pxPass').value = proxy?.password || ''
  }

  function hideProxyEditBox() {
    const box = $('proxyEditBox')
    if (!box) return
    box.hidden = true
    box.setAttribute('hidden', '')
    state._proxyEditingId = null
  }

  async function saveProxyFromForm() {
    const name = ($('pxName')?.value || '').trim()
    const type = $('pxType')?.value || 'socks5'
    const host = ($('pxHost')?.value || '').trim()
    const port = parseInt($('pxPort')?.value, 10) || 0
    const username = ($('pxUser')?.value || '').trim()
    const password = $('pxPass')?.value || ''
    if (!host) return toast('请填写代理主机', true)
    if (!port || port < 1 || port > 65535) return toast('端口无效', true)
    const list = ensureProxyList()
    const id = state._proxyEditingId || ('px_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6))
    const row = {
      id,
      name: name || `${type}://${host}:${port}`,
      type,
      host,
      port,
      username: username || '',
      password: password || '',
    }
    const idx = list.findIndex((p) => p.id === id)
    if (idx >= 0) list[idx] = { ...list[idx], ...row }
    else list.push(row)
    state.settings.proxyList = list
    if (hasApi && api.saveSettings) await api.saveSettings(state.settings)
    hideProxyEditBox()
    state._proxySelectedId = id
    fillProxySelect(id)
    renderProxyTable('proxyBody', id)
    renderProxyTable('setProxyBody', id)
    toast('代理已保存')
  }

  function bindProxyUi() {
    if (state._proxyUiBound) return
    state._proxyUiBound = true
    const add = () => showProxyEditBox(null)
    const edit = () => {
      const id = state._proxySelectedId || $('fProxyId')?.value
      const p = ensureProxyList().find((x) => x.id === id)
      if (!p) return toast('请先选中代理', true)
      showProxyEditBox(p)
    }
    const del = async () => {
      const id = state._proxySelectedId || $('fProxyId')?.value
      if (!id) return toast('请先选中代理', true)
      if (!(await askConfirm('确定删除该代理配置？', { title: '删除代理', danger: true, okText: '确定删除' }))) return
      state.settings.proxyList = ensureProxyList().filter((p) => p.id !== id)
      if (hasApi && api.saveSettings) await api.saveSettings(state.settings)
      if (state._proxySelectedId === id) state._proxySelectedId = null
      fillProxySelect('')
      renderProxyTable('proxyBody', null)
      renderProxyTable('setProxyBody', null)
      toast('已删除')
    }
    on('btnProxyAdd', 'click', add)
    on('btnProxyEdit', 'click', edit)
    on('btnProxyDel', 'click', del)
    on('btnProxySave', 'click', () => { saveProxyFromForm().catch((e) => toast(String(e.message || e), true)) })
    on('btnProxyCancel', 'click', hideProxyEditBox)
  }

  function openHostModal(hostId) {
    if (!document.body.classList.contains('float-window') && hasApi && typeof api.openFloatWindow === 'function') {
      openIndependentFloat({
        kind: 'host-editor',
        id: 'host-editor',
        title: hostId ? '编辑连接' : '新建连接',
        width: 520,
        height: 400,
        init: { hostId }
      }).catch(console.error)
      return
    }
    state.editHostId = hostId
    const h = hostId ? state.hosts.find((x) => x.id === hostId) : null
    if ($('modalTitle')) $('modalTitle').textContent = h ? '编辑连接' : '新建连接'
    if ($('fName')) $('fName').value = h?.name || ''
    if ($('fGroup')) $('fGroup').value = h?.group || '默认'
    if ($('fHost')) $('fHost').value = h?.host || ''
    if ($('fPort')) $('fPort').value = h?.port || 22
    if ($('fUser')) $('fUser').value = h?.username || 'root'
    // 不回填真实密码到输入框（安全）；有已存密码时显示占位
    if ($('fPass')) {
      $('fPass').value = ''
      $('fPass').placeholder = h?.password || passwordVault.get(h?.id) ? '已保存密码（留空则沿用）' : '输入密码'
    }
    if ($('fKey')) $('fKey').value = h?.privateKeyPath || ''
    if ($('fRemark')) $('fRemark').value = h?.remark || ''
    if ($('fRememberPass')) $('fRememberPass').checked = h?.rememberPassword !== false
    if ($('fAuthMethod')) $('fAuthMethod').value = h?.authMethod || 'password'
    if ($('fCharset')) $('fCharset').value = h?.charset || 'UTF-8'
    if ($('fBackspace')) $('fBackspace').value = h?.backspace || 'ASCII'
    if ($('fDelKey')) $('fDelKey').value = h?.delKey || 'VT220'
    if ($('fProxyId')) {
      fillProxySelect(h?.proxyId || '')
      renderProxyTable('proxyBody', h?.proxyId || null)
      hideProxyEditBox()
      bindProxyUi()
    }
    if ($('fExecChannel')) $('fExecChannel').checked = h?.execChannel !== false
    // host editor left nav
    document.querySelectorAll('.hed-nav [data-hed]').forEach((b) => {
      b.classList.toggle('active', b.getAttribute('data-hed') === 'ssh')
    })
    document.querySelectorAll('.hed-pane').forEach((p) => {
      p.hidden = p.getAttribute('data-hed-pane') !== 'ssh'
    })
    showModal('hostModal', true)
    const hostWin = $('hostModal')?.querySelector('.modal')
    // 如果在浮窗内，我们重置一下可能被改过的尺寸，使其填满
    if (document.body.classList.contains('float-window') && hostWin) {
      hostWin.style.width = '100%'
      hostWin.style.height = '100%'
      hostWin.style.left = '0'
      hostWin.style.top = '0'
      hostWin.style.position = 'relative'
    }
    $('fHost')?.focus()
  }

  async function saveHost(andConnect) {
    const existing = state.editHostId ? state.hosts.find((h) => h.id === state.editHostId) : null
    const host = {
      id: state.editHostId || 'h_' + Date.now().toString(36),
      name: $('fName').value.trim() || $('fHost').value.trim() || 'host',
      group: ($('fGroup')?.value || '').trim() || '连接',
      host: $('fHost').value.trim(),
      port: Number($('fPort')?.value) || 22,
      username: ($('fUser')?.value || '').trim() || 'root',
      privateKeyPath: ($('fKey')?.value || '').trim(),
      remark: ($('fRemark')?.value || '').trim(),
      rememberPassword: $('fRememberPass') ? !!$('fRememberPass').checked : true,
      authMethod: $('fAuthMethod')?.value || 'password',
      charset: $('fCharset')?.value || 'UTF-8',
      backspace: $('fBackspace')?.value || 'ASCII',
      delKey: $('fDelKey')?.value || 'VT220',
      proxyId: $('fProxyId')?.value || '',
      execChannel: $('fExecChannel') ? !!$('fExecChannel').checked : true,
    }
    if (!host.host) {
      $('fHost').focus()
      return toast('主机不能为空', true)
    }
    const pass = ($('fPass').value || '').trim()
    // keep previous password if field left blank on edit
    if (pass) {
      passwordVault.set(host.id, pass)
      if (host.rememberPassword !== false) host.password = pass
    } else if (existing && existing.password && host.rememberPassword !== false) {
      host.password = existing.password
      passwordVault.set(host.id, existing.password)
    } else if (passwordVault.get(host.id) && host.rememberPassword !== false) {
      host.password = passwordVault.get(host.id)
    } else if (host.rememberPassword === false) {
      delete host.password
      passwordVault.delete(host.id)
    }
    const idx = state.hosts.findIndex((h) => h.id === host.id)
    if (idx >= 0) state.hosts[idx] = { ...state.hosts[idx], ...host }
    else state.hosts.push(host)
    await persistHosts()
    state.activeHostId = host.id
    if (document.body.classList.contains('float-window')) {
      // 独立编辑窗保存后，通知主窗重载主机列表并同步连接管理器浮窗
      try { await api.floatToMain?.({ type: 'hosts-updated' }) } catch (_) {}
      if (typeof window._floatSaveHook === 'function') window._floatSaveHook()
    } else {
      showModal('hostModal', false)
    }
    renderConnMgr()
    renderHostBrowser()
    renderQuickConnect()
    toast(andConnect ? '已保存，正在连接…' : '已保存（含密码）')
    if (andConnect) await connectHost(host.id, passwordVault.get(host.id) || host.password || '')
  }

  // ── bottom tabs ────────────────────────────────────────
  let _ctxDismissBound = false
  function removeCtx() {
    document.querySelectorAll('.ctx-menu').forEach((m) => m.remove())
    if (_ctxDismissBound) {
      document.removeEventListener('pointerdown', _onCtxOutside, true)
      document.removeEventListener('mousedown', _onCtxOutside, true)
      document.removeEventListener('click', _onCtxOutside, true)
      document.removeEventListener('keydown', _onCtxKey, true)
      window.removeEventListener('blur', removeCtx)
      window.removeEventListener('resize', removeCtx)
      _ctxDismissBound = false
    }
  }
  function _onCtxOutside(e) {
    const menu = document.querySelector('.ctx-menu')
    if (!menu) {
      removeCtx()
      return
    }
    // 点在菜单内：不关（菜单按钮自己关）
    if (menu.contains(e.target)) return
    // 任意空白/其它区域（含左键）关闭
    removeCtx()
  }
  function _onCtxKey(e) {
    if (e.key === 'Escape') {
      e.preventDefault()
      removeCtx()
    }
  }
  function bindCtxDismiss() {
    if (_ctxDismissBound) return
    _ctxDismissBound = true
    // capture + pointerdown：比 click 更早，不会被 xterm 吃掉
    document.addEventListener('pointerdown', _onCtxOutside, true)
    document.addEventListener('mousedown', _onCtxOutside, true)
    document.addEventListener('click', _onCtxOutside, true)
    document.addEventListener('keydown', _onCtxKey, true)
    window.addEventListener('blur', removeCtx)
    window.addEventListener('resize', removeCtx)
  }

  function showSftpContext(x, y) {
    removeCtx()
    const menu = document.createElement('div')
    menu.className = 'ctx-menu'
    menu.style.left = Math.max(4, x) + 'px'
    menu.style.top = Math.max(4, y) + 'px'
    const isDir = !!state.selectedSftp?.isDir
    menu.innerHTML = [
      ['open', isDir ? '打开目录' : '编辑 / 打开'],
      ['download', '下载'],
      ['upload', '上传到此目录'],
      ['rename', '重命名'],
      ['mkdir', '新建目录'],
      ['delete', '删除'],
      ['pack', '打包 tar.gz'],
      ['copy', '复制路径'],
      ['insert', '插入命令框'],
      ['refresh', '刷新'],
    ]
      .map(
        ([a, lab]) =>
          `<button type="button" data-act="${a}" class="ctx-item">${lab}</button>`,
      )
      .join('')
    document.body.appendChild(menu)
    // 贴边翻转
    const rect = menu.getBoundingClientRect()
    if (rect.right > window.innerWidth - 4) menu.style.left = Math.max(4, window.innerWidth - rect.width - 4) + 'px'
    if (rect.bottom > window.innerHeight - 4) menu.style.top = Math.max(4, window.innerHeight - rect.height - 4) + 'px'
    menu.querySelectorAll('button').forEach((b) => {
      b.onclick = async () => {
        removeCtx()
        await sftpCtxAction(b.dataset.act)
      }
    })
    // 下一帧再绑，避免右键那次 pointerup 立刻关掉
    requestAnimationFrame(() => bindCtxDismiss())
  }


  function getSelectedSftpItems() {
    const body = $('sftpBody')
    if (body) {
      const rows = [...body.querySelectorAll('tr.selected[data-name]')]
      if (rows.length) {
        return rows.map((r) => ({
          name: r.dataset.name,
          isDir: r.dataset.dir === '1',
          fullPath: r.dataset.full || '',
          size: Number(r.dataset.size) || 0,
        }))
      }
    }
    if (Array.isArray(state.selectedSftpList) && state.selectedSftpList.length) return state.selectedSftpList
    if (state.selectedSftp) return [state.selectedSftp]
    return []
  }

  const TRANSFER_PACK_BYTES = 8 * 1024 * 1024 // ≥8MB 或 多文件 → 自动打包

  async function sftpCtxAction(act) {
    const tab = sessionTab()
    if (!tab?.sessionId || !hasApi) return toast('请先连接', true)
    const sel = state.selectedSftp
    const full = sel?.fullPath || (sel ? sftpJoin(tab.sftpPath || '/', sel.name) : tab.sftpPath || '/')
    if (act === 'refresh') return refreshSftp()
    if (act === 'open' || act === 'edit') {
      if (sel?.isDir) {
        tab.sftpPath = full
        /* SFTP 与 shell 分离：不写 cd */
        return refreshSftp()
      }
      // open/edit remote text file（可编辑 + 保存）
      toast('正在打开…')
      const r = await api.sftpRead(tab.sessionId, full)
      if (!r?.ok) return toast(r?.error || '读取失败', true)
      let text = ''
      try {
        // UTF-8 safe (escape/atob is Latin-1 only and mangles CJK)
        const bin = atob(r.dataBase64 || '')
        const bytes = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
        text = new TextDecoder('utf-8', { fatal: false }).decode(bytes)
      } catch (_) {
        try {
          text = atob(r.dataBase64 || '')
        } catch (e2) {
          return toast('无法解码文件内容', true)
        }
      }
      // 过大文件仍允许编辑，但提示（主进程已 cap 8MB）
      if (text.length > 1 * 1024 * 1024) {
        const ok = await askConfirm(
          '文件约 ' + Math.round(text.length / 1024) + ' KB，编辑可能较慢，仍要打开？',
          { title: '大文件' },
        )
        if (!ok) return
      }
      showEditorModal(full, text)
      return
    }
    if (act === 'copy') {
      try {
        await navigator.clipboard.writeText(full)
        toast('已复制 ' + full)
      } catch (_) {
        toast(full)
      }
      return
    }
    if (act === 'insert') {
      const cmd = $('cmd')
      if (cmd) {
        cmd.value = (cmd.value + ' ' + shellQuote(full)).trim()
        cmd.focus()
      }
      return
    }
    if (act === 'mkdir') {
      const name = await askPrompt('新目录名', '', { title: '新建目录' })
      if (!name) return
      const r = await api.sftpMkdir(tab.sessionId, joinRemote(tab.sftpPath || '/', name))
      if (!r?.ok) return toast(r?.error || 'mkdir 失败', true)
      return refreshSftp()
    }
    if (act === 'rename' && sel) {
      const name = await askPrompt('新名称', sel.name, { title: '重命名' })
      if (!name || name === sel.name) return
      const r = await api.sftpRename(tab.sessionId, full, joinRemote(tab.sftpPath || '/', name))
      if (!r?.ok) return toast(r?.error || '重命名失败', true)
      return refreshSftp()
    }
    if (act === 'delete' && sel) {
      if (!(await askConfirm('删除 ' + full + ' ?', { title: '删除' }))) return
      const r = await api.sftpUnlink(tab.sessionId, full, !!sel.isDir)
      if (!r?.ok) return toast(r?.error || '删除失败', true)
      return refreshSftp()
    }
    if (act === 'download') {
      const items = getSelectedSftpItems()
      const list = items.length ? items : sel ? [sel] : []
      if (!list.length) return toast('请选中文件')
      const paths = list.map((it) => it.fullPath || joinRemote(tab.sftpPath, it.name))
      toast('下载中…')
      const r = typeof api.sftpDownloadSmart === 'function'
        ? await api.sftpDownloadSmart(tab.sessionId, paths, { autoPack: true })
        : await api.sftpDownload(tab.sessionId, paths[0])
      toast(r?.packed ? '已下载并解压' : r?.ok ? '已下载' : r?.error || '下载失败', !r?.ok)
      return
    }
    if (act === 'upload') {
      toast('上传中…')
      const r = await api.sftpUpload(tab.sessionId, tab.sftpPath || '/', null, { autoPack: true })
      toast(r?.packed ? '上传完成（已自动解压）' : r?.ok ? '上传完成' : r?.error || '上传失败', !r?.ok)
      return refreshSftp()
    }
    if (act === 'pack' && sel) {
      const r = await api.packRemote(tab.sessionId, [full], 'tar.gz')
      toast(r?.ok ? '打包完成' : r?.error || '打包失败', !r?.ok)
      return refreshSftp()
    }
  }


  // ── Built-in text editor (RSyntaxTextArea-class language coverage) ──
  const EditorLib = (() => {
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

    return { guessLang, langLabel, listLanguages, highlightPlain, lineCount, buildGutter, buildLineGutter, findAll, replaceAll, cursorFromIndex, indexFromLineCol, isProbablyBinary, createEditorDoc, EXT_LANG, LANG_LABELS }
  })()

  let editorState = {
    path: '',
    original: '',
    dirty: false,
    lang: 'plaintext',
    findIdx: -1,
    finds: [],
    syntaxHl: true,
    wordWrap: false,
    findCase: false,
    findRegex: false,
  }

  function applyEditorChrome() {
    const ta = $('edBody')
    if (!ta) return
    const s = state.settings || {}
    const fontFamily =
      withMonoI18n(s.fontFamily || DEFAULT_TERM_FONT_FAMILY)
    const fontSize = Number(editorState._fontSize || s.fontSize) || 13
    const wrap = !!editorState.wordWrap
    const hl = $('edHighlight')
    const g = $('edGutter')
    const wrapEl = ta.parentElement
    const body = document.querySelector('.ed-body')
    // Soft-wrap desyncs logical gutter vs visual lines — hide gutter while wrap is on.
    if (body) body.classList.toggle('is-wrap', wrap)
    if (g) g.hidden = !!wrap
    if (body) {
      body.style.gridTemplateColumns = wrap ? '0 1fr' : '32px 1fr'
    }
    for (const el of [ta, hl, g]) {
      if (!el) continue
      el.style.fontFamily = fontFamily
      el.style.fontSize = fontSize + 'px'
      el.style.lineHeight = '1.45'
      el.style.font = fontSize + 'px/1.45 ' + fontFamily
      if (el === ta || el === hl) {
        el.style.whiteSpace = wrap ? 'pre-wrap' : 'pre'
        el.style.wordBreak = wrap ? 'break-word' : 'normal'
        el.style.overflowWrap = wrap ? 'anywhere' : 'normal'
      }
    }
    ta.wrap = wrap ? 'soft' : 'off'
    ta.setAttribute('wrap', wrap ? 'soft' : 'off')
    if (wrapEl) wrapEl.classList.toggle('is-wrap', wrap)
    const fs = $('edFontSize')
    if (fs && document.activeElement !== fs) fs.value = String(fontSize)
    const ww = $('edWordWrap')
    if (ww && document.activeElement !== ww) ww.checked = wrap
    const bar = $('edCurLine')
    if (bar) bar.hidden = !!wrap
  }

  function markEditorCurrentLine() {
    const t = $('edBody')
    if (!t || editorState.wordWrap) {
      const bar0 = $('edCurLine')
      if (bar0) bar0.hidden = true
      return
    }
    const wrap = t.parentElement
    if (!wrap) return
    let bar = $('edCurLine')
    if (!bar) {
      bar = document.createElement('div')
      bar.id = 'edCurLine'
      bar.className = 'ed-cur-line'
      wrap.insertBefore(bar, wrap.firstChild)
    }
    const pos = t.selectionStart || 0
    const line = t.value.slice(0, pos).split(/\n/).length
    const style = window.getComputedStyle(t)
    let lh = parseFloat(style.lineHeight)
    if (!lh || !isFinite(lh)) {
      const fs = parseFloat(style.fontSize) || 13
      lh = fs * 1.45
    }
    const padTop = parseFloat(style.paddingTop) || 8
    bar.style.height = lh + 'px'
    bar.style.top = padTop + (line - 1) * lh - t.scrollTop + 'px'
    bar.hidden = false
  }

  function ensureEditorDom() {
    let mask = document.getElementById('editorMask')
    if (mask) return mask
    mask = document.createElement('div')
    mask.id = 'editorMask'
    // 浮动层：无全屏遮罩，不挡主界面
    mask.className = 'modal-mask editor-float-mask'
    mask.innerHTML = `
      <div class="modal editor-modal" id="editorModalWin">
        <div class="modal-title editor-titlebar" id="edTitlebar">
          <span id="edTitle" class="ed-title">编辑器</span>
          <span id="edMeta" class="ed-meta"></span>
          <button type="button" class="icon-btn" id="edClose" title="关闭">×</button>
        </div>
        <div class="ed-toolbar">
          <button type="button" class="mini-btn" id="edSaveBtn">保存</button>
          <button type="button" class="mini-btn" id="edReloadBtn">重新加载</button>
          <label class="inline-lab">语言
            <select id="edLang" class="thin-input" style="width:130px"></select>
          </label>
          <label class="inline-lab" title="语法高亮（默认开启）">
            <input type="checkbox" id="edSyntaxHl" checked /> 语法高亮
          </label>
          <label class="inline-lab" title="自动换行">
            <input type="checkbox" id="edWordWrap" /> 换行
          </label>
          <label class="inline-lab" title="字号（跟随设置，可临时调）">字号
            <input type="number" id="edFontSize" class="thin-input" min="10" max="28" value="13" style="width:52px" />
          </label>
          <span class="ed-sep"></span>
          <input id="edFind" class="thin-input" placeholder="查找…" style="width:120px" />
          <label class="inline-lab" title="区分大小写"><input type="checkbox" id="edFindCase" /> Aa</label>
          <label class="inline-lab" title="正则"><input type="checkbox" id="edFindRegex" /> .*</label>
          <button type="button" class="mini-btn" id="edFindPrev">上一个</button>
          <button type="button" class="mini-btn" id="edFindNext">下一个</button>
          <input id="edReplace" class="thin-input" placeholder="替换为…" style="width:110px" />
          <button type="button" class="mini-btn" id="edReplaceOne">替换</button>
          <button type="button" class="mini-btn" id="edReplaceAll">全部替换</button>
          <span class="ed-sep"></span>
          <button type="button" class="mini-btn" id="edGoto">跳转行</button>
          <span id="edFindCount" class="ed-meta"></span>
        </div>
        <div class="ed-body">
          <pre id="edGutter" class="ed-gutter" aria-hidden="true"></pre>
          <div class="ed-code-wrap">
            <pre id="edHighlight" class="ed-highlight" aria-hidden="true"></pre>
            <textarea id="edBody" class="ed-textarea" spellcheck="false" wrap="off"></textarea>
          </div>
        </div>
        <div class="ed-statusbar">
          <span id="edStatusLeft">就绪</span>
          <span class="sb-spacer"></span>
          <span id="edStatusRight">Ln 1, Col 1</span>
        </div>
      </div>`
    document.body.appendChild(mask)
    // 标题栏拖动 + 默认偏移到右下，避免挡住终端
    const win = mask.querySelector('#editorModalWin') || mask.querySelector('.editor-modal')
    if (win) {
      enableModalDrag(win, {
        kind: 'editor',
        title: '文本编辑器',
        floatId: 'editor',
        buildInit: () => {
          const tab = sessionTab()
          return {
            path: editorState.path || ($('edTitle')?.textContent || ''),
            text: $('edBody')?.value ?? editorState.original ?? '',
            sessionId: tab?.sessionId || null,
            lang: editorState.lang || 'plaintext',
            syntaxHl: editorState.syntaxHl !== false,
            fontSize: Number(editorState._fontSize || state.settings?.fontSize) || 13,
            fontFamily: state.settings?.fontFamily || '',
          }
        },
      })
      // 首次打开默认位置
      if (!win.style.left) {
        const w = Math.min(640, Math.floor(window.innerWidth * 0.62))
        const h = Math.min(480, Math.floor(window.innerHeight * 0.55))
        win.style.width = w + 'px'
        win.style.height = h + 'px'
        win.style.left = Math.max(24, window.innerWidth - w - 36) + 'px'
        win.style.top = Math.max(48, Math.floor(window.innerHeight * 0.12)) + 'px'
        win.style.position = 'fixed'
        win.style.margin = '0'
        win.style.transform = 'none'
      }
    }

    // populate languages once
    const sel = mask.querySelector('#edLang')
    sel.innerHTML = EditorLib.listLanguages()
      .map((l) => `<option value="${l.id}">${l.name}</option>`)
      .join('')

    const ta = () => $('edBody')
    const syncScroll = () => {
      const t = ta()
      const g = $('edGutter')
      const h = $('edHighlight')
      if (!t) return
      if (g) g.scrollTop = t.scrollTop
      if (h) {
        h.scrollTop = t.scrollTop
        h.scrollLeft = t.scrollLeft
      }
    }
    const refreshView = () => {
      const t = ta()
      if (!t) return
      const text = t.value
      const g = $('edGutter')
      const h = $('edHighlight')
      const wrap = t.parentElement
      if (g) g.textContent = EditorLib.buildGutter(text)
            let hlOk = false
      const wantHl = editorState.syntaxHl !== false
      // Guard: full re-highlight on every keystroke freezes UI on large files.
      const HL_MAX = 180000
      const canHl = wantHl && text.length <= HL_MAX
      if (h) {
        try {
          if (canHl) {
            h.innerHTML = EditorLib.highlightPlain(text, editorState.lang) + '\n'
            hlOk = true
          } else {
            h.textContent = ''
            hlOk = false
          }
        } catch (_) {
          h.textContent = ''
          hlOk = false
        }
      }
      // 开启高亮时 textarea 透明叠字；关闭时显示纯文字
      if (wrap) wrap.classList.toggle('has-hl', !!canHl && hlOk)
      const dirty = text !== editorState.original
      editorState.dirty = dirty
      const lines = EditorLib.lineCount(text)
      const bytes = new Blob([text]).size
      if ($('edMeta')) {
        const skipHl = editorState.syntaxHl !== false && text.length > 180000
        $('edMeta').textContent =
          (dirty ? '● ' : '') +
          EditorLib.langLabel(editorState.lang) +
          ' · ' +
          lines +
          ' 行 · ' +
          bytes +
          ' B' +
          (skipHl ? ' · 过大跳过高亮' : '')
      }
      if ($('edStatusLeft')) $('edStatusLeft').textContent = dirty ? '已修改（未保存）' : '就绪'
      // cursor
      const pos = t.selectionStart || 0
      const head = text.slice(0, pos)
      const ls = head.split(/\n/)
      if ($('edStatusRight')) {
        $('edStatusRight').textContent = 'Ln ' + ls.length + ', Col ' + ((ls[ls.length - 1] || '').length + 1)
      }
      try { markEditorCurrentLine() } catch (_) {}
      syncScroll()
    }

    ta().addEventListener('input', () => {
      refreshView()
    })
    ta().addEventListener('scroll', syncScroll)
    ta().addEventListener('click', refreshView)
    ta().addEventListener('keyup', refreshView)
    // Tab 插入空格，避免失焦
    ta().addEventListener('keydown', (e) => {
      if (e.key === 'Tab') {
        e.preventDefault()
        const t = ta()
        const s = t.selectionStart
        const en = t.selectionEnd
        const v = t.value
        t.value = v.slice(0, s) + '  ' + v.slice(en)
        t.selectionStart = t.selectionEnd = s + 2
        refreshView()
      }
    })
    sel.addEventListener('change', () => {
      editorState.lang = sel.value
      refreshView()
    })
    const hlCb = mask.querySelector('#edSyntaxHl')
    if (hlCb) {
      hlCb.checked = editorState.syntaxHl !== false
      hlCb.addEventListener('change', () => {
        editorState.syntaxHl = !!hlCb.checked
        state.settings.editorSyntaxHl = editorState.syntaxHl
        if (hasApi && api.saveSettings) api.saveSettings(state.settings).catch((e) => console.warn('[save settings]', e))
        refreshView()
      })
    }
    const ww = mask.querySelector('#edWordWrap')
    if (ww) {
      ww.checked = !!editorState.wordWrap
      ww.addEventListener('change', () => {
        editorState.wordWrap = !!ww.checked
        state.settings.editorWordWrap = editorState.wordWrap
        if (hasApi && api.saveSettings) api.saveSettings(state.settings).catch((e) => console.warn('[save settings]', e))
        applyEditorChrome()
        refreshView()
      })
    }
    const fs = mask.querySelector('#edFontSize')
    if (fs) {
      fs.value = String(Number(state.settings.fontSize) || 13)
      fs.addEventListener('change', () => {
        const n = Math.min(28, Math.max(10, Number(fs.value) || 13))
        editorState._fontSize = n
        // temporary for this session; keep global settings font for terminal
        applyEditorChrome()
        refreshView()
      })
    }
    const fc = mask.querySelector('#edFindCase')
    if (fc) {
      fc.checked = !!editorState.findCase
      fc.addEventListener('change', () => {
        editorState.findCase = !!fc.checked
      })
    }
    const fr = mask.querySelector('#edFindRegex')
    if (fr) {
      fr.checked = !!editorState.findRegex
      fr.addEventListener('change', () => {
        editorState.findRegex = !!fr.checked
      })
    }
    try { applyEditorChrome() } catch (_) {}

    $('edClose').onclick = () => closeEditor(true)
    $('edSaveBtn').onclick = () => saveEditor()
    $('edReloadBtn').onclick = () => reloadEditor()
    $('edFindNext').onclick = () => editorFind(1)
    $('edFindPrev').onclick = () => editorFind(-1)
    $('edReplaceOne').onclick = () => editorReplace(false)
    $('edReplaceAll').onclick = () => editorReplace(true)
    $('edGoto').onclick = async () => {
      const v = await askPrompt('跳转到行号', '1', { title: '跳转' })
      if (v == null) return
      const line = Math.max(1, parseInt(v, 10) || 1)
      const t = ta()
      const parts = t.value.split(/\n/)
      let idx = 0
      for (let i = 0; i < Math.min(line - 1, parts.length); i++) idx += parts[i].length + 1
      t.focus()
      t.setSelectionRange(idx, idx)
      // approximate scroll
      const ratio = (line - 1) / Math.max(parts.length, 1)
      t.scrollTop = ratio * t.scrollHeight
      refreshView()
    }
    $('edFind').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        editorFind(e.shiftKey ? -1 : 1)
      }
    })
    mask.addEventListener('keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
        e.preventDefault()
        saveEditor()
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') {
        e.preventDefault()
        $('edFind')?.focus()
      }
      if (e.key === 'Escape') {
        e.preventDefault()
        closeEditor(true)
      }
    })

    mask._refreshView = refreshView
    return mask
  }

  function editorFind(dir) {
    const q = $('edFind')?.value || ''
    const t = $('edBody')
    if (!t || !q) return
    editorState.finds = EditorLib.findAll(t.value, q, {
      caseSensitive: !!editorState.findCase,
      regex: !!editorState.findRegex,
    })
    $('edFindCount').textContent = editorState.finds.length ? editorState.finds.length + ' 处' : '无匹配'
    if (!editorState.finds.length) return
    const cur = t.selectionStart || 0
    let idx = editorState.findIdx
    if (dir > 0) {
      idx = editorState.finds.findIndex((h) => h.index >= cur)
      if (idx < 0) idx = 0
      if (editorState.finds[idx] && editorState.finds[idx].index === cur && editorState.finds.length > 1) {
        idx = (idx + 1) % editorState.finds.length
      }
    } else {
      idx = -1
      for (let i = editorState.finds.length - 1; i >= 0; i--) {
        if (editorState.finds[i].index < cur) {
          idx = i
          break
        }
      }
      if (idx < 0) idx = editorState.finds.length - 1
    }
    editorState.findIdx = idx
    const hit = editorState.finds[idx]
    if (!hit) return
    t.focus()
    t.setSelectionRange(hit.index, hit.index + hit.length)
    // Scroll caret into view (textarea has no scrollIntoView for selection)
    try {
      const head = t.value.slice(0, hit.index)
      const line = head.split(/\n/).length
      const style = window.getComputedStyle(t)
      let lh = parseFloat(style.lineHeight)
      if (!lh || !isFinite(lh)) lh = (parseFloat(style.fontSize) || 13) * 1.45
      const padTop = parseFloat(style.paddingTop) || 8
      const y = padTop + (line - 1) * lh
      if (y < t.scrollTop + 8) t.scrollTop = Math.max(0, y - lh * 2)
      else if (y > t.scrollTop + t.clientHeight - lh * 2) t.scrollTop = y - t.clientHeight / 2
    } catch (_) {}
    maskRefresh()
  }

  function editorReplace(all) {
    const q = $('edFind')?.value || ''
    const rep = $('edReplace')?.value ?? ''
    const t = $('edBody')
    if (!t || !q) return
    const opts = { caseSensitive: !!editorState.findCase, regex: !!editorState.findRegex }
    if (all) {
      if (typeof EditorLib.replaceAll === 'function') {
        const r = EditorLib.replaceAll(t.value, q, rep, opts)
        t.value = r.text
        toast(r.count ? ('已替换 ' + r.count + ' 处') : '无匹配')
      } else {
        const hits = EditorLib.findAll(t.value, q, opts)
        let out = ''
        let last = 0
        for (const h of hits) {
          out += t.value.slice(last, h.index) + rep
          last = h.index + h.length
        }
        out += t.value.slice(last)
        t.value = hits.length ? out : t.value
        toast(hits.length ? ('已替换 ' + hits.length + ' 处') : '无匹配')
      }
      maskRefresh()
      return
    }
    const start = t.selectionStart
    const end = t.selectionEnd
    const sel = t.value.slice(start, end)
    const hits = EditorLib.findAll(sel, q, opts)
    if (sel && hits.length === 1 && hits[0].index === 0 && hits[0].length === sel.length) {
      t.setRangeText(rep, start, end, 'end')
      maskRefresh()
      editorFind(1)
    } else {
      editorFind(1)
      const s2 = t.selectionStart
      const e2 = t.selectionEnd
      if (e2 > s2) {
        t.setRangeText(rep, s2, e2, 'end')
        maskRefresh()
      }
    }
  }

  function maskRefresh() {
    const mask = $('editorMask')
    if (mask && mask._refreshView) mask._refreshView()
  }

  async function closeEditor(ask) {
    const mask = $('editorMask')
    if (!mask) return
    if (ask && editorState.dirty) {
      const ok = await askConfirm('文件已修改，关闭将丢失未保存更改？', { title: '关闭编辑器' })
      if (!ok) return
    }
    mask.hidden = true
    mask.setAttribute('hidden', '')
  }

  async function saveEditor() {
    const tab = sessionTab()
    if (!tab?.sessionId || !editorState.path) return toast('无会话或路径', true)
    if (!hasApi || typeof api.sftpWrite !== 'function') return toast('SFTP 写入不可用', true)
    const body = $('edBody')?.value ?? ''
    let b64
    try {
      const bytes = new TextEncoder().encode(body)
      let bin = ''
      const chunk = 0x8000
      for (let i = 0; i < bytes.length; i += chunk) {
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk))
      }
      b64 = btoa(bin)
    } catch (e) {
      try {
        b64 = btoa(unescape(encodeURIComponent(body)))
      } catch (e2) {
        return toast('编码失败: ' + (e2.message || e2), true)
      }
    }
    if ($('edStatusLeft')) $('edStatusLeft').textContent = '保存中…'
    const r = await api.sftpWrite(tab.sessionId, editorState.path, b64)
    if (!r?.ok) return toast(r?.error || '保存失败', true)
    editorState.original = body
    editorState.dirty = false
    toast('已保存 ' + editorState.path)
    maskRefresh()
    try { await refreshSftp() } catch (_) {}
  }

  async function reloadEditor() {
    const tab = sessionTab()
    if (!tab?.sessionId || !editorState.path) return
    if (editorState.dirty) {
      const ok = await askConfirm('放弃未保存修改并重新加载？', { title: '重新加载' })
      if (!ok) return
    }
    const r = await api.sftpRead(tab.sessionId, editorState.path)
    if (!r?.ok) return toast(r?.error || '读取失败', true)
    let text = ''
    try {
      const bin = atob(r.dataBase64 || '')
      const bytes = new Uint8Array(bin.length)
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
      text = new TextDecoder('utf-8', { fatal: false }).decode(bytes)
    } catch (_) {
      try {
        text = atob(r.dataBase64 || '')
      } catch (e2) {
        text = ''
      }
    }
    $('edBody').value = text
    editorState.original = text
    editorState.dirty = false
    maskRefresh()
    toast('已重新加载')
  }

  async function showEditorModal(remotePath, text) {
    editorState.path = remotePath
    editorState.original = text || ''
    editorState.dirty = false
    editorState.lang = EditorLib.guessLang(remotePath) || 'plaintext'
    editorState.findIdx = -1
    editorState.finds = []
    editorState.syntaxHl = state.settings.editorSyntaxHl !== false
    editorState.wordWrap = !!state.settings.editorWordWrap
    editorState.findCase = false
    editorState.findRegex = false
    editorState._fontSize = Number(state.settings.fontSize) || 13

    // 默认：独立桌面编辑窗（打开即独立，不挡终端）
    if (hasApi && typeof api.openFloatWindow === 'function' && !document.body.classList.contains('float-window')) {
      const tab = sessionTab()
      const r = await openIndependentFloat({
        kind: 'editor',
        id: 'editor',
        title: (remotePath || '文本编辑器').slice(0, 80),
        width: 720,
        height: 520,
        init: {
          path: remotePath || '',
          text: text || '',
          sessionId: tab?.sessionId || null,
          lang: editorState.lang || 'plaintext',
          syntaxHl: editorState.syntaxHl !== false,
          fontSize: Number(editorState._fontSize || state.settings?.fontSize) || 13,
          fontFamily: state.settings?.fontFamily || '',
          theme: getUiThemeMode(),
        },
      })
      if (r && r.ok) {
        // 关掉页内编辑器遮罩（若有）
        try {
          const m = $('editorMask')
          if (m) {
            m.hidden = true
            m.setAttribute('hidden', '')
          }
        } catch (_) {}
        return
      }
    }

    const mask = ensureEditorDom()
    mask.hidden = false
    mask.removeAttribute('hidden')
    const win = mask.querySelector('#editorModalWin') || mask.querySelector('.editor-modal')
    if (win) {
      enableModalDrag(win, {
        kind: 'editor',
        title: '文本编辑器',
        floatId: 'editor',
      })
      if (!win.style.left || !win.style.top) {
        const w = Math.min(640, Math.floor(window.innerWidth * 0.62))
        const h = Math.min(480, Math.floor(window.innerHeight * 0.55))
        win.style.width = w + 'px'
        win.style.height = h + 'px'
        win.style.left = Math.max(24, window.innerWidth - w - 36) + 'px'
        win.style.top = Math.max(48, Math.floor(window.innerHeight * 0.12)) + 'px'
        win.style.position = 'fixed'
        win.style.margin = '0'
        win.style.transform = 'none'
      }
      win.style.zIndex = String(Date.now() % 100000 + 700)
    }
    if ($('edTitle')) $('edTitle').textContent = remotePath
    try {
      const langs = EditorLib.listLanguages().map((l) => l.id)
      $('edLang').value = langs.includes(editorState.lang) ? editorState.lang : 'plaintext'
      editorState.lang = $('edLang').value || 'plaintext'
    } catch (_) {}
    try {
      const hlCb = $('edSyntaxHl')
      if (hlCb) hlCb.checked = editorState.syntaxHl !== false
      const ww = $('edWordWrap')
      if (ww) ww.checked = !!editorState.wordWrap
      const fs = $('edFontSize')
      if (fs) fs.value = String(editorState._fontSize || 13)
      const fc = $('edFindCase')
      if (fc) fc.checked = !!editorState.findCase
      const fr = $('edFindRegex')
      if (fr) fr.checked = !!editorState.findRegex
      applyEditorChrome()
    } catch (_) {}
    const ta = $('edBody')
    if (ta) {
      ta.value = text || ''
      ta.readOnly = false
      ta.removeAttribute('readonly')
      ta.removeAttribute('disabled')
    }
    try { applyEditorChrome() } catch (_) {}
    if ($('edFind')) $('edFind').value = ''
    if ($('edReplace')) $('edReplace').value = ''
    if ($('edFindCount')) $('edFindCount').textContent = ''
    maskRefresh()
    setTimeout(() => {
      const t = $('edBody')
      if (!t) return
      t.focus()
      try {
        t.setSelectionRange(0, 0)
      } catch (_) {}
    }, 40)
  }


  function setBottom(name) {
    state.bottom = name
    document.querySelectorAll('.bottom-tab').forEach((t) => {
      t.classList.toggle('active', t.dataset.bottom === name)
    })
    document.querySelectorAll('.bottom-panel').forEach((p) => p.classList.remove('active'))
    if (name === 'files') $('panelFiles')?.classList.add('active')
    else {
      $('panelCmds')?.classList.add('active')
      renderCmdBoard()
    }
    // 切到文件/命令时若底栏被藏了，自动展开
    if (state.bottomCollapsed) setBottomCollapsed(false)
  }

  function setBottomCollapsed(collapsed) {
    const center = document.querySelector('.work-center')
    const btn = $('btnToggleBottom')
    state.bottomCollapsed = !!collapsed
    if (center) {
      center.classList.toggle('bottom-collapsed', !!collapsed)
      if (!collapsed) {
        center.classList.remove('chrome-compact')
        state.chromeCompact = false
        const bh = (state.settings && state.settings.layout && state.settings.layout.bottomHeight) || 200
        center.style.gridTemplateRows = '1fr var(--cmd-h) 4px ' + bh + 'px'
        document.documentElement.style.setProperty('--bottom-h', bh + 'px')
        // 清掉 dock 可能残留的内联高，让它随网格行铺满（否则展开后底部露白）
        const dock = $('bottomDock')
        if (dock) { dock.style.height = ''; dock.style.maxHeight = ''; dock.style.minHeight = '' }
      } else if (!center.classList.contains('chrome-compact')) {
        center.style.gridTemplateRows = '1fr var(--cmd-h) 0 0'
      }
    }
    if (btn) {
      btn.textContent = collapsed ? '▴' : '▾'
      btn.title = collapsed ? '显示文件/命令底栏' : '隐藏文件/命令底栏'
      btn.setAttribute('aria-label', btn.title)
      btn.classList.toggle('is-hidden-bottom', !!collapsed)
    }
    try {
      applyTermFontScale()
    } catch (_) {
      try {
        fitAddon && fitAddon.fit && fitAddon.fit()
      } catch (__) {}
    }
  }

  // ── menus / bind ───────────────────────────────────────
  function positionFlyout(el, anchorBtn, { rightPad = 8 } = {}) {
    if (!el || !anchorBtn) return
    const r = anchorBtn.getBoundingClientRect()
    const top = Math.round(r.bottom + 4)
    el.style.top = top + 'px'
    el.style.right = Math.max(4, Math.round(window.innerWidth - r.right + rightPad - (r.width / 2))) + 'px'
    el.style.left = 'auto'
  }

  function fillToolsHostSelect() {
    const sel = $('toolsHostSelect')
    if (!sel) return
    const cur = sel.value || state.activeHostId || state.mgrSelectedId || ''
    const opts = ['<option value="">选择主机…</option>']
    for (const h of state.hosts || []) {
      const label = (h.name || h.host || h.id) + (h.host ? `  (${h.host})` : '')
      opts.push(`<option value="${esc(h.id)}">${esc(label)}</option>`)
    }
    sel.innerHTML = opts.join('')
    if (cur && state.hosts.some((h) => h.id === cur)) sel.value = cur
  }

  function refreshToolsDlPath() {
    const el = $('toolsDlPath')
    if (!el) return
    const p = state.settings?.downloadPath || ''
    el.textContent = p || '默认下载目录'
    el.title = p || '未设置（使用系统默认）'
  }

  function closeFlyouts() {
    const tools = $('toolsPanel')
    const menu = $('mainMenu')
    if (tools) {
      tools.hidden = true
      tools.setAttribute('hidden', '')
    }
    if (menu) {
      menu.hidden = true
      menu.setAttribute('hidden', '')
    }
    $('btnToolsPanel')?.classList.remove('open')
    $('btnMainMenu')?.classList.remove('open')
    menu?.querySelectorAll('.mm-item.open').forEach((it) => {
      it.classList.remove('open')
      const sub = it.querySelector('.mm-sub')
      if (sub) {
        sub.hidden = true
        sub.setAttribute('hidden', '')
      }
    })
  }

  function openToolsPanel() {
    const panel = $('toolsPanel')
    const btn = $('btnToolsPanel')
    if (!panel || !btn) return
    const willOpen = panel.hidden || panel.hasAttribute('hidden')
    closeFlyouts()
    if (!willOpen) return
    fillToolsHostSelect()
    refreshToolsDlPath()
    panel.hidden = false
    panel.removeAttribute('hidden')
    btn.classList.add('open')
    positionFlyout(panel, btn, { rightPad: 0 })
    // align panel right edge near tools button
    const r = btn.getBoundingClientRect()
    const w = panel.offsetWidth || 360
    panel.style.right = Math.max(8, Math.round(window.innerWidth - r.right - 8)) + 'px'
    panel.style.left = 'auto'
    if (w > window.innerWidth - 16) panel.style.right = '8px'
  }

  function openMainMenu() {
    const menu = $('mainMenu')
    const btn = $('btnMainMenu')
    if (!menu || !btn) return
    const willOpen = menu.hidden || menu.hasAttribute('hidden')
    closeFlyouts()
    if (!willOpen) return
    menu.hidden = false
    menu.removeAttribute('hidden')
    btn.classList.add('open')
    const r = btn.getBoundingClientRect()
    menu.style.top = Math.round(r.bottom + 4) + 'px'
    menu.style.right = Math.max(8, Math.round(window.innerWidth - r.right)) + 'px'
    menu.style.left = 'auto'
  }

  function bindMenus() {
    // top-right: tools grid + hamburger with nested secondary menus
    on('btnToolsPanel', 'click', (e) => {
      e.stopPropagation()
      openToolsPanel()
    })
    on('btnMainMenu', 'click', (e) => {
      e.stopPropagation()
      openMainMenu()
    })

    // tools panel chips
    $('toolsPanel')?.querySelectorAll('.tools-chip[data-act]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.preventDefault()
        e.stopPropagation()
        const act = btn.getAttribute('data-act') || btn.dataset.act
        if (!act) return
        closeFlyouts()
        // if host selected in tools panel, prefer it
        const hid = $('toolsHostSelect')?.value
        if (hid) {
          state.activeHostId = hid
          state.mgrSelectedId = hid
        }
        try {
          await menuAction(act)
        } catch (err) {
          console.error('tools menuAction', act, err)
          toast('工具动作失败: ' + (err?.message || err), true)
        }
      })
    })

    // tools host select — switch active host
    $('toolsHostSelect')?.addEventListener('change', (e) => {
      const id = e.target.value
      if (!id) return
      state.activeHostId = id
      state.mgrSelectedId = id
    })
    $('toolsHostSelect')?.addEventListener('click', (e) => e.stopPropagation())

    // download path pick / open
    on('btnDlPick', 'click', async (e) => {
      e.stopPropagation()
      if (!hasApi || !api.openDirectory) return toast('无法打开目录选择', true)
      const r = await api.openDirectory()
      if (!r?.ok || !r.path) return
      state.settings = state.settings || {}
      state.settings.downloadPath = r.path
      try {
        await api.saveSettings(state.settings)
      } catch (_) {}
      refreshToolsDlPath()
      toast('下载目录: ' + r.path)
    })
    on('btnDlOpen', 'click', async (e) => {
      e.stopPropagation()
      const p = state.settings?.downloadPath
      if (!p) return toast('请先选择下载目录', true)
      if (!hasApi || !api.openPath) return toast('无法打开路径', true)
      const r = await api.openPath(p)
      if (!r?.ok) toast('打开失败: ' + (r?.error || ''), true)
    })
    $('toolsPanel')?.addEventListener('click', (e) => e.stopPropagation())

    // main menu nested items
    const mainMenu = $('mainMenu')
    if (mainMenu) {
      mainMenu.addEventListener('click', (e) => e.stopPropagation())

      // hover / click secondary submenus
      mainMenu.querySelectorAll('.mm-item.has-sub').forEach((item) => {
        const sub = item.querySelector('.mm-sub')
        if (!sub) return
        const showSub = () => {
          mainMenu.querySelectorAll('.mm-item.open').forEach((it) => {
            if (it === item) return
            it.classList.remove('open')
            const s = it.querySelector('.mm-sub')
            if (s) {
              s.hidden = true
              s.setAttribute('hidden', '')
            }
          })
          item.classList.add('open')
          sub.hidden = false
          sub.removeAttribute('hidden')
          // if submenu would go off left edge, flip to right
          const rect = sub.getBoundingClientRect()
          if (rect.left < 4) {
            sub.style.right = 'auto'
            sub.style.left = '100%'
            sub.style.marginLeft = '2px'
            sub.style.marginRight = '0'
          } else {
            sub.style.right = '100%'
            sub.style.left = 'auto'
            sub.style.marginRight = '2px'
            sub.style.marginLeft = '0'
          }
        }
        const hideSub = () => {
          item.classList.remove('open')
          sub.hidden = true
          sub.setAttribute('hidden', '')
        }
        item.addEventListener('mouseenter', showSub)
        item.addEventListener('mouseleave', (e) => {
          const to = e.relatedTarget
          if (to && (item.contains(to) || sub.contains(to))) return
          hideSub()
        })
        sub.addEventListener('mouseenter', showSub)
        sub.addEventListener('mouseleave', (e) => {
          const to = e.relatedTarget
          if (to && item.contains(to)) return
          hideSub()
        })
        item.addEventListener('click', (e) => {
          // click on parent row toggles sub (not on sub buttons)
          if (e.target.closest('.mm-sub')) return
          e.stopPropagation()
          if (item.classList.contains('open')) hideSub()
          else showSub()
        })
      })

      // leaf actions (top-level mm-btn + nested mm-sub buttons)
      mainMenu.querySelectorAll('button[data-act]').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.preventDefault()
          e.stopPropagation()
          const act = btn.getAttribute('data-act') || btn.dataset.act
          if (!act) return
          closeFlyouts()
          try {
            await menuAction(act)
          } catch (err) {
            console.error('menuAction', act, err)
            toast('菜单动作失败: ' + (err?.message || err), true)
          }
        })
      })
    }

    // outside click / Esc close
    document.addEventListener('click', () => closeFlyouts())
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') closeFlyouts()
    })
    window.addEventListener('resize', () => closeFlyouts())
  }

  async function menuAction(act) {
    switch (act) {
      case 'conn-mgr':
        openConnMgr()
        break
      case 'new':
        openHostModal(null)
        break
      case 'connect':
        if (state.activeHostId) await connectHost(state.activeHostId)
        else {
          showModal('connMgrModal', true)
          renderConnMgr()
        }
        break
      case 'disconnect':
        await disconnectActive()
        break
      case 'reconnect':
        await doReconnect()
        break
      case 'import-hosts':
        if (!hasApi) return
        {
          let dir
          try {
            if (api.openDirectory) {
              const d = await api.openDirectory()
              if (d?.ok && d.path) dir = d.path
              else if (d && d.canceled) return
            }
          } catch (_) {}
          const r = await api.importHosts(dir)
          if (!r?.ok) return toast('导入失败: ' + (r?.error || ''), true)
          await loadAll()
          renderConnMgr()
          toast(`已导入 ${r.count} 台`)
        }
        break
      case 'import-quick':
        if (!hasApi) return
        {
          let configPath
          try {
            if (api.openFile) {
              const f = await api.openFile()
              // dialog:open-file → { ok, paths: string[] }
              if (f?.ok && (f.path || f.paths?.[0] || f.filePaths?.[0])) {
                configPath = f.path || f.paths?.[0] || f.filePaths[0]
              } else if (f && (f.canceled || f.ok === false)) {
                return
              }
            }
          } catch (_) {}
          const r = await api.importQuick(configPath)
          if (!r?.ok) return toast('导入失败: ' + (r?.error || ''), true)
          state.quick = r.list || (await api.loadQuick()) || []
          renderCmdBoard()
          toast('快捷命令 ' + (r.count || 0))
        }
        break
      case 'settings':
        openSettings()
        break
      case 'copy':
        document.execCommand('copy')
        break
      case 'paste':
        try {
          const text = await navigator.clipboard.readText()
          const t = sessionTab()
          if (t?.sessionId && text) await api.write(t.sessionId, text)
        } catch (_) {
          toast('无法读剪贴板', true)
        }
        break
      case 'clear-term':
        term?.clear?.()
        break
      case 'toggle-side':
        setSidebarCollapsed(!state.sideCollapsed)
        break
      case 'bottom-files':
        setBottomCollapsed(false)
        setBottom('files')
        break
      case 'bottom-cmds':
        setBottomCollapsed(false)
        setBottom('cmds')
        break
      case 'toggle-bottom':
        setBottomCollapsed(!state.bottomCollapsed)
        break
      case 'tab-process':
        await openToolTab('process')
        break
      case 'tab-network':
        await openToolTab('network')
        break
      case 'tab-route':
        await openToolTab('route')
        break
      case 'sysinfo': {
        const t = sessionTab()
        if (!t?.sessionId) return toast('请先连接', true)
        const tab = {
          id: 'tab_' + Date.now().toString(36),
          type: 'sysinfo',
          title: '系统信息',
          hostId: t.hostId,
          sessionId: t.sessionId,
          status: 'connected',
        }
        state.tabs.push(tab)
        await switchTab(tab.id)
        break
      }
      case 'key-mgr':
        toast('密钥管理器：请在主机编辑「认证」里填写私钥路径（完整密钥库后续版本）')
        openHostModal(state.activeHostId || state.mgrSelectedId || null)
        setTimeout(() => {
          const b = document.querySelector('.hed-nav [data-hed="ssh"]')
          b?.click()
          $('fKey')?.focus()
        }, 50)
        break
      case 'speed-test':
        toast('速度测试：请先连接主机后在工具中使用（开发中）')
        break
      case 'custom-accel':
        toast('自定义加速：请在主机编辑「高级」中配置')
        openHostModal(state.activeHostId || state.mgrSelectedId || null)
        break
      case 'about': {
        const ver = state.appVersion || '0.1.0'
        const st = state.updateStatus
        const extra =
          st === 'update-available' && state.updateInfo?.latestVersion
            ? ` · 有新版本 ${state.updateInfo.latestVersion}`
            : st === 'latest'
              ? ' · 已是最新'
              : ''
        toast(`PixShell ${ver}${extra} · 原生 ssh2 · 本地连接管理 · 外部 CLI :8766`)
        break
      }
      case 'open-repo':
        await openPixShellRepo()
        break
      case 'open-releases':
        await openPixShellReleases()
        break
      case 'help-docs':
        await openPixShellRepo()
        break
      case 'external-cli':
        openSettings()
        setTimeout(() => $('setExternalCli')?.focus(), 50)
        break
      case 'cloud-sync':
      case 'backup-config':
        openBackupConfig()
        break
      case 'backup-local':
        await runBackupProvider('local')
        break
      case 'backup-webdav':
        await runBackupProvider('webdav')
        break
      case 'backup-github':
        await runBackupProvider('github')
        break
      case 'backup-google':
        await runBackupProvider('google')
        break
      case 'backup-microsoft':
        await runBackupProvider('microsoft')
        break
      case 'backup-baidu':
        await runBackupProvider('baidu')
        break
      case 'backup-quark':
        await runBackupProvider('quark')
        break
      case 'backup-export':
        await exportLocalBackupBundle()
        break
      case 'backup-import':
        await importLocalBackupBundle()
        break
      case 'update':
        await runSoftwareUpdate({ fromMenu: true })
        break
      default:
        break
    }
  }

  async function openSettings() {
    // 打开设置即刷新终端外观（不依赖保存）：与设置预览同一条 forceScheme 路径
    try {
      if (term) {
        scrubIncompatibleTermBgOverride(state.settings, state.settings?.theme || 'dark', { persist: true })
        await applyTerminalAppearance({
          forceSchemeBackground: (state.settings?.theme || 'dark') !== 'light',
        })
        try {
          if (typeof term.refresh === 'function' && term.rows > 0) term.refresh(0, term.rows - 1)
        } catch (_) {}
      }
    } catch (e) {
      console.warn('[openSettings appearance]', e)
    }
    const s = state.settings || {}
    if ($('setThemeMode')) $('setThemeMode').value = s.theme === 'light' ? 'light' : 'dark'
    if ($('setFontSize')) $('setFontSize').value = s.fontSize || 13
    if ($('setFontFamily')) {
      const sel = $('setFontFamily')
      const raw = String(s.fontFamily || DEFAULT_TERM_FONT_FAMILY)
      const primary = raw.split(',')[0].trim().replace(/^["']|["']$/g, '')
      // 选项 value 为主字体名；应用时 withMonoI18n 追加多国回退
      let matched = [...sel.options].find((o) => {
        const ov = String(o.value || '').split(',')[0].trim().replace(/^["']|["']$/g, '')
        return ov.toLowerCase() === primary.toLowerCase()
      })
      if (!matched) {
        const opt = document.createElement('option')
        opt.value = primary
        opt.textContent = primary + '（多国回退）'
        sel.insertBefore(opt, sel.firstChild)
        matched = opt
      }
      sel.value = matched.value
    }
    if ($('setCursorStyle')) $('setCursorStyle').value = s.cursorStyle || 'block'
    if ($('setCursorBlink')) $('setCursorBlink').checked = s.cursorBlink !== false
    if ($('setTermType')) $('setTermType').value = s.termType || 'xterm-256color'
    if ($('setBoldBright')) $('setBoldBright').checked = s.drawBoldTextInBrightColors !== false
    if ($('setEditorSyntaxHl')) $('setEditorSyntaxHl').checked = s.editorSyntaxHl !== false
    if ($('setEditorWordWrap')) $('setEditorWordWrap').checked = !!s.editorWordWrap
    if ($('setTermLiveHl')) $('setTermLiveHl').checked = s.termLiveHighlight !== false
    if ($('setSideW'))
      $('setSideW').value =
        s.layout?.sidebarWidth ||
        parseInt(getComputedStyle(document.documentElement).getPropertyValue('--sidebar-w'), 10) ||
        240
    if ($('setBottomH'))
      $('setBottomH').value =
        s.layout?.bottomHeight ||
        parseInt(getComputedStyle(document.documentElement).getPropertyValue('--bottom-h'), 10) ||
        260
    if ($('setSyncSftp')) $('setSyncSftp').checked = s.syncDirWithSftp === true
    if ($('setAutoReconnect')) $('setAutoReconnect').checked = s.autoReconnect !== false
    if ($('setMonInterval')) $('setMonInterval').value = s.monitorIntervalSec || 8
    if ($('setExternalCli')) $('setExternalCli').checked = s.externalCliEnabled === true
    if ($('setCliPort')) $('setCliPort').value = s.externalCliPort || 8766
    await fillSchemeSelect(s.colorScheme || 'dracula')
    bindSettingsLivePreview()
    await refreshSettingsPreview()
    refreshCliStatusHint()
    // 默认独立弹出窗（不挡主界面），失败再页内 modal
    if (hasApi && typeof api.openFloatWindow === 'function' && !document.body.classList.contains('float-window')) {
      try {
        const r = await openIndependentFloat({
          kind: 'settings',
          id: 'settings',
          title: '设置',
          width: 480,
          height: 520,
          init: {
            theme: getUiThemeMode(),
            settings: JSON.parse(JSON.stringify(state.settings || {})),
          },
        })
        if (r && r.ok) {
          // 主窗里的 settings 表单仍可被 float 通过 floatToMain 操作；这里先隐藏页内遮罩
          showModal('settingsModal', false)
          return
        }
      } catch (e) {
        try {
          rlog('warn', 'settings', 'float-open-fail', { err: e && e.message })
        } catch (_) {}
      }
    }
    // 页内：无全屏死遮罩，用 float-modal-mask 可拖
    const mask = $('settingsModal')
    if (mask) {
      mask.classList.add('float-modal-mask')
      mask.style.background = 'transparent'
    }
    showModal('settingsModal', true)
    // 定位到主区中上方，不挡整个终端
    try {
      const modal = mask?.querySelector('.modal')
      if (modal) {
        modal.style.position = 'fixed'
        modal.style.left = 'max(12px, calc(50vw - 260px))'
        modal.style.top = '48px'
        modal.style.margin = '0'
        modal.style.maxHeight = 'min(86vh, 720px)'
        modal.style.zIndex = '680'
      }
    } catch (_) {}
  }

  async function fillSchemeSelect(selected) {
    const sel = $('setScheme')
    if (!sel) return
    let list = state._schemeList
    if (!list || !list.length) {
      list = await loadSchemeList()
      state._schemeList = list
    }
    if (!list.length) {
      list = [
        { id: 'dracula', name: 'Dracula' },
        { id: 'pix-dark', name: 'Pix Dark' },
        { id: 'nord', name: 'Nord' },
        { id: 'monokai', name: 'Monokai' },
        { id: 'solarized_dark', name: 'Solarized Dark' },
      ]
    }
    let cur = selected || state.settings.colorScheme || 'dracula'
    // 已删除的方案：不要再塞进下拉（会表现为“选了没变化”）
    const idSet = new Set(list.map((x) => x.id))
    if (!idSet.has(cur)) {
      // monokai → monokai_soda 等别名，尽量落到仍存在的 id
      const alias = {
        monokai: 'monokai_soda',
        nord: 'spacegray',
        solarized: 'solarized_dark',
        solarized_dark_patched: 'solarized_dark',
        batman: 'dracula',
        espresso: 'afterglow',
        idletoes: 'afterglow',
        default: 'pix-dark',
      }
      const key = String(cur).toLowerCase().replace(/[^a-z0-9]+/g, '_')
      cur = idSet.has(alias[key]) ? alias[key] : idSet.has('dracula') ? 'dracula' : list[0]?.id || 'dracula'
    }
    sel.innerHTML = list
      .map((x) => `<option value="${esc(x.id)}">${esc(x.name || x.id)}</option>`)
      .join('')
    sel.value = cur
  }

  function bindSettingsLivePreview() {
    if (state._settingsPreviewBound) return
    state._settingsPreviewBound = true
    ;['setScheme', 'setFontFamily', 'setFontSize', 'setCursorStyle'].forEach((id) => {
      const el = $(id)
      if (!el) return
      el.addEventListener('change', () => refreshSettingsPreview())
      el.addEventListener('input', () => refreshSettingsPreview())
    })
    $('setCursorBlink')?.addEventListener('change', () => refreshSettingsPreview())
  }

  async function refreshSettingsPreview() {
    const schemeId = $('setScheme')?.value || state.settings.colorScheme || 'dracula'
    const fontFamily = withMonoI18n($('setFontFamily')?.value || state.settings.fontFamily || DEFAULT_TERM_FONT_FAMILY)
    const fontSize = Number($('setFontSize')?.value) || state.settings.fontSize || 13
    const theme = (await fetchSchemeTheme(schemeId)) || buildLocalFallbackTheme(state.settings)
    updateTermPreview(theme, fontFamily, fontSize)
    // 设置面板改配色时立刻作用到真终端（预览不带粘住的 override）
    try {
      if (term) {
        await applyTerminalAppearance({
          schemeId,
          forceSchemeBackground: true,
          settingsPatch: {
            fontFamily,
            fontSize,
            cursorStyle: $('setCursorStyle')?.value || state.settings.cursorStyle,
            cursorBlink: $('setCursorBlink') ? !!$('setCursorBlink').checked : state.settings.cursorBlink,
            colorScheme: schemeId,
          },
        })
      }
    } catch (_) {}
  }

  async function refreshCliStatusHint() {
    const el = $('cliStatusHint')
    if (!el || !hasApi || !api.cliStatus) return
    try {
      const st = await api.cliStatus()
      const on = !!(st && st.enabled)
      el.innerHTML =
        (on
          ? `外部 CLI：<b style="color:var(--ok)">已启用</b> · <code>127.0.0.1:${st.port || 8766}</code>`
          : `外部 CLI：<b style="color:var(--warn)">已关闭</b>`) +
        ` · token: <code style="font-size:11px">Application Support/PixShell/agent_token</code><br/>` +
        `AI 用 <code>pixshell-cli sessions</code> / <code>exec</code> 操作本机会话（仅本机回环）。`
      updateCliStatusBar(st)
    } catch (_) {}
  }

  function updateCliStatusBar(st) {
    const el = $('statusLine')
    if (!el) return
    // 文案三态（勿把「桥在监听」说成「已连接/已对接」）：
    //  未开启 = 设置关或未 listen
    //  已开启 = 本地桥在听，尚无外部 CLI/Agent 请求
    //  已对接 = 近期有鉴权通过的外部请求
    let textEl = $('cliText')
    if (!textEl) {
      textEl = document.createElement('span')
      textEl.id = 'cliText'
      textEl.className = 'cli-text'
      el.appendChild(textEl)
    }
    let dot = $('cliDot')
    if (!dot) {
      dot = document.createElement('span')
      dot.id = 'cliDot'
      dot.className = 'cli-dot'
      dot.setAttribute('aria-hidden', 'true')
      el.insertBefore(dot, textEl)
    }
    el.classList.remove('on', 'off', 'err', 'warn')
    dot.classList.remove('on', 'off', 'err', 'warn')
    const listening = !!(st && st.listening)
    const clientMs = Number(st && st.clientIdleMs)
    const paired =
      listening &&
      st &&
      st.clientSeen &&
      (Number.isFinite(clientMs) ? clientMs < 5 * 60 * 1000 : true)
    if (paired) {
      textEl.textContent = 'CLI 已对接'
      el.classList.add('on')
      dot.classList.add('on')
      el.title = st?.port
        ? `外部 CLI/Agent 已对接 · 127.0.0.1:${st.port}`
        : '外部 CLI/Agent 已对接'
    } else if (listening) {
      // 仅本地桥开启，没有外部客户端 — 不算「已连接」
      textEl.textContent = 'CLI 已开启'
      el.classList.add('warn')
      dot.classList.add('warn')
      el.title = st?.port
        ? `本地桥监听中，等待外部 CLI/Agent · 127.0.0.1:${st.port}（设置里可关闭）`
        : '本地桥已开启，尚无外部对接'
    } else {
      textEl.textContent = 'CLI 未开启'
      el.classList.add('off')
      dot.classList.add('off')
      el.title = st?.settingsOn
        ? '设置已开但未监听 — 可重启或检查端口'
        : '外部 CLI 未开启 — 设置 → 外部 CLI 集成'
    }
  }

  async function refreshCliStatusBar() {
    if (!hasApi || !api.cliStatus) {
      updateCliStatusBar(null)
      return
    }
    try {
      const st = await api.cliStatus()
      updateCliStatusBar(st)
    } catch (_) {
      const el = $('statusLine')
      const textEl = $('cliText')
      if (el) {
        if (textEl) textEl.textContent = 'CLI 未连接'
        else el.textContent = 'CLI 未连接'
        el.classList.remove('on', 'err')
        el.classList.add('off')
        const dot = $('cliDot')
        if (dot) {
          dot.classList.remove('on', 'err')
          dot.classList.add('off')
        }
      }
    }
  }

  const BACKUP_PROVIDERS = [
    { id: 'local', name: '本地', desc: '导出/导入本机 JSON 备份包（hosts / 设置 / 快捷命令）', fields: [] },
    { id: 'webdav', name: 'WebDAV', desc: '一键打开坚果云等登录页，再填应用密码/路径', fields: [
      { key: 'url', label: '服务器 URL', ph: 'https://dav.example.com/remote.php/dav/files/user/' },
      { key: 'user', label: '用户名', ph: '' },
      { key: 'password', label: '密码/应用密码', ph: '', password: true },
      { key: 'path', label: '远端路径', ph: '/PixShell/backup.json' },
    ]},
    { id: 'github', name: 'GitHub', desc: '一键登录 GitHub（Device Flow）或浏览器授权，自动写入 Token', fields: [
      { key: 'token', label: 'Token', ph: 'ghp_…', password: true },
      { key: 'gistId', label: 'Gist ID（可选）', ph: '留空则首次创建' },
      { key: 'filename', label: '文件名', ph: 'pixshell-backup.json' },
    ]},
    { id: 'google', name: '谷歌云盘', desc: 'Google Drive API（OAuth 客户端）', fields: [
      { key: 'clientId', label: 'Client ID', ph: '' },
      { key: 'clientSecret', label: 'Client Secret', ph: '', password: true },
      { key: 'folderId', label: '文件夹 ID（可选）', ph: '' },
    ]},
    { id: 'microsoft', name: '微软 OneDrive', desc: 'Microsoft Graph / OneDrive', fields: [
      { key: 'clientId', label: 'Application (client) ID', ph: '' },
      { key: 'clientSecret', label: 'Client Secret', ph: '', password: true },
      { key: 'tenant', label: 'Tenant', ph: 'common' },
    ]},
    { id: 'baidu', name: '百度网盘', desc: '百度网盘开放平台应用', fields: [
      { key: 'appKey', label: 'App Key', ph: '' },
      { key: 'secretKey', label: 'Secret Key', ph: '', password: true },
      { key: 'path', label: '网盘路径', ph: '/apps/PixShell/backup.json' },
    ]},
    { id: 'quark', name: '夸克网盘', desc: '夸克开放能力 / Cookie 会话（按官方文档）', fields: [
      { key: 'cookie', label: 'Cookie / Token', ph: '', password: true },
      { key: 'path', label: '网盘路径', ph: '/PixShell/backup.json' },
    ]},
  ]

  function defaultBackupSettings() {
    const providers = {}
    for (const p of BACKUP_PROVIDERS) {
      providers[p.id] = { enabled: false, config: {} }
    }
    return { providers, lastExportAt: null, lastImportAt: null }
  }

  function getBackupSettings() {
    state.settings = state.settings || {}
    if (!state.settings.backup || typeof state.settings.backup !== 'object') {
      state.settings.backup = defaultBackupSettings()
    }
    // ensure all providers exist
    const base = defaultBackupSettings()
    for (const id of Object.keys(base.providers)) {
      if (!state.settings.backup.providers[id]) {
        state.settings.backup.providers[id] = base.providers[id]
      }
    }
    return state.settings.backup
  }

  function isBackupEnabled(providerId) {
    const b = getBackupSettings()
    return !!(b.providers?.[providerId]?.enabled)
  }

  let backupUi = { selected: 'local', draft: null }

  function openBackupConfig(selectId) {
    if (!document.body.classList.contains('float-window') && hasApi && typeof api.openFloatWindow === 'function') {
      openIndependentFloat({
        kind: 'backup',
        id: 'backup',
        title: '备份与恢复',
        width: 640,
        height: 480,
        init: { selectId }
      }).catch(console.error)
      return
    }
    
    backupUi.selected = selectId || backupUi.selected || 'local'
    backupUi.draft = JSON.parse(JSON.stringify(getBackupSettings()))
    renderBackupGrid()
    renderBackupDetail()
    showModal('backupModal', true)
    
    const modal = $('backupModal')?.querySelector('.modal')
    if (document.body.classList.contains('float-window') && modal) {
      modal.style.width = '100%'
      modal.style.height = '100%'
      modal.style.left = '0'
      modal.style.top = '0'
      modal.style.position = 'relative'
    }
  }

  function renderBackupGrid() {
    const grid = $('backupGrid')
    if (!grid || !backupUi.draft) return
    grid.innerHTML = BACKUP_PROVIDERS.map((p) => {
      const st = backupUi.draft.providers[p.id] || { enabled: false }
      const active = backupUi.selected === p.id ? ' active' : ''
      return `<div class="backup-card${active}" data-id="${p.id}">
        <div class="backup-card-top">
          <div class="backup-card-name">${esc(p.name)}</div>
          <span class="backup-state ${st.enabled ? 'on' : ''}">${st.enabled ? '已启用' : '未配置'}</span>
        </div>
        <div class="backup-card-desc">${esc(p.desc)}</div>
        <div class="backup-card-foot">
          <label class="backup-enable" data-stop="1">
            <input type="checkbox" data-enable="${p.id}" ${st.enabled ? 'checked' : ''} />
            启用
          </label>
          <span class="link-btn" data-cfg="${p.id}">配置</span>
        </div>
      </div>`
    }).join('')
    grid.querySelectorAll('.backup-card').forEach((card) => {
      card.addEventListener('click', (e) => {
        if (e.target.closest('[data-stop]')) return
        backupUi.selected = card.dataset.id
        renderBackupGrid()
        renderBackupDetail()
      })
    })
    grid.querySelectorAll('input[data-enable]').forEach((inp) => {
      inp.addEventListener('change', (e) => {
        e.stopPropagation()
        const id = inp.getAttribute('data-enable')
        backupUi.draft.providers[id] = backupUi.draft.providers[id] || { enabled: false, config: {} }
        backupUi.draft.providers[id].enabled = !!inp.checked
        renderBackupGrid()
        renderBackupDetail()
      })
      inp.addEventListener('click', (e) => e.stopPropagation())
    })
    grid.querySelectorAll('[data-cfg]').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation()
        backupUi.selected = btn.getAttribute('data-cfg')
        renderBackupGrid()
        renderBackupDetail()
      })
    })
  }

  function renderBackupDetail() {
    const box = $('backupDetail')
    const form = $('backupDetailForm')
    const title = $('backupDetailTitle')
    if (!box || !form || !backupUi.draft) return
    const p = BACKUP_PROVIDERS.find((x) => x.id === backupUi.selected) || BACKUP_PROVIDERS[0]
    const st = backupUi.draft.providers[p.id] || { enabled: false, config: {} }
    st.config = st.config || {}
    if (title) title.textContent = p.name + ' · 配置' + (st.enabled ? '（已启用）' : '')
    const oneClickIds = ['github', 'webdav', 'google', 'microsoft', 'baidu', 'quark']
    let oneClickHtml = ''
    if (oneClickIds.includes(p.id)) {
      const isGh = p.id === 'github'
      oneClickHtml =
        '<div class="backup-oneclick" style="grid-column:1/-1">' +
        '<button type="button" class="cmd-btn primary" id="btnBackupOneClick">' +
        (isGh ? '一键登录 GitHub（Device Flow）' : '一键打开登录页') +
        '</button>' +
        (isGh
          ? '<button type="button" class="cmd-btn" id="btnBackupGhBrowser">仅打开 GitHub 网站</button>'
          : '') +
        '</div>' +
        '<div class="form-tip" id="backupOneClickHint" style="grid-column:1/-1;font-size:11px;opacity:.9">' +
        (isGh
          ? '推荐：一键登录自动获取 Token，无需手填。也可在浏览器登录后粘贴 Token（兼容）。'
          : '一键打开服务商登录页；登录后按提示完成授权/应用密码，无需先死记字段。') +
        '</div>' +
        '<div class="backup-device-code" id="backupDeviceBox" hidden style="grid-column:1/-1"></div>'
    }
    if (!p.fields.length) {
      form.innerHTML =
        '<div class="form-tip" style="grid-column:1/-1">本地备份无需账号。使用下方「导出/导入本地包」。</div>'
      box.hidden = false
      return
    }
    form.innerHTML =
      oneClickHtml +
      p.fields
        .map((f) => {
          const val = st.config[f.key] != null ? String(st.config[f.key]) : ''
          const type = f.password ? 'password' : 'text'
          return (
            '<label>' +
            esc(f.label) +
            '</label><input data-bk="' +
            esc(f.key) +
            '" type="' +
            type +
            '" class="thin-input" placeholder="' +
            esc(f.ph || '') +
            '" value="' +
            esc(val) +
            '" />'
          )
        })
        .join('')
    form.querySelectorAll('input[data-bk]').forEach((inp) => {
      inp.addEventListener('input', () => {
        const key = inp.getAttribute('data-bk')
        backupUi.draft.providers[p.id] = backupUi.draft.providers[p.id] || { enabled: false, config: {} }
        backupUi.draft.providers[p.id].config = backupUi.draft.providers[p.id].config || {}
        backupUi.draft.providers[p.id].config[key] = inp.value
      })
    })
    const bindOne = (id, fn) => {
      const el = form.querySelector('#' + id) || $(id)
      if (el) el.onclick = fn
    }
    bindOne('btnBackupOneClick', async () => {
      if (p.id === 'github') await startGitHubBackupLogin()
      else await openBackupProviderLogin(p.id)
    })
    bindOne('btnBackupGhBrowser', async () => {
      await openBackupProviderLogin('github')
    })
    box.hidden = false
  }

  async function openBackupProviderLogin(providerId) {
    if (!hasApi || typeof api.backupOpenLogin !== 'function') {
      // 无 API 时仍尝试 openExternal
      try {
        if (api.openExternal) {
          const map = {
            github: 'https://github.com/login',
            webdav: 'https://www.jianguoyun.com/d/login',
            google: 'https://accounts.google.com/',
            microsoft: 'https://login.microsoftonline.com/',
            baidu: 'https://pan.baidu.com/',
            quark: 'https://pan.quark.cn/',
          }
          await api.openExternal(map[providerId] || 'https://github.com/login')
          toast('已打开登录页')
          return
        }
      } catch (_) {}
      return toast('无法打开登录页', true)
    }
    const r = await api.backupOpenLogin(providerId)
    if (r?.ok) toast('已打开 ' + (providerId) + ' 登录页')
    else toast('打开失败: ' + (r?.error || ''), true)
  }

  async function startGitHubBackupLogin() {
    if (!hasApi || typeof api.backupGithubDeviceStart !== 'function') {
      return openBackupProviderLogin('github')
    }
    toast('正在启动 GitHub 登录…')
    const r = await api.backupGithubDeviceStart()
    if (!r?.ok) {
      toast('Device Flow 不可用，已改为打开登录页: ' + (r?.error || ''), true)
      return openBackupProviderLogin('github')
    }
    const box = $('backupDeviceBox')
    if (box) {
      box.hidden = false
      box.removeAttribute('hidden')
      box.innerHTML =
        '请在浏览器输入设备码：<code>' +
        esc(r.userCode || '') +
        '</code><br/>页面：' +
        esc(r.verificationUri || '') +
        '<br/><span id="backupDeviceStatus">等待授权…</span>'
    }
    // poll
    const deviceCode = r.deviceCode
    const clientId = r.clientId
    let interval = Math.max(3, Number(r.interval) || 5) * 1000
    const deadline = Date.now() + (Number(r.expiresIn) || 900) * 1000
    const tick = async () => {
      if (Date.now() > deadline) {
        if ($('backupDeviceStatus')) $('backupDeviceStatus').textContent = '已超时，请重试'
        return
      }
      const pr = await api.backupGithubDevicePoll(deviceCode, clientId)
      if (pr?.ok && pr.accessToken) {
        if ($('backupDeviceStatus')) $('backupDeviceStatus').textContent = '授权成功，正在保存…'
        const ar = await api.backupApplyOAuth('github', pr.accessToken, 'pixshell-backup.json')
        if (ar?.ok) {
          // sync draft
          try {
            backupUi.draft = JSON.parse(JSON.stringify(ar.backup || getBackupSettings()))
            state.settings.backup = ar.backup
          } catch (_) {}
          // fill token field if visible
          const tok = document.querySelector('input[data-bk="token"]')
          if (tok) tok.value = pr.accessToken
          if (backupUi.draft?.providers?.github) {
            backupUi.draft.providers.github.enabled = true
            backupUi.draft.providers.github.config = backupUi.draft.providers.github.config || {}
            backupUi.draft.providers.github.config.token = pr.accessToken
          }
          renderBackupGrid()
          renderBackupDetail()
          toast('GitHub 已登录并写入配置')
        } else toast('保存失败: ' + (ar?.error || ''), true)
        return
      }
      if (pr?.slowDown) interval += 2000
      if (pr?.pending || pr?.error === 'authorization_pending' || pr?.error === 'slow_down') {
        setTimeout(tick, interval)
        return
      }
      if ($('backupDeviceStatus'))
        $('backupDeviceStatus').textContent = '失败: ' + (pr?.error || 'unknown')
    }
    setTimeout(tick, interval)
  }

  async function saveBackupConfig() {
    if (!backupUi.draft) return
    state.settings = state.settings || {}
    state.settings.backup = backupUi.draft
    if (hasApi && api.saveSettings) {
      const r = await api.saveSettings(state.settings)
      if (r && r.ok === false) return toast('保存失败: ' + (r.error || ''), true)
    }
    showModal('backupModal', false)
    toast('备份选项已保存（仅已启用的提供商会生效）')
  }

  async function exportLocalBackupBundle() {
    if (!hasApi) return toast('无 fsApi', true)
    try {
      // lazy use packages/sync if available via dynamic path is not in renderer;
      // build bundle inline (same shape as packages/sync exportBundle)
      const hosts = (state.hosts || []).map(({ password, privateKey, ...h }) => h)
      const bundle = {
        version: 1,
        exportedAt: new Date().toISOString(),
        hosts,
        settings: { ...(state.settings || {}) },
        quickCommands: state.quick || [],
      }
      // strip secrets from settings.backup configs optionally keep structure
      const text = JSON.stringify(bundle, null, 2)
      const r = await api.saveFile?.({ defaultPath: `pixshell-backup-${new Date().toISOString().slice(0, 10)}.json` })
      if (!r?.ok || !r.path) return
      const w = await api.writeTextFile(r.path, text)
      if (w && w.ok === false) return toast('写入失败: ' + (w.error || ''), true)
      const b = getBackupSettings()
      b.lastExportAt = new Date().toISOString()
      if (api.saveSettings) await api.saveSettings(state.settings)
      toast('已导出本地备份: ' + r.path)
    } catch (e) {
      toast('导出失败: ' + (e.message || e), true)
    }
  }

  async function importLocalBackupBundle() {
    if (!hasApi) return toast('无 fsApi', true)
    try {
      const f = await api.openFile?.()
      const path = f?.path || f?.paths?.[0] || f?.filePaths?.[0]
      if (!f?.ok || !path) return
      const r = await api.readTextFile(path)
      const text = typeof r === 'string' ? r : r?.text || r?.data || r?.content
      if (!text) return toast('读取失败', true)
      const bundle = JSON.parse(text)
      if (!bundle || bundle.version !== 1) return toast('不支持的备份格式', true)
      if (!(await askConfirm(`导入将合并 ${ (bundle.hosts || []).length } 台主机配置，是否继续？`, { title: '导入本地备份' }))) return
      // merge hosts by id
      const map = new Map((state.hosts || []).map((h) => [h.id, h]))
      for (const h of bundle.hosts || []) {
        if (!h || !h.id) continue
        map.set(h.id, { ...map.get(h.id), ...h })
      }
      state.hosts = [...map.values()]
      if (bundle.quickCommands) state.quick = bundle.quickCommands
      if (bundle.settings && typeof bundle.settings === 'object') {
        // do not clobber theme/cli blindly — shallow merge
        state.settings = { ...state.settings, ...bundle.settings, backup: state.settings.backup }
      }
      await persistHosts()
      if (api.saveSettings) await api.saveSettings(state.settings)
      if (api.saveQuick && state.quick) await api.saveQuick(state.quick)
      renderConnMgr()
      renderCmdBoard()
      const b = getBackupSettings()
      b.lastImportAt = new Date().toISOString()
      if (api.saveSettings) await api.saveSettings(state.settings)
      toast('导入完成')
    } catch (e) {
      toast('导入失败: ' + (e.message || e), true)
    }
  }

  async function runBackupProvider(providerId) {
    if (providerId === 'local') {
      return exportLocalBackupBundle()
    }
    if (!isBackupEnabled(providerId)) {
      toast('该备份方式尚未启用 — 请先在「备份选项配置」中勾选启用', true)
      openBackupConfig(providerId)
      return
    }
    const p = BACKUP_PROVIDERS.find((x) => x.id === providerId)
    const conf = getBackupSettings().providers[providerId]?.config || {}
    // 云端实际上传后续接 API；当前给出已配置确认与本地导出兜底
    toast(`${p?.name || providerId} 已启用。云端推送接口开发中，已先执行本地导出作为备份。`)
    await exportLocalBackupBundle()
    console.log('[backup] provider ready', providerId, Object.keys(conf))
  }

  async function saveSettings() {
    if ($('setThemeMode')?.value) setThemeMode($('setThemeMode').value, { persist: false })
    state.settings.fontSize = Number($('setFontSize')?.value) || 13
    state.settings.fontFamily = withMonoI18n(
      $('setFontFamily')?.value ||
      state.settings.fontFamily ||
      DEFAULT_TERM_FONT_FAMILY
    )
    const prevScheme = state.settings.colorScheme || 'dracula'
    const nextScheme = $('setScheme')?.value || state.settings.colorScheme || 'dracula'
    state.settings.colorScheme = nextScheme
    state.settings.cursorStyle = $('setCursorStyle')?.value || 'block'
    state.settings.cursorBlink = !!$('setCursorBlink')?.checked
    state.settings.termType = $('setTermType')?.value || 'xterm-256color'
    state.settings.drawBoldTextInBrightColors = $('setBoldBright') ? !!$('setBoldBright').checked : state.settings.drawBoldTextInBrightColors !== false
    state.settings.editorSyntaxHl = $('setEditorSyntaxHl') ? !!$('setEditorSyntaxHl').checked : state.settings.editorSyntaxHl !== false
    state.settings.editorWordWrap = $('setEditorWordWrap') ? !!$('setEditorWordWrap').checked : !!state.settings.editorWordWrap
    state.settings.termLiveHighlight = $('setTermLiveHl') ? !!$('setTermLiveHl').checked : state.settings.termLiveHighlight !== false
    // 用户在设置里换了配色方案：清掉粘住的 termBgOverride，否则背景永远盖住新方案（日志里 override 压 monokai 就是这问题）
    // 右键「设置背景」仍可再写 override；背景面板「恢复配色默认」也会清
    if (String(prevScheme) !== String(nextScheme)) {
      try {
        delete state.settings.termBgOverride
        delete state.settings.termBg
        state.settings.termBgUserSet = false
      } catch (_) {}
    }
    state.settings.layout = state.settings.layout || {}
    state.settings.layout.sidebarWidth = Number($('setSideW')?.value) || 240
    state.settings.layout.bottomHeight = Number($('setBottomH')?.value) || 200
    state.settings.syncDirWithSftp = !!$('setSyncSftp')?.checked
    state.settings.autoReconnect = !!$('setAutoReconnect')?.checked
    state.settings.monitorIntervalSec = Math.max(4, Number($('setMonInterval')?.value) || 8)
    state.settings.externalCliEnabled = !!$('setExternalCli')?.checked
    state.settings.externalCliPort = Math.max(1024, Number($('setCliPort')?.value) || 8766)
    document.documentElement.style.setProperty('--sidebar-w', state.settings.layout.sidebarWidth + 'px')
    document.documentElement.style.setProperty('--bottom-h', state.settings.layout.bottomHeight + 'px')
    const schemeChanged = String(prevScheme) !== String(state.settings.colorScheme)
    const darkUnlocked = (state.settings?.theme || 'dark') !== 'light' && state.settings?.termBgUserSet !== true
    await applyTerminalAppearance({ forceSchemeBackground: schemeChanged || darkUnlocked })
    if (hasApi) {
      await api.saveSettings(state.settings)
      if (api.setAutoReconnect) await api.setAutoReconnect(state.settings.autoReconnect)
      if (api.cliSetEnabled) {
        const r = await api.cliSetEnabled(state.settings.externalCliEnabled, state.settings.externalCliPort)
        if (!r?.ok) toast('CLI 桥: ' + (r?.error || '失败'), true)
      }
    }
    showModal('settingsModal', false)
    toast('设置已保存')
    if (sessionTab()?.sessionId) startMonitor()
  }

  function bindResizers() {
    // 可重复调用：先卸旧监听再绑（避免 capture 丢事件 / 热更新残留）
    const prev = state._resizeCtl
    if (prev && typeof prev.destroy === 'function') {
      try { prev.destroy() } catch (_) {}
    }

    let dragging = null
    const cleanups = []
    const on = (target, type, fn, opts) => {
      if (!target) return
      target.addEventListener(type, fn, opts)
      cleanups.push(() => target.removeEventListener(type, fn, opts))
    }

    const readBottomH = () => {
      const raw = getComputedStyle(document.documentElement).getPropertyValue('--bottom-h')
      const n = parseInt(String(raw).trim(), 10)
      return Number.isFinite(n) && n > 0 ? n : 200
    }
    const readSideW = () => {
      const raw = getComputedStyle(document.documentElement).getPropertyValue('--sidebar-w')
      const n = parseInt(String(raw).trim(), 10)
      return Number.isFinite(n) && n > 0 ? n : 240
    }

    /** 同时改 CSS 变量 + 直接写 grid，避免变量未刷新 */
    const applyBottom = (h) => {
      const v = Math.min(620, Math.max(120, Math.round(h)))
      document.documentElement.style.setProperty('--bottom-h', v + 'px')
      const wc = document.querySelector('.work-center')
      if (wc) {
        if (wc.classList.contains('chrome-compact')) {
          wc.style.gridTemplateRows = ''
        } else if (wc.classList.contains('bottom-collapsed')) {
          wc.style.gridTemplateRows = '1fr var(--cmd-h) 0 0'
        } else {
          wc.classList.remove('chrome-compact')
          wc.style.gridTemplateRows = '1fr var(--cmd-h) 4px ' + v + 'px'
        }
      }
      // dock 高度由 grid 行（--bottom-h）单一控制；这里清掉历史内联高，
      // 否则内联 height 与 grid 行一旦不同步（如连接时 setBottomCollapsed 只改 grid
      // 不改内联），dock 就填不满网格行、底部露一大截白（发送条上浮到中间）。
      const dock = $('bottomDock')
      if (dock) {
        dock.style.height = ''
        dock.style.maxHeight = ''
        dock.style.minHeight = ''
        dock.style.display = ''
      }
      return v
    }
    const applySide = (w) => {
      const v = Math.min(420, Math.max(160, Math.round(w)))
      document.documentElement.style.setProperty('--sidebar-w', v + 'px')
      return v
    }
    const persist = (kind, last) => {
      if (last == null || !Number.isFinite(last)) return
      state.settings.layout = state.settings.layout || {}
      if (kind === 'side') state.settings.layout.sidebarWidth = last
      else state.settings.layout.bottomHeight = last
      if (hasApi && api.saveSettings) api.saveSettings(state.settings).catch((e) => console.warn('[save layout]', e))
      try { fitAddon?.fit() } catch (_) {}
    }

    const onMove = (e) => {
      if (!dragging) return
      // 兼容 pointer / mouse
      const clientX = e.clientX
      const clientY = e.clientY
      if (clientX == null && clientY == null) return
      if (dragging.type === 'side') {
        dragging._last = applySide(dragging.w + (clientX - dragging.x))
      } else {
        dragging._last = applyBottom(dragging.h + (dragging.y - clientY))
        try { fitAddon?.fit() } catch (_) {}
      }
      if (e.cancelable) e.preventDefault()
    }

    const endDrag = (e) => {
      if (!dragging) return
      const kind = dragging.type
      const last = dragging._last
      const el = dragging.el
      try {
        if (e && el && e.pointerId != null && el.releasePointerCapture) {
          el.releasePointerCapture(e.pointerId)
        }
      } catch (_) {}
      if (el) el.classList.remove('is-dragging')
      dragging = null
      document.body.classList.remove('resizing-layout')
      persist(kind, last)
    }

    // 关键：document 捕获阶段 —— setPointerCapture 后 window 监听会丢事件
    on(document, 'pointermove', onMove, true)
    on(document, 'pointerup', endDrag, true)
    on(document, 'pointercancel', endDrag, true)
    on(document, 'mousemove', onMove, true)
    on(document, 'mouseup', endDrag, true)

    const startBottomDrag = (e, el) => {
      // 紧凑模式（快速连接）不拖底栏；终端页若误标 compact 则清掉
      const wc = document.querySelector('.work-center')
      if (wc && wc.classList.contains('chrome-compact')) {
        const tab = state.tabs.find((t) => t.id === state.activeTabId)
        if (tab && tab.type === 'term') {
          setChromeCompact(false)
          setBottomCollapsed(false)
        } else {
          return
        }
      }
      if (state.bottomCollapsed) return
      if (e.button != null && e.button !== 0) return
      // 忽略来自按钮的事件
      if (e.target && e.target.closest && e.target.closest('button, input, select, a, textarea')) {
        // 允许点在 resizer 把手本身
        if (!e.target.closest('#bottomResizer')) return
      }
      const handle = el || $('bottomResizer')
      dragging = {
        type: 'bottom',
        y: e.clientY,
        h: readBottomH(),
        el: handle,
        _last: readBottomH(),
      }
      document.body.classList.add('resizing-layout')
      if (handle) handle.classList.add('is-dragging')
      try {
        if (e.pointerId != null && handle && handle.setPointerCapture) {
          handle.setPointerCapture(e.pointerId)
        }
      } catch (_) {}
      // 元素上也绑 move（capture 目标是 el 时必经）
      if (handle && !handle._psMoveBound) {
        handle._psMoveBound = true
        handle.addEventListener('pointermove', onMove)
        handle.addEventListener('pointerup', endDrag)
        handle.addEventListener('pointercancel', endDrag)
      }
      if (e.cancelable) e.preventDefault()
      e.stopPropagation()
    }

    const br = $('bottomResizer')
    if (br) {
      on(br, 'pointerdown', (e) => startBottomDrag(e, br))
      on(br, 'mousedown', (e) => startBottomDrag(e, br))
      on(br, 'dblclick', (e) => {
        e.preventDefault()
        applyBottom(200)
        persist('bottom', 200)
      })
    }

    // 底栏高度只保留 #bottomResizer 一条（去掉内嵌 grip 双条）

    // cmd-bar 底边热区（无第二条视觉条，仅扩大可拖区域）
    const cmdBar = $('cmdBar')
    if (cmdBar && !cmdBar.dataset.resizeEdgeBound) {
      cmdBar.dataset.resizeEdgeBound = '1'
      on(cmdBar, 'pointerdown', (e) => {
        const rect = cmdBar.getBoundingClientRect()
        if (rect.bottom - e.clientY > 10) return
        startBottomDrag(e, br || cmdBar)
      })
      on(cmdBar, 'mousedown', (e) => {
        const rect = cmdBar.getBoundingClientRect()
        if (rect.bottom - e.clientY > 10) return
        startBottomDrag(e, br || cmdBar)
      })
    }

    // tabs 顶缘
    const tabs = document.querySelector('#bottomDock .bottom-tabs')
    if (tabs && !tabs.dataset.resizeBound) {
      tabs.dataset.resizeBound = '1'
      on(tabs, 'pointerdown', (e) => {
        if (e.target.closest('button')) {
          const rect = tabs.getBoundingClientRect()
          if (e.clientY - rect.top > 6) return
        } else {
          const rect = tabs.getBoundingClientRect()
          if (e.clientY - rect.top > 10) return
        }
        startBottomDrag(e, br || br || tabs)
      })
    }

    const side = $('sidebarResizer')
    if (side) {
      const startSide = (e) => {
        if (state.sideCollapsed) return
        if (e.button != null && e.button !== 0) return
        dragging = {
          type: 'side',
          x: e.clientX,
          w: readSideW(),
          el: side,
          _last: readSideW(),
        }
        document.body.classList.add('resizing-layout')
        try {
          if (e.pointerId != null && side.setPointerCapture) side.setPointerCapture(e.pointerId)
        } catch (_) {}
        if (!side._psMoveBound) {
          side._psMoveBound = true
          side.addEventListener('pointermove', onMove)
          side.addEventListener('pointerup', endDrag)
          side.addEventListener('pointercancel', endDrag)
        }
        if (e.cancelable) e.preventDefault()
      }
      on(side, 'pointerdown', startSide)
      on(side, 'mousedown', startSide)
    }

    // 启动时对齐一次 layout
    try {
      if (!state.bottomCollapsed) applyBottom(readBottomH())
    } catch (_) {}

    state._resizeCtl = {
      destroy() {
        for (const off of cleanups) {
          try { off() } catch (_) {}
        }
        cleanups.length = 0
        state._resizersBound = false
      },
    }
    state._resizersBound = true
  }


  function on(id, event, handler) {
    const el = typeof id === 'string' ? $(id) : id
    if (!el) return false
    el.addEventListener(event, (e) => {
      try {
        const r = handler(e)
        if (r && typeof r.then === 'function') r.catch((err) => {
          console.error(err)
          toast(err.message || String(err), true)
        })
      } catch (err) {
        console.error(err)
        toast(err.message || String(err), true)
      }
    })
    return true
  }


  // ── Terminal background presets ───────────────────────
  const TERM_BG_PRESETS = [
    { id: 'deep', name: '深灰', color: '#0f1419' },
    { id: 'default', name: '默认', color: '#1e1f29' },
    { id: 'night', name: 'Night', color: '#1a1b26' },
    { id: 'dracula', name: 'Dracula', color: '#282a36' },
    { id: 'solar', name: 'Solarized', color: '#002b36' },
    { id: 'cat', name: 'Catppuccin', color: '#1e1e2e' },
    { id: 'github', name: 'GitHub', color: '#0d1117' },
    { id: 'nord', name: 'Nord', color: '#2e3440' },
    { id: 'rose', name: 'Rosé', color: '#191724' },
    { id: 'tokyo', name: 'Tokyo', color: '#16161e' },
    { id: 'gray', name: '黑灰', color: '#1c1c1c' },
    { id: 'black', name: '纯黑', color: '#000000' },
  ]

  function normalizeCssColor(c) {
    const s = String(c || '').trim()
    if (!s) return ''
    if (/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(s)) return s
    if (/^rgb(a)?\(/i.test(s) || /^hsl(a)?\(/i.test(s)) return s
    // allow named? keep short
    if (/^[a-zA-Z]+$/.test(s) && s.length < 20) return s
    return s
  }

  function previewTermBg(color) {
    const box = $('termBgPreview')
    const text = $('termBgPreviewText')
    if (!box) return
    const c = normalizeCssColor(color) || '#0f1419'
    box.style.background = c
    // 预览字色：深底用浅字
    if (text) {
      // 简单亮度：#rrggbb
      let light = true
      const m = /^#([0-9a-fA-F]{6})$/.exec(c)
      if (m) {
        const n = parseInt(m[1], 16)
        const r = (n >> 16) & 255
        const g = (n >> 8) & 255
        const b = n & 255
        const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        light = lum < 0.55
      }
      text.style.color = light ? '#cdd6f4' : '#1d1d1f'
    }
  }

  function paintTermBgGrid(selected) {
    const grid = $('termBgGrid')
    if (!grid) return
    const sel = normalizeCssColor(selected).toLowerCase()
    grid.innerHTML = TERM_BG_PRESETS.map((p) => {
      const active = sel && p.color.toLowerCase() === sel ? ' active' : ''
      return `<button type="button" class="term-bg-swatch${active}" data-color="${esc(p.color)}" title="${esc(p.color)}">
        <span class="term-bg-swatch-chip" style="background:${esc(p.color)}"></span>
        <span class="term-bg-swatch-name">${esc(p.name)}</span>
      </button>`
    }).join('')
    grid.querySelectorAll('.term-bg-swatch').forEach((btn) => {
      btn.addEventListener('click', () => {
        const c = btn.getAttribute('data-color') || ''
        state._termBgPick = c
        if ($('termBgCustom')) $('termBgCustom').value = c
        if ($('termBgColorPick') && /^#([0-9a-fA-F]{6})$/.test(c)) $('termBgColorPick').value = c
        paintTermBgGrid(c)
        previewTermBg(c)
      })
    })
  }

  async function applyTermBgColor(color, { clear = false } = {}) {
    state.settings = state.settings || {}
    if (clear) {
      delete state.settings.termBgOverride
      try {
        delete state.settings.termBg
      } catch (_) {}
      state.settings.termBgUserSet = false
      try {
        rlog('info', 'term', 'bg-clear')
      } catch (_) {}
    } else {
      const c = normalizeCssColor(color)
      if (!c) return toast('无效颜色', true)
      state.settings.termBgOverride = c
      state.settings.termBg = c
      state.settings.termBgUserSet = true
      try {
        rlog('info', 'term', 'bg-set', { color: c })
      } catch (_) {}
    }
    try {
      await applyTerminalAppearance({ forceSchemeBackground: !!clear })
    } catch (e) {
      try {
        rlog('error', 'term', 'bg-apply-fail', { err: e && e.message })
      } catch (_) {}
      return toast('应用背景失败: ' + (e && e.message ? e.message : e), true)
    }
    // 立即再刷 DOM，防止 toast/modal 关闭后被盖住（仍走 resolve，避免暗色吃浅灰）
    try {
      const mode = state.settings?.theme === 'light' ? 'light' : 'dark'
      const bg =
        resolveTermBgOverride(state.settings, mode) ||
        state._activeTermTheme?.background ||
        (mode === 'light' ? '#d4d6dc' : '#0f1419')
      paintTermBackgroundDom(bg)
    } catch (_) {}
    if (hasApi) {
      try {
        await api.saveSettings(state.settings)
      } catch (e) {
        try {
          rlog('error', 'term', 'bg-save-fail', { err: e && e.message })
        } catch (_) {}
      }
    }
    toast(clear ? '已恢复配色默认背景' : '背景已更新')
  }

  function openTermBgPicker() {
    const mask = $('termBgModal')
    if (!mask) return toast('背景面板缺失', true)
    const mode = state.settings?.theme === 'light' ? 'light' : 'dark'
    const cur =
      resolveTermBgOverride(state.settings, mode) ||
      state._activeTermTheme?.background ||
      (mode === 'light' ? '#d4d6dc' : '#0f1419')
    state._termBgPick = cur
    if ($('termBgCustom')) $('termBgCustom').value = cur
    if ($('termBgColorPick') && /^#([0-9a-fA-F]{6})$/.test(String(cur))) {
      $('termBgColorPick').value = cur
    }
    paintTermBgGrid(cur)
    previewTermBg(cur)
    showModal('termBgModal', true)
    makeModalFloatDraggable('termBgModal', { title: '终端背景', halfW: 260 })
  }

  function bindTermBgPickerUi() {
    if (state._termBgUiBound) return
    state._termBgUiBound = true
    on('btnTermBgClose', 'click', () => showModal('termBgModal', false))
    on('btnTermBgCancel', 'click', () => showModal('termBgModal', false))
    on('btnTermBgOk', 'click', async () => {
      const c = state._termBgPick || $('termBgCustom')?.value
      await applyTermBgColor(c)
      showModal('termBgModal', false)
    })
    on('btnTermBgReset', 'click', async () => {
      await applyTermBgColor(null, { clear: true })
      showModal('termBgModal', false)
    })
    on('btnTermBgCustomApply', 'click', () => {
      const c = normalizeCssColor($('termBgCustom')?.value || '')
      if (!c) return toast('请输入颜色，如 #0f1419', true)
      state._termBgPick = c
      paintTermBgGrid(c)
      previewTermBg(c)
    })
    on('termBgColorPick', 'input', (e) => {
      const c = e.target.value
      state._termBgPick = c
      if ($('termBgCustom')) $('termBgCustom').value = c
      paintTermBgGrid(c)
      previewTermBg(c)
    })
    on('termBgCustom', 'keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        $('btnTermBgCustomApply')?.click()
      }
    })
    // 点遮罩空白关闭
    $('termBgModal')?.addEventListener('click', (e) => {
      if (e.target === $('termBgModal')) showModal('termBgModal', false)
    })
  }

  async function pickPrivateKeyFile() {
    if (!hasApi) return toast('请用 Electron 启动', true)
    let path = ''
    try {
      if (typeof api.openKeyFile === 'function') {
        const r = await api.openKeyFile()
        if (r?.ok) path = r.path || r.paths?.[0] || ''
        else if (r && r.ok === false && !r.path) return
      } else if (api.openFile) {
        const r = await api.openFile()
        if (r?.ok) path = r.path || r.paths?.[0] || r.filePaths?.[0] || ''
        else return
      }
    } catch (e) {
      return toast('打开文件失败: ' + (e.message || e), true)
    }
    if (!path) return
    if ($('fKey')) $('fKey').value = path
    toast('已选择私钥: ' + path.split(/[/\\]/).pop())
  }

  function bindKeyPickDrop() {
    if (state._keyPickBound) return
    state._keyPickBound = true
    on('btnPickKey', 'click', () => pickPrivateKeyFile())
    const row = $('fKeyRow')
    const input = $('fKey')
    if (!row && !input) return
    const zone = row || input
    const setOver = (on) => {
      if (row) row.classList.toggle('drag-over', !!on)
    }
    ;['dragenter', 'dragover'].forEach((ev) => {
      zone.addEventListener(ev, (e) => {
        e.preventDefault()
        e.stopPropagation()
        setOver(true)
        try {
          e.dataTransfer.dropEffect = 'copy'
        } catch (_) {}
      })
    })
    ;['dragleave', 'dragend'].forEach((ev) => {
      zone.addEventListener(ev, (e) => {
        e.preventDefault()
        setOver(false)
      })
    })
    zone.addEventListener('drop', async (e) => {
      e.preventDefault()
      e.stopPropagation()
      setOver(false)
      const files = e.dataTransfer?.files
      if (!files || !files.length) return toast('未检测到文件', true)
      const f = files[0]
      let p = ''
      try {
        if (hasApi && typeof api.getPathForFile === 'function') p = api.getPathForFile(f) || ''
      } catch (_) {}
      if (!p) p = f.path || ''
      if (!p) {
        toast('无法读取文件路径，请点「打开」选择', true)
        return
      }
      if ($('fKey')) $('fKey').value = p
      toast('已填入私钥: ' + (f.name || p.split(/[/\\]/).pop()))
    })
  }

  // ── Terminal context menu ─────────────────────────────
  function showTermContextMenu(x, y) {
    removeCtx()
    const menu = document.createElement('div')
    menu.className = 'ctx-menu'
    menu.style.left = x + 'px'
    menu.style.top = y + 'px'
    const hasSel = !!(term && term.getSelection && term.getSelection())
    menu.innerHTML = `
      <button type="button" data-act="copy" ${hasSel ? '' : 'disabled'}>复制 <span class="ctx-accel">⌘C</span></button>
      <button type="button" data-act="paste">粘贴 <span class="ctx-accel">⌘V</span></button>
      <button type="button" data-act="paste-sel" ${hasSel ? '' : 'disabled'}>粘贴选中</button>
      <div class="ctx-sep"></div>
      <button type="button" data-act="find">查找 <span class="ctx-accel">⌘F</span></button>
      <div class="ctx-sep"></div>
      <button type="button" data-act="clear-buf">清空缓存</button>
      <button type="button" data-act="bg" style="color:var(--accent)">设置背景…</button>
    `
    document.body.appendChild(menu)
    // keep on screen
    const r = menu.getBoundingClientRect()
    if (r.right > window.innerWidth) menu.style.left = Math.max(8, window.innerWidth - r.width - 8) + 'px'
    if (r.bottom > window.innerHeight) menu.style.top = Math.max(8, window.innerHeight - r.height - 8) + 'px'

    menu.querySelectorAll('button[data-act]').forEach((b) => {
      b.addEventListener('click', async (e) => {
        e.stopPropagation()
        const act = b.getAttribute('data-act')
        removeCtx()
        const tab = sessionTab()
        if (act === 'copy') {
          const s = term?.getSelection?.() || ''
          if (s) {
            try { await navigator.clipboard.writeText(s); toast('已复制') } catch (_) { toast(s) }
          }
        } else if (act === 'paste') {
          try {
            const text = await navigator.clipboard.readText()
            if (text && tab?.sessionId && hasApi) await api.write(tab.sessionId, text)
            else if (text) term?.paste?.(text) || term?.write?.(text)
          } catch (_) {
            toast('无法读取剪贴板', true)
          }
        } else if (act === 'paste-sel') {
          const s = term?.getSelection?.() || ''
          if (s && tab?.sessionId && hasApi) await api.write(tab.sessionId, s)
        } else if (act === 'find') {
          const q = await askPrompt('在终端缓冲中查找', '', { title: '查找' })
          if (q == null || q === '') return
          const query = typeof q === 'object' ? q.value : q
          const sid = tab?.sessionId
          const buf = (sid && termBuffers.get(sid)) || ''
          const idx = buf.toLowerCase().lastIndexOf(String(query).toLowerCase())
          if (idx < 0) toast('未找到: ' + query, true)
          else {
            toast('已找到（缓冲位置 ' + idx + '）')
            // soft highlight by writing notice
            term?.writeln?.('\\r\\n\\x1b[33m[find] ' + query + '\\x1b[0m')
          }
        } else if (act === 'clear-buf') {
          const sid = tab?.sessionId
          if (sid) termBuffers.set(sid, '')
          term?.clear?.()
          term?.write?.('\\x1b[2J\\x1b[H')
          toast('终端缓存已清空')
        } else if (act === 'bg') {
          await openTermBgPicker()
        }
      })
    })
    // 左键点空白 / Esc / 失焦 → 收起（之前缺这个所以关不掉）
    requestAnimationFrame(() => bindCtxDismiss())
  }

    /**
   * 页内模态拖动（仅主窗内浮层兜底用）。
   * 默认弹层请走 openIndependentFloat → 独立 BrowserWindow，不要再「拖出去升级」。
   */
  function enableModalDrag(modalEl, opts = {}) {
    if (!modalEl) return
    if (opts.kind) modalEl.dataset.floatKind = opts.kind
    if (opts.title) modalEl.dataset.floatTitle = opts.title
    if (opts.floatId) modalEl.dataset.floatId = opts.floatId
    if (typeof opts.buildInit === 'function') modalEl._buildFloatInit = opts.buildInit
    modalEl.classList.add('draggable')

    const title = modalEl.querySelector('.modal-title, .editor-titlebar, .hb-popup-titlebar')
    if (!title) return
    if (modalEl.dataset.dragBound) return
    modalEl.dataset.dragBound = '1'
    title.title = '拖动窗口'
    title.style.cursor = 'move'
    title.style.userSelect = 'none'
    title.style.webkitAppRegion = 'no-drag'

    let ox = 0
    let oy = 0
    let dragging = false

    title.addEventListener('mousedown', (e) => {
      if (e.button !== 0) return
      if (e.target.closest('button, input, select, textarea, a, label, [data-pop-out-btn]')) return
      dragging = true
      modalEl.classList.add('dragging')
      const rect = modalEl.getBoundingClientRect()
      modalEl.style.position = 'fixed'
      modalEl.style.margin = '0'
      modalEl.style.left = rect.left + 'px'
      modalEl.style.top = rect.top + 'px'
      modalEl.style.transform = 'none'
      modalEl.style.zIndex = String(700 + (Date.now() % 1000))
      modalEl.style.maxWidth = 'none'
      modalEl.style.maxHeight = 'none'
      ox = e.clientX - rect.left
      oy = e.clientY - rect.top
      e.preventDefault()
    })
    const onMove = (e) => {
      if (!dragging) return
      modalEl.style.left = e.clientX - ox + 'px'
      modalEl.style.top = e.clientY - oy + 'px'
    }
    const onUp = () => {
      if (!dragging) return
      dragging = false
      modalEl.classList.remove('dragging')
    }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
  }

  /**
   * 打开独立桌面窗（默认路径）。可拖到任意屏幕，不挡主界面 SSH。
   * @returns {Promise<{ok:boolean,id?:string,error?:string}>}
   */

  function getUiThemeMode() {
    if (document.body.classList.contains('theme-light')) return 'light'
    if (document.body.classList.contains('theme-dark')) return 'dark'
    return state.settings?.theme === 'light' ? 'light' : 'dark'
  }

  /** 弹出窗/内联浮层调色板，与主窗 theme-light|dark 一致 */
  function getChromePalette(mode) {
    const light = (mode || getUiThemeMode()) === 'light'
    if (light) {
      // 与主窗 body.theme-light 令牌一致（中性灰）
      return {
        mode: 'light',
        bg: '#d6d6de',
        bg2: '#d6d6de',
        bg3: '#c8c8d2',
        fg: '#0b0b0d',
        muted: 'rgba(40, 40, 45, 0.78)',
        accent: '#007aff',
        border: 'rgba(0,0,0,0.14)',
        control: 'rgba(60,60,70,0.14)',
        inputBg: '#cfcfd8',
        headBg: '#c8c8d2',
        rowBg: '#d6d6de',
        windowBg: '#d6d6de',
      }
    }
    // 与主窗 :root/theme-dark 令牌一致（中性灰），杜绝浮窗偏紫、和主界面不统一
    return {
      mode: 'dark',
      bg: '#1c1c1e',
      bg2: '#2c2c2e',
      bg3: '#3a3a3c',
      fg: '#f7f7fa',
      muted: 'rgba(235, 235, 245, 0.78)',
      accent: '#0a84ff',
      border: 'rgba(255, 255, 255, 0.16)',
      control: 'rgba(120, 120, 128, 0.32)',
      inputBg: '#161618',
      headBg: '#2c2c2e',
      rowBg: '#1c1c1e',
      windowBg: '#1c1c1e',
    }
  }

  async function openIndependentFloat(opts) {
    opts = opts || {}
    if (document.body.classList.contains('float-window')) {
      return { ok: false, error: 'already-float' }
    }
    if (!hasApi || typeof api.openFloatWindow !== 'function') {
      toast('当前环境不支持独立窗口', true)
      return { ok: false, error: 'no-api' }
    }
    const kind = opts.kind || 'conn-mgr'
    const id = opts.id || opts.floatId || kind
    let init = opts.init
    if (init == null && typeof opts.buildInit === 'function') {
      try {
        init = opts.buildInit()
      } catch (e) {
        rlog('warn', 'float-init', e.message || e)
      }
    }
    const width = Math.max(360, Number(opts.width) || 560)
    const height = Math.max(280, Number(opts.height) || 480)
    // 优先主窗中上方；光标仅作微调，避免贴屏底只露一条边
    let x
    let y
    try {
      if (typeof api.getMainBounds === 'function') {
        const b = await api.getMainBounds()
        if (b && b.ok && b.bounds) {
          const bb = b.bounds
          x = Math.round(bb.x + Math.max(20, (bb.width - width) / 2))
          y = Math.round(bb.y + Math.max(40, (bb.height - height) / 4))
        }
      }
    } catch (_) {}
    try {
      if ((x == null || y == null) && typeof api.getCursorScreenPoint === 'function') {
        const p = await api.getCursorScreenPoint()
        if (p && p.ok && p.x != null) {
          x = Math.round(p.x - width / 2)
          y = Math.round(p.y - Math.min(80, height / 4))
        }
      }
    } catch (_) {}
    const themeMode = getUiThemeMode()
    const pal = getChromePalette(themeMode)
    const initPayload =
      init != null && typeof init === 'object' && !Array.isArray(init)
        ? { ...init, theme: themeMode }
        : { theme: themeMode, ...(init != null ? { data: init } : {}) }
    const payload = {
      id,
      kind,
      title: String(opts.title || 'PixShell').slice(0, 120),
      width,
      height,
      x,
      y,
      theme: themeMode,
      backgroundColor: pal.windowBg || (themeMode === 'light' ? '#ececf1' : '#1e1e2e'),
      init: initPayload,
    }
    try {
      rlog('info', 'float', 'openIndependentFloat', {
        id: payload.id,
        kind: payload.kind,
        w: payload.width,
        h: payload.height,
        theme: themeMode,
        initHosts: payload.init && Array.isArray(payload.init.hosts) ? payload.init.hosts.length : null,
      })
      const r = await api.openFloatWindow(payload)
      rlog(r && r.ok ? 'info' : 'error', 'float', 'openIndependentFloat result', r || {})
      if (!r || !r.ok) {
        toast('打开独立窗口失败: ' + ((r && r.error) || 'unknown'), true)
      }
      return r || { ok: false, error: 'no-result' }
    } catch (e) {
      rlog('error', 'float', 'openIndependentFloat throw', { err: e.message || e })
      toast('打开独立窗口失败: ' + (e.message || e), true)
      return { ok: false, error: String(e.message || e) }
    }
  }

  /** 独立浮窗模式：仅渲染 floatRoot，不跑主界面 */
  function getFloatQuery() {
    try {
      const q = new URLSearchParams(location.search || '')
      if (q.get('float') === '1') {
        return { id: q.get('id') || 'float', kind: q.get('kind') || 'conn-mgr' }
      }
    } catch (_) {}
    return null
  }

  async function bootFloatWindow(meta) {
    document.body.classList.add('float-window')
    try {
      let th = state.settings?.theme || 'dark'
      try {
        const ir = await api.getFloatInit?.(meta?.id)
        if (ir?.ok && ir.init?.theme) th = ir.init.theme
      } catch (_) {}
      applyBodyChromeClasses(th)
      const pal0 = getChromePalette(th)
      if (hasApi && typeof api.setWindowBackground === 'function') {
        try {
          await api.setWindowBackground(pal0.windowBg)
        } catch (_) {}
      }
    } catch (_) {
      document.body.classList.add('theme-dark')
    }
    const root = $('floatRoot')
    if (!root) {
      document.body.innerHTML =
        '<div style="padding:24px;color:#eee;font:14px system-ui">floatRoot 缺失</div>'
      try {
        await api.floatReady?.({ id: meta?.id || '', err: 'no-floatRoot' })
      } catch (_) {}
      return
    }
    root.hidden = false
    root.removeAttribute('hidden')
    // 强制铺满：所有浮窗共用，杜绝 height:0 / display:none 黑屏
    root.style.cssText =
      'display:flex!important;flex-direction:column;position:fixed;inset:0;' +
      'width:100%;height:100%;min-height:100vh;min-width:100vw;margin:0;padding:0;' +
      'overflow:hidden;z-index:10;visibility:visible;opacity:1;box-sizing:border-box;'
    document.documentElement.style.cssText =
      (document.documentElement.getAttribute('style') || '') +
      ';width:100%;height:100%;overflow:hidden;margin:0;'
    document.body.style.cssText =
      (document.body.getAttribute('style') || '') +
      ';width:100%;height:100%;overflow:hidden;margin:0;visibility:visible;opacity:1;'
    root.innerHTML = ''
    document.querySelectorAll('.app > :not(.float-root)').forEach((el) => {
      el.style.display = 'none'
    })
    const appEl = document.querySelector('.app')
    if (appEl) {
      appEl.style.cssText =
        'display:block!important;width:100%;height:100%;min-height:100vh;margin:0;padding:0;overflow:hidden;'
    }

    const floatDiag = { paintOk: false, hosts: 0, err: null, kind: meta?.kind || '' }
    const signalReady = async () => {
      try {
        rlog('info', 'float', 'ready-signal', {
          id: meta?.id,
          kind: floatDiag.kind,
          paintOk: floatDiag.paintOk,
          hosts: floatDiag.hosts,
          err: floatDiag.err,
        })
        if (hasApi && typeof api.floatReady === 'function') {
          let bg = ''
          try {
            bg = getChromePalette(getUiThemeMode()).windowBg || ''
          } catch (_) {}
          await api.floatReady({
            id: meta?.id || '',
            kind: floatDiag.kind,
            paintOk: floatDiag.paintOk,
            hosts: floatDiag.hosts,
            err: floatDiag.err,
            backgroundColor: bg,
          })
        }
      } catch (e) {
        console.error('floatReady', e)
        rlog('error', 'float', 'ready-signal-fail', { err: e && e.message })
      }
    }

    const kind = meta.kind || 'conn-mgr'
    try {
    if (kind === 'conn-mgr' || kind === 'hosts') {
      // 独立窗列表：全内联样式，不依赖 .host-browser 等可能把高度压成 0 的规则
      // 日志已证 paint 有 49 行仍黑屏 → 纯 CSS 可见性/高度问题
      // 跟随主窗浅色/深色，禁止写死暗色（UI 一致性）
      let themeMode = getUiThemeMode()
      try {
        const ir0 = await api.getFloatInit?.(meta.id)
        if (ir0?.ok && ir0.init?.theme) themeMode = ir0.init.theme
      } catch (_) {}
      const pal = getChromePalette(themeMode)
      try {
        applyBodyChromeClasses(themeMode)
      } catch (_) {}
      try {
        if (hasApi && typeof api.setWindowBackground === 'function') {
          await api.setWindowBackground(pal.windowBg)
        }
      } catch (_) {}
      const BG = pal.bg
      const BG2 = pal.bg2
      const FG = pal.fg
      const MUTED = pal.muted
      const ACC = pal.accent
      const BORDER = pal.border
      const CONTROL = pal.control
      const INPUT_BG = pal.inputBg
      const HEAD_BG = pal.headBg
      const ROW_BG = pal.rowBg

      root.innerHTML = ''
      root.style.cssText =
        'display:flex;flex-direction:column;position:fixed;inset:0;width:100%;height:100%;' +
        'margin:0;padding:0;background:' + BG + ';color:' + FG + ';overflow:hidden;z-index:1;'

      const shell = document.createElement('div')
      shell.id = 'floatConnShell'
      shell.style.cssText =
        'display:flex;flex-direction:column;width:100%;height:100%;min-height:100%;' +
        'background:' + BG + ';color:' + FG + ';overflow:hidden;'

      const bar = document.createElement('div')
      bar.style.cssText =
        'display:flex;align-items:center;gap:6px;flex:0 0 32px;height:32px;' +
        'padding:0 12px 0 78px;background:' + BG2 + ';border-bottom:1px solid ' + BORDER + ';' +
        'font:650 13px/1 system-ui,-apple-system,sans-serif;-webkit-app-region:drag;user-select:none;'
      const title = document.createElement('span')
      title.textContent = '连接管理器'
      title.style.cssText = 'color:' + FG + ';flex:0 0 auto;'
      const actions = document.createElement('div')
      actions.style.cssText =
        'margin-left:auto;display:flex;gap:6px;-webkit-app-region:no-drag;'
      const mkBtn = (id, label) => {
        const b = document.createElement('button')
        b.type = 'button'
        b.id = id
        b.textContent = label
        b.style.cssText =
          'height:22px;padding:0 8px;border:1px solid ' + BORDER + ';border-radius:5px;' +
          'background:' + CONTROL + ';color:' + FG + ';font:12px system-ui;cursor:pointer;'
        return b
      }
      const btnNew = mkBtn('floatBtnNew', '＋连接')
      const btnRefresh = mkBtn('floatBtnRefresh', '刷新')
      const btnClose = mkBtn('floatBtnClose', '关闭')
      actions.appendChild(btnNew)
      actions.appendChild(btnRefresh)
      actions.appendChild(btnClose)
      bar.appendChild(title)
      bar.appendChild(actions)

      const toolbar = document.createElement('div')
      toolbar.style.cssText =
        'display:flex;align-items:center;gap:8px;flex:0 0 auto;padding:8px 12px;' +
        'background:' + BG2 + ';border-bottom:1px solid ' + BORDER + ';font:12px system-ui;'
      const countEl = document.createElement('span')
      countEl.id = 'floatHostCount'
      countEl.style.cssText = 'color:' + MUTED + ';'
      const filter = document.createElement('input')
      filter.type = 'search'
      filter.placeholder = '搜索主机…'
      filter.id = 'floatHostFilter'
      filter.style.cssText =
        'flex:1;min-width:100px;height:22px;padding:0 6px;border:1px solid ' + BORDER + ';' +
        'border-radius:6px;background:' + INPUT_BG + ';color:' + FG + ';font:12px system-ui;'
      toolbar.appendChild(countEl)
      toolbar.appendChild(filter)

      const list = document.createElement('div')
      list.id = 'floatHostBrowser'
      // 居中列布局：分组卡片不再铺满整窗宽度（宽屏下按钮会被推到极右、中间空一大截），
      // 收进一个居中的最大宽度列，读起来才像列表而不是「占满整个 UI」。
      list.style.cssText =
        'display:flex;flex-direction:column;align-items:center;flex:1 1 auto;min-height:0;' +
        'overflow-y:auto;overflow-x:hidden;padding:8px 12px;' +
        'background:' + BG + ';color:' + FG + ';-webkit-overflow-scrolling:touch;'

      shell.appendChild(bar)
      shell.appendChild(toolbar)
      shell.appendChild(list)
      root.appendChild(shell)

      rlog('info', 'float', 'conn-mgr boot-inline', {
        rootH: root.offsetHeight,
        listH: list.offsetHeight,
        hostsBefore: Array.isArray(state.hosts) ? state.hosts.length : -1,
      })

      try {
        const ir = await api.getFloatInit?.(meta.id)
        const init = ir && ir.ok ? ir.init : null
        rlog('info', 'float', 'getFloatInit', {
          ok: !!(ir && ir.ok),
          initHosts: init && Array.isArray(init.hosts) ? init.hosts.length : 0,
        })
        if (init && Array.isArray(init.hosts) && init.hosts.length) {
          const byId = new Map((Array.isArray(state.hosts) ? state.hosts : []).map((h) => [h.id, h]))
          for (const h of init.hosts) {
            if (!h || !h.id) continue
            byId.set(h.id, { ...(byId.get(h.id) || {}), ...h })
          }
          state.hosts = [...byId.values()]
        }
      } catch (e) {
        rlog('warn', 'float', 'getFloatInit fail', { err: e && e.message })
      }
      if (!Array.isArray(state.hosts) || !state.hosts.length) {
        try {
          if (hasApi && api.loadHosts) {
            const loaded = await api.loadHosts()
            state.hosts = Array.isArray(loaded) ? loaded : []
            rlog('info', 'float', 'loadHosts', { n: state.hosts.length })
          }
        } catch (e) {
          rlog('error', 'float', 'loadHosts fail', { err: e && e.message })
          state.hosts = []
        }
      }
      floatDiag.hosts = Array.isArray(state.hosts) ? state.hosts.length : 0

      const paintInline = () => {
        const q = (filter.value || '').trim().toLowerCase()
        let hosts = (state.hosts || []).filter((h) => h && !h.deleted)
        if (q) {
          hosts = hosts.filter(
            (h) =>
              String(h.name || '').toLowerCase().includes(q) ||
              String(h.host || '').toLowerCase().includes(q) ||
              String(h.group || '').toLowerCase().includes(q) ||
              String(h.username || '').toLowerCase().includes(q),
          )
        }
        const groups = new Map()
        for (const h of hosts) {
          const g = String((h.group || '默认') + '').trim() || '默认'
          if (!groups.has(g)) groups.set(g, [])
          groups.get(g).push(h)
        }
        const groupNames = [...groups.keys()].sort((a, b) => {
          if (a === '默认') return 1
          if (b === '默认') return -1
          return a.localeCompare(b, 'zh')
        })
        countEl.textContent = hosts.length + ' 台 · ' + groupNames.length + ' 组'
        list.innerHTML = ''
        if (!hosts.length) {
          const empty = document.createElement('div')
          empty.style.cssText =
            'margin:24px;padding:24px;text-align:center;color:' + MUTED + ';' +
            'border:1px dashed ' + BORDER + ';border-radius:8px;background:' + BG2 + ';'
          empty.textContent = '暂无主机。点「＋连接」添加。'
          list.appendChild(empty)
        } else {
          for (const g of groupNames) {
            const items = groups.get(g) || []
            const sec = document.createElement('div')
            sec.style.cssText =
              'width:100%;max-width:760px;margin:0 0 10px;border:1px solid ' + BORDER + ';border-radius:8px;overflow:hidden;background:' + BG2 + ';'
            const head = document.createElement('div')
            head.style.cssText =
              'padding:6px 8px 6px 10px;font:650 12px system-ui;color:' + FG + ';background:' + HEAD_BG + ';cursor:pointer;display:flex;align-items:center;gap:6px;user-select:none;'
            // 折叠状态跨重绘保留（搜索/主机更新会重建列表，之前每次都被重置成展开）
            if (!(state._connMgrCollapsed instanceof Set)) state._connMgrCollapsed = new Set()
            const collapsed = state._connMgrCollapsed.has(g)
            const arrow = document.createElement('span')
            arrow.textContent = '▶'
            arrow.style.cssText =
              'display:inline-block;flex:0 0 auto;transition:transform var(--dur-2,170ms) var(--ease-out,ease);transform:rotate(' +
              (collapsed ? 0 : 90) + 'deg);'
            const gLabel = document.createElement('span')
            gLabel.style.cssText = 'flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;'
            gLabel.textContent = g + ' (' + items.length + ')'
            head.appendChild(arrow)
            head.appendChild(gLabel)
            // 「默认」是未分组桶，不给重命名/删除（改它=改所有无分组主机，易误伤）
            if (g !== '默认') {
              const mkGBtn = (label, danger) => {
                const b = document.createElement('button')
                b.type = 'button'
                b.textContent = label
                b.style.cssText =
                  'height:20px;padding:0 7px;border:0;border-radius:5px;cursor:pointer;flex:0 0 auto;' +
                  'font:11px system-ui;' +
                  (danger ? 'background:rgba(255,69,58,0.16);color:#ff6a5f;' : 'background:' + CONTROL + ';color:' + FG + ';')
                return b
              }
              const bGRename = mkGBtn('重命名', false)
              const bGDel = mkGBtn('删除', true)
              bGRename.addEventListener('click', async (e) => {
                e.stopPropagation()
                try { await api.floatToMain({ type: 'rename-group', group: g }) } catch (_) {}
              })
              bGDel.addEventListener('click', async (e) => {
                e.stopPropagation()
                try { await api.floatToMain({ type: 'delete-group', group: g }) } catch (_) {}
              })
              head.appendChild(bGRename)
              head.appendChild(bGDel)
            }
            sec.appendChild(head)

            const bodyDiv = document.createElement('div')
            bodyDiv.style.cssText = 'display:' + (collapsed ? 'none' : 'block') + ';'
            sec.appendChild(bodyDiv)

            head.addEventListener('click', (e) => {
              if (e.target.closest('button')) return
              const isHidden = bodyDiv.style.display === 'none'
              bodyDiv.style.display = isHidden ? 'block' : 'none'
              arrow.style.transform = isHidden ? 'rotate(90deg)' : 'rotate(0deg)'
              if (isHidden) state._connMgrCollapsed.delete(g)
              else state._connMgrCollapsed.add(g)
            })
            for (const h of items) {
              const row = document.createElement('div')
              row.dataset.id = h.id
              row.style.cssText =
                'display:flex;align-items:center;gap:10px;padding:8px 10px;' +
                'border-top:1px solid ' + BORDER + ';background:' + BG + ';cursor:pointer;'
              const letter = document.createElement('div')
              letter.style.cssText =
                'width:22px;height:22px;border-radius:6px;overflow:hidden;background:' + BG2 + ';' +
                'display:flex;align-items:center;justify-content:center;flex:0 0 auto;'
              const av = document.createElement('img')
              av.src = hostAvatarSrc(h)
              av.alt = ''
              av.draggable = false
              av.style.cssText = 'width:100%;height:100%;object-fit:contain;'
              letter.appendChild(av)
              const main = document.createElement('div')
              main.style.cssText = 'flex:1;min-width:0;'
              const t1 = document.createElement('div')
              t1.style.cssText =
                'font:650 13px system-ui;color:' + FG + ';white-space:nowrap;overflow:hidden;text-overflow:ellipsis;'
              t1.textContent = h.name || h.host || '未命名'
              const t2 = document.createElement('div')
              t2.style.cssText =
                'font:11px ui-monospace,Menlo,monospace;color:' + MUTED + ';' +
                'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;'
              t2.textContent =
                (h.username || 'root') + '@' + (h.host || '-') + ':' + (h.port || 22)
              main.appendChild(t1)
              main.appendChild(t2)
              const acts = document.createElement('div')
              acts.style.cssText = 'display:flex;gap:6px;flex:0 0 auto;'
              const mkSmall = (label, primary) => {
                const b = document.createElement('button')
                b.type = 'button'
                b.textContent = label
                b.style.cssText =
                  'height:22px;padding:0 8px;border:0;border-radius:5px;cursor:pointer;font:11px system-ui;' +
                  (primary
                    ? 'background:' + ACC + ';color:#fff;font-weight:650;'
                    : 'background:' + CONTROL + ';color:' + FG + ';')
                return b
              }
              const bConn = mkSmall('连接', true)
              const bEdit = mkSmall('编辑', false)
              const bDel = mkSmall('删除', false)
              bConn.addEventListener('click', async (e) => {
                e.stopPropagation()
                try {
                  await api.floatToMain({ type: 'connect', hostId: h.id })
                  toast('已请求主窗口连接')
                } catch (err) {
                  toast(String(err.message || err), true)
                }
              })
              bEdit.addEventListener('click', async (e) => {
                e.stopPropagation()
                try {
                  await api.floatToMain({ type: 'edit-host', hostId: h.id })
                } catch (_) {}
              })
              bDel.addEventListener('click', async (e) => {
                e.stopPropagation()
                try {
                  await api.floatToMain({ type: 'delete-host', hostId: h.id })
                } catch (_) {}
              })
              row.addEventListener('dblclick', async (e) => {
                if (e.target.closest('button')) return
                e.preventDefault()
                try {
                  await api.floatToMain({ type: 'connect', hostId: h.id })
                } catch (_) {}
              })
              acts.appendChild(bConn)
              acts.appendChild(bEdit)
              acts.appendChild(bDel)
              row.appendChild(letter)
              row.appendChild(main)
              row.appendChild(acts)
              bodyDiv.appendChild(row)
            }
            list.appendChild(sec)
          }
        }
        floatDiag.paintOk = list.childNodes.length > 0
        floatDiag.hosts = hosts.length
        rlog('info', 'float', 'paint-inline', {
          rows: hosts.length,
          groups: groupNames.length,
          listH: list.offsetHeight,
          listChildren: list.childNodes.length,
          rootH: root.offsetHeight,
          shellH: shell.offsetHeight,
        })
      }

      filter.addEventListener('input', paintInline)
      btnNew.addEventListener('click', async () => {
        try {
          await api.floatToMain({ type: 'new-host' })
        } catch (_) {}
      })
      btnRefresh.addEventListener('click', async () => {
        try {
          if (hasApi && api.loadHosts) {
            state.hosts = (await api.loadHosts()) || state.hosts
            for (const h of state.hosts) {
              if (h.password) passwordVault.set(h.id, h.password)
            }
          }
          paintInline()
        } catch (e) {
          toast(String(e.message || e), true)
        }
      })
      btnClose.addEventListener('click', () => {
        api.closeFloatWindow?.(meta.id)
      })
      try {
        api.onFloatMessage?.((msg) => {
          if (!msg) return
          if (msg.type === 'hosts-updated' && Array.isArray(msg.hosts)) {
            state.hosts = msg.hosts
            paintInline()
          }
          if (msg.type === 'float-init' && msg.init) {
            const init = msg.init
            if (Array.isArray(init.hosts)) {
              state.hosts = init.hosts
              paintInline()
              rlog('info', 'float', 're-init paint', { n: state.hosts.length })
            }
          }
        })
      } catch (_) {}

      paintInline()
      // 用标准 flex 滚动：list 为 flex:1 + min-height:0 + overflow:auto，
      // 内容超高时自身出滚动条。之前把 minHeight 顶到近满窗，会让 list 被外层裁掉、
      // 反而不出滚动条（分组多了滚不动）。这里只兜底防 0 高。
      requestAnimationFrame(() => {
        list.style.minHeight = '0'
        if (list.offsetHeight < 40) list.style.minHeight = '120px'
        rlog('info', 'float', 'layout-raf', { innerH: window.innerHeight, listH: list.offsetHeight })
      })

    } else if (kind === 'host-editor' || kind === 'host') {
      let init = null
      try {
        const r = await api.getFloatInit?.(meta.id)
        if (r && r.ok) init = r.init
      } catch (_) {}
      const hostId = init && init.hostId
      if (mountModalInFloat(root, 'hostModal', 'btnHostClose')) {
        openHostModal(hostId || null)
        // 保存成功后关闭本浮窗；saveHost 内部已负责 floatToMain 通知主窗刷新列表
        window._floatSaveHook = () => api.closeFloatWindow?.(meta.id)
      }
    } else if (kind === 'editor') {
      await bootFloatEditor(root, meta)
    } else if (kind === 'settings') {
      await bootFloatSettings(root, meta)
    } else if (kind === 'backup') {
      let init = null
      try {
        const r = await api.getFloatInit?.(meta.id)
        if (r && r.ok) init = r.init
      } catch (_) {}
      
      if (mountModalInFloat(root, 'backupModal', 'btnBackupClose')) {
        openBackupConfig(init?.selectId || null)
      }
    } else {
      root.innerHTML = `
        <div class="hb-popup-shell">
          <div class="hb-popup-titlebar">
            <span>PixShell</span>
            <div class="hb-pop-actions">
              <button type="button" class="mini-btn" id="floatBtnClose">关闭</button>
            </div>
          </div>
          <div style="padding:16px;color:var(--muted)">未知浮窗类型: ${esc(kind)}</div>
        </div>`
      $('floatBtnClose')?.addEventListener('click', () => api.closeFloatWindow?.(meta.id))
    }
    } catch (e) {
      console.error('bootFloatWindow', e)
      floatDiag.err = String(e && e.message ? e.message : e)
      root.innerHTML =
        '<div class="hb-popup-shell" style="display:flex;flex-direction:column;height:100%;background:#1e1e2e;color:#eee">' +
        '<div class="hb-popup-titlebar" style="flex:0 0 36px;padding:0 12px 0 72px;display:flex;align-items:center;background:#313244">' +
        '<span>启动失败</span></div>' +
        '<div style="padding:20px;color:#f38ba8;font:13px system-ui;white-space:pre-wrap">' +
        esc(String(e && e.message ? e.message : e)) +
        '</div></div>'
    }
    // 任何有 DOM 的浮窗都算 paint 成功（编辑器此前从未置 paintOk → 日志 paintOk:false）
    try {
      const kids = root && root.childNodes ? root.childNodes.length : 0
      const h = root ? root.offsetHeight : 0
      if (kids > 0) floatDiag.paintOk = true
      floatDiag.hosts = floatDiag.hosts || kids
      rlog('info', 'float', 'boot-done', {
        kind: floatDiag.kind,
        kids,
        rootH: h,
        paintOk: floatDiag.paintOk,
        err: floatDiag.err,
      })
    } catch (_) {}
    // 有内容再通知主进程 show，避免黑屏空壳
    await signalReady()
    // 再 paint 一帧后强制 focus，防 GPU 合成层空白
    try {
      requestAnimationFrame(() => {
        try {
          root.style.visibility = 'visible'
          root.style.opacity = '1'
          if (root.offsetHeight < 40) {
            root.style.minHeight = '100vh'
            root.style.height = '100%'
          }
        } catch (_) {}
      })
    } catch (_) {}
  }


  async function bootFloatSettings(root, meta) {
    let init = null
    try {
      const r = await api.getFloatInit?.(meta.id)
      if (r && r.ok) init = r.init
    } catch (_) {}
    const themeMode = (init && init.theme) || getUiThemeMode()
    try {
      applyBodyChromeClasses(themeMode)
    } catch (_) {}
    const pal = getChromePalette(themeMode)
    try {
      if (hasApi && api.setWindowBackground) await api.setWindowBackground(pal.windowBg)
    } catch (_) {}
    if (init && init.settings && typeof init.settings === 'object') {
      state.settings = { ...(state.settings || {}), ...init.settings }
    }
    root.style.cssText =
      'display:flex!important;flex-direction:column;position:fixed;inset:0;width:100%;height:100%;' +
      'margin:0;background:' + pal.bg + ';color:' + pal.fg + ';z-index:10;overflow:hidden;'
    // 把主文档里的设置表单克隆进浮窗（同源 DOM id 冲突：先藏主窗 mask）
    try {
      showModal('settingsModal', false)
    } catch (_) {}
    const src = document.querySelector('#settingsModal .settings-modal') || document.querySelector('#settingsModal .modal')
    root.innerHTML =
      '<div class="hb-popup-shell float-settings-shell" style="display:flex;flex-direction:column;height:100%;background:' +
      pal.bg +
      ';color:' +
      pal.fg +
      '">' +
      '<div class="hb-popup-titlebar" style="flex:0 0 36px;display:flex;align-items:center;gap:8px;padding:0 10px 0 72px;background:' +
      pal.bg2 +
      ';border-bottom:1px solid ' +
      pal.border +
      ';-webkit-app-region:drag">' +
      '<span style="font-weight:650">设置</span>' +
      '<div style="margin-left:auto;display:flex;gap:6px;-webkit-app-region:no-drag">' +
      '<button type="button" class="cmd-btn primary" id="floatSetSave">保存</button>' +
      '<button type="button" class="mini-btn" id="floatBtnClose">关闭</button>' +
      '</div></div>' +
      '<div id="floatSettingsBody" style="flex:1;min-height:0;overflow:auto;padding:10px 12px"></div></div>'
    const body = $('floatSettingsBody')
    if (src && body) {
      const clone = src.cloneNode(true)
      // 去掉克隆体的模态框卡片外观，并铺满可用高度：min-height:100% 让内容不足时
      // 也撑到窗口底部（不再是顶部一小块+下方一大截暗色空白）。
      Object.assign(clone.style, {
        width: '100%', maxWidth: 'none', minWidth: '0', height: 'auto', minHeight: '100%',
        margin: '0', border: 'none', borderRadius: '0', boxShadow: 'none',
        background: 'transparent', animation: 'none',
        display: 'flex', flexDirection: 'column',
      })
      clone.classList.remove('draggable')
      // 去掉标题栏重复（浮窗 titlebar 已有 保存/关闭）
      const mt = clone.querySelector('.modal-title')
      if (mt) mt.remove()
      // 去掉底部重复按钮；顶栏 floatSetSave / floatBtnClose 即唯一操作
      clone.querySelectorAll('.modal-actions').forEach((el) => el.remove())
      clone.querySelectorAll('.settings-title-actions').forEach((el) => el.remove())
      // 让内部表单区吃满剩余高度，内容随窗口拉到底
      const sbody = clone.querySelector('.settings-body')
      if (sbody) Object.assign(sbody.style, { flex: '1 1 auto', minHeight: '0', maxHeight: 'none', overflow: 'visible' })
      body.appendChild(clone)
      // re-id collision: settings controls stay with same ids — only one window active
    } else if (body) {
      body.innerHTML = '<p style="opacity:.8">设置表单未找到，请从主窗口打开。</p>'
    }
    // 填充并绑定
    try {
      await fillSchemeSelect(state.settings?.colorScheme || 'dracula')
      bindSettingsLivePreview()
      await refreshSettingsPreview()
      // sync fields
      const s = state.settings || {}
      if ($('setThemeMode')) $('setThemeMode').value = s.theme === 'light' ? 'light' : 'dark'
      if ($('setFontSize')) $('setFontSize').value = s.fontSize || 13
      if ($('setScheme') && s.colorScheme) {
        try {
          $('setScheme').value = s.colorScheme
        } catch (_) {}
      }
    } catch (e) {
      console.error('bootFloatSettings fill', e)
    }
    $('floatSetSave')?.addEventListener('click', async () => {
      try {
        await saveSettings()
        toast('设置已保存')
      } catch (e) {
        toast('保存失败: ' + (e.message || e), true)
      }
    })
    // wire existing save buttons inside clone
    $('btnSetSave')?.addEventListener('click', async () => {
      await saveSettings()
    })
    $('btnSetCancel')?.addEventListener('click', () => api.closeFloatWindow?.(meta.id))
    $('btnSetClose')?.addEventListener('click', () => api.closeFloatWindow?.(meta.id))
    $('floatBtnClose')?.addEventListener('click', () => api.closeFloatWindow?.(meta.id))
  }

  async function bootFloatEditor(root, meta) {
    // 取主进程缓存的首屏数据
    let init = null
    try {
      const r = await api.getFloatInit?.(meta.id)
      if (r && r.ok) init = r.init
    } catch (_) {}
    if (!init) {
      init = await new Promise((resolve) => {
        let done = false
        const finish = (v) => {
          if (done) return
          done = true
          resolve(v)
        }
        const t = setTimeout(() => finish(null), 600)
        try {
          api.onFloatMessage?.((msg) => {
            if (msg && msg.type === 'float-init' && msg.init) {
              clearTimeout(t)
              finish(msg.init)
            }
          })
        } catch (_) {
          clearTimeout(t)
          finish(null)
        }
      })
    }
    init = init || {}
    const path = init.path || '未命名'
    const sessionId = init.sessionId || null
    const text0 = init.text != null ? String(init.text) : ''
    const lang0 = init.lang || 'plaintext'
    const syntaxHl = init.syntaxHl !== false
    const fontSize = Number(init.fontSize) || 13
    const fontFamily = withMonoI18n(init.fontFamily || DEFAULT_TERM_FONT_FAMILY)
    const themeMode = init.theme || getUiThemeMode()
    try {
      applyBodyChromeClasses(themeMode)
    } catch (_) {}
    const pal = getChromePalette(themeMode)
    const isLight = themeMode === 'light'
    try {
      if (hasApi && typeof api.setWindowBackground === 'function') {
        await api.setWindowBackground(
          pal.windowBg || (isLight ? '#ececf1' : '#1e1e1e'),
        )
      }
    } catch (_) {}

    // 全内联布局；浅色必须深色字，禁止写死 #d4d4d4 导致白字看不见
    const BG = isLight ? '#e8e8ee' : '#1e1e1e'
    const BG2 = isLight ? '#dcdce4' : '#252526'
    const BG3 = isLight ? '#d0d0d8' : '#2d2d2d'
    const FG = isLight ? '#1d1d1f' : '#d4d4d4'
    const MUTED = isLight ? 'rgba(60,60,67,0.75)' : '#9cdcfe'
    const BORDER = isLight ? 'rgba(0,0,0,0.14)' : '#444'
    const TITLE_FG = isLight ? '#1d1d1f' : '#eee'
    const BAR_FG = isLight ? 'rgba(60,60,67,0.85)' : '#bbb'
    const CARET = isLight ? '#111' : '#fff'

    root.style.cssText =
      'display:flex!important;flex-direction:column;position:fixed;inset:0;' +
      'width:100%;height:100%;min-height:100vh;margin:0;padding:0;overflow:hidden;' +
      'background:' + BG + ';color:' + FG + ';z-index:10;visibility:visible;opacity:1;'

    root.innerHTML =
      '<div id="floatEditorShell" class="hb-popup-shell float-editor-shell" style="' +
      'display:flex;flex-direction:column;width:100%;height:100%;min-height:100%;' +
      'background:' + BG + ';color:' + FG + ';overflow:hidden;box-sizing:border-box;">' +
      '<div id="floatEdTitlebar" class="hb-popup-titlebar" style="' +
      'display:flex;align-items:center;gap:6px;flex:0 0 28px;height:28px;' +
      'padding:0 8px 0 72px;background:' + BG3 + ';border-bottom:1px solid ' + BORDER + ';' +
      'font:650 13px system-ui;-webkit-app-region:drag;user-select:none;color:' + TITLE_FG + ';">' +
      '<span id="floatEdTitle" style="max-width:55%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:' + TITLE_FG + ';">' +
      esc(path) +
      '</span>' +
      '<span id="floatEdMeta" style="color:' + MUTED + ';font-size:11px;margin-left:8px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"></span>' +
      '<div style="margin-left:auto;display:flex;gap:4px;-webkit-app-region:no-drag;">' +
      '<button type="button" class="mini-btn" id="floatEdSave" style="height:24px;padding:0 10px;-webkit-app-region:no-drag;">保存</button>' +
      '<button type="button" class="mini-btn" id="floatEdReload" style="height:24px;padding:0 10px;-webkit-app-region:no-drag;">重新加载</button>' +
      '<button type="button" class="mini-btn" id="floatBtnClose" style="height:24px;padding:0 10px;-webkit-app-region:no-drag;">关闭</button>' +
      '</div></div>' +
      '<div style="display:flex;flex-wrap:wrap;align-items:center;gap:8px;flex:0 0 auto;' +
      'padding:2px 8px;background:' + BG2 + ';border-bottom:1px solid ' + BORDER + ';font:11px system-ui;color:' + BAR_FG + ';min-height:26px;">' +
      '<label style="display:inline-flex;align-items:center;gap:4px;">语言 ' +
      '<select id="floatEdLang" style="height:24px;background:' + BG2 + ';color:' + FG + ';border:1px solid ' + BORDER + ';border-radius:4px;min-width:88px;height:22px;"></select></label>' +
      '<label style="display:inline-flex;align-items:center;gap:4px;"><input type="checkbox" id="floatEdHl" ' +
      (syntaxHl ? 'checked' : '') +
      '/> 语法高亮</label>' +
      '<span style="flex:1"></span>' +
      '<span id="floatEdStatus" style="color:' + MUTED + ';font-size:11px;">就绪</span>' +
      '</div>' +
      '<div id="floatEdBodyWrap" style="display:flex;flex:1 1 auto;min-height:120px;height:100%;' +
      'background:' + BG + ';overflow:hidden;position:relative;">' +
      '<pre id="floatEdGutter" aria-hidden="true" style="flex:0 0 32px;width:32px;margin:0;padding:6px 3px 6px 0;' +
      'text-align:right;font:' + fontSize + 'px/1.45 ' + fontFamily.replace(/"/g, '') + ';' +
      'color:#858585;background:' + BG + ';border-right:1px solid #333;overflow:hidden;user-select:none;"></pre>' +
      '<div id="floatEdCodeWrap" style="flex:1 1 auto;min-width:0;min-height:0;height:100%;position:relative;overflow:hidden;">' +
      '<pre id="floatEdHighlight" aria-hidden="true" style="position:absolute;inset:0;margin:0;padding:8px;' +
      'font:' + fontSize + 'px/1.45 monospace;white-space:pre;overflow:auto;pointer-events:none;' +
      'color:' + FG + ';background:transparent;z-index:1;"></pre>' +
      '<textarea id="floatEdBody" spellcheck="false" wrap="off" style="position:absolute;inset:0;z-index:2;' +
      'width:100%;height:100%;margin:0;padding:8px;border:0;resize:none;outline:none;' +
      'font:' + fontSize + 'px/1.45 monospace;white-space:pre;overflow:auto;tab-size:2;' +
      'color:' + FG + ';-webkit-text-fill-color:' + FG + ';caret-color:#fff;background:transparent;' +
      'box-sizing:border-box;"></textarea>' +
      '</div></div></div>'

    const ta = $('floatEdBody')
    const g = $('floatEdGutter')
    const hl = $('floatEdHighlight')
    const langSel = $('floatEdLang')
    let dirty = false
    let original = text0
    let lang = lang0

    // 字体：直接写 style，避免 CSS 变量在浮窗失效
    const monoStack = fontFamily
    if (ta) {
      ta.style.fontFamily = monoStack
      ta.style.color = FG
      ta.style.webkitTextFillColor = FG
      ta.style.caretColor = CARET
      ta.style.opacity = '1'
      ta.style.visibility = 'visible'
      ta.style.fontSize = fontSize + 'px'
      ta.style.lineHeight = '1.45'
      ta.value = text0
    }
    ;[g, hl].forEach((el) => {
      if (!el) return
      el.style.fontFamily = monoStack
      el.style.fontSize = fontSize + 'px'
      el.style.lineHeight = '1.45'
    })

    if (langSel && typeof EditorLib !== 'undefined' && EditorLib.listLanguages) {
      try {
        langSel.innerHTML = EditorLib.listLanguages()
          .map((l) => '<option value="' + esc(l.id) + '">' + esc(l.name) + '</option>')
          .join('')
        langSel.value = lang
      } catch (_) {}
    }

    const paint = () => {
      if (!ta) return
      const val = ta.value
      if (g && EditorLib && EditorLib.buildGutter) {
        try {
          g.textContent = EditorLib.buildGutter(val)
        } catch (_) {
          g.textContent = '1'
        }
      }
      const want = $('floatEdHl')?.checked !== false
      if (hl) {
        try {
          if (want && EditorLib && EditorLib.highlightPlain && val.length <= 180000) {
            hl.innerHTML = EditorLib.highlightPlain(val, lang) + '\n'
            // 有高亮时 textarea 透明叠字，但 caret 可见
            ta.style.color = FG
            ta.style.webkitTextFillColor = FG  // 浮窗始终可见字，高亮仅装饰
            ta.style.caretColor = CARET
            hl.style.display = 'block'
            hl.style.color = FG
          } else {
            hl.textContent = ''
            hl.style.display = 'none'
            ta.style.color = FG
            ta.style.webkitTextFillColor = FG
            ta.style.caretColor = CARET
          }
        } catch (_) {
          hl.textContent = ''
          hl.style.display = 'none'
          ta.style.color = FG
          ta.style.webkitTextFillColor = FG
        }
      } else {
        ta.style.color = FG
        ta.style.webkitTextFillColor = FG
      }
      const lines =
        EditorLib && EditorLib.lineCount ? EditorLib.lineCount(val) : val.split('\n').length
      if ($('floatEdMeta')) {
        $('floatEdMeta').textContent = (dirty ? '● ' : '') + lines + ' 行 · ' + val.length + ' B'
      }
      if ($('floatEdTitle')) {
        $('floatEdTitle').textContent = (dirty ? '● ' : '') + path
      }
    }
    const syncScroll = () => {
      if (!ta) return
      if (g) g.scrollTop = ta.scrollTop
      if (hl) {
        hl.scrollTop = ta.scrollTop
        hl.scrollLeft = ta.scrollLeft
      }
    }
    ta?.addEventListener('input', () => {
      dirty = ta.value !== original
      paint()
    })
    ta?.addEventListener('scroll', syncScroll)
    langSel?.addEventListener('change', () => {
      lang = langSel.value || 'plaintext'
      paint()
    })
    $('floatEdHl')?.addEventListener('change', paint)
    paint()

    // 布局自检：高度塌了就强制撑开
    try {
      const wrap = $('floatEdBodyWrap')
      const shell = $('floatEditorShell')
      if (wrap && wrap.offsetHeight < 80) {
        wrap.style.flex = '1 1 auto'
        wrap.style.minHeight = '200px'
        wrap.style.height = 'calc(100vh - 80px)'
      }
      if (shell && shell.offsetHeight < 100) {
        shell.style.height = '100vh'
        shell.style.minHeight = '100vh'
      }
      rlog('info', 'float', 'editor-paint', {
        rootH: root.offsetHeight,
        shellH: shell ? shell.offsetHeight : -1,
        wrapH: wrap ? wrap.offsetHeight : -1,
        textLen: text0.length,
        hasTa: !!ta,
      })
    } catch (_) {}

    $('floatEdSave')?.addEventListener('click', async () => {
      if (!sessionId || !path) return toast('无会话或路径', true)
      if (!hasApi || typeof api.sftpWrite !== 'function') return toast('SFTP 写入不可用', true)
      const body = ta?.value ?? ''
      let b64
      try {
        const bytes = new TextEncoder().encode(body)
        let bin = ''
        const chunk = 0x8000
        for (let i = 0; i < bytes.length; i += chunk) {
          bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk))
        }
        b64 = btoa(bin)
      } catch (e) {
        try {
          b64 = btoa(unescape(encodeURIComponent(body)))
        } catch (e2) {
          return toast('编码失败', true)
        }
      }
      if ($('floatEdStatus')) $('floatEdStatus').textContent = '保存中…'
      const r = await api.sftpWrite(sessionId, path, b64)
      if (!r?.ok) {
        if ($('floatEdStatus')) $('floatEdStatus').textContent = '保存失败'
        return toast(r?.error || '保存失败', true)
      }
      original = body
      dirty = false
      paint()
      if ($('floatEdStatus')) $('floatEdStatus').textContent = '已保存'
      toast('已保存 ' + path)
      try {
        await api.floatToMain({ type: 'editor-saved', path, sessionId })
      } catch (_) {}
    })

    $('floatEdReload')?.addEventListener('click', async () => {
      if (!sessionId || !path) return
      if (dirty) {
        const ok = await askConfirm('放弃未保存修改并重新加载？', { title: '重新加载' })
        if (!ok) return
      }
      const r = await api.sftpRead(sessionId, path)
      if (!r?.ok) return toast(r?.error || '读取失败', true)
      let text = ''
      try {
        const bin = atob(r.dataBase64 || '')
        const bytes = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
        text = new TextDecoder('utf-8', { fatal: false }).decode(bytes)
      } catch (_) {
        try {
          text = atob(r.dataBase64 || '')
        } catch (e2) {
          text = ''
        }
      }
      if (ta) ta.value = text
      original = text
      dirty = false
      paint()
      toast('已重新加载')
    })

    $('floatBtnClose')?.addEventListener('click', async () => {
      if (dirty) {
        const ok = await askConfirm('文件已修改，关闭将丢失未保存更改？', { title: '关闭编辑器' })
        if (!ok) return
      }
      api.closeFloatWindow?.(meta.id)
    })

    // 聚焦编辑区，确认可交互
    try {
      setTimeout(() => ta && ta.focus(), 50)
    } catch (_) {}
  }

  function bindFloatMessagesFromMain() {
    if (!hasApi || typeof api.onFloatMessage !== 'function') return
    // 主窗接收浮窗指令
    if (document.body.classList.contains('float-window')) return
    api.onFloatMessage((msg) => {
      if (!msg || !msg.type) return
      if (msg.type === 'connect' && msg.hostId) {
        showModal('connMgrModal', false)
        connectHost(msg.hostId)
      } else if (msg.type === 'edit-host') {
        openHostModal(msg.hostId || null)
      } else if (msg.type === 'new-host') {
        openHostModal(null)
      } else if (msg.type === 'open-conn-mgr') {
        openConnMgr()
      } else if (msg.type === 'open-settings') {
        // 已在独立设置窗则忽略
        if (!document.body.classList.contains('float-window')) openSettings()
      } else if (msg.type === 'open-backup') {
        openBackupConfig()
      } else if (msg.type === 'delete-host' && msg.hostId) {
        ;(async () => {
          try {
            if (!(await askConfirm('确定删除该主机？', { title: '删除主机', danger: true, okText: '确定删除' }))) return
            state.hosts = state.hosts.filter((h) => h.id !== msg.hostId)
            passwordVault.delete(msg.hostId)
            await persistHosts()
            renderQuickConnect()
            try {
              await api.floatToFloat?.({ id: 'conn-mgr', type: 'hosts-updated', hosts: state.hosts })
            } catch (_) {}
          } catch (e) {
            rlog('error', 'float', 'delete-host', { err: e && e.message })
          }
        })()
      } else if (msg.type === 'rename-group' && msg.group) {
        ;(async () => {
          try {
            const g = String(msg.group)
            const inGroup = (h) => ((h.group || '默认') + '').trim() || '默认'
            const nn = await askPrompt('新的分组名称', g === '默认' ? '' : g, { title: '重命名分组' })
            if (nn == null) return
            const next = String(nn).trim()
            if (!next || next === g) return
            // '默认' 作为未分组桶：目标名为「默认」时等于取消分组（group 置空）
            const target = next === '默认' ? '' : next
            let n = 0
            for (const h of state.hosts) {
              if (inGroup(h) === g) { h.group = target; n++ }
            }
            if (!n) return
            await persistHosts()
            renderConnMgr()
            renderHostBrowser()
            renderQuickConnect()
            try {
              await api.floatToFloat?.({ id: 'conn-mgr', type: 'hosts-updated', hosts: state.hosts })
            } catch (_) {}
            toast('已重命名分组：' + g + ' → ' + next)
          } catch (e) {
            rlog('error', 'float', 'rename-group', { err: e && e.message })
          }
        })()
      } else if (msg.type === 'delete-group' && msg.group) {
        ;(async () => {
          try {
            const g = String(msg.group)
            const inGroup = (h) => ((h.group || '默认') + '').trim() || '默认'
            const victims = state.hosts.filter((h) => inGroup(h) === g)
            if (!victims.length) return
            const ok = await askConfirm(
              '确定删除分组「' + g + '」及其中 ' + victims.length + ' 个连接？此操作不可恢复。',
              { title: '删除分组', danger: true, okText: '删除分组' },
            )
            if (!ok) return
            const ids = new Set(victims.map((h) => h.id))
            state.hosts = state.hosts.filter((h) => !ids.has(h.id))
            for (const id of ids) passwordVault.delete(id)
            await persistHosts()
            renderConnMgr()
            renderHostBrowser()
            renderQuickConnect()
            try {
              await api.floatToFloat?.({ id: 'conn-mgr', type: 'hosts-updated', hosts: state.hosts })
            } catch (_) {}
            toast('已删除分组「' + g + '」及 ' + victims.length + ' 个连接')
          } catch (e) {
            rlog('error', 'float', 'delete-group', { err: e && e.message })
          }
        })()
      } else if (msg.type === 'editor-saved') {
        try { refreshSftp() } catch (_) {}
      } else if (msg.type === 'hosts-updated') {
        ;(async () => {
          if (hasApi && api.loadHosts) {
            const h = await api.loadHosts()
            // loadHosts() resolves to the hosts array (not {ok,data})
            if (Array.isArray(h)) state.hosts = h
          }
          renderConnMgr()
          renderHostBrowser()
          renderQuickConnect()
          try {
            await api.floatToFloat?.({ id: 'conn-mgr', type: 'hosts-updated', hosts: state.hosts })
          } catch (_) {}
        })()
      }
    })
    try {
      api.onFloatClosed?.((msg) => {
        // 浮窗关闭后不自动重开页内层（用户已明确弹出）
        void msg
      })
    } catch (_) {}
  }

  function setSidebarCollapsed(collapsed) {
    const row = document.querySelector('.main-row')
    const btn = $('btnSideToggle')
    const restore = $('btnSideRestore')
    if (!row) return
    row.classList.toggle('side-collapsed', !!collapsed)
    state.sideCollapsed = !!collapsed
    if (btn) {
      btn.textContent = collapsed ? '⟩' : '⟨'
      btn.title = collapsed ? '显示侧栏' : '隐藏侧栏'
    }
    if (restore) {
      if (collapsed) {
        restore.hidden = false
        restore.removeAttribute('hidden')
      } else {
        restore.hidden = true
        restore.setAttribute('hidden', '')
      }
    }
    try { fitAddon?.fit() } catch (_) {}
  }

  function showModal(id, show) {
    const el = $(id)
    if (!el) return
    el.hidden = !show
    if (show) el.removeAttribute('hidden')
    else el.setAttribute('hidden', '')
  }

  /**
   * 把主窗 DOM 里的既有模态框（#hostModal / #backupModal 等）重挂进独立浮窗根节点：
   * 铺满窗口、去圆角、隐藏自带关闭按钮、标题栏作为系统拖动区。返回内部 .modal 元素。
   * host-editor / backup 两处独立窗共用，避免各写一份重复的重挂逻辑。
   */
  function mountModalInFloat(root, modalId, closeBtnId) {
    const host = $(modalId)
    if (!host) return null
    root.appendChild(host)
    host.hidden = false
    // 遮罩层铺满窗口，但去掉毛玻璃/居中/暗底——否则模态框只占 92vw 居中，
    // 四周留一圈模糊暗框（用户看到的「多出一大块毛玻璃」）。
    Object.assign(host.style, {
      position: 'absolute', inset: '0', width: '100%', height: '100%',
      display: 'block', margin: '0', padding: '0',
      background: 'transparent', backdropFilter: 'none', WebkitBackdropFilter: 'none',
      animation: 'none',
    })
    const modal = host.querySelector('.modal')
    if (modal) {
      // 模态框铺满整窗、去圆角/阴影/最大宽高限制，成为窗口本体而非浮层卡片。
      Object.assign(modal.style, {
        position: 'absolute', inset: '0', width: '100%', height: '100%',
        maxWidth: 'none', maxHeight: 'none', minWidth: '0', minHeight: '0',
        left: '0', top: '0', transform: 'none', margin: '0',
        borderRadius: '0', border: 'none', boxShadow: 'none', animation: 'none',
      })
      modal.classList.remove('draggable')
      modal.classList.add('float-mounted')
      const closeBtn = closeBtnId ? modal.querySelector('#' + closeBtnId) : null
      if (closeBtn) closeBtn.style.display = 'none'
      const titleBar = modal.querySelector('.modal-title')
      if (titleBar) {
        titleBar.style.webkitAppRegion = 'drag'
        titleBar.style.cursor = 'default'
      }
    }
    return modal
  }

  /**
   * 让页内二级弹窗（终端背景 / 命令板选项 / 编辑快捷命令等）可自由拖动，
   * 且遮罩收缩为 0×0 不再挡住终端。标题栏为拖动手柄。
   */
  function makeModalFloatDraggable(id, opts = {}) {
    const mask = $(id)
    if (!mask) return
    mask.classList.add('float-modal-mask')
    const win = mask.querySelector('.modal')
    if (!win) return
    // 首次弹出给一个居中偏上的落点，之后保留用户拖动后的位置
    if (!win.dataset.floatPlaced) {
      win.dataset.floatPlaced = '1'
      win.style.position = 'fixed'
      win.style.margin = '0'
      win.style.left = 'max(12px, calc(50vw - ' + (Number(opts.halfW) || 240) + 'px))'
      win.style.top = (opts.top || '64px')
    }
    if (typeof enableModalDrag === 'function') {
      enableModalDrag(win, { kind: opts.kind || id, title: opts.title || '' })
    }
  }

  function applyCmdEditorCollapsed(collapsed) {
    const board = $('cmdBoard') || document.querySelector('#panelCmds .cmd-board')
    const expand = $('btnCmdEditorExpand')
    const colBtn = $('btnCmdEditorCollapse')
    if (!board) return
    board.classList.toggle('is-editor-collapsed', !!collapsed)
    if (expand) {
      if (collapsed) {
        expand.hidden = false
        expand.removeAttribute('hidden')
      } else {
        expand.hidden = true
        expand.setAttribute('hidden', '')
      }
    }
    if (colBtn) colBtn.title = collapsed ? '展开命令编辑器' : '向右收起命令编辑器'
    state.cmdEditorCollapsed = !!collapsed
    try {
      state.settings = state.settings || {}
      state.settings.cmdEditorCollapsed = !!collapsed
    } catch (_) {}
  }


  // ── 命令历史弹出（点选填入；禁止往终端刷整表） ─────────
  let _cmdHistUi = { open: false, active: 0, filter: '', onDoc: null, onKey: null }

  function hideCmdHistoryPopup() {
    const pop = $('cmdHistPopup')
    const btn = $('btnHist')
    if (pop) {
      pop.hidden = true
      pop.setAttribute('hidden', '')
    }
    if (btn) btn.setAttribute('aria-expanded', 'false')
    if (_cmdHistUi.onDoc) {
      try { document.removeEventListener('pointerdown', _cmdHistUi.onDoc, true) } catch (_) {}
      _cmdHistUi.onDoc = null
    }
    if (_cmdHistUi.onKey) {
      try { document.removeEventListener('keydown', _cmdHistUi.onKey, true) } catch (_) {}
      _cmdHistUi.onKey = null
    }
    _cmdHistUi.open = false
  }

  function filteredCmdHistory() {
    const q = String(_cmdHistUi.filter || '').trim().toLowerCase()
    const list = Array.isArray(state.history) ? state.history : []
    if (!q) return list.slice()
    return list.filter((line) => String(line).toLowerCase().includes(q))
  }

  function paintCmdHistoryList() {
    const box = $('cmdHistList')
    if (!box) return
    const items = filteredCmdHistory()
    if (!items.length) {
      box.innerHTML = '<div class="cmd-hist-empty">' +
        (state.history && state.history.length
          ? '无匹配历史'
          : '暂无历史 — 在上方命令栏发送后会出现在这里') +
        '</div>'
      return
    }
    if (_cmdHistUi.active < 0) _cmdHistUi.active = 0
    if (_cmdHistUi.active >= items.length) _cmdHistUi.active = items.length - 1
    box.innerHTML = items
      .map((line, i) => {
        const active = i === _cmdHistUi.active ? ' is-active' : ''
        return (
          `<div class="cmd-hist-item${active}" role="option" data-i="${i}" title="${esc(line)}">
            <span class="cmd-hist-text">${esc(line)}</span>
            <span class="cmd-hist-actions">
              <button type="button" class="icon-btn" data-act="send" title="发送">▶</button>
              <button type="button" class="icon-btn" data-act="copy" title="复制">⎘</button>
              <button type="button" class="icon-btn" style="color:var(--error)" data-act="del" title="删除">✖</button>
            </span>
          </div>`
        )
      })
      .join('')
    box.querySelectorAll('.cmd-hist-item').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.preventDefault()
        e.stopPropagation()
        const i = Number(btn.dataset.i)
        const items2 = filteredCmdHistory()
        const line = items2[i]
        if (line == null) return
        
        const actBtn = e.target.closest('[data-act]')
        if (actBtn) {
          const act = actBtn.dataset.act
          if (act === 'send') {
            applyHistoryLine(line, { send: true })
          } else if (act === 'copy') {
            try { await navigator.clipboard.writeText(line); toast('已复制命令') } catch (_) {}
          } else if (act === 'del') {
            // Find and remove all occurrences in original state.history
            state.history = state.history.filter((x) => x !== line)
            saveSettingsDebounced()
            renderCmdHistList()
          }
          return
        }
        applyHistoryLine(line, { send: false })
      })
      btn.addEventListener('dblclick', (e) => {
        e.preventDefault()
        e.stopPropagation()
        const i = Number(btn.dataset.i)
        const items2 = filteredCmdHistory()
        const line = items2[i]
        if (line == null) return
        applyHistoryLine(line, { send: true })
      })
      btn.addEventListener('mouseenter', () => {
        _cmdHistUi.active = Number(btn.dataset.i) || 0
        box.querySelectorAll('.cmd-hist-item').forEach((b) => {
          b.classList.toggle('is-active', Number(b.dataset.i) === _cmdHistUi.active)
        })
      })
    })
    // scroll active into view
    try {
      const act = box.querySelector('.cmd-hist-item.is-active')
      if (act) act.scrollIntoView({ block: 'nearest' })
    } catch (_) {}
  }

  function applyHistoryLine(line, opts = {}) {
    const input = $('cmd')
    if (!input) return
    input.value = String(line || '')
    // 同步 histIndex 到完整 history 中的位置
    const full = state.history || []
    const idx = full.indexOf(line)
    state.histIndex = idx >= 0 ? idx : -1
    hideCmdHistoryPopup()
    input.focus()
    try {
      const len = input.value.length
      input.setSelectionRange(len, len)
    } catch (_) {}
    if (opts.send) {
      sendCommand()
    }
  }

  function positionCmdHistoryPopup() {
    const pop = $('cmdHistPopup')
    const btn = $('btnHist')
    const bar = $('cmdBar') || btn?.parentElement
    if (!pop || !btn) return
    const br = btn.getBoundingClientRect()
    const barR = bar ? bar.getBoundingClientRect() : br
    const w = Math.max(320, Math.min(560, window.innerWidth - 24))
    pop.style.width = w + 'px'
    // 默认贴在命令栏上方（历史按钮附近）
    let left = Math.round(br.right - w)
    if (left < 12) left = 12
    if (left + w > window.innerWidth - 12) left = window.innerWidth - w - 12
    pop.style.left = left + 'px'
    // 先显示测高
    pop.hidden = false
    pop.removeAttribute('hidden')
    const ph = pop.offsetHeight || 300
    let top = Math.round(barR.top - ph - 6)
    if (top < 8) {
      // 上方不够则放下方
      top = Math.round(barR.bottom + 6)
    }
    if (top + ph > window.innerHeight - 8) {
      top = Math.max(8, window.innerHeight - ph - 8)
    }
    pop.style.top = top + 'px'
  }

  function showCmdHistoryPopup() {
    const pop = $('cmdHistPopup')
    const btn = $('btnHist')
    if (!pop) return
    if (_cmdHistUi.open) {
      hideCmdHistoryPopup()
      return
    }
    _cmdHistUi.filter = ''
    _cmdHistUi.active = 0
    const filt = $('cmdHistFilter')
    if (filt) filt.value = ''
    paintCmdHistoryList()
    positionCmdHistoryPopup()
    if (btn) btn.setAttribute('aria-expanded', 'true')
    _cmdHistUi.open = true
    _cmdHistUi.onDoc = (ev) => {
      const t = ev.target
      if (pop.contains(t) || (btn && btn.contains(t))) return
      hideCmdHistoryPopup()
    }
    _cmdHistUi.onKey = (ev) => {
      if (!_cmdHistUi.open) return
      const items = filteredCmdHistory()
      if (ev.key === 'Escape') {
        ev.preventDefault()
        hideCmdHistoryPopup()
        $('cmd')?.focus()
        return
      }
      if (ev.key === 'ArrowDown') {
        ev.preventDefault()
        _cmdHistUi.active = Math.min(items.length - 1, _cmdHistUi.active + 1)
        paintCmdHistoryList()
        return
      }
      if (ev.key === 'ArrowUp') {
        ev.preventDefault()
        _cmdHistUi.active = Math.max(0, _cmdHistUi.active - 1)
        paintCmdHistoryList()
        return
      }
      if (ev.key === 'Enter') {
        // 若焦点在过滤框或列表，填入当前项
        const line = items[_cmdHistUi.active]
        if (line != null && (document.activeElement === $('cmdHistFilter') || $('cmdHistPopup')?.contains(document.activeElement))) {
          ev.preventDefault()
          applyHistoryLine(line, { send: ev.metaKey || ev.ctrlKey })
        }
      }
    }
    document.addEventListener('pointerdown', _cmdHistUi.onDoc, true)
    document.addEventListener('keydown', _cmdHistUi.onKey, true)
    setTimeout(() => {
      try { $('cmdHistFilter')?.focus() } catch (_) {}
    }, 30)
  }


  function bindUi() {
    // platform + theme chrome (macOS traffic lights / win controls)
    applyBodyChromeClasses(state.settings?.theme || 'dark')
    // 状态栏版本（预留；后续可从 main 注入）
    if (!$('appVersion')?.dataset.locked) setAppVersionLabel('0.1.0')
    paintBrandUpdateDot()
    const brand = $('sidebarBrand')
    if (brand && !brand.dataset.boundUpdate) {
      brand.dataset.boundUpdate = '1'
      brand.addEventListener('click', (e) => {
        e.preventDefault()
        openPixShellReleases().catch(() => {})
      })
    }

    // window controls & pixel theme toggle
    on('btnWinClose', 'click', () => api.closeWindow?.())
    on('btnWinMin', 'click', () => api.minimizeWindow?.())
    on('btnWinMax', 'click', () => api.maximizeWindow?.())
    // Windows / non-mac titlebar buttons
    document.querySelectorAll('#winControls .win-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        const act = btn.getAttribute('data-win')
        if (act === 'min') api.minimizeWindow?.()
        else if (act === 'max') api.maximizeWindow?.()
        else if (act === 'close') api.closeWindow?.()
      })
    })
    on('btnThemeToggle', 'click', () => {
      const next = state.settings.theme === 'light' ? 'dark' : 'light'
      setThemeMode(next)
      toast(next === 'light' ? '已切换至浅色模式' : '已切换至深色模式')
    })

    try {
      bindMenus()
    } catch (e) {
      console.error('bindMenus', e)
    }
    try {
      bindResizers()
    } catch (e) {
      console.error('bindResizers', e)
    }

    // sidebar collapse
    on('btnSideToggle', 'click', () => setSidebarCollapsed(!state.sideCollapsed))
    on('btnSideRestore', 'click', (e) => {
      e.stopPropagation()
      setSidebarCollapsed(false)
    })
    // 收起后：单击/双击左侧条都能展开（不再只靠难发现的双击）
    $('sidebarResizer')?.addEventListener('click', (e) => {
      if (!state.sideCollapsed) return
      e.preventDefault()
      e.stopPropagation()
      setSidebarCollapsed(false)
    })
    $('sidebarResizer')?.addEventListener('dblclick', () => setSidebarCollapsed(!state.sideCollapsed))
    // 底栏 文件/命令 显隐（命令栏发送旁）
    on('btnToggleBottom', 'click', () => setBottomCollapsed(!state.bottomCollapsed))
    // draggable modals（均可拖出主窗 / 双击标题弹出独立窗）
    const dragMap = {
      connMgrModal: { kind: 'conn-mgr', title: '连接管理器', floatId: 'conn-mgr' },
      hostModal: { kind: 'host-editor', title: '连接设置', floatId: 'host-editor' },
      settingsModal: { kind: 'settings', title: '设置', floatId: 'settings' },
      backupModal: { kind: 'backup', title: '备份与恢复', floatId: 'backup' },
    }
    Object.keys(dragMap).forEach((id) => {
      const mask = $(id)
      const modal = mask?.querySelector('.modal')
      if (modal) enableModalDrag(modal, dragMap[id])
    })

    bindTermBgPickerUi()
    bindKeyPickDrop()

    // ── connection manager ──
    on('btnConnMgr', 'click', () => {
      openConnMgr()
    })
    on('btnConnMgrClose', 'click', () => showModal('connMgrModal', false))
    on('btnMgrCancel', 'click', () => showModal('connMgrModal', false))
    on('btnMgrNew', 'click', () => openHostModal(null))
    on('btnMgrEdit', 'click', () => {
      if (state.mgrSelectedId) openHostModal(state.mgrSelectedId)
      else toast('请先选中主机')
    })
    on('btnMgrDel', 'click', async () => {
      if (!state.mgrSelectedId) return
      if (!(await askConfirm('确定删除该主机？', { title: '删除主机', danger: true, okText: '确定删除' }))) return
      state.hosts = state.hosts.filter((h) => h.id !== state.mgrSelectedId)
      state.mgrSelectedId = null
      await persistHosts()
      renderConnMgr()
    })
    on('btnMgrFolder', 'click', async () => {
      const g = await askPrompt('新分组名称', '新分组', { title: '新建分组' })
      if (!g) return
      openHostModal(null)
      if ($('fGroup')) $('fGroup').value = g
    })
    on('btnMgrConnect', 'click', async () => {
      if (!state.mgrSelectedId) return toast('请选中主机')
      const closeAfter = $('mgrCloseAfter')?.checked
      await connectHost(state.mgrSelectedId)
      if (closeAfter) showModal('connMgrModal', false)
    })
    on('mgrFilter', 'input', (e) => {
      state.mgrFilter = e.target.value
      state.hostBrowserFilter = e.target.value
      renderConnMgr()
    })
    on('mgrShowDeleted', 'change', () => renderConnMgr())

    // ── toolbar (left brand actions; tools/menu via bindMenus flyouts) ──
    on('btnNew', 'click', () => openHostModal(null))
    // 侧栏主控：已连接=断开，未连接/已断开=连接或重连
    const connBtn = $('btnConnToggle')
    if (connBtn && !connBtn.dataset.boundToggle) {
      connBtn.dataset.boundToggle = '1'
      connBtn.addEventListener('click', (e) => onConnToggleClick(e))
    }
    // 旧 label / 红灯兜底
    const connLab = $('connStateLabel')
    if (connLab && !connLab.dataset.boundReconnect) {
      connLab.dataset.boundReconnect = '1'
      connLab.addEventListener('click', (e) => onConnToggleClick(e))
      connLab.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          onConnToggleClick(e)
        }
      })
    }
    const syncDot = $('syncDot')
    if (syncDot && !syncDot.dataset.boundReconnect) {
      syncDot.dataset.boundReconnect = '1'
      syncDot.style.cursor = 'pointer'
      syncDot.title = '点击切换连接'
      syncDot.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        onConnToggleClick(e)
      })
    }

    on('btnSysInfo', 'click', () => menuAction('sysinfo'))
    on('btnSysInfoRefresh', 'click', () => {
      const t = state.tabs.find((x) => x.id === state.activeTabId)
      if (t && t.type === 'sysinfo') fillSysInfo(t)
      else {
        const st = sessionTab()
        if (st) fillSysInfo({ sessionId: st.sessionId, hostId: st.hostId })
      }
    })
    on('btnCopyIp', 'click', async () => {
      const ip = $('lmIp')?.textContent || ''
      try {
        await navigator.clipboard.writeText(ip)
        toast('已复制 ' + ip)
      } catch (_) {
        toast(ip)
      }
    })
    on('btnQcClear', 'click', async () => {
      state.settings.recentHosts = []
      if (hasApi) await api.saveSettings(state.settings)
      renderQuickConnect()
    })

    // ── host modal ──
    // 左侧二级页签：SSH / 终端 / 代理 / 隧道
    document.querySelectorAll('.hed-nav [data-hed]').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        const k = btn.getAttribute('data-hed')
        document.querySelectorAll('.hed-nav [data-hed]').forEach((b) => {
          b.classList.toggle('active', b === btn)
        })
        document.querySelectorAll('.hed-pane').forEach((p) => {
          const show = p.getAttribute('data-hed-pane') === k
          p.hidden = !show
          if (show) p.removeAttribute('hidden')
          else p.setAttribute('hidden', '')
        })
      })
    })
    on('btnHostClose', 'click', () => showModal('hostModal', false))
    on('btnModalCancel', 'click', () => showModal('hostModal', false))
    on('btnModalSaveOnly', 'click', () => saveHost(false))
    on('btnModalSave', 'click', () => saveHost(true))
    on('hostModal', 'click', (e) => {
      if (e.target === $('hostModal')) showModal('hostModal', false)
    })
    on('connMgrModal', 'click', (e) => {
      const mask = $('connMgrModal')
      // 浮动模式下点空白不关，避免误关；全屏遮罩模式仍可点外关闭
      if (e.target === mask && mask && !mask.classList.contains('float-modal-mask')) {
        showModal('connMgrModal', false)
      }
    })
    on('btnSetCancel', 'click', () => showModal('settingsModal', false))
    on('btnSetClose', 'click', () => showModal('settingsModal', false))
    on('btnSetSave', 'click', () => saveSettings())
    on('btnBackupClose', 'click', () => showModal('backupModal', false))
    on('btnBackupCancel', 'click', () => showModal('backupModal', false))
    on('btnBackupSave', 'click', () => saveBackupConfig())
    on('btnBackupExportNow', 'click', () => exportLocalBackupBundle())
    on('btnBackupImportNow', 'click', () => importLocalBackupBundle())
    on('btnCliInstallSkills', 'click', async () => {
      if (!hasApi || !api.cliInstallSkills) return toast('不可用', true)
      const r = await api.cliInstallSkills()
      if (r?.ok) {
        toast(`Skills 已安装 ${r.installed?.length || 0} 处` + (r.cliPath ? ' · CLI: ' + r.cliPath : ''))
      } else {
        toast('安装失败: ' + (r?.error || JSON.stringify(r?.errors || '')), true)
      }
    })
    on('btnCliCopyTokenPath', 'click', async () => {
      if (!hasApi || !api.cliTokenPath) return
      const r = await api.cliTokenPath()
      const p = r?.path || ''
      try {
        if (p) await navigator.clipboard.writeText(p)
        toast(p ? '已复制 token 路径' : '无路径', !p)
      } catch {
        toast(p || '复制失败', true)
      }
    })
    on('btnCliRotateToken', 'click', async () => {
      if (!hasApi || !api.cliRotateToken) return toast('不可用', true)
      const r = await api.cliRotateToken()
      if (r?.ok) {
        toast('Token 已轮换，旧 Token 已失效')
      } else {
        toast('轮换失败: ' + (r?.error || ''), true)
      }
    })
    on('settingsModal', 'click', (e) => {
      if (e.target === $('settingsModal')) showModal('settingsModal', false)
    })

    document.querySelectorAll('.bottom-tab').forEach((t) => {
      t.addEventListener('click', () => setBottom(t.dataset.bottom))
    })

    on('btnSend', 'click', () => sendCommand())
    on('cmd', 'keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        sendCommand()
      } else if (e.altKey && (e.key === 'h' || e.key === 'H' || e.key === 'ArrowUp')) {
        // Alt+H / Alt+↑ 打开历史弹出（不刷终端）
        e.preventDefault()
        showCmdHistoryPopup()
      } else if (e.key === 'ArrowUp') {
        e.preventDefault()
        if (state.histIndex === -1) state.draft = $('cmd').value
        if (state.histIndex < state.history.length - 1) state.histIndex++
        $('cmd').value = state.history[state.histIndex] || ''
      } else if (e.key === 'ArrowDown') {
        e.preventDefault()
        if (state.histIndex <= 0) {
          state.histIndex = -1
          $('cmd').value = state.draft
        } else {
          state.histIndex--
          $('cmd').value = state.history[state.histIndex] || ''
        }
      }
    })
    on('btnHist', 'click', (e) => {
      e.preventDefault()
      e.stopPropagation()
      showCmdHistoryPopup()
    })
    on('btnHistClear', 'click', (e) => {
      e.preventDefault()
      e.stopPropagation()
      state.history = []
      state.histIndex = -1
      paintCmdHistoryList()
      toast('历史已清空')
    })
    on('cmdHistFilter', 'input', () => {
      _cmdHistUi.filter = $('cmdHistFilter')?.value || ''
      _cmdHistUi.active = 0
      paintCmdHistoryList()
    })
    // 窗口尺寸变化时若打开则重定位
    window.addEventListener('resize', () => {
      if (_cmdHistUi.open) positionCmdHistoryPopup()
    })


    // applyCmdEditorCollapsed hoisted
    on('btnCmdEditorCollapse', 'click', () => {
      applyCmdEditorCollapsed(true)
      try {
        if (hasApi && api.saveSettings) api.saveSettings(state.settings)
      } catch (_) {}
    })
    on('btnCmdEditorExpand', 'click', () => {
      applyCmdEditorCollapsed(false)
      try {
        if (hasApi && api.saveSettings) api.saveSettings(state.settings)
      } catch (_) {}
    })
    // 恢复收起状态
    try {
      if (state.settings && state.settings.cmdEditorCollapsed) applyCmdEditorCollapsed(true)
    } catch (_) {}

    on('btnCmdOpt', 'click', () => openCmdOptionsPanel())
    on('btnCmdOptClose', 'click', () => showModal('cmdOptModal', false))
    on('btnCmdOptDone', 'click', () => showModal('cmdOptModal', false))
    on('btnCmdAdd', 'click', () => openCmdEditModal(-1))
    on('btnCmdAddGroup', 'click', async () => {
      const g = await askPrompt('新分组名称', state.activeCmdGroup || '新分组', { title: '新建分组' })
      if (!g) return
      state.activeCmdGroup = g
      openCmdEditModal(-1)
      if ($('cmdEditGroup')) $('cmdEditGroup').value = g
    })
    on('btnCmdImport', 'click', async () => {
      if (!hasApi) return toast('无 API', true)
      try {
        if (api.importQuick) {
          const r = await api.importQuick()
          if (r?.ok && Array.isArray(r.list)) {
            state.quick = r.list
            await persistQuickList()
            paintCmdOptList()
            toast('已导入 ' + r.list.length + ' 条')
            return
          }
        }
        const f = await api.openFile?.()
        const path = f?.path || f?.paths?.[0]
        if (!path) return
        const rr = await api.readTextFile(path)
        const text = typeof rr === 'string' ? rr : rr?.text
        const data = JSON.parse(text)
        const list = Array.isArray(data) ? data : data.commands || data.quick || []
        if (!list.length) return toast('文件无命令', true)
        state.quick = list.map((q) => ({
          name: q.name || q.title || '命令',
          group: q.group || q.category || '导入',
          command: q.command || q.cmd || '',
        }))
        await persistQuickList()
        paintCmdOptList()
        toast('已导入 ' + state.quick.length + ' 条')
      } catch (e) {
        toast('导入失败: ' + (e.message || e), true)
      }
    })
    on('btnCmdExport', 'click', async () => {
      const list = ensureQuickMutable()
      const text = JSON.stringify({ version: 1, commands: list }, null, 2)
      try {
        if (hasApi && api.saveFile && api.writeTextFile) {
          const r = await api.saveFile({ defaultPath: 'pixshell-commands.json' })
          if (r?.ok && r.path) {
            await api.writeTextFile(r.path, text)
            toast('已导出')
            return
          }
        }
        await navigator.clipboard.writeText(text)
        toast('已复制 JSON 到剪贴板')
      } catch (e) {
        toast('导出失败: ' + (e.message || e), true)
      }
    })
    on('btnCmdEditClose', 'click', () => showModal('cmdEditModal', false))
    on('btnCmdEditCancel', 'click', () => showModal('cmdEditModal', false))
    on('btnCmdEditSave', 'click', () => saveCmdEditModal())
    on('btnSendChip', 'click', () => {
      if (!state.selectedChipCmd) return toast('请先点选一条快捷命令', true)
      sendQuick(state.selectedChipCmd)
    })
    on('btnSendEditor', 'click', async () => {
      const raw = $('cmdEditor')?.value || ''
      if (!raw.trim()) return
      await sendQuick({ name: 'editor', command: raw.endsWith('\n') ? raw : raw + '\n' })
    })

    on('sftpRefresh', 'click', () => refreshSftp())
    on('sftpUp', 'click', async () => {
      const tab = sessionTab()
      if (!tab) return toast('请先连接', true)
      const cur = tab.sftpPath || '/'
      if (cur === '/' || cur === '') return toast('已在根目录')
      await navigateSftp(tab, sftpJoin(cur, '..') || '/', { syncShell: false })
    })

    on('sftpUpload', 'click', async () => {
      const tab = sessionTab()
      if (!tab?.sessionId) return toast('请先连接', true)
      toast('上传中…（大文件/多文件将自动打包）')
      const r = await api.sftpUpload(tab.sessionId, tab.sftpPath || '/', null, { autoPack: true })
      const msg = r?.packed
        ? '上传完成（已自动打包并在远端解压）'
        : r?.ok
          ? '上传完成'
          : '上传: ' + (r?.error || 'fail')
      toast(msg, !r?.ok)
      await refreshSftp()
    })
    on('sftpDownload', 'click', async () => {
      const tab = sessionTab()
      if (!tab?.sessionId) return toast('请先连接', true)
      const items = getSelectedSftpItems()
      if (!items.length) return toast('请选中文件或目录')
      const paths = items.map((it) => it.fullPath || joinRemote(tab.sftpPath, it.name))
      toast('下载中…（大文件/多文件将自动打包，完成后解压）')
      const r = typeof api.sftpDownloadSmart === 'function'
        ? await api.sftpDownloadSmart(tab.sessionId, paths, { autoPack: true })
        : await api.sftpDownload(tab.sessionId, paths[0])
      const msg = r?.packed
        ? '已下载并解压'
        : r?.ok
          ? '已下载'
          : '下载: ' + (r?.error || '')
      toast(msg, !r?.ok)
    })
    on('sftpHist', 'click', () => {
      const tab = sessionTab()
      toast(tab?.sftpPath ? '当前路径: ' + tab.sftpPath : '未连接')
    })
    on('sftpBody', 'contextmenu', (e) => {
      const row = e.target.closest('tr[data-name]')
      if (!row) return
      e.preventDefault()
      $('sftpBody').querySelectorAll('tr').forEach((r) => r.classList.remove('selected'))
      row.classList.add('selected')
      state.selectedSftp = { name: row.dataset.name, isDir: row.dataset.dir === '1' }
      showSftpContext(e.clientX, e.clientY)
    })

    // events from main
    if (hasApi) {
      try {
        api.onData((msg) => {
          const sessionId = msg?.sessionId
          const data = msg?.data
          if (data == null || !sessionId) return
          writeActive(sessionId, typeof data === 'string' ? data : String(data))
        })
        api.onStatus((msg) => {
          const { sessionId, status, message } = msg || {}
          let tab = state.tabs.find((t) => t.sessionId === sessionId)
          // reconnect may keep same sessionId; still update matching tab
          if (!tab && status === 'reconnecting') {
            tab = state.tabs.find((t) => t.sessionId === sessionId || (t.hostId && message && String(message).includes(t.title)))
          }
          // 动画与 tab 解耦：tab 已关掉时也必须收遮罩，否则会“失败/关闭还一直转”
          if (status === 'closed' || status === 'error') {
            hideConnectOverlay(false, {
              reason: 'status-' + status,
              showFail: status === 'error',
              title: '连接失败',
            })
          } else if (status === 'connected') {
            // 仅当仍是当前连接会话时闪成功，避免关 tab 后迟到的 connected 误闪
            if (!tab || tab.status === 'connecting' || tab.status === 'reconnecting' || tab.status === 'connected') {
              hideConnectOverlay(true)
            } else {
              hideConnectOverlay(false, { reason: 'stale-connected' })
            }
          }
          if (tab) {
            tab.status = status
            if (message && (status === 'closed' || status === 'error' || status === 'reconnecting')) {
              writeActive(sessionId, `\r\n\x1b[90m[${status}] ${message}\x1b[0m\r\n`)
            }
            if (status === 'closed' || status === 'error') {
              updateSyncDot(false)
              updateBrandForSession()
              // Do not show reconnect banner on clean exit / manual close —
              // only when status becomes 'reconnecting' (below).
              const ban = $('reconnectBanner')
              if (ban && status === 'closed' && message === 'manual') ban.classList.remove('show')
              if (ban && status === 'closed' && message && /shell closed|exit/i.test(String(message))) {
                ban.classList.remove('show')
              }
            }
            if (status === 'connected') {
              updateSyncDot(true)
              updateBrandForSession()
              const ban = $('reconnectBanner')
              if (ban) ban.classList.remove('show')
              if (tab.id === state.activeTabId || sessionTab()?.sessionId === sessionId) {
                startMonitor()
              }
            }
            if (status === 'reconnecting') {
              const ban = $('reconnectBanner')
              if (ban) {
                ban.textContent = message || '重连中…'
                ban.classList.add('show')
              }
            }
            renderTabs()
            renderStatus()
          } else if (status === 'closed' || status === 'error' || status === 'connected') {
            updateBrandForSession()
            renderStatus()
          }
        })
        // CLI bridge → open / update terminal tabs when external agent connects
        if (typeof api.onCliEvent === 'function') {
          api.onCliEvent((msg) => {
            try {
              handleCliEvent(msg)
            } catch (e) {
              console.error('cli event', e)
            }
          })
        }
      } catch (e) {
        console.error('bind api events', e)
      }
    }

    window.addEventListener('keydown', (e) => {
      const meta = e.metaKey || e.ctrlKey
      if (meta && e.key.toLowerCase() === 'n') {
        e.preventDefault()
        openHostModal(null)
      }
      if (meta && e.key.toLowerCase() === 'w') {
        e.preventDefault()
        if (state.activeTabId) closeTab(state.activeTabId)
      }
      if (meta && e.key === 'Tab') {
        e.preventDefault()
        const tabs = state.tabs
        if (tabs.length < 2) return
        const idx = tabs.findIndex((t) => t.id === state.activeTabId)
        const next = e.shiftKey
          ? tabs[(idx - 1 + tabs.length) % tabs.length]
          : tabs[(idx + 1) % tabs.length]
        switchTab(next.id)
      }
    })
  }

  async function main() {
    const floatMeta = getFloatQuery()

    // 独立浮窗模式：只加载数据 + 渲染 floatRoot，不跑主界面
    if (floatMeta) {
      document.body.classList.add('float-window')
      if (!hasApi) {
        toast('未检测到 fsApi', true)
        return
      }
      try {
        await loadAll()
      } catch (e) {
        console.error('float loadAll', e)
      }
      try {
        await bootFloatWindow(floatMeta)
      } catch (e) {
        console.error('bootFloatWindow', e)
        toast('浮窗启动失败: ' + (e.message || e), true)
      }
      return
    }

    // CRITICAL: bind UI first — never block clicks on IPC load
    try {
      bindUi()
    } catch (e) {
      console.error('bindUi fatal', e)
      toast('UI 绑定失败: ' + e.message, true)
    }
    try {
      initTerm()
    } catch (e) {
      console.error('initTerm', e)
    }
    setBottom('files')
    refreshCliStatusBar()
    openQuickConnectTab()
    renderCmdBoard()
    renderStatus()
    bindFloatMessagesFromMain()

    if (!hasApi) {
      toast('未检测到 fsApi，请用 node start.js 启动', true)
      if ($('statusSsh2')) $('statusSsh2').textContent = '无 fsApi'
      return
    }

    try {
      await loadAll()
      renderConnMgr()
      renderQuickConnect()
      renderStatus()
    } catch (e) {
      console.error('loadAll', e)
      toast('加载配置失败: ' + (e.message || e), true)
    }

    try {
      const r = await api.sshReady()
      if ($('statusSsh2')) {
        $('statusSsh2').textContent = r?.ssh2 ? 'ssh2 OK' : 'ssh2 缺失'
      }
      if (!r?.ssh2) toast('ssh2 未加载: ' + (r?.error || ''), true)
      else if ($('statusHost')) $('statusHost').textContent = $('statusHost').textContent || 'SSH 未连接'
    } catch (e) {
      toast('sshReady 失败: ' + e.message, true)
    }
  }

  // expose for DevTools diagnosis
  window.__fpsDebug = {
    hasApi,
    state,
    connectHost,
    openHostModal,
    showModal,
    renderConnMgr,
  }

  main().catch((e) => {
    console.error(e)
    toast('启动失败: ' + e.message, true)
  })
})()
