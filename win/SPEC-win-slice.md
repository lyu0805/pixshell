# 任务：PixShell Windows 原生纵向切片（WPF + WebView2 + xterm.js）

## 目标
在 `<repo>\win` 建一个**能编译能运行**的 WPF 纵向切片，作为 Windows 原生 SSH 客户端的地基。这一步**不接 SSH**，只证明：WPF 窗口 + WebView2 承载 xterm.js 终端 + 渲染彩色 banner。对标 mac 侧已跑通的同款切片。

## 环境（已就绪）
- .NET SDK 9.0.316（`dotnet` 在 PATH）
- WebView2 运行时已安装
- node/npm/git 可用
- 无 Visual Studio → 只能用 `dotnet build` / `dotnet run` 命令行

## 要求
1. 项目：`<repo>\win\PixShell.csproj`，`net9.0-windows`，`<UseWPF>true</UseWPF>`，`<OutputType>WinExe</OutputType>`。
2. NuGet 依赖：
   - `Microsoft.Web.WebView2`（承载终端）
   - `SSH.NET`（先加引用，本切片**不使用**，为下一步预留）
3. `App.xaml` / `App.xaml.cs` 标准 WPF 启动。
4. `MainWindow.xaml`：整窗一个 `WebView2` 控件，标题 "PixShell — native (Windows)"。
5. `web\terminal.html` + 本地 vendored 的 xterm.js：
   - 用 npm 拉 `@xterm/xterm`（或从 CDN 下载 xterm.js + xterm.css 到 `web\`，**必须本地内嵌，不许运行时依赖外网**）。
   - 页面初始化 xterm，写入彩色 banner（用 ANSI 转义）：
     ```
     \x1b[1;36mPixShell\x1b[0m native (Windows) — WebView2 + xterm.js 渲染 OK
     \x1b[32m✓\x1b[0m 纵向切片: WPF 窗口 + 终端已跑通
     \x1b[33m下一步:\x1b[0m 接入 SSH.NET 会话 (shell stream)
     ```
6. `MainWindow.xaml.cs`：初始化 WebView2，`EnsureCoreWebView2Async` 后导航到本地 `web\terminal.html`（用 `SetVirtualHostNameToFolderMapping` 或 file:// 均可，只要能加载本地 xterm）。

## 验收（必须自测）
- 在 `<repo>\win` 运行 `dotnet build`，**必须绿**，把所有错误修掉。
- 把 `dotnet build` 的最终输出写到 `<repo>\win\_build_result.txt`。
- 不要改本文件；产出物是上面的项目文件 + web 资源。
