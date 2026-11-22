class_name HeroRig
extends Node3D
## Hero animation rig. Loads res://models/heroes/<id>.glb when present (38u tall,
## feet at Y=0, +X forward) or builds a procedural skeleton with real clips.
## AnimationTree graph:
##   idle ─┐
##   walk/run (BlendSpace1D, synced) ─ loco_ts ─┴ move (Blend2, idle independent)
##   ─ cast_up (OneShot, upper-body filter) ─ cast_full (OneShot) ─ roll (OneShot)
##   ─ jump_blend (Blend2 ← jump clip scrubbed through TimeSeek) ─ output

const CAST_RATE := 1.25
const CAST_VIS_CD := 0.45
const YAW_RATE := 14.0
const V_WALK := 70.0
const V_RUN := 150.0
const UPPER_KEYS := ["spine", "chest", "neck", "head", "clavicle", "shoulder", "arm", "hand"]
const CLIP_KEYS := {
	"idle": ["idle"], "walk": ["walk"], "run": ["run"], "cast": ["cast", "attack"],
	"roll": ["roll", "dodge"], "jump": ["jump"], "die": ["die", "death"],
}

var hero_id := "warden"
var procedural := true
var player: AnimationPlayer
var tree: AnimationTree
var skeleton: Skeleton3D
var clips := {}
var upper_bones: Array[String] = []

var cast_up_fires := 0
var cast_full_fires := 0
var cast_full_aborts := 0

var _v_walk := V_WALK
var _v_run := V_RUN
var _spd := 0.0
var _cast_full_active := false
var _cast_full_t := 0.0
var _cast_vis_cd := 0.0
var _rolling := false
var _dead := false
var _last_pulse := -1
var _jump_len := 0.7
var _sil_mat: ShaderMaterial
var _sil := 0.0
var _sil_target := 0.0
var _meshes: Array[MeshInstance3D] = []


func setup(id: String) -> void:
	hero_id = id
	var ps := Models.load_slot("heroes", id)
	if ps != null:
		_setup_asset(ps)
	else:
		_build_procedural()
	clips = map_clips(player.get_animation_list() if player != null else PackedStringArray())
	_build_tree()
	_apply_silhouette()


# ----------------------------------------------------------------------------
# Clip mapping & helpers (static so they are unit-testable)
# ----------------------------------------------------------------------------
## Case-insensitive role -> clip mapping. Missing roles fall back to idle (or
## the first clip). Returns {} for an empty clip list.
static func map_clips(names: PackedStringArray) -> Dictionary:
	var out := {}
	if names.is_empty():
		return out
	for role in CLIP_KEYS:
		for key in CLIP_KEYS[role]:
			if out.has(role):
				break
			for n in names:
				if String(n).to_lower().contains(key):
					out[role] = String(n)
					break
	var fallback: String = out.get("idle", String(names[0]))
	if not out.has("idle"):
		out["idle"] = fallback
	for role in CLIP_KEYS:
		if not out.has(role):
			out[role] = out.get("walk", fallback) if role == "run" else (out.get("run", fallback) if role == "walk" else fallback)
	return out


static func is_upper_bone(bone_name: String) -> bool:
	var n := bone_name.to_lower()
	for k in UPPER_KEYS:
		if n.contains(k):
			return true
	return false


## Continuous locomotion playback rate: 1.0 across the walk..run band, smoothly
## below walk speed and above run speed. No discontinuity anywhere.
func loco_rate(spd: float) -> float:
	var ref := clampf(spd, _v_walk, _v_run)
	return clampf(spd / ref, 0.85, 1.30)


func cast_full_active() -> bool:
	return _cast_full_active


# ----------------------------------------------------------------------------
# Construction
# ----------------------------------------------------------------------------
func _setup_asset(ps: PackedScene) -> void:
	procedural = false
	var inst := ps.instantiate()
	add_child(inst)
	player = _find(inst, "AnimationPlayer") as AnimationPlayer
	skeleton = _find(inst, "Skeleton3D") as Skeleton3D
	_collect_meshes(inst)
	if player == null:
		player = AnimationPlayer.new()
		inst.add_child(player)


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _collect_meshes(n: Node) -> void:
	if n is MeshInstance3D:
		_meshes.append(n)
	for c in n.get_children():
		_collect_meshes(c)


func _build_procedural() -> void:
	procedural = true
	var h: Dictionary = Content.hero(hero_id)
	var body: Color = h.color
	var accent: Color = h.accent
	var skin := Color(0.86, 0.70, 0.56)
	var dark := body.darkened(0.4)
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	add_child(skeleton)
	var bones := [
		["root", "", Vector3.ZERO],
		["hips", "root", Vector3(0, 19, 0)],
		["spine", "hips", Vector3(0, 4, 0)],
		["chest", "spine", Vector3(0, 5, 0)],
		["neck", "chest", Vector3(0, 5.5, 0)],
		["head", "neck", Vector3(0, 1.5, 0)],
		["clavicle_l", "chest", Vector3(0, 4, -2.5)],
		["shoulder_l", "clavicle_l", Vector3(0, 0, -2.8)],
		["arm_l", "shoulder_l", Vector3(0, -6.2, 0)],
		["hand_l", "arm_l", Vector3(0, -5.6, 0)],
		["clavicle_r", "chest", Vector3(0, 4, 2.5)],
		["shoulder_r", "clavicle_r", Vector3(0, 0, 2.8)],
		["arm_r", "shoulder_r", Vector3(0, -6.2, 0)],
		["hand_r", "arm_r", Vector3(0, -5.6, 0)],
		["thigh_l", "hips", Vector3(0, -1, -2.6)],
		["shin_l", "thigh_l", Vector3(0, -8.6, 0)],
		["foot_l", "shin_l", Vector3(0, -8.4, 0)],
		["thigh_r", "hips", Vector3(0, -1, 2.6)],
		["shin_r", "thigh_r", Vector3(0, -8.6, 0)],
		["foot_r", "shin_r", Vector3(0, -8.4, 0)],
	]
	for b in bones:
		var i := skeleton.add_bone(b[0])
		if b[1] != "":
			skeleton.set_bone_parent(i, skeleton.find_bone(b[1]))
		skeleton.set_bone_rest(i, Transform3D(Basis(), b[2]))
	skeleton.reset_bone_poses()
	# Visual parts attached to bones.
	_part("hips", "box", Vector3(7, 5, 10), dark, Vector3(0, 0.5, 0))
	_part("spine", "box", Vector3(6.5, 6, 9), body, Vector3(0, 2.5, 0))
	_part("chest", "box", Vector3(8, 7.5, 12), body, Vector3(0, 2.5, 0))
	_part("chest", "box", Vector3(2.5, 6, 10), accent, Vector3(3.6, 2.2, 0))
	_part("head", "blob", Vector3(3.2, 3.6, 3.2), skin, Vector3(0.4, 2.6, 0))
	_part("head", "box", Vector3(1.0, 0.8, 3.2), Color(0.1, 0.1, 0.12), Vector3(3.3, 3.0, 0))
	match hero_id:
		"warden":
			_part("head", "blob", Vector3(3.6, 2.4, 3.6), accent.darkened(0.2), Vector3(0.2, 4.6, 0))
			_part("hand_l", "box", Vector3(2.0, 10, 8), accent.darkened(0.3), Vector3(0.5, -1.5, -1.6))
			_part("hand_r", "box", Vector3(1.2, 16, 1.6), Color(0.75, 0.75, 0.78), Vector3(0, -7, 0))
		"spark":
			_part("head", "cone", Vector3(3.8, 7.0, 0), body.darkened(0.2), Vector3(0, 4.8, 0))
			_part("hand_r", "box", Vector3(1.0, 22, 1.0), Color(0.45, 0.32, 0.22), Vector3(0, -2, 0))
			_part("hand_r", "blob", Vector3(1.8, 1.8, 1.8), accent, Vector3(0, 9.5, 0))
		"ember":
			_part("head", "blob", Vector3(3.8, 3.0, 3.8), Color(0.55, 0.12, 0.08), Vector3(-0.6, 3.6, 0))
			_part("hand_r", "blob", Vector3(2.0, 2.0, 2.0), accent, Vector3(0, -1, 0))
			_part("hips", "box", Vector3(8, 9, 11), body.darkened(0.2), Vector3(-0.5, -4.5, 0))
		"storm":
			_part("head", "box", Vector3(4.2, 1.8, 4.2), accent.darkened(0.3), Vector3(0, 5.0, 0))
			_part("hand_r", "box", Vector3(1.2, 20, 1.2), Color(0.6, 0.7, 0.75), Vector3(0, -3, 0))
			_part("hand_r", "cone", Vector3(1.8, 5, 0), accent, Vector3(0, 7, 0))
	for side in ["l", "r"]:
		_part("shoulder_" + side, "limb", Vector3(1.5, 6.2, 1.9), body, Vector3.ZERO)
		_part("arm_" + side, "limb", Vector3(1.2, 5.6, 1.5), skin.darkened(0.05), Vector3.ZERO)
		_part("hand_" + side, "blob", Vector3(1.5, 1.6, 1.4), skin, Vector3.ZERO)
		_part("thigh_" + side, "limb", Vector3(2.0, 8.6, 2.5), dark, Vector3.ZERO)
		_part("shin_" + side, "limb", Vector3(1.6, 8.4, 2.0), dark.lightened(0.08), Vector3.ZERO)
		_part("foot_" + side, "box", Vector3(5.0, 2.0, 3.0), Color(0.22, 0.17, 0.14), Vector3(1.4, 1.0, 0))
	player = AnimationPlayer.new()
	player.name = "AnimationPlayer"
	add_child(player)
	var lib := AnimationLibrary.new()
	for a in _procedural_clips():
		lib.add_animation(a.resource_name, a)
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
	mat.roughness = 0.72
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
			var e: Vector3 = k[1]
			a.rotation_track_insert_key(tr, k[0], Quaternion.from_euler(e * (PI / 180.0)))
	for bone in pos:
		var tp := a.add_track(Animation.TYPE_POSITION_3D)
		a.track_set_path(tp, NodePath("Skeleton3D:" + bone))
		for k in pos[bone]:
			a.position_track_insert_key(tp, k[0], k[1])
	return a


static func _z(t: float, deg: float, x: float = 0.0, y: float = 0.0) -> Array:
	return [t, Vector3(x, y, deg)]


func _procedural_clips() -> Array:
	var out := []
	var hp := Vector3(0, 19, 0)
	out.append(_clip("idle", 1.6, true, {
		"chest": [_z(0.0, 0.0), _z(0.8, -2.5), _z(1.6, 0.0)],
		"shoulder_l": [_z(0.0, 3.0, -6.0), _z(0.8, 1.0, -7.0), _z(1.6, 3.0, -6.0)],
		"shoulder_r": [_z(0.0, 3.0, 6.0), _z(0.8, 1.0, 7.0), _z(1.6, 3.0, 6.0)],
		"arm_l": [_z(0.0, 10.0), _z(1.6, 10.0)],
		"arm_r": [_z(0.0, 10.0), _z(1.6, 10.0)],
	}, {"hips": [[0.0, hp], [0.8, hp - Vector3(0, 0.25, 0)], [1.6, hp]]}))
	out.append(_clip("walk", 0.9, true, {
		"thigh_l": [_z(0.0, 26.0), _z(0.45, -26.0), _z(0.9, 26.0)],
		"thigh_r": [_z(0.0, -26.0), _z(0.45, 26.0), _z(0.9, -26.0)],
		"shin_l": [_z(0.0, -6.0), _z(0.225, -8.0), _z(0.45, -10.0), _z(0.675, -38.0), _z(0.9, -6.0)],
		"shin_r": [_z(0.0, -10.0), _z(0.225, -38.0), _z(0.45, -6.0), _z(0.675, -8.0), _z(0.9, -10.0)],
		"shoulder_l": [_z(0.0, -20.0, -6.0), _z(0.45, 20.0, -6.0), _z(0.9, -20.0, -6.0)],
		"shoulder_r": [_z(0.0, 20.0, 6.0), _z(0.45, -20.0, 6.0), _z(0.9, 20.0, 6.0)],
		"arm_l": [_z(0.0, 12.0), _z(0.9, 12.0)],
		"arm_r": [_z(0.0, 12.0), _z(0.9, 12.0)],
		"spine": [_z(0.0, -4.0), _z(0.9, -4.0)],
	}, {"hips": [[0.0, hp], [0.225, hp - Vector3(0, 0.8, 0)], [0.45, hp], [0.675, hp - Vector3(0, 0.8, 0)], [0.9, hp]]}))
	out.append(_clip("run", 0.6, true, {
		"thigh_l": [_z(0.0, 46.0), _z(0.3, -40.0), _z(0.6, 46.0)],
		"thigh_r": [_z(0.0, -40.0), _z(0.3, 46.0), _z(0.6, -40.0)],
		"shin_l": [_z(0.0, -12.0), _z(0.15, -20.0), _z(0.3, -18.0), _z(0.45, -85.0), _z(0.6, -12.0)],
		"shin_r": [_z(0.0, -18.0), _z(0.15, -85.0), _z(0.3, -12.0), _z(0.45, -20.0), _z(0.6, -18.0)],
		"shoulder_l": [_z(0.0, -38.0, -8.0), _z(0.3, 38.0, -8.0), _z(0.6, -38.0, -8.0)],
		"shoulder_r": [_z(0.0, 38.0, 8.0), _z(0.3, -38.0, 8.0), _z(0.6, 38.0, 8.0)],
		"arm_l": [_z(0.0, 55.0), _z(0.6, 55.0)],
		"arm_r": [_z(0.0, 55.0), _z(0.6, 55.0)],
		"spine": [_z(0.0, -14.0), _z(0.6, -14.0)],
	}, {"hips": [[0.0, hp], [0.15, hp - Vector3(0, 1.4, 0)], [0.3, hp], [0.45, hp - Vector3(0, 1.4, 0)], [0.6, hp]]}))
	out.append(_clip("cast", 0.8, false, {
		"shoulder_r": [_z(0.0, 0.0, 6.0), _z(0.2, 150.0, 10.0), _z(0.45, 95.0, 4.0), _z(0.8, 0.0, 6.0)],
		"arm_r": [_z(0.0, 0.0), _z(0.2, 60.0), _z(0.45, 5.0), _z(0.8, 0.0)],
		"shoulder_l": [_z(0.0, 0.0, -6.0), _z(0.2, -25.0, -14.0), _z(0.8, 0.0, -6.0)],
		"chest": [[0.0, Vector3.ZERO], [0.2, Vector3(0, 20, 4)], [0.45, Vector3(0, -15, -6)], [0.8, Vector3.ZERO]],
		"spine": [_z(0.0, 0.0), _z(0.2, 6.0), _z(0.45, -10.0), _z(0.8, 0.0)],
		"head": [_z(0.0, 0.0), _z(0.45, -6.0), _z(0.8, 0.0)],
	}, {}))
	out.append(_clip("roll", 0.5, false, {
		"hips": [_z(0.0, 0.0), _z(0.125, -90.0), _z(0.25, -180.0), _z(0.375, -270.0), _z(0.5, -360.0)],
		"thigh_l": [_z(0.0, 0.0), _z(0.08, 85.0), _z(0.42, 85.0), _z(0.5, 0.0)],
		"thigh_r": [_z(0.0, 0.0), _z(0.08, 80.0), _z(0.42, 80.0), _z(0.5, 0.0)],
		"shin_l": [_z(0.0, 0.0), _z(0.08, -110.0), _z(0.42, -110.0), _z(0.5, 0.0)],
		"shin_r": [_z(0.0, 0.0), _z(0.08, -105.0), _z(0.42, -105.0), _z(0.5, 0.0)],
		"spine": [_z(0.0, 0.0), _z(0.08, -30.0), _z(0.42, -30.0), _z(0.5, 0.0)],
		"shoulder_l": [_z(0.0, 0.0), _z(0.08, 70.0), _z(0.42, 70.0), _z(0.5, 0.0)],
		"shoulder_r": [_z(0.0, 0.0), _z(0.08, 70.0), _z(0.42, 70.0), _z(0.5, 0.0)],
	}, {"hips": [[0.0, hp], [0.25, Vector3(0, 10, 0)], [0.5, hp]]}))
	out.append(_clip("jump", 0.7, false, {
		"thigh_l": [_z(0.0, 26.0), _z(0.15, -10.0), _z(0.35, 62.0), _z(0.55, 20.0), _z(0.7, 30.0)],
		"thigh_r": [_z(0.0, 24.0), _z(0.15, -14.0), _z(0.35, 56.0), _z(0.55, 16.0), _z(0.7, 28.0)],
		"shin_l": [_z(0.0, -52.0), _z(0.15, -6.0), _z(0.35, -84.0), _z(0.55, -22.0), _z(0.7, -56.0)],
		"shin_r": [_z(0.0, -50.0), _z(0.15, -4.0), _z(0.35, -78.0), _z(0.55, -18.0), _z(0.7, -52.0)],
		"spine": [_z(0.0, -12.0), _z(0.15, 4.0), _z(0.35, -16.0), _z(0.55, -4.0), _z(0.7, -12.0)],
		"shoulder_l": [_z(0.0, -30.0, -8.0), _z(0.15, 60.0, -20.0), _z(0.35, 30.0, -30.0), _z(0.55, 10.0, -20.0), _z(0.7, -10.0, -8.0)],
		"shoulder_r": [_z(0.0, -30.0, 8.0), _z(0.15, 60.0, 20.0), _z(0.35, 30.0, 30.0), _z(0.55, 10.0, 20.0), _z(0.7, -10.0, 8.0)],
	}, {"hips": [[0.0, Vector3(0, 16, 0)], [0.15, hp], [0.35, hp + Vector3(0, 1, 0)], [0.55, hp], [0.7, Vector3(0, 16.5, 0)]]}))
	out.append(_clip("die", 1.2, false, {
		"hips": [_z(0.0, 0.0), _z(0.5, 45.0), _z(1.2, 86.0)],
		"shoulder_l": [_z(0.0, 0.0), _z(0.4, 60.0, -30.0), _z(1.2, 120.0, -40.0)],
		"shoulder_r": [_z(0.0, 0.0), _z(0.4, 50.0, 30.0), _z(1.2, 110.0, 40.0)],
		"head": [_z(0.0, 0.0), _z(1.2, 20.0)],
		"thigh_l": [_z(0.0, 0.0), _z(1.2, 20.0)],
		"thigh_r": [_z(0.0, 0.0), _z(1.2, 35.0)],
		"shin_l": [_z(0.0, 0.0), _z(1.2, -30.0)],
	}, {"hips": [[0.0, hp], [0.5, Vector3(0, 9, 0)], [1.2, Vector3(0, 4, 0)]]}))
	return out


func _build_tree() -> void:
	if player == null or clips.is_empty():
		# Guard: no clips at all (e.g. a static mesh dropped into the slot).
		tree = null
		return
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("idle", _anim_node("idle"), Vector2(0, 0))
	var bs := AnimationNodeBlendSpace1D.new()
	bs.min_space = 0.0
	bs.max_space = 1.0
	bs.add_blend_point(_anim_node("walk"), 0.0, -1, &"walk")
	bs.add_blend_point(_anim_node("run"), 1.0, -1, &"run")
	bs.sync = true
	bt.add_node("loco", bs, Vector2(0, 200))
	bt.add_node("loco_ts", AnimationNodeTimeScale.new(), Vector2(200, 200))
	bt.connect_node("loco_ts", 0, "loco")
	var mv := AnimationNodeBlend2.new()
	mv.sync = false
	bt.add_node("move", mv, Vector2(400, 100))
	bt.connect_node("move", 0, "idle")
	bt.connect_node("move", 1, "loco_ts")
	# Upper-body cast (while moving).
	var cu := AnimationNodeOneShot.new()
	cu.fadein_time = 0.06
	cu.fadeout_time = 0.12
	cu.filter_enabled = true
	upper_bones.clear()
	if skeleton != null:
		var skel_path := str(player.get_parent().get_path_to(skeleton))
		for i in skeleton.get_bone_count():
			var bn := skeleton.get_bone_name(i)
			if is_upper_bone(bn):
				upper_bones.append(bn)
				cu.set_filter_path(NodePath(skel_path + ":" + bn), true)
	bt.add_node("cast_up", cu, Vector2(600, 100))
	bt.add_node("cast_anim_up", _anim_node("cast"), Vector2(400, 300))
	bt.add_node("cast_ts_up", AnimationNodeTimeScale.new(), Vector2(500, 300))
	bt.connect_node("cast_ts_up", 0, "cast_anim_up")
	bt.connect_node("cast_up", 0, "move")
	bt.connect_node("cast_up", 1, "cast_ts_up")
	# Full-body cast (while standing).
	var cf := AnimationNodeOneShot.new()
	cf.fadein_time = 0.08
	cf.fadeout_time = 0.15
	bt.add_node("cast_full", cf, Vector2(800, 100))
	bt.add_node("cast_anim_full", _anim_node("cast"), Vector2(600, 300))
	bt.add_node("cast_ts_full", AnimationNodeTimeScale.new(), Vector2(700, 300))
	bt.connect_node("cast_ts_full", 0, "cast_anim_full")
	bt.connect_node("cast_full", 0, "cast_up")
	bt.connect_node("cast_full", 1, "cast_ts_full")
	# Roll.
	var ro := AnimationNodeOneShot.new()
	ro.fadein_time = 0.03
	ro.fadeout_time = 0.08
	bt.add_node("roll", ro, Vector2(1000, 100))
	bt.add_node("roll_anim", _anim_node("roll"), Vector2(800, 300))
	bt.add_node("roll_ts", AnimationNodeTimeScale.new(), Vector2(900, 300))
	bt.connect_node("roll_ts", 0, "roll_anim")
	bt.connect_node("roll", 0, "cast_full")
	bt.connect_node("roll", 1, "roll_ts")
	# Jump: the real clip, frozen (scale 0) and scrubbed by jump_progress().
	bt.add_node("jump_anim", _anim_node("jump"), Vector2(1000, 300))
	bt.add_node("jump_ts", AnimationNodeTimeScale.new(), Vector2(1100, 300))
	bt.add_node("jump_seek", AnimationNodeTimeSeek.new(), Vector2(1200, 300))
	bt.connect_node("jump_ts", 0, "jump_anim")
	bt.connect_node("jump_seek", 0, "jump_ts")
	bt.add_node("jump_blend", AnimationNodeBlend2.new(), Vector2(1300, 100))
	bt.connect_node("jump_blend", 0, "roll")
	bt.connect_node("jump_blend", 1, "jump_seek")
	bt.connect_node("output", 0, "jump_blend")
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	tree.tree_root = bt
	player.get_parent().add_child(tree)
	tree.anim_player = tree.get_path_to(player)
	tree.active = true
	var cast_len := player.get_animation(clips.cast).length
	var roll_len := player.get_animation(clips.roll).length
	_jump_len = player.get_animation(clips.jump).length
	player.get_animation(clips.die).loop_mode = Animation.LOOP_NONE
	tree.set("parameters/loco_ts/scale", 1.0)
	tree.set("parameters/cast_ts_up/scale", CAST_RATE)
	tree.set("parameters/cast_ts_full/scale", CAST_RATE)
	tree.set("parameters/roll_ts/scale", roll_len / SimWorld.ROLL_TIME)
	tree.set("parameters/jump_ts/scale", 0.0)
	tree.set("parameters/jump_blend/blend_amount", 0.0)
	tree.set("parameters/move/blend_amount", 0.0)
	_cast_full_t = cast_len / CAST_RATE


func _anim_node(role: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = clips.get(role, clips.idle)
	return a


func _apply_silhouette() -> void:
	_sil_mat = ShaderMaterial.new()
	_sil_mat.shader = load("res://shaders/3d/silhouette.gdshader")
	_sil_mat.set_shader_parameter("intensity", 0.0)
	for mi in _meshes:
		mi.material_overlay = _sil_mat


# ----------------------------------------------------------------------------
# Runtime
# ----------------------------------------------------------------------------
## Shows the silhouette when the hero is occluded by a tall prop.
func set_occluded(on: bool) -> void:
	_sil_target = 1.0 if on else 0.0


func request_cast() -> void:
	if tree == null or _cast_vis_cd > 0.0:
		return
	_cast_vis_cd = CAST_VIS_CD
	if _spd > _v_walk * 0.35:
		tree.set("parameters/cast_up/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		cast_up_fires += 1
	else:
		tree.set("parameters/cast_full/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		_cast_full_active = true
		_cast_full_t = player.get_animation(clips.cast).length / CAST_RATE
		cast_full_fires += 1


## Per-frame update from interpolated sim state.
func update(dt: float, vel: Vector2, facing: Vector2, rolling: bool, jump_p: float, cast_pulse: int, dead: bool) -> void:
	_spd = vel.length()
	_cast_vis_cd = maxf(_cast_vis_cd - dt, 0.0)
	if dead:
		if not _dead:
			_dead = true
			if tree != null:
				tree.active = false
			if player != null and clips.has("die"):
				player.play(clips.die)
		return
	if facing.length_squared() > 0.0001:
		var target := atan2(-facing.y, facing.x)
		rotation.y = lerp_angle(rotation.y, target, clampf(dt * YAW_RATE, 0.0, 1.0))
	_sil = move_toward(_sil, _sil_target, dt * 5.0)
	if _sil_mat != null:
		_sil_mat.set_shader_parameter("intensity", _sil)
	if tree == null:
		return
	var move_amt := smoothstep(0.0, _v_walk * 0.35, _spd)
	tree.set("parameters/move/blend_amount", move_amt)
	tree.set("parameters/loco/blend_position", clampf((_spd - _v_walk) / (_v_run - _v_walk), 0.0, 1.0))
	tree.set("parameters/loco_ts/scale", loco_rate(_spd))
	if _last_pulse == -1:
		_last_pulse = cast_pulse
	elif cast_pulse != _last_pulse:
		_last_pulse = cast_pulse
		request_cast()
	if _cast_full_active:
		_cast_full_t -= dt
		if _cast_full_t <= 0.0:
			_cast_full_active = false
		elif _spd > _v_walk * 0.35:
			# Started moving mid full-body cast: fade it out, never replay cast_up.
			tree.set("parameters/cast_full/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
			_cast_full_active = false
			cast_full_aborts += 1
	if rolling and not _rolling:
		tree.set("parameters/roll/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_rolling = rolling
	if jump_p > 0.0:
		tree.set("parameters/jump_blend/blend_amount", 1.0)
		tree.set("parameters/jump_seek/seek_request", clampf(jump_p, 0.0, 1.0) * _jump_len)
	else:
		tree.set("parameters/jump_blend/blend_amount", 0.0)
