/**
 * Command-box remote file quick pick
 */
async function listRemoteCandidates(sftpList, sessionId, basePath = '.') {
  const res = await sftpList(sessionId, basePath)
  if (!res || !res.ok) return []
  return (res.entries || [])
    .filter((e) => e.name !== '.' && e.name !== '..')
    .map((e) => ({
      label: e.name + (e.isDir ? '/' : ''),
      insert: e.isDir ? e.name + '/' : e.name,
      isDir: !!e.isDir,
    }))
}

function mergeCompletions(commandPrefix, localCatalog, remoteCandidates) {
  const p = String(commandPrefix || '')
  const last = p.split(/\s+/).pop() || ''
  const out = []
  for (const c of localCatalog || []) {
    if (!last || c.startsWith(last) || c.includes(last)) out.push({ label: c, insert: c, source: 'local' })
  }
  for (const r of remoteCandidates || []) {
    if (!last || r.label.startsWith(last) || r.label.includes(last))
      out.push({ label: r.label, insert: r.insert, source: 'remote' })
  }
  return out.slice(0, 30)
}

function insertPathIntoCommand(command, pathToInsert, cursorPos) {
  const cmd = String(command || '')
  const pos = cursorPos == null ? cmd.length : cursorPos
  const before = cmd.slice(0, pos)
  const after = cmd.slice(pos)
  // replace last token if it looks like a path fragment
  const m = before.match(/^(.*?)(\S*)$/)
  if (!m) return cmd + pathToInsert
  return m[1] + pathToInsert + after
}

module.exports = { listRemoteCandidates, mergeCompletions, insertPathIntoCommand }
