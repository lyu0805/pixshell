/**
 * Multi-platform support surface for PixShell (Electron targets)
 */
function detectPlatform(platform = process.platform, arch = process.arch) {
  const os =
    platform === 'darwin' ? 'mac' : platform === 'win32' ? 'win' : platform === 'linux' ? 'linux' : 'other'
  return {
    platform,
    arch,
    os,
    isMac: os === 'mac',
    isWin: os === 'win',
    isLinux: os === 'linux',
    supported: os === 'mac' || os === 'win' || os === 'linux',
    electronTarget:
      os === 'mac' ? 'darwin' : os === 'win' ? 'win32' : os === 'linux' ? 'linux' : null,
  }
}

function packageTargets() {
  return [
    { id: 'mac-x64', platform: 'darwin', arch: 'x64', artifact: 'dmg/zip' },
    { id: 'mac-arm64', platform: 'darwin', arch: 'arm64', artifact: 'dmg/zip' },
    { id: 'win-x64', platform: 'win32', arch: 'x64', artifact: 'nsis/portable' },
    { id: 'linux-x64', platform: 'linux', arch: 'x64', artifact: 'AppImage' },
  ]
}

function runtimeDataDir(osHome, platform = process.platform) {
  if (platform === 'darwin') return `${osHome}/Library/Application Support/PixShell`
  if (platform === 'win32') return `${osHome}\\AppData\\Roaming\\PixShell`
  return `${osHome}/.local/share/PixShell`
}

module.exports = { detectPlatform, packageTargets, runtimeDataDir }
