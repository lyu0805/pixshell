# PixShell v0.1.2 | 双端原生 SSH / SFTP 客户端

分享一个面向运维与 AI 工作流开发的桌面 SSH / SFTP 客户端：**PixShell**。

项目自 v0.1.1 起重构为 macOS（AppKit）与 Windows（WPF）双端原生应用（同一 monorepo），不依赖 Electron。当前版本为 **v0.1.2**。

- 仓库地址：[https://github.com/lyu0805/pixshell](https://github.com/lyu0805/pixshell)
- Releases：[https://github.com/lyu0805/pixshell/releases](https://github.com/lyu0805/pixshell/releases)

---

## 项目结构与技术选型

| 平台 | UI 框架 | 终端渲染 | SSH / SFTP 实现 |
| --- | --- | --- | --- |
| 🍎 **macOS** | Swift / AppKit | **SwiftTerm**（原生渲染） | SwiftNIO + 自研 SFTP v3 |
| 🪟 **Windows** | C# **WPF** | **WebView2** + **xterm.js** | SSH.NET |

注：macOS 端不内置 xterm.js，终端走 SwiftTerm 原生渲染；Windows 端走 WebView2 内嵌 xterm.js。

---

## 主要功能与特性介绍

### 1. AI MCP & Agent Bridge（AI 工具集成）

为了配合 Claude Code、Codex、Grok、OpenCode、Cursor、Windsurf、Ollama 等 AI 工具或自动化脚本操作服务器，PixShell 内置了本地 Agent 桥与 AI 支持：

- **本地 HTTP Agent Bridge**：默认监听 `127.0.0.1:8766`，提供 REST API 与 MCP Server 接口。
- **无头模式 (Headless) 交互**：外部 AI 工具可通过 Agent 桥驱动 PixShell 中已建立的持久交互式 SSH 会话，不需要每条指令都重新建立一次新的 SSH 连接。
- **一键注册为默认 SSH 包装工具 (`pixshell-ssh`)**：汉堡菜单提供独立配置窗口，可自动检测本机已安装的 AI CLI 工具与桌面应用，一键注册/取消注册为系统的默认交互式 SSH 引擎。
- **Web SSH 网页终端**：提供 `GET /webssh` 网页终端路由（基于 xterm.js 与本地桥），可在默认浏览器中打开并操作当前会话。

### 2. SSH 协议与设备兼容

针对嵌入式设备、路由器及老旧系统进行了协议适配：

- **OpenWrt / Dropbear 支持**：包含 CTR、Chacha20、RSA 等算法分支与 OpenSSH fallback 尝试，解决部分 OpenWrt / Dropbear 设备连接拒绝问题。
- **SFTP PTY 伪终端回落**：对未开启或缺少 `subsystem sftp` 的设备，可自动回落至 PTY 伪终端通道，并兼容常见 `sftp-server` 路径（如 `/usr/libexec/sftp-server`、`/usr/lib/sftp-server`）。

### 3. 凭据存储与交互体验

- **本地加密凭据存储**：口令采用本地加密文件 `credentials.dat` 保存，不频繁调用 macOS Keychain 授权框。
- **取消模态打扰**：去掉了网络断开时的「本地网络权限」误弹模态框，保障连接过程连续。

### 4. FinalShell 配置迁移

针对 FinalShell 用户提供了自动迁移工具：

- **一键扫描与解密**：可自动扫描本地 FinalShell 保存的主机与密码配置，解密后批量导入至 PixShell。
- 实测支持 50 台主机及 48 个保存口令的批量导入。

### 5. SFTP 权限修改与打包传输

- **文件权限修改窗口 (`ChmodWindow`)**：SFTP 右键「文件权限...」弹窗，提供所有者 (Owner)、组 (Group)、其他 (Other) 9 项读写执行复选框、八进制数值显示（如 `0755`）、递归设置子目录以及按文件/目录类型过滤应用。窗口支持拖动与随意拉伸缩放，配色跟随主题。
- **打包传输 (`✓ 打包传输`)**：SFTP 右键提供打包传输开关（默认开启）。开启时传输大文件或目录会自动在源端打包、传输、目标端解压并自动清理两端生成的临时压缩包。

### 6. 主机指纹管理 (Host Fingerprint Manager)

- 提供独立的指纹管理窗口，可查看 `known_hosts` 条目、单条删除指纹，并支持指纹文件的**导入**与**导出**备份。

### 7. 基础终端与传输功能

- **多标签页 SSH 会话**：支持标签页切换、重连、PTY 尺寸同步。
- **应用内本机终端**：快速连接 Logo 可直接在应用内打开本地 Shell 标签页（Mac `LocalSession` / Win 重定向 cmd·PowerShell），无需拉起外部终端应用。
- **快捷键支持**：输入框完整支持全选 (Cmd+A/Ctrl+A)、剪切 (Cmd+X/Ctrl+X)、复制 (Cmd+C/Ctrl+C)、粘贴 (Cmd+V/Ctrl+V) 及 Esc 取消焦点。
- **双栏 SFTP 浏览器**：支持上传、下载、新建目录、远程文件文本编辑。
- **主题**：内置亮色、暗色、水墨（默认）、复古及多套终端配色。
- **代理**：支持 SOCKS5 / SOCKS4 / HTTP 代理。

---

## 支持平台与下载

- **macOS**：arm64 / x64（提供 `.dmg` 安装盘）
- **Windows**：x64（提供 `.exe` 安装包与 `.zip` 绿色版）

安装包可前往 Release 页面获取：[https://github.com/lyu0805/pixshell/releases](https://github.com/lyu0805/pixshell/releases)
