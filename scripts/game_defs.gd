class_name GameDefs
extends RefCounted

## Central balance data for Sandwar, a Dune 2000 style RTS prototype.

const TILE := 40
const MAP := 56
const WORLD := MAP * TILE

const PLAYER := 0
const ENEMY := 1
const TEAM_COLORS := [Color(0.24, 0.46, 0.93), Color(0.9, 0.3, 0.22)]
const TEAM_NAMES := ["Atreides", "Harkonnen"]

const SAND := 0
const ROCK := 1

## What a weapon does to each kind of target - the counter triangle. Damage is
## multiplied by this before it lands, so rocketeers shred vehicles, quads mow
## down infantry and tanks level bases, and nothing is good at everything.
const WEAPONS := {
	"small_arms": {"infantry": 1.0, "vehicle": 0.35, "building": 0.30, "soft": 0.85},
	"rocket": {"infantry": 0.45, "vehicle": 1.0, "building": 0.55, "soft": 1.0},
	"cannon": {"infantry": 0.55, "vehicle": 0.90, "building": 1.0, "soft": 1.0},
}

const ARMOUR_CLASS := {
	"infantry": "infantry",
	"rocket": "infantry",
	"trike": "vehicle",
	"quad": "vehicle",
	"tank": "vehicle",
	"harvester": "vehicle",
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
		"cost": 400,
		"build": 10.0,
		"hp": 430.0,
		"size": 2,
		"vision": 220.0,
		"drain": 20,
	},
	"factory": {
		"name": "Light Factory",
		"cost": 700,
		"build": 16.0,
		"hp": 560.0,
		"size": 3,
		"w": 3,
		"h": 2,
		"vision": 240.0,
		"drain": 30,
	},
	"turret": {
		"name": "Gun Turret",
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
	"wall": {
		"name": "Wall",
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
	"slab": {"name": "Concrete", "cost": 20},
	"wall": {"name": "Wall", "cost": 50},
}

const UNITS := {
	"infantry": {
		"name": "Infantry",
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
		"weapon": "rocket",
	},
	"quad": {
		"name": "Quad",
		"cost": 200,
		"build": 9.0,
		"hp": 105.0,
		"speed": 138.0,
		"damage": 5.0,
		"range": 118.0,
		"cooldown": 0.42,
		"radius": 12.0,
		"vision": 300.0,
		"producer": "factory",
		"weapon": "small_arms",
	},
	"tank": {
		"name": "Siege Tank",
		"cost": 520,
		"build": 22.0,
		"hp": 430.0,
		"speed": 52.0,
		"damage": 34.0,
		"range": 195.0,
		"cooldown": 1.9,
		"radius": 18.0,
		"vision": 260.0,
		"producer": "factory",
		"weapon": "cannon",
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
		"producer": "factory",
		"weapon": "small_arms",
	},
}
