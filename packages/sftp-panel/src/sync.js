/**
 * Terminal cwd ↔ SFTP path sync
 */
function normalizeRemotePath(p) {
  if (!p || p === '~') return '.'
  let s = String(p).replace(/\/+/g, '/')
  if (s.length > 1 && s.endsWith('/')) s = s.slice(0, -1)
  return s || '.'
}

function joinRemote(base, name) {
  if (!name || name === '.') return normalizeRemotePath(base)
  if (name === '..') {
    const parts = normalizeRemotePath(base).split('/').filter(Boolean)
    if (normalizeRemotePath(base) === '.' || normalizeRemotePath(base) === '/') return '.'
    parts.pop()
    return parts.length ? '/' + parts.join('/') : (String(base).startsWith('/') ? '/' : '.')
  }
  if (name.startsWith('/')) return normalizeRemotePath(name)
  const b = normalizeRemotePath(base)
  if (b === '.' ) return name
  if (b === '/') return '/' + name
  return b + '/' + name
}

function shouldSyncCd(command) {
  return /^\s*cd\s+/.test(String(command || ''))
}

function parseCdTarget(command) {
  const m = String(command || '').match(/^\s*cd\s*(.*)$/)
  if (!m) return null
  let t = m[1].trim()
  if (!t) return '~'
  t = t.replace(/^['"]|['"]$/g, '')
  return t
}

function applyCd(currentPath, command) {
  if (!shouldSyncCd(command)) return currentPath
  const target = parseCdTarget(command)
  if (target === null) return currentPath
  if (target === '~' || target === '') return '.'
  if (target.startsWith('/')) return normalizeRemotePath(target)
  return joinRemote(currentPath || '.', target)
}

module.exports = { normalizeRemotePath, joinRemote, shouldSyncCd, parseCdTarget, applyCd }
