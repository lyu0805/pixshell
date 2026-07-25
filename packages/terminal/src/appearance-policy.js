/**
 * Pure terminal appearance policy (unit-testable, no DOM/Electron).
 * Used by renderer mentally; tests require this module directly.
 */

/**
 * Resolve final xterm theme from scheme + settings.
 * @param {object|null} schemeTheme - from getScheme/toXtermTheme
 * @param {object} settings
 * @param {{ forceSchemeBackground?: boolean }} [opts]
 */
function resolveTermTheme(schemeTheme, settings, opts = {}) {
  const s = settings || {}
  const forceSchemeBg = !!opts.forceSchemeBackground
  const base = {
    background: '#1e1f29',
    foreground: '#f8f8f2',
    cursor: '#bbbbbb',
    cursorAccent: '#1e1f29',
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
  }
  const theme = { ...base, ...(schemeTheme || {}) }
  // Only honor user background override when explicitly flagged
  const userSet = s.termBgUserSet === true
  const override = forceSchemeBg || !userSet ? '' : String(s.termBgOverride || '').trim()
  if (override) {
    theme.background = override
    theme.cursorAccent = override
  } else {
    theme.cursorAccent = theme.cursorAccent || theme.background
  }
  if (!theme.foreground) theme.foreground = base.foreground
  if (!theme.background) theme.background = base.background

  // Force high-contrast error / warning ANSI so severity always pops
  // regardless of the selected scheme's vintage palette.
  const mode = String((settings && settings.theme) || 'dark') === 'light' ? 'light' : 'dark'
  if (mode === 'light') {
    theme.red = '#b00014'
    theme.brightRed = '#d4001f'
    theme.yellow = '#9a4200'
    theme.brightYellow = '#b84f00'
  } else {
    theme.red = '#ff2d20'
    theme.brightRed = '#ff453a'
    theme.yellow = '#ffcc00'
    theme.brightYellow = '#ffd60a'
  }
  return theme
}

/**
 * Font size vs panel size: scales gently with host growth (fullscreen larger),
 * never freezes forever; caps prevent explosion.
 * @param {number} baseFont settings.fontSize
 * @param {number} hostW
 * @param {number} hostH
 */
function resolveTermFontPx(baseFont, hostW, hostH) {
  const base = Math.max(8, Math.min(36, Number(baseFont) || 13))
  const w = Math.max(1, Number(hostW) || 640)
  const h = Math.max(1, Number(hostH) || 400)
  // Reference panel ~720×480; scale by geometric mean of ratios
  const sw = w / 720
  const sh = h / 480
  let scale = Math.sqrt(Math.max(0.01, sw * sh))
  // Product: allow growth on fullscreen, damp extremes
  if (scale < 0.88) scale = 0.88
  if (scale > 1.42) scale = 1.42
  const px = Math.round(base * scale)
  return Math.max(9, Math.min(28, px))
}

/**
 * When user picks a new color scheme in settings, clear sticky bg override.
 */
function settingsAfterSchemeChange(prevSettings, nextSchemeId) {
  const s = { ...(prevSettings || {}) }
  const prev = s.colorScheme
  s.colorScheme = nextSchemeId || s.colorScheme || 'dracula'
  if (String(prev || '') !== String(s.colorScheme)) {
    delete s.termBgOverride
    delete s.termBg
    s.termBgUserSet = false
  }
  return s
}

/**
 * Mark user-set background from right-click picker.
 */
function settingsAfterBgPick(prevSettings, color, { clear = false } = {}) {
  const s = { ...(prevSettings || {}) }
  if (clear) {
    delete s.termBgOverride
    delete s.termBg
    s.termBgUserSet = false
  } else {
    s.termBgOverride = color
    s.termBg = color
    s.termBgUserSet = true
  }
  return s
}

module.exports = {
  resolveTermTheme,
  resolveTermFontPx,
  settingsAfterSchemeChange,
  settingsAfterBgPick,
}
