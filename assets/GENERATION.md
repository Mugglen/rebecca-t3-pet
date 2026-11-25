# 角色资产生成记录

方式：内置 imagegen，透明背景。输出 `rebecca-atlas.png`，1536×1024 RGBA，3×2 每格 512×512。已查看完整输出、核对六个动作和身份特征；角落及格间采样 alpha=0，存在边缘半透明像素。

生成母版 `rebecca-atlas-v1.png` 与运行文件字节相同，没有抠图、重绘或重采样。SHA-256：`851a82966ffad1d6c9b1b8554f61f1a24bdb85fbef7c0e3539b3ea5ad1d31f5b`。

工具默认输出入口已使用目录联接落在 `D:\Scratch\codex-generated-images`；运行文件直接复制工具保存的原始 PNG，本项目运行不依赖该入口或 C 盘文件。

参考：`references/originals/cdpr-edgerunners-01.png`、`gsc-nendoroid-01.jpg`、`gsc-nendoroid-03.jpg`。参考来源见 `references/manifest.json`，不直接作为运行资产。

目标：3 列 × 2 行，idle/working/attention/success/error/offline 六个静态动作。WPF 使用分格图片与位移/缩放动效；此版本不宣称逐帧动画。

## 提示词

Create a production-ready transparent RGBA PNG sprite atlas for a Windows desktop companion: Rebecca from Cyberpunk: Edgerunners, in charming polished 2D chibi anime style. Use the supplied images strictly as character identity and proportion references, not photo style. Exact 3 columns by 2 rows equal-cell atlas on a transparent canvas, intended 1536x1024, six complete isolated full-body characters, one centered in each cell, no lines between cells, no text, no labels, no watermark, no opaque background, no floor or cast shadow. Each character has the same design, same height about 80% of its cell, same frontal slight-three-quarter orientation, same feet baseline, generous padding all sides; nothing crosses cell boundaries. Maintain identity: light mint/turquoise twin ponytails, navy arched headband with chunky cybernetic hair blocks, very pale ice-blue skin, distinctive eyes with RED sclera/background and GREEN with yellow concentric iris rings, oversized navy jacket with electric-lime trim and collar, small pink geometric neck marking, one pink and one cyan mechanical glove, dark ankle boots. Modest closed oversized jacket silhouette. Crisp dark outlines, luminous cel shading, readable at 240 pixels tall, expressive adult fictional character drawn as 2.5-head-tall chibi. SIX POSES by grid order: top-left IDLE, cheeky confident smile hands relaxed; top-middle WORKING, focused eyes looking at a small cyan floating terminal panel at waist height while both gloves type; top-right ATTENTION, one hand waving near head with alert friendly expression; bottom-left SUCCESS, delighted wide grin and one raised fist; bottom-middle ERROR, comically annoyed eyebrows with arms folded; bottom-right OFFLINE, sleepy eyes closed and relaxed drooping posture. No guns, no weapons, no floating symbols, no extra characters, no decorative scene. Essential: real transparent alpha and clean non-overlapping equal grid, consistent character dimensions and foot anchors.
