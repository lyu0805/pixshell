# 任务：实现 mac 原生 SSH 交互式 PTY 会话（Swift）

## 背景
PixShell-mac 是 macOS 原生 SSH 客户端（AppKit + SwiftTerm）。仓库 `/Volumes/ssd1t/opencode/PixShell-mac/`，SwiftPM 包，`swift-tools-version: 6.0`。
**构建必须带环境变量**（否则 CLT 的 SwiftPM 会链接失败）：
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
```

## 你要做的
实现 `Sources/PixShell/SSH/SSHSession.swift` 里已定义的 **`SSHSession` 协议**（不要改协议签名），提供一个可用的交互式 PTY shell 会话实现。

要求：
1. **SSH 库**：优先用 **Citadel**（基于 swift-nio-ssh，SPM 引入）。若 Citadel 无法开交互式 PTY shell，则直接用 `apple/swift-nio-ssh`。把依赖加进 `Package.swift`。
2. 实现文件放 `Sources/PixShell/SSH/CitadelSSHSession.swift`（或按所选库命名）。
3. 支持**密码**与**私钥(PEM 内容)**两种认证。
4. `connectAndOpenShell`：TCP 连接 → SSH 握手 → 请求 PTY（term/cols/rows）→ 请求 shell → 就绪后主线程回调 `sshSessionDidOpenShell`。
5. 远端输出 → 主线程 `didReceive`；`send()` 把字节写给远端；`resize()` 发 window-change；`close()` 干净关闭；错误/关闭走 `didCloseWith`。
6. 所有 delegate 回调**在主线程**投递。
7. 不要动 `main.swift` / 其他文件；只加 SSH 实现 + 改 `Package.swift` 依赖。
8. 完成后**必须** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` 通过，把编译错误全部修掉。

## 验收
- `swift build` 绿。
- 提供一个 3~5 行注释说明：用了哪个库、PTY/shell 是怎么开的、认证走哪条路径。
