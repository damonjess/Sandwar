class_name GameDefs
extends RefCounted

## Central balance data for Sandwar, a Dune 2000 style RTS prototype.

const TILE := 40
## The battlefield grid is configured per campaign mission before the battle
## scene is built. Skirmish and tools keep the classic 56 x 56 map.
static var MAP := 56
static var WORLD := MAP * TILE

static func set_map_size(value: int) -> void:
	MAP = clampi(value, 40, 72)
	WORLD = MAP * TILE

const PLAYER := 0
const ENEMY := 1

## House ids for team 0 and team 1. CampaignState overwrites this at the start
## of every battle; the defaults keep tools and standalone checks playable.
static var team_houses: Array = [Factions.ATREIDES, Factions.HARKONNEN]
static var tech_level := 99

## ------------------------------------------------------------ UI typography
## A phone renders the same 1280x720 logical canvas on a much smaller panel, so
## HUD and menu text scales up there while desktop keeps its authored sizes.
const UI_PHONE_SCALE := 1.22
## Layout-check hook: a value above zero forces a scale on any device.
static var ui_scale_override := 0.0

static func ui_scale() -> float:
	if ui_scale_override > 0.0:
		return ui_scale_override
	if OS.has_feature("mobile") or DisplayServer.is_touchscreen_available():
		return UI_PHONE_SCALE
	return 1.0

## Device-aware UI font size. The 12 px floor keeps every readable label legible.
static func fs(px: int) -> int:
	return maxi(12, int(round(float(px) * ui_scale())))

## Shortens text down to the last word that still fits max_lines and appends an
## ellipsis, so scaled-down phone layouts clip flavour text deliberately.
static func fit_text(font: Font, text: String, width: float, font_size: int, max_lines: int) -> String:
	if max_lines <= 0 or text.strip_edges() == "":
		return ""
	var clamped := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, max_lines).y
	var full := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, -1).y
	if full <= clamped:
		return text
	var lo := 0
	var hi := text.length()
	while lo < hi:
		var mid := int((lo + hi + 1) / 2)
		var probe := text.substr(0, mid).strip_edges() + "…"
		var probe_full := font.get_multiline_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, -1).y
		var probe_clamped := font.get_multiline_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, max_lines).y
		if probe_full <= probe_clamped:
			lo = mid
		else:
			hi = mid - 1
	if lo <= 0:
		return ""
	var cut := text.substr(0, lo)
	# Break on a word boundary so the ellipsis never lands inside a word.
	var space := cut.rfind(" ")
	if space > 0:
		cut = cut.substr(0, space)
	return cut.strip_edges() + "…"

## Set by the CampaignState autoload. Using a plain node reference keeps the
## gameplay scripts loadable by --check-only, where autoload globals do not
## exist, and keeps the house selection reachable from tools as well.
static var campaign: Node = null

static func house_for_team(team: int) -> String:
	return String(team_houses[clampi(team, 0, team_houses.size() - 1)])

static func team_color(team: int) -> Color:
	return Factions.color(house_for_team(team))

static func team_name(team: int) -> String:
	return Factions.display_name(house_for_team(team))

## Buildable units for a house, filtered by tech level. The shared core
## (infantry, rocketeers, siege tanks, harvesters) appears for every house;
## the uniques are listed in Factions.HOUSES.
static func unit_roster(house: String, tech := -1) -> Array:
	var limit := tech_level if tech < 0 else tech
	var out: Array = []
	for id in Factions.roster(house):
		if not UNITS.has(id):
			continue
		if int(UNITS[id].get("tech", 1)) > limit:
			continue
		out.append(id)
	return out

## Tech gating for every buildable entry, shared by the sidebar and the
## production checks so a hidden item can never be queued by touch.
static func item_tech(kind: String, id: String) -> int:
	if kind == "structure":
		return int(STRUCTURES.get(id, {}).get("tech", 1))
	if kind == "brush":
		return int(BRUSHES.get(id, {}).get("tech", 1))
	return int(UNITS.get(id, {}).get("tech", 1))

static func tech_available(kind: String, id: String, tech := -1) -> bool:
	var limit := tech_level if tech < 0 else tech
	return item_tech(kind, id) <= limit

static func structure_items(tech := -1) -> Array:
	var limit := tech_level if tech < 0 else tech
	var out: Array = []
	for id in ["windtrap", "refinery", "silo", "barracks", "factory",
			"heavy_factory", "outpost", "repair_pad", "turret", "rocketturret",
			"starport", "hightech", "ix", "palace"]:
		if int(STRUCTURES[id].get("tech", 1)) <= limit:
			out.append(["structure", id])
	for id in ["slab", "wall"]:
		if int(BRUSHES[id].get("tech", 1)) <= limit:
			out.append(["brush", id])
	return out

## The single classic upgrade tier for a production building. Barracks and both
## factories expose one upgrade; an upgraded building unlocks its advanced
## roster globally for that team.
static func upgrade_for(id: String) -> Dictionary:
	return STRUCTURES.get(id, {}).get("upgrade", {})

## Mission tier at which a production upgrade becomes available. The upgrade
## button is hidden until this tier, so Mission 2 cannot buy the Light Factory
## upgrade that belongs to Mission 3.
static func upgrade_tech(id: String) -> int:
	return int(upgrade_for(id).get("tech", item_tech("structure", id)))

static func producer_for_unit(id: String) -> String:
	return String(UNITS.get(id, {}).get("producer", ""))

## Units that only appear once their producer has been upgraded. Returning an
## empty string means the unit is available as soon as its producer exists.
static func upgrade_required_for(id: String) -> String:
	return String(UNITS.get(id, {}).get("requires_upgrade", ""))

## The IX Research Centre is the second half of the super-vehicle gate: the
## Heavy Factory must be upgraded and IX must stand, exactly as in Dune 2000.
static func requires_ix(id: String) -> bool:
	return bool(UNITS.get(id, {}).get("requires_ix", false))

static func carryall_support(id: String) -> bool:
	return bool(UNITS.get(id, {}).get("support_carryall", false))

## Bullets bounce off concrete walls; only these weapons can breach them.
const WALL_IMMUNE_WEAPONS := ["small_arms", "heavy_rifle", "sniper", "gas"]

static func wall_immune(weapon: String) -> bool:
	return WALL_IMMUNE_WEAPONS.has(weapon)

static func player_roster() -> Array:
	return unit_roster(house_for_team(PLAYER))

const SAND := 0
const ROCK := 1

## What a weapon does to each kind of target - the counter triangle. Damage is
## multiplied by this before it lands, so rocketeers shred vehicles, quads mow
## down infantry and tanks level bases, and nothing is good at everything.
const WEAPONS := {
	"small_arms": {"infantry": 1.0, "vehicle": 0.35, "building": 0.30, "soft": 0.85},
	"rocket": {"infantry": 0.45, "vehicle": 1.0, "building": 0.55, "soft": 1.0},
	# Quad pods: small anti-vehicle rockets that also crack structures.
	"quad_rocket": {"infantry": 0.35, "vehicle": 1.0, "building": 0.85, "soft": 0.90},
	"cannon": {"infantry": 0.55, "vehicle": 0.90, "building": 1.0, "soft": 1.0},
	# Siege Tank: slow, long-range, punishing against infantry groups and bases.
	"artillery": {"infantry": 1.15, "vehicle": 0.80, "building": 1.15, "soft": 1.0},
	# Devastator: super-heavy anti-armour plasma with a wide fireball.
	"twin_plasma": {"infantry": 0.75, "vehicle": 1.25, "building": 0.90, "soft": 1.0},
	# House uniques.
	"sniper": {"infantry": 1.65, "vehicle": 0.35, "building": 0.20, "soft": 0.55},
	"heavy_rifle": {"infantry": 1.15, "vehicle": 0.32, "building": 0.26, "soft": 0.80},
	"demolition": {"infantry": 0.35, "vehicle": 0.25, "building": 2.80, "soft": 2.20},
	"sonic": {"infantry": 1.20, "vehicle": 0.95, "building": 0.55, "soft": 0.90},
	"gas": {"infantry": 0.20, "vehicle": 0.30, "building": 0.18, "soft": 0.30},
	# Palace Death Hand: a nuclear-scale area warhead. The raw impact values in
	# death_hand_impact() are deliberately high; this row makes them lethal to
	# structures and squads instead of falling back to small-arms multipliers.
	"death_hand": {"infantry": 3.0, "vehicle": 2.4, "building": 2.2, "soft": 2.4},
}

const ARMOUR_CLASS := {
	"infantry": "infantry",
	"rocket": "infantry",
	"fremen": "infantry",
	"sardaukar": "infantry",
	"saboteur": "infantry",
	"trike": "vehicle",
	"raider_trike": "vehicle",
	"quad": "vehicle",
	"tank": "vehicle",
	"atreides_tank": "vehicle",
	"harkonnen_tank": "vehicle",
	"ordos_tank": "vehicle",
	"sonic_tank": "vehicle",
	"devastator": "vehicle",
	"deviator": "vehicle",
	"harvester": "vehicle",
	"mcv": "vehicle",
}

## Footprint in tiles: square buildings just set "size"; non-square
## structures add w/h (Light Factory 3x2). The Wind Trap is 2x2.
static func size_of(id: String) -> Vector2i:
	var d: Dictionary = STRUCTURES[id]
	return Vector2i(int(d.get("w", d["size"])), int(d.get("h", d["size"])))

## Structures whose visuals come from a packed scene rather than the baked
## sheet. Everything else still blits the baked building sheet.
static func scene_of(id: String) -> String:
	return String(STRUCTURES[id].get("scene", ""))

static func damage_multiplier(weapon: String, target_class: String) -> float:
	var row: Dictionary = WEAPONS.get(weapon, WEAPONS["small_arms"])
	return float(row.get(target_class, 1.0))

const STRUCTURES := {
	"cy": {
		"name": "Construction Yard",
		"tech": 1,
		"cost": 1000,
		"build": 22.0,
		"hp": 900.0,
		"size": 3,
		"vision": 260.0,
		"drain": 0,
		"power": 70,
		"scene": "res://construction_yard.tscn",
	},
	"windtrap": {
		"name": "Wind Trap",
		"tech": 1,
		"cost": 225,
		"build": 10.0,
		"hp": 320.0,
		"size": 2,
		"vision": 220.0,
		"drain": 0,
		"power": 200,
		"armour": "soft",
		"scene": "res://wind_trap.tscn",
	},
	"refinery": {
		"name": "Refinery",
		"tech": 1,
		"cost": 600,
		"build": 14.0,
		"hp": 620.0,
		"size": 3,
		"w": 3,
		"h": 2,
		"vision": 240.0,
		"drain": 40,
		"scene": "res://refinery.tscn",
	},
	"barracks": {
		"name": "Barracks",
		"tech": 1,
		"cost": 400,
		"build": 10.0,
		"hp": 430.0,
		"size": 2,
		"vision": 220.0,
		"drain": 20,
		"upgrade": {"cost": 300, "time": 8.0, "name": "Barracks Upgrade", "tech": 2},
	},
	"factory": {
		"name": "Light Factory",
		"tech": 2,
		"cost": 700,
		"build": 16.0,
		"hp": 560.0,
		"size": 3,
		"w": 3,
		"h": 2,
		"vision": 240.0,
		"drain": 30,
		"upgrade": {"cost": 450, "time": 9.0, "name": "Light Factory Upgrade", "tech": 3},
	},
	"heavy_factory": {
		"name": "Heavy Factory",
		"tech": 3,
		"cost": 1200,
		"build": 24.0,
		"hp": 960.0,
		"size": 3,
		"vision": 260.0,
		"drain": 50,
		"armour": "building",
		"upgrade": {"cost": 700, "time": 11.0, "name": "Heavy Factory Upgrade", "tech": 4},
	},
	"silo": {
		"name": "Spice Silo",
		"tech": 2,
		"cost": 150,
		"build": 5.0,
		"hp": 180.0,
		"size": 1,
		"vision": 120.0,
		"drain": 0,
		"armour": "soft",
		"storage": 1500,
	},
	"outpost": {
		"name": "Outpost",
		"tech": 2,
		"cost": 400,
		"build": 12.0,
		"hp": 460.0,
		"size": 2,
		"vision": 360.0,
		"drain": 40,
		"armour": "building",
		"power_dependent": true,
		"radar": true,
	},
	"repair_pad": {
		"name": "Repair Pad",
		"tech": 4,
		"cost": 500,
		"build": 15.0,
		"hp": 720.0,
		"size": 3,
		"vision": 180.0,
		"drain": 30,
		"armour": "building",
	},
	"turret": {
		"name": "Gun Turret",
		"tech": 3,
		"cost": 300,
		"build": 8.0,
		"hp": 380.0,
		"size": 1,
		"damage": 13.0,
		"range": 210.0,
		"cooldown": 1.2,
		"turn_rate": 8.0,
		"vision": 250.0,
		"drain": 0,
		"weapon": "cannon",
	},
	"rocketturret": {
		"name": "Rocket Turret",
		"tech": 4,
		"cost": 450,
		"build": 12.0,
		"hp": 300.0,
		"size": 1,
		"damage": 26.0,
		"range": 290.0,
		"cooldown": 2.6,
		"turn_rate": 3.5,
		"rocket_speed": 380.0,
		"splash": 56.0,
		"splash_fraction": 0.6,
		"vision": 300.0,
		"drain": 20,
		"power_dependent": true,
		"weapon": "rocket",
	},
	"starport": {
		"name": "Starport",
		"tech": 5,
		"cost": 1500,
		"build": 26.0,
		"hp": 1200.0,
		"size": 3,
		"vision": 300.0,
		"drain": 40,
		"armour": "building",
	},
	"hightech": {
		"name": "High Tech Factory",
		"tech": 5,
		"cost": 1400,
		"build": 24.0,
		"hp": 900.0,
		"size": 3,
		"w": 3,
		"h": 2,
		"vision": 280.0,
		"drain": 60,
		"armour": "soft",
		"upgrade": {"cost": 650, "time": 10.0, "name": "Ornithopter Upgrade", "tech": 5, "house": "atreides"},
	},
	"ix": {
		"name": "IX Research Centre",
		"tech": 6,
		"cost": 1300,
		"build": 26.0,
		"hp": 760.0,
		"size": 2,
		"vision": 260.0,
		"drain": 50,
		"armour": "soft",
		"power_dependent": true,
	},
	"palace": {
		"name": "Palace",
		"tech": 7,
		"cost": 1800,
		"build": 32.0,
		"hp": 1400.0,
		"size": 3,
		"vision": 340.0,
		"drain": 80,
		"armour": "building",
		"power_dependent": true,
	},
	"wall": {
		"name": "Wall",
		"tech": 3,
		"cost": 50,
		"build": 2.0,
		"hp": 280.0,
		"size": 1,
		"vision": 120.0,
		"drain": 0,
	},
}

## Instant placement brushes (no production queue).
const BRUSHES := {
	"slab": {"name": "Concrete", "tech": 1, "cost": 20},
	"wall": {"name": "Wall", "tech": 3, "cost": 50},
}

const UNITS := {
	"infantry": {
		"name": "Light Infantry",
		"cost": 60,
		"build": 5.0,
		"hp": 58.0,
		"speed": 58.0,
		"damage": 7.0,
		"range": 110.0,
		"cooldown": 0.75,
		"radius": 9.0,
		"vision": 210.0,
		"producer": "barracks",
		"weapon": "small_arms",
		"tech": 1,
	},
	"rocket": {
		"name": "Rocket Trooper",
		"cost": 90,
		"build": 6.0,
		"hp": 52.0,
		"speed": 49.0,
		"damage": 17.0,
		"range": 175.0,
		"cooldown": 1.5,
		"radius": 9.0,
		"vision": 235.0,
		"producer": "barracks",
		"requires_upgrade": "barracks",
		"weapon": "rocket",
		"tech": 2,
	},
	"quad": {
		"name": "Quad",
		"cost": 200,
		"build": 9.0,
		"hp": 105.0,
		"speed": 138.0,
		"damage": 11.0,
		"range": 145.0,
		"cooldown": 1.55,
		"radius": 12.0,
		"vision": 300.0,
		"producer": "factory",
		"requires_upgrade": "factory",
		"weapon": "quad_rocket",
		"splash": 26.0,
		"splash_fraction": 0.45,
		"tech": 3,
	},
	"tank": {
		"name": "Siege Tank",
		"cost": 520,
		"build": 22.0,
		"hp": 430.0,
		"speed": 52.0,
		"damage": 44.0,
		"range": 270.0,
		"cooldown": 2.8,
		"radius": 18.0,
		"vision": 300.0,
		"producer": "heavy_factory",
		"requires_upgrade": "heavy_factory",
		"weapon": "artillery",
		"splash": 68.0,
		"splash_fraction": 0.65,
		"tech": 4,
	},
	"trike": {
		"name": "Trike",
		"cost": 150,
		"build": 8.0,
		"hp": 115.0,
		"speed": 118.0,
		"damage": 10.0,
		"range": 135.0,
		"cooldown": 0.95,
		"radius": 12.0,
		"vision": 280.0,
		"producer": "factory",
		"weapon": "small_arms",
		"tech": 2,
	},
	"harvester": {
		"name": "Harvester",
		"cost": 400,
		"build": 13.0,
		"hp": 240.0,
		"speed": 44.0,
		"damage": 0.0,
		"range": 0.0,
		"cooldown": 1.0,
		"radius": 15.0,
		"vision": 200.0,
		"producer": "heavy_factory",
		"weapon": "small_arms",
		"tech": 3,
	},
	"carryall": {
		"name": "Carryall",
		"cost": 500,
		"build": 12.0,
		"hp": 180.0,
		"speed": 220.0,
		"damage": 0.0,
		"range": 0.0,
		"cooldown": 1.0,
		"radius": 18.0,
		"vision": 300.0,
		"producer": "hightech",
		"weapon": "small_arms",
		"support_carryall": true,
		"tech": 5,
	},
	"mcv": {
		"name": "Mobile Construction Vehicle",
		"cost": 900,
		"build": 26.0,
		"hp": 620.0,
		"speed": 34.0,
		"damage": 0.0,
		"range": 0.0,
		"cooldown": 1.0,
		"radius": 22.0,
		"vision": 240.0,
		"producer": "heavy_factory",
		"requires_upgrade": "heavy_factory",
		"weapon": "small_arms",
		"tech": 4,
	},

	# ---------------------------------------------------------- house uniques
	# Atreides: balanced, precise, line-breaking.
	"atreides_tank": {
		"name": "Atreides Combat Tank",
		"cost": 620,
		"build": 20.0,
		"hp": 480.0,
		"speed": 60.0,
		"damage": 36.0,
		"range": 200.0,
		"cooldown": 1.8,
		"radius": 18.0,
		"vision": 265.0,
		"producer": "heavy_factory",
		"weapon": "cannon",
		"tech": 3,
	},
	"fremen": {
		"name": "Fremen",
		"cost": 260,
		"build": 11.0,
		"hp": 95.0,
		"speed": 62.0,
		"damage": 44.0,
		"range": 235.0,
		"cooldown": 2.0,
		"radius": 9.0,
		"vision": 300.0,
		"producer": "barracks",
		"requires_upgrade": "barracks",
		"weapon": "sniper",
		"stealth": 120.0,
		"tech": 5,
	},
	"sonic_tank": {
		"name": "Sonic Tank",
		"cost": 900,
		"build": 28.0,
		"hp": 520.0,
		"speed": 44.0,
		"damage": 55.0,
		"range": 170.0,
		"cooldown": 2.6,
		"radius": 19.0,
		"vision": 260.0,
		"producer": "heavy_factory",
		"requires_upgrade": "heavy_factory",
		"weapon": "sonic",
		"special": "sonic",
		"requires_ix": true,
		"tech": 6,
	},

	# Harkonnen: heavy plate, slow, devastating guns.
	"harkonnen_tank": {
		"name": "Harkonnen Combat Tank",
		"cost": 650,
		"build": 22.0,
		"hp": 576.0,
		"speed": 54.0,
		"damage": 41.4,
		"range": 198.0,
		"cooldown": 2.0,
		"radius": 19.0,
		"vision": 260.0,
		"producer": "heavy_factory",
		"weapon": "cannon",
		"tech": 3,
	},
	"sardaukar": {
		"name": "Sardaukar",
		"cost": 240,
		"build": 10.0,
		"hp": 155.0,
		"speed": 52.0,
		"damage": 15.0,
		"range": 150.0,
		"cooldown": 0.40,
		"radius": 10.0,
		"vision": 240.0,
		"producer": "barracks",
		"requires_upgrade": "barracks",
		"weapon": "heavy_rifle",
		"tech": 5,
	},
	"devastator": {
		"name": "Devastator",
		"cost": 1100,
		"build": 34.0,
		"hp": 900.0,
		"speed": 38.0,
		"damage": 65.0,
		"range": 210.0,
		"cooldown": 2.9,
		"radius": 22.0,
		"vision": 270.0,
		"producer": "heavy_factory",
		"requires_upgrade": "heavy_factory",
		"weapon": "twin_plasma",
		"splash": 64.0,
		"splash_fraction": 0.55,
		"requires_ix": true,
		"tech": 6,
	},

	# Ordos: fast, cheap, underhanded.
	"raider_trike": {
		"name": "Raider Trike",
		"cost": 130,
		"build": 7.0,
		"hp": 100.0,
		"speed": 138.0,
		"damage": 9.0,
		"range": 132.0,
		"cooldown": 0.70,
		"radius": 12.0,
		"vision": 300.0,
		"producer": "factory",
		"weapon": "small_arms",
		"tech": 2,
	},
	"ordos_tank": {
		"name": "Ordos Combat Tank",
		"cost": 600,
		"build": 19.0,
		"hp": 420.0,
		"speed": 72.0,
		"damage": 34.0,
		"range": 195.0,
		"cooldown": 1.7,
		"radius": 17.0,
		"vision": 270.0,
		"producer": "heavy_factory",
		"weapon": "cannon",
		"tech": 3,
	},
	"saboteur": {
		"name": "Saboteur",
		"cost": 200,
		"build": 9.0,
		"hp": 72.0,
		"speed": 86.0,
		"damage": 26.0,
		"range": 95.0,
		"cooldown": 1.7,
		"radius": 9.0,
		"vision": 240.0,
		"producer": "barracks",
		"requires_upgrade": "barracks",
		"weapon": "demolition",
		"tech": 5,
	},
	"deviator": {
		"name": "Deviator",
		"cost": 750,
		"build": 24.0,
		"hp": 330.0,
		"speed": 56.0,
		"damage": 18.0,
		"range": 300.0,
		"cooldown": 4.2,
		"radius": 16.0,
		"vision": 300.0,
		"producer": "heavy_factory",
		"requires_upgrade": "heavy_factory",
		"weapon": "gas",
		"special": "deviate",
		"requires_ix": true,
		"tech": 6,
	},
}
