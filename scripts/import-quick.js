/**
 * Import quick commands from a JSON config into PixShell side-panel format.
 * node scripts/import-quick.js [config.json] [out.json]
 */
const fs = require('fs')
const path = require('path')
const os = require('os')

function flattenQuickCommands(groups) {
  const out = []
  for (const g of groups || []) {
    const gname = g.name || g.id || '默认'
    for (const c of g.commands || []) {
      if (c.delete_time && c.delete_time > 0) continue
      let cmd = c.command || ''
      if (c.append_cr !== false && !cmd.endsWith('\n')) cmd += '\n'
      out.push({
        id: c.id,
        name: c.name || cmd.slice(0, 24),
        command: cmd,
        group: gname,
        appendCr: c.append_cr !== false,
      })
    }
  }
  return out
}

function importFromConfig(configPath) {
  const raw = JSON.parse(fs.readFileSync(configPath, 'utf8'))
  return {
    source: configPath,
    quick: flattenQuickCommands(raw.quick_commands || []),
    proxies: (raw.proxy_list || []).map((p) => ({
      id: p.id,
      name: p.name || p.host,
      type: Number(p.type) === 100 ? 'socks5' : Number(p.type) === 200 ? 'ssh-jump' : 'socks5',
      host: p.host || '',
      port: Number(p.port) || 22,
      username: p.user_name || p.username || '',
      password: '',
      _note: 'password not imported; fill in settings if needed',
    })),
  }
}

function main() {
  const input = process.argv[2] || process.env.PIXSHELL_IMPORT_CONFIG_JSON || ''
  if (!input) {
    console.error('Usage: node scripts/import-quick.js <config.json> [out.json]')
    process.exit(1)
  }
  const out = process.argv[3] || path.join(os.tmpdir(), 'pixshell-imported-quick.json')
  const data = importFromConfig(input)
  fs.mkdirSync(path.dirname(out), { recursive: true })
  fs.writeFileSync(out, JSON.stringify(data, null, 2))
  console.log('quick', data.quick.length, 'proxies', data.proxies.length, '->', out)
}

if (require.main === module) main()
module.exports = { flattenQuickCommands, importFromConfig }
