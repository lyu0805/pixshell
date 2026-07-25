/**
 * RDP session — spawn system remote desktop client
 */
const { spawn } = require('child_process')

function buildRdpUrl({ host, port = 3389, username }) {
  const h = host || '127.0.0.1'
  const p = Number(port) || 3389
  const user = username ? `${username}@` : ''
  return `rdp://${user}${h}:${p}`
}

function launchRdp({ host, port = 3389, username } = {}) {
  if (!host) return { ok: false, error: 'host required' }
  const platform = process.platform
  if (platform === 'darwin') {
    const url = buildRdpUrl({ host, port, username })
    spawn('open', [url], { detached: true, stdio: 'ignore' }).unref()
    return { ok: true, method: 'open-rdp-url', url }
  }
  if (platform === 'win32') {
    const target = port === 3389 ? host : `${host}:${port}`
    spawn('mstsc', [`/v:${target}`], { detached: true, stdio: 'ignore' }).unref()
    return { ok: true, method: 'mstsc', target }
  }
  const args = [`/v:${host}:${port}`]
  if (username) args.push(`/u:${username}`)
  spawn('xfreerdp', args, { detached: true, stdio: 'ignore' }).unref()
  return { ok: true, method: 'xfreerdp', args }
}

module.exports = { launchRdp, buildRdpUrl }
