/**
 * SessionManager / SshEngine — orchestrates native SSHSession stack
 * for Electron IPC. Not a bridge: owns lifecycle, persistence, multi-session map.
 */
'use strict'

const fs = require('fs')
const path = require('path')
let _log; try { _log = require('./logger') } catch (_) { _log = null }
function slog(level, tag, msg, extra) {
  try {
    if (!_log) return
    if (level === 'error') _log.error(tag, msg, extra)
    else if (level === 'warn') _log.warn(tag, msg, extra)
    else _log.info(tag, msg, extra)
  } catch (_) {}
}
const os = require('os')
const crypto = require('crypto')
const {
  SSHSession,
  SSHMultiplexer,
  isSsh2Available,
} = require('../../ssh/src/index.js')

function dataDir() {
  let base
  try {
    const { app } = require('electron')
    if (app && typeof app.getPath === 'function') {
      base = app.getPath('userData')
    }
  } catch (_) {}
  if (!base) {
    // Align with Electron app name PixShell even in CLI selftests
    if (process.platform === 'darwin') {
      base = path.join(os.homedir(), 'Library', 'Application Support', 'PixShell')
    } else if (process.platform === 'win32') {
      base = path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'PixShell')
    } else {
      base = path.join(os.homedir(), '.local', 'share', 'PixShell')
    }
  }
  const dir = path.join(base, 'pixshell')
  try {
    fs.mkdirSync(dir, { recursive: true })
  } catch (e) {
    // fallback writable location
    const fb = path.join(os.homedir(), '.pixshell-data', 'pixshell')
    fs.mkdirSync(fb, { recursive: true })
    return fb
  }
  return dir
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return fallback
  }
}

function writeJson(file, data) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true })
    // ensure dir is writable by current user when possible
    try {
      fs.chmodSync(path.dirname(file), 0o755)
    } catch (_) {}
    const tmp = file + '.tmp.' + process.pid
    // hosts.json may contain passwords — always 0o600
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2), { encoding: 'utf8', mode: 0o600 })
    fs.renameSync(tmp, file)
    try {
      fs.chmodSync(file, 0o600)
    } catch (_) {}
  } catch (e) {
    // last resort: try direct write
    try {
      fs.writeFileSync(file, JSON.stringify(data, null, 2), { encoding: 'utf8', mode: 0o600 })
      try {
        fs.chmodSync(file, 0o600)
      } catch (_) {}
    } catch (e2) {
      try {
        fs.rmSync(file + '.tmp.' + process.pid, { force: true })
      } catch (_) {}
      const err = new Error('写入配置失败: ' + (e2.message || e.message))
      err.code = e2.code || e.code
      err.path = file
      throw err
    }
  }
}


/**
 * Optional Electron safeStorage for host passwords.
 *
 * Default (compat): when safeStorage is unavailable, falls back to plaintext
 * (logged once as warn). Force mode refuses plaintext persistence:
 *   - env ELECTRON_SAFE_STORAGE=1  → always force
 *   - settings.requireSafeStorage: true → force when saveHosts reads settings
 *
 * encryptSecret(plain, opts?):
 *   opts.force / opts.requireSafeStorage → throw if cannot encrypt
 *   returns plaintext only when force is off and encryption unavailable
 */
let _plainWarnOnce = false
function isSafeStorageForceEnv() {
  const v = String(process.env.ELECTRON_SAFE_STORAGE || '').trim().toLowerCase()
  return v === '1' || v === 'true' || v === 'yes' || v === 'on'
}

function isEncryptionAvailable() {
  try {
    const { safeStorage } = require('electron')
    return !!(
      safeStorage &&
      typeof safeStorage.isEncryptionAvailable === 'function' &&
      safeStorage.isEncryptionAvailable() &&
      typeof safeStorage.encryptString === 'function'
    )
  } catch (_) {
    return false
  }
}

function encryptSecret(plain, opts) {
  if (plain == null || plain === '') return plain
  const s = String(plain)
  if (s.startsWith('enc:v1:')) return s
  const force =
    !!(opts && (opts.force || opts.requireSafeStorage)) || isSafeStorageForceEnv()
  try {
    const { safeStorage } = require('electron')
    if (
      safeStorage &&
      typeof safeStorage.isEncryptionAvailable === 'function' &&
      safeStorage.isEncryptionAvailable()
    ) {
      const buf = safeStorage.encryptString(s)
      return 'enc:v1:' + Buffer.from(buf).toString('base64')
    }
  } catch (_) {}
  if (force) {
    const err = new Error(
      'safeStorage unavailable: refuse to persist password (ELECTRON_SAFE_STORAGE / requireSafeStorage)',
    )
    err.code = 'SAFE_STORAGE_REQUIRED'
    throw err
  }
  if (!_plainWarnOnce) {
    _plainWarnOnce = true
    console.warn(
      '[pixshell] safeStorage unavailable — host passwords will be stored in plaintext in hosts.json (set ELECTRON_SAFE_STORAGE=1 or settings.requireSafeStorage to refuse)',
    )
  }
  return s
}

function decryptSecret(stored) {
  if (stored == null || stored === '') return ''
  const s = String(stored)
  if (!s.startsWith('enc:v1:')) return s
  try {
    const { safeStorage } = require('electron')
    if (safeStorage && typeof safeStorage.decryptString === 'function') {
      const buf = Buffer.from(s.slice(7), 'base64')
      return safeStorage.decryptString(buf)
    }
  } catch (e) {
    console.warn('[pixshell] decryptSecret failed:', e && e.message)
    return ''
  }
  return ''
}

function newId(prefix) {
  return prefix + '_' + Date.now().toString(36) + crypto.randomBytes(3).toString('hex')
}

/**
 * Engine entry held per UI sessionId (one shell tab).
 * Control connection may be shared via multiplexer when reuseSession=true.
 */
class SshEngine {
  constructor() {
    /** @type {Map<string, {
     *   id: string,
     *   session: SSHSession,
     *   shell: import('../../ssh/src/session/shell-session').ShellSession|null,
     *   profile: object,
     *   manualClose: boolean,
     *   hostId?: string,
     *   execChain?: Promise<any>,
     *   monBusy?: boolean,
     *   monFail?: number,
     * }>} */
    this.sessions = new Map()
    this.payloads = new Map()
    this.reconnectTimers = new Map()
    this.multiplexer = new SSHMultiplexer()
    this.onData = null
    this.onStatus = null
    this.autoReconnect = true
    this.maxReconnect = 8
    /** ms online before clearing reconnect attempt budget (anti-flap) */
    this.stableMs = 15000
    this.stableTimers = new Map()
    /** cached monitor script b64 */
    this._monB64 = null
    this._monB64Lite = null
    this._sysB64 = null
  }

  ready() {
    const ok = isSsh2Available()
    return {
      ok: true,
      ssh2: ok,
      ssh2Path: ok ? 'ssh2' : null,
      error: ok ? null : SSHSession.loadError(),
      sessions: this.sessions.size,
      architecture: 'native-ssh2',
    }
  }

  setDataHandler(fn) {
    this.onData = fn
  }
  setStatusHandler(fn) {
    this.onStatus = fn
  }

  _emitData(id, buf) {
    if (this.onData) this.onData(id, Buffer.isBuffer(buf) ? buf : Buffer.from(buf))
  }
  _emitStatus(id, status, message) {
    if (this.onStatus) this.onStatus(id, status, message || '')
  }

  // ── persistence ────────────────────────────────────────
  loadHosts() {
    const file = path.join(dataDir(), 'hosts.json')
    let hosts = readJson(file, [])
    if (!Array.isArray(hosts)) hosts = []
    if (hosts.length === 0) {
      try {
        const imported = this.autoImportLocalHostTree()
        if (imported.length) {
          hosts = imported
          writeJson(file, hosts)
        }
      } catch (e) {
        // ignore import errors
      }
    }
    // decrypt passwords for in-memory use (safeStorage when available)
    return hosts.map((h) => {
      if (!h || h.password == null) return h
      const plain = decryptSecret(h.password)
      return plain === h.password ? h : { ...h, password: plain }
    })
  }

  /** One-shot seed from local connection-tree sample paths */
  /** Seed hosts from a local connection tree if present. */
  autoImportLocalHostTree() {
    try {
      const { importHostsDir } = require('../../../scripts/import-hosts.js')
      const candidates = []
      if (process.env.PIXSHELL_IMPORT_CONN_DIR) candidates.push(process.env.PIXSHELL_IMPORT_CONN_DIR)
      // Discover: ~/Library/*/conn containing *_connect_config.json
      try {
        const lib = path.join(os.homedir(), 'Library')
        for (const name of fs.readdirSync(lib)) {
          const c = path.join(lib, name, 'conn')
          if (fs.existsSync(c)) candidates.push(c)
        }
      } catch (_) {}
      // Optional mounts via env list
      if (process.env.PIXSHELL_IMPORT_CONN_PATHS) {
        for (const c of String(process.env.PIXSHELL_IMPORT_CONN_PATHS).split(path.delimiter)) {
          if (c) candidates.push(c)
        }
      }
      for (const c of candidates) {
        if (!c || !fs.existsSync(c)) continue
        let ok = false
        try {
          for (const n of fs.readdirSync(c)) {
            if (String(n).endsWith('_connect_config.json')) {
              ok = true
              break
            }
            try {
              if (fs.existsSync(path.join(c, n, 'folder.json'))) {
                ok = true
                break
              }
            } catch (_) {}
          }
        } catch (_) {}
        if (!ok) continue
        const hosts = importHostsDir(c) || []
        if (hosts.length) return hosts
      }
    } catch (_) {}
    return []
  }

  saveHosts(hosts) {
    // 允许保存 password（本机 userData，优先 Electron safeStorage 加密）；privateKey 仍不落盘。
    // Force mode (ELECTRON_SAFE_STORAGE=1 or settings.requireSafeStorage): when encryption
    // is unavailable, strip password fields instead of writing plaintext; return warning.
    let settings = {}
    try {
      settings = this.loadSettings() || {}
    } catch (_) {
      settings = {}
    }
    const force =
      isSafeStorageForceEnv() || settings.requireSafeStorage === true
    let strippedPasswords = 0
    let warning = null

    const clean = (hosts || []).map((h) => {
      const { privateKey, ...rest } = h
      const out = { ...rest }
      if (h.rememberPassword === false) {
        delete out.password
        return out
      }
      if (h.password != null && String(h.password).length) {
        try {
          out.password = encryptSecret(String(h.password), {
            force,
            requireSafeStorage: force,
          })
        } catch (e) {
          // Force mode + no encryption: strip password, keep host metadata
          delete out.password
          strippedPasswords += 1
          warning =
            (e && e.message) ||
            'safeStorage unavailable: passwords not persisted'
        }
      }
      return out
    })
    writeJson(path.join(dataDir(), 'hosts.json'), clean)
    const result = { ok: true, count: clean.length }
    if (strippedPasswords > 0) {
      result.strippedPasswords = strippedPasswords
      result.warning =
        warning ||
        `safeStorage unavailable: stripped ${strippedPasswords} password(s) (requireSafeStorage / ELECTRON_SAFE_STORAGE)`
    }
    return result
  }
  loadSettings() {
    const defaults = {
      fontSize: 13,
      fontFamily: 'JetBrains Mono, Cascadia Code, Source Code Pro, Menlo, monospace',
      colorScheme: 'dracula',
      cursorStyle: 'block',
      cursorBlink: true,
      termType: 'xterm-256color',
      editorSyntaxHl: true,
      termLiveHighlight: true,
      drawBoldTextInBrightColors: true,
      minimumContrastRatio: 4.5,
      theme: 'dark',
      syncDirWithSftp: false,
      autoReconnect: true,
      monitorIntervalSec: 5,
      reuseSession: false,
      // Local AI-agent bridge: opt-in (was true — open port by default is a risk)
      externalCliEnabled: false,
      externalCliPort: 8766,
      /**
       * When true (or ELECTRON_SAFE_STORAGE=1), refuse to persist host passwords
       * if Electron safeStorage encryption is unavailable (strip + warning).
       * Default false keeps plaintext fallback for compatibility.
       */
      requireSafeStorage: false,
      proxyList: [],
      quickCommands: [],
      recentHosts: [],
      layout: { sidebarWidth: 200, bottomHeight: 200 },
      commandInput: { cleanAfterSend: true, appendCr: true },
    }
    return { ...defaults, ...readJson(path.join(dataDir(), 'settings.json'), {}) }
  }
  saveSettings(settings) {
    try {
      writeJson(path.join(dataDir(), 'settings.json'), settings || {})
      if (settings && typeof settings.autoReconnect === 'boolean') {
        this.autoReconnect = settings.autoReconnect
      }
      return { ok: true }
    } catch (e) {
      return { ok: false, error: e.message || String(e), path: path.join(dataDir(), 'settings.json') }
    }
  }
  loadQuick() {
    return readJson(path.join(dataDir(), 'quick-commands.json'), [])
  }
  saveQuick(list) {
    writeJson(path.join(dataDir(), 'quick-commands.json'), list || [])
    return { ok: true }
  }
  pushRecent(hostId) {
    if (!hostId) return
    try {
      const s = this.loadSettings()
      s.recentHosts = [hostId, ...(s.recentHosts || []).filter((x) => x !== hostId)].slice(0, 30)
      this.saveSettings(s)
    } catch (e) {
      // never fail SSH connect because recent list / settings cannot be written
      console.warn('[pixshell] pushRecent failed:', e && e.message)
    }
  }

  // ── connect (orchestrate SSHSession) ───────────────────
  async connect(payload) {
    payload = payload || {}
    if (!isSsh2Available()) {
      return { ok: false, error: SSHSession.loadError() || 'ssh2 未加载' }
    }
    const host = String(payload.host || '').trim()
    const user = String(payload.username || payload.user || 'root').trim()
    const port = Number(payload.port) || 22
    if (!host) return { ok: false, error: '主机地址为空' }

    const password =
      payload.password != null && String(payload.password).length > 0
        ? String(payload.password)
        : undefined
    const hasKey = !!(
      payload.privateKey ||
      payload.privateKeyPath ||
      (payload.privateKeys && payload.privateKeys.length)
    )
    const allowAgent =
      payload.auth === 'agent' ||
      !!payload.agentForward ||
      (!!process.env.SSH_AUTH_SOCK && payload.useAgent === true)
    // Fail loud — never silent / never "ok without shell"
    if (!password && !hasKey && !allowAgent) {
      return {
        ok: false,
        error: '未提供密码或私钥（连接对话框填写密码后点「保存并连接」）',
      }
    }
    if (!user) return { ok: false, error: '用户名为空' }

    const sessionId = payload.sessionId || newId('ssh')
    this._clearReconnect(sessionId)
    // Drop stale session with same id
    if (this.sessions.has(sessionId)) {
      try {
        this.disconnect(sessionId)
      } catch (_) {}
    }

    const profile = {
      id: payload.hostId || null,
      host,
      port,
      user,
      username: user,
      auth: payload.auth || null,
      password,
      privateKey: payload.privateKey,
      privateKeys: payload.privateKeys || (payload.privateKeyPath ? [payload.privateKeyPath] : []),
      privateKeyPath: payload.privateKeyPath,
      passphrase: payload.passphrase,
      // Dropbear/OpenWrt: shorter interval, more misses allowed
      keepaliveInterval: payload.keepaliveInterval ?? 10000,
      keepaliveCountMax: payload.keepaliveCountMax ?? 10,
      readyTimeout: payload.readyTimeout ?? 30000,
      proxy: payload.proxy || null,
      agentForward: !!payload.agentForward,
      skipBanner: !!payload.skipBanner,
      cols: payload.cols || 120,
      rows: payload.rows || 30,
      term: payload.term || 'xterm-256color',
    }

    this._emitStatus(sessionId, 'connecting', `${user}@${host}:${port}`)

    let session = null
    let createdSession = false
    let settings = { reuseSession: false }
    try {
      settings = this.loadSettings() || { reuseSession: false }
      if (settings.reuseSession) {
        session = this.multiplexer.get(profile)
        if (session && (!session.authenticated || session.destroyed)) {
          this.multiplexer.remove(session)
          session = null
        }
      }
      if (!session) {
        session = new SSHSession(profile)
        createdSession = true
        session.on('serviceMessage', (msg) => {
          this._emitData(sessionId, Buffer.from(`\r\n\x1b[90m${msg}\x1b[0m\r\n`))
        })
        await session.start()
        if (!session.authenticated || !session.conn) {
          throw new Error('认证未完成（无 ready）')
        }
        // Only add to multiplexer after auth succeeds
        if (settings.reuseSession) this.multiplexer.add(session)
      }

      const shell = await session.openShell({
        cols: profile.cols,
        rows: profile.rows,
        term: profile.term,
      })
      if (!shell) throw new Error('shell 通道未建立')

      shell.on('data', (buf) => this._emitData(sessionId, buf))
      shell.on('close', () => {
        // Clean logout (`exit` / remote shell end) while control conn still up:
        // do NOT auto-reconnect — user intentionally ended the shell.
        const entry = this.sessions.get(sessionId)
        const stillAuth = !!(entry && entry.session && entry.session.authenticated && entry.session.conn)
        if (stillAuth) {
          this._onShellEndedCleanly(sessionId, 'shell closed')
        } else {
          this._onSessionTransportLost(sessionId, 'shell closed')
        }
      })
      shell.on('error', (err) => {
        this._emitData(
          sessionId,
          Buffer.from(`\r\n\x1b[31m[shell] ${(err && err.message) || err}\x1b[0m\r\n`),
        )
      })
      // control connection drop — bind once per UI sessionId; off on disconnect
      const onCtrlClose = () => this._onSessionTransportLost(sessionId, 'connection closed')
      const onCtrlEnd = () => this._onSessionTransportLost(sessionId, 'connection ended')
      session.on('close', onCtrlClose)
      session.on('end', onCtrlEnd)
      // stash so disconnect can remove listeners (reuse multi-tab)
      session._pixHandlers = session._pixHandlers || new Map()
      session._pixHandlers.set(sessionId, { onCtrlClose, onCtrlEnd })

      this.sessions.set(sessionId, {
        id: sessionId,
        session,
        shell,
        profile,
        manualClose: false,
        hostId: payload.hostId,
        execChain: Promise.resolve(),
        monBusy: false,
        monFail: 0,
      })
      // Anti-flap: keep _attempt until stableMs online; brief success must not reset budget.
      const incomingAttempt = Number(payload._attempt || 0)
      this.payloads.set(sessionId, {
        ...payload,
        sessionId,
        host,
        port,
        username: user,
        password,
        _attempt: incomingAttempt,
        _connectedAt: Date.now(),
      })
      this._armStableAttemptReset(sessionId)

      // warm sftp later — routers often MaxSessions=2~3; shell+sftp+exec at once kills conn
      setTimeout(() => {
        const e = this.sessions.get(sessionId)
        if (!e || e.manualClose) return
        e.session.openSFTP().catch(() => {
          /* silent — open on first file panel use */
        })
      }, 1500)

      this._emitStatus(sessionId, 'connected', `${user}@${host}:${port}`)
      if (payload.hostId) this.pushRecent(payload.hostId)
      return { ok: true, sessionId, host, port, username: user }
    } catch (e) {
      const msg = (e && e.message) || String(e)
      this._emitStatus(sessionId, 'error', msg)
      // Tear down partial connect: destroy newly created control conn; unref reused.
      try {
        if (session) {
          if (createdSession) {
            try {
              session.destroy()
            } catch (_) {}
            this.multiplexer.remove(session)
          } else {
            // shell open may have ref()'d — balance it
            try {
              session.unref()
            } catch (_) {}
          }
        }
      } catch (_) {}
      this.sessions.delete(sessionId)
      slog('error', 'connect', 'fail', { sessionId, host, error: msg })
      return { ok: false, sessionId, error: msg }
    }
  }

  _detachSessionHandlers(session, sessionId) {
    if (!session || !session._pixHandlers) return
    const h = session._pixHandlers.get(sessionId)
    if (!h) return
    try {
      session.off('close', h.onCtrlClose)
    } catch (_) {}
    try {
      session.off('end', h.onCtrlEnd)
    } catch (_) {}
    session._pixHandlers.delete(sessionId)
  }

  /**
   * After unref on a reused control connection: destroy when no shells remain.
   */
  _releaseControlIfIdle(session) {
    if (!session || session.destroyed) return
    const refs = typeof session._refCount === 'number' ? session._refCount : 0
    const liveShells = session.shellSessions ? session.shellSessions.size : 0
    if (refs > 0 || liveShells > 0) return
    try {
      session.destroy()
    } catch (_) {}
    this.multiplexer.remove(session)
  }

  disconnect(sessionId) {
    this._clearReconnect(sessionId)
    const entry = this.sessions.get(sessionId)
    if (entry) entry.manualClose = true
    if (!entry) {
      this.payloads.delete(sessionId)
      return { ok: true }
    }
    try {
      entry.shell?.kill()
    } catch (_) {}
    this._detachSessionHandlers(entry.session, sessionId)
    // If not reusing, destroy control connection
    const settings = this.loadSettings()
    if (!settings.reuseSession) {
      try {
        entry.session?.destroy()
      } catch (_) {}
      this.multiplexer.remove(entry.session)
    } else {
      try {
        entry.session?.unref()
      } catch (_) {}
      this._releaseControlIfIdle(entry.session)
    }
    this.sessions.delete(sessionId)
    this.payloads.delete(sessionId)
    this._emitStatus(sessionId, 'closed', 'manual')
    return { ok: true }
  }

  async reconnect(sessionId) {
    const payload = this.payloads.get(sessionId)
    if (!payload) return { ok: false, error: '无保存的连接信息，请重新连接' }
    // Snapshot before disconnect deletes payloads; keep the SAME sessionId so
    // the UI tab / CLI screen buffer stay bound (matches auto-reconnect).
    const snap = { ...payload, sessionId, _attempt: 0 }
    this.disconnect(sessionId)
    return this.connect(snap)
  }

  setAutoReconnect(enabled) {
    this.autoReconnect = !!enabled
    return { ok: true, autoReconnect: this.autoReconnect }
  }

  _clearReconnect(sessionId) {
    const t = this.reconnectTimers.get(sessionId)
    if (t) clearTimeout(t)
    this.reconnectTimers.delete(sessionId)
    this._clearStable(sessionId)
  }

  _clearStable(sessionId) {
    const t = this.stableTimers.get(sessionId)
    if (t) clearTimeout(t)
    this.stableTimers.delete(sessionId)
  }

  /**
   * Only reset reconnect attempt budget after the session stays up for stableMs.
   * Prevents flap (up→down in <stableMs) from never exhausting maxReconnect.
   */
  _armStableAttemptReset(sessionId) {
    this._clearStable(sessionId)
    const payload = this.payloads.get(sessionId)
    if (!payload) return
    const attempt = Number(payload._attempt || 0)
    if (!attempt) return
    const ms = Number(this.stableMs) > 0 ? Number(this.stableMs) : 15000
    const timer = setTimeout(() => {
      this.stableTimers.delete(sessionId)
      const p = this.payloads.get(sessionId)
      if (!p || !this.sessions.has(sessionId)) return
      p._attempt = 0
      try {
        // optional trail — ignore if slog not in scope
        if (typeof slog === 'function') slog('info', 'reconnect', 'stable: attempt budget cleared', { sessionId, afterMs: ms })
      } catch (_) {}
    }, ms)
    this.stableTimers.set(sessionId, timer)
  }

  /**
   * Interactive shell ended while the control connection is still up
   * (user typed `exit`, remote logout). Close this UI session without auto-reconnect.
   */
  _onShellEndedCleanly(sessionId, reason) {
    const entry = this.sessions.get(sessionId)
    if (!entry) return
    if (entry._lostHandled) return
    entry._lostHandled = true
    entry.manualClose = true
    this._clearReconnect(sessionId)
    try {
      entry.shell?.kill?.()
    } catch (_) {}
    this._detachSessionHandlers(entry.session, sessionId)
    // Keep control connection if reuseSession; otherwise tear down fully.
    let reuse = false
    try {
      reuse = !!(this.loadSettings() || {}).reuseSession
    } catch (_) {}
    if (!reuse) {
      try {
        entry.session?.destroy?.()
      } catch (_) {}
      this.multiplexer.remove(entry.session)
    } else {
      try {
        entry.session?.unref?.()
      } catch (_) {}
      this._releaseControlIfIdle(entry.session)
    }
    this.sessions.delete(sessionId)
    this.payloads.delete(sessionId)
    this._emitStatus(sessionId, 'closed', reason || 'shell closed')
  }

  /**
   * Shell or control connection died. Reconnect unless user closed manually.
   * Dedupes multiple close events from shell + session.
   */
  _onSessionTransportLost(sessionId, reason) {
    const entry = this.sessions.get(sessionId)
    if (!entry) return
    if (entry._lostHandled) return
    entry._lostHandled = true
    const manual = !!entry.manualClose
    try {
      entry.shell?.kill?.()
    } catch (_) {}
    this._detachSessionHandlers(entry.session, sessionId)
    try {
      if (!manual) entry.session?.destroy?.()
    } catch (_) {}
    try {
      this.multiplexer.remove(entry.session)
    } catch (_) {}
    this.sessions.delete(sessionId)
    this._emitStatus(sessionId, 'closed', reason || 'closed')
    if (this.autoReconnect && !manual) {
      this._scheduleReconnect(sessionId)
    } else {
      this.payloads.delete(sessionId)
    }
  }

  _scheduleReconnect(sessionId) {
    this._clearReconnect(sessionId)
    const payload = this.payloads.get(sessionId)
    if (!payload) return
    let attempt = Number(payload._attempt || 0) + 1
    if (attempt > this.maxReconnect) {
      this._emitStatus(sessionId, 'error', '重连失败（已达最大次数）— 请手动重新连接')
      this.payloads.delete(sessionId)
      return
    }
    payload._attempt = attempt
    // P1 intentional backoff: 1s,2s,4s,8s,16s… cap 30s (Math.min(30, 2**(n-1)) seconds)
    const delayMs = Math.min(30000, 1000 * Math.pow(2, attempt - 1))
    this._emitStatus(sessionId, 'reconnecting', `第 ${attempt}/${this.maxReconnect} 次，${Math.round(delayMs / 1000)}s 后…`)
    const timer = setTimeout(() => {
      // keep same sessionId so UI tab stays bound
      this.connect({ ...payload, sessionId, _attempt: attempt })
        .then((r) => {
          if (!r.ok) {
            // connect failed — payload still there; schedule again under same logical id
            this._scheduleReconnect(sessionId)
          }
        })
        .catch(() => this._scheduleReconnect(sessionId))
    }, delayMs)
    this.reconnectTimers.set(sessionId, timer)
  }

  write(sessionId, data) {
    const e = this.sessions.get(sessionId)
    if (!e?.shell) return { ok: false, error: '会话不存在或未就绪' }
    if (e.shell.open === false) return { ok: false, error: 'shell 已关闭' }
    try {
      const ok = e.shell.write(data)
      return ok ? { ok: true } : { ok: false, error: 'write failed' }
    } catch (err) {
      return { ok: false, error: err.message || String(err) }
    }
  }

  writeBinary(sessionId, base64) {
    return this.write(sessionId, Buffer.from(String(base64 || ''), 'base64'))
  }

  resize(sessionId, cols, rows) {
    const e = this.sessions.get(sessionId)
    if (!e?.shell) return { ok: false, error: '会话不存在或未就绪' }
    try {
      e.shell.resize(cols, rows)
      return { ok: true }
    } catch (err) {
      return { ok: false, error: err.message || String(err) }
    }
  }

  /**
   * Serialize exec per session so dropbear MaxSessions isn't exhausted by
   * overlapping monitor + tools + accidental double ticks.
   */
  async exec(sessionId, command, opts = {}) {
    const e = this.sessions.get(sessionId)
    if (!e?.session) return { ok: false, error: '会话不存在', stdout: '', stderr: '' }
    if (!e.session.authenticated) {
      return { ok: false, error: '会话未认证', stdout: '', stderr: '' }
    }
    const timeoutMs = opts.timeoutMs
    const run = async () => {
      try {
        return await e.session.exec(command, { timeoutMs })
      } catch (err) {
        return { ok: false, error: err.message || String(err), stdout: '', stderr: '' }
      }
    }
    // Serialize per session. Capture THIS call's promise — never await the
    // shared e.execChain tip (concurrent callers would all wait for the last one
    // and return the wrong result).
    const prev = e.execChain || Promise.resolve()
    const mine = prev.catch(() => {}).then(() => run())
    e.execChain = mine
    try {
      return (await mine) || { ok: false, error: 'exec empty', stdout: '', stderr: '' }
    } catch (err) {
      return { ok: false, error: err.message || String(err), stdout: '', stderr: '' }
    }
  }

  async _sftp(sessionId) {
    const e = this.sessions.get(sessionId)
    if (!e?.session) return { error: '会话不存在' }
    try {
      const sftp = await e.session.openSFTP()
      return { sftp, entry: e }
    } catch (err) {
      return { error: err.message }
    }
  }

  /**
   * WinSCP-style remote directory listing via pure SFTP (never shell ls/cd).
   * Default path is absolute "/" so UI always browses the remote FS root.
   */
  async sftpList(sessionId, remotePath) {
    const r = await this._sftp(sessionId)
    if (r.error) return { ok: false, error: r.error }
    let p = remotePath == null || remotePath === '' || remotePath === '.' ? '/' : String(remotePath)
    // normalize //foo
    p = p.replace(/\/{2,}/g, '/')
    if (!p.startsWith('/')) p = '/' + p
    try {
      let real = p
      try {
        real = await r.sftp.realpath(p)
      } catch (_) {
        real = p
      }
      const entries = await r.sftp.readdir(real)
      // stable sort dirs first happens on renderer; keep raw here
      return {
        ok: true,
        path: real,
        entries: (entries || []).map((x) => ({
          name: x.name,
          fullPath: x.fullPath || (real === '/' ? '/' + x.name : real.replace(/\/+$/, '') + '/' + x.name),
          isDir: !!(x.isDirectory || x.isDir),
          isSymlink: !!x.isSymlink,
          size: Number(x.size) || 0,
          modifyTime: Number(x.modifyTime) || 0,
          rights: x.rights || '',
          owner: x.owner,
          group: x.group,
          mode: x.mode,
        })),
      }
    } catch (err) {
      return { ok: false, error: err.message || String(err), path: p }
    }
  }

  async sftpRead(sessionId, remotePath) {
    const r = await this._sftp(sessionId)
    if (r.error) return { ok: false, error: r.error }
    // Hard cap: whole-file base64 into renderer will OOM on big logs/binaries.
    const MAX_BYTES = 8 * 1024 * 1024
    try {
      try {
        const st = await r.sftp.stat(remotePath)
        if (st && Number(st.size) > MAX_BYTES) {
          return {
            ok: false,
            error: `文件过大 (${Math.round(Number(st.size) / 1048576)} MB)，编辑器上限 8 MB`,
            size: Number(st.size) || 0,
          }
        }
      } catch (_) {
        /* stat optional — still enforce after read */
      }
      const data = await r.sftp.readFile(remotePath)
      if (data.length > MAX_BYTES) {
        return {
          ok: false,
          error: `文件过大 (${Math.round(data.length / 1048576)} MB)，编辑器上限 8 MB`,
          size: data.length,
        }
      }
      return { ok: true, dataBase64: data.toString('base64'), size: data.length }
    } catch (err) {
      return { ok: false, error: err.message }
    }
  }

  async sftpWrite(sessionId, remotePath, dataBuf) {
    const r = await this._sftp(sessionId)
    if (r.error) return { ok: false, error: r.error }
    try {
      await r.sftp.writeFile(remotePath, dataBuf)
      return { ok: true }
    } catch (err) {
      return { ok: false, error: err.message }
    }
  }

  async sftpMkdir(sessionId, remotePath) {
    const r = await this._sftp(sessionId)
    if (r.error) return { ok: false, error: r.error }
    try {
      await r.sftp.mkdir(remotePath)
      return { ok: true }
    } catch (err) {
      return { ok: false, error: err.message }
    }
  }

  async sftpUnlink(sessionId, remotePath, isDir) {
    const r = await this._sftp(sessionId)
    if (r.error) return { ok: false, error: r.error }
    try {
      if (isDir) await r.sftp.rmdir(remotePath)
      else await r.sftp.unlink(remotePath)
      return { ok: true }
    } catch (err) {
      return { ok: false, error: err.message }
    }
  }

  async sftpRename(sessionId, from, to) {
    const r = await this._sftp(sessionId)
    if (r.error) return { ok: false, error: r.error }
    try {
      await r.sftp.rename(from, to)
      return { ok: true }
    } catch (err) {
      return { ok: false, error: err.message }
    }
  }

  async sftpDownloadFile(sessionId, remotePath, localPath) {
    const r = await this._sftp(sessionId)
    if (r.error) return { ok: false, error: r.error }
    try {
      await r.sftp.fastGet(remotePath, localPath)
      return { ok: true, localPath }
    } catch (err) {
      return { ok: false, error: err.message }
    }
  }

  async sftpUploadFile(sessionId, localPath, remotePath) {
    const r = await this._sftp(sessionId)
    if (r.error) return { ok: false, error: r.error }
    try {
      await r.sftp.fastPut(localPath, remotePath)
      return { ok: true, remotePath }
    } catch (err) {
      return { ok: false, error: err.message }
    }
  }

  /**
   * BusyBox/OpenWrt-safe remote metrics.
   * Full script: remote-monitor.sh (base64 | sh).
   * Lite path: tiny inline sh — no sleep, no ping — for dropbear / MaxSessions-limited hosts.
   * Never overlaps: monBusy + per-session execChain.
   *
   * CRITICAL: collectMonitor always builds via `_monitorInlineScript` (lite path + full
   * fallback). Method MUST exist — missing it throws while assembling cmd and blanks the
   * entire sidebar (load/cpu/mem/disk/proc).
   */
  _monitorInlineScript(_lite) {
    // no sleep / no ping / short proc — finish in <1s on OpenWrt; no base64 dependency
    // Keep overlay root disks (OpenWrt); skip only pure tmp/dev/sys noise.
    return [
      'echo ===mon===',
      'L=`cat /proc/loadavg 2>/dev/null`; set -- $L; echo load=$1,$2,$3',
      'U=`cat /proc/uptime 2>/dev/null|cut -d. -f1`',
      'if [ -n "$U" ]; then d=`expr $U / 86400 2>/dev/null||echo 0`; h=`expr $U % 86400 / 3600 2>/dev/null||echo 0`; m=`expr $U % 3600 / 60 2>/dev/null||echo 0`; echo uptime=${d}d${h}h${m}m; else echo uptime=-; fi',
      // since-boot average is OK for lite (avoid sleep that blocks dropbear channel)
      "CPU=`awk '/^cpu /{i=$5+0;if(NF>=6)i+=$6;t=0;for(n=2;n<=NF;n++)t+=$n+0;if(t>0)printf \"%.1f\",100-i*100/t;else print 0}' /proc/stat 2>/dev/null`",
      'echo cpu=${CPU:-0}',
      "awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} END{if(t>0){if(a+0==0)a=f+b+c;u=t-a;if(u<0)u=0;printf \"mem=%d %d %d\\n\",int(u*100/t),int(u/1024),int(t/1024)}else print \"mem=0 0 0\"}' /proc/meminfo 2>/dev/null",
      "awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{if(t>0){u=t-f;printf \"swap=%d %d %d\\n\",int(u*100/t),int(u/1024),int(t/1024)}else print \"swap=0 0 0\"}' /proc/meminfo 2>/dev/null",
      "IP=`ip -4 -o addr show scope global 2>/dev/null|awk '{print $4;exit}'|cut -d/ -f1`",
      'if [ -z "$IP" ]; then IP=`ifconfig 2>/dev/null|awk \'/inet /{print $2}\'|sed \'s/addr://\'|awk \'$0!~/^127\\./{print;exit}\'`; fi',
      'echo ip=${IP:-}',
      "awk -F'[: ]+' 'NR>2{gsub(/:/,\"\",$1);if($1!=\"\"&&$1!=\"lo\"&&$1!~/^lo/){print \"net=\"$1\" \"$2\" \"$10;exit}}' /proc/net/dev 2>/dev/null",
      // KEEP overlay; skip tmpfs/devtmpfs/proc/sys only
      "df -h 2>/dev/null|awk 'NR>1{fs=$1; if(fs~/^(tmpfs|devtmpfs|devfs|efivarfs|proc|sysfs|cgroup|autofs|shm)$/) next; if(NF>=6){mnt=$6; for(i=7;i<=NF;i++)mnt=mnt\" \"$i; if(mnt~/^\\/dev$|^\\/run|^\\/sys|^\\/proc/) next; print \"disk=\"mnt\"\\t\"$2\"\\t\"$3\"\\t\"$4\"\\t\"$5}}'|head -n 8",
      // BusyBox ps has no -eo; capture GNU first — empty pipe still exits 0 so use [ -n ]
      'OUT=`ps -eo rss,pcpu,args --sort=-pcpu 2>/dev/null | awk \'NR>1{rss=$1+0;cpu=$2;cmd="";for(i=3;i<=NF;i++)cmd=cmd(i==3?"":" ")$i; m=(rss>=1024)?sprintf("%.1fM",rss/1024):sprintf("%dK",rss); printf "proc=%s\\t%s\\t%s\\n",m,cpu,cmd}\' | head -n 8`',
      'if [ -n "$OUT" ]; then echo "$OUT"; else ps w 2>/dev/null | awk \'NR>1{cmd="";for(i=5;i<=NF;i++)cmd=cmd(i==5?"":" ")$i;printf "proc=-\\t-\\t%s\\n",cmd}\' | head -n 8; fi',
      'echo ping_ms=',
      'echo ping_target=',
      'echo ===end===',
    ].join('\n')
  }

  _monitorScriptB64(lite) {
    if (lite) {
      if (this._monB64Lite) return this._monB64Lite
      this._monB64Lite = Buffer.from(this._monitorInlineScript(true), 'utf8').toString('base64')
      return this._monB64Lite
    }
    if (this._monB64) return this._monB64
    const scriptPath = path.join(__dirname, 'remote-monitor.sh')
    let remoteScript = fs.readFileSync(scriptPath, 'utf8')
    remoteScript = remoteScript.replace(/^#!.*\n/, '')
    this._monB64 = Buffer.from(remoteScript, 'utf8').toString('base64')
    return this._monB64
  }

  _parseMonitorText(text) {
    const data = {
      load: '',
      cpu: '0',
      mem: '0 0 0',
      swap: '0 0 0',
      uptime: '-',
      ip: '',
      netdev: '',
      disks: '',
      procs: '',
      pingMs: '',
      pingTarget: '',
      raw: text,
    }
    const diskLines = []
    const procLines = []
    for (const line of String(text || '').split(/\r?\n/)) {
      const s = line.trim()
      if (!s || s.indexOf('===') === 0) continue
      const eq = s.indexOf('=')
      if (eq < 0) continue
      const k = s.slice(0, eq)
      const v = s.slice(eq + 1)
      if (k === 'load') data.load = v
      else if (k === 'cpu') data.cpu = v
      else if (k === 'mem') data.mem = v
      else if (k === 'swap') data.swap = v
      else if (k === 'uptime') data.uptime = v
      else if (k === 'ip') data.ip = v
      else if (k === 'net') data.netdev = v
      else if (k === 'disk') diskLines.push(v)
      else if (k === 'proc') procLines.push(v)
      else if (k === 'ping_ms') data.pingMs = v
      else if (k === 'ping_target') data.pingTarget = v
    }
    data.disks = diskLines.join('\n')
    data.procs = procLines.slice(0, 10).join('\n')
    return data
  }

  async collectMonitor(sessionId) {
    const e = this.sessions.get(sessionId)
    if (!e?.session) return { ok: false, error: '会话不存在', data: {} }
    // skip if previous tick still running — never pile exec channels on dropbear
    if (e.monBusy) {
      return { ok: true, skipped: true, data: e._lastMon || {} }
    }
    // backoff after failures (router OOM / channel full)
    const fail = Number(e.monFail) || 0
    if (fail > 0 && e._monNextAt && Date.now() < e._monNextAt) {
      return { ok: true, skipped: true, data: e._lastMon || {} }
    }
    e.monBusy = true
    try {
      // prefer lite after 2 fails or when host looks like a router profile
      const host = String((e.profile && e.profile.host) || '')
      const nameHint = String(e.hostId || '') + host
      const preferLite =
        fail >= 1 ||
        /\b(1|31|123)\.1$/.test(host) ||
        /openwrt|lede|router|ax6|ikuai|ros/i.test(nameHint)

      const tryOnce = async (lite) => {
        let cmd
        try {
          // OpenWrt/ImmortalWrt often has NO base64 applet — run script body directly.
          // Full script may still use base64 when available; lite is always inline.
          if (lite) {
            cmd = this._monitorInlineScript(true)
          } else {
            const b64 = this._monitorScriptB64(false)
            cmd =
              'echo ' +
              b64 +
              ' | (base64 -d 2>/dev/null || base64 -D 2>/dev/null || busybox base64 -d 2>/dev/null || openssl base64 -d -A 2>/dev/null) | sh' +
              ' || sh -c ' +
              JSON.stringify(this._monitorInlineScript(true))
          }
        } catch (err) {
          return { ok: false, error: 'monitor script: ' + (err.message || err), data: {} }
        }
        // lite: 8s; full: 15s (includes 0.4–1s sleep for CPU sample)
        const r = await this.exec(sessionId, cmd, { timeoutMs: lite ? 8000 : 15000 })
        const text = String((r && r.stdout) || '')
        if (!text.trim()) {
          return {
            ok: false,
            error: (r && r.error) || 'monitor 无输出',
            data: { raw: String((r && r.stderr) || '') },
          }
        }
        return { ok: true, data: this._parseMonitorText(text) }
      }

      let result = await tryOnce(preferLite)
      // if full failed once, immediately try lite before counting hard fail
      if (!result.ok && !preferLite) {
        result = await tryOnce(true)
      }
      if (result.ok) {
        e.monFail = 0
        e._monNextAt = 0
        e._lastMon = result.data
        return result
      }
      e.monFail = fail + 1
      // 5s, 10s, 20s… cap 60s
      const backoff = Math.min(60000, 5000 * Math.pow(2, Math.min(4, e.monFail - 1)))
      e._monNextAt = Date.now() + backoff
      slog('warn', 'monitor', 'collect failed', {
        sessionId,
        fail: e.monFail,
        error: result && result.error,
        backoff,
      })
      return result
    } finally {
      e.monBusy = false
    }
  }

  async collectProcesses(sessionId) {
    // Single exec only — per-pid readlink used to open dozens of channels and
    // thrash dropbear MaxSessions on routers.
    const r = await this.exec(
      sessionId,
      'ps -eo pid,user,rss,pcpu,comm,args --sort=-pcpu 2>/dev/null | head -n 80 || ps w 2>/dev/null | head -n 80',
    )
    if (!r.ok) return r
    const lines = String(r.stdout || '')
      .split(/\r?\n/)
      .slice(1)
      .filter(Boolean)
    const rows = []
    for (const line of lines) {
      const m = line.trim().match(/^(\d+)\s+(\S+)\s+(\d+)\s+([\d.]+)\s+(\S+)\s+(.*)$/)
      if (!m) continue
      rows.push({
        pid: m[1],
        user: m[2],
        mem: (Number(m[3]) / 1024).toFixed(1) + 'M',
        memKb: Number(m[3]),
        cpu: m[4],
        name: m[5],
        command: m[6],
        location: '',
      })
    }
    return { ok: true, rows }
  }

  async collectNetwork(sessionId) {
    const r = await this.exec(
      sessionId,
      'ss -tulnpH 2>/dev/null || netstat -tulnp 2>/dev/null | tail -n +3',
    )
    const rows = []
    for (const line of String(r.stdout || '').split(/\r?\n/)) {
      if (!line.trim()) continue
      const parts = line.trim().split(/\s+/)
      if (parts.length < 5) continue
      let proto = parts[0]
      let state = parts[1]
      let local = parts[4] || parts[3] || ''
      if (!/tcp|udp/i.test(proto) && parts.length >= 6) {
        proto = parts[0]
        local = parts[3]
        state = parts[5] || ''
      }
      const lp = local.lastIndexOf(':')
      const listenIp = lp >= 0 ? local.slice(0, lp) : local
      const port = lp >= 0 ? local.slice(lp + 1) : ''
      const pm = line.match(/pid=(\d+)/) || line.match(/,(\d+)\//)
      const nm = line.match(/"([^"]+)"/) || line.match(/\/([^/\s]+)$/)
      rows.push({
        pid: pm ? pm[1] : '',
        name: nm ? nm[1] : '',
        listenIp,
        port,
        proto,
        state,
        raw: line,
      })
    }
    return { ok: true, rows, raw: r.stdout || '' }
  }


  /**
   * One-shot structured system info (BusyBox / OpenWrt / ImmortalWrt).
   * Prefer direct `sh` body — many routers ship WITHOUT base64 applet, so
   * `echo $b64 | base64 -d | sh` silently yields empty output.
   */
  _sysInfoInlineScript() {
    // Keep under ~4KB. No bashisms. No base64 dependency.
    return [
      'echo ===sysinfo===',
      'HN=`uname -n 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo -`',
      'echo hostname=$HN',
      'echo kernel_name=`uname -s 2>/dev/null || echo Linux`',
      'echo kernel_release=`uname -r 2>/dev/null || echo -`',
      'echo kernel_version=`uname -v 2>/dev/null || echo -`',
      'echo machine=`uname -m 2>/dev/null || echo -`',
      'echo uname_a=`uname -a 2>/dev/null || echo -`',
      // OS: openwrt_release first (routers), then os-release
      'OS_PRETTY=',
      'if [ -f /etc/openwrt_release ]; then OS_PRETTY=`awk -F"\'" \'/DISTRIB_DESCRIPTION/{print $2;exit}\' /etc/openwrt_release 2>/dev/null`; fi',
      'if [ -z "$OS_PRETTY" ] && [ -f /etc/os-release ]; then OS_PRETTY=`awk -F= \'/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2;exit}\' /etc/os-release 2>/dev/null`; fi',
      'if [ -z "$OS_PRETTY" ] && [ -f /etc/os-release ]; then OS_PRETTY=`awk -F= \'/^NAME=/{gsub(/"/,"",$2);print $2;exit}\' /etc/os-release 2>/dev/null`; fi',
      'if [ -z "$OS_PRETTY" ] && [ -f /etc/redhat-release ]; then OS_PRETTY=`head -n1 /etc/redhat-release 2>/dev/null`; fi',
      'echo os_pretty=${OS_PRETTY:--}',
      'if [ -f /etc/os-release ]; then echo os_id=`awk -F= \'/^ID=/{gsub(/"/,"",$2);print $2;exit}\' /etc/os-release 2>/dev/null`; fi',
      'if [ -f /etc/openwrt_release ] && [ -z "$OS_ID" ]; then echo os_id=`awk -F"\'" \'/DISTRIB_ID/{print $2;exit}\' /etc/openwrt_release 2>/dev/null`; fi',
      // uptime via awk (BusyBox expr edge cases)
      'awk \'{s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); printf "uptime_sec=%d\\nuptime=%dd%dh%dm\\nuptime_human=%d days, %d hours, %d minutes\\n",s,d,h,m,d,h,m}\' /proc/uptime 2>/dev/null',
      'L=`cat /proc/loadavg 2>/dev/null`; set -- $L; echo load=$1,$2,$3; echo load_1=$1; echo load_5=$2; echo load_15=$3',
      'echo cpu_count=`grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1`',
      'echo cpu_model=`awk -F: \'/^model name/{gsub(/^[ \\t]+/,"",$2);print $2;exit} /^Hardware/{gsub(/^[ \\t]+/,"",$2);print $2;exit} /^cpu model/{gsub(/^[ \\t]+/,"",$2);print $2;exit}\' /proc/cpuinfo 2>/dev/null`',
      // one cpu_row summary (full per-core table is heavy on big boxes; routers usually 1-4)
      'awk -F: \'/^processor/{n++} /^model name/{gsub(/^[ \\t]+/,"",$2);m=$2} /^Hardware/{if(m==""){gsub(/^[ \\t]+/,"",$2);m=$2}} /^cpu model/{if(m==""){gsub(/^[ \\t]+/,"",$2);m=$2}} /^cpu MHz/{gsub(/^[ \\t]+/,"",$2);z=$2} /^BogoMIPS/{gsub(/^[ \\t]+/,"",$2);b=$2} /^bogomips/{gsub(/^[ \\t]+/,"",$2);b=$2} /^cache size/{gsub(/^[ \\t]+/,"",$2);c=$2} END{if(n<1)n=1; for(i=0;i<n && i<16;i++) printf "cpu_row=%d\\t%s\\t%s\\t%s\\t%s\\n",i,m,z,c,b}\' /proc/cpuinfo 2>/dev/null',
      'awk \'/^cpu /{u=$2+0;ni=$3+0;sy=$4+0;id=$5+0;io=0;irq=0;sirq=0;st=0; if(NF>=6)io=$6+0; if(NF>=7)irq=$7+0; if(NF>=8)sirq=$8+0; if(NF>=9)st=$9+0; t=u+ni+sy+id+io+irq+sirq+st; if(t<=0)t=1; printf "cpu_user=%.1f\\ncpu_nice=%.1f\\ncpu_system=%.1f\\ncpu_idle=%.1f\\ncpu_iowait=%.1f\\ncpu_irq=%.1f\\ncpu_softirq=%.1f\\ncpu_steal=%.1f\\ncpu_busy=%.1f\\n",u*100/t,ni*100/t,sy*100/t,id*100/t,io*100/t,irq*100/t,sirq*100/t,st*100/t,100-id*100/t; exit}\' /proc/stat 2>/dev/null',
      'awk \'/^MemTotal:/{t=$2+0}/^MemAvailable:/{a=$2+0}/^MemFree:/{f=$2+0}/^Buffers:/{b=$2+0}/^Cached:/{c=$2+0}/^SReclaimable:/{s=$2+0}/^SwapTotal:/{st=$2+0}/^SwapFree:/{sf=$2+0} END{if(t>0){if(a<=0)a=f+b+c+s;u=t-a;if(u<0)u=0;printf "mem_total_kb=%d\\nmem_used_kb=%d\\nmem_free_kb=%d\\nmem_available_kb=%d\\nmem_pct=%d\\nmem=%d %d %d\\n",t,u,f,a,int(u*100/t+0.5),int(u*100/t+0.5),int(u/1024),int(t/1024)}else{print "mem=0 0 0";print "mem_pct=0"} if(st>0){su=st-sf;if(su<0)su=0;printf "swap_total_kb=%d\\nswap_used_kb=%d\\nswap_pct=%d\\nswap=%d %d %d\\n",st,su,int(su*100/st+0.5),int(su*100/st+0.5),int(su/1024),int(st/1024)}else{print "swap=0 0 0";print "swap_pct=0";print "swap_total_kb=0";print "swap_used_kb=0"}}\' /proc/meminfo 2>/dev/null',
      "awk -F'[: ]+' 'NR>2{gsub(/:/,\"\",$1);if($1!=\"\"&&$1!=\"lo\"&&$1!~/^lo/)printf \"net_row=%s\\t%s\\t%s\\n\",$1,$2,$10}' /proc/net/dev 2>/dev/null | head -n 24",
      'if command -v ip >/dev/null 2>&1; then ip -o -4 addr show 2>/dev/null | awk \'{split($4,a,"/"); if($2!="lo") printf "net_ip=%s\\t%s\\n",$2,a[1]}\' | head -n 24; else ifconfig 2>/dev/null | awk \'/^[a-zA-Z0-9]/{if(iface!=""&&ip!="")printf "net_ip=%s\\t%s\\n",iface,ip; iface=$1; gsub(/:/,"",iface); ip=""} /inet /{for(i=1;i<=NF;i++){if($i~/^addr:/){split($i,a,":");ip=a[2]} else if($i=="inet"&&$(i+1)!~/^addr/){ip=$(i+1)}}} END{if(iface!=""&&ip!=""&&iface!="lo")printf "net_ip=%s\\t%s\\n",iface,ip}\' | head -n 24; fi',
      // MAC
      'if [ -d /sys/class/net ]; then for d in /sys/class/net/*; do [ -d "$d" ] || continue; name=`basename "$d"`; [ "$name" = "lo" ] && continue; mac=`cat "$d/address" 2>/dev/null`; [ -n "$mac" ] && [ "$mac" != "00:00:00:00:00:00" ] && printf "mac=%s\t%s\n" "$name" "$mac"; done | head -n 24; fi',
      // primary IP: prefer br-lan / lan, then RFC1918, then first
      'IP=`ip -o -4 addr show 2>/dev/null | awk \'/br-lan|[^a-z]lan /{split($4,a,"/"); print a[1]; exit}\'`',
      'if [ -z "$IP" ]; then IP=`ip -o -4 addr show 2>/dev/null | awk \'{split($4,a,"/"); ip=a[1]; if(ip~/^127\\./)next; if(ip~/^10\\./||ip~/^192\\.168\\./||ip~/^172\\.(1[6-9]|2[0-9]|3[0-1])\\./){print ip; exit}}\'`; fi',
      'if [ -z "$IP" ]; then IP=`ip -4 -o addr show scope global 2>/dev/null | awk \'{print $4;exit}\' | cut -d/ -f1`; fi',
      'if [ -z "$IP" ]; then IP=`ifconfig 2>/dev/null | awk \'/inet /{print $2}\' | sed \'s/addr://\' | awk \'$0!~/^127\\./{print;exit}\'`; fi',
      'echo ip=${IP:-}',
      // disks: KEEP overlay root; skip only pure tmp/dev/sys
      'df -h 2>/dev/null | awk \'NR>1 { fs=$1; if(NF>=6){ sz=$2; us=$3; av=$4; pct=$5; mnt=$6; for(i=7;i<=NF;i++) mnt=mnt" "$i } else next; if(fs~/^(tmpfs|devtmpfs|devfs|efivarfs|proc|sysfs|cgroup|autofs)$/) next; if(mnt~/^\\/(dev|run|sys|proc|tmp)$/) next; if(mnt~/^\\/(dev|run|sys|proc|tmp)\\//) next; printf "disk=%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n", mnt,sz,us,av,pct,fs }\' | head -n 20',
      'echo ===end===',
    ].join('\n')
  }

  _sysInfoScriptB64() {
    if (this._sysB64) return this._sysB64
    // Prefer file when present (richer), else inline
    const scriptPath = path.join(__dirname, 'remote-sysinfo.sh')
    let remoteScript
    try {
      remoteScript = fs.readFileSync(scriptPath, 'utf8').replace(/^#!.*\n/, '')
    } catch (_) {
      remoteScript = this._sysInfoInlineScript()
    }
    this._sysB64 = Buffer.from(remoteScript, 'utf8').toString('base64')
    return this._sysB64
  }

  _parseSysInfoText(text) {
    const data = {
      hostname: '-',
      kernelName: '-',
      kernelRelease: '-',
      kernelVersion: '-',
      machine: '-',
      unameA: '',
      osPretty: '-',
      osId: '',
      osVersion: '',
      uptime: '-',
      uptimeHuman: '-',
      uptimeSec: '',
      load: '',
      load1: '',
      load5: '',
      load15: '',
      cpuCount: '',
      cpuModel: '-',
      cpuBusy: '',
      cpuUser: '',
      cpuNice: '',
      cpuSystem: '',
      cpuIdle: '',
      cpuIowait: '',
      cpuIrq: '',
      cpuSoftirq: '',
      cpuSteal: '',
      mem: '0 0 0',
      memPct: 0,
      memTotalKb: 0,
      memUsedKb: 0,
      memFreeKb: 0,
      memAvailableKb: 0,
      swap: '0 0 0',
      swapPct: 0,
      swapTotalKb: 0,
      swapUsedKb: 0,
      ip: '',
      cpuRows: [],
      netRows: [],
      netIps: [],
      macs: [],
      disks: [],
      raw: text,
    }
    for (const line of String(text || '').split(/\r?\n/)) {
      const s = line.trim()
      if (!s || s.indexOf('===') === 0) continue
      const eq = s.indexOf('=')
      if (eq < 0) continue
      const k = s.slice(0, eq)
      const v = s.slice(eq + 1)
      switch (k) {
        case 'hostname': data.hostname = v || '-'; break
        case 'kernel_name': data.kernelName = v || '-'; break
        case 'kernel_release': data.kernelRelease = v || '-'; break
        case 'kernel_version': data.kernelVersion = v || '-'; break
        case 'machine': data.machine = v || '-'; break
        case 'uname_a': data.unameA = v; break
        case 'os_pretty': data.osPretty = v || '-'; break
        case 'os_id': data.osId = v; break
        case 'os_version': data.osVersion = v; break
        case 'uptime': data.uptime = v || '-'; break
        case 'uptime_human': data.uptimeHuman = v || '-'; break
        case 'uptime_sec': data.uptimeSec = v; break
        case 'load': data.load = v; break
        case 'load_1': data.load1 = v; break
        case 'load_5': data.load5 = v; break
        case 'load_15': data.load15 = v; break
        case 'cpu_count': data.cpuCount = v; break
        case 'cpu_model': data.cpuModel = v || '-'; break
        case 'cpu_busy': data.cpuBusy = v; break
        case 'cpu_user': data.cpuUser = v; break
        case 'cpu_nice': data.cpuNice = v; break
        case 'cpu_system': data.cpuSystem = v; break
        case 'cpu_idle': data.cpuIdle = v; break
        case 'cpu_iowait': data.cpuIowait = v; break
        case 'cpu_irq': data.cpuIrq = v; break
        case 'cpu_softirq': data.cpuSoftirq = v; break
        case 'cpu_steal': data.cpuSteal = v; break
        case 'mem': data.mem = v; break
        case 'mem_pct': data.memPct = Number(v) || 0; break
        case 'mem_total_kb': data.memTotalKb = Number(v) || 0; break
        case 'mem_used_kb': data.memUsedKb = Number(v) || 0; break
        case 'mem_free_kb': data.memFreeKb = Number(v) || 0; break
        case 'mem_available_kb': data.memAvailableKb = Number(v) || 0; break
        case 'swap': data.swap = v; break
        case 'swap_pct': data.swapPct = Number(v) || 0; break
        case 'swap_total_kb': data.swapTotalKb = Number(v) || 0; break
        case 'swap_used_kb': data.swapUsedKb = Number(v) || 0; break
        case 'ip': data.ip = v; break
        case 'cpu_row': {
          const p = v.split('\t')
          data.cpuRows.push({
            id: p[0] || '',
            model: p[1] || '',
            mhz: p[2] || '',
            cache: p[3] || '',
            bogomips: p[4] || '',
          })
          break
        }
        case 'net_row': {
          const p = v.split('\t')
          data.netRows.push({ name: p[0] || '', rx: p[1] || '0', tx: p[2] || '0' })
          break
        }
        case 'net_ip': {
          const p = v.split('\t')
          data.netIps.push({ name: p[0] || '', ip: p[1] || '' })
          break
        }
        case 'mac': {
          const p = v.split(/\t+|\s+/)
          data.macs.push({ name: p[0] || '', mac: p[1] || '' })
          break
        }
        case 'disk': {
          const p = v.split('\t')
          data.disks.push({
            mount: p[0] || '',
            size: p[1] || '',
            used: p[2] || '',
            avail: p[3] || '',
            pct: p[4] || '',
            fs: p[5] || '',
          })
          break
        }
        default:
          break
      }
    }
    // merge ip/mac into net rows
    const ipMap = new Map(data.netIps.map((x) => [x.name, x.ip]))
    const macMap = new Map(data.macs.map((x) => [x.name, x.mac]))
    for (const row of data.netRows) {
      row.ip = ipMap.get(row.name) || ''
      row.mac = macMap.get(row.name) || ''
    }
    // de-dupe disks by mount (OpenWrt often lists /boot twice)
    if (data.disks.length) {
      const seen = new Set()
      data.disks = data.disks.filter((d) => {
        const k = d.mount || ''
        if (!k || seen.has(k)) return false
        seen.add(k)
        return true
      })
    }
    // if net_row empty but net_ip present, synthesize
    if (!data.netRows.length && data.netIps.length) {
      data.netRows = data.netIps.map((x) => ({
        name: x.name,
        ip: x.ip,
        mac: macMap.get(x.name) || '',
        rx: '',
        tx: '',
      }))
    }
    return data
  }

  async collectSysInfo(sessionId) {
    const e = this.sessions.get(sessionId)
    if (!e?.session) return { ok: false, error: '会话不存在', data: {} }

    // 1) Direct inline (OpenWrt without base64)
    const inline = this._sysInfoInlineScript()
    let r = await this.exec(sessionId, inline, { timeoutMs: 12000 })
    let text = String((r && r.stdout) || '')
    if (!text.includes('===sysinfo===') && !text.includes('hostname=')) {
      // 2) base64 file pipeline (full Linux with coreutils)
      try {
        const b64 = this._sysInfoScriptB64()
        const cmd =
          'echo ' +
          b64 +
          ' | (base64 -d 2>/dev/null || base64 -D 2>/dev/null || busybox base64 -d 2>/dev/null || openssl base64 -d -A 2>/dev/null) | sh'
        if (cmd.length < 10000) {
          r = await this.exec(sessionId, cmd, { timeoutMs: 12000 })
          text = String((r && r.stdout) || '')
        }
      } catch (_) {}
    }
    if (!text.trim()) {
      return {
        ok: false,
        error: (r && r.error) || '系统信息无输出（远端可能无 base64 或 exec 被拒）',
        data: { raw: String((r && (r.stderr || r.stdout)) || '') },
      }
    }
    return { ok: true, data: this._parseSysInfoText(text) }
  }

  closeAll() {
    for (const id of [...this.sessions.keys()]) this.disconnect(id)
    this.multiplexer.clear()
  }
}

module.exports = { SshEngine }
