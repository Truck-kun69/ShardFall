class_name WorldView3D
extends Node3D
## 3D presentation of a SimWorld: terrain, liquid, ground fog, chunked props,
## MultiMesh swarm with contact shadows, hero and boss rigs, FX and lighting.
## Reads simulation state only; interpolates with FixedStep.alpha().

const GROUND_SIZE := 2200.0
const LIGHT_GAIN := 0.6
const CAM_DIST := 600.0
const CAM_PITCH_DEG := 58.0
const CAM_FOV := 42.0
const CELL_BUILD_R := 1250.0
const CELL_FREE_R := 1750.0
const FOE_STRIDE := 16   ## 12 transform + 4 custom.
const BLOB_STRIDE := 16  ## 12 transform + 4 colour.
const SUN_ENERGY := 1.2
const SUN_FLOOR := 0.32
const AMBIENT_FLOOR := 0.22
const VIGNETTE_MAX := 0.35
const CLUTTER := ["bones", "bush", "grass"]
const CULLED := ["bush", "grass"]
const SWAY := {"tree": 0.5, "tree_dead": 0.15, "bush": 1.0, "grass": 1.6}

var world: SimWorld
var terrain: Terrain
var act_data: Dictionary
var dist := CAM_DIST

var camera: Camera3D
var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var key_light: DirectionalLight3D
var torch: OmniLight3D
var ground: MeshInstance3D
var water: MeshInstance3D
var fog: MeshInstance3D
var terrain_mat: ShaderMaterial
var water_mat: ShaderMaterial
var fog_mat: ShaderMaterial
var prop_mat: ShaderMaterial
var vignette: ColorRect
var hero: HeroRig
var _hero_blob: MeshInstance3D
var boss_rig: BossRig
var fx: Fx3D

var _prop_mats := {}
var _cells := {}
var _foe_mm: Array[MultiMeshInstance3D] = []
var _foe_mats: Array[ShaderMaterial] = []
var _foe_bufs: Array[PackedFloat32Array] = []   ## One pre-allocated buffer per archetype.
var _foe_n := PackedInt32Array()
var _blob_mm: MultiMeshInstance3D
var _blob_buf := PackedFloat32Array()
var _cam_target := Vector3.ZERO
var _last_hp := 0.0
var _hurt_fx := 0.0


func setup(w: SimWorld) -> void:
	world = w
	terrain = w.terrain
	act_data = Content.act(w.act)
	_build_environment()
	_build_ground()
	_build_swarm()
	hero = HeroRig.new()
	hero.name = "Hero"
	add_child(hero)
	hero.setup(w.hero_id)
	_hero_blob = MeshInstance3D.new()
	_hero_blob.mesh = Models.quad_mesh(2.0)
	var bm := ShaderMaterial.new()
	bm.shader = load("res://shaders/3d/blob.gdshader")
	bm.set_shader_parameter("strength", 0.6)
	_hero_blob.material_override = bm
	_hero_blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_hero_blob)
	fx = Fx3D.new()
	fx.name = "Fx"
	add_child(fx)
	fx.setup(w)
	_last_hp = w.hp
	_update_cells(Vector2.ZERO, true)
	render(0.0, 1.0)


# ----------------------------------------------------------------------------
# Environment & lighting
# ----------------------------------------------------------------------------
func _build_environment() -> void:
	var a := act_data
	camera = Camera3D.new()
	camera.fov = CAM_FOV
	camera.near = 4.0
	camera.far = 2600.0
	add_child(camera)
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = a.sky_top
	sky_mat.sky_horizon_color = a.sky_horizon
	sky_mat.ground_horizon_color = (a.sky_horizon as Color).darkened(0.35)
	sky_mat.ground_bottom_color = a.ground_bottom
	sky_mat.sun_angle_max = 30.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = maxf(0.55, AMBIENT_FLOOR)
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.25
	env.glow_intensity = 0.45
	env.glow_strength = 1.0
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = a.fog
	env.fog_depth_begin = 700.0
	env.fog_depth_end = 2200.0
	env.fog_depth_curve = 1.6
	camera.environment = env
	sun = DirectionalLight3D.new()
	sun.light_color = a.sun
	sun.light_energy = maxf(SUN_ENERGY, SUN_FLOOR)
	sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	add_child(sun)
	Quality.apply_sun(sun, dist)
	key_light = DirectionalLight3D.new()
	key_light.light_energy = 0.9 * LIGHT_GAIN
	key_light.light_color = Color(0.85, 0.88, 1.0)
	key_light.shadow_enabled = false
	key_light.rotation_degrees = Vector3(-30.0, 160.0, 0.0)
	add_child(key_light)
	torch = OmniLight3D.new()
	torch.light_energy = 1.6 * LIGHT_GAIN
	torch.omni_range = 360.0
	torch.omni_attenuation = 1.3
	torch.light_color = Color(1.0, 0.82, 0.6)
	torch.shadow_enabled = false   # Never on mobile.
	add_child(torch)
	var cl := CanvasLayer.new()
	cl.layer = 0
	add_child(cl)
	vignette = ColorRect.new()
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vm := ShaderMaterial.new()
	vm.shader = load("res://shaders/vignette.gdshader")
	vm.set_shader_parameter("strength", minf(0.28, VIGNETTE_MAX))
	vignette.material = vm
	cl.add_child(vignette)


func _terrain_uniforms(m: ShaderMaterial) -> void:
	m.set_shader_parameter("t_amp", terrain.amp)
	m.set_shader_parameter("t_seeds", terrain.seeds)


func _build_ground() -> void:
	var a := act_data
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/3d/terrain.gdshader")
	_terrain_uniforms(terrain_mat)
	terrain_mat.set_shader_parameter("tex_a", load("res://textures/terrain/ground_moss_albedo.png"))
	terrain_mat.set_shader_parameter("tex_b", load("res://textures/terrain/ground_dirt_albedo.png"))
	terrain_mat.set_shader_parameter("tex_rock", load("res://textures/terrain/ground_rock_albedo.png"))
	terrain_mat.set_shader_parameter("tex_a_n", load("res://textures/terrain/ground_moss_normal.png"))
	terrain_mat.set_shader_parameter("tex_rock_n", load("res://textures/terrain/ground_rock_normal.png"))
	terrain_mat.set_shader_parameter("tex_scale", 0.0085)
	terrain_mat.set_shader_parameter("tint", 0.18)
	terrain_mat.set_shader_parameter("pal_a", a.ground)
	terrain_mat.set_shader_parameter("pal_b", a.ground2)
	terrain_mat.set_shader_parameter("grass_w", 0.7 if terrain.liquid == "water" else 0.25)
	terrain_mat.set_shader_parameter("has_liquid", 1.0 if terrain.has_liquid() else 0.0)
	terrain_mat.set_shader_parameter("liquid_level", terrain.level())
	terrain_mat.set_shader_parameter("patch_color", Color(0.06, 0.05, 0.05) if terrain.patch_kind == "oil" else Color(0.30, 0.26, 0.24))
	terrain_mat.set_shader_parameter("patch_gloss", 1.0 if terrain.patch_kind == "oil" else 0.0)
	ground = MeshInstance3D.new()
	ground.name = "Ground"
	_rebuild_ground_mesh()
	ground.material_override = terrain_mat
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	water_mat = ShaderMaterial.new()
	water_mat.shader = load("res://shaders/3d/water.gdshader")
	water_mat.set_shader_parameter("liquid_color", a.liquid_color)
	water_mat.set_shader_parameter("emissive", 1.0 if terrain.liquid == "lava" else (0.25 if terrain.liquid == "poison" else 0.0))
	water = MeshInstance3D.new()
	water.name = "Water"
	var wm := PlaneMesh.new()
	wm.size = Vector2(GROUND_SIZE, GROUND_SIZE)
	water.mesh = wm
	water.material_override = water_mat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.visible = terrain.liquid != "none"
	add_child(water)
	fog_mat = ShaderMaterial.new()
	fog_mat.shader = load("res://shaders/3d/fog.gdshader")
	_terrain_uniforms(fog_mat)
	fog_mat.set_shader_parameter("fog_color", a.fog)
	fog_mat.set_shader_parameter("density", 0.2)
	fog_mat.set_shader_parameter("radius", 1100.0)
	fog = MeshInstance3D.new()
	fog.name = "GroundFog"
	var fm := PlaneMesh.new()
	fm.size = Vector2(1100.0, 1100.0)
	fm.subdivide_width = 24
	fm.subdivide_depth = 24
	fog.mesh = fm
	fog.material_override = fog_mat
	fog.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fog.custom_aabb = AABB(Vector3(-560, -200, -560), Vector3(1120, 400, 1120))
	add_child(fog)
	prop_mat = _make_prop_mat(0.0)


func _make_prop_mat(sway: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/3d/prop.gdshader")
	m.set_shader_parameter("tint", Color(0.96, 0.95, 0.93))
	m.set_shader_parameter("sway", sway)
	return m


func prop_mat_for(kind: String) -> ShaderMaterial:
	if not SWAY.has(kind):
		return prop_mat
	if not _prop_mats.has(kind):
		_prop_mats[kind] = _make_prop_mat(SWAY[kind])
	return _prop_mats[kind]


func ground_subdivisions() -> int:
	return int(GROUND_SIZE / float(Quality.ground_q())) - 1


func _rebuild_ground_mesh() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(GROUND_SIZE, GROUND_SIZE)
	pm.subdivide_width = ground_subdivisions()
	pm.subdivide_depth = ground_subdivisions()
	ground.mesh = pm
	ground.custom_aabb = AABB(Vector3(-GROUND_SIZE * 0.5, -200, -GROUND_SIZE * 0.5), Vector3(GROUND_SIZE, 400, GROUND_SIZE))


## Re-applies quality-dependent settings after an Options change.
func apply_quality() -> void:
	_rebuild_ground_mesh()
	Quality.apply_sun(sun, dist)
	for c in _cells.keys():
		(_cells[c] as Node).queue_free()
	_cells.clear()
	_update_cells(Vector2(_cam_target.x, _cam_target.z), true)


# ----------------------------------------------------------------------------
# Swarm MultiMeshes
# ----------------------------------------------------------------------------
func _build_swarm() -> void:
	_foe_n.resize(Swarm.KINDS)
	for k in Swarm.KINDS:
		var fb := PackedFloat32Array()
		fb.resize(Swarm.CAP * FOE_STRIDE)
		_foe_bufs.append(fb)
		var kind: String = Content.FOE_ORDER[k]
		var mesh := Models.foe_mesh(kind)
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/3d/foe.gdshader")
		var fd: Dictionary = Content.FOES[kind]
		mat.set_shader_parameter("height", float(fd.height))
		mat.set_shader_parameter("tint_color", fd.color)
		mat.set_shader_parameter("tint_amount", 0.1)
		mat.set_shader_parameter("gait", 1.4 if kind == "runner" else 1.0)
		var tex := Models.foe_textures(kind)
		if tex.has("albedo"):
			mat.set_shader_parameter("has_albedo", true)
			mat.set_shader_parameter("albedo_tex", tex.albedo)
		if tex.has("normal"):
			mat.set_shader_parameter("has_normal", true)
			mat.set_shader_parameter("normal_tex", tex.normal)
		if tex.has("orm"):
			mat.set_shader_parameter("has_orm", true)
			mat.set_shader_parameter("orm_tex", tex.orm)
		if tex.has("vat"):
			var vat: Dictionary = tex.vat
			mat.set_shader_parameter("has_vat", true)
			mat.set_shader_parameter("vat_tex", vat.tex)
			mat.set_shader_parameter("vat_rows", float(vat.frames))
			for clip in ["walk", "attack", "hit", "death", "spawn"]:
				if vat.clips.has(clip):
					var c: Vector3 = vat.clips[clip]
					mat.set_shader_parameter("vat_" + clip, Vector4(c.x, c.y, c.z, float(vat.frames)))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = Swarm.CAP
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Foes_" + kind
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mmi.custom_aabb = AABB(Vector3(-1e5, -1e3, -1e5), Vector3(2e5, 2e3, 2e5))
		add_child(mmi)
		_foe_mm.append(mmi)
		_foe_mats.append(mat)
	var bm := ShaderMaterial.new()
	bm.shader = load("res://shaders/3d/blob.gdshader")
	var bmm := MultiMesh.new()
	bmm.transform_format = MultiMesh.TRANSFORM_3D
	bmm.use_colors = true
	bmm.mesh = Models.quad_mesh(2.0)
	bmm.instance_count = Swarm.CAP + 1
	bmm.visible_instance_count = 0
	_blob_mm = MultiMeshInstance3D.new()
	_blob_mm.name = "ContactShadows"
	_blob_mm.multimesh = bmm
	_blob_mm.material_override = bm
	_blob_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_blob_mm.custom_aabb = AABB(Vector3(-1e5, -1e3, -1e5), Vector3(2e5, 2e3, 2e5))
	add_child(_blob_mm)
	_blob_buf.resize((Swarm.CAP + 1) * BLOB_STRIDE)


static func _status_code(s: Swarm, i: int) -> float:
	if s.elite[i] == 1:
		return 5.0
	if s.st_burn[i] > 0.0:
		return 1.0
	if s.st_chill[i] > 0.0:
		return 2.0
	if s.st_shock[i] > 0.0:
		return 3.0
	if s.st_chaos[i] > 0.0:
		return 4.0
	return 0.0


func _render_swarm(alpha: float) -> int:
	var s := world.swarm
	var hx := world.pos.x
	var hy := world.pos.y
	var nblob := 0
	_foe_n.fill(0)
	# Single pass; each foe is written straight into its archetype's buffer
	# (packed arrays are references, so `buf` aliases the stored buffer).
	for i in s.count:
		if s.used[i] == 0:
			continue
		var k := s.kind[i]
		var buf: PackedFloat32Array = _foe_bufs[k]
		var x := lerpf(s.ox[i], s.px[i], alpha)
		var y := lerpf(s.oy[i], s.py[i], alpha)
		var gy := terrain.height(x, y)
		var yaw := 0.0
		if s.vx[i] * s.vx[i] + s.vy[i] * s.vy[i] > 1.0:
			yaw = atan2(-s.vy[i], s.vx[i])
		else:
			yaw = atan2(-(hy - y), hx - x)
		var sc := 1.4 if s.elite[i] == 1 else 1.0
		var o := _foe_n[k] * FOE_STRIDE
		Fx3D.put_xf(buf, o, yaw, sc, sc, x, gy, y)
		var clip := 0.0
		var prog := 0.0
		if s.alive[i] == 0:
			clip = 3.0
			prog = 1.0 - s.dying[i] / Swarm.DEATH_T
		elif s.spawn_t[i] > 0.0:
			clip = 4.0
			prog = 1.0 - s.spawn_t[i] / Swarm.SPAWN_T
		elif s.kind[i] == Swarm.Kind.CHARGER and s.state[i] == 1:
			clip = 1.0
			prog = 1.0 - s.state_t[i] / 0.6
		elif s.flash[i] > 0.0:
			clip = 2.0
			prog = 1.0 - s.flash[i] / 0.12
		buf[o + 12] = fposmod(s.anim[i], 1.0)
		buf[o + 13] = s.flash[i] / 0.12
		buf[o + 14] = _status_code(s, i)
		buf[o + 15] = clip + clampf(prog, 0.0, 0.999)
		_foe_n[k] += 1
		var bo := nblob * BLOB_STRIDE
		Fx3D.put_xf(_blob_buf, bo, 0.0, s.radius[i] * 1.5, 1.0, x, gy + 0.6, y)
		Fx3D.put_col(_blob_buf, bo, Color(1, 1, 1, 0.5 if clip == 3.0 else 1.0))
		nblob += 1
	var total := 0
	for k in Swarm.KINDS:
		RenderingServer.multimesh_set_buffer(_foe_mm[k].multimesh.get_rid(), _foe_bufs[k])
		_foe_mm[k].multimesh.visible_instance_count = _foe_n[k]
		total += _foe_n[k]
	if world.boss != null:
		var bp := world.boss.prev_pos.lerp(world.boss.pos, alpha)
		var bo2 := nblob * BLOB_STRIDE
		Fx3D.put_xf(_blob_buf, bo2, 0.0, Boss.RADIUS * 1.6, 1.0, bp.x, terrain.height(bp.x, bp.y) + 0.6, bp.y)
		Fx3D.put_col(_blob_buf, bo2, Color(1, 1, 1, 1))
		nblob += 1
	RenderingServer.multimesh_set_buffer(_blob_mm.multimesh.get_rid(), _blob_buf)
	_blob_mm.multimesh.visible_instance_count = nblob
	return total


# ----------------------------------------------------------------------------
# Chunked props
# ----------------------------------------------------------------------------
func _update_cells(center: Vector2, build_all: bool) -> void:
	var c0 := PropLayout.chunk_of(center)
	var built := 0
	for cy in range(c0.y - 2, c0.y + 3):
		for cx in range(c0.x - 2, c0.x + 3):
			var c := Vector2i(cx, cy)
			if _cells.has(c):
				continue
			var cc := Vector2((float(cx) + 0.5) * PropLayout.CHUNK, (float(cy) + 0.5) * PropLayout.CHUNK)
			if cc.distance_to(center) > CELL_BUILD_R:
				continue
			if not build_all and built >= 1:
				continue
			_cells[c] = _build_cell(c)
			built += 1
	for c in _cells.keys():
		var cc2 := Vector2((float(c.x) + 0.5) * PropLayout.CHUNK, (float(c.y) + 0.5) * PropLayout.CHUNK)
		if cc2.distance_to(center) > CELL_FREE_R:
			(_cells[c] as Node).queue_free()
			_cells.erase(c)


## Builds one prop cell: a MultiMeshInstance3D per prop kind. Procedural meshes
## get the neutral prop material; PBR asset meshes keep their own materials.
func _build_cell(c: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.name = "Cell_%d_%d" % [c.x, c.y]
	add_child(node)
	var by_kind := {}
	for s in world.layout.solids(c):
		if not by_kind.has(s[0]):
			by_kind[s[0]] = []
		by_kind[s[0]].append(s)
	for s in world.layout.decor(c, Quality.prop_density()):
		if not by_kind.has(s[0]):
			by_kind[s[0]] = []
		by_kind[s[0]].append(s)
	for kind in by_kind:
		var list: Array = by_kind[kind]
		var mesh := Models.prop_mesh(kind)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = list.size()
		for i in list.size():
			var s: Array = list[i]
			var x: float = s[1]
			var y: float = s[2]
			var sc: float = s[4]
			var basis := Basis(Vector3.UP, -float(s[3])).scaled(Vector3(sc, sc, sc))
			mm.set_instance_transform(i, Transform3D(basis, Vector3(x, terrain.height(x, y) - 1.5, y)))
			mm.set_instance_custom_data(i, Color(fposmod(x * 0.0137 + y * 0.0071, 1.0), fposmod(x * 0.003 - y * 0.011, 1.0), 0, 0))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = String(kind)
		mmi.multimesh = mm
		var mat: Material = null if Models.has_pbr(mesh) else prop_mat_for(kind)
		mmi.material_override = mat
		if kind in CLUTTER:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if kind in CULLED:
			mmi.visibility_range_end = Quality.clutter_cull_distance(dist)
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		node.add_child(mmi)
	return node


func cell_count() -> int:
	return _cells.size()


func cell_node(c: Vector2i) -> Node3D:
	return _cells.get(c, null)


# ----------------------------------------------------------------------------
# Per-frame render
# ----------------------------------------------------------------------------
func render(dt: float, alpha: float) -> void:
	var w := world
	var hp2 := w.prev_pos.lerp(w.pos, alpha)
	var jp := lerpf(w.prev_jump_p, w.jump_p, alpha) if w.airborne() else 0.0
	var gy := terrain.height(hp2.x, hp2.y)
	var lift := SimWorld.jump_lift(jp)
	hero.position = Vector3(hp2.x, gy + lift, hp2.y)
	var vel := (w.pos - w.prev_pos) / FixedStep.STEP
	hero.update(dt, vel, w.facing, w.rolling(), jp, w.cast_pulse, not w.alive)
	hero.set_occluded(w.layout.sweep_high(hp2, Vector2(0, 1), 80.0, 10.0) < 80.0)
	# Contact shadow shrinks with the parabolic jump lift 4*jp*(1-jp)*58.
	var shrink := 1.0 - 0.55 * (lift / SimWorld.JUMP_LIFT)
	var bs := 17.0 * shrink
	_hero_blob.transform = Transform3D(Basis().scaled(Vector3(bs, 1.0, bs)), Vector3(hp2.x, gy + 0.7, hp2.y))
	(_hero_blob.material_override as ShaderMaterial).set_shader_parameter("strength", 0.6 * shrink)
	# Camera & lights follow the hero.
	_cam_target = Vector3(hp2.x, gy, hp2.y)
	var pitch := deg_to_rad(CAM_PITCH_DEG)
	camera.position = _cam_target + Vector3(0.0, dist * sin(pitch), dist * cos(pitch))
	camera.look_at(_cam_target + Vector3(0, 12, 0), Vector3.UP)
	torch.position = _cam_target + Vector3(0, 55, 0)
	var q := float(Quality.ground_q())
	ground.position = Vector3(snappedf(hp2.x, q), 0.0, snappedf(hp2.y, q))
	water.position = Vector3(snappedf(hp2.x, 50.0), terrain.level(), snappedf(hp2.y, 50.0))
	terrain_mat.set_shader_parameter("liquid_level", terrain.level())
	fog.position = Vector3(snappedf(hp2.x, 1100.0 / 24.0), 0.0, snappedf(hp2.y, 1100.0 / 24.0))
	_update_cells(hp2, false)
	_render_swarm(alpha)
	_render_boss(dt, alpha)
	fx.consume(w.events)
	fx.update(dt, alpha)
	if w.hp < _last_hp:
		_hurt_fx = 1.0
	_last_hp = w.hp
	_hurt_fx = maxf(_hurt_fx - dt * 3.0, 0.0)
	(vignette.material as ShaderMaterial).set_shader_parameter("hurt", _hurt_fx)


func _render_boss(dt: float, alpha: float) -> void:
	var b := world.boss
	if b == null:
		return
	if boss_rig == null:
		boss_rig = BossRig.new()
		boss_rig.name = "Boss"
		add_child(boss_rig)
		boss_rig.setup(b.id, Content.BOSSES[b.id].color)
	var p := b.prev_pos.lerp(b.pos, alpha)
	boss_rig.position = Vector3(p.x, terrain.height(p.x, p.y), p.y)
	boss_rig.rotation.y = lerp_angle(boss_rig.rotation.y, atan2(-b.facing.y, b.facing.x), clampf(dt * 8.0, 0.0, 1.0))
	var spd := b.pos.distance_to(b.prev_pos) / FixedStep.STEP
	boss_rig.update_state(dt, b.dead(), b.state == Boss.St.EXECUTE, b.busy(), b.flinch_t > 0.0, spd, b.attacks_done % 2 == 0, b.death_t / Boss.DEATH_T, b.flash)
