/**
 * ShellSession — interactive PTY channel over ssh2.
 * Own code; emits data/close; write/resize API mirrors BaseSession ideas.
 */
'use strict'

const { EventEmitter } = require('events')

class ShellSession extends EventEmitter {
  /**
   * @param {import('ssh2').ClientChannel} stream
   * @param {{ cols?: number, rows?: number, debug?: Function }} [opts]
   */
  constructor(stream, opts = {}) {
    super()
    this.stream = stream
    this.open = true
    this.cols = opts.cols || 120
    this.rows = opts.rows || 30
    this._debug = opts.debug || (() => {})
    /** optional OSC-reported cwd */
    this.reportedCwd = null

    stream.on('data', (data) => {
      const buf = Buffer.isBuffer(data) ? data : Buffer.from(data)
      this._maybeParseOscCwd(buf)
      this.emit('data', buf)
    })
    stream.stderr?.on('data', (data) => {
      this.emit('data', Buffer.isBuffer(data) ? data : Buffer.from(data))
    })
    stream.on('close', () => {
      this.open = false
      this._debug('shell closed')
      this.emit('close')
    })
    stream.on('error', (err) => {
      this.emit('error', err)
    })
  }

  write(data) {
    if (!this.open || !this.stream) return false
    try {
      this.stream.write(data)
      return true
    } catch (e) {
      this.emit('error', e)
      return false
    }
  }

  /** Resize remote PTY */
  resize(cols, rows) {
    this.cols = Number(cols) || this.cols
    this.rows = Number(rows) || this.rows
    if (!this.open || !this.stream) return
    try {
      this.stream.setWindow(this.rows, this.cols, 0, 0)
    } catch (e) {
      this._debug('resize failed', e.message)
    }
  }

  kill() {
    try {
      this.stream?.close?.()
    } catch (_) {}
    this.open = false
  }

  async destroy() {
    this.kill()
    this.removeAllListeners()
  }

  /**
   * Best-effort OSC 7 / OSC 1337 cwd parse.
   * @param {Buffer} buf
   */
  _maybeParseOscCwd(buf) {
    const s = buf.toString('utf8')
    // OSC 7 ; file://host/path ST
    let m = s.match(/\x1b\]7;file:\/\/[^/]*(\/[^\x07\x1b]*)/)
    if (m) {
      try {
        this.reportedCwd = decodeURIComponent(m[1])
        this.emit('cwd', this.reportedCwd)
      } catch (_) {}
      return
    }
    // iTerm OSC 1337 CurrentDir=
    m = s.match(/\x1b\]1337;CurrentDir=([^\x07\x1b]*)/)
    if (m) {
      this.reportedCwd = m[1]
      this.emit('cwd', this.reportedCwd)
    }
  }
}

module.exports = { ShellSession }
