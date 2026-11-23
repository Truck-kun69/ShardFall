class_name Boss
extends RefCounted
## Boss state machine: CHASE -> WINDUP -> EXECUTE -> RECOVER.
## Every attack is telegraphed during WINDUP; RECOVER is an exposed punish
## window where the boss takes bonus damage.

enum St { CHASE, WINDUP, EXECUTE, RECOVER, DEAD }
const ATTACKS := ["cleave", "volley", "slam", "summon"]
const WINDUP_T := {"cleave": 0.9, "volley": 0.8, "slam": 1.1, "summon": 0.7}
const EXECUTE_T := 0.25
const RECOVER_T := 1.4
const EXPOSED_MULT := 1.5
const CLEAVE_R := 170.0
const CLEAVE_ARC := 1.92   # radians (~110 degrees)
const SLAM_R := 130.0
const RADIUS := 34.0
const DEATH_T := 2.4

var id := ""
var name := ""
var elem := 0
var pos := Vector2.ZERO
var prev_pos := Vector2.ZERO
var facing := Vector2.LEFT
var hp := 1.0
var maxhp := 1.0
var speed := 60.0
var state := St.CHASE
var t := 0.0
var cd := 2.5
var attack := ""
var attack_i := 0
var target := Vector2.ZERO
var flinch_t := 0.0
var flash := 0.0
var death_t := 0.0
var attacks_done := 0   ## Increments per EXECUTE (render alternates clips on it).


func _init(boss_id: String, at: Vector2, act_idx: int) -> void:
	var d: Dictionary = Content.BOSSES[boss_id]
	id = boss_id
	name = String(d.name)
	elem = int(d.elem)
	speed = float(d.speed)
	maxhp = float(d.hp)
	hp = maxhp
	pos = at
	prev_pos = at
	attack_i = act_idx


func exposed() -> bool:
	return state == St.RECOVER


func busy() -> bool:
	return state == St.WINDUP or state == St.EXECUTE or state == St.RECOVER


func dead() -> bool:
	return state == St.DEAD


## Returns true when this hit killed the boss.
func damage(amount: float) -> bool:
	if state == St.DEAD:
		return false
	var amt := amount * (EXPOSED_MULT if exposed() else 1.0)
	hp -= amt
	flash = 0.1
	if amt > maxhp * 0.04:
		flinch_t = 0.18
	if hp <= 0.0:
		hp = 0.0
		state = St.DEAD
		death_t = DEATH_T
		return true
	return false


## Telegraph for rendering: {shape, pos, dir, radius, arc, progress} or {}.
func telegraph() -> Dictionary:
	if state != St.WINDUP:
		return {}
	var total: float = WINDUP_T[attack]
	var prog := clampf(1.0 - t / total, 0.0, 1.0)
	match attack:
		"cleave":
			return {"shape": "cone", "pos": pos, "dir": facing, "radius": CLEAVE_R, "arc": CLEAVE_ARC, "progress": prog}
		"slam":
			return {"shape": "circle", "pos": target, "dir": facing, "radius": SLAM_R, "arc": TAU, "progress": prog}
		"volley":
			return {"shape": "lane", "pos": pos, "dir": facing, "radius": 320.0, "arc": 1.2, "progress": prog}
		"summon":
			return {"shape": "circle", "pos": pos, "dir": facing, "radius": 90.0, "arc": TAU, "progress": prog}
	return {}


## Advances the state machine. `w` is the SimWorld (for spawning and damage).
func step(dt: float, w: SimWorld) -> void:
	prev_pos = pos
	flash = maxf(flash - dt, 0.0)
	flinch_t = maxf(flinch_t - dt, 0.0)
	if state == St.DEAD:
		death_t = maxf(death_t - dt, 0.0)
		return
	var to_hero := w.pos - pos
	var dist := to_hero.length()
	match state:
		St.CHASE:
			if dist > 1.0:
				facing = facing.lerp(to_hero / dist, clampf(dt * 6.0, 0.0, 1.0)).normalized()
			if dist > 70.0 and flinch_t <= 0.0:
				# Bosses surge when kited so the fight always comes to the hero.
				var surge := 1.0 + clampf((dist - 300.0) / 200.0, 0.0, 1.8)
				pos = w.terrain.foe_move(pos, facing * speed * surge * dt, RADIUS)
			cd -= dt
			if cd <= 0.0 and dist < 520.0:
				attack = ATTACKS[attack_i % ATTACKS.size()]
				attack_i += 1
				state = St.WINDUP
				t = WINDUP_T[attack]
				target = w.pos
		St.WINDUP:
			if attack == "cleave" and dist > 1.0:
				# Slow tracking during windup: dodgeable by circling.
				facing = facing.lerp(to_hero / dist, clampf(dt * 1.5, 0.0, 1.0)).normalized()
			t -= dt
			if t <= 0.0:
				state = St.EXECUTE
				t = EXECUTE_T
				attacks_done += 1
				_execute(w)
		St.EXECUTE:
			t -= dt
			if t <= 0.0:
				state = St.RECOVER
				t = RECOVER_T
		St.RECOVER:
			t -= dt
			if t <= 0.0:
				state = St.CHASE
				cd = 1.6 + float(attack_i % 3) * 0.4


func _execute(w: SimWorld) -> void:
	match attack:
		"cleave":
			var d := w.pos - pos
			if d.length() < CLEAVE_R + SimWorld.HERO_R and absf(facing.angle_to(d)) < CLEAVE_ARC * 0.5:
				w.hurt_hero(26.0, "boss")
			w.emit_event("boss_cleave", pos, facing)
		"slam":
			if w.pos.distance_to(target) < SLAM_R + SimWorld.HERO_R and not w.airborne():
				w.hurt_hero(32.0, "boss")
			w.emit_event("boss_slam", target, facing)
		"volley":
			for k in 7:
				var a := facing.angle() + (float(k) - 3.0) * 0.17
				var dir := Vector2(cos(a), sin(a))
				w.spawn_projectile(pos + dir * RADIUS, dir * 260.0, 12.0, elem, 1, 0, 3.0, 9.0)
			w.emit_event("boss_volley", pos, facing)
		"summon":
			for k in 6:
				var a2 := float(k) / 6.0 * TAU
				var p := pos + Vector2(cos(a2), sin(a2)) * 80.0
				if w.terrain.passable(p):
					w.swarm.spawn(Swarm.Kind.RUNNER if k % 2 == 0 else Swarm.Kind.GRUNT, p.x, p.y, false, w.hp_mult())
			w.emit_event("boss_summon", pos, facing)
