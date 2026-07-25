# 实施计划（团队并行）

## 当前状态（2026-07-24）

已完成：

- 仓库骨架 `/Volumes/d/pixshell`
- 官网能力 23 项功能矩阵
- 架构决策（领域 monorepo + 独立 Electron 壳，非整仓 fork 第三方客户端）
- 配置/布局 schema 初稿（本地 JSON）
- 像素设计 tokens + 专业运维布局壳 CSS
- 可交互静态原型 `prototypes/pixel-shell`
- domain：`@fs/core` settings/session/hosts
- 契约：`@fs/ssh`、`@fs/command-box`、`@fs/monitor`
- 辅助脚本 `scripts/list-jar.js`（历史研究用，见 `docs/archive/`）

阻塞：

- 会话工具短暂不可用时，本地 jar 索引与 Windows 深度调研可延后

## 下一波并行任务

### A. 配置导入

```
# 导入 Windows 配置字段映射（路径按本机样本调整）
node scripts/import-config.js /path/to/config.json
```

### B. electron-baseline

- packages/app 升级为 electron + vite（若尚未）
- 接入 xterm.js + ssh2
- 复用 pixel shell 布局

### C. import-config / hosts

- 读取 config.json → AppSettings（已有 mapLegacyConfig）
- 解析 conn/ 主机（待 schema）

## 验收（P0）

- [ ] 像素主窗布局与专业运维区域一致
- [ ] 能 SSH 登录并多标签
- [ ] 底栏命令框发送到 session
- [ ] SFTP 同屏，cd 同步
- [ ] 主机侧栏增删改查 + 演示导入
