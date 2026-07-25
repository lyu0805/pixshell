#!/usr/bin/env node
/**
 * PixShell CLI — drive desktop sessions from system terminal / AI agents.
 * CLI surface: hosts/connect/sessions/shell/exec/screen/sftp.
 *
 * Usage:
 *   pixshell-cli sessions [--json]
 *   pixshell-cli hosts [--group-id <id>] [--json]
 *   pixshell-cli connect --host-id <id> [--timeout 120] [--json]
 *   pixshell-cli shell  --session <id> --cmd "ls -la"
 *   pixshell-cli send   --session <id> --text "top"
 *   pixshell-cli exec   --session <id> --cmd "uname -a"
 *   pixshell-cli screen --session <id> [--lines 200 | --all]
 *   pixshell-cli sftp list|download|upload ...
 */
'use strict'

const fs = require('fs')
const path = require('path')
const os = require('os')
const http = require('http')

const DEFAULT_PORT = Number(process.env.PIXSHELL_CLI_PORT) || 8766

function tokenPath() {
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'PixShell', 'agent_token')
  }
  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'PixShell', 'agent_token')
  }
  return path.join(os.homedir(), '.local', 'share', 'PixShell', 'agent_token')
}

function loadToken() {
  if (process.env.PIXSHELL_AGENT_TOKEN) return process.env.PIXSHELL_AGENT_TOKEN.trim()
  try {
    return fs.readFileSync(tokenPath(), 'utf8').trim()
  } catch {
    return ''
  }
}

function color(enabled, code, s) {
  if (!enabled) return s
  return `\x1b[${code}m${s}\x1b[0m`
}

/** Flags that always take a value (even if next token starts with `-`). */
const VALUE_FLAGS = new Set([
  'session',
  'cmd',
  'text',
  'lines',
  'path',
  'remote',
  'local',
  'group-id',
  'host-id',
  'timeout',
  'port',
  'token',
])

function parseArgs(argv) {
  const args = {
    _: [],
    flags: {},
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--') {
      args._.push(...argv.slice(i + 1))
      break
    }
    if (a === '--json') args.flags.json = true
    else if (a === '--all') args.flags.all = true
    else if (a === '--newline') args.flags.newline = true
    else if (a === '--no-newline') args.flags.noNewline = true
    else if (a === '--help' || a === '-h') args.flags.help = true
    else if (a.startsWith('--')) {
      // support --key=value
      const eq = a.indexOf('=')
      if (eq > 2) {
        const key = a.slice(2, eq)
        args.flags[key] = a.slice(eq + 1)
        continue
      }
      const key = a.slice(2)
      const next = argv[i + 1]
      if (next != null && (VALUE_FLAGS.has(key) || !next.startsWith('-'))) {
        args.flags[key] = next
        i++
      } else {
        args.flags[key] = true
      }
    } else if (a.startsWith('-') && a.length === 2) {
      const map = { s: 'session', c: 'cmd', t: 'text', n: 'lines', p: 'path', r: 'remote', l: 'local', g: 'group-id' }
      const key = map[a[1]] || a[1]
      const next = argv[i + 1]
      if (next != null && (VALUE_FLAGS.has(key) || !next.startsWith('-'))) {
        args.flags[key] = next
        i++
      } else args.flags[key] = true
    } else {
      args._.push(a)
    }
  }
  return args
}

function help() {
  return `PixShell CLI  · 从系统终端操作 PixShell 桌面端的活动会话

用法:
  pixshell-cli hosts [--group-id <id>] [--json]
  pixshell-cli connect --host-id <host_id> [--timeout 120] [--json]
  pixshell-cli sessions [--json]
  pixshell-cli shell --session <id> --cmd "ls -la"
  pixshell-cli send  --session <id> --text "top"
  pixshell-cli exec  --session <id> --cmd "uname -a"
  pixshell-cli screen --session <id> [--lines 200 | --all]
  pixshell-cli sftp list     --session <id> [--path /var/log]
  pixshell-cli sftp download --session <id> --remote /tmp/a.log [--local ./a.log]
  pixshell-cli sftp upload   --session <id> --local ./a.log --remote /tmp/a.log
  pixshell-cli health [--json]
  pixshell-cli token-path

命令:
  hosts, host-list   列出主机分组和主机
  connect, open      按 host_id 创建新会话（桌面端出现对应 tab）
  sessions, list     列出全部会话（先用它拿 session id）
  shell, send        把输入发到交互式终端（看得见，像手敲）
  exec, direct       直接执行命令并返回输出，不写入终端画面
  screen, read       读取会话当前终端屏幕缓冲
  sftp               列目录 / 下载 / 上传
  health             探测本地桥是否在线

选项:
  --session, -s <id>     目标会话 id（支持唯一前缀）
  --host-id <id>         connect 目标主机 id
  --group-id, -g <id>    hosts 目标分组
  --cmd, -c <command>    要执行/发送的命令（shell 自动回车）
  --text, -t <text>      原始文本（默认不回车，除非 --newline）
  --lines, -n <n>        screen 末 N 行
  --all                  screen 整个缓冲
  --timeout <seconds>    connect/exec 超时，默认 120
  --path, -p <path>      sftp list 路径
  --remote, -r <path>    sftp 远端路径
  --local, -l <path>     sftp 本地路径
  --port <port>          本地服务端口，默认 ${DEFAULT_PORT}
  --json                 JSON 输出
  --newline / --no-newline
  --help, -h

环境变量:
  PIXSHELL_CLI_PORT      默认端口
  PIXSHELL_AGENT_TOKEN   覆盖 agent_token 文件

说明:
  • 请先打开 PixShell 桌面端，并在设置中启用「外部 CLI 集成」。
  • token 文件: ${tokenPath()}
  • shell/send 写入交互终端；exec 走独立 SSH exec 通道。
`
}

function request(port, method, urlPath, { token, body, timeoutMs } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body != null ? JSON.stringify(body) : null
    const req = http.request(
      {
        host: '127.0.0.1',
        port,
        path: urlPath,
        method,
        headers: {
          Accept: 'application/json',
          ...(token ? { Authorization: 'Bearer ' + token } : {}),
          ...(payload
            ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
            : {}),
        },
        timeout: timeoutMs || 30000,
      },
      (res) => {
        const chunks = []
        res.on('data', (c) => chunks.push(c))
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8')
          let json = null
          try {
            json = JSON.parse(text)
          } catch {
            json = { ok: res.statusCode >= 200 && res.statusCode < 300, raw: text }
          }
          resolve({ status: res.statusCode, json, text })
        })
      },
    )
    req.on('error', (err) => reject(err))
    req.on('timeout', () => {
      req.destroy()
      reject(new Error('request timeout'))
    })
    if (payload) req.write(payload)
    req.end()
  })
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const useJson = !!args.flags.json
  const useColor = !useJson && process.stdout.isTTY
  const port = Number(args.flags.port) || DEFAULT_PORT
  const cmd = (args._[0] || '').toLowerCase()
  const sub = (args._[1] || '').toLowerCase()

  if (!cmd || args.flags.help) {
    process.stdout.write(help())
    process.exit(cmd ? 0 : 0)
  }

  if (cmd === 'token-path') {
    const p = tokenPath()
    if (useJson) console.log(JSON.stringify({ ok: true, path: p }))
    else console.log(p)
    return
  }

  const token = loadToken()

  const failConnect = (err) => {
    const msg =
      '无法连接 PixShell。请确认 PixShell 桌面端正在运行，并已启用外部 CLI 集成。' +
      (err && err.message ? ' (' + err.message + ')' : '')
    if (useJson) console.log(JSON.stringify({ ok: false, error: msg }))
    else console.error(color(useColor, '31', '✗ ') + msg)
    process.exit(1)
  }

  const call = async (method, p, body, timeoutMs) => {
    try {
      return await request(port, method, p, { token, body, timeoutMs })
    } catch (e) {
      failConnect(e)
    }
  }

  const print = (obj, pretty) => {
    if (useJson) {
      console.log(JSON.stringify(obj, null, 0))
      return
    }
    if (typeof pretty === 'function') pretty(obj)
    else if (obj && obj.error && !obj.ok) {
      console.error(color(useColor, '31', '✗ ') + obj.error)
    } else {
      console.log(JSON.stringify(obj, null, 2))
    }
  }

  // health
  if (cmd === 'health' || cmd === 'status') {
    const r = await call('GET', '/v1/health')
    print(r.json, (j) => {
      if (j.ok) console.log(color(useColor, '32', '✓ ') + `PixShell bridge :${j.port}  sessions=${j.sessions}`)
      else console.error(color(useColor, '31', '✗ ') + (j.error || 'fail'))
    })
    process.exit(r.json && r.json.ok ? 0 : 1)
  }

  if (!token) {
    const msg = '找不到 agent_token。请先启动 PixShell 并启用外部 CLI。\n路径: ' + tokenPath()
    if (useJson) console.log(JSON.stringify({ ok: false, error: msg }))
    else console.error(color(useColor, '31', '✗ ') + msg)
    process.exit(1)
  }

  // hosts
  if (cmd === 'hosts' || cmd === 'host-list') {
    let pathUrl = '/v1/app/hosts'
    const gid = args.flags['group-id'] || args.flags.g
    if (gid) pathUrl += '?group-id=' + encodeURIComponent(gid)
    const r = await call('GET', pathUrl)
    print(r.json, (j) => {
      if (!j.ok) return console.error(color(useColor, '31', '✗ ') + (j.error || 'fail'))
      if (j.hosts && !j.groups) {
        for (const h of j.hosts) {
          console.log(`${h.id}\t${h.username}@${h.host}:${h.port}\t${h.name || ''}`)
        }
        return
      }
      for (const g of j.groups || []) {
        console.log(color(useColor, '36', `[${g.name}]`))
        for (const h of g.hosts || []) {
          console.log(`  ${h.id}\t${h.username}@${h.host}:${h.port}\t${h.name || ''}`)
        }
      }
      if (j.hosts && j.hosts.length) {
        console.log(color(useColor, '36', '[未分组]'))
        for (const h of j.hosts) {
          console.log(`  ${h.id}\t${h.username}@${h.host}:${h.port}\t${h.name || ''}`)
        }
      }
    })
    process.exit(r.json && r.json.ok ? 0 : 1)
  }

  // connect
  if (cmd === 'connect' || cmd === 'open') {
    const hostId = args.flags['host-id'] || args.flags.hostId || args.flags.id
    if (!hostId) {
      print({ ok: false, error: '缺少 host_id：--host-id <host_id>' })
      process.exit(1)
    }
    const timeout = Number(args.flags.timeout) || 120
    const r = await call(
      'POST',
      '/v1/app/hosts/connect',
      { host_id: hostId, timeout },
      (timeout + 5) * 1000,
    )
    print(r.json, (j) => {
      if (j.ok) console.log(color(useColor, '32', '✓ ') + `session ${j.sessionId}  ${j.username}@${j.host}:${j.port}`)
      else console.error(color(useColor, '31', '✗ ') + (j.error || 'connect failed'))
    })
    process.exit(r.json && r.json.ok ? 0 : 1)
  }

  // sessions
  if (cmd === 'sessions' || cmd === 'list') {
    const r = await call('GET', '/v1/app/sessions')
    print(r.json, (j) => {
      if (!j.ok) return console.error(color(useColor, '31', '✗ ') + (j.error || 'fail'))
      const list = j.sessions || []
      if (!list.length) {
        console.log('(无活动会话)')
        return
      }
      for (const s of list) {
        console.log(`${s.id}\t${s.username}@${s.host}:${s.port}\t${s.status}\t${s.hostId || ''}`)
      }
    })
    process.exit(r.json && r.json.ok ? 0 : 1)
  }

  // shell / send
  if (cmd === 'shell' || cmd === 'send') {
    const session = args.flags.session || args.flags.s
    if (!session) {
      print({ ok: false, error: '缺少 session：--session <session_id>' })
      process.exit(1)
    }
    const body = { session }
    if (cmd === 'shell' || args.flags.cmd) {
      body.cmd = args.flags.cmd || args.flags.c
      if (!body.cmd) {
        print({ ok: false, error: '缺少 --cmd' })
        process.exit(1)
      }
    }
    if (args.flags.text != null || cmd === 'send') {
      body.text = args.flags.text != null ? args.flags.text : args.flags.t
      if (body.text == null) {
        print({ ok: false, error: '缺少 --text' })
        process.exit(1)
      }
    }
    if (args.flags.newline) body.newline = true
    if (args.flags.noNewline) body.newline = false
    const r = await call('POST', '/v1/app/shell', body)
    print(r.json, (j) => {
      if (j.ok) console.log(color(useColor, '32', '✓ ') + `sent → ${j.sessionId}`)
      else console.error(color(useColor, '31', '✗ ') + (j.error || 'fail'))
    })
    process.exit(r.json && r.json.ok ? 0 : 1)
  }

  // exec
  if (cmd === 'exec' || cmd === 'direct') {
    const session = args.flags.session || args.flags.s
    const c = args.flags.cmd || args.flags.c
    if (!session) {
      print({ ok: false, error: '缺少 session：--session <session_id>' })
      process.exit(1)
    }
    if (!c) {
      print({ ok: false, error: '缺少 --cmd' })
      process.exit(1)
    }
    const timeout = Number(args.flags.timeout) || 120
    const r = await call('POST', '/v1/app/exec', { session, cmd: c, timeout }, (timeout + 5) * 1000)
    if (useJson) {
      console.log(JSON.stringify(r.json))
    } else if (r.json && r.json.ok) {
      process.stdout.write(r.json.stdout || '')
      if (r.json.stderr) process.stderr.write(r.json.stderr)
    } else {
      console.error(color(useColor, '31', '✗ ') + ((r.json && r.json.error) || 'exec failed'))
      if (r.json && r.json.stdout) process.stdout.write(r.json.stdout)
      if (r.json && r.json.stderr) process.stderr.write(r.json.stderr)
    }
    process.exit(r.json && r.json.ok ? 0 : 1)
  }

  // screen
  if (cmd === 'screen' || cmd === 'read') {
    const session = args.flags.session || args.flags.s
    if (!session) {
      print({ ok: false, error: '缺少 session：--session <session_id>' })
      process.exit(1)
    }
    const q = new URLSearchParams({ session })
    if (args.flags.all) q.set('all', '1')
    if (args.flags.lines || args.flags.n) q.set('lines', String(args.flags.lines || args.flags.n))
    const r = await call('GET', '/v1/app/screen?' + q.toString())
    if (useJson) console.log(JSON.stringify(r.json))
    else if (r.json && r.json.ok) process.stdout.write((r.json.text || '') + (r.json.text && !r.json.text.endsWith('\n') ? '\n' : ''))
    else console.error(color(useColor, '31', '✗ ') + ((r.json && r.json.error) || 'fail'))
    process.exit(r.json && r.json.ok ? 0 : 1)
  }

  // sftp
  if (cmd === 'sftp') {
    const session = args.flags.session || args.flags.s
    if (!session) {
      print({ ok: false, error: '缺少 session：--session <session_id>' })
      process.exit(1)
    }
    if (sub === 'list' || sub === 'ls' || !sub) {
      const remotePath = args.flags.path || args.flags.p || args.flags.remote || '/'
      const r = await call('POST', '/v1/app/sftp/list', { session, path: remotePath })
      print(r.json, (j) => {
        if (!j.ok) return console.error(color(useColor, '31', '✗ ') + (j.error || 'fail'))
        console.log(color(useColor, '36', j.path || remotePath))
        for (const e of j.entries || []) {
          const mark = e.isDir ? 'd' : e.isSymlink ? 'l' : '-'
          console.log(`${mark}\t${e.size}\t${e.name}`)
        }
      })
      process.exit(r.json && r.json.ok ? 0 : 1)
    }
    if (sub === 'download' || sub === 'get') {
      const remote = args.flags.remote || args.flags.r
      const local = args.flags.local || args.flags.l
      if (!remote) {
        print({ ok: false, error: '缺少 --remote' })
        process.exit(1)
      }
      const r = await call('POST', '/v1/app/sftp/download', { session, remote, local })
      print(r.json, (j) => {
        if (j.ok) console.log(color(useColor, '32', '✓ ') + (j.localPath || local || 'downloaded'))
        else console.error(color(useColor, '31', '✗ ') + (j.error || 'fail'))
      })
      process.exit(r.json && r.json.ok ? 0 : 1)
    }
    if (sub === 'upload' || sub === 'put') {
      const remote = args.flags.remote || args.flags.r
      const local = args.flags.local || args.flags.l
      if (!remote || !local) {
        print({ ok: false, error: '需要 --local 与 --remote' })
        process.exit(1)
      }
      const r = await call('POST', '/v1/app/sftp/upload', { session, remote, local })
      print(r.json, (j) => {
        if (j.ok) console.log(color(useColor, '32', '✓ ') + (j.remotePath || remote))
        else console.error(color(useColor, '31', '✗ ') + (j.error || 'fail'))
      })
      process.exit(r.json && r.json.ok ? 0 : 1)
    }
    print({ ok: false, error: '未知 sftp 子命令: ' + sub })
    process.exit(1)
  }

  console.error('未知命令：' + cmd + '\n')
  process.stdout.write(help())
  process.exit(1)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
