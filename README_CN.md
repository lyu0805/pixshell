<div align="center">

<img src="./docs/assets/pixshell-title.svg" alt="PixShell" width="820">

[![Version](https://img.shields.io/badge/version-0.1.1-blue)](https://github.com/lyu0805/pixshell)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)](https://github.com/lyu0805/pixshell)
[![Node](https://img.shields.io/badge/Node.js-%3E%3D20-339933.svg)](https://nodejs.org/)
[![License](https://img.shields.io/badge/license-UNLICENSED-lightgrey)](./LICENSE)

**🌐 Multi-language support / 多国语言支持**

🇺🇸 [English](./README.md) · 🇨🇳 **中文**

**🖥️ 跨平台 SSH / SFTP 桌面客户端 · ⚡ 终端 · 🗂️ 连接管理 · 📦 文件传输**

</div>

---

## ✨ 概览

PixShell 是一款面向运维场景的跨平台 **SSH / SFTP** 桌面客户端，基于 Electron、原生 `ssh2` 与 xterm。它把多会话终端、连接管理器、SFTP 浏览、远程编辑、浅色/深色主题，以及本地 CLI / Agent 桥接整合在一个桌面应用中。

## 📚 目录

- [🖼️ 界面预览](#️-界面预览)
- [🚀 核心功能](#-核心功能)
- [💻 支持平台](#-支持平台)
- [⚡ 快速开始](#-快速开始)
- [📦 打包](#-打包)
- [🗂️ 首次运行配置](#️-首次运行配置)
- [🧪 自测](#-自测)
- [📁 项目结构](#-项目结构)
- [🔒 数据与安全](#-数据与安全)

## 🖼️ 界面预览

| 主终端 | 连接管理器 |
| :---: | :---: |
| ![主终端](./docs/assets/screenshots/main-terminal.png) | ![连接管理器](./docs/assets/screenshots/connection-manager.png) |
| 🖥️ 多标签 SSH 工作区 | 🗂️ 分组、备注与主机图标 |

| 新建连接 | 浅色主题 |
| :---: | :---: |
| ![新建连接](./docs/assets/screenshots/new-ssh-connection.png) | ![浅色主题](./docs/assets/screenshots/light-theme.png) |
| ✏️ 紧凑连接编辑器 | 🌞 高对比浅色配色 |

| 传输 | 文本编辑器 |
| :---: | :---: |
| ![传输](./docs/assets/screenshots/transfer.png) | ![文本编辑器](./docs/assets/screenshots/text-editor.png) |
| 📦 上传 / 下载与打包传输 | 📝 远程文件编辑 |

更多：[⚡ 快速连接](./docs/assets/screenshots/quick-connect.png) · [📐 折叠侧栏](./docs/assets/screenshots/main-sidebar-collapsed.png) · [☁️ 备份设置](./docs/assets/screenshots/backup-settings.png) · [💻 终端会话](./docs/assets/screenshots/terminal-session.png)

## 🚀 核心功能

| 模块 | 能力 |
| --- | --- |
| 🖥️ **多会话终端** | 多标签 SSH 会话，xterm 渲染，支持重连 |
| 🗂️ **连接管理器** | 分组、备注、主机图标、快速连接 |
| 🔑 **认证方式** | 密码 / 私钥登录，可选保存密码 |
| 📁 **SFTP** | 文件浏览、上传下载、远程文本编辑 |
| 🎨 **主题** | 浅色 / 深色界面，高对比终端配色 |
| 🤖 **CLI / Agent** | 本地自动化入口，便于连接与命令编排 |
| 📦 **安装包** | macOS / Windows / Linux 安装包，运行时依赖已内置 |

## 💻 支持平台

| 平台 | 架构 | 状态 |
| --- | --- | --- |
| 🍎 macOS | arm64 / x64 | ✅ 支持 |
| 🪟 Windows | x64 | ✅ 支持 |
| 🐧 Linux | x64 | ✅ 支持 |

## ⚡ 快速开始

源码开发需要 Node.js **>= 20** 与 npm。正式安装包已内置运行时，**终端用户无需单独安装 Node.js**。

```bash
npm install
npm start
# 或
node start.js
```

启动脚本：

| 平台 | 启动方式 |
| --- | --- |
| 🍎 macOS | [`start.command`](./start.command) / [`启动 PixShell.command`](./启动%20PixShell.command) |
| 🪟 Windows | [`start.bat`](./start.bat) / [`启动.ps1`](./启动.ps1) |

## 📦 打包

```bash
npm run dist        # 当前平台
npm run dist:mac
npm run dist:win
npm run dist:linux
```

| 平台 | 输出说明 |
| --- | --- |
| 🪟 Windows | NSIS 安装程序 + 便携版；**支持自定义安装路径** |
| 🍎 macOS | DMG + ZIP |
| 🐧 Linux | AppImage |

构建产物输出到 `dist/`。

## 🗂️ 首次运行配置

用户 SSH 主机、密码、设置与快捷命令 **不会** 打进安装包。首次启动时，PixShell 会自动创建本地配置目录与空默认文件。

| 平台 | 路径 |
| --- | --- |
| 🍎 macOS | `~/Library/Application Support/PixShell/pixshell/` |
| 🪟 Windows | `%APPDATA%\PixShell\pixshell\` |
| 🐧 Linux | `~/.local/share/PixShell/pixshell/` |

运行时常见文件：

- 📄 `hosts.json` — 主机列表（权限 `0600`；密码优先系统安全存储）
- ⚙️ `settings.json` — 应用设置
- ⚡ `quick-commands.json` — 快捷命令库

私钥、密码、known_hosts 等敏感信息仅保存在本机，不会进入 git 与安装包。

## 🧪 自测

```bash
npm test
# 或
node scripts/unit-checks.js
```

## 📁 项目结构

```text
pixshell/
├── packages/app          # Electron 主进程 + 渲染层
├── packages/core         # 主机 / 设置 / 会话领域模型
├── packages/terminal     # xterm 主题与辅助
├── packages/sftp-panel   # SFTP 面板辅助
├── packages/transfer     # 打包传输工具
├── packages/cli          # pixshell-cli 桥接
├── scripts/              # 公开打包 / 导入辅助脚本
├── docs/assets           # logo 与截图
├── build/                # 打包图标
├── electron-builder.yml  # macOS / Windows / Linux 目标
├── README.md             # 英文文档
└── README_CN.md          # 中文文档
```

本仓库仅包含源码与文档，不包含用户 SSH 主机、密码、私钥、运行日志或安装包产物。

## 🔒 数据与安全

- 🛡️ 用户配置在首次运行时生成到系统用户数据目录。
- 📦 正式安装包刻意不包含 `hosts.json`、密码与私钥。
- 📝 运行日志仅保存在本机，并由 Git 忽略。
- 🔐 可用时优先使用系统安全存储保存密码。

## 📄 许可证

UNLICENSED / 专有源码，除非所有者另行说明。

---

<div align="center">

如果 PixShell 对你有帮助，欢迎点个 Star ⭐

</div>
