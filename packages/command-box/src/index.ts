/**
 * classic-style command input box logic
 * - history
 * - simple prefix completion
 * - custom param templates: echo hello ${name}
 */

export interface CommandBoxOptions {
  cleanAfterSend?: boolean
  ignoreBlankLine?: boolean
  appendCr?: boolean
  maxHistory?: number
}

export interface CompletionItem {
  label: string
  detail?: string
  /** insert text */
  insert: string
}

export class CommandBoxController {
  history: string[] = []
  private histIndex = -1
  private draft = ''
  opts: Required<CommandBoxOptions>

  constructor(opts: CommandBoxOptions = {}, initialHistory: string[] = []) {
    this.opts = {
      cleanAfterSend: opts.cleanAfterSend ?? true,
      ignoreBlankLine: opts.ignoreBlankLine ?? true,
      appendCr: opts.appendCr ?? true,
      maxHistory: opts.maxHistory ?? 500,
    }
    this.history = [...initialHistory]
  }

  /** Expand ${param} using values map */
  static expandTemplate(template: string, params: Record<string, string>): string {
    return template.replace(/\$\{([a-zA-Z0-9_]+)\}/g, (_, key) => {
      if (params[key] === undefined) return `\${${key}}`
      return params[key]
    })
  }

  prepareSend(raw: string): string | null {
    let cmd = raw
    if (this.opts.ignoreBlankLine && !cmd.trim()) return null
    if (this.opts.appendCr && !cmd.endsWith('\n') && !cmd.endsWith('\r')) {
      cmd = cmd + '\n'
    }
    const stored = raw.replace(/\r?\n$/, '')
    if (stored.trim()) {
      this.history = [stored, ...this.history.filter((h) => h !== stored)].slice(0, this.opts.maxHistory)
    }
    this.histIndex = -1
    this.draft = ''
    return cmd
  }

  /** ArrowUp */
  historyPrev(current: string): string {
    if (this.histIndex === -1) this.draft = current
    if (this.histIndex < this.history.length - 1) this.histIndex += 1
    return this.history[this.histIndex] ?? current
  }

  /** ArrowDown */
  historyNext(current: string): string {
    if (this.histIndex <= 0) {
      this.histIndex = -1
      return this.draft
    }
    this.histIndex -= 1
    return this.history[this.histIndex] ?? current
  }

  complete(prefix: string, catalog: string[]): CompletionItem[] {
    const p = prefix.trim()
    if (!p) return []
    return catalog
      .filter((c) => c.startsWith(p) || c.includes(p))
      .slice(0, 30)
      .map((c) => ({ label: c, insert: c }))
  }
}

/** Built-in command catalog seed (local) */
export const DEFAULT_COMMAND_CATALOG = [
  'ls',
  'ls -la',
  'cd',
  'pwd',
  'df -h',
  'free -m',
  'top',
  'htop',
  'ps aux',
  'netstat -lntp',
  'ss -lntp',
  'tail -f',
  'journalctl -u',
  'systemctl status',
  'docker ps',
  'kubectl get pods',
  'cat /etc/os-release',
  'uname -a',
]
