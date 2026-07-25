/**
 * PixShell External CLI / AI-Agent bridge.
 *
 * Local-only HTTP API (127.0.0.1) so Claude Code / Codex / OpenCode / scripts
 * can drive open SSH sessions via local HTTP on 127.0.0.1.
 *
 * Auth: Bearer / X-PixShell-Token / ?token=  against agent_token file.
 * Never binds 0.0.0.0.
 *
 * Security (defense in depth):
 * - Reject non-loopback remoteAddress even though listen is 127.0.0.1
 * - No CORS reflection; never emit open Access-Control-Allow-Origin (local CLI only)
 * - Simple per-IP rate limit to reduce local abuse
 */
'use strict'

const http = require('http')
const fs = require('fs')
const path = require('path')
const os = require('os')
const crypto = require('crypto')
const { URL } = require('url')

const DEFAULT_PORT = 8766
const MAX_BODY = 32 * 1024 * 1024 // 32 MiB (sftp upload)
/** Simple abuse throttle: max requests per IP per window (local only). */
const RATE_LIMIT_MAX = 120
const RATE_LIMIT_WINDOW_MS = 60 * 1000

let slog = null
try {
  slog = require('./logger')
} catch (_) {
  slog = null
}

function secWarn(msg, extra) {
  try {
    if (slog && typeof slog.warn === 'function') slog.warn('agent-bridge', msg, extra)
    else console.warn('[PixShell agent-bridge]', msg, extra != null ? extra : '')
  } catch (_) {
    try {
      console.warn('[PixShell agent-bridge]', msg)
    } catch (__) {}
  }
}

function isLoopbackAddress(ra) {
  if (!ra) return false
  const a = String(ra)
  return a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1'
}

/** Fixed-window counter per IP — no deps. */
const rateBuckets = new Map()
function rateLimitAllow(ip) {
  const key = ip || 'unknown'
  const now = Date.now()
  // always drop expired buckets first
  for (const [k, v] of rateBuckets) {
    if (now >= v.resetAt) rateBuckets.delete(k)
  }
  let b = rateBuckets.get(key)
  if (!b || now >= b.resetAt) {
    b = { count: 0, resetAt: now + RATE_LIMIT_WINDOW_MS }
    rateBuckets.set(key, b)
  }
  b.count += 1
  // hard cap map size (loopback usually 1 key; defend future multi-proxy)
  if (rateBuckets.size > 256) {
    const first = rateBuckets.keys().next().value
    if (first != null) rateBuckets.delete(first)
  }
  return b.count <= RATE_LIMIT_MAX
}

function tokenDir() {
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'PixShell')
  }
  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'PixShell')
  }
  return path.join(os.homedir(), '.local', 'share', 'PixShell')
}

function tokenPath() {
  return path.join(tokenDir(), 'agent_token')
}

function ensureToken() {
  const dir = tokenDir()
  const file = tokenPath()
  try {
    fs.mkdirSync(dir, { recursive: true })
  } catch (_) {}
  try {
    if (fs.existsSync(file)) {
      const t = fs.readFileSync(file, 'utf8').trim()
      if (t && t.length >= 16) return t
    }
  } catch (_) {}
  const t = crypto.randomBytes(32).toString('base64url')
  try {
    fs.writeFileSync(file, t, { encoding: 'utf8', mode: 0o600 })
  } catch (e) {
    console.warn('[PixShell agent-bridge] cannot write agent_token:', e.message)
  }
  return t
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (c) => {
      size += c.length
      if (size > MAX_BODY) {
        reject(new Error('body too large'))
        req.destroy()
        return
      }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks)))
    req.on('error', reject)
  })
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj == null ? {} : obj)
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  })
  res.end(body)
}

function sendText(res, code, text, type) {
  const body = text == null ? '' : String(text)
  res.writeHead(code, {
    'Content-Type': type || 'text/plain; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  })
  res.end(body)
}

function parseQuery(u) {
  const q = {}
  for (const [k, v] of u.searchParams.entries()) q[k] = v
  return q
}

function pickToken(req, query) {
  const h = req.headers || {}
  const auth = String(h.authorization || h.Authorization || '')
  if (/^Bearer\s+/i.test(auth)) return auth.replace(/^Bearer\s+/i, '').trim()
  // PixShell-only headers (no legacy third-party trademark aliases)
  if (h['x-pixshell-token']) return String(h['x-pixshell-token']).trim()
  if (h['x-agent-token']) return String(h['x-agent-token']).trim()
  if (query.token) return String(query.token).trim()
  return ''
}

function timingSafeEqualStr(a, b) {
  try {
    const ba = Buffer.from(String(a))
    const bb = Buffer.from(String(b))
    if (ba.length !== bb.length) return false
    return crypto.timingSafeEqual(ba, bb)
  } catch {
    return false
  }
}

/**
 * @param {object} opts
 * @param {import('./ssh-engine').SshEngine} opts.engine
 * @param {() => import('electron').BrowserWindow|null} opts.getMainWindow
 * @param {object} [opts.screenStore] Map sessionId -> text buffer (shared with renderer feed)
 * @param {(msg: object) => void} [opts.onUiEvent] push connect/open tab to renderer
 * @param {number} [opts.port]
 */
function createAgentBridge(opts) {
  const engine = opts.engine
  const getMainWindow = opts.getMainWindow || (() => null)
  const screenStore = opts.screenStore || new Map()
  const onUiEvent = opts.onUiEvent || (() => {})
  let port = Number(opts.port) || DEFAULT_PORT
  let token = ensureToken()
  let server = null
  let enabled = false
  let listeningPort = 0
  /** @type {number} last successful auth from external CLI/Agent (epoch ms) */
  let lastClientAt = 0
  let lastClientPath = ''

  function appendScreen(sessionId, chunk) {
    if (!sessionId) return
    const text = Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk || '')
    if (!text) return
    let cur = screenStore.get(sessionId) || ''
    cur += text
    // cap ~512KB per session
    if (cur.length > 512 * 1024) cur = cur.slice(cur.length - 512 * 1024)
    screenStore.set(sessionId, cur)
  }

  function clearScreen(sessionId) {
    if (sessionId) screenStore.delete(sessionId)
  }

  function resolveSessionId(raw) {
    const id = String(raw || '').trim()
    if (!id) return null
    if (engine.sessions.has(id)) return id
    // Unique prefix only (e.g. "ssh_m5x"). Do NOT use includes() — short tokens
    // like "a" / "ssh" would ambiguously match many sessions.
    const matches = []
    for (const k of engine.sessions.keys()) {
      if (k.startsWith(id)) matches.push(k)
    }
    if (matches.length === 1) return matches[0]
    return null
  }

  function hostList() {
    const hosts = engine.loadHosts() || []
    // group by group field
    const groupsMap = new Map()
    const ungrouped = []
    for (const h of hosts) {
      const g = (h.group || h.groupName || '').trim()
      const item = {
        id: h.id,
        name: h.name || h.host,
        host: h.host,
        port: Number(h.port) || 22,
        username: h.username || h.user || 'root',
        group: g || null,
        authType: h.authType || h.authMethod || h.auth || 'password',
        hasPassword: !!(h.password && String(h.password).length),
        remark: h.remark || '',
      }
      if (!g) ungrouped.push(item)
      else {
        if (!groupsMap.has(g)) groupsMap.set(g, [])
        groupsMap.get(g).push(item)
      }
    }
    const groups = [...groupsMap.entries()].map(([name, items]) => ({
      id: name,
      name,
      hosts: items,
    }))
    return {
      ok: true,
      groups,
      hosts: ungrouped,
      all: hosts.map((h) => ({
        id: h.id,
        name: h.name || h.host,
        host: h.host,
        port: Number(h.port) || 22,
        username: h.username || h.user || 'root',
        group: h.group || null,
      })),
    }
  }

  function sessionList() {
    const list = []
    for (const [id, e] of engine.sessions.entries()) {
      const p = e.profile || {}
      const pay = engine.payloads.get(id) || {}
      list.push({
        id,
        sessionId: id,
        hostId: e.hostId || pay.hostId || p.id || null,
        host: p.host || pay.host || '',
        port: p.port || pay.port || 22,
        username: p.username || p.user || pay.username || '',
        status: e.session && e.session.authenticated ? 'connected' : 'unknown',
        title: `${p.username || p.user || ''}@${p.host || ''}`,
      })
    }
    return { ok: true, sessions: list }
  }

  async function connectHost(body) {
    const hostId = body.host_id || body.hostId || body.id
    if (!hostId) return { ok: false, error: '缺少 host_id' }
    const hosts = engine.loadHosts() || []
    const h = hosts.find((x) => x.id === hostId || x.host === hostId)
    if (!h) return { ok: false, error: '主机不存在: ' + hostId }

    const password =
      (body.password != null && String(body.password)) ||
      (h.password && String(h.password)) ||
      undefined
    const privateKey = body.privateKey || h.privateKey || undefined
    const privateKeyPath = body.privateKeyPath || h.privateKeyPath || h.keyPath || undefined

    if (!password && !privateKey && !privateKeyPath) {
      return {
        ok: false,
        error: '主机未保存密码/私钥；请在 PixShell 中记住密码后再用 CLI 连接，或传 password',
      }
    }

    const sessionId = 'ssh_' + Date.now().toString(36) + crypto.randomBytes(3).toString('hex')
    const timeoutSec = Math.min(900, Math.max(1, Number(body.timeout) || 120))
    const timeoutMs = timeoutSec * 1000

    // notify UI to open tab (renderer will also track)
    onUiEvent({
      type: 'cli-connect',
      sessionId,
      hostId: h.id,
      host: h.host,
      port: h.port || 22,
      username: h.username || h.user || 'root',
      title: h.name || h.host,
    })

    // If CLI timeout wins the race, still-running engine.connect must not leave
    // an orphan session (and a dangling tab). Flag + post-complete disconnect.
    let timedOut = false
    const connectPromise = engine
      .connect({
        sessionId,
        hostId: h.id,
        host: h.host,
        port: Number(h.port) || 22,
        username: h.username || h.user || 'root',
        password,
        privateKey,
        privateKeyPath,
        passphrase: body.passphrase || h.passphrase,
        cols: 120,
        rows: 30,
      })
      .then((r) => {
        if (timedOut) {
          const sid = (r && r.sessionId) || sessionId
          try {
            engine.disconnect(sid)
          } catch (_) {}
          return { ok: false, error: `connect timeout ${timeoutSec}s`, sessionId: sid }
        }
        return r
      })
      .catch((e) => ({
        ok: false,
        error: (e && e.message) || String(e),
        sessionId,
      }))

    const raced = await Promise.race([
      connectPromise,
      new Promise((resolve) =>
        setTimeout(() => {
          timedOut = true
          resolve({ ok: false, error: `connect timeout ${timeoutSec}s`, sessionId })
        }, timeoutMs),
      ),
    ])

    if (raced && raced.ok) {
      onUiEvent({
        type: 'cli-connected',
        sessionId: raced.sessionId || sessionId,
        hostId: h.id,
        host: h.host,
        port: h.port || 22,
        username: h.username || h.user || 'root',
        title: h.name || h.host,
      })
      return {
        ok: true,
        sessionId: raced.sessionId || sessionId,
        host: h.host,
        port: h.port || 22,
        username: h.username || h.user || 'root',
        hostId: h.id,
      }
    }
    // Best-effort cleanup if session already registered under this id
    try {
      if (engine.sessions.has(sessionId)) engine.disconnect(sessionId)
    } catch (_) {}
    return {
      ok: false,
      sessionId: (raced && raced.sessionId) || sessionId,
      error: (raced && raced.error) || '连接失败',
    }
  }

  async function handleShell(body) {
    const sid = resolveSessionId(body.session || body.session_id || body.sessionId)
    if (!sid) return { ok: false, error: '会话不存在或 id 不唯一' }
    let text = body.text != null ? String(body.text) : body.cmd != null ? String(body.cmd) : ''
    if (body.cmd != null && body.text == null) {
      // shell --cmd auto newline
      if (!text.endsWith('\n') && !text.endsWith('\r')) text += '\n'
    } else if (body.newline === true || body.newline === '1') {
      if (!text.endsWith('\n') && !text.endsWith('\r')) text += '\n'
    } else if (body.no_newline === true || body.newline === false) {
      // leave as-is
    } else if (body.cmd != null) {
      if (!text.endsWith('\n')) text += '\n'
    }
    const r = engine.write(sid, text)
    return r && r.ok !== false ? { ok: true, sessionId: sid, bytes: Buffer.byteLength(text) } : { ok: false, error: (r && r.error) || 'write failed', sessionId: sid }
  }

  async function handleExec(body) {
    const sid = resolveSessionId(body.session || body.session_id || body.sessionId)
    if (!sid) return { ok: false, error: '会话不存在或 id 不唯一', stdout: '', stderr: '' }
    const cmd = body.cmd || body.command || body.text
    if (!cmd) return { ok: false, error: '缺少 cmd', stdout: '', stderr: '' }
    const timeoutSec = Math.min(900, Math.max(1, Number(body.timeout) || 120))
    const r = await engine.exec(sid, String(cmd), { timeoutMs: timeoutSec * 1000 })
    return {
      ok: !!(r && r.ok),
      sessionId: sid,
      stdout: (r && r.stdout) || '',
      stderr: (r && r.stderr) || '',
      error: (r && r.error) || null,
      code: r && r.code,
    }
  }

  function handleScreen(query, body) {
    const sid = resolveSessionId(
      (body && (body.session || body.session_id || body.sessionId)) ||
        query.session ||
        query.session_id ||
        query.s,
    )
    if (!sid) return { ok: false, error: '会话不存在或 id 不唯一', text: '', lines: [] }
    const all = query.all === '1' || query.all === 'true' || (body && body.all)
    const n = Number(query.lines || query.n || (body && body.lines)) || 200
    const buf = screenStore.get(sid) || ''
    // strip some ANSI for readability but keep raw available
    const raw = buf
    const lines = raw.split(/\r?\n/)
    const slice = all ? lines : lines.slice(-Math.max(1, n))
    return {
      ok: true,
      sessionId: sid,
      text: slice.join('\n'),
      lines: slice,
      totalLines: lines.length,
      rawLength: raw.length,
    }
  }

  async function handleSftpList(query, body) {
    const sid = resolveSessionId(
      (body && (body.session || body.session_id || body.sessionId)) || query.session || query.s,
    )
    if (!sid) return { ok: false, error: '会话不存在' }
    const remotePath = (body && (body.path || body.remote || body.remotePath)) || query.path || query.p || '/'
    return engine.sftpList(sid, remotePath)
  }

  /** Restrict CLI local paths to home / tmp / downloads (token-bearing callers). */
  function assertLocalPath(p, label) {
    const raw = String(p || '')
    if (!raw || raw.includes('\0')) throw new Error((label || 'path') + ' invalid')
    const resolved = path.resolve(raw)
    const roots = [
      os.homedir(),
      os.tmpdir(),
      path.join(os.homedir(), 'Downloads'),
      path.join(os.homedir(), 'Desktop'),
      tokenDir(),
    ]
    const ok = roots.some((root) => {
      const r = path.resolve(root)
      return resolved === r || resolved.startsWith(r + path.sep)
    })
    if (!ok) throw new Error((label || 'path') + ' not allowed: ' + resolved)
    return resolved
  }

  async function handleSftpDownload(body) {
    const sid = resolveSessionId(body.session || body.session_id || body.sessionId)
    if (!sid) return { ok: false, error: '会话不存在' }
    const remote = body.remote || body.remotePath || body.path
    if (!remote) return { ok: false, error: '缺少 remote' }
    let local = body.local || body.localPath
    if (!local) {
      local = path.join(os.tmpdir(), 'pixshell-dl-' + path.basename(String(remote).replace(/[/\\]/g, '_')))
    }
    try {
      local = assertLocalPath(local, 'local')
    } catch (e) {
      return { ok: false, error: e.message || String(e) }
    }
    return engine.sftpDownloadFile(sid, remote, local)
  }

  async function handleSftpUpload(body) {
    const sid = resolveSessionId(body.session || body.session_id || body.sessionId)
    if (!sid) return { ok: false, error: '会话不存在' }
    let local = body.local || body.localPath
    const remote = body.remote || body.remotePath
    if (!local || !remote) return { ok: false, error: '需要 local 与 remote' }
    try {
      local = assertLocalPath(local, 'local')
    } catch (e) {
      return { ok: false, error: e.message || String(e) }
    }
    if (!fs.existsSync(local)) return { ok: false, error: '本地文件不存在: ' + local }
    return engine.sftpUploadFile(sid, local, remote)
  }

  async function route(req, res, u, query, bodyObj) {
    const method = (req.method || 'GET').toUpperCase()
    let p = u.pathname || '/'
    // normalize trailing slash
    if (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1)

    // health — also used by CLI probe (optional auth for easy diagnostics)
    if (p === '/v1/health' || p === '/health') {
      return sendJson(res, 200, {
        ok: true,
        service: 'pixshell-agent-bridge',
        port: listeningPort,
        sessions: engine.sessions.size,
        enabled: true,
        nonce: query.nonce || null,
        ts: Date.now(),
      })
    }

    // auth for everything else
    const got = pickToken(req, query)
    if (!got || !timingSafeEqualStr(got, token)) {
      return sendJson(res, 401, { ok: false, error: 'Unauthorized — 检查 agent_token / Bearer' })
    }
    // 鉴权通过 = 外部 CLI/Agent 真正对接过（health 无 token 不算）
    lastClientAt = Date.now()
    lastClientPath = p

    // App API surface for external CLI
    if ((p === '/v1/app/hosts' || p === '/v1/app/host-list') && method === 'GET') {
      const all = hostList()
      if (query['group-id'] || query.group_id || query.g) {
        const gid = query['group-id'] || query.group_id || query.g
        const g = all.groups.find((x) => x.id === gid || x.name === gid)
        return sendJson(res, 200, {
          ok: true,
          group: g || null,
          hosts: g ? g.hosts : [],
        })
      }
      return sendJson(res, 200, all)
    }

    if ((p === '/v1/app/hosts/connect' || p === '/v1/app/connect')) {
      if (method !== 'POST') {
        return sendJson(res, 405, { ok: false, error: 'use POST (password must not go in query string)' })
      }
      const body = bodyObj || {}
      const r = await connectHost(body)
      return sendJson(res, r.ok ? 200 : 400, r)
    }

    if ((p === '/v1/app/sessions' || p === '/v1/app/list') && method === 'GET') {
      return sendJson(res, 200, sessionList())
    }

    if (p === '/v1/app/shell') {
      if (method !== 'POST') {
        return sendJson(res, 405, { ok: false, error: 'use POST' })
      }
      const r = await handleShell(bodyObj || {})
      return sendJson(res, r.ok ? 200 : 400, r)
    }

    if (p === '/v1/app/exec' || p === '/v1/app/direct') {
      if (method !== 'POST') {
        return sendJson(res, 405, { ok: false, error: 'use POST' })
      }
      const r = await handleExec(bodyObj || {})
      return sendJson(res, r.ok ? 200 : 400, r)
    }

    if ((p === '/v1/app/screen' || p === '/v1/app/read') && (method === 'GET' || method === 'POST')) {
      const r = handleScreen(query, bodyObj)
      return sendJson(res, r.ok ? 200 : 400, r)
    }

    if (p === '/v1/app/sftp/list' && (method === 'GET' || method === 'POST')) {
      const r = await handleSftpList(query, bodyObj)
      return sendJson(res, r.ok ? 200 : 400, r)
    }

    if (p === '/v1/app/sftp/download' && method === 'POST') {
      const r = await handleSftpDownload(bodyObj || {})
      return sendJson(res, r.ok ? 200 : 400, r)
    }

    if (p === '/v1/app/sftp/upload' && method === 'POST') {
      const r = await handleSftpUpload(bodyObj || {})
      return sendJson(res, r.ok ? 200 : 400, r)
    }

    // AI agent stubs — so tools probing /v1/ask don't crash; real LLM stays in external CLI
    if (p === '/v1/ask' || p === '/v1/execute' || p === '/v1/plan' || p === '/v1/models' || p === '/v1/providers') {
      return sendJson(res, 501, {
        ok: false,
        error:
          'PixShell 本地桥不内置 LLM。请用外部 Agent（Claude Code / Codex / OpenCode）+ pixshell-cli 操作会话。',
        hint: 'pixshell-cli sessions && pixshell-cli exec -s <id> -c "uname -a"',
      })
    }

    return sendJson(res, 404, { ok: false, error: 'not found: ' + p })
  }

  function onRequest(req, res) {
    // Never open browser cross-origin: omit Access-Control-Allow-Origin entirely
    // (no wildcard and no Origin reflection). Local CLI/tools do not need CORS.

    // only accept loopback (defense in depth; server already bound to 127.0.0.1)
    const ra = req.socket && req.socket.remoteAddress
    if (ra && !isLoopbackAddress(ra)) {
      secWarn('reject non-loopback', { remoteAddress: ra })
      return sendJson(res, 403, { ok: false, error: 'loopback only' })
    }

    if (!rateLimitAllow(ra || 'loopback')) {
      secWarn('rate limit', { remoteAddress: ra || 'loopback' })
      return sendJson(res, 429, { ok: false, error: 'rate limit' })
    }

    const method = (req.method || 'GET').toUpperCase()
    // Minimal OPTIONS without opening CORS to all origins
    if (method === 'OPTIONS') {
      res.writeHead(204, {
        'Content-Length': 0,
        'Cache-Control': 'no-store',
        Allow: 'GET, POST, OPTIONS',
      })
      return res.end()
    }

    let u
    try {
      u = new URL(req.url || '/', `http://127.0.0.1:${listeningPort || port}`)
    } catch {
      return sendJson(res, 400, { ok: false, error: 'bad url' })
    }
    const query = parseQuery(u)

    const needBody = method === 'POST' || method === 'PUT' || method === 'PATCH'

    const run = async () => {
      let bodyObj = null
      if (needBody) {
        const raw = await readBody(req)
        if (raw.length) {
          const ct = String(req.headers['content-type'] || '')
          if (ct.includes('application/json') || raw[0] === 0x7b || raw[0] === 0x5b) {
            try {
              bodyObj = JSON.parse(raw.toString('utf8'))
            } catch {
              return sendJson(res, 400, { ok: false, error: 'invalid json' })
            }
          } else {
            // form-ish key=value
            try {
              bodyObj = Object.fromEntries(new URLSearchParams(raw.toString('utf8')))
            } catch {
              bodyObj = { raw: raw.toString('utf8') }
            }
          }
        } else {
          bodyObj = {}
        }
      }
      await route(req, res, u, query, bodyObj)
    }

    run().catch((e) => {
      secWarn('request error', { error: (e && e.message) || String(e) })
      console.error('[PixShell agent-bridge]', e)
      if (!res.headersSent) sendJson(res, 500, { ok: false, error: e.message || String(e) })
    })
  }

  async function start(desiredPort) {
    if (server) await stop()
    token = ensureToken()
    port = Number(desiredPort) || Number(port) || DEFAULT_PORT
    enabled = true
    const maxPort = Math.max(port + 20, DEFAULT_PORT + 20)

    return new Promise((resolve, reject) => {
      let settled = false
      const fail = (err) => {
        if (settled) return
        settled = true
        try {
          server?.close?.()
        } catch (_) {}
        server = null
        enabled = false
        reject(err)
      }
      const tryListen = (p) => {
        const s = http.createServer(onRequest)
        server = s
        s.once('error', (err) => {
          console.error('[PixShell agent-bridge] listen error', err.message)
          try {
            s.close()
          } catch (_) {}
          if (err.code === 'EADDRINUSE' && p < maxPort) {
            tryListen(p + 1)
          } else {
            fail(err)
          }
        })
        s.listen(p, '127.0.0.1', () => {
          if (settled) return
          settled = true
          const addr = s.address()
          listeningPort = addr && addr.port ? addr.port : p
          port = listeningPort
          console.log(
            '[PixShell agent-bridge] http://127.0.0.1:' + listeningPort + ' (token in agent_token)',
          )
          resolve({ ok: true, port: listeningPort, tokenPath: tokenPath() })
        })
      }
      tryListen(port)
    })
  }

  async function stop() {
    enabled = false
    listeningPort = 0
    // 关闭桥后不再显示「已对接」
    lastClientAt = 0
    lastClientPath = '' 
    try {
      rateBuckets.clear()
    } catch (_) {}
    const s = server
    server = null
    if (!s) return { ok: true }
    return new Promise((resolve) => {
      try {
        s.close(() => resolve({ ok: true }))
      } catch {
        resolve({ ok: true })
      }
    })
  }

  function status() {
    const listening = !!(server && enabled && listeningPort)
    const clientSeen = lastClientAt > 0
    const clientIdleMs = clientSeen ? Math.max(0, Date.now() - lastClientAt) : null
    return {
      ok: true,
      enabled: listening, // 仅真正在听时视为已启用
      listening,
      settingsOn: !!enabled,
      port: listeningPort || port,
      tokenPath: tokenPath(),
      tokenPresent: !!token,
      sessions: engine.sessions.size,
      defaultPort: DEFAULT_PORT,
      // 外部对接：鉴权通过的请求才算 clientSeen（非仅监听）
      clientSeen,
      clientIdleMs,
      lastClientAt: lastClientAt || null,
      lastClientPath: lastClientPath || null,
    }
  }

  function getToken() {
    return token || ensureToken()
  }

  function rotateToken() {
    try {
      fs.unlinkSync(tokenPath())
    } catch (_) {}
    token = ensureToken()
    return token
  }

  return {
    start,
    stop,
    status,
    getToken,
    rotateToken,
    appendScreen,
    clearScreen,
    ensureToken,
    tokenPath,
    DEFAULT_PORT,
  }
}

module.exports = {
  createAgentBridge,
  ensureToken,
  tokenPath,
  tokenDir,
  DEFAULT_PORT,
}
