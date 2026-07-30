import Foundation

/// 极薄 i18n：中英对照表 + 系统语言跟随。
/// v0.1.x 不全量搬硬编码；先铺基础设施和关键 chrome，后续按模块迁。
///
/// 用法：`L10n.t("menu.file")` / `L10n.t("editor.save")`
/// - 当前语言取 `Locale.preferredLanguages` 首项；zh* → 中文，其它 → 英文。
/// - 缺 key 回落英文，再缺回落 key 本身（方便扫漏）。
enum L10n {
    enum Lang: String { case zh, en }

    /// 可强制覆盖（调试/测试）；nil = 跟随系统。
    static var override: Lang? = nil

    static var lang: Lang {
        if let o = override { return o }
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if pref.hasPrefix("zh") { return .zh }
        return .en
    }

    static func t(_ key: String) -> String {
        if lang == .zh, let s = zh[key] { return s }
        if let s = en[key] { return s }
        if let s = zh[key] { return s } // en 缺时回落中文（产品默认中文优先）
        return key
    }

    // MARK: - 表（只放 chrome / 高频；业务大段文案仍可硬编码）

    private static let en: [String: String] = [
        // 菜单
        "menu.file": "File",
        "menu.edit": "Edit",
        "menu.view": "View",
        "menu.window": "Window",
        "menu.help": "Help",
        "menu.keys": "Key Manager…",
        "menu.fingerprints": "Host Fingerprints…",
        "menu.backup": "Backup Options…",
        "menu.quit": "Quit PixShell",
        // 通用
        "common.ok": "OK",
        "common.cancel": "Cancel",
        "common.close": "Close",
        "common.save": "Save",
        "common.delete": "Delete",
        "common.refresh": "Refresh",
        "common.copy": "Copy",
        "common.error": "Error",
        "common.warning": "Warning",
        // 编辑器
        "editor.title": "Editor",
        "editor.save": "Save",
        "editor.close": "Close",
        "editor.find": "Find",
        "editor.replace": "Replace",
        "editor.replaceAll": "Replace All",
        "editor.lineNumbers": "Line numbers",
        "editor.wrap": "Wrap lines",
        "editor.dirty": "Modified",
        "editor.saving": "Saving…",
        "editor.saved": "Saved",
        "editor.saveFailed": "Save failed",
        "editor.modifiedTitle": "File modified",
        "editor.modifiedBody": "Save changes to “%@”?",
        "editor.discard": "Don’t Save",
        // 密钥
        "keys.title": "Key Manager",
        "keys.generate": "Generate Key",
        "keys.copyPub": "Copy Public Key",
        "keys.useForHost": "Use for This Host",
        "keys.delete": "Delete",
        "keys.refresh": "Refresh",
        "keys.empty": "No keys under ~/.ssh — click Generate",
        "keys.genTitle": "Generate SSH Key",
        "keys.genBody": "Creates a standard key pair in ~/.ssh via system ssh-keygen.",
        "keys.gen": "Generate",
        // 命令板
        "cmd.title": "Commands",
        "cmd.all": "All",
        "cmd.new": "New",
        "cmd.send": "Send",
        "cmd.sendTo": "Send to",
        "cmd.current": "Current session",
        "cmd.allConnected": "All connected sessions",
        "cmd.collapse": "Collapse",
        "cmd.expand": "Expand",
        "cmd.history": "History",
        "cmd.options": "Options",
        "cmd.editor": "Command editor",
        // 连接
        "conn.quick": "Quick Connect",
        "conn.connect": "Connect",
        "conn.disconnect": "Disconnect",
        "conn.hosts": "Hosts",
        "conn.local": "Local Terminal",
        // 桥 / Web
        "web.missingToken": "Missing token. Open from PixShell → New → Web, or append ?token=…",
        "web.bridgeDown": "Bridge unreachable",
        // 状态
        "status.ready": "Ready",
        "status.connecting": "Connecting…",
        "status.connected": "Connected",
        "status.disconnected": "Disconnected",
    ]

    private static let zh: [String: String] = [
        "menu.file": "文件",
        "menu.edit": "编辑",
        "menu.view": "查看",
        "menu.window": "窗口",
        "menu.help": "帮助",
        "menu.keys": "密钥管理…",
        "menu.fingerprints": "主机指纹管理…",
        "menu.backup": "备份选项…",
        "menu.quit": "退出 PixShell",
        "common.ok": "确定",
        "common.cancel": "取消",
        "common.close": "关闭",
        "common.save": "保存",
        "common.delete": "删除",
        "common.refresh": "刷新",
        "common.copy": "复制",
        "common.error": "错误",
        "common.warning": "警告",
        "editor.title": "编辑器",
        "editor.save": "保存",
        "editor.close": "关闭",
        "editor.find": "查找",
        "editor.replace": "替换",
        "editor.replaceAll": "全部替换",
        "editor.lineNumbers": "行号",
        "editor.wrap": "自动换行",
        "editor.dirty": "已修改",
        "editor.saving": "保存中…",
        "editor.saved": "已保存",
        "editor.saveFailed": "保存失败",
        "editor.modifiedTitle": "文件已修改",
        "editor.modifiedBody": "是否保存对“%@”的更改？",
        "editor.discard": "放弃",
        "keys.title": "密钥管理",
        "keys.generate": "＋生成密钥",
        "keys.copyPub": "复制公钥",
        "keys.useForHost": "用于此主机",
        "keys.delete": "删除",
        "keys.refresh": "刷新",
        "keys.empty": "~/.ssh 下没有找到密钥 —— 点「＋生成密钥」新建一个",
        "keys.genTitle": "生成 SSH 密钥",
        "keys.genBody": "会在 ~/.ssh 下用系统 ssh-keygen 生成标准密钥对。",
        "keys.gen": "生成",
        "cmd.title": "命令",
        "cmd.all": "全部",
        "cmd.new": "新建",
        "cmd.send": "发送",
        "cmd.sendTo": "发送到",
        "cmd.current": "当前会话",
        "cmd.allConnected": "所有已连接会话",
        "cmd.collapse": "⟩ 收起",
        "cmd.expand": "⟨ 展开",
        "cmd.history": "历史",
        "cmd.options": "选项",
        "cmd.editor": "命令编辑器",
        "conn.quick": "快速连接",
        "conn.connect": "连接",
        "conn.disconnect": "断开",
        "conn.hosts": "主机",
        "conn.local": "本地终端",
        "web.missingToken": "缺少 token。请从「新建连接 → Web」连接，或附加 ?token=…",
        "web.bridgeDown": "桥不可达",
        "status.ready": "就绪",
        "status.connecting": "连接中…",
        "status.connected": "已连接",
        "status.disconnected": "已断开",
    ]
}
