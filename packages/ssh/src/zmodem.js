/**
 * Zmodem helpers + load zmodem.js for main bridge
 */
const path = require('path')
const fs = require('fs')
const os = require('os')

function loadZmodemModule() {
  const candidates = [
    'zmodem.js',
    path.join(process.cwd(), 'node_modules/zmodem.js'),
    path.join(__dirname, '../../../node_modules/zmodem.js'),
    path.join(os.homedir(), 'Library/Application Support/PixShell/app/node_modules/zmodem.js'),
  ]
  for (const c of candidates) {
    try {
      return require(c)
    } catch {}
  }
  return null
}

function createZmodemSession(opts = {}) {
  const mod = loadZmodemModule()
  if (!mod || !mod.Sentry) {
    return {
      kind: 'zmodem-stub',
      active: false,
      onShellData() {
        return { consumed: false }
      },
    }
  }
  // Prefer main-process bridge; this factory is for docs/tests
  const sentry = new mod.Sentry({
    to_terminal(octets) {
      if (opts.toTerminal) opts.toTerminal(octets)
    },
    sender(octets) {
      if (opts.writeBinary) opts.writeBinary(Buffer.from(octets).toString('base64'))
    },
    on_detect(detection) {
      if (opts.onDetect) opts.onDetect(detection)
    },
    on_retract() {
      if (opts.onRetract) opts.onRetract()
    },
  })
  return {
    kind: 'zmodemjs',
    active: true,
    sentry,
    onShellData(buf) {
      try {
        sentry.consume(buf instanceof Uint8Array ? buf : new Uint8Array(buf))
        return { consumed: true }
      } catch {
        return { consumed: false }
      }
    },
  }
}

function remoteSzCommand(remotePaths) {
  const list = (remotePaths || []).map((p) => shellQuote(p)).join(' ')
  return `sz -e -b ${list}`
}

function remoteRzCommand() {
  return 'rz -e -b'
}

function remoteCheckLrzsz() {
  return 'command -v sz; command -v rz; (sz --version 2>&1 || true) | head -1'
}

function shellQuote(p) {
  if (/^[a-zA-Z0-9_./~-]+$/.test(p)) return p
  return `'${String(p).replace(/'/g, `'\\''`)}'`
}

function buildSzPipeline(remotePaths) {
  return { remoteCommand: remoteSzCommand(remotePaths), localMode: 'receive' }
}
function buildRzPipeline() {
  return { remoteCommand: remoteRzCommand(), localMode: 'send' }
}

module.exports = {
  createZmodemSession,
  loadZmodemModule,
  remoteSzCommand,
  remoteRzCommand,
  remoteCheckLrzsz,
  REMOTE_SZ: 'sz',
  REMOTE_RZ: 'rz',
  buildSzPipeline,
  buildRzPipeline,
}
