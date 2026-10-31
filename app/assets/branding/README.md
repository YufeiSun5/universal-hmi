# Universal HMI 应用图标

2026-10-29 使用 Codex 内置 image_gen 生成并经 PM 视觉审查；未使用付费 CLI/API 回退。
母版 `universal_hmi.png` 为 RGBA，外边界透明。`ci/generate_launch_icons.py` 只负责缩放和格式导出，PWA maskable 另加不透明深蓝安全区底板；不重绘主标。
源输出：`C:/Users/SunYufei/.codex/generated_images/01a185dd-0456-7e33-8602-3a609a18f085/exec-1f5cc379-f20e-47af-93c6-a3d05825ac35.png`。

生成提示词：

Use case: logo-brand. Asset type: production desktop application icon for Universal HMI, industrial monitoring and control software. Create one original beautiful modern app icon: deep midnight navy rounded-square tile, with a large simple geometric silver-white and cyan connected monitoring mark centered inside. The mark combines an open squared U-shaped industrial conduit with one clean cyan rising signal segment and two subtle round connection nodes. Strong silhouette, balanced intentional negative space, exceptionally readable at 16-32px. Sophisticated precision-engineered identity, restrained satin material and barely perceptible tonal depth, crisp clean edges. No words, no letters, no numbers, no Flutter logo, no existing brand logos, no tiny details, no busy grids, no gear, no excessive 3D, no glow halo. Square composition viewed straight-on, icon fills 90 percent of canvas, outside rounded tile genuinely transparent with alpha; no scene or mockup.
