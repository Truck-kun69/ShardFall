class_name Hud
extends Control
## In-run HUD inside the display safe area. Redraws are throttled to 18 Hz
## (never an unconditional per-frame queue_redraw()).

const REDRAW_HZ := 18.0
const PAD := 16.0

var world: SimWorld
var show_fps := false
var redraws := 0
var _acc := 0.0
var _safe := Rect2()
var touch: TouchControls


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_on_resized)
	_on_resized()


func _on_resized() -> void:
	_safe = TouchControls.safe_rect_for(size)
	queue_redraw()


func bind(w: SimWorld) -> void:
	world = w
	_acc = 0.0
	_on_resized()


func _process(dt: float) -> void:
	if world == null or not visible:
		return
	_acc -= dt
	if _acc <= 0.0:
		_acc += 1.0 / REDRAW_HZ
		if _acc < 0.0:
			_acc = 0.0
		redraws += 1
		queue_redraw()


func _bar(r: Rect2, frac: float, col: Color, bg: Color = Color(0.05, 0.06, 0.1, 0.72)) -> void:
	draw_rect(r, bg)
	draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(frac, 0.0, 1.0), r.size.y)), col)
	draw_rect(r, Color(0.2, 0.23, 0.35, 0.9), false, 2.0)


func _text(p: Vector2, s: String, fs: int, col: Color = Color(0.93, 0.91, 0.86), align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	var font := get_theme_default_font()
	draw_string_outline(font, p, s, align, w, fs, 4, Color(0.02, 0.02, 0.04, 0.9))
	draw_string(font, p, s, align, w, fs, col)


func _draw() -> void:
	if world == null:
		return
	if not _safe.has_area():
		_on_resized()
	var w := world
	var s := clampf(minf(size.x, size.y) / 720.0, 0.75, 1.6)
	var o := _safe.position + Vector2(PAD, PAD)
	var full_w := _safe.size.x - PAD * 2.0
	# XP bar across the top.
	_bar(Rect2(o, Vector2(full_w, 8.0 * s)), w.xp / maxf(w.xp_next, 1.0), Color(0.32, 0.80, 0.96))
	# HP bar + level.
	var hp_r := Rect2(o + Vector2(0, 16.0 * s), Vector2(minf(320.0 * s, full_w * 0.4), 18.0 * s))
	_bar(hp_r, w.hp / maxf(w.max_hp, 1.0), Color(0.93, 0.35, 0.37))
	_text(hp_r.position + Vector2(8, hp_r.size.y - 3.0 * s), "%d / %d" % [ceili(maxf(w.hp, 0.0)), int(w.max_hp)], int(15 * s))
	_text(hp_r.position + Vector2(0, hp_r.size.y + 24.0 * s), "LV %d" % w.level, int(22 * s), Color(0.96, 0.75, 0.31))
	_text(hp_r.position + Vector2(70.0 * s, hp_r.size.y + 24.0 * s), "%d kills" % w.kills, int(18 * s), Color(0.6, 0.63, 0.72))
	# Timer (and boss countdown) centred.
	var mm := int(w.time) / 60
	var ss := int(w.time) % 60
	var cx := _safe.position.x + _safe.size.x * 0.5
	_text(Vector2(cx - 100.0 * s, o.y + 44.0 * s), "%02d:%02d" % [mm, ss], int(28 * s), Color(0.93, 0.91, 0.86), HORIZONTAL_ALIGNMENT_CENTER, 200.0 * s)
	if w.boss == null and w.mode == "story":
		var left := int(ceil(w.boss_time_left()))
		_text(Vector2(cx - 150.0 * s, o.y + 66.0 * s), "Boss in %d:%02d" % [left / 60, left % 60], int(16 * s), Color(0.6, 0.63, 0.72), HORIZONTAL_ALIGNMENT_CENTER, 300.0 * s)
	# Boss bar.
	if w.boss != null and not w.boss.dead():
		var bw := minf(560.0 * s, full_w * 0.6)
		var br := Rect2(Vector2(cx - bw * 0.5, o.y + 78.0 * s), Vector2(bw, 14.0 * s))
		_bar(br, w.boss.hp / w.boss.maxhp, Color(0.95, 0.45, 0.2) if not w.boss.exposed() else Color(1.0, 0.85, 0.3))
		_text(Vector2(br.position.x, br.position.y - 4.0 * s), w.boss.name + ("   EXPOSED" if w.boss.exposed() else ""), int(16 * s), Color(0.96, 0.75, 0.31))
	# Ult meter (right side, under the pause button).
	var ur := Rect2(Vector2(_safe.end.x - PAD - 180.0 * s, o.y + 70.0 * s), Vector2(180.0 * s, 10.0 * s))
	_bar(ur, w.ult, Color(0.96, 0.75, 0.31) if w.ult >= 1.0 else Color(0.7, 0.56, 0.25))
	_text(ur.position + Vector2(0, -4.0 * s), "ULT" + ("  READY" if w.ult >= 1.0 else ""), int(14 * s), Color(0.96, 0.75, 0.31))
	if w.slowmo_t > 0.0:
		_text(Vector2(cx - 150.0 * s, _safe.position.y + _safe.size.y * 0.3), "PERFECT DODGE", int(30 * s), Color(0.5, 0.9, 1.0), HORIZONTAL_ALIGNMENT_CENTER, 300.0 * s)
	if show_fps:
		_text(Vector2(o.x, _safe.end.y - PAD), "%d fps  %s  x%.2f  foes %d" % [Engine.get_frames_per_second(), Quality.TIER_NAMES[Quality.tier], Quality.dyn_scale, w.swarm.alive_n], int(14 * s), Color(0.6, 0.63, 0.72))
