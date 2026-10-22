# 白猫信号员 · Codex 桌面版

本目录的 `white-cat-signal/` 是官方 `hatch-pet` 格式的本地宠物包，包含 `pet.json` 与 `spritesheet.webp`。本机已安装到：

```text
/Users/ghostxmerlin/.codex/pets/white-cat-signal/
```

## 启用

1. 打开 Codex / ChatGPT 桌面应用的 **设置 → Pets / 宠物**。
2. 点 **Refresh / 刷新**，选择 **白猫信号员**。
3. 点显示宠物，或通过命令菜单选择 **Show pet**。

目前完成的是文件安装及本地格式校验；尚未验证桌面应用实际选中和悬浮显示。自动操作工具禁止控制 Codex 自身界面，最后的设置操作由用户完成。

迁移到另一台电脑时，把 `white-cat-signal/` 放到该电脑的 `${CODEX_HOME:-$HOME/.codex}/pets/` 下，再按上述步骤选择。遇到同名目录时先检查已有内容，不要直接覆盖。

## 格式

- 本地 ID：`white-cat-signal`；显示名称：白猫信号员。
- `spriteVersionNumber: 2` 必须保留，否则高为 2288 像素的图集会按 v1 格式被拒绝。
- 无损透明 WebP，1536 × 2288，8 列 × 11 行，每格 192 × 208。
- 原始 73 个动画/方向帧全部保持不变。
- 额外中立帧位于第 0 行、第 6 列，来源是 idle 第 0 帧。该格不是 idle 的第 7 帧，不加入循环。
- 实际 74 个有内容格、14 个透明空格。
- `../qa/desktop-atlas-validation.json`：官方 `hatch-pet` 校验通过，零错误、零警告。
- `../qa/desktop-adaptation.json`：仅中立格变化及其余帧逐像素一致的验证记录。

本地桌面选择与 ChatGPT Work 云端宠物库的选择是两件事。云端记录保持原样；CodeIsland 接入继续参照 `../README-CLAUDE.md` 和 `../integration.json`。

官方说明：https://learn.chatgpt.com/docs/pets
