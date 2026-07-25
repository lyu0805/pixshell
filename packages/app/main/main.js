/**
 * PixShell Electron main process — native SSH engine IPC, no mock.
 */
'use strict'

const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron')
const path = require('path')
const fs = require('fs')
const os = require('os')
const { SshEngine } = require('./ssh-engine')
const log = require('./logger')
const { createAgentBridge } = require('./agent-bridge')
const cloudOAuth = require('./cloud-oauth')
const appUpdate = require('./app-update')

let mainWindow = null
/** native-113-float-theme */
/** @type {Map<string, import('electron').BrowserWindow>} */
const floatWindows = new Map()
/** @type {Map<string, any>} 浮窗首屏数据（大文本不进 URL） */
const floatInitData = new Map()
const engine = new SshEngine()
/** @type {Map<string, string>} shared terminal screen buffers for CLI `screen` */
const screenStore = new Map()
const agentBridge = createAgentBridge({
  engine,
  getMainWindow: () => mainWindow,
  screenStore,
  onUiEvent: (msg) => {
    if (!mainWindow || mainWindow.isDestroyed()) return
    try {
      mainWindow.webContents.send('cli:event', msg)
    } catch (_) {}
  },
})

try {
  app.setName('PixShell')
  if (app.setAppUserModelId) app.setAppUserModelId('com.pixshell.app')
} catch (_) {}

/** Local path sandbox for IPC that accepts an explicit path (no dialog). */
function pathRoots() {
  const roots = [os.homedir(), os.tmpdir()]
  try {
    roots.push(app.getPath('downloads'))
  } catch (_) {}
  try {
    roots.push(app.getPath('userData'))
  } catch (_) {}
  try {
    roots.push(app.getPath('documents'))
  } catch (_) {}
  try {
    roots.push(app.getPath('desktop'))
  } catch (_) {}
  return roots.filter(Boolean)
}

function assertUnderRoots(p, label) {
  const resolved = path.resolve(String(p || ''))
  if (!resolved || resolved.includes('\0')) throw new Error('bad path')
  const ok = pathRoots().some((root) => {
    const r = path.resolve(root)
    return resolved === r || resolved.startsWith(r + path.sep)
  })
  if (!ok) throw new Error((label || 'path') + ' not allowed: ' + resolved)
  return resolved
}

function assertUserWritablePath(p) {
  return assertUnderRoots(p, 'write path')
}

function assertUserReadablePath(p) {
  return assertUnderRoots(p, 'read path')
}

const { execFile, spawn } = require('child_process')
const { promisify } = require('util')
const execFileAsync = promisify(execFile)

const TRANSFER_PACK_BYTES = 8 * 1024 * 1024 // 8MB

function runLocal(cmd, args, opts = {}) {
  return execFileAsync(cmd, args, {
    maxBuffer: 32 * 1024 * 1024,
    ...opts,
  }).then(
    (r) => ({ ok: true, stdout: r.stdout || '', stderr: r.stderr || '' }),
    (e) => ({ ok: false, error: e.message || String(e), stdout: e.stdout || '', stderr: e.stderr || '' }),
  )
}

function shellQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`
}

function localFileSize(p) {
  try {
    return fs.statSync(p).size || 0
  } catch (_) {
    return 0
  }
}

async function remoteStatSize(sessionId, remotePath) {
  try {
    const r = await engine.exec(
      sessionId,
      `stat -c %s -- ${shellQuote(remotePath)} 2>/dev/null || stat -f %z -- ${shellQuote(remotePath)} 2>/dev/null || wc -c < ${shellQuote(remotePath)} 2>/dev/null`,
    )
    const n = parseInt(String(r?.stdout || r?.out || '').trim().split(/\s+/).pop(), 10)
    return Number.isFinite(n) ? n : 0
  } catch (_) {
    return 0
  }
}

async function shouldPackLocal(paths) {
  if (!paths || paths.length === 0) return false
  if (paths.length > 1) return true
  const p = paths[0]
  try {
    const st = fs.statSync(p)
    if (st.isDirectory()) return true
    if (st.size >= TRANSFER_PACK_BYTES) return true
  } catch (_) {}
  return false
}

async function shouldPackRemote(sessionId, paths) {
  if (!paths || paths.length === 0) return false
  if (paths.length > 1) return true
  const sz = await remoteStatSize(sessionId, paths[0])
  if (sz >= TRANSFER_PACK_BYTES) return true
  // directory heuristic via remote test
  try {
    const r = await engine.exec(sessionId, `test -d ${shellQuote(paths[0])} && echo DIR || echo FILE`)
    if (/DIR/.test(String(r?.stdout || r?.out || ''))) return true
  } catch (_) {}
  return false
}



// ═══════════════════════════════════════════════════════════
// HARD RULE: GPU hardware acceleration is mandatory on every
// platform we ship — macOS x86_64 (Intel), macOS arm64
// (Apple Silicon), Windows x86_64. Never call
// app.disableHardwareAcceleration(). Switches MUST run before ready.
// ═══════════════════════════════════════════════════════════
try {
  // Never software-rasterize UI / canvas / WebGL
  if (typeof app.disableHardwareAcceleration === 'function') {
    // deliberately NOT calling it — document the ban
  }
  app.commandLine.appendSwitch('ignore-gpu-blocklist')
  app.commandLine.appendSwitch('enable-gpu-rasterization')
  app.commandLine.appendSwitch('enable-zero-copy')
  app.commandLine.appendSwitch('enable-native-gpu-memory-buffers')
  app.commandLine.appendSwitch('enable-accelerated-2d-canvas')
  app.commandLine.appendSwitch('canvas-msaa-sample-count', '0')
  app.commandLine.appendSwitch('enable-hardware-overlays', 'single-fullscreen,single-on-top,underlay')
  app.commandLine.appendSwitch('num-raster-threads', '4')

  // Feature flags (merge carefully — Chromium takes last enable-features)
  const gpuFeatures = [
    'CanvasOopRasterization',
    'Accelerated2dCanvas',
    'UseSkiaRenderer',
  ]
  if (process.platform === 'darwin') {
    // Metal on both Intel + Apple Silicon
    // Metal enabled via use-angle=metal; no extra feature flag needed
  } else if (process.platform === 'win32') {
    // D3D / dual-GPU laptops: prefer discrete GPU for this process
    gpuFeatures.push('D3D11VideoDecoder')
    app.commandLine.appendSwitch('force_high_performance_gpu')
    app.commandLine.appendSwitch('enable-accelerated-video-decode')
  } else if (process.platform === 'linux') {
    gpuFeatures.push('VaapiVideoDecoder', 'VaapiVideoEncoder')
  }
  app.commandLine.appendSwitch('enable-features', gpuFeatures.join(','))

  // ANGLE backend: let Chromium pick Metal/D3D11/GL — never force swiftshader
  // (do not set use-gl=swiftshader / use-angle=swiftshader)
  if (process.platform === 'darwin') {
    app.commandLine.appendSwitch('use-angle', 'metal')
  } else if (process.platform === 'win32') {
    app.commandLine.appendSwitch('use-angle', 'd3d11')
  }
} catch (_) {}


function createWindow() {
  const iconPath = path.join(__dirname, '..', 'renderer', 'icons', 'app-icon.svg')
  // 默认高宽比约 4:3（高:宽 = 4:3 → 宽:高 = 3:4），偏高不宽扁
  // 基准 720×960，再夹进主屏工作区
  let winW = 720
  let winH = 960
  let winX
  let winY
  try {
    const { screen } = require('electron')
    const wa = screen.getPrimaryDisplay().workArea
    const maxW = Math.max(560, Math.floor(wa.width * 0.72))
    const maxH = Math.max(520, Math.floor(wa.height * 0.88))
    // 保持 3:4（宽:高）
    if (winH > maxH) {
      winH = maxH
      winW = Math.round((winH * 3) / 4)
    }
    if (winW > maxW) {
      winW = maxW
      winH = Math.round((winW * 4) / 3)
    }
    winW = Math.max(560, winW)
    winH = Math.max(520, winH)
    winX = Math.round(wa.x + (wa.width - winW) / 2)
    winY = Math.round(wa.y + Math.max(16, (wa.height - winH) / 2))
  } catch (_) {}
  mainWindow = new BrowserWindow({
    width: winW,
    height: winH,
    x: winX,
    y: winY,
    minWidth: 520,
    minHeight: Math.round((520 * 4) / 3), // 保持可缩放时仍偏高
    backgroundColor: '#181825',
    title: 'PixShell',
    // mac: hidden titlebar + traffic lights; Windows/Linux: system frame buttons (no fake mac lights)
    ...(process.platform === 'darwin'
      ? {
          titleBarStyle: 'hidden',
          trafficLightPosition: { x: 12, y: 8 },
        }
      : {
          frame: true,
          autoHideMenuBar: true,
        }),
    icon: iconPath,
    paintWhenInitiallyHidden: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: false,
      backgroundThrottling: false,
      offscreen: false,
      webgl: true,
      experimentalFeatures: false,
      enableBlinkFeatures: 'Canvas2dGPUTransfer',
    },
    show: false,
    useContentSize: false,
    center: winX == null,
  })

  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'))
  mainWindow.once('ready-to-show', () => {
    if (!mainWindow || mainWindow.isDestroyed()) return
    try {
      mainWindow.setSize(winW, winH, false)
      if (winX != null && winY != null) mainWindow.setPosition(winX, winY, false)
      else mainWindow.center()
    } catch (_) {}
    mainWindow.show()
  })

  // Surface GPU status to logs for self-audit (no UI noise)
  try {
    mainWindow.webContents.on('did-finish-load', async () => {
      try {
        const st = await mainWindow.webContents.executeJavaScript(
          `({
            webgl: !!(document.createElement('canvas').getContext('webgl') || document.createElement('canvas').getContext('experimental-webgl')),
            webgl2: !!document.createElement('canvas').getContext('webgl2'),
            hw: typeof navigator !== 'undefined' ? (navigator.hardwareConcurrency||0) : 0,
            plat: typeof navigator !== 'undefined' ? navigator.platform : '',
            ua: typeof navigator !== 'undefined' ? navigator.userAgent : ''
          })`,
          true,
        )
        console.log('[PixShell GPU]', JSON.stringify(st)); try { log.info('gpu', 'probe', st) } catch (_) {}
        if (st && st.webgl === false) {
          console.error('[PixShell GPU] WebGL unavailable — hardware acceleration broken')
        }
      } catch (e) {
        console.warn('[PixShell GPU] probe failed', e && e.message)
      }
    })
  } catch (_) {}

  engine.setDataHandler((sessionId, chunk) => {
    // always feed CLI screen buffer (even if window briefly gone)
    try {
      agentBridge.appendScreen(sessionId, chunk)
    } catch (_) {}
    if (!mainWindow || mainWindow.isDestroyed()) return
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    mainWindow.webContents.send('ssh:data', {
      sessionId,
      data: buf.toString('utf8'),
      dataBase64: buf.toString('base64'),
    })
  })
  engine.setStatusHandler((sessionId, status, message) => {
    try {
      log.info('ssh-status', String(status), { sessionId, message: String(message || '').slice(0, 200) })
    } catch (_) {}
    if (status === 'closed' || status === 'error') {
      try {
        agentBridge.clearScreen(sessionId)
      } catch (_) {}
    }
    if (!mainWindow || mainWindow.isDestroyed()) return
    mainWindow.webContents.send('ssh:status', { sessionId, status, message })
  })

  mainWindow.on('closed', () => {
    mainWindow = null
    // macOS: app often stays alive after last window; keep SSH + agent bridge for activate.
    // Other platforms quit via window-all-closed which still closes sessions.
    if (process.platform !== 'darwin') {
      try {
        engine.closeAll()
      } catch (_) {}
    }
  })

  // DevTools on env
  if (process.env.FS_DEBUG === '1') mainWindow.webContents.openDevTools({ mode: 'detach' })
}

function registerIpc() {
  ipcMain.handle('log:write', async (_e, payload = {}) => {
    try {
      const level = String(payload.level || 'info').toLowerCase()
      const tag = String(payload.tag || 'renderer').slice(0, 64)
      const msg = String(payload.msg || '')
      const extra = payload.extra
      if (level === 'error') log.error(tag, msg, extra)
      else if (level === 'warn') log.warn(tag, msg, extra)
      else if (level === 'debug') log.debug(tag, msg, extra)
      else log.info(tag, msg, extra)
      return { ok: true }
    } catch (e) {
      return { ok: false, error: e && e.message }
    }
  })
  ipcMain.handle('log:paths', async () => {
    try {
      return { ok: true, dirs: log.dirs() }
    } catch (e) {
      return { ok: false, error: e && e.message, dirs: [] }
    }
  })
  // window controls
  ipcMain.handle('window:minimize', async () => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.minimize()
    return { ok: true }
  })
  ipcMain.handle('window:maximize', async () => {
    if (mainWindow && !mainWindow.isDestroyed()) {
      if (mainWindow.isMaximized()) mainWindow.unmaximize()
      else mainWindow.maximize()
    }
    return { ok: true }
  })
  ipcMain.handle('window:close', async () => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.close()
    return { ok: true }
  })
  ipcMain.handle('window:isMaximized', async () => {
    return { ok: true, isMaximized: mainWindow && !mainWindow.isDestroyed() ? mainWindow.isMaximized() : false }
  })

  ipcMain.handle('window:new-main', async () => {
    createWindow()
    return { ok: true }
  })

  ipcMain.handle('window:set-bg', async (_e, color) => {
    try {
      const c = String(color || '').trim()
      if (!c || !mainWindow || mainWindow.isDestroyed()) return { ok: false }
      mainWindow.setBackgroundColor(c)
      return { ok: true }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })

  ipcMain.handle('app:get-version', async () => {
    try {
      let ver = '0.1.0'
      try {
        const pkgPath = path.join(__dirname, '..', '..', '..', 'package.json')
        const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'))
        if (pkg && pkg.version) ver = String(pkg.version)
      } catch (_) {
        try { ver = app.getVersion() } catch (__) {}
      }
      return { ok: true, version: ver }
    } catch (e) {
      return { ok: false, version: '0.1.0', error: String(e && e.message || e) }
    }
  })

  function readAppVersionSafe() {
    try {
      const pkgPath = path.join(__dirname, '..', '..', '..', 'package.json')
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'))
      if (pkg && pkg.version) return String(pkg.version)
    } catch (_) {}
    try {
      return app.getVersion()
    } catch (_) {
      return '0.1.0'
    }
  }

  ipcMain.handle('app:check-update', async () => {
    try {
      const current = readAppVersionSafe()
      const r = await appUpdate.checkForUpdate(current, {
        platform: process.platform,
        arch: process.arch,
      })
      return {
        ...r,
        repoUrl: appUpdate.REPO_URL,
        releasesUrl: appUpdate.RELEASES_URL,
      }
    } catch (e) {
      return {
        ok: false,
        status: 'error',
        updateAvailable: false,
        currentVersion: readAppVersionSafe(),
        latestVersion: '',
        releaseUrl: appUpdate.RELEASES_URL,
        htmlUrl: appUpdate.RELEASES_URL,
        repoUrl: appUpdate.REPO_URL,
        releasesUrl: appUpdate.RELEASES_URL,
        asset: null,
        error: String(e && e.message || e),
        message: '检查更新失败: ' + String(e && e.message || e),
      }
    }
  })

  ipcMain.handle('app:download-update', async (_e, payload = {}) => {
    try {
      const current = readAppVersionSafe()
      let info = payload && payload.info
      if (!info || !info.asset || !info.asset.url) {
        info = await appUpdate.checkForUpdate(current, {
          platform: process.platform,
          arch: process.arch,
        })
      }
      if (!info || !info.ok) {
        return {
          ok: false,
          error: (info && info.error) || 'check failed',
          message: (info && info.message) || '检查更新失败',
          info,
        }
      }
      if (!info.updateAvailable) {
        return {
          ok: true,
          skipped: true,
          reason: 'latest',
          message: info.message || '已是最新版本',
          info,
          repoUrl: appUpdate.REPO_URL,
          releasesUrl: appUpdate.RELEASES_URL,
        }
      }
      if (!info.asset || !info.asset.url) {
        // No packaged asset yet — open releases page for the user
        try {
          await shell.openExternal(info.htmlUrl || info.releaseUrl || appUpdate.RELEASES_URL)
        } catch (_) {}
        return {
          ok: true,
          skipped: true,
          reason: 'no-asset',
          opened: info.htmlUrl || info.releaseUrl || appUpdate.RELEASES_URL,
          message: '已有新版本，但暂无当前平台安装包，已打开发行页',
          info,
          repoUrl: appUpdate.REPO_URL,
          releasesUrl: appUpdate.RELEASES_URL,
        }
      }
      let destDir
      try {
        destDir = path.join(app.getPath('downloads'), 'PixShell-Updates')
      } catch (_) {
        destDir = path.join(os.homedir(), 'Downloads', 'PixShell-Updates')
      }
      const dl = await appUpdate.downloadUpdateAsset(info.asset, destDir)
      if (!dl.ok) {
        return {
          ok: false,
          error: dl.error || 'download failed',
          message: '下载更新失败: ' + (dl.error || 'unknown'),
          info,
        }
      }
      try {
        await shell.showItemInFolder(dl.path)
      } catch (_) {
        try { await shell.openPath(path.dirname(dl.path)) } catch (__) {}
      }
      return {
        ok: true,
        downloaded: true,
        path: dl.path,
        bytes: dl.bytes,
        name: dl.name,
        message: `已下载 ${dl.name}，请运行安装包完成更新`,
        info,
        repoUrl: appUpdate.REPO_URL,
        releasesUrl: appUpdate.RELEASES_URL,
      }
    } catch (e) {
      return {
        ok: false,
        error: String(e && e.message || e),
        message: '下载更新失败: ' + String(e && e.message || e),
        repoUrl: appUpdate.REPO_URL,
        releasesUrl: appUpdate.RELEASES_URL,
      }
    }
  })

  ipcMain.handle('app:open-releases', async () => {
    try {
      await shell.openExternal(appUpdate.RELEASES_URL)
      return { ok: true, url: appUpdate.RELEASES_URL }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e), url: appUpdate.RELEASES_URL }
    }
  })

  ipcMain.handle('app:open-repo', async () => {
    try {
      await shell.openExternal(appUpdate.REPO_URL)
      return { ok: true, url: appUpdate.REPO_URL }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e), url: appUpdate.REPO_URL }
    }
  })

  ipcMain.handle('window:cursor-screen', async () => {
    try {
      const { screen } = require('electron')
      const p = screen.getCursorScreenPoint()
      return { ok: true, x: p.x, y: p.y }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })


  // 独立桌面窗（连接管理器 / 编辑器 等）— 打开即独立 BrowserWindow，不绑 parent
  
  ipcMain.handle('window:get-main-bounds', async () => {
    try {
      if (!mainWindow || mainWindow.isDestroyed()) return { ok: false }
      const b = mainWindow.getBounds()
      return { ok: true, bounds: b }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })

ipcMain.handle('window:open-float', async (_e, payload = {}) => {
    try {
      const { BrowserWindow, screen } = require('electron')
      const id = String(payload.id || 'float')
      const title = String(payload.title || 'PixShell')
      if (payload.init != null) floatInitData.set(id, payload.init)
      let width = Math.max(320, Math.min(1400, Number(payload.width) || 560))
      let height = Math.max(220, Math.min(1000, Number(payload.height) || 480))
      let x = payload.x != null ? Number(payload.x) : undefined
      let y = payload.y != null ? Number(payload.y) : undefined
      if ((x == null || y == null) && mainWindow && !mainWindow.isDestroyed()) {
        const b = mainWindow.getBounds()
        x = Math.round(b.x + (b.width - width) / 2)
        y = Math.round(b.y + Math.max(40, (b.height - height) / 3))
      }
      if (mainWindow && !mainWindow.isDestroyed() && x != null && y != null && payload.relativeToMain) {
        const b = mainWindow.getContentBounds ? mainWindow.getContentBounds() : mainWindow.getBounds()
        x = Math.round(b.x + x)
        y = Math.round(b.y + y)
      }
      if (x == null) x = 120
      if (y == null) y = 80
      try {
        const disp = screen.getDisplayNearestPoint({ x: Math.round(x || 0), y: Math.round(y || 0) })
        const wa = disp.workArea
        // 整窗必须落在 workArea 内，禁止 y=885 这类贴底只露一条边
        if (x == null || Number.isNaN(x)) x = wa.x + 40
        if (y == null || Number.isNaN(y)) y = wa.y + 40
        if (width > wa.width - 20) width = Math.max(320, wa.width - 20)
        if (height > wa.height - 20) height = Math.max(220, wa.height - 20)
        if (x + width > wa.x + wa.width) x = wa.x + wa.width - width
        if (y + height > wa.y + wa.height) y = wa.y + wa.height - height
        if (x < wa.x) x = wa.x
        if (y < wa.y) y = wa.y
      } catch (eClamp) {
        try { require('./logger').warn('float', 'clamp-fail', String(eClamp && eClamp.message || eClamp)) } catch (_) {}
      }
      const existing = floatWindows.get(id)
      if (existing && !existing.isDestroyed()) {
        existing.setTitle(title)
        existing.setSize(width, height)
        existing.setPosition(Math.round(x), Math.round(y))
        try {
          const bg = payload.backgroundColor || (payload.theme === 'light' ? '#ececf1' : '#1e1e2e')
          existing.setBackgroundColor(String(bg))
        } catch (_) {}
        existing.show()
        existing.focus()
        try {
          if (payload.init != null) {
            existing.webContents.send('float:message', { type: 'float-init', id, init: payload.init })
          }
          if (payload.theme) {
            existing.webContents.send('float:message', {
              type: 'theme',
              theme: payload.theme,
              backgroundColor: payload.backgroundColor,
            })
          }
        } catch (_) {}
        return { ok: true, id, reused: true }
      }
      const win = new BrowserWindow({
        width,
        height,
        x: Math.round(x),
        y: Math.round(y),
        minWidth: 320,
        minHeight: 220,
        show: false,
        title,
        backgroundColor: String(payload.backgroundColor || (payload.theme === 'light' ? '#ececf1' : '#1e1e2e')),
        ...(process.platform === 'darwin'
          ? {
              titleBarStyle: 'hiddenInset',
              trafficLightPosition: { x: 12, y: 12 },
            }
          : {
              frame: true,
              autoHideMenuBar: true,
              // Windows system caption; content matches app theme colors
            }),
        parent: undefined,
        modal: false,
        resizable: true,
        minimizable: true,
        maximizable: true,
        fullscreenable: false,
        alwaysOnTop: !!payload.alwaysOnTop,
        webPreferences: {
          preload: path.join(__dirname, 'preload.js'),
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: false,
          spellcheck: false,
          backgroundThrottling: false,
          offscreen: false,
          webgl: true,
        },
      })
      floatWindows.set(id, win)
      let shown = false
      const showOnce = () => {
        if (shown || win.isDestroyed()) return
        shown = true
        try {
          win.show()
          win.focus()
        } catch (_) {}
      }
      win._pixFloatShow = showOnce
      win.on('closed', () => {
        if (floatWindows.get(id) === win) floatWindows.delete(id)
        floatInitData.delete(id)
        try {
          if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.webContents.send('float:closed', { id })
          }
        } catch (_) {}
      })
      const kind = String(payload.kind || id)
      const q = new URLSearchParams({ float: '1', kind, id })
      q.set('v', String(Date.now()))
      const htmlPath = path.join(__dirname, '..', 'renderer', 'index.html')
      const { pathToFileURL } = require('url')
      try {
        const slog = require('./logger')
        slog.info('float', 'open', { id, kind, width, height, x, y, hasInit: payload.init != null })
      } catch (_) {}
      win.webContents.on('console-message', (_e, level, message, line, sourceId) => {
        try {
          const slog = require('./logger')
          const lv = level >= 2 ? 'error' : level === 1 ? 'warn' : 'info'
          slog[lv]('float-console', String(message || ''), { id, kind, line, sourceId })
        } catch (_) {}
      })
      win.webContents.on('did-fail-load', (_e, code, desc, url) => {
        try {
          require('./logger').error('float', 'did-fail-load', { id, kind, code, desc, url })
        } catch (_) {}
        showOnce()
      })
      win.webContents.once('did-finish-load', () => {
        // 内容加载完先露出窗口，避免一直黑屏等 float:ready
        setTimeout(showOnce, 120)
      })
      win.webContents.once('dom-ready', () => {
        setTimeout(showOnce, 400)
      })
      await win.loadURL(pathToFileURL(htmlPath).toString() + '?' + q.toString())
      // 兜底：最多 1.2s 必须 show（原 2.5s 太久且仍可能黑）
      setTimeout(showOnce, 1200)
      return { ok: true, id, reused: false }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })

  // 浮窗 renderer 画完 UI 后通知，再 show（避免空壳黑屏）
  ipcMain.handle('float:ready', async (e, payload = {}) => {
    try {
      const id = String((payload && payload.id) || '')
      try {
        require('./logger').info('float', 'ready', {
          id,
          kind: payload && payload.kind,
          hosts: payload && payload.hosts,
          paintOk: payload && payload.paintOk,
          err: payload && payload.err,
        })
      } catch (_) {}
      let win = id ? floatWindows.get(id) : null
      if (!win || win.isDestroyed()) {
        for (const [fid, w] of floatWindows.entries()) {
          if (w && !w.isDestroyed() && w.webContents === e.sender) {
            win = w
            break
          }
        }
      }
      if (win && !win.isDestroyed()) {
        try {
          if (payload && payload.backgroundColor) {
            win.setBackgroundColor(String(payload.backgroundColor || (payload.theme === 'light' ? '#ececf1' : '#1e1e2e')))
          }
        } catch (_) {}
        if (typeof win._pixFloatShow === 'function') win._pixFloatShow()
        else {
          win.show()
          win.focus()
        }
        // 强制提到前台，避免黑窗藏在后面
        try {
          if (process.platform === 'darwin') win.moveTop()
        } catch (_) {}
      }
      return { ok: true }
    } catch (err) {
      try {
        require('./logger').error('float', 'ready-handler', String(err && err.message || err))
      } catch (_) {}
      return { ok: false, error: String(err && err.message || err) }
    }
  })

  ipcMain.handle('window:get-float-init', async (_e, payload = {}) => {
    const id = String(payload.id || '')
    const init = floatInitData.has(id) ? floatInitData.get(id) : null
    // 取一次即清，避免泄漏大文本；也可重复取：保留到 close
    return { ok: true, id, init }
  })

  ipcMain.handle('window:close-float', async (_e, payload = {}) => {
    const id = String(payload.id || '')
    const win = floatWindows.get(id)
    if (win && !win.isDestroyed()) win.close()
    floatWindows.delete(id)
    floatInitData.delete(id)
    return { ok: true }
  })

  ipcMain.handle('window:focus-float', async (_e, payload = {}) => {
    const id = String(payload.id || '')
    const win = floatWindows.get(id)
    if (win && !win.isDestroyed()) {
      win.show()
      win.focus()
      return { ok: true }
    }
    return { ok: false }
  })

  ipcMain.handle('window:float-bounds', async (_e, payload = {}) => {
    const id = String(payload.id || '')
    const win = floatWindows.get(id)
    if (!win || win.isDestroyed()) return { ok: false }
    if (payload.bounds) {
      const b = payload.bounds
      win.setBounds({
        x: Math.round(b.x),
        y: Math.round(b.y),
        width: Math.round(b.width),
        height: Math.round(b.height),
      })
    }
    return { ok: true, bounds: win.getBounds() }
  })

  // 浮窗 → 主窗 消息（例如连接请求）
  ipcMain.handle('float:to-main', async (_e, payload = {}) => {
    try {
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('float:message', payload || {})
        // 连接类操作尽量聚焦主窗
        if (payload && (payload.type === 'connect' || payload.type === 'focus-main')) {
          if (mainWindow.isMinimized()) mainWindow.restore()
          mainWindow.show()
          mainWindow.focus()
        }
      }
      return { ok: true }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })

  ipcMain.handle('float:to-float', async (_e, payload = {}) => {
    try {
      const id = String((payload && payload.id) || '')
      const win = floatWindows.get(id)
      if (win && !win.isDestroyed()) {
        win.webContents.send('float:message', payload || {})
        return { ok: true }
      }
      return { ok: false, error: 'float not found' }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })


  // health
  ipcMain.handle('ssh:ready', async () => engine.ready())

  // session
  ipcMain.handle('ssh:connect', async (_e, payload) => {
    try {
      const r = await engine.connect(payload || {})
      // Normalize IPC shape for renderer: always {ok, sessionId?, error?}
      if (!r || typeof r !== 'object') {
        return { ok: false, error: 'connect 无返回值' }
      }
      if (r.ok) {
        return {
          ok: true,
          sessionId: r.sessionId,
          host: r.host,
          port: r.port,
          username: r.username,
        }
      }
      return {
        ok: false,
        sessionId: r.sessionId || null,
        error: r.error || '连接失败',
      }
    } catch (e) {
      return { ok: false, error: e.message || String(e) }
    }
  })
  ipcMain.handle('ssh:disconnect', async (_e, { sessionId } = {}) => engine.disconnect(sessionId))
  ipcMain.handle('ssh:reconnect', async (_e, { sessionId } = {}) => engine.reconnect(sessionId))
  ipcMain.handle('ssh:write', async (_e, { sessionId, data } = {}) => engine.write(sessionId, data))
  ipcMain.handle('ssh:write-binary', async (_e, { sessionId, dataBase64 } = {}) =>
    engine.writeBinary(sessionId, String(dataBase64 || '')),
  )
  ipcMain.handle('ssh:resize', async (_e, { sessionId, cols, rows } = {}) =>
    engine.resize(sessionId, cols, rows),
  )
  ipcMain.handle('ssh:exec', async (_e, { sessionId, command } = {}) => engine.exec(sessionId, command))
  ipcMain.handle('ssh:set-auto-reconnect', async (_e, { enabled } = {}) =>
    engine.setAutoReconnect(enabled),
  )

  // sftp
  ipcMain.handle('ssh:sftp-list', async (_e, { sessionId, remotePath } = {}) =>
    engine.sftpList(sessionId, remotePath),
  )
  ipcMain.handle('ssh:sftp-read', async (_e, { sessionId, remotePath } = {}) =>
    engine.sftpRead(sessionId, remotePath),
  )
  ipcMain.handle('ssh:sftp-write', async (_e, { sessionId, remotePath, dataBase64 } = {}) =>
    engine.sftpWrite(sessionId, remotePath, Buffer.from(String(dataBase64 || ''), 'base64')),
  )
  ipcMain.handle('ssh:sftp-mkdir', async (_e, { sessionId, remotePath } = {}) =>
    engine.sftpMkdir(sessionId, remotePath),
  )
  ipcMain.handle('ssh:sftp-unlink', async (_e, { sessionId, remotePath, isDir } = {}) =>
    engine.sftpUnlink(sessionId, remotePath, isDir),
  )
  ipcMain.handle('ssh:sftp-rename', async (_e, { sessionId, from, to } = {}) =>
    engine.sftpRename(sessionId, from, to),
  )
  async function downloadSmart(sessionId, remotePaths, destDir) {
    const list = (remotePaths || []).filter(Boolean).map(String)
    if (!list.length) return { ok: false, error: '无路径' }
    const wantPack = list.length > 1 || (await shouldPackRemote(sessionId, list))
    if (!wantPack && list.length === 1) {
      let lp
      if (destDir) {
        lp = path.join(destDir, path.basename(list[0]))
      } else {
        const r = await dialog.showSaveDialog(mainWindow, { defaultPath: path.basename(list[0]) })
        if (r.canceled || !r.filePath) return { ok: false, error: 'cancelled' }
        lp = r.filePath
      }
      try { lp = assertUserWritablePath(lp) } catch (e) { return { ok: false, error: e.message } }
      return engine.sftpDownloadFile(sessionId, list[0], lp)
    }
    let outDir = destDir
    if (!outDir) {
      const r = await dialog.showOpenDialog(mainWindow, {
        properties: ['openDirectory', 'createDirectory'],
        title: '选择下载解压目录',
      })
      if (r.canceled || !r.filePaths?.[0]) return { ok: false, error: 'cancelled' }
      outDir = r.filePaths[0]
    }
    try { outDir = assertUserWritablePath(outDir) } catch (e) { return { ok: false, error: e.message } }

    const stamp = Date.now()
    const remoteArchive = `/tmp/pixshell_dl_${stamp}.tar.gz`
    const localArchive = path.join(os.tmpdir(), `pixshell_dl_${stamp}.tar.gz`)
    // 逐项 -C parent basename，避免绝对路径进包；目录也会被递归打入
    const tarParts = list
      .map((rp) => {
        const norm = String(rp).replace(/\/+$/, '') || '/'
        const base = path.posix.basename(norm) || norm
        let parent = path.posix.dirname(norm)
        if (!parent || parent === '.') parent = '/'
        return `-C ${shellQuote(parent)} ${shellQuote(base)}`
      })
      .join(' ')
    const packCmd = `tar -czf ${shellQuote(remoteArchive)} ${tarParts} 2>&1`
    const pr = await engine.exec(sessionId, packCmd)
    // exec.ok is now false when exit code !== 0
    if (!pr || !pr.ok) {
      try { await engine.exec(sessionId, `rm -f ${shellQuote(remoteArchive)}`) } catch (_) {}
      return {
        ok: false,
        error:
          '远端打包失败: ' +
          (pr?.error || pr?.stderr || pr?.stdout || ('exit ' + (pr?.code ?? '?'))) ,
      }
    }
    const dl = await engine.sftpDownloadFile(sessionId, remoteArchive, localArchive)
    try { await engine.exec(sessionId, `rm -f ${shellQuote(remoteArchive)}`) } catch (_) {}
    if (!dl?.ok) {
      try { fs.unlinkSync(localArchive) } catch (_) {}
      return { ok: false, error: dl?.error || '下载压缩包失败' }
    }
    const ex = await runLocal('tar', ['-xzf', localArchive, '-C', outDir])
    try { fs.unlinkSync(localArchive) } catch (_) {}
    if (!ex.ok) return { ok: false, error: '解压失败: ' + (ex.error || ex.stderr || ''), packed: true }
    return { ok: true, packed: true, localPath: outDir, count: list.length }
  }

  ipcMain.handle('ssh:sftp-download', async (_e, { sessionId, remotePath, localPath } = {}) => {
    const paths = Array.isArray(remotePath) ? remotePath : [remotePath]
    if (paths.length !== 1 || (await shouldPackRemote(sessionId, paths))) {
      const destDir = localPath ? path.dirname(localPath) : null
      return downloadSmart(sessionId, paths, destDir)
    }
    let lp = localPath
    if (!lp) {
      const name = path.basename(remotePath || 'download')
      const r = await dialog.showSaveDialog(mainWindow, { defaultPath: name })
      if (r.canceled || !r.filePath) return { ok: false, error: 'cancelled' }
      lp = r.filePath
    } else {
      try {
        lp = assertUserWritablePath(lp)
      } catch (e) {
        return { ok: false, error: e.message || String(e) }
      }
    }
    return engine.sftpDownloadFile(sessionId, remotePath, lp)
  })

  ipcMain.handle('ssh:sftp-download-smart', async (_e, { sessionId, remotePaths } = {}) => {
    const list = Array.isArray(remotePaths) ? remotePaths : remotePaths ? [remotePaths] : []
    return downloadSmart(sessionId, list, null)
  })

  ipcMain.handle('ssh:sftp-upload', async (_e, { sessionId, remoteDir, localPath, opts } = {}) => {
    let paths = localPath ? (Array.isArray(localPath) ? localPath : [localPath]) : null
    if (!paths) {
      const r = await dialog.showOpenDialog(mainWindow, {
        properties: ['openFile', 'openDirectory', 'multiSelections'],
      })
      if (r.canceled || !r.filePaths?.length) return { ok: false, error: 'cancelled' }
      paths = r.filePaths
    } else {
      try {
        paths = paths.map((x) => assertUserReadablePath(x))
      } catch (e) {
        return { ok: false, error: e.message || String(e) }
      }
    }
    const dir = (remoteDir || '.').replace(/\/+$/, '') || '.'
    const autoPack = !opts || opts.autoPack !== false
    const needPack = autoPack && (await shouldPackLocal(paths))
    if (!needPack) {
      const results = []
      for (const lp of paths) {
        const name = path.basename(lp)
        const remote = dir === '.' ? name : dir + '/' + name
        results.push(await engine.sftpUploadFile(sessionId, lp, remote))
      }
      const failed = results.find((x) => !x.ok)
      return failed || { ok: true, results, packed: false }
    }
    const stamp = Date.now()
    const localArchive = path.join(os.tmpdir(), `pixshell_ul_${stamp}.tar.gz`)
    const remoteArchive = (dir === '.' ? '' : dir + '/') + `pixshell_ul_${stamp}.tar.gz`
    const args = ['-czf', localArchive]
    for (const lp of paths) {
      args.push('-C', path.dirname(lp), path.basename(lp))
    }
    const pack = await runLocal('tar', args)
    if (!pack.ok) {
      try { fs.unlinkSync(localArchive) } catch (_) {}
      return { ok: false, error: '本地打包失败: ' + (pack.error || pack.stderr || '') }
    }
    const up = await engine.sftpUploadFile(sessionId, localArchive, remoteArchive)
    try { fs.unlinkSync(localArchive) } catch (_) {}
    if (!up?.ok) return { ok: false, error: up?.error || '上传压缩包失败' }
    const extractDir = dir === '.' ? '.' : dir
    // 先 tar 再 rm：禁止 `tar; rm` 用分号把 tar 非零退出码冲掉
    const ex = await engine.exec(
      sessionId,
      `tar -xzf ${shellQuote(remoteArchive)} -C ${shellQuote(extractDir)} 2>&1`,
    )
    try {
      await engine.exec(sessionId, `rm -f ${shellQuote(remoteArchive)}`)
    } catch (_) {}
    // exec.ok is now false when exit code !== 0
    if (!ex || !ex.ok) {
      return {
        ok: false,
        error:
          '远端解压失败: ' +
          (ex?.error || ex?.stderr || ex?.stdout || ('exit ' + (ex?.code ?? '?'))) ,
        packed: true,
      }
    }
    return { ok: true, packed: true, count: paths.length }
  })

  // structured collect
  ipcMain.handle('ssh:monitor', async (_e, { sessionId } = {}) => engine.collectMonitor(sessionId))
  ipcMain.handle('ssh:processes', async (_e, { sessionId } = {}) => engine.collectProcesses(sessionId))
  ipcMain.handle('ssh:network', async (_e, { sessionId } = {}) => engine.collectNetwork(sessionId))
  ipcMain.handle('ssh:sysinfo', async (_e, { sessionId } = {}) => engine.collectSysInfo(sessionId))

  // pack remote
  ipcMain.handle('ssh:pack', async (_e, { sessionId, paths, format } = {}) => {
    const list = (paths || []).map((p) => `'${String(p).replace(/'/g, `'\\''`)}'`).join(' ')
    if (!list) return { ok: false, error: '无路径' }
    const out =
      format === 'zip'
        ? `pack_${Date.now()}.zip`
        : `pack_${Date.now()}.tar.gz`
    const cmd =
      format === 'zip'
        ? `zip -r ${out} ${list} 2>&1`
        : `tar -czvf ${out} ${list} 2>&1`
    const r = await engine.exec(sessionId, cmd)
    return { ...r, out }
  })

  // hosts / settings / quick
  ipcMain.handle('hosts:load', async () => engine.loadHosts())
  ipcMain.handle('hosts:save', async (_e, hosts) => engine.saveHosts(hosts))
  ipcMain.handle('settings:load', async () => engine.loadSettings())
  ipcMain.handle('settings:save', async (_e, settings) => engine.saveSettings(settings))
  ipcMain.handle('quick:load', async () => engine.loadQuick())
  ipcMain.handle('quick:save', async (_e, list) => engine.saveQuick(list))

  ipcMain.handle('hosts:import-hosts', async (_e, connDir) => {
    try {
      const { importHostsDir } = require('../../../scripts/import-hosts.js')
      // Prefer explicit path; else discover local */conn trees.
      let dir = connDir || process.env.PIXSHELL_IMPORT_CONN_DIR || ''
      if (!dir) {
        try {
          const lib = path.join(os.homedir(), 'Library')
          for (const name of fs.readdirSync(lib)) {
            const c = path.join(lib, name, 'conn')
            if (!fs.existsSync(c)) continue
            const names = fs.readdirSync(c)
            if (names.some((n) => String(n).endsWith('_connect_config.json') || fs.existsSync(path.join(c, n, 'folder.json')))) {
              dir = c
              break
            }
          }
        } catch (_) {}
      }
      if (!dir) return { ok: false, error: '未指定连接树目录（传 connDir 或设 PIXSHELL_IMPORT_CONN_DIR）' }
      const hosts = importHostsDir(dir)
      const existing = engine.loadHosts()
      const map = new Map(existing.map((h) => [h.id || h.host + h.port + h.username, h]))
      for (const h of hosts || []) {
        const key = h.id || h.host + h.port + h.username
        map.set(key, { ...map.get(key), ...h })
      }
      const merged = [...map.values()]
      engine.saveHosts(merged)
      return { ok: true, count: (hosts || []).length, total: merged.length, dir }
    } catch (e) {
      return { ok: false, error: e.message }
    }
  })

  ipcMain.handle('quick:import', async (_e, configPath) => {
    try {
      const { importFromConfig } = require('../../../scripts/import-quick.js')
      let p = configPath || process.env.PIXSHELL_IMPORT_CONFIG_JSON || ''
      if (!p) {
        try {
          const lib = path.join(os.homedir(), 'Library')
          for (const name of fs.readdirSync(lib)) {
            const c = path.join(lib, name, 'config.json')
            if (fs.existsSync(c)) {
              p = c
              break
            }
          }
        } catch (_) {}
      }
      if (!p) return { ok: false, error: '未指定 config 路径（传 configPath 或设 PIXSHELL_IMPORT_CONFIG_JSON）' }
      const list = importFromConfig(p)
      engine.saveQuick(list || [])
      return { ok: true, count: (list || []).length, list, path: p }
    } catch (e) {
      return { ok: false, error: e.message }
    }
  })

  // dialogs / fs
  ipcMain.handle('dialog:open-file', async () => {
    const r = await dialog.showOpenDialog(mainWindow, { properties: ['openFile', 'multiSelections'] })
    return { ok: !r.canceled, paths: r.filePaths || [] }
  })
  ipcMain.handle('dialog:open-key', async () => {
    const r = await dialog.showOpenDialog(mainWindow, {
      properties: ['openFile'],
      title: '选择 SSH 私钥',
      filters: [
        { name: '私钥 / 密钥', extensions: ['pem', 'key', 'ppk', 'rsa', 'ed25519'] },
        { name: '所有文件', extensions: ['*'] },
      ],
    })
    return { ok: !r.canceled, path: (r.filePaths && r.filePaths[0]) || '', paths: r.filePaths || [] }
  })
  ipcMain.handle('dialog:open-directory', async () => {
    const r = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory', 'createDirectory'],
    })
    return { ok: !r.canceled, path: (r.filePaths && r.filePaths[0]) || '' }
  })
  ipcMain.handle('shell:open-path', async (_e, targetPath) => {
    try {
      if (!targetPath) return { ok: false, error: 'empty path' }
      const err = await shell.openPath(String(targetPath))
      return err ? { ok: false, error: err } : { ok: true }
    } catch (e) {
      return { ok: false, error: e.message || String(e) }
    }
  })
  ipcMain.handle('dialog:save-file', async (_e, { defaultPath } = {}) => {
    const r = await dialog.showSaveDialog(mainWindow, { defaultPath })
    return { ok: !r.canceled, path: r.filePath }
  })
  ipcMain.handle('fs:write-text', async (_e, { filePath, text } = {}) => {
    let p = filePath
    if (!p) {
      const r = await dialog.showSaveDialog(mainWindow, { defaultPath: 'export.json' })
      if (r.canceled || !r.filePath) return { ok: false, error: 'cancelled' }
      p = r.filePath
    } else {
      try {
        p = assertUserWritablePath(p)
      } catch (e) {
        return { ok: false, error: e.message || String(e) }
      }
    }
    fs.writeFileSync(p, text ?? '', 'utf8')
    return { ok: true, path: p }
  })
  ipcMain.handle('fs:read-text', async (_e, filePath) => {
    let p = filePath
    if (!p) {
      const r = await dialog.showOpenDialog(mainWindow, { properties: ['openFile'] })
      if (r.canceled || !r.filePaths?.[0]) return { ok: false, error: 'cancelled' }
      p = r.filePaths[0]
    } else {
      try {
        p = assertUserReadablePath(p)
      } catch (e) {
        return { ok: false, error: e.message || String(e) }
      }
    }
    return { ok: true, path: p, text: fs.readFileSync(p, 'utf8') }
  })
  ipcMain.handle('shell:open-external', async (_e, url) => {
    try {
      const u = String(url || '')
      let parsed
      try {
        parsed = new URL(u)
      } catch {
        return { ok: false, error: 'invalid url' }
      }
      const okProto = ['http:', 'https:', 'mailto:'].includes(parsed.protocol)
      if (!okProto) return { ok: false, error: 'protocol not allowed: ' + parsed.protocol }
      await shell.openExternal(u)
      return { ok: true }
    } catch (e) {
      return { ok: false, error: e.message }
    }
  })


  // ── Cloud backup one-click login / OAuth ─────────────────
  ipcMain.handle('backup:list-oneclick', async () => {
    try {
      return { ok: true, providers: cloudOAuth.listOneClickProviders() }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e), providers: [] }
    }
  })
  ipcMain.handle('backup:open-login', async (_e, payload = {}) => {
    try {
      const id = String(payload.providerId || payload.id || '')
      const info = cloudOAuth.getProviderLogin(id)
      if (!info) return { ok: false, error: 'unknown provider' }
      const url = String(payload.url || info.loginUrl || '')
      if (!url) return { ok: false, error: 'no login url' }
      await shell.openExternal(url)
      return { ok: true, providerId: id, opened: url, hint: info.hint, authStyle: info.authStyle }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })
  ipcMain.handle('backup:github-device-start', async () => {
    try {
      const r = await cloudOAuth.startGitHubDeviceFlow()
      if (r && r.ok && r.verificationUri) {
        try {
          await shell.openExternal(r.verificationUri)
        } catch (_) {}
      }
      return r
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })
  ipcMain.handle('backup:github-device-poll', async (_e, payload = {}) => {
    try {
      return await cloudOAuth.pollGitHubDeviceToken(payload.deviceCode, payload.clientId)
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })
  ipcMain.handle('backup:apply-oauth', async (_e, payload = {}) => {
    try {
      const settings = engine.loadSettings() || {}
      const next = cloudOAuth.applyOAuthToBackupConfig(
        settings.backup,
        payload.providerId || 'github',
        { accessToken: payload.accessToken, filename: payload.filename },
      )
      settings.backup = next
      engine.saveSettings(settings)
      return { ok: true, backup: next }
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) }
    }
  })


  // Terminal color schemes (full palette for xterm)
  let termSchemes = null
  function loadTermSchemes() {
    if (termSchemes) return termSchemes
    const candidates = [
      path.join(__dirname, '../../terminal/src/schemes.js'),
      path.join(app.getAppPath(), 'packages/terminal/src/schemes.js'),
      path.join(process.cwd(), 'packages/terminal/src/schemes.js'),
    ]
    for (const p of candidates) {
      try {
        if (fs.existsSync(p)) {
          termSchemes = require(p)
          break
        }
      } catch (_) {}
    }
    if (!termSchemes) {
      termSchemes = {
        listSchemes: () => [
          { id: 'dracula', name: 'Dracula' },
          { id: 'pix-dark', name: 'Pix Dark' },
          { id: 'nord', name: 'Nord' },
        ],
        getScheme: (id) => ({
          id: id || 'dracula',
          name: 'Dracula',
          background: '#1e1f29',
          foreground: '#f8f8f2',
          cursor: '#bbbbbb',
          selectionBackground: '#44475a',
          black: '#000000',
          red: '#ff5555',
          green: '#50fa7b',
          yellow: '#f1fa8c',
          blue: '#bd93f9',
          magenta: '#ff79c6',
          cyan: '#8be9fd',
          white: '#bbbbbb',
          brightBlack: '#555555',
          brightRed: '#ff5555',
          brightGreen: '#50fa7b',
          brightYellow: '#f1fa8c',
          brightBlue: '#bd93f9',
          brightMagenta: '#ff79c6',
          brightCyan: '#8be9fd',
          brightWhite: '#ffffff',
        }),
        toXtermTheme: (s) => {
          const sch = typeof s === 'string' ? termSchemes.getScheme(s) : s
          return { ...sch, cursorAccent: sch.background }
        },
      }
    }
    return termSchemes
  }
  ipcMain.handle('schemes:list', async () => {
    const mod = loadTermSchemes()
    return { ok: true, schemes: mod.listSchemes() }
  })
  ipcMain.handle('schemes:get', async (_e, id) => {
    const mod = loadTermSchemes()
    const scheme = mod.getScheme(id)
    return {
      ok: true,
      scheme: { id: id || scheme?.name, ...scheme },
      xterm: mod.toXtermTheme(scheme),
    }
  })

  ipcMain.handle('rdp:launch', async (_e, payload = {}) => {
    try {
      const host = payload.host || '127.0.0.1'
      const port = payload.port || 3389
      if (process.platform === 'darwin') {
        await shell.openExternal(`rdp://full%20address=s:${host}:${port}`)
      } else if (process.platform === 'win32') {
        require('child_process').spawn('mstsc', [`/v:${host}:${port}`], { detached: true })
      } else {
        require('child_process').spawn('xfreerdp', [`/v:${host}:${port}`], { detached: true })
      }
      return { ok: true }
    } catch (e) {
      return { ok: false, error: e.message }
    }
  })

  // kill process via exec
  ipcMain.handle('ssh:kill', async (_e, { sessionId, pid, signal } = {}) => {
    const ALLOWED = new Set(['TERM', 'KILL', 'HUP', 'INT', 'QUIT', 'USR1', 'USR2', 'STOP', 'CONT'])
    const sig = String(signal || 'TERM')
      .toUpperCase()
      .replace(/^SIG/, '')
    if (!ALLOWED.has(sig)) return { ok: false, error: 'invalid signal' }
    const n = Number(pid)
    if (!Number.isInteger(n) || n <= 0) return { ok: false, error: 'invalid pid' }
    return engine.exec(sessionId, `kill -${sig} ${n} 2>&1`)
  })

  // ── External CLI / AI-Agent bridge ─────────────────────
  ipcMain.handle('cli:status', async () => agentBridge.status())
  ipcMain.handle('cli:set-enabled', async (_e, { enabled, port } = {}) => {
    try {
      const settings = engine.loadSettings() || {}
      settings.externalCliEnabled = !!enabled
      if (port != null && Number(port) > 0) settings.externalCliPort = Number(port)
      engine.saveSettings(settings)
      if (enabled) {
        const r = await agentBridge.start(settings.externalCliPort || port)
        return { ok: true, ...agentBridge.status(), ...r }
      }
      await agentBridge.stop()
      return { ok: true, ...agentBridge.status() }
    } catch (e) {
      return { ok: false, error: e.message || String(e), ...agentBridge.status() }
    }
  })
  ipcMain.handle('cli:rotate-token', async () => {
    const t = agentBridge.rotateToken()
    return { ok: true, tokenPath: agentBridge.tokenPath(), rotated: !!t }
  })
  ipcMain.handle('cli:install-skills', async () => {
    try {
      return installAgentSkills()
    } catch (e) {
      return { ok: false, error: e.message || String(e) }
    }
  })
  ipcMain.handle('cli:token-path', async () => ({
    ok: true,
    path: agentBridge.tokenPath(),
  }))
}

/**
 * Install pixshell-ops skill into common agent skill dirs (Claude / Codex / OpenCode).
 * Does not overwrite user-customized SKILL.md if content hash differs and user set skip.
 */
function installAgentSkills() {
  const src = path.join(__dirname, '..', '..', 'cli', 'skills', 'pixshell-ops', 'SKILL.md')
  if (!fs.existsSync(src)) {
    return { ok: false, error: 'skill source missing: ' + src, installed: [] }
  }
  const text = fs.readFileSync(src, 'utf8')
  const home = require('os').homedir()
  const targets = [
    path.join(home, '.claude', 'skills', 'pixshell-ops', 'SKILL.md'),
    path.join(home, '.codex', 'skills', 'pixshell-ops', 'SKILL.md'),
    path.join(home, '.config', 'opencode', 'skills', 'pixshell-ops', 'SKILL.md'),
  ]
  const installed = []
  const errors = []
  const skipped = []
  for (const dest of targets) {
    try {
      fs.mkdirSync(path.dirname(dest), { recursive: true })
      if (fs.existsSync(dest)) {
        const prev = fs.readFileSync(dest, 'utf8')
        if (prev === text) {
          installed.push(dest)
          continue
        }
        // User customized SKILL.md — do not clobber.
        skipped.push(dest)
        continue
      }
      fs.writeFileSync(dest, text, 'utf8')
      installed.push(dest)
    } catch (e) {
      errors.push({ path: dest, error: e.message })
    }
  }
  // also copy CLI launcher hint into user bin if writable
  let cliNote = null
  try {
    const cliSrc = path.join(__dirname, '..', '..', 'cli', 'pixshell-cli.js')
    const binDir =
      process.platform === 'win32'
        ? path.join(home, 'AppData', 'Local', 'PixShell')
        : path.join(home, '.local', 'bin')
    fs.mkdirSync(binDir, { recursive: true })
    const destCli = path.join(binDir, process.platform === 'win32' ? 'pixshell-cli.js' : 'pixshell-cli')
    if (process.platform === 'win32') {
      fs.copyFileSync(cliSrc, destCli)
      const cmd = path.join(binDir, 'pixshell-cli.cmd')
      fs.writeFileSync(cmd, `@echo off\r\nnode "%~dp0pixshell-cli.js" %*\r\n`, 'utf8')
      cliNote = cmd
    } else {
      // wrapper script so PATH entry stays stable across source moves
      const wrapper =
        '#!/bin/sh\n' +
        'exec node ' +
        JSON.stringify(cliSrc) +
        ' "$@"\n'
      fs.writeFileSync(destCli, wrapper, { encoding: 'utf8', mode: 0o755 })
      try {
        fs.chmodSync(destCli, 0o755)
      } catch (_) {}
      cliNote = destCli
    }
  } catch (e) {
    errors.push({ path: 'cli-wrapper', error: e.message })
  }
  return {
    ok: errors.length === 0 || installed.length > 0 || (typeof skipped !== 'undefined' && skipped.length > 0),
    installed,
    skipped: typeof skipped !== 'undefined' && skipped.length ? skipped : undefined,
    cliPath: cliNote,
    errors: errors.length ? errors : undefined,
  }
}

app.whenReady().then(async () => {
  try {
    const userData = app.getPath('userData')
    // Dev source tree (NTFS) preferred; runtime copy lives under userData/app
    let repoRoot = '/Volumes/d/pixshell'
    if (!fs.existsSync(path.join(repoRoot, 'packages', 'app', 'main'))) {
      repoRoot = path.resolve(__dirname, '../../../..')
    }
    log.init({ repoRoot, userData })
    log.installConsoleMirror()
    log.installProcessHandlers()
    log.info('main', 'app ready', { userData, repoRoot, pid: process.pid })
  } catch (e) {
    console.warn('[PixShell] logger init failed', e && e.message)
  }
  registerIpc()
  createWindow()
  // External CLI: opt-in only (default false). User enables in 设置.
  try {
    const settings = engine.loadSettings() || {}
    const enabled = settings.externalCliEnabled === true
    if (enabled) {
      const port = Number(settings.externalCliPort) || undefined
      await agentBridge.start(port)
    } else if (settings.externalCliEnabled == null) {
      settings.externalCliEnabled = false
      try {
        engine.saveSettings(settings)
      } catch (_) {}
    }
  } catch (e) {
    console.warn('[PixShell agent-bridge] auto-start failed:', e && e.message)
  }
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  // macOS: keep SSH sessions + CLI bridge alive while dock icon remains
  // (window can be re-created via activate). Tear down only on before-quit.
  if (process.platform === 'darwin') return
  try {
    agentBridge.stop()
  } catch (_) {}
  engine.closeAll()
  app.quit()
})

app.on('will-quit', () => {
  for (const w of [...floatWindows.values()]) {
    try { if (w && !w.isDestroyed()) w.destroy() } catch (_) {}
  }
  floatWindows.clear()
})

app.on('before-quit', () => {
  try {
    agentBridge.stop()
  } catch (_) {}
  try {
    engine.closeAll()
  } catch (_) {}
})
