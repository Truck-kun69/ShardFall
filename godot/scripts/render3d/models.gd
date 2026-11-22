class_name Models
extends RefCounted
## Asset slots + procedural fallbacks.
## A connector-produced GLB dropped into res://models/{heroes,bosses,foes,props}/
## replaces the procedural mesh automatically. With no assets present every
## mesh is built here (flat-shaded, vertex-coloured, $0 spend).

const PROP_HEIGHT := {
	"tree": 130.0, "tree_dead": 125.0, "arch": 120.0, "pillar": 95.0, "wall": 65.0,
	"rock": 38.0, "bush": 26.0, "bones": 22.0, "grass": 14.0,
}
const HERO_HEIGHT := 38.0
const BOSS_HEIGHT := 88.0

static var _cache := {}
static var _rng := RandomNumberGenerator.new()


static func slot_path(cat: String, id: String) -> String:
	return "res://models/%s/%s.glb" % [cat, id]


static func has_slot(cat: String, id: String) -> bool:
	return ResourceLoader.exists(slot_path(cat, id))


static func load_slot(cat: String, id: String) -> PackedScene:
	var p := slot_path(cat, id)
	if ResourceLoader.exists(p):
		return load(p) as PackedScene
	return null


static func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null


## Extracts the first mesh of an imported asset. Surface override materials are
## copied onto the Mesh surfaces BEFORE the scene nodes are freed, so PBR
## materials authored on the node survive.
static func mesh_from_asset(ps: PackedScene) -> Mesh:
	if ps == null:
		return null
	var root := ps.instantiate()
	var mi := _find_mesh(root)
	var out: Mesh = null
	if mi != null:
		var m: Mesh = mi.mesh.duplicate()
		for s in m.get_surface_count():
			var ov: Material = mi.get_surface_override_material(s)
			if ov == null and mi.material_override != null:
				ov = mi.material_override
			if ov != null:
				m.surface_set_material(s, ov)
		out = m
	root.free()
	return out


## True only when EVERY surface carries its own PBR material.
static func has_pbr(m: Mesh) -> bool:
	if m == null or m.get_surface_count() == 0:
		return false
	for s in m.get_surface_count():
		var mat := m.surface_get_material(s)
		if mat is ShaderMaterial:
			continue
		if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
			continue
		return false
	return true


static func prop_mesh(kind: String) -> Mesh:
	var key := "prop:" + kind
	if _cache.has(key):
		return _cache[key]
	var m: Mesh = null
	if has_slot("props", kind):
		m = mesh_from_asset(load_slot("props", kind))
	if m == null:
		m = _proc_prop(kind)
	_cache[key] = m
	return m


static func foe_mesh(kind: String) -> Mesh:
	var key := "foe:" + kind
	if _cache.has(key):
		return _cache[key]
	var m: Mesh = null
	if has_slot("foes", kind):
		m = mesh_from_asset(load_slot("foes", kind))
	if m == null:
		m = _proc_foe(kind)
	_cache[key] = m
	return m


## Optional per-foe PBR textures + SVA3 vertex animation.
static func foe_textures(kind: String) -> Dictionary:
	var out := {}
	for ch in ["albedo", "normal", "orm"]:
		var p := "res://models/foes/%s_%s.png" % [kind, ch]
		if ResourceLoader.exists(p):
			out[ch] = load(p)
	var vp := "res://models/foes/%s.vat" % kind
	if FileAccess.file_exists(vp):
		var vat := load_vat(vp)
		if not vat.is_empty():
			out["vat"] = vat
	return out


## SVA3 vertex-animation file: "SVA3", u32 version, u32 verts, u32 clips,
## clips x {char[16] name, u32 start, u32 frames, f32 fps}, then f32 xyz offsets
## [total_frames][verts]. Returned as an RGBA float texture (x = vertex column
## read from UV2.x, y = frame row).
static func load_vat(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	if f.get_buffer(4).get_string_from_ascii() != "SVA3":
		return {}
	f.get_32()
	var verts := f.get_32()
	var nclips := f.get_32()
	var clips := {}
	var total := 0
	for c in nclips:
		var nm := f.get_buffer(16).get_string_from_ascii().strip_edges()
		var start := f.get_32()
		var frames := f.get_32()
		var fps := f.get_float()
		clips[nm] = Vector3(start, frames, fps)
		total = maxi(total, int(start + frames))
	var img := Image.create_empty(verts, total, false, Image.FORMAT_RGBAF)
	for fr in total:
		for v in verts:
			img.set_pixel(v, fr, Color(f.get_float(), f.get_float(), f.get_float(), 1.0))
	return {"tex": ImageTexture.create_from_image(img), "clips": clips, "frames": total, "verts": verts}


# ============================================================================
# Procedural mesh builder (flat-shaded, outward-oriented triangles)
# ============================================================================
static func _mb() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(), "uv": PackedVector2Array()}


## Adds one triangle facing away from `inside`.
static func _tri(b: Dictionary, p0: Vector3, p1: Vector3, p2: Vector3, col: Color, inside: Vector3) -> void:
	var n := (p1 - p0).cross(p2 - p0)
	if n.length_squared() < 1e-10:
		return
	n = n.normalized()
	var ctr := (p0 + p1 + p2) / 3.0
	var outward := n if n.dot(ctr - inside) >= 0.0 else -n
	# Godot front faces wind clockwise: (p1-p0)x(p2-p0) must point inward.
	if n.dot(outward) > 0.0:
		var t := p1
		p1 = p2
		p2 = t
	var lin := col.srgb_to_linear()   # vertex colours are authored in sRGB
	for p in [p0, p1, p2]:
		b.v.append(p)
		b.n.append(outward)
		b.c.append(lin)
		b.uv.append(Vector2(p.x, p.z) * 0.02)


## Double-sided quad (for grass blades and cloth).
static func _quad2(b: Dictionary, a: Vector3, c: Vector3, d: Vector3, e: Vector3, col: Color) -> void:
	var n := (c - a).cross(d - a).normalized()
	_tri(b, a, c, d, col, (a + c + d) / 3.0 - n)
	_tri(b, a, d, e, col, (a + d + e) / 3.0 - n)
	_tri(b, a, c, d, col, (a + c + d) / 3.0 + n)
	_tri(b, a, d, e, col, (a + d + e) / 3.0 + n)


static func _frustum(b: Dictionary, base: Vector3, r0: float, r1: float, h: float, seg: int, col: Color, col_top: Color = Color(0, 0, 0, 0), tilt: Vector3 = Vector3.ZERO) -> void:
	var ct := col if col_top.a == 0.0 else col_top
	var top := base + Vector3(0, h, 0) + tilt
	var inside := base + Vector3(0, h * 0.5, 0) + tilt * 0.5
	for i in seg:
		var a0 := float(i) / float(seg) * TAU
		var a1 := float(i + 1) / float(seg) * TAU
		var p0 := base + Vector3(cos(a0) * r0, 0, sin(a0) * r0)
		var p1 := base + Vector3(cos(a1) * r0, 0, sin(a1) * r0)
		var q0 := top + Vector3(cos(a0) * r1, 0, sin(a0) * r1)
		var q1 := top + Vector3(cos(a1) * r1, 0, sin(a1) * r1)
		_tri(b, p0, p1, q1, col, inside)
		if r1 > 0.01:
			_tri(b, p0, q1, q0, ct, inside)
			_tri(b, top, q0, q1, ct, inside)
		_tri(b, base, p1, p0, col.darkened(0.2), inside)


static func _box(b: Dictionary, ctr: Vector3, size: Vector3, col: Color, yaw: float = 0.0, roll: float = 0.0) -> void:
	var bas := Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, roll)
	var hs := size * 0.5
	var c := []
	for i in 8:
		var o := Vector3(hs.x if (i & 1) else -hs.x, hs.y if (i & 2) else -hs.y, hs.z if (i & 4) else -hs.z)
		c.append(ctr + bas * o)
	var faces := [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
	for f in faces:
		var shade := col.lightened(0.06) if f == faces[3] else col
		_tri(b, c[f[0]], c[f[1]], c[f[2]], shade, ctr)
		_tri(b, c[f[0]], c[f[2]], c[f[3]], shade, ctr)


static func _blob(b: Dictionary, ctr: Vector3, rad: Vector3, col: Color, seed_v: int, rough: float = 0.18, lat: int = 5, lon: int = 8) -> void:
	_rng.seed = seed_v
	var rows := []
	for i in lat + 1:
		var row := []
		var th := float(i) / float(lat) * PI
		for j in lon:
			var ph := float(j) / float(lon) * TAU
			var dir := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			var j_ := 1.0 + (_rng.randf() - 0.5) * rough * (0.0 if i == 0 or i == lat else 1.0)
			row.append(ctr + Vector3(dir.x * rad.x, dir.y * rad.y, dir.z * rad.z) * j_)
		rows.append(row)
	for i in lat:
		for j in lon:
			var j2 := (j + 1) % lon
			var a: Vector3 = rows[i][j]
			var bb: Vector3 = rows[i][j2]
			var cc: Vector3 = rows[i + 1][j]
			var dd: Vector3 = rows[i + 1][j2]
			var shade := col.lightened(0.08 * (1.0 - float(i) / float(lat))).darkened(0.12 * float(i) / float(lat))
			# Pole rows produce degenerate triangles, which _tri() skips.
			_tri(b, a, bb, dd, shade, ctr)
			_tri(b, a, dd, cc, shade, ctr)


static func _commit(b: Dictionary, uv2_columns: bool = false) -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = b.v
	arr[Mesh.ARRAY_NORMAL] = b.n
	arr[Mesh.ARRAY_COLOR] = b.c
	arr[Mesh.ARRAY_TEX_UV] = b.uv
	if uv2_columns:
		var uv2 := PackedVector2Array()
		var n: int = b.v.size()
		uv2.resize(n)
		for i in n:
			uv2[i] = Vector2((float(i) + 0.5) / float(n), 0.0)
		arr[Mesh.ARRAY_TEX_UV2] = uv2
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Builds a mesh then rescales it so its height matches the slot contract and
## its lowest vertex sits exactly on Y=0.
static func _fit(b: Dictionary, height: float) -> void:
	var lo := INF
	var hi := -INF
	for p in b.v:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	var s := height / maxf(hi - lo, 0.001)
	for i in b.v.size():
		var p: Vector3 = b.v[i]
		b.v[i] = Vector3(p.x * s, (p.y - lo) * s, p.z * s)


static func _proc_prop(kind: String) -> ArrayMesh:
	var b := _mb()
	var bark := Color(0.36, 0.26, 0.18)
	var leaf := Color(0.22, 0.34, 0.18)
	var stone := Color(0.50, 0.48, 0.44)
	match kind:
		"tree":
			_frustum(b, Vector3.ZERO, 7.0, 4.0, 58.0, 7, bark)
			_blob(b, Vector3(0, 62, 0), Vector3(36, 24, 36), leaf, 11, 0.25)
			_blob(b, Vector3(4, 88, -3), Vector3(28, 22, 28), leaf.lightened(0.06), 12, 0.25)
			_blob(b, Vector3(-2, 112, 2), Vector3(17, 18, 17), leaf.lightened(0.1), 13, 0.25)
		"tree_dead":
			var dead := Color(0.40, 0.36, 0.32)
			_frustum(b, Vector3.ZERO, 7.0, 2.0, 112.0, 6, dead)
			_frustum(b, Vector3(0, 50, 0), 3.0, 0.8, 40.0, 5, dead, Color(0, 0, 0, 0), Vector3(26, 6, 6))
			_frustum(b, Vector3(0, 70, 0), 2.6, 0.6, 34.0, 5, dead, Color(0, 0, 0, 0), Vector3(-20, 8, -14))
			_frustum(b, Vector3(0, 92, 0), 2.0, 0.4, 30.0, 5, dead, Color(0, 0, 0, 0), Vector3(8, 4, 20))
			_frustum(b, Vector3(0, 108, 0), 1.6, 0.3, 17.0, 4, dead, Color(0, 0, 0, 0), Vector3(-4, 0, -3))
		"rock":
			_blob(b, Vector3(0, 19, 0), Vector3(28, 19, 24), stone, 21, 0.3, 4, 7)
			_blob(b, Vector3(14, 10, 10), Vector3(13, 10, 12), stone.darkened(0.08), 22, 0.3, 3, 6)
		"wall":
			var rows := 3
			for r in rows:
				var y0 := float(r) * 20.0
				var off := 9.0 if r % 2 == 1 else 0.0
				var x := -54.0 + off
				var k := 0
				while x < 54.0 - 1.0:
					var w := minf(27.0, 54.0 - x)
					_box(b, Vector3(x + w * 0.5, y0 + 10.0, 0), Vector3(w - 1.5, 19.0, 22.0 - float(k % 2) * 2.0), stone.darkened(0.04 * float((k + r) % 3)))
					x += w
					k += 1
			_box(b, Vector3(0, 62.5, 0), Vector3(110, 5, 24), stone.lightened(0.05))
		"pillar":
			_box(b, Vector3(0, 5, 0), Vector3(28, 10, 28), stone.darkened(0.06))
			_frustum(b, Vector3(0, 10, 0), 10.0, 8.5, 75.0, 8, stone)
			_box(b, Vector3(0, 90, 0), Vector3(26, 10, 26), stone.lightened(0.05))
		"arch":
			_box(b, Vector3(-45, 47.5, 0), Vector3(20, 95, 22), stone)
			_box(b, Vector3(45, 47.5, 0), Vector3(20, 95, 22), stone)
			_box(b, Vector3(0, 107.5, 0), Vector3(124, 25, 24), stone.lightened(0.04))
		"bones":
			var bone := Color(0.82, 0.78, 0.68)
			_blob(b, Vector3(18, 7, 0), Vector3(8, 7, 7), bone, 31, 0.1, 4, 6)
			for i in 5:
				var x2 := -14.0 + float(i) * 6.0
				_frustum(b, Vector3(x2, 0, -8), 1.4, 1.0, 22.0, 4, bone, Color(0, 0, 0, 0), Vector3(0, -6, 8))
			_box(b, Vector3(-2, 2, 0), Vector3(36, 3, 4), bone.darkened(0.1))
		"bush":
			_blob(b, Vector3(0, 11, 0), Vector3(15, 11, 15), leaf.darkened(0.05), 41, 0.3, 4, 7)
			_blob(b, Vector3(9, 15, 5), Vector3(10, 11, 10), leaf, 42, 0.3, 4, 6)
			_blob(b, Vector3(-8, 13, -6), Vector3(10, 13, 10), leaf.lightened(0.05), 43, 0.3, 4, 6)
		"grass":
			var g := Color(0.34, 0.46, 0.22)
			for i in 6:
				var a := float(i) * 1.1
				var r2 := 3.0 + float(i % 3) * 2.0
				var base := Vector3(cos(a) * r2, 0, sin(a) * r2)
				var lean := Vector3(cos(a), 0, sin(a)) * 4.0
				var side := Vector3(-sin(a), 0, cos(a)) * 1.4
				var h := 10.0 + float(i % 4) * 1.5
				_quad2(b, base - side, base + side, base + side * 0.3 + lean + Vector3(0, h, 0), base - side * 0.3 + lean + Vector3(0, h, 0), g.lightened(0.04 * float(i % 3)))
		_:
			_box(b, Vector3(0, 10, 0), Vector3(20, 20, 20), stone)
	_fit(b, PROP_HEIGHT.get(kind, 20.0))
	return _commit(b)


static func _proc_foe(kind: String) -> ArrayMesh:
	var b := _mb()
	var d: Dictionary = Content.FOES.get(kind, Content.FOES["grunt"])
	var col: Color = d.color
	var dark := col.darkened(0.35)
	var eye := Color(1.0, 0.55, 0.2)
	match kind:
		"grunt":
			_frustum(b, Vector3(-2, 0, -5), 3.0, 2.5, 12.0, 5, dark)
			_frustum(b, Vector3(-2, 0, 5), 3.0, 2.5, 12.0, 5, dark)
			_blob(b, Vector3(0, 17, 0), Vector3(9, 8, 8), col, 51)
			_blob(b, Vector3(6, 25, 0), Vector3(5, 4.5, 4.5), col.lightened(0.05), 52)
			_box(b, Vector3(10, 25.5, 0), Vector3(1.5, 1.5, 5), eye)
			_frustum(b, Vector3(2, 21, -9), 2.5, 2.0, -12.0, 5, col, Color(0, 0, 0, 0), Vector3(5, 0, 0))
			_frustum(b, Vector3(2, 21, 9), 2.5, 2.0, -12.0, 5, col, Color(0, 0, 0, 0), Vector3(5, 0, 0))
		"runner":
			for lx in [-7.0, 7.0]:
				for lz in [-4.0, 4.0]:
					_frustum(b, Vector3(lx, 0, lz), 1.6, 2.2, 12.0, 4, dark)
			_blob(b, Vector3(0, 15, 0), Vector3(13, 5, 6), col, 61)
			_blob(b, Vector3(14, 19, 0), Vector3(5, 4, 4), col.lightened(0.05), 62)
			_box(b, Vector3(18.5, 19.5, 0), Vector3(1.2, 1.2, 4.5), eye)
			_frustum(b, Vector3(-12, 16, 0), 1.6, 0.2, 8.0, 4, dark, Color(0, 0, 0, 0), Vector3(-6, 0, 0))
		"brute":
			_frustum(b, Vector3(-2, 0, -7), 5.0, 4.0, 15.0, 6, dark)
			_frustum(b, Vector3(-2, 0, 7), 5.0, 4.0, 15.0, 6, dark)
			_blob(b, Vector3(0, 25, 0), Vector3(14, 13, 13), col, 71)
			_blob(b, Vector3(8, 37, 0), Vector3(6, 5, 6), col.lightened(0.04), 72)
			_box(b, Vector3(13.5, 38, 0), Vector3(1.5, 1.5, 6), eye)
			_blob(b, Vector3(4, 22, -16), Vector3(6, 13, 6), col.darkened(0.08), 73)
			_blob(b, Vector3(4, 22, 16), Vector3(6, 13, 6), col.darkened(0.08), 74)
		"spitter":
			_frustum(b, Vector3(0, 0, -4), 2.5, 2.0, 9.0, 5, dark)
			_frustum(b, Vector3(0, 0, 4), 2.5, 2.0, 9.0, 5, dark)
			_blob(b, Vector3(-2, 16, 0), Vector3(10, 9, 10), col, 81)
			_frustum(b, Vector3(2, 21, 0), 3.0, 2.2, 6.0, 5, col.lightened(0.05), Color(0, 0, 0, 0), Vector3(3, 0, 0))
			_blob(b, Vector3(7, 27, 0), Vector3(4.5, 3.5, 3.5), col.lightened(0.1), 82)
			_box(b, Vector3(11, 27, 0), Vector3(1.4, 2.0, 3.0), Color(0.7, 1.0, 0.4))
		"charger":
			for lx2 in [-8.0, 8.0]:
				for lz2 in [-5.0, 5.0]:
					_frustum(b, Vector3(lx2, 0, lz2), 2.6, 3.0, 13.0, 5, dark)
			_blob(b, Vector3(0, 19, 0), Vector3(15, 8, 9), col, 91)
			_blob(b, Vector3(15, 22, 0), Vector3(6, 6, 6), col.lightened(0.04), 92)
			_frustum(b, Vector3(18, 26, -4), 1.6, 0.2, 9.0, 4, Color(0.85, 0.80, 0.70), Color(0, 0, 0, 0), Vector3(6, 0, -2))
			_frustum(b, Vector3(18, 26, 4), 1.6, 0.2, 9.0, 4, Color(0.85, 0.80, 0.70), Color(0, 0, 0, 0), Vector3(6, 0, 2))
			_box(b, Vector3(20.5, 23, 0), Vector3(1.4, 1.4, 6), eye)
	_fit(b, float(d.height))
	return _commit(b, true)


## Generic low-poly parts for procedural rigs (hero/boss).
static func part_mesh(shape: String, size: Vector3, col: Color, seed_v: int = 1) -> ArrayMesh:
	var key := "part:%s:%s:%s:%d" % [shape, size, col, seed_v]
	if _cache.has(key):
		return _cache[key]
	var b := _mb()
	match shape:
		"box":
			_box(b, Vector3.ZERO, size, col)
		"limb":
			# Segment hanging down from the joint (bone origin) along -Y.
			_frustum(b, Vector3(0, -size.y, 0), size.z, size.x, size.y, 6, col)
		"blob":
			_blob(b, Vector3.ZERO, size, col, seed_v, 0.1, 5, 8)
		"cone":
			_frustum(b, Vector3.ZERO, size.x, 0.0, size.y, 6, col)
	var m := _commit(b)
	_cache[key] = m
	return m


static func quad_mesh(size: float) -> ArrayMesh:
	var key := "quad:%f" % size
	if _cache.has(key):
		return _cache[key]
	var pm := PlaneMesh.new()
	pm.size = Vector2(size, size)
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, pm.get_mesh_arrays())
	_cache[key] = m
	return m
