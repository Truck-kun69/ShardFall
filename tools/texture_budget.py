#!/usr/bin/env python3
"""Texture budget: assigns and verifies per-category import limits.

Budgets (all VRAM-compressed, compress/mode=2):
  2048 px  hero / boss textures, landmark props (arch, pillar, wall), foe albedo
  1024 px  prop + foe normal / ORM, clutter albedo (bush, grass, bones, rock,
           tree, tree_dead), terrain textures

  --apply   write/patch the .import file next to every source image
  --check   fail (exit 1) if any image lacks a compliant .import
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = os.path.join(ROOT, "godot")
SCAN = ["textures/terrain", "models"]
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".webp", ".tga")
LANDMARKS = ("arch", "pillar", "wall")


def classify(rel):
    """Return (budget_px, is_normal) for a res-relative image path."""
    name = os.path.basename(rel).lower()
    is_normal = "normal" in name or name.endswith("_n.png")
    is_orm = "_orm" in name or "roughness" in name or "_ao" in name
    if rel.startswith("models/heroes/") or rel.startswith("models/bosses/"):
        return 2048, is_normal
    if rel.startswith("models/foes/"):
        if is_normal or is_orm:
            return 1024, is_normal
        return 2048, is_normal
    if rel.startswith("models/props/"):
        if is_normal or is_orm:
            return 1024, is_normal
        if name.startswith(LANDMARKS):
            return 2048, is_normal
        return 1024, is_normal
    return 1024, is_normal


def images():
    for base in SCAN:
        top = os.path.join(GODOT, base)
        for dirpath, _, files in os.walk(top):
            for f in sorted(files):
                if f.lower().endswith(IMAGE_EXT):
                    full = os.path.join(dirpath, f)
                    yield os.path.relpath(full, GODOT).replace(os.sep, "/")


IMPORT_TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://{rel}"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map={normal}
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit={limit}
detect_3d/compress_to=0
"""


def read_params(path):
    params = {}
    section = ""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            m = re.match(r"^\[(.+)\]$", line)
            if m:
                section = m.group(1)
                continue
            if section == "params" and "=" in line:
                k, v = line.split("=", 1)
                params[k.strip()] = v.strip()
    return params


def patch_import(path, rel, limit, normal):
    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(IMPORT_TEMPLATE.format(rel=rel, limit=limit, normal=1 if normal else 0))
        return "created"
    text = open(path, encoding="utf-8").read()
    want = {"compress/mode": "2", "process/size_limit": str(limit), "mipmaps/generate": "true",
            "compress/normal_map": "1" if normal else "0", "detect_3d/compress_to": "0"}
    for k, v in want.items():
        pat = re.compile(r"^" + re.escape(k) + r"=.*$", re.M)
        if pat.search(text):
            text = pat.sub(f"{k}={v}", text)
        else:
            text = text.replace("[params]\n", f"[params]\n\n{k}={v}\n", 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return "patched"


def image_size(path):
    from PIL import Image
    with Image.open(path) as im:
        return im.size


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--apply", action="store_true")
    g.add_argument("--check", action="store_true")
    args = ap.parse_args()
    failures = []
    count = 0
    for rel in images():
        count += 1
        limit, normal = classify(rel)
        imp = os.path.join(GODOT, rel + ".import")
        if args.apply:
            print(f"  {patch_import(imp, rel, limit, normal):8s} {rel} -> {limit}px{' (normal)' if normal else ''}")
            continue
        if not os.path.exists(imp):
            failures.append(f"{rel}: missing .import")
            continue
        p = read_params(imp)
        if p.get("compress/mode") != "2":
            failures.append(f"{rel}: compress/mode={p.get('compress/mode')} (want 2, VRAM compressed)")
        if p.get("process/size_limit") != str(limit):
            failures.append(f"{rel}: size_limit={p.get('process/size_limit')} (budget {limit})")
        if p.get("mipmaps/generate") != "true":
            failures.append(f"{rel}: mipmaps disabled")
        w, h = image_size(os.path.join(GODOT, rel))
        if min(w, h) <= 256:
            failures.append(f"{rel}: source {w}x{h} is <= 256 px")
        print(f"  ok  {rel:58s} {w}x{h} budget {limit}")
    if args.check:
        if count == 0:
            failures.append("no textures found under " + ", ".join(SCAN))
        if failures:
            print("TEXTURE BUDGET FAIL:")
            for f in failures:
                print("  - " + f)
            return 1
        print(f"texture budget OK ({count} textures, all compress/mode=2 within budget)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
