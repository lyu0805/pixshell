/**
 * Cloud sync config shape
 */
function defaultSyncConfig() {
  return {
    modified_time: 0,
    last_pull_time: 0,
    smtp_port: 0,
    port: 0,
    last_push_ver: 0,
    ssl_enable: true,
    auto_sync: true,
    host: '',
    user: '',
    // password never logged
  }
}

function mapFromReference(raw = {}) {
  return {
    ...defaultSyncConfig(),
    ...raw,
  }
}

/** Local export/import of hosts+settings as JSON bundle (offline substitute for cloud) */
function exportBundle({ hosts, settings, quickCommands }) {
  return {
    version: 1,
    exportedAt: new Date().toISOString(),
    hosts: (hosts || []).map(({ password, ...h }) => h),
    settings: settings || {},
    quickCommands: quickCommands || [],
  }
}

function importBundle(bundle) {
  if (!bundle || bundle.version !== 1) throw new Error('unsupported bundle')
  return {
    hosts: bundle.hosts || [],
    settings: bundle.settings || {},
    quickCommands: bundle.quickCommands || [],
  }
}

module.exports = { defaultSyncConfig, mapFromReference, exportBundle, importBundle }
