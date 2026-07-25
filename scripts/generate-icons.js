#!/usr/bin/env node
/**
 * Generate runtime + packaging icons from packages/app/renderer/icons/logo.png
 * and optional build/icon sources.
 *
 * Usage: node scripts/generate-icons.js
 */
'use strict'

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')
const iconsDir = path.join(root, 'packages/app/renderer/icons')
const buildDir = path.join(root, 'build')
const uiLogoPng = path.join(iconsDir, 'logo.png')
const buildIconPng = path.join(buildDir, 'icon.png')
const buildIconIcns = path.join(buildDir, 'icon.icns')

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true })
}

function copyIfExists(src, dst) {
  if (!fs.existsSync(src)) return false
  ensureDir(path.dirname(dst))
  fs.copyFileSync(src, dst)
  return true
}

function runPython(code) {
  const r = spawnSync('python3', ['-c', code], { encoding: 'utf8' })
  if (r.status !== 0) {
    console.error(r.stderr || r.stdout || 'python3 failed')
    process.exit(r.status || 1)
  }
  if (r.stdout) process.stdout.write(r.stdout)
}

ensureDir(buildDir)
ensureDir(iconsDir)

const srcPng = fs.existsSync(uiLogoPng)
  ? uiLogoPng
  : fs.existsSync(buildIconPng)
    ? buildIconPng
    : ''

if (!srcPng) {
  console.error('No logo source found. Expected', uiLogoPng, 'or', buildIconPng)
  process.exit(1)
}

if (srcPng !== uiLogoPng) copyIfExists(srcPng, uiLogoPng)

if (!fs.existsSync(buildIconIcns)) {
  console.warn('build/icon.icns missing; mac packaging may fall back to PNG')
}

const py = `
from PIL import Image
import io, os, struct
src = ${JSON.stringify(srcPng)}
build = ${JSON.stringify(buildDir)}
icons = ${JSON.stringify(iconsDir)}
img = Image.open(src).convert('RGBA')
master = img.resize((512, 512), Image.Resampling.NEAREST)
master.save(os.path.join(build, 'icon.png'), 'PNG')
rt = img.resize((256, 256), Image.Resampling.NEAREST)
rt.save(os.path.join(icons, 'app-icon.png'), 'PNG')
small = img.resize((128, 128), Image.Resampling.NEAREST)
small.save(os.path.join(icons, 'app-icon-128.png'), 'PNG')
sizes = [16, 24, 32, 48, 64, 128, 256]
pngs = []
for s in sizes:
    im = img.resize((s, s), Image.Resampling.NEAREST)
    buf = io.BytesIO()
    im.save(buf, format='PNG')
    pngs.append((s, buf.getvalue()))
offset = 6 + 16 * len(pngs)
entries = []
parts = []
for s, blob in pngs:
    w = 0 if s >= 256 else s
    h = 0 if s >= 256 else s
    entries.append(struct.pack('<BBBBHHII', w, h, 0, 0, 1, 32, len(blob), offset))
    parts.append(blob)
    offset += len(blob)
header = struct.pack('<HHH', 0, 1, len(pngs))
ico = header + b''.join(entries) + b''.join(parts)
for path in [os.path.join(build, 'icon.ico'), os.path.join(icons, 'app-icon.ico')]:
    with open(path, 'wb') as f:
        f.write(ico)
print('icons generated', {
  'src': src,
  'build_png': os.path.join(build, 'icon.png'),
  'runtime_png': os.path.join(icons, 'app-icon.png'),
  'ico_bytes': len(ico),
})
`
runPython(py)
console.log('generate-icons: ok')
