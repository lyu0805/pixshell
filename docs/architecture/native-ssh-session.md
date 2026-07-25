# PixShell 原生 SSH 会话层

PixShell 使用 **Node `ssh2`** 自研会话层，不桥接第三方桌面客户端运行时。

| 概念 | 本仓库模块 |
|------|------------|
| SSH 会话 | `packages/ssh/src/session/ssh-session.js` |
| Shell 通道 | `packages/ssh/src/session/shell-session.js` |
| SFTP 通道 | `packages/ssh/src/session/sftp-session.js` |
| 多路复用 | `packages/ssh/src/session/multiplexer.js` |
| 算法/默认 | `packages/ssh/src/algorithms.js` |
| 认证链 | `SSHSession.start()`：password / keyboard-interactive / pubkey / agent |
| 服务消息 | `emit('serviceMessage')` → 终端灰字提示 |
| OSC cwd | Shell 侧解析 OSC 7 / 1337 |
| 会话管理 / IPC | `packages/app/main/ssh-engine.js` |

## 禁止

- 依赖或包装第三方 SSH 桌面客户端的私有包/服务
- 以 mock /「桥接 OK」冒充真连接

## 运行时

仅 `ssh2` Client；真实 TCP/SSH。
