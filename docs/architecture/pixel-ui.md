# 像素复古 UI 规范

参考：https://segmentfault.com/a/1190000047694174

## 风格定位

**HD 像素 + 轻微 neo-brutal 硬阴影**，服务运维工具可读性：

- 不是纯红白机游戏 UI（避免信息密度过低）
- 不是 Win98 皮肤仿制（避免与现代紧凑运维布局冲突）
- 是：有限调色板、硬边框、实心阴影、像素图标、等宽数据区

## Token

见 `packages/ui-pixel/src/tokens.css`。

| Token | 值 | 用途 |
|-------|-----|------|
| bg-0 | `#0d1117` | 应用底 |
| bg-1 | `#141b24` | 侧栏/面板 |
| bg-2 | `#1c2633` | 抬起面 |
| accent | `#ffcc33` | 焦点/激活 |
| accent-2 | `#3ddc97` | 成功/在线 |
| danger | `#ff5c5c` | 错误/断开 |
| info | `#5cb3ff` | 信息/监控 |
| border | `#3d4f66` | 硬边 |
| border-hi | `#7ec8ff` | 按钮描边 |

## 组件

- `.px-btn` / `.px-btn.primary`
- `.px-input`
- `.px-tab` / `.active`
- `.px-titlebar`
- `.px-status`
- `.px-panel`
- 壳布局：`.fs-shell` 等（`shell.css`）

## 布局（专业运维密度）

1. 左：主机树 + 底信息区
2. 上：多标签
3. 中上：终端
4. 中下：SFTP | 监控/任务（可切换）
5. 底：独立命令输入框（非 TTY 内输入替代，而是底栏特色）
6. 最底：状态条

## 字体

- UI：Fusion Pixel / Ark Pixel / 系统 UI 回退
- 终端：DejaVu Sans Mono + 中文等宽
- 装饰标题可选用 Press Start 2P（慎用，仅标题）

## 可引入库（可选）

| 库 | 何时用 |
|----|--------|
| NES.css | 仅按钮/容器灵感，不整站引入 |
| RetroUI | React 化后可参考 |
| 98.css | 不采用（风格偏差） |

当前阶段：**自研 tokens + 壳 CSS**，零依赖可预览。

## 预览

```bash
cd /Volumes/d/pixshell
npx --yes serve@14 prototypes/pixel-shell -p 4789
# open http://127.0.0.1:4789
```
