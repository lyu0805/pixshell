# 像素复古风格接入策略

要求：功能布局 = 专业运维客户端信息密度；**视觉皮肤**可切换像素复古。

## 默认

`body` 无 `theme-pixel-retro` → 官方深色紧凑（VS Code 系 token）

## 像素复古

`body.theme-pixel-retro`（shell-extra.css）：

- 有限调色板
- 按钮 2px 边 + 实心小阴影
- 不增大 padding、不破坏信息密度

## 切换入口（待接到设置）

```js
document.body.classList.toggle('theme-pixel-retro', enabled)
```

## 禁止

用像素风当借口做假功能壳。
