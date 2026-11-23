class_name CampaignMissions
extends RefCounted

## Seven-mission campaign shed for each House. Every tier is data, not a hard
## coded script: objective, map size/seed, starting force, economy and AI
## pressure all live here so the map screen can show them before deployment.
##
## The player's exact target province is chosen from the live frontier, which
## is what gives the strategic map its branching choices. The tier templates
## supply the mission context and the battlefield preset.

const TIER_COUNT := 7

## House-specific Mentat orders, one entry per tier. These run under the
## typewriter on the dedicated briefing screen and are also available from the
## in-battle OPTIONS menu.
const MENTAT_ORDERS := {
	"atreides": [
		"The banner of House Atreides flies over this province, but the Harkonnen will not yield it without blood. Secure the spice flow and clear their scouts before they can carry word of our landing. Every soldier you spend today is a life the Duke will mourn tomorrow.",
		"Harkonnen raiders are probing our refinery line, and their light vehicles are fast enough to slip past ours. Raise the light factory, field our trikes, and break their spearhead before it reaches the silos. Precision, not vengeance, will carry this front.",
		"The enemy has turned this frontier into a nest of gun turrets and walls. Bring up our combat tanks and reduce their outpost methodically. Leave the civilians and the spice alone; the Duke wants a province, not a graveyard.",
		"The central field is the richest vein on this shelf, and both armies can smell it. Hold the contested sand long enough to harvest four thousand credits, then withdraw behind our lines. Do not let Harkonnen greed choose the ground for you.",
		"Our Fremen scouts report that the enemy is massing elites behind a fortified line. Take the field with our own elite infantry and break the fortress before it can launch. The desert remembers every promise, Commander.",
		"The sonic tank is ready, and its voice will end this stalemate. Escort it through the fortified enemy base and silence every gun that dares answer. House Atreides does not conquer by fear, but today the enemy will learn respect.",
		"The Imperial Basin is the last redoubt of our rival, and its walls are thick with their best troops. Bring the full might of our House, break the stronghold, and end the war for Arrakis. When the dust settles, let the planet remember who held the line.",
	],
	"harkonnen": [
		"The Baron has granted you this rock, and he expects a return on his patience. Strip the spice from it, crush the Atreides scouts, and let the survivors crawl home with tales of Harkonnen mercy. There is no mercy.",
		"Atreides raiders are sniffing around our lines like jackals. Build the light factory, roll out the Quads, and grind them into the sand before their reports reach the Duke. Speed is a tool; terror is the objective.",
		"Their frontier outpost squats on ground that belongs to House Harkonnen. Bring up the combat tanks, shatter their turrets and walls, and leave nothing standing that can shelter a flag. The Baron does not pay for prisoners.",
		"The contested field is fat with spice, and the Atreides are already digging in. Harvest four thousand credits while your tanks hold the center, then bury their claim under our tracks. Greed is only a sin when it is weak.",
		"The enemy has sent their elite guard to hold this front. They will die tired. Take the Sardaukar and your heaviest armour into their fortress and make an example that will echo across the planet.",
		"The Devastator is awake, and its plasma will paint the enemy base crimson. Break their forward fortress, crush every structure, and let the desert drink what remains. This is the Baron's answer to their noble pretensions.",
		"The Imperial Basin is the last nest of resistance on Arrakis. Bring the full weight of House Harkonnen, tear down their stronghold, and nail our banner to the wreckage. When the spice flows, the Baron will remember who delivered it.",
	],
	"ordos": [
		"The Executrix has purchased your silence and your ambition. Harvest the quota before the other Houses understand what we are building, and let their scouts vanish into the sand. Profit is the only flag worth dying for.",
		"Atreides and Harkonnen are both watching this shelf, which means neither is watching their flanks. Raise the light factory, field our Raiders, and cut their patrols apart while they posture. Information is worth more than armour.",
		"The enemy has fortified a frontier outpost and called it strength. Strip away its turrets with our combat tanks, open a corridor, and leave their command structure wondering who sold them the plans. There is always a seller.",
		"The central field is a bidding war written in spice. Hold the contested sand, fill our silos with four thousand credits, and make both Great Houses pay for every metre. When the market moves, be the one holding the ledger.",
		"Our Saboteurs have mapped the enemy fortress, and its elite garrison is exactly where we predicted. Send them in with the strike force, gut the defenses, and leave the survivors arguing over the bill. Chaos is a currency.",
		"The Deviator is ready, and the enemy's own war machines will open their gates for us. Break the fortified base with subversion and speed, then vanish before their reinforcements can agree on a story. A clean victory is for lesser Houses.",
		"The Imperial Basin is the final account, and every House has come to collect. Turn their alliance inside out, seize the stronghold, and let the Executrix write the terms of the new market. Arrakis belongs to whoever survives the audit.",
	],
}

const TIER_TEMPLATES := [
	{
		"title": "LANDING",
		"brief": "Put the banner down, secure a spice flow and blood the troops.",
		"objective": {"type": "harvest_or_clear", "credits": 2500, "kills": 4},
		"objective_text": "Harvest 2,500 credits of spice — or destroy the 4-unit enemy scout force.",
		"unlock": "Construction Yard · Wind Trap · Refinery · Barracks · Concrete · Light Infantry",
		"unlock_icons": [["structure", "cy"], ["structure", "windtrap"], ["structure", "refinery"], ["structure", "barracks"], ["brush", "slab"], ["unit", "infantry"]],
		"map_size": 44,
		"starting_credits": 2000,
		"base_preset": "landing",
		"base_seed": 7101,
		"ai": {"start_credits": 700, "army_cap": 8, "attack_delay": 60.0, "think": 2.5, "production": 0.85, "aggression": 0.75},
	},
	{
		"title": "THE SPICE MUST FLOW",
		"brief": "A light factory turns the beachhead into an army. Break the raiders.",
		"objective": {"type": "destroy_units"},
		"objective_text": "Destroy every enemy unit in the sector.",
		"unlock": "Light Factory · Rocket Trooper · {light}",
		"unlock_icons": [["structure", "factory"], ["unit", "rocket"], ["unit", "@scout"]],
		"map_size": 46,
		"starting_credits": 2400,
		"base_preset": "outpost",
		"base_seed": 7202,
		"ai": {"start_credits": 1000, "army_cap": 10, "attack_delay": 52.0, "think": 2.3, "production": 0.92, "aggression": 0.85},
	},
	{
		"title": "FRONTIER OUTPOST",
		"brief": "The enemy has dug in. Fortify the line and bring up armour.",
		"objective": {"type": "destroy_structures"},
		"objective_text": "Destroy the enemy outpost.",
		"unlock": "Gun Turret · Wall · {tank}",
		"unlock_icons": [["structure", "turret"], ["brush", "wall"], ["unit", "@tank"]],
		"map_size": 48,
		"starting_credits": 2800,
		"base_preset": "frontier",
		"base_seed": 7303,
		"ai": {"start_credits": 1400, "army_cap": 12, "attack_delay": 45.0, "think": 2.1, "production": 1.0, "aggression": 0.9},
	},
	{
		"title": "CONTESTED SANDS",
		"brief": "The central field is rich and exposed. Hold it long enough to fill the silos.",
		"objective": {"type": "harvest", "credits": 4000},
		"objective_text": "Harvest 4,000 credits from the contested central spice field.",
		"unlock": "Rocket Turret · Siege Tank",
		"unlock_icons": [["structure", "rocketturret"], ["unit", "tank"]],
		"map_size": 52,
		"starting_credits": 3200,
		"base_preset": "contested",
		"base_seed": 7404,
		"ai": {"start_credits": 1800, "army_cap": 14, "attack_delay": 39.0, "think": 1.95, "production": 1.06, "aggression": 1.0},
	},
	{
		"title": "THE ELITE",
		"brief": "House elites take the field. Crack the fortified base before it masses.",
		"objective": {"type": "destroy_all"},
		"objective_text": "Destroy every enemy structure and unit.",
		"unlock": "{elite}",
		"unlock_icons": [["unit", "@elite"]],
		"map_size": 52,
		"starting_credits": 3600,
		"base_preset": "fortress",
		"base_seed": 7505,
		"ai": {"start_credits": 2200, "army_cap": 17, "attack_delay": 33.0, "think": 1.8, "production": 1.12, "aggression": 1.05},
	},
	{
		"title": "WAR MACHINE",
		"brief": "The signature super-vehicle is ready. Break the enemy's forward fortress.",
		"objective": {"type": "destroy_all"},
		"objective_text": "Destroy the fortified enemy base — every structure and unit.",
		"unlock": "{super}",
		"unlock_icons": [["unit", "@super"]],
		"map_size": 56,
		"starting_credits": 4200,
		"base_preset": "stronghold",
		"base_seed": 7606,
		"ai": {"start_credits": 2700, "army_cap": 20, "attack_delay": 28.0, "think": 1.65, "production": 1.18, "aggression": 1.1},
	},
	{
		"title": "IMPERIAL BASIN",
		"brief": "The rival House has fortified the Imperial Basin. End the war for Arrakis.",
		"objective": {"type": "stronghold"},
		"objective_text": "Destroy the rival House stronghold in the Imperial Basin.",
		"unlock": "Full tech tree · every House unique",
		"unlock_title": "FULL TECH TREE",
		"unlock_icons": [["unit", "@scout"], ["unit", "@tank"], ["unit", "tank"], ["unit", "@elite"], ["unit", "@super"]],
		"map_size": 60,
		"starting_credits": 5000,
		"base_preset": "citadel",
		"base_seed": 7707,
		"ai": {"start_credits": 3400, "army_cap": 24, "attack_delay": 23.0, "think": 1.5, "production": 1.25, "aggression": 1.15},
	},
]

## Local tile offsets from each base's top-left anchor. Role tokens ("scout",
## "tank", "elite", "super") are resolved to the active House's unique unit.
const BASE_PRESETS := {
	"landing": {
		"player": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4]],
			"units": [["harvester", 8, 6], ["infantry", 2, 6], ["infantry", 3, 6]],
		},
		"enemy": {
			"buildings": [["cy", 0, 0], ["barracks", 4, 0], ["turret", 7, 3]],
			"units": [["infantry", 2, 6], ["infantry", 3, 6], ["scout", 2, 7], ["scout", 4, 7]],
		},
	},
	"outpost": {
		"player": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5]],
			"units": [["harvester", 8, 6], ["infantry", 2, 6], ["infantry", 3, 6], ["scout", 2, 7]],
		},
		"enemy": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 3]],
			"units": [["harvester", 8, 6], ["infantry", 2, 6], ["infantry", 3, 6], ["scout", 2, 7], ["scout", 4, 7]],
		},
	},
	"frontier": {
		"player": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 4]],
			"units": [["harvester", 8, 6], ["infantry", 2, 6], ["infantry", 3, 6], ["scout", 2, 7], ["tank", 3, 7]],
		},
		"enemy": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 4], ["turret", 0, 6]],
			"units": [["harvester", 8, 6], ["infantry", 2, 6], ["infantry", 3, 6], ["scout", 2, 7], ["tank", 3, 7]],
		},
	},
	"contested": {
		"player": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 4], ["rocketturret", 0, 7]],
			"units": [["harvester", 8, 6], ["harvester", 9, 5], ["infantry", 2, 6], ["scout", 2, 7], ["tank", 3, 7], ["tank", 7, 6]],
		},
		"enemy": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 4], ["turret", 0, 6], ["rocketturret", 7, 6]],
			"units": [["harvester", 8, 6], ["harvester", 9, 5], ["infantry", 2, 6], ["scout", 2, 7], ["tank", 3, 7], ["tank", 7, 7]],
		},
	},
	"fortress": {
		"player": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 4], ["turret", 0, 6], ["rocketturret", 7, 6]],
			"units": [["harvester", 8, 6], ["harvester", 9, 5], ["infantry", 2, 6], ["elite", 1, 7], ["tank", 3, 7], ["tank", 7, 7]],
		},
		"enemy": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 4], ["turret", 0, 6], ["turret", 7, 6], ["rocketturret", 0, 7]],
			"units": [["harvester", 8, 6], ["harvester", 9, 5], ["infantry", 2, 6], ["elite", 1, 7], ["tank", 3, 7], ["tank", 7, 7], ["scout", 4, 7]],
		},
	},
	"stronghold": {
		"player": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 4], ["turret", 0, 6], ["rocketturret", 7, 6], ["rocketturret", 8, 4]],
			"units": [["harvester", 8, 6], ["harvester", 9, 5], ["infantry", 2, 6], ["elite", 1, 7], ["tank", 3, 7], ["tank", 7, 7], ["super", 8, 7]],
		},
		"enemy": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["barracks", 2, 3], ["factory", 4, 5], ["factory", 8, 3], ["turret", 7, 4], ["turret", 0, 6], ["turret", 7, 6], ["turret", 9, 5], ["rocketturret", 0, 7], ["rocketturret", 8, 6]],
			"units": [["harvester", 8, 7], ["harvester", 10, 6], ["infantry", 2, 6], ["infantry", 3, 6], ["elite", 1, 7], ["tank", 3, 7], ["tank", 7, 7], ["super", 8, 5]],
		},
	},
	"citadel": {
		"player": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["refinery", 5, 0], ["barracks", 0, 4], ["factory", 4, 5], ["turret", 7, 4], ["turret", 0, 6], ["factory", 8, 0], ["rocketturret", 7, 6], ["rocketturret", 8, 4]],
			"units": [["harvester", 8, 6], ["harvester", 9, 5], ["infantry", 2, 6], ["infantry", 3, 6], ["elite", 1, 7], ["tank", 3, 7], ["tank", 7, 7], ["super", 8, 7]],
		},
		"enemy": {
			"buildings": [["cy", 0, 0], ["windtrap", 4, 3], ["windtrap", 8, 0], ["refinery", 5, 0], ["barracks", 0, 3], ["barracks", 2, 3], ["factory", 4, 5], ["factory", 8, 3], ["turret", 7, 4], ["turret", 0, 6], ["turret", 7, 6], ["turret", 9, 5], ["rocketturret", 0, 7], ["rocketturret", 8, 6], ["rocketturret", 10, 5]],
			"units": [["harvester", 8, 7], ["harvester", 10, 6], ["infantry", 2, 6], ["infantry", 3, 6], ["elite", 1, 6], ["elite", 1, 7], ["tank", 3, 7], ["tank", 7, 7], ["super", 8, 5], ["super", 9, 7]],
		},
	},
}

const RIVAL := {
	"atreides": "harkonnen",
	"harkonnen": "atreides",
	"ordos": "harkonnen",
}

static func rival_for(house: String) -> String:
	return String(RIVAL.get(house, "harkonnen"))

static func third_for(house: String) -> String:
	var rival := rival_for(house)
	for id in Factions.HOUSE_ORDER:
		if id != house and id != rival:
			return id
	return Factions.ORDOS

static func template_for_tier(tier: int) -> Dictionary:
	return TIER_TEMPLATES[clampi(tier, 0, TIER_COUNT - 1)]

static func preset(name: String) -> Dictionary:
	return BASE_PRESETS.get(name, BASE_PRESETS["landing"])

static func house_role(house: String, role: String) -> String:
	if role == "scout":
		return Factions.scout(house)
	if role == "tank":
		var sig: Array = Factions.signature(house)
		return String(sig[1]) if sig.size() > 1 else "tank"
	if role == "elite":
		var sig: Array = Factions.signature(house)
		return String(sig[2]) if sig.size() > 2 else "infantry"
	if role == "super":
		var sig: Array = Factions.signature(house)
		return String(sig[3]) if sig.size() > 3 else "tank"
	return role

## Resolve @role tokens in a tier's tech strip to the active House's unique
## unit so the briefing always shows the exact hardware being unlocked.
static func _resolve_unlock_icons(house: String, raw: Array) -> Array:
	var out: Array = []
	for entry in raw:
		var kind := String(entry[0])
		var id := String(entry[1])
		if id.begins_with("@"):
			id = house_role(house, id.substr(1))
		out.append([kind, id])
	return out

## The seven campaign tiers with House-specific names and unlock copy.
static func campaign_for(house: String) -> Array:
	var out: Array = []
	var sig: Array = Factions.signature(house)
	var light := String(sig[0]) if sig.size() > 0 else Factions.scout(house)
	var tank := String(sig[1]) if sig.size() > 1 else "tank"
	var elite := String(sig[2]) if sig.size() > 2 else "infantry"
	var super_unit := String(sig[3]) if sig.size() > 3 else "tank"
	for i in TIER_COUNT:
		var t: Dictionary = TIER_TEMPLATES[i].duplicate(true)
		t["tier"] = i + 1
		t["tech_level"] = i + 1
		t["player_house"] = house
		var orders: Array = MENTAT_ORDERS.get(house, [])
		t["mentat_text"] = String(orders[i]) if i < orders.size() else "Commander, the desert is listening."
		t["unlock_icons"] = _resolve_unlock_icons(house, t.get("unlock_icons", []))
		t["rival_house"] = rival_for(house)
		t["third_house"] = third_for(house)
		t["unlock_text"] = String(t["unlock"]).format({
			"light": String(GameDefs.UNITS.get(light, {}).get("name", light)),
			"tank": String(GameDefs.UNITS.get(tank, {}).get("name", tank)),
			"elite": String(GameDefs.UNITS.get(elite, {}).get("name", elite)),
			"super": String(GameDefs.UNITS.get(super_unit, {}).get("name", super_unit)),
		})
		t.erase("unlock")
		out.append(t)
	return out

## Pick one or two adjacent enemy/neutral provinces for the current tier. The
## outer ring is offered during the opening landings, then the inner ring; the
## final tier always opens the Imperial Basin stronghold.
static func available_missions(state: Node) -> Array:
	if state == null:
		return []
	var player := String(state.get("player_house"))
	var tier := int(state.get("mission_tier"))
	if tier >= TIER_COUNT:
		return []
	var owners: Dictionary = state.get("territory_owners")
	var templates := campaign_for(player)
	var t: Dictionary = templates[clampi(tier, 0, TIER_COUNT - 1)]
	var candidates: Array = []
	if tier == TIER_COUNT - 1:
		if String(owners.get(ArrakisMap.CENTER, "neutral")) != player:
			candidates = [ArrakisMap.CENTER]
	else:
		var frontier: Array = ArrakisMap.frontier(player, owners)
		var want := "outer" if tier < 2 else "inner"
		for id in frontier:
			if id == ArrakisMap.CENTER:
				continue
			if ArrakisMap.kind_of(id) == want:
				candidates.append(id)
		if candidates.is_empty():
			for id in frontier:
				if id != ArrakisMap.CENTER:
					candidates.append(id)
		# Prefer a province actually held by a House; a neutral frontier is a
		# fallback so the briefing's enemy House still matches the map colour.
		var held: Array = []
		for id in candidates:
			if Factions.exists(String(owners.get(id, "neutral"))):
				held.append(id)
		if not held.is_empty():
			candidates = held
		if candidates.size() > 2:
			candidates = candidates.slice(0, 2)
	if candidates.is_empty():
		return []
	var out: Array = []
	for region in candidates:
		var owner := String(owners.get(region, "neutral"))
		var enemy := owner if Factions.exists(owner) else String(t["rival_house"])
		if enemy == player:
			enemy = String(t["rival_house"])
		var mission: Dictionary = t.duplicate(true)
		mission["mission_id"] = "%s_t%d_%s" % [player, tier + 1, region]
		mission["region"] = region
		mission["region_name"] = ArrakisMap.display_name(region)
		mission["enemy_house"] = enemy
		mission["enemy_name"] = Factions.display_name(enemy)
		mission["final"] = tier == TIER_COUNT - 1
		mission["map_seed"] = int(t["base_seed"]) + _region_index(region) * 97 + tier * 13
		var p: Dictionary = preset(String(t["base_preset"]))
		mission["player_start"] = p["player"].duplicate(true)
		mission["enemy_start"] = p["enemy"].duplicate(true)
		out.append(mission)
	return out

static func _region_index(id: String) -> int:
	return ArrakisMap.ORDER.find(id)

static func objective_progress(game, objective: Dictionary) -> String:
	if game == null or objective.is_empty():
		return ""
	match String(objective.get("type", "")):
		"harvest":
			return "SPICE %d / %d" % [int(game.harvested), int(objective.get("credits", 0))]
		"harvest_or_clear":
			return "SPICE %d / %d   ·   KILLS %d / %d" % [
				int(game.harvested), int(objective.get("credits", 0)),
				int(game.enemy_units_destroyed), int(objective.get("kills", 0)),
			]
		"destroy_units":
			return "ENEMY UNITS %d" % _enemy_unit_count(game)
		"destroy_structures":
			return "ENEMY STRUCTURES %d" % _enemy_building_count(game)
		"destroy_all", "stronghold":
			return "ENEMY UNITS %d   ·   STRUCTURES %d" % [_enemy_unit_count(game), _enemy_building_count(game)]
	return ""

static func _enemy_unit_count(game) -> int:
	var n := 0
	for u in game.units:
		if is_instance_valid(u) and not u.dead and u.team == 1:
			n += 1
	return n

static func _enemy_building_count(game) -> int:
	var n := 0
	for b in game.buildings:
		if is_instance_valid(b) and not b.dead and b.team == 1:
			n += 1
	return n
