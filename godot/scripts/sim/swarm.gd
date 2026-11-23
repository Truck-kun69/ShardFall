class_name Swarm
extends RefCounted
## Structure-of-arrays foe pool. Pre-allocated to CAP; spawning reuses a free list.
## Owns elemental statuses, reaction cascades and deterministic separation.

const CAP := 720
enum Kind { GRUNT, RUNNER, BRUTE, SPITTER, CHARGER }
const KINDS := 5
const DEATH_T := 0.45
const SPAWN_T := 0.35
const MAX_CASCADE := 2

# Status durations (seconds).
const BURN_T := 3.0
const CHILL_T := 2.5
const SHOCK_T := 2.0
const CHAOS_T := 4.0

var count := 0        ## High-water mark of used slots.
var alive_n := 0
var px := PackedFloat32Array()
var py := PackedFloat32Array()
var ox := PackedFloat32Array()   ## Previous-tick position (render interpolation).
var oy := PackedFloat32Array()
var vx := PackedFloat32Array()
var vy := PackedFloat32Array()
var sep_x := PackedFloat32Array()
var sep_y := PackedFloat32Array()
var hp := PackedFloat32Array()
var maxhp := PackedFloat32Array()
var speed := PackedFloat32Array()
var radius := PackedFloat32Array()
var dmg := PackedFloat32Array()
var flash := PackedFloat32Array()
var anim := PackedFloat32Array()
var atk_t := PackedFloat32Array()
var state_t := PackedFloat32Array()
var blade_cd := PackedFloat32Array()
var dying := PackedFloat32Array()
var spawn_t := PackedFloat32Array()
var lock_x := PackedFloat32Array()
var lock_y := PackedFloat32Array()
var st_burn := PackedFloat32Array()
var st_chill := PackedFloat32Array()
var st_shock := PackedFloat32Array()
var st_chaos := PackedFloat32Array()
var kind := PackedInt32Array()
var state := PackedInt32Array()
var elite := PackedByteArray()
var alive := PackedByteArray()
var used := PackedByteArray()   ## Slot in use (alive or playing its death anim).

var killed := PackedInt32Array()   ## Kills since the last drain (world consumes).
var killed_n := 0
var reactions: Array = []          ## [name, x, y] reaction events since last drain.
var grid: SpatialGrid
var _free := PackedInt32Array()
var _free_n := 0
var _nbuf := PackedInt32Array()
var _cbuf := PackedInt32Array()


func _init() -> void:
	# Packed arrays are value types in GDScript, so each member is sized directly.
	px.resize(CAP); py.resize(CAP); ox.resize(CAP); oy.resize(CAP); vx.resize(CAP); vy.resize(CAP)
	sep_x.resize(CAP); sep_y.resize(CAP); hp.resize(CAP); maxhp.resize(CAP); speed.resize(CAP)
	radius.resize(CAP); dmg.resize(CAP); flash.resize(CAP); anim.resize(CAP); atk_t.resize(CAP)
	state_t.resize(CAP); blade_cd.resize(CAP); dying.resize(CAP); spawn_t.resize(CAP)
	lock_x.resize(CAP); lock_y.resize(CAP); st_burn.resize(CAP); st_chill.resize(CAP)
	st_shock.resize(CAP); st_chaos.resize(CAP)
	kind.resize(CAP); state.resize(CAP); elite.resize(CAP); alive.resize(CAP); used.resize(CAP)
	killed.resize(CAP)
	_free.resize(CAP)
	_nbuf.resize(96)
	_cbuf.resize(96)
	grid = SpatialGrid.new(CAP)
	clear()


func clear() -> void:
	count = 0
	alive_n = 0
	_free_n = 0
	killed_n = 0
	alive.fill(0)
	used.fill(0)
	reactions.clear()


func spawn(k: int, x: float, y: float, is_elite: bool, hp_mult: float) -> int:
	var i := -1
	if _free_n > 0:
		_free_n -= 1
		i = _free[_free_n]
	elif count < CAP:
		i = count
		count += 1
	else:
		return -1
	var d: Dictionary = Content.FOES[Content.FOE_ORDER[k]]
	var em := 6.0 if is_elite else 1.0
	kind[i] = k
	elite[i] = 1 if is_elite else 0
	px[i] = x; py[i] = y; ox[i] = x; oy[i] = y
	vx[i] = 0.0; vy[i] = 0.0; sep_x[i] = 0.0; sep_y[i] = 0.0
	maxhp[i] = float(d.hp) * hp_mult * em
	hp[i] = maxhp[i]
	speed[i] = float(d.speed) * (0.85 if is_elite else 1.0)
	radius[i] = float(d.radius) * (1.4 if is_elite else 1.0)
	dmg[i] = float(d.dmg) * (1.6 if is_elite else 1.0)
	flash[i] = 0.0
	anim[i] = float(i % 17) * 0.137
	atk_t[i] = 1.0 + float(i % 7) * 0.2
	state_t[i] = 0.0
	state[i] = 0
	blade_cd[i] = 0.0
	dying[i] = 0.0
	spawn_t[i] = SPAWN_T
	st_burn[i] = 0.0; st_chill[i] = 0.0; st_shock[i] = 0.0; st_chaos[i] = 0.0
	alive[i] = 1
	used[i] = 1
	alive_n += 1
	return i


func _kill(i: int) -> void:
	if alive[i] == 0:
		return
	alive[i] = 0
	alive_n -= 1
	dying[i] = DEATH_T
	if killed_n < killed.size():
		killed[killed_n] = i
		killed_n += 1


## Rebuilds the spatial grid from all living foes.
func rebuild_grid() -> void:
	grid.clear()
	for i in count:
		if alive[i] == 1:
			grid.insert(i, px[i], py[i])


## Deterministic CPU separation, parity-split: on even ticks even slots resolve,
## on odd ticks odd slots resolve. Each foe only pushes itself, so the result is
## independent of iteration order.
func separate(tick: int) -> void:
	var parity := tick & 1
	for i in count:
		if alive[i] == 0:
			continue
		if (i & 1) != parity:
			continue
		var x := px[i]
		var y := py[i]
		var ri := radius[i]
		var sx := 0.0
		var sy := 0.0
		var n := grid.query(x, y, ri + 18.0, _nbuf)
		for k in n:
			var j := _nbuf[k]
			if j == i or alive[j] == 0:
				continue
			var dx := x - px[j]
			var dy := y - py[j]
			var rr := ri + radius[j]
			var d2 := dx * dx + dy * dy
			if d2 >= rr * rr:
				continue
			if d2 < 0.0001:
				# Exact overlap: split by slot order so it stays deterministic.
				dx = 1.0 if i > j else -1.0
				dy = 0.0
				d2 = 1.0
			var d := sqrt(d2)
			var push := (rr - d) / d
			sx += dx * push
			sy += dy * push
		# Parity halves the update rate, so push twice as hard (capped).
		sep_x[i] = clampf(sx * 1.6, -6.0, 6.0)
		sep_y[i] = clampf(sy * 1.6, -6.0, 6.0)


## Applies damage with elemental statuses and reactions. Returns true on kill.
## Reactions may cascade to neighbours up to MAX_CASCADE deep.
func damage(i: int, amount: float, elem: int, depth: int = 0) -> bool:
	if i < 0 or i >= count or alive[i] == 0:
		return false
	var amt := amount
	if st_shock[i] > 0.0:
		amt *= 1.25
	var react := ""
	match elem:
		Content.Elem.FIRE:
			if st_chill[i] > 0.0:
				react = "shatter"
				amt *= 2.0
				st_chill[i] = 0.0
			elif st_shock[i] > 0.0:
				react = "overload"
				st_shock[i] = 0.0
			st_burn[i] = BURN_T
		Content.Elem.COLD:
			if st_burn[i] > 0.0:
				react = "quench"
				amt *= 1.6
				st_burn[i] = 0.0
			else:
				st_chill[i] = CHILL_T
		Content.Elem.LIGHT:
			if st_chill[i] > 0.0:
				react = "superconduct"
			st_shock[i] = SHOCK_T
		Content.Elem.CHAOS:
			if st_burn[i] > 0.0 or st_chill[i] > 0.0 or st_shock[i] > 0.0:
				react = "corrupt"
			st_chaos[i] = CHAOS_T
	hp[i] -= amt
	flash[i] = 0.12
	var x := px[i]
	var y := py[i]
	if react != "":
		if reactions.size() < 64:
			reactions.append([react, x, y])
		if depth < MAX_CASCADE:
			_cascade(react, i, x, y, amount, depth + 1)
	if hp[i] <= 0.0:
		_kill(i)
		return true
	return false


func _cascade(react: String, src: int, x: float, y: float, amount: float, depth: int) -> void:
	var rad := 90.0 if react == "superconduct" else 80.0
	var n := grid.query(x, y, rad, _cbuf)
	# Copy candidates first: nested damage() calls reuse _cbuf at the next depth.
	var local := PackedInt32Array()
	local.resize(n)
	for k in n:
		local[k] = _cbuf[k]
	for k in n:
		var j := local[k]
		if j == src or alive[j] == 0:
			continue
		var dx := px[j] - x
		var dy := py[j] - y
		if dx * dx + dy * dy > rad * rad:
			continue
		match react:
			"overload":
				damage(j, amount * 0.4, Content.Elem.FIRE, depth)
			"superconduct":
				damage(j, amount * 0.25, Content.Elem.LIGHT, depth)
			"corrupt":
				st_chaos[j] = CHAOS_T
				damage(j, amount * 0.2, Content.Elem.CHAOS, MAX_CASCADE)
			"shatter":
				damage(j, amount * 0.3, Content.Elem.PHYS, depth)
			"quench":
				st_chill[j] = maxf(st_chill[j], 1.0)


## Status DoTs and timers. `dt` is the (possibly slowed) foe delta.
func tick_status(dt: float) -> void:
	for i in count:
		if used[i] == 0:
			continue
		if alive[i] == 0:
			dying[i] -= dt
			if dying[i] <= 0.0:
				used[i] = 0
				_free[_free_n] = i
				_free_n += 1
			continue
		flash[i] = maxf(flash[i] - dt, 0.0)
		spawn_t[i] = maxf(spawn_t[i] - dt, 0.0)
		blade_cd[i] = maxf(blade_cd[i] - dt, 0.0)
		var dot := 0.0
		if st_burn[i] > 0.0:
			st_burn[i] -= dt
			dot += 6.0 + maxhp[i] * 0.03
		if st_chaos[i] > 0.0:
			st_chaos[i] -= dt
			dot += 4.0 + maxhp[i] * 0.02
		if st_chill[i] > 0.0:
			st_chill[i] -= dt
		if st_shock[i] > 0.0:
			st_shock[i] -= dt
		if dot > 0.0:
			hp[i] -= dot * dt
			if hp[i] <= 0.0:
				_kill(i)


func slow_factor(i: int) -> float:
	return 0.6 if st_chill[i] > 0.0 else 1.0


## Returns the nearest living foe within `max_r` of (x, y), or -1.
func nearest(x: float, y: float, max_r: float, exclude: int = -1) -> int:
	var best := -1
	var bd := max_r * max_r
	var n := grid.query(x, y, max_r, _nbuf)
	if n >= _nbuf.size():
		# Dense area overflowed the buffer: fall back to a full scan.
		for i in count:
			if alive[i] == 0 or i == exclude:
				continue
			var d := (px[i] - x) * (px[i] - x) + (py[i] - y) * (py[i] - y)
			if d < bd:
				bd = d
				best = i
		return best
	for k in n:
		var i := _nbuf[k]
		if alive[i] == 0 or i == exclude:
			continue
		var d2 := (px[i] - x) * (px[i] - x) + (py[i] - y) * (py[i] - y)
		if d2 < bd:
			bd = d2
			best = i
	if best == -1 and max_r > SpatialGrid.CELL * 4.0:
		for i in count:
			if alive[i] == 0 or i == exclude:
				continue
			var d3 := (px[i] - x) * (px[i] - x) + (py[i] - y) * (py[i] - y)
			if d3 < bd:
				bd = d3
				best = i
	return best


## Collects living foes inside a circle into `out`; returns the count.
func in_radius(x: float, y: float, r: float, out: PackedInt32Array) -> int:
	var n := 0
	for i in count:
		if alive[i] == 0:
			continue
		var dx := px[i] - x
		var dy := py[i] - y
		var rr := r + radius[i]
		if dx * dx + dy * dy <= rr * rr:
			if n >= out.size():
				return n
			out[n] = i
			n += 1
	return n
