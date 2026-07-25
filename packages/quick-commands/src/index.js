/**
 * Quick command panel logic
 */
class QuickCommandPanel {
  /**
   * @param {import('@fs/core').QuickCommand[]} commands
   */
  constructor(commands = []) {
    this.commands = commands
    this.selectedGroup = ''
  }

  groups() {
    const set = new Set(this.commands.map((c) => c.group || 'default'))
    return [...set].sort()
  }

  list(group) {
    const g = group ?? this.selectedGroup
    if (!g) return this.commands
    return this.commands.filter((c) => (c.group || 'default') === g)
  }

  /**
   * Build command string from template + params
   * @param {import('@fs/core').QuickCommand} cmd
   * @param {Record<string,string>} params
   */
  render(cmd, params = {}) {
    let out = cmd.command
    for (const [k, v] of Object.entries(params)) {
      out = out.split('${' + k + '}').join(v)
    }
    // fill defaults
    for (const p of cmd.params || []) {
      if (out.includes('${' + p.name + '}') && p.defaultValue != null) {
        out = out.split('${' + p.name + '}').join(p.defaultValue)
      }
    }
    return out
  }
}

const DEMO_QUICK_COMMANDS = [
  {
    id: 'qc1',
    name: '磁盘',
    group: '系统',
    command: 'df -h',
  },
  {
    id: 'qc2',
    name: '内存',
    group: '系统',
    command: 'free -m',
  },
  {
    id: 'qc3',
    name: '进程TOP',
    group: '系统',
    command: 'ps aux --sort=-%cpu | head -20',
  },
  {
    id: 'qc4',
    name: 'Nginx 重载',
    group: '服务',
    command: 'sudo systemctl reload nginx',
  },
  {
    id: 'qc5',
    name: '看日志',
    group: '服务',
    command: 'sudo tail -n ${lines} -f ${file}',
    params: [
      { name: 'lines', defaultValue: '100' },
      { name: 'file', defaultValue: '/var/log/nginx/error.log', required: true },
    ],
  },
  {
    id: 'qc6',
    name: 'Docker PS',
    group: '容器',
    command: 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"',
  },
]

module.exports = { QuickCommandPanel, DEMO_QUICK_COMMANDS }
