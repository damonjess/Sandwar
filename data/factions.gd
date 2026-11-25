class_name Factions
extends RefCounted

## The three Great Houses of Sandwar, modelled on Dune 2000.
##
## Everything house-specific lives here: the exact banner colour, the tactical
## brief shown on the House Selection screen, the buildable roster (shared core
## plus house uniques) and the scout each base starts with. GameDefs.UNITS owns
## the actual combat numbers; this file only decides who may build what.

const ATREIDES := "atreides"
const HARKONNEN := "harkonnen"
const ORDOS := "ordos"

const HOUSE_ORDER := [ATREIDES, HARKONNEN, ORDOS]

const HOUSES := {
	ATREIDES: {
		"name": "House Atreides",
		"short": "ATREIDES",
		"color": Color(46.0 / 255.0, 107.0 / 255.0, 230.0 / 255.0),
		"hex": "#2E6BE6",
		"emblem": "hawk",
		"mentat_name": "THUFIR HAWAT",
		"mentat_title": "MENTAT · HOUSE ATREIDES",
		"style": "Balanced armour & firepower",
		"summary": "The Old Duke's line fights with discipline and precision. Balanced tanks and elite Fremen sharpshooters hold the line while the Sonic Tank breaks it.",
		"doctrine": "HOLD · PRECISION · STRIKE",
		"units": [
			"infantry", "rocket", "fremen",
			"trike", "atreides_tank", "sonic_tank", "tank", "harvester", "mcv", "carryall",
		],
		"signature": ["trike", "atreides_tank", "fremen", "sonic_tank"],
		"scout": "trike",
	},
	HARKONNEN: {
		"name": "House Harkonnen",
		"short": "HARKONNEN",
		"color": Color(214.0 / 255.0, 50.0 / 255.0, 50.0 / 255.0),
		"hex": "#D63232",
		"emblem": "bull",
		"mentat_name": "PITER DE VRIES",
		"mentat_title": "MENTAT-ASSASSIN · HOUSE HARKONNEN",
		"style": "Heavy armour, slow, brutal firepower",
		"summary": "The Baron's war machine grinds forward behind thick plate. Quads screen lumbering Combat Tanks and Devastators, while Sardaukar shock troops clear what survives the guns.",
		"doctrine": "GRIND · ENDURE · CRUSH",
		"units": [
			"infantry", "rocket", "sardaukar",
			"trike", "quad", "harkonnen_tank", "devastator", "tank", "harvester", "mcv", "carryall",
		],
		"signature": ["quad", "harkonnen_tank", "sardaukar", "devastator"],
		"scout": "trike",
	},
	ORDOS: {
		"name": "House Ordos",
		"short": "ORDOS",
		"color": Color(40.0 / 255.0, 168.0 / 255.0, 78.0 / 255.0),
		"hex": "#28A84E",
		"emblem": "serpent",
		"mentat_name": "THE EXECUTRIX",
		"mentat_title": "CYBERNETIC MENTAT · HOUSE ORDOS",
		"style": "Fast, unconventional, hit-and-run",
		"summary": "The Executrix sells speed and sabotage, never a fair fight. Raider Trikes and light Combat Tanks run rings around heavier houses while Saboteurs gut infrastructure and Deviators steal vehicles outright.",
		"doctrine": "STRIKE · SLIP · SEIZE",
		"units": [
			"infantry", "rocket", "saboteur",
			"raider_trike", "ordos_tank", "deviator", "tank", "harvester", "mcv", "carryall",
		],
		"signature": ["raider_trike", "ordos_tank", "saboteur", "deviator"],
		"scout": "raider_trike",
	},
}

static func exists(house: String) -> bool:
	return HOUSES.has(house)

static func data(house: String) -> Dictionary:
	return HOUSES.get(house, HOUSES[ATREIDES])

static func color(house: String) -> Color:
	return Color(data(house)["color"])

static func display_name(house: String) -> String:
	return String(data(house)["name"])

static func short_name(house: String) -> String:
	return String(data(house)["short"])

static func mentat_name(house: String) -> String:
	return String(data(house).get("mentat_name", "MENTAT"))

static func mentat_title(house: String) -> String:
	return String(data(house).get("mentat_title", "HOUSE MENTAT"))

static func roster(house: String) -> Array:
	return data(house)["units"].duplicate()

static func signature(house: String) -> Array:
	return data(house)["signature"].duplicate()

static func scout(house: String) -> String:
	return String(data(house)["scout"])

static func other_houses(house: String) -> Array:
	var out: Array = []
	for id in HOUSE_ORDER:
		if id != house:
			out.append(id)
	return out
