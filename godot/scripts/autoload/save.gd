extends Node
## Persistent profile (user://save.json): currencies, unlocks, upgrades, settings.

const PATH := "user://save.json"
const VERSION := 1

var data := {}


func _ready() -> void:
	load_profile()


func defaults() -> Dictionary:
	return {
		"version": VERSION,
		"gold": 0, "echoes": 0,
		"heroes": ["warden"], "hero": "warden",
		"act": 0, "act_unlocked": 0, "mode": "story",
		"upgrades": {"hp": 0, "dmg": 0, "xp": 0, "gold": 0},
		"best": {},
		"settings": {
			"quality": -1,          # -1 = auto-detect, else Quality.Tier
			"gles_safe": false,
			"joystick": "floating", # or "fixed"
			"ui_scale": 1.0,
			"music": 0.6, "sfx": 0.8,
			"show_fps": false,
		},
	}


func load_profile() -> void:
	data = defaults()
	if not FileAccess.file_exists(PATH):
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("save.json unreadable; starting a fresh profile")
		return
	_merge(data, parsed)


func _merge(dst: Dictionary, src: Dictionary) -> void:
	for k in src:
		if dst.has(k) and typeof(dst[k]) == TYPE_DICTIONARY and typeof(src[k]) == TYPE_DICTIONARY:
			_merge(dst[k], src[k])
		else:
			dst[k] = src[k]


func save_profile() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("Could not write %s" % PATH)
		return
	f.store_string(JSON.stringify(data, "\t"))


func setting(key: String):
	return data.settings.get(key, defaults().settings.get(key))


func set_setting(key: String, v) -> void:
	data.settings[key] = v
	save_profile()


func has_hero(id: String) -> bool:
	return id in data.heroes


func buy_hero(id: String) -> bool:
	var cost := int(Content.hero(id).cost)
	if has_hero(id) or int(data.gold) < cost:
		return false
	data.gold = int(data.gold) - cost
	data.heroes.append(id)
	save_profile()
	return true


func upgrade_cost(id: String) -> int:
	var u: Dictionary = Content.UPGRADES[id]
	return int(u.cost) * (int(data.upgrades.get(id, 0)) + 1)


func buy_upgrade(id: String) -> bool:
	var lvl := int(data.upgrades.get(id, 0))
	if lvl >= int(Content.UPGRADES[id].max):
		return false
	var cost := upgrade_cost(id)
	if int(data.gold) < cost:
		return false
	data.gold = int(data.gold) - cost
	data.upgrades[id] = lvl + 1
	save_profile()
	return true


func record_run(act: int, won: bool, gold: int, echoes: int, time_s: float, kills: int) -> void:
	data.gold = int(data.gold) + gold
	data.echoes = int(data.echoes) + echoes
	if won and act >= int(data.act_unlocked) and act < Content.ACTS.size() - 1:
		data.act_unlocked = act + 1
	var key := str(act)
	var best: Dictionary = data.best.get(key, {"time": 0.0, "kills": 0})
	best.time = maxf(float(best.time), time_s)
	best.kills = maxi(int(best.kills), kills)
	data.best[key] = best
	save_profile()
