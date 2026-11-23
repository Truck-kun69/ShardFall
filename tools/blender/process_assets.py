"""Headless Blender 4.5+ asset processor: raw connector output -> slot contract.

    blender -b -P tools/blender/process_assets.py -- --raw tools/asset_raw --out godot/models [--only heroes,foes]

Per category:
  heroes   rigged GLB -> 38.0u tall, feet Z=0 (glTF Y=0), +X forward, clips renamed to
           idle/walk/run/cast/roll/jump/die; the jump clip is trimmed around its apex
           BEFORE strip_root_motion(); clip durations clamped into contract bounds.
  bosses   rigged GLB -> 88.0u, clips idle/walk/attack/slam/die.
  foes     16k-tri rigged mesh -> 1,800-tri game mesh (identity node), Cycles
           selected_to_active bake of Normal + AO/Roughness into 1024 px normal/ORM,
           2048 px albedo, SVA3 vertex animation (walk/attack/hit/death/spawn)
           indexed by UV2.x.
  props    GLB -> contract height, feet at 0, identity node, PBR maps, ALBEDO_FLOOR lift.

Every action assignment goes through assign(), which also sets the action slot
(Blender 4.4+ slotted actions otherwise leave the armature frozen in rest pose).
"""
import argparse
import math
import os
import struct
import sys

import bpy  # noqa: E402  (only available inside Blender)
import bmesh  # noqa: E402
from mathutils import Vector, kdtree  # noqa: E402

HERO_H = 38.0
BOSS_H = 88.0
FOE_H = {"grunt": 28.0, "runner": 24.0, "brute": 42.0, "spitter": 30.0, "charger": 34.0}
PROP_H = {"tree": 130.0, "tree_dead": 125.0, "arch": 120.0, "pillar": 95.0, "wall": 65.0,
          "rock": 38.0, "bush": 26.0, "bones": 22.0}
FOE_TRIS = 1800
BAKE_PX = 1024
ALBEDO_PX = 2048
ALBEDO_FLOOR = 0.12        # minimum luminance for generated albedo (bushes come out crushed)
FPS = 30
HERO_CLIPS = {"idle": ("idle",), "walk": ("walk",), "run": ("run",), "cast": ("cast", "attack", "spell"),
              "roll": ("roll", "dodge"), "jump": ("jump",), "die": ("die", "death")}
BOSS_CLIPS = {"idle": ("idle",), "walk": ("walk", "run"), "attack": ("attack", "swing"),
              "slam": ("slam", "smash"), "die": ("die", "death")}
CLIP_BOUNDS = {"cast": (0.50, 1.10), "roll": (0.40, 0.80), "jump": (0.50, 1.00)}
CLIP_MIN = 0.40
VAT_CLIPS = ("walk", "attack", "hit", "death", "spawn")


# ----------------------------------------------------------------------------
# Scene helpers
# ----------------------------------------------------------------------------
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


def world_bbox(objs):
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    for o in objs:
        if o.type != "MESH":
            continue
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return lo, hi


def normalize(objs, height, src_forward="-Y"):
    """Scale to `height`, feet on Z=0, centred, facing +X (game forward)."""
    roots = [o for o in objs if o.parent is None]
    pivot = bpy.data.objects.new("pivot", None)
    bpy.context.scene.collection.objects.link(pivot)
    for r in roots:
        r.parent = pivot
    turn = {"-Y": math.pi / 2, "+Y": -math.pi / 2, "-X": math.pi, "+X": 0.0}[src_forward]
    pivot.rotation_euler = (0.0, 0.0, turn)
    bpy.context.view_layer.update()
    lo, hi = world_bbox(objs)
    s = height / max(hi.z - lo.z, 1e-6)
    pivot.scale = (s, s, s)
    bpy.context.view_layer.update()
    lo, hi = world_bbox(objs)
    pivot.location -= Vector(((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, lo.z))
    bpy.context.view_layer.update()
    # Bake the pivot into the children so exported nodes are clean.
    for r in roots:
        mw = r.matrix_world.copy()
        r.parent = None
        r.matrix_world = mw
    bpy.data.objects.remove(pivot)
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = next((o for o in objs if o.type == "ARMATURE"), objs[0])
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


# ----------------------------------------------------------------------------
# Animation
# ----------------------------------------------------------------------------
def assign(arm, act):
    """Assign an action AND its slot (Blender 4.4+/4.5 slotted actions).
    Without the slot the armature evaluates nothing and stays frozen."""
    ad = arm.animation_data or arm.animation_data_create()
    ad.action = act
    slots = getattr(act, "slots", None)
    if slots is not None and hasattr(ad, "action_slot"):
        if len(slots) == 0:
            slots.new(id_type="OBJECT", name=arm.name)
        ad.action_slot = act.slots[0]


def fcurves(act):
    """All F-curves of an action (legacy list or layered/slotted channelbags)."""
    if getattr(act, "fcurves", None) is not None and len(act.fcurves) > 0:
        return list(act.fcurves)
    out = []
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for bag in getattr(strip, "channelbags", []):
                out += list(bag.fcurves)
    return out


def clip_len(act):
    a, b = act.frame_range
    return (b - a) / FPS


def map_clips(arm, spec):
    out = {}
    actions = list(bpy.data.actions)
    for role, keys in spec.items():
        for key in keys:
            hit = next((a for a in actions if key in a.name.lower() and a not in out.values()), None)
            if hit is not None:
                out[role] = hit
                break
    missing = [r for r in spec if r not in out]
    if missing:
        raise RuntimeError(f"{arm.name}: missing clips {missing} in {[a.name for a in actions]}")
    for role, act in out.items():
        act.name = role
        act.use_fake_user = True
    return out


def bone_height_curve(arm, act, bone):
    """World-space Z of `bone` head for every frame of the action."""
    assign(arm, act)
    a, b = (int(round(x)) for x in act.frame_range)
    pts = []
    for f in range(a, b + 1):
        bpy.context.scene.frame_set(f)
        pb = arm.pose.bones[bone]
        pts.append((f, (arm.matrix_world @ pb.head).z))
    return pts


def trim(act, start, end):
    """Keep keys in [start, end] (frames), re-keying the ends, shifted to start at 0."""
    for fc in fcurves(act):
        v0, v1 = fc.evaluate(start), fc.evaluate(end)
        kps = fc.keyframe_points
        for i in reversed(range(len(kps))):
            if kps[i].co.x < start - 1e-4 or kps[i].co.x > end + 1e-4:
                kps.remove(kps[i])
        kps.insert(start, v0)
        kps.insert(end, v1)
        for kp in kps:
            kp.co.x -= start
            kp.handle_left.x -= start
            kp.handle_right.x -= start
        fc.update()
    act.frame_range = (0.0, end - start)


def trim_apex(arm, act, hips, target_s):
    """Centre the jump window on the apex of the hips height curve."""
    pts = bone_height_curve(arm, act, hips)
    apex_f = max(pts, key=lambda p: p[1])[0]
    a, b = act.frame_range
    half = target_s * FPS * 0.5
    start = max(a, apex_f - half)
    end = min(b, start + target_s * FPS)
    start = max(a, end - target_s * FPS)
    trim(act, start, end)


def strip_root_motion(act, root_names=("root", "hips", "pelvis")):
    """Zero horizontal travel on the root/hips location channels (keeps vertical)."""
    for fc in fcurves(act):
        path = fc.data_path
        if not path.endswith(".location"):
            continue
        if not any(f'"{n}"' in path.lower() for n in root_names):
            continue
        if fc.array_index in (0, 2):   # bone-local X/Z are horizontal for Y-up rigs
            base = fc.keyframe_points[0].co.y if len(fc.keyframe_points) else 0.0
            for kp in fc.keyframe_points:
                kp.co.y = base
                kp.handle_left.y = base
                kp.handle_right.y = base
            fc.update()


def scale_time(act, factor):
    for fc in fcurves(act):
        for kp in fc.keyframe_points:
            kp.co.x *= factor
            kp.handle_left.x *= factor
            kp.handle_right.x *= factor
        fc.update()
    a, b = act.frame_range
    act.frame_range = (a * factor, b * factor)


def enforce_bounds(act, role):
    lo, hi = CLIP_BOUNDS.get(role, (CLIP_MIN, 1e9))
    lo = max(lo, CLIP_MIN)
    d = clip_len(act)
    if d < lo:
        scale_time(act, lo / max(d, 1e-3))
    elif d > hi and role != "jump":
        scale_time(act, hi / d)


def find_bone(arm, keys):
    for k in keys:
        for b in arm.data.bones:
            if k in b.name.lower():
                return b.name
    return arm.data.bones[0].name


# ----------------------------------------------------------------------------
# Textures
# ----------------------------------------------------------------------------
def new_image(name, px, non_color):
    img = bpy.data.images.new(name, px, px, alpha=False, float_buffer=False)
    img.colorspace_settings.name = "Non-Color" if non_color else "sRGB"
    return img


def albedo_floor(img):
    px = list(img.pixels)
    for i in range(0, len(px), 4):
        r, g, b = px[i], px[i + 1], px[i + 2]
        lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if lum < ALBEDO_FLOOR:
            k = ALBEDO_FLOOR / max(lum, 1e-4)
            px[i], px[i + 1], px[i + 2] = min(r * k, 1.0), min(g * k, 1.0), min(b * k, 1.0)
    img.pixels[:] = px


def save_png(img, path):
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()


def bake(low, high, kind, img, extrusion=0.6):
    """Cycles selected_to_active bake of `kind` from high onto low into img."""
    scn = bpy.context.scene
    scn.render.engine = "CYCLES"
    scn.cycles.samples = 16
    scn.render.bake.use_selected_to_active = True
    scn.render.bake.cage_extrusion = extrusion
    scn.render.bake.margin = 8
    for mat in low.data.materials:
        nt = mat.node_tree
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = img
        nt.nodes.active = node
    bpy.ops.object.select_all(action="DESELECT")
    high.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    kw = {"type": kind, "use_selected_to_active": True}
    if kind == "NORMAL":
        kw["normal_space"] = "TANGENT"
    if kind == "DIFFUSE":
        kw["pass_filter"] = {"COLOR"}
    bpy.ops.object.bake(**kw)


# ----------------------------------------------------------------------------
# Categories
# ----------------------------------------------------------------------------
def export_glb(objs, path, animations):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True,
                              export_animations=animations, export_animation_mode="ACTIONS",
                              export_force_sampling=True, export_image_format="AUTO")
    print(f"  exported {path}")


def process_rigged(src, out_path, height, spec, is_hero):
    reset()
    objs = import_glb(src)
    arm = next((o for o in objs if o.type == "ARMATURE"), None)
    if arm is None:
        raise RuntimeError(f"{src}: no armature (rigging stage output expected)")
    normalize(objs, height)
    clips = map_clips(arm, spec)
    hips = find_bone(arm, ("hips", "pelvis", "root"))
    for role, act in clips.items():
        assign(arm, act)
        if is_hero and role == "jump":
            lo, hi = CLIP_BOUNDS["jump"]
            target = min(max(clip_len(act), lo), hi)
            trim_apex(arm, act, hips, target)      # apex-centred trim FIRST
        strip_root_motion(act)                     # then remove horizontal travel
        enforce_bounds(act, role)
    assign(arm, clips["idle"])
    export_glb(objs, out_path, True)


def write_vat(path, verts, clips):
    names = [c for c in VAT_CLIPS if c in clips]
    start = 0
    header = b"SVA3" + struct.pack("<III", 1, verts, len(names))
    table, body = b"", b""
    for n in names:
        frames = clips[n]
        table += n.encode().ljust(16, b"\0") + struct.pack("<IIf", start, len(frames), float(FPS))
        for fr in frames:
            for off in fr:
                body += struct.pack("<fff", *off)
        start += len(frames)
    with open(path, "wb") as fh:
        fh.write(header + table + body)


def to_game_space(v):
    """Blender Z-up -> glTF/Godot Y-up offset."""
    return (v.x, v.z, -v.y)


def process_foe(src, out_dir, ident):
    reset()
    objs = import_glb(src)
    arm = next((o for o in objs if o.type == "ARMATURE"), None)
    high = next(o for o in objs if o.type == "MESH")
    normalize(objs, FOE_H.get(ident, 30.0))
    # Game mesh: decimated copy, unwrapped, no armature, identity transform.
    low = high.copy()
    low.data = high.data.copy()
    low.name = ident
    bpy.context.scene.collection.objects.link(low)
    low.parent = None
    for m in list(low.modifiers):
        low.modifiers.remove(m)
    tris = sum(len(p.vertices) - 2 for p in low.data.polygons)
    dec = low.modifiers.new("decimate", "DECIMATE")
    dec.ratio = min(1.0, FOE_TRIS / max(tris, 1) * 0.98)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.modifier_apply(modifier="decimate")
    bpy.ops.object.mode_set(mode="EDIT")
    bm = bmesh.from_edit_mesh(low.data)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.update_edit_mesh(low.data)
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(island_margin=0.02)
    bpy.ops.object.mode_set(mode="OBJECT")
    mat = bpy.data.materials.new(ident + "_mat")
    mat.use_nodes = True
    low.data.materials.clear()
    low.data.materials.append(mat)
    # Bakes (high -> low): normal + AO + roughness at 1024 px, albedo at 2048 px.
    albedo = new_image(ident + "_albedo", ALBEDO_PX, False)
    normal = new_image(ident + "_normal", BAKE_PX, True)
    ao = new_image(ident + "_ao", BAKE_PX, True)
    rough = new_image(ident + "_rough", BAKE_PX, True)
    bake(low, high, "DIFFUSE", albedo)
    bake(low, high, "NORMAL", normal)
    bake(low, high, "AO", ao)
    bake(low, high, "ROUGHNESS", rough)
    albedo_floor(albedo)
    orm = new_image(ident + "_orm", BAKE_PX, True)
    a_px, r_px = list(ao.pixels), list(rough.pixels)
    o_px = [0.0] * len(a_px)
    for i in range(0, len(a_px), 4):
        o_px[i], o_px[i + 1], o_px[i + 2], o_px[i + 3] = a_px[i], r_px[i], 0.0, 1.0
    orm.pixels[:] = o_px
    for img, ch in ((albedo, "albedo"), (normal, "normal"), (orm, "orm")):
        save_png(img, os.path.join(out_dir, f"{ident}_{ch}.png"))
    # UV2.x = vertex column for the VAT texture.
    uv2 = low.data.uv_layers.new(name="UV2")
    n = len(low.data.vertices)
    for loop in low.data.loops:
        uv2.data[loop.index].uv = ((loop.vertex_index + 0.5) / n, 0.0)
    # VAT: each game vertex follows its nearest rest-pose source vertex.
    tree = kdtree.KDTree(len(high.data.vertices))
    for v in high.data.vertices:
        tree.insert(high.matrix_world @ v.co, v.index)
    tree.balance()
    nearest = [tree.find(low.matrix_world @ v.co)[1] for v in low.data.vertices]
    rest = [high.matrix_world @ high.data.vertices[i].co for i in nearest]
    clips = {}
    if arm is not None:
        spec = {"walk": ("walk", "run"), "attack": ("attack",), "hit": ("hit", "hurt"), "death": ("death", "die"), "spawn": ("spawn", "rise")}
        for role, keys in spec.items():
            act = next((a for a in bpy.data.actions if any(k in a.name.lower() for k in keys)), None)
            if act is None:
                continue
            assign(arm, act)
            a, b = (int(round(x)) for x in act.frame_range)
            frames = []
            for f in range(a, b + 1):
                bpy.context.scene.frame_set(f)
                dg = bpy.context.evaluated_depsgraph_get()
                ev = high.evaluated_get(dg)
                me = ev.to_mesh()
                frames.append([to_game_space(ev.matrix_world @ me.vertices[i].co - rest[k]) for k, i in enumerate(nearest)])
                ev.to_mesh_clear()
            clips[role] = frames
    write_vat(os.path.join(out_dir, f"{ident}.vat"), n, clips)
    export_glb([low], os.path.join(out_dir, f"{ident}.glb"), False)


def process_prop(src, out_dir, ident):
    reset()
    objs = import_glb(src)
    normalize(objs, PROP_H[ident])
    meshes = [o for o in objs if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    prop = bpy.context.view_layer.objects.active
    prop.name = ident
    for img in bpy.data.images:
        if img.size[0] == 0:
            continue
        name = img.name.lower()
        ch = "normal" if "normal" in name else ("orm" if any(k in name for k in ("metal", "rough", "orm", "occlusion")) else "albedo")
        if ch == "albedo":
            albedo_floor(img)
        save_png(img, os.path.join(out_dir, f"{ident}_{ch}.png"))
    export_glb([prop], os.path.join(out_dir, f"{ident}.glb"), False)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    args = ap.parse_args(argv)
    only = set(filter(None, args.only.split(",")))
    done = 0
    for cat in ("heroes", "bosses", "foes", "props"):
        if only and cat not in only:
            continue
        src_dir = os.path.join(args.raw, cat)
        if not os.path.isdir(src_dir):
            continue
        out_dir = os.path.join(args.out, cat)
        os.makedirs(out_dir, exist_ok=True)
        for f in sorted(os.listdir(src_dir)):
            stage = "_rig.glb" if cat in ("heroes", "bosses") else "_mesh.glb"
            if not f.endswith(stage):
                continue
            ident = f[: -len(stage)]
            src = os.path.join(src_dir, f)
            print(f"[{cat}] {ident}")
            if cat == "heroes":
                process_rigged(src, os.path.join(out_dir, ident + ".glb"), HERO_H, HERO_CLIPS, True)
            elif cat == "bosses":
                process_rigged(src, os.path.join(out_dir, ident + ".glb"), BOSS_H, BOSS_CLIPS, False)
            elif cat == "foes":
                process_foe(src, out_dir, ident)
            else:
                process_prop(src, out_dir, ident)
            done += 1
    print(f"processed {done} asset(s). Next: python3 tools/texture_budget.py --apply && python3 tools/gate_check.py")


if __name__ == "__main__":
    main()
