/**
 * Agentless remote monitor — collect via SSH exec (classic style).
 * Commands are Linux-oriented; later add uname branching.
 */

export interface MonitorSnapshot {
  ts: number
  cpuPercent?: number
  memUsedMb?: number
  memTotalMb?: number
  diskUsedPercent?: number
  loadavg?: string
  uptime?: string
  platform?: string
  raw?: Record<string, string>
}

export interface ProcessRow {
  user: string
  pid: string
  cpu: string
  mem: string
  command: string
}

export const MONITOR_COMMANDS = {
  load: `cat /proc/loadavg 2>/dev/null || uptime`,
  mem: `free -m 2>/dev/null | awk 'NR==2{print $2,$3}'`,
  disk: `df -P / 2>/dev/null | awk 'NR==2{print $5}'`,
  uptime: `uptime -p 2>/dev/null || uptime`,
  uname: `uname -a`,
  os: `cat /etc/os-release 2>/dev/null | head -5`,
  topProcs: `ps aux --sort=-%cpu 2>/dev/null | head -n 15`,
  pingLocal: `ping -c 1 -W 1 127.0.0.1 2>/dev/null | tail -1`,
}

export type ExecFn = (command: string) => Promise<{ stdout: string; stderr: string; code: number | null }>

export async function collectSnapshot(exec: ExecFn): Promise<MonitorSnapshot> {
  const snap: MonitorSnapshot = { ts: Date.now(), raw: {} }
  const keys = ['load', 'mem', 'disk', 'uptime', 'uname'] as const
  for (const k of keys) {
    try {
      const r = await exec(MONITOR_COMMANDS[k])
      snap.raw![k] = r.stdout.trim()
    } catch (e: any) {
      snap.raw![k] = `err:${e?.message || e}`
    }
  }
  // mem parse
  const mem = snap.raw!.mem?.split(/\s+/)
  if (mem && mem.length >= 2) {
    snap.memTotalMb = Number(mem[0]) || undefined
    snap.memUsedMb = Number(mem[1]) || undefined
  }
  const disk = snap.raw!.disk?.replace('%', '')
  if (disk && !Number.isNaN(Number(disk))) snap.diskUsedPercent = Number(disk)
  snap.loadavg = snap.raw!.load
  snap.uptime = snap.raw!.uptime
  snap.platform = snap.raw!.uname
  return snap
}

export function parsePsAux(stdout: string): ProcessRow[] {
  const lines = stdout.split(/\r?\n/).slice(1)
  const rows: ProcessRow[] = []
  for (const line of lines) {
    const parts = line.trim().split(/\s+/)
    if (parts.length < 11) continue
    rows.push({
      user: parts[0],
      pid: parts[1],
      cpu: parts[2],
      mem: parts[3],
      command: parts.slice(10).join(' '),
    })
  }
  return rows
}
