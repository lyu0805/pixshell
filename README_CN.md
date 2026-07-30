# PixShell

<div align="center">

<img src="./docs/assets/pixshell-title.svg" alt="PixShell" width="820">

[![Version](https://img.shields.io/badge/version-0.1.3-blue)](https://github.com/lyu0805/pixshell)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey)](https://github.com/lyu0805/pixshell)
[![macOS](https://img.shields.io/badge/macOS-Swift%20%2B%20SwiftTerm%20%2B%20SwiftNIO-000000.svg)](./mac)
[![Windows](https://img.shields.io/badge/Windows-WPF%20%2B%20WebView2%20%2B%20SSH.NET-0078D6.svg)](./win)
[![License](https://img.shields.io/badge/license-UNLICENSED-lightgrey)](./LICENSE)

<img src="./docs/assets/icon.png" alt="PixShell icon" width="96" height="96">

**🌐 多语言**

🇺🇸 [English](./README.md) · 🇨🇳 **中文**

**🖥️ 原生跨平台 SSH / SFTP 桌面客户端 · ⚡ 终端 · 🗂️ 连接管理 · 📦 文件传输**

</div>

---

## ✨ 概览

PixShell 是面向运维场景的 **SSH / SFTP** 桌面客户端。自 **v0.1.1** 起以 **双端原生应用** 形态发布（同一 monorepo），不再依赖 Electron。

| 平台 | UI | 终端 | SSH 栈 |
| --- | --- | --- | --- |
| 🍎 **macOS** | Swift / AppKit | **SwiftTerm**（原生渲染） | **SwiftNIO** + 自研 SFTP v3 |
| 🪟 **Windows** | C# **WPF** | **WebView2** + **xterm.js** | **SSH.NET** |

> ⚠️ macOS **不内置** xterm.js；Mac 终端渲染走 **SwiftTerm**。Windows 终端才是 WebView2 + xterm.js。

## 🖼️ App Interface / 软件界面

### 暗色模式 / 淡色模式

| 暗色模式 | 淡色模式 |
| :---: | :---: |
| <img src="./docs/assets/screenshots/dark-theme.png" alt="暗色模式" width="480"> | <img src="./docs/assets/screenshots/light-theme.png" alt="淡色模式" width="480"> |

### 主机管理 / 新建连接

| 主机管理 | 新建连接 |
| :---: | :---: |
| <img src="./docs/assets/screenshots/connection-manager.png" alt="主机管理" width="480"> | <img src="./docs/assets/screenshots/new-connection.png" alt="新建连接" width="480"> |

### 快速连接:历史 / 收起侧边栏

| 快速连接:历史 | 收起侧边栏 |
| :---: | :---: |
| <img src="./docs/assets/screenshots/quick-connect-history.png" alt="快速连接:历史" width="480"> | <img src="./docs/assets/screenshots/sidebar-collapsed.png" alt="收起侧边栏" width="480"> |

### AI 工具交互 / 对接 MCP:本地 CLI

| AI 工具交互 | 对接 MCP:本地 CLI |
| :---: | :---: |
| <img src="./docs/assets/screenshots/ai-interaction.png" alt="AI 工具交互" width="480"> | <img src="./docs/assets/screenshots/mcp-cli-bridge.png" alt="对接 MCP:本地 CLI" width="480"> |

### 文本编辑器 / 下载管理

| 文本编辑器 | 下载管理 |
| :---: | :---: |
| <img src="./docs/assets/screenshots/text-editor.png" alt="文本编辑器" width="480"> | <img src="./docs/assets/screenshots/download-manager.png" alt="下载管理" width="480"> |

### 云备份:本地备份 / 密钥管理

| 云备份:本地备份 | 密钥管理 |
| :---: | :---: |
| <img src="./docs/assets/screenshots/cloud-backup.png" alt="云备份:本地备份" width="480"> | <img src="./docs/assets/screenshots/key-manager.png" alt="密钥管理" width="480"> |

## 🚀 核心特性

| 领域 | 能力 |
| --- | --- |
| 🖥️ **多会话终端** | 标签页 SSH、重连、PTY 自适应。Mac: SwiftTerm · Win: WebView2 + xterm.js |
| 🗂️ **连接管理** | 分组、备注、主机图标、快速连接 |
| 🔑 **认证** | 密码 + 私钥；可选系统安全存储密码 |
| 📁 **SFTP** | 双栏浏览、上传/下载、打包传输、远程文本编辑 |
| 🎨 **主题** | 明暗界面 + 终端配色 |
| 📡 **代理** | SOCKS / HTTP（双端路径不同，行为对齐） |
| 🤖 **CLI / agent 桥** | 本地自动化 HTTP 桥，支持连接 / 执行 / SFTP |
| 📐 **布局对齐** | 五区工作区在 macOS / Windows 对齐 |

## 💻 支持平台

| 平台 | 架构 | 状态 |
| --- | --- | --- |
| 🍎 macOS | arm64 / x64 | ✅ 支持（原生） |
| 🪟 Windows | x64 | ✅ 支持（原生） |
| 🐧 Linux | — | ❌ 不在原生 0.1.1 线 |

## ⚡ 快速开始

### 🍎 macOS

需要完整 **Xcode**。

```bash
cd mac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
bash "启动 PixShell.command"
# 发布包
swift build -c release
bash scripts/package-mac.sh release
open dist/PixShell.app
```

### 🪟 Windows

需要 **.NET 9 SDK**。

```powershell
cd win
.\build.ps1
# 或
dotnet publish PixShell.csproj -c Release -r win-x64 --self-contained true -o publish/win-x64
```

## 📦 安装包

发布页：<https://github.com/lyu0805/pixshell/releases>

- macOS：`PixShell-0.1.3-mac-arm64.dmg` / `PixShell-0.1.3-mac-x64.dmg`
- Windows：`PixShell-0.1.3-win-x64-setup.exe` / `PixShell-0.1.3-win-x64.zip`

应用内 **菜单 → 软件更新** 会打开上述发行页。

## 📁 项目结构

```text
PixShell-all monorepo
├── mac/     SwiftPM → package-mac.sh → PixShell.app / DMG
└── win/     .NET 9 WPF → publish win-x64 → zip + Inno Setup
```

## 🔒 许可

见 [LICENSE](./LICENSE)（UNLICENSED / 保留所有权利）。
