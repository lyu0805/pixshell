/**
 * Generic host-tree import mapper for JSON connection entries.
 */

import { HostProfile } from '@fs/core'

export interface RawHostEntry {
  [key: string]: unknown
}

/**
 * Best-effort mapper from a generic JSON host entry into HostProfile.
 */
export function mapHostEntry(raw: RawHostEntry, index = 0): HostProfile | null {
  const host = String(raw.host || raw.hostname || raw.ip || '')
  if (!host && !raw.name) return null
  const port = Number(raw.port || raw.sshPort || 22) || 22
  const username = String(raw.user || raw.username || raw.login || 'root')
  const name = String(raw.name || raw.title || `${username}@${host}`)
  const authType =
    raw.privateKey || raw.key_path || raw.pkey ? 'key' : 'password'
  return {
    id: String(raw.id || raw.uuid || `imported_${index}_${host}_${port}`),
    name,
    host: host || '0.0.0.0',
    port,
    username,
    authType: authType as HostProfile['authType'],
    group: raw.group ? String(raw.group) : raw.folder ? String(raw.folder) : undefined,
    remark: raw.remark ? String(raw.remark) : raw.note ? String(raw.note) : undefined,
    raw: raw as Record<string, unknown>,
  }
}

// Back-compat aliases
export type RawConnEntry = RawHostEntry
export const mapConnEntry = mapHostEntry

export function mapHostList(entries: RawHostEntry[]): HostProfile[] {
  return entries
    .map((e, i) => mapHostEntry(e, i))
    .filter((x): x is HostProfile => !!x)
}

export const mapConnList = mapHostList
