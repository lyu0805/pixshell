#!/usr/bin/env node
/**
 * Minimal SSH backend smoke test (no real password hardcoded).
 * Run from runtime root or source:
 *   node scripts/ssh-connect-smoke.js
 * Exit 0 only if all checks pass.
 */
'use strict'

const path = require('path')
const fs = require('fs')
const assert = require('assert')

function findRoot() {
  const candidates = [
    process.cwd(),
    path.join(__dirname, '..'),
    path.join(
      require('os').homedir(),
      'Library/Application Support/PixShell/app',
    ),
  ]
  for (const c of candidates) {
    if (fs.existsSync(path.join(c, 'packages/ssh/src/session/ssh-session.js'))) {
      return c
    }
  }
  return path.join(__dirname, '..')
}

const root = findRoot()
process.chdir(root)
console.log('[smoke] root =', root)

let failed = 0
function check(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => console.log('PASS', name))
    .catch((e) => {
      failed++
      console.error('FAIL', name, e && e.message ? e.message : e)
    })
}

async function main() {
  // 1) ssh2 require
  await check('require(ssh2)', () => {
    const ssh2 = require('ssh2')
    assert.strictEqual(typeof ssh2.Client, 'function')
  })

  // 2) SSHSession module
  const sessionPath = path.join(root, 'packages/ssh/src/session/ssh-session.js')
  const { SSHSession, buildAuthMethodList, Client, resolveSsh2 } = require(sessionPath)
  await check('SSHSession.isAvailable', () => {
    assert.ok(Client, 'Client null')
    assert.strictEqual(SSHSession.isAvailable(), true)
    assert.ok(resolveSsh2())
  })

  await check('buildAuthMethodList KI before password', () => {
    const list = buildAuthMethodList(
      { tryKeyboard: true, password: 'x', privateKey: null, agent: null },
      { hasPassword: true, loadedKey: false, auth: null },
    )
    assert.deepStrictEqual(list, ['keyboard-interactive', 'password'])
  })

  await check('buildAuthMethodList key+password', () => {
    const list = buildAuthMethodList(
      { tryKeyboard: true, password: 'x', privateKey: 'k', agent: null },
      { hasPassword: true, loadedKey: true, auth: null },
    )
    assert.deepStrictEqual(list, ['publickey', 'keyboard-interactive', 'password'])
  })

  // 3) SshEngine ready + validation
  const { SshEngine } = require(path.join(root, 'packages/app/main/ssh-engine.js'))
  const engine = new SshEngine()
  await check('engine.ready ssh2', () => {
    const r = engine.ready()
    assert.strictEqual(r.ok, true)
    assert.strictEqual(r.ssh2, true)
  })

  await check('connect empty host', async () => {
    const r = await engine.connect({})
    assert.strictEqual(r.ok, false)
    assert.ok(/主机/.test(r.error || ''))
  })

  await check('connect no auth material', async () => {
    const r = await engine.connect({ host: '127.0.0.1', username: 'root' })
    assert.strictEqual(r.ok, false)
    assert.ok(/密码|私钥/.test(r.error || ''), r.error)
  })

  await check('connect refused port → real error (not fake ok)', async () => {
    const r = await engine.connect({
      host: '127.0.0.1',
      port: 1,
      username: 'root',
      password: 'x',
      readyTimeout: 2000,
    })
    assert.strictEqual(r.ok, false, 'must not ok on refused')
    assert.ok(r.sessionId, 'sessionId on fail')
    assert.ok(r.error, 'error message')
    assert.ok(
      /ECONNREFUSED|refused|timeout|Timed out|closed|认证|All configured/i.test(r.error),
      'got: ' + r.error,
    )
  })

  await check('bad password → fails fast (no 25s hang)', async () => {
    const t0 = Date.now()
    const r = await engine.connect({
      host: '127.0.0.1',
      port: 22,
      username: 'root',
      password: 'definitely-not-the-password-' + Date.now(),
      readyTimeout: 12000,
    })
    const ms = Date.now() - t0
    assert.strictEqual(r.ok, false)
    assert.ok(r.error, r.error)
    // KI-first should finish auth failure well under readyTimeout
    assert.ok(ms < 11000, 'took too long: ' + ms + 'ms err=' + r.error)
    assert.ok(
      /All configured|authentication|认证|Permission|failed|失败/i.test(r.error),
      'unexpected: ' + r.error,
    )
    console.log('  (auth fail in', ms, 'ms:', r.error + ')')
  })

  await check('write/resize without session', () => {
    assert.strictEqual(engine.write('nope', 'x').ok, false)
    assert.strictEqual(engine.resize('nope', 80, 24).ok, false)
  })

  if (failed) {
    console.error('\n[smoke] FAILED', failed)
    process.exit(1)
  }
  console.log('\n[smoke] ALL PASS')
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
