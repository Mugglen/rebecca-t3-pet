# 角色资产生成记录

方式：内置 imagegen，透明背景。输出 `rebecca-atlas.png`，1536×1024 RGBA，3×2 每格 512×512。已查看完整输出、核对六个动作和身份特征；角落及格间采样 alpha=0，存在边缘半透明像素。

生成母版 `rebecca-atlas-v1.png` 与运行文件字节相同，没有抠图、重绘或重采样。SHA-256：`851a82966ffad1d6c9b1b8554f61f1a24bdb85fbef7c0e3539b3ea5ad1d31f5b`。

工具默认输出入口已使用目录联接落在 `D:\Scratch\codex-generated-images`；运行文件直接复制工具保存的原始 PNG，本项目运行不依赖该入口或 C 盘文件。

参考：`references/originals/cdpr-edgerunners-01.png`、`gsc-nendoroid-01.jpg`、`gsc-nendoroid-03.jpg`。参考来源见 `references/manifest.json`，不直接作为运行资产。

目标：3 列 × 2 行，idle/working/attention/success/error/offline 六个静态动作。WPF 使用分格图片与位移/缩放动效；此版本不宣称逐帧动画。

## 工作坐姿更新（2026-11-25）

用户要求将工作姿势改为坐姿。使用内置 imagegen，以原图集的上中格为编辑目标，输出单独的 `rebecca-working-seated.png`：1254×1254、32 位 RGBA PNG。提示期望 1024×1024，工具实际输出 1254×1254，保留原始输出，没有抠图或重采样。

原图集及 v1 母版保持原字节；WPF 加载六格后，以新图覆盖 working 状态（待机坐姿随后追加，见下节）。角色盘腿坐着操作青色小终端，保留原角色外观和一粉一蓝的机械手。新文件 SHA-256：`d3024fa0d2e18586e593a1ec04dc76a1b50a40fe75ad5847bca0aa32b4f22313`。四角 alpha=0，共 1,033,272 个全透明像素；alpha>128 的主体边界为 `(210,206)–(973,1206)`，坐姿底部约位于画布 96% 高度。

生成入口：`exec-4b4c6d30-d717-42f5-9c8c-3a5e79478985.png`，源图 `exec-8b0b9995-214a-4368-a415-9e8f4d4bdff3.png` 与项目原图集 SHA 相同。工具输出目录的 junction 已核实指向 D 盘；最终资产复制到本项目 `assets/`。

验证：现有 WPF smoke 28 项通过，`tmp/desktop-smoke-20261125-043506/desktop-working.png` 的实际 320×380 渲染已目视检查坐姿、终端与透明边缘；这张预览使用合成任务数据。原图集 SHA 未变化，未覆盖的姿势继续使用原像素。

### 坐姿编辑完整提示词

Use case: precise-object-edit. Asset type: transparent working-state sprite for an existing Windows desktop pet. The input is a 3-column by 2-row Rebecca sprite atlas; the edit target is ONLY the TOP-MIDDLE working character. Produce ONE standalone square PNG containing ONLY that character, not a sprite sheet. Change her standing posture into a clearly seated CROSS-LEGGED posture, resting on an invisible ground plane, with both bent legs and dark shoes visible, typing with her pink and cyan mechanical gloves on the same small cyan translucent holographic terminal above her lap. Preserve the existing adult fictional Rebecca character's precise chibi anime design and rendering: mint twin ponytails, navy arched headband and mechanical hair blocks with lime accents, very pale blue face, red outer eyes with green/yellow rings, the focused slightly grumpy working expression, oversized closed navy jacket with lime trim, pink neck marking, same left-pink/right-cyan gloves from the viewer's perspective, dark boots. Match the original crisp dark outlines, cel shading, face shape, colors and slightly three-quarter frontal orientation. Keep the terminal small and readable and do not obscure her face. Composition: 1024 by 1024 transparent canvas, full seated body entirely visible, horizontally centered, comfortable padding. Maintain the head's scale relative to the original 512-square atlas cell; do not zoom the sitting character up to standing height. Seated silhouette should be roughly 65-70 percent of canvas height, with her seated base/boots near 94 percent of canvas height and extra transparent space above her. No chair, no room, no floor, no ground shadow, no aura or colored background haze, no vignette, no duplicate characters, no labels, no watermark. Background must be genuine transparent alpha, including all open space around the hair and legs. Keep the design modest and the jacket closed. The only intended change is a seated working pose.

## 待机坐姿更新（2026-11-25）

用户追加要求待机也坐着。继续使用内置 imagegen，以工作坐姿 PNG 为编辑目标，移除终端，将双手放松放在膝上，改为轻松微笑。保持盘腿坐姿、同一画布及落地基线，输出 `rebecca-idle-seated.png`，1254×1254 RGBA，未经抠图或重采样。SHA-256：`73a4d663075acb272e041f7c5c610050b5ac8528a2bfea350cf3e2a44d7e15c0`。

工具原始输出：`exec-aa6c4cf4-b912-42c1-a8a1-8f6ca35b52d9.png`。全透明像素 1,051,177；四角 alpha 为 1/0/0/0（左上仅 1/255）；alpha>128 主体边界 `(208,205)–(948,1206)`，与工作坐姿底部相同。最终运行时覆盖 idle 和 working 两格，其余四格仍来自原始图集。

追加待机坐姿后再次通过 WPF smoke 28 项，工作态渲染在 `tmp/desktop-smoke-20261125-043753/desktop-working.png`，待机渲染在 `tmp/desktop-idle-seated.png`。两者均已按桌宠 320×380 输出尺寸目视检查；预览使用合成状态数据，未替代实际任务状态验证。

### 待机编辑完整提示词

Use case: precise-object-edit. Edit the provided transparent PNG of the seated chibi Rebecca desktop companion into her relaxed IDLE state. Keep the exact same cross-legged seated pose, body proportions, character size, position, hair silhouette, headband, jacket, leg markings, shoes, linework, color palette, canvas framing and transparent background. Make only these targeted changes: remove the cyan holographic terminal completely; move the pink and cyan gloved hands to rest naturally on her knees/lap; soften her focused frown into a small relaxed, cheeky smile with gently open friendly eyes. Preserve the red outer eyes with green/yellow iris rings, mint twin ponytails, pale blue skin, navy jacket with neon lime trim, and viewer-left pink/viewer-right cyan gloves. She should feel quietly content while waiting, not asleep and not waving. Keep every limb complete, keep the closed modest jacket and cross-legged sitting, and keep her seated baseline and head scale identical to the input so switching between idle and working does not jump. One full-body character only, square canvas, generous identical transparent margins, genuine transparent alpha. No text, no symbols, no terminal, no chair, no floor, no shadow, no scenery, no opaque background, no aura. Preserve the existing artwork everywhere except expression and hand/terminal changes.

## 原图集提示词

Create a production-ready transparent RGBA PNG sprite atlas for a Windows desktop companion: Rebecca from Cyberpunk: Edgerunners, in charming polished 2D chibi anime style. Use the supplied images strictly as character identity and proportion references, not photo style. Exact 3 columns by 2 rows equal-cell atlas on a transparent canvas, intended 1536x1024, six complete isolated full-body characters, one centered in each cell, no lines between cells, no text, no labels, no watermark, no opaque background, no floor or cast shadow. Each character has the same design, same height about 80% of its cell, same frontal slight-three-quarter orientation, same feet baseline, generous padding all sides; nothing crosses cell boundaries. Maintain identity: light mint/turquoise twin ponytails, navy arched headband with chunky cybernetic hair blocks, very pale ice-blue skin, distinctive eyes with RED sclera/background and GREEN with yellow concentric iris rings, oversized navy jacket with electric-lime trim and collar, small pink geometric neck marking, one pink and one cyan mechanical glove, dark ankle boots. Modest closed oversized jacket silhouette. Crisp dark outlines, luminous cel shading, readable at 240 pixels tall, expressive adult fictional character drawn as 2.5-head-tall chibi. SIX POSES by grid order: top-left IDLE, cheeky confident smile hands relaxed; top-middle WORKING, focused eyes looking at a small cyan floating terminal panel at waist height while both gloves type; top-right ATTENTION, one hand waving near head with alert friendly expression; bottom-left SUCCESS, delighted wide grin and one raised fist; bottom-middle ERROR, comically annoyed eyebrows with arms folded; bottom-right OFFLINE, sleepy eyes closed and relaxed drooping posture. No guns, no weapons, no floating symbols, no extra characters, no decorative scene. Essential: real transparent alpha and clean non-overlapping equal grid, consistent character dimensions and foot anchors.
