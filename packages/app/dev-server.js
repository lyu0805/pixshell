/**
 * Dev entry without electron: serve renderer + note.
 * Prefer: npm start (electron)
 */
const { spawn } = require('child_process')
const path = require('path')
const fs = require('fs')

const root = path.join(__dirname, '..', '..', '..')
const electronBin = path.join(root, 'node_modules', '.bin', 'electron')
const mainJs = path.join(__dirname, 'main', 'main.js')

if (!fs.existsSync(electronBin) && !fs.existsSync(electronBin + '.cmd')) {
  console.log('electron 未安装。请先执行:')
  console.log('  cd /Volumes/d/pixshell && npm install')
  console.log('')
  console.log('临时预览像素壳:')
  console.log('  npm run dev:shell')
  // fallback static
  const serve = spawn(
    process.platform === 'win32' ? 'npx.cmd' : 'npx',
    ['--yes', 'serve@14', path.join(__dirname, 'renderer'), '-p', '4790'],
    { stdio: 'inherit', cwd: root, shell: true },
  )
  serve.on('exit', (c) => process.exit(c || 0))
} else {
  const child = spawn(electronBin, [mainJs], {
    stdio: 'inherit',
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SECURITY_WARNINGS: '1' },
  })
  child.on('exit', (c) => process.exit(c || 0))
}
