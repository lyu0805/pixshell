const fs = require('fs')
const path = require('path')
const { app } = require('electron')
const os = require('os')

function resolveSsh2() {
  const candidates = [
    'ssh2',
    path.join(process.cwd(), 'node_modules/ssh2'),
    path.join(__dirname, '../../../node_modules/ssh2'),
    path.join(__dirname, '../../../../node_modules/ssh2'),
    path.join(os.homedir(), 'Library/Application Support/PixShell/app/node_modules/ssh2'),
  ]
  for (const c of candidates) {
    try {
      return require(c)
    } catch {}
  }
  return null
}

const ssh2mod = resolveSsh2()
const Client = ssh2mod ? ssh2mod.Client : null

function dataDir() {
  const dir = path.join(app.getPath('userData'), 'pixshell')
  fs.mkdirSync(dir, { recursive: true })
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
  fs.writeFileSync(file, JSON.stringify(data, null, 2), 'utf8')
}

class SshSessionHub {
  constructor() {
    /** @type {Map<string, any>} */
    this.sessions = new Map()
    this.payloads = new Map()
    this.reconnectTimers = new Map()
    this.onData = null
    this.onStatus = null
    this.autoReconnect = true
    this.maxReconnectAttempts = 5
  }

  setDataHandler(fn) {
    this.onData = fn
  }
  setStatusHandler(fn) {
    this.onStatus = fn
  }

  _emitStatus(id, status, message) {
    if (this.onStatus) this.onStatus(id, status, message)
  }
  _emitData(id, buf) {
    if (this.onData) this.onData(id, buf)
  }

  ssh2Ready() {
    return !!Client
  }

  loadHosts() {
    const file = path.join(dataDir(), 'hosts.json')
    const demo = []
    const hosts = readJson(file, demo)
    if (!fs.existsSync(file)) writeJson(file, hosts)
    return hosts
  }

  saveHosts(hosts) {
    writeJson(path.join(dataDir(), 'hosts.json'), hosts)
    return true
  }

  loadSettings() {
    const file = path.join(dataDir(), 'settings.json')
    const defaults = {
      theme: 'chalkboard',
      colorScheme: 'chalkboard',
      fontSize: 12,
      fontFamily: 'DejaVu Sans Mono, Cascadia Mono, Sarasa Mono SC, Menlo, Consolas, monospace',
      showSidebar: true,
      syncDirWithSftp: true,
      bgImgEnable: false,
      bgImg: '',
      bgImgBlurLevel: 4,
      downloadPath: '',
      uploadPath: '',
      proxyList: [],
      monitorIntervalSec: 5,
      multiPingTargets: ['1.1.1.1', '8.8.8.8', '114.114.114.114', 'www.baidu.com'],
      autoReconnect: true,
      layout: {
        leftSideWidth: 200,
        leftSideBottomHeight: 160,
        centerBottomHeight: 220,
        commandDividerLocation: 600,
      },
      commandInput: {
        cleanAfterSend: true,
        ignoreBlankLine: true,
        appendCr: true,
        promptEnable: true,
      },
      accelerate: {
        enabled: false,
        protocol: 'udp',
        server_port: 150,
        direct_cn: true,
        server_host: '',
        interoperable: false,
        note: 'accelerate relay not connected',
      },
    }
    const s = readJson(file, defaults)
    if (!fs.existsSync(file)) writeJson(file, s)
    return s
  }

  saveSettings(settings) {
    writeJson(path.join(dataDir(), 'settings.json'), settings)
    return true
  }

  /**
   * @param {{sessionId?: string, host: string, port?: number, username: string, password?: string, privateKey?: string, passphrase?: string, proxy?: object}} payload
   */
  connect(payload) {
    const sessionId =
      payload.sessionId ||
      `sess_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 7)}`
    const self = this

    if (!Client) {
      const err =
        'ssh2 模块未加载。请在运行目录执行: npm install ssh2 --prefix "' +
        path.join(os.homedir(), 'Library/Application Support/PixShell/app') +
        '"'
      this._emitStatus(sessionId, 'error', err)
      return Promise.resolve({ ok: false, sessionId, error: err, mock: false })
    }

    if (!payload.host) {
      return Promise.resolve({ ok: false, sessionId, error: '主机地址为空' })
    }
    if (!payload.username) {
      return Promise.resolve({ ok: false, sessionId, error: '用户名为空' })
    }
    if (!payload.password && !payload.privateKey) {
      return Promise.resolve({
        ok: false,
        sessionId,
        error: '未提供密码或私钥（连接对话框填写密码后点「保存并连接」）',
      })
    }

    return new Promise(async (resolve) => {
      const conn = new Client()
      const entry = {
        mock: false,
        conn,
        stream: null,
        sftp: null,
        cwd: '~',
        proxy: payload.proxy || null,
        manualClose: false,
      }
      self.sessions.set(sessionId, entry)
      self.payloads.set(sessionId, { ...payload, sessionId })
      self._emitStatus(sessionId, 'connecting', `${payload.username}@${payload.host}:${payload.port || 22}`)

      const cfg = {
        host: String(payload.host).trim(),
        port: Number(payload.port) || 22,
        username: String(payload.username).trim(),
        password: payload.password || undefined,
        privateKey: payload.privateKey || undefined,
        passphrase: payload.passphrase || undefined,
        readyTimeout: 20000,
        keepaliveInterval: 15000,
        tryKeyboard: true,
        algorithms: undefined,
      }

      if (payload.proxy && payload.proxy.host) {
        const px = payload.proxy
        const ptype = px.type || 'socks5'
        if (ptype === 'socks5' || ptype === 'socks4') {
          try {
            const { SocksClient } = require('socks')
            const { socket } = await SocksClient.createConnection({
              proxy: {
                host: px.host,
                port: Number(px.port) || 1080,
                type: ptype === 'socks4' ? 4 : 5,
                userId: px.username || undefined,
                password: px.password || undefined,
              },
              command: 'connect',
              destination: { host: cfg.host, port: cfg.port },
              timeout: 20000,
            })
            cfg.sock = socket
            self._emitData(sessionId, Buffer.from(`\r\n[proxy] SOCKS ok → ${cfg.host}:${cfg.port}\r\n`))
          } catch (e) {
            self._emitStatus(sessionId, 'error', '代理失败: ' + e.message)
            self.sessions.delete(sessionId)
            resolve({ ok: false, sessionId, error: '代理失败: ' + e.message })
            return
          }
        }
      }

      conn
        .on('ready', () => {
          conn.shell({ term: 'xterm-256color', cols: 120, rows: 30 }, (err, stream) => {
            if (err) {
              self._emitStatus(sessionId, 'error', err.message)
              try {
                conn.end()
              } catch {}
              self.sessions.delete(sessionId)
              resolve({ ok: false, sessionId, error: err.message })
              return
            }
            entry.stream = stream
            stream.on('data', (data) => self._emitData(sessionId, data))
            stream.on('close', () => {
              self._emitStatus(sessionId, 'closed', 'shell closed')
              const was = self.sessions.get(sessionId)
              self.sessions.delete(sessionId)
              if (self.autoReconnect && was && !was.manualClose) {
                self._scheduleReconnect(sessionId)
              } else {
                self.payloads.delete(sessionId)
              }
            })
            stream.stderr?.on('data', (data) => self._emitData(sessionId, data))
            conn.sftp((e2, sftp) => {
              if (!e2) entry.sftp = sftp
              else self._emitData(sessionId, Buffer.from(`\r\n[sftp] ${e2.message}\r\n`))
            })
            self._emitStatus(sessionId, 'connected', '')
            resolve({ ok: true, sessionId, mock: false })
          })
        })
        .on('keyboard-interactive', (name, instructions, lang, prompts, finish) => {
          // reply with password for all prompts
          const pw = payload.password || ''
          finish(prompts.map(() => pw))
        })
        .on('error', (err) => {
          const msg = err && err.message ? err.message : String(err)
          const code = err && err.code ? ' (' + err.code + ')' : ''
          const full = msg + code
          self._emitStatus(sessionId, 'error', full)
          self.sessions.delete(sessionId)
          resolve({ ok: false, sessionId, error: full })
        })
        .on('timeout', () => {
          self._emitStatus(sessionId, 'error', '连接超时')
          try { conn.end() } catch {}
          self.sessions.delete(sessionId)
          resolve({ ok: false, sessionId, error: '连接超时 (readyTimeout)' })
        })
        .connect(cfg)
    })
  }

  disconnect(sessionId) {
    const s = this.sessions.get(sessionId)
    this._clearReconnect(sessionId)
    if (s) s.manualClose = true
    if (!s) {
      this.payloads.delete(sessionId)
      return { ok: true }
    }
    try {
      s.stream?.close?.()
      s.conn?.end?.()
    } catch {}
    this.sessions.delete(sessionId)
    this.payloads.delete(sessionId)
    this._emitStatus(sessionId, 'closed', 'manual')
    return { ok: true }
  }

  _clearReconnect(sessionId) {
    const t = this.reconnectTimers.get(sessionId)
    if (t) clearTimeout(t)
    this.reconnectTimers.delete(sessionId)
  }

  _scheduleReconnect(sessionId) {
    this._clearReconnect(sessionId)
    const payload = this.payloads.get(sessionId)
    if (!payload) return
    const attempt = (payload._attempt || 0) + 1
    if (attempt > this.maxReconnectAttempts) {
      this._emitStatus(sessionId, 'error', '重连失败（已达最大次数）')
      this.payloads.delete(sessionId)
      return
    }
    payload._attempt = attempt
    const delay = Math.min(30000, 1000 * Math.pow(2, attempt - 1))
    this._emitStatus(sessionId, 'reconnecting', `第 ${attempt} 次，${delay}ms 后…`)
    const timer = setTimeout(() => {
      this.reconnectTimers.delete(sessionId)
      this.connect({ ...payload, sessionId, _attempt: attempt })
        .then((r) => {
          if (r && r.ok) {
            const p = this.payloads.get(sessionId)
            if (p) p._attempt = 0
          } else {
            this._scheduleReconnect(sessionId)
          }
        })
        .catch(() => this._scheduleReconnect(sessionId))
    }, delay)
    this.reconnectTimers.set(sessionId, timer)
  }

  reconnect(sessionId) {
    const payload = this.payloads.get(sessionId)
    if (!payload) return Promise.resolve({ ok: false, error: '无重连凭据，请重新连接主机' })
    this._clearReconnect(sessionId)
    const s = this.sessions.get(sessionId)
    if (s) {
      s.manualClose = true
      try {
        s.stream?.close?.()
        s.conn?.end?.()
      } catch {}
      this.sessions.delete(sessionId)
    }
    payload._attempt = 0
    return this.connect({ ...payload, sessionId })
  }

  setAutoReconnect(enabled) {
    this.autoReconnect = !!enabled
    return { ok: true, autoReconnect: this.autoReconnect }
  }

  writeBinary(sessionId, base64) {
    const s = this.sessions.get(sessionId)
    if (!s) return { ok: false, error: 'no session' }
    if (!s.stream) return { ok: false, error: 'no shell' }
    try {
      s.stream.write(Buffer.from(base64 || '', 'base64'))
      return { ok: true }
    } catch (e) {
      return { ok: false, error: e.message }
    }
  }

  write(sessionId, data) {
    const s = this.sessions.get(sessionId)
    if (!s) return { ok: false, error: 'no session' }
    if (!s.stream) return { ok: false, error: 'no shell' }
    s.stream.write(data)
    return { ok: true }
  }

  resize(sessionId, cols, rows) {
    const s = this.sessions.get(sessionId)
    if (!s?.stream?.setWindow) return { ok: true }
    try {
      s.stream.setWindow(rows, cols, 0, 0)
    } catch {}
    return { ok: true }
  }

  exec(sessionId, command) {
    const s = this.sessions.get(sessionId)
    if (!s) return Promise.resolve({ ok: false, error: 'no session' })
    if (!s.conn) return Promise.resolve({ ok: false, error: 'no connection' })
    return new Promise((resolve) => {
      s.conn.exec(command, (err, stream) => {
        if (err) return resolve({ ok: false, error: err.message })
        let stdout = ''
        let stderr = ''
        stream.on('data', (d) => (stdout += d.toString('utf8')))
        stream.stderr.on('data', (d) => (stderr += d.toString('utf8')))
        stream.on('close', (code) => resolve({ ok: true, code, stdout, stderr }))
      })
    })
  }

  sftpList(sessionId, remotePath) {
    const s = this.sessions.get(sessionId)
    if (!s) return Promise.resolve({ ok: false, error: 'no session' })
    if (!s.sftp) return Promise.resolve({ ok: false, error: 'SFTP 未就绪，请稍候再试' })
    const p = remotePath || '.'
    return new Promise((resolve) => {
      s.sftp.readdir(p, (err, list) => {
        if (err) return resolve({ ok: false, error: err.message })
        const entries = list.map((item) => ({
          name: item.filename,
          isDir: (item.attrs.mode & 0o170000) === 0o040000,
          size: item.attrs.size || 0,
          modifyTime: (item.attrs.mtime || 0) * 1000,
          rights: item.longname,
        }))
        resolve({ ok: true, path: p, entries })
      })
    })
  }

  sftpRead(sessionId, remotePath) {
    const s = this.sessions.get(sessionId)
    if (!s) return Promise.resolve({ ok: false, error: 'no session' })
    if (!s.sftp) return Promise.resolve({ ok: false, error: 'SFTP 未就绪' })
    return new Promise((resolve) => {
      const chunks = []
      const rs = s.sftp.createReadStream(remotePath)
      rs.on('data', (c) => chunks.push(c))
      rs.on('error', (e) => resolve({ ok: false, error: e.message }))
      rs.on('close', () => resolve({ ok: true, dataBase64: Buffer.concat(chunks).toString('base64') }))
    })
  }

  sftpWrite(sessionId, remotePath, dataBuf) {
    const s = this.sessions.get(sessionId)
    if (!s) return Promise.resolve({ ok: false, error: 'no session' })
    if (!s.sftp) return Promise.resolve({ ok: false, error: 'SFTP 未就绪' })
    return new Promise((resolve) => {
      const ws = s.sftp.createWriteStream(remotePath)
      ws.on('error', (e) => resolve({ ok: false, error: e.message }))
      ws.on('close', () => resolve({ ok: true }))
      ws.end(dataBuf || Buffer.alloc(0))
    })
  }

  sftpDownloadFile(sessionId, remotePath, localPath) {
    const s = this.sessions.get(sessionId)
    if (!s) return Promise.resolve({ ok: false, error: 'no session' })
    if (!s.sftp) return Promise.resolve({ ok: false, error: 'SFTP 未就绪' })
    return new Promise((resolve) => {
      s.sftp.fastGet(remotePath, localPath, (err) => {
        if (err) resolve({ ok: false, error: err.message })
        else resolve({ ok: true, localPath })
      })
    })
  }

  sftpUploadFile(sessionId, localPath, remotePath) {
    const s = this.sessions.get(sessionId)
    if (!s) return Promise.resolve({ ok: false, error: 'no session' })
    if (!s.sftp) return Promise.resolve({ ok: false, error: 'SFTP 未就绪' })
    return new Promise((resolve) => {
      s.sftp.fastPut(localPath, remotePath, (err) => {
        if (err) resolve({ ok: false, error: err.message })
        else resolve({ ok: true, remotePath })
      })
    })
  }

  sftpMkdir(sessionId, remotePath) {
    const s = this.sessions.get(sessionId)
    if (!s?.sftp) return Promise.resolve({ ok: false, error: 'SFTP 未就绪' })
    return new Promise((resolve) => {
      s.sftp.mkdir(remotePath, (err) => resolve(err ? { ok: false, error: err.message } : { ok: true }))
    })
  }

  sftpUnlink(sessionId, remotePath, isDir) {
    const s = this.sessions.get(sessionId)
    if (!s?.sftp) return Promise.resolve({ ok: false, error: 'SFTP 未就绪' })
    return new Promise((resolve) => {
      const fn = isDir ? s.sftp.rmdir.bind(s.sftp) : s.sftp.unlink.bind(s.sftp)
      fn(remotePath, (err) => resolve(err ? { ok: false, error: err.message } : { ok: true }))
    })
  }

  sftpRename(sessionId, from, to) {
    const s = this.sessions.get(sessionId)
    if (!s?.sftp) return Promise.resolve({ ok: false, error: 'SFTP 未就绪' })
    return new Promise((resolve) => {
      s.sftp.rename(from, to, (err) => resolve(err ? { ok: false, error: err.message } : { ok: true }))
    })
  }

  closeAll() {
    for (const id of [...this.sessions.keys()]) this.disconnect(id)
  }
}

module.exports = { SshSessionHub }
