/**
 * Import host tree JSON files into PixShell hosts.json shape.
 * node scripts/import-hosts.js [connDir] [outHostsJson]
 *
 * Looks for *_connect_config.json files under a connection tree directory.
 * Group names are read from folder.json when present.
 * Encrypted third-party passwords are never imported.
 */
const fs = require('fs')
const path = require('path')
const os = require('os')

function walk(dir, acc = []) {
  if (!fs.existsSync(dir)) return acc
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name)
    let st
    try { st = fs.statSync(p) } catch { continue }
    if (st.isDirectory()) walk(p, acc)
    else if (name.endsWith('_connect_config.json')) acc.push(p)
  }
  return acc
}

function loadFolderNames(connDir) {
  const map = { root: '连接' }
  if (!fs.existsSync(connDir)) return map
  for (const name of fs.readdirSync(connDir)) {
    const folderJson = path.join(connDir, name, 'folder.json')
    if (!fs.existsSync(folderJson)) continue
    try {
      const raw = JSON.parse(fs.readFileSync(folderJson, 'utf8'))
      if (raw.id) map[raw.id] = raw.name || name
      map[name] = raw.name || name
    } catch (_) {}
  }
  return map
}

function mapHost(raw, groupHint, folderNames) {
  const parent = raw.parent_id || 'root'
  let group = groupHint
  if (!group || group === 'conn' || group === '默认') {
    group = (folderNames && (folderNames[parent] || folderNames[groupHint])) ||
      (parent && parent !== 'root' ? parent : '连接')
  }
  if (group === 'root' || !group) group = '连接'
  return {
    id: raw.id || ('h_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6)),
    name: raw.name || raw.host || 'host',
    host: raw.host || '',
    port: Number(raw.port) || 22,
    username: raw.user_name || raw.username || 'root',
    authType: Number(raw.authentication_type) === 2 ? 'key' : 'password',
    authMethod: Number(raw.authentication_type) === 2 ? 'publicKey' : 'password',
    password: '',
    group,
    proxyId: raw.proxy_id && raw.proxy_id !== '0' ? String(raw.proxy_id) : '',
    connectionType: raw.conection_type ?? raw.connection_type ?? 100,
    accelerate: !!raw.accelerate,
    charset: raw.terminal_encoding || 'UTF-8',
    encoding: raw.terminal_encoding || 'UTF-8',
    remark: raw.description || '',
    secretKeyId: raw.secret_key_id || '',
    execChannel: raw.exec_channel_enable !== false,
    rememberPassword: true,
    rawParentId: parent,
  }
}

function importHostsDir(connDir) {
  const folderNames = loadFolderNames(connDir)
  const files = walk(connDir)
  const hosts = []
  const seen = new Set()
  for (const f of files) {
    try {
      const raw = JSON.parse(fs.readFileSync(f, 'utf8'))
      if (raw.delete_time && Number(raw.delete_time) > 0) continue
      const dirBase = path.basename(path.dirname(f))
      const groupHint =
        dirBase === 'conn' || dirBase === path.basename(connDir)
          ? folderNames[raw.parent_id] || '连接'
          : folderNames[dirBase] || folderNames[raw.parent_id] || dirBase
      const h = mapHost(raw, groupHint, folderNames)
      if (!h.host) continue
      if (seen.has(h.id)) continue
      seen.add(h.id)
      hosts.push(h)
    } catch (e) {
      console.warn('skip', f, e.message)
    }
  }
  hosts.sort((a, b) => {
    const g = String(a.group).localeCompare(String(b.group), 'zh')
    return g || String(a.name).localeCompare(String(b.name), 'zh')
  })
  return hosts
}

function main() {
  const candidates = [
    process.argv[2],
    process.env.PIXSHELL_IMPORT_CONN_DIR,
    ...(() => {
      try {
        const lib = path.join(os.homedir(), 'Library')
        return fs.readdirSync(lib).map((n) => path.join(lib, n, 'conn'))
      } catch {
        return []
      }
    })(),
  ].filter(Boolean)
  let connDir = candidates[0]
  for (const c of candidates) {
    if (c && fs.existsSync(c)) { connDir = c; break }
  }
  const out = process.argv[3] || path.join(os.tmpdir(), 'pixshell-imported-hosts.json')
  const hosts = importHostsDir(connDir)
  fs.mkdirSync(path.dirname(out), { recursive: true })
  fs.writeFileSync(out, JSON.stringify({ source: connDir, count: hosts.length, hosts }, null, 2))
  console.log('imported', hosts.length, 'from', connDir, '->', out)
  return { connDir, hosts, out }
}

if (require.main === module) main()
module.exports = { importHostsDir, mapHost, loadFolderNames, main }
