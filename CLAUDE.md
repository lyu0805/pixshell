# PixShell 项目指令

## 目标
PixShell：跨平台 SSH 客户端。经典运维客户端交互密度；原生 ssh2。
代码写在 `/Volumes/d/pixshell/`。

## 架构
- monorepo 领域包 + Electron 主壳
- SSH：ssh2；终端：xterm；SFTP：ssh2 SFTP（非 shell ls 冒充）
- 运行：NTFS 源码可同步到 APFS `~/Library/Application Support/PixShell/app`

## 启动
```bash
node /Volumes/d/pixshell/start.js
```

## 约束
- 注释、文件名、文件夹名、包名、产品文案统一使用 **PixShell**
- 禁止使用任何第三方商业客户端商标/产品名作为标识
- 禁止在公开仓库写入第三方产品名或来源分析类措辞
- 禁止上传：`代码说明概要.md`、`logs/` 运行日志、SSH 主机/密钥/密码等私密信息
