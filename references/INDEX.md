# 瑞贝卡参考资料库

采集日期：2026-11-25。已下载 **31 张来自官方网页的角色／商品参考图**，另保存 CDPR 官方英文 Cosplay Guide（9 页，23,508,705 字节）并逐页渲染。

合计 40 个图像文件，其中 **38 个含角色或造型细节**，另外 2 个是指南规则／署名页。按 SHA-256 检查重复，不以网页上的重复缩略图凑数量。

## 先看这几张

| 用途 | 本地图像 | 来源 |
| --- | --- | --- |
| 原作配色和宽外套 | [CDPR 角色立绘](originals/cdpr-edgerunners-01.png) | [Cyberpunk 官方页](https://www.cyberpunk.net/en/edgerunners) |
| Q 版整体比例 | [Nendoroid 笑脸](originals/gsc-nendoroid-01.jpg) | [Good Smile 官方页](https://www.goodsmile.com/en/product/12203/Nendoroid%20Rebecca) |
| 提醒／生气表情 | [Nendoroid 怒脸](originals/gsc-nendoroid-03.jpg) | 同上 |
| 完成庆祝、双拳动作 | [Nendoroid 双拳](originals/gsc-nendoroid-04.jpg) | 同上 |
| 原作头部与脸部线路 | [Cosplay Guide 第 4 页](originals/cdpr-cosplay-04.png) | [CDPR 官方 PDF](https://cdn-s-cyberpunk.cdprojektred.com/cosplay-guides/REBECCA_COSPLAY_GUIDE_EN.pdf#page=4) |
| 双手配色与眼睛结构 | [Cosplay Guide 第 7 页](originals/cdpr-cosplay-07.png) | [CDPR 官方 PDF](https://cdn-s-cyberpunk.cdprojektred.com/cosplay-guides/REBECCA_COSPLAY_GUIDE_EN.pdf#page=7) |
| 背面衣服与头发 | [BUZZmod 背面](originals/gsc-buzzmod-03.jpg) | [Good Smile / Aniplex 官方页](https://www.goodsmile.com/en/product/1140950/%2BBUZZmod.%2BCyberpunk%2BEdgerunners%2BREBECCA%2B1%2B12%2Bscale%2Baction%2Bfigure) |
| 放松待机坐姿 | [BUZZmod 坐姿](originals/gsc-buzzmod-09.jpg) | 同上 |

## 文件与来源

- [完整本地图库](gallery.html)：40 图、来源链接及尺寸；打开图片可跳到来源网页。
- [精选图库](compact-preview.html)：9 张代表图，供 T3 内联展示。
- [机器可读清单](manifest.json)：逐图 URL、来源页、分类、权利方署名、尺寸、文件大小、SHA-256、用途和采集失败记录。
- [美术方向](../docs/ART-DIRECTION.md)：从参考图归纳的不可丢失特征与桌宠动作建议。
- [官方指南 PDF](originals/rebecca-cosplay-guide-en-proxy.pdf)：下载完整性已按响应长度 23,508,705 字节核对，9 页均成功渲染。

| 来源组 | 图像数 | 主要用途 |
| --- | ---: | --- |
| CDPR 官方角色页 | 1 | 原作色彩和服装轮廓 |
| Good Smile Nendoroid 2186 | 5 | Q 版比例、笑脸、怒脸、手势 |
| Good Smile HELLO! | 3 | 极简 Q 版、粗线与小尺寸识别 |
| Good Smile POP UP PARADE | 7 | 服装体积、前后视图、鞋、气质 |
| Aniplex BUZZmod（Good Smile 官方产品页） | 10 | 站立、坐下、跳跃、背面、手臂动作 |
| Good Smile Plushie | 5 | 面部与纹样简化、侧背造型 |
| CDPR Cosplay Guide | 9 页图 | 7 个造型参考页 + 2 个文档页 |

所有来源均来自 CDPR、Good Smile 官方域名；BUZZmod 产品页标注制造商 Aniplex。未把搜索结果里的用户上传图、转售图片或未验证粉丝图混作官方资料。网页商品图可能是原型或 CG 渲染，以对应页面说明为准。

## 保存与使用边界

原图、指南和网页快照是本地设计研究资料；它们不是项目生成的资产，也没有被当作桌宠运行素材。来源页未提供统一的开源素材许可，清单不声称存在这样的许可。Git 保存清单、文档和图库页面；原始文件及缩略图保留在本机 D 盘，重新克隆后需重新采集才能打开本地图。

以后生成或绘制的角色素材应单独放入项目运行资源目录，并记录提示、工具和版本；不得将这些参考图重新命名后声称是项目原创。

## 复现和检查

1. 使用项目允许的 Python，在 D 盘安装 `Pillow` 与 `PyMuPDF`（本轮分别为 13.0.0 与 2.1）。本轮工具位于 `references/.tools`，缓存与临时文件也在本目录下的隐藏目录。
2. `collect_sources.py` 收集官方网页；加 `--download` 下载匹配该角色的图片并生成清单。
3. `collect_sources.py --guide` 下载官方 PDF 并逐页渲染；网络需要代理时可设置 `REFERENCE_PROXY` 为本机已有 HTTP 代理地址。
4. `build_gallery.py` 为已有参考图与指南页生成缩略图、校验数据和图库。
5. 指南页使用 PyMuPDF 按 1.2 倍页面尺度渲染，未裁切或改变角色内容。

已用图像查看工具检查原作立绘、Nendoroid 笑脸／怒脸／双拳、官方头部及手眼细节、BUZZmod 坐姿，并检查包含全部 40 图的联系表。全部 PNG/JPEG 能解码。

采集遇到两项限制：网页工具因 PDF 体积过大拒绝打开；直连下载在 120 秒时只收到部分内容。随后通过本机现有代理下载完整 PDF，已恢复，细节见清单 `failures`。
