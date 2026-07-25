/**
 * Real ssh2 client implementing SshClient contract.
 * Used by Electron main hub (currently inlined in ssh-hub.js for require simplicity).
 * This module is the portable version for tests / non-electron hosts.
 */

let Client
try {
  ;({ Client } = require('ssh2'))
} catch {
  Client = null
}

/**
 * @returns {import('./index').SshClient}
 */
function createSsh2Client() {
  if (!Client) {
    const { createMockSshClient } = require('./index')
    return createMockSshClient()
  }

  /** @type {import('ssh2').Client | null} */
  let conn = null
  /** @type {import('ssh2').ClientChannel | null} */
  let shellStream = null
  /** @type {import('ssh2').SFTPWrapper | null} */
  let sftp = null

  return {
    async connect(opts) {
      if (conn) await this.disconnect()
      conn = new Client()
      await new Promise((resolve, reject) => {
        conn
          .on('ready', resolve)
          .on('error', reject)
          .connect({
            host: opts.host,
            port: opts.port || 22,
            username: opts.username,
            password: opts.password,
            privateKey: opts.privateKey,
            passphrase: opts.passphrase,
            readyTimeout: opts.readyTimeoutMs || 20000,
            keepaliveInterval: opts.keepaliveIntervalMs || 15000,
          })
      })
      sftp = await new Promise((resolve, reject) => {
        conn.sftp((err, s) => (err ? reject(err) : resolve(s)))
      })
    },

    async disconnect() {
      try {
        shellStream?.close?.()
      } catch {}
      try {
        conn?.end?.()
      } catch {}
      conn = null
      shellStream = null
      sftp = null
    },

    async shell() {
      if (!conn) throw new Error('not connected')
      shellStream = await new Promise((resolve, reject) => {
        conn.shell({ term: 'xterm-256color' }, (err, stream) => (err ? reject(err) : resolve(stream)))
      })
      const stream = shellStream
      return {
        write(data) {
          stream.write(data)
        },
        resize(cols, rows) {
          stream.setWindow(rows, cols, 0, 0)
        },
        async *[Symbol.asyncIterator]() {
          const queue = []
          let pending = null
          let ended = false
          stream.on('data', (buf) => {
            if (pending) {
              pending({ value: buf, done: false })
              pending = null
            } else queue.push(buf)
          })
          stream.on('close', () => {
            ended = true
            if (pending) pending({ value: undefined, done: true })
          })
          while (!ended || queue.length) {
            if (queue.length) {
              yield queue.shift()
              continue
            }
            const r = await new Promise((resolve) => {
              pending = resolve
            })
            if (r.done) return
            yield r.value
          }
        },
      }
    },

    async exec(command) {
      if (!conn) throw new Error('not connected')
      return new Promise((resolve, reject) => {
        conn.exec(command, (err, stream) => {
          if (err) return reject(err)
          let stdout = ''
          let stderr = ''
          stream.on('data', (d) => (stdout += d.toString('utf8')))
          stream.stderr.on('data', (d) => (stderr += d.toString('utf8')))
          stream.on('close', (code) => resolve({ code, stdout, stderr }))
        })
      })
    },

    async sftpList(remotePath) {
      if (!sftp) throw new Error('sftp not ready')
      const list = await new Promise((resolve, reject) => {
        sftp.readdir(remotePath || '.', (err, l) => (err ? reject(err) : resolve(l)))
      })
      return list.map((item) => ({
        name: item.filename,
        path: `${remotePath || '.'}/${item.filename}`,
        isDir: (item.attrs.mode & 0o170000) === 0o040000,
        size: item.attrs.size || 0,
        modifyTime: (item.attrs.mtime || 0) * 1000,
        rights: item.longname,
      }))
    },

    async sftpRead(remotePath) {
      if (!sftp) throw new Error('sftp not ready')
      return new Promise((resolve, reject) => {
        const chunks = []
        const rs = sftp.createReadStream(remotePath)
        rs.on('data', (c) => chunks.push(c))
        rs.on('error', reject)
        rs.on('close', () => resolve(Buffer.concat(chunks)))
      })
    },

    async sftpWrite(remotePath, data) {
      if (!sftp) throw new Error('sftp not ready')
      return new Promise((resolve, reject) => {
        const ws = sftp.createWriteStream(remotePath)
        ws.on('error', reject)
        ws.on('close', resolve)
        ws.end(data)
      })
    },

    async sftpMkdir(remotePath) {
      if (!sftp) throw new Error('sftp not ready')
      return new Promise((resolve, reject) => {
        sftp.mkdir(remotePath, (err) => (err ? reject(err) : resolve()))
      })
    },

    async sftpRemove(remotePath) {
      if (!sftp) throw new Error('sftp not ready')
      return new Promise((resolve, reject) => {
        sftp.unlink(remotePath, (err) => {
          if (!err) return resolve()
          sftp.rmdir(remotePath, (e2) => (e2 ? reject(e2) : resolve()))
        })
      })
    },

    async probeCwd() {
      const r = await this.exec('pwd')
      return (r.stdout || '').trim().split(/\r?\n/)[0] || '~'
    },
  }
}

module.exports = { createSsh2Client }
