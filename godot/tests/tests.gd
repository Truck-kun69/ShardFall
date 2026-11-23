extends Node
## Unit suite. Run: godot --headless --path godot res://tests/tests.tscn -- unit
## Prints one PASS/FAIL line per assertion and exits non-zero on any failure.

var _pass := 0
var _fail := 0
var _failures: Array[String] = []
var _group := ""


func check(label: String, cond: bool, detail: String = "") -> void:
	var full := "%s :: %s" % [_group, label]
	if cond:
		_pass += 1
		print("  PASS  ", full)
	else:
		_fail += 1
		_failures.append(full + ("  (" + detail + ")" if detail != "" else ""))
		print("  FAIL  ", full, ("  (" + detail + ")" if detail != "" else ""))


func group(n: String) -> void:
	_group = n
	print("[%s]" % n)


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or "unit" in args:
		await _run_unit()
	print("UNIT SUMMARY: %d passed, %d failed" % [_pass, _fail])
	for f in _failures:
		print("  FAILED: ", f)
	get_tree().quit(1 if _fail > 0 or _pass == 0 else 0)


func _run_unit() -> void:
	t_fixed_step()
	t_content()
	t_quality()
	await t_hero_rig()
	await t_boss_rig()
	t_prop_layout()
	t_jump_vault()
	t_foe_move_guard()
	t_rising_tide()
	t_swarm()
	t_hero_movement()
	t_world_sim()
	await t_touch_hud()
	await t_sfx()
	t_models()
	await t_main_flow()


# ----------------------------------------------------------------------------
func t_fixed_step() -> void:
	group("FixedStep")
	var c := FixedStep.new()
	check("STEP is 1/60", is_equal_approx(FixedStep.STEP, 1.0 / 60.0))
	check("MAX_STEPS is 2", FixedStep.MAX_STEPS == 2)
	check("one frame at 60 Hz -> 1 tick", c.advance(1.0 / 60.0) == 1)
	check("long hitch clamps to MAX_STEPS", c.advance(0.5) == 2)
	check("alpha stays in [0,1] after hitch", c.alpha() >= 0.0 and c.alpha() <= 1.0)
	c.reset()
	c.advance(0.008)
	check("sub-step frame -> 0 ticks, alpha ~0.48", c.advance(0.0) == 0 and absf(c.alpha() - 0.48) < 0.01, str(c.alpha()))


func t_content() -> void:
	group("Content")
	check("4 heroes", Content.HERO_ORDER == ["warden", "spark", "ember", "storm"])
	check("5 acts", Content.ACTS.size() == 5)
	check("5 core archetypes", Content.FOE_ORDER == ["grunt", "runner", "brute", "spitter", "charger"])
	check("5 elements", Content.ELEM_NAMES == ["PHYS", "FIRE", "COLD", "LIGHT", "CHAOS"])
	var ok := true
	for w in Content.WEAPONS:
		ok = ok and Content.EVOLUTIONS.has(Content.WEAPONS[w].evolves_to) and Content.PASSIVES.has(Content.WEAPONS[w].evolve_with)
	check("every weapon has an evolution + catalyst passive", ok)
	var bosses_ok := true
	for a in Content.ACTS:
		bosses_ok = bosses_ok and Content.BOSSES.has(a.boss)
	check("every act has a boss", bosses_ok)


func t_quality() -> void:
	group("Quality")
	check("auto_render_scale Low 0.75", is_equal_approx(Quality.auto_render_scale(0), 0.75))
	check("auto_render_scale Medium 1.0", is_equal_approx(Quality.auto_render_scale(1), 1.0))
	check("auto_render_scale High 1.0", is_equal_approx(Quality.auto_render_scale(2), 1.0))
	var hi := Quality.aa_for(Quality.Tier.HIGH, 1.0)
	check("High = MSAA 2x, no FXAA", hi.msaa == Viewport.MSAA_2X and hi.ssaa == Viewport.SCREEN_SPACE_AA_DISABLED)
	var med := Quality.aa_for(Quality.Tier.MEDIUM, 1.0)
	check("Medium @1.0 = FXAA, no MSAA", med.msaa == Viewport.MSAA_DISABLED and med.ssaa == Viewport.SCREEN_SPACE_AA_FXAA)
	var med_lo := Quality.aa_for(Quality.Tier.MEDIUM, 0.85)
	check("Medium @0.85 = no FXAA (below 0.90)", med_lo.ssaa == Viewport.SCREEN_SPACE_AA_DISABLED and med_lo.msaa == Viewport.MSAA_DISABLED)
	var lo := Quality.aa_for(Quality.Tier.LOW, 0.75)
	check("Low = AA off", lo.msaa == Viewport.MSAA_DISABLED and lo.ssaa == Viewport.SCREEN_SPACE_AA_DISABLED)
	var never_stack := true
	for t in 3:
		for s in [0.75, 0.85, 0.9, 1.0]:
			var a := Quality.aa_for(t, s)
			never_stack = never_stack and not (a.msaa != Viewport.MSAA_DISABLED and a.ssaa != Viewport.SCREEN_SPACE_AA_DISABLED)
	check("MSAA and FXAA never stack", never_stack)
	check("shadow distance 720 at dist 600", is_equal_approx(Quality.shadow_distance(600.0), 720.0))
	check("clutter cull 950 at dist 600", is_equal_approx(Quality.clutter_cull_distance(600.0), 950.0))
	check("ground_q = [16,12,10]", Quality.GROUND_Q == [16, 12, 10])
	check("detect Adreno 740 + 8GB -> High", Quality.detect("Adreno (TM) 740", 8192) == Quality.Tier.HIGH)
	check("detect Adreno 619 -> Medium", Quality.detect("Adreno (TM) 619", 6144) == Quality.Tier.MEDIUM)
	check("detect Mali-G52 -> Low", Quality.detect("Mali-G52 MC2", 4096) == Quality.Tier.LOW)
	check("detect Mali-G78 + 8GB -> High", Quality.detect("Mali-G78 MP20", 8192) == Quality.Tier.HIGH)
	check("detect Mali-G610 -> Medium", Quality.detect("Mali-G610 MC6", 8192) == Quality.Tier.MEDIUM)
	check("detect 2GB RAM -> Low", Quality.detect("Adreno (TM) 740", 2048) == Quality.Tier.LOW)
	check("detect High GPU on 4GB -> Medium", Quality.detect("Adreno (TM) 750", 4096) == Quality.Tier.MEDIUM)
	Quality.set_tier(Quality.Tier.MEDIUM)
	for i in 600:
		Quality.update_dynamic(1.0 / 30.0)
	check("Medium dynamic scale drops but floors at 0.85", is_equal_approx(Quality.dyn_scale, Quality.DYN_FLOOR_MED), str(Quality.dyn_scale))
	Quality.set_tier(Quality.Tier.HIGH)
	var changed := false
	for i in 600:
		changed = changed or Quality.update_dynamic(1.0 / 20.0)
	check("High locked native (no dynamic downscale)", not changed and is_equal_approx(Quality.dyn_scale, 1.0))
	Quality.set_tier(Quality.Tier.LOW)
	check("Low fixed at 0.75", is_equal_approx(Quality.dyn_scale, 0.75) and not Quality.update_dynamic(1.0 / 10.0))
	check("prop density Low 0.7 / High 1.0", is_equal_approx(Quality.prop_density(), 0.7))
	Quality.set_tier(Quality.Tier.MEDIUM)


# ----------------------------------------------------------------------------
func _rig(id: String) -> HeroRig:
	var r := HeroRig.new()
	add_child(r)
	r.setup(id)
	r.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	return r


func t_hero_rig() -> void:
	group("HeroRig")
	var m := HeroRig.map_clips(PackedStringArray(["Armature|IDLE", "Walk_Loop", "RUN_fast", "Attack01", "Dodge", "Jump_Full", "Death"]))
	check("case-insensitive clip mapping", m.idle == "Armature|IDLE" and m.walk == "Walk_Loop" and m.run == "RUN_fast" and m.cast == "Attack01" and m.roll == "Dodge" and m.jump == "Jump_Full" and m.die == "Death", str(m))
	var m2 := HeroRig.map_clips(PackedStringArray(["cast_spell", "roll", "die", "idle", "walk", "run", "jump"]))
	check("cast preferred over attack, die mapped", m2.cast == "cast_spell" and m2.die == "die")
	check("empty clip list guarded", HeroRig.map_clips(PackedStringArray()).is_empty())
	var m3 := HeroRig.map_clips(PackedStringArray(["Idle"]))
	check("missing roles fall back to idle", m3.walk == "Idle" and m3.jump == "Idle" and m3.die == "Idle")
	for id in Content.HERO_ORDER:
		var rr := _rig(id)
		check("procedural rig '%s' has all 7 clips" % id, rr.clips.size() == 7 and rr.player.get_animation_list().size() == 7)
		rr.queue_free()
	var r := _rig("warden")
	check("upper-body mask has spine/chest/neck/head/clavicle/shoulder/arm/hand", r.upper_bones.has("spine") and r.upper_bones.has("chest") and r.upper_bones.has("neck") and r.upper_bones.has("head") and r.upper_bones.has("clavicle_l") and r.upper_bones.has("shoulder_r") and r.upper_bones.has("arm_l") and r.upper_bones.has("hand_r"), str(r.upper_bones))
	check("upper-body mask excludes legs/hips", not r.upper_bones.has("thigh_l") and not r.upper_bones.has("hips") and not r.upper_bones.has("shin_r"))
	# loco_rate continuity.
	var prev := r.loco_rate(0.0)
	var max_jump := 0.0
	var in_range := true
	var s := 0.0
	while s <= 320.0:
		var v := r.loco_rate(s)
		in_range = in_range and v >= 0.85 - 1e-6 and v <= 1.30 + 1e-6
		max_jump = maxf(max_jump, absf(v - prev))
		prev = v
		s += 0.25
	check("loco_rate within [0.85, 1.30]", in_range)
	check("loco_rate continuous (max step %.4f per 0.25 u/s)" % max_jump, max_jump < 0.01)
	check("loco_rate == 1 across walk..run band", is_equal_approx(r.loco_rate(HeroRig.V_WALK), 1.0) and is_equal_approx(r.loco_rate(110.0), 1.0) and is_equal_approx(r.loco_rate(HeroRig.V_RUN), 1.0))
	check("loco_rate exact formula below walk", is_equal_approx(r.loco_rate(63.0), 63.0 / HeroRig.V_WALK))
	# cast_full abort.
	r.update(0.016, Vector2.ZERO, Vector2.RIGHT, false, 0.0, 0, false)
	r.update(0.016, Vector2.ZERO, Vector2.RIGHT, false, 0.0, 1, false)
	r.tree.advance(0.016)
	check("standing cast fires cast_full", r.cast_full_fires == 1 and r.cast_full_active() and r.cast_up_fires == 0)
	r.update(0.016, Vector2(HeroRig.V_WALK * 0.5, 0.0), Vector2.RIGHT, false, 0.0, 1, false)
	check("moving during cast_full -> FADE_OUT abort", r.cast_full_aborts == 1 and not r.cast_full_active())
	check("abort issued ONE_SHOT_REQUEST_FADE_OUT", int(r.tree.get("parameters/cast_full/request")) == AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	for i in 10:
		r.update(0.016, Vector2(HeroRig.V_WALK * 0.5, 0.0), Vector2.RIGHT, false, 0.0, 1, false)
		r.tree.advance(0.016)
	check("abort does not replay cast_up", r.cast_up_fires == 0)
	r.update(0.5, Vector2(100, 0), Vector2.RIGHT, false, 0.0, 2, false)
	check("moving cast uses upper-body cast_up", r.cast_up_fires == 1)
	r.update(0.016, Vector2(100, 0), Vector2.RIGHT, false, 0.0, 3, false)
	check("CAST_VIS_CD (0.45 s) throttles visual casts", r.cast_up_fires == 1)
	check("CAST_RATE 1.25 on cast time scales", is_equal_approx(float(r.tree.get("parameters/cast_ts_up/scale")), 1.25) and is_equal_approx(HeroRig.CAST_VIS_CD, 0.45))
	# Jump clip scrubbed by jump_progress.
	var thigh := r.skeleton.find_bone("thigh_l")
	r.update(0.016, Vector2.ZERO, Vector2.RIGHT, false, 0.1, 3, false)
	r.tree.advance(0.016)
	var q1 := r.skeleton.get_bone_pose_rotation(thigh)
	r.update(0.016, Vector2.ZERO, Vector2.RIGHT, false, 0.5, 3, false)
	r.tree.advance(0.016)
	var q2 := r.skeleton.get_bone_pose_rotation(thigh)
	r.update(0.016, Vector2.ZERO, Vector2.RIGHT, false, 0.5, 3, false)
	r.tree.advance(0.2)
	var q3 := r.skeleton.get_bone_pose_rotation(thigh)
	check("jump pose follows jump_progress", q1.angle_to(q2) > 0.05, "%f" % q1.angle_to(q2))
	check("jump clip frozen between scrubs (no free playback)", q2.angle_to(q3) < 0.01, "%f" % q2.angle_to(q3))
	check("jump clip is a real clip (not a bone hack)", r.player.get_animation(r.clips.jump).get_track_count() > 4)
	# Smooth yaw.
	r.rotation.y = 0.0
	r.update(0.016, Vector2.ZERO, Vector2(0, 1), false, 0.0, 3, false)
	var target := atan2(-1.0, 0.0)
	check("yaw smooths via lerp_angle(dt*14)", absf(angle_difference(r.rotation.y, lerp_angle(0.0, target, 0.016 * 14.0))) < 0.001)
	# Death.
	r.update(0.016, Vector2.ZERO, Vector2.RIGHT, false, 0.0, 3, true)
	check("death plays die clip once, tree off", not r.tree.active and r.player.current_animation == r.clips.die)
	r.queue_free()
	await get_tree().process_frame


func t_boss_rig() -> void:
	group("BossRig")
	check("pick_clip idle when slow", BossRig.pick_clip(false, false, false, false, 2.0) == "idle")
	check("pick_clip walk when moving", BossRig.pick_clip(false, false, false, false, 30.0) == "walk")
	check("pick_clip attack/slam alternate", BossRig.pick_clip(false, true, true, false, 0.0, false) == "attack" and BossRig.pick_clip(false, true, true, false, 0.0, true) == "slam")
	check("pick_clip die wins", BossRig.pick_clip(true, true, true, true, 50.0) == "die")
	var b := BossRig.new()
	add_child(b)
	b.setup("gravelord", Color(0.5, 0.5, 0.5))
	var b2 := BossRig.new()
	add_child(b2)
	b2.setup("rimeheart", Color(0.5, 0.6, 0.7))
	check("flash shader cached statically (shared)", b._flash_mat.shader == b2._flash_mat.shader and b._flash_mat.shader == BossRig.flash_shader())
	check("all boss clips present", b.clips.idle != "" and b.clips.walk != "" and b.clips.attack != "" and b.clips.slam != "" and b.clips.die != "")
	b.update_state(0.016, false, false, false, false, 1.0, false, 1.0, 0.0)
	check("idle below 5 u/s", b.current == "idle")
	b.update_state(0.016, false, false, false, false, 40.0, false, 1.0, 0.0)
	check("walk above 5 u/s", b.current == "walk")
	b.update_state(0.016, false, true, true, false, 0.0, true, 1.0, 0.0)
	check("attack state plays slam on alt", b.current == "slam")
	check("die clip non-looping", b.player.get_animation(b.clips.die).loop_mode == Animation.LOOP_NONE)
	b.update_state(0.016, true, false, false, false, 0.0, false, 1.0, 0.0)
	check("death plays die", b.current == "die" and b.player.current_animation == b.clips.die)
	b.player.advance(0.5)
	var pos1 := b.player.current_animation_position
	b.update_state(0.016, true, false, false, false, 0.0, false, 0.5, 0.0)
	check("die plays once (not restarted)", b.player.current_animation_position >= pos1 - 0.001)
	b.update_state(0.016, true, false, false, false, 0.0, false, 0.0, 0.0)
	check("light fades to 0 during death sink", is_zero_approx(b.light.light_energy) and b.body.position.y < -10.0, "%f" % b.light.light_energy)
	b.queue_free()
	b2.queue_free()
	await get_tree().process_frame


# ----------------------------------------------------------------------------
func _solid_sig(list: Array) -> String:
	var parts := PackedStringArray()
	for s in list:
		parts.append("%s@%.3f,%.3f,%.3f,%.3f" % [s[0], s[1], s[2], s[3], s[4]])
	return ",".join(parts)


func t_prop_layout() -> void:
	group("PropLayout")
	var t := Terrain.new(0)
	var lay := t.layout
	var c := Vector2i(0, 0)
	check("deterministic stream 1", _solid_sig(lay.gen_solids_uncached(c)) == _solid_sig(lay.gen_solids_uncached(c)))
	var t2 := Terrain.new(0)
	check("identical across instances", _solid_sig(t2.layout.gen_solids_uncached(Vector2i(1, -1))) == _solid_sig(lay.gen_solids_uncached(Vector2i(1, -1))))
	var dh := lay.decor(c, 1.0)
	var dl := lay.decor(c, 0.7)
	check("decor Med/High 150-286 per chunk", dh.size() >= 150 and dh.size() <= 286, str(dh.size()))
	check("decor Low 105-155 per chunk", dl.size() >= 105 and dl.size() <= 155, str(dl.size()))
	var arches := 0
	var trees := 0
	var rocks := 0
	var clear_ok := true
	var gap_ok := true
	for cy in range(-1, 2):
		for cx in range(-1, 2):
			var list := lay.gen_solids_uncached(Vector2i(cx, cy))
			var cluster := []
			for s in list:
				match String(s[0]):
					"arch":
						arches += 1
					"tree", "tree_dead":
						trees += 1
						cluster.append(s)
					"rock":
						rocks += 1
						cluster.append(s)
				for cc in PropLayout.colliders_for(s[0], s[1], s[2], s[3], s[4]):
					if Vector2(cc[0], cc[1]).length() < PropLayout.SPAWN_CLEAR:
						clear_ok = false
			for i in cluster.size():
				for j in range(i + 1, cluster.size()):
					var a: Array = cluster[i]
					var b: Array = cluster[j]
					var ra: float = PropLayout.colliders_for(a[0], a[1], a[2], a[3], a[4])[0][2]
					var rb: float = PropLayout.colliders_for(b[0], b[1], b[2], b[3], b[4])[0][2]
					if Vector2(a[1], a[2]).distance_to(Vector2(b[1], b[2])) - ra - rb < PropLayout.MIN_GAP - 0.01:
						gap_ok = false
	check("landmarks present (arches over 9 chunks: %d)" % arches, arches >= 5)
	check("groves and outcrops present", trees >= 9 and rocks >= 9, "%d trees %d rocks" % [trees, rocks])
	check("SPAWN_CLEAR 160 respected", clear_ok)
	check("MIN_GAP 48 between cluster solids", gap_ok)
	var wall := PropLayout.colliders_for("wall", 0.0, 0.0, 0.0, 1.0)
	check("wall = 5 circles r18 at -36..36", wall.size() == 5 and is_equal_approx(wall[0][0], -36.0) and is_equal_approx(wall[4][0], 36.0) and is_equal_approx(wall[2][2], 18.0) and not wall[0][3])
	var arch := PropLayout.colliders_for("arch", 0.0, 0.0, 0.0, 1.0)
	check("arch = 2 high posts r14 at +-45", arch.size() == 2 and is_equal_approx(arch[0][0], 45.0) and is_equal_approx(arch[1][0], -45.0) and arch[0][3] and is_equal_approx(arch[0][2], 14.0))
	check("tree r14 high, rock r18 low, scaled", is_equal_approx(PropLayout.colliders_for("tree", 0, 0, 0, 1.5)[0][2], 21.0) and PropLayout.colliders_for("tree", 0, 0, 0, 1)[0][3] and not PropLayout.colliders_for("rock", 0, 0, 0, 1)[0][3])
	# Slide-out.
	var tree_s: Array = []
	for s in lay.solids(Vector2i(1, 0)):
		if s[0] == "tree":
			tree_s = s
			break
	if tree_s.is_empty():
		for s in lay.solids(Vector2i(-1, 0)):
			if s[0] == "tree" or s[0] == "tree_dead":
				tree_s = s
				break
	check("found a tree to slide against", not tree_s.is_empty())
	if not tree_s.is_empty():
		var inside := Vector2(tree_s[1], tree_s[2]) + Vector2(3, 1)
		var out := lay.slide_out(inside, 12.0, true)
		check("slide_out pushes out of solids", not lay.inside_any_solid(out, 11.9), str(out))
	var tf := Terrain.new(2)
	var lf := tf.layout
	for cy in range(-1, 2):
		for cx in range(-1, 2):
			lf._chunks[Vector2i(cx, cy)] = []
	for o in PropLayout.colliders_for("arch", 300.0, 0.0, PI * 0.5, 1.0):
		lf._add_collider(o[0], o[1], o[2], o[3])
	check("arch centre is open", not lf.inside_any_solid(Vector2(300, 0), 12.0))


func _empty_terrain(act: int) -> Terrain:
	var t := Terrain.new(act)
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			t.layout._chunks[Vector2i(cx, cy)] = []
	return t


func t_jump_vault() -> void:
	group("Jump")
	check("JUMP_TIME 0.55 / DIST 200 / CD 2.0 / buffer 0.15", is_equal_approx(SimWorld.JUMP_TIME, 0.55) and is_equal_approx(SimWorld.JUMP_DIST, 200.0) and is_equal_approx(SimWorld.JUMP_CD, 2.0) and is_equal_approx(SimWorld.INPUT_BUFFER, 0.15))
	var r := SimWorld.HERO_R
	var t := _empty_terrain(2)
	t.layout.add_test_collider(100.0, 0.0, 18.0, false)
	var land := t.layout.jump_landing(Vector2.ZERO, Vector2.RIGHT, SimWorld.JUMP_DIST, r)
	check("vaults a low rock", land.x > 100.0 + 18.0 + r and is_equal_approx(land.x, 200.0), str(land))
	var t2 := _empty_terrain(2)
	t2.layout.add_test_collider(100.0, 0.0, 14.0, true)
	var land2 := t2.layout.jump_landing(Vector2.ZERO, Vector2.RIGHT, SimWorld.JUMP_DIST, r)
	check("stops short of a high tree", land2.x <= 100.0 - 14.0 - r + 0.01 and land2.x > 50.0, str(land2))
	var t3 := _empty_terrain(2)
	t3.layout.add_test_collider(200.0, 0.0, 18.0, false)
	var land3 := t3.layout.jump_landing(Vector2.ZERO, Vector2.RIGHT, SimWorld.JUMP_DIST, r)
	check("never lands inside any solid", not t3.layout.inside_any_solid(land3, r) and land3.x < 200.0 - 18.0 - r + 0.01, str(land3))
	var t4 := _empty_terrain(2)
	for o in PropLayout.colliders_for("wall", 120.0, 0.0, PI * 0.5, 1.0):
		t4.layout.add_test_collider(o[0], o[1], o[2], o[3])
	var land4 := t4.layout.jump_landing(Vector2.ZERO, Vector2.RIGHT, SimWorld.JUMP_DIST, r)
	check("vaults a wall", is_equal_approx(land4.x, 200.0), str(land4))
	var t5 := _empty_terrain(2)
	for o in PropLayout.colliders_for("arch", 120.0, 0.0, PI * 0.5, 1.0):
		t5.layout.add_test_collider(o[0], o[1], o[2], o[3])
	var land5 := t5.layout.jump_landing(Vector2.ZERO, Vector2.RIGHT, SimWorld.JUMP_DIST, r)
	check("jumps through an arch's open centre", is_equal_approx(land5.x, 200.0), str(land5))
	var land5b := t5.layout.jump_landing(Vector2(0, 45), Vector2.RIGHT, SimWorld.JUMP_DIST, r)
	check("stops short of an arch post", land5b.x < 120.0 - 14.0 - r + 0.01, str(land5b))
	var t6 := _empty_terrain(2)
	t6.block_rect = Rect2(180, -100, 200, 200)
	var land6 := t6.layout.jump_landing(Vector2.ZERO, Vector2.RIGHT, SimWorld.JUMP_DIST, r)
	check("rejects landing in impassable terrain", t6.passable(land6) and land6.x < 180.0, str(land6))
	# Ground hazards are vaulted (no damage while airborne).
	var w := SimWorld.new(2, "warden", 3)
	w.terrain.force_hazard = "lava"
	w.spawn_acc = 1e9
	w.elite_acc = 1e9
	w.press_jump()
	var hp0 := w.hp
	var air_ticks := 0
	for i in 30:
		w.step(FixedStep.STEP)
		if w.airborne():
			air_ticks += 1
	check("airborne for ~0.55 s", air_ticks >= 30 or w.airborne(), str(air_ticks))
	check("no hazard damage while airborne", is_equal_approx(w.hp, hp0), "%f -> %f" % [hp0, w.hp])
	for i in 60:
		w.step(FixedStep.STEP)
	check("hazard damages when grounded", w.hp < hp0)
	check("jump_progress back to 0 after landing", w.jump_progress() == 0.0 and not w.airborne())
	# Cooldown + input buffer.
	var w2 := SimWorld.new(2, "warden", 3)
	w2.spawn_acc = 1e9
	w2.press_jump()
	w2.step(FixedStep.STEP)
	var t_j := 0.0
	while w2.airborne():
		w2.step(FixedStep.STEP)
		t_j += FixedStep.STEP
	w2.press_jump()
	w2.step(FixedStep.STEP)
	check("JUMP_CD blocks an immediate re-jump", not w2.airborne())
	while w2.jump_cd > 0.1:
		w2.step(FixedStep.STEP)
	w2.press_jump()
	var jumped := false
	for i in 9:
		w2.step(FixedStep.STEP)
		jumped = jumped or w2.airborne()
	check("buffered press (0.15 s) fires when cooldown ends", jumped)
	check("parabolic lift peaks at 58", is_equal_approx(SimWorld.jump_lift(0.5), 58.0) and is_zero_approx(SimWorld.jump_lift(0.0)))


func t_foe_move_guard() -> void:
	group("Terrain")
	var t := _empty_terrain(2)
	t.block_rect = Rect2(50, -500, 1000, 1000)
	t.layout.add_test_collider(40.0, 0.0, 20.0, false)
	var a := Vector2(14, 0)
	var r := t.foe_move(a, Vector2(31, 0), 10.0)
	check("foe_move guard: slide into impassable returns a", r == a, str(r))
	var r2 := t.move(a, Vector2(31, 0), 10.0)
	check("move guard: slide into impassable returns a", r2 == a, str(r2))
	var r3 := t.foe_move(Vector2(-100, 0), Vector2(5, 0), 10.0)
	check("free movement unaffected", r3.is_equal_approx(Vector2(-95, 0)))
	# World invariant: no living foe ever stands in impassable terrain.
	var w := SimWorld.new(0, "warden", 11)
	var bad := 0
	for i in 900:
		w.autopilot(w.time, FixedStep.STEP)
		w.step(FixedStep.STEP)
		if i % 30 == 0:
			for k in w.swarm.count:
				if w.swarm.alive[k] == 1 and not w.terrain.passable(Vector2(w.swarm.px[k], w.swarm.py[k])):
					bad += 1
	check("no foe in deep water / cliffs over 15 s (act 1)", bad == 0, str(bad))
	check("hero always passable", w.terrain.passable(w.pos))
	check("origin plateau dry in all acts", Terrain.new(0).passable(Vector2.ZERO) and Terrain.new(1).passable(Vector2.ZERO) and Terrain.new(2).passable(Vector2.ZERO) and Terrain.new(3).passable(Vector2.ZERO) and Terrain.new(4).passable(Vector2.ZERO))


func t_rising_tide() -> void:
	group("RisingTide")
	var a := Terrain.new(3)
	var b := Terrain.new(3)
	b.time = 600.0
	check("Stage 4 level rises", b.level() > a.level() + 10.0, "%f vs %f" % [b.level(), a.level()])
	var same := true
	var same_decor := true
	for cy in range(-2, 3):
		for cx in range(-2, 3):
			var c := Vector2i(cx, cy)
			same = same and _solid_sig(a.layout.gen_solids_uncached(c)) == _solid_sig(b.layout.gen_solids_uncached(c))
			same_decor = same_decor and a.layout.decor(c, 1.0) == b.layout.decor(c, 1.0)
	check("solid layout invariant under rising tide (level0)", same)
	check("decor layout invariant under rising tide", same_decor)
	var flooded := 0
	for i in 400:
		var p := Vector2(float(i % 20) * 60.0 - 600.0, float(i / 20) * 60.0 - 600.0)
		if a.passable(p) and not b.passable(p):
			flooded += 1
	check("tide actually floods ground (%d samples)" % flooded, flooded > 0)


func t_swarm() -> void:
	group("Swarm")
	check("CAP 720", Swarm.CAP == 720)
	var s := Swarm.new()
	var i := s.spawn(Swarm.Kind.BRUTE, 0, 0, false, 1.0)
	s.rebuild_grid()
	s.damage(i, 1.0, Content.Elem.COLD)
	var hp_before := s.hp[i]
	s.damage(i, 10.0, Content.Elem.FIRE)
	check("COLD then FIRE -> shatter (2x)", s.reactions.size() == 1 and s.reactions[0][0] == "shatter" and is_equal_approx(hp_before - s.hp[i], 20.0))
	s.reactions.clear()
	s.damage(i, 1.0, Content.Elem.LIGHT)
	var j := s.spawn(Swarm.Kind.GRUNT, 30, 0, false, 1.0)
	s.rebuild_grid()
	s.damage(i, 5.0, Content.Elem.FIRE)
	check("FIRE on shocked -> overload cascades to neighbour", s.reactions.size() >= 1 and s.reactions[0][0] == "overload" and s.st_burn[j] > 0.0)
	var killed := false
	for k in 50:
		killed = s.damage(j, 50.0, Content.Elem.PHYS) or killed
	check("kills tracked", killed and s.killed_n >= 1 and s.alive[j] == 0)
	# Determinism of parity-split separation.
	var a := Swarm.new()
	var b := Swarm.new()
	for k in 200:
		var x := float(k % 20) * 4.0
		var y := float(k / 20) * 4.0
		a.spawn(k % 5, x, y, false, 1.0)
		b.spawn(k % 5, x, y, false, 1.0)
	for tick in 60:
		for sw in [a, b]:
			sw.rebuild_grid()
			sw.separate(tick)
			for k in sw.count:
				sw.px[k] += sw.sep_x[k]
				sw.py[k] += sw.sep_y[k]
	var same := true
	for k in 200:
		same = same and a.px[k] == b.px[k] and a.py[k] == b.py[k]
	check("deterministic separation", same)
	var spread := 0.0
	for k in 200:
		spread = maxf(spread, Vector2(a.px[k], a.py[k]).length())
	check("separation spreads an overlapping pack", spread > 90.0, str(spread))


func t_hero_movement() -> void:
	group("Movement")
	var w := SimWorld.new(2, "warden", 5)
	w.spawn_acc = 1e9
	w.elite_acc = 1e9
	w.set_move(Vector2.RIGHT)
	for k in 4:
		w.step(FixedStep.STEP)
	check("reaches full speed in ~0.06 s", w.vel.length() >= w.base_speed * 0.99, str(w.vel.length()))
	w.set_move(Vector2.ZERO)
	for k in 3:
		w.step(FixedStep.STEP)
	check("stops in ~0.05 s", w.vel.length() < 1.0, str(w.vel.length()))
	w.press_roll()
	w.step(FixedStep.STEP)
	check("roll: 0.26 s with i-frames", w.rolling() and w.iframe_t > 0.2 and is_equal_approx(SimWorld.ROLL_TIME, 0.26))
	var hp0 := w.hp
	w.hurt_hero(20.0, "contact")
	check("perfect dodge: no damage, slow-mo + riposte", is_equal_approx(w.hp, hp0) and w.slowmo_t > 0.0 and w.riposte and w.perfect_dodges == 1)
	for k in 20:
		w.step(FixedStep.STEP)
	check("roll ends and riposte fires", not w.rolling() and not w.riposte)
	var w2 := SimWorld.new(2, "warden", 5)
	w2.press_roll()
	for k in 9:
		w2.step(FixedStep.STEP)
	var hp1 := w2.hp
	w2.hurt_hero(20.0, "contact")
	check("late-roll hit: i-frames, no perfect", is_equal_approx(w2.hp, hp1) and w2.slowmo_t == 0.0)


func t_world_sim() -> void:
	group("SimWorld")
	var a := SimWorld.new(0, "spark", 99)
	var b := SimWorld.new(0, "spark", 99)
	for k in 1200:
		a.autopilot(a.time, FixedStep.STEP)
		b.autopilot(b.time, FixedStep.STEP)
		a.step(FixedStep.STEP)
		b.step(FixedStep.STEP)
		a.events.clear()
		b.events.clear()
	check("deterministic run (same seed)", a.pos == b.pos and a.kills == b.kills and a.swarm.alive_n == b.swarm.alive_n, "%s/%s %d/%d" % [a.pos, b.pos, a.kills, b.kills])
	check("combat happens (kills %d)" % a.kills, a.kills > 5)
	check("xp and levels accrue", a.level > 1 or a.xp > 0.0)
	var w := SimWorld.new(1, "ember", 4)
	w.boss_acc = 0.1
	for k in 600:
		w.autopilot(w.time, FixedStep.STEP)
		w.step(FixedStep.STEP)
		w.events.clear()
	check("boss spawns on timer", w.boss != null)
	w.max_hp = 1e9
	w.hp = 1e9
	w.alive = true
	w.over = false
	w.set_move(Vector2.ZERO)
	var seen := {}
	var exposed := false
	for k in 900:
		w.step(FixedStep.STEP)
		w.events.clear()
		seen[w.boss.state] = true
		exposed = exposed or w.boss.exposed()
	check("boss cycles CHASE->WINDUP->EXECUTE->RECOVER", seen.has(Boss.St.CHASE) and seen.has(Boss.St.WINDUP) and seen.has(Boss.St.EXECUTE) and seen.has(Boss.St.RECOVER))
	check("punish window exposed", exposed)
	var hp := w.boss.hp
	w.boss.state = Boss.St.RECOVER
	w.boss.damage(100.0)
	check("exposed takes 1.5x", is_equal_approx(hp - w.boss.hp, 150.0))
	w.boss.state = Boss.St.WINDUP
	w.boss.attack = "slam"
	w.boss.t = 0.5
	check("telegraph during windup", not w.boss.telegraph().is_empty() and w.boss.telegraph().shape == "circle")
	# Level-up flow incl. evolution.
	var e := SimWorld.new(0, "warden", 1)
	e.weapons[0].lvl = Content.MAX_WEAPON_LVL
	e.passives["haste"] = 1
	e.pending_levelups = 1
	e.roll_choices()
	check("evolution offered when maxed + catalyst", e.choices.size() >= 1 and e.choices[0].type == "evolve")
	e.choose(0)
	check("evolution applied", e.weapons[0].id == "bladestorm")


func t_touch_hud() -> void:
	group("TouchControls")
	var cl := CanvasLayer.new()
	add_child(cl)
	var tc := TouchControls.new()
	cl.add_child(tc)
	await get_tree().process_frame
	for sz in [Vector2(1280, 720), Vector2(2400, 1080), Vector2(1600, 720), Vector2(960, 540), Vector2(3200, 1440)]:
		tc.size = sz
		tc.safe_override = Rect2()
		tc._relayout()
		check("layout valid %s (clearance %.1f px)" % [sz, tc.min_clearance()], tc.layout_valid() and tc.min_clearance() >= TouchControls.CLEARANCE)
	tc.size = Vector2(2400, 1080)
	tc.safe_override = Rect2(96, 0, 2210, 1040)   # notch + gesture bar
	tc._relayout()
	check("respects notch safe area (clearance %.1f px)" % tc.min_clearance(), tc.layout_valid() and tc.min_clearance() >= TouchControls.CLEARANCE)
	check("5 right-thumb buttons", TouchControls.BUTTONS == ["ROLL", "JUMP", "ULT", "1", "2"])
	var n0 := tc.layouts
	for i in 10:
		await get_tree().process_frame
	check("layout cached (no per-frame relayout)", tc.layouts == n0)
	tc.set_options("fixed", 1.2)
	check("relayout on option change", tc.layouts == n0 + 1 and tc.joystick_mode == "fixed")
	check("joystick R scales with sc", is_equal_approx(tc.R, TouchControls.BASE_JOY_R * tc.sc))
	group("Hud")
	var hud := Hud.new()
	cl.add_child(hud)
	var w := SimWorld.new(0, "warden", 1)
	hud.bind(w)
	var r0 := hud.redraws
	for i in 60:
		hud._process(1.0 / 60.0)
	var per_s := hud.redraws - r0
	check("HUD redraw throttled to 15-20 Hz (%d in 1 s)" % per_s, per_s >= 15 and per_s <= 20)
	cl.queue_free()
	await get_tree().process_frame


func t_sfx() -> void:
	group("Audio")
	check("Master has AudioEffectLimiter", AudioServer.get_bus_effect_count(0) >= 1 and AudioServer.get_bus_effect(0, 0) is AudioEffectLimiter)
	check("Music/SFX/UI buses", AudioServer.get_bus_index("Music") > 0 and AudioServer.get_bus_index("SFX") > 0 and AudioServer.get_bus_index("UI") > 0)
	check("5-voice polyphony", Sfx.voice_count() == 5)
	var s0: int = Sfx.steals
	for i in 7:
		Sfx.play("hit")
	check("oldest-voice stealing beyond 5 voices", Sfx.steals - s0 == 2, str(Sfx.steals - s0))
	var v: int = Sfx.play_at("hit", Vector2(1000, 0), Vector2.ZERO)
	check("stereo panning right", is_equal_approx(Sfx._pan_fx[v].pan, 1.0))
	var v2: int = Sfx.play_at("hit", Vector2(-260, 0), Vector2.ZERO)
	check("stereo panning partial left", is_equal_approx(Sfx._pan_fx[v2].pan, -0.5))
	var p0: float = Sfx.xp_pitch()
	for i in 5:
		Sfx.xp_pickup()
	check("XP pitch climbs on combo", Sfx.xp_pitch() > p0 + 0.2)
	Sfx._process(1.0)
	check("XP pitch resets after combo window", is_equal_approx(Sfx.xp_pitch(), 1.0))
	Sfx.stop_all()
	await get_tree().create_timer(0.25).timeout


func t_models() -> void:
	group("Models")
	var ok := true
	var detail := ""
	for k in Models.PROP_HEIGHT:
		var m := Models.prop_mesh(k)
		var ab := m.get_aabb()
		if absf(ab.size.y - float(Models.PROP_HEIGHT[k])) > 0.5 or absf(ab.position.y) > 0.01:
			ok = false
			detail += "%s h=%.1f min=%.2f " % [k, ab.size.y, ab.position.y]
	check("procedural props match slot heights, feet at Y=0", ok, detail)
	var fok := true
	for k in Content.FOE_ORDER:
		var ab2 := Models.foe_mesh(k).get_aabb()
		fok = fok and ab2.size.y >= 24.0 - 0.01 and ab2.size.y <= 42.0 + 0.01 and absf(ab2.position.y) < 0.01
	check("procedural foes 24-42u, feet at Y=0", fok)
	check("procedural meshes are not PBR", not Models.has_pbr(Models.prop_mesh("rock")))
	# mesh_from_asset keeps node surface override materials.
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var mat := StandardMaterial3D.new()
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mi.set_surface_override_material(0, mat)
	var ps := PackedScene.new()
	ps.pack(root)
	root.free()
	var out := Models.mesh_from_asset(ps)
	check("mesh_from_asset copies surface_override_material", out != null and out.surface_get_material(0) is StandardMaterial3D and (out.surface_get_material(0) as StandardMaterial3D).albedo_texture != null)
	check("has_pbr true for textured surfaces", Models.has_pbr(out))
	var two := ArrayMesh.new()
	var arr := BoxMesh.new().get_mesh_arrays()
	two.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	two.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	two.surface_set_material(0, mat)
	check("has_pbr checks ALL surfaces", not Models.has_pbr(two))


func t_main_flow() -> void:
	group("MainFlow")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	check("boots into MENU with 3D stage", main.state == 0 and main.stage.visible and main.screens.menu.visible)
	main._start_run()
	check("PLAY starts a run", main.state == 1 and main.view != null and main.world != null and main.view.camera.current)
	for i in 20:
		await get_tree().process_frame
	check("simulation advances", main.world.tick > 0)
	main._pause()
	check("pause", main.state == 2 and main.screens.pause_panel.visible)
	var t0: int = main.world.tick
	for i in 5:
		await get_tree().process_frame
	check("paused sim is frozen", main.world.tick == t0)
	main._resume()
	check("resume", main.state == 1)
	main.world.pending_levelups = 1
	main.world.roll_choices()
	await get_tree().process_frame
	check("level-up overlay", main.state == 3 and main.screens.levelup.visible)
	main._on_choice(0)
	check("choice resumes the run", main.state == 1 and main.world.pending_levelups == 0)
	var gold0 := int(Save.data.gold)
	main.world.gold_run = 10.0
	main._abandon()
	check("abandon -> END with rewards banked", main.state == 4 and int(Save.data.gold) == gold0 + 10)
	main._to_menu()
	await get_tree().process_frame
	check("back to MENU, run torn down", main.state == 0 and main.view == null and main.world == null)
	Save.data.gold = gold0
	Save.save_profile()
	main.queue_free()
	await get_tree().process_frame
