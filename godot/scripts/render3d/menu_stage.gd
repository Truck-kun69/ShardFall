class_name MenuStage3D
extends Node3D
## Visible 3D backdrop for the main menu: the selected hero idling on a small
## ruin platform under the act's sky, lit by sun + key light.

const LIGHT_GAIN := 1.0

var camera: Camera3D
var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var key_light: OmniLight3D
var hero: HeroRig
var _pivot: Node3D
var _hero_id := ""
var _t := 0.0
var _props: Node3D


func _ready() -> void:
	camera = Camera3D.new()
	camera.fov = 36.0
	camera.position = Vector3(-15, 30, 105)
	add_child(camera)
	camera.look_at(Vector3(-21, 19, 0))
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.25
	env.glow_intensity = 0.45
	camera.environment = env
	sun = DirectionalLight3D.new()
	sun.light_energy = 1.2
	sun.rotation_degrees = Vector3(-40, -50, 0)
	sun.shadow_enabled = Quality.tier != Quality.Tier.LOW
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 400.0
	add_child(sun)
	key_light = OmniLight3D.new()
	key_light.light_energy = 0.9 * LIGHT_GAIN
	key_light.omni_range = 160.0
	key_light.light_color = Color(1.0, 0.85, 0.65)
	key_light.position = Vector3(10, 50, 50)
	key_light.shadow_enabled = false
	add_child(key_light)
	_pivot = Node3D.new()
	_pivot.position = Vector3(-45, 0, 0)
	add_child(_pivot)
	var plat := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 34.0
	cm.bottom_radius = 38.0
	cm.height = 6.0
	cm.radial_segments = 12
	plat.mesh = cm
	plat.position = Vector3(0, -3, 0)
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.36, 0.34, 0.32)
	pm.roughness = 0.9
	plat.material_override = pm
	_pivot.add_child(plat)
	_props = Node3D.new()
	add_child(_props)
	var pmat := ShaderMaterial.new()
	pmat.shader = load("res://shaders/3d/prop.gdshader")
	pmat.set_shader_parameter("tint", Color(0.96, 0.95, 0.93))
	var placements := [["arch", Vector3(-70, 0, -170), 0.3], ["pillar", Vector3(-150, 0, -95), 0.0], ["tree", Vector3(70, 0, -230), 0.0],
		["rock", Vector3(30, 0, -70), 1.2], ["tree_dead", Vector3(-190, 0, -200), 0.8], ["bush", Vector3(-110, 0, -40), 0.0],
		["wall", Vector3(40, 0, -320), 0.2], ["grass", Vector3(-80, 0, -20), 0.0], ["grass", Vector3(-20, 0, -25), 1.0]]
	for p in placements:
		var mi := MeshInstance3D.new()
		var mesh := Models.prop_mesh(p[0])
		mi.mesh = mesh
		if not Models.has_pbr(mesh):
			mi.material_override = pmat
		mi.position = p[1]
		mi.rotation.y = p[2]
		_props.add_child(mi)
	var ground := MeshInstance3D.new()
	var gm := PlaneMesh.new()
	gm.size = Vector2(900, 900)
	ground.mesh = gm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_texture = load("res://textures/terrain/ground_moss_albedo.png")
	gmat.uv1_scale = Vector3(6, 6, 6)
	gmat.roughness = 0.95
	ground.material_override = gmat
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ground.position = Vector3(0, -0.5, -150)
	add_child(ground)
	set_act(0)


func set_act(i: int) -> void:
	var a := Content.act(i)
	sky_mat.sky_top_color = a.sky_top
	sky_mat.sky_horizon_color = a.sky_horizon
	sky_mat.ground_bottom_color = a.ground_bottom
	sky_mat.ground_horizon_color = (a.sky_horizon as Color).darkened(0.35)
	sun.light_color = a.sun


func set_hero(id: String) -> void:
	if id == _hero_id:
		return
	_hero_id = id
	if hero != null:
		hero.queue_free()
	hero = HeroRig.new()
	_pivot.add_child(hero)
	hero.setup(id)
	hero.rotation.y = -PI * 0.4


func activate(on: bool) -> void:
	visible = on
	camera.current = on


func _process(dt: float) -> void:
	if not visible or hero == null:
		return
	_t += dt
	# Face the camera (+Z in 3D is +y in sim space) with a slow idle sway.
	hero.update(dt, Vector2.ZERO, Vector2(0.35 + sin(_t * 0.4) * 0.35, 1.0).normalized(), false, 0.0, 0, false)
