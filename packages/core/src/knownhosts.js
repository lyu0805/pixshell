/**
 * Browser-free pure analysis page data builder is in scripts.
 * Known-hosts helpers and schema notes.
 *
 * knownhosts.json is large JSON map: host -> fingerprint/entries
 * tconfig.json: transfer server settings (udp port 150 etc)
 */

// Placeholder exporter for knownhosts import later
function summarizeKnownHosts(obj) {
  if (!obj || typeof obj !== 'object') return { count: 0 }
  const keys = Object.keys(obj)
  return {
    count: keys.length,
    sampleKeys: keys.slice(0, 20),
  }
}

module.exports = { summarizeKnownHosts }
