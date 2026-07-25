<div align="center">

<img src="./docs/assets/pixshell-title.svg" alt="PixShell" width="820">

[![Version](https://img.shields.io/badge/version-0.1.0-blue)](https://github.com/lyu0805/pixshell)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey)](https://github.com/lyu0805/pixshell)
[![Node](https://img.shields.io/badge/Node.js-%3E%3D20-339933.svg)](https://nodejs.org/)
[![License](https://img.shields.io/badge/license-UNLICENSED-lightgrey)](./LICENSE)

**🌐 Multi-language support / 多国语言支持**

🇺🇸 **English** · 🇨🇳 [中文](./README_CN.md)

**🖥️ Cross-platform SSH / SFTP desktop client · ⚡ Terminal · 🗂️ Connection manager · 📦 File transfer**

</div>

---

## ✨ Overview

PixShell is a dense, ops-friendly **SSH / SFTP** desktop client built with Electron, native `ssh2`, and xterm. It combines multi-session terminals, a connection manager, SFTP browsing, remote editing, light/dark themes, and a local CLI / agent bridge in one desktop app.

## 📚 Contents

- [🖼️ Screenshots](#️-screenshots)
- [🚀 Key features](#-key-features)
- [💻 Supported platforms](#-supported-platforms)
- [⚡ Quick start](#-quick-start)
- [📦 Packaging](#-packaging)
- [🗂️ First-run configuration](#️-first-run-configuration)
- [🧪 Self-tests](#-self-tests)
- [📁 Project layout](#-project-layout)
- [🔒 Data and security](#-data-and-security)

## 🖼️ Screenshots

| Main Terminal | Connection Manager |
| :---: | :---: |
| ![Main Terminal](./docs/assets/screenshots/main-terminal.png) | ![Connection Manager](./docs/assets/screenshots/connection-manager.png) |
| 🖥️ Tabbed SSH workspace | 🗂️ Groups, notes, and host icons |

| New Connection | Light Theme |
| :---: | :---: |
| ![New Connection](./docs/assets/screenshots/new-ssh-connection.png) | ![Light Theme](./docs/assets/screenshots/light-theme.png) |
| ✏️ Compact connection editor | 🌞 High-contrast light palette |

| Transfer | Text Editor |
| :---: | :---: |
| ![Transfer](./docs/assets/screenshots/transfer.png) | ![Text Editor](./docs/assets/screenshots/text-editor.png) |
| 📦 Upload / download and pack transfer | 📝 Remote file editing |

More: [⚡ Quick Connect](./docs/assets/screenshots/quick-connect.png) · [📐 Collapsed Sidebar](./docs/assets/screenshots/main-sidebar-collapsed.png) · [☁️ Backup Settings](./docs/assets/screenshots/backup-settings.png) · [💻 Terminal Session](./docs/assets/screenshots/terminal-session.png)

## 🚀 Key features

| Area | What it provides |
| --- | --- |
| 🖥️ **Multi-session terminal** | Tabbed SSH sessions with xterm rendering and reconnect support. |
| 🗂️ **Connection manager** | Groups, notes, host icons, and quick connect. |
| 🔑 **Authentication** | Password and private-key auth, optional password save. |
| 📁 **SFTP** | File browser, upload / download, and remote text editing. |
| 🎨 **Themes** | Light / dark UI with high-contrast terminal palettes. |
| 🤖 **CLI / agent bridge** | Local automation entry for host connect and command workflows. |
| 📦 **Packaged installers** | macOS / Windows / Linux builds with runtime dependencies bundled. |

## 💻 Supported platforms

| Platform | Architecture | Status |
| --- | --- | --- |
| 🍎 macOS | arm64 / x64 | ✅ Supported |
| 🪟 Windows | x64 | ✅ Supported |
| 🐧 Linux | x64 | ✅ Supported |

## ⚡ Quick start

Source development requires Node.js **>= 20** and npm. Packaged installers already include the runtime, so end users do **not** need to install Node.js separately.

```bash
npm install
npm start
# or
node start.js
```

Launcher scripts:

| Platform | Launcher |
| --- | --- |
| 🍎 macOS | [`start.command`](./start.command) / [`启动 PixShell.command`](./启动%20PixShell.command) |
| 🪟 Windows | [`start.bat`](./start.bat) / [`启动.ps1`](./启动.ps1) |

## 📦 Packaging

```bash
npm run dist        # current platform
npm run dist:mac
npm run dist:win
npm run dist:linux
```

| Platform | Output notes |
| --- | --- |
| 🪟 Windows | NSIS installer + portable build; **custom install directory supported** |
| 🍎 macOS | DMG + ZIP |
| 🐧 Linux | AppImage |

Build output is written to `dist/`.

## 🗂️ First-run configuration

User SSH hosts, passwords, settings, and quick commands are **never packaged** into the app. On first launch, PixShell creates a local config directory and empty defaults.

| Platform | Path |
| --- | --- |
| 🍎 macOS | `~/Library/Application Support/PixShell/pixshell/` |
| 🪟 Windows | `%APPDATA%\PixShell\pixshell\` |
| 🐧 Linux | `~/.local/share/PixShell/pixshell/` |

Typical runtime files:

- 📄 `hosts.json` — saved hosts (mode `0600`; passwords prefer OS secure storage)
- ⚙️ `settings.json` — app preferences
- ⚡ `quick-commands.json` — quick command library

Private keys, passwords, known_hosts, and other secrets stay on the local machine only. They are excluded from git and installers.

## 🧪 Self-tests

```bash
npm test
# or
node scripts/unit-checks.js
```

## 📁 Project layout

```text
pixshell/
├── packages/app          # Electron main + renderer
├── packages/core         # hosts / settings / session domain
├── packages/terminal     # xterm themes and helpers
├── packages/sftp-panel   # SFTP browser helpers
├── packages/transfer     # pack / transfer utilities
├── packages/cli          # pixshell-cli bridge
├── scripts/              # public packaging / import helpers
├── docs/assets           # logo + screenshots
├── build/                # app icons for packaging
├── electron-builder.yml  # macOS / Windows / Linux targets
├── README.md             # English documentation
└── README_CN.md          # Chinese documentation
```

This repository contains source code and documentation only. It does not include user SSH hosts, passwords, private keys, runtime logs, or packaged installers.

## 🔒 Data and security

- 🛡️ User configuration is generated on first run in the platform user-data directory.
- 📦 Packaged builds intentionally omit `hosts.json`, passwords, and private keys.
- 📝 Runtime logs stay local and are ignored by Git.
- 🔐 Prefer OS secure storage for passwords when available.

## 📄 License

UNLICENSED / proprietary source unless otherwise stated by the owner.

---

<div align="center">

If PixShell is useful to you, a Star is appreciated ⭐

</div>
