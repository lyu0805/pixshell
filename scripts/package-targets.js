/** Print package targets from shipped platform module */
const { detectPlatform, packageTargets, runtimeDataDir } = require('../packages/core/src/platform')
const path = require('path')
const os = require('os')
if (require.main === module) {
  console.log(JSON.stringify({ detect: detectPlatform(), targets: packageTargets(), dataDir: runtimeDataDir(os.homedir()) }, null, 2))
}
module.exports = { detectPlatform, packageTargets, runtimeDataDir }
