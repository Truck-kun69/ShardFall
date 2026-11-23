class_name TouchControls
extends Control
## Mobile thumb controls. Left half: floating (or fixed) joystick with radius R
## scaled by `sc`. Right thumb: ROLL, JUMP, ULT, 1, 2 arranged around the corner
## inside DisplayServer.get_display_safe_area() with >= 12 px outer-ring
## clearance. Layout is cached and only recomputed on resize/option change.

signal action_pressed(action: String)

const BUTTONS := ["ROLL", "JUMP", "ULT", "1", "2"]
const BASE_R := {"ROLL": 60.0, "JUMP": 50.0, "ULT": 46.0, "1": 40.0, "2": 40.0}
const RING := 5.0          ## Outer ring stroke beyond the button radius.
const CLEARANCE := 12.0    ## Minimum gap: ring edge to safe-area edge and to other rings.
const BASE_JOY_R := 72.0
const DEADZONE := 0.12

var sc := 1.0
var ui_scale := 1.0
var joystick_mode := "floating"
var R := BASE_JOY_R
var move := Vector2.ZERO
var cooldown := {"ROLL": 0.0, "JUMP": 0.0, "ULT": 1.0, "1": 0.0, "2": 0.0}
var safe_override := Rect2()   ## Tests can inject a safe area.

var btn_center := {}
var btn_r := {}
var joy_fixed := Vector2.ZERO
var layouts := 0               ## Number of _relayout() runs (cache check).

var _safe := Rect2()
var _joy_touch := -1
var _joy_center := Vector2.ZERO
var _joy_knob := Vector2.ZERO
var _btn_touch := {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_safe = Rect2(Vector2.ZERO, Vector2(1280, 720))
	_layout_with(1.0)
	resized.connect(_relayout)
	_relayout.call_deferred()


func set_options(mode: String, scale_v: float) -> void:
	joystick_mode = mode
	ui_scale = scale_v
	_relayout()


## Display safe area converted to this control's coordinate space.
func safe_rect() -> Rect2:
	if safe_override.has_area():
		return safe_override.intersection(Rect2(Vector2.ZERO, size))
	return safe_rect_for(size)


## Display safe area mapped into a canvas of `canvas_size` (stretch-aware).
static func safe_rect_for(canvas_size: Vector2) -> Rect2:
	var size := canvas_size
	var full := Rect2(Vector2.ZERO, size)
	var sa := DisplayServer.get_display_safe_area()
	var win := Vector2(DisplayServer.window_get_size())
	if sa.size.x <= 0 or sa.size.y <= 0 or win.x <= 0.0 or win.y <= 0.0:
		return full
	var k := size / win
	var r := Rect2(Vector2(sa.position) * k, Vector2(sa.size) * k)
	var clipped := r.intersection(full)
	return clipped if clipped.has_area() else full


func _relayout() -> void:
	layouts += 1
	_safe = safe_rect()
	var s := ui_scale * clampf(minf(size.x, size.y) / 720.0, 0.7, 1.6)
	for attempt in 16:
		_layout_with(s)
		if layout_valid():
			break
		s *= 0.92
	sc = s
	queue_redraw()


func _layout_with(s: float) -> void:
	R = BASE_JOY_R * s
	for b in BUTTONS:
		btn_r[b] = float(BASE_R[b]) * s
	var corner := _safe.end
	var rr: float = btn_r["ROLL"]
	var roll_c := corner - Vector2.ONE * (CLEARANCE + RING + rr + 6.0 * s)
	btn_center["ROLL"] = roll_c
	# Remaining buttons on a quarter arc from "left" (180 deg) to "up" (270 deg),
	# evenly spaced; the radius grows until neighbouring rings keep CLEARANCE.
	var order := ["JUMP", "1", "2", "ULT"]
	var step := (PI * 0.5) / float(order.size() - 1)
	var dist := rr + RING * 2.0 + CLEARANCE + float(btn_r.JUMP) + 4.0 * s
	for i in range(1, order.size()):
		var need := float(btn_r[order[i - 1]]) + float(btn_r[order[i]]) + RING * 2.0 + CLEARANCE + 4.0 * s
		dist = maxf(dist, need / (2.0 * sin(step * 0.5)))
	for i in order.size():
		var ang := PI + step * float(i)
		btn_center[order[i]] = roll_c + Vector2(cos(ang), sin(ang)) * dist
	joy_fixed = Vector2(_safe.position.x + CLEARANCE + RING + R + 40.0 * s, _safe.end.y - (CLEARANCE + RING + R + 40.0 * s))


## Every button ring sits >= CLEARANCE inside the safe area and >= CLEARANCE
## away from every other ring.
func layout_valid() -> bool:
	var inner := _safe.grow(-CLEARANCE)
	for b in BUTTONS:
		var c: Vector2 = btn_center[b]
		var r: float = float(btn_r[b]) + RING
		if c.x - r < inner.position.x or c.y - r < inner.position.y or c.x + r > inner.end.x or c.y + r > inner.end.y:
			return false
	for i in BUTTONS.size():
		for j in range(i + 1, BUTTONS.size()):
			var a: String = BUTTONS[i]
			var b2: String = BUTTONS[j]
			var d := (btn_center[a] as Vector2).distance_to(btn_center[b2])
			if d < float(btn_r[a]) + float(btn_r[b2]) + RING * 2.0 + CLEARANCE:
				return false
	return true


func min_clearance() -> float:
	var best := INF
	for b in BUTTONS:
		var c: Vector2 = btn_center[b]
		var r: float = float(btn_r[b]) + RING
		best = minf(best, minf(minf(c.x - r - _safe.position.x, c.y - r - _safe.position.y), minf(_safe.end.x - c.x - r, _safe.end.y - c.y - r)))
	return best


func reset() -> void:
	move = Vector2.ZERO
	_joy_touch = -1
	_btn_touch.clear()
	queue_redraw()


func _hit_button(p: Vector2) -> String:
	for b in BUTTONS:
		if p.distance_to(btn_center[b]) <= float(btn_r[b]) + RING + 8.0:
			return b
	return ""


func _input(ev: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if ev is InputEventScreenTouch:
		var t := ev as InputEventScreenTouch
		var p := t.position
		if t.pressed:
			var b := _hit_button(p)
			if b != "":
				_btn_touch[t.index] = b
				action_pressed.emit(b)
				queue_redraw()
				get_viewport().set_input_as_handled()
				return
			if p.x < size.x * 0.5 and _joy_touch == -1:
				_joy_touch = t.index
				_joy_center = p if joystick_mode == "floating" else joy_fixed
				_joy_knob = p
				_update_move()
				get_viewport().set_input_as_handled()
		else:
			if t.index == _joy_touch:
				_joy_touch = -1
				move = Vector2.ZERO
				queue_redraw()
			_btn_touch.erase(t.index)
	elif ev is InputEventScreenDrag:
		var d := ev as InputEventScreenDrag
		if d.index == _joy_touch:
			_joy_knob = d.position
			if joystick_mode == "floating":
				var off := _joy_knob - _joy_center
				if off.length() > R:
					_joy_center = _joy_knob - off.normalized() * R
			_update_move()
			get_viewport().set_input_as_handled()


func _update_move() -> void:
	var off := (_joy_knob - _joy_center) / maxf(R, 1.0)
	var l := off.length()
	if l < DEADZONE:
		move = Vector2.ZERO
	else:
		move = off.limit_length(1.0) * inverse_lerp(DEADZONE, 1.0, minf(l, 1.0)) / minf(l, 1.0)
	queue_redraw()


func set_cooldowns(cd: Dictionary) -> void:
	var changed := false
	for k in cd:
		if absf(float(cooldown.get(k, 0.0)) - float(cd[k])) > 0.02:
			cooldown[k] = cd[k]
			changed = true
	if changed:
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	# Joystick.
	if _joy_touch != -1 or joystick_mode == "fixed":
		var c := _joy_center if _joy_touch != -1 else joy_fixed
		draw_circle(c, R, Color(0.05, 0.06, 0.1, 0.35))
		draw_arc(c, R, 0, TAU, 48, Color(0.93, 0.91, 0.86, 0.45), 3.0 * sc, true)
		var k := c + move * R
		draw_circle(k, R * 0.42, Color(0.93, 0.91, 0.86, 0.55))
	for b in BUTTONS:
		var bc: Vector2 = btn_center[b]
		var r: float = btn_r[b]
		var held: bool = b in _btn_touch.values()
		var ready := float(cooldown.get(b, 0.0)) <= 0.0 if b != "ULT" else float(cooldown.ULT) >= 1.0
		var fill := Color(0.09, 0.11, 0.16, 0.62 if not held else 0.85)
		draw_circle(bc, r, fill)
		var ring := Color(0.96, 0.75, 0.31, 0.95) if (b == "ULT" and ready) else Color(0.93, 0.91, 0.86, 0.75 if ready else 0.35)
		draw_arc(bc, r + RING * 0.5, 0, TAU, 40, ring, RING, true)
		var frac := float(cooldown.get(b, 0.0))
		if b == "ULT":
			if frac < 1.0:
				draw_arc(bc, r - 4.0 * sc, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, Color(0.96, 0.75, 0.31, 0.8), 4.0 * sc, true)
		elif frac > 0.0:
			draw_arc(bc, r - 4.0 * sc, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, Color(0.32, 0.8, 0.96, 0.8), 4.0 * sc, true)
		var fs := int(maxf(14.0, r * (0.42 if b.length() > 1 else 0.7)))
		var ts := font.get_string_size(b, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
		draw_string(font, bc + Vector2(-ts.x * 0.5, ts.y * 0.32), b, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color(0.93, 0.91, 0.86, 0.95 if ready else 0.55))
