/**
 * SSHMultiplexer — shared control connection for multiple shells:
 * reuse one control connection per host:port:user:proxy key when reuseSession is true.
 * Own implementation.
 */
'use strict'

class SSHMultiplexer {
  constructor() {
    /** @type {Map<string, import('./ssh-session').SSHSession>} */
    this._sessions = new Map()
  }

  /**
   * @param {object} profile
   */
  keyFor(profile) {
    const host = profile.host || ''
    const port = profile.port || 22
    const user = profile.user || profile.username || ''
    const px = profile.proxy
    const proxyKey = px ? `${px.type || 'socks5'}:${px.host}:${px.port}` : ''
    return `${host}:${port}:${user}:${proxyKey}`
  }

  /**
   * @param {import('./ssh-session').SSHSession} session
   */
  add(session) {
    const key = this.keyFor(session.profile)
    this._sessions.set(key, session)
    session.once('destroyed', () => {
      if (this._sessions.get(key) === session) this._sessions.delete(key)
    })
    session.once('close', () => {
      // keep until destroy for brief reconnect windows
    })
  }

  /**
   * @param {object} profile
   * @returns {import('./ssh-session').SSHSession|null}
   */
  get(profile) {
    const key = this.keyFor(profile)
    const s = this._sessions.get(key)
    if (s && s.authenticated && !s.destroyed) return s
    if (s) this._sessions.delete(key)
    return null
  }

  remove(session) {
    for (const [k, v] of this._sessions) {
      if (v === session) this._sessions.delete(k)
    }
  }

  clear() {
    for (const s of this._sessions.values()) {
      try {
        s.destroy()
      } catch (_) {}
    }
    this._sessions.clear()
  }

  get size() {
    return this._sessions.size
  }
}

module.exports = { SSHMultiplexer }
