"""Build local contact sheets and HTML galleries from manifest metadata."""
from __future__ import annotations
import hashlib
import html
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / ".tools"))
from PIL import Image, ImageDraw, ImageFont

manifest_path = ROOT / "manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
pdf = next(x for x in manifest["sources"] if x["id"] == "cdpr-cosplay")
assets = [x for x in manifest["assets"] if x["source_id"] != "cdpr-cosplay"]
pdf_path = ROOT / "originals" / "rebecca-cosplay-guide-en-proxy.pdf"
if pdf_path.exists():
    manifest["source_documents"] = [{"id": "cdpr-cosplay-pdf", "source_page": pdf["url"], "local_path": "originals/rebecca-cosplay-guide-en-proxy.pdf", "size_bytes": pdf_path.stat().st_size, "sha256": hashlib.sha256(pdf_path.read_bytes()).hexdigest(), "page_count": 9, "retrieval": "Complete download via configured local HTTP proxy after direct download timeout."}]
    for i in range(1, 10):
        path = ROOT / "originals" / f"cdpr-cosplay-{i:02}.png"
        if not path.exists():
            continue
        with Image.open(path) as im:
            width, height = im.size
            im.thumbnail((600, 600))
            im.convert("RGB").save(ROOT / "preview-images" / f"cdpr-cosplay-{i:02}.png")
        assets.append({"id": f"cdpr-cosplay-{i:02}", "source_id": "cdpr-cosplay", "source_page": pdf["url"], "source_title": pdf["title"], "source_class": pdf["class"], "attribution": pdf["owner"], "intended_use": "Official cosplay guide page; see page captions and ART-DIRECTION.md for use.", "image_url": pdf["url"] + f"#page={i}", "local_path": str(path.relative_to(ROOT)).replace("\\", "/"), "download_status": "rendered-from-official-pdf", "derivation": {"source_document": "cdpr-cosplay-pdf", "page_number": i, "renderer": "PyMuPDF", "scale": 1.2, "content_changes": "None; page rasterization only."}, "width": width, "height": height, "format": "PNG", "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size_bytes": path.stat().st_size, "reuse_license": "Not established; local visual research only. Not a runtime asset."})
captions = {
    "cdpr-edgerunners-01": "原作角色立绘：宽外套、双马尾、配色",
    "gsc-nendoroid-01": "Q 版全身：笑脸、双手举起",
    "gsc-nendoroid-02": "Q 版动作：单手指向前方、张嘴",
    "gsc-nendoroid-03": "Q 版怒脸：眉眼与双手动作",
    "gsc-nendoroid-04": "Q 版得意笑：双拳庆祝",
    "gsc-nendoroid-05": "Q 版互动：与 David 并排",
    "gsc-hello-01": "极简 Q 版：正面比例与大色块",
    "gsc-hello-02": "极简 Q 版：偏转头部与马尾体积",
    "gsc-hello-03": "极简 Q 版：另一侧头部视角",
    "gsc-popup-01": "举手半身：肩袖体积与气质",
    "gsc-popup-02": "举手全身：服装、站姿与鞋",
    "gsc-popup-03": "举手偏侧视角：面部与发束",
    "gsc-popup-04": "与 David、Lucy 的组合展示",
    "gsc-popup-05": "单色背景全身：外套轮廓",
    "gsc-popup-06": "背面：发束、外套后片与鞋",
    "gsc-popup-07": "近景：面部与肩颈细节",
    "gsc-buzzmod-01": "持物站姿：重心和宽袖",
    "gsc-buzzmod-02": "正面放松站姿",
    "gsc-buzzmod-03": "背面：发尾层次与服装结构",
    "gsc-buzzmod-04": "侧身站姿：鞋与膝部角度",
    "gsc-buzzmod-05": "双臂向前的动态姿态",
    "gsc-buzzmod-06": "跳跃：发束和衣服动态",
    "gsc-buzzmod-07": "单手举物、抬腿动作",
    "gsc-buzzmod-08": "与 Lucy 的站姿组合",
    "gsc-buzzmod-09": "放松坐姿：适合待机动作研究",
    "gsc-buzzmod-10": "斜俯视全身与外套体积",
    "gsc-plush-01": "布偶坐姿：小尺寸识别",
    "gsc-plush-02": "布偶正面：符号和表情简化",
    "gsc-plush-03": "布偶侧面：发饰与轮廓",
    "gsc-plush-04": "布偶背面：双马尾结构",
    "gsc-plush-05": "布偶纹样：图案简化参考",
    "cdpr-cosplay-01": "官方指南封面：强化机械手",
    "cdpr-cosplay-02": "官方角色档案页",
    "cdpr-cosplay-03": "官方全身造型页",
    "cdpr-cosplay-04": "官方头部：正面与侧面",
    "cdpr-cosplay-05": "官方无外套造型：内部服装与纹样位置",
    "cdpr-cosplay-06": "官方纹样图形细节",
    "cdpr-cosplay-07": "官方粉蓝机械手与多色眼睛细节",
    "cdpr-cosplay-08": "指南附页：Fan Content Guidelines（非角色参考图）",
    "cdpr-cosplay-09": "指南附页：署名（非角色参考图）",
}
for asset in assets:
    asset["caption"] = captions[asset["id"]]
    asset["reference_role"] = "source-document-page" if asset["id"] in {"cdpr-cosplay-08", "cdpr-cosplay-09"} else "visual-reference"
manifest["assets"] = assets
manifest["summary"] = {"image_files": len(assets), "visual_references": sum(a["reference_role"] == "visual-reference" for a in assets), "document_pages": 2, "unique_image_hashes": len({a["sha256"] for a in assets})}
manifest["failures"] = [{"source_id": "cdpr-cosplay", "operation": "web open", "reason": "Web fetch rejects the 23,508,705-byte PDF as too large; fetched directly to D: instead.", "recovered": True}, {"source_id": "cdpr-cosplay", "operation": "direct curl download", "reason": "120-second timeout after 7,425,468 bytes; complete 23,508,705-byte file retrieved through existing local proxy.", "recovered": True}]
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

cols, cell_w, cell_h = 5, 280, 300
sheet = Image.new("RGB", (cols * cell_w, ((len(assets) + cols - 1)//cols)*cell_h), "#ededeb")
draw = ImageDraw.Draw(sheet)
for n, a in enumerate(assets):
    with Image.open(ROOT / a["local_path"]) as im:
        rgba = im.convert("RGBA")
        rgba.thumbnail((cell_w - 20, cell_h - 36))
        left = (n%cols)*cell_w + (cell_w-rgba.width)//2
        top = (n//cols)*cell_h + 5
        sheet.paste(rgba, (left, top), rgba)
    draw.text(((n%cols)*cell_w+10, (n//cols)*cell_h+cell_h-24), a["id"], fill="#20242c")
sheet.save(ROOT / "preview-images" / "all-references-contact-sheet.jpg", quality=90)

def cards(items):
    out=[]
    for a in items:
        preview = str((ROOT/"preview-images"/(a["id"]+".png")).resolve()).replace("\\","/")
        out.append(f'<article class="card"><a href="{html.escape(a["source_page"],quote=True)}" target="_blank" rel="noopener"><img src="{html.escape(preview,quote=True)}" alt="{html.escape(a.get("caption",a["id"]),quote=True)}"></a><div class="meta"><strong>{html.escape(a["id"])}</strong><p>{html.escape(a.get("caption",a["source_title"]))}</p><small>{html.escape(a["source_class"])} · {a["width"]} × {a["height"]}</small></div></article>')
    return ''.join(out)

css = '''*{box-sizing:border-box}body{margin:0;font-family:var(--font-sans,system-ui);color:var(--foreground)}main{max-width:1440px;margin:auto}h1{font-size:24px;margin:0 0 8px}p{line-height:1.6}.sub{color:var(--muted-foreground);font-size:14px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px;margin-top:18px}.card{border:1px solid var(--border);border-radius:var(--radius,12px);overflow:hidden;background:var(--card)}img{display:block;width:100%;height:245px;object-fit:contain;background:var(--secondary)}.meta{padding:16px}.meta p{margin:5px 0;font-size:13px}.meta small{color:var(--muted-foreground);font-size:11px}a{color:var(--primary)}.pill{display:inline-block;border:1px solid var(--border);border-radius:var(--radius,12px);padding:3px 9px;font-size:12px;margin:0 5px 6px 0}'''
full = f'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>瑞贝卡参考图库</title><style>{css}</style><main><h1>瑞贝卡 · 官方参考图库</h1><p class="sub">38 张视觉参考 + 2 张指南附页 · 原作角色、Q 版比例、表情、服装与官方设定。点击图片可访问来源。仅作本地设计参考，非桌宠运行素材。</p><div class="grid">{cards(assets)}</div></main></html>'
(ROOT/"gallery.html").write_text(full,encoding="utf-8")
selected_ids=["cdpr-edgerunners-01","gsc-nendoroid-01","gsc-nendoroid-03","gsc-nendoroid-04","gsc-hello-03","gsc-popup-06","gsc-buzzmod-09","cdpr-cosplay-04","cdpr-cosplay-07"]
selected=[next(a for a in assets if a["id"]==i) for i in selected_ids if any(a["id"]==i for a in assets)]
compact=f'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>瑞贝卡参考精选</title><style>{css}.grid{{grid-template-columns:repeat(auto-fit,minmax(180px,1fr))}}img{{height:210px}}</style><main><p class="sub">38 张官方来源视觉参考 + 1 份 9 页官方指南。这里精选原作造型、Q 版比例与表情；点击图片查看来源。</p><span class="pill">CD PROJEKT RED</span><span class="pill">Good Smile Company</span><span class="pill">Aniplex</span><div class="grid">{cards(selected)}</div><p class="sub">参考图用于造型研究；桌宠角色单独制作。</p></main></html>'
(ROOT/"compact-preview.html").write_text(compact,encoding="utf-8")
print(f"Built galleries for {len(assets)} assets")
