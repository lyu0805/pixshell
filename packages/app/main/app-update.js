/**
 * PixShell self-update helpers (GitHub Releases).
 * Network stays in the main process; pure helpers are unit-testable offline.
 */
'use strict'

const https = require('https')
const http = require('http')
const fs = require('fs')
const path = require('path')
const { URL } = require('url')

const REPO_OWNER = 'lyu0805'
const REPO_NAME = 'pixshell'
const REPO_SLUG = `${REPO_OWNER}/${REPO_NAME}`
const REPO_URL = `https://github.com/${REPO_SLUG}`
const RELEASES_URL = `${REPO_URL}/releases`
const API_LATEST = `https://api.github.com/repos/${REPO_SLUG}/releases/latest`
const API_LIST = `https://api.github.com/repos/${REPO_SLUG}/releases?per_page=8`
const UA = 'PixShell-Update'
const ATOM_URL = `https://github.com/${REPO_SLUG}/releases.atom`

function githubAuthHeaders() {
  const token = String(
    process.env.PIXSHELL_GITHUB_TOKEN ||
      process.env.GITHUB_TOKEN ||
      process.env.GH_TOKEN ||
      '',
  ).trim()
  if (!token) return {}
  // classic / fine-grained both accept Bearer
  return { Authorization: 'Bearer ' + token }
}

function normalizeVersion(v) {
  return String(v || '')
    .trim()
    .replace(/^v/i, '')
    .replace(/[^\d.].*$/, (tail) => {
      // keep trailing pre-release only if pure digits already stripped
      return ''
    })
    .replace(/\.+$/, '')
}

function parseVersionParts(v) {
  const s = normalizeVersion(v)
  if (!s) return null
  const parts = s.split('.').map((x) => {
    const n = parseInt(x, 10)
    return Number.isFinite(n) ? n : 0
  })
  while (parts.length < 3) parts.push(0)
  return parts.slice(0, 4)
}

/** @returns {number} 1 if a>b, -1 if a<b, 0 equal/unknown */
function compareVersions(a, b) {
  const pa = parseVersionParts(a)
  const pb = parseVersionParts(b)
  if (!pa || !pb) return 0
  const n = Math.max(pa.length, pb.length)
  for (let i = 0; i < n; i++) {
    const x = pa[i] || 0
    const y = pb[i] || 0
    if (x > y) return 1
    if (x < y) return -1
  }
  return 0
}

function platformHints(platform = process.platform, arch = process.arch) {
  const p = String(platform || '')
  const a = String(arch || '')
  if (p === 'darwin') {
    return {
      id: 'mac',
      ext: ['.dmg', '.pkg', '.zip'],
      nameNeed: ['mac', 'darwin', 'osx'],
      nameAvoid: ['win', 'windows', 'linux', 'appimage'],
      archNeed: a === 'arm64' ? ['arm64', 'aarch64', 'apple-silicon', 'm1', 'm2'] : ['x64', 'amd64', 'x86_64', 'intel'],
      archSoft: a === 'arm64' ? ['universal'] : ['universal', 'x64'],
    }
  }
  if (p === 'win32') {
    return {
      id: 'win',
      ext: ['.exe', '.msi', '.zip'],
      nameNeed: ['win', 'windows', 'nsis'],
      nameAvoid: ['mac', 'darwin', 'linux', 'appimage', 'dmg'],
      archNeed: a === 'arm64' ? ['arm64', 'aarch64'] : ['x64', 'amd64', 'x86_64', 'win64', 'win-x64'],
      archSoft: ['portable', 'setup', 'installer'],
    }
  }
  return {
    id: 'linux',
    ext: ['.AppImage', '.appimage', '.deb', '.rpm', '.tar.gz', '.tgz', '.zip'],
    nameNeed: ['linux', 'appimage'],
    nameAvoid: ['mac', 'darwin', 'win', 'windows', 'dmg', 'nsis'],
    archNeed: a === 'arm64' ? ['arm64', 'aarch64'] : ['x64', 'amd64', 'x86_64'],
    archSoft: ['appimage'],
  }
}

function scoreAsset(asset, hints) {
  const name = String(asset && (asset.name || asset.browser_download_url) || '').toLowerCase()
  if (!name) return -1000
  let score = 0
  const extHit = (hints.ext || []).some((ext) => name.endsWith(String(ext).toLowerCase()))
  if (extHit) score += 50
  else score -= 20
  if ((hints.nameNeed || []).some((k) => name.includes(k))) score += 25
  if ((hints.nameAvoid || []).some((k) => name.includes(k))) score -= 40
  if ((hints.archNeed || []).some((k) => name.includes(k))) score += 30
  if ((hints.archSoft || []).some((k) => name.includes(k))) score += 8
  // Prefer installer over generic zip when tied
  if (name.endsWith('.dmg') || name.endsWith('.exe') || name.endsWith('.appimage')) score += 6
  if (name.includes('blockmap') || name.endsWith('.yml') || name.endsWith('.yaml') || name.endsWith('.json')) {
    score -= 100
  }
  if (asset && Number(asset.size) > 0) score += 1
  return score
}

function pickReleaseAsset(assets, platform, arch) {
  const list = Array.isArray(assets) ? assets : []
  if (!list.length) return null
  const hints = platformHints(platform, arch)
  let best = null
  let bestScore = -999
  for (const a of list) {
    const s = scoreAsset(a, hints)
    if (s > bestScore) {
      bestScore = s
      best = a
    }
  }
  if (!best || bestScore < 20) {
    // fallback: first binary-looking asset that is not metadata
    best =
      list.find((a) => {
        const n = String(a && a.name || '').toLowerCase()
        return n && !n.endsWith('.yml') && !n.endsWith('.yaml') && !n.endsWith('.json') && !n.includes('blockmap')
      }) || null
  }
  if (!best) return null
  return {
    name: best.name || path.basename(String(best.browser_download_url || 'update.bin')),
    url: best.browser_download_url || best.url || '',
    size: Number(best.size) || 0,
    contentType: best.content_type || '',
    score: bestScore,
  }
}

function summarizeRelease(release, currentVersion, platform, arch) {
  if (!release || typeof release !== 'object') {
    return {
      ok: true,
      status: 'unknown',
      updateAvailable: false,
      currentVersion: normalizeVersion(currentVersion) || String(currentVersion || ''),
      latestVersion: '',
      releaseName: '',
      releaseUrl: RELEASES_URL,
      htmlUrl: RELEASES_URL,
      asset: null,
      message: 'no release',
    }
  }
  const latestVersion = normalizeVersion(release.tag_name || release.name || '')
  const current = normalizeVersion(currentVersion) || '0.0.0'
  const cmp = latestVersion ? compareVersions(latestVersion, current) : 0
  const updateAvailable = cmp > 0
  const asset = pickReleaseAsset(release.assets || [], platform, arch)
  return {
    ok: true,
    status: updateAvailable ? 'update-available' : latestVersion ? 'latest' : 'unknown',
    updateAvailable,
    currentVersion: current,
    latestVersion: latestVersion || current,
    releaseName: release.name || release.tag_name || '',
    releaseUrl: release.html_url || RELEASES_URL,
    htmlUrl: release.html_url || RELEASES_URL,
    publishedAt: release.published_at || release.created_at || '',
    asset,
    body: typeof release.body === 'string' ? release.body.slice(0, 2000) : '',
    message: updateAvailable
      ? `发现新版本 ${latestVersion}`
      : latestVersion
        ? `已是最新版本 ${current}`
        : '暂无发行版',
  }
}

function httpRequest(urlStr, { method = 'GET', headers = {}, maxRedirects = 5 } = {}) {
  return new Promise((resolve, reject) => {
    let settled = false
    const finish = (err, res, body) => {
      if (settled) return
      settled = true
      if (err) reject(err)
      else resolve({ res, body })
    }
    try {
      const u = new URL(urlStr)
      const lib = u.protocol === 'http:' ? http : https
      const req = lib.request(
        {
          protocol: u.protocol,
          hostname: u.hostname,
          port: u.port || (u.protocol === 'http:' ? 80 : 443),
          path: u.pathname + u.search,
          method,
          headers: {
            'User-Agent': UA,
            Accept: 'application/vnd.github+json',
            ...headers,
          },
        },
        (res) => {
          const code = res.statusCode || 0
          if (
            code >= 300 &&
            code < 400 &&
            res.headers.location &&
            maxRedirects > 0
          ) {
            const next = new URL(res.headers.location, u).toString()
            res.resume()
            httpRequest(next, { method, headers, maxRedirects: maxRedirects - 1 })
              .then((r) => finish(null, r.res, r.body))
              .catch((e) => finish(e))
            return
          }
          const chunks = []
          res.on('data', (c) => chunks.push(c))
          res.on('end', () => {
            finish(null, res, Buffer.concat(chunks))
          })
          res.on('error', (e) => finish(e))
        },
      )
      req.setTimeout(20000, () => {
        req.destroy(new Error('request timeout'))
      })
      req.on('error', (e) => finish(e))
      req.end()
    } catch (e) {
      finish(e)
    }
  })
}

async function httpGetJson(urlStr) {
  const { res, body } = await httpRequest(urlStr, {
    headers: {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      ...githubAuthHeaders(),
    },
  })
  const code = res.statusCode || 0
  const text = body ? body.toString('utf8') : ''
  let data = null
  try {
    data = text ? JSON.parse(text) : null
  } catch (_) {
    data = null
  }
  if (code === 404) {
    return { ok: false, notFound: true, statusCode: code, data, error: 'not found' }
  }
  if (code < 200 || code >= 300) {
    const msg =
      (data && (data.message || data.error)) ||
      `HTTP ${code}`
    return { ok: false, statusCode: code, data, error: String(msg) }
  }
  return { ok: true, statusCode: code, data }
}


function decodeXmlEntities(s) {
  return String(s || '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
}

function parseAtomReleases(xml) {
  const text = String(xml || '')
  const entries = []
  const re = /<entry>([\s\S]*?)<\/entry>/g
  let m
  while ((m = re.exec(text))) {
    const block = m[1]
    const title = ((block.match(/<title[^>]*>([\s\S]*?)<\/title>/) || [])[1] || '').trim()
    const link = ((block.match(/<link[^>]*href="([^"]+)"/) || [])[1] || '').trim()
    const updated = ((block.match(/<updated>([\s\S]*?)<\/updated>/) || [])[1] || '').trim()
    const id = ((block.match(/<id>([\s\S]*?)<\/id>/) || [])[1] || '').trim()
    const tag = normalizeVersion(title) || normalizeVersion(link) || ''
    if (!tag && !title) continue
    entries.push({
      tag_name: tag ? ('v' + tag) : title,
      name: decodeXmlEntities(title) || tag,
      html_url: link || RELEASES_URL,
      published_at: updated,
      draft: false,
      prerelease: /pre|alpha|beta|rc/i.test(title),
      assets: [],
      _fromAtom: true,
      _atomId: id,
    })
  }
  return entries
}

async function fetchReleasesFromAtom() {
  try {
    const { res, body } = await httpRequest(ATOM_URL, {
      headers: {
        Accept: 'application/atom+xml, application/xml, text/xml, */*',
        ...githubAuthHeaders(),
      },
    })
    const code = res.statusCode || 0
    if (code < 200 || code >= 300) {
      return { ok: false, error: 'atom HTTP ' + code }
    }
    const list = parseAtomReleases(body ? body.toString('utf8') : '')
    const rel = list.find((r) => r && !r.prerelease) || list[0] || null
    if (!rel) return { ok: true, release: null, empty: true, source: 'atom' }
    return { ok: true, release: rel, source: 'atom' }
  } catch (e) {
    return { ok: false, error: String(e && e.message || e) }
  }
}

async function fetchLatestRelease() {
  const latest = await httpGetJson(API_LATEST)
  if (latest.ok && latest.data && !latest.data.draft) {
    return { ok: true, release: latest.data, source: 'api-latest' }
  }
  const rateLimited =
    latest.statusCode === 403 ||
    /rate limit/i.test(String(latest.error || '')) ||
    /rate limit/i.test(String((latest.data && latest.data.message) || ''))
  if (latest.notFound || (latest.data && latest.data.message === 'Not Found')) {
    const list = await httpGetJson(API_LIST)
    if (list.ok) {
      const arr = Array.isArray(list.data) ? list.data : []
      const rel = arr.find((r) => r && !r.draft && !r.prerelease) || arr.find((r) => r && !r.draft) || null
      if (!rel) return { ok: true, release: null, empty: true, source: 'api-list' }
      return { ok: true, release: rel, source: 'api-list' }
    }
  }
  // API 空仓库 / 限流 / 网络异常时回退 releases.atom（无需 token）
  if (latest.notFound || rateLimited || !latest.ok) {
    const atom = await fetchReleasesFromAtom()
    if (atom.ok) return atom
    if (latest.notFound) return { ok: true, release: null, empty: true, source: 'api-empty' }
    return { ok: false, error: latest.error || atom.error || 'latest release failed' }
  }
  return { ok: false, error: latest.error || 'latest release failed' }
}

async function checkForUpdate(currentVersion, opts = {}) {
  const platform = opts.platform || process.platform
  const arch = opts.arch || process.arch
  try {
    const fr = await fetchLatestRelease()
    if (!fr.ok) {
      return {
        ok: false,
        status: 'error',
        updateAvailable: false,
        currentVersion: normalizeVersion(currentVersion) || String(currentVersion || ''),
        latestVersion: '',
        releaseUrl: RELEASES_URL,
        htmlUrl: RELEASES_URL,
        asset: null,
        error: fr.error || 'check failed',
        message: '检查更新失败: ' + (fr.error || 'unknown'),
      }
    }
    if (!fr.release) {
      return {
        ok: true,
        status: 'none',
        updateAvailable: false,
        currentVersion: normalizeVersion(currentVersion) || String(currentVersion || ''),
        latestVersion: '',
        releaseUrl: RELEASES_URL,
        htmlUrl: RELEASES_URL,
        asset: null,
        message: '暂无 GitHub 发行版',
      }
    }
    return summarizeRelease(fr.release, currentVersion, platform, arch)
  } catch (e) {
    return {
      ok: false,
      status: 'error',
      updateAvailable: false,
      currentVersion: normalizeVersion(currentVersion) || String(currentVersion || ''),
      latestVersion: '',
      releaseUrl: RELEASES_URL,
      htmlUrl: RELEASES_URL,
      asset: null,
      error: String(e && e.message || e),
      message: '检查更新失败: ' + String(e && e.message || e),
    }
  }
}

function downloadFile(urlStr, destPath, { onProgress, maxRedirects = 8 } = {}) {
  return new Promise((resolve, reject) => {
    const run = (url, left) => {
      let u
      try {
        u = new URL(url)
      } catch (e) {
        reject(e)
        return
      }
      const lib = u.protocol === 'http:' ? http : https
      const req = lib.request(
        {
          protocol: u.protocol,
          hostname: u.hostname,
          port: u.port || (u.protocol === 'http:' ? 80 : 443),
          path: u.pathname + u.search,
          method: 'GET',
          headers: {
            'User-Agent': UA,
            Accept: 'application/octet-stream',
          },
        },
        (res) => {
          const code = res.statusCode || 0
          if (code >= 300 && code < 400 && res.headers.location && left > 0) {
            const next = new URL(res.headers.location, u).toString()
            res.resume()
            run(next, left - 1)
            return
          }
          if (code < 200 || code >= 300) {
            res.resume()
            reject(new Error('download HTTP ' + code))
            return
          }
          const total = Number(res.headers['content-length']) || 0
          let received = 0
          const tmp = destPath + '.part'
          const out = fs.createWriteStream(tmp)
          res.on('data', (chunk) => {
            received += chunk.length
            if (typeof onProgress === 'function') {
              try {
                onProgress({ received, total, ratio: total ? received / total : 0 })
              } catch (_) {}
            }
          })
          res.pipe(out)
          out.on('finish', () => {
            out.close(() => {
              try {
                fs.renameSync(tmp, destPath)
                resolve({ ok: true, path: destPath, bytes: received })
              } catch (e) {
                reject(e)
              }
            })
          })
          out.on('error', (e) => {
            try { fs.unlinkSync(tmp) } catch (_) {}
            reject(e)
          })
          res.on('error', (e) => {
            try { fs.unlinkSync(tmp) } catch (_) {}
            reject(e)
          })
        },
      )
      req.setTimeout(60000, () => req.destroy(new Error('download timeout')))
      req.on('error', reject)
      req.end()
    }
    run(urlStr, maxRedirects)
  })
}

async function downloadUpdateAsset(asset, destDir) {
  if (!asset || !asset.url) {
    return { ok: false, error: 'no asset url' }
  }
  const dir = path.resolve(String(destDir || ''))
  if (!dir) return { ok: false, error: 'no dest dir' }
  fs.mkdirSync(dir, { recursive: true })
  const safeName = String(asset.name || 'PixShell-update.bin').replace(/[\\/:*?"<>|]/g, '_')
  const dest = path.join(dir, safeName)
  const r = await downloadFile(asset.url, dest)
  return { ok: true, path: r.path, bytes: r.bytes, name: safeName }
}

module.exports = {
  REPO_OWNER,
  REPO_NAME,
  REPO_SLUG,
  REPO_URL,
  RELEASES_URL,
  API_LATEST,
  normalizeVersion,
  parseVersionParts,
  compareVersions,
  platformHints,
  scoreAsset,
  pickReleaseAsset,
  summarizeRelease,
  checkForUpdate,
  downloadUpdateAsset,
  downloadFile,
  httpGetJson,
  fetchLatestRelease,
  fetchReleasesFromAtom,
  parseAtomReleases,
  githubAuthHeaders,
}
