/**
 * @fs/ssh — native ssh2 session stack.
 * Public entry for main process.
 */
'use strict'

const { SSHSession, Client, resolveSsh2 } = require('./session/ssh-session')
const { ShellSession } = require('./session/shell-session')
const { SFTPSession } = require('./session/sftp-session')
const { SSHMultiplexer } = require('./session/multiplexer')
const { buildAlgorithms, DEFAULT_ALGORITHMS } = require('./algorithms')

module.exports = {
  SSHSession,
  ShellSession,
  SFTPSession,
  SSHMultiplexer,
  buildAlgorithms,
  DEFAULT_ALGORITHMS,
  Client,
  resolveSsh2,
  isSsh2Available: () => SSHSession.isAvailable(),
}
