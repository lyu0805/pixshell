# Wave 2 — Electron + ssh2 基线

日期：2026-07-24

## 完成内容

### Electron 应用骨架（`packages/app`）
- `main/main.js` — 窗口 + IPC
- `main/preload.js` — `window.fsApi` 桥
- `main/ssh-hub.js` — 多会话 SSH（ssh2，缺依赖时自动 mock）
- `renderer/` — 像素壳 + xterm + 主机侧栏 + SFTP 面板 + 命令输入框
- `dev-server.js` — `npm run dev` 入口

### 协议
- `packages/ssh/src/ssh2-client.js` — 可移植 ssh2 实现

### 根 package.json 依赖
- electron, ssh2, @xterm/xterm, @xterm/addon-fit, electron-store

## 启动

```bash
cd /Volumes/d/pixshell
npm install
npm run dev
# 或
npm start
```

无 electron 时会 fallback 静态 serve renderer :4790（无真 SSH）。
仅 UI 原型：`npm run dev:shell` → :4789

## PixShell 行为已接线

| 行为 | 状态 |
|------|------|
| 左侧主机列表 | ✅ |
| 多标签会话 | ✅ |
| xterm 交互 shell | ✅（需 npm install） |
| 底栏命令输入框 + 历史 | ✅ |
| SFTP 列目录 / 双击进目录 | ✅ |
| cd 命令 → 刷新 SFTP | ✅ |
| SFTP 进目录 → 发送 cd | ✅ |
| 断开 | ✅ |
| 监控采集 | 占位 |
| 配置导入 conn 主机 | 未做 |

## 注意

- 密码目前仅内存传递；hosts.json 存盘会去掉 password 字段
- 分类器故障期间未在本机执行 npm install，需你本地跑一次
