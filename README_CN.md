<div align="center">

<img src="./docs/assets/pixshell-title.svg" alt="PixShell" width="820">

[![Version](https://img.shields.io/badge/version-0.1.3-blue)](https://github.com/lyu0805/pixshell)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey)](https://github.com/lyu0805/pixshell)
[![macOS](https://img.shields.io/badge/macOS-Swift%20%2B%20SwiftTerm%20%2B%20SwiftNIO-000000.svg)](./mac)
[![Windows](https://img.shields.io/badge/Windows-WPF%20%2B%20WebView2%20%2B%20SSH.NET-0078D6.svg)](./win)

<img src="./docs/assets/icon.png" alt="PixShell 图标" width="96" height="96">

[English](./README.md)

**macOS / Windows 原生 SSH SFTP 客户端**

</div>

---

PixShell 是面向运维场景的 SSH / SFTP 桌面客户端，以双端原生应用形态发布。

| 平台 | UI | 终端 | SSH |
| --- | --- | --- | --- |
| macOS | Swift / AppKit | SwiftTerm | SwiftNIO |
| Windows | C# WPF | WebView2 + xterm.js | SSH.NET |

## 界面截图

| | |
| :---: | :---: |
| <img src="./docs/assets/screenshots/dark-theme.png" width="480"> | <img src="./docs/assets/screenshots/light-theme.png" width="480"> |
| <img src="./docs/assets/screenshots/connection-manager.png" width="480"> | <img src="./docs/assets/screenshots/new-connection.png" width="480"> |
| <img src="./docs/assets/screenshots/quick-connect-history.png" width="480"> | <img src="./docs/assets/screenshots/sidebar-collapsed.png" width="480"> |
| <img src="./docs/assets/screenshots/ai-interaction.png" width="480"> | <img src="./docs/assets/screenshots/mcp-cli-bridge.png" width="480"> |
| <img src="./docs/assets/screenshots/text-editor.png" width="480"> | <img src="./docs/assets/screenshots/download-manager.png" width="480"> |
| <img src="./docs/assets/screenshots/cloud-backup.png" width="480"> | <img src="./docs/assets/screenshots/key-manager.png" width="480"> |

## 功能

- 多标签 SSH 会话，支持重连与 PTY 自适应
- 连接管理器：分组、备注、主机系统图标
- 密码与私钥认证
- SFTP 文件浏览：上传、下载、打包传输、远程编辑
- 明暗主题与终端配色方案
- SOCKS / HTTP 代理
- 本地自动化桥接，供 CLI 与 Agent 工作流使用
- 五区布局在 macOS / Windows 双端对齐

## 构建

### macOS

需要 Xcode。

```bash
cd mac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
bash scripts/package-mac.sh release
```

### Windows

需要 .NET 9 SDK 与 Edge WebView2 运行时。

```powershell
cd win
dotnet publish PixShell.csproj -c Release -r win-x64 --self-contained true -o publish/win-x64
```

## 下载

预编译包发布于 [GitHub Releases](https://github.com/lyu0805/pixshell/releases)。

- macOS：`PixShell-0.1.3-mac-arm64.dmg` / `PixShell-0.1.3-mac-x64.dmg`
- Windows：`PixShell-0.1.3-win-x64-setup.exe` / `PixShell-0.1.3-win-x64.zip`

## 项目结构

```
PixShell-all/
├── mac/          SwiftPM、AppKit、SwiftTerm、SwiftNIO
├── win/          .NET 9 WPF、WebView2 + xterm.js、SSH.NET
├── build/        公用打包图标
├── docs/         截图与发行说明
└── .github/      CI 工作流
```

## 许可

见 [LICENSE](./LICENSE)。采用 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) 许可 — 允许署名后自由分享与改编，禁止商业用途。
