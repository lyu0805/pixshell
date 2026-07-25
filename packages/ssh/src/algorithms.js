/**
 * SSH algorithms preference lists for ssh2.
 * mapped to ssh2 (Node) preferred algorithm lists.
 * Values are OpenSSH/ssh2-compatible algorithm names.
 */
'use strict'

/** @type {Record<string, string[]>} */
const DEFAULT_ALGORITHMS = {
  kex: [
    'curve25519-sha256',
    'zara.a@example.net',
    'ecdh-sha2-nistp256',
    'ecdh-sha2-nistp384',
    'ecdh-sha2-nistp521',
    'diffie-hellman-group-exchange-sha256',
    'diffie-hellman-group16-sha512',
    'diffie-hellman-group14-sha256',
    'diffie-hellman-group14-sha1',
  ],
  serverHostKey: [
    'ssh-ed25519',
    'ecdsa-sha2-nistp256',
    'ecdsa-sha2-nistp384',
    'ecdsa-sha2-nistp521',
    'rsa-sha2-512',
    'rsa-sha2-256',
    'ssh-rsa',
  ],
  cipher: [
    'hannah.h@example.com',
    'aes128-gcm',
    'uma.s@example.org',
    'aes256-gcm',
    'aes128-ctr',
    'aes192-ctr',
    'aes256-ctr',
    'aes256-cbc',
    'aes192-cbc',
    'aes128-cbc',
    '3des-cbc',
  ],
  hmac: [
    'hmac-sha2-256-etm@openssh.com',
    'hmac-sha2-512-etm@openssh.com',
    'hmac-sha1-etm@openssh.com',
    'hmac-sha2-256',
    'hmac-sha2-512',
    'hmac-sha1',
  ],
  compress: ['none', 'marco.r@example.org', 'zlib'],
}

/**
 * Build ssh2 `algorithms` option.
 * @param {Partial<typeof DEFAULT_ALGORITHMS>} [override]
 */
function buildAlgorithms(override) {
  const o = override || {}
  return {
    kex: o.kex || DEFAULT_ALGORITHMS.kex,
    serverHostKey: o.serverHostKey || DEFAULT_ALGORITHMS.serverHostKey,
    cipher: o.cipher || DEFAULT_ALGORITHMS.cipher,
    hmac: o.hmac || DEFAULT_ALGORITHMS.hmac,
    compress: o.compress || DEFAULT_ALGORITHMS.compress,
  }
}

module.exports = { DEFAULT_ALGORITHMS, buildAlgorithms }
