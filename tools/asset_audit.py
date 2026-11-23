#!/usr/bin/env python3
"""Binary audit of connector-produced assets against the slot contract.

Checks every GLB under godot/models/{heroes,bosses,foes,props}/ plus its
companion textures and SVA3 vertex-animation file:

  heroes   38.0u tall, feet Y=0, skinned, clips idle/walk/run/cast/roll/jump/die,
           cast 0.50-1.10 s, roll 0.40-0.80 s, jump 0.50-1.00 s, every clip >= 0.40 s
  bosses   88.0u tall, feet Y=0, skinned, clips idle/walk/attack/slam/die (>= 0.40 s)
  foes     24-42u tall, feet Y=0, identity mesh node, <= 1800 tris,
           <id>_albedo/_normal/_orm.png (normal+ORM per-channel R/G std >= 3.0),
           <id>.vat SVA3 with walk travel > 2.0 and non-zero attack/death motion
  props    contract height per kind, feet Y=0, identity mesh node, PBR textures

Also usable standalone:  python3 tools/asset_audit.py [--self-test]
"""
import json
import math
import os
import struct
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "godot", "models")

HERO_H = 38.0
BOSS_H = 88.0
FOE_H = (24.0, 42.0)
FOE_TRIS = 1800
PROP_H = {"tree": 130.0, "tree_dead": 125.0, "arch": 120.0, "pillar": 95.0, "wall": 65.0,
          "rock": 38.0, "bush": 26.0, "bones": 22.0}
HEIGHT_TOL = 0.05
MIN_Y_TOL = 0.02
CLIP_MIN = 0.40
HERO_CLIPS = {"idle": None, "walk": None, "run": None, "cast": (0.50, 1.10),
              "roll": (0.40, 0.80), "jump": (0.50, 1.00), "die": None}
HERO_ALIASES = {"cast": ("cast", "attack"), "roll": ("roll", "dodge"), "die": ("die", "death")}
BOSS_CLIPS = {"idle": None, "walk": None, "attack": None, "slam": None, "die": None}
BOSS_ALIASES = {"die": ("die", "death"), "walk": ("walk", "run")}
MAP_STD_MIN = 3.0
VAT_WALK_TRAVEL = 2.0
CLIP_HARD_MAX = 10.0


# ----------------------------------------------------------------------------
# GLB parsing
# ----------------------------------------------------------------------------
COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_glb(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 20 or data[:4] != b"glTF":
        raise ValueError("not a GLB (bad magic)")
    version, length = struct.unpack_from("<II", data, 4)
    if version != 2:
        raise ValueError(f"glTF version {version} != 2")
    off = 12
    gltf, binchunk = None, b""
    while off < min(length, len(data)):
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            gltf = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            binchunk = chunk
        off += 8 + clen
    if gltf is None:
        raise ValueError("GLB has no JSON chunk")
    return gltf, binchunk


def accessor_values(gltf, binchunk, idx):
    acc = gltf["accessors"][idx]
    fmt, size = COMP[acc["componentType"]]
    n = NCOMP[acc["type"]]
    view = gltf["bufferViews"][acc["bufferView"]]
    base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = view.get("byteStride", size * n)
    out = []
    for i in range(acc["count"]):
        out.append(struct.unpack_from("<" + fmt * n, binchunk, base + i * stride))
    return out


def accessor_minmax(gltf, binchunk, idx):
    acc = gltf["accessors"][idx]
    if "min" in acc and "max" in acc:
        return acc["min"], acc["max"]
    vals = accessor_values(gltf, binchunk, idx)
    n = len(vals[0])
    return [min(v[i] for v in vals) for i in range(n)], [max(v[i] for v in vals) for i in range(n)]


def node_is_identity(node):
    t = node.get("translation", [0, 0, 0])
    r = node.get("rotation", [0, 0, 0, 1])
    s = node.get("scale", [1, 1, 1])
    m = node.get("matrix")
    if m is not None:
        ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        return all(abs(a - b) < 1e-4 for a, b in zip(m, ident))
    return (all(abs(v) < 1e-4 for v in t) and all(abs(a - b) < 1e-4 for a, b in zip(r, [0, 0, 0, 1]))
            and all(abs(v - 1) < 1e-4 for v in s))


def mesh_stats(gltf, binchunk):
    """Bounds (scaled by the mesh node's scale) and triangle count."""
    lo, hi, tris = [math.inf] * 3, [-math.inf] * 3, 0
    mesh_nodes = [n for n in gltf.get("nodes", []) if "mesh" in n]
    for node in mesh_nodes or [{"mesh": i} for i in range(len(gltf.get("meshes", [])))]:
        s = node.get("scale", [1, 1, 1])
        t = node.get("translation", [0, 0, 0])
        for prim in gltf["meshes"][node["mesh"]]["primitives"]:
            mn, mx = accessor_minmax(gltf, binchunk, prim["attributes"]["POSITION"])
            for i in range(3):
                a, b = mn[i] * s[i] + t[i], mx[i] * s[i] + t[i]
                lo[i], hi[i] = min(lo[i], a, b), max(hi[i], a, b)
            if "indices" in prim:
                tris += gltf["accessors"][prim["indices"]]["count"] // 3
            else:
                tris += gltf["accessors"][prim["attributes"]["POSITION"]]["count"] // 3
    return lo, hi, tris, mesh_nodes


def clip_durations(gltf, binchunk):
    out = {}
    for a in gltf.get("animations", []):
        dur = 0.0
        for s in a.get("samplers", []):
            mn, mx = accessor_minmax(gltf, binchunk, s["input"])
            dur = max(dur, mx[0] - mn[0])
        out[a.get("name", "")] = dur
    return out


def find_clip(durs, role, aliases):
    for key in aliases.get(role, (role,)):
        for name, d in durs.items():
            if key in name.lower():
                return name, d
    return None, None


# ----------------------------------------------------------------------------
# Textures + VAT
# ----------------------------------------------------------------------------
def channel_std(path):
    from PIL import Image
    import numpy as np
    with Image.open(path) as im:
        a = np.asarray(im.convert("RGB"), dtype=np.float32)
    return float(a[..., 0].std()), float(a[..., 1].std()), a.shape[1], a.shape[0]


def read_vat(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] != b"SVA3":
        raise ValueError("bad SVA3 magic")
    _ver, verts, nclips = struct.unpack_from("<III", data, 4)
    off = 16
    clips = {}
    total = 0
    for _ in range(nclips):
        name = data[off:off + 16].split(b"\0")[0].decode("ascii").strip()
        start, frames, fps = struct.unpack_from("<IIf", data, off + 16)
        clips[name] = (start, frames, fps)
        total = max(total, start + frames)
        off += 28
    need = total * verts * 12
    if len(data) - off < need:
        raise ValueError("SVA3 truncated")
    floats = struct.unpack_from("<" + "f" * (total * verts * 3), data, off)
    return verts, clips, floats


def vat_motion(verts, clip, floats):
    """Max per-vertex travel between any frame of the clip and its first frame."""
    start, frames, _ = clip
    best = 0.0
    for f in range(start, start + frames):
        for v in range(verts):
            i0 = (start * verts + v) * 3
            i1 = (f * verts + v) * 3
            d = math.dist(floats[i0:i0 + 3], floats[i1:i1 + 3])
            best = max(best, d)
    return best


# ----------------------------------------------------------------------------
# Per-category audits
# ----------------------------------------------------------------------------
def _height_check(errors, label, lo, hi, want, tol=HEIGHT_TOL):
    h = hi[1] - lo[1]
    if abs(h - want) > want * tol:
        errors.append(f"{label}: height {h:.2f} (want {want} +-{int(tol * 100)}%)")
    if abs(lo[1]) > max(want * MIN_Y_TOL, 0.05):
        errors.append(f"{label}: min_y {lo[1]:.3f} (feet must sit at Y=0)")
    return h


def _clip_checks(errors, label, durs, spec, aliases):
    for role, bounds in spec.items():
        name, d = find_clip(durs, role, aliases)
        if name is None:
            errors.append(f"{label}: missing clip '{role}'")
            continue
        lo_b, hi_b = bounds if bounds else (CLIP_MIN, CLIP_HARD_MAX)
        if d < max(lo_b, CLIP_MIN) - 1e-3:
            errors.append(f"{label}: clip '{name}' {d:.2f}s below lower bound {max(lo_b, CLIP_MIN):.2f}s")
        if d > hi_b + 1e-3:
            errors.append(f"{label}: clip '{name}' {d:.2f}s above upper bound {hi_b:.2f}s")


def _maps(errors, label, base_dir, ident, needed=("albedo", "normal", "orm")):
    for ch in needed:
        p = os.path.join(base_dir, f"{ident}_{ch}.png")
        if not os.path.exists(p):
            errors.append(f"{label}: missing {ident}_{ch}.png")
            continue
        if ch in ("normal", "orm"):
            sr, sg, w, h = channel_std(p)
            if sr < MAP_STD_MIN or sg < MAP_STD_MIN:
                errors.append(f"{label}: {ch} map flat (R std {sr:.2f}, G std {sg:.2f} < {MAP_STD_MIN})")


def audit_glb(path, category, ident):
    errors = []
    label = f"{category}/{ident}.glb"
    try:
        gltf, binchunk = read_glb(path)
    except Exception as exc:  # noqa: BLE001 - report every parse failure
        return [f"{label}: unreadable ({exc})"], {}
    lo, hi, tris, mesh_nodes = mesh_stats(gltf, binchunk)
    durs = clip_durations(gltf, binchunk)
    info = {"tris": tris, "height": hi[1] - lo[1], "clips": durs}
    base_dir = os.path.dirname(path)
    if category == "heroes":
        _height_check(errors, label, lo, hi, HERO_H)
        if not gltf.get("skins"):
            errors.append(f"{label}: no skin (must be rigged)")
        _clip_checks(errors, label, durs, HERO_CLIPS, HERO_ALIASES)
    elif category == "bosses":
        _height_check(errors, label, lo, hi, BOSS_H)
        if not gltf.get("skins"):
            errors.append(f"{label}: no skin (must be rigged)")
        _clip_checks(errors, label, durs, BOSS_CLIPS, BOSS_ALIASES)
    elif category == "foes":
        h = hi[1] - lo[1]
        if not (FOE_H[0] - 0.01 <= h <= FOE_H[1] + 0.01):
            errors.append(f"{label}: height {h:.2f} outside {FOE_H[0]}-{FOE_H[1]}u")
        if abs(lo[1]) > 0.5:
            errors.append(f"{label}: min_y {lo[1]:.3f} (feet must sit at Y=0)")
        if tris > FOE_TRIS:
            errors.append(f"{label}: {tris} tris > {FOE_TRIS}")
        if not mesh_nodes or not all(node_is_identity(n) for n in mesh_nodes):
            errors.append(f"{label}: mesh node transform must be identity")
        _maps(errors, label, base_dir, ident)
        vat = os.path.join(base_dir, f"{ident}.vat")
        if not os.path.exists(vat):
            errors.append(f"{label}: missing {ident}.vat")
        else:
            try:
                verts, clips, floats = read_vat(vat)
                for c in ("walk", "attack", "hit", "death", "spawn"):
                    if c not in clips:
                        errors.append(f"{label}: VAT missing clip '{c}'")
                if "walk" in clips and vat_motion(verts, clips["walk"], floats) <= VAT_WALK_TRAVEL:
                    errors.append(f"{label}: VAT walk travel <= {VAT_WALK_TRAVEL}")
                for c in ("attack", "death"):
                    if c in clips and vat_motion(verts, clips[c], floats) <= 1e-4:
                        errors.append(f"{label}: VAT '{c}' has no motion")
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{label}: VAT unreadable ({exc})")
    elif category == "props":
        if ident not in PROP_H:
            errors.append(f"{label}: unknown prop kind (expected one of {sorted(PROP_H)})")
        else:
            _height_check(errors, label, lo, hi, PROP_H[ident], 0.06)
        if not mesh_nodes or not all(node_is_identity(n) for n in mesh_nodes):
            errors.append(f"{label}: mesh node transform must be identity")
        mats = gltf.get("materials", [])
        if not mats or not all("baseColorTexture" in m.get("pbrMetallicRoughness", {}) for m in mats):
            errors.append(f"{label}: every material needs a PBR albedo texture")
        _maps(errors, label, base_dir, ident)
    return errors, info


def audit_tree(models_dir=MODELS, verbose=True):
    """Returns (errors, count). Prints one line per asset."""
    errors, count = [], 0
    for cat in ("heroes", "bosses", "foes", "props"):
        d = os.path.join(models_dir, cat)
        if not os.path.isdir(d):
            errors.append(f"missing slot directory models/{cat}/")
            continue
        for f in sorted(os.listdir(d)):
            if not f.lower().endswith(".glb"):
                continue
            count += 1
            errs, info = audit_glb(os.path.join(d, f), cat, f[:-4])
            errors += errs
            if verbose:
                state = "OK " if not errs else "BAD"
                print(f"  {state} {cat}/{f}: h={info.get('height', 0):.1f} tris={info.get('tris', 0)} clips={len(info.get('clips', {}))}")
    return errors, count


# ----------------------------------------------------------------------------
# Self-test fixtures (prove the auditor catches both good and bad assets)
# ----------------------------------------------------------------------------
def write_glb(path, height, min_y=0.0, skinned=True, clips=None, tris=12, node_scale=None, textured=False):
    """Minimal valid GLB: a box-ish mesh with given bounds, optional skin and clips."""
    clips = clips or {}
    pos = []
    w = height * 0.25
    for y in (min_y, min_y + height):
        for x in (-w, w):
            for z in (-w, w):
                pos.append((x, y, z))
    idx = []
    for t in range(tris):
        idx += [t % 8, (t + 1) % 8, (t + 3) % 8]
    blob = b"".join(struct.pack("<fff", *p) for p in pos)
    ib_off = len(blob)
    blob += b"".join(struct.pack("<H", i) for i in idx)
    while len(blob) % 4:
        blob += b"\0"
    views = [{"buffer": 0, "byteOffset": 0, "byteLength": ib_off},
             {"buffer": 0, "byteOffset": ib_off, "byteLength": len(idx) * 2}]
    accs = [{"bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3",
             "min": [-w, min_y, -w], "max": [w, min_y + height, w]},
            {"bufferView": 1, "componentType": 5123, "count": len(idx), "type": "SCALAR"}]
    anims = []
    for name, dur in clips.items():
        off = len(blob)
        blob += struct.pack("<ff", 0.0, dur)
        views.append({"buffer": 0, "byteOffset": off, "byteLength": 8})
        accs.append({"bufferView": len(views) - 1, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0.0], "max": [dur]})
        tin = len(accs) - 1
        off2 = len(blob)
        blob += struct.pack("<8f", 0, 0, 0, 1, 0, 0, 0, 1)
        views.append({"buffer": 0, "byteOffset": off2, "byteLength": 32})
        accs.append({"bufferView": len(views) - 1, "componentType": 5126, "count": 2, "type": "VEC4"})
        anims.append({"name": name, "samplers": [{"input": tin, "output": len(accs) - 1}],
                      "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}}]})
    mesh_node = {"mesh": 0, "name": "mesh"}
    if node_scale:
        mesh_node["scale"] = node_scale
    nodes = [mesh_node, {"name": "root_bone"}]
    gltf = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0, 1]}], "nodes": nodes,
            "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "material": 0}]}],
            "materials": [{"pbrMetallicRoughness": ({"baseColorTexture": {"index": 0}} if textured else {})}],
            "accessors": accs, "bufferViews": views, "buffers": [{"byteLength": len(blob)}]}
    if anims:
        gltf["animations"] = anims
    if skinned:
        gltf["skins"] = [{"joints": [1]}]
        mesh_node["skin"] = 0
    js = json.dumps(gltf).encode()
    while len(js) % 4:
        js += b" "
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    with open(path, "wb") as fh:
        fh.write(out)


def write_vat(path, verts, clips_motion):
    """clips_motion: {name: amplitude}; each clip 8 frames."""
    names = list(clips_motion)
    frames = 8
    data = b"SVA3" + struct.pack("<III", 1, verts, len(names))
    for i, n in enumerate(names):
        data += n.encode().ljust(16, b"\0") + struct.pack("<IIf", i * frames, frames, 30.0)
    for n in names:
        amp = clips_motion[n]
        for f in range(frames):
            for v in range(verts):
                data += struct.pack("<fff", amp * math.sin(f / frames * math.pi), 0.0, 0.0)
    with open(path, "wb") as fh:
        fh.write(data)


def write_map(path, flat):
    from PIL import Image
    import numpy as np
    rng = np.random.default_rng(3)
    if flat:
        a = np.full((512, 512, 3), 128, dtype=np.uint8)
    else:
        a = rng.integers(60, 200, size=(512, 512, 3), dtype=np.uint8)
    Image.fromarray(a, "RGB").save(path)


def self_test(verbose=True):
    """Build good and bad fixtures; the auditor must accept the good and reject the bad."""
    failures = []
    good_hero = {"idle": 2.0, "walk": 1.0, "run": 0.7, "cast": 0.8, "roll": 0.6, "jump": 0.7, "die": 1.5}
    with tempfile.TemporaryDirectory() as tmp:
        for cat in ("heroes", "bosses", "foes", "props"):
            os.makedirs(os.path.join(tmp, cat))
        write_glb(os.path.join(tmp, "heroes", "warden.glb"), HERO_H, clips=good_hero)
        write_glb(os.path.join(tmp, "bosses", "gravelord.glb"), BOSS_H,
                  clips={"Idle": 2.0, "Walk": 1.2, "Attack": 0.9, "Slam": 1.1, "Death": 2.0})
        write_glb(os.path.join(tmp, "foes", "grunt.glb"), 28.0, skinned=False, tris=1800)
        for ch in ("albedo", "normal", "orm"):
            write_map(os.path.join(tmp, "foes", f"grunt_{ch}.png"), flat=False)
        write_vat(os.path.join(tmp, "foes", "grunt.vat"), 6, {"walk": 4.0, "attack": 2.0, "hit": 1.0, "death": 3.0, "spawn": 2.0})
        write_glb(os.path.join(tmp, "props", "rock.glb"), 38.0, skinned=False, textured=True)
        for ch in ("albedo", "normal", "orm"):
            write_map(os.path.join(tmp, "props", f"rock_{ch}.png"), flat=False)
        errs, n = audit_tree(tmp, verbose=False)
        if errs or n != 4:
            failures.append(f"good fixtures rejected: {errs} (n={n})")
        # Bad fixtures: each must produce at least one specific error.
        bad = {
            "heroes/warden.glb (short jump)": (lambda p: write_glb(p, HERO_H, clips=dict(good_hero, jump=0.3)), "heroes", "jump"),
            "heroes/warden.glb (long cast)": (lambda p: write_glb(p, HERO_H, clips=dict(good_hero, cast=1.6)), "heroes", "above upper bound"),
            "heroes/warden.glb (floating)": (lambda p: write_glb(p, HERO_H, min_y=4.0, clips=good_hero), "heroes", "min_y"),
            "heroes/warden.glb (unrigged)": (lambda p: write_glb(p, HERO_H, skinned=False, clips=good_hero), "heroes", "no skin"),
            "heroes/warden.glb (giant)": (lambda p: write_glb(p, 76.0, clips=good_hero), "heroes", "height"),
            "foes/grunt.glb (too dense)": (lambda p: write_glb(p, 28.0, skinned=False, tris=2400), "foes", "tris"),
            "foes/grunt.glb (scaled node)": (lambda p: write_glb(p, 28.0, skinned=False, node_scale=[1, 1, 1.5]), "foes", "identity"),
        }
        for label, (make, cat, needle) in bad.items():
            path = os.path.join(tmp, label.split(" ")[0])
            make(path)
            errs, _ = audit_glb(path, cat, os.path.basename(path)[:-4])
            if not any(needle in e for e in errs):
                failures.append(f"bad fixture not caught: {label} -> {errs}")
        # Restore good foe, then break its maps / VAT.
        write_glb(os.path.join(tmp, "foes", "grunt.glb"), 28.0, skinned=False, tris=1800)
        write_map(os.path.join(tmp, "foes", "grunt_normal.png"), flat=True)
        errs, _ = audit_glb(os.path.join(tmp, "foes", "grunt.glb"), "foes", "grunt")
        if not any("flat" in e for e in errs):
            failures.append(f"flat normal map not caught: {errs}")
        write_map(os.path.join(tmp, "foes", "grunt_normal.png"), flat=False)
        write_vat(os.path.join(tmp, "foes", "grunt.vat"), 6, {"walk": 1.0, "attack": 0.0, "hit": 1.0, "death": 0.0, "spawn": 1.0})
        errs, _ = audit_glb(os.path.join(tmp, "foes", "grunt.glb"), "foes", "grunt")
        if not (any("walk travel" in e for e in errs) and any("'attack' has no motion" in e for e in errs) and any("'death' has no motion" in e for e in errs)):
            failures.append(f"static VAT not caught: {errs}")
    if verbose:
        print(f"  auditor self-test: {'PASS' if not failures else 'FAIL'} "
              f"(good fixtures: 4 assets; bad fixtures: {len(bad) + 2} variants must be rejected)")
        for f in failures:
            print("   - " + f)
    return failures


def main():
    if "--self-test" in sys.argv:
        return 1 if self_test() else 0
    errors, count = audit_tree()
    print(f"{count} connector GLB(s) audited")
    for e in errors:
        print("  - " + e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
