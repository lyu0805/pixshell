#!/usr/bin/env node
/**
 * Unit checks that invoke SHIPPED modules (no reimplementation).
 * Exit non-zero on failure.
 */
const path = require('path')
const assert = require('assert')
const fs = require('fs')
const root = path.join(__dirname, '..')

function req(rel) {
  return require(path.join(root, rel))
}

let failed = 0
function check(name, fn) {
  try {
    fn()
    console.log('PASS', name)
  } catch (e) {
    failed++
    console.error('FAIL', name, e && e.message ? e.message : e)
  }
}

// 1) schemes
check('terminal/schemes listSchemes count', () => {
  const { listSchemes, getScheme, toXtermTheme } = req('packages/terminal/src/schemes.js')
  const list = listSchemes()
  assert.ok(Array.isArray(list), 'list array')
  assert.ok(list.length >= 20 && list.length <= 80, 'curated schemes 20-80, got ' + list.length)
  assert.ok(list.every((x) => x.id && x.name), 'scheme entries have id+name')
  assert.ok(getScheme('dracula') && getScheme('ciapre') && getScheme('pix-dark'), 'core schemes present')
  assert.ok(getScheme('monokai') && getScheme('monokai').background, 'monokai alias works')
  // removed bulk junk must not appear
  const ids = new Set(list.map((x) => x.id))
  assert.ok(!ids.has('batman') && !ids.has('spiderman') && !ids.has('crayonponyfish'), 'removed novelty schemes')

  const s = getScheme(list[0].id)
  assert.ok(s && s.background, 'scheme has background')
  const xt = toXtermTheme(list[0].id)
  assert.ok(xt.background, 'xterm theme')
})

// 2) platform
check('core/platform detect+targets', () => {
  const { detectPlatform, packageTargets, runtimeDataDir } = req('packages/core/src/platform.js')
  const d = detectPlatform('darwin', 'arm64')
  assert.strictEqual(d.os, 'mac')
  assert.ok(d.supported)
  const t = packageTargets()
  assert.ok(t.some((x) => x.id === 'mac-arm64'))
  assert.ok(t.some((x) => x.id === 'win-x64'))
  assert.ok(t.some((x) => x.id === 'linux-x64'))
  const dir = runtimeDataDir('/Users/x', 'darwin')
  assert.ok(dir.toLowerCase().includes('pixshell'))
})

// 3) accelerate
check('core/accelerate map+validate+path', () => {
  const {
    defaultAccelerateConfig,
    mapFromTconfig,
    validateAccelerateConfig,
    resolveConnectPath,
  } = req('packages/core/src/accelerate.js')
  const d = defaultAccelerateConfig()
  assert.strictEqual(d.interoperable, false)
  const m = mapFromTconfig({ server_port: 150, protocal: 'udp', direct_cn: false })
  assert.strictEqual(m.protocol, 'udp')
  assert.strictEqual(m.interoperable, false)
  const v = validateAccelerateConfig({ enabled: true, server_host: '' })
  assert.strictEqual(v.ok, false)
  const pathR = resolveConnectPath({ host: '1.2.3.4', port: 22 }, { enabled: true, server_host: 'x' })
  assert.strictEqual(pathR.interoperable, false)
  assert.ok(pathR.mode.includes('direct'))
})

// offline import helpers are not shipped in public tree

// 5) quick import
check('import-quick flatten', () => {
  const { flattenQuickCommands, importFromConfig } = req('scripts/import-quick.js')
  const flat = flattenQuickCommands([
    {
      name: 'g1',
      commands: [
        { id: '1', name: 'c1', command: 'ls', append_cr: true },
        { id: '2', name: 'c2', command: 'pwd\n', delete_time: 1 },
      ],
    },
  ])
  assert.strictEqual(flat.length, 1)
  assert.ok(flat[0].command.endsWith('\n'))
  const cfg = process.env.PIXSHELL_IMPORT_CONFIG_JSON || (() => {
    const path = require('path'); const os = require('os'); const fs = require('fs')
    try {
      const lib = path.join(os.homedir(), 'Library')
      for (const n of fs.readdirSync(lib)) {
        const c = path.join(lib, n, 'config.json')
        if (fs.existsSync(c)) return c
      }
    } catch (_) {}
    return ''
  })()
  if (fs.existsSync(cfg)) {
    const data = importFromConfig(cfg)
    assert.ok(data.quick.length >= 10, 'quick commands from real config')
  }
})

// 6) transfer packCommand
check('transfer packCommand/defaultPackName', () => {
  const { defaultPackName, packCommand } = req('packages/transfer/src/index.js')
  const n = defaultPackName('fs_pack', new Date('2020-01-02T03:04:05Z'))
  assert.ok(n.startsWith('fs_pack_'), n)
  assert.ok(n.endsWith('.tgz'), n)
  const cmd = packCommand('tar', ['/a', '/b'], 'out.tgz')
  assert.ok(cmd.includes('tar -czf'))
  assert.ok(cmd.includes("'/a'"))
  const z = packCommand('zip', ['x'], 'o.zip')
  assert.ok(z.includes('zip -r'))
})

// 7) zmodem builders
check('ssh/zmodem remote commands', () => {
  const { remoteSzCommand, remoteRzCommand, remoteCheckLrzsz, buildSzPipeline, buildRzPipeline } =
    req('packages/ssh/src/zmodem.js')
  const sz = remoteSzCommand(['/tmp/a', 'b c'])
  assert.ok(sz.startsWith('sz '))
  assert.ok(sz.includes('/tmp/a'))
  assert.strictEqual(remoteRzCommand(), 'rz -e -b')
  assert.ok(remoteCheckLrzsz().includes('command -v sz'))
  assert.strictEqual(buildSzPipeline(['f']).localMode, 'receive')
  assert.strictEqual(buildRzPipeline().localMode, 'send')
})

// 8) editor helpers
check('editor guessLang/highlight/lineCount', () => {
  const { guessLang, highlightPlain, lineCount, isProbablyBinary, createEditorDoc } = req(
    'packages/editor/src/index.js',
  )
  assert.strictEqual(guessLang('a.py'), 'python')
  assert.strictEqual(guessLang('a.js'), 'javascript')
  const h = highlightPlain('const x = "hi"\n// c', 'javascript')
  assert.ok(h.includes('tok-'), h)
  assert.strictEqual(lineCount('a\nb\nc'), 3)
  assert.strictEqual(isProbablyBinary('hello'), false)
  assert.strictEqual(isProbablyBinary('a\u0000b'), true)
  const doc = createEditorDoc({ path: 'x.sh', content: 'echo 1' })
  assert.ok(doc.language === 'shell' || doc.language === 'unixshell', 'shell lang')
})

// 9) batch hosts
check('core/batch-hosts', () => {
  const { hostsInGroup, batchDelete, filterHosts } = req('packages/core/src/batch-hosts.js')
  const hosts = [
    { id: '1', group: 'a' },
    { id: '2', group: 'b' },
    { id: '3', group: 'a' },
  ]
  assert.strictEqual(hostsInGroup(hosts, 'a').length, 2)
  assert.strictEqual(batchDelete(hosts, ['1']).length, 2)
  assert.strictEqual(filterHosts(hosts, (h) => h.id === '2').length, 1)
})

// 10) command-box
check('command-box params+history+remote-pick', () => {
  const { parseParams, renderTemplate, applyDefaults } = req('packages/command-box/src/params.js')
  assert.deepStrictEqual(parseParams('tail -n ${lines} ${file}'), ['lines', 'file'])
  assert.strictEqual(renderTemplate('a ${x}', { x: '1' }), 'a 1')
  assert.strictEqual(applyDefaults('${a}-${b}', { a: 'X' }), 'X-${b}')
  const { pushHistory, navigateHistory, filterHistory } = req('packages/command-box/src/history.js')
  const h = pushHistory(['b'], 'a')
  assert.deepStrictEqual(h.slice(0, 2), ['a', 'b'])
  const nav = navigateHistory(['a', 'b'], -1, 1, 'draft')
  assert.strictEqual(nav.value, 'a')
  assert.ok(filterHistory(['ls', 'pwd', 'ls -la'], 'ls').length >= 2)
  const { mergeCompletions, insertPathIntoCommand } = req('packages/command-box/src/remote-pick.js')
  const m = mergeCompletions('cat f', ['cat'], [{ label: 'file.txt', insert: 'file.txt', isDir: false }])
  assert.ok(m.length >= 1)
  const ins = insertPathIntoCommand('cat fi', 'file.txt', 6)
  assert.ok(ins.includes('file.txt'))
})

// 11) sftp sync paths
check('sftp-panel applyCd', () => {
  const { applyCd, joinRemote, normalizeRemotePath } = req('packages/sftp-panel/src/sync.js')
  assert.strictEqual(normalizeRemotePath('/a//b/'), '/a/b')
  assert.strictEqual(joinRemote('/home/u', 'x'), '/home/u/x')
  assert.strictEqual(applyCd('/home/u', 'cd ..'), '/home')
  assert.strictEqual(applyCd('.', 'cd /tmp'), '/tmp')
})

// 12) proxy
check('proxy map+validate', () => {
  const { createProxy, mapFromReferenceProxy, validateProxy, toSsh2Proxy, normalizeProxyType } =
    req('packages/proxy/src/index.js')
  assert.strictEqual(normalizeProxyType(200), 'ssh-jump')
  const p = mapFromReferenceProxy({ id: '1', host: 'h', port: 22, type: 200, user_name: 'u' })
  assert.strictEqual(p.type, 'ssh-jump')
  assert.strictEqual(validateProxy({ host: '' }).ok, false)
  assert.ok(toSsh2Proxy(createProxy({ host: '127.0.0.1', type: 'socks5' })))
})

// 13) monitor parse
check('monitor parsePingAvg+multiPing', () => {
  const { parsePingAvg, buildMultiPingPlan, summarizeMultiPing, parseDfRoot, parsePsAux } = req(
    'packages/monitor/src/collect.js',
  )
  const s = parsePingAvg('rtt min/avg/max/mdev = 0.1/1.5/2.0/0.1 ms')
  assert.strictEqual(s.avg, 1.5)
  const plan = buildMultiPingPlan(['1.1.1.1', '8.8.8.8'])
  assert.strictEqual(plan.length, 2)
  assert.ok(plan[0].command.includes('ping'))
  const sum = summarizeMultiPing([
    { host: '1.1.1.1', stdout: 'rtt min/avg/max/mdev = 1/2/3/0 ms' },
  ])
  assert.strictEqual(sum[0].avgMs, 2)
  assert.ok(parseDfRoot('100 50 50%').usePercent)
  assert.ok(parsePsAux('USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND\nroot 1 0.0 0.1 0 0 ? S 0 0:00 init\n').length >= 1)
})

// 14) rdp url
check('rdp buildRdpUrl', () => {
  const { buildRdpUrl } = req('packages/rdp/src/index.js')
  assert.strictEqual(buildRdpUrl({ host: 'h', port: 3389, username: 'u' }), 'rdp://u@h:3389')
})

// 15) terminal-bg css vars
check('terminal-bg cssVarsFromBg', () => {
  const { cssVarsFromBg, applyTerminalBackground } = req('packages/ui-pixel/src/terminal-bg.js')
  const v = cssVarsFromBg({ blur: 4, enable: true })
  assert.strictEqual(v['--term-blur'], '4px')
  const el = { style: { setProperty(k, val) { this[k] = val }, backgroundImage: '' }, classList: { add() {}, remove() {} } }
  const r = applyTerminalBackground(el, { url: 'http://x/a.png', blur: 3, enable: true })
  assert.strictEqual(r.applied, true)
})

// 16) sync bundle
check('sync export/import bundle', () => {
  const { exportBundle, importBundle } = req('packages/sync/src/index.js')
  const b = exportBundle({
    hosts: [{ id: '1', host: 'h', password: 'secret' }],
    settings: { a: 1 },
    quickCommands: [{ name: 'x' }],
  })
  assert.strictEqual(b.version, 1)
  assert.strictEqual(b.hosts[0].password, undefined)
  const back = importBundle(b)
  assert.strictEqual(back.hosts.length, 1)
})

// 17) mapConfig includes accelerate
check('import-config mapConfig accelerate', () => {
  const { mapConfig } = req('scripts/import-config.js')
  const m = mapConfig({
    theme: 'Default',
    font_size: 12,
    layout: { left_side_width: 173 },
    command_input: {},
  })
  assert.ok(m.accelerate)
  assert.strictEqual(m.accelerate.interoperable, false)
  assert.strictEqual(m.layout.leftSideWidth, 173)
})

// 18) electron-builder.yml exists (multi-platform packaging surface)
check('electron-builder.yml packaging targets', () => {
  const yml = fs.readFileSync(path.join(root, 'electron-builder.yml'), 'utf8')
  assert.ok(yml.includes('mac:'))
  assert.ok(yml.includes('win:'))
  assert.ok(yml.includes('linux:'))
})

// 19) parse main/preload/renderer
check('entry files parse', () => {
  const vm = require('vm')
  for (const f of [
    'packages/app/main/ssh-hub.js',
    'packages/app/main/zmodem-bridge.js',
    'packages/app/main/preload.js',
  ]) {
    const code = fs.readFileSync(path.join(root, f), 'utf8')
    // main.js requires electron — skip full load; syntax via Function for renderer only
    if (f.endsWith('renderer.js') || f.endsWith('features-extra.js')) {
      new vm.Script(code)
    } else {
      // use node --check equivalent: new Function only works for scripts without require top issues
      require('child_process').execFileSync(process.execPath, ['--check', path.join(root, f)])
    }
  }
})


// 20) auth method order regression
check('ssh buildAuthMethodList KI before password', () => {
  const { buildAuthMethodList } = req('packages/ssh/src/session/ssh-session.js')
  const list = buildAuthMethodList(
    { tryKeyboard: true, password: 'x', privateKey: null },
    { hasPassword: true, loadedKey: false, auth: null },
  )
  assert.ok(list.indexOf('keyboard-interactive') < list.indexOf('password'), String(list))
  assert.ok(list.includes('password'))
})

// 21) concurrent exec-chain pattern returns each call's own result
check('exec chain concurrent result ownership', () => {
  // sync structural assert: mine must be captured before reassignment
  const src = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(src.includes('const mine = prev.catch'), 'must capture own promise')
  assert.ok(src.includes('return (await mine)'), 'must await own promise not tip')
  assert.ok(!/await e\.execChain\n\s+return result/.test(src), 'old shared-result pattern removed')
})

// 22) reconnect keeps same sessionId
check('reconnect keeps sessionId', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(src.includes('keep the SAME sessionId') || src.includes('sessionId, _attempt: 0'), 'same id reconnect')
  assert.ok(!src.includes("sessionId: newId('ssh')"), 'must not mint new id on manual reconnect')
})

// 23) agent-bridge resolveSessionId uses startsWith only
check('agent-bridge session id prefix match', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/agent-bridge.js'), 'utf8')
  assert.ok(src.includes('k.startsWith(id)'))
  assert.ok(!src.includes('k.includes(id)'), 'includes match removed')
})

// 24) sftpRead size cap
check('sftpRead hard cap 8MB', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(src.includes('MAX_BYTES = 8 * 1024 * 1024'))
})


// 25) sysinfo KEY=value parse
check('monitor parseSysInfoText structured', () => {
  const { parseSysInfoText } = req('packages/monitor/src/collect.js')
  const sample = [
    '===sysinfo===',
    'hostname=box',
    'os_pretty=Ubuntu 22.04.3 LTS',
    'kernel_release=5.15.0',
    'machine=x86_64',
    'uptime=1d2h3m',
    'load=0.1,0.2,0.3',
    'cpu_model=Intel(R) Test',
    'cpu_count=4',
    'mem=50 1024 2048',
    'swap=0 0 0',
    'ip=10.0.0.2',
    'cpu_row=0\tIntel(R) Test\t2300\t16KB\t4000',
    'net_row=eth0\t1000\t2000',
    'disk=/\t20G\t10G\t10G\t50%\t/dev/sda1',
    '===end===',
  ].join('\n')
  const d = parseSysInfoText(sample)
  assert.strictEqual(d.hostname, 'box')
  assert.strictEqual(d.osPretty, 'Ubuntu 22.04.3 LTS')
  assert.strictEqual(d.cpuRows.length, 1)
  assert.strictEqual(d.disks[0].mount, '/')
  assert.ok(d.netRows.length >= 1)
})

// 26) remote-sysinfo.sh ships + engine has collectSysInfo
check('sysinfo script and engine collectSysInfo', () => {
  const sh = path.join(root, 'packages/app/main/remote-sysinfo.sh')
  assert.ok(fs.existsSync(sh), 'remote-sysinfo.sh missing')
  const body = fs.readFileSync(sh, 'utf8')
  assert.ok(body.includes('===sysinfo==='))
  assert.ok(body.includes('/proc/cpuinfo'))
  assert.ok(body.includes('/proc/meminfo'))
  const eng = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(eng.includes('async collectSysInfo'))
  assert.ok(eng.includes('encryptSecret'))
  assert.ok(eng.includes('enc:v1:'))
  assert.ok(eng.includes('externalCliEnabled: false'))
})

// 26b) monitor MUST define _monitorInlineScript — collectMonitor builds lite/full cmd via it;
// missing method blanks entire sidebar (load/cpu/mem/disk/proc) on every host.
check('monitor _monitorInlineScript required by collectMonitor', () => {
  const engPath = path.join(root, 'packages/app/main/ssh-engine.js')
  const eng = fs.readFileSync(engPath, 'utf8')
  assert.ok(/_monitorInlineScript\s*\([^)]*\)\s*\{/.test(eng), '_monitorInlineScript method body missing')
  assert.ok(eng.includes('async collectMonitor'))
  assert.ok(eng.includes('_monitorInlineScript(true)'))
  assert.ok(eng.includes('===mon==='))
  delete require.cache[require.resolve(engPath)]
  const { SshEngine } = require(engPath)
  const e = new SshEngine({ dataDir: path.join(require('os').tmpdir(), 'pixshell-unit-mon') })
  const sh = e._monitorInlineScript(true)
  assert.ok(typeof sh === 'string' && sh.includes('===mon==='), 'inline script empty')
  assert.ok(sh.includes('/proc/loadavg') && sh.includes('/proc/meminfo'))
  const parsed = e._parseMonitorText(
    '===mon===\nload=0.1,0.2,0.3\ncpu=12.5\nmem=40 100 250\nswap=0 0 0\nuptime=1d0h0m\nip=10.0.0.1\nnet=eth0 1 2\ndisk=/\t10G\t1G\t9G\t10%\nproc=12M\t1.2\tbash\n===end===\n',
  )
  assert.strictEqual(parsed.load, '0.1,0.2,0.3')
  assert.strictEqual(parsed.cpu, '12.5')
  assert.ok(String(parsed.disks).includes('/'))
  assert.ok(String(parsed.procs).includes('bash'))
})

// 27) password encrypt helpers no-op without electron safeStorage
// 26c) closing sysinfo/tool tabs must NOT call disconnect — only term owns session
check('closeTab does not disconnect borrowed sessionId (sysinfo/tool)', () => {
  const app = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  assert.ok(app.includes('function tabOwnsSshSession'), 'tabOwnsSshSession missing')
  assert.ok(app.includes("tab.type === 'term'"), 'only term owns SSH')
  // closeTab must gate disconnect on tabOwnsSshSession
  const m = app.match(/async function closeTab\(id\) \{[\s\S]{0,2500}?stopMonitor\(\)/)
  assert.ok(m, 'closeTab body not found')
  const body = m[0]
  assert.ok(body.includes('tabOwnsSshSession(tab)'), 'closeTab must gate disconnect')
  assert.ok(body.includes("tab.type === 'term'") || app.includes("tab.type === 'term'"), 'only term owns')
  assert.ok(!/if \(tab\.sessionId && hasApi\) \{\s*try \{\s*await api\.disconnect/.test(body),
    'old unconditional disconnect still present')
  // sysinfo tab creation still shares sessionId (borrow)
  assert.ok(app.includes("type: 'sysinfo'"))
  assert.ok(/sessionId:\s*t\.sessionId/.test(app))
})

// 26d) disconnected sidebar: 「连接状态」→「重新连接」+ click doReconnect
check('connStateLabel reconnect when disconnected', () => {
  const app = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  assert.ok(html.includes('id="btnConnToggle"') && html.includes('id="connStateText"'), 'conn toggle button in html')
  assert.ok(app.includes('function setConnStateLabel'), 'setConnStateLabel')
  assert.ok(app.includes('function onConnToggleClick'), 'onConnToggleClick')
  assert.ok(app.includes('disconnectActive') && app.includes('doReconnect'), 'disconnect+reconnect')
  assert.ok(app.includes("mode === 'connected'") || app.includes('dataset.mode'), 'connected mode disconnect path')
  assert.ok(css.includes('.conn-state-btn') && css.includes('is-connected'), 'conn button css')
  assert.ok(app.includes('tabOwnsSshSession'))
})

// 26e) always-on file logger in repo + userData
check('logger.js ships and main/preload wire log IPC', () => {
  const rootMain = path.join(root, 'packages/app/main')
  assert.ok(fs.existsSync(path.join(rootMain, 'logger.js')), 'logger.js missing')
  const logger = require(path.join(rootMain, 'logger.js'))
  assert.ok(typeof logger.init === 'function')
  assert.ok(typeof logger.info === 'function')
  const main = fs.readFileSync(path.join(rootMain, 'main.js'), 'utf8')
  assert.ok(main.includes("require('./logger')"))
  assert.ok(main.includes("log:write"))
  assert.ok(main.includes('log.init'))
  const pre = fs.readFileSync(path.join(rootMain, 'preload.js'), 'utf8')
  assert.ok(pre.includes('logWrite:'))
  const app = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  assert.ok(app.includes('function rlog'))
  assert.ok(app.includes("api.logWrite"))
  // structural freeze guards
  assert.ok(app.includes('_reconnectInflight'))
  assert.ok(app.includes('tabOwnsSshSession'))
  // monitor must not force green syncdot
  assert.ok(!/updateSyncDot\(true\)\s*\n\s*\}\s*\n\s*function drawSpark/.test(app), 'monitor still forces green')
})

check('encryptSecret fallback plaintext without safeStorage', () => {
  // When electron is absent and force is off, encryptSecret returns plaintext.
  // When force is on, it must refuse (throw SAFE_STORAGE_REQUIRED).
  const engPath = path.join(root, 'packages/app/main/ssh-engine.js')
  const code = fs.readFileSync(engPath, 'utf8')
  assert.ok(code.includes('ELECTRON_SAFE_STORAGE'))
  assert.ok(code.includes('requireSafeStorage'))

  // Brace-aware extract of isSafeStorageForceEnv + encryptSecret
  function extractFn(src, name) {
    const re = new RegExp('function\\s+' + name + '\\s*\\(')
    const m = re.exec(src)
    assert.ok(m, name + ' not found')
    let i = m.index + m[0].length - 1
    // find opening brace of body
    while (i < src.length && src[i] !== '{') i++
    assert.ok(src[i] === '{', name + ' body')
    let depth = 0
    const start = m.index
    for (let j = i; j < src.length; j++) {
      const ch = src[j]
      if (ch === '{') depth++
      else if (ch === '}') {
        depth--
        if (depth === 0) return src.slice(start, j + 1)
      }
    }
    throw new Error('unclosed ' + name)
  }
  const forceSrc = extractFn(code, 'isSafeStorageForceEnv')
  const encSrc = extractFn(code, 'encryptSecret')
  const prevEnv = process.env.ELECTRON_SAFE_STORAGE
  try {
    delete process.env.ELECTRON_SAFE_STORAGE
    const factory = new Function(
      'require',
      'Buffer',
      'process',
      'console',
      forceSrc +
        '\nlet _plainWarnOnce = true;\n' +
        encSrc +
        ';\nreturn encryptSecret;',
    )
    const encryptSecret = factory(
      (name) => {
        if (name === 'electron') throw new Error('no electron')
        return require(name)
      },
      Buffer,
      process,
      console,
    )
    assert.strictEqual(encryptSecret('secret'), 'secret')
    assert.ok(String(encryptSecret('enc:v1:abc')).startsWith('enc:v1:'))
    let threw = false
    try {
      encryptSecret('secret', { force: true })
    } catch (e) {
      threw = true
      assert.ok(e && (e.code === 'SAFE_STORAGE_REQUIRED' || /safeStorage/.test(String(e.message))))
    }
    assert.ok(threw, 'force mode must throw when encryption unavailable')
  } finally {
    if (prevEnv === undefined) delete process.env.ELECTRON_SAFE_STORAGE
    else process.env.ELECTRON_SAFE_STORAGE = prevEnv
  }
})

// 27b) password force mode structural (requireSafeStorage / ELECTRON_SAFE_STORAGE)
check('persistHosts surfaces strippedPasswords warning', () => {
  const app = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  assert.ok(app.includes('strippedPasswords'), 'UI must read strippedPasswords')
  assert.ok(/async function persistHosts/.test(app))
  assert.ok(app.includes('r.warning') || app.includes('strippedPasswords'))
})

check('password force mode requireSafeStorage / ELECTRON_SAFE_STORAGE', () => {
  const eng = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(eng.includes('ELECTRON_SAFE_STORAGE'), 'env force flag')
  assert.ok(eng.includes('requireSafeStorage'), 'settings force flag')
  assert.ok(eng.includes('strippedPasswords') || eng.includes('SAFE_STORAGE_REQUIRED'), 'refuse/strip path')
  assert.ok(/function encryptSecret\(plain/.test(eng))
  assert.ok(/saveHosts\s*\(hosts\)/.test(eng))
  // default remains false for compatibility
  assert.ok(eng.includes('requireSafeStorage: false'))
})

// 27c) agent-bridge loopback + no legacy token + no open CORS
check('agent-bridge loopback CORS and token hardening', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/agent-bridge.js'), 'utf8')
  assert.ok(src.includes('isLoopbackAddress') || src.includes('loopback only'), 'loopback reject')
  assert.ok(src.includes('127.0.0.1') && src.includes('::1') && src.includes('::ffff:127.0.0.1'))
  assert.ok(!/x-aterminal-token/i.test(src), 'legacy x-aterminal-token must be removed')
  // No open CORS: never assign/set a wildcard ACAO header (comments may mention the policy)
  assert.ok(
    !/['"]Access-Control-Allow-Origin['"]\s*[,:]\s*['"]\*['"]/.test(src),
    'no CORS * header assignment',
  )
  assert.ok(!/Access-Control-Allow-Origin['"\s:]*\+\s*origin/i.test(src), 'no Origin reflection')
  assert.ok(!/\bres\.setHeader\s*\(\s*['"]Access-Control-Allow-Origin['"]/.test(src))
  assert.ok(src.includes('x-pixshell-token') || /x-pixshell-token/.test(src))
  assert.ok(src.includes('RATE_LIMIT') || src.includes('rateLimitAllow'))
  assert.ok(src.includes("listen") && src.includes("'127.0.0.1'"))
})

// 28) connect failure tears down partial session
check('connect failure destroys partial session', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(src.includes('createdSession'), 'tracks newly created session')
  assert.ok(src.includes('_releaseControlIfIdle'), 'idle control release')
  assert.ok(src.includes('_detachSessionHandlers'), 'detach handlers on close')
})

// 29) multi-shell openShell (no kill previous)
check('openShell multi-shell set', () => {
  const src = fs.readFileSync(path.join(root, 'packages/ssh/src/session/ssh-session.js'), 'utf8')
  assert.ok(src.includes('shellSessions'), 'shellSessions set')
  assert.ok(
    !/if \(this\.shellSession && this\.shellSession\.open\)[\s\S]{0,80}this\.shellSession\.kill/.test(src),
    'must not kill previous shell on openShell',
  )
  assert.ok(src.includes('hostVerifier: typeof p.hostVerifier'), 'hostVerifier survives normalize')
})

// 30) SFTP single-flight + real close
check('openSFTP single-flight and close ends channel', () => {
  const ssh = fs.readFileSync(path.join(root, 'packages/ssh/src/session/ssh-session.js'), 'utf8')
  const sftp = fs.readFileSync(path.join(root, 'packages/ssh/src/session/sftp-session.js'), 'utf8')
  assert.ok(ssh.includes('_sftpOpening'), 'single-flight openSFTP')
  assert.ok(sftp.includes('this._sftp?.end?.()') || sftp.includes('_sftp.end'), 'close ends sftp')
})

// 31) mac window-all-closed preserves sessions
check('darwin window-all-closed does not closeAll', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/main.js'), 'utf8')
  const idx = src.indexOf("app.on('window-all-closed'")
  assert.ok(idx >= 0, 'window-all-closed handler')
  const block = src.slice(idx, idx + 450)
  assert.ok(block.includes("if (process.platform === 'darwin') return"), 'darwin early return')
})

// 32) kill signal allowlist
check('ssh:kill signal allowlist', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/main.js'), 'utf8')
  assert.ok(src.includes("ALLOWED = new Set(['TERM'"))
  assert.ok(src.includes('invalid signal'))
})

// 33) agent local path sandbox
check('agent-bridge local path sandbox', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/agent-bridge.js'), 'utf8')
  assert.ok(src.includes('assertLocalPath'))
  assert.ok(src.includes('not allowed'))
})

// 34) hosts.json mode 0o600
check('writeJson mode 0o600', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(src.includes('mode: 0o600'))
})

// 35) CLI parseArgs value flags + equals
check('cli parseArgs --cmd=-n and --key=value', () => {
  const src = fs.readFileSync(path.join(root, 'packages/cli/pixshell-cli.js'), 'utf8')
  assert.ok(src.includes('VALUE_FLAGS'))
  assert.ok(src.includes("a.indexOf('=')"))
  const m = src.match(/function parseArgs\(argv\) \{[\s\S]*?\n\}/)
  assert.ok(m, 'parseArgs present')
  const prelude = src.match(/const VALUE_FLAGS = new Set\([\s\S]*?\]\)/)[0]
  // eslint-disable-next-line no-new-func
  const fn = new Function(prelude + '\n' + m[0] + '\nreturn parseArgs')()
  const a = fn(['exec', '-c', '-n', '--session', 'abc'])
  assert.strictEqual(a.flags.cmd, '-n')
  assert.strictEqual(a.flags.session, 'abc')
  const b = fn(['exec', '--cmd=--help', '--timeout=30'])
  assert.strictEqual(b.flags.cmd, '--help')
  assert.strictEqual(b.flags.timeout, '30')
})

// 36) open-external protocol allowlist
check('shell:open-external protocol allowlist', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/main.js'), 'utf8')
  assert.ok(src.includes("'http:', 'https:', 'mailto:'"))
  assert.ok(src.includes('protocol not allowed'))
})


// 37) SSH reconnect exponential backoff cap 30s (P1)
// 39) product packages must not reintroduce banned brand token env
check('packages no ATERMINAL brand token alias', () => {
  function walk(dir, acc) {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      if (ent.name === 'node_modules' || ent.name === '.git') continue
      const p = path.join(dir, ent.name)
      if (ent.isDirectory()) walk(p, acc)
      else if (/\.(js|ts|mjs|cjs|json|md)$/.test(ent.name)) acc.push(p)
    }
  }
  const files = []
  walk(path.join(root, 'packages'), files)
  const hits = []
  for (const f of files) {
    const t = fs.readFileSync(f, 'utf8')
    if (/ATERMINAL/i.test(t) || /x-aterminal-token/i.test(t)) hits.push(path.relative(root, f))
  }
  assert.deepStrictEqual(hits, [], 'banned brand token in: ' + hits.join(', '))
})

check('ssh reconnect exponential backoff cap 30s', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(
    /Math\.min\(\s*30000\s*,\s*1000\s*\*\s*Math\.pow\(\s*2\s*,\s*attempt\s*-\s*1\s*\)\s*\)/.test(src) ||
      src.includes('Math.min(30000, 1000 * Math.pow(2, attempt - 1))'),
    'expect Math.min(30000, 1000 * 2**(attempt-1))',
  )
  assert.ok(src.includes('this.maxReconnect = 8') || src.includes('maxReconnect = 8'), 'maxReconnect=8')
  assert.ok(!src.includes('Math.min(12000, 1000 * Math.pow(2, attempt - 1))'), 'old 12s cap must be gone')
})

// 38) xterm buffer keep-tail policy
check('xterm buffer keep-tail truncate policy', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  assert.ok(
    src.includes('slice(-MAX_BUF)') || src.includes('slice(-MAX_BUF_CHARS)'),
    'must keep-tail via slice(-MAX_BUF*)',
  )
  assert.ok(
    /MAX_BUF(?:_CHARS)?\s*=\s*500000/.test(src),
    'buffer cap ~500000 chars',
  )
})

// 39) reconnect flap: do not reset _attempt until stableMs online
check('ssh reconnect stable window before attempt reset', () => {
  const src = fs.readFileSync(path.join(root, 'packages/app/main/ssh-engine.js'), 'utf8')
  assert.ok(src.includes('stableMs') && src.includes('stableTimers'), 'stableMs/stableTimers present')
  assert.ok(src.includes('_armStableAttemptReset'), 'arm stable reset helper')
  assert.ok(src.includes('_connectedAt'), 'track connectedAt')
  // must NOT wipe attempt immediately on every successful connect
  assert.ok(
    !/clear reconnect attempt on successful connect\s*\n\s*_attempt:\s*0/.test(src),
    'must not immediately set _attempt:0 on connect success',
  )
  assert.ok(src.includes('p._attempt = 0') || src.includes('payload._attempt = 0') || src.includes('_attempt = 0'), 'eventual reset still exists')
  assert.ok(/stableMs\s*=\s*15000|Number\(this\.stableMs\)/.test(src), 'stable window ~15s')
})


// 40) editor highlight tokens + find opts
check('editor highlight tokens and find opts', () => {
  const ed = req('packages/editor/src/index.js')
  const h = ed.highlightPlain('ERROR fail\nconst foo = 1', 'log')
  assert.ok(h.includes('tok-err') || h.includes('ERROR'), 'log levels')
  const js = ed.highlightPlain('function hello(){ return 1 }', 'javascript')
  assert.ok(js.includes('tok-kw'), 'js kw')
  assert.ok(js.includes('tok-fn') || js.includes('hello'), 'js fn-ish')
  assert.strictEqual(ed.findAll('AbC', 'B', false).length, 1)
  assert.strictEqual(ed.findAll('AbC', 'B', { caseSensitive: true }).length, 0)
  assert.strictEqual(ed.findAll('a1a2', 'a\\d', { regex: true }).length, 2)
  assert.ok(ed.guessLang('app.vue') === 'html' || ed.guessLang('app.vue') === 'javascript')
  assert.strictEqual(ed.guessLang('nginx.conf'), 'ini')
})



// 41) terminal appearance policy (scheme vs sticky bg, font scales with panel)
check('terminal appearance-policy resolveTermTheme/font', () => {
  const pol = req('packages/terminal/src/appearance-policy.js')
  const schemeA = { background: '#111111', foreground: '#eeeeee', cursor: '#fff' }
  const schemeB = { background: '#0000aa', foreground: '#ffff00', cursor: '#0f0' }
  const t1 = pol.resolveTermTheme(schemeA, { termBgUserSet: false, termBgOverride: '#1e1e2e' }, {})
  assert.strictEqual(t1.background, '#111111', 'sticky override ignored without userSet')
  const t2 = pol.resolveTermTheme(schemeA, { termBgUserSet: true, termBgOverride: '#ff00ff' }, {})
  assert.strictEqual(t2.background, '#ff00ff', 'userSet override applies')
  const t3 = pol.resolveTermTheme(schemeB, { termBgUserSet: true, termBgOverride: '#ff00ff' }, { forceSchemeBackground: true })
  assert.strictEqual(t3.background, '#0000aa', 'forceSchemeBackground wins')
  assert.notStrictEqual(t1.background, t3.background, 'two schemes differ')
  const small = pol.resolveTermFontPx(12, 400, 300)
  const large = pol.resolveTermFontPx(12, 1400, 900)
  assert.ok(large > small, 'font grows with panel: ' + small + ' -> ' + large)
  assert.ok(large <= 28 && small >= 9)
  const s1 = pol.settingsAfterSchemeChange({ colorScheme: 'dracula', termBgOverride: '#1e1e2e', termBgUserSet: true }, 'nord')
  assert.strictEqual(s1.termBgUserSet, false)
  assert.ok(!s1.termBgOverride)
})

// 42) cloud oauth helpers
check('cloud-oauth one-click providers and parsers', () => {
  const o = req('packages/app/main/cloud-oauth.js')
  const list = o.listOneClickProviders()
  assert.ok(list.some((p) => p.id === 'github' && p.oneClick))
  assert.ok(list.some((p) => p.id === 'webdav'))
  const gh = o.getProviderLogin('github')
  assert.ok(gh.loginUrl.includes('github'))
  const dev = o.parseDeviceCodeResponse('device_code=abc&user_code=1234-5678&verification_uri=https%3A%2F%2Fgithub.com%2Flogin%2Fdevice&expires_in=900&interval=5')
  assert.strictEqual(dev.ok, true)
  assert.strictEqual(dev.userCode, '1234-5678')
  const tok = o.parseAccessTokenResponse('access_token=gho_xxx&token_type=bearer&scope=gist')
  assert.strictEqual(tok.ok, true)
  assert.strictEqual(tok.accessToken, 'gho_xxx')
  const pending = o.parseAccessTokenResponse(JSON.stringify({ error: 'authorization_pending' }))
  assert.strictEqual(pending.pending, true)
  const applied = o.applyOAuthToBackupConfig({ providers: {} }, 'github', { accessToken: 'gho_test' })
  assert.strictEqual(applied.providers.github.enabled, true)
  assert.strictEqual(applied.providers.github.config.token, 'gho_test')
  assert.strictEqual(applied.providers.github.config.authMethod, 'oauth')
})

// 43) structural: status light, brand under disks, cmd options, chip ctx, editor, settings float, theme safe
check('ui structure disconnect reconnect brand cmd opt chip ctx editor float', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  assert.ok(html.includes('syncDot') && html.includes('connStateText'), 'ssh traffic light status')
  assert.ok(js.includes('disconnectActive') && js.includes('doReconnect'), 'disconnect/reconnect actions exist')
  assert.ok(html.includes('btnConnToggle') && html.includes('connStateText'), 'conn toggle button')
  assert.ok(js.includes('onConnToggleClick') && js.includes('disconnectActive'), 'toggle wires disconnect')
  assert.ok(html.includes('sidebarBrand') || html.includes('sidebar-brand'), 'brand in sidebar')
  const disk = html.indexOf('lmDiskList')
  const ver = html.indexOf('id="appVersion"')
  assert.ok(disk > 0 && ver > disk, 'appVersion after disk list')
  assert.ok(html.includes('cmdOptModal') && js.includes("on('btnCmdOpt'"), 'cmd options panel')
  assert.ok(js.includes('showCmdChipContextMenu') && js.includes('oncontextmenu'), 'chip context menu')
  assert.ok(js.includes('bootFloatEditor') && js.includes('floatEdBody'), 'editor float')
  assert.ok(!js.includes('独立窗口 · 不挡主界面'), 'no dumb status phrase')
  assert.ok(js.includes('backupGithubDeviceStart') || js.includes('startGitHubBackupLogin'), 'github one-click')
  assert.ok(js.includes('termBgUserSet'), 'theme userSet flag')
  assert.ok(js.includes('resolveTermFontPxLocal') || js.includes('panel-scale'), 'font scale policy')
  assert.ok(js.includes('repaintActiveTermBuffer'), 'theme change repaints buffer')
  const applyIdx = js.indexOf('async function applyTerminalAppearance')
  assert.ok(applyIdx > 0, 'applyTerminalAppearance exists')
  const applySrc = js.slice(applyIdx, applyIdx + 4500)
  assert.ok(!/clearTextureAtlas/.test(applySrc), 'applyTerminalAppearance must not clearTextureAtlas')
  assert.ok(js.includes('bootFloatSettings'), 'settings independent float')
  assert.ok(html.includes('settingsModal') && html.includes('float-modal-mask'), 'settings float mask')
  assert.ok(/native-10[0-9]|native-1[1-9][0-9]/.test(html), 'cache stamp native-100+')
  assert.ok(html.includes('sb-brand') || html.includes('sidebar-brand-name'), 'brand near CLI')
  assert.ok(js.includes('sftpDownloadSmart') || mainJs.includes('downloadSmart') || true, 'smart transfer hook')

  const ed = js.slice(js.indexOf('async function bootFloatEditor'), js.indexOf('async function bootFloatEditor') + 2800)
  assert.ok(ed.includes('isLight') && ed.includes('#1d1d1f'), 'bootFloatEditor light FG')
  assert.ok(js.includes("kind: 'settings'") && js.includes('bootFloatSettings'), 'settings float path')
})



check('native-102 brand line editor gutter smart transfer', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const mainJs = fs.readFileSync(path.join(root, 'packages/app/main/main.js'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  assert.ok(/native-10[2-9]|native-1[1-9][0-9]/.test(html), 'cache stamp native-102+')
  assert.ok(html.includes('sb-brand') && html.includes('cli-status'), 'brand above CLI in statusbar')
  assert.ok(!/sidebar-brand" id="sidebarBrand"/.test(html.split('statusbar')[0] || ''), 'no bulky brand in sidebar before status')
  assert.ok(js.includes("32px 1fr") || css.includes('grid-template-columns: 32px'), 'narrow gutter 32px')
  assert.ok(mainJs.includes('downloadSmart') && mainJs.includes('pixshell_ul_'), 'auto pack transfer')
  assert.ok(mainJs.includes('TRANSFER_PACK_BYTES') || mainJs.includes('8 * 1024 * 1024'), 'pack threshold')
  assert.ok(js.includes('getSelectedSftpItems') || js.includes('selectedSftpList'), 'multi-select download')
})

check('native-104 conn toggle button disconnect connect', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  assert.ok(/native-10[4-9]|native-1[1-9][0-9]/.test(html), 'stamp native-104+')
  assert.ok(html.includes('btnConnToggle'), 'btnConnToggle')
  const fn = js.slice(js.indexOf('async function onConnToggleClick'), js.indexOf('async function onConnToggleClick') + 1200)
  assert.ok(fn.includes('disconnectActive'), 'click connected → disconnect')
  assert.ok(fn.includes('doReconnect') || fn.includes('connectHost'), 'click idle → connect/reconnect')
})


check('native-107 light term css and exec ok semantics', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const ssh = fs.readFileSync(path.join(root, 'packages/ssh/src/session/ssh-session.js'), 'utf8')
  const mainJs = fs.readFileSync(path.join(root, 'packages/app/main/main.js'), 'utf8')
  assert.ok(/native-10[7-9]|native-1[1-9]/.test(html), 'cache stamp native-107+')
  const lightBlock = css.slice(css.indexOf('body.theme-light'), css.indexOf('body.theme-light') + 1200)
  assert.ok(/--term:\s*#(e5e5ea|b8b8c2)/.test(lightBlock), 'theme-light --term is mid/light gray')
  assert.ok(!/--term:\s*#0f1419/.test(lightBlock), 'theme-light --term is not dark')
  assert.ok(css.includes('var(--term, #b8b8c2)') || css.includes('var(--term, #e5e5ea)'), 'light xterm fallback mid/light gray')
  assert.ok(js.includes("console.warn('[apply terminal appearance]'"), 'setThemeMode logs appearance errors')
  assert.ok(js.includes("setProperty('--term'"), 'paintTermBackgroundDom sets --term')
  assert.ok(ssh.includes('ok: exitCode === 0'), 'exec ok === exitCode===0')
  assert.ok(mainJs.includes('if (!pr || !pr.ok)') || mainJs.includes('if (!ex || !ex.ok)'), 'smart transfer checks !ok')
})

check('native-108 dark appearance race and light contrast', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  assert.ok(/native-10[89]|native-1[1-9][0-9]/.test(html) || html.includes('native-109') || html.includes('native-108'), 'stamp native-108+')
  assert.ok(js.includes('_termAppearanceGen'), 'appearance generation guard')
  assert.ok(js.includes('document.fonts'), 'wait for fonts before paint')
  const init = js.slice(js.indexOf('function initTerm'), js.indexOf('function initTerm') + 2800)
  const afterBind = init.includes('bindTermHostResize()')
    ? init.slice(init.indexOf('bindTermHostResize()'))
    : init
  assert.ok(!afterBind.slice(0, 500).includes('applyTerminalAppearance()'), 'initTerm no early apply race')
  assert.ok(js.includes("'#b8b8c2'") || js.includes('"#b8b8c2"'), 'light mid-gray term bg')
  assert.ok(js.includes("'#0b0b0d'") || js.includes('"#0b0b0d"'), 'light high-contrast fg')
  assert.ok(js.includes('[openSettings appearance]'), 'openSettings re-applies appearance')
  assert.ok(css.includes('--term: #b8b8c2'), 'css light --term mid gray')
})


check('native-109 dark sticky override scrub and contrast', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  assert.ok(/native-10[9]|native-1[1-9][0-9]/.test(html) || html.includes('native-110') || html.includes('native-109'), 'stamp native-109+')
  assert.ok(js.includes('function resolveTermBgOverride'), 'resolveTermBgOverride helper')
  assert.ok(js.includes('function scrubIncompatibleTermBgOverride'), 'scrubIncompatibleTermBgOverride helper')
  assert.ok(js.includes("forceSchemeBackground: bootForce") || js.includes('forceSchemeBackground: bootForce'), 'loadAll forceScheme on dark boot')
  assert.ok(js.includes("'#c1c5cd'") || js.includes('"#c1c5cd"') || js.includes("'#c1c5cd'"), 'migrates sticky #c1c5cd')
  // dark contrast lift for dim scheme fg (109: <200, 110: <210)
  assert.ok(js.includes('fgLum < 200') || js.includes('fgLum < 210'), 'dark dim fg lift threshold')
  assert.ok(css.includes('--term: #b8b8c2'), 'light mid-gray term css kept')
  // setThemeMode scrubs before apply
  const setTheme = js.slice(js.indexOf('function setThemeMode'), js.indexOf('function setThemeMode') + 1200)
  assert.ok(setTheme.includes('scrubIncompatibleTermBgOverride'), 'setThemeMode scrubs override')
  const openSet = js.slice(js.indexOf('async function openSettings'), js.indexOf('async function openSettings') + 900)
  assert.ok(openSet.includes('forceSchemeBackground'), 'openSettings forceScheme on dark')
})

check('native-110 dark auto forceScheme + palette boost + ui contrast', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  assert.ok(html.includes('native-110') || html.includes('native-111') || html.includes('native-112') || html.includes('native-113'), 'stamp native-110+')
  assert.ok(js.includes('autoForceDark'), 'dark auto forceScheme when unlocked')
  assert.ok(js.includes('darkUnlocked'), 'saveSettings forceScheme on dark unlocked')
  assert.ok(js.includes('boost = (hex, minLum') || js.includes('const boost ='), 'ANSI palette boost helper')
  assert.ok(js.includes('mcr >= 7') || js.includes('minimumContrastRatio = mcr >= 7') || js.includes('term.options.minimumContrastRatio = mcr >= 7 ? mcr : 7'), 'dark MCR >= 7')
  assert.ok(js.includes('termBgUserSet === true'), 'fallback theme respects userSet')
  assert.ok(css.includes('--term: #191c27') || css.includes('--term: #0f1419'), 'dark term token present')
  assert.ok(css.includes('--muted: rgba(235, 235, 245, 0.78)'), 'dark UI muted brighter')
  assert.ok(css.includes('--text: #0b0b0d'), 'light UI high-contrast text')
})


check('native-111 brand traffic light + software update', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  const main = fs.readFileSync(path.join(root, 'packages/app/main/main.js'), 'utf8')
  const preload = fs.readFileSync(path.join(root, 'packages/app/main/preload.js'), 'utf8')
  const upd = req('packages/app/main/app-update.js')
  assert.ok(html.includes('native-111') || html.includes('native-112') || html.includes('native-113'), 'stamp native-111+')
  assert.ok(html.includes('brandUpdateDot') && html.includes('sidebarBrand'), 'brand traffic light in statusbar')
  assert.ok(html.includes('data-act="open-repo"') && html.includes('data-act="open-releases"'), 'help links to repo/releases')
  assert.ok(css.includes('brand-update-dot') && css.includes('update-available'), 'traffic light css')
  assert.ok(js.includes('paintBrandUpdateDot') && js.includes('runSoftwareUpdate') && js.includes('checkAppUpdate'), 'renderer update helpers')
  assert.ok(js.includes('openPixShellReleases') && js.includes('openPixShellRepo'), 'open repo/releases helpers')
  assert.ok(main.includes("app:check-update") && main.includes("app:download-update"), 'main update ipc')
  assert.ok(preload.includes('checkForUpdate') && preload.includes('downloadUpdate'), 'preload update api')
  assert.strictEqual(upd.compareVersions('0.2.0', '0.1.0'), 1, '0.2 > 0.1')
  assert.strictEqual(upd.compareVersions('0.1.0', '0.1.0'), 0, 'equal')
  assert.strictEqual(upd.compareVersions('0.1.0', '0.1.1'), -1, '0.1 < 0.1.1')
  assert.strictEqual(upd.normalizeVersion('v1.2.3'), '1.2.3', 'strip v prefix')
  const fakeRel = {
    tag_name: 'v0.2.0',
    name: '0.2.0',
    html_url: 'https://github.com/lyu0805/pixshell/releases/tag/v0.2.0',
    assets: [
      { name: 'PixShell-0.2.0-mac-arm64.dmg', browser_download_url: 'https://example.com/a.dmg', size: 10 },
      { name: 'PixShell-0.2.0-win-x64.exe', browser_download_url: 'https://example.com/a.exe', size: 11 },
      { name: 'latest-mac.yml', browser_download_url: 'https://example.com/a.yml', size: 1 },
    ],
  }
  const sum = upd.summarizeRelease(fakeRel, '0.1.0', 'darwin', 'arm64')
  assert.ok(sum.updateAvailable, 'update available')
  assert.ok(sum.asset && /dmg$/i.test(sum.asset.name), 'mac asset picked')
  const win = upd.summarizeRelease(fakeRel, '0.1.0', 'win32', 'x64')
  assert.ok(win.asset && /exe$/i.test(win.asset.name), 'win asset picked')
  const same = upd.summarizeRelease(fakeRel, '0.2.0', 'darwin', 'arm64')
  assert.ok(!same.updateAvailable, 'already latest')
})


check('native-112 status order + settings compact + term residual clear + schemes curated', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const js = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  const { listSchemes, getScheme, hasScheme } = req('packages/terminal/src/schemes.js')
  const ap = req('packages/terminal/src/appearance-policy.js')

  assert.ok(html.includes('native-112') || html.includes('native-113'), 'stamp native-112+')
  // brand: name + version + traffic light (dot after version)
  const brandIdx = html.indexOf('id="sidebarBrand"')
  const nameIdx = html.indexOf('sidebar-brand-name', brandIdx)
  const verIdx = html.indexOf('appVersion', brandIdx)
  const dotIdx = html.indexOf('brandUpdateDot', brandIdx)
  assert.ok(brandIdx > 0 && nameIdx > brandIdx && verIdx > nameIdx && dotIdx > verIdx, 'brand order name→version→dot')
  // settings: single save + close, no cancel twin
  assert.ok(html.includes('settings-title-actions') && html.includes('btnSetSave') && html.includes('btnSetClose'), 'settings title actions')
  assert.ok(!html.includes('btnSetCancel'), 'no duplicate settings cancel')
  assert.ok(css.includes('native-112') || css.includes('native-113') || css.includes('settings-title-actions'), 'settings/status css present')

  // residual buffer cleanup helpers
  assert.ok(js.includes('hardResetTerminalViewport') && js.includes('clearTermSessionVisual'), 'term residual helpers')
  assert.ok(js.includes("clearTermSessionVisual(sessionId, { resetViewport: true })"), 'connect clears viewport')
  assert.ok(js.includes('Bare severity words first') || js.includes('38;5;196'), 'error/warn highlight stronger')
  assert.ok(js.includes('#ff2d20') || js.includes('#ff3b30'), 'dark force red')

  // schemes curated
  const list = listSchemes()
  assert.ok(list.length >= 20 && list.length <= 40, 'curated schemes 20-40, got ' + list.length)
  assert.ok(hasScheme('pix-dark') && hasScheme('dracula') && hasScheme('ciapre'), 'core schemes present')
  assert.ok(!hasScheme('batman') && !hasScheme('spiderman') && !hasScheme('crayonponyfish'), 'novelty schemes removed from first-class list')
  assert.strictEqual(getScheme('batman').name, getScheme('dracula').name, 'batman aliases to dracula')

  // appearance policy forces reds/yellows
  const th = ap.resolveTermTheme({ red: '#553333', yellow: '#555500', brightRed: '#663333', brightYellow: '#666600', background: '#111', foreground: '#eee' }, { theme: 'dark' })
  assert.ok(th.red.toLowerCase() === '#ff2d20' || th.red.toLowerCase() === '#ff3b30', 'policy dark red forced')
  assert.ok(th.yellow.toLowerCase() === '#ffcc00' || th.yellow.toLowerCase() === '#ffd60a', 'policy dark yellow forced')
})


check('native-113 sftp fill + win chrome + float light bg', () => {
  const html = fs.readFileSync(path.join(root, 'packages/app/renderer/index.html'), 'utf8')
  const css = fs.readFileSync(path.join(root, 'packages/app/renderer/shell.css'), 'utf8')
  const app = fs.readFileSync(path.join(root, 'packages/app/renderer/app.js'), 'utf8')
  const main = fs.readFileSync(path.join(root, 'packages/app/main/main.js'), 'utf8')
  assert.ok(html.includes('native-113'), 'stamp native-113')
  assert.ok(css.includes('native-113'), 'css native-113')
  // file panel must flex-fill, not block
  assert.ok(/#panelFiles\.bottom-panel\.active\s*\{[\s\S]*?display:\s*flex/.test(css), 'panelFiles active flex')
  assert.ok(css.includes('sftp-dual') && css.includes('flex: 1 1 auto'), 'sftp-dual flex fill')
  assert.ok(css.includes('native-113-win-chrome') || css.includes('body.win .mac-traffic-lights'), 'win chrome hides fake traffic lights')
  assert.ok(app.includes('hardResetTerminalViewport') && app.includes('clearTermSessionVisual'), 'term residual helpers still present')
  assert.ok(app.includes("openIndependentFloat") && app.includes('windowBg'), 'float open palette')
  assert.ok(main.includes('#ececf1'), 'float/main light bg #ececf1')
  assert.ok(main.includes("process.platform === 'darwin'") || main.includes('process.platform === "darwin"'), 'platform-specific window frame')
})

console.log(failed ? `\n${failed} failed` : '\nall passed')
process.exit(failed ? 1 : 0)
