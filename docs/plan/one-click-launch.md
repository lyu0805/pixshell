# macOS .command 一键启动

## 文件

| 文件 | 用途 |
|------|------|
| `启动 PixShell.command` | 检查 Node → 缺依赖则 npm install → 启动 Electron |
| `安装依赖.command` | 只跑 npm install |
| `start.command` | 英文名转发到中文启动脚本 |

## 赋予执行权限（只需一次）

当前会话若无法 chmod，请在「终端」执行：

```bash
chmod +x "/Volumes/d/pixshell/启动 PixShell.command" \
         "/Volumes/d/pixshell/安装依赖.command" \
         "/Volumes/d/pixshell/start.command"
```

或：

```bash
cd /Volumes/d/pixshell && npm run chmod:command
```

## 使用

Finder 中双击 `启动 PixShell.command`。  
会打开「终端」窗口显示日志；关闭 Electron 窗口即结束。

## 常见问题

1. **双击闪退 / 用文本编辑器打开**  
   未加执行位 → 执行上面的 `chmod +x`。

2. **“无法打开，因为来自身份不明的开发者”**  
   右键 → 打开 → 仍要打开。NTFS/网络盘上的脚本有时会被隔离。

3. **找不到 node**  
   安装 Node 20+：https://nodejs.org/ 或 `brew install node`。

4. **npm install 很慢**  
   首次正常；可先跑 `安装依赖.command`，完成后再启动。

5. **electron 下载失败**  
   配置镜像后重试，例如：
   ```bash
   export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
   cd /Volumes/d/pixshell && npm install
   ```
