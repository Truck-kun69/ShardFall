extends Node
## Visual smoke harness (needs a real renderer, e.g. Xvfb + lavapipe):
##   godot --path godot res://tests/render_shot.tscn -- --act=0 --tier=1 --frames=240 --out=/path/shot.png
## Runs the real game view with scripted input, then saves a screenshot.
## Also fails loudly (exit 1) on any shader compile error reported by the engine.

var _args := {}
var _frames := 240
var _frame := 0
var _world: SimWorld
var _view: WorldView3D
var _clock := FixedStep.new()
var _menu: MenuStage3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1]
	_frames = int(_args.get("frames", "240"))
	Quality.set_tier(int(_args.get("tier", "1")))
	Quality.apply_viewport(get_viewport())
	if _args.get("menu", "0") == "1":
		_menu = MenuStage3D.new()
		add_child(_menu)
		_menu.set_hero(_args.get("hero", "warden"))
		_menu.activate(true)
		var sc := Screens.new()
		var cl := CanvasLayer.new()
		add_child(cl)
		cl.add_child(sc)
		sc.show_menu()
		return
	_world = SimWorld.new(int(_args.get("act", "0")), _args.get("hero", "warden"), 42)
	_view = WorldView3D.new()
	add_child(_view)
	_view.setup(_world)
	_view.camera.current = true
	var hud := Hud.new()
	var cl2 := CanvasLayer.new()
	cl2.layer = 2
	add_child(cl2)
	var tc := TouchControls.new()
	cl2.add_child(tc)
	hud.touch = tc
	cl2.add_child(hud)
	hud.bind(_world)
	if _args.has("boss"):
		_world.boss_acc = 0.5


func _process(dt: float) -> void:
	_frame += 1
	if _world != null:
		var sdt := 1.0 / 30.0
		_world.autopilot(_world.time, sdt)
		var n := _clock.advance(sdt)
		for i in n:
			_world.step(FixedStep.STEP)
			if not _world.choices.is_empty():
				_world.choose(0)
		_view.render(sdt, _clock.alpha())
		_world.events.clear()
	if _frame == _frames:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var out: String = _args.get("out", "user://shot.png")
		img.save_png(out)
		print("[render_shot] saved %s (%dx%d) foes=%d" % [out, img.get_width(), img.get_height(), _world.swarm.alive_n if _world else 0])
		get_tree().quit(0)
