class_name Quality
extends RefCounted
## Device-class detection and every quality-dependent render setting.
## Low / Medium / High are detected from the GPU name and RAM and can be
## overridden from Options. An OpenGL ES 3 safe mode (gl_compatibility) is
## written to the project-settings override file and applies on restart.

enum Tier { LOW, MEDIUM, HIGH }
const TIER_NAMES := ["Low", "Medium", "High"]

## Mobile 3D render scale per tier (Low, Medium, High).
const RENDER_SCALE := [0.75, 1.0, 1.0]
const DYN_FLOOR_MED := 0.85     ## Medium may dynamically drop to this scale.
const FXAA_MIN_SCALE := 0.90    ## Medium enables FXAA only at or above this scale.
const SHADOW_SIZE := [0, 1024, 2048]
const GROUND_Q := [16, 12, 10]  ## Ground grid spacing (units per quad).
const DENSITY := [0.7, 1.0, 1.0]
const OVERRIDE_PATH := "user://override.cfg"

static var tier := Tier.MEDIUM
static var detected := Tier.MEDIUM
static var dyn_scale := 1.0
static var _frame_avg := 1.0 / 60.0
static var _dyn_acc := 0.0


## Heuristic device class from GPU name + physical RAM (MiB).
static func detect(gpu_name: String, ram_mb: int) -> int:
	var g := gpu_name.to_lower()
	var t := Tier.MEDIUM
	if g.contains("adreno"):
		var n := _first_int(g.substr(g.find("adreno")))
		if n >= 730:
			t = Tier.HIGH
		elif n >= 610:
			t = Tier.MEDIUM
		else:
			t = Tier.LOW
	elif g.contains("immortalis") or g.contains("xclipse"):
		t = Tier.HIGH
	elif g.contains("mali-g"):
		var m := _first_int(g.substr(g.find("mali-g") + 6))
		if m >= 100:
			t = Tier.HIGH if m >= 710 else Tier.MEDIUM   # G610 / G710+
		elif m >= 78:
			t = Tier.HIGH                                  # G78
		elif m >= 57:
			t = Tier.MEDIUM                                # G57 / G68 / G76 / G77
		else:
			t = Tier.LOW                                   # G52 and older
	elif g.contains("mali") or g.contains("powervr") or g.contains("sgx") or g.contains("vivante"):
		t = Tier.LOW
	elif g.contains("llvmpipe") or g.contains("swiftshader") or g.contains("lavapipe"):
		t = Tier.LOW
	elif g.contains("nvidia") or g.contains("radeon") or g.contains("geforce") or g.contains("apple"):
		t = Tier.HIGH
	if ram_mb > 0 and ram_mb < 3072:
		t = Tier.LOW
	elif ram_mb > 0 and ram_mb < 5120 and t == Tier.HIGH:
		t = Tier.MEDIUM
	return t


static func _first_int(s: String) -> int:
	var digits := ""
	for ch in s:
		if ch >= "0" and ch <= "9":
			digits += ch
		elif digits != "":
			break
	return int(digits) if digits != "" else 0


static func set_tier(t: int) -> void:
	tier = clampi(t, Tier.LOW, Tier.HIGH)
	dyn_scale = auto_render_scale(tier)


static func auto_render_scale(t: int) -> float:
	return RENDER_SCALE[clampi(t, 0, 2)]


static func prop_density() -> float:
	return DENSITY[tier]


static func ground_q() -> int:
	return GROUND_Q[tier]


static func shadow_distance(dist: float) -> float:
	return 720.0 * dist / 600.0


static func clutter_cull_distance(dist: float) -> float:
	return 950.0 * dist / 600.0


## Anti-aliasing for a tier at a given render scale. MSAA and FXAA never stack.
static func aa_for(t: int, scale: float) -> Dictionary:
	match t:
		Tier.HIGH:
			return {"msaa": Viewport.MSAA_2X, "ssaa": Viewport.SCREEN_SPACE_AA_DISABLED}
		Tier.MEDIUM:
			if scale >= FXAA_MIN_SCALE:
				return {"msaa": Viewport.MSAA_DISABLED, "ssaa": Viewport.SCREEN_SPACE_AA_FXAA}
			return {"msaa": Viewport.MSAA_DISABLED, "ssaa": Viewport.SCREEN_SPACE_AA_DISABLED}
	return {"msaa": Viewport.MSAA_DISABLED, "ssaa": Viewport.SCREEN_SPACE_AA_DISABLED}


static func apply_viewport(vp: Viewport) -> void:
	var s := dyn_scale
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = s
	var aa := aa_for(tier, s)
	vp.msaa_3d = aa.msaa
	vp.screen_space_aa = aa.ssaa
	vp.use_taa = false


## Medium-tier dynamic resolution between DYN_FLOOR_MED and 1.0. High is locked
## native (no dynamic downscale); Low is fixed at its 0.75 scale. Returns true
## when the scale changed (caller re-applies the viewport).
static func update_dynamic(frame_dt: float) -> bool:
	if tier != Tier.MEDIUM:
		return false
	_frame_avg = lerpf(_frame_avg, frame_dt, 0.05)
	_dyn_acc -= frame_dt
	if _dyn_acc > 0.0:
		return false
	_dyn_acc = 1.0
	var old := dyn_scale
	if _frame_avg > 1.0 / 52.0:
		dyn_scale = maxf(dyn_scale - 0.05, DYN_FLOOR_MED)
	elif _frame_avg < 1.0 / 58.0:
		dyn_scale = minf(dyn_scale + 0.05, 1.0)
	return not is_equal_approx(old, dyn_scale)


## Sun shadow: single orthogonal cascade on phones, distance scales with camera.
static func apply_sun(sun: DirectionalLight3D, dist: float) -> void:
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 720.0 * dist / 600.0
	sun.directional_shadow_blend_splits = false
	if tier == Tier.LOW:
		sun.shadow_enabled = false
		return
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	RenderingServer.directional_shadow_atlas_set_size(SHADOW_SIZE[tier], true)
	if tier == Tier.HIGH:
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	else:
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_LOW)


## Writes (or clears) the OpenGL ES 3 safe-mode override. Takes effect on restart.
static func set_gles_safe_mode(on: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(OVERRIDE_PATH)
	if on:
		cfg.set_value("rendering", "renderer/rendering_method", "gl_compatibility")
		cfg.set_value("rendering", "renderer/rendering_method.mobile", "gl_compatibility")
	else:
		if cfg.has_section_key("rendering", "renderer/rendering_method"):
			cfg.erase_section_key("rendering", "renderer/rendering_method")
		if cfg.has_section_key("rendering", "renderer/rendering_method.mobile"):
			cfg.erase_section_key("rendering", "renderer/rendering_method.mobile")
	cfg.save(OVERRIDE_PATH)


static func gles_safe_mode_active() -> bool:
	return RenderingServer.get_current_rendering_method() == "gl_compatibility"
