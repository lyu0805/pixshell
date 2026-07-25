# 团队任务板

## 角色与文件边界（减少冲突）

| 角色 | 可写路径 | 当前目标 |
|------|----------|----------|
| research | `local research notes`, local research archives (not shipped) | 历史调研存档，不进产品代码 |
| arch | `docs/architecture/**`, `CLAUDE.md` | monorepo 映射、Electron 基线 |
| ui | `packages/ui-pixel/**`, `prototypes/**`, `docs/architecture/pixel-ui.md` | 像素壳打磨 |
| core | `packages/core/**`, `packages/command-box/**` | 模型/导入/命令框 |
| protocol | `packages/ssh/**`, `packages/monitor/**` | ssh2 真实现、监控采集 |
| app | `packages/app/**` | Electron 入口 |

## 并行波次 1（进行中）

1. research：历史笔记仅入 archive
2. ui：原型可点
3. core：settings/session/hosts 已齐
4. protocol：真 SSH + monitor 契约已齐

## 并行波次 2（下一步）

1. app：electron-vite 脚手架
2. protocol：ssh2 真连接
3. ui：xterm 挂到终端区
4. core：conn 解析/导入

## 完成定义

见 `docs/plan/implementation.md` P0 验收。
