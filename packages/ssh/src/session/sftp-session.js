/**
 * SFTPSession — SFTP facade over ssh2 SFTPWrapper.
 */
'use strict'

const pathPosix = require('path').posix

class SFTPSession {
  /**
   * @param {import('ssh2').SFTPWrapper} sftp
   * @param {{ debug?: Function }} [opts]
   */
  constructor(sftp, opts = {}) {
    this._sftp = sftp
    this._debug = opts.debug || (() => {})
    this._closed = false
  }

  get closed() {
    return this._closed
  }

  /**
   * @param {string} p
   * @returns {Promise<Array<{
   *   name: string, fullPath: string, isDirectory: boolean, isSymlink: boolean,
   *   mode: number, size: number, modifyTime: number, accessTime: number,
   *   rights: string, owner?: number, group?: number
   * }>>}
   */
  readdir(p) {
    this._debug('readdir', p)
    return new Promise((resolve, reject) => {
      this._sftp.readdir(p, (err, list) => {
        if (err) return reject(err)
        const entries = (list || []).map((item) => {
          const attrs = item.attrs || {}
          const mode = attrs.mode || 0
          const isDir = (mode & 0o170000) === 0o040000
          const isLink = (mode & 0o170000) === 0o120000
          return {
            name: item.filename,
            fullPath: p === '/' ? '/' + item.filename : pathPosix.join(p, item.filename),
            longname: item.longname || '',
            isDirectory: isDir,
            isSymlink: isLink,
            isDir,
            mode,
            size: attrs.size || 0,
            modifyTime: (attrs.mtime || 0) * 1000,
            accessTime: (attrs.atime || 0) * 1000,
            rights: modeString(mode, isDir),
            owner: attrs.uid,
            group: attrs.gid,
          }
        })
        resolve(entries)
      })
    })
  }

  realpath(p) {
    return new Promise((resolve, reject) => {
      this._sftp.realpath(p, (err, abs) => (err ? reject(err) : resolve(abs)))
    })
  }

  stat(p) {
    return new Promise((resolve, reject) => {
      this._sftp.stat(p, (err, attrs) => {
        if (err) return reject(err)
        const mode = attrs.mode || 0
        const isDir = (mode & 0o170000) === 0o040000
        resolve({
          name: pathPosix.basename(p),
          fullPath: p,
          isDirectory: isDir,
          isSymlink: (mode & 0o170000) === 0o120000,
          mode,
          size: attrs.size || 0,
          modifyTime: (attrs.mtime || 0) * 1000,
          rights: modeString(mode, isDir),
        })
      })
    })
  }

  readFile(p) {
    return new Promise((resolve, reject) => {
      this._sftp.readFile(p, (err, data) => (err ? reject(err) : resolve(Buffer.from(data))))
    })
  }

  writeFile(p, data) {
    return new Promise((resolve, reject) => {
      this._sftp.writeFile(p, data, (err) => (err ? reject(err) : resolve()))
    })
  }

  mkdir(p) {
    return new Promise((resolve, reject) => {
      this._sftp.mkdir(p, (err) => (err ? reject(err) : resolve()))
    })
  }

  rmdir(p) {
    return new Promise((resolve, reject) => {
      this._sftp.rmdir(p, (err) => (err ? reject(err) : resolve()))
    })
  }

  unlink(p) {
    return new Promise((resolve, reject) => {
      this._sftp.unlink(p, (err) => (err ? reject(err) : resolve()))
    })
  }

  rename(from, to) {
    return new Promise((resolve, reject) => {
      this._sftp.rename(from, to, (err) => (err ? reject(err) : resolve()))
    })
  }

  chmod(p, mode) {
    return new Promise((resolve, reject) => {
      this._sftp.chmod(p, mode, (err) => (err ? reject(err) : resolve()))
    })
  }

  /** Upload via fastPut */
  fastPut(localPath, remotePath) {
    return new Promise((resolve, reject) => {
      this._sftp.fastPut(localPath, remotePath, (err) => (err ? reject(err) : resolve()))
    })
  }

  fastGet(remotePath, localPath) {
    return new Promise((resolve, reject) => {
      this._sftp.fastGet(remotePath, localPath, (err) => (err ? reject(err) : resolve()))
    })
  }

  close() {
    this._closed = true
    // End the SFTP subsystem channel only (not the control connection).
    try {
      this._sftp?.end?.()
    } catch (_) {}
    this._sftp = null
  }
}

function modeString(mode, isDir) {
  const t = isDir ? 'd' : '-'
  const bits = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
  const chars = 'rwxrwxrwx'
  let s = t
  for (let i = 0; i < 9; i++) s += mode & bits[i] ? chars[i] : '-'
  return s
}

module.exports = { SFTPSession, modeString }
