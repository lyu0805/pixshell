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
    var sysInfoWindow: NSWindow?      // 系统信息独立弹窗（可拖动/缩放）
    var lastPingAt: Date = .distantPast
    var toolsPanel: ToolsPanel!        // 顶栏宫格 → 工具面板
    var backupPanel: BackupPanel!      // 备份选项独立弹窗（对齐 ConnManager）
    var editorPanel: EditorPanel!
    var detachedWindows: [DetachedTermWindow] = []   // 被拖出去的会话窗口（持有，否则 ARC 立刻回收）
    var editorWindow: NSWindow?        // 编辑器独立窗口（可拖出主窗）      // 内置文本编辑器（SFTP 双击文件打开）
    var proxyPanel: ProxyPanel!        // 代理服务器管理（菜单 选项 → 代理）
    var keyManager: KeyManager!        // 密钥管理（生成/复制公钥/用于此主机/删除）
    var fingerprintManager: FingerprintManager!  // 主机指纹（known_hosts 列表/删除）
    var aiSshBridgeManager: AiSshBridgeManager!  // AI 工具 SSH 一键注册窗口
    let proxyStore = ProxyStore()
    var editingRemotePath: String = "" // 当前编辑的远端文件路径
    var backupEnabled: Set<String> = []
    var downloadDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    var menuBtn: NSButton!
    var monTimer: Timer?
    var connectOverlay: ConnectOverlay?   // 连接动画（覆盖终端区，取代终端里那行"连接中…"文字）
    var retryPrompting = false            // 认证失败重弹密码框的去重标记

    var agentBridge: AgentBridge?      // 本地 CLI/AI-Agent 桥（127.0.0.1 + token）
    /// 无头模式：CLI 自动拉起 / 有头关闭后兜底。只跑本地桥，不建窗、无 Dock 图标；
    /// 有头打开接管时（收到 /v1/app/shutdown）退出让位。
    var isHeadless = false
    /// 无头模式下自建会话的桥宿主（有头时 AppDelegate 自己实现 BridgeHost）。
    var headlessHost: HeadlessBridgeHost?
    /// 有头模式下供 agent 使用的**独立无头会话池**：agent 的 connect/exec/screen/sftp
    /// 全部走这里自建的零 UI 会话（HeadlessSession），与用户 GUI 标签页完全隔离——
    /// agent 调用**绝不会**在界面里新开标签、不会抢控制器、不会重复开 SSH。
    var agentHeadlessHost: HeadlessBridgeHost?
    var bridgeTimer: Timer?            // 周期对齐桥状态 → 状态栏三态
    /// CLI 桥状态（与桥实现解耦：桥启动/收到鉴权请求时回填，状态栏据此显示三态）
    var bridgeStatus: (running: Bool, port: Int, clientIdle: TimeInterval?) = (false, 0, nil)

    // 命令框：历史 / 参数 / 目录同步
    var cmdHistory = CommandHistory()
    // P0：SFTP 与终端完全独立，禁止双向 cd 联动（点文件夹不再往终端灌 cd）
    var syncDirWithSftp = false

    // 配置：darkTheme 始终反映当前 Theme.dark（主题可运行时切换）。
    var darkTheme: Bool { Theme.dark }
    var highlightEnabled = true

    // MARK: - 生命周期
    func applicationDidFinishLaunching(_ note: Notification) {
        if isHeadless {
            // 无头模式：不建 UI，仅启动本地桥。GPU/主题/窗口/菜单全部跳过。
            Log.banner("0.1.8 [headless]")
            // 无头也刷新 AI SSH 桥接注册：保证 `ssh` 包装脚本内容是最新的（随 CLI 一起变）。
            // 有头时在设置页手动注册/取消；无头静默幂等刷新，已注册过就重写 wrapper 不弹窗。
            AiSshBridge.register(bridgePort: nil)
            startAgentBridge()
            return
        }
        // GPU 加速：**优先 layer-backed，失败可回落**。
        // 硬开且无兜底会在弱 GPU 场景花屏/黑屏。策略：
        // 1) 环境变量 PIXSHELL_RENDER=sw|hw 可覆盖
        // 2) 上次崩溃标记 → 本轮关掉默认 Core Animation
        // 3) 正常路径 register NSViewDefaultUsesCoreAnimation=true（可被 1/2 覆盖）
        configureGpuAcceleration()
        Log.banner("0.1.8")
        Log.info("主题=\(Theme.dark ? "深色" : "浅色")（来源：env/持久化/默认）", "ui")
        NSApp.appearance = NSAppearance(named: darkTheme ? .darkAqua : .aqua)
        AppIcon.install()    // 没有 .app bundle 就没有图标资源，所有系统弹窗会退化成"蓝色文件夹"占位图
        buildMainMenu()
        buildWindow()
        // macOS 15+：启动即触发「本地网络」系统弹窗（不能静默写 TCC，只能主动要一次）
        LocalNetworkAuth.requestAuthorizationIfNeeded()
        maybeSeedAndAutoConnect()
        startAgentBridge()   // 本地桥：仅 127.0.0.1，token 鉴权
        // 启动 8 秒仍存活 → 清崩溃标记（说明本轮 GPU 路径 OK）
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            Self.clearGpuCrashFlagIfNeeded()
        }
    }

    /// GPU 偏好与崩溃回落。标记文件：Application Support/PixShell/gpu-fallback.flag
    private func configureGpuAcceleration() {
        let env = (ProcessInfo.processInfo.environment["PIXSHELL_RENDER"] ?? "").lowercased()
        let flagURL: URL = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let dir = base.appendingPathComponent("PixShell", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("gpu-fallback.flag")
        }()
        Self._gpuFlagURL = flagURL

        let forceSw = env == "sw" || env == "software" || env == "soft"
        let forceHw = env == "hw" || env == "hardware" || env == "gpu"
        let hadCrash = FileManager.default.fileExists(atPath: flagURL.path)

        if forceSw || (!forceHw && hadCrash) {
            // 软件兜底：不要 register 默认 CA；各视图仍可自行 wantsLayer，但不全局强开
            UserDefaults.standard.set(false, forKey: "NSViewDefaultUsesCoreAnimation")
            Log.info("GPU：软件兜底 (env=\(env.isEmpty ? "auto" : env), crashFlag=\(hadCrash))", "ui")
            Self._gpuUsingFallback = true
        } else {
            UserDefaults.standard.register(defaults: [
                "NSViewDefaultUsesCoreAnimation": true,
            ])
            Log.info("GPU：Core Animation 优先 (失败将写回落标记)", "ui")
            Self._gpuUsingFallback = false
        }

        // 捕获下一次异常信号式崩溃不够（那是信号），这里挂 NSSetUncaughtExceptionHandler 写标记
        NSSetUncaughtExceptionHandler { exc in
            AppDelegate.markGpuCrash(reason: exc.reason ?? exc.name.rawValue)
        }
    }

    /// 跨文件可读：Layout 根据此开关决定是否开 drawsAsynchronously。
    static var _gpuFlagURL: URL?
    static var _gpuUsingFallback = false

    static func markGpuCrash(reason: String) {
        guard !_gpuUsingFallback, let url = _gpuFlagURL else { return }
        let body = "\(ISO8601DateFormatter().string(from: Date()))\n\(reason)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        Log.warn("已写 GPU 回落标记，下次启动将关闭默认 Core Animation", "ui")
    }

    static func clearGpuCrashFlagIfNeeded() {
        guard !_gpuUsingFallback, let url = _gpuFlagURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 无头进程收到 reopen（用户 Finder 双击 / `open -a`）：说明想打开界面。
    /// 无头是 .accessory 不建窗，`open -a` 又只激活已运行实例（不会新启有头），
    /// 所以这里必须自己退出并重新拉起**有头**，否则用户双击看起来"没反应"。
    /// 注意：`open -a` 在无头还活着时只会发 reopen 死循环，必须先 terminate 等退出再 open。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard isHeadless else { return true }
        // 无头进程收到 reopen（用户 Finder 双击 / `open -a`）：说明想打开界面。
        // 无头是 .accessory 不建窗，`open -a` 只激活已运行实例不会新启有头，双击会"没反应"。
        // 解决：用 `open -n` 强制**新实例**启动有头（绕过 LaunchServices 实例复用，不依赖 terminate 时序）。
        // 新有头启动后走 waitForHeadlessToYield → 让本无头退出（onPortBusy 让位）→ 接管主端口。
        Log.info("无头收到 reopen（用户想开界面）→ open -n 拉起新有头实例", "ui")
        let appPath = Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : ""
        let args: [String] = appPath.isEmpty ? ["-n", "-a", "PixShell"] : ["-n", appPath]
        AgentBridge.spawnOpenApp(args)
        return false
    }

    // MARK: - 通用小工具（供各扩展复用）
    func setStatus(_ s: String) { statusRight?.stringValue = s }
}

// MARK: - 入口
setbuf(stdout, nil)   // 关掉 stdout 缓冲，便于观察 print（自测/调试）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 无头模式（--headless，CLI 自动拉起/有头关闭后兜底）：不注册 Dock/菜单栏图标、不建窗，
// 仅跑本地桥供 MCP/CLI 后台调用；有头打开时接管并让它退出。默认有头。
delegate.isHeadless = CommandLine.arguments.contains("--headless")
app.setActivationPolicy(delegate.isHeadless ? .accessory : .regular)
app.run()
