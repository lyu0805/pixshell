# PixShell 原生化总蓝图（mac Swift / Windows C#）

路线 A：纯原生 ×2。前后端功能对齐现有 Electron 版（`/Volumes/d/pixshell`，renderer≈16K 行 + main≈5.7K 行）。
- mac → `mac/`（AppKit/SwiftUI + SwiftTerm，我直接掌控）
- win → `<repo>\win`（WPF + WebView2/xterm.js + SSH.NET，SSH 驱动 Windows agent 写）

## 角色
- **我(developer)**：架构 / 关键路径 / 集成 / 审核所有产出 / 端到端验证（编译+运行+截屏）
- **local-codex**：mac Swift 模块（grok-4.5）
- **win-opencode / win-codex / Hermes**：Windows C# 模块（SSH 驱动）

## 阶段
- **P0 纵向切片**：连接 + 终端 + 单会话（mac ✅ 渲染；win ✅ 编译，待运行验证 + 接 SSH）
- **P1 核心可用**：主机存储、连接管理器、多会话 tab、设置持久化、配色/高亮
- **P2 文件传输**：SFTP 双栏、传输队列、zmodem(rz/sz)
- **P3 进阶**：SOCKS 代理+隧道、监控/sysinfo 面板、命令板/快捷命令、代码编辑器
- **P4 收尾**：自动更新、cloud OAuth、agent-bridge/CLI 远控、打包签名（.app 公证 / MSIX 或自包含 exe）

## 模块拆分表

| # | 子系统 | Electron 现状 | mac(Swift) | Windows(C#) | 负责 | 阶段 |
|---|---|---|---|---|---|---|
| 1 | SSH 引擎(连接/PTY/keepalive/重连退避) | ssh-engine.js | Citadel/SwiftNIO-SSH | SSH.NET ShellStream | local-codex(mac)/win-agent | P0-P1 |
| 2 | 多会话 hub(会话复用/tab) | ssh-hub.js | SessionManager | SessionManager | 我 | P1 |
| 3 | 终端渲染 + IO 桥接 | xterm.js | SwiftTerm TerminalView | WebView2 + xterm.js | 我(集成) | P0 |
| 4 | 配色方案 + 高亮引擎 | appearance-policy + decorate | 移植高亮/主题逻辑 | 复用 xterm 侧同款 | 我 | P1 |
| 5 | 主机存储 + 凭据 | electron-store | UserDefaults/JSON+Keychain | JSON + DPAPI | local-codex/win-agent | P1 |
| 6 | 连接管理器/快连/主机编辑/分组 | renderer | AppKit 列表+编辑 | WPF 列表+编辑 | local-codex/win-agent | P1 |
| 7 | 设置界面 + 持久化 | renderer settings | SwiftUI/AppKit | WPF | local-codex/win-agent | P1 |
| 8 | SFTP 后端(浏览/传输) | main sftp | Citadel SFTP | SSH.NET Sftp | win-agent/local-codex | P2 |
| 9 | SFTP 双栏 UI | sftp-panel | AppKit | WPF | Hermes/local-codex | P2 |
| 10 | zmodem(rz/sz) | zmodem-bridge.js | Swift 实现 | C# 实现 | win-agent | P2 |
| 11 | SOCKS 代理 + 隧道 | packages/proxy | SwiftNIO | SSH.NET 端口转发 | win-agent | P3 |
| 12 | 监控 / sysinfo 面板 | remote-*.sh + UI | 面板 | 面板 | Hermes | P3 |
| 13 | 命令板 / 快捷命令 | command-box | AppKit | WPF | local-codex | P3 |
| 14 | 代码编辑器(高亮) | editor | 原生/组件 | AvalonEdit | win-agent | P3 |
| 15 | 自动更新 | app-update.js | Sparkle | Squirrel/自建 | 我 | P4 |
| 16 | cloud OAuth | cloud-oauth.js | ASWebAuthSession | WebView2 | 我 | P4 |
| 17 | agent-bridge / CLI 远控 | agent-bridge.js + cli | 移植 | 移植 | 我 | P4 |
| 18 | 打包 / 签名 | electron-builder | xcodebuild+codesign+notarize | dotnet publish+MSIX | 我 | P4 |

## 共享契约
- SSH 会话统一接口：mac 见 `Sources/PixShell/SSH/SSHSession.swift`；Windows 定义等价 `ISshSession`（连接/开PTYshell/send/resize/close + 输出回调）。
- 主机模型字段两端一致：id/name/host/port/username/auth(password|key)/group/osId。
- 配色/高亮语义键两端一致（见 Electron 版 decoratePlainChunk 的 kind 集合）。

## 当前状态（P0）
- mac：原生窗口 + SwiftTerm 彩色渲染 ✅（截屏验证）；SSH 模块实现中(local-codex)。
- win：WPF+WebView2+xterm 切片 `dotnet build` 绿 ✅；待运行验证 + 接 SSH.NET。
