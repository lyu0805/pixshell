# PixShell 前端交互逻辑（重点）

对照 `docs/features/feature-matrix.md` 交互必须项。

## 1. 多标签会话隔离

| 行为 | 实现 |
|------|------|
| 每会话独立输出缓冲 | `termBuffers: Map<sessionId, string>`，上限约 500KB 字符（超限截断保留尾部） |
| 后台会话仍收数据 | `onData` 始终写入 buffer，仅当前 tab 渲染到 xterm |
| 切标签恢复 | `switchToTab` → `term.reset` + 回放 buffer |
| 同主机多开 | 右键「新开会话」/ Shift+双击主机 / `forceNew` |
| 标签右键 | 切换 / 重连 / 再开 / 关闭 / 关闭其他 |
| Ctrl+Tab / Ctrl+1..9 | 切换标签 |

## 2. 终端 ↔ SFTP 同屏同步

| 行为 | 实现 |
|------|------|
| 命令框 `cd` | `sendCommand` → `handleTtyLine` → `tab.sftpPath` → `refreshSftp` |
| 终端内 `cd` | `term.onData` 行缓冲 + 回显解析 → 同上 |
| SFTP 进目录 | 双击目录 / 树点击 → 可选 `cd` 写会话（`syncDirWithSftp`） |
| 设置开关 | `settings.syncDirWithSftp`（默认 true） |
| 状态栏 | `statusSync` 显示当前同步路径 |

## 3. 命令框（非纯 TTY）

| 行为 | 实现 |
|------|------|
| Enter 发送 | 写当前 session，可选清输入 |
| ↑↓ 历史 | `state.history` |
| Tab 补全 | 本地目录 + 远程路径 |
| 参数 `${x}` | prompt 解析 |
| 发送后焦点 | 保持命令框（底栏 UX） |
| Ctrl+; / Ctrl+J | 聚焦命令框 |
| Ctrl+` | 聚焦终端 |

## 4. 主机侧栏

| 行为 | 实现 |
|------|------|
| 单击 | 选中 |
| 双击 | 连接（已连则切换） |
| Shift/Alt+双击 | 强制新标签会话 |
| 右键 | 连接 / 新开会话 / 编辑 / 复制 / 连接本组 / 删除 |
| 过滤 | `hostFilter` |

## 5. SFTP

| 行为 | 实现 |
|------|------|
| 单击选中 / ⌘多选 | selected + multi-sel |
| 双击目录/文件 | 进入 / 编辑器 |
| 右键菜单 | 打开/下载/上传/重命名/新建/删除/打包/复制路径/插入命令框 |
| 拖拽上传 | drop on panel → `sftpUpload` |
| F5 刷新 / F2 重命名 / Delete 删除 | 全局热键 |
| 路径点击 | 复制；Alt+点击上级 |

## 6. 焦点模型

- 点终端区 → xterm focus
- 点命令栏 → cmd focus
- Esc 从命令框回到终端

## 关键文件

- `packages/app/renderer/app.js` — 核心交互
- `packages/app/renderer/features-extra.js` — 拖拽/热键/增强（若存在）
- `packages/sftp-panel/src/sync.js` — applyCd 纯逻辑
- `packages/core/src/tabs.js` — Tab 模型参考
