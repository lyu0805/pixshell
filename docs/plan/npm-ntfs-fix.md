# 安装失败排查

## 你遇到的两个错误

### 1) `EACCES` / `EEXIST` on `~/.npm/_cacache`
全局 npm 缓存里有 **root 属主** 文件（以前 `sudo npm`）。

### 2) `ENOENT mkdir .../Volumes/d/pixshell/node_modules/...`
`/Volumes/d` 是 **Tuxera NTFS**。npm 在 NTFS 上大量并发 `mkdir` 经常失败。

## 当前方案（已写进 start.js）

1. 检测到源码在 `/Volumes/d` → **不在 NTFS 上 npm install**
2. 同步到 APFS：
   `~/Library/Application Support/PixShell/app`
3. 在该目录 `npm install` + 启动 Electron

源码仍在 `/Volumes/d/pixshell` 编辑；运行副本在用户目录。

## 请再试

双击 **`启动 PixShell.command`**  
或：

```bash
node /Volumes/d/pixshell/start.js
```

首次会 rsync + npm install（在 APFS 上，应可成功）。

## 若仍失败，手动三行

```bash
RUNTIME="$HOME/Library/Application Support/PixShell/app"
mkdir -p "$RUNTIME"
rsync -a --delete --exclude node_modules --exclude .npm-cache /Volumes/d/pixshell/ "$RUNTIME/"
cd "$RUNTIME" && npm install --cache ./.npm-cache
node start.js
```
