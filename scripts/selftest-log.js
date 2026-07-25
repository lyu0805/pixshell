#!/usr/bin/env node
/**
 * PixShell self-test with file log — run without UI.
 * node scripts/selftest-log.js
 */
'use strict'

const fs = require('fs')
const path = require('path')
const os = require('os')

const LOG_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'PixShell', 'logs')
const LOG_FILE = path.join(LOG_DIR, `selftest-${new Date().toISOString().replace(/[:.]/g, '-')}.log`)
const LATEST = path.join(LOG_DIR, 'selftest-latest.log')

fs.mkdirSync(LOG_DIR, { recursive: true })

const lines = []
function log(...a) {
  const s = a.map((x) => (typeof x === 'string' ? x : JSON.stringify(x, null, 2))).join(' ')
  const line = `[${new Date().toISOString()}] ${s}`
  lines.push(line)
  console.log(line)
}
function flush() {
  const body = lines.join('\n') + '\n'
  fs.writeFileSync(LOG_FILE, body, 'utf8')
  fs.writeFileSync(LATEST, body, 'utf8')
  log('LOG_WRITTEN', LOG_FILE)
}

let failed = 0
function pass(name, detail) {
  log('PASS', name, detail || '')
}
function fail(name, err) {
  failed++
  log('FAIL', name, err && err.stack ? err.stack : String(err))
}

async function main() {
  log('=== PixShell selftest start ===')
  log('cwd', process.cwd())
  log('uid', process.getuid && process.getuid(), 'user', process.env.USER)
  log('node', process.version)

  // 1) data dir write
  const dataDir = path.join(os.homedir(), 'Library', 'Application Support', 'PixShell', 'pixshell')
  try {
    fs.mkdirSync(dataDir, { recursive: true })
    const testFile = path.join(dataDir, 'selftest-write.tmp')
    fs.writeFileSync(testFile, JSON.stringify({ t: Date.now() }), 'utf8')
    fs.unlinkSync(testFile)
    const settingsPath = path.join(dataDir, 'settings.json')
    const hostsPath = path.join(dataDir, 'hosts.json')
    // rewrite settings
    let settings = {}
    try {
      settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'))
    } catch (_) {}
    settings.selftestAt = new Date().toISOString()
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf8')
    pass('dataDir write', dataDir)
    log('hosts.json exists', fs.existsSync(hostsPath), 'size', fs.existsSync(hostsPath) ? fs.statSync(hostsPath).size : 0)
    if (fs.existsSync(hostsPath)) {
      const hosts = JSON.parse(fs.readFileSync(hostsPath, 'utf8'))
      log('hosts count', Array.isArray(hosts) ? hosts.length : -1)
      if (Array.isArray(hosts) && hosts[0]) log('sample host', { name: hosts[0].name, host: hosts[0].host, group: hosts[0].group })
    }
  } catch (e) {
    fail('dataDir write', e)
  }

  // 2) load engine
  let engine
  try {
    const { SshEngine } = require('../packages/app/main/ssh-engine.js')
    engine = new SshEngine()
    const ready = engine.ready()
    log('engine.ready', ready)
    if (!ready.ssh2) fail('ssh2 ready', ready.error || 'missing')
    else pass('ssh2 ready', ready.ssh2Path || 'ok')
  } catch (e) {
    fail('load SshEngine', e)
    flush()
    process.exit(1)
  }

  // 3) loadHosts / saveSettings via engine
  try {
    const hosts = engine.loadHosts()
    log('engine.loadHosts', Array.isArray(hosts) ? hosts.length : typeof hosts)
    const s = engine.loadSettings()
    log('engine.loadSettings keys', Object.keys(s || {}))
    const r = engine.saveSettings({ ...s, selftestEngine: Date.now() })
    log('engine.saveSettings', r)
    if (r && r.ok === false) fail('engine.saveSettings', r.error || r)
    else pass('engine.saveSettings')
    // pushRecent must not throw
    if (Array.isArray(hosts) && hosts[0]) {
      engine.pushRecent(hosts[0].id)
      pass('engine.pushRecent', hosts[0].id)
    }
  } catch (e) {
    fail('engine persistence', e)
  }

  // 4) connect validation (no password)
  try {
    const r1 = await engine.connect({ host: '', username: 'root', password: 'x' })
    log('connect empty host', r1)
    if (r1 && r1.ok === false) pass('reject empty host')
    else fail('reject empty host', r1)
    const r2 = await engine.connect({ host: '127.0.0.1', username: 'root' })
    log('connect no auth', r2)
    if (r2 && r2.ok === false) pass('reject no auth')
    else fail('reject no auth', r2)
  } catch (e) {
    fail('connect validation', e)
  }

  // 5) dead port — real network path
  try {
    const t0 = Date.now()
    const r = await engine.connect({
      host: '127.0.0.1',
      port: 1,
      username: 'u',
      password: 'p',
      readyTimeout: 1500,
    })
    log('connect dead port', r, 'ms', Date.now() - t0)
    if (r && r.ok === false && /ECONNREFUSED|timed out|timeout|EACCES|ENOTFOUND/i.test(r.error || '')) {
      pass('dead port real error', r.error)
    } else if (r && r.ok === false) {
      pass('dead port failed (ok)', r.error)
    } else {
      fail('dead port should fail', r)
    }
  } catch (e) {
    fail('dead port', e)
  }

  // 6) optional real host from hosts.json if PIXSHELL_TEST_HOST + PIXSHELL_TEST_PASS set
  const testHost = process.env.PIXSHELL_TEST_HOST
  const testPass = process.env.PIXSHELL_TEST_PASS
  const testUser = process.env.PIXSHELL_TEST_USER || 'root'
  const testPort = Number(process.env.PIXSHELL_TEST_PORT) || 22
  if (testHost && testPass) {
    log('=== real connect test ===', testUser + '@' + testHost + ':' + testPort)
    try {
      const t0 = Date.now()
      const r = await engine.connect({
        host: testHost,
        port: testPort,
        username: testUser,
        password: testPass,
        readyTimeout: 20000,
        cols: 80,
        rows: 24,
      })
      log('real connect result', r, 'ms', Date.now() - t0)
      if (!r || !r.ok) {
        fail('real connect', r && r.error)
      } else {
        pass('real connect', r.sessionId)
        // exec
        const ex = await engine.exec(r.sessionId, 'echo PIXSHELL_OK; uname -a; pwd')
        log('exec', ex)
        if (ex && (ex.stdout || '').includes('PIXSHELL_OK')) pass('exec echo')
        else fail('exec echo', ex)
        // monitor
        const mon = await engine.collectMonitor(r.sessionId)
        log('monitor ok', mon && mon.ok, 'keys', mon && mon.data && Object.keys(mon.data))
        log('monitor data sample', mon && mon.data && {
          load: mon.data.load,
          cpu: mon.data.cpu,
          mem: mon.data.mem,
          ip: mon.data.ip,
          uptime: mon.data.uptime,
          pingMs: mon.data.pingMs,
        })
        if (mon && mon.ok) pass('collectMonitor')
        else fail('collectMonitor', mon && mon.error)
        // sftp list /
        const list = await engine.sftpList(r.sessionId, '/')
        log('sftpList /', list && list.ok, 'path', list && list.path, 'entries', list && list.entries && list.entries.length)
        if (list && list.ok && list.entries && list.entries.length) pass('sftpList /', list.entries.length + ' entries')
        else fail('sftpList /', list && list.error)
        // write should work
        const w = engine.write(r.sessionId, 'echo shell-write-ok\n')
        log('shell write', w)
        await new Promise((r) => setTimeout(r, 400))
        engine.disconnect(r.sessionId)
        pass('disconnect')
      }
    } catch (e) {
      fail('real connect path', e)
    }
  } else {
    // try LAN openwrt-like host from list without password — expect auth fail fast not hang
    try {
      const hosts = engine.loadHosts() || []
      const cand = hosts.find((h) => h.host === '192.168.1.1' || h.host === '192.168.123.1' || /192\.168\./.test(h.host || ''))
      if (cand) {
        log('=== LAN connect without stored password (expect auth fail or need pass) ===', cand.name, cand.host)
        const t0 = Date.now()
        const r = await engine.connect({
          host: cand.host,
          port: cand.port || 22,
          username: cand.username || 'root',
          password: cand.password || 'definitely-wrong-password-pixshell-test',
          readyTimeout: 12000,
        })
        log('LAN result', r, 'ms', Date.now() - t0)
        const ms = Date.now() - t0
        if (r && r.ok === false) {
          if (ms < 20000) pass('LAN auth fail within timeout', r.error + ' @' + ms + 'ms')
          else fail('LAN hung too long', ms + 'ms ' + r.error)
        } else if (r && r.ok) {
          pass('LAN connected with test password (unexpected but ok)')
          engine.disconnect(r.sessionId)
        }
      } else {
        log('SKIP LAN test — no 192.168 host in list')
      }
    } catch (e) {
      fail('LAN test', e)
    }
  }

  log('=== summary failed=' + failed + ' ===')
  flush()
  process.exit(failed ? 1 : 0)
}

main().catch((e) => {
  fail('main', e)
  flush()
  process.exit(1)
})
