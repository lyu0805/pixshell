# PixShell 布局规格（专业运维密度）

来源：产品布局目标 + 本机截图对照（像素/紧凑主题）

## 主界面结构

| 区域 | 颜色 | 说明 |
|------|------|------|
| 菜单/工具栏 | 浅灰 #f0f0f0 | 文件/连接… + 图标工具条 |
| 左侧主机树 | 白/浅灰 | 分组 + 主机 |
| 左侧监控条 | #f0f4f7 | IP、负载、CPU/内存进度条、进程 TOP、分区 |
| 中央终端 | 深青黑 #183040 | 黑底终端主区域 |
| 底栏 SFTP | 浅灰/白 | 左目录树 + 右文件表（名称/大小/时间/权限） |
| 命令栏 | 浅灰 | 「命令」+ 输入框 + 发送 |
| 状态栏 | 蓝 #0078d4 | 底部状态 |

## 实现文件

- `packages/app/renderer/index.html` — 结构
- `packages/app/renderer/shell.css` — 浅色 chrome
- `packages/app/renderer/features-extra.js` — 左侧监控采集（若存在）
- `packages/app/main/main.js` — backgroundColor #f0f0f0

## 验证（2026-07-24 23:00）

Electron 窗口截图采样：

- side: 白 (255,255,255)
- term: (24,48,64)
- bottom: (240,240,240)
- status: (0,120,212)
