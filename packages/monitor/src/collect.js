/**
 * Monitor panels: process list, ping, sysinfo — classic-style agentless via SSH exec
 */
const MONITOR_COMMANDS = {
  load: 'cat /proc/loadavg 2>/dev/null || uptime',
  mem: "free -m 2>/dev/null | awk 'NR==2{print $2,$3,$4}'",
  disk: "df -P 2>/dev/null | head -20",
  diskRoot: "df -P / 2>/dev/null | awk 'NR==2{print $2,$3,$5}'",
  uptime: 'uptime -p 2>/dev/null || uptime',
  uname: 'uname -a',
  os: 'cat /etc/os-release 2>/dev/null | head -12',
  cpuInfo: 'nproc 2>/dev/null; grep -m1 "model name" /proc/cpuinfo 2>/dev/null',
  topProcs: "ps aux --sort=-%cpu 2>/dev/null | head -n 25",
  listeners: "ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null | head -40",
  ping: 'ping -c 4 -W 1 127.0.0.1 2>/dev/null | tail -5',
}

function parsePsAux(stdout) {
  const lines = String(stdout || '').split(/\r?\n/).slice(1)
  const rows = []
  for (const line of lines) {
    const p = line.trim().split(/\s+/)
    if (p.length < 11) continue
    rows.push({
      user: p[0],
      pid: p[1],
      cpu: p[2],
      mem: p[3],
      vsz: p[4],
      rss: p[5],
      tty: p[6],
      stat: p[7],
      start: p[8],
      time: p[9],
      command: p.slice(10).join(' '),
    })
  }
  return rows
}

/** Parse ping summary lines for avg RTT */
function parsePingAvg(stdout) {
  const s = String(stdout || '')
  // Linux: rtt min/avg/max/mdev = 0.1/0.2/0.3/0.0 ms
  let m = s.match(/=\s*([\d.]+)\/([\d.]+)\/([\d.]+)/)
  if (m) return { min: Number(m[1]), avg: Number(m[2]), max: Number(m[3]), unit: 'ms' }
  // macOS: round-trip min/avg/max/stddev = ...
  m = s.match(/min\/avg\/max[^=]*=\s*([\d.]+)\/([\d.]+)\/([\d.]+)/i)
  if (m) return { min: Number(m[1]), avg: Number(m[2]), max: Number(m[3]), unit: 'ms' }
  return null
}

function parseDfRoot(stdout) {
  // "total used 45%" or blocks
  const s = String(stdout || '').trim()
  const parts = s.split(/\s+/)
  if (parts.length >= 3) {
    return { total: parts[0], used: parts[1], usePercent: parts[2] }
  }
  return { raw: s }
}

function multiPingCommand(host, count = 3) {
  const h = String(host || '').replace(/[^a-zA-Z0-9.:_-]/g, '')
  return `ping -c ${Number(count) || 3} -W 2 ${h} 2>&1 | tail -n 3`
}

function buildMultiPingPlan(targets, count = 3) {
  const list = (targets || []).map((t) => String(t).trim()).filter(Boolean).slice(0, 20)
  return list.map((host) => ({ host, command: multiPingCommand(host, count) }))
}

function summarizeMultiPing(results) {
  // results: [{host, stdout, ok}]
  return (results || []).map((r) => {
    const stats = parsePingAvg(r.stdout || r.stderr || '')
    return {
      host: r.host,
      ok: !!stats || /bytes from|ttl=/i.test(String(r.stdout || '')),
      avgMs: stats ? stats.avg : null,
      stats,
      raw: String(r.stdout || '').trim().slice(0, 500),
    }
  })
}

function sysInfoCommands() {
  // Prefer one-shot structured script when shipped via engine.collectSysInfo.
  // Fallback multi-command list for generic exec consumers.
  return [
    'uname -a',
    'cat /etc/os-release 2>/dev/null | head -15 || cat /etc/openwrt_release 2>/dev/null',
    'hostname 2>/dev/null; uname -srm',
    'cat /proc/uptime 2>/dev/null; cat /proc/loadavg 2>/dev/null',
    'cat /proc/meminfo 2>/dev/null | head -20',
    "grep -E 'model name|Hardware|cpu model|processor|BogoMIPS|cache size|cpu MHz' /proc/cpuinfo 2>/dev/null | head -40",
    'df -h 2>/dev/null | head -15',
    'ip -o -4 addr 2>/dev/null || ifconfig 2>/dev/null | head -40',
  ]
}

/** Parse KEY=value lines from remote-sysinfo.sh */
function parseSysInfoText(text) {
  const data = {
    hostname: '-',
    osPretty: '-',
    kernelRelease: '-',
    machine: '-',
    uptime: '-',
    load: '',
    cpuModel: '-',
    cpuCount: '',
    mem: '',
    swap: '',
    ip: '',
    cpuRows: [],
    netRows: [],
    disks: [],
    raw: text,
  }
  for (const line of String(text || '').split(/\r?\n/)) {
    const s = line.trim()
    if (!s || s.indexOf('===') === 0) continue
    const eq = s.indexOf('=')
    if (eq < 0) continue
    const k = s.slice(0, eq)
    const v = s.slice(eq + 1)
    if (k === 'hostname') data.hostname = v || '-'
    else if (k === 'os_pretty') data.osPretty = v || '-'
    else if (k === 'kernel_release') data.kernelRelease = v || '-'
    else if (k === 'machine') data.machine = v || '-'
    else if (k === 'uptime' || k === 'uptime_human') data.uptime = v || data.uptime
    else if (k === 'load') data.load = v
    else if (k === 'cpu_model') data.cpuModel = v || '-'
    else if (k === 'cpu_count') data.cpuCount = v
    else if (k === 'mem') data.mem = v
    else if (k === 'swap') data.swap = v
    else if (k === 'ip') data.ip = v
    else if (k === 'cpu_row') {
      const p = v.split('\t')
      data.cpuRows.push({ id: p[0], model: p[1], mhz: p[2], cache: p[3], bogomips: p[4] })
    } else if (k === 'net_row') {
      const p = v.split('\t')
      data.netRows.push({ name: p[0], rx: p[1], tx: p[2] })
    } else if (k === 'disk') {
      const p = v.split('\t')
      data.disks.push({ mount: p[0], size: p[1], used: p[2], avail: p[3], pct: p[4], fs: p[5] })
    }
  }
  return data
}

async function collectAll(exec) {
  const out = { ts: Date.now(), raw: {} }
  for (const [k, cmd] of Object.entries(MONITOR_COMMANDS)) {
    try {
      const r = await exec(cmd)
      out.raw[k] = (r.stdout || r.stderr || '').trim()
    } catch (e) {
      out.raw[k] = 'err:' + (e.message || e)
    }
  }
  out.processes = parsePsAux(out.raw.topProcs || '')
  out.diskRoot = parseDfRoot(out.raw.diskRoot || '')
  out.load = out.raw.load
  return out
}

module.exports = {
  MONITOR_COMMANDS,
  parsePsAux,
  parsePingAvg,
  parseDfRoot,
  multiPingCommand,
  buildMultiPingPlan,
  summarizeMultiPing,
  sysInfoCommands,
  parseSysInfoText,
  collectAll,
}
