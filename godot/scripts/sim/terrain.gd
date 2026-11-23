class_name Terrain
extends RefCounted
## Deterministic analytic terrain shared by simulation and rendering.
## height() is mirrored exactly by shaders/3d/terrain_h.gdshaderinc, so the
## displaced ground mesh, decals, fog and every FX element drape on the same surface.

const DEEP := 8.0          ## Liquid deeper than this is impassable.
const CLIFF_SLOPE := 1.15  ## Height gradient above this is an impassable cliff.
const SPAWN_SAFE := 260.0  ## No hazard patches inside this radius of the origin.
const FLOOR_H := 10.0      ## Guaranteed dry plateau height at the origin.
const PLATEAU_R := 420.0

var act := 0
var amp := 40.0
var seeds := Vector4.ZERO
var level0 := -20.0        ## Initial liquid level; prop layout uses this only.
var liquid := "water"
var patch_kind := "spikes"
var tide_rate := 0.0
var tide_max := 0.0
var time := 0.0
var layout: PropLayout

# Test-only override: an axis-aligned region treated as impassable.
var block_rect := Rect2()
var force_hazard := ""


func _init(act_idx: int) -> void:
	act = act_idx
	var a: Dictionary = Content.act(act_idx)
	amp = float(a.amp)
	seeds = a.seeds
	level0 = float(a.level0)
	liquid = String(a.liquid)
	patch_kind = String(a.patch)
	tide_rate = float(a.tide_rate)
	tide_max = float(a.tide_max)
	layout = PropLayout.new(self, act_idx)


func height(x: float, y: float) -> float:
	var hb := amp * (0.55 * sin(x * 0.0041 + seeds.x) * cos(y * 0.0037 + seeds.y)
		+ 0.30 * sin((x + y) * 0.0063 + seeds.z)
		+ 0.15 * sin(x * 0.0117 - y * 0.0093 + seeds.w))
	var w := exp(-(x * x + y * y) / (PLATEAU_R * PLATEAU_R))
	return hb + w * maxf(FLOOR_H - hb, 0.0)


func ground_y(p: Vector2) -> float:
	return height(p.x, p.y)


## Current liquid level (Stage 4 rises over time).
func level() -> float:
	return level0 + minf(time * tide_rate, tide_max)


func has_liquid() -> bool:
	return liquid != "none"


func depth_at(x: float, y: float, lvl: float) -> float:
	if liquid == "none":
		return -1.0
	return lvl - height(x, y)


func slope(x: float, y: float) -> float:
	var gx := (height(x + 2.0, y) - height(x - 2.0, y)) * 0.25
	var gy := (height(x, y + 2.0) - height(x, y - 2.0)) * 0.25
	return sqrt(gx * gx + gy * gy)


func passable(p: Vector2) -> bool:
	if block_rect.has_area() and block_rect.has_point(p):
		return false
	if depth_at(p.x, p.y, level()) > DEEP:
		return false
	return slope(p.x, p.y) < CLIFF_SLOPE


## Passability against the initial liquid level. Prop placement uses this so the
## layout never changes when the Stage 4 tide rises.
func passable0(x: float, y: float) -> bool:
	if liquid != "none" and depth_at(x, y, level0) > -4.0:
		return false
	return slope(x, y) < CLIFF_SLOPE


func patch(x: float, y: float) -> float:
	return sin(x * 0.011 + seeds.y * 2.0) * sin(y * 0.013 + seeds.x * 2.0) + 0.5 * sin((x - y) * 0.007 + seeds.w)


## Ground hazard under a point: shallow liquid ("water", "lava", "poison") or a
## patch hazard ("spikes", "oil"). Empty string when the ground is safe.
func hazard_at(p: Vector2) -> String:
	if force_hazard != "":
		return force_hazard
	var d := depth_at(p.x, p.y, level())
	if d > 0.0:
		return liquid
	if p.length_squared() > SPAWN_SAFE * SPAWN_SAFE and patch(p.x, p.y) > 1.08:
		return patch_kind
	return ""


## Hero ground movement: solid-prop slide-out (both low and high props) plus the
## passability guard so the slide never pushes into deep liquid or cliffs.
func move(a: Vector2, delta: Vector2, radius: float) -> Vector2:
	var q := a + delta
	var r := layout.slide_out(q, radius, true)
	if r != q and not passable(r) and passable(q): return a
	if passable(r):
		return r
	# Blocked by liquid or cliff: try sliding along each axis.
	var qx := layout.slide_out(Vector2(q.x, a.y), radius, true)
	if passable(qx):
		return qx
	var qy := layout.slide_out(Vector2(a.x, q.y), radius, true)
	if passable(qy):
		return qy
	return a


## Foe movement. Identical guard: a foe is never shoved into deep liquid/cliffs.
func foe_move(a: Vector2, delta: Vector2, radius: float) -> Vector2:
	var q := a + delta
	var r := layout.slide_out(q, radius, true)
	if r != q and not passable(r) and passable(q): return a
	if passable(r):
		return r
	var qx := layout.slide_out(Vector2(q.x, a.y), radius, true)
	if passable(qx):
		return qx
	var qy := layout.slide_out(Vector2(a.x, q.y), radius, true)
	if passable(qy):
		return qy
	return a
