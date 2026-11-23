class_name SimWorld
extends RefCounted
## Authoritative fixed-step simulation: hero, swarm, boss, weapons, pickups.
## Rendering only reads from here. No engine nodes, so it runs headless in tests.

const HERO_R := 12.0
const ACCEL_T := 0.06          ## Seconds from rest to full speed.
const DECEL_T := 0.05          ## Seconds from full speed to rest.
const ROLL_TIME := 0.26
const ROLL_SPEED := 540.0
const ROLL_CD := 0.5
const INPUT_BUFFER := 0.15
const PERFECT_WINDOW := 0.12   ## First part of a roll that counts as a perfect dodge.
const SLOWMO_T := 0.45
const SLOWMO_SCALE := 0.35
const JUMP_TIME := 0.55
const JUMP_DIST := 200.0
const JUMP_CD := 2.0
const JUMP_LIFT := 58.0
const BOSS_TIME := 240.0
const PROJ_CAP := 384
const GEM_CAP := 600
const MARK_CAP := 64
const PICK_CAP := 32
const SKILL_CD := [7.0, 12.0]
const EVENT_CAP := 256

var act := 0
var hero_id := "warden"
var mode := "story"
var terrain: Terrain
var layout: PropLayout
var swarm: Swarm
var boss: Boss = null
var rng := RandomNumberGenerator.new()
var meta := {}

var time := 0.0
var tick := 0

# --- Hero -------------------------------------------------------------------
var pos := Vector2.ZERO
var prev_pos := Vector2.ZERO
var vel := Vector2.ZERO
var facing := Vector2.RIGHT
var move_input := Vector2.ZERO
var hp := 100.0
var max_hp := 100.0
var base_speed := 140.0
var armor := 0.0
var roll_t := 0.0
var roll_cd := 0.0
var roll_buf := 0.0
var roll_dir := Vector2.RIGHT
var jump_t := -1.0
var jump_cd := 0.0
var jump_buf := 0.0
var jump_from := Vector2.ZERO
var jump_to := Vector2.ZERO
var jump_p := 0.0
var prev_jump_p := 0.0
var iframe_t := 0.0
var slowmo_t := 0.0
var riposte := false
var perfect_dodges := 0
var hurt_t := 0.0
var hazard_acc := 0.25
var hazard_now := ""
var ult := 0.0
var ult_buf := 0.0
var skill_cd := [0.0, 0.0]
var skill_buf := [0.0, 0.0]
var cast_pulse := 0       ## Increments whenever the hero casts (drives the cast clip).

# --- Progression ------------------------------------------------------------
var level := 1
var xp := 0.0
var xp_next := 6.0
var kills := 0
var gold_run := 0.0
var echoes_run := 0
var weapons: Array = []   ## [{id, lvl, cd}]
var passives := {}
var pending_levelups := 0
var choices: Array = []
var alive := true
var won := false
var over := false

# --- Director (explicit countdown accumulators only) ------------------------
var spawn_acc := 1.0
var elite_acc := 40.0
var boss_acc := BOSS_TIME

# --- Projectiles (SoA) ------------------------------------------------------
var pr_n := 0
var pr_x := PackedFloat32Array()
var pr_y := PackedFloat32Array()
var pr_ox := PackedFloat32Array()
var pr_oy := PackedFloat32Array()
var pr_vx := PackedFloat32Array()
var pr_vy := PackedFloat32Array()
var pr_life := PackedFloat32Array()
var pr_dmg := PackedFloat32Array()
var pr_r := PackedFloat32Array()
var pr_elem := PackedInt32Array()
var pr_team := PackedInt32Array()
var pr_pierce := PackedInt32Array()
var pr_last := PackedInt32Array()

# --- Gems -------------------------------------------------------------------
var gm_n := 0
var gm_x := PackedFloat32Array()
var gm_y := PackedFloat32Array()
var gm_ox := PackedFloat32Array()
var gm_oy := PackedFloat32Array()
var gm_v := PackedFloat32Array()
var gm_fly := PackedByteArray()

# --- Ground marks (burning pools, etc.) --------------------------------------
var mk_n := 0
var mk_x := PackedFloat32Array()
var mk_y := PackedFloat32Array()
var mk_r := PackedFloat32Array()
var mk_t := PackedFloat32Array()
var mk_t0 := PackedFloat32Array()
var mk_dps := PackedFloat32Array()
var mk_acc := PackedFloat32Array()
var mk_elem := PackedInt32Array()

# --- Pickups (0 heal, 1 magnet, 2 gold) ---------------------------------------
var pk_n := 0
var pk_x := PackedFloat32Array()
var pk_y := PackedFloat32Array()
var pk_kind := PackedInt32Array()

## Per-tick FX/audio events: [type, x, y, dx, dy, extra]. The renderer drains it.
var events: Array = []

var _buf := PackedInt32Array()
var blade_boss_cd := 0.0
var _ap_roll := 1.6
var _ap_jump := 2.5


func _init(act_idx: int, hero: String, seed_v: int = 1, meta_upgrades: Dictionary = {}, run_mode: String = "story") -> void:
	act = act_idx
	hero_id = hero
	mode = run_mode
	meta = meta_upgrades
	rng.seed = seed_v
	terrain = Terrain.new(act_idx)
	layout = terrain.layout
	swarm = Swarm.new()
	_buf.resize(Swarm.CAP)
	pr_x.resize(PROJ_CAP); pr_y.resize(PROJ_CAP); pr_ox.resize(PROJ_CAP); pr_oy.resize(PROJ_CAP)
	pr_vx.resize(PROJ_CAP); pr_vy.resize(PROJ_CAP); pr_life.resize(PROJ_CAP); pr_dmg.resize(PROJ_CAP)
	pr_r.resize(PROJ_CAP); pr_elem.resize(PROJ_CAP); pr_team.resize(PROJ_CAP); pr_pierce.resize(PROJ_CAP)
	pr_last.resize(PROJ_CAP)
	gm_x.resize(GEM_CAP); gm_y.resize(GEM_CAP); gm_ox.resize(GEM_CAP); gm_oy.resize(GEM_CAP)
	gm_v.resize(GEM_CAP); gm_fly.resize(GEM_CAP)
	mk_x.resize(MARK_CAP); mk_y.resize(MARK_CAP); mk_r.resize(MARK_CAP); mk_t.resize(MARK_CAP)
	mk_t0.resize(MARK_CAP); mk_dps.resize(MARK_CAP); mk_acc.resize(MARK_CAP); mk_elem.resize(MARK_CAP)
	pk_x.resize(PICK_CAP); pk_y.resize(PICK_CAP); pk_kind.resize(PICK_CAP)
	var h: Dictionary = Content.hero(hero)
	max_hp = float(h.hp) * (1.0 + 0.08 * float(meta.get("hp", 0)))
	hp = max_hp
	base_speed = float(h.speed)
	armor = float(h.armor)
	weapons.append({"id": String(h.weapon), "lvl": 1, "cd": 0.4})
	if mode == "endless":
		boss_acc = INF


# ============================================================================
# Input (buffered presses; consumed by the fixed step)
# ============================================================================
func set_move(v: Vector2) -> void:
	move_input = v.limit_length(1.0)


func press_roll() -> void:
	roll_buf = INPUT_BUFFER


func press_jump() -> void:
	jump_buf = INPUT_BUFFER


func press_ult() -> void:
	ult_buf = INPUT_BUFFER


func press_skill(i: int) -> void:
	skill_buf[i] = INPUT_BUFFER


# ============================================================================
# Queries
# ============================================================================
func airborne() -> bool:
	return jump_t >= 0.0


func rolling() -> bool:
	return roll_t > 0.0


## 0..1 progress through the current jump (0 when grounded).
func jump_progress() -> float:
	return jump_p


static func jump_lift(jp: float) -> float:
	return 4.0 * jp * (1.0 - jp) * JUMP_LIFT


func speed_mult() -> float:
	var s := 1.0 + 0.07 * float(passives.get("swift", 0))
	if not airborne():
		if hazard_now == "water":
			s *= 0.7
		elif hazard_now == "oil":
			s *= 0.6
	return s


func dmg_mult() -> float:
	return (1.0 + 0.12 * float(passives.get("might", 0))) * (1.0 + 0.06 * float(meta.get("dmg", 0)))


func cd_mult() -> float:
	return maxf(1.0 - 0.08 * float(passives.get("haste", 0)), 0.5)


func hp_mult() -> float:
	return 1.0 + time / 120.0 + float(act) * 0.35


func magnet_r() -> float:
	return 70.0 * (1.0 + 0.35 * float(passives.get("magnet", 0)))


func boss_time_left() -> float:
	return maxf(boss_acc, 0.0)


func emit_event(t: String, p: Vector2, d: Vector2 = Vector2.ZERO, extra: float = 0.0) -> void:
	if events.size() < EVENT_CAP:
		events.append([t, p.x, p.y, d.x, d.y, extra])


# ============================================================================
# Fixed step
# ============================================================================
func step(dt: float) -> void:
	tick += 1
	time += dt
	terrain.time = time
	if over:
		return
	var fdt := dt * (SLOWMO_SCALE if slowmo_t > 0.0 else 1.0)
	_hero(dt)
	_skills(dt)
	_weapons(dt)
	_blades()
	_foes(fdt)
	if boss != null:
		boss.step(fdt, self)
		if boss.dead() and boss.death_t <= 0.0 and not won:
			won = true
			over = true
			echoes_run += 3 + act
			emit_event("victory", boss.pos)
	_projectiles(dt, fdt)
	_marks(dt)
	_gems(dt)
	_pickups()
	_hazards(dt)
	_director(dt)
	_drain_kills()
	if hp <= 0.0 and alive:
		alive = false
		over = true
		emit_event("hero_die", pos)


func _hero(dt: float) -> void:
	prev_pos = pos
	prev_jump_p = jump_p
	roll_buf = maxf(roll_buf - dt, 0.0)
	jump_buf = maxf(jump_buf - dt, 0.0)
	ult_buf = maxf(ult_buf - dt, 0.0)
	roll_cd = maxf(roll_cd - dt, 0.0)
	jump_cd = maxf(jump_cd - dt, 0.0)
	iframe_t = maxf(iframe_t - dt, 0.0)
	slowmo_t = maxf(slowmo_t - dt, 0.0)
	hurt_t = maxf(hurt_t - dt, 0.0)
	var spd := base_speed * speed_mult()
	if airborne():
		jump_t += dt
		jump_p = clampf(jump_t / JUMP_TIME, 0.0, 1.0)
		pos = jump_from.lerp(jump_to, jump_p)
		if jump_t >= JUMP_TIME:
			jump_t = -1.0
			jump_p = 0.0
			pos = jump_to
			_area(pos, 60.0, 10.0 * dmg_mult(), Content.Elem.PHYS, 30.0)
			emit_event("land", pos)
		return
	if rolling():
		roll_t -= dt
		pos = terrain.move(pos, roll_dir * ROLL_SPEED * dt, HERO_R)
		if roll_t <= 0.0:
			roll_t = 0.0
			vel = roll_dir * spd
			if riposte:
				riposte = false
				_area(pos, 140.0, 45.0 * dmg_mult(), Content.Elem.PHYS, 60.0)
				emit_event("riposte", pos, Vector2.ZERO, 140.0)
		return
	var want := move_input
	if roll_buf > 0.0 and roll_cd <= 0.0:
		roll_buf = 0.0
		roll_dir = want.normalized() if want.length_squared() > 0.01 else facing
		facing = roll_dir
		roll_t = ROLL_TIME
		iframe_t = ROLL_TIME
		roll_cd = ROLL_CD
		emit_event("roll", pos, roll_dir)
		return
	if jump_buf > 0.0 and jump_cd <= 0.0:
		jump_buf = 0.0
		var jd := want.normalized() if want.length_squared() > 0.01 else facing
		facing = jd
		jump_from = pos
		jump_to = layout.jump_landing(pos, jd, JUMP_DIST, HERO_R)
		jump_t = 0.0
		jump_p = 0.0
		jump_cd = JUMP_CD
		emit_event("jump", pos, jd)
		return
	var target := want * spd
	# Crisp response: ~0.06 s to full speed, ~0.05 s to stop.
	var rate := spd / ACCEL_T if target.length() >= vel.length() else spd / DECEL_T
	vel = vel.move_toward(target, rate * dt)
	if vel.length_squared() > 0.0001:
		var np := terrain.move(pos, vel * dt, HERO_R)
		pos = np
	if want.length_squared() > 0.01:
		facing = want.normalized()


func hurt_hero(amount: float, src: String) -> void:
	if not alive:
		return
	if src == "contact" and airborne():
		return
	if iframe_t > 0.0:
		if rolling() and roll_t > ROLL_TIME - PERFECT_WINDOW and slowmo_t <= 0.0 and src != "hazard":
			slowmo_t = SLOWMO_T
			riposte = true
			perfect_dodges += 1
			emit_event("perfect", pos)
		if src != "hazard":
			return
	var amt := maxf(amount - armor - 2.0 * float(passives.get("ward", 0)), 1.0)
	hp -= amt
	hurt_t = 0.25
	emit_event("hurt", pos, Vector2.ZERO, amt)


func _hazards(dt: float) -> void:
	hazard_now = "" if airborne() else terrain.hazard_at(pos)
	hazard_acc -= dt
	if hazard_acc > 0.0:
		return
	hazard_acc += 0.25
	match hazard_now:
		"lava":
			hurt_hero(6.0 + armor, "hazard")
		"poison":
			hurt_hero(4.0 + armor, "hazard")
		"spikes":
			hurt_hero(3.5 + armor, "hazard")


# ============================================================================
# Skills & ultimate
# ============================================================================
func _skills(dt: float) -> void:
	for k in 2:
		skill_cd[k] = maxf(float(skill_cd[k]) - dt, 0.0)
		skill_buf[k] = maxf(float(skill_buf[k]) - dt, 0.0)
		if float(skill_buf[k]) > 0.0 and float(skill_cd[k]) <= 0.0 and not airborne():
			skill_buf[k] = 0.0
			skill_cd[k] = SKILL_CD[k]
			cast_pulse += 1
			if k == 0:
				_signature()
			else:
				var tgt := swarm.nearest(pos.x, pos.y, 400.0)
				var at := Vector2(swarm.px[tgt], swarm.py[tgt]) if tgt >= 0 else pos + facing * 120.0
				_area(at, 90.0, 40.0 * dmg_mult(), Content.Elem.CHAOS, 40.0)
				emit_event("bomb", at, Vector2.ZERO, 90.0)
	if ult_buf > 0.0 and ult >= 1.0 and not airborne():
		ult_buf = 0.0
		ult = 0.0
		cast_pulse += 1
		var e: int = Content.hero(hero_id).elem
		_area(pos, 260.0, 70.0 * dmg_mult(), e, 90.0)
		iframe_t = maxf(iframe_t, 0.6)
		emit_event("ult", pos, Vector2.ZERO, 260.0)


func _signature() -> void:
	var h: Dictionary = Content.hero(hero_id)
	match String(h.skill):
		"bulwark":
			_area(pos, 120.0, 30.0 * dmg_mult(), Content.Elem.PHYS, 70.0)
			iframe_t = maxf(iframe_t, 0.8)
			emit_event("nova", pos, Vector2.ZERO, 120.0)
		"blink":
			var d := move_input.normalized() if move_input.length_squared() > 0.01 else facing
			var from := pos
			pos = layout.jump_landing(pos, d, 170.0, HERO_R)
			prev_pos = pos
			_area(from, 80.0, 22.0 * dmg_mult(), Content.Elem.LIGHT, 0.0)
			_area(pos, 80.0, 22.0 * dmg_mult(), Content.Elem.LIGHT, 0.0)
			emit_event("blink", from, pos - from)
		"flamewave":
			var n := swarm.in_radius(pos.x, pos.y, 170.0, _buf)
			for k in n:
				var i := _buf[k]
				var d2 := Vector2(swarm.px[i], swarm.py[i]) - pos
				if absf(facing.angle_to(d2)) < 0.65:
					swarm.damage(i, 26.0 * dmg_mult(), Content.Elem.FIRE)
			emit_event("cone", pos, facing, 170.0)
		"frostring":
			_area(pos, 150.0, 18.0 * dmg_mult(), Content.Elem.COLD, 0.0)
			emit_event("nova", pos, Vector2.ZERO, 150.0)


# ============================================================================
# Weapons
# ============================================================================
func _weapons(dt: float) -> void:
	for w in weapons:
		var base := Content.weapon_base(w.id)
		if base == "blades":
			continue
		w.cd = float(w.cd) - dt
		if float(w.cd) <= 0.0:
			_fire(w)
			var cd_full: float = float(Content.WEAPONS[base].cd) * cd_mult()
			w.cd = maxf(float(w.cd) + cd_full, 0.05)


func focus_bonus() -> int:
	return int(passives.get("focus", 0)) / 2 + (1 if int(passives.get("focus", 0)) >= 4 else 0)


func _aim_dir(max_r: float) -> Vector2:
	var t := swarm.nearest(pos.x, pos.y, max_r)
	if t >= 0:
		var d := Vector2(swarm.px[t], swarm.py[t]) - pos
		if d.length_squared() > 0.01:
			return d.normalized()
	if boss != null and not boss.dead() and boss.pos.distance_to(pos) < max_r:
		return (boss.pos - pos).normalized()
	return facing


func _fire(w: Dictionary) -> void:
	var id: String = w.id
	var base := Content.weapon_base(id)
	var evolved := id != base
	var lvl: int = w.lvl
	var dmg := Content.weapon_damage(id, lvl) * dmg_mult()
	var elem: int = Content.WEAPONS[base].elem
	cast_pulse += 1
	match base:
		"bolt":
			var n := 1 + (1 if lvl >= 3 else 0) + (1 if lvl >= 5 else 0) + focus_bonus()
			var d := _aim_dir(560.0)
			for k in n:
				var a := d.angle() + (float(k) - float(n - 1) * 0.5) * 0.14
				var dir := Vector2(cos(a), sin(a))
				spawn_projectile(pos + dir * 10.0, dir * 520.0, dmg, elem, 0, 99 if evolved else (1 if lvl >= 4 else 0), 1.3, 7.0)
		"nova":
			var r := (90.0 + 12.0 * float(lvl)) * (1.6 if evolved else 1.0)
			_area(pos, r, dmg, elem, 50.0)
			emit_event("nova", pos, Vector2.ZERO, r)
		"chain":
			var jumps := 2 + lvl + (3 if evolved else 0)
			var cur := swarm.nearest(pos.x, pos.y, 380.0)
			var from := pos
			var prev := -1
			for k in jumps:
				if cur < 0:
					break
				var to := Vector2(swarm.px[cur], swarm.py[cur])
				emit_event("chain", from, to - from)
				swarm.damage(cur, dmg, elem)
				prev = cur
				from = to
				cur = swarm.nearest(to.x, to.y, 150.0, prev)
		"ember":
			var t := swarm.nearest(pos.x, pos.y, 440.0)
			var at := Vector2(swarm.px[t], swarm.py[t]) if t >= 0 else pos + facing * 140.0
			add_mark(at, (55.0 + 6.0 * float(lvl)) * (1.5 if evolved else 1.0), 3.0, dmg, elem)
		"frost":
			var n2 := 3 + lvl + focus_bonus() + (3 if evolved else 0)
			var d2 := _aim_dir(480.0)
			for k in n2:
				var a2 := d2.angle() + (float(k) - float(n2 - 1) * 0.5) * 0.2
				var dir2 := Vector2(cos(a2), sin(a2))
				spawn_projectile(pos + dir2 * 10.0, dir2 * 440.0, dmg, elem, 0, 2 if evolved else 0, 0.75, 6.0)


func blade_count() -> int:
	for w in weapons:
		if Content.weapon_base(w.id) == "blades":
			return 2 + int(w.lvl) / 2 + (2 if w.id != "blades" else 0)
	return 0


func blade_radius() -> float:
	for w in weapons:
		if Content.weapon_base(w.id) == "blades":
			return 64.0 + (22.0 if w.id != "blades" else 0.0)
	return 64.0


func blade_pos(k: int, n: int, t: float) -> Vector2:
	var a := t * 3.4 + float(k) / float(maxi(n, 1)) * TAU
	return Vector2(cos(a), sin(a)) * blade_radius()


func _blades() -> void:
	blade_boss_cd = maxf(blade_boss_cd - 1.0 / 60.0, 0.0)
	var n := blade_count()
	if n == 0:
		return
	var w: Dictionary = {}
	for ww in weapons:
		if Content.weapon_base(ww.id) == "blades":
			w = ww
	var dmg := Content.weapon_damage(w.id, int(w.lvl)) * dmg_mult()
	for k in n:
		var bp := pos + blade_pos(k, n, time)
		var c := swarm.grid.query(bp.x, bp.y, 30.0, _buf)
		for m in c:
			var i := _buf[m]
			if swarm.alive[i] == 0 or swarm.blade_cd[i] > 0.0:
				continue
			var dx := swarm.px[i] - bp.x
			var dy := swarm.py[i] - bp.y
			var rr := swarm.radius[i] + 14.0
			if dx * dx + dy * dy < rr * rr:
				swarm.blade_cd[i] = 0.35
				swarm.damage(i, dmg, Content.Elem.PHYS)
		if boss != null and not boss.dead() and bp.distance_to(boss.pos) < Boss.RADIUS + 14.0 and blade_boss_cd <= 0.0:
			blade_boss_cd = 0.18
			_hit_boss(dmg)


func _area(at: Vector2, r: float, dmg: float, elem: int, knock: float) -> void:
	var n := swarm.in_radius(at.x, at.y, r, _buf)
	for k in n:
		var i := _buf[k]
		if knock > 0.0 and swarm.kind[i] != Swarm.Kind.BRUTE:
			var d := Vector2(swarm.px[i], swarm.py[i]) - at
			if d.length_squared() > 0.01:
				var p := terrain.foe_move(Vector2(swarm.px[i], swarm.py[i]), d.normalized() * knock * 0.4, swarm.radius[i])
				swarm.px[i] = p.x
				swarm.py[i] = p.y
		swarm.damage(i, dmg, elem)
	if boss != null and not boss.dead() and boss.pos.distance_to(at) < r + Boss.RADIUS:
		_hit_boss(dmg)


func _hit_boss(dmg: float) -> void:
	if boss.damage(dmg):
		emit_event("boss_die", boss.pos)
	ult = minf(ult + 0.002, 1.0)


func spawn_projectile(p: Vector2, v: Vector2, dmg: float, elem: int, team: int, pierce: int, life: float, r: float) -> void:
	if pr_n >= PROJ_CAP:
		return
	var i := pr_n
	pr_n += 1
	pr_x[i] = p.x; pr_y[i] = p.y; pr_ox[i] = p.x; pr_oy[i] = p.y
	pr_vx[i] = v.x; pr_vy[i] = v.y
	pr_life[i] = life
	pr_dmg[i] = dmg
	pr_r[i] = r
	pr_elem[i] = elem
	pr_team[i] = team
	pr_pierce[i] = pierce
	pr_last[i] = -1


func _proj_remove(i: int) -> void:
	pr_n -= 1
	if i == pr_n:
		return
	pr_x[i] = pr_x[pr_n]; pr_y[i] = pr_y[pr_n]; pr_ox[i] = pr_ox[pr_n]; pr_oy[i] = pr_oy[pr_n]
	pr_vx[i] = pr_vx[pr_n]; pr_vy[i] = pr_vy[pr_n]; pr_life[i] = pr_life[pr_n]
	pr_dmg[i] = pr_dmg[pr_n]; pr_r[i] = pr_r[pr_n]; pr_elem[i] = pr_elem[pr_n]
	pr_team[i] = pr_team[pr_n]; pr_pierce[i] = pr_pierce[pr_n]; pr_last[i] = pr_last[pr_n]


func _projectiles(dt: float, fdt: float) -> void:
	var i := 0
	while i < pr_n:
		var pdt := dt if pr_team[i] == 0 else fdt
		pr_ox[i] = pr_x[i]
		pr_oy[i] = pr_y[i]
		pr_x[i] += pr_vx[i] * pdt
		pr_y[i] += pr_vy[i] * pdt
		pr_life[i] -= pdt
		var dead := pr_life[i] <= 0.0
		if not dead and pr_team[i] == 0:
			var n := swarm.grid.query(pr_x[i], pr_y[i], pr_r[i] + 20.0, _buf)
			for k in n:
				var j := _buf[k]
				if swarm.alive[j] == 0 or j == pr_last[i]:
					continue
				var dx := swarm.px[j] - pr_x[i]
				var dy := swarm.py[j] - pr_y[i]
				var rr := swarm.radius[j] + pr_r[i]
				if dx * dx + dy * dy < rr * rr:
					swarm.damage(j, pr_dmg[i], pr_elem[i])
					emit_event("hit", Vector2(pr_x[i], pr_y[i]), Vector2(pr_vx[i], pr_vy[i]).normalized(), float(pr_elem[i]))
					pr_last[i] = j
					pr_pierce[i] -= 1
					if pr_pierce[i] < 0:
						dead = true
						break
			if not dead and boss != null and not boss.dead():
				if Vector2(pr_x[i], pr_y[i]).distance_to(boss.pos) < Boss.RADIUS + pr_r[i]:
					_hit_boss(pr_dmg[i])
					emit_event("hit", Vector2(pr_x[i], pr_y[i]), Vector2.ZERO, float(pr_elem[i]))
					dead = true
		elif not dead:
			var dh := Vector2(pr_x[i], pr_y[i]).distance_to(pos)
			if dh < HERO_R + pr_r[i]:
				hurt_hero(pr_dmg[i], "projectile")
				dead = iframe_t <= 0.0 or not rolling()
		if dead:
			_proj_remove(i)
		else:
			i += 1


func add_mark(at: Vector2, r: float, life: float, dps: float, elem: int) -> void:
	var i := mk_n
	if mk_n >= MARK_CAP:
		# Replace the oldest-ending mark (deterministic: smallest remaining time).
		i = 0
		for k in MARK_CAP:
			if mk_t[k] < mk_t[i]:
				i = k
	else:
		mk_n += 1
	mk_x[i] = at.x; mk_y[i] = at.y; mk_r[i] = r; mk_t[i] = life; mk_t0[i] = life
	mk_dps[i] = dps; mk_acc[i] = 0.0; mk_elem[i] = elem
	emit_event("mark", at, Vector2.ZERO, r)


func _marks(dt: float) -> void:
	var i := 0
	while i < mk_n:
		mk_t[i] -= dt
		mk_acc[i] -= dt
		if mk_acc[i] <= 0.0:
			mk_acc[i] += 0.25
			_area(Vector2(mk_x[i], mk_y[i]), mk_r[i], mk_dps[i] * 0.25, mk_elem[i], 0.0)
		if mk_t[i] <= 0.0:
			mk_n -= 1
			mk_x[i] = mk_x[mk_n]; mk_y[i] = mk_y[mk_n]; mk_r[i] = mk_r[mk_n]; mk_t[i] = mk_t[mk_n]
			mk_t0[i] = mk_t0[mk_n]; mk_dps[i] = mk_dps[mk_n]; mk_acc[i] = mk_acc[mk_n]; mk_elem[i] = mk_elem[mk_n]
		else:
			i += 1


# ============================================================================
# Foes
# ============================================================================
func _foes(fdt: float) -> void:
	swarm.rebuild_grid()
	swarm.separate(tick)
	var hx := pos.x
	var hy := pos.y
	for i in swarm.count:
		if swarm.alive[i] == 0:
			swarm.ox[i] = swarm.px[i]
			swarm.oy[i] = swarm.py[i]
			continue
		var x := swarm.px[i]
		var y := swarm.py[i]
		swarm.ox[i] = x
		swarm.oy[i] = y
		if swarm.spawn_t[i] > 0.0:
			continue
		var dx := hx - x
		var dy := hy - y
		var dist := sqrt(dx * dx + dy * dy)
		var nx := dx / dist if dist > 0.01 else 0.0
		var ny := dy / dist if dist > 0.01 else 0.0
		var sp := swarm.speed[i] * swarm.slow_factor(i)
		var wx := nx * sp
		var wy := ny * sp
		swarm.atk_t[i] -= fdt
		match swarm.kind[i]:
			Swarm.Kind.SPITTER:
				if dist < 180.0:
					wx = -wx * 0.6
					wy = -wy * 0.6
				elif dist < 240.0:
					wx = 0.0
					wy = 0.0
				if swarm.atk_t[i] <= 0.0 and dist < 380.0:
					swarm.atk_t[i] += 2.4
					spawn_projectile(Vector2(x, y), Vector2(nx, ny) * 210.0, swarm.dmg[i], Content.Elem.CHAOS, 1, 0, 2.4, 6.0)
					emit_event("spit", Vector2(x, y), Vector2(nx, ny))
				elif swarm.atk_t[i] <= 0.0:
					swarm.atk_t[i] = 0.0
			Swarm.Kind.CHARGER:
				match swarm.state[i]:
					0:
						if dist < 260.0 and swarm.atk_t[i] <= 0.0:
							swarm.state[i] = 1
							swarm.state_t[i] = 0.6
							swarm.lock_x[i] = nx
							swarm.lock_y[i] = ny
						elif swarm.atk_t[i] <= 0.0:
							swarm.atk_t[i] = 0.0
					1:
						wx = 0.0
						wy = 0.0
						swarm.state_t[i] -= fdt
						if swarm.state_t[i] <= 0.0:
							swarm.state[i] = 2
							swarm.state_t[i] = 0.45
					2:
						wx = swarm.lock_x[i] * sp * 3.2
						wy = swarm.lock_y[i] * sp * 3.2
						swarm.state_t[i] -= fdt
						if swarm.state_t[i] <= 0.0:
							swarm.state[i] = 0
							swarm.atk_t[i] = 3.0
		swarm.vx[i] = wx
		swarm.vy[i] = wy
		var delta := Vector2((wx * fdt) + swarm.sep_x[i], (wy * fdt) + swarm.sep_y[i])
		if delta.length_squared() > 0.000001:
			var np := terrain.foe_move(Vector2(x, y), delta, swarm.radius[i])
			swarm.px[i] = np.x
			swarm.py[i] = np.y
		swarm.anim[i] += fdt * (sp / 60.0)
		# Contact damage.
		var rr := swarm.radius[i] + HERO_R
		if dist < rr + 2.0 and swarm.atk_t[i] <= 0.0 and swarm.kind[i] != Swarm.Kind.SPITTER:
			hurt_hero(swarm.dmg[i], "contact")
			swarm.atk_t[i] = 0.8
	swarm.tick_status(fdt)


func _drain_kills() -> void:
	for k in swarm.killed_n:
		var i := swarm.killed[k]
		kills += 1
		ult = minf(ult + 0.012, 1.0)
		gold_run += 0.25 * (1.0 + 0.1 * float(meta.get("gold", 0)))
		var fd: Dictionary = Content.FOES[Content.FOE_ORDER[swarm.kind[i]]]
		var v := float(fd.xp) * (5.0 if swarm.elite[i] == 1 else 1.0)
		_drop_gem(Vector2(swarm.px[i], swarm.py[i]), v)
		if swarm.elite[i] == 1 and pk_n < PICK_CAP:
			pk_x[pk_n] = swarm.px[i]
			pk_y[pk_n] = swarm.py[i]
			pk_kind[pk_n] = (kills % 3)
			pk_n += 1
		emit_event("die", Vector2(swarm.px[i], swarm.py[i]), Vector2.ZERO, float(swarm.kind[i]))
	swarm.killed_n = 0
	for r in swarm.reactions:
		emit_event("react", Vector2(r[1], r[2]), Vector2.ZERO, 0.0)
	swarm.reactions.clear()


func _drop_gem(p: Vector2, v: float) -> void:
	if gm_n >= GEM_CAP:
		gm_v[kills % GEM_CAP] += v
		return
	gm_x[gm_n] = p.x; gm_y[gm_n] = p.y; gm_ox[gm_n] = p.x; gm_oy[gm_n] = p.y
	gm_v[gm_n] = v
	gm_fly[gm_n] = 0
	gm_n += 1


func _gems(dt: float) -> void:
	var mr := magnet_r()
	var i := 0
	while i < gm_n:
		gm_ox[i] = gm_x[i]
		gm_oy[i] = gm_y[i]
		var dx := pos.x - gm_x[i]
		var dy := pos.y - gm_y[i]
		var d2 := dx * dx + dy * dy
		if gm_fly[i] == 0 and d2 < mr * mr:
			gm_fly[i] = 1
		if gm_fly[i] == 1:
			var d := sqrt(d2)
			if d < 16.0:
				_gain_xp(gm_v[i])
				emit_event("xp", pos, Vector2.ZERO, gm_v[i])
				gm_n -= 1
				gm_x[i] = gm_x[gm_n]; gm_y[i] = gm_y[gm_n]; gm_ox[i] = gm_ox[gm_n]; gm_oy[i] = gm_oy[gm_n]
				gm_v[i] = gm_v[gm_n]; gm_fly[i] = gm_fly[gm_n]
				continue
			var s := minf(460.0 * dt, d)
			gm_x[i] += dx / d * s
			gm_y[i] += dy / d * s
		i += 1


func _pickups() -> void:
	var i := 0
	while i < pk_n:
		if Vector2(pk_x[i], pk_y[i]).distance_to(pos) < 26.0:
			match pk_kind[i]:
				0:
					hp = minf(hp + max_hp * 0.3, max_hp)
				1:
					for g in gm_n:
						gm_fly[g] = 1
				2:
					gold_run += 25.0
			emit_event("pickup", pos, Vector2.ZERO, float(pk_kind[i]))
			pk_n -= 1
			pk_x[i] = pk_x[pk_n]; pk_y[i] = pk_y[pk_n]; pk_kind[i] = pk_kind[pk_n]
		else:
			i += 1


func _gain_xp(v: float) -> void:
	xp += v * (1.0 + 0.08 * float(meta.get("xp", 0)))
	while xp >= xp_next:
		xp -= xp_next
		level += 1
		xp_next = 6.0 + float(level - 1) * 5.0 + pow(float(level), 1.35)
		pending_levelups += 1
		emit_event("levelup", pos)
	if pending_levelups > 0 and choices.is_empty():
		roll_choices()


# ============================================================================
# Level-up choices
# ============================================================================
func roll_choices() -> void:
	choices.clear()
	var pool := []
	var forced := []
	for w in weapons:
		var base := Content.weapon_base(w.id)
		if w.id != base:
			continue
		if int(w.lvl) < Content.MAX_WEAPON_LVL:
			pool.append({"type": "weapon", "id": w.id})
		elif passives.has(Content.WEAPONS[base].evolve_with):
			forced.append({"type": "evolve", "id": w.id})
	if weapons.size() < Content.MAX_WEAPONS:
		for id in Content.WEAPONS:
			var owned := false
			for w in weapons:
				if Content.weapon_base(w.id) == id:
					owned = true
			if not owned:
				pool.append({"type": "new", "id": id})
	for p in Content.PASSIVES:
		if int(passives.get(p, 0)) < int(Content.PASSIVES[p].max):
			pool.append({"type": "passive", "id": p})
	# Deterministic Fisher-Yates with the run RNG.
	for k in range(pool.size() - 1, 0, -1):
		var j := rng.randi_range(0, k)
		var tmp = pool[k]
		pool[k] = pool[j]
		pool[j] = tmp
	choices = forced.slice(0, 1)
	for c in pool:
		if choices.size() >= 3:
			break
		choices.append(c)
	if choices.is_empty():
		choices.append({"type": "heal", "id": "heal"})


func choice_label(c: Dictionary) -> String:
	match String(c.type):
		"weapon":
			for w in weapons:
				if w.id == c.id:
					return "%s  Lv %d" % [Content.weapon_name(c.id), int(w.lvl) + 1]
		"new":
			return "NEW  %s" % Content.weapon_name(c.id)
		"evolve":
			return "EVOLVE  %s" % Content.EVOLUTIONS[Content.WEAPONS[c.id].evolves_to].name
		"passive":
			return "%s  %d/%d" % [Content.PASSIVES[c.id].name, int(passives.get(c.id, 0)) + 1, int(Content.PASSIVES[c.id].max)]
		"heal":
			return "Restore 40% HP"
	return "?"


func choice_desc(c: Dictionary) -> String:
	match String(c.type):
		"weapon", "new":
			return String(Content.WEAPONS[c.id].desc)
		"evolve":
			return "Max-level %s fused with %s." % [Content.weapon_name(c.id), Content.PASSIVES[Content.WEAPONS[c.id].evolve_with].name]
		"passive":
			return String(Content.PASSIVES[c.id].desc)
	return "Catch your breath."


func choose(idx: int) -> void:
	if choices.is_empty():
		return
	var c: Dictionary = choices[clampi(idx, 0, choices.size() - 1)]
	match String(c.type):
		"weapon":
			for w in weapons:
				if w.id == c.id:
					w.lvl = int(w.lvl) + 1
		"new":
			weapons.append({"id": c.id, "lvl": 1, "cd": 0.3})
		"evolve":
			for w in weapons:
				if w.id == c.id:
					w.id = String(Content.WEAPONS[c.id].evolves_to)
					w.lvl = Content.MAX_WEAPON_LVL
		"passive":
			passives[c.id] = int(passives.get(c.id, 0)) + 1
			if c.id == "vigor":
				max_hp += 20.0
				hp = minf(hp + 20.0, max_hp)
		"heal":
			hp = minf(hp + max_hp * 0.4, max_hp)
	pending_levelups -= 1
	choices.clear()
	if pending_levelups > 0:
		roll_choices()


# ============================================================================
# Director
# ============================================================================
func _director(dt: float) -> void:
	spawn_acc -= dt
	if spawn_acc <= 0.0:
		spawn_acc += maxf(0.28, 1.5 - time * 0.005)
		var batch := 3 + int(time / 25.0)
		for b in batch:
			if swarm.alive_n >= 600:
				break
			_spawn_ring(_pick_kind(), false)
	elite_acc -= dt
	if elite_acc <= 0.0:
		elite_acc += 40.0
		_spawn_ring(_pick_kind(), true)
	if boss == null:
		boss_acc -= dt
		if boss_acc <= 0.0:
			_spawn_boss()


func _pick_kind() -> int:
	var mix: Array = Content.act(act).foe_mix
	var gates := [0.0, 20.0, 45.0, 60.0, 90.0]
	var total := 0
	for k in Swarm.KINDS:
		if time >= gates[k]:
			total += int(mix[k])
	var r := rng.randi_range(0, maxi(total - 1, 0))
	for k in Swarm.KINDS:
		if time < gates[k]:
			continue
		r -= int(mix[k])
		if r < 0:
			return k
	return Swarm.Kind.GRUNT


func _spawn_ring(k: int, elite: bool) -> void:
	for attempt in 4:
		var a := rng.randf() * TAU
		var d := rng.randf_range(560.0, 680.0)
		var p := pos + Vector2(cos(a), sin(a)) * d
		if not terrain.passable(p):
			continue
		p = layout.slide_out(p, 14.0, true)
		if not terrain.passable(p):
			continue
		swarm.spawn(k, p.x, p.y, elite, hp_mult())
		return


func _spawn_boss() -> void:
	var at := pos + facing * 420.0
	for attempt in 12:
		if terrain.passable(at) and not layout.inside_any_solid(at, Boss.RADIUS):
			break
		var a := float(attempt) * 0.9
		at = pos + Vector2(cos(a), sin(a)) * 420.0
	boss = Boss.new(String(Content.act(act).boss), at, act)
	boss.maxhp *= 1.0 + 0.1 * float(level)
	boss.hp = boss.maxhp
	emit_event("boss_spawn", at)


## Deterministic scripted input used by headless gate scenes.
func autopilot(t: float, dt: float) -> void:
	set_move(Vector2(cos(t * 0.7), sin(t * 0.9)))
	_ap_roll -= dt
	if _ap_roll <= 0.0:
		_ap_roll += 1.6
		press_roll()
	_ap_jump -= dt
	if _ap_jump <= 0.0:
		_ap_jump += 2.5
		press_jump()
	if not choices.is_empty():
		choose(0)
