# PixShell — macOS 原生端

原生 macOS SSH/SFTP 客户端(AppKit + SwiftTerm + swift-nio-ssh)。布局照搬 Electron 老仓库(见 `docs/LAYOUT-PARITY.md`)。

## 构建 / 运行

> ⚠️ 必须用完整 Xcode 的工具链(CLT 的 SwiftPM 有缺陷会链接失败):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build            # 构建
swift run PixShell     # 运行(或 .build/debug/PixShell)
bash scripts/package-mac.sh debug   # 打包成可双击的 dist/PixShell.app
```

## 已实现（均已构建 + 截图/自测验证）

- **五区布局**:顶栏(品牌+会话tab) / 侧栏(主机) / work-center(终端) / 底部坞(文件/命令) / 状态栏。
- **深色主题**:整窗深色 + 区域底色 + SwiftTerm 终端配色(明暗 ANSI 16 色照搬老仓库)。
- **连接管理器**:主机列表(JSON 持久化 `~/Library/Application Support/PixShell/hosts.json`),增/改/删,密码存 **Keychain**(不落明文)。
- **多会话 tab**:每 tab 独立 `TerminalView` + `NIOSSHSession`,顶栏切换/关闭。
- **交互式 SSH shell**:swift-nio-ssh PTY,输入/输出/resize/标题 全通。
- **SFTP 双栏**:本地(FileManager) | 远端(自研 SFTP v3 over swift-nio-ssh),列目录/进入/上传/下载/新建/删除。**上传+下载往返已真机自测通过**。
- **命令板**:发送命令 + 快捷命令到当前会话。
- **侧栏折叠**。
- **Web SSH 网页终端**：本地桥 `GET /webssh`（或 `/v1/app/webssh`）提供浏览器 xterm.js 终端；菜单「工具 → Web SSH 网页终端…」打开 `http://127.0.0.1:8766/webssh?token=…`。轮询 `/v1/app/stream`、输入 `/v1/app/shell`，支持 `?session=` / `?host_id=`。

## 目录结构

```
Sources/PixShell/
  main.swift              # 入口 + AppDelegate + 五区布局 + 会话/面板编排
  Model/Host.swift        # 主机模型
  Store/HostStore.swift   # 主机 JSON 持久化
  Store/Keychain.swift    # 密码 Keychain
  SSH/SSHSession.swift    # SSH 会话协议 + 凭据
  SSH/NIOSSHSession.swift # swift-nio-ssh PTY shell 实现
  Bridge/AgentBridge.swift / BridgeRoutes.swift / WebSSHPage.swift  # 本地桥 + Web SSH 页
  SFTP/SFTPService.swift  # SFTP 服务协议 + 类型
  SFTP/SFTPProtocol.swift # SFTP v3 线协议编解码
  SFTP/NIOSFTPSession.swift # SFTP v3 实现(over swift-nio-ssh)
  Highlight/SemanticHighlight.swift # 语义高亮引擎(移植自老仓库,待安全接入实时流)
  UI/TerminalTheme.swift  # 终端配色主题
  UI/SFTPPanel.swift      # SFTP 双栏面板
  UI/CommandPanel.swift   # 命令板
  UI/HostEditor.swift     # 主机编辑表单
docs/
  LAYOUT-PARITY.md        # 布局契约(与 Electron 老仓库对齐)
  BLUEPRINT.md            # 全模块拆分蓝图
  WIN-CONN.md             # Windows 构建说明
```

## 演示用环境变量（无人值守/调试）
- `PIXSHELL_HOST/PORT/USER/PASS/NAME`:首次运行种一条主机。
- `PIXSHELL_AUTOCONNECT=1`:启动自动连第一条。
- `PIXSHELL_THEME=light`:浅色主题。
- `PIXSHELL_SFTP_SELFTEST=1`:连上后自动跑 SFTP 上传+下载往返自测。

## 待办
- 语义高亮安全接入实时 PTY 流(整行完成后 / 非 alt-screen)。
- 私钥认证、代理/隧道、监控面板、自动更新、公证签名。
