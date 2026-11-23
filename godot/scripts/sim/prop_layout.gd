class_name PropLayout
extends RefCounted
## Single deterministic prop layout per (chunk_x, chunk_y, stage).
##  Stream 1 (solids): identical across all quality tiers; drives collision.
##  Stream 2 (decor):  bush + grass, count scaled by Quality.prop_density().
## Placement only consults Terrain.passable0() (initial liquid level0), so the
## Stage 4 rising tide never desynchronises the layout.

const CHUNK := 600.0
const SPAWN_CLEAR := 160.0
const MIN_GAP := 48.0
const MARGIN := 60.0
const HCELL := 64.0
const SOLID_KINDS := ["tree", "tree_dead", "rock", "wall", "pillar", "arch", "bones"]
const DECOR_KINDS := ["bush", "grass"]
const HIGH_KINDS := ["tree", "tree_dead", "pillar", "arch"]

## Weak back-reference: Terrain owns this layout, so a strong ref would cycle.
var terrain: Terrain:
	get:
		return _terrain_ref.get_ref() as Terrain
var stage := 0
var _terrain_ref: WeakRef

var col_x := PackedFloat32Array()
var col_y := PackedFloat32Array()
var col_r := PackedFloat32Array()
var col_high := PackedByteArray()
var col_n := 0

var _chunks := {}   # Vector2i -> Array of [kind, x, y, rot, scale]
var _cells := {}    # Vector2i -> PackedInt32Array of collider indices
var _dead_tree := 0.25


func _init(t: Terrain, stage_idx: int) -> void:
	_terrain_ref = weakref(t)
	stage = stage_idx
	_dead_tree = float(Content.act(stage_idx).dead_tree)


static func seed_for(cx: int, cy: int, stage_idx: int, stream: int) -> int:
	var h := (cx * 73856093) ^ (cy * 19349663) ^ (stage_idx * 83492791) ^ (stream * 2654435761)
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7FFFFFFFFFFFFFFF


## Collision circles for one solid, scaled with the prop scale.
## Returns an Array of [x, y, r, high].
static func colliders_for(kind: String, x: float, y: float, rot: float, s: float) -> Array:
	var u := Vector2(cos(rot), sin(rot))
	match kind:
		"tree", "tree_dead", "pillar":
			return [[x, y, 14.0 * s, true]]
		"rock":
			return [[x, y, 18.0 * s, false]]
		"wall":
			var out := []
			for off in [-36.0, -18.0, 0.0, 18.0, 36.0]:
				var p: Vector2 = Vector2(x, y) + u * (float(off) * s)
				out.append([p.x, p.y, 18.0 * s, false])
			return out
		"arch":
			var a := Vector2(x, y) + u * (45.0 * s)
			var b := Vector2(x, y) - u * (45.0 * s)
			return [[a.x, a.y, 14.0 * s, true], [b.x, b.y, 14.0 * s, true]]
	return []


static func chunk_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CHUNK), floori(p.y / CHUNK))


## Stream 1: solids for a chunk (cached, colliders registered once).
func solids(c: Vector2i) -> Array:
	if _chunks.has(c):
		return _chunks[c]
	var list := _gen_solids(c)
	_chunks[c] = list
	for s in list:
		for cc in colliders_for(s[0], s[1], s[2], s[3], s[4]):
			_add_collider(cc[0], cc[1], cc[2], cc[3])
	return list


## Generates stream 1 without touching the cache (used by determinism tests).
func gen_solids_uncached(c: Vector2i) -> Array:
	return _gen_solids(c)


func _gen_solids(c: Vector2i) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_for(c.x, c.y, stage, 1)
	var base := Vector2(c.x * CHUNK, c.y * CHUNK)
	var out := []
	var circles := []   # [x, y, r] for gap checks
	# Landmarks: arch + 2 flanking walls + pillar + bones.
	var nl := rng.randi_range(1, 2)
	for l in nl:
		for attempt in 4:
			var ctr := base + Vector2(rng.randf_range(200.0, 400.0), rng.randf_range(200.0, 400.0))
			var ang := rng.randf_range(0.0, TAU)
			var s := rng.randf_range(0.95, 1.1)
			var u := Vector2(cos(ang), sin(ang))
			var v := Vector2(-u.y, u.x)
			var wall_a := ctr + u * (125.0 * s)
			var wall_b := ctr - u * (125.0 * s)
			var pil := ctr + v * (95.0 * s)
			var bon := ctr - v * (50.0 * s)
			var parts := [
				["arch", ctr.x, ctr.y, ang, s],
				["wall", wall_a.x, wall_a.y, ang, s],
				["wall", wall_b.x, wall_b.y, ang, s],
				["pillar", pil.x, pil.y, ang, s],
				["bones", bon.x, bon.y, rng.randf_range(0.0, TAU), s],
			]
			if _parts_ok(parts, circles):
				_commit(parts, out, circles)
				break
	# Clusters: groves of 2-4 trees or outcrops of 3-5 rocks.
	var ncl := rng.randi_range(4, 6)
	for k in ncl:
		var grove := rng.randf() < 0.5
		var ctr2 := base + Vector2(rng.randf_range(MARGIN + 40.0, CHUNK - MARGIN - 40.0),
			rng.randf_range(MARGIN + 40.0, CHUNK - MARGIN - 40.0))
		var n := rng.randi_range(2, 4) if grove else rng.randi_range(3, 5)
		for m in n:
			for attempt in 5:
				var a := rng.randf() * TAU
				var d := 0.0 if (m == 0 and attempt == 0) else rng.randf_range(70.0, 125.0)
				var p := ctr2 + Vector2(cos(a), sin(a)) * d
				p.x = clampf(p.x, base.x + MARGIN, base.x + CHUNK - MARGIN)
				p.y = clampf(p.y, base.y + MARGIN, base.y + CHUNK - MARGIN)
				var kind := "rock"
				if grove:
					kind = "tree_dead" if rng.randf() < _dead_tree else "tree"
				var sc := rng.randf_range(0.85, 1.25)
				var part := [[kind, p.x, p.y, rng.randf() * TAU, sc]]
				if _parts_ok(part, circles):
					_commit(part, out, circles)
					break
	return out


func _check_circles(kind: String, x: float, y: float, rot: float, s: float) -> Array:
	var cs := colliders_for(kind, x, y, rot, s)
	if cs.is_empty():
		cs = [[x, y, 10.0 * s, false]]   # bones: gap-checked footprint, no collider
	return cs


func _parts_ok(parts: Array, circles: Array) -> bool:
	for part in parts:
		for cc in _check_circles(part[0], part[1], part[2], part[3], part[4]):
			var x: float = cc[0]
			var y: float = cc[1]
			var r: float = cc[2]
			if not terrain.passable0(x, y):
				return false
			if Vector2(x, y).length() < SPAWN_CLEAR + r:
				return false
			for o in circles:
				var dx: float = x - float(o[0])
				var dy: float = y - float(o[1])
				var gap := sqrt(dx * dx + dy * dy) - r - float(o[2])
				if gap < MIN_GAP:
					return false
	return true


func _commit(parts: Array, out: Array, circles: Array) -> void:
	for part in parts:
		out.append(part)
		for cc in _check_circles(part[0], part[1], part[2], part[3], part[4]):
			circles.append([cc[0], cc[1], cc[2]])


## Stream 2: decor for a chunk. density = Quality.prop_density():
## 1.0 gives 150-286 per chunk (Medium/High), 0.7 gives 105-155 (Low).
func decor(c: Vector2i, density: float) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_for(c.x, c.y, stage, 2)
	var base_n := rng.randi_range(150, 286)
	var n := base_n
	if density < 1.0:
		n = int(105.0 + float(base_n - 150) * (50.0 / 136.0))
	solids(c)
	var base := Vector2(c.x * CHUNK, c.y * CHUNK)
	var out := []
	for i in n:
		var is_bush := rng.randf() < 0.3
		for attempt in 4:
			var p := base + Vector2(rng.randf() * CHUNK, rng.randf() * CHUNK)
			if not terrain.passable0(p.x, p.y):
				continue
			if inside_any_solid(p, 4.0):
				continue
			out.append(["bush" if is_bush else "grass", p.x, p.y, rng.randf() * TAU, rng.randf_range(0.8, 1.3)])
			break
	return out


static func decor_count_range(density: float) -> Vector2i:
	return Vector2i(150, 286) if density >= 1.0 else Vector2i(105, 155)


func _add_collider(x: float, y: float, r: float, high: bool) -> void:
	var i := col_n
	col_x.append(x)
	col_y.append(y)
	col_r.append(r)
	col_high.append(1 if high else 0)
	col_n += 1
	var x0 := floori((x - r) / HCELL)
	var x1 := floori((x + r) / HCELL)
	var y0 := floori((y - r) / HCELL)
	var y1 := floori((y + r) / HCELL)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var key := Vector2i(cx, cy)
			if _cells.has(key):
				var arr: PackedInt32Array = _cells[key]
				arr.append(i)
				_cells[key] = arr
			else:
				_cells[key] = PackedInt32Array([i])


## Test hook: registers an extra collider (after ensuring the chunk exists).
func add_test_collider(x: float, y: float, r: float, high: bool) -> void:
	solids(chunk_of(Vector2(x, y)))
	_add_collider(x, y, r, high)


func ensure_around(p: Vector2, r: float) -> void:
	var c0 := chunk_of(p - Vector2(r + MARGIN, r + MARGIN))
	var c1 := chunk_of(p + Vector2(r + MARGIN, r + MARGIN))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var c := Vector2i(cx, cy)
			if not _chunks.has(c):
				solids(c)


## Spatial-hashed 2-pass normal slide-out against solid circles.
func slide_out(p: Vector2, radius: float, include_low: bool) -> Vector2:
	ensure_around(p, radius)
	var q := p
	for pass_i in 2:
		var x0 := floori((q.x - radius) / HCELL)
		var x1 := floori((q.x + radius) / HCELL)
		var y0 := floori((q.y - radius) / HCELL)
		var y1 := floori((q.y + radius) / HCELL)
		for cy in range(y0, y1 + 1):
			for cx in range(x0, x1 + 1):
				var key := Vector2i(cx, cy)
				if not _cells.has(key):
					continue
				var arr: PackedInt32Array = _cells[key]
				for idx in arr:
					if not include_low and col_high[idx] == 0:
						continue
					var dx := q.x - col_x[idx]
					var dy := q.y - col_y[idx]
					var rr := col_r[idx] + radius
					var d2 := dx * dx + dy * dy
					if d2 >= rr * rr:
						continue
					if d2 < 0.000001:
						dx = 1.0
						dy = 0.0
						d2 = 1.0
					var d := sqrt(d2)
					q = Vector2(col_x[idx] + dx / d * rr, col_y[idx] + dy / d * rr)
	return q


func inside_any_solid(p: Vector2, radius: float) -> bool:
	ensure_around(p, radius)
	var x0 := floori((p.x - radius) / HCELL)
	var x1 := floori((p.x + radius) / HCELL)
	var y0 := floori((p.y - radius) / HCELL)
	var y1 := floori((p.y + radius) / HCELL)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var key := Vector2i(cx, cy)
			if not _cells.has(key):
				continue
			for idx in (_cells[key] as PackedInt32Array):
				var dx := p.x - col_x[idx]
				var dy := p.y - col_y[idx]
				var rr := col_r[idx] + radius
				if dx * dx + dy * dy < rr * rr:
					return true
	return false


## Distance along `dir` until a swept circle first touches a HIGH collider.
## Returns `dist` when the path is clear.
func sweep_high(from: Vector2, dir: Vector2, dist: float, radius: float) -> float:
	var to := from + dir * dist
	ensure_around(from, radius)
	ensure_around(to, radius)
	var pad := radius + 64.0
	var x0 := floori((minf(from.x, to.x) - pad) / HCELL)
	var x1 := floori((maxf(from.x, to.x) + pad) / HCELL)
	var y0 := floori((minf(from.y, to.y) - pad) / HCELL)
	var y1 := floori((maxf(from.y, to.y) + pad) / HCELL)
	var best := dist
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var key := Vector2i(cx, cy)
			if not _cells.has(key):
				continue
			for idx in (_cells[key] as PackedInt32Array):
				if col_high[idx] == 0:
					continue
				var m := from - Vector2(col_x[idx], col_y[idx])
				var rr := col_r[idx] + radius
				var b := m.dot(dir)
				var cc := m.dot(m) - rr * rr
				if cc <= 0.0:
					continue
				var disc := b * b - cc
				if disc < 0.0:
					continue
				var s := -b - sqrt(disc)
				if s >= 0.0 and s < best:
					best = s
	return best


## Jump landing: vaults low props (rock, wall) and ground hazards, stops short of
## high props (tree, tree_dead, pillar, arch posts) and never lands inside any
## solid or in impassable terrain.
func jump_landing(from: Vector2, dir: Vector2, dist: float, radius: float) -> Vector2:
	var u := dir.normalized() if dir.length_squared() > 0.0 else Vector2.RIGHT
	var d := dist
	var hit := sweep_high(from, u, dist, radius)
	if hit < d:
		d = maxf(hit - 2.0, 0.0)
	while d > 0.0:
		var p := from + u * d
		if not inside_any_solid(p, radius) and terrain.passable(p):
			return p
		d -= 6.0
	return from
