# 架构总览：原生 SSH × 专业运维布局 × 像素 UI

## 1. 设计原则

1. **功能语义**：专业运维客户端信息密度（侧栏主机树、命令框、同屏 SFTP、监控、快捷命令）。
2. **传输/终端内核**：自研 monorepo 领域包 + `ssh2` + xterm，不依赖第三方桌面客户端运行时。
3. **视觉层独立**：`ui-pixel` 像素复古设计系统，可与默认紧凑主题切换。
4. **先插件化边界，再必要时扩展包**：能做成 package 的不改 core。

## 2. 推荐工程形态

**推荐：领域 monorepo + 独立 Electron 应用壳**

理由：

- 主壳布局（侧栏主机树 + 底栏命令区 + SFTP 同屏）是壳级需求，需自有 `packages/app`。
- SSH/session/terminal 能力以自研包交付，便于裁剪与演进。
- 体积与主题可控，不整仓引入无关桌面客户端。

## 3. 逻辑架构

```
┌──────────────────────────────────────────────────────────┐
│ Electron Shell (packages/app)                            │
│  window / tray / hotkeys / native menus                  │
└───────────────────────────┬──────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────┐
│ UI Shell (pixel-retro / compact)                         │
│  HostSidebar | TabHost | Terminal+SFTP | CommandBox      │
│  QuickCommands | MonitorDrawer | Editor | Settings       │
└───────────────────────────┬──────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────┐
│ Domain Services                                          │
│  HostStore  SessionManager  CommandHistory  QuickCmd     │
│  MonitorCollector  TransferService  ProxyService  Sync   │
└───────────────────────────┬──────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────┐
│ Protocol / IO                                            │
│  SSH (ssh2)  SFTP  Zmodem  RDP(后期)  Local PTY          │
└──────────────────────────────────────────────────────────┘
```

## 4. 包职责

| 包 | 用途 |
|----|------|
| `packages/core` | 配置、热键、tab、主机模型 |
| `packages/terminal` | xterm 封装与配色 |
| `packages/ssh` | SSH / SFTP / 会话 |
| `packages/app` | Electron 主进程、secret storage、UI 壳 |
| 设置 UI | 像素风 Settings |
| 主机树 / 命令框 / 监控 | 应用壳内新建 |

## 5. 像素复古 UI 规范（初稿）

参考：SegmentFault 像素复古合集（NES.css / RetroUI / Pxlkit / 98.css）

| Token | 建议 |
|-------|------|
| 字体 | 中文像素/点阵优先；终端可用 `DejaVuSansMono` + 中文等宽 |
| 边框 | 2–4px 硬边、无圆角或 0 |
| 阴影 | 实心偏移阴影（brutal/pixel），不用高斯 |
| 调色 | 有限调色板（背景墨黑/深蓝，强调色琥珀/青绿，危险红） |
| 控件 | 按钮、输入框、滚动条、窗口标题栏像素化 |
| 图标 | 16×16 / 32×32 像素图标集 |
| 动效 | 步进式，少用缓动曲线 |

实现路径：CSS 变量设计系统 + 自研组件。

## 6. P0 实施顺序

1. monorepo + Electron 空壳 + 像素主窗口布局线框
2. 主机管理（本地 JSON，兼容常见 conn 导入）
3. SSH 会话 + 多标签终端
4. 底部命令输入框（发送到当前 session）
5. SFTP 面板 + 目录同步
6. 快捷命令面板

## 7. 配置与导入输入

| 源 | 说明 |
|----|------|
| 本地 `config.json` | 布局/主题/命令框等字段 |
| `conn/` | 主机连接条目（导入脚本） |
| `knownhosts.json` | 主机密钥信任 |
| 监控采集 | 经 SSH 执行标准命令，无 agent |

## 8. 分工（团队模式）

| 角色 | 任务 |
|------|------|
| arch | monorepo 与 Electron 基线 |
| ui | 像素主壳 |
| feature | P0 功能实现 |
| protocol | 真 ssh2 / SFTP |
