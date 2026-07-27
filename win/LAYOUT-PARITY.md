# 布局契约：原生端照搬 Electron 老仓库的布局模式

两端（mac AppKit / Windows WPF）的前端**整体布局必须与 Electron 版一致**（区域划分一致，非像素级）。
来源：`/Volumes/d/pixshell/packages/app/renderer/index.html`。

## 区域骨架

```
┌─────────────────────────────────────────────────┐
│ 顶栏 top-bar                                       │
│  ├ 品牌按钮(连接管理器 icon，最左)                   │
│  └ 会话标签条 tabbar (#tabs)  ← 每个 SSH 会话一个 tab │
├──────────┬──────────────────────────────────────┤
│ 侧栏      │ 工作区 workspace                        │
│ sidebar  │  ├ work-center：当前会话终端(填充)        │
│  ├ head  │  └ bottom-dock 底部坞(可折叠/可拖高)      │
│  │ (折叠) │      ├ bottom-tabs: [文件][命令]          │
│  └ scroll│      └ bottom-body:                      │
│   快连/   │          · panelFiles = SFTP 文件面板     │
│   主机浏览 │          · panelCmds  = 命令板/快捷命令    │
│ (可拖宽)  │                                         │
├──────────┴──────────────────────────────────────┤
│ 状态栏 statusbar: [PixShell] [版本] … 连接状态      │
└─────────────────────────────────────────────────┘
```

## 各区域职责
- **top-bar**：左侧品牌/连接管理器入口；右侧会话标签条（多会话切换，带关闭）。会话 tab 在**顶部**，不在侧栏也不在右栏内部。
- **sidebar（左）**：可折叠 + 可拖宽。内容 = 快速连接 / 主机浏览器（分组的主机列表 + 增改删 + 连接）。
- **workspace（中/右）**：
  - **work-center**：当前会话的终端（填充剩余空间）。
  - **bottom-dock（底部坞）**：可折叠、可拖高。顶部两个 tab「文件 / 命令」；
    - **文件 panelFiles** = SFTP 双栏（本地/远端文件浏览 + 传输）。
    - **命令 panelCmds** = 命令板 / 快捷命令（发送到当前会话）。
- **statusbar（底）**：品牌名 + 版本，右侧放连接/同步状态等。

## 映射到原生控件
| 区域 | mac AppKit | Windows WPF |
|---|---|---|
| 根 | 垂直布局容器 | `DockPanel`/`Grid`(行:顶栏/主/状态栏) |
| 顶栏 tab | 顶部 NSView + 会话 NSButton 条 | 顶部 `StackPanel` + tab 按钮 |
| 侧栏 | 左 NSSplitView 分栏 + 列表 | 左 `GridSplitter` + `ListBox` |
| work-center | 终端容器(SwiftTerm) | WebView2+xterm |
| bottom-dock | 底部可折叠 NSView(文件/命令) | 底部 `Grid` 行 + `TabControl` |
| 状态栏 | 底部 NSView + 标签 | 底部 `StatusBar` |

## 阶段
- L0：搭出布局骨架五区（顶栏 tab / 侧栏 / 终端 / 底部坞占位 / 状态栏），终端与多会话接进 work-center + 顶栏 tab。
- L1：sidebar 折叠/拖宽；bottom-dock 折叠/拖高 + tab 切换。
- L2：填 panelFiles（SFTP）、panelCmds（命令板）。
- L3：配色/高亮引擎移植（对齐 Electron decoratePlainChunk 语义键）、设置界面。
- L4：打包（mac .app 公证 / win 自包含 exe）。
