# Windows 构建说明

本公开仓库不记录个人开发机、内网地址、密钥、远程连接别名或运维通道。

Windows 侧请在标准 Windows x64 环境中构建：

```powershell
cd win
dotnet restore PixShell.csproj -r win-x64
dotnet build PixShell.csproj -c Release -r win-x64 --self-contained false
dotnet publish PixShell.csproj -c Release -r win-x64 --self-contained false -o publish/win-x64
```

GitHub Actions 使用 `windows-2025` runner 生成 `PixShell-win-x64` 产物。
