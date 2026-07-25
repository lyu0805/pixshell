/**
 * Settings UI model defaults
 */
function defaultUiSettings() {
  return {
    theme: 'pix-dark', // or pixel-retro
    colorScheme: 'pix-dark',
    fontSize: 13,
    enFontName: 'DejaVu Sans Mono',
    cnFontName: 'Microsoft YaHei UI',
    showSidebar: true,
    showCommandBar: true,
    bgImgEnable: false,
    bgImg: '',
    bgImgBlurLevel: 4,
    syncDirWithSftp: true,
    closeToTray: false,
    confirmClose: true,
    packTrans: false,
    commandInput: {
      cleanAfterSend: true,
      ignoreBlankLine: true,
      appendCr: true,
      promptEnable: true,
      fullPath: true,
    },
    layout: {
      leftSideWidth: 200,
      centerBottomHeight: 200,
      sideFootHeight: 140,
    },
  }
}

function applyLayoutCss(settings) {
  const root = typeof document !== 'undefined' ? document.documentElement : null
  if (!root || !settings?.layout) return
  if (settings.layout.leftSideWidth)
    root.style.setProperty('--sidebar-w', settings.layout.leftSideWidth + 'px')
  if (settings.layout.centerBottomHeight)
    root.style.setProperty('--bottom-h', settings.layout.centerBottomHeight + 'px')
  if (settings.theme === 'pixel-retro' && typeof document !== 'undefined') {
    document.body.classList.add('theme-pixel-retro')
  } else if (typeof document !== 'undefined') {
    document.body.classList.remove('theme-pixel-retro')
  }
}

module.exports = { defaultUiSettings, applyLayoutCss }
