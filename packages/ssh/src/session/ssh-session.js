/**
 * SSHSession — native ssh2 connection object.
 *
 *  - profile/options → connect config
 *  - multi-step auth methods (password → keyboard-interactive → publickey)
 *  - algorithms preference list
 *  - shell channel separate from control connection
 *  - lazy SFTP activation
 *  - keepalive / readyTimeout
 *  - SOCKS proxy transport
 *  - service messages to UI
 *
 */
'use strict'

const { EventEmitter } = require('events')
const fs = require('fs')
const path = require('path')
const os = require('os')
const { buildAlgorithms } = require('../algorithms')
const { ShellSession } = require('./shell-session')
const { SFTPSession } = require('./sftp-session')

function resolveSsh2() {
  const candidates = [
    // Prefer process-local module resolution first (Electron main cwd = runtime root)
    'ssh2',
    path.join(process.cwd(), 'node_modules/ssh2'),
    // packages/ssh/src/session → ../../../../ = repo root
    path.join(__dirname, '../../../../node_modules/ssh2'),
    // packages/ssh/src/session → ../../../../../ = parent of monorepo
    path.join(__dirname, '../../../../../node_modules/ssh2'),
    // packages/app/main → via relative from session (runtime APFS)
    path.join(__dirname, '../../../../../node_modules/ssh2'),
    path.join(os.homedir(), 'Library/Application Support/PixShell/app/node_modules/ssh2'),
    path.join(os.homedir(), '.local/share/PixShell/app/node_modules/ssh2'),
  ]
  let lastErr = null
  for (const c of candidates) {
    try {
      const mod = require(c)
      if (mod && mod.Client) return mod
    } catch (e) {
      lastErr = e
    }
  }
  if (lastErr) resolveSsh2._lastError = lastErr.message
  return null
}

const ssh2mod = resolveSsh2()
const Client = ssh2mod ? ssh2mod.Client : null

/**
 * @typedef {object} SSHProfile
 * @property {string} [id]
 * @property {string} host
 * @property {number} [port]
 * @property {string} [user]
 * @property {string} [username]
 * @property {string|null} [auth]  password|publicKey|agent|keyboardInteractive|null(auto)
 * @property {string} [password]
 * @property {string|string[]} [privateKeys]
 * @property {string} [privateKey]
 * @property {string} [passphrase]
 * @property {number} [keepaliveInterval]
 * @property {number} [keepaliveCountMax]
 * @property {number|null} [readyTimeout]
 * @property {object} [proxy]  { type, host, port, username, password }
 * @property {boolean} [agentForward]
 * @property {boolean} [skipBanner]
 * @property {object} [algorithms]
 * @property {number} [cols]
 * @property {number} [rows]
 * @property {string} [term]
 */

class SSHSession extends EventEmitter {
  /**
   * @param {SSHProfile} profile
   * @param {{ debug?: Function }} [opts]
   */
  constructor(profile, opts = {}) {
    super()
    this.profile = normalizeProfile(profile)
    this.conn = null
    /** @type {ShellSession|null} last opened shell (compat) */
    this.shellSession = null
    /** @type {Set<ShellSession>} all live shells (reuseSession multi-tab) */
    this.shellSessions = new Set()
    /** @type {SFTPSession|null} */
    this.sftpSession = null
    /** @type {Promise<SFTPSession>|null} single-flight openSFTP */
    this._sftpOpening = null
    this.authenticated = false
    this.destroyed = false
    this._refCount = 0
    this._debug = opts.debug || (() => {})
    this._serviceLog = []
  }

  static isAvailable() {
    return !!Client
  }

  static loadError() {
    if (Client) return null
    const detail = resolveSsh2._lastError ? ` (${resolveSsh2._lastError})` : ''
    return 'ssh2 module not found — 在运行目录执行 npm install ssh2' + detail
  }

  /** Service message to UI terminal */
  emitServiceMessage(msg) {
    this._serviceLog.push(msg)
    this.emit('serviceMessage', msg)
  }

  ref() {
    this._refCount++
    return this._refCount
  }
  unref() {
    this._refCount = Math.max(0, this._refCount - 1)
    return this._refCount
  }

  /**
   * Connect + authenticate.
   *
   * Auth order (auto) — critical for OpenSSH/PAM:
   *  1. publickey (if privateKey)
   *  2. agent (only when useful — see below)
   *  3. keyboard-interactive with password (PAM-friendly; MUST be before password
   *     on many hosts — password-then-KI hangs until readyTimeout on macOS/OpenSSH)
   *  4. password
   *
   * Agent is NOT auto-injected when password/key already provided (empty agent
   * waste + can confuse method order).
   */
  async start() {
    if (!Client) throw new Error(SSHSession.loadError())
    if (this.conn) {
      try {
        this.conn.end()
      } catch (_) {}
      this.conn = null
      this.authenticated = false
      this.destroyed = false
    }

    const p = this.profile
    // 连接过程 UI 用前端动画条，不再往终端灌英文 Connecting 行

    const hasPassword = p.password != null && String(p.password).length > 0
    const auth = p.auth // null = auto

    const cfg = {
      host: p.host.trim(),
      port: p.port,
      username: p.user,
      // Routers (dropbear) under monitor load need more keepalive slack
      readyTimeout: p.readyTimeout ?? 30000,
      keepaliveInterval: p.keepaliveInterval ?? 10000,
      // 10 × 10s = 100s without reply before drop (was 4×15s=60s — too aggressive)
      keepaliveCountMax: p.keepaliveCountMax ?? 10,
      // KI when we can answer (password) OR auth is forced to keyboard-interactive.
      tryKeyboard:
        (!auth || auth === 'password' || auth === 'keyboardInteractive') &&
        (hasPassword || auth === 'keyboardInteractive'),
      // Accept unknown hosts by default on first connect.
      // Caller may pass profile.hostVerifier for strict known_hosts later.
      hostVerifier:
        typeof p.hostVerifier === 'function'
          ? p.hostVerifier
          : () => true,
    }
    if (p.algorithms) {
      cfg.algorithms = buildAlgorithms(p.algorithms)
    }

    // ── credentials ───────────────────────────────────────
    if (hasPassword && (!auth || auth === 'password' || auth === 'keyboardInteractive')) {
      cfg.password = String(p.password)
    }

    let loadedKey = false
    if (p.privateKey && (!auth || auth === 'publicKey')) {
      cfg.privateKey = p.privateKey
      if (p.passphrase) cfg.passphrase = p.passphrase
      loadedKey = true
    } else if (p.privateKeys?.length && (!auth || auth === 'publicKey')) {
      const keyPath = Array.isArray(p.privateKeys) ? p.privateKeys[0] : p.privateKeys
      const expanded = expandPath(String(keyPath), p)
      try {
        cfg.privateKey = fs.readFileSync(expanded)
        if (p.passphrase) cfg.passphrase = p.passphrase
        loadedKey = true
        this.emitServiceMessage(`Using private key ${expanded}`)
      } catch (e) {
        this.emitServiceMessage(`! Could not load key ${expanded}: ${e.message}`)
      }
    }

    // Agent: only when explicit, or when no password/key (agent-only login),
    // or agentForward requested (still need agent sock for forwarding setup).
    const wantAgent =
      auth === 'agent' ||
      !!p.agentForward ||
      ((!hasPassword && !loadedKey) && (!auth || auth === 'agent'))
    if (wantAgent && process.env.SSH_AUTH_SOCK) {
      cfg.agent = process.env.SSH_AUTH_SOCK
      cfg.agentForward = !!p.agentForward
    }

    // Explicit auth method order — avoid default none→password→agent→KI hang.
    cfg.authHandler = buildAuthMethodList(cfg, { hasPassword, loadedKey, auth })

    // SOCKS transport
    if (p.proxy && p.proxy.host) {
      await this._applyProxy(cfg, p.proxy)
    }

    // Guard: must have at least one auth material
    if (
      cfg.password == null &&
      cfg.privateKey == null &&
      !cfg.agent &&
      !cfg.tryKeyboard
    ) {
      throw new Error('未提供可用的认证方式（密码/私钥/agent）')
    }

    await new Promise((resolve, reject) => {
      const conn = new Client()
      this.conn = conn
      let settled = false
      const done = (err) => {
        if (settled) return
        settled = true
        if (err) {
          try {
            conn.end()
          } catch (_) {}
          reject(err)
        } else {
          resolve()
        }
      }

      conn
        .on('ready', () => {
          this.authenticated = true
          this.emitServiceMessage('Authenticated')
          this.emit('ready')
          done()
        })
        .on('banner', (msg) => {
          if (!p.skipBanner) this.emitServiceMessage(String(msg).replace(/\n/g, '\r\n'))
        })
        .on('keyboard-interactive', (_name, _instructions, _lang, prompts, finish) => {
          // Always answer; empty password if none (server may still prompt).
          try {
            const pw = hasPassword ? String(p.password) : ''
            const answers = (prompts || []).map((pr) => {
              const promptText = String((pr && pr.prompt) || '').toLowerCase()
              // passphrase-style prompts for encrypted keys are rare on KI;
              // default to password.
              if (p.passphrase && /passphrase|私钥/.test(promptText)) return String(p.passphrase)
              return pw
            })
            finish(answers)
          } catch (e) {
            try {
              finish((prompts || []).map(() => ''))
            } catch (_) {}
            done(new Error('keyboard-interactive 响应失败: ' + (e.message || e)))
          }
        })
        .on('error', (err) => {
          const msg = formatSshError(err)
          this.emitServiceMessage('! ' + msg)
          // Avoid unhandled 'error' EventEmitter throw when no listeners yet
          if (this.listenerCount('error') > 0) this.emit('error', err)
          done(new Error(msg))
        })
        .on('end', () => {
          this.emit('end')
        })
        .on('close', () => {
          this.authenticated = false
          this.emit('close')
          // If closed before ready and not settled → connection dropped mid-auth
          if (!settled) {
            done(new Error('连接在认证完成前被关闭'))
          }
        })
        .connect(cfg)
    })

    return this
  }

  async _applyProxy(cfg, proxy) {
    const type = proxy.type || 'socks5'
    if (type === 'socks5' || type === 'socks4') {
      this.emitServiceMessage(`Proxy SOCKS ${proxy.host}:${proxy.port || 1080}`)
      const { SocksClient } = require('socks')
      const { socket } = await SocksClient.createConnection({
        proxy: {
          host: proxy.host,
          port: Number(proxy.port) || 1080,
          type: type === 'socks4' ? 4 : 5,
          userId: proxy.username || undefined,
          password: proxy.password || undefined,
        },
        command: 'connect',
        destination: { host: cfg.host, port: cfg.port },
        timeout: 20000,
      })
      cfg.sock = socket
    } else if (type === 'http') {
      // ssh2 supports http proxy via sock stream — minimal: fail with clear message
      throw new Error('HTTP proxy 请改用 SOCKS5，或后续实现 CONNECT 隧道')
    }
  }

  /**
   * Open interactive shell (independent channel per call — multi-tab safe).
   * @param {{ cols?: number, rows?: number, term?: string, x11?: boolean }} [opts]
   */
  async openShell(opts = {}) {
    if (!this.conn || !this.authenticated) throw new Error('Cannot open shell before auth')
    const cols = opts.cols || this.profile.cols || 120
    const rows = opts.rows || this.profile.rows || 30
    const term = opts.term || this.profile.term || 'xterm-256color'

    const stream = await new Promise((resolve, reject) => {
      this.conn.shell({ term, cols, rows }, (err, s) => (err ? reject(err) : resolve(s)))
    })
    const shell = new ShellSession(stream, {
      cols,
      rows,
      debug: this._debug,
    })
    this.shellSessions.add(shell)
    this.shellSession = shell
    shell.on('close', () => {
      this.shellSessions.delete(shell)
      if (this.shellSession === shell) this.shellSession = null
      this.emit('shellClose')
    })
    shell.on('cwd', (cwd) => this.emit('cwd', cwd))
    this.ref()
    return shell
  }

  /**
   * Lazy SFTP (single-flight — concurrent callers share one channel open).
   * @returns {Promise<SFTPSession>}
   */
  async openSFTP() {
    if (!this.conn || !this.authenticated) throw new Error('Cannot open SFTP before auth')
    if (this.sftpSession && !this.sftpSession.closed) return this.sftpSession
    if (this._sftpOpening) return this._sftpOpening
    this._sftpOpening = (async () => {
      try {
        if (this.sftpSession && !this.sftpSession.closed) return this.sftpSession
        // Close stale wrapper so a new channel is not leaked under a dead handle.
        try {
          this.sftpSession?.close?.()
        } catch (_) {}
        const sftp = await new Promise((resolve, reject) => {
          this.conn.sftp((err, s) => (err ? reject(err) : resolve(s)))
        })
        this.sftpSession = new SFTPSession(sftp, { debug: this._debug })
        return this.sftpSession
      } finally {
        this._sftpOpening = null
      }
    })()
    return this._sftpOpening
  }

  /**
   * One-shot exec channel with hard timeout.
   * Dropbear/OpenWrt often caps concurrent channels; hung exec (ping/sleep)
   * must not pin a channel forever or the interactive shell dies next.
   * @param {string} command
   * @param {{ timeoutMs?: number }} [opts]
   */
  exec(command, opts = {}) {
    if (!this.conn || !this.authenticated) {
      return Promise.resolve({ ok: false, error: 'not authenticated', stdout: '', stderr: '', code: null })
    }
    const timeoutMs = Math.max(1000, Number(opts.timeoutMs) || 12000)
    return new Promise((resolve) => {
      let settled = false
      let stream = null
      let timer = null
      // Keep partial output across timeout — monitor scripts often emit then hang.
      let stdout = ''
      let stderr = ''
      const finish = (result) => {
        if (settled) return
        settled = true
        if (timer) clearTimeout(timer)
        try {
          stream?.close?.()
        } catch (_) {}
        try {
          stream?.destroy?.()
        } catch (_) {}
        resolve(result)
      }
      timer = setTimeout(() => {
        finish({
          ok: false,
          error: 'exec timeout ' + timeoutMs + 'ms',
          stdout,
          stderr,
          code: null,
          timedOut: true,
        })
      }, timeoutMs)
      try {
        this.conn.exec(String(command || ''), { pty: false }, (err, s) => {
          if (err) {
            finish({ ok: false, error: err.message, stdout, stderr, code: null })
            return
          }
          if (settled) {
            try {
              s.close()
            } catch (_) {}
            return
          }
          stream = s
          stream.on('data', (d) => {
            stdout += d.toString('utf8')
            // hard cap output so a runaway process cannot OOM the client
            if (stdout.length > 512 * 1024) stdout = stdout.slice(-256 * 1024)
          })
          stream.stderr?.on('data', (d) => {
            stderr += d.toString('utf8')
            if (stderr.length > 64 * 1024) stderr = stderr.slice(-32 * 1024)
          })
          stream.on('close', (code) => {
            const exitCode = code ?? 0
            finish({ ok: exitCode === 0, code: exitCode, stdout, stderr })
          })
          stream.on('error', (e) => {
            finish({
              ok: false,
              error: (e && e.message) || String(e),
              stdout,
              stderr,
              code: null,
            })
          })
        })
      } catch (e) {
        finish({
          ok: false,
          error: (e && e.message) || String(e),
          stdout,
          stderr,
          code: null,
        })
      }
    })
  }

  write(data) {
    return this.shellSession?.write(data) ?? false
  }

  resize(cols, rows) {
    this.shellSession?.resize(cols, rows)
  }

  async destroy() {
    if (this.destroyed) return
    this.destroyed = true
    try {
      this.shellSession?.kill()
    } catch (_) {}
    try {
      this.sftpSession?.close()
    } catch (_) {}
    for (const sh of this.shellSessions) {
      try {
        sh.kill()
      } catch (_) {}
    }
    this.shellSessions.clear()
    try {
      this.conn?.end()
    } catch (_) {}
    this.conn = null
    this.shellSession = null
    this.sftpSession = null
    this._sftpOpening = null
    this.authenticated = false
    this.emit('destroyed')
    this.removeAllListeners()
  }
}

function normalizeProfile(p) {
  const user = p.user || p.username || 'root'
  let privateKeys = p.privateKeys
  if (!privateKeys && p.privateKeyPath) privateKeys = [p.privateKeyPath]
  if (typeof privateKeys === 'string') privateKeys = [privateKeys]
  return {
    id: p.id || null,
    host: String(p.host || '').trim(),
    port: Number(p.port) || 22,
    user: String(user).trim(),
    auth: p.auth || null,
    password: p.password || undefined,
    privateKey: p.privateKey || undefined,
    privateKeys: privateKeys || [],
    passphrase: p.passphrase || undefined,
    keepaliveInterval: p.keepaliveInterval ?? 10000,
    keepaliveCountMax: p.keepaliveCountMax ?? 10,
    readyTimeout: p.readyTimeout ?? 30000,
    proxy: p.proxy || null,
    agentForward: !!p.agentForward,
    skipBanner: !!p.skipBanner,
    algorithms: p.algorithms || null,
    cols: p.cols || 120,
    rows: p.rows || 30,
    term: p.term || 'xterm-256color',
    // Non-serializable hook — must survive normalize for strict known_hosts.
    hostVerifier: typeof p.hostVerifier === 'function' ? p.hostVerifier : undefined,
  }
}

function expandPath(pk, profile) {
  let s = pk.replace(/^~(?=$|[/\\])/, os.homedir())
  s = s.replace(/%h/g, profile.host)
  s = s.replace(/%r/g, profile.user)
  return s
}

function formatSshError(err) {
  if (!err) return 'unknown error'
  const msg = err.message || String(err)
  const level = err.level ? ` [${err.level}]` : ''
  const code = err.code ? ` (${err.code})` : ''
  return msg + level + code
}

/**
 * Build ssh2 authHandler list.
 * Prefer keyboard-interactive before password when both available — on OpenSSH
 * with UsePAM, password-then-KI often never receives INFO_REQUEST after a
 * failed password and hangs until readyTimeout.
 * @param {object} cfg partial connect cfg
 * @param {{ hasPassword: boolean, loadedKey: boolean, auth: string|null }} flags
 * @returns {string[]}
 */
function buildAuthMethodList(cfg, flags) {
  const { hasPassword, loadedKey, auth } = flags
  if (auth === 'publicKey') return ['publickey']
  if (auth === 'agent') return ['agent']
  if (auth === 'password') {
    // still try KI first if enabled (many servers only accept KI for "password")
    return cfg.tryKeyboard ? ['keyboard-interactive', 'password'] : ['password']
  }
  if (auth === 'keyboardInteractive') return ['keyboard-interactive']

  /** @type {string[]} */
  const list = []
  if (loadedKey || cfg.privateKey) list.push('publickey')
  if (cfg.agent) list.push('agent')
  if (cfg.tryKeyboard && hasPassword) list.push('keyboard-interactive')
  if (hasPassword || cfg.password != null) list.push('password')
  // Fallback if somehow empty
  if (!list.length) {
    if (cfg.tryKeyboard) list.push('keyboard-interactive')
    list.push('none')
  }
  return list
}

module.exports = {
  SSHSession,
  normalizeProfile,
  Client,
  resolveSsh2,
  buildAuthMethodList,
}
