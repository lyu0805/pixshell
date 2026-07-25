/**
 * Default hotkey bindings for common terminal actions
 * Format: { action: { key, ctrl, alt, shift } }
 * modifiers: Ctrl/Alt/Shift/Meta
 */
const DEFAULT_HOTKEYS = {
  copy: { key: 'c', ctrl: true, action: 'copy' },
  paste: { key: 'v', ctrl: true, action: 'paste' },
  find: { key: 'f', ctrl: true, action: 'find' },
  newConn: { key: 'n', ctrl: true, action: 'new-connection' },
  closeTab: { key: 'w', ctrl: true, action: 'close-tab' },
}

function matchHotkey(e, binding) {
  if (!binding) return false
  const key = (e.key || '').toLowerCase()
  if (key !== String(binding.key || '').toLowerCase()) return false
  if (!!binding.ctrl !== !!(e.ctrlKey || e.metaKey)) return false
  if (!!binding.alt !== !!e.altKey) return false
  if (!!binding.shift !== !!e.shiftKey) return false
  return true
}

function handleKeyEvent(e, hotkeys, handlers) {
  for (const [name, binding] of Object.entries(hotkeys || DEFAULT_HOTKEYS)) {
    if (matchHotkey(e, binding) && handlers[binding.action || name]) {
      e.preventDefault()
      handlers[binding.action || name]()
      return true
    }
  }
  return false
}

module.exports = { DEFAULT_HOTKEYS, matchHotkey, handleKeyEvent }
