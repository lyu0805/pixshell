import AppKit
import SwiftTerm

// PixShell macOS 原生端入口 + 主控制器（AppDelegate）。
// 职责按文件拆分（模块化，避免单文件屎山）：
//   main.swift              — 类声明 + 状态 + 生命周期 + 入口
//   App/AppDelegate+Layout.swift    — 五区布局构建 + 底部坞切换 + 侧栏折叠
//   App/AppDelegate+Hosts.swift     — 主机增改删 + 侧栏列表数据源
//   App/AppDelegate+Sessions.swift  — 多会话开/切/关 + SSH/终端 delegate
// 布局照搬 Electron 老仓库(docs/LAYOUT-PARITY.md)：顶栏 / 侧栏 | 工作区[终端+底部坞] / 状态栏。
final class AppDelegate: NSObject, NSApplicationDelegate, TerminalViewDelegate, SSHSessionDelegate,
                         NSTableViewDataSource, NSTableViewDelegate {
    // 顶层
    var window: NSWindow!
    let store = HostStore()
    var mainRow: NSView!               // 侧栏 | 分隔条 | 工作区
    var sideWrap: NSView!              // 侧栏容器（宽度可收到 0）
    var sideWidthC: NSLayoutConstraint!
    var monitorWidthC: NSLayoutConstraint!
    var sidebarWidth: CGFloat = 210

    // 侧栏 / 状态栏
    var tableView: NSTableView!
    var statusLabel: NSTextField!

    // 设置项 UI 弱引用
    weak var settingsHlWell: NSColorWell?
    weak var settingsPlainWell: NSColorWell?

    // 会话 + 顶栏 tab + 终端容器
    var sessions: [TermSession] = []
    var current: Int = -1
    var tabBar: FlowView!              // 标签栏：排满自动折行（最多 2 行，再多就滚动）
    var termContainer: NSView!
    var placeholder: NSTextField!
    var quickConnect: QuickConnect!   // 快速连接/历史 落地页（无活动会话时占据工作区）

    // 底部坞
    var bottomBody: NSView!
    var filesTab: NSButton!
    var cmdsTab: NSButton!
    var sftpPanel: SFTPPanel!
    var cmdPanel: CommandPanel!
    var dockView: NSView!              // 整个 文件/命令 坞（tab行 + 面板体）
    var dockHeightC: NSLayoutConstraint!  // 坞总高（折叠=0，整块消失）
    /// 坞展开时的高度（可拖拽调整，持久化到 UserDefaults）
    var dockHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "pixshell.bottomHeight")
        return CGFloat(saved >= 200 ? saved : 340)   // 低于 200 视为无效（tab 行会被挤没）
    }()
    var dockCollapsed = false          // 坞是否折叠
    var dockToggleBtn: IconButton!     // 命令栏右侧 ▾/▴（隐藏/显示整个坞）
    var fileOps: NSStackView!          // 坞行右侧文件操作图标组（仅「文件」tab 显示）
    var chatBtn: IconButton!           // 坞行机器人图标：切换 本地文件 / 与本机 agent 对话
    var dockPathLabel: NSTextField!    // 坞行内远端路径
    var sideCollapsed = false          // 侧栏是否折叠
    var sidebarEdge: NSView!           // 侧栏折叠后的「⟩ 侧栏」竖条

    // 顶栏图标按钮 / 命令栏 / 状态栏
    var newTabBtn: NSButton!
    var cmdInput: NSTextField!
    var statusDot: Dot!
    var statusRight: NSTextField!

    // 监控侧栏 + 连接管理器弹窗 + 系统信息页 + 监控定时器
    var monitor: MonitorSidebar!
    var connMgr: ConnManager!
    var sysInfo: SysInfoPanel!
    var toolsPanel: ToolsPanel!        // 顶栏宫格 → 工具面板
    var backupPanel: BackupPanel!      // 菜单 云端同步 → 备份选项
    var editorPanel: EditorPanel!
    var detachedWindows: [DetachedTermWindow] = []   // 被拖出去的会话窗口（持有，否则 ARC 立刻回收）
    var editorWindow: NSWindow?        // 编辑器独立窗口（可拖出主窗）      // 内置文本编辑器（SFTP 双击文件打开）
    var proxyPanel: ProxyPanel!        // 代理服务器管理（菜单 选项 → 代理）
    var keyManager: KeyManager!        // 密钥管理（生成/复制公钥/用于此主机/删除）
    let proxyStore = ProxyStore()
    var editingRemotePath: String = "" // 当前编辑的远端文件路径
    var backupEnabled: Set<String> = []
    var downloadDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    var menuBtn: NSButton!
    var monTimer: Timer?
    var connectOverlay: ConnectOverlay?   // 连接动画（覆盖终端区，取代终端里那行"连接中…"文字）
    var retryPrompting = false            // 认证失败重弹密码框的去重标记

    var agentBridge: AgentBridge?      // 本地 CLI/AI-Agent 桥（127.0.0.1 + token）
    var bridgeTimer: Timer?            // 周期对齐桥状态 → 状态栏三态
    /// CLI 桥状态（与桥实现解耦：桥启动/收到鉴权请求时回填，状态栏据此显示三态）
    var bridgeStatus: (running: Bool, port: Int, clientIdle: TimeInterval?) = (false, 0, nil)

    // 命令框：历史 / 参数 / 目录同步
    var cmdHistory = CommandHistory()
    var syncDirWithSftp = true         // 老仓库 settings.syncDirWithSftp 默认开

    // 配置：darkTheme 始终反映当前 Theme.dark（主题可运行时切换）。
    var darkTheme: Bool { Theme.dark }
    var highlightEnabled = true

    // MARK: - 生命周期
    func applicationDidFinishLaunching(_ note: Notification) {
        Log.banner("0.1.0")
        Log.info("主题=\(Theme.dark ? "深色" : "浅色")（来源：env/持久化/默认）", "ui")
        NSApp.appearance = NSAppearance(named: darkTheme ? .darkAqua : .aqua)
        AppIcon.install()    // 没有 .app bundle 就没有图标资源，所有系统弹窗会退化成"蓝色文件夹"占位图
        buildMainMenu()
        buildWindow()
        maybeSeedAndAutoConnect()
        startAgentBridge()   // 本地桥：仅 127.0.0.1，token 鉴权
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - 通用小工具（供各扩展复用）
    func setStatus(_ s: String) { statusRight?.stringValue = s }
}

// MARK: - 入口
setbuf(stdout, nil)   // 关掉 stdout 缓冲，便于观察 print（自测/调试）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
