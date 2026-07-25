/**
 * classic-style multi-session terminal tab bar model (renderer-agnostic)
 */
class TabController {
  constructor() {
    /** @type {{id:string,hostId:string,title:string,status:string,sessionId?:string,sftpPath:string}[]} */
    this.tabs = []
    this.activeId = null
  }

  open(host) {
    const existing = this.tabs.find((t) => t.hostId === host.id && t.status === 'connected')
    if (existing) {
      this.activeId = existing.id
      return existing
    }
    const tab = {
      id: 'tab_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 5),
      hostId: host.id,
      title: host.name || host.host,
      status: 'idle',
      sessionId: undefined,
      sftpPath: '.',
    }
    this.tabs.push(tab)
    this.activeId = tab.id
    return tab
  }

  active() {
    return this.tabs.find((t) => t.id === this.activeId) || null
  }

  setActive(id) {
    if (this.tabs.some((t) => t.id === id)) this.activeId = id
  }

  close(id) {
    this.tabs = this.tabs.filter((t) => t.id !== id)
    if (this.activeId === id) this.activeId = this.tabs.at(-1)?.id || null
  }

  update(id, patch) {
    const t = this.tabs.find((x) => x.id === id)
    if (t) Object.assign(t, patch)
    return t
  }
}

module.exports = { TabController }
