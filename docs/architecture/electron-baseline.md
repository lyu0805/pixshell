# Electron 基线方案

## 依赖选型（P0）

| 层 | 库 | 说明 |
|----|----|------|
| Shell | electron | 主进程 / 窗口 |
| Bundler | electron-vite 或 vite + electron-builder | 快速迭代 |
| UI | 静态 HTML/原生；或 React + 像素 CSS | 像素壳已有原型 |
| Terminal | @xterm/xterm + addons | 终端渲染 |
| SSH | ssh2 | 真连接会话 |
| SFTP | ssh2.sftp | 同屏面板 |
| Zmodem | zmodem.js（可选） | P1 |
| Store | electron-store / 自研 JSON | 主机与设置 |
| Secrets | keytar / safeStorage | 密码不进明文配置 |

## 进程划分

```
Main:  window, tray, secret, ssh worker spawn
Preload: bridge API
Renderer: pixel shell UI + xterm
Utility/Worker: ssh2 sockets（避免 renderer 直接 net）
```

## 与原型衔接

`prototypes/pixel-shell` 的 DOM 结构直接迁移为 renderer：

- `#hostList` ← HostStore
- `#tabs` ← SessionManager
- `#terminal` ← xterm
- `#sftp` ← sftpList
- `#cmd` ← CommandBoxController

## 安装命令

```bash
cd /Volumes/d/pixshell
npm install
```

## 不做的事

- 不引入第三方 jar 运行时
- 不打包专有 IP 库 / 专有加速协议
- 不将第三方桌面客户端整仓作为生产依赖
