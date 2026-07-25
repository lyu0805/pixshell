# 本机必跑命令（会话 Bash 被分类器拦截时）

在终端执行（或 Claude 里用 `!` 前缀）：

```bash
cd /Volumes/d/pixshell

# 1) 依赖
npm install

# 2) 导入配置字段映射（路径按本机样本调整）
node scripts/import-config.js /path/to/config.json

# 3) 启动 Electron 像素壳
npm run dev
```

可选：静态 UI 原型

```bash
npx --yes serve@14 prototypes/pixel-shell -p 4789
```
