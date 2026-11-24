"""Reproduce the local reference library; writes only beside this script."""
from __future__ import annotations
import concurrent.futures
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse

ROOT = Path(__file__).resolve().parent
(ROOT / ".tmp").mkdir(parents=True, exist_ok=True)
os.environ["TEMP"] = os.environ["TMP"] = str(ROOT / ".tmp")
SOURCES = [
    {"id": "cdpr-edgerunners", "title": "Cyberpunk: Edgerunners official character page", "url": "https://www.cyberpunk.net/en/edgerunners", "class": "official-character-art", "owner": "CD PROJEKT RED / TRIGGER", "notes": "Original anime character identity and color references."},
    {"id": "gsc-nendoroid", "title": "Nendoroid Rebecca (2186)", "url": "https://www.goodsmile.com/en/product/12203/Nendoroid%20Rebecca", "class": "official-licensed-chibi", "owner": "Good Smile Company / CD PROJEKT", "notes": "Chibi proportions, expressions and compact silhouettes."},
    {"id": "gsc-hello", "title": "HELLO! GOOD SMILE Rebecca", "url": "https://www.goodsmile.com/en/product/60362/HELLO%2BGOOD%2BSMILE%2BRebecca", "class": "official-licensed-chibi", "owner": "Good Smile Company / CD PROJEKT", "notes": "Highly simplified chibi head-body ratio and back view."},
    {"id": "gsc-popup", "title": "POP UP PARADE Rebecca", "url": "https://www.goodsmile.com/en/product/12778/POP%2BUP%2BPARADE%2BRebecca", "class": "official-licensed-figure", "owner": "Good Smile Company / CD PROJEKT", "notes": "Outfit volume, asymmetric arms, footwear, standing pose."},
    {"id": "gsc-buzzmod", "title": "BUZZmod. Cyberpunk: Edgerunners REBECCA", "url": "https://www.goodsmile.com/en/product/1140950/%2BBUZZmod.%2BCyberpunk%2BEdgerunners%2BREBECCA%2B1%2B12%2Bscale%2Baction%2Bfigure", "class": "official-licensed-action-figure", "owner": "Aniplex / Good Smile Company / CD PROJEKT", "notes": "Expressive faces and jointed action poses; not chibi proportions."},
    {"id": "gsc-plush", "title": "Cyberpunk: Edgerunners Plushie Rebecca", "url": "https://www.goodsmile.com/en/product/11463/Cyberpunk%20Edgerunners%20Plushie%20Rebecca", "class": "official-licensed-plush", "owner": "Good Smile Company / CD PROJEKT", "notes": "Simplified facial markings and small-scale character recognition."},
]
PDF = {"id": "cdpr-cosplay", "title": "Rebecca Cosplay Guide (English)", "url": "https://cdn-s-cyberpunk.cdprojektred.com/cosplay-guides/REBECCA_COSPLAY_GUIDE_EN.pdf", "class": "official-character-guide", "owner": "CD PROJEKT RED / TRIGGER", "notes": "Primary source for turnaround, garments, cyberarms, face, tattoos and palette."}


def fetch(url: str, path: Path) -> tuple[bool, str]:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.stat().st_size:
        return True, "cached"
    partial = path.with_suffix(path.suffix + ".part")
    proxy = ["--proxy", os.environ["REFERENCE_PROXY"]] if os.environ.get("REFERENCE_PROXY") else []
    completed = subprocess.run(
        ["curl.exe", "--location", "--fail", "--silent", "--show-error", "--retry", "1", "--connect-timeout", "15", "--max-time", "120", *proxy, "--output", str(partial), url],
        capture_output=True, text=True, cwd=ROOT,
    )
    if completed.returncode == 0:
        partial.replace(path)
    return completed.returncode == 0, completed.stderr.strip()[:300]


def discover():
    results = []
    for source in SOURCES:
        path = ROOT / "source-pages" / (source["id"] + ".html")
        ok, error = fetch(source["url"], path)
        if not ok:
            results.append({**source, "status": "failed", "error": error})
            continue
        content = path.read_text(encoding="utf-8")
        # Source HTML is preserved locally so URL provenance remains inspectable.
        tags = re.findall(r"<img\b[^>]*>", content, re.I)
        candidates = []
        for tag in tags:
            attrs = dict((k.lower(), html.unescape(v)) for k, _, v in re.findall(r'([\w-]+)\s*=\s*([\"\x27])(.*?)\2', tag))
            url = attrs.get("src") or attrs.get("data-src")
            if url:
                candidates.append({"url": urllib.parse.urljoin(source["url"], url), "alt": attrs.get("alt", ""), "tag": tag[:800]})
        results.append({**source, "status": "downloaded", "images": candidates})
    (ROOT / "source-pages" / "discovered.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    for source in results:
        print(source["id"], source["status"], len(source.get("images", [])))
        for candidate in source.get("images", []):
            if source["id"].startswith("gsc") or "rebecca" in str(candidate).lower():
                print(candidate["url"], candidate["alt"])


def download_images():
    (ROOT / "preview-images").mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(ROOT / ".tools"))
    from PIL import Image
    discovered = json.loads((ROOT / "source-pages" / "discovered.json").read_text(encoding="utf-8"))
    patterns = {"gsc-nendoroid": "/14518/", "gsc-hello": "/60362/", "gsc-popup": "/15095/", "gsc-buzzmod": "/1140950/", "gsc-plush": "/13778/"}
    jobs = []
    for source in discovered:
        urls = list(dict.fromkeys(x["url"] for x in source.get("images", []) if patterns.get(source["id"], "rebecca@") in x["url"] and re.search(r"\.(jpg|png)$", x["url"])))
        if source["id"] == "cdpr-edgerunners":
            urls = ["https://www.cyberpunk.net/build/images/edgerunners/characters/rebecca@2x-6a96c002.png"]
        for index, url in enumerate(urls, 1):
            jobs.append((source, index, url))

    def one(job):
        source, index, url = job
        suffix = Path(urllib.parse.urlparse(url).path).suffix
        image_id = f'{source["id"]}-{index:02d}'
        path = ROOT / "originals" / (image_id + suffix)
        ok, error = fetch(url, path)
        result = {"id": image_id, "source_id": source["id"], "source_page": source["url"], "source_title": source["title"], "source_class": source["class"], "attribution": source["owner"], "intended_use": source["notes"], "image_url": url, "local_path": str(path.relative_to(ROOT)).replace("\\", "/"), "download_status": "downloaded" if ok else "failed", "reuse_license": "Not established; local visual research only. Not a runtime asset."}
        if ok:
            try:
                with Image.open(path) as image:
                    result.update(width=image.width, height=image.height, format=image.format)
                    image.thumbnail((500, 500))
                    preview = ROOT / "preview-images" / (image_id + ".png")
                    image.convert("RGB").save(preview)
                result["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                result["size_bytes"] = path.stat().st_size
                print(image_id, result["width"], result["height"], flush=True)
            except Exception as exc:
                result.update(download_status="invalid-image", error=str(exc))
        else:
            result["error"] = error
            print(image_id, error, flush=True)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        assets = list(executor.map(one, jobs))
    manifest = {"schema_version": 1, "collected_date": "2026-11-25", "sources": SOURCES + [PDF], "assets": assets, "notes": "Public official references collected for local design research. Raw images, PDFs and generated thumbnails are not project runtime assets and are excluded from Git."}
    (ROOT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def download_guide():
    sys.path.insert(0, str(ROOT / ".tools"))
    import pymupdf
    path = ROOT / "originals" / "rebecca-cosplay-guide-en-proxy.pdf"
    ok, error = fetch(PDF["url"], path)
    if not ok:
        raise RuntimeError(error)
    with pymupdf.open(path) as document:
        print(f"Guide: {path.stat().st_size} bytes, {len(document)} pages")
        for i, page in enumerate(document, 1):
            page.get_pixmap(matrix=pymupdf.Matrix(1.2, 1.2), alpha=False).save(ROOT / "originals" / f"cdpr-cosplay-{i:02}.png")


if __name__ == "__main__":
    if "--guide" in sys.argv:
        download_guide()
    elif "--download" in sys.argv:
        download_images()
    else:
        discover()
