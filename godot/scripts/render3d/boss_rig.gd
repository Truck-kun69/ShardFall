class_name BossRig
extends Node3D
## Boss rig: res://models/bosses/<id>.glb (88u, feet Y=0, +X forward, clips
## idle/walk/attack/slam/die) or a procedural skeleton with the same clips.
## The hit-flash shader is cached statically so spawning a boss never stalls.

const SINK_DEPTH := 34.0

static var _flash_shader: Shader = null

var boss_id := ""
var procedural := true
var player: AnimationPlayer
var skeleton: Skeleton3D
var light: OmniLight3D
var body: Node3D
var clips := {}
var current := ""
var base_light := 2.4

var _flash_mat: ShaderMaterial
var _died := false
var _meshes: Array[MeshInstance3D] = []


static func flash_shader() -> Shader:
	if _flash_shader == null:
		_flash_shader = load("res://shaders/3d/flash.gdshader")
	return _flash_shader


## Clip choice. `alt` alternates attack/slam between consecutive attacks.
static func pick_clip(dead: bool, attack: bool, busy: bool, flinch: bool, speed: float, alt: bool = false) -> String:
	if dead:
		return "die"
	if attack:
		return "slam" if alt else "attack"
	if busy or flinch:
		return "idle"
	if speed < 5.0:
		return "idle"
	return "walk"


func setup(id: String, tint: Color) -> void:
	boss_id = id
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	var ps := Models.load_slot("bosses", id)
	if ps != null:
		procedural = false
		var inst := ps.instantiate()
		body.add_child(inst)
		player = _find(inst, "AnimationPlayer") as AnimationPlayer
		_collect(inst)
	if player == null:
		procedural = true
		_build_procedural(tint)
	for role in ["idle", "walk", "attack", "slam", "die"]:
		clips[role] = _match(role)
	if clips.die != "":
		player.get_animation(clips.die).loop_mode = Animation.LOOP_NONE
	for role in ["attack", "slam"]:
		if clips[role] != "":
			player.get_animation(clips[role]).loop_mode = Animation.LOOP_NONE
	_flash_mat = ShaderMaterial.new()
	_flash_mat.shader = flash_shader()
	for mi in _meshes:
		mi.material_overlay = _flash_mat
	light = OmniLight3D.new()
	light.light_color = tint.lightened(0.4)
	light.light_energy = base_light
	light.omni_range = 220.0
	light.shadow_enabled = false
	light.position = Vector3(0, 60, 0)
	add_child(light)
	_play("idle")


func _match(role: String) -> String:
	if player == null:
		return ""
	var keys := {"idle": ["idle"], "walk": ["walk", "run"], "attack": ["attack", "swing"], "slam": ["slam", "smash"], "die": ["die", "death"]}
	for k in keys[role]:
		for n in player.get_animation_list():
			if String(n).to_lower().contains(k):
				return String(n)
	var list := player.get_animation_list()
	return String(list[0]) if list.size() > 0 else ""


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _collect(n: Node) -> void:
	if n is MeshInstance3D:
		_meshes.append(n)
	for c in n.get_children():
		_collect(c)


func _play(role: String) -> void:
	var clip: String = clips.get(role, "")
	if clip == "" or player == null:
		return
	current = role
	player.play(clip, 0.15)


## dead/attack/busy/flinch mirror Boss state; death_frac goes 1 -> 0 while the
## corpse sinks, fading the boss light to 0 with it.
func update_state(dt: float, dead: bool, attack: bool, busy: bool, flinch: bool, speed: float, alt: bool, death_frac: float, flash: float) -> void:
	_flash_mat.set_shader_parameter("flash", clampf(flash * 8.0, 0.0, 1.0))
	if dead:
		if not _died:
			_died = true
			_play("die")
		var f := clampf(death_frac, 0.0, 1.0)
		light.light_energy = base_light * f
		body.position.y = -SINK_DEPTH * (1.0 - f) * (1.0 - f)
		return
	var want := pick_clip(false, attack, busy, flinch, speed, alt)
	if current == "attack" or current == "slam":
		if player.is_playing() and want != "attack" and want != "slam":
			return   # let the swing finish
	if want != current:
		_play(want)
	if current == "walk":
		player.speed_scale = clampf(speed / 50.0, 0.7, 1.4)
	else:
		player.speed_scale = 1.0


func _build_procedural(tint: Color) -> void:
	var col := tint
	var dark := tint.darkened(0.45)
	var bone_c := Color(0.85, 0.80, 0.70)
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	body.add_child(skeleton)
	var bones := [
		["root", "", Vector3.ZERO], ["hips", "root", Vector3(0, 40, 0)],
		["spine", "hips", Vector3(0, 9, 0)], ["chest", "spine", Vector3(0, 12, 0)],
		["neck", "chest", Vector3(0, 13, 0)], ["head", "neck", Vector3(0, 4, 0)],
		["shoulder_l", "chest", Vector3(0, 10, -17)], ["arm_l", "shoulder_l", Vector3(0, -17, 0)], ["hand_l", "arm_l", Vector3(0, -16, 0)],
		["shoulder_r", "chest", Vector3(0, 10, 17)], ["arm_r", "shoulder_r", Vector3(0, -17, 0)], ["hand_r", "arm_r", Vector3(0, -16, 0)],
		["thigh_l", "hips", Vector3(0, -2, -8)], ["shin_l", "thigh_l", Vector3(0, -19, 0)],
		["thigh_r", "hips", Vector3(0, -2, 8)], ["shin_r", "thigh_r", Vector3(0, -19, 0)],
	]
	for b in bones:
		var i := skeleton.add_bone(b[0])
		if b[1] != "":
			skeleton.set_bone_parent(i, skeleton.find_bone(b[1]))
		skeleton.set_bone_rest(i, Transform3D(Basis(), b[2]))
	skeleton.reset_bone_poses()
	_part("hips", "box", Vector3(18, 12, 26), dark, Vector3(0, 2, 0))
	_part("spine", "box", Vector3(20, 14, 28), col, Vector3(0, 6, 0))
	_part("chest", "blob", Vector3(16, 13, 22), col, Vector3(2, 7, 0))
	_part("head", "blob", Vector3(7, 8, 7), col.lightened(0.1), Vector3(3, 5, 0))
	_part("head", "box", Vector3(2, 2, 8), Color(1.0, 0.6, 0.2), Vector3(9.5, 6, 0))
	_part("head", "cone", Vector3(2.4, 11, 0), bone_c, Vector3(0, 10, -5))
	_part("head", "cone", Vector3(2.4, 11, 0), bone_c, Vector3(0, 10, 5))
	for side in ["l", "r"]:
		_part("shoulder_" + side, "blob", Vector3(9, 7, 9), dark, Vector3(0, 2, 0))
		_part("shoulder_" + side, "limb", Vector3(4.5, 17, 5.5), col, Vector3.ZERO)
		_part("arm_" + side, "limb", Vector3(4.5, 16, 5.0), col.darkened(0.1), Vector3.ZERO)
		_part("hand_" + side, "blob", Vector3(6, 6, 6), dark, Vector3(0, -3, 0))
		_part("thigh_" + side, "limb", Vector3(5.5, 19, 7.0), dark, Vector3.ZERO)
		_part("shin_" + side, "limb", Vector3(6.0, 19, 5.5), dark.lightened(0.1), Vector3.ZERO)
	player = AnimationPlayer.new()
	player.name = "AnimationPlayer"
	body.add_child(player)
	var lib := AnimationLibrary.new()
	var hp := Vector3(0, 40, 0)
	lib.add_animation("idle", _clip("idle", 2.0, true, {
		"chest": [[0.0, Vector3.ZERO], [1.0, Vector3(0, 0, -3)], [2.0, Vector3.ZERO]],
		"shoulder_l": [[0.0, Vector3(-8, 0, 4)], [1.0, Vector3(-10, 0, 0)], [2.0, Vector3(-8, 0, 4)]],
		"shoulder_r": [[0.0, Vector3(8, 0, 4)], [1.0, Vector3(10, 0, 0)], [2.0, Vector3(8, 0, 4)]],
		"arm_l": [[0.0, Vector3(0, 0, 20)], [2.0, Vector3(0, 0, 20)]],
		"arm_r": [[0.0, Vector3(0, 0, 20)], [2.0, Vector3(0, 0, 20)]],
	}, {"hips": [[0.0, hp], [1.0, hp - Vector3(0, 1, 0)], [2.0, hp]]}))
	lib.add_animation("walk", _clip("walk", 1.4, true, {
		"thigh_l": [[0.0, Vector3(0, 0, 22)], [0.7, Vector3(0, 0, -22)], [1.4, Vector3(0, 0, 22)]],
		"thigh_r": [[0.0, Vector3(0, 0, -22)], [0.7, Vector3(0, 0, 22)], [1.4, Vector3(0, 0, -22)]],
		"shin_l": [[0.0, Vector3(0, 0, -8)], [1.05, Vector3(0, 0, -35)], [1.4, Vector3(0, 0, -8)]],
		"shin_r": [[0.0, Vector3(0, 0, -8)], [0.35, Vector3(0, 0, -35)], [1.4, Vector3(0, 0, -8)]],
		"shoulder_l": [[0.0, Vector3(-8, 0, -16)], [0.7, Vector3(-8, 0, 16)], [1.4, Vector3(-8, 0, -16)]],
		"shoulder_r": [[0.0, Vector3(8, 0, 16)], [0.7, Vector3(8, 0, -16)], [1.4, Vector3(8, 0, 16)]],
		"spine": [[0.0, Vector3(0, 0, -6)], [1.4, Vector3(0, 0, -6)]],
	}, {"hips": [[0.0, hp], [0.35, hp - Vector3(0, 2, 0)], [0.7, hp], [1.05, hp - Vector3(0, 2, 0)], [1.4, hp]]}))
	lib.add_animation("attack", _clip("attack", 0.9, false, {
		"shoulder_r": [[0.0, Vector3(8, 0, 0)], [0.3, Vector3(20, 0, 140)], [0.55, Vector3(-10, 0, -30)], [0.9, Vector3(8, 0, 0)]],
		"arm_r": [[0.0, Vector3.ZERO], [0.3, Vector3(0, 0, 50)], [0.55, Vector3(0, 0, 5)], [0.9, Vector3.ZERO]],
		"chest": [[0.0, Vector3.ZERO], [0.3, Vector3(0, -30, 6)], [0.55, Vector3(0, 35, -10)], [0.9, Vector3.ZERO]],
	}, {}))
	lib.add_animation("slam", _clip("slam", 1.1, false, {
		"shoulder_l": [[0.0, Vector3(-8, 0, 0)], [0.4, Vector3(-10, 0, 170)], [0.65, Vector3(-5, 0, 40)], [1.1, Vector3(-8, 0, 0)]],
		"shoulder_r": [[0.0, Vector3(8, 0, 0)], [0.4, Vector3(10, 0, 170)], [0.65, Vector3(5, 0, 40)], [1.1, Vector3(8, 0, 0)]],
		"spine": [[0.0, Vector3.ZERO], [0.4, Vector3(0, 0, 12)], [0.65, Vector3(0, 0, -28)], [1.1, Vector3.ZERO]],
		"thigh_l": [[0.0, Vector3.ZERO], [0.65, Vector3(0, 0, 25)], [1.1, Vector3.ZERO]],
		"thigh_r": [[0.0, Vector3.ZERO], [0.65, Vector3(0, 0, 25)], [1.1, Vector3.ZERO]],
		"shin_l": [[0.0, Vector3.ZERO], [0.65, Vector3(0, 0, -45)], [1.1, Vector3.ZERO]],
		"shin_r": [[0.0, Vector3.ZERO], [0.65, Vector3(0, 0, -45)], [1.1, Vector3.ZERO]],
	}, {"hips": [[0.0, hp], [0.65, hp - Vector3(0, 7, 0)], [1.1, hp]]}))
	lib.add_animation("die", _clip("die", 2.0, false, {
		"hips": [[0.0, Vector3.ZERO], [0.8, Vector3(40, 0, 10)], [2.0, Vector3(82, 0, 14)]],
		"shoulder_l": [[0.0, Vector3.ZERO], [2.0, Vector3(-60, 0, 30)]],
		"shoulder_r": [[0.0, Vector3.ZERO], [2.0, Vector3(70, 0, 50)]],
		"head": [[0.0, Vector3.ZERO], [2.0, Vector3(25, 0, 10)]],
	}, {"hips": [[0.0, hp], [0.8, Vector3(0, 26, 0)], [2.0, Vector3(0, 12, 0)]]}))
	player.add_animation_library("", lib)


func _part(bone: String, shape: String, size: Vector3, col: Color, offset: Vector3) -> void:
	var ba := BoneAttachment3D.new()
	ba.bone_name = bone
	skeleton.add_child(ba)
	var mi := MeshInstance3D.new()
	mi.mesh = Models.part_mesh(shape, size, col)
	mi.position = offset
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.65
	mi.material_override = mat
	ba.add_child(mi)
	_meshes.append(mi)


func _clip(clip_name: String, length: float, loop: bool, rot: Dictionary, pos: Dictionary) -> Animation:
	var a := Animation.new()
	a.resource_name = clip_name
	a.length = length
	a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	for bone in rot:
		var tr := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(tr, NodePath("Skeleton3D:" + bone))
		for k in rot[bone]:
			a.rotation_track_insert_key(tr, k[0], Quaternion.from_euler((k[1] as Vector3) * (PI / 180.0)))
	for bone in pos:
		var tp := a.add_track(Animation.TYPE_POSITION_3D)
		a.track_set_path(tp, NodePath("Skeleton3D:" + bone))
		for k in pos[bone]:
			a.position_track_insert_key(tp, k[0], k[1])
	return a
