<div align="center">

<img src="packages/app/renderer/icons/logo.svg" alt="PixShell logo" width="120" height="120">

# PixShell

**Cross-platform SSH / SFTP desktop client**

[English](#english) | [中文](#中文)

<br/>

[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-blue)](#)
[![Electron](https://img.shields.io/badge/Electron-33-47848F?logo=electron&logoColor=white)](#)
[![Node](https://img.shields.io/badge/node-%3E%3D20-339933?logo=node.js&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-UNLICENSED-lightgrey)](#license)

</div>

---

## English

PixShell is a dense, ops-friendly SSH / SFTP desktop client built with Electron, native `ssh2`, and xterm.

### Features

- Multi-session SSH terminal with tabbed workspace
- Connection manager with groups, notes, and host icons
- Password / private-key authentication, optional save password
- SFTP file browser, upload / download, and remote text editor
- Light / dark themes with high-contrast terminal palettes
- Local agent / CLI bridge for automation workflows
- Packaged installers for **macOS**, **Windows**, and **Linux** (runtime dependencies bundled)

### Screenshots

| Main Terminal | Connection Manager | Light Theme |
|---|---|---|
| ![Main Terminal](docs/assets/screenshots/main-terminal.png) | ![Connection Manager](docs/assets/screenshots/connection-manager.png) | ![Light Theme](docs/assets/screenshots/light-theme.png) |

| New Connection | Transfer | Editor |
|---|---|---|
| ![New Connection](docs/assets/screenshots/new-ssh-connection.png) | ![Transfer](docs/assets/screenshots/transfer.png) | ![Editor](docs/assets/screenshots/text-editor.png) |

More: [Quick Connect](docs/assets/screenshots/quick-connect.png) · [Collapsed Sidebar](docs/assets/screenshots/main-sidebar-collapsed.png) · [Backup Settings](docs/assets/screenshots/backup-settings.png) · [Terminal Session](docs/assets/screenshots/terminal-session.png)

### Install (packaged app)

Packaged builds already include Electron and required runtime libraries. End users do **not** need to install Node.js separately.

#### Windows

- Installer type: NSIS
- **Custom install directory is supported**
- Desktop / Start Menu shortcuts are created by default

```bash
npm run dist:win
```

#### macOS

```bash
npm run dist:mac
```

#### Linux

```bash
npm run dist:linux
```

### First-run configuration

User SSH hosts, passwords, settings, and quick commands are **never packaged** into the app.

On first launch, PixShell automatically creates a local config directory and empty defaults.

| Platform | Path |
|---|---|
| macOS | `~/Library/Application Support/PixShell/pixshell/` |
| Windows | `%APPDATA%\PixShell\pixshell\` |
| Linux | `~/.local/share/PixShell/pixshell/` |

Typical files created at runtime:

- `hosts.json` — saved hosts (mode `0600`; passwords prefer OS secure storage)
- `settings.json` — app preferences
- `quick-commands.json` — quick command library

Private keys, passwords, known_hosts, and other secrets stay on the local machine only. They are excluded from git and installers.

### Develop from source

```bash
# requires Node.js >= 20
npm install
npm start
```

Useful scripts:

```bash
npm test          # unit checks
npm run icons     # regenerate app icons
npm run dist      # package current platform
npm run dist:mac
npm run dist:win
npm run dist:linux
```

### Project layout

```text
packages/
  app/           Electron main + renderer shell
  core/          hosts / settings / session domain
  terminal/      xterm themes and helpers
  sftp-panel/    SFTP browser helpers
  transfer/      pack / transfer utilities
  cli/           pixshell-cli bridge
docs/            architecture and feature notes
scripts/         public packaging / import helpers
```

---

## 中文

PixShell 是一款面向运维场景的跨平台 SSH / SFTP 桌面客户端，基于 Electron、原生 `ssh2` 与 xterm。

### 功能

- 多会话 SSH 终端与标签页工作区
- 连接管理器：分组、备注、主机图标
- 密码 / 私钥认证，可选保存密码
- SFTP 文件浏览、上传下载、远程文本编辑
- 浅色 / 深色主题，高对比终端配色
- 本地 Agent / CLI 桥接，便于自动化
- macOS / Windows / Linux 安装包（运行时依赖已打包）

### 截图

| 主终端 | 连接管理器 | 浅色主题 |
|---|---|---|
| ![主终端](docs/assets/screenshots/main-terminal.png) | ![连接管理器](docs/assets/screenshots/connection-manager.png) | ![浅色主题](docs/assets/screenshots/light-theme.png) |

| 新建连接 | 传输 | 编辑器 |
|---|---|---|
| ![新建连接](docs/assets/screenshots/new-ssh-connection.png) | ![传输](docs/assets/screenshots/transfer.png) | ![编辑器](docs/assets/screenshots/text-editor.png) |

更多：[快速连接](docs/assets/screenshots/quick-connect.png) · [折叠侧栏](docs/assets/screenshots/main-sidebar-collapsed.png) · [备份设置](docs/assets/screenshots/backup-settings.png) · [终端会话](docs/assets/screenshots/terminal-session.png)

### 安装（正式包）

正式安装包已内置 Electron 与必要运行时库，**终端用户无需单独安装 Node.js**。

#### Windows

- 安装程序类型：NSIS
- **支持自定义安装路径**
- 默认创建桌面与开始菜单快捷方式

```bash
npm run dist:win
```

#### macOS

```bash
npm run dist:mac
```

#### Linux

```bash
npm run dist:linux
```

### 首次运行配置

用户 SSH 主机、密码、设置与快捷命令 **不会** 打进安装包。

首次启动时，PixShell 会自动创建本地配置目录与空默认文件。

| 平台 | 路径 |
|---|---|
| macOS | `~/Library/Application Support/PixShell/pixshell/` |
| Windows | `%APPDATA%\PixShell\pixshell\` |
| Linux | `~/.local/share/PixShell/pixshell/` |

运行时常见文件：

- `hosts.json` — 主机列表（权限 `0600`；密码优先系统安全存储）
- `settings.json` — 应用设置
- `quick-commands.json` — 快捷命令库

私钥、密码、known_hosts 等敏感信息仅保存在本机，不会进入 git 与安装包。

### 源码开发

```bash
# 需要 Node.js >= 20
npm install
npm start
```

常用脚本：

```bash
npm test          # 单元检查
npm run icons     # 重新生成图标
npm run dist      # 打包当前平台
npm run dist:mac
npm run dist:win
npm run dist:linux
```

### 目录结构

```text
packages/
  app/           Electron 主进程 + 渲染层
  core/          主机 / 设置 / 会话领域模型
  terminal/      xterm 主题与辅助
  sftp-panel/    SFTP 面板辅助
  transfer/      打包传输工具
  cli/           pixshell-cli 桥接
docs/            架构与功能说明
scripts/         公开打包 / 导入辅助脚本
```

---

## License

UNLICENSED / proprietary source unless otherwise stated by the owner.

---

<div align="center">

If PixShell is useful to you, a Star is appreciated ⭐

</div>
