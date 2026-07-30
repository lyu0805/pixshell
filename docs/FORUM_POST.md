PixShell SSH工具,服务器管理软件,支持Windows,macOS,版本0.1.3,更新日期2026.7.30

PixShell 是面向运维与 AI 工作流的原生跨平台 SSH / SFTP 桌面客户端，不依赖 Electron，极简高效。

特色功能:
双端原生渲染、AI Agent Bridge、无头模式交互、一键接管 ssh、Web SSH 网页终端、OpenWrt/Dropbear 专门兼容、本地加密凭据免弹窗、一键数据迁移、文件权限修改、打包传输自动解压清理。

下载地址:
macOS Arm64版 (Apple Silicon):
https://github.com/lyu0805/pixshell/releases/download/v0.1.3/PixShell-0.1.2-mac-arm64.dmg
macOS X64版 (Intel):
https://github.com/lyu0805/pixshell/releases/download/v0.1.3/PixShell-0.1.2-mac-x64.dmg
Windows X64版 安装包:
https://github.com/lyu0805/pixshell/releases/download/v0.1.3/PixShell-0.1.2-win-x64-setup.exe
Windows X64版 绿色版:
https://github.com/lyu0805/pixshell/releases/download/v0.1.3/PixShell-0.1.2-win-x64.zip

项目主页:
https://github.com/lyu0805/pixshell

更新日志:
https://github.com/lyu0805/pixshell/releases/tag/v0.1.3

主要特性:
1. 多平台原生支持 Windows, macOS（Mac: AppKit+SwiftTerm; Win: WPF+WebView2+xterm.js），零 Electron 臃肿。
2. 多标签，批量服务器管理。
3. 终端，SFTP 同屏显示，同步切换目录。
4. AI 工具交互支持：内置 HTTP Agent Bridge (127.0.0.1:8766)，支持 MCP Server 与无头 (Headless) 模式驱动持久会话。
5. AI SSH 自动注册：一键检测并注册为系统默认 SSH 包装工具 (pixshell-ssh)，让 Claude Code / Codex / Grok 等无缝接管。
6. Web SSH 网页终端：内置轻量 xterm.js 浏览器终端接口 (GET /webssh)。
7. OpenWrt / Dropbear 兼容：专有算法支持 (CTR/Chacha20/RSA) 及 SFTP PTY 伪终端回落。
8. 零弹窗打扰：采用本地 credentials.dat 加密存储，无 Keychain / 本地网络授权弹窗打扰。
9. 一键数据迁移：自动扫描解密导入第三方 SSH 客户端保存的主机及密码。
10. 文件权限修改 (Chmod)：9 项读写执复选框、八进制显示、递归设置子目录与类型过滤，支持窗口拖动与随意缩放。
11. 打包传输：大文件与目录自动压缩传输、目标端自动解压并清理两端临时包。
12. 主机指纹管理：已知主机 known_hosts 查看、单条删除、导入与导出备份。
13. 内置文本编辑器：支持远程文本编辑、查找、替换与一键保存回写。
14. 命令输入框快捷键：完整支持全选 (Cmd+A/Ctrl+A)、剪切、复制、粘贴与 Esc 焦点切换。
15. 服务器性能与网络实时监控：CPU、内存、磁盘及网卡实时上下行速率。
16. 密钥与代理支持：密码/私钥认证，SOCKS5 / HTTP 代理。
17. 内置应用内本机 Shell 终端：一键打开本地 Shell 标签页，无需唤起外部终端。

界面截图:

暗色模式 / 淡色模式
![暗色模式](docs/assets/screenshots/dark-theme.png) ![淡色模式](docs/assets/screenshots/light-theme.png)

主机管理 / 新建连接
![主机管理](docs/assets/screenshots/connection-manager.png) ![新建连接](docs/assets/screenshots/new-connection.png)

快速连接历史 / 收起侧边栏
![快速连接历史](docs/assets/screenshots/quick-connect-history.png) ![收起侧边栏](docs/assets/screenshots/sidebar-collapsed.png)

AI 工具交互 / 对接 MCP 本地 CLI
![AI 工具交互](docs/assets/screenshots/ai-interaction.png) ![对接 MCP 本地 CLI](docs/assets/screenshots/mcp-cli-bridge.png)

文本编辑器 / 下载管理
![文本编辑器](docs/assets/screenshots/text-editor.png) ![下载管理](docs/assets/screenshots/download-manager.png)

密钥管理 / 云备份
![密钥管理](docs/assets/screenshots/key-manager.png) ![云备份](docs/assets/screenshots/cloud-backup.png)
