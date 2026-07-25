# PixShell 功能矩阵 → 实现规格

来源：产品能力清单（运维 SSH 客户端常见能力面，2025–2026）  
样本路径仅作导入测试用，产品代码不绑定第三方发行包。

## 产品定位

一体化服务器 / 网络管理软件：SSH 客户端 + 运维开发工具集。

## 主要特性（23 项）

| # | 原名 | 说明 | 优先级 | 基线 | 实现包 |
|---|------|------|--------|------|--------|
| 1 | 多平台支持 | Win / macOS / Linux | P0 | Electron | `app` |
| 2 | 多标签,批量服务器管理 | 标签 + 主机树/列表 | P0 | tabs | `host-manager` |
| 3 | 登录 ssh 和 Windows 远程桌面 | SSH + RDP | P0/P2 | packages/ssh | `ssh` / `rdp` |
| 4 | 平滑字体,100+ 配色 | 字体与配色方案 | P1 | color schemes | `ui-pixel` + terminal theme |
| 5 | 终端,sftp 同屏,同步切换目录 | 核心差异化 | P0 | 需新建 | `sftp-panel` |
| 6 | 命令自动提示,智能匹配 | 命令补全 | P0 | 弱 | `command-box` |
| 7 | sftp 优化加载 | 快速列目录/打开 | P0 | 需加强 | `ssh` / `sftp-panel` |
| 8 | 服务器网络/性能实时监控 | 无服务端插件 | P1 | 无 | `monitor` |
| 9 | 海外服务器加速 | RDP/SSH 加速 | P2 | 无 | 后期 |
| 10 | 内存/CPU, Ping, Trace | 监控子项 | P1 | 无 | `monitor` |
| 11 | 实时硬盘监控 | 磁盘 | P1 | 无 | `monitor` |
| 12 | 进程管理器 | 远程进程 | P1 | 无 | `monitor` |
| 13 | 快捷命令面板 | 数十命令同屏 | P0 | quick commands | `quick-commands` |
| 14 | 内置文本编辑器 | 高亮/折叠/搜索 | P1 | 无/弱 | `editor` |
| 15 | 代理服务器 | SSH/RDP 代理 | P1 | ssh proxy | `proxy` |
| 16 | 打包传输,自动压缩解压 | 批量文件 | P1 | 无 | `transfer` |
| 17 | rz,sz (zmodem) | 文件传输协议 | P1 | zmodem 可选 | `ssh` |
| 18 | 多地点 ping 监控 | 多探测点 | P2 | 无 | `monitor` |
| 19 | 命令输入框补全/历史 | 底部命令区 | P0 | 无（底栏特色） | `command-box` |
| 20 | 自定义命令参数 | 动态生成命令 | P1 | 无 | `command-box` / `quick-commands` |
| 21 | 终端背景图+模糊+文字阴影 | 视觉 | P1 | 主题可扩展 | `ui-pixel` |
| 22 | 一键系统信息 | sysinfo | P1 | 无 | `monitor` |
| 23 | 命令框快速选主机文件 | 路径选择 | P1 | 无 | `command-box` |

## 特色能力（额外）

| 能力 | 优先级 | 备注 |
|------|--------|------|
| 云端同步 | P2 | `sync_config` 字段可导入 |
| 免费海外 RDP 加速 | P2 | 依赖外部服务，可做接口预留 |
| 本地化命令输入框 | P0 | 与 #19 合并 |

## 从 config.json 反推的 UI 结构

```
MainWindow
├── left_side (width ~159)
│   ├── host tree / connection list (connection_filter)
│   └── left_side_bottom (height ~140)
├── center
│   ├── tab strip
│   ├── tab content
│   │   ├── tab_terminal       bottom_height~250, SFTP/命令底栏
│   │   ├── tab_tasktab
│   │   ├── tab_host_detect_tab
│   │   ├── tab_net_mananagertab
│   │   └── tab_newtab
│   └── command_divider / command_input 区
└── status / tray (close_to_tray, confirm_close)
```

### 关键配置字段

- `show_sidebar`, `layout.left_side_width`
- `command_input`：`clean_after_send_command`, `ignore_blankl_line`, `append_cr`, `send_command_key`
- `command_input_show_hide`, `command_prompt_enable`, `command_input_full_path`
- `quick_commands`, `selected_cmd_group`, `cmd_history`
- `bg_img_enable`, `bg_img`, `bg_img_blur_level`
- `proxy_list`, `secret_key_list`
- `sync_config`：auto_sync / smtp / ssl
- `hotkeys2`：键码映射
- `theme`, `en_font_name`, `cn_font_name`, `font_size`
- `editor_type`, editor window bounds
- `pack_trans`, download_path / recent paths
- `bottom_bar_show_type`, `right_button_click_action`

## 交互必须对齐的细节

1. **终端 + SFTP 同屏**：切换终端 cwd 时 SFTP 同步；SFTP 进入目录可影响终端（可配置）。
2. **底部命令输入框**：非纯终端 TTY 输入，独立输入区，支持补全/历史/左右键字段选择/主机文件快选。
3. **快捷命令面板**：分组，可带参数模板。
4. **主机侧栏**：过滤、批量操作、连接状态。
5. **监控无需装 agent**：通过 SSH 执行标准命令采集（`top`/`ps`/`df`/`cat /proc/*` 等）。
6. **关闭行为**：确认关闭、托盘、连接后关窗等开关。
