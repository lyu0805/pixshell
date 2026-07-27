# PixShell

PixShell 是一款原生的高性能跨平台终端与运维工具客户端，致力于为开发者和运维人员提供极致流畅的 SSH、SFTP 与服务器管理体验。

基于系统原生 UI 框架彻底重构，目前支持 macOS 与 Windows 双平台原生版本。

## 核心特性

- 🚀 **原生体验**：
  - macOS 版本基于 Swift / AppKit 开发，极致响应，融入 Apple 生态。
  - Windows 版本基于 C# WPF / WebView2，快速轻量，界面清爽。
- 💻 **内置 xterm.js 终端**：提供完整的 ANSI / 256 色 / TrueColor 支持，以及强大的自绘和快速缩放体验。
- 📁 **内置 SFTP 面板**：无缝的上传、下载与远端文件管理。
- 🎨 **主题管理**：深浅色模式支持，内置数十款经典终端配色。
- 🤖 **进阶功能**：支持多会话管理、自动状态监控、密钥管理以及智能执行等丰富能力。

## 目录结构与架构

本仓库采用多平台独立目录进行管理（非强迫性的像素级同构 UI）：

- `mac/`：macOS 原生代码工程（依赖 SwiftPM）。
- `win/`：Windows 原生代码工程（依赖 .NET 9）。

> **设计理念**：UI 排版、交互控件及功能编排允许存在合理的平台差异，以贴合各自操作系统的原生设计规范；但核心协议、数据结构与终端底层对接逻辑在两端保持完全一致。

## 本地构建指南

### macOS 环境

**前置要求**：安装最新版 Xcode 和完整 Swift Toolchain。

```bash
cd mac
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# 编译 release 产物
swift build -c release
# 打包为 macOS 可执行 .app
bash scripts/package-mac.sh release

# 运行测试
open dist/PixShell.app
```

### Windows 环境

**前置要求**：安装 Windows x64 系统，以及 .NET 9 SDK。

```powershell
cd win
dotnet restore PixShell.csproj -r win-x64
dotnet build PixShell.csproj -c Release -r win-x64 --self-contained false -nologo
dotnet publish PixShell.csproj -c Release -r win-x64 --self-contained false -o publish/win-x64

# 启动程序
.\publish\win-x64\PixShell.exe
```
*(注：如果目标机器尚未安装 Edge WebView2 环境，可通过 `winget install Microsoft.EdgeWebView2Runtime` 一键补齐。)*

## CI/CD 自动构建

本项目支持通过 GitHub Actions 进行自动化云端多平台编译发布。每一次推送代码时，都会在 `.github/workflows/build.yml` 的调度下并行生成以下三种架构的产物：

| 平台目标 | 运行环境 (Runner) | 构架产物 |
|---|---|---|
| **mac-arm64** | `macos-15` (Apple Silicon) | `PixShell-mac-arm64` |
| **mac-x64** | `macos-15-intel` | `PixShell-mac-x64` |
| **win-x64** | `windows-2025` | `PixShell-win-x64` |

> ⚠️ 当前的自动构建 CI 产物均为 Unsigned (未签名) 的纯净安装包形式，通常可作为体验或内部测试使用。正式对公分发前，仍需执行额外的 macOS Developer ID 公证和 Windows 安装包代码签发。

