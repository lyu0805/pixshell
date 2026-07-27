<div align="center">

<img src="./docs/assets/pixshell-title.svg" alt="PixShell" width="820">

[![Version](https://img.shields.io/badge/version-0.1.1-blue)](https://github.com/lyu0805/pixshell)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey)](https://github.com/lyu0805/pixshell)
[![macOS](https://img.shields.io/badge/macOS-Swift%20%2B%20SwiftTerm%20%2B%20SwiftNIO-000000.svg)](./mac)
[![Windows](https://img.shields.io/badge/Windows-WPF%20%2B%20WebView2%20%2B%20SSH.NET-0078D6.svg)](./win)
[![License](https://img.shields.io/badge/license-UNLICENSED-lightgrey)](./LICENSE)

<img src="./docs/assets/icon.png" alt="PixShell icon" width="96" height="96">

**🌐 Multi-language support / 多国语言支持**

🇺🇸 **English** · 🇨🇳 **中文**（本页双语）

**🖥️ Native cross-platform SSH / SFTP desktop client · ⚡ Terminal · 🗂️ Connection manager · 📦 File transfer**

**原生跨平台 SSH / SFTP 桌面客户端 · ⚡ 终端 · 🗂️ 连接管理 · 📦 文件传输**

</div>

---

## ✨ Overview / 概览

PixShell is a dense, ops-friendly **SSH / SFTP** desktop client. Since **v0.1.1** it ships as **two native apps** in one monorepo — not Electron.

PixShell 是面向运维场景的 **SSH / SFTP** 桌面客户端。自 **v0.1.1** 起以 **双端原生应用** 形态发布（同一 monorepo），不再依赖 Electron。

| Platform / 平台 | UI | Terminal / 终端 | SSH stack |
| --- | --- | --- | --- |
| 🍎 **macOS** | Swift / AppKit | **SwiftTerm**（原生渲染，非 xterm.js） | **SwiftNIO** + 自研 SFTP v3 |
| 🪟 **Windows** | C# **WPF** shell | **WebView2** 内嵌 **xterm.js** | **SSH.NET** |

> ⚠️ macOS does **not** embed xterm.js. Terminal rendering on Mac is **SwiftTerm**.  
> ⚠️ macOS **不内置** xterm.js；Mac 终端渲染走 **SwiftTerm**。Windows 终端才是 WebView2 + xterm.js。


## 🖼️ Screenshots / 截图

| Main Terminal | Connection Manager |
| :---: | :---: |
| ![Main Terminal](./docs/assets/screenshots/main-terminal.png) | ![Connection Manager](./docs/assets/screenshots/connection-manager.png) |

| SFTP Transfer | Text Editor |
| :---: | :---: |
| ![Transfer](./docs/assets/screenshots/transfer.png) | ![Editor](./docs/assets/screenshots/text-editor.png) |

## 📚 Contents / 目录

- [🚀 Key features / 核心特性](#-key-features--核心特性)
- [💻 Supported platforms / 支持平台](#-supported-platforms--支持平台)
- [🏗️ Architecture / 架构](#️-architecture--架构)
- [⚡ Quick start / 快速开始](#-quick-start--快速开始)
- [📦 Packaging / 打包](#-packaging--打包)
- [🗂️ First-run configuration / 首次运行配置](#️-first-run-configuration--首次运行配置)
- [📁 Project layout / 项目结构](#-project-layout--项目结构)
- [🤖 CLI / agent bridge](#-cli--agent-bridge)
- [🔒 Data and security / 数据与安全](#-data-and-security--数据与安全)

## 🚀 Key features / 核心特性

| Area / 领域 | What it provides / 能力 |
| --- | --- |
| 🖥️ **Multi-session terminal** | Tabbed SSH sessions, reconnect, PTY resize. Mac: SwiftTerm · Win: WebView2 + xterm.js |
| 🗂️ **Connection manager** | Groups, notes, host OS icons, quick connect |
| 🔑 **Authentication** | Password + private key; optional OS secure storage for passwords |
| 📁 **SFTP** | Dual-pane browser, upload / download, pack transfer, remote text edit |
| 🎨 **Themes** | Light / dark UI + terminal palettes |
| 📡 **Proxy** | SOCKS / HTTP proxy on both platforms（实现路径不同，行为对齐） |
| 🤖 **CLI / agent bridge** | Local automation HTTP bridge for connect / run / SFTP workflows |
| 📐 **Layout parity** | Five-zone workspace aligned across macOS and Windows |

## 💻 Supported platforms / 支持平台

| Platform | Architecture | Status |
| --- | --- | --- |
| 🍎 macOS | arm64 / x64 | ✅ Supported（原生） |
| 🪟 Windows | x64 | ✅ Supported（原生） |
| 🐧 Linux | — | ❌ Not in native 0.1.1 line |

## 🏗️ Architecture / 架构

```text
PixShell-all monorepo
├── mac/     SwiftPM executable → package-mac.sh → PixShell.app
│            AppKit UI · SwiftTerm · SwiftNIO SSH · 自研 SFTP
└── win/     .NET 9 WPF → publish win-x64
             WPF chrome · WebView2(xterm.js) · SSH.NET · SFTP
```

**Design rule / 设计约定**

- Shared product behavior and five-zone layout across platforms.
- Platform-native controls and terminal stacks where they perform best.
- 双端功能与五区布局对齐；控件与终端栈按平台原生最优路径实现。

## ⚡ Quick start / 快速开始

### 🍎 macOS

**Requires / 前置**：完整 **Xcode**（不要只用 Command Line Tools；请设置 `DEVELOPER_DIR`）。

```bash
cd mac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Debug run / 调试运行
swift build
# 或一键：
bash "启动 PixShell.command"

# Release package / 发布打包
swift build -c release
bash scripts/package-mac.sh release
open dist/PixShell.app
```

### 🪟 Windows

**Requires / 前置**：**.NET 9 SDK**；终端依赖 **Edge WebView2 Runtime**（多数 Win10/11 已自带）。

```powershell
cd win

# 推荐一键脚本
.\build.ps1 -Action publish -Configuration Release -Runtime win-x64
.\publish\win-x64\PixShell.exe

# 或直接 dotnet
dotnet restore PixShell.csproj -r win-x64
dotnet publish PixShell.csproj -c Release -r win-x64 --self-contained true -o publish/win-x64
```

若缺少 WebView2：

```powershell
winget install Microsoft.EdgeWebView2Runtime
```

## 📦 Packaging / 打包

| Target | How / 方式 | Output / 产物 |
| --- | --- | --- |
| 🍎 mac-arm64 / mac-x64 | `mac/scripts/package-mac.sh release` · GitHub Actions | `PixShell.app`（zip 工件，CI unsigned） |
| 🪟 win-x64 | `win/build.ps1` / `dotnet publish` · GitHub Actions | `publish/win-x64/PixShell.exe` |

App icons used by packaging:

| File | Role |
| --- | --- |
| `docs/assets/icon.png` / `pixshell-title.svg` / `logo.svg` | README & docs |
| `build/icon.icns` · `mac/Resources/AppIcon.icns` | macOS `.app` Dock / Finder icon |
| `build/icon.ico` · `win/Resources/AppIcon.ico` | Windows exe `ApplicationIcon` |

### CI/CD

GitHub Actions (`.github/workflows/build.yml`) builds:

| Artifact | Runner |
| --- | --- |
| `PixShell-mac-arm64` | `macos-15` |
| `PixShell-mac-x64` | `macos-15-intel` |
| `PixShell-win-x64` | `windows-2025` |

## 🗂️ First-run configuration / 首次运行配置

User hosts, passwords, settings, and quick commands are **never** packaged into the app.  
用户主机、密码、设置与快捷命令 **不会** 打进安装包。

| Platform | Path |
| --- | --- |
| 🍎 macOS | `~/Library/Application Support/PixShell/` |
| 🪟 Windows | `%APPDATA%\PixShell\` |

Typical runtime files / 常见运行时文件：

- 📄 `hosts.json` — saved hosts（密码优先走系统安全存储）
- ⚙️ `settings.json` — app preferences
- ⚡ quick-command library / 快捷命令库

Private keys, passwords, and known_hosts stay on the local machine only.

## 📁 Project layout / 项目结构

```text
PixShell-all/
├── mac/                      # macOS native (SwiftPM)
│   ├── Sources/PixShell/     # App / UI / SSH / SFTP / Bridge
│   ├── Resources/AppIcon.icns
│   ├── scripts/package-mac.sh
│   └── 启动 PixShell.command
├── win/                      # Windows native (.NET 9 WPF)
│   ├── UI/ Terminal/ Sftp/ Bridge/
│   ├── web/                  # vendored xterm.js for WebView2 only
│   ├── Resources/AppIcon.ico
│   ├── build.ps1
│   └── PixShell.csproj
├── build/                    # shared packaging icons (.icns / .ico / .png)
├── docs/assets/              # logo + title art for README
├── .github/workflows/        # multi-platform CI
└── README.md
```

This repository contains source and docs only — no user secrets, runtime logs, or release binaries.

## 🤖 CLI / agent bridge

Both platforms expose a local automation bridge for host connect, command execution, and SFTP helpers (used by `pixshell-cli` / agent workflows).

双端均提供本机自动化桥：连接主机、执行命令、SFTP 辅助（供 CLI / agent 工作流使用）。

| Platform | Listen stack（实现差异，协议对齐） |
| --- | --- |
| 🍎 macOS | `NWListener` HTTP bridge |
| 🪟 Windows | `HttpListener` bridge |

## 🔒 Data and security / 数据与安全

- 🛡️ Config is created on first run under the platform user-data directory.
- 📦 Packaged builds omit hosts, passwords, and private keys.
- 📝 Runtime logs stay local and are git-ignored.
- 🔐 Prefer OS secure storage for passwords when available.
- 📄 Internal engineering notes such as `代码概要.md` are **local-only** and git-ignored（不进入发布树）。

## 📄 License

UNLICENSED / proprietary source unless otherwise stated by the owner.

---

<div align="center">

**PixShell v0.1.1** · Native macOS + Windows

If PixShell is useful to you, a Star is appreciated ⭐

</div>
