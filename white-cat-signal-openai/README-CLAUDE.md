# 白猫信号员 · OpenAI Pets v2

已在 ChatGPT Work 云端宠物库创建并选中。云端稳定宠物 ID：`pet_6ad6fb5cb244819195b7aee2bbf84e30`。这不等于桌面悬浮宠物已被选中。
Codex 桌面版现已另行安装到 `/Users/ghostxmerlin/.codex/pets/white-cat-signal/`，本地标识为 `white-cat-signal`；用户仍需在 **设置 → Pets / 宠物 → Refresh / 刷新** 中选择「白猫信号员」，再显示宠物。自动操作工具禁止控制 Codex 自身界面，因此尚未验证客户端实际选中或悬浮显示。
最终图集、质量检查、三位独立方向审阅、服务端预检及桌面适配图集校验均已通过；具体记录见 `DELIVERY.json`。

本包提供白猫与右侧高铁路信号灯的 OpenAI Pets v2 动画资源。**接入参数以 `integration.json` 为准；交付检查、上传、创建或选中状态以 `DELIVERY.json` 为准。** `DELIVERY.json` 尚不存在时，不应把本说明当作这些步骤已完成的证明。`white-cat-signal` 是本地素材标识，不是已创建的 Pets 服务 ID。

## 最终文件约定

下列路径均相对本包根目录：

| 路径 | 用途 |
|---|---|
| `integration.json` | 网格、状态、方向坐标、逐帧时长与接入映射 |
| `final/spritesheet-extended.png` | **运行时美术的权威源 PNG**，使用交付记录对应的精确最终字节 |
| `final-frames/<state>/00.png` | 从最终 PNG 解码后导出的完整 192 × 208 单元格 |
| `final-frames/look/00.png` 至 `15.png` | 按顺时针顺序导出的十六个完整方向单元格 |
| `preview/preview-manifest.json` | 预览所用最终 PNG 的 SHA-256、帧数、时长和输出清单 |
| `preview/` | 逐状态 GIF、全状态 GIF/MP4、方向循环、idle→jump→idle 和标注静帧 |
| `qa/` | 官方检查报告与视觉审阅记录 |
| `pet_request.json`、`imagegen-jobs.json` | 制作约束、各组源图与依赖关系 |
| `decoded/`、`references/`、`source/`、`prompts/` | 制作源图、参考与提示词 |

本次没有修改应用代码。Claude 负责 CodeIsland 的加载、状态选择和播放。`decoded/` 中的青色源条及预览 GIF/MP4 是制作或检查材料；运行时读取最终 PNG，或从它导出的 `final-frames/`。

## Codex 桌面安装包

`desktop/white-cat-signal/` 内的 `pet.json` 与 `spritesheet.webp` 是可直接安装的本地包，详见 `desktop/README.md`。复制整个 `white-cat-signal` 目录到 `${CODEX_HOME:-$HOME/.codex}/pets/`，然后在设置中刷新并选中。桌面本地宠物与 ChatGPT Work 云端宠物分开安装和选择。

桌面图集沿用全部 73 个原始动画/方向帧，另按当前 `hatch-pet` 官方组装器要求，在第 0 行、第 6 列放入第 0 行、第 0 列的中立姿态副本。它有 74 个有内容格、14 个空格；中立姿态不加入六帧 idle 循环。无损编码检查确认仅此格变化，其余帧逐像素一致。桌面 WebP 的 SHA-256 和校验见 `qa/desktop-adaptation.json`、`qa/desktop-atlas-validation.json`。

下面的 CodeIsland 接入参数仍指向原始 PNG 和 `final-frames/`，其 73 帧、15 个空格的约定保持不变。不要把桌面适配图集重新上传替换云端图集。

## 固定网格

v2 图为 **1536 × 2288 px**、**8 列 × 11 行**，每格 **192 × 208 px**，RGBA 透明 PNG。行列均从 0 开始；左上为原点，x 向右、y 向下。第 r 行第 c 列矩形为 `[c*192, r*208, 192, 208]`，格式为 `[x, y, width, height]`。

所有帧保留整格透明留白，并采用同一显示缩放与位置变换。不要按可见内容逐帧裁紧、重新居中或独立放大；跳跃高度保存在单元格内。也不要镜像向右移动帧来代替向左移动帧，信号灯必须始终位于屏幕右侧。

| 行 | 状态 | 有效帧数 | 用途 |
|---|---|---:|---|
| 0 | idle | 6 | 默认卧姿呼吸，蓝灯 |
| 1 | running-right | 8 | 向右移动 |
| 2 | running-left | 8 | 向左移动，灯仍在右侧 |
| 3 | waving | 4 | 挥爪打招呼 |
| 4 | jumping | 5 | 整组短暂跃起并落地 |
| 5 | failed | 8 | 失败反应，红灯 |
| 6 | waiting | 6 | 等待批准或回答，红灯 |
| 7 | running | 6 | 认真工作，绿灯；不是跑步 |
| 8 | review | 6 | 查看结果，绿灯 |
| 9 | look directions A | 8 | 000° 至 157.5° |
| 10 | look directions B | 8 | 180° 至 337.5° |

每行从最左侧开始使用指定帧数，剩余格不播放。前九行 57 帧，加十六个方向帧，共 **73 个有效帧、15 个透明空格**。

## 朝向选择

朝向以屏幕坐标顺时针排列：**000° 上、090° 右、180° 下、270° 左**，每格相差 22.5°。`integration.json` 的 `directions.poses` 提供每个方向的角度、标签、行列、矩形和导出路径。

第 9 行是 `000, 022.5, 045, 067.5, 090, 112.5, 135, 157.5`；第 10 行是 `180, 202.5, 225, 247.5, 270, 292.5, 315, 337.5`。

若使用指针，取 `dx = pointerX - referenceX`、`dy = pointerY - referenceY`，计算 `angle = (degrees(atan2(dx, -dy)) + 360) % 360`，最近帧索引为 `floor((angle + 11.25) / 22.5) % 16`。应用自行选择参考点和中心死区；死区内回到 idle。**000° 是向上，不是中立帧。** 方向帧用于按指针选择，方向循环 GIF 只展示资源顺序。

## CodeIsland 状态选择

沿用现有五个 `AgentStatus`：

| 现有状态 | 动画行 | 灯色 |
|---|---|---|
| `idle` | `idle`，第 0 行 | 蓝 |
| `processing`、`running` | `running`，第 7 行 | 绿 |
| `waitingApproval`、`waitingQuestion` | `waiting`，第 6 行 | 红 |

保留原有 UI 文字以区分思考/执行、批准/回答。第 7 行 `running` 表示处理任务，不表示脚步奔跑。其他行是可选动作资源，不要求新增同名 `AgentStatus`。整组猫与高信号灯需要合适的独立显示区域，保留完整 192:208 单元格比例。

## 时序

`integration.json` 的 `standard_states[].frame_durations_ms` 按官方 work-pets 0.1.6 的 `render_animation_previews.py` 原样记录；数组与每行帧顺序一一对应。应用按毫秒时长推进，不必使用某个固定全局帧率。继续遵守现有减少动态效果、休眠和可见性控制；减少动态效果时显示 `idle` 第 0 帧。

## 独立静态素材包

原先的 **`white-cat-signal-pet` 是另一个包**，采用 1600 × 1120 分层静态 PNG，其资源与锚点由该包的 `pet-manifest.json` 定义。它的灯色切换 GIF 不是猫动作动画，也不能当作本包的 v2 单元格。

本动画图集没有离线/全灭灯行。若需要断连回退，可由应用选择独立静态包中的 `states/offline.png`；不要为此新增现有 `AgentStatus` 枚举成员。本包的加载不依赖静态包，只有显式采用此回退时才需另行带上它。
