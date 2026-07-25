# Wave2 进度补充

## 代码已落盘（即使 npm install 未在本会话执行）

### 可运行应用

`packages/app` Electron 结构完整：

- SSH 多会话 hub
- xterm 终端
- 像素专业运维布局
- 命令框 + 历史
- SFTP 列表 + 双击目录 + cd 同步
- 快捷命令按钮 + 监控采集按钮

### 领域包

- `@fs/core` — settings/session/hosts/import/tabs
- `@fs/ssh` — 契约 + ssh2 实现
- `@fs/command-box` — 命令框逻辑
- `@fs/monitor` — 采集命令
- `@fs/quick-commands` — 快捷命令
- `@fs/sftp-panel` — 目录同步工具
- `@fs/ui-pixel` — tokens/css

### 脚本

- `scripts/list-jar.js` + `zip-names.js`（历史研究辅助）
- `scripts/import-config.js`

## 阻塞

会话内多数 Bash 调用被安全分类拦截时，请本地执行 `docs/plan/run-locally.md` 中的命令。

## 下一步（恢复 shell 后立刻）

1. npm install && npm run dev
2. 解析 conn/ 主机文件格式
3. 快捷命令完整面板 UI
4. 监控定时刷新
5. 代理链路
