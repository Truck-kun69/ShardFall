extends Node
## Root orchestrator: quality setup, menu <-> run flow, fixed-step simulation
## loop with interpolated rendering, input (touch + keyboard + gamepad), audio cues.

enum St { MENU, RUN, PAUSE, LEVELUP, END }

var state := St.MENU
var clock := FixedStep.new()
var world: SimWorld
var view: WorldView3D
var stage: MenuStage3D
var ui_layer: CanvasLayer
var hud: Hud
var touch: TouchControls
var screens: Screens
var _end_delay := 0.0
var _rewarded := false
var _reward_gold := 0
var _reward_echoes := 0
var _sfx_hits := 0


func _ready() -> void:
	_setup_input_map()
	_detect_quality()
	stage = MenuStage3D.new()
	stage.name = "MenuStage"
	add_child(stage)
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 1
	add_child(ui_layer)
	touch = TouchControls.new()
	touch.name = "Touch"
	ui_layer.add_child(touch)
	hud = Hud.new()
	hud.name = "Hud"
	hud.touch = touch
	ui_layer.add_child(hud)
	screens = Screens.new()
	screens.name = "Screens"
	ui_layer.add_child(screens)
	screens.play_requested.connect(_start_run)
	screens.resume_requested.connect(_resume)
	screens.abandon_requested.connect(_abandon)
	screens.choice_made.connect(_on_choice)
	screens.end_continue.connect(_to_menu)
	screens.options_changed.connect(_on_options)
	screens.hero_changed.connect(func(id): stage.set_hero(id))
	screens.act_changed.connect(func(i): stage.set_act(i))
	screens.pause_requested.connect(_pause)
	touch.action_pressed.connect(_on_touch_action)
	get_viewport().size_changed.connect(_on_resize)
	_on_options()
	_to_menu()


# ----------------------------------------------------------------------------
# Quality
# ----------------------------------------------------------------------------
func _detect_quality() -> void:
	var gpu := RenderingServer.get_video_adapter_name()
	var mem: Dictionary = OS.get_memory_info()
	var ram_mb := int(mem.get("physical", 0)) / 1048576
	Quality.detected = Quality.detect(gpu, ram_mb)
	var ov := int(Save.setting("quality"))
	Quality.set_tier(Quality.detected if ov < 0 else ov)
	Quality.apply_viewport(get_viewport())
	print("[Shardfall] GPU '%s' RAM %d MiB -> %s (render scale %.2f, %s)" % [gpu, ram_mb, Quality.TIER_NAMES[Quality.tier], Quality.dyn_scale, RenderingServer.get_current_rendering_method()])


func _on_options() -> void:
	var ov := int(Save.setting("quality"))
	var t := Quality.detected if ov < 0 else ov
	if t != Quality.tier:
		Quality.set_tier(t)
		Quality.apply_viewport(get_viewport())
		if view != null:
			view.apply_quality()
	touch.set_options(String(Save.setting("joystick")), float(Save.setting("ui_scale")))
	hud.show_fps = bool(Save.setting("show_fps"))


func _on_resize() -> void:
	if screens != null and touch != null:
		screens.place_pause_button(touch.safe_rect())


# ----------------------------------------------------------------------------
# Flow
# ----------------------------------------------------------------------------
func _to_menu() -> void:
	state = St.MENU
	get_tree().paused = false
	if view != null:
		view.queue_free()
		view = null
	world = null
	hud.bind(null)
	hud.visible = false
	touch.visible = false
	stage.set_hero(String(Save.data.hero))
	stage.set_act(int(Save.data.act))
	stage.activate(true)
	screens.show_menu()
	Sfx.music(true)


func _start_run() -> void:
	var hero_id := String(Save.data.hero)
	var act := int(Save.data.act)
	if not Save.has_hero(hero_id) or act > int(Save.data.act_unlocked):
		return
	world = SimWorld.new(act, hero_id, int(Time.get_ticks_usec() & 0x7FFFFFFF), Save.data.upgrades, String(Save.data.mode))
	view = WorldView3D.new()
	view.name = "WorldView"
	add_child(view)
	view.setup(world)
	stage.activate(false)
	view.camera.current = true
	clock.reset()
	hud.bind(world)
	hud.visible = true
	touch.visible = DisplayServer.is_touchscreen_available()
	touch.reset()
	screens.show_hud()
	screens.place_pause_button(touch.safe_rect())
	_rewarded = false
	_end_delay = 1.4
	state = St.RUN


func _pause() -> void:
	if state != St.RUN:
		return
	state = St.PAUSE
	touch.reset()
	screens.show_pause()


func _resume() -> void:
	if state != St.PAUSE:
		return
	state = St.RUN
	screens.show_hud()


func _abandon() -> void:
	if world != null:
		world.over = true
		world.alive = false
	_finish_run()


func _on_choice(i: int) -> void:
	if world == null:
		return
	world.choose(i)
	if world.pending_levelups > 0 and not world.choices.is_empty():
		screens.show_levelup(world)
		return
	state = St.RUN
	screens.show_hud()


func _finish_run() -> void:
	if world == null:
		return
	if not _rewarded:
		_rewarded = true
		_reward_gold = int(world.gold_run) + (50 * (world.act + 1) if world.won else 0)
		_reward_echoes = world.echoes_run
		Save.record_run(world.act, world.won, _reward_gold, _reward_echoes, world.time, world.kills)
	state = St.END
	touch.visible = false
	screens.show_end(world, _reward_gold, _reward_echoes)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_pause()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if state == St.RUN:
			_pause()
		elif state == St.PAUSE:
			_resume()


# ----------------------------------------------------------------------------
# Frame loop
# ----------------------------------------------------------------------------
func _process(dt: float) -> void:
	if world == null or view == null:
		return
	match state:
		St.RUN:
			_gather_input()
			var n := clock.advance(dt)
			for i in n:
				world.step(FixedStep.STEP)
			view.render(dt, clock.alpha())
			_play_event_sfx()
			world.events.clear()
			touch.set_cooldowns({
				"ROLL": world.roll_cd / SimWorld.ROLL_CD, "JUMP": world.jump_cd / SimWorld.JUMP_CD,
				"ULT": world.ult, "1": float(world.skill_cd[0]) / float(SimWorld.SKILL_CD[0]),
				"2": float(world.skill_cd[1]) / float(SimWorld.SKILL_CD[1]),
			})
			if world.pending_levelups > 0 and not world.choices.is_empty():
				state = St.LEVELUP
				touch.reset()
				screens.show_levelup(world)
			elif world.over:
				_end_delay -= dt
				if _end_delay <= 0.0:
					_finish_run()
			if Quality.update_dynamic(dt):
				Quality.apply_viewport(get_viewport())
		St.PAUSE, St.LEVELUP, St.END:
			view.render(0.0, clock.alpha())
			world.events.clear()


func _gather_input() -> void:
	var k := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var m := touch.move if touch.visible else Vector2.ZERO
	world.set_move(m if m.length_squared() > k.length_squared() else k)
	if Input.is_action_just_pressed("roll"):
		world.press_roll()
	if Input.is_action_just_pressed("jump"):
		world.press_jump()
	if Input.is_action_just_pressed("ult"):
		world.press_ult()
	if Input.is_action_just_pressed("skill1"):
		world.press_skill(0)
	if Input.is_action_just_pressed("skill2"):
		world.press_skill(1)


func _unhandled_input(ev: InputEvent) -> void:
	if ev.is_action_pressed("pause"):
		if state == St.RUN:
			_pause()
		elif state == St.PAUSE:
			_resume()


func _on_touch_action(a: String) -> void:
	if world == null or state != St.RUN:
		return
	match a:
		"ROLL":
			world.press_roll()
		"JUMP":
			world.press_jump()
		"ULT":
			world.press_ult()
		"1":
			world.press_skill(0)
		"2":
			world.press_skill(1)


func _play_event_sfx() -> void:
	_sfx_hits = 0
	var hp := world.pos
	for e in world.events:
		var at := Vector2(e[1], e[2])
		match String(e[0]):
			"hit", "die":
				if _sfx_hits < 2:
					_sfx_hits += 1
					Sfx.play_at("hit" if e[0] == "hit" else "die", at, hp, randf_range(0.9, 1.15), -8.0)
			"xp":
				Sfx.xp_pickup()
			"levelup":
				Sfx.play("levelup")
			"roll":
				Sfx.play("roll", 1.0, -4.0)
			"jump":
				Sfx.play("jump", 1.0, -4.0)
			"land":
				Sfx.play("land", 1.0, -4.0)
			"hurt":
				Sfx.play("hurt", randf_range(0.95, 1.05), -2.0)
			"perfect":
				Sfx.play("perfect")
			"nova", "riposte", "bomb", "boss_slam":
				Sfx.play_at("nova", at, hp)
			"ult":
				Sfx.play("ult")
			"boss_spawn":
				Sfx.play_at("boss", at, hp)
			"react":
				Sfx.play_at("react", at, hp, 1.0, -6.0)
			"victory":
				Sfx.play("victory")


func _setup_input_map() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"roll": [KEY_SHIFT], "jump": [KEY_SPACE], "ult": [KEY_R],
		"skill1": [KEY_Q], "skill2": [KEY_E], "pause": [KEY_ESCAPE, KEY_P],
	}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		for kc in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = kc
			InputMap.action_add_event(action, ev)
	var axes := {"move_left": [JOY_AXIS_LEFT_X, -1.0], "move_right": [JOY_AXIS_LEFT_X, 1.0], "move_up": [JOY_AXIS_LEFT_Y, -1.0], "move_down": [JOY_AXIS_LEFT_Y, 1.0]}
	for action in axes:
		var jm := InputEventJoypadMotion.new()
		jm.axis = axes[action][0]
		jm.axis_value = axes[action][1]
		InputMap.action_add_event(action, jm)
	var btns := {"roll": JOY_BUTTON_B, "jump": JOY_BUTTON_A, "ult": JOY_BUTTON_Y, "skill1": JOY_BUTTON_LEFT_SHOULDER, "skill2": JOY_BUTTON_RIGHT_SHOULDER, "pause": JOY_BUTTON_START}
	for action in btns:
		var jb := InputEventJoypadButton.new()
		jb.button_index = btns[action]
		InputMap.action_add_event(action, jb)
