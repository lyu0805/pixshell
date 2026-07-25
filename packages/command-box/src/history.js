/**
 * Command history for the command box
 */
function pushHistory(history, cmd, limit = 500) {
  const c = String(cmd || '').replace(/\n+$/, '')
  if (!c.trim()) return history || []
  const next = [c, ...(history || []).filter((h) => h !== c)]
  return next.slice(0, limit)
}

function navigateHistory(history, index, direction, draft) {
  // index -1 means draft; direction +1 older, -1 newer (up = older)
  const hist = history || []
  if (direction > 0) {
    const ni = Math.min(hist.length - 1, (index < 0 ? -1 : index) + 1)
    if (ni < 0 || !hist.length) return { index: -1, value: draft || '' }
    return { index: ni, value: hist[ni] || '' }
  }
  if (index <= 0) return { index: -1, value: draft || '' }
  const ni = index - 1
  return { index: ni, value: hist[ni] || '' }
}

function filterHistory(history, prefix, limit = 20) {
  const p = String(prefix || '')
  return (history || []).filter((h) => !p || h.startsWith(p) || h.includes(p)).slice(0, limit)
}

module.exports = { pushHistory, navigateHistory, filterHistory }
