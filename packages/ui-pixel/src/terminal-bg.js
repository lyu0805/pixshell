/**
 * Terminal background image + blur + text shadow
 */
function applyTerminalBackground(el, { url, blur = 4, enable = true } = {}) {
  if (!el) return { applied: false }
  if (!enable || !url) {
    el.style.backgroundImage = ''
    el.style.setProperty('--term-blur', '0px')
    el.classList && el.classList.remove('has-bg')
    return { applied: false }
  }
  const safe = String(url).replace(/'/g, '%27')
  el.style.backgroundImage = `url('${safe}')`
  el.style.backgroundSize = 'cover'
  el.style.backgroundPosition = 'center'
  el.style.setProperty('--term-blur', `${Number(blur) || 0}px`)
  el.classList && el.classList.add('has-bg')
  return { applied: true, blur: Number(blur) || 0, url: safe }
}

function cssVarsFromBg({ blur = 4, enable = true } = {}) {
  return {
    '--term-blur': enable ? `${Number(blur) || 0}px` : '0px',
  }
}

const CSS_SNIPPET = `
.terminal-pane.has-bg {
  background-size: cover;
  background-position: center;
  background-repeat: no-repeat;
}
.terminal-pane::before {
  content: '';
  position: absolute;
  inset: 0;
  backdrop-filter: blur(var(--term-blur, 0px));
  pointer-events: none;
  z-index: 0;
}
.xterm-host { position: relative; z-index: 1; }
.xterm { text-shadow: 0 1px 2px rgba(0,0,0,0.65); }
`

module.exports = { applyTerminalBackground, cssVarsFromBg, CSS_SNIPPET }
