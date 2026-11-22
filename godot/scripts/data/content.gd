class_name Content
extends RefCounted
## Static game content: heroes, acts, foes, weapons, passives, evolutions.
## Pure data, no engine state. Every system reads from here.

enum Elem { PHYS, FIRE, COLD, LIGHT, CHAOS }
const ELEM_NAMES := ["PHYS", "FIRE", "COLD", "LIGHT", "CHAOS"]
const ELEM_COLORS := [
	Color(0.92, 0.88, 0.80), Color(1.0, 0.48, 0.18), Color(0.55, 0.85, 1.0),
	Color(1.0, 0.92, 0.35), Color(0.78, 0.40, 1.0),
]

const HERO_ORDER := ["warden", "spark", "ember", "storm"]
const HEROES := {
	"warden": {
		"name": "Warden", "title": "Shield of the Verge", "elem": Elem.PHYS,
		"hp": 160.0, "speed": 138.0, "armor": 3.0, "weapon": "blades",
		"skill": "bulwark", "ult": "earthsplit",
		"color": Color(0.80, 0.70, 0.52), "accent": Color(0.95, 0.80, 0.40), "cost": 0,
	},
	"spark": {
		"name": "Sparkcaller", "title": "Voice of the Storm", "elem": Elem.LIGHT,
		"hp": 110.0, "speed": 150.0, "armor": 0.0, "weapon": "chain",
		"skill": "blink", "ult": "skyfall",
		"color": Color(0.40, 0.52, 0.82), "accent": Color(1.0, 0.92, 0.35), "cost": 400,
	},
	"ember": {
		"name": "Emberwitch", "title": "Keeper of Cinders", "elem": Elem.FIRE,
		"hp": 120.0, "speed": 144.0, "armor": 1.0, "weapon": "ember",
		"skill": "flamewave", "ult": "inferno",
		"color": Color(0.62, 0.22, 0.18), "accent": Color(1.0, 0.55, 0.20), "cost": 600,
	},
	"storm": {
		"name": "Stormwright", "title": "Breaker of Tides", "elem": Elem.COLD,
		"hp": 130.0, "speed": 142.0, "armor": 2.0, "weapon": "frost",
		"skill": "frostring", "ult": "maelstrom",
		"color": Color(0.30, 0.55, 0.62), "accent": Color(0.60, 0.90, 1.0), "cost": 800,
	},
}

## Five themed acts. Terrain parameters are mirrored by shaders/3d/terrain_h.gdshaderinc.
const ACTS := [
	{
		"name": "Ashen Verge", "liquid": "water", "level0": -20.0, "tide_rate": 0.0, "tide_max": 0.0,
		"amp": 44.0, "seeds": Vector4(0.3, 1.7, 2.9, 4.1), "plateau": 34.0, "patch": "spikes",
		"ground": Color(0.42, 0.45, 0.30), "ground2": Color(0.36, 0.31, 0.24),
		"liquid_color": Color(0.16, 0.30, 0.36), "sky_top": Color(0.36, 0.46, 0.62),
		"sky_horizon": Color(0.66, 0.66, 0.66), "ground_bottom": Color(0.16, 0.12, 0.09),
		"sun": Color(1.0, 0.93, 0.82), "fog": Color(0.55, 0.58, 0.60), "dead_tree": 0.25,
		"boss": "gravelord", "foe_mix": [5, 3, 2, 1, 1],
	},
	{
		"name": "Cinder Wastes", "liquid": "lava", "level0": -24.0, "tide_rate": 0.0, "tide_max": 0.0,
		"amp": 52.0, "seeds": Vector4(2.2, 0.4, 5.3, 1.1), "plateau": 40.0, "patch": "oil",
		"ground": Color(0.38, 0.30, 0.26), "ground2": Color(0.24, 0.20, 0.19),
		"liquid_color": Color(1.0, 0.36, 0.08), "sky_top": Color(0.40, 0.30, 0.30),
		"sky_horizon": Color(0.70, 0.52, 0.40), "ground_bottom": Color(0.18, 0.08, 0.05),
		"sun": Color(1.0, 0.80, 0.62), "fog": Color(0.50, 0.36, 0.30), "dead_tree": 0.85,
		"boss": "pyre_colossus", "foe_mix": [4, 3, 2, 3, 2],
	},
	{
		"name": "Frostmere", "liquid": "none", "level0": -999.0, "tide_rate": 0.0, "tide_max": 0.0,
		"amp": 40.0, "seeds": Vector4(4.4, 3.1, 0.7, 2.6), "plateau": 30.0, "patch": "spikes",
		"ground": Color(0.70, 0.74, 0.78), "ground2": Color(0.48, 0.52, 0.58),
		"liquid_color": Color(0.5, 0.7, 0.8), "sky_top": Color(0.42, 0.54, 0.70),
		"sky_horizon": Color(0.78, 0.82, 0.86), "ground_bottom": Color(0.20, 0.20, 0.24),
		"sun": Color(0.92, 0.96, 1.0), "fog": Color(0.70, 0.76, 0.82), "dead_tree": 0.6,
		"boss": "rimeheart", "foe_mix": [3, 4, 3, 2, 2],
	},
	{
		"name": "Drowned Reach", "liquid": "water", "level0": -18.0, "tide_rate": 0.05, "tide_max": 14.0,
		"amp": 46.0, "seeds": Vector4(1.3, 5.2, 3.8, 0.2), "plateau": 42.0, "patch": "oil",
		"ground": Color(0.34, 0.40, 0.34), "ground2": Color(0.28, 0.30, 0.27),
		"liquid_color": Color(0.12, 0.26, 0.30), "sky_top": Color(0.30, 0.40, 0.50),
		"sky_horizon": Color(0.58, 0.62, 0.64), "ground_bottom": Color(0.10, 0.12, 0.12),
		"sun": Color(0.92, 0.95, 1.0), "fog": Color(0.42, 0.50, 0.54), "dead_tree": 0.4,
		"boss": "tidewarden", "foe_mix": [3, 3, 3, 3, 3],
	},
	{
		"name": "Rift Heart", "liquid": "poison", "level0": -22.0, "tide_rate": 0.0, "tide_max": 0.0,
		"amp": 50.0, "seeds": Vector4(3.6, 2.4, 1.9, 5.5), "plateau": 38.0, "patch": "spikes",
		"ground": Color(0.32, 0.26, 0.38), "ground2": Color(0.22, 0.18, 0.26),
		"liquid_color": Color(0.40, 0.85, 0.30), "sky_top": Color(0.30, 0.24, 0.42),
		"sky_horizon": Color(0.56, 0.44, 0.62), "ground_bottom": Color(0.12, 0.08, 0.14),
		"sun": Color(0.95, 0.85, 1.0), "fog": Color(0.40, 0.32, 0.48), "dead_tree": 0.7,
		"boss": "shard_sovereign", "foe_mix": [3, 3, 3, 3, 4],
	},
]

const FOE_ORDER := ["grunt", "runner", "brute", "spitter", "charger"]
const FOES := {
	"grunt": {"hp": 22.0, "speed": 74.0, "dmg": 8.0, "radius": 11.0, "xp": 1.0, "height": 28.0, "color": Color(0.55, 0.50, 0.42)},
	"runner": {"hp": 14.0, "speed": 118.0, "dmg": 6.0, "radius": 9.0, "xp": 1.0, "height": 24.0, "color": Color(0.62, 0.44, 0.34)},
	"brute": {"hp": 90.0, "speed": 52.0, "dmg": 16.0, "radius": 17.0, "xp": 4.0, "height": 42.0, "color": Color(0.46, 0.40, 0.40)},
	"spitter": {"hp": 26.0, "speed": 64.0, "dmg": 9.0, "radius": 11.0, "xp": 2.0, "height": 30.0, "color": Color(0.40, 0.52, 0.36)},
	"charger": {"hp": 40.0, "speed": 70.0, "dmg": 14.0, "radius": 13.0, "xp": 3.0, "height": 34.0, "color": Color(0.58, 0.36, 0.30)},
}

const BOSSES := {
	"gravelord": {"name": "The Gravelord", "hp": 2600.0, "speed": 58.0, "elem": Elem.PHYS, "color": Color(0.52, 0.48, 0.42)},
	"pyre_colossus": {"name": "Pyre Colossus", "hp": 3200.0, "speed": 54.0, "elem": Elem.FIRE, "color": Color(0.60, 0.28, 0.16)},
	"rimeheart": {"name": "Rimeheart", "hp": 3600.0, "speed": 60.0, "elem": Elem.COLD, "color": Color(0.52, 0.66, 0.76)},
	"tidewarden": {"name": "The Tidewarden", "hp": 4100.0, "speed": 62.0, "elem": Elem.LIGHT, "color": Color(0.26, 0.42, 0.46)},
	"shard_sovereign": {"name": "Shard Sovereign", "hp": 5000.0, "speed": 66.0, "elem": Elem.CHAOS, "color": Color(0.46, 0.26, 0.56)},
}

## Weapons. `cd` is seconds between fires; damage and count scale per level (1..5).
const WEAPONS := {
	"bolt": {"name": "Shard Bolt", "elem": Elem.CHAOS, "dmg": 14.0, "cd": 0.95, "desc": "Seeking shards at the nearest foe.", "evolve_with": "focus", "evolves_to": "rift_lance"},
	"nova": {"name": "Pulse Nova", "elem": Elem.PHYS, "dmg": 16.0, "cd": 2.6, "desc": "A ring of force around you.", "evolve_with": "vigor", "evolves_to": "cataclysm"},
	"blades": {"name": "Warden Blades", "elem": Elem.PHYS, "dmg": 11.0, "cd": 0.0, "desc": "Blades orbit and cut.", "evolve_with": "haste", "evolves_to": "bladestorm"},
	"chain": {"name": "Chain Spark", "elem": Elem.LIGHT, "dmg": 13.0, "cd": 1.25, "desc": "Lightning leaps between foes.", "evolve_with": "might", "evolves_to": "thunderweb"},
	"ember": {"name": "Ember Pool", "elem": Elem.FIRE, "dmg": 18.0, "cd": 2.2, "desc": "Burning ground under the pack.", "evolve_with": "magnet", "evolves_to": "hellmouth"},
	"frost": {"name": "Frost Fan", "elem": Elem.COLD, "dmg": 10.0, "cd": 1.1, "desc": "A fan of chilling shards.", "evolve_with": "swift", "evolves_to": "glacier"},
}
const EVOLUTIONS := {
	"rift_lance": {"name": "Rift Lance", "base": "bolt", "mult": 2.2},
	"cataclysm": {"name": "Cataclysm", "base": "nova", "mult": 2.4},
	"bladestorm": {"name": "Bladestorm", "base": "blades", "mult": 2.0},
	"thunderweb": {"name": "Thunderweb", "base": "chain", "mult": 2.1},
	"hellmouth": {"name": "Hellmouth", "base": "ember", "mult": 2.3},
	"glacier": {"name": "Glacier", "base": "frost", "mult": 2.2},
}
const MAX_WEAPON_LVL := 5
const MAX_WEAPONS := 4

const PASSIVES := {
	"might": {"name": "Might", "desc": "+12% damage", "max": 5},
	"haste": {"name": "Haste", "desc": "-8% weapon cooldown", "max": 5},
	"vigor": {"name": "Vigor", "desc": "+20 max HP, heal 20", "max": 5},
	"swift": {"name": "Swift", "desc": "+7% move speed", "max": 5},
	"magnet": {"name": "Magnet", "desc": "+35% pickup radius", "max": 5},
	"focus": {"name": "Focus", "desc": "+1 projectile every 2 ranks", "max": 4},
	"ward": {"name": "Ward", "desc": "+2 armor", "max": 4},
}

## Persistent meta upgrades bought with Gold (shown under the Upgrades sub-menu).
const UPGRADES := {
	"hp": {"name": "Hardened", "desc": "+8% max HP per rank", "max": 5, "cost": 120},
	"dmg": {"name": "Honed", "desc": "+6% damage per rank", "max": 5, "cost": 150},
	"xp": {"name": "Insight", "desc": "+8% XP per rank", "max": 5, "cost": 100},
	"gold": {"name": "Greed", "desc": "+10% gold per rank", "max": 5, "cost": 90},
}

## Modes sub-menu entries.
const MODES := {
	"story": {"name": "Story", "desc": "Clear the act, slay its boss."},
	"endless": {"name": "Endless Delve", "desc": "No boss timer. Survive as long as you can."},
}


static func hero(id: String) -> Dictionary:
	return HEROES.get(id, HEROES["warden"])


static func act(i: int) -> Dictionary:
	return ACTS[clampi(i, 0, ACTS.size() - 1)]


static func weapon_damage(id: String, lvl: int) -> float:
	if EVOLUTIONS.has(id):
		var e: Dictionary = EVOLUTIONS[id]
		return float(WEAPONS[e.base].dmg) * float(e.mult) * 1.6
	return float(WEAPONS[id].dmg) * (1.0 + 0.28 * float(lvl - 1))


static func weapon_base(id: String) -> String:
	if EVOLUTIONS.has(id):
		return String(EVOLUTIONS[id].base)
	return id


static func weapon_name(id: String) -> String:
	if EVOLUTIONS.has(id):
		return String(EVOLUTIONS[id].name)
	return String(WEAPONS[id].name)
