extends Node

## Persistent campaign state: chosen House, conquered provinces, mission tier,
## active battlefield parameters and the JSON save that lets a phone or desktop
## player continue without losing the war.
##
## GameDefs owns the presentation data; this autoload owns progression and is
## the single place that mutates the strategic map.

const SAVE_PATH := "user://campaign_save.json"
const MAX_TECH := 99
const SAVE_VERSION := 1

var player_house := Factions.ATREIDES
var enemy_house := Factions.HARKONNEN
var rival_house := Factions.HARKONNEN
var third_house := Factions.ORDOS
var current_tech_level := MAX_TECH
var missions_won := 0

var campaign_active := false
var campaign_complete := false
## Zero-based: 0 is Mission 1, 6 is the final stronghold.
var mission_tier := 0
var territory_owners: Dictionary = {}
var active_mission: Dictionary = {}
var battle_mode := "skirmish"
var pending_conquest: Dictionary = {}
var last_result: Dictionary = {}

var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	GameDefs.campaign = self
	GameDefs.set_map_size(56)
	_rng.randomize()
	load_campaign()
	if not campaign_active:
		player_house = Factions.ATREIDES
		rival_house = CampaignMissions.rival_for(player_house)
		third_house = CampaignMissions.third_for(player_house)
		enemy_house = rival_house
		current_tech_level = MAX_TECH
		sync_defs()

func has_campaign_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

func load_campaign() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var text := FileAccess.get_file_as_string(SAVE_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Campaign save is not valid JSON: %s" % SAVE_PATH)
		return false
	var data: Dictionary = parsed
	var saved_house := String(data.get("player_house", player_house))
	if not Factions.exists(saved_house):
		push_warning("Campaign save has an unknown House; ignoring it.")
		return false
	player_house = saved_house
	rival_house = String(data.get("rival_house", CampaignMissions.rival_for(player_house)))
	if not Factions.exists(rival_house) or rival_house == player_house:
		rival_house = CampaignMissions.rival_for(player_house)
	third_house = String(data.get("third_house", CampaignMissions.third_for(player_house)))
	if not Factions.exists(third_house) or third_house == player_house or third_house == rival_house:
		third_house = CampaignMissions.third_for(player_house)
	mission_tier = clampi(int(data.get("mission_tier", 0)), 0, CampaignMissions.TIER_COUNT)
	missions_won = maxi(int(data.get("missions_won", mission_tier)), 0)
	campaign_active = bool(data.get("campaign_active", true))
	campaign_complete = bool(data.get("campaign_complete", mission_tier >= CampaignMissions.TIER_COUNT))
	var saved_owners = data.get("territories", {})
	territory_owners = {}
	for id in ArrakisMap.ORDER:
		var owner := String(saved_owners.get(id, "neutral")) if typeof(saved_owners) == TYPE_DICTIONARY else "neutral"
		if owner != "neutral" and not Factions.exists(owner):
			owner = "neutral"
		territory_owners[id] = owner
	if campaign_complete:
		for id in ArrakisMap.ORDER:
			territory_owners[id] = player_house
	enemy_house = rival_house
	current_tech_level = MAX_TECH
	active_mission = {}
	battle_mode = "campaign"
	pending_conquest = {}
	sync_defs()
	return true

func save_campaign() -> bool:
	if not campaign_active:
		return false
	var data := {
		"version": SAVE_VERSION,
		"player_house": player_house,
		"rival_house": rival_house,
		"third_house": third_house,
		"missions_won": missions_won,
		"mission_tier": mission_tier,
		"campaign_active": campaign_active,
		"campaign_complete": campaign_complete,
		"territories": territory_owners,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
	}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Could not write campaign save: %s" % SAVE_PATH)
		return false
	file.store_string(JSON.stringify(data, "\t"))
	return true

## Start a fresh seven-mission war. This deliberately overwrites the previous
## campaign save; the House screen's New Campaign is the only entry point.
func new_campaign(house: String) -> void:
	if not Factions.exists(house):
		return
	player_house = house
	rival_house = CampaignMissions.rival_for(house)
	third_house = CampaignMissions.third_for(house)
	enemy_house = rival_house
	mission_tier = 0
	missions_won = 0
	campaign_active = true
	campaign_complete = false
	active_mission = {}
	pending_conquest = {}
	last_result = {}
	battle_mode = "campaign"
	current_tech_level = 1
	territory_owners = ArrakisMap.initial_owners(player_house, rival_house, third_house)
	GameDefs.set_map_size(44)
	sync_defs()
	save_campaign()

## Standalone skirmish with maximum tech. It never touches the campaign save.
func start_quick_skirmish(house: String) -> void:
	if not Factions.exists(house):
		return
	player_house = house
	var others := Factions.other_houses(house)
	enemy_house = String(others[_rng.randi_range(0, others.size() - 1)])
	current_tech_level = MAX_TECH
	campaign_active = false
	campaign_complete = false
	active_mission = {}
	battle_mode = "skirmish"
	pending_conquest = {}
	last_result = {}
	GameDefs.set_map_size(56)
	sync_defs()

## Called by Game._ready. A campaign mission uses its frozen battlefield
## parameters; a skirmish rolls a fresh opponent. Never rerolls a campaign
## enemy on retry, so a defeat returns to the same battle.
func prepare_battle() -> void:
	if campaign_active and not active_mission.is_empty():
		_apply_active_mission()
		return
	battle_mode = "skirmish"
	current_tech_level = MAX_TECH
	var others := Factions.other_houses(player_house)
	enemy_house = String(others[_rng.randi_range(0, others.size() - 1)])
	GameDefs.set_map_size(56)
	sync_defs()

## Freeze the selected mission's House, tech, map dimensions and AI contract.
func begin_mission(mission: Dictionary) -> void:
	if mission.is_empty():
		return
	active_mission = mission.duplicate(true)
	player_house = String(mission.get("player_house", player_house))
	enemy_house = String(mission.get("enemy_house", rival_house))
	rival_house = String(mission.get("rival_house", rival_house))
	third_house = String(mission.get("third_house", CampaignMissions.third_for(player_house)))
	current_tech_level = int(mission.get("tech_level", 1))
	campaign_active = true
	campaign_complete = false
	battle_mode = "campaign"
	GameDefs.set_map_size(int(mission.get("map_size", 56)))
	sync_defs()
	save_campaign()

func _apply_active_mission() -> void:
	var m := active_mission
	player_house = String(m.get("player_house", player_house))
	enemy_house = String(m.get("enemy_house", enemy_house))
	rival_house = String(m.get("rival_house", rival_house))
	third_house = String(m.get("third_house", third_house))
	current_tech_level = int(m.get("tech_level", current_tech_level))
	battle_mode = "campaign"
	GameDefs.set_map_size(int(m.get("map_size", 56)))
	sync_defs()

func record_mission_result(win: bool, stats: Dictionary) -> void:
	if not campaign_active or active_mission.is_empty():
		return
	var region := String(active_mission.get("region", ""))
	last_result = {
		"win": win,
		"stats": stats.duplicate(true),
		"region": region,
	}
	if win and region != "":
		var before: Dictionary = territory_owners.duplicate(true)
		var old_owner := String(territory_owners.get(region, "neutral"))
		territory_owners[region] = player_house
		mission_tier = mini(mission_tier + 1, CampaignMissions.TIER_COUNT)
		missions_won += 1
		var final := mission_tier >= CampaignMissions.TIER_COUNT
		if final:
			campaign_complete = true
			for id in ArrakisMap.ORDER:
				territory_owners[id] = player_house
		pending_conquest = {
			"region": region,
			"from": old_owner,
			"to": player_house,
			"tier": mission_tier,
			"final": final,
			"before": before,
		}
	save_campaign()

## Leave the battle for the strategic map. The tier and ownership are already
## saved by record_mission_result; this only clears transient battle state.
func return_to_map() -> void:
	active_mission = {}
	battle_mode = "campaign"
	enemy_house = rival_house
	current_tech_level = MAX_TECH
	GameDefs.set_map_size(56)
	sync_defs()

func cancel_battle() -> void:
	active_mission = {}
	battle_mode = "skirmish"
	if not campaign_active:
		enemy_house = rival_house
	sync_defs()

func clear_pending_conquest() -> void:
	pending_conquest = {}

## Old House-screen API kept for compatibility with older tools. It only
## changes the in-memory preference; starting a mode owns the save.
func select_house(id: String) -> void:
	if not Factions.exists(id):
		return
	player_house = id
	rival_house = CampaignMissions.rival_for(id)
	third_house = CampaignMissions.third_for(id)
	enemy_house = rival_house
	sync_defs()

func begin_skirmish() -> void:
	prepare_battle()

func sync_defs() -> void:
	GameDefs.team_houses = [player_house, enemy_house]
	GameDefs.tech_level = current_tech_level

func house_for_team(team: int) -> String:
	if team == GameDefs.ENEMY:
		return enemy_house
	return player_house

func color_for_team(team: int) -> Color:
	return Factions.color(house_for_team(team))

func name_for_team(team: int) -> String:
	return Factions.display_name(house_for_team(team))

func player_color() -> Color:
	return Factions.color(player_house)

func enemy_color() -> Color:
	return Factions.color(enemy_house)

func at_max_tech() -> bool:
	return current_tech_level >= MAX_TECH

func available_missions() -> Array:
	return CampaignMissions.available_missions(self)

func mission_number() -> int:
	return mini(mission_tier + 1, CampaignMissions.TIER_COUNT)

func territories_owned(house: String) -> int:
	return ArrakisMap.house_owned(territory_owners, house)

func control_percent(house: String) -> float:
	return 100.0 * float(territories_owned(house)) / float(ArrakisMap.ORDER.size())

func campaign_summary() -> String:
	if not has_campaign_save():
		return ""
	if campaign_complete:
		return "CAMPAIGN COMPLETE · %s · ARRAKIS CONQUERED" % Factions.display_name(player_house)
	var n := territories_owned(player_house)
	return "CAMPAIGN SAVED · %s · MISSION %d / %d · %d %s" % [
		Factions.display_name(player_house),
		mission_number(),
		CampaignMissions.TIER_COUNT,
		n,
		"PROVINCE" if n == 1 else "PROVINCES",
	]

func objective_text() -> String:
	if active_mission.is_empty():
		return ""
	return String(active_mission.get("objective_text", ""))
