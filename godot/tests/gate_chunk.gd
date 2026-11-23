extends Node
## Gate scene: builds the real WorldView3D for every quality tier x act, runs the
## simulation with scripted input, and verifies render-contract invariants.
## Run: godot --headless --path godot res://tests/gate_chunk.tscn

const TICKS := 240

var _fail := 0
var _checks := 0
var _solid_sig := {}


func ok(label: String, cond: bool, detail: String = "") -> bool:
	_checks += 1
	if not cond:
		_fail += 1
		print("  FAIL  ", label, ("  (" + detail + ")" if detail != "" else ""))
	return cond


func _ready() -> void:
	for tier in [Quality.Tier.LOW, Quality.Tier.MEDIUM, Quality.Tier.HIGH]:
		for act in Content.ACTS.size():
			await _run_combo(tier, act)
	await _pbr_rule()
	print("GATE_CHUNK SUMMARY: %d checks, %d failed" % [_checks, _fail])
	get_tree().quit(1 if _fail > 0 or _checks == 0 else 0)


func _sig(list: Array) -> String:
	var parts := PackedStringArray()
	for s in list:
		parts.append("%s@%.2f,%.2f,%.3f,%.3f" % [s[0], s[1], s[2], s[3], s[4]])
	return ",".join(parts)


func _run_combo(tier: int, act: int) -> void:
	Quality.set_tier(tier)
	var tname: String = Quality.TIER_NAMES[tier]
	var aname: String = Content.act(act).name
	var tag := "%s/%s" % [tname, aname]
	var w := SimWorld.new(act, Content.HERO_ORDER[act % 4], 1000 + act)
	var v := WorldView3D.new()
	add_child(v)
	v.setup(w)
	var clock := FixedStep.new()
	var bad_foes := 0
	for i in TICKS:
		w.autopilot(w.time, FixedStep.STEP)
		var n := clock.advance(FixedStep.STEP)
		for k in n:
			w.step(FixedStep.STEP)
			if not w.choices.is_empty():
				w.choose(0)
		v.render(FixedStep.STEP, clock.alpha())
		w.events.clear()
		if i % 25 == 0:
			for k in w.swarm.count:
				if w.swarm.alive[k] == 1 and not w.terrain.passable(Vector2(w.swarm.px[k], w.swarm.py[k])):
					bad_foes += 1
	ok(tag + " foes always on passable ground", bad_foes == 0, str(bad_foes))
	ok(tag + " hero on passable ground", w.terrain.passable(w.pos))
	# Ground / liquid / fog.
	var pm := v.ground.mesh as PlaneMesh
	ok(tag + " ground GROUND_SIZE 2200", is_equal_approx(pm.size.x, 2200.0))
	ok(tag + " ground subdivisions = 2200/ground_q", pm.subdivide_width == int(2200.0 / float(Quality.GROUND_Q[tier])) - 1, str(pm.subdivide_width))
	ok(tag + " ground cast_shadow OFF", v.ground.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	ok(tag + " tex_scale 0.0085 / tint 0.18", is_equal_approx(float(v.terrain_mat.get_shader_parameter("tex_scale")), 0.0085) and is_equal_approx(float(v.terrain_mat.get_shader_parameter("tint")), 0.18))
	ok(tag + " water hidden iff liquid none", v.water.visible == (w.terrain.liquid != "none"))
	var fm := v.fog.mesh as PlaneMesh
	ok(tag + " ground fog 24x24 subdivided", fm.subdivide_width == 24 and fm.subdivide_depth == 24)
	# Lighting.
	ok(tag + " sun 1.2 (>= 0.32 floor)", is_equal_approx(v.sun.light_energy, 1.2) and v.sun.light_energy >= 0.32)
	ok(tag + " ambient from sky >= 0.22", v.env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and v.env.ambient_light_energy >= 0.22)
	ok(tag + " ACES tonemap", v.env.tonemap_mode == Environment.TONE_MAPPER_ACES)
	ok(tag + " glow screen/bloom0/thr1.25/int0.45", v.env.glow_blend_mode == Environment.GLOW_BLEND_MODE_SCREEN and is_zero_approx(v.env.glow_bloom) and is_equal_approx(v.env.glow_hdr_threshold, 1.25) and is_equal_approx(v.env.glow_intensity, 0.45))
	ok(tag + " torch 1.6*LIGHT_GAIN r360, no shadow", is_equal_approx(v.torch.light_energy, 1.6 * WorldView3D.LIGHT_GAIN) and is_equal_approx(v.torch.omni_range, 360.0) and not v.torch.shadow_enabled)
	ok(tag + " key light 0.9*LIGHT_GAIN", is_equal_approx(v.key_light.light_energy, 0.9 * WorldView3D.LIGHT_GAIN))
	ok(tag + " vignette <= 0.35", float((v.vignette.material as ShaderMaterial).get_shader_parameter("strength")) <= 0.35)
	ok(tag + " shadow distance 720*dist/600", is_equal_approx(v.sun.directional_shadow_max_distance, 720.0 * v.dist / 600.0))
	ok(tag + " single orthogonal cascade", v.sun.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL)
	ok(tag + " sun shadows off only on Low", v.sun.shadow_enabled == (tier != Quality.Tier.LOW))
	# Props.
	var c0 := Vector2i(0, 0)
	var sig := _sig(w.layout.solids(c0)) + "|" + _sig(w.layout.solids(Vector2i(1, 1)))
	if _solid_sig.has(act):
		ok(tag + " solids identical across quality tiers", _solid_sig[act] == sig)
	else:
		_solid_sig[act] = sig
	var dens := Quality.prop_density()
	var rng := PropLayout.decor_count_range(dens)
	var dcount := w.layout.decor(c0, dens).size()
	ok(tag + " decor count %d in %s" % [dcount, rng], dcount >= rng.x and dcount <= rng.y)
	ok(tag + " prop cells built", v.cell_count() >= 4, str(v.cell_count()))
	var cell := v.cell_node(c0)
	var kinds_seen := 0
	if ok(tag + " origin cell exists", cell != null):
		for mmi in cell.get_children():
			var kind := String(mmi.name)
			kinds_seen += 1
			var mesh: Mesh = (mmi as MultiMeshInstance3D).multimesh.mesh
			if kind in ["bones", "bush", "grass"]:
				ok(tag + " %s casts no shadow" % kind, mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
			else:
				ok(tag + " %s casts shadow" % kind, mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
			if kind in ["bush", "grass"]:
				ok(tag + " %s culled at 950*dist/600, fade disabled" % kind, is_equal_approx(mmi.visibility_range_end, 950.0 * v.dist / 600.0) and mmi.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED)
			if Models.has_pbr(mesh):
				ok(tag + " PBR %s keeps its own material" % kind, mmi.material_override == null)
			else:
				var pmat := mmi.material_override as ShaderMaterial
				ok(tag + " %s uses neutral prop_mat" % kind, pmat != null and (pmat.get_shader_parameter("tint") as Color).is_equal_approx(Color(0.96, 0.95, 0.93)))
	ok(tag + " origin cell has grass+bush", kinds_seen >= 2)
	# Swarm buffers + hero grounding.
	ok(tag + " 5 foe MultiMeshes at CAP", v._foe_mm.size() == 5 and v._foe_mm[0].multimesh.instance_count == Swarm.CAP)
	var bufs_ok := v._foe_bufs.size() == Swarm.KINDS
	for b in v._foe_bufs:
		bufs_ok = bufs_ok and b.size() == Swarm.CAP * WorldView3D.FOE_STRIDE
	ok(tag + " per-kind foe buffers pre-allocated", bufs_ok)
	var drawn := 0
	for k in Swarm.KINDS:
		drawn += v._foe_mm[k].multimesh.visible_instance_count
	var used := 0
	for k in w.swarm.count:
		used += w.swarm.used[k]
	ok(tag + " every live/dying foe drawn once (%d)" % drawn, drawn == used, "%d vs %d" % [drawn, used])
	var written := true
	for k in Swarm.KINDS:
		if v._foe_mm[k].multimesh.visible_instance_count > 0:
			var b: PackedFloat32Array = v._foe_bufs[k]
			written = written and absf(b[3]) + absf(b[11]) > 0.0 and absf(b[5] - 1.0) < 0.5
	ok(tag + " foe transforms written in place (by-reference buffers)", written)
	var hp := w.pos
	ok(tag + " hero grounded at terrain height", absf(v.hero.position.y - (w.terrain.height(hp.x, hp.y) + SimWorld.jump_lift(w.jump_p))) < 6.0 or w.airborne())
	var foe_mat := v._foe_mats[0]
	ok(tag + " foe tint <= 10%", float(foe_mat.get_shader_parameter("tint_amount")) <= 0.1)
	print("GATE_CHUNK %-6s %-14s cells=%d solids=%d decor=%d foes=%d kills=%d t=%.1fs" % [tname, aname, v.cell_count(), w.layout.solids(c0).size(), dcount, w.swarm.alive_n, w.kills, w.time])
	v.queue_free()
	await get_tree().process_frame


## Injects a textured (PBR) mesh into the rock slot and verifies _build_cell()
## never applies prop_mat to it.
func _pbr_rule() -> void:
	Quality.set_tier(Quality.Tier.MEDIUM)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(Image.create_empty(8, 8, false, Image.FORMAT_RGBA8))
	var pbr := ArrayMesh.new()
	pbr.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
	pbr.surface_set_material(0, mat)
	var saved = Models._cache.get("prop:rock")
	Models._cache["prop:rock"] = pbr
	var w := SimWorld.new(0, "warden", 5)
	var v := WorldView3D.new()
	add_child(v)
	v.setup(w)
	var found := 0
	for c in v._cells:
		var node: Node3D = v._cells[c]
		for mmi in node.get_children():
			if String(mmi.name) == "rock":
				found += 1
				ok("PBR rock cell %s has no prop_mat override" % c, mmi.material_override == null)
	ok("PBR rule exercised (%d rock cells)" % found, found > 0)
	if saved == null:
		Models._cache.erase("prop:rock")
	else:
		Models._cache["prop:rock"] = saved
	v.queue_free()
	await get_tree().process_frame
	print("GATE_CHUNK PBR rule: %d rock cells verified" % found)
