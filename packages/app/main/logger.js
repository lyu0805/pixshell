/**
 * PixShell file logger — always-on runtime trail for freezes / SSH bugs.
 *
 * Writes to:
 *  1) <repo>/logs/pixshell-runtime.log  (when source tree is writable)
 *  2) <userData>/logs/pixshell-runtime.log  (APFS runtime, always)
 *  3) daily rotate: pixshell-YYYY-MM-DD.log in the same dirs
 *  4) pixshell-runtime.log 滚动保留最近 1000 行（MAX_RUNTIME_LINES）
 *
 * Never throws into callers. Safe before app.ready if userData path passed later.
 */
'use strict'

const fs = require('fs')
const path = require('path')
const os = require('os')

const MAX_BYTES = 8 * 1024 * 1024 // 8MB then rotate .1 (daily)
/** 运行时主日志 pixshell-runtime.log 保持最近 N 行滚动（铁律） */
const MAX_RUNTIME_LINES = 1000
const levels = { error: 0, warn: 1, info: 2, debug: 3 }

/** @type {string[]} */
let logDirs = []
let minLevel = 'debug'
let installedConsole = false
let seq = 0

function dayStamp(d = new Date()) {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function ts() {
  const d = new Date()
  return d.toISOString()
}

function ensureDir(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true })
    return true
  } catch {
    return false
  }
}

/**
 * @param {{ repoRoot?: string, userData?: string, level?: string }} opts
 */
function initLogger(opts = {}) {
  const dirs = []
  if (opts.repoRoot) {
    dirs.push(path.join(opts.repoRoot, 'logs'))
  }
  // Source tree on /Volumes/d (dev)
  try {
    const srcGuess = path.resolve(__dirname, '../../../..')
    if (fs.existsSync(path.join(srcGuess, 'packages', 'app', 'main'))) {
      dirs.push(path.join(srcGuess, 'logs'))
    }
  } catch (_) {}
  // Explicit /Volumes/d/pixshell when present
  if (fs.existsSync('/Volumes/d/pixshell/packages/app/main')) {
    dirs.push('/Volumes/d/pixshell/logs')
  }
  if (opts.userData) {
    dirs.push(path.join(opts.userData, 'logs'))
  } else {
    const ud =
      process.platform === 'darwin'
        ? path.join(os.homedir(), 'Library', 'Application Support', 'PixShell')
        : path.join(os.homedir(), '.local', 'share', 'PixShell')
    dirs.push(path.join(ud, 'logs'))
  }
  // unique preserve order
  const seen = new Set()
  logDirs = []
  for (const d of dirs) {
    const n = path.resolve(d)
    if (seen.has(n)) continue
    seen.add(n)
    if (ensureDir(n)) logDirs.push(n)
  }
  if (opts.level && levels[opts.level] != null) minLevel = opts.level
  writeRaw('INFO', 'logger', `init dirs=${logDirs.join(' | ')} pid=${process.pid} platform=${process.platform}`)
  return logDirs.slice()
}

function rotateIfNeeded(file) {
  try {
    const st = fs.statSync(file)
    if (st.size < MAX_BYTES) return
    const bak = file + '.1'
    try {
      fs.unlinkSync(bak)
    } catch (_) {}
    fs.renameSync(file, bak)
  } catch (_) {}
}

/** 将 runtime 日志裁到最近 MAX_RUNTIME_LINES 行（滚动） */
function trimRuntimeLog(file) {
  try {
    if (!fs.existsSync(file)) return
    const raw = fs.readFileSync(file, 'utf8')
    // 快路径：行数粗估
    let n = 0
    for (let i = 0; i < raw.length; i++) if (raw.charCodeAt(i) === 10) n++
    if (n <= MAX_RUNTIME_LINES) return
    const lines = raw.split('\n')
    // 末尾可能空串
    while (lines.length && lines[lines.length - 1] === '') lines.pop()
    if (lines.length <= MAX_RUNTIME_LINES) return
    const kept = lines.slice(-MAX_RUNTIME_LINES)
    fs.writeFileSync(file, kept.join('\n') + '\n', { encoding: 'utf8', mode: 0o600 })
  } catch (_) {}
}

// 每写若干条再 trim，避免每行都读整文件
let writeCountSinceTrim = 0

function writeRaw(level, tag, msg, extra) {
  if (levels[String(level).toLowerCase()] == null) level = 'INFO'
  const lv = String(level).toUpperCase()
  if (levels[lv.toLowerCase()] > levels[minLevel]) return
  seq++
  let line =
    `${ts()} ${lv.padEnd(5)} [${tag || 'app'}] #${seq} ${String(msg || '').replace(/\r?\n/g, ' | ')}`
  if (extra !== undefined) {
    try {
      const s = typeof extra === 'string' ? extra : JSON.stringify(extra)
      line += ' ' + s.slice(0, 4000)
    } catch (_) {
      line += ' [extra unreifiable]'
    }
  }
  line += '\n'
  writeCountSinceTrim++
  const doTrim = writeCountSinceTrim >= 20 || seq <= 3
  if (doTrim) writeCountSinceTrim = 0
  for (const dir of logDirs) {
    try {
      const main = path.join(dir, 'pixshell-runtime.log')
      const daily = path.join(dir, `pixshell-${dayStamp()}.log`)
      rotateIfNeeded(main)
      fs.appendFileSync(main, line, { encoding: 'utf8', mode: 0o600 })
      fs.appendFileSync(daily, line, { encoding: 'utf8', mode: 0o600 })
      if (doTrim) trimRuntimeLog(main)
    } catch (_) {
      /* ignore disk errors */
    }
  }
}

function log(level, tag, msg, extra) {
  try {
    writeRaw(level, tag, msg, extra)
  } catch (_) {}
}

const api = {
  init: initLogger,
  dirs: () => logDirs.slice(),
  debug: (tag, msg, extra) => log('debug', tag, msg, extra),
  info: (tag, msg, extra) => log('info', tag, msg, extra),
  warn: (tag, msg, extra) => log('warn', tag, msg, extra),
  error: (tag, msg, extra) => log('error', tag, msg, extra),
  /**
   * Mirror console.* into files (once).
   */
  installConsoleMirror() {
    if (installedConsole) return
    installedConsole = true
    const wrap = (level, orig) =>
      function mirrored(...args) {
        try {
          const msg = args
            .map((a) => {
              if (typeof a === 'string') return a
              try {
                return JSON.stringify(a)
              } catch {
                return String(a)
              }
            })
            .join(' ')
          writeRaw(level, 'console', msg)
        } catch (_) {}
        return orig.apply(console, args)
      }
    console.log = wrap('info', console.log.bind(console))
    console.info = wrap('info', console.info.bind(console))
    console.warn = wrap('warn', console.warn.bind(console))
    console.error = wrap('error', console.error.bind(console))
  },
  installProcessHandlers() {
    process.on('uncaughtException', (err) => {
      writeRaw('error', 'process', 'uncaughtException ' + (err && err.stack ? err.stack : err))
    })
    process.on('unhandledRejection', (reason) => {
      const s = reason && reason.stack ? reason.stack : String(reason)
      writeRaw('error', 'process', 'unhandledRejection ' + s)
    })
  },
}

module.exports = api
