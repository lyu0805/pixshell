/**
 * Proxy list model — referenceClient proxy_list compatible
 */
function createProxy(p = {}) {
  return {
    id: p.id || 'px_' + Date.now().toString(36),
    name: p.name || 'proxy',
    type: normalizeProxyType(p.type),
    host: p.host || '',
    port: Number(p.port) || defaultPort(normalizeProxyType(p.type)),
    username: p.username || p.user_name || '',
    password: p.password || '',
  }
}

function normalizeProxyType(t) {
  if (t === 100 || t === '100') return 'socks5'
  if (t === 200 || t === '200') return 'ssh-jump'
  if (t === 'socks4' || t === 'socks5' || t === 'http' || t === 'ssh-jump') return t
  return 'socks5'
}

function defaultPort(type) {
  if (type === 'http') return 8080
  if (type === 'ssh-jump') return 22
  return 1080
}

function mapFromReferenceProxy(p = {}) {
  return createProxy({
    id: p.id,
    name: p.name || p.host,
    type: p.type,
    host: p.host,
    port: p.port,
    username: p.user_name || p.username,
    password: p.password || '',
  })
}

function toSsh2Proxy(proxy) {
  if (!proxy || !proxy.host) return undefined
  const type = normalizeProxyType(proxy.type)
  if (type === 'socks5' || type === 'socks4') {
    return {
      type,
      host: proxy.host,
      port: Number(proxy.port) || 1080,
      username: proxy.username || undefined,
      password: proxy.password || undefined,
    }
  }
  if (type === 'http') {
    return {
      type: 'http',
      host: proxy.host,
      port: Number(proxy.port) || 8080,
      username: proxy.username || undefined,
      password: proxy.password || undefined,
    }
  }
  if (type === 'ssh-jump') {
    return {
      type: 'ssh-jump',
      host: proxy.host,
      port: Number(proxy.port) || 22,
      username: proxy.username || undefined,
      password: proxy.password || undefined,
    }
  }
  return undefined
}

function validateProxy(proxy) {
  const p = createProxy(proxy || {})
  const errors = []
  if (!p.host) errors.push('host required')
  if (!p.port || p.port < 1 || p.port > 65535) errors.push('invalid port')
  return { ok: errors.length === 0, errors, proxy: p }
}

function findProxyById(list, id) {
  if (!id || id === '0') return null
  return (list || []).find((p) => p.id === id) || null
}

module.exports = {
  createProxy,
  normalizeProxyType,
  mapFromReferenceProxy,
  toSsh2Proxy,
  validateProxy,
  findProxyById,
  defaultPort,
}
