# 🚀 PixShell v0.1.2 发布 | 双端原生 SSH / SFTP 客户端

> **告别 Electron 臃肿 · 原生性能 · AI 可驱动 · OpenWrt 友好 · FinalShell 一键搬家**

---

## 一句话介绍

**PixShell** 是面向运维 / 极客 / AI 工作流的 **原生跨平台 SSH / SFTP 桌面客户端**。

- 🍎 **macOS**：Swift + AppKit + **SwiftTerm** + SwiftNIO
- 🪟 **Windows**：C# **WPF** + WebView2 + **xterm.js** + SSH.NET
- ❌ **不依赖 Electron**，没有 Chromium 全家桶，启动快、内存省、手感干净

当前版本：**v0.1.2**  
仓库：[https://github.com/lyu0805/pixshell](https://github.com/lyu0805/pixshell)  
发布页：[https://github.com/lyu0805/pixshell/releases](https://github.com/lyu0805/pixshell/releases)

---

## 为什么又做一个 SSH 客户端？

市面上 SSH 工具很多，但常见痛点也很多：

| 痛点 | 常见现状 | PixShell 的做法 |
| --- | --- | --- |
| 体积与性能 | Electron 客户端动辄几百 MB | **双端原生**，零 Electron 运行时 |
| 路由器 / 嵌入式 | Dropbear 算法 / SFTP 子系统兼容差 | **OpenWrt / Dropbear 专门兼容** |
| AI 自动化 | 每次 `ssh` 都重新握手、难做持久会话 | **Agent Bridge + 无头模式 + 一键劫持 ssh** |
| 弹窗打扰 | Keychain / 本地网络授权反复弹 | **本地加密凭据，零模态打断** |
| 搬家成本 | FinalShell 配置迁移麻烦 | **一键解密导入主机 + 密码** |
| 文件权限 / 打包传 | 交互弱、大目录传得慢 | **1:1 Chmod 弹窗 + 打包传输自动解压清理** |

如果你既要 **日常运维**，又要 **让 Claude Code / Codex / Grok / OpenCode 直接开 SSH 干活**，PixShell 就是冲这个场景做的。

---

## ✨ 核心卖点（v0.1.2）

### 1. 🖥️ 双端原生 · Zero Electron

| 平台 | UI | 终端 | SSH 栈 |
| --- | --- | --- | --- |
| 🍎 macOS | AppKit | **SwiftTerm** 原生渲染 | SwiftNIO + 自研 SFTP v3 |
| 🪟 Windows | WPF | WebView2 + **xterm.js** | SSH.NET |

- 同一 monorepo 维护，功能与五区工作台布局对齐
- 不塞一整套浏览器内核当壳
- 启动快、占内存少、更像真正的桌面软件

> 说明：macOS **不内置** xterm.js；Mac 终端走 SwiftTerm，Windows 终端才是 xterm.js。

---

### 2. 🤖 AI MCP & Agent Bridge · AI 工具极客神器

这是 PixShell 最「现代」的一块。

#### 内置本地 HTTP Agent Bridge

- 默认监听：`127.0.0.1:8766`
- 支持 MCP Server / CLI 对接
- 可连接主机、执行命令、做 SFTP 辅助自动化

#### 无头模式（Headless）

- Claude Code / Codex / Grok / OpenCode 等 AI 工具可 **驱动已建立的持久交互式 SSH 会话**
- 不再「每问一句就重新连一次」
- 适合长会话、多步运维、反复进同机排查

#### 一键注册默认 SSH 包装工具

- 汉堡菜单独立弹窗
- 自动检测本机已装 AI CLI / 桌面工具：
  - Claude Code
  - Codex
  - Grok
  - OpenCode
  - Cursor
  - Windsurf
  - Ollama
- 一键注册 / 取消注册为默认交互式 SSH 引擎
- 对外暴露为 `pixshell-ssh`，对上层工具近乎无感替换 `ssh`

#### Web SSH

- 内置轻量网页终端：`GET /webssh`
- xterm.js + 本地桥
- 汉堡菜单可一键在默认浏览器打开

> 一句话：**AI 不再只会「发一条 ssh 命令」——它可以真正接管 PixShell 里的交互会话。**

---

### 3. 📡 协议与设备兼容王 · OpenWrt / 嵌入式友好

很多「看起来很现代」的客户端，连个 OpenWrt 路由器就翻车。PixShell v0.1.2 专门补了这块：

- 原生兼容 **OpenWrt Dropbear**
  - CTR
  - Chacha20
  - RSA
- 支持 OpenSSH fallback 协议重试
- 针对缺少 `subsystem sftp` 的设备：
  - 自动 **PTY 伪终端 fallback**
  - 兼容常见 sftp-server 路径（如 `/usr/libexec/sftp-server`、`/usr/lib/sftp-server`）

适合：

- 软路由 / 旁路由
- 老嵌入式板子
- 各种「能 SSH，但 SFTP 子系统残废」的设备

---

### 4. 🔕 零模态打断 · 加密凭据存储

用 SSH 客户端最烦什么？

不是功能少，是 **弹窗多**。

PixShell v0.1.2：

- ❌ 不再频繁弹 macOS Keychain 授权
- ❌ 不再乱弹「本地网络权限 / Local Network Auth」类模态框
- ✅ 本地加密凭据文件：`credentials.dat`
- ✅ 连接、断网、重连过程更安静、更连续

你该专注的是终端，不是点「允许 / 始终允许」。

---

### 5. 🧳 一键 FinalShell 迁移

从 FinalShell 搬家最痛的是：主机在、密码也在，但你不想一个个抄。

PixShell 支持：

- **一键自动扫描**
- **自动解密**
- **导入主机与口令**

实测可导入：

- **50 台主机**
- **48 个密码**

适合长期 FinalShell 用户直接切换，不用从零重建连接库。

---

### 6. 📁 1:1 FinalShell 风格 Chmod + 打包传输

#### 文件权限弹窗 `ChmodWindow`

右键「文件权限...」：

- Owner / Group / Other 共 **9 个读写执行复选框**
- 实时八进制显示：`0755` / `0644`
- 支持 **递归设置子目录**
- 三种应用范围：
  - 应用于文件和目录
  - 只应用于文件
  - 只应用于目录
- 可拖动、可缩放，主题对齐，不做「半残对话框」

#### `✓ 打包传输`

SFTP 右键菜单可勾选：

- 默认开启，状态持久化
- 大文件 / 文件夹自动走 **tar 打包传输**
- 目标端自动解压
- 两端临时压缩包自动清理

结果就是：

> 传目录更快、更稳，少踩「一堆小文件 thrash」的坑。

---

### 7. 🔐 主机指纹管理（Host Fingerprint Manager）

独立可拖动 / 缩放弹窗，管理 `known_hosts`：

- 查看
- 单条删除
- **导入…**
- **导出…**

适合：

- 机器重装后指纹变化
- 多机迁移
- 想备份 / 同步 known_hosts 的场景

---

## 🧰 日常也会用到的基础能力

除了 v0.1.2 的「高光」，基础盘也齐：

- 🖥️ 多标签 SSH 会话、重连、PTY 自适应
- 🗂️ 连接管理：分组、备注、主机图标、快速连接历史
- 🔑 密码 + 私钥认证
- 📁 SFTP 双栏浏览、上传 / 下载、远程文本编辑
- 🎨 明暗主题 + 终端配色（默认水墨风）
- 📡 SOCKS / HTTP 代理
- 💻 应用内本机终端（不强制跳系统 Terminal / Windows Terminal）
- ⌨️ 输入框完整快捷键：全选 / 剪切 / 复制 / 粘贴 / Esc 取消焦点
- 🔄 应用内检查更新（对接 GitHub Releases）

---

## 🖼️ 界面气质

PixShell 走的是 **运维向紧凑工作台**，不是花里胡哨的「又一个 Electron 终端皮肤」：

- 侧栏主机树
- 中央多标签终端
- 底栏文件 / 命令坞
- 状态栏
- 连接管理、密钥管理、下载管理、备份、AI / MCP 桥接独立弹窗

暗色 / 淡色都有，默认更偏长时间盯屏的运维审美。

---

## 💻 支持平台

| 平台 | 架构 | 状态 |
| --- | --- | --- |
| 🍎 macOS | arm64 / x64 | ✅ 原生支持 |
| 🪟 Windows | x64 | ✅ 原生支持 |
| 🐧 Linux | — | ❌ 暂未进入原生发布线 |

---

## 📦 下载

发布页：

**[https://github.com/lyu0805/pixshell/releases](https://github.com/lyu0805/pixshell/releases)**

常见资产名：

| 平台 | 文件 |
| --- | --- |
| macOS Apple Silicon | `mac-arm64.dmg` |
| macOS Intel | `mac-x64.dmg` |
| Windows x64 安装版 | `win-x64-setup.exe` |
| Windows x64 绿色版 | `win-x64.zip` |

> Windows 终端依赖本机 **WebView2 Runtime**（Win10/11 多数已自带）。  
> 若缺失可用：`winget install Microsoft.EdgeWebView2Runtime`

---

## 适合谁？

### 非常推荐

- 路由器 / OpenWrt / 嵌入式玩家
- 需要稳定 SFTP + 权限管理的运维
- FinalShell 老用户想平滑搬家
- 用 Claude Code / Codex / OpenCode 等 AI 工具做服务器自动化的人
- 讨厌 Electron 吃内存、弹窗多、启动慢的人

### 可能暂时不适合

- 需要 Linux 桌面客户端的人（当前未发布）
- 只要最基础 `ssh user@host`、完全不需要 GUI / SFTP 的人

---

## 快速上手建议

1. 安装后先建 1～2 个常用主机
2. 若你是 FinalShell 用户，直接走 **一键迁移**
3. 需要 AI 协作时：
   - 打开 Agent Bridge
   - 一键注册 `pixshell-ssh`
   - 让 Claude Code / Codex / OpenCode 走持久会话
4. 路由器 / 老设备优先试 SFTP；若子系统缺失，看 PTY fallback 是否自动接上
5. 大目录传输打开 `✓ 打包传输`
6. 需要改权限时直接右键 `文件权限...`

---

## 和「又一个终端」的差别

很多 SSH 客户端停在：

> 能连、能打字、能传文件

PixShell 想多走半步：

> **原生性能 + 嵌入式兼容 + 安静 UX + FinalShell 迁移 + 可被 AI 真正驱动的 SSH 会话**

如果你平时：

- 一边盯着服务器
- 一边让 AI 帮你排障 / 部署 / 批量操作
- 还要兼顾 OpenWrt、SFTP、权限、大目录传输

那 v0.1.2 会比「纯终端壳」更顺手。

---

## 🔗 链接汇总

- 项目主页： [https://github.com/lyu0805/pixshell](https://github.com/lyu0805/pixshell)
- Releases： [https://github.com/lyu0805/pixshell/releases](https://github.com/lyu0805/pixshell/releases)
- 当前版本：**v0.1.2**
- 平台：macOS（arm64 / x64）· Windows（x64）

---

## 结尾

PixShell 还在快速迭代。  
v0.1.2 这一版重点不是「再堆十个皮肤」，而是把真正卡人的地方打通：

- 原生双端
- AI 可接管 SSH
- OpenWrt / Dropbear 兼容
- 无弹窗凭据
- FinalShell 一键迁移
- Chmod + 打包传输

欢迎试用、提 Issue、提体验反馈。  
如果它对你有用，给仓库点个 ⭐ 就是最大鼓励。

---

**PixShell v0.1.2**  
**Native SSH / SFTP · AI-ready · OpenWrt-friendly · FinalShell migratable**
