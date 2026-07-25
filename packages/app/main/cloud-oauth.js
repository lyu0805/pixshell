/**
 * Cloud backup OAuth / device-code helpers (unit-testable).
 * Browser login for GitHub; WebDAV uses vendor portal open + saved session fields.
 */

const https = require('https')
const http = require('http')
const { URL } = require('url')

const GITHUB_CLIENT_ID = process.env.PIXSHELL_GITHUB_CLIENT_ID || 'Iv1.b507a08c87ecfe98'
// Note: public OAuth App id placeholder — production builds should set PIXSHELL_GITHUB_CLIENT_ID.
// Device flow works with registered OAuth Apps that enable device flow.

function buildGitHubDeviceCodeUrl() {
  return 'https://github.com/login/device'
}

function buildGitHubAuthorizeHint(userCode) {
  return {
    verificationUri: 'https://github.com/login/device',
    userCode: String(userCode || ''),
    instruction: '在浏览器打开验证页，输入设备码完成登录',
  }
}

/** Provider → browser login portal (one-click open; token may still be pasted after browser session if API limited) */
const PROVIDER_LOGIN = {
  github: {
    name: 'GitHub',
    loginUrl: 'https://github.com/login',
    authStyle: 'device_or_browser',
    hint: '一键打开 GitHub 登录；推荐 Device Flow 自动拿 Token，无需手填路径',
  },
  google: {
    name: 'Google Drive',
    loginUrl: 'https://accounts.google.com/ServiceLogin?service=wise',
    authStyle: 'browser',
    hint: '一键打开 Google 登录页，登录后在应用内完成网盘授权',
  },
  microsoft: {
    name: 'OneDrive',
    loginUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
    authStyle: 'browser',
    hint: '一键打开 Microsoft 登录',
  },
  baidu: {
    name: '百度网盘',
    loginUrl: 'https://pan.baidu.com/',
    authStyle: 'browser',
    hint: '一键打开百度网盘登录页',
  },
  quark: {
    name: '夸克网盘',
    loginUrl: 'https://pan.quark.cn/',
    authStyle: 'browser',
    hint: '一键打开夸克网盘登录页',
  },
  webdav: {
    name: 'WebDAV',
    loginUrl: 'https://www.jianguoyun.com/d/login',
    authStyle: 'browser_vendor',
    hint: '一键打开坚果云等 WebDAV 服务商登录页；登录后可用应用密码自动填入',
  },
}

function getProviderLogin(providerId) {
  const id = String(providerId || '').toLowerCase()
  return PROVIDER_LOGIN[id] || null
}

function listOneClickProviders() {
  return Object.entries(PROVIDER_LOGIN).map(([id, v]) => ({
    id,
    name: v.name,
    loginUrl: v.loginUrl,
    authStyle: v.authStyle,
    hint: v.hint,
    oneClick: true,
  }))
}

/**
 * Start GitHub device code flow (POST oauth/device/code).
 * Returns user_code + verification_uri + device_code for polling.
 */
function parseDeviceCodeResponse(body) {
  // application/x-www-form-urlencoded or JSON
  let data = {}
  const text = String(body || '').trim()
  if (text.startsWith('{')) {
    try {
      data = JSON.parse(text)
    } catch (_) {
      data = {}
    }
  } else {
    for (const part of text.split('&')) {
      const [k, v] = part.split('=')
      if (k) data[decodeURIComponent(k)] = decodeURIComponent(v || '')
    }
  }
  if (!data.device_code && !data.user_code) {
    return { ok: false, error: data.error_description || data.error || 'device code failed', raw: data }
  }
  return {
    ok: true,
    deviceCode: data.device_code,
    userCode: data.user_code,
    verificationUri: data.verification_uri || data.verification_uri_complete || 'https://github.com/login/device',
    expiresIn: Number(data.expires_in) || 900,
    interval: Number(data.interval) || 5,
  }
}

function parseAccessTokenResponse(body) {
  let data = {}
  const text = String(body || '').trim()
  if (text.startsWith('{')) {
    try {
      data = JSON.parse(text)
    } catch (_) {
      data = {}
    }
  } else {
    for (const part of text.split('&')) {
      const [k, v] = part.split('=')
      if (k) data[decodeURIComponent(k)] = decodeURIComponent(v || '')
    }
  }
  if (data.access_token) {
    return {
      ok: true,
      accessToken: data.access_token,
      tokenType: data.token_type || 'bearer',
      scope: data.scope || '',
    }
  }
  if (data.error === 'authorization_pending') {
    return { ok: false, pending: true, error: 'authorization_pending' }
  }
  if (data.error === 'slow_down') {
    return { ok: false, pending: true, slowDown: true, error: 'slow_down' }
  }
  return { ok: false, error: data.error_description || data.error || 'token failed', raw: data }
}

function httpPostForm(urlStr, formObj, headers = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr)
    const body = new URLSearchParams(formObj).toString()
    const lib = u.protocol === 'http:' ? http : https
    const req = lib.request(
      {
        hostname: u.hostname,
        path: u.pathname + u.search,
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Accept: 'application/json',
          'User-Agent': 'PixShell-Backup',
          'Content-Length': Buffer.byteLength(body),
          ...headers,
        },
      },
      (res) => {
        const chunks = []
        res.on('data', (c) => chunks.push(c))
        res.on('end', () => {
          resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') })
        })
      },
    )
    req.on('error', reject)
    req.write(body)
    req.end()
  })
}

async function startGitHubDeviceFlow(clientId) {
  const id = clientId || GITHUB_CLIENT_ID
  try {
    const r = await httpPostForm('https://github.com/login/device/code', {
      client_id: id,
      scope: 'gist',
    })
    const parsed = parseDeviceCodeResponse(r.body)
    if (!parsed.ok) return { ...parsed, clientId: id }
    return { ...parsed, clientId: id, loginUrl: parsed.verificationUri }
  } catch (e) {
    return { ok: false, error: e.message || String(e), clientId: id }
  }
}

async function pollGitHubDeviceToken(deviceCode, clientId, opts = {}) {
  const id = clientId || GITHUB_CLIENT_ID
  try {
    const r = await httpPostForm('https://github.com/login/oauth/access_token', {
      client_id: id,
      device_code: deviceCode,
      grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
    })
    return parseAccessTokenResponse(r.body)
  } catch (e) {
    return { ok: false, error: e.message || String(e) }
  }
}

/**
 * Apply successful OAuth into backup settings structure (no secrets in logs).
 */
function applyOAuthToBackupConfig(backupSettings, providerId, tokenPayload) {
  const b = JSON.parse(JSON.stringify(backupSettings || { providers: {} }))
  if (!b.providers) b.providers = {}
  const id = String(providerId || 'github')
  const prev = b.providers[id] || { enabled: false, config: {} }
  const config = { ...(prev.config || {}) }
  if (tokenPayload && tokenPayload.accessToken) {
    config.token = tokenPayload.accessToken
    config.authMethod = 'oauth'
    config.linkedAt = new Date().toISOString()
  }
  if (tokenPayload && tokenPayload.filename) config.filename = tokenPayload.filename
  b.providers[id] = {
    enabled: true,
    config,
  }
  return b
}

module.exports = {
  GITHUB_CLIENT_ID,
  PROVIDER_LOGIN,
  getProviderLogin,
  listOneClickProviders,
  buildGitHubDeviceCodeUrl,
  buildGitHubAuthorizeHint,
  parseDeviceCodeResponse,
  parseAccessTokenResponse,
  startGitHubDeviceFlow,
  pollGitHubDeviceToken,
  applyOAuthToBackupConfig,
  httpPostForm,
}
