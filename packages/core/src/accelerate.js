/**
 * Optional network accelerate relay config (tconfig.json).
 * Open-source client only stores config + UI slot; does NOT implement commercial protocol.
 */
function defaultAccelerateConfig() {
  return {
    enabled: false,
    protocol: 'udp',
    server_port: 150,
    direct_cn: true,
    server_host: '',
    note: 'custom accelerate relay; not a generic open protocol',
    interoperable: false,
  }
}

function mapFromTconfig(raw = {}) {
  const base = defaultAccelerateConfig()
  return {
    ...base,
    server_port: Number(raw.server_port ?? base.server_port) || 150,
    protocol: raw.protocal || raw.protocol || base.protocol,
    direct_cn: raw.direct_cn !== undefined ? !!raw.direct_cn : base.direct_cn,
    server_host: raw.server_host || raw.host || '',
    enabled: !!raw.enabled,
    interoperable: false,
    note: base.note,
  }
}

function validateAccelerateConfig(cfg) {
  const c = { ...defaultAccelerateConfig(), ...(cfg || {}) }
  const errors = []
  if (c.enabled && !c.server_host) errors.push('server_host required when enabled')
  if (c.server_port < 1 || c.server_port > 65535) errors.push('invalid server_port')
  return { ok: errors.length === 0, errors, config: c }
}

/** Connection path preference when accelerate is toggled (local policy only) */
function resolveConnectPath(hostCfg, accelerateCfg) {
  const acc = mapFromTconfig(accelerateCfg || {})
  if (!acc.enabled || !hostCfg) {
    return { mode: 'direct', host: hostCfg?.host, port: hostCfg?.port || 22, accelerate: false }
  }
  // Intentionally still direct: custom relay protocol is not implemented
  return {
    mode: 'direct-with-accelerate-flag',
    host: hostCfg.host,
    port: hostCfg.port || 22,
    accelerate: true,
    warning: acc.note,
    interoperable: false,
  }
}

module.exports = {
  defaultAccelerateConfig,
  mapFromTconfig,
  validateAccelerateConfig,
  resolveConnectPath,
}
