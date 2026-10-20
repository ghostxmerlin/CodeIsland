# 图像生成记录

使用内置 OpenAI `image_gen`，每次均开启透明背景。参考附件仅用于理解卧猫姿态，成品没有使用附件中的图片像素。下述最后一次主图修订以已生成的白猫与矮信号灯主图作为输入。

## 主图最终修订提示词

```text
Edit the provided desktop-pet illustration. User correction: THE RAILWAY SIGNAL MUST BE SIGNIFICANTLY TALLER AND BIGGER. Preserve the exact lovable sleeping pure-white plump cat identity, face, fluffy white fur, paws, tail, drawing style and peaceful lying pose. Recompose with the cat in the lower-left and a large tall railway signal standing on the right on the same ground baseline. Signal overall height about 1.55 to 1.65 TIMES the cat's full resting height, so the top of the signal is clearly well above the ears and back. Enlarge signal housing and each lens, roughly 1.4 times the current width, give it a noticeably longer substantial post. The lamp should occupy about 27% of total artwork width and cat about 65% with a clean transparent gap. Keep all feet and cat tail wholly visible and fully inside frame, generous 50px outer clear margins. Railway signal still exactly three large circular lenses vertically RED TOP, GREEN MIDDLE, BLUE BOTTOM, unlit/dark colored glass with small highlights, rounded vintage charcoal housing and sturdy foot. Match the soft hand-painted Japanese animated fantasy-film illustration style. No other changes. Deliver a single compact composition with ACTUAL CLEAN TRANSPARENCY everywhere outside the cat and signal, NO backdrop, NO diffuse haze, NO floor, NO shadows, NO glow, NO text or watermark. Crisp clean cutout alpha boundary; solid opaque interior fur and metal. Wide landscape 3:2 canvas.
```

输出为 `base-tall.png`。生成图的外缘留白不足，因此交付时只增加了透明画布边距，不裁切角色。

## 灯片提示摘要

灯片素材来自独立生成任务，参照同一主图的手绘玻璃质感。以下为要求摘要，完整调用提示词保存在同目录 `lamp-prompts.txt`：

- 点亮版本 `lamp-lenses.png`：恰好三枚分开的圆形玻璃灯片，横向红、绿、蓝；同心玻璃纹理、左上反光、鲜明内部光源；不含灯壳、猫、文字、背景或外溢光晕。
- 熄灭版本 `lamp-lenses-off.png`：以点亮灯片为输入，保留形状和顺序；全部改为近黑的暗酒红、深绿、海军蓝玻璃，微弱反射，无发光核心。

图层合成使用生成的亮灯片和暗灯片，不以代码生成灯光。完整猫、灯架与画面位置在各状态之间保持一致。
