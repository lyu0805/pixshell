import { HostProfile } from './settings'

export type SessionStatus = 'idle' | 'connecting' | 'connected' | 'error' | 'closed'

export interface TerminalSession {
  id: string
  hostId: string
  title: string
  status: SessionStatus
  cwd?: string
  errorMessage?: string
  /** SFTP panel cwd — synced with terminal when enabled */
  sftpCwd?: string
  syncDirWithSftp: boolean
}

export interface SessionManagerState {
  sessions: TerminalSession[]
  activeSessionId: string | null
}

export function createSession(host: HostProfile): TerminalSession {
  return {
    id: `sess_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 7)}`,
    hostId: host.id,
    title: host.name || `${host.username}@${host.host}`,
    status: 'idle',
    syncDirWithSftp: true,
    sftpCwd: '~',
    cwd: '~',
  }
}

export class SessionManager {
  state: SessionManagerState = { sessions: [], activeSessionId: null }

  open(host: HostProfile): TerminalSession {
    const s = createSession(host)
    s.status = 'connecting'
    this.state.sessions.push(s)
    this.state.activeSessionId = s.id
    return s
  }

  setActive(id: string) {
    if (this.state.sessions.some((s) => s.id === id)) this.state.activeSessionId = id
  }

  close(id: string) {
    this.state.sessions = this.state.sessions.filter((s) => s.id !== id)
    if (this.state.activeSessionId === id) {
      this.state.activeSessionId = this.state.sessions.at(-1)?.id ?? null
    }
  }

  markConnected(id: string) {
    const s = this.state.sessions.find((x) => x.id === id)
    if (s) s.status = 'connected'
  }

  markError(id: string, message: string) {
    const s = this.state.sessions.find((x) => x.id === id)
    if (s) {
      s.status = 'error'
      s.errorMessage = message
    }
  }

  /** When terminal cwd changes, keep SFTP browser in sync */
  syncCwdFromTerminal(id: string, cwd: string) {
    const s = this.state.sessions.find((x) => x.id === id)
    if (!s) return
    s.cwd = cwd
    if (s.syncDirWithSftp) s.sftpCwd = cwd
  }

  syncCwdFromSftp(id: string, cwd: string) {
    const s = this.state.sessions.find((x) => x.id === id)
    if (!s) return
    s.sftpCwd = cwd
    if (s.syncDirWithSftp) s.cwd = cwd
  }
}
