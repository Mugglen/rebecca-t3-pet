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
manifest["assets"] = assets
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

css = '''*{box-sizing:border-box}body{margin:0;font-family:system-ui,"Segoe UI","Microsoft YaHei",sans-serif;color:var(--text-primary,#dfe5ee)}main{padding:20px;max-width:1440px;margin:auto}h1{font-size:24px;margin:0 0 8px}p{line-height:1.6}.sub{color:var(--text-secondary,#a5b1c0);font-size:14px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px;margin-top:18px}.card{border:1px solid var(--border-color,#485565);border-radius:12px;overflow:hidden;background:var(--surface-bg,#18222e)}img{display:block;width:100%;height:245px;object-fit:contain;background:#eeeeea}.meta{padding:12px}.meta p{margin:5px 0;font-size:13px}.meta small{color:var(--text-secondary,#a5b1c0);font-size:11px}a{color:var(--link-color,#8adcd2)}.pill{display:inline-block;border:1px solid var(--border-color,#485565);border-radius:99px;padding:3px 9px;font-size:12px;margin:0 5px 6px 0}'''
full = f'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>瑞贝卡参考图库</title><style>{css}</style><main><h1>瑞贝卡 · 官方参考图库</h1><p class="sub">{len(assets)} 张图像 · 原作角色、Q 版比例、表情、服装与官方设定。点击图片可访问来源。仅作本地设计参考，非桌宠运行素材。</p><div class="grid">{cards(assets)}</div></main></html>'
(ROOT/"gallery.html").write_text(full,encoding="utf-8")
selected_ids=["cdpr-edgerunners-01","gsc-nendoroid-01","gsc-nendoroid-03","gsc-hello-03","gsc-popup-06","gsc-buzzmod-09","cdpr-cosplay-02","cdpr-cosplay-05","cdpr-cosplay-07"]
selected=[next(a for a in assets if a["id"]==i) for i in selected_ids if any(a["id"]==i for a in assets)]
compact=f'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>瑞贝卡参考精选</title><style>{css}.grid{{grid-template-columns:repeat(auto-fit,minmax(180px,1fr))}}img{{height:210px}}</style><main><h1>瑞贝卡 · 角色参考精选</h1><p class="sub">已收集 {len(assets)} 张官方来源参考图。这里选择原作造型、Q 版比例与表情；点击图片查看原始来源。</p><span class="pill">CD PROJEKT RED</span><span class="pill">Good Smile Company</span><span class="pill">Aniplex</span><div class="grid">{cards(selected)}</div><p class="sub">这些是设计参考，尚未授权为游戏或桌宠成品素材；运行角色单独制作。</p></main></html>'
(ROOT/"compact-preview.html").write_text(compact,encoding="utf-8")
print(f"Built galleries for {len(assets)} assets")
