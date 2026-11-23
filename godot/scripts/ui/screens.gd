class_name Screens
extends Control
## Menus and overlays, built in code. The main menu stays uncluttered: currency
## pill, 4 hero tiles, act selector, a large PLAY call-to-action and a 4-button
## bottom bar (Gear, Upgrades, Modes, Options). Meta menus live in sub-panels.

signal play_requested
signal resume_requested
signal abandon_requested
signal choice_made(idx: int)
signal end_continue
signal options_changed
signal hero_changed(id: String)
signal act_changed(idx: int)
signal pause_requested

const INK := Color(0.05, 0.06, 0.10)
const PANEL := Color(0.09, 0.106, 0.16, 0.94)
const PANEL2 := Color(0.13, 0.153, 0.25)
const LINE := Color(0.2, 0.23, 0.35)
const FG := Color(0.93, 0.91, 0.86)
const MUTED := Color(0.6, 0.63, 0.72)
const GOLD := Color(0.96, 0.75, 0.31)
const ON_GOLD := Color(0.16, 0.11, 0.02)

var menu: Control
var levelup: Control
var pause_panel: Control
var end_panel: Control
var sub: Control
var hud_buttons: Control
var safe_margin: MarginContainer

var _pill: Label
var _act_label: Label
var _act_sub: Label
var _hero_tiles := {}
var _help: Label
var _sub_box: VBoxContainer
var _sub_title: Label
var _lv_box: VBoxContainer
var _end_title: Label
var _end_body: Label
var _mode_label: Label
var _theme: Theme


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_theme = _make_theme()
	theme = _theme
	_build_menu()
	_build_levelup()
	_build_pause()
	_build_end()
	_build_sub()
	_build_hud_buttons()
	resized.connect(_apply_safe_area)
	_apply_safe_area()
	hide_all()


# ----------------------------------------------------------------------------
# Theme
# ----------------------------------------------------------------------------
func _box(bg: Color, border: Color, radius: int = 12, bw: int = 2) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 22
	t.set_color("font_color", "Label", FG)
	t.set_color("font_color", "Button", FG)
	t.set_color("font_hover_color", "Button", FG)
	t.set_color("font_pressed_color", "Button", GOLD)
	t.set_color("font_disabled_color", "Button", MUTED)
	t.set_stylebox("normal", "Button", _box(PANEL2, LINE))
	t.set_stylebox("hover", "Button", _box(PANEL2.lightened(0.08), LINE.lightened(0.2)))
	t.set_stylebox("pressed", "Button", _box(PANEL2.darkened(0.1), GOLD))
	t.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), Color(0.32, 0.8, 0.96), 12, 3))
	t.set_stylebox("disabled", "Button", _box(PANEL2.darkened(0.3), LINE))
	t.set_stylebox("panel", "PanelContainer", _box(PANEL, LINE, 16))
	t.set_constant("separation", "VBoxContainer", 12)
	t.set_constant("separation", "HBoxContainer", 12)
	t.set_constant("h_separation", "GridContainer", 12)
	t.set_constant("v_separation", "GridContainer", 12)
	return t


func _label(text: String, size: int = 22, col: Color = FG) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _button(text: String, cb: Callable, min_h: float = 64.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, min_h)
	b.pressed.connect(func(): Sfx.ui(); cb.call())
	return b


func _apply_safe_area() -> void:
	if safe_margin == null:
		return
	var sa := TouchControls.safe_rect_for(size)
	safe_margin.add_theme_constant_override("margin_left", int(sa.position.x) + 20)
	safe_margin.add_theme_constant_override("margin_top", int(sa.position.y) + 14)
	safe_margin.add_theme_constant_override("margin_right", int(size.x - sa.end.x) + 20)
	safe_margin.add_theme_constant_override("margin_bottom", int(size.y - sa.end.y) + 14)


# ----------------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------------
func _build_menu() -> void:
	menu = Control.new()
	menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(menu)
	safe_margin = MarginContainer.new()
	safe_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	safe_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu.add_child(safe_margin)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	safe_margin.add_child(col)
	# Top row: title + currency pill.
	var top := HBoxContainer.new()
	col.add_child(top)
	var title := VBoxContainer.new()
	title.add_theme_constant_override("separation", 0)
	title.add_child(_label("SHARDFALL", 46, FG))
	title.add_child(_label("RIFT SURVIVORS", 20, GOLD))
	top.add_child(title)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", _box(Color(0.05, 0.06, 0.1, 0.8), GOLD.darkened(0.3), 24))
	pill.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_pill = _label("", 22, GOLD)
	pill.add_child(_pill)
	top.add_child(pill)
	# Middle: 3D stage (left, unobstructed) + selection column (right).
	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(mid)
	var stage_gap := Control.new()
	stage_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage_gap.size_flags_stretch_ratio = 1.1
	stage_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(stage_gap)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.custom_minimum_size = Vector2(440, 0)
	right.alignment = BoxContainer.ALIGNMENT_END
	mid.add_child(right)
	right.add_child(_label("CHOOSE YOUR HERO", 18, MUTED))
	var grid := GridContainer.new()
	grid.columns = 2
	right.add_child(grid)
	for id in Content.HERO_ORDER:
		var hb := Button.new()
		hb.toggle_mode = true
		hb.custom_minimum_size = Vector2(210, 74)
		hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_theme_font_size_override("font_size", 20)
		hb.pressed.connect(_on_hero_tile.bind(id))
		grid.add_child(hb)
		_hero_tiles[id] = hb
	var act_row := HBoxContainer.new()
	right.add_child(act_row)
	act_row.add_child(_button("<", func(): _step_act(-1), 64))
	var act_col := VBoxContainer.new()
	act_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	act_col.add_theme_constant_override("separation", 0)
	_act_label = _label("", 26, FG)
	_act_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_act_sub = _label("", 16, MUTED)
	_act_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	act_col.add_child(_act_label)
	act_col.add_child(_act_sub)
	act_row.add_child(act_col)
	act_row.add_child(_button(">", func(): _step_act(1), 64))
	var play := Button.new()
	play.text = "PLAY"
	play.name = "Play"
	play.custom_minimum_size = Vector2(0, 92)
	play.add_theme_font_size_override("font_size", 44)
	play.add_theme_color_override("font_color", ON_GOLD)
	play.add_theme_color_override("font_hover_color", ON_GOLD)
	play.add_theme_color_override("font_pressed_color", ON_GOLD)
	play.add_theme_stylebox_override("normal", _box(GOLD, GOLD.lightened(0.2), 18))
	play.add_theme_stylebox_override("hover", _box(GOLD.lightened(0.1), GOLD.lightened(0.3), 18))
	play.add_theme_stylebox_override("pressed", _box(GOLD.darkened(0.15), GOLD, 18))
	play.pressed.connect(func(): Sfx.ui(); play_requested.emit())
	right.add_child(play)
	_mode_label = _label("", 16, MUTED)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(_mode_label)
	# Bottom bar.
	var bar := HBoxContainer.new()
	bar.name = "BottomBar"
	col.add_child(bar)
	for entry in [["Gear", _open_gear], ["Upgrades", _open_upgrades], ["Modes", _open_modes], ["Options", _open_options]]:
		var b := _button(entry[0], entry[1], 60)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.add_child(b)
	_help = _label("Move WASD / arrows   Roll Shift   Jump Space   Skills Q / E   Ult R   Pause Esc", 15, MUTED)
	_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_help.visible = not DisplayServer.is_touchscreen_available()
	col.add_child(_help)


func refresh_menu() -> void:
	_pill.text = "◆ %d    ✦ %d" % [int(Save.data.gold), int(Save.data.echoes)]
	var sel: String = Save.data.hero
	for id in _hero_tiles:
		var h: Dictionary = Content.hero(id)
		var b: Button = _hero_tiles[id]
		var owned := Save.has_hero(id)
		b.text = String(h.name) if owned else "%s   ◆%d" % [h.name, int(h.cost)]
		b.button_pressed = id == sel
		b.modulate = Color(1, 1, 1) if owned else Color(0.75, 0.75, 0.8)
	var ai := int(Save.data.act)
	var a := Content.act(ai)
	_act_label.text = "Act %d  ·  %s" % [ai + 1, a.name]
	var locked := ai > int(Save.data.act_unlocked)
	_act_sub.text = "Locked: clear Act %d first" % ai if locked else "Boss: %s" % Content.BOSSES[a.boss].name
	(menu.find_child("Play", true, false) as Button).disabled = locked or not Save.has_hero(sel)
	_mode_label.text = "Mode: %s" % Content.MODES[Save.data.mode].name


func _on_hero_tile(id: String) -> void:
	Sfx.ui()
	if not Save.has_hero(id):
		if Save.buy_hero(id):
			Save.data.hero = id
	else:
		Save.data.hero = id
	Save.save_profile()
	refresh_menu()
	hero_changed.emit(String(Save.data.hero))


func _step_act(d: int) -> void:
	Save.data.act = clampi(int(Save.data.act) + d, 0, Content.ACTS.size() - 1)
	Save.save_profile()
	refresh_menu()
	act_changed.emit(int(Save.data.act))


# ----------------------------------------------------------------------------
# Sub-menus (Gear / Upgrades / Modes / Options)
# ----------------------------------------------------------------------------
func _build_sub() -> void:
	sub = Control.new()
	sub.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(sub)
	var scrim := ColorRect.new()
	scrim.color = Color(0.02, 0.02, 0.05, 0.6)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sub.add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sub.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	_sub_title = _label("", 30, GOLD)
	v.add_child(_sub_title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(580, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_sub_box = VBoxContainer.new()
	_sub_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_sub_box)
	v.add_child(_button("Close", _close_sub, 60))


func _open_sub(t: String) -> void:
	_sub_title.text = t
	for c in _sub_box.get_children():
		c.queue_free()
	sub.visible = true


func _close_sub() -> void:
	sub.visible = false
	refresh_menu()


func _row(left: String, desc: String, btn_text: String, cb: Callable, enabled: bool = true) -> void:
	var h := HBoxContainer.new()
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 0)
	v.add_child(_label(left, 22))
	v.add_child(_label(desc, 16, MUTED))
	h.add_child(v)
	var b := _button(btn_text, cb, 56)
	b.custom_minimum_size.x = 170
	b.disabled = not enabled
	h.add_child(b)
	_sub_box.add_child(h)


func _open_gear() -> void:
	_open_sub("Gear")
	for id in Content.HERO_ORDER:
		var h: Dictionary = Content.hero(id)
		var desc := "%s · HP %d · Speed %d · Armor %d · %s" % [h.title, int(h.hp), int(h.speed), int(h.armor), Content.WEAPONS[h.weapon].name]
		if Save.has_hero(id):
			_row(String(h.name), desc, "Selected" if Save.data.hero == id else "Select", _gear_pick.bind(id), Save.data.hero != id)
		else:
			_row(String(h.name), desc, "◆ %d" % int(h.cost), _gear_buy.bind(id), int(Save.data.gold) >= int(h.cost))


func _gear_pick(id: String) -> void:
	Save.data.hero = id
	Save.save_profile()
	hero_changed.emit(id)
	_open_gear()


func _gear_buy(id: String) -> void:
	if Save.buy_hero(id):
		Save.data.hero = id
		Save.save_profile()
		hero_changed.emit(id)
	_open_gear()


func _open_upgrades() -> void:
	_open_sub("Upgrades")
	_sub_box.add_child(_label("Gold ◆ %d" % int(Save.data.gold), 20, GOLD))
	for id in Content.UPGRADES:
		var u: Dictionary = Content.UPGRADES[id]
		var lvl := int(Save.data.upgrades.get(id, 0))
		var maxed := lvl >= int(u.max)
		_row("%s  %d/%d" % [u.name, lvl, int(u.max)], String(u.desc), "MAX" if maxed else "◆ %d" % Save.upgrade_cost(id),
			_upgrade_buy.bind(id), not maxed and int(Save.data.gold) >= Save.upgrade_cost(id))


func _upgrade_buy(id: String) -> void:
	Save.buy_upgrade(id)
	_open_upgrades()


func _mode_pick(id: String) -> void:
	Save.data.mode = id
	Save.save_profile()
	_open_modes()


func _open_modes() -> void:
	_open_sub("Modes")
	for id in Content.MODES:
		var m: Dictionary = Content.MODES[id]
		_row(String(m.name), String(m.desc), "Active" if Save.data.mode == id else "Choose", _mode_pick.bind(id), Save.data.mode != id)


func _open_options() -> void:
	_open_sub("Options")
	var q := int(Save.setting("quality"))
	var qname: String = "Auto (%s)" % Quality.TIER_NAMES[Quality.detected] if q < 0 else Quality.TIER_NAMES[q]
	_row("Graphics: " + qname, "Auto-detects Low / Medium / High from GPU + RAM.", "Change", func():
		var nq := q + 1
		if nq > 2:
			nq = -1
		Save.set_setting("quality", nq)
		options_changed.emit()
		_open_options())
	var safe_on := bool(Save.setting("gles_safe"))
	_row("Safe mode (OpenGL ES 3): " + ("On" if safe_on else "Off"), "For unstable Mali Vulkan drivers. Applies after restart.", "Toggle", func():
		Save.set_setting("gles_safe", not safe_on)
		Quality.set_gles_safe_mode(not safe_on)
		_open_options())
	var joy: String = Save.setting("joystick")
	_row("Joystick: " + joy.capitalize(), "Floating follows your thumb; fixed stays put.", "Toggle", func():
		Save.set_setting("joystick", "fixed" if joy == "floating" else "floating")
		options_changed.emit()
		_open_options())
	var us := float(Save.setting("ui_scale"))
	_row("Button size: %d%%" % int(us * 100.0), "Scales the touch buttons and joystick.", "Change", func():
		var n := us + 0.1
		if n > 1.31:
			n = 0.8
		Save.set_setting("ui_scale", snappedf(n, 0.1))
		options_changed.emit()
		_open_options())
	var mv := float(Save.setting("music"))
	_row("Music: %d%%" % int(mv * 100.0), "", "Change", func():
		Save.set_setting("music", 0.0 if mv >= 0.99 else snappedf(mv + 0.2, 0.2))
		Sfx.apply_volumes()
		_open_options())
	var sv := float(Save.setting("sfx"))
	_row("Effects: %d%%" % int(sv * 100.0), "", "Change", func():
		Save.set_setting("sfx", 0.0 if sv >= 0.99 else snappedf(sv + 0.2, 0.2))
		Sfx.apply_volumes()
		_open_options())
	var fps := bool(Save.setting("show_fps"))
	_row("Show FPS: " + ("On" if fps else "Off"), "", "Toggle", func():
		Save.set_setting("show_fps", not fps)
		options_changed.emit()
		_open_options())


# ----------------------------------------------------------------------------
# In-run overlays
# ----------------------------------------------------------------------------
func _overlay(title: String) -> Array:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var scrim := ColorRect.new()
	scrim.color = Color(0.02, 0.02, 0.05, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	var t := _label(title, 34, GOLD)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	return [root, v, t]


func _build_levelup() -> void:
	var o := _overlay("LEVEL UP")
	levelup = o[0]
	_lv_box = o[1]


func show_levelup(w: SimWorld) -> void:
	hide_all()
	levelup.visible = true
	for c in _lv_box.get_children():
		if c is Button:
			c.queue_free()
	for i in w.choices.size():
		var c: Dictionary = w.choices[i]
		var b := Button.new()
		b.text = "%s\n%s" % [w.choice_label(c), w.choice_desc(c)]
		b.custom_minimum_size = Vector2(520, 96)
		b.add_theme_font_size_override("font_size", 22)
		if String(c.type) == "evolve":
			b.add_theme_stylebox_override("normal", _box(PANEL2, GOLD))
		b.pressed.connect(func(): Sfx.ui(); choice_made.emit(i))
		_lv_box.add_child(b)
	await get_tree().process_frame
	for c in _lv_box.get_children():
		if c is Button:
			(c as Button).grab_focus()
			break


func _build_pause() -> void:
	var o := _overlay("PAUSED")
	pause_panel = o[0]
	var v: VBoxContainer = o[1]
	v.add_child(_button("Resume", func(): resume_requested.emit(), 72))
	v.add_child(_button("Abandon run", func(): abandon_requested.emit(), 64))


func _build_end() -> void:
	var o := _overlay("")
	end_panel = o[0]
	var v: VBoxContainer = o[1]
	_end_title = o[2]
	_end_body = _label("", 22, FG)
	_end_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_end_body)
	v.add_child(_button("Continue", func(): end_continue.emit(), 72))


func show_end(w: SimWorld, gold: int, echoes: int) -> void:
	hide_all()
	end_panel.visible = true
	_end_title.text = "VICTORY" if w.won else "FALLEN"
	var mm := int(w.time) / 60
	var ss := int(w.time) % 60
	_end_body.text = "%s\nSurvived %02d:%02d   ·   Level %d   ·   %d kills\nPerfect dodges %d\n+◆ %d gold    +✦ %d echoes" % [
		Content.act(w.act).name, mm, ss, w.level, w.kills, w.perfect_dodges, gold, echoes]


func _build_hud_buttons() -> void:
	hud_buttons = Control.new()
	hud_buttons.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud_buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud_buttons)
	var pb := Button.new()
	pb.name = "Pause"
	pb.text = "II"
	pb.custom_minimum_size = Vector2(64, 56)
	pb.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pb.position = Vector2(-90, 18)
	pb.pressed.connect(func(): Sfx.ui(); pause_requested.emit())
	hud_buttons.add_child(pb)


func place_pause_button(safe: Rect2) -> void:
	var pb: Button = hud_buttons.get_node("Pause")
	pb.set_anchors_preset(Control.PRESET_TOP_LEFT)
	pb.position = Vector2(safe.end.x - 64.0 - 16.0, safe.position.y + 14.0)


func hide_all() -> void:
	menu.visible = false
	levelup.visible = false
	pause_panel.visible = false
	end_panel.visible = false
	sub.visible = false
	hud_buttons.visible = false


func show_menu() -> void:
	hide_all()
	menu.visible = true
	refresh_menu()


func show_hud() -> void:
	hide_all()
	hud_buttons.visible = true


func show_pause() -> void:
	hide_all()
	pause_panel.visible = true
