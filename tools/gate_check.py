#!/usr/bin/env python3
"""Automated release gate for Shardfall: Rift Survivors (Android-only alpha).

Exits 0 only when every step passes; there are no skips and no fallbacks.

  1. Static code assertions (anti-shortcut invariants + required contract values)
  2. Asset & GLB binary audit (+ auditor self-test fixtures, connector dry run at $0)
  3. .ctex audit over textures/terrain + models (0 at <= 256 px) + texture_budget --check
  4. Engine tests: import, headless boot, gate_chunk (Low/Med/High x 5 acts),
     unit suite, real-GPU render smoke (Xvfb + Vulkan) with shader-error scan
  5. Canonical Android build (tools/build_android.sh): signed arm64-v8a APK

Requirements: Godot 4.7.2 (GODOT env or `godot` on PATH), Android SDK, JDK,
Python 3 with numpy + Pillow, and Xvfb (or a $DISPLAY) with a Vulkan driver.
"""
import glob
import os
import py_compile
import re
import shutil
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GD = os.path.join(ROOT, "godot")
TOOLS = os.path.join(ROOT, "tools")
GODOT = os.environ.get("GODOT", "godot")
sys.path.insert(0, TOOLS)

FAILS = []
STEP = [""]


def step(title):
    STEP[0] = title
    print()
    print("=" * 78)
    print(title)
    print("=" * 78, flush=True)


def check(cond, desc, detail=""):
    tag = "PASS" if cond else "FAIL"
    print(f"  [{tag}] {desc}" + (f"  -- {detail}" if detail and not cond else ""), flush=True)
    if not cond:
        FAILS.append(f"{STEP[0].split(':')[0]}: {desc}" + (f" ({detail})" if detail else ""))
    return cond


def read(rel):
    with open(os.path.join(GD, rel), encoding="utf-8") as fh:
        return fh.read()


def godot_files(exts):
    out = []
    for dirpath, dirnames, files in os.walk(GD):
        dirnames[:] = [d for d in dirnames if d not in (".godot", "android")]
        for f in files:
            if f.endswith(exts):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def func_body(src, name):
    m = re.search(r"^(?:static )?func " + re.escape(name) + r"\(.*?(?=^(?:static )?func |\Z)", src, re.M | re.S)
    return m.group(0) if m else ""


def strip_comments(src):
    """Remove // and /* */ comments (shaders) so prose never trips a code check."""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


# ============================================================================
# 1. Static assertions
# ============================================================================
def static_checks():
    step("STEP 1: static code assertions")
    code = godot_files((".gd", ".gdshader", ".gdshaderinc", ".tscn", ".tres", ".cfg", ".godot"))
    texts = {p: open(p, encoding="utf-8").read() for p in code}
    rel = lambda p: os.path.relpath(p, GD)  # noqa: E731

    forbidden = [
        (r"JumpTuck", "zero JumpTuck bone hacks"),
        (r"pal\s*\*\s*4\.0", "zero pal * 4.0 over-tinting"),
        (r"inverse\s*\(\s*mat3", "zero inverse(mat3(...)) in shaders"),
        (r"has_feature\(\s*[\"']web[\"']\s*\)", "zero OS.has_feature(\"web\")"),
        (r"fmod\s*\([^)]*\)\s*<\s*[\w.]*dt\b", "zero fmod(t, X) < dt gameplay timers"),
        (r"material_override\s*=\s*prop_mat\b", "zero material_override = prop_mat"),
    ]
    for pat, desc in forbidden:
        hits = [f"{rel(p)}:{t[:m.start()].count(chr(10)) + 1}" for p, t in texts.items() for m in re.finditer(pat, t)]
        check(not hits, desc, ", ".join(hits[:5]))
    for shader in ("shaders/3d/fog.gdshader", "shaders/3d/prop.gdshader"):
        check(not re.search(r"\bdiscard\b", strip_comments(read(shader))), f"no fragment discard in {shader}")
    for f in ("scripts/render3d/world_view_3d.gd", "scripts/render3d/fx_3d.gd"):
        check(".slice(" not in read(f), f"zero .slice() in {f}")
    check(not glob.glob(os.path.join(ROOT, "**", "*.html"), recursive=True), "no web build artifacts (*.html) in repo")

    presets = read("export_presets.cfg")
    names = re.findall(r'^name="([^"]+)"', presets, re.M)
    plats = re.findall(r'^platform="([^"]+)"', presets, re.M)
    check(names == ["Android"] and plats == ["Android"], "single export preset 'Android' (no Web/Lite)", f"{names} {plats}")
    check(not re.search(r"lite", presets, re.I), "zero Lite preset")
    check('package/unique_name="com.shardfall.riftsurvivors"' in presets, "package com.shardfall.riftsurvivors")
    check("architectures/arm64-v8a=true" in presets and "architectures/armeabi-v7a=false" in presets
          and "architectures/x86=false" in presets and "architectures/x86_64=false" in presets, "arm64-v8a only")
    check("gradle_build/use_gradle_build=false" in presets and "package/signed=true" in presets, "template build, signed")

    proj = read("project.godot")
    check('renderer/rendering_method="mobile"' in proj, "Mobile renderer")
    check("file_logging/enable_file_logging.android=false" in proj, "file logging disabled on Android")
    check("pointing/emulate_touch_from_mouse.android=false" in proj, "emulate_touch_from_mouse.android=false")
    check("textures/vram_compression/import_etc2_astc=true" in proj, "ETC2/ASTC import enabled")
    check('config/project_settings_override="user://override.cfg"' in proj, "settings override file (GLES3 safe mode)")

    q = read("scripts/render3d/quality.gd")
    m = re.search(r"const RENDER_SCALE := \[([^\]]+)\]", q)
    scales = [float(x) for x in m.group(1).split(",")] if m else []
    check(scales == [0.75, 1.0, 1.0], "auto_render_scale = 0.75 / 1.0 / 1.0", str(scales))
    check("DYN_FLOOR_MED := 0.85" in q and "FXAA_MIN_SCALE := 0.90" in q, "Medium dynamic floor 0.85, FXAA only >= 0.90")
    check("Viewport.MSAA_2X" in q and "SCREEN_SPACE_AA_FXAA" in q, "High MSAA 2x / Medium FXAA")
    check("SHADOW_SIZE := [0, 1024, 2048]" in q and "SHADOW_ORTHOGONAL" in q, "single orthogonal cascade 1024/2048")
    check("SHADOW_QUALITY_SOFT_LOW" in q and "SHADOW_QUALITY_SOFT_MEDIUM" in q, "soft shadow LOW (Med) / MEDIUM (High)")
    check("720.0 * dist / 600.0" in q, "shadow distance = 720 * dist / 600")
    check("950.0 * dist / 600.0" in q, "clutter cull = 950 * dist / 600")
    check("GROUND_Q := [16, 12, 10]" in q, "ground_q = [16, 12, 10]")
    check("gl_compatibility" in q, "OpenGL ES 3 safe-mode toggle")
    mainsrc = read("scripts/main.gd")
    check("Quality.detect(" in mainsrc and "Quality.apply_viewport" in mainsrc and "update_dynamic" in mainsrc,
          "main.gd applies auto-detected quality + dynamic scale")

    fs = read("scripts/sim/fixed_step.gd")
    check("const STEP := 1.0 / 60.0" in fs and "const MAX_STEPS := 2" in fs, "fixed step 60 Hz, MAX_STEPS 2")
    wv = read("scripts/render3d/world_view_3d.gd")
    check("prev_pos.lerp(" in wv and "clock.alpha()" in mainsrc, "alpha() interpolation used by WorldView3D")
    check("lerpf(s.ox[i], s.px[i], alpha)" in wv and "lerpf(w.prev_jump_p, w.jump_p, alpha)" in wv,
          "foes + jump arc interpolated")
    check("const CAP := 720" in read("scripts/sim/swarm.gd"), "swarm CAP 720")
    check("func separate(tick: int)" in read("scripts/sim/swarm.gd") and "(i & 1) != parity" in read("scripts/sim/swarm.gd"),
          "parity-split deterministic separation")

    w = read("scripts/sim/world.gd")
    for const in ("JUMP_TIME := 0.55", "JUMP_DIST := 200.0", "JUMP_CD := 2.0", "INPUT_BUFFER := 0.15",
                  "ROLL_TIME := 0.26", "ACCEL_T := 0.06", "DECEL_T := 0.05"):
        check(const in w, f"world.gd {const}")
    check("move_toward(" in w, "crisp accel/decel via move_toward")
    pl = read("scripts/sim/prop_layout.gd")
    check("SPAWN_CLEAR := 160.0" in pl and "MIN_GAP := 48.0" in pl, "SPAWN_CLEAR 160 / MIN_GAP 48")
    check("passable0" in pl and "level0" in read("scripts/sim/terrain.gd"), "layout uses level0 (tide-invariant)")
    t = read("scripts/sim/terrain.gd")
    guard = "if r != q and not passable(r) and passable(q): return a"
    check(guard in func_body(t, "move"), "Terrain.move() passability guard")
    check(guard in func_body(t, "foe_move"), "Terrain.foe_move() passability guard")
    b = read("scripts/sim/bosses.gd")
    check(all(s in b for s in ("CHASE", "WINDUP", "EXECUTE", "RECOVER", '"cleave"', '"volley"', '"slam"', '"summon"')),
          "boss FSM + telegraphed attacks")

    check("GROUND_SIZE := 2200.0" in wv, "GROUND_SIZE 2200")
    check('"tex_scale", 0.0085' in wv and '"tint", 0.18' in wv, "tex_scale 0.0085 / tint 0.18")
    check("TONE_MAPPER_ACES" in wv and "AMBIENT_SOURCE_SKY" in wv and "GLOW_BLEND_MODE_SCREEN" in wv,
          "ACES + sky ambient + screen glow")
    check("glow_bloom = 0.0" in wv and "glow_hdr_threshold = 1.25" in wv and "glow_intensity = 0.45" in wv,
          "glow bloom 0 / threshold 1.25 / intensity 0.45")
    check("1.6 * LIGHT_GAIN" in wv and "omni_range = 360.0" in wv and "0.9 * LIGHT_GAIN" in wv
          and "torch.shadow_enabled = false" in wv, "torch 1.6*gain r360 no shadow, key 0.9*gain")
    check("SUN_FLOOR := 0.32" in wv and "AMBIENT_FLOOR := 0.22" in wv and "VIGNETTE_MAX := 0.35" in wv, "gloom floors")
    check("Color(0.96, 0.95, 0.93)" in wv, "neutral prop_mat tint")
    check("null if Models.has_pbr(mesh)" in func_body(wv, "_build_cell"), "_build_cell never applies prop_mat to PBR")
    check("water.visible = terrain.liquid != \"none\"" in wv, "water hidden when liquid == none")
    fx = read("scripts/render3d/fx_3d.gd")
    check("subdivide_width = 8" in fx and "subdivide_width = 24" in wv, "decals 8x8 / fog 24x24 subdivided")
    check(fx.count("ground_y(") >= 8, "FX draped via ground_y(pos) + offset")
    for sh in ("decal.gdshader", "fog.gdshader", "terrain.gdshader"):
        check('#include "res://shaders/3d/terrain_h.gdshaderinc"' in read("shaders/3d/" + sh), f"{sh} drapes via terrain_h")
    foe = read("shaders/3d/foe.gdshader")
    check("UV2.x" in foe and "has_albedo" in foe and "mix(0.65, 1.0, orm.r)" in foe and "= orm.g" in foe
          and "= orm.b" in foe and "hint_range(0.0, 0.1)" in foe, "foe shader VAT/PBR/10% tint")
    md = read("scripts/render3d/models.gd")
    body = func_body(md, "mesh_from_asset")
    check(0 <= body.find("get_surface_override_material") < body.find("root.free()"),
          "mesh_from_asset copies override materials before freeing nodes")
    check("for s in m.get_surface_count():" in func_body(md, "has_pbr"), "has_pbr checks all surfaces")
    check("SHADOW_CASTING_SETTING_OFF" in func_body(wv, "_build_cell") and "VISIBILITY_RANGE_FADE_DISABLED" in wv,
          "clutter no-shadow + culled without fade")
    check("_hero_blob" in wv and "4.0 * jp * (1.0 - jp) * JUMP_LIFT" in w and "JUMP_LIFT := 58.0" in w,
          "hero contact shadow vs parabolic lift 4*jp*(1-jp)*58")
    check("depth_test_inverted" in read("shaders/3d/silhouette.gdshader") and "material_overlay = _sil_mat" in read("scripts/render3d/hero_rig.gd"),
          "hero inverted-depth silhouette pass")

    hr = read("scripts/render3d/hero_rig.gd")
    check("CAST_RATE := 1.25" in hr and "CAST_VIS_CD := 0.45" in hr, "CAST_RATE 1.25 / CAST_VIS_CD 0.45")
    check("var ref := clampf(spd, _v_walk, _v_run)" in hr and "return clampf(spd / ref, 0.85, 1.30)" in hr, "loco_rate formula")
    check("ONE_SHOT_REQUEST_FADE_OUT" in hr and "_spd > _v_walk * 0.35" in hr, "cast_full fade-out abort")
    check("AnimationNodeBlendSpace1D" in hr and "bs.sync = true" in hr and "mv.sync = false" in hr, "walk/run synced, idle independent")
    check("lerp_angle(" in hr and "YAW_RATE := 14.0" in hr, "smooth yaw lerp_angle(dt*14)")
    check("AnimationNodeTimeSeek" in hr and "jump_seek/seek_request" in hr, "jump clip scrubbed by jump_progress")
    br = read("scripts/render3d/boss_rig.gd")
    check("static var _flash_shader" in br and "static func pick_clip(" in br and "light.light_energy = base_light * f" in br,
          "BossRig static flash shader, pick_clip, light fade")

    tc = read("scripts/ui/touch_controls.gd")
    check("CLEARANCE := 12.0" in tc and "get_display_safe_area" in tc and '["ROLL", "JUMP", "ULT", "1", "2"]' in tc,
          "5 thumb buttons, 12 px clearance in safe area")
    check("func _relayout()" in tc and "_process" not in tc, "touch layout cached (no per-frame relayout)")
    hud = read("scripts/ui/hud.gd")
    hz = float(re.search(r"REDRAW_HZ := ([\d.]+)", hud).group(1))
    check(15.0 <= hz <= 20.0, f"HUD throttled redraw {hz} Hz")
    pbody = func_body(hud, "_process")
    check("queue_redraw()" in pbody and "_acc" in pbody, "no unconditional per-frame queue_redraw")
    sc = read("scripts/ui/screens.gd")
    check(all(x in sc for x in ('"Gear"', '"Upgrades"', '"Modes"', '"Options"', '"PLAY"')) and "is_touchscreen_available" in sc,
          "main menu: PLAY + Gear/Upgrades/Modes/Options, keyboard help hidden on touch")
    check("MenuStage3D.new()" in mainsrc, "visible 3D MenuStage3D")
    bus = read("default_bus_layout.tres")
    check("AudioEffectLimiter" in bus and all(f'&"{b}"' in bus for b in ("Music", "SFX", "UI")), "bus layout Master limiter + Music/SFX/UI")
    sfx = read("scripts/autoload/sfx.gd")
    check("VOICES := 5" in sfx and "AudioEffectPanner" in sfx and "func play_at(" in sfx and "_xp_pitch" in sfx,
          "5-voice stealing, panned play_at, XP pitch climb")

    for p in glob.glob(os.path.join(TOOLS, "*.py")) + [os.path.join(TOOLS, "blender", "process_assets.py")]:
        try:
            py_compile.compile(p, doraise=True)
            ok = True
        except py_compile.PyCompileError as exc:
            ok = False
            print(exc)
        check(ok, f"python compiles: {os.path.relpath(p, ROOT)}")
    bp = open(os.path.join(TOOLS, "blender", "process_assets.py"), encoding="utf-8").read()
    check("ad.action_slot = act.slots[0]" in bp and "def assign(arm, act)" in bp, "Blender assign() sets action_slot")
    rig_body = bp[bp.find("def process_rigged("):bp.find("def write_vat(")]
    i_trim = rig_body.find("trim_apex(arm, act, hips, target)")
    i_strip = rig_body.find("strip_root_motion(act)")
    check(0 <= i_trim < i_strip, "apex-centred jump trim before strip_root_motion()")
    check("selected_to_active" in bp and "ALBEDO_FLOOR" in bp and "BAKE_PX = 1024" in bp, "Cycles selected_to_active bake + ALBEDO_FLOOR")


# ============================================================================
# 2. Asset audit
# ============================================================================
def asset_checks():
    step("STEP 2: asset & GLB binary audit")
    import asset_audit
    failures = asset_audit.self_test(verbose=True)
    check(not failures, "auditor self-test (good accepted, bad rejected)", "; ".join(failures))
    for cat in ("heroes", "bosses", "foes", "props"):
        check(os.path.isdir(os.path.join(GD, "models", cat)), f"slot directory models/{cat}/ exists")
    errors, count = asset_audit.audit_tree(verbose=True)
    if count == 0:
        print("  connector GLBs present: 0 -> every slot uses its procedural fallback ($0.00 spend)")
    check(not errors, f"{count} connector GLB(s) satisfy the slot contract", "; ".join(errors[:6]))
    r = subprocess.run([sys.executable, os.path.join(TOOLS, "asset_connectors.py"), "--plan"],
                       capture_output=True, text=True, timeout=60, env=dict(os.environ, FAL_KEY=""))
    tail = r.stdout.strip().splitlines()[-2:]
    for line in tail:
        print("  | " + line)
    check(r.returncode == 0 and "DRY RUN" in r.stdout and "$0.00 spent" in r.stdout, "connector pipeline dry run ($0.00)")


# ============================================================================
# 3. .ctex audit
# ============================================================================
def ctex_checks():
    step("STEP 3: .ctex audit + texture budget")
    rc = subprocess.run([GODOT, "--headless", "--path", GD, "--import"], capture_output=True, text=True, timeout=900)
    check(rc.returncode == 0 and "SCRIPT ERROR" not in rc.stdout + rc.stderr, "godot --import")
    sources = []
    for base in ("textures/terrain", "models"):
        for dirpath, _, files in os.walk(os.path.join(GD, base)):
            sources += [os.path.join(dirpath, f) for f in files if f.endswith(".import")]
    small, total = [], 0
    for imp in sorted(sources):
        text = open(imp, encoding="utf-8").read()
        dests = sorted(set(re.findall(r'"res://(\.godot/imported/[^"]+\.ctex)"', text)))
        check(bool(dests), f"{os.path.relpath(imp, GD)} has imported .ctex")
        for d in dests:
            p = os.path.join(GD, d)
            if not os.path.exists(p):
                check(False, f"missing {d}")
                continue
            with open(p, "rb") as fh:
                head = fh.read(16)
            magic = head[:4]
            _ver, w, h = struct.unpack("<III", head[4:16])
            total += 1
            if magic != b"GST2" or w <= 256 or h <= 256:
                small.append(f"{os.path.basename(d)} {w}x{h} {magic!r}")
            print(f"  ctex {w:>5}x{h:<5} {os.path.basename(d)}")
    check(total > 0, f"{total} .ctex files audited")
    check(not small, "0 .ctex at <= 256 px in textures/terrain + models", "; ".join(small))
    r = subprocess.run([sys.executable, os.path.join(TOOLS, "texture_budget.py"), "--check"], capture_output=True, text=True)
    for line in r.stdout.rstrip().splitlines():
        print("  | " + line)
    check(r.returncode == 0, "texture_budget.py --check")


# ============================================================================
# 4. Engine tests
# ============================================================================
ERR_RE = re.compile(r"SCRIPT ERROR|SHADER ERROR|Parse Error|Compile Error|^ERROR:|leaked at exit|still in use at exit|Invalid access", re.M)


def run_godot(args, label, timeout, env=None, show=lambda l: True):
    t0 = time.time()
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    out = (r.stdout or "") + (r.stderr or "")
    shown = 0
    for line in out.splitlines():
        if line.strip() and show(line):
            print("  | " + line)
            shown += 1
    errs = [l for l in out.splitlines() if ERR_RE.search(l) and "ALSA" not in l]
    check(r.returncode == 0, f"{label}: exit code 0", f"rc={r.returncode}")
    check(not errs, f"{label}: no engine/script/shader errors or leaks", "; ".join(errs[:4]))
    print(f"  ({label} took {time.time() - t0:.1f}s)")
    return r.returncode == 0 and not errs, out


def engine_checks():
    step("STEP 4: headless engine tests")
    base = [GODOT, "--headless", "--path", GD]
    run_godot(base + ["--quit"], "godot --headless --quit (main scene boot)", 300)
    _, out = run_godot(base + ["--quit-after", "180"], "main menu 180 frames", 300)
    run_godot(base + ["res://tests/gate_chunk.tscn"], "tests/gate_chunk.tscn (Low/Med/High x 5 acts)", 1800,
              show=lambda l: l.startswith("GATE_CHUNK") or "FAIL" in l)
    _, out = run_godot(base + ["res://tests/tests.tscn", "--", "unit"], "tests/tests.tscn -- unit", 900,
                       show=lambda l: not l.startswith("  PASS"))
    m = re.search(r"UNIT SUMMARY: (\d+) passed, (\d+) failed", out)
    check(bool(m) and int(m.group(2)) == 0 and int(m.group(1)) > 100, "unit suite summary", m.group(0) if m else "no summary")
    for key in ("loco_rate continuous", "moving during cast_full -> FADE_OUT abort", "light fades to 0 during death sink",
                "pick_clip idle when slow", "death plays die", "slide_out pushes out of solids", "vaults a low rock",
                "stops short of a high tree", "foe_move guard", "solid layout invariant under rising tide"):
        check(f"PASS  " in out and any(key in l and "PASS" in l for l in out.splitlines()), f"unit covers: {key}")
    render_smoke()


def render_smoke():
    """Real renderer (Vulkan) pass: compiles every shader and screenshots the game."""
    shots = os.path.join(ROOT, "build", "gate_shots")
    os.makedirs(shots, exist_ok=True)
    env = dict(os.environ)
    lvp = "/opt/lavapipe/lvp_icd.json"
    if not env.get("VK_ICD_FILENAMES") and os.path.exists(lvp):
        env["VK_ICD_FILENAMES"] = lvp
    prefix = []
    if not env.get("DISPLAY"):
        xvfb = shutil.which("xvfb-run")
        if not check(xvfb is not None, "render smoke: display available (xvfb-run or $DISPLAY)"):
            return
        prefix = [xvfb, "-a", "-s", "-screen 0 1280x720x24"]
    combos = [("menu", ["--menu=1", "--frames=40", "--hero=ember"]),
              ("act1_high_boss", ["--act=0", "--tier=2", "--frames=70", "--boss=1"]),
              ("act5_low", ["--act=4", "--tier=0", "--frames=50", "--hero=storm"])]
    for name, extra in combos:
        out_png = os.path.join(shots, name + ".png")
        if os.path.exists(out_png):
            os.remove(out_png)
        args = prefix + [GODOT, "--path", GD, "--rendering-driver", "vulkan", "--rendering-method", "mobile",
                         "--audio-driver", "Dummy", "--resolution", "1280x720", "res://tests/render_shot.tscn", "--",
                         "--out=" + out_png] + extra
        ok, out = run_godot(args, f"render smoke [{name}]", 1200, env=env,
                            show=lambda l: "render_shot" in l or "Vulkan" in l or "ERROR" in l)
        if check(os.path.exists(out_png), f"render smoke [{name}] screenshot written"):
            from PIL import Image
            import numpy as np
            a = np.asarray(Image.open(out_png).convert("RGB"), dtype=np.float32)
            check(a.std() > 12.0, f"render smoke [{name}] image has content (std {a.std():.1f})")


# ============================================================================
# 5. Android build
# ============================================================================
def build_checks():
    step("STEP 5: canonical Android APK build")
    t0 = time.time()
    r = subprocess.run(["bash", os.path.join(TOOLS, "build_android.sh")], capture_output=True, text=True, timeout=3600)
    out = r.stdout + r.stderr
    for line in out.splitlines():
        if "JAVA_TOOL_OPTIONS" in line or "_JAVA_OPTIONS" in line:
            continue
        print("  | " + line)
    check(r.returncode == 0 and "BUILD OK" in out, "tools/build_android.sh", f"rc={r.returncode}")
    apk = os.path.join(ROOT, "build", "ShardFall.apk")
    check(os.path.exists(apk), "build/ShardFall.apk exists")
    m = re.search(r"\.ctex inside APK: (\d+) files, ([\d.]+) MB", out)
    check(bool(m) and int(m.group(1)) > 0, ".ctex payload reported", m.group(0) if m else "")
    print(f"  (build took {time.time() - t0:.1f}s)")


def main():
    t0 = time.time()
    print("Shardfall: Rift Survivors - release gate")
    print(f"root: {ROOT}")
    gv = subprocess.run([GODOT, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"godot: {gv}")
    if not check(gv.startswith("4.7.2.stable"), "Godot 4.7.2 stable", gv):
        return 1
    static_checks()
    asset_checks()
    ctex_checks()
    engine_checks()
    build_checks()
    print()
    print("=" * 78)
    if FAILS:
        print(f"GATE FAIL: {len(FAILS)} check(s) failed ({time.time() - t0:.0f}s)")
        for f in FAILS:
            print("  - " + f)
        return 1
    print(f"GATE PASS: all checks green ({time.time() - t0:.0f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
