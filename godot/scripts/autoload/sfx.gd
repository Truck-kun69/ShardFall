extends Node
## Procedurally synthesised audio ($0 assets). SFX run through a 5-voice pool
## with oldest-voice stealing; each voice has its own panner bus for stereo
## placement in play_at(). XP pickups climb in pitch while a combo continues.

const VOICES := 5
const RATE := 22050
const PAN_RANGE := 520.0
const XP_PITCH_MAX := 1.9
const XP_PITCH_STEP := 0.045
const XP_COMBO_T := 0.8

var streams := {}
var _voices: Array[AudioStreamPlayer] = []
var _started := PackedFloat64Array()
var _pan_fx: Array[AudioEffectPanner] = []
var _ui: AudioStreamPlayer
var _music: AudioStreamPlayer
var _xp_pitch := 1.0
var _xp_combo := 0.0
var _clock := 0.0
var steals := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()
	_synth_all()
	_started.resize(VOICES)
	for i in VOICES:
		var bus_name := "SFX_V%d" % i
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "SFX")
			AudioServer.add_bus_effect(idx, AudioEffectPanner.new())
		var bi := AudioServer.get_bus_index(bus_name)
		_pan_fx.append(AudioServer.get_bus_effect(bi, 0) as AudioEffectPanner)
		var p := AudioStreamPlayer.new()
		p.bus = bus_name
		add_child(p)
		_voices.append(p)
		_started[i] = -1.0
	_ui = AudioStreamPlayer.new()
	_ui.bus = "UI"
	add_child(_ui)
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	_music.stream = streams.music
	add_child(_music)
	apply_volumes()


func stop_all() -> void:
	for v in _voices:
		v.stop()
	_ui.stop()


func _exit_tree() -> void:
	if _music != null:
		_music.stop()
		_music.stream = null
	for v in _voices:
		v.stop()
		v.stream = null
	_ui.stop()


func _ensure_buses() -> void:
	for b in ["Music", "SFX", "UI"]:
		if AudioServer.get_bus_index(b) == -1:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, b)
			AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")


func apply_volumes() -> void:
	var m := float(Save.setting("music"))
	var s := float(Save.setting("sfx"))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(maxf(m, 0.0001)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(maxf(s, 0.0001)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("UI"), linear_to_db(maxf(s, 0.0001)))


func _process(dt: float) -> void:
	_clock += dt
	if _xp_combo > 0.0:
		_xp_combo -= dt
		if _xp_combo <= 0.0:
			_xp_pitch = 1.0


func music(on: bool) -> void:
	# Headless runs (CI/tests) have no audio device; never leave a stream
	# playing there, or the engine reports the live playback as a leak at exit.
	if DisplayServer.get_name() == "headless":
		return
	if on and not _music.playing:
		_music.play()
	elif not on:
		_music.stop()
		_music.stream = null


## Picks a free voice, else steals the one that started longest ago.
func _voice() -> int:
	var best := 0
	var oldest := INF
	for i in VOICES:
		if not _voices[i].playing:
			return i
		if _started[i] < oldest:
			oldest = _started[i]
			best = i
	steals += 1
	return best


func play(id: String, pitch: float = 1.0, vol_db: float = 0.0) -> int:
	return play_at(id, Vector2.ZERO, Vector2.ZERO, pitch, vol_db)


## Stereo-panned one-shot relative to the listener (hero) position.
func play_at(id: String, at: Vector2, listener: Vector2, pitch: float = 1.0, vol_db: float = 0.0) -> int:
	if not streams.has(id):
		return -1
	var v := _voice()
	_pan_fx[v].pan = clampf((at.x - listener.x) / PAN_RANGE, -1.0, 1.0)
	var p := _voices[v]
	p.stream = streams[id]
	p.pitch_scale = pitch
	p.volume_db = vol_db
	p.play()
	_started[v] = _clock
	_clock += 0.000001   # strict ordering for same-frame plays
	return v


func xp_pickup() -> void:
	play("xp", _xp_pitch, -6.0)
	_xp_pitch = minf(_xp_pitch + XP_PITCH_STEP, XP_PITCH_MAX)
	_xp_combo = XP_COMBO_T


func xp_pitch() -> float:
	return _xp_pitch


func ui(id: String = "ui") -> void:
	if streams.has(id):
		_ui.stream = streams[id]
		_ui.play()


func voice_count() -> int:
	return _voices.size()


func voice_started(i: int) -> float:
	return _started[i]


# ----------------------------------------------------------------------------
# Synthesis
# ----------------------------------------------------------------------------
func _wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w


func _tone(dur: float, f0: float, f1: float, noise: float, decay: float, shape: String = "sin") -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(f0 * 13.0 + f1)
	for i in n:
		var t := float(i) / float(n)
		var f := lerpf(f0, f1, t)
		ph += f / float(RATE)
		var s := 0.0
		match shape:
			"sin":
				s = sin(ph * TAU)
			"sq":
				s = 1.0 if fposmod(ph, 1.0) < 0.5 else -1.0
			"saw":
				s = fposmod(ph, 1.0) * 2.0 - 1.0
		s = lerpf(s, rng.randf_range(-1.0, 1.0), noise)
		var env := exp(-t * decay) * minf(t * 60.0, 1.0)
		out[i] = s * env * 0.7
	return out


func _synth_all() -> void:
	streams.hit = _wav(_tone(0.08, 420.0, 160.0, 0.55, 6.0))
	streams.shoot = _wav(_tone(0.10, 900.0, 420.0, 0.15, 5.0, "sq"))
	streams.xp = _wav(_tone(0.09, 1250.0, 1650.0, 0.0, 4.0))
	streams.levelup = _wav(_tone(0.55, 520.0, 1040.0, 0.0, 2.5, "saw"))
	streams.roll = _wav(_tone(0.18, 300.0, 120.0, 0.7, 4.0))
	streams.jump = _wav(_tone(0.16, 240.0, 520.0, 0.2, 4.0))
	streams.land = _wav(_tone(0.14, 140.0, 60.0, 0.6, 5.0))
	streams.hurt = _wav(_tone(0.16, 220.0, 110.0, 0.3, 4.0, "saw"))
	streams.die = _wav(_tone(0.12, 260.0, 90.0, 0.6, 5.0))
	streams.perfect = _wav(_tone(0.35, 880.0, 1760.0, 0.0, 3.0))
	streams.nova = _wav(_tone(0.30, 180.0, 70.0, 0.5, 3.0))
	streams.ult = _wav(_tone(0.8, 110.0, 40.0, 0.4, 2.0, "saw"))
	streams.boss = _wav(_tone(0.9, 70.0, 50.0, 0.35, 1.6, "saw"))
	streams.react = _wav(_tone(0.2, 700.0, 300.0, 0.3, 4.0, "sq"))
	streams.ui = _wav(_tone(0.05, 900.0, 1100.0, 0.0, 6.0))
	streams.victory = _wav(_tone(1.0, 440.0, 880.0, 0.0, 1.5, "saw"))
	# Music: a slow two-chord drone pad, looped seamlessly.
	var dur := 8.0
	var n := int(dur * RATE)
	var m := PackedFloat32Array()
	m.resize(n)
	for i in n:
		var t := float(i) / float(RATE)
		var chord := 0 if t < dur * 0.5 else 1
		var root := 55.0 if chord == 0 else 49.0
		var s := sin(TAU * root * t) * 0.35 + sin(TAU * root * 1.5 * t) * 0.2 + sin(TAU * root * 2.0 * t + sin(t * 0.7)) * 0.12
		var xf := minf(minf(t, dur - t) * 4.0, 1.0) * 0.5 + 0.5
		m[i] = s * 0.35 * xf
	streams.music = _wav(m, true)
