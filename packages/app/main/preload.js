/**
 * Preload — expose native fsApi to renderer (contextIsolation).
 */
'use strict'

const { contextBridge, ipcRenderer, webUtils } = require('electron')

function on(channel, cb) {
  const listener = (_e, msg) => cb(msg)
  ipcRenderer.on(channel, listener)
  return () => ipcRenderer.removeListener(channel, listener)
}

contextBridge.exposeInMainWorld('fsApi', {
  // window controls
  minimizeWindow: () => ipcRenderer.invoke('window:minimize'),
  maximizeWindow: () => ipcRenderer.invoke('window:maximize'),
  closeWindow: () => ipcRenderer.invoke('window:close'),
  isMaximized: () => ipcRenderer.invoke('window:isMaximized'),
  newMainWindow: () => ipcRenderer.invoke('window:new-main'),
  setWindowBackground: (color) => ipcRenderer.invoke('window:set-bg', color),
  getAppVersion: () => ipcRenderer.invoke('app:get-version'),
  checkForUpdate: () => ipcRenderer.invoke('app:check-update'),
  downloadUpdate: (info) => ipcRenderer.invoke('app:download-update', info ? { info } : {}),
  openReleases: () => ipcRenderer.invoke('app:open-releases'),
  openRepo: () => ipcRenderer.invoke('app:open-repo'),
  getMainBounds: () => ipcRenderer.invoke('window:get-main-bounds'),
  openFloatWindow: (payload) => ipcRenderer.invoke('window:open-float', payload || {}),
  closeFloatWindow: (id) => ipcRenderer.invoke('window:close-float', { id }),
  focusFloatWindow: (id) => ipcRenderer.invoke('window:focus-float', { id }),
  setFloatBounds: (id, bounds) => ipcRenderer.invoke('window:float-bounds', { id, bounds }),
  getFloatInit: (id) => ipcRenderer.invoke('window:get-float-init', { id }),
  getCursorScreenPoint: () => ipcRenderer.invoke('window:cursor-screen'),
  floatToMain: (payload) => ipcRenderer.invoke('float:to-main', payload || {}),
  floatToFloat: (payload) => ipcRenderer.invoke('float:to-float', payload || {}),
  onFloatMessage: (cb) => on('float:message', cb),
  onFloatClosed: (cb) => on('float:closed', cb),
  floatReady: (payload) =>
    ipcRenderer.invoke(
      'float:ready',
      payload && typeof payload === 'object' ? payload : { id: payload || '' },
    ),

  // health
  sshReady: () => ipcRenderer.invoke('ssh:ready'),

  // session
  connect: (payload) => ipcRenderer.invoke('ssh:connect', payload),
  disconnect: (sessionId) => ipcRenderer.invoke('ssh:disconnect', { sessionId }),
  reconnect: (sessionId) => ipcRenderer.invoke('ssh:reconnect', { sessionId }),
  write: (sessionId, data) => ipcRenderer.invoke('ssh:write', { sessionId, data }),
  writeBinary: (sessionId, dataBase64) =>
    ipcRenderer.invoke('ssh:write-binary', { sessionId, dataBase64 }),
  resize: (sessionId, cols, rows) => ipcRenderer.invoke('ssh:resize', { sessionId, cols, rows }),
  exec: (sessionId, command) => ipcRenderer.invoke('ssh:exec', { sessionId, command }),
  setAutoReconnect: (enabled) => ipcRenderer.invoke('ssh:set-auto-reconnect', { enabled }),
  kill: (sessionId, pid, signal) => ipcRenderer.invoke('ssh:kill', { sessionId, pid, signal }),

  // sftp
  sftpList: (sessionId, remotePath) => ipcRenderer.invoke('ssh:sftp-list', { sessionId, remotePath }),
  sftpRead: (sessionId, remotePath) => ipcRenderer.invoke('ssh:sftp-read', { sessionId, remotePath }),
  sftpWrite: (sessionId, remotePath, dataBase64) =>
    ipcRenderer.invoke('ssh:sftp-write', { sessionId, remotePath, dataBase64 }),
  sftpMkdir: (sessionId, remotePath) => ipcRenderer.invoke('ssh:sftp-mkdir', { sessionId, remotePath }),
  sftpUnlink: (sessionId, remotePath, isDir) =>
    ipcRenderer.invoke('ssh:sftp-unlink', { sessionId, remotePath, isDir }),
  sftpRename: (sessionId, from, to) => ipcRenderer.invoke('ssh:sftp-rename', { sessionId, from, to }),
  sftpDownload: (sessionId, remotePath, localPath) =>
    ipcRenderer.invoke('ssh:sftp-download', { sessionId, remotePath, localPath }),
  sftpDownloadSmart: (sessionId, remotePaths, opts) =>
    ipcRenderer.invoke('ssh:sftp-download-smart', { sessionId, remotePaths, opts }),
  sftpUpload: (sessionId, remoteDir, localPath, opts) =>
    ipcRenderer.invoke('ssh:sftp-upload', { sessionId, remoteDir, localPath, opts }),

  // collect
  monitor: (sessionId) => ipcRenderer.invoke('ssh:monitor', { sessionId }),
  processes: (sessionId) => ipcRenderer.invoke('ssh:processes', { sessionId }),
  network: (sessionId) => ipcRenderer.invoke('ssh:network', { sessionId }),
  sysinfo: (sessionId) => ipcRenderer.invoke('ssh:sysinfo', { sessionId }),
  packRemote: (sessionId, paths, format) =>
    ipcRenderer.invoke('ssh:pack', { sessionId, paths, format }),

  // hosts / settings / quick
  loadHosts: () => ipcRenderer.invoke('hosts:load'),
  saveHosts: (hosts) => ipcRenderer.invoke('hosts:save', hosts),
  loadSettings: () => ipcRenderer.invoke('settings:load'),
  saveSettings: (settings) => ipcRenderer.invoke('settings:save', settings),
  loadQuick: () => ipcRenderer.invoke('quick:load'),
  saveQuick: (list) => ipcRenderer.invoke('quick:save', list),
  importHosts: (dir) => ipcRenderer.invoke('hosts:import-hosts', dir),
  importQuick: (configPath) => ipcRenderer.invoke('quick:import', configPath),

  // misc
  openFile: () => ipcRenderer.invoke('dialog:open-file'),
  openKeyFile: () => ipcRenderer.invoke('dialog:open-key'),
  getPathForFile: (file) => {
    try {
      if (file && typeof webUtils?.getPathForFile === 'function') return webUtils.getPathForFile(file)
      return (file && file.path) || ''
    } catch (_) {
      return (file && file.path) || ''
    }
  },
  openDirectory: () => ipcRenderer.invoke('dialog:open-directory'),
  openPath: (p) => ipcRenderer.invoke('shell:open-path', p),
  saveFile: (opts) => ipcRenderer.invoke('dialog:save-file', opts),
  writeTextFile: (filePath, text) => ipcRenderer.invoke('fs:write-text', { filePath, text }),
  readTextFile: (filePath) => ipcRenderer.invoke('fs:read-text', filePath),
  openExternal: (url) => ipcRenderer.invoke('shell:open-external', url),
  backupListOneClick: () => ipcRenderer.invoke('backup:list-oneclick'),
  backupOpenLogin: (providerId, url) =>
    ipcRenderer.invoke('backup:open-login', { providerId, url }),
  backupGithubDeviceStart: () => ipcRenderer.invoke('backup:github-device-start'),
  backupGithubDevicePoll: (deviceCode, clientId) =>
    ipcRenderer.invoke('backup:github-device-poll', { deviceCode, clientId }),
  backupApplyOAuth: (providerId, accessToken, filename) =>
    ipcRenderer.invoke('backup:apply-oauth', { providerId, accessToken, filename }),
  listSchemes: () => ipcRenderer.invoke('schemes:list'),
  getScheme: (id) => ipcRenderer.invoke('schemes:get', id),
  launchRdp: (payload) => ipcRenderer.invoke('rdp:launch', payload),

  // external CLI / AI-agent bridge
  cliStatus: () => ipcRenderer.invoke('cli:status'),
  cliSetEnabled: (enabled, port) => ipcRenderer.invoke('cli:set-enabled', { enabled, port }),
  cliRotateToken: () => ipcRenderer.invoke('cli:rotate-token'),
  cliInstallSkills: () => ipcRenderer.invoke('cli:install-skills'),
  cliTokenPath: () => ipcRenderer.invoke('cli:token-path'),

  // logging (always-on file trail)
  logWrite: (level, tag, msg, extra) =>
    ipcRenderer.invoke('log:write', { level, tag, msg, extra }),
  logPaths: () => ipcRenderer.invoke('log:paths'),

  // events
  onData: (cb) => on('ssh:data', cb),
  onStatus: (cb) => on('ssh:status', cb),
  onCliEvent: (cb) => on('cli:event', cb),
})
