/**
 * Batch host operations — bulk server management
 */
function filterHosts(hosts, pred) {
  return (hosts || []).filter(pred)
}

function hostsInGroup(hosts, group) {
  return filterHosts(hosts, (h) => (h.group || '默认') === group)
}

/**
 * Connect many hosts sequentially with concurrency limit
 * connectFn(host) => Promise
 */
async function batchConnect(hosts, connectFn, { concurrency = 3, onProgress } = {}) {
  const queue = [...hosts]
  const results = []
  let active = 0
  let i = 0

  return new Promise((resolve) => {
    const next = () => {
      if (!queue.length && active === 0) return resolve(results)
      while (active < concurrency && queue.length) {
        const host = queue.shift()
        active++
        const idx = i++
        Promise.resolve()
          .then(() => connectFn(host))
          .then(
            (r) => {
              results[idx] = { hostId: host.id, ok: true, result: r }
            },
            (e) => {
              results[idx] = { hostId: host.id, ok: false, error: e.message || String(e) }
            },
          )
          .finally(() => {
            active--
            if (onProgress) onProgress(results.filter(Boolean).length, hosts.length)
            next()
          })
      }
    }
    next()
  })
}

function batchDelete(hosts, ids) {
  const set = new Set(ids)
  return hosts.filter((h) => !set.has(h.id))
}

module.exports = { filterHosts, hostsInGroup, batchConnect, batchDelete }
