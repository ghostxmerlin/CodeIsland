# 给 Claude 的素材接入说明

这是一套供 **CodeIsland agent 状态桌宠**使用的分层美术素材：一只纯白、圆胖、熟睡的猫，靠在高大复古铁路信号灯旁，三盏灯分别为红、绿、蓝。美术使用内置 OpenAI imagegen 生成，方向为温暖手绘、圆润的奇幻动画白猫。

本次交付仅制作素材，**尚未接入或修改应用代码**；Claude 负责后续接入。它是 CodeIsland 专用素材包，不要求、也不声称符合 ChatGPT Work Pets 的 11 行 v2 格式。

## 文件与坐标

**以 `pet-manifest.json` 为最终文件清单、画布尺寸及锚点的唯一依据。** 下表为素材命名与用途约定；如有调整，以清单为准。

| 文件 | 用途 |
| --- | --- |
| `master.png` | 猫与信号灯的完整底图，所有灯未点亮 |
| `layers/cat.png` | 独立猫图层 |
| `layers/signal-off.png` | 独立未点亮信号灯图层 |
| `layers/light-red.png` | 红灯玻璃亮起的透明叠加层 |
| `layers/light-green.png` | 绿灯玻璃亮起的透明叠加层 |
| `layers/light-blue.png` | 蓝灯玻璃亮起的透明叠加层 |
| `states/idle-blue.png` | 蓝灯空闲状态完整图 |
| `states/working-green.png` | 绿灯工作状态完整图 |
| `states/attention-red.png` | 红灯等待用户状态完整图 |
| `states/offline.png` | 无会话或断连时的未点亮完整图 |
| `preview/states.png` | 状态对照预览 |
| `preview/states.gif` | 状态切换演示 |

角色、信号灯、灯光与完整状态 PNG 采用相同的 RGBA 画布和坐标系：原点位于左上角，x 向右、y 向下。分层 PNG 保留整幅画布的透明留白，不按可见内容单独裁剪。读取清单中的尺寸和锚点；各层使用同一个等比缩放与平移变换，灯光才能准确覆盖灯罩。

交付画布为 **1600 × 1120 px**，建议桌面显示约 **400 × 280 pt**，按实际桌面空间等比缩放。`lampOverlayRects` 使用 `[x, y, width, height]`；`visibleBounds` 使用 `[left, top, right, bottom]`。图层不需要根据这些矩形再次裁切，整幅叠放即可。

预览图和 GIF 仅用于观看。**GIF 展示灯色切换，不是猫的逐帧动画，也不应作为运行时素材。**

## 状态映射

| 应用状态 | 素材状态 | UI 文字建议 |
| --- | --- | --- |
| `idle` | `idle-blue` | 空闲 |
| `processing` | `working-green` | 思考中 |
| `running` | `working-green` | 执行中 |
| `waitingApproval` | `attention-red` | 等待批准 |
| `waitingQuestion` | `attention-red` | 等待回答 |
| 无会话或连接断开 | `offline` | 未连接 |

多个状态可以共用灯色，应用仍应保留原有状态文字，尤其区分“等待批准”与“等待回答”。`offline` 是素材和连接层面的回退状态，**不是现有 `AgentStatus` 枚举成员**。

映射示意，具体类型与资源加载方式由接入代码确定：

```swift
// 无会话或断连时，先在调用方选择 "offline"。
switch status {
case .idle:
    return "idle-blue"
case .processing, .running:
    return "working-green"
case .waitingApproval, .waitingQuestion:
    return "attention-red"
}
```

## 接入选择

1. **完整状态图**：直接切换 `states/` 中的 PNG，最容易保持美术布局一致，适合首轮接入。
2. **分层合成**：依次绘制未点亮信号灯、猫，以及至多一个当前灯色叠加层。断连时不绘制灯光层。所有层沿用同一画布与适配变换；如清单给出图层顺序，以清单为准。

如需呼吸效果，可在运行时对猫图层做轻微缩放，并使用清单中的猫锚点；信号灯与灯光层保持固定。素材未提供烘焙的猫帧动画，请勿把状态图当作猫动作序列。

## 现有代码的适配边界

- `Sources/CodeIsland/MascotView.swift` 目前默认约 27 pt，现有调用点约 18–40 pt，用于路由程序化 SwiftUI 吉祥物。
- `PixelCharacterView.swift` 中的 `ClawdView` 使用 Canvas 与正方形裁切。整幅“猫 + 高信号灯”需要独立桌面展示区域，并保留原始宽高比；直接塞入现有 27 pt 图标位置会损失细节或被裁切。
- `Sources/CodeIslandCore/Models.swift` 定义上述五个 agent 状态；接入时沿用这些状态，不为离线素材擅自新增枚举成员。
- `Package.swift` 已配置复制 `Resources`。Claude 可将最终素材纳入相应资源目录，并按实际 target/bundle 验证加载路径。
- 如添加运行时呼吸或过渡效果，应沿用 `MascotTimeline.swift` 的最高 20 fps、休眠、可见性与“减少动态效果”控制。

最终素材的透明度、边缘、图层对齐与视觉检查由交付方完成；本文不构成这些检查已通过的声明。接入后仍需在目标桌面尺寸和深浅背景上检查显示效果。

`validation.json` 记录本地素材检查和文件 SHA-256；`VISUAL-QA.md` 记录视觉检查。`assemble_assets.py` 只对已生成的图像进行分离、缩放、排布与合成，不绘制角色。重建依赖 Pillow 与 numpy，不需要再次调用图像模型。
