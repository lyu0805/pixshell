/**
 * SSH client facade — session API (SSHSession / Shell / SFTP / Multiplexer).
 * Runtime will use ssh2 (Node) inside Electron main/utility process.
 * This module defines the contract used by UI / SessionManager.
 */

export interface SshConnectOptions {
  host: string
  port: number
  username: string
  password?: string
  privateKey?: string
  passphrase?: string
  proxy?: {
    type: 'socks5' | 'http' | 'jump'
    host: string
    port: number
    username?: string
    password?: string
  }
  readyTimeoutMs?: number
  keepaliveIntervalMs?: number
}

export interface SshExecResult {
  code: number | null
  stdout: string
  stderr: string
}

export interface SftpEntry {
  name: string
  path: string
  isDir: boolean
  size: number
  modifyTime: number
  rights?: string
  owner?: string
  group?: string
}

export interface SshClient {
  connect(opts: SshConnectOptions): Promise<void>
  disconnect(): Promise<void>
  /** interactive shell stream — UI attaches xterm */
  shell(): Promise<AsyncIterable<Buffer> & { write(data: string | Buffer): void; resize(cols: number, rows: number): void }>
  exec(command: string): Promise<SshExecResult>
  sftpList(path: string): Promise<SftpEntry[]>
  sftpRead(path: string): Promise<Buffer>
  sftpWrite(path: string, data: Buffer): Promise<void>
  sftpMkdir(path: string): Promise<void>
  sftpRemove(path: string): Promise<void>
  /** best-effort cwd probe for classic-style sync */
  probeCwd(): Promise<string>
}

export type SshClientFactory = () => SshClient

/** Mock client for pixel shell / unit tests */
export function createMockSshClient(): SshClient {
  let cwd = '/home/deploy'
  let connected = false
  return {
    async connect() {
      connected = true
    },
    async disconnect() {
      connected = false
    },
    async shell() {
      if (!connected) throw new Error('not connected')
      const encoder = new TextEncoder()
      const queue: Buffer[] = [Buffer.from(`mock shell ready\r\n$ `)]
      const listeners: Array<(v: IteratorResult<Buffer>) => void> = []
      const push = (b: Buffer) => {
        const w = listeners.shift()
        if (w) w({ value: b, done: false })
        else queue.push(b)
      }
      const stream = {
        write(data: string | Buffer) {
          const s = typeof data === 'string' ? data : data.toString('utf8')
          if (s.includes('pwd')) push(Buffer.from(cwd + '\r\n$ '))
          else push(Buffer.from(`# mock: ${s.replace(/\r?\n/g, ' ')}\r\n$ `))
        },
        resize() {},
        async *[Symbol.asyncIterator]() {
          while (true) {
            if (queue.length) {
              yield queue.shift()!
              continue
            }
            yield await new Promise<Buffer>((resolve) => {
              listeners.push((r) => resolve(r.value as Buffer))
            })
          }
        },
      }
      return stream
    },
    async exec(command: string) {
      return { code: 0, stdout: `mock:${command}\n`, stderr: '' }
    },
    async sftpList(path: string) {
      return [
        { name: '.', path, isDir: true, size: 0, modifyTime: Date.now() },
        { name: '..', path, isDir: true, size: 0, modifyTime: Date.now() },
        { name: 'apps', path: path + '/apps', isDir: true, size: 4096, modifyTime: Date.now() },
        { name: 'logs', path: path + '/logs', isDir: true, size: 4096, modifyTime: Date.now() },
        { name: '.bashrc', path: path + '/.bashrc', isDir: false, size: 1220, modifyTime: Date.now() },
      ]
    },
    async sftpRead() {
      return Buffer.from('')
    },
    async sftpWrite() {},
    async sftpMkdir() {},
    async sftpRemove() {},
    async probeCwd() {
      return cwd
    },
  }
}
