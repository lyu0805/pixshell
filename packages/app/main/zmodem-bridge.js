/**
 * Main-process ZMODEM bridge using zmodem.js Sentry.
 * Receives binary shell octets, detects sessions, saves received files via dialog.
 */
const path = require('path')
const fs = require('fs')
const { dialog } = require('electron')

function loadZmodem() {
  const candidates = [
    'zmodem.js',
    path.join(process.cwd(), 'node_modules/zmodem.js'),
    path.join(__dirname, '../../../node_modules/zmodem.js'),
    path.join(__dirname, '../../../../node_modules/zmodem.js'),
  ]
  // also Absolute runtime path
  const home = require('os').homedir()
  candidates.push(path.join(home, 'Library/Application Support/PixShell/app/node_modules/zmodem.js'))
  for (const c of candidates) {
    try {
      const m = require(c)
      return m.Zmodem || m
    } catch {}
  }
  // dist browser bundle exposes window.Zmodem - skip
  try {
    const dist = path.join(home, 'Library/Application Support/PixShell/app/node_modules/zmodem.js/dist/zmodem.js')
    if (fs.existsSync(dist)) {
      // not usable in node easily (sets window)
    }
  } catch {}
  return null
}

class ZmodemBridge {
  constructor(hub, getWindow) {
    this.hub = hub
    this.getWindow = getWindow
    this.bySession = new Map() // sessionId -> { sentry, active }
    this.Zmodem = loadZmodem()
  }

  available() {
    return !!this.Zmodem && !!this.Zmodem.Sentry
  }

  ensure(sessionId) {
    if (!this.available()) return null
    if (this.bySession.has(sessionId)) return this.bySession.get(sessionId)
    const self = this
    const entry = { active: false, sentry: null }
    entry.sentry = new this.Zmodem.Sentry({
      to_terminal(octets) {
        // pass through text to renderer as utf8
        try {
          const buf = Buffer.from(octets)
          if (self.hub.onData) self.hub.onData(sessionId, buf)
        } catch {}
      },
      sender(octets) {
        try {
          self.hub.writeBinary(sessionId, Buffer.from(octets).toString('base64'))
        } catch {}
      },
      on_detect(detection) {
        try {
          const zsession = detection.confirm()
          entry.active = true
          self._notify(sessionId, 'detect', { type: zsession.type })
          if (zsession.type === 'receive') {
            zsession.on('offer', (xfer) => {
              const details = xfer.get_details()
              self._notify(sessionId, 'offer', { name: details.name, size: details.size })
              xfer
                .accept()
                .then(() => {
                  const payloads = xfer.get_payloads()
                  const buf = Buffer.concat(payloads.map((p) => Buffer.from(p)))
                  return self._saveReceived(details.name || 'download.bin', buf)
                })
                .then((saved) => {
                  self._notify(sessionId, 'received', saved)
                  entry.active = false
                })
                .catch((e) => {
                  self._notify(sessionId, 'error', { error: e.message || String(e) })
                  entry.active = false
                })
            })
            zsession.start()
          } else if (zsession.type === 'send') {
            // wait for sendFile call
            entry.sendSession = zsession
            self._notify(sessionId, 'send-ready', {})
          }
          zsession.on('session_end', () => {
            entry.active = false
            entry.sendSession = null
            self._notify(sessionId, 'end', {})
          })
        } catch (e) {
          try {
            detection.deny()
          } catch {}
          self._notify(sessionId, 'error', { error: e.message || String(e) })
        }
      },
      on_retract() {
        entry.active = false
        self._notify(sessionId, 'retract', {})
      },
    })
    this.bySession.set(sessionId, entry)
    return entry
  }

  consume(sessionId, buf) {
    const entry = this.ensure(sessionId)
    if (!entry || !entry.sentry) return false
    try {
      const u8 = buf instanceof Uint8Array ? buf : new Uint8Array(buf)
      entry.sentry.consume(u8)
      return entry.active
    } catch {
      return false
    }
  }

  async sendFile(sessionId, localPath) {
    const entry = this.ensure(sessionId)
    if (!entry) return { ok: false, error: 'zmodem not available' }
    // Trigger remote rz then wait - simpler path: use SFTP
    // For true zmodem send we need an active send session (remote ran rz)
    if (!entry.sendSession) {
      return { ok: false, error: 'no active send session — remote must run rz first' }
    }
    const Z = this.Zmodem
    // Node file send without Browser: manual offer
    try {
      const data = fs.readFileSync(localPath)
      const name = path.basename(localPath)
      const offer = {
        name,
        size: data.length,
        mtime: Math.floor(fs.statSync(localPath).mtimeMs / 1000),
        mode: 0o100644,
      }
      // Session.Send API: send_offer
      if (typeof entry.sendSession.send_offer === 'function') {
        const xfer = await entry.sendSession.send_offer(offer)
        if (!xfer) return { ok: false, error: 'offer skipped' }
        // send in chunks
        const chunk = 1024 * 16
        for (let i = 0; i < data.length; i += chunk) {
          const slice = data.subarray(i, Math.min(i + chunk, data.length))
          if (i + chunk >= data.length) {
            await xfer.end(slice)
          } else {
            xfer.send(slice)
          }
        }
        return { ok: true, name, size: data.length }
      }
      return { ok: false, error: 'send_offer not available in this zmodem build' }
    } catch (e) {
      return { ok: false, error: e.message }
    }
  }

  async _saveReceived(name, buf) {
    const win = this.getWindow && this.getWindow()
    const r = await dialog.showSaveDialog(win || undefined, {
      title: 'ZMODEM 接收保存',
      defaultPath: name,
    })
    if (r.canceled || !r.filePath) return { ok: false, error: 'cancelled', name }
    fs.writeFileSync(r.filePath, buf)
    return { ok: true, path: r.filePath, name, size: buf.length }
  }

  _notify(sessionId, event, payload) {
    const win = this.getWindow && this.getWindow()
    if (win && !win.isDestroyed()) {
      win.webContents.send('zmodem:event', { sessionId, event, ...payload })
    }
  }

  destroy(sessionId) {
    this.bySession.delete(sessionId)
  }
}

module.exports = { ZmodemBridge, loadZmodem }
