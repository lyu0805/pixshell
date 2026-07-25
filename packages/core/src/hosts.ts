import { HostProfile } from './settings'

/** In-memory host store — later: JSON file + host-tree import */
export class HostStore {
  hosts: HostProfile[] = []

  constructor(seed?: HostProfile[]) {
    if (seed) this.hosts = seed
  }

  list() {
    return this.hosts
  }

  upsert(host: HostProfile) {
    const i = this.hosts.findIndex((h) => h.id === host.id)
    if (i >= 0) this.hosts[i] = host
    else this.hosts.push(host)
  }

  remove(id: string) {
    this.hosts = this.hosts.filter((h) => h.id !== id)
  }

  get(id: string) {
    return this.hosts.find((h) => h.id === id)
  }
}

export const demoHosts: HostProfile[] = [
  {
    id: 'demo-local',
    name: 'demo-local',
    host: '127.0.0.1',
    port: 22,
    username: 'root',
    authType: 'password',
    group: 'lab',
    remark: '像素壳演示主机',
  },
  {
    id: 'demo-prod',
    name: 'prod-web-01',
    host: '203.0.113.10',
    port: 22,
    username: 'deploy',
    authType: 'key',
    group: 'prod',
  },
]
