/**
 * Pack transfer + compress helpers
 */
function shellQuote(p) {
  return `'${String(p).replace(/'/g, `'\\''`)}'`
}

function defaultPackName(prefix = 'fs_pack', date = new Date()) {
  const p = (n) => String(n).padStart(2, '0')
  return `${prefix}_${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}_${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}.tgz`
}

function packCommand(format, remotePaths, outName) {
  const list = (remotePaths || []).map(shellQuote).join(' ')
  if (!list) throw new Error('no paths')
  const out = shellQuote(outName || defaultPackName(format === 'zip' ? 'fs_pack' : 'fs_pack').replace(/\.tgz$/, format === 'zip' ? '.zip' : '.tgz'))
  if (format === 'zip') return `zip -r ${out} ${list} && ls -la ${out}`
  return `tar -czf ${out} ${list} && ls -la ${out}`
}

async function remoteTarCreate(exec, remotePaths, outTar) {
  const cmd = packCommand('tar', remotePaths, outTar)
  return exec(cmd)
}

async function remoteTarExtract(exec, tarPath, destDir) {
  const t = shellQuote(tarPath)
  const d = shellQuote(destDir || '.')
  return exec(`mkdir -p ${d} && tar -xzf ${t} -C ${d} && echo OK`)
}

async function remoteZipCreate(exec, remotePaths, outZip) {
  const cmd = packCommand('zip', remotePaths, outZip)
  return exec(cmd)
}

module.exports = {
  remoteTarCreate,
  remoteTarExtract,
  remoteZipCreate,
  defaultPackName,
  packCommand,
  shellQuote,
}
