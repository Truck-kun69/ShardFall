class_name Fx3D
extends Node3D
## Projectiles, blades, gems, pickups, ground marks, telegraphs, rings, sparks,
## debris and chain arcs. Every element is placed at ground_y(pos) + offset so it
## drapes on the terrain. MultiMesh buffers are pre-allocated once.

const SPARK_CAP := 256
const RING_CAP := 16
const ARC_CAP := 64
const STRIDE_C := 16   ## 12 transform + 4 colour floats.
const GRAVITY := 620.0

var world: SimWorld
var terrain: Terrain

var _proj: MultiMeshInstance3D
var _blade: MultiMeshInstance3D
var _gem: MultiMeshInstance3D
var _pick: MultiMeshInstance3D
var _spark: MultiMeshInstance3D
var _arc: MultiMeshInstance3D
var _proj_buf := PackedFloat32Array()
var _blade_buf := PackedFloat32Array()
var _gem_buf := PackedFloat32Array()
var _pick_buf := PackedFloat32Array()
var _spark_buf := PackedFloat32Array()
var _arc_buf := PackedFloat32Array()

var decal_mat: ShaderMaterial
var _marks: Array[MeshInstance3D] = []
var _tele: MeshInstance3D
var _rings: Array[MeshInstance3D] = []
var _ring_r := PackedFloat32Array()
var _ring_x := PackedFloat32Array()
var _ring_y := PackedFloat32Array()
var _ring_t := PackedFloat32Array()
var _ring_col := PackedColorArray()
var _ring_next := 0

var sp_n := 0
var sp_x := PackedFloat32Array()
var sp_y := PackedFloat32Array()
var sp_z := PackedFloat32Array()
var sp_vx := PackedFloat32Array()
var sp_vy := PackedFloat32Array()
var sp_vz := PackedFloat32Array()
var sp_life := PackedFloat32Array()
var sp_life0 := PackedFloat32Array()
var sp_size := PackedFloat32Array()
var sp_col := PackedColorArray()

var arc_n := 0
var arc_ax := PackedFloat32Array()
var arc_ay := PackedFloat32Array()
var arc_bx := PackedFloat32Array()
var arc_by := PackedFloat32Array()
var arc_life := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()


func setup(w: SimWorld) -> void:
	world = w
	terrain = w.terrain
	_rng.seed = 7
	var glow := ShaderMaterial.new()
	glow.shader = load("res://shaders/3d/fx_glow.gdshader")
	var proj_mesh := SphereMesh.new()
	proj_mesh.radius = 1.0
	proj_mesh.height = 2.0
	proj_mesh.radial_segments = 8
	proj_mesh.rings = 4
	_proj = _mm(proj_mesh, SimWorld.PROJ_CAP, glow)
	_proj_buf.resize(SimWorld.PROJ_CAP * STRIDE_C)
	var blade_mesh := PrismMesh.new()
	blade_mesh.size = Vector3(24, 3, 6)
	_blade = _mm(blade_mesh, 16, glow)
	_blade_buf.resize(16 * STRIDE_C)
	var gem_mesh := SphereMesh.new()
	gem_mesh.radius = 4.0
	gem_mesh.height = 10.0
	gem_mesh.radial_segments = 4
	gem_mesh.rings = 1
	_gem = _mm(gem_mesh, SimWorld.GEM_CAP, glow)
	_gem_buf.resize(SimWorld.GEM_CAP * STRIDE_C)
	var pick_mesh := SphereMesh.new()
	pick_mesh.radius = 7.0
	pick_mesh.height = 14.0
	pick_mesh.radial_segments = 8
	pick_mesh.rings = 4
	_pick = _mm(pick_mesh, SimWorld.PICK_CAP, glow)
	_pick_buf.resize(SimWorld.PICK_CAP * STRIDE_C)
	var spark_mesh := BoxMesh.new()
	spark_mesh.size = Vector3.ONE
	_spark = _mm(spark_mesh, SPARK_CAP, glow)
	_spark_buf.resize(SPARK_CAP * STRIDE_C)
	var arc_mesh := BoxMesh.new()
	arc_mesh.size = Vector3(1, 1, 1)
	_arc = _mm(arc_mesh, ARC_CAP, glow)
	_arc_buf.resize(ARC_CAP * STRIDE_C)
	sp_x.resize(SPARK_CAP); sp_y.resize(SPARK_CAP); sp_z.resize(SPARK_CAP)
	sp_vx.resize(SPARK_CAP); sp_vy.resize(SPARK_CAP); sp_vz.resize(SPARK_CAP)
	sp_life.resize(SPARK_CAP); sp_life0.resize(SPARK_CAP); sp_size.resize(SPARK_CAP); sp_col.resize(SPARK_CAP)
	arc_ax.resize(ARC_CAP); arc_ay.resize(ARC_CAP); arc_bx.resize(ARC_CAP); arc_by.resize(ARC_CAP); arc_life.resize(ARC_CAP)
	# Draped decals: 8x8 subdivided planes sharing one material (instance uniforms).
	decal_mat = ShaderMaterial.new()
	decal_mat.shader = load("res://shaders/3d/decal.gdshader")
	decal_mat.set_shader_parameter("t_amp", terrain.amp)
	decal_mat.set_shader_parameter("t_seeds", terrain.seeds)
	var dmesh := PlaneMesh.new()
	dmesh.size = Vector2(2, 2)
	dmesh.subdivide_width = 8
	dmesh.subdivide_depth = 8
	for i in SimWorld.MARK_CAP:
		_marks.append(_decal(dmesh))
	_tele = _decal(dmesh)
	for i in RING_CAP:
		_rings.append(_decal(dmesh))
	_ring_r.resize(RING_CAP)
	_ring_x.resize(RING_CAP)
	_ring_y.resize(RING_CAP)
	_ring_t.resize(RING_CAP)
	_ring_col.resize(RING_CAP)
	_ring_t.fill(-1.0)


func _mm(mesh: Mesh, cap: int, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = cap
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-1e5, -1e3, -1e5), Vector3(2e5, 2e3, 2e5))
	add_child(mmi)
	return mmi


func _decal(mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = decal_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = AABB(Vector3(-1.2, -200, -1.2), Vector3(2.4, 400, 2.4))
	mi.visible = false
	add_child(mi)
	return mi


func ground_y(x: float, y: float) -> float:
	return terrain.height(x, y)


static func put_xf(buf: PackedFloat32Array, o: int, yaw: float, sc: float, sy: float, x: float, y: float, z: float) -> void:
	var c := cos(yaw)
	var s := sin(yaw)
	buf[o] = c * sc; buf[o + 1] = 0.0; buf[o + 2] = s * sc; buf[o + 3] = x
	buf[o + 4] = 0.0; buf[o + 5] = sy; buf[o + 6] = 0.0; buf[o + 7] = y
	buf[o + 8] = -s * sc; buf[o + 9] = 0.0; buf[o + 10] = c * sc; buf[o + 11] = z


static func put_col(buf: PackedFloat32Array, o: int, col: Color) -> void:
	buf[o + 12] = col.r; buf[o + 13] = col.g; buf[o + 14] = col.b; buf[o + 15] = col.a


func _upload(mmi: MultiMeshInstance3D, buf: PackedFloat32Array, n: int) -> void:
	RenderingServer.multimesh_set_buffer(mmi.multimesh.get_rid(), buf)
	mmi.multimesh.visible_instance_count = n


# ----------------------------------------------------------------------------
# Events
# ----------------------------------------------------------------------------
func consume(events: Array) -> void:
	for e in events:
		var t: String = e[0]
		var x: float = e[1]
		var y: float = e[2]
		match t:
			"hit":
				_burst(x, y, 14.0, 5, Content.ELEM_COLORS[int(e[5])], 160.0, 0.25, 2.0)
			"die":
				_burst(x, y, 12.0, 8, Color(0.45, 0.40, 0.34), 140.0, 0.6, 3.0)
			"react":
				_burst(x, y, 16.0, 12, Color(0.85, 0.55, 1.0), 220.0, 0.4, 2.5)
				ring(x, y, 80.0, Color(0.8, 0.5, 1.0, 0.7))
			"levelup":
				_burst(x, y, 20.0, 24, Color(1.0, 0.85, 0.35), 260.0, 0.8, 2.5)
				ring(x, y, 120.0, Color(1.0, 0.85, 0.35, 0.8))
			"perfect":
				_burst(x, y, 20.0, 16, Color(0.5, 0.9, 1.0), 240.0, 0.5, 2.5)
				ring(x, y, 90.0, Color(0.5, 0.9, 1.0, 0.9))
			"nova", "ult", "riposte", "bomb":
				var col := Color(1.0, 0.9, 0.6, 0.85) if t != "bomb" else Color(0.8, 0.4, 1.0, 0.85)
				ring(x, y, float(e[5]), col)
			"land":
				ring(x, y, 60.0, Color(0.9, 0.85, 0.75, 0.6))
				_burst(x, y, 3.0, 8, Color(0.55, 0.48, 0.40), 120.0, 0.4, 3.0)
			"boss_slam":
				ring(x, y, Boss.SLAM_R, Color(1.0, 0.4, 0.2, 0.9))
				_burst(x, y, 4.0, 20, Color(0.5, 0.42, 0.36), 260.0, 0.8, 5.0)
			"boss_cleave":
				_burst(x + float(e[3]) * 90.0, y + float(e[4]) * 90.0, 20.0, 14, Color(1.0, 0.6, 0.3), 240.0, 0.4, 3.0)
			"chain":
				_arc_add(x, y, x + float(e[3]), y + float(e[4]))
			"boss_die":
				_burst(x, y, 40.0, 40, Color(1.0, 0.7, 0.4), 320.0, 1.2, 4.0)


func ring(x: float, y: float, r: float, col: Color) -> void:
	var i := _ring_next
	_ring_next = (_ring_next + 1) % RING_CAP
	_ring_r[i] = r
	_ring_x[i] = x
	_ring_y[i] = y
	_ring_t[i] = 0.0
	_ring_col[i] = col


func _burst(x: float, y: float, h: float, n: int, col: Color, spd: float, life: float, size: float) -> void:
	var gy := ground_y(x, y)
	for k in n:
		if sp_n >= SPARK_CAP:
			return
		var i := sp_n
		sp_n += 1
		var a := _rng.randf() * TAU
		var v := spd * (0.4 + 0.6 * _rng.randf())
		sp_x[i] = x
		sp_z[i] = y
		sp_y[i] = gy + h
		sp_vx[i] = cos(a) * v
		sp_vz[i] = sin(a) * v
		sp_vy[i] = spd * (0.4 + 0.8 * _rng.randf())
		sp_life[i] = life * (0.6 + 0.4 * _rng.randf())
		sp_life0[i] = sp_life[i]
		sp_size[i] = size * (0.6 + 0.6 * _rng.randf())
		sp_col[i] = col


func _arc_add(ax: float, ay: float, bx: float, by: float) -> void:
	var i := arc_n
	if arc_n >= ARC_CAP:
		i = _rng.randi_range(0, ARC_CAP - 1)
	else:
		arc_n += 1
	arc_ax[i] = ax; arc_ay[i] = ay; arc_bx[i] = bx; arc_by[i] = by
	arc_life[i] = 0.16


# ----------------------------------------------------------------------------
# Per-frame
# ----------------------------------------------------------------------------
func update(dt: float, alpha: float) -> void:
	var w := world
	var t := w.time + alpha * FixedStep.STEP
	# Projectiles.
	for i in w.pr_n:
		var x := lerpf(w.pr_ox[i], w.pr_x[i], alpha)
		var y := lerpf(w.pr_oy[i], w.pr_y[i], alpha)
		var o := i * STRIDE_C
		var r := w.pr_r[i]
		put_xf(_proj_buf, o, atan2(-w.pr_vy[i], w.pr_vx[i]), r, r * 0.8, x, ground_y(x, y) + 14.0, y)
		var col: Color = Content.ELEM_COLORS[w.pr_elem[i]]
		if w.pr_team[i] == 1:
			col = Color(0.75, 1.0, 0.35)
		put_col(_proj_buf, o, col)
	_upload(_proj, _proj_buf, w.pr_n)
	# Orbiting blades.
	var hp := w.prev_pos.lerp(w.pos, alpha)
	var nb := mini(w.blade_count(), 16)
	for k in nb:
		var bp := hp + w.blade_pos(k, nb, t)
		var o2 := k * STRIDE_C
		var ang := atan2(-(bp.y - hp.y), bp.x - hp.x) - PI * 0.5
		put_xf(_blade_buf, o2, ang, 1.0, 1.0, bp.x, ground_y(bp.x, bp.y) + 16.0, bp.y)
		put_col(_blade_buf, o2, Color(0.95, 0.92, 0.80))
	_upload(_blade, _blade_buf, nb)
	# Gems.
	for i in w.gm_n:
		var gx := lerpf(w.gm_ox[i], w.gm_x[i], alpha)
		var gz := lerpf(w.gm_oy[i], w.gm_y[i], alpha)
		var o3 := i * STRIDE_C
		var big := 1.0 if w.gm_v[i] < 3.0 else 1.6
		put_xf(_gem_buf, o3, t * 2.5 + float(i), big, big, gx, ground_y(gx, gz) + 7.0 + sin(t * 4.0 + float(i)) * 1.5, gz)
		put_col(_gem_buf, o3, Color(0.35, 0.85, 1.0) if w.gm_v[i] < 3.0 else Color(0.9, 0.5, 1.0))
	_upload(_gem, _gem_buf, w.gm_n)
	# Pickups.
	for i in w.pk_n:
		var o4 := i * STRIDE_C
		var px := w.pk_x[i]
		var pz := w.pk_y[i]
		put_xf(_pick_buf, o4, t, 1.0, 1.0, px, ground_y(px, pz) + 10.0 + sin(t * 3.0) * 2.0, pz)
		var pc := Color(0.4, 1.0, 0.5) if w.pk_kind[i] == 0 else (Color(0.4, 0.8, 1.0) if w.pk_kind[i] == 1 else Color(1.0, 0.8, 0.3))
		put_col(_pick_buf, o4, pc)
	_upload(_pick, _pick_buf, w.pk_n)
	# Sparks / debris (CPU integrated, compacted in place).
	var i5 := 0
	while i5 < sp_n:
		sp_life[i5] -= dt
		if sp_life[i5] <= 0.0:
			sp_n -= 1
			sp_x[i5] = sp_x[sp_n]; sp_y[i5] = sp_y[sp_n]; sp_z[i5] = sp_z[sp_n]
			sp_vx[i5] = sp_vx[sp_n]; sp_vy[i5] = sp_vy[sp_n]; sp_vz[i5] = sp_vz[sp_n]
			sp_life[i5] = sp_life[sp_n]; sp_life0[i5] = sp_life0[sp_n]; sp_size[i5] = sp_size[sp_n]; sp_col[i5] = sp_col[sp_n]
			continue
		sp_vy[i5] -= GRAVITY * dt
		sp_x[i5] += sp_vx[i5] * dt
		sp_y[i5] += sp_vy[i5] * dt
		sp_z[i5] += sp_vz[i5] * dt
		var gy := ground_y(sp_x[i5], sp_z[i5]) + 0.8
		if sp_y[i5] < gy:
			sp_y[i5] = gy
			sp_vy[i5] *= -0.3
			sp_vx[i5] *= 0.6
			sp_vz[i5] *= 0.6
		var f := sp_life[i5] / sp_life0[i5]
		var o5 := i5 * STRIDE_C
		var s := sp_size[i5] * (0.4 + 0.6 * f)
		put_xf(_spark_buf, o5, sp_x[i5] * 0.1, s, s, sp_x[i5], sp_y[i5], sp_z[i5])
		var c5: Color = sp_col[i5]
		c5.a = f
		put_col(_spark_buf, o5, c5)
		i5 += 1
	_upload(_spark, _spark_buf, sp_n)
	# Chain arcs.
	var i6 := 0
	while i6 < arc_n:
		arc_life[i6] -= dt
		if arc_life[i6] <= 0.0:
			arc_n -= 1
			arc_ax[i6] = arc_ax[arc_n]; arc_ay[i6] = arc_ay[arc_n]; arc_bx[i6] = arc_bx[arc_n]; arc_by[i6] = arc_by[arc_n]
			arc_life[i6] = arc_life[arc_n]
			continue
		var mx := (arc_ax[i6] + arc_bx[i6]) * 0.5
		var mz := (arc_ay[i6] + arc_by[i6]) * 0.5
		var dx := arc_bx[i6] - arc_ax[i6]
		var dz := arc_by[i6] - arc_ay[i6]
		var ln := sqrt(dx * dx + dz * dz)
		var o6 := i6 * STRIDE_C
		var yaw := atan2(-dz, dx)
		var c := cos(yaw)
		var s6 := sin(yaw)
		var th := 2.2
		_arc_buf[o6] = c * ln; _arc_buf[o6 + 1] = 0.0; _arc_buf[o6 + 2] = s6 * th; _arc_buf[o6 + 3] = mx
		_arc_buf[o6 + 4] = 0.0; _arc_buf[o6 + 5] = th; _arc_buf[o6 + 6] = 0.0; _arc_buf[o6 + 7] = ground_y(mx, mz) + 16.0
		_arc_buf[o6 + 8] = -s6 * ln; _arc_buf[o6 + 9] = 0.0; _arc_buf[o6 + 10] = c * th; _arc_buf[o6 + 11] = mz
		put_col(_arc_buf, o6, Color(1.0, 0.95, 0.5, 1.0))
		i6 += 1
	_upload(_arc, _arc_buf, arc_n)
	# Ground marks.
	for k in SimWorld.MARK_CAP:
		var mi := _marks[k]
		if k >= w.mk_n:
			mi.visible = false
			continue
		mi.visible = true
		var r := w.mk_r[k]
		mi.transform = Transform3D(Basis().scaled(Vector3(r, 1.0, r)), Vector3(w.mk_x[k], 0.0, w.mk_y[k]))
		var mc: Color = Content.ELEM_COLORS[w.mk_elem[k]]
		mc.a = 0.55 * clampf(w.mk_t[k] / 0.4, 0.0, 1.0)
		mi.set_instance_shader_parameter("d_color", mc)
		mi.set_instance_shader_parameter("d_shape", Vector4(0.0, 1.0, TAU, 0.12))
	# Boss telegraph.
	var tg: Dictionary = w.boss.telegraph() if w.boss != null else {}
	if tg.is_empty():
		_tele.visible = false
	else:
		_tele.visible = true
		var tp: Vector2 = tg.pos
		var tr: float = tg.radius
		var dir: Vector2 = tg.dir
		var shape := 0.0
		match String(tg.shape):
			"cone":
				shape = 2.0
			"lane":
				shape = 3.0
		_tele.transform = Transform3D(Basis(Vector3.UP, atan2(-dir.y, dir.x)).scaled(Vector3(tr, 1.0, tr)), Vector3(tp.x, 0.0, tp.y))
		_tele.set_instance_shader_parameter("d_color", Color(1.0, 0.25, 0.15, 0.75))
		_tele.set_instance_shader_parameter("d_shape", Vector4(shape, float(tg.progress), float(tg.arc), 0.1))
	# Expanding rings.
	for k in RING_CAP:
		var rmi := _rings[k]
		if _ring_t[k] < 0.0:
			rmi.visible = false
			continue
		_ring_t[k] += dt
		var p := _ring_t[k] / 0.4
		if p >= 1.0:
			_ring_t[k] = -1.0
			rmi.visible = false
			continue
		rmi.visible = true
		var rr := _ring_r[k] * (0.3 + 0.7 * p)
		rmi.transform = Transform3D(Basis().scaled(Vector3(rr, 1.0, rr)), Vector3(_ring_x[k], 0.0, _ring_y[k]))
		var rc: Color = _ring_col[k]
		rc.a *= 1.0 - p
		rmi.set_instance_shader_parameter("d_color", rc)
		rmi.set_instance_shader_parameter("d_shape", Vector4(1.0, 1.0, TAU, 0.18))
