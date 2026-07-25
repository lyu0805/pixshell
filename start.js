#!/usr/bin/env node
/**
 * Cross-platform launcher.
 *
 * Critical: /Volumes/d is Tuxera NTFS — npm install often fails with ENOENT on mkdir
 * under node_modules. We install & run from an APFS-local runtime dir when needed.
 *
 * Usage: node start.js
 */
const { spawn, spawnSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const os = require('os')

const SOURCE_ROOT = __dirname

function log(...a) {
  console.log(...a)
}

function exists(p) {
  try {
    return fs.existsSync(p)
  } catch {
    return false
  }
}

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, {
    cwd: opts.cwd || process.cwd(),
    stdio: 'inherit',
    shell: process.platform === 'win32',
    env: { ...process.env, ...(opts.env || {}) },
  })
  return r.status ?? 1
}

/** NTFS / network volumes break npm concurrent mkdir */
function needsLocalRuntime(root) {
  if (process.platform === 'win32') return false
  const n = root.replace(/\\/g, '/')
  if (n.startsWith('/Volumes/d') || n.startsWith('/Volumes/Win') || n.startsWith('/Volumes/SAMSUNG')) {
    return true
  }
  // also if node_modules creation previously failed markers
  return false
}

function localRuntimeRoot() {
  const base =
    process.platform === 'darwin'
      ? path.join(os.homedir(), 'Library', 'Application Support', 'PixShell')
      : path.join(os.homedir(), '.local', 'share', 'PixShell')
  return path.join(base, 'app')
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true })
}

function pixshellElectronRunning() {
  if (process.platform === 'win32') return false
  try {
    const r = spawnSync('pgrep', ['-f', 'PixShell/app/node_modules/electron|PixShell/app/packages/app/main'], {
      encoding: 'utf8',
    })
    const out = String(r.stdout || '').trim()
    return r.status === 0 && out.length > 0
  } catch {
    return false
  }
}

/** Best-effort: ensure runtime tree is user-writable before rsync/cp */
function ensureRuntimeWritable(dst) {
  if (process.platform === 'win32' || !exists(dst)) return
  try {
    // 不递归 chown 整个树（慢）；只修常见被锁目录权限
    const targets = [
      dst,
      path.join(dst, 'packages'),
      path.join(dst, 'packages', 'app'),
      path.join(dst, 'packages', 'app', 'main'),
      path.join(dst, 'packages', 'app', 'renderer'),
    ]
    for (const p of targets) {
      if (!exists(p)) continue
      try {
        fs.chmodSync(p, 0o755)
      } catch (_) {}
    }
  } catch (_) {}
}

/**
 * Sync project sources → runtime (exclude heavy/junk).
 *
 * 说明：源码常在 NTFS（/Volumes/d），运行在 APFS Application Support。
 * rsync --delete 在「旧 Electron 仍占着 renderer/*.js」时会 unlinkat Permission denied。
 * 策略：先无 --delete 覆盖更新（可热更大部分文件）→ 失败再 cp -Rf → 不 rm -rf 整树。
 */
function syncToRuntime(src, dst) {
  ensureDir(dst)
  ensureRuntimeWritable(dst)

  const excludes = [
    '--exclude',
    'node_modules',
    '--exclude',
    '.npm-cache',
    '--exclude',
    '.git',
    '--exclude',
    'logs',
    '--exclude',
    'dist',
  ]
  const from = src.endsWith('/') ? src : src + '/'
  const to = dst.endsWith('/') ? dst : dst + '/'

  if (pixshellElectronRunning()) {
    log('[sync] 检测到 PixShell/Electron 仍在运行 — 用「覆盖更新」同步（不 --delete）')
    log('[sync] 若界面仍是旧版，请先完全退出 PixShell 再启动')
  }

  if (process.platform !== 'win32' && exists('/usr/bin/rsync')) {
    // 1) 覆盖更新（不删多余文件）— 旧实例占文件时成功率更高
    let code = run('rsync', ['-a'].concat(excludes).concat([from, to]), { cwd: src })
    if (code === 0) {
      // 2) 空闲时再尝试 --delete 清理 runtime 里已删除的源文件
      if (!pixshellElectronRunning()) {
        const dcode = run(
          'rsync',
          ['-a', '--delete'].concat(excludes).concat([from, to]),
          { cwd: src },
        )
        if (dcode !== 0) {
          log('[sync] rsync --delete 跳过（可忽略；覆盖更新已成功）')
        }
      }
      return true
    }
    log('[warn] rsync 覆盖失败，改用 cp -Rf（不是崩溃）')
    log('[warn] 常见原因：旧 PixShell 未退出、文件被占用、或权限不足')
  }

  // minimal copy of essentials — 覆盖写，避免 rm -rf 整包（Electron 运行中会 Permission denied）
  const items = [
    'package.json',
    'start.js',
    'packages',
    'prototypes',
    'scripts',
    'docs',
    'themes',
    '代码说明概要.md',
  ]
  for (const name of items) {
    const fromPath = path.join(src, name)
    const toPath = path.join(dst, name)
    if (!exists(fromPath)) continue
    if (process.platform === 'win32') {
      run('xcopy', [fromPath, toPath, '/E', '/I', '/Y', '/Q'])
    } else {
      // cp -Rf：目录合并覆盖；失败时再尝试单文件
      const code = run('cp', ['-Rf', fromPath, path.dirname(toPath) + '/'])
      if (code !== 0) {
        log('[warn] cp 部分失败:', name, '— 可先退出 PixShell 后重试')
      }
    }
  }
  return true
}

function needInstall(root) {
  return !(
    exists(path.join(root, 'node_modules/electron')) &&
    exists(path.join(root, 'node_modules/ssh2')) &&
    exists(path.join(root, 'node_modules/@xterm/xterm'))
  )
}

function npmInstall(root) {
  const cache = path.join(root, '.npm-cache')
  ensureDir(cache)
  log('[install] npm install @', root)
  log('[install] cache =>', cache)
  // serial optional: reduce NTFS issues if still on bad fs
  return run(
    process.platform === 'win32' ? 'npm.cmd' : 'npm',
    ['install', '--cache', cache, '--no-fund', '--no-audit'],
    {
      cwd: root,
      env: {
        npm_config_cache: cache,
        // electron mirror optional — user can set ELECTRON_MIRROR
      },
    },
  )
}

function verifyRuntimeDeps(root) {
  const ssh2 = path.join(root, 'node_modules/ssh2')
  const electron = path.join(root, 'node_modules/electron')
  const xterm = path.join(root, 'node_modules/@xterm/xterm')
  const miss = []
  if (!exists(ssh2)) miss.push('ssh2')
  if (!exists(electron)) miss.push('electron')
  if (!exists(xterm)) miss.push('@xterm/xterm')
  if (miss.length) {
    log('[ERROR] 缺少依赖:', miss.join(', '))
    log('[ERROR] 请执行: cd "' + root + '" && npm install')
    return false
  }
  // ssh2 verify
  try {
    const r = spawnSync(process.execPath, ['-e', "require('ssh2');console.log('ok')"], {
      cwd: root,
      encoding: 'utf8',
    })
    if (!r.stdout || !r.stdout.includes('ok')) {
      log('[ERROR] ssh2 无法 require，stdout=', r.stdout, 'stderr=', r.stderr)
      return false
    }
    log('[ok] ssh2 可加载')
  } catch (e) {
    log('[ERROR] ssh2 检测失败', e.message)
    return false
  }
  return true
}

function startElectron(root) {
  process.env.ELECTRON_DISABLE_SECURITY_WARNINGS = '1'
  const mainJs = path.join(root, 'packages/app/main/main.js')
  if (!exists(mainJs)) {
    log('[ERROR] missing', mainJs)
    process.exit(1)
  }
  const localCli = path.join(root, 'node_modules/electron/cli.js')
  const localBin =
    process.platform === 'win32'
      ? path.join(root, 'node_modules/.bin/electron.cmd')
      : path.join(root, 'node_modules/.bin/electron')

  let electronCmd
  let electronArgs
  if (exists(localCli)) {
    electronCmd = process.execPath
    electronArgs = [localCli, mainJs]
  } else if (exists(localBin)) {
    electronCmd = localBin
    electronArgs = [mainJs]
  } else {
    electronCmd = process.platform === 'win32' ? 'npx.cmd' : 'npx'
    electronArgs = ['electron', mainJs]
  }

  log('[start] electron cwd=', root)
  const child = spawn(electronCmd, electronArgs, {
    cwd: root,
    stdio: 'inherit',
    shell: process.platform === 'win32',
    env: process.env,
  })
  child.on('exit', (code) => process.exit(code || 0))
  child.on('error', (err) => {
    log('[ERROR]', err.message)
    process.exit(1)
  })
}

function main() {
  log('==========================================')
  log('  PIXSHELL')
  log('==========================================')
  log('Source:', SOURCE_ROOT)

  let root = SOURCE_ROOT
  if (needsLocalRuntime(SOURCE_ROOT)) {
    root = localRuntimeRoot()
    log('[fs] NTFS/外置卷检测到 → 运行目录改到 APFS:')
    log('     ', root)
    log('[sync] 同步源码 → 运行目录 ...')
    syncToRuntime(SOURCE_ROOT, root)
  } else {
    log('[fs] 使用源码目录运行')
  }

  log('')
  log('[1/3] Node', process.version)

  if (needInstall(root)) {
    log('[2/3] 安装依赖 ...')
    const code = npmInstall(root)
    if (code !== 0) {
      log('[ERROR] npm install failed:', code)
      log('')
      log('若仍失败，请手动执行：')
      log('  mkdir -p "' + root + '"')
      log('  rsync -a --delete --exclude node_modules --exclude .npm-cache "' + SOURCE_ROOT + '/" "' + root + '/"')
      log('  cd "' + root + '" && npm install --cache ./.npm-cache')
      log('  node start.js')
      process.exit(code)
    }
  } else {
    log('[2/3] 依赖已就绪')
  }

  log('[3/3] 启动 Electron ...')
  if (!verifyRuntimeDeps(root)) {
    log('[retry] 重新 npm install ...')
    npmInstall(root)
    if (!verifyRuntimeDeps(root)) process.exit(1)
  }
  startElectron(root)
}

main()
