extends Node2D

## Sandwar - a Dune 2000 style RTS foundation.
## Spice economy, concrete bases, walls, unit production, combat and an AI.

const TILE := GameDefs.TILE
## Read live from GameDefs: missions resize the battlefield before this scene
## is instantiated, and quick skirmish resets it to 56.
var MAP: int:
	get:
		return GameDefs.MAP

var terrain: Terrain
var shroud: Shroud
var fx: Fx
var scorch_layer: ScorchLayer
var sfx: Sfx
var audio: Node
var camera: CameraRig
var hud: GameHUD
var rng := RandomNumberGenerator.new()
var astar: AStarGrid2D

var units: Array = []
var buildings: Array = []
## Airborne jobs in flight (refinery gifts, harvester ferries, reinforcements).
var carryalls: Array = []
## Active Shai-Hulud. They live outside `units`: they are terrain hazards, not
## selectable army, and ground units cannot target them.
var worms: Array = []
## Only one worm may run a hunt at a time; the rest keep prowling.
var worm_hunting = null
## After a meal, no worm may lock on until this elapsed time passes.
var worm_quiet_until := 0.0
## instance id -> true while a Carryall owns that harvester's airlift.
var ferry_claims: Dictionary = {}
var ferry_ready: Dictionary = {}
var reinforce_used := false
var rescue_used := false
var reinforce_timer := 0.0
var rescue_timer := 0.0
var credits := [2200, 1500]
var harvested := 0
var units_built := 0
var elapsed := 0.0
var game_over := false

## Mission attachment. Empty for Quick Skirmish.
var mission: Dictionary = {}
var campaign_mission := false
var objective: Dictionary = {}
var enemy_units_destroyed := 0
var enemy_buildings_destroyed := 0
var player_units_lost := 0
var player_buildings_lost := 0
var ai_army_cap := 16
var ai_think_base := 2.0
var ai_aggression := 1.0
var ai_production := 1.0

var selected: Array = []
var selected_build = null
var repair_mode := false
## Armed by the Guard/Rally action when a structure is selected. The next map
## tap becomes that structure's production rally point.
var rally_mode := false
var rally_building = null
## Player-nominated spawn building per production type. Set by tapping an
## already-selected Barracks/Factory again, or by giving it a rally point.
var primary_barracks = null
var primary_factory = null
var drag_active := false
var drag_start := Vector2.ZERO
var drag_now := Vector2.ZERO
var hover_world := Vector2.ZERO
var press_touch := false
## Armed by the BOX button: the next touch drag draws a selection box instead of
## panning. Explicit, so a swipe can never start a box by accident.
var box_armed := false

var structure_queue: Array = []
var infantry_queue: Array = []
var vehicle_queue: Array = []
var _power_low := false
var placing := ""
var brush := ""
## A completed structure waits here until the player taps its flashing READY
## sidebar icon. It is deliberately independent of `placing`: leaving placement
## does not lose the building or its queue slot entirely.
var ready_structure: Dictionary = {}
var touch_place_pending := false
var touch_place_index := -1
var touch_place_start := Vector2.ZERO
var messages: Array = []
var hint := ""

const REPAIR_COST_PER_HP := 0.4
const REPAIR_RATE := 0.09

var ai_wave := 0
var ai_queue: Array = []
var ai_think := 12.0
var ai_attack_timer := 30.0
var check_timer := 0.0
var vision_timer := 0.0
## Radio proximity sweep and the quiet window after an "enemy approaching" call.
var alert_timer := 0.0
var enemy_alert_until := -1.0

func _ready() -> void:
	rng.randomize()
	# Campaign missions freeze their House, tech and battlefield in
	# CampaignState.begin_mission. Skirmish rolls a fresh non-mirror opponent.
	var state = GameDefs.campaign
	if state != null:
		state.call("prepare_battle")
		var active = state.get("active_mission")
		if typeof(active) == TYPE_DICTIONARY:
			mission = active
	campaign_mission = not mission.is_empty()

	var map_size := 56
	var map_seed := rng.randi()
	if campaign_mission:
		map_size = int(mission.get("map_size", 56))
		map_seed = int(mission.get("map_seed", map_seed))
		objective = mission.get("objective", {}).duplicate(true)
		credits = [int(mission.get("starting_credits", 2200)), 1500]
		var ai: Dictionary = mission.get("ai", {})
		credits[1] = int(ai.get("start_credits", 1500))
		ai_army_cap = int(ai.get("army_cap", AI_MAX_ARMY))
		ai_think_base = float(ai.get("think", AI_THINK))
		ai_think = ai_think_base
		ai_attack_timer = float(ai.get("attack_delay", 30.0))
		ai_aggression = float(ai.get("aggression", 1.0))
		ai_production = float(ai.get("production", 1.0))
	GameDefs.set_map_size(map_size)
	rng.seed = map_seed

	terrain = Terrain.new()
	terrain.z_index = -10
	add_child(terrain)
	terrain.generate(map_seed)

	shroud = Shroud.new()
	add_child(shroud)
	shroud.setup(terrain)

	scorch_layer = ScorchLayer.new()
	scorch_layer.z_index = -1
	add_child(scorch_layer)

	fx = Fx.new()
	fx.z_index = 20
	add_child(fx)

	sfx = Sfx.new()
	add_child(sfx)
	audio = get_node_or_null("/root/AudioManager")

	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, MAP, MAP)
	astar.cell_size = Vector2(TILE, TILE)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()

	camera = CameraRig.new()
	add_child(camera)
	camera.make_current()
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = MAP * TILE
	camera.limit_bottom = MAP * TILE

	_build_starting_bases()
	_spawn_worms()
	focus_home()

	hud = GameHUD.new()
	add_child(hud)
	hud.setup(self)

	hint = "Tap a unit, then tap the ground.  Build from the side panel."
	if campaign_mission:
		_say("MISSION %d · %s — %s" % [int(mission.get("tier", 1)), String(mission.get("region_name", "Arrakis")), String(mission.get("objective_text", ""))])
	else:
		_say("Spice must flow. Destroy the enemy Construction Yard.")
	_update_vision()
	_apply_fog()

## Enemy radar perimeter, in tiles, and how long the line stays quiet after a
## contact before it can call again.
const ENEMY_ALERT_TILES := 13
const ENEMY_ALERT_QUIET := 20.0

func _process(delta: float) -> void:
	elapsed += delta
	if not game_over:
		_tick_production(delta)
		_tick_ai(delta)
		check_timer += delta
		if check_timer >= 0.5:
			check_timer = 0.0
			_check_victory()
		alert_timer += delta
		if alert_timer >= 0.5:
			alert_timer = 0.0
			_check_enemy_approach()
		vision_timer += delta
		if vision_timer >= 0.2:
			vision_timer = 0.0
			_update_vision()
			_apply_fog()
		_tick_repair(delta)
		_tick_carryall_jobs(delta)
		_tick_reinforcements(delta)
	if placing != "" or brush != "" or drag_active:
		queue_redraw()

# ---------------------------------------------------------------- world setup

func _base_anchor(team: int) -> Vector2i:
	var f := Vector2(0.22, 0.68) if team == 0 else Vector2(0.68, 0.18)
	return Vector2i(int(round(float(MAP) * f.x)), int(round(float(MAP) * f.y)))

func _build_starting_bases() -> void:
	if campaign_mission:
		_build_mission_bases()
		return
	var player_scout := Factions.scout(GameDefs.house_for_team(0))
	var enemy_scout := Factions.scout(GameDefs.house_for_team(1))
	add_building("cy", 0, Vector2i(12, 38), true)
	add_building("refinery", 0, Vector2i(17, 38), true)
	add_building("barracks", 0, Vector2i(12, 43), true)
	add_building("turret", 0, Vector2i(19, 42), true)
	spawn_unit("harvester", 0, Vector2(21.0, 44.0) * float(TILE))
	spawn_unit("infantry", 0, Vector2(16.0, 44.0) * float(TILE))
	spawn_unit("infantry", 0, Vector2(16.8, 44.9) * float(TILE))
	spawn_unit(player_scout, 0, Vector2(18.4, 45.6) * float(TILE))

	add_building("cy", 1, Vector2i(38, 10), true)
	add_building("refinery", 1, Vector2i(43, 10), true)
	add_building("barracks", 1, Vector2i(38, 15), true)
	add_building("factory", 1, Vector2i(42, 14), true)
	add_building("turret", 1, Vector2i(36, 16), true)
	add_building("turret", 1, Vector2i(46, 12), true)
	spawn_unit("harvester", 1, Vector2(41.0, 16.0) * float(TILE))
	spawn_unit("infantry", 1, Vector2(40.0, 18.0) * float(TILE))
	spawn_unit("infantry", 1, Vector2(40.7, 18.7) * float(TILE))
	spawn_unit(enemy_scout, 1, Vector2(39.0, 19.2) * float(TILE))

func _build_mission_bases() -> void:
	var player_start: Dictionary = mission.get("player_start", {})
	var enemy_start: Dictionary = mission.get("enemy_start", {})
	var pa := _base_anchor(0)
	var ea := _base_anchor(1)
	for spec in player_start.get("buildings", []):
		var tile := pa + Vector2i(int(spec[1]), int(spec[2]))
		add_building(String(spec[0]), 0, tile, true)
	for spec in player_start.get("units", []):
		var id := CampaignMissions.house_role(GameDefs.house_for_team(0), String(spec[0]))
		var tile := pa + Vector2i(int(spec[1]), int(spec[2]))
		spawn_unit(id, 0, terrain.tile_center(tile) + Vector2(rng.randf_range(-7.0, 7.0), rng.randf_range(-7.0, 7.0)))
	for spec in enemy_start.get("buildings", []):
		var tile := ea + Vector2i(int(spec[1]), int(spec[2]))
		add_building(String(spec[0]), 1, tile, true)
	for spec in enemy_start.get("units", []):
		var id := CampaignMissions.house_role(GameDefs.house_for_team(1), String(spec[0]))
		var tile := ea + Vector2i(int(spec[1]), int(spec[2]))
		spawn_unit(id, 1, terrain.tile_center(tile) + Vector2(rng.randf_range(-7.0, 7.0), rng.randf_range(-7.0, 7.0)))

func add_building(id: String, team: int, tile: Vector2i, starting := false):
	var span := GameDefs.size_of(id)
	var paved := _concrete_ratio(tile, span)
	var b := Building.new()
	b.configure(id, team, self)
	b.position = (Vector2(tile) + Vector2(span) * 0.5) * float(TILE)
	add_child(b)
	buildings.append(b)
	terrain.pave_span(tile, span)
	if id == "wall":
		_refresh_wall_neighbours(tile, team)
	if id == "windtrap" and paved < 1.0 and not starting:
		# Built off its slab the trap starts damaged, as it does in Dune 2000.
		# Mission maps are allowed to begin with a healthy trap on raw rock.
		b.hp = b.max_hp * 0.6
	_buildings_changed()
	if id == "refinery" and not starting:
		_spawn_free_harvester(b, team)
	return b

## Dune 2000 gifts one harvester with every new refinery, flown in slung under
## a Carryall. The hull exists immediately but is airborne and untouchable
## until the dropship sets it on open ground beside the docking pad.
func _spawn_free_harvester(refinery, team: int) -> void:
	var span: Vector2i = refinery.span
	var pad: Vector2i = refinery.tile_origin() + Vector2i(span.x / 2, span.y)
	var open := _open_tile(pad)
	if open.x < 0:
		return
	var drop := terrain.tile_center(open)
	var load: Array = [_spawn_hidden_unit("harvester", team, drop)]
	var drop_ship = _launch_carryall(team, drop, load, "harvester")
	drop_ship.job = "refinery"

## How much of a footprint already sits on concrete, 0..1.
func _concrete_ratio(tile: Vector2i, span: Vector2i) -> float:
	var total := span.x * span.y
	if total <= 0:
		return 1.0
	var paved := 0
	for ty in range(tile.y, tile.y + span.y):
		for tx in range(tile.x, tile.x + span.x):
			if tx < 0 or ty < 0 or tx >= MAP or ty >= MAP:
				continue
			if terrain.concrete[ty * MAP + tx] == 1:
				paved += 1
	return float(paved) / float(total)

## Spawn a unit that is already riding in a Carryall's grapple bay.
func _spawn_hidden_unit(id: String, team_id: int, drop: Vector2):
	var u = spawn_unit(id, team_id, drop)
	u.airborne = true
	u.visible = false
	u.set_process(false)
	u.set_physics_process(false)
	return u

## Nearest map edge to a drop point, far enough outside the battlefield that
## the inbound leg always reads as a fly-in.
func _edge_point(near: Vector2) -> Vector2:
	var world := float(MAP * TILE)
	var jitter := rng.randf_range(-3.0, 3.0) * float(TILE)
	var d_left := near.x
	var d_right := world - near.x
	var d_top := near.y
	var d_bottom := world - near.y
	var best := minf(minf(d_left, d_right), minf(d_top, d_bottom))
	if best == d_left:
		return Vector2(-170.0, clampf(near.y + jitter, 48.0, world - 48.0))
	if best == d_right:
		return Vector2(world + 170.0, clampf(near.y + jitter, 48.0, world - 48.0))
	if best == d_top:
		return Vector2(clampf(near.x + jitter, 48.0, world - 48.0), -170.0)
	return Vector2(clampf(near.x + jitter, 48.0, world - 48.0), world + 170.0)

## Leave across the opposite edge so the exit leg never doubles back.
func _exit_point(from: Vector2, drop: Vector2) -> Vector2:
	var world := float(MAP * TILE)
	var lateral := rng.randf_range(-4.0, 4.0) * float(TILE)
	if from.x < 0.0:
		return Vector2(world + 190.0, clampf(drop.y + lateral, 48.0, world - 48.0))
	if from.x > world:
		return Vector2(-190.0, clampf(drop.y + lateral, 48.0, world - 48.0))
	if from.y < 0.0:
		return Vector2(clampf(drop.x + lateral, 48.0, world - 48.0), world + 190.0)
	return Vector2(clampf(drop.x + lateral, 48.0, world - 48.0), -190.0)

func _launch_carryall(team_id: int, drop: Vector2, load: Array, kind: String):
	var from := _edge_point(drop)
	var drop_ship := Carryall.new()
	add_child(drop_ship)
	carryalls.append(drop_ship)
	drop_ship.setup(self, team_id, from, drop, load, _exit_point(from, drop), kind)
	return drop_ship

func _tick_carryall_jobs(_delta: float) -> void:
	carryalls = carryalls.filter(func(c): return is_instance_valid(c) and not c.is_queued_for_deletion())
	# A claim dies the moment its harvester touches down (or is destroyed).
	for key in ferry_claims.keys():
		var h = instance_from_id(key)
		if h == null or not is_instance_valid(h) or h.dead or not h.airborne:
			ferry_claims.erase(key)

func _pending_harvester_drop(team_id: int) -> bool:
	for c in carryalls:
		if is_instance_valid(c) and not c.released and c.team == team_id and c.carry_kind == "harvester":
			return true
	return false

## Long-haul airlift: only for a harvester already driving home more than twelve
## tiles from its refinery, with no other Carryall assigned to that hull.
func maybe_request_ferry(h) -> void:
	if h == null or not is_instance_valid(h) or h.dead or h.airborne:
		return
	var key: int = h.get_instance_id()
	if ferry_claims.has(key):
		return
	if elapsed < float(ferry_ready.get(key, 0.0)):
		return
	var refinery = nearest_building(h.global_position, h.team, "refinery")
	if refinery == null:
		return
	if h.global_position.distance_to(refinery.global_position) <= 12.0 * float(TILE):
		return
	var drop: Vector2 = refinery.global_position + Vector2(0.0, refinery.size_px * 0.5 + float(TILE) * 0.7)
	var open := _open_tile(terrain.tile_of(drop))
	if open.x < 0:
		return
	ferry_claims[key] = true
	ferry_ready[key] = elapsed + 40.0
	h.airborne = true
	h.attack_target = null
	h.visible = false
	h.set_process(false)
	h.set_physics_process(false)
	var drop_ship = _launch_carryall(h.team, terrain.tile_center(open), [h], "harvester")
	drop_ship.job = "ferry"

## Milestone reinforcements, plus a Mission 1 safety net: if the last harvester
## dies, a replacement is flown in so the spice economy cannot soft-lock.
func _tick_reinforcements(delta: float) -> void:
	if not reinforce_used:
		reinforce_timer += delta
		if reinforce_timer >= 82.0 and nearest_building(Vector2.ZERO, 0, "cy") != null:
			reinforce_used = true
			_drop_reinforcements(false)
	# Campaign Mission 1 and every skirmish get one emergency harvester if
	# the player loses their last one. Losing the opening harvester to a worm
	# should never turn the match into an unwinnable walk.
	var rescue_enabled: bool = not campaign_mission or int(mission.get("tier", 1)) == 1
	if rescue_enabled and not rescue_used:
		rescue_timer += delta
		if rescue_timer >= 15.0 and _count_units(0, "harvester") == 0 \
				and _count_buildings(0, "refinery") > 0 and not _pending_harvester_drop(0):
			rescue_used = true
			_drop_reinforcements(true)

func _drop_reinforcements(rescue: bool) -> void:
	var cy = nearest_building(Vector2.ZERO, 0, "cy")
	if cy == null:
		return
	var tile: Vector2i = _open_tile(cy.tile_origin() + Vector2i(0, cy.span.y + 2))
	if tile.x < 0:
		tile = _open_tile(terrain.tile_of(cy.global_position) + Vector2i(3, 3))
	if tile.x < 0:
		return
	var drop := terrain.tile_center(tile)
	var load: Array = []
	if rescue:
		load.append(_spawn_hidden_unit("harvester", 0, drop))
	else:
		var house := GameDefs.house_for_team(0)
		for role in ["infantry", "rocket"]:
			var id := CampaignMissions.house_role(house, String(role))
			load.append(_spawn_hidden_unit(id, 0, drop))
	var drop_ship = _launch_carryall(0, drop, load, "harvester" if rescue else "unit")
	drop_ship.job = "reinforce"
	drop_ship.announce = true

func _spawn_worms() -> void:
	var count := 2 if MAP >= 54 else 1
	for i in count:
		var w := Sandworm.new()
		add_child(w)
		w.setup(self, i)
		worms.append(w)

## Player-facing wormsign alert: radio call, sidebar log line and an amber
## radar ring on the ridge's current position.
func worm_warning(pos: Vector2) -> void:
	play_voice("wormsign", 20.0)
	_say("Warning: Wormsign detected!")
	if hud != null and hud.minimap != null:
		hud.minimap.ping(pos, Color(1.0, 0.72, 0.18))

func spawn_unit(id: String, team: int, pos: Vector2):
	var u
	if id == "harvester":
		u = Harvester.new()
	else:
		u = Unit.new()
	u.configure(id, team, self)
	u.position = pos.clamp(Vector2(20.0, 20.0), Vector2(float(MAP * TILE) - 20.0, float(MAP * TILE) - 20.0))
	add_child(u)
	units.append(u)
	return u

func _buildings_changed() -> void:
	_rebuild_nav()
	if hud != null:
		hud.refresh()

## Walls are the only structure whose art depends on its neighbours. Refreshing
## the placed tile and its four orthogonal neighbours is enough to update every
## end cap, corner and junction affected by a placement or destruction.
func _wall_at(tile: Vector2i, team_id: int):
	for b in buildings:
		if not is_instance_valid(b) or b.dead or b.type_id != "wall" or b.team != team_id:
			continue
		if b.tile_origin() == tile:
			return b
	return null

func wall_connection_mask(b) -> int:
	if b == null or not is_instance_valid(b) or b.type_id != "wall":
		return 0
	var tile: Vector2i = b.tile_origin()
	var mask := 0
	if _wall_at(tile + Vector2i(0, -1), b.team) != null:
		mask |= WallArt.N
	if _wall_at(tile + Vector2i(1, 0), b.team) != null:
		mask |= WallArt.E
	if _wall_at(tile + Vector2i(0, 1), b.team) != null:
		mask |= WallArt.S
	if _wall_at(tile + Vector2i(-1, 0), b.team) != null:
		mask |= WallArt.W
	return mask

func _refresh_wall_neighbours(tile: Vector2i, team_id: int) -> void:
	for offset in [Vector2i.ZERO, Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var b = _wall_at(tile + offset, team_id)
		if b != null:
			b.set_wall_mask(wall_connection_mask(b))

# ------------------------------------------------------------------ pathing

func _rebuild_nav() -> void:
	if astar == null:
		return
	for y in MAP:
		for x in MAP:
			astar.set_point_solid(Vector2i(x, y), false)
	for b in buildings:
		if not is_instance_valid(b) or b.dead:
			continue
		var origin := terrain.tile_of(b.world_rect().position)
		for ty in range(origin.y, origin.y + b.span.y):
			for tx in range(origin.x, origin.x + b.span.x):
				if tx >= 0 and ty >= 0 and tx < MAP and ty < MAP:
					astar.set_point_solid(Vector2i(tx, ty), true)

func _is_walkable(tile: Vector2i) -> bool:
	if tile.x < 0 or tile.y < 0 or tile.x >= MAP or tile.y >= MAP:
		return false
	return not astar.is_point_solid(tile)

func _open_tile(tile: Vector2i) -> Vector2i:
	if _is_walkable(tile):
		return tile
	for r in range(1, 7):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var t := tile + Vector2i(dx, dy)
				if _is_walkable(t):
					return t
	return Vector2i(-1, -1)

func find_path(from: Vector2, to: Vector2) -> Array:
	var start := _open_tile(terrain.tile_of(from))
	var goal := _open_tile(terrain.tile_of(to))
	if start.x < 0 or goal.x < 0:
		return []
	var ids: Array = astar.get_id_path(start, goal)
	var points: Array = []
	for i in range(1, ids.size()):
		points.append(terrain.tile_center(ids[i]))
	if points.is_empty():
		points.append(terrain.tile_center(goal))
	return points

# --------------------------------------------------------------- book keeping

## Route the WAV pipeline through the Game object so standalone script checks
## do not depend on Godot registering autoload names as globals.
func play_sfx(id: String, pos: Vector2, db := 0.0, pitch := 1.0) -> void:
	if audio != null:
		audio.call("play_at", id, pos, db, pitch)

func play_ui_sfx(id: String, db := 0.0, pitch := 1.0) -> void:
	if audio != null:
		audio.call("play_ui", id, db, pitch)

## Spoken comms alert; the AudioManager owns the single voice channel and queue.
func play_voice(id: String, cooldown := 12.0) -> void:
	if audio != null:
		audio.call("play_voice", id, cooldown)

## Radar sweep: warn once when a visible enemy closes on any player structure.
func _check_enemy_approach() -> void:
	if elapsed < enemy_alert_until:
		return
	var reach := float(ENEMY_ALERT_TILES * TILE)
	for u in units:
		if not is_instance_valid(u) or u.dead or u.team == 0:
			continue
		if not terrain.is_visible_at(u.global_position):
			continue
		for b in buildings:
			if not is_instance_valid(b) or b.dead or b.team != 0:
				continue
			if u.global_position.distance_to(b.global_position) <= reach:
				enemy_alert_until = elapsed + ENEMY_ALERT_QUIET
				play_voice("enemy_approaching", 22.0)
				_say("Warning: Enemy unit approaching!")
				if hud != null and hud.minimap != null:
					hud.minimap.ping(u.global_position, Color(1.0, 0.22, 0.16))
				return

func on_building_damaged(b) -> void:
	if b.team != 0:
		return
	play_voice("base_under_attack", 18.0)
	if hud != null and hud.minimap != null:
		hud.minimap.ping(b.global_position, Color(1.0, 0.22, 0.16))

func on_unit_damaged(u) -> void:
	if u.team != 0 or u.type_id != "harvester":
		return
	play_voice("harvester_under_attack", 15.0)
	if hud != null and hud.minimap != null:
		hud.minimap.ping(u.global_position, Color(1.0, 0.62, 0.18))

func on_unit_destroyed(u) -> void:
	if u.team == 1:
		enemy_units_destroyed += 1
	else:
		player_units_lost += 1
	units.erase(u)
	selected.erase(u)
	# Classic Dune 2000: a wrecked Devastator's reactor goes critical. This is
	# deliberately indiscriminate, so clumping friendly armour around one is a
	# real risk rather than a free shield.
	if u.type_id == "devastator" and not u.swallowed:
		_devastator_meltdown(u.global_position)
	if u.crushed:
		# Tracks leave dust and a squashed smear, not a full explosion.
		if fx != null:
			fx.impact(u.global_position, "light", 1.1)
			fx.popup("CRUSHED", u.global_position + Vector2(0.0, -16.0))
		if scorch_layer != null:
			scorch_layer.add(u.global_position, 6.0)
		play_sfx("explosion_small", u.global_position, -12.0, 0.82)
	elif u.swallowed:
		# Sandworm: dragged under in one bite. Dust and a low gulp, no fireball.
		if fx != null:
			fx.sand_burst(u.global_position, 58.0, 0.9)
		play_sfx("explosion_small", u.global_position, -8.0, 0.55)
	else:
		if fx != null:
			fx.blast(u.global_position)
		play_sfx("explosion_medium", u.global_position, -1.0)

## Devastator reactor blast: a large nuclear fireball plus falloff damage to
## every unit and structure around the wreck, regardless of team.
func _devastator_meltdown(center: Vector2) -> void:
	const BLAST_RADIUS := 155.0
	const BLAST_DAMAGE := 95.0
	if fx != null:
		fx.nuke(center)
		fx.impact(center, "plasma", 3.0)
		fx.sand_burst(center, 118.0, 1.35)
		fx.popup("REACTOR BLAST", center + Vector2(0.0, -46.0))
	if scorch_layer != null:
		scorch_layer.add(center, 46.0)
	play_sfx("explosion_building", center, 0.0, 0.85)
	for other in units.duplicate():
		if not is_instance_valid(other) or other.dead or other.airborne:
			continue
		var reach: float = BLAST_RADIUS + float(other.radius)
		var d: float = center.distance_to(other.global_position)
		if d > reach:
			continue
		var falloff := clampf(1.0 - d / reach, 0.0, 1.0)
		other.take_damage(BLAST_DAMAGE * (0.35 + 0.65 * falloff))
	for b in buildings.duplicate():
		if not is_instance_valid(b) or b.dead:
			continue
		var reach: float = BLAST_RADIUS + float(b.size_px) * 0.5
		var d: float = center.distance_to(b.global_position)
		if d > reach:
			continue
		var falloff := clampf(1.0 - d / reach, 0.0, 1.0)
		b.take_damage(BLAST_DAMAGE * (0.35 + 0.65 * falloff))

func on_building_destroyed(b) -> void:
	if b.team == 1:
		enemy_buildings_destroyed += 1
	else:
		player_buildings_lost += 1
	var was_wall: bool = b.type_id == "wall"
	var wall_tile: Vector2i = b.tile_origin()
	var wall_team: int = b.team
	buildings.erase(b)
	if selected_build == b:
		selected_build = null
	if primary_barracks == b:
		primary_barracks = null
	if primary_factory == b:
		primary_factory = null
	if fx != null:
		fx.blast(b.global_position)
	play_sfx("explosion_building", b.global_position, 0.0)
	_say("%s destroyed." % String(GameDefs.STRUCTURES[b.type_id]["name"]))
	if was_wall:
		_refresh_wall_neighbours(wall_tile, wall_team)
	_buildings_changed()

func add_credits(team: int, amount: float) -> void:
	if game_over:
		return
	credits[team] += int(amount)
	if team == 0:
		harvested += int(amount)

func popup(text: String, pos: Vector2) -> void:
	if fx != null:
		fx.popup(text, pos)

func unit_count(team: int) -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u) and not u.dead and u.team == team:
			n += 1
	return n

func nearest_enemy(pos: Vector2, team: int, radius: float):
	var best = null
	var best_d := radius
	var fogged: bool = team == 0
	for u in units:
		if not is_instance_valid(u) or u.dead or u.airborne or u.team == team:
			continue
		if fogged and not terrain.is_visible_at(u.global_position):
			continue
		var d: float = u.global_position.distance_to(pos)
		# Fremen stealth: beyond their detection radius they cannot be picked
		# as an automatic target. Deliberate attack orders still work.
		if u.stealth > 0.0 and d > u.stealth:
			continue
		if d < best_d:
			best_d = d
			best = u
	if best != null:
		return best
	for b in buildings:
		if not is_instance_valid(b) or b.dead or b.team == team:
			continue
		if fogged and not terrain.is_visible_at(b.global_position):
			continue
		var d: float = b.global_position.distance_to(pos)
		if d < best_d + b.size_px * 0.5:
			best_d = d
			best = b
	return best

## Refresh vision from every player-owned unit and structure.
func _update_vision() -> void:
	if terrain == null:
		return
	terrain.clear_visible()
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == 0:
			terrain.reveal(b.global_position, float(GameDefs.STRUCTURES[b.type_id].get("vision", 200.0)) + b.size_px * 0.35)
	for u in units:
		if is_instance_valid(u) and not u.dead and u.team == 0:
			terrain.reveal(u.global_position, float(GameDefs.UNITS[u.type_id].get("vision", 200.0)))

## Hide enemy units and structures the player cannot currently see.
func _apply_fog() -> void:
	for u in units:
		if is_instance_valid(u):
			u.visible = not u.airborne and (u.team == 0 or terrain.is_visible_at(u.global_position))
	for b in buildings:
		if is_instance_valid(b):
			b.visible = b.team == 0 or terrain.is_visible_at(b.global_position)
	if shroud != null:
		shroud.refresh()

func nearest_building(pos: Vector2, team: int, id: String):
	var best = null
	var best_d := 1.0e9
	for b in buildings:
		if not is_instance_valid(b) or b.dead:
			continue
		if b.team != team or b.type_id != id:
			continue
		var d: float = b.global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = b
	return best

func _building_of(team: int, id: String):
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == team and b.type_id == id:
			return b
	return null

func _has_building(team: int, id: String) -> bool:
	return _building_of(team, id) != null

func _find_producer(unit_id: String):
	var producer_id := String(GameDefs.UNITS[unit_id]["producer"])
	# A Barracks or Factory the player nominated takes priority, so units keep
	# emerging from the forward producer instead of the starting base.
	var primary = primary_barracks if producer_id == "barracks" else primary_factory
	if primary != null and is_instance_valid(primary) and not primary.dead \
			and primary.team == 0 and primary.type_id == producer_id:
		return primary
	return nearest_building(terrain.tile_center(_base_anchor(0)), 0, producer_id)

# ---------------------------------------------------------------- production

func can_build(kind: String, id: String) -> bool:
	if game_over:
		return false
	# Tech pacing is part of the mission contract: the sidebar never even
	# offers a locked unit, and a stale tap cannot queue one either.
	if not GameDefs.tech_available(kind, id):
		return false
	if kind == "structure":
		var def: Dictionary = GameDefs.STRUCTURES[id]
		if credits[0] < int(def["cost"]):
			return false
		return _has_building(0, "cy")
	if kind == "brush":
		var brush_def: Dictionary = GameDefs.BRUSHES[id]
		if credits[0] < int(brush_def["cost"]):
			return false
		return _has_building(0, "cy")
	var udef: Dictionary = GameDefs.UNITS[id]
	if credits[0] < int(udef["cost"]):
		return false
	return _has_building(0, String(udef["producer"]))

func _category_for_item(kind: String, id: String) -> String:
	if kind == "structure":
		return "structures"
	if kind == "unit":
		var producer := String(GameDefs.UNITS[id]["producer"])
		return "infantry" if producer == "barracks" else "vehicles"
	return ""

func _queue_for_category(category: String) -> Array:
	match category:
		"structures":
			return structure_queue
		"infantry":
			return infantry_queue
		"vehicles":
			return vehicle_queue
	return []

## Queue counts include the item currently being produced, so the badge reads
## as the total number of that unit waiting in this category.
func queue_count(kind: String, id: String) -> int:
	var category := _category_for_item(kind, id)
	if category == "":
		return 0
	var n := 0
	for item in _queue_for_category(category):
		if String(item["id"]) == id:
			n += 1
	return n

func queue_ready(kind: String, id: String) -> bool:
	return kind == "structure" and not ready_structure.is_empty() and String(ready_structure["id"]) == id

## Progress of this item only while it is the active head of its category.
func queue_progress(kind: String, id: String) -> float:
	if queue_ready(kind, id):
		return 1.0
	var category := _category_for_item(kind, id)
	if category == "":
		return 0.0
	var q := _queue_for_category(category)
	if q.is_empty() or String(q[0]["id"]) != id:
		return 0.0
	var item: Dictionary = q[0]
	return clampf(1.0 - float(item["left"]) / maxf(float(item["total"]), 0.01), 0.0, 1.0)

func _category_rate(team_id: int, category: String) -> float:
	var producer_id := "cy"
	if category == "infantry":
		producer_id = "barracks"
	elif category == "vehicles":
		producer_id = "factory"
	var count := 0
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == team_id and b.type_id == producer_id:
			count += 1
	# Multiple production buildings give the classic C&C speed bonus. It is
	# deliberately gentle (12% per extra building, capped at +60%).
	var bonus := clampf(float(maxi(count - 1, 0)) * 0.12, 0.0, 0.60)
	return production_rate(team_id) * (1.0 + bonus)

func queue_structure(id: String) -> void:
	if game_over:
		return
	if not can_build("structure", id):
		_say("Cannot build %s yet." % String(GameDefs.STRUCTURES[id]["name"]))
		return
	if structure_queue.size() >= 99:
		_say("Structures queue is full (99).")
		return
	var def: Dictionary = GameDefs.STRUCTURES[id]
	credits[0] -= int(def["cost"])
	brush = ""
	structure_queue.append({
		"kind": "structure",
		"id": id,
		"name": String(def["name"]),
		"left": float(def["build"]),
		"total": float(def["build"]),
	})
	_say("Queued %s (%d)." % [String(def["name"]), queue_count("structure", id)])

func queue_unit(id: String) -> void:
	if game_over:
		return
	if not can_build("unit", id):
		_say("Need the right production building for %s." % String(GameDefs.UNITS[id]["name"]))
		return
	var category := _category_for_item("unit", id)
	var q := _queue_for_category(category)
	if q.size() >= 99:
		_say("%s queue is full (99)." % category.capitalize())
		return
	var def: Dictionary = GameDefs.UNITS[id]
	credits[0] -= int(def["cost"])
	q.append({
		"kind": "unit",
		"id": id,
		"name": String(def["name"]),
		"left": float(def["build"]),
		"total": float(def["build"]),
	})
	_say("Queued %s (%d)." % [String(def["name"]), queue_count("unit", id)])

## Secondary/right-click on a build tile, a touch long-press, or the sidebar X
## badge removes one matching item. A READY structure refunds its full cost and
## frees the construction line; ordinary queued items refund their purchase
## price as before.
func dequeue_item(kind: String, id: String) -> bool:
	if kind == "structure" and queue_ready(kind, id):
		return cancel_ready_structure(id)
	var category := _category_for_item(kind, id)
	if category == "":
		return false
	var q := _queue_for_category(category)
	for i in range(q.size() - 1, -1, -1):
		if String(q[i]["id"]) != id:
			continue
		var item: Dictionary = q[i]
		var refund := int(GameDefs.STRUCTURES[id]["cost"]) if kind == "structure" else int(GameDefs.UNITS[id]["cost"])
		credits[0] += refund
		q.remove_at(i)
		_say("Cancelled %s (+%d credits)." % [String(item["name"]), refund])
		if hud != null:
			hud.refresh()
		return true
	return false

func cancel_icon(kind: String, id: String) -> bool:
	return dequeue_item(kind, id)

## Cancel the finished-but-unplaced structure. Full purchase price is returned
## and the structure production line immediately resumes with the next order.
func cancel_ready_structure(id := "") -> bool:
	if ready_structure.is_empty():
		return false
	if id != "" and String(ready_structure["id"]) != id:
		return false
	var built_id := String(ready_structure["id"])
	var refund := int(GameDefs.STRUCTURES[built_id]["cost"])
	credits[0] += refund
	ready_structure = {}
	touch_place_pending = false
	touch_place_index = -1
	if placing == built_id:
		placing = ""
	_say("Cancelled %s (+%d credits)." % [String(GameDefs.STRUCTURES[built_id]["name"]), refund])
	queue_redraw()
	if hud != null:
		hud.refresh()
	return true

## Every structure drains power and every wind trap generates it. A damaged
## trap makes less power in proportion to its health, so raiding them hurts.
func power_out(team_id: int) -> float:
	var total := 0.0
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == team_id:
			var gen := float(GameDefs.STRUCTURES[b.type_id].get("power", 0))
			if gen > 0.0:
				total += gen * clampf(b.hp / maxf(b.max_hp, 1.0), 0.0, 1.0)
	return total

func power_used(team_id: int) -> float:
	var total := 0.0
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == team_id:
			total += float(GameDefs.STRUCTURES[b.type_id].get("drain", 0))
	return total

func has_power(team_id: int) -> bool:
	return power_out(team_id) + 0.01 >= power_used(team_id)

## Full power builds at full speed; a starved base crawls, as in Dune 2000.
func production_rate(team_id: int) -> float:
	var rate := 1.0 if has_power(team_id) else 0.55
	if team_id == 1:
		rate *= ai_production
	return rate

func _complete_unit(item: Dictionary) -> void:
	var id := String(item["id"])
	var producer = _find_producer(id)
	var origin := terrain.tile_center(_base_anchor(0))
	if producer != null:
		origin = producer.global_position + Vector2(0.0, producer.size_px * 0.5 + 30.0)
		if producer.team == 0 and producer.has_rally:
			# Rally uses the same collision-safe spawn helper as a normal
			# deployment, so units never appear inside terrain or a structure.
			var open := _open_tile(terrain.tile_of(producer.rally_point))
			if open.x >= 0:
				origin = terrain.tile_center(open)
	spawn_unit(id, 0, origin + Vector2(rng.randf_range(-20.0, 20.0), rng.randf_range(0.0, 18.0)))
	units_built += 1
	play_voice("unit_ready", 6.0)
	_say("%s deployed." % String(item["name"]))
	if sfx != null:
		sfx.play_at("deploy", origin, -8.0)

func _advance_queue(q: Array, category: String, delta: float) -> void:
	if q.is_empty():
		return
	var item: Dictionary = q[0]
	var rate := _category_rate(0, category)
	item["left"] = float(item["left"]) - delta * rate
	if float(item["left"]) > 0.0:
		return
	q.pop_front()
	if category == "structures":
		# Dune-style flow: completion leaves the player in normal control. The
		# structure waits READY until its sidebar icon is tapped. This also lets
		# the completed structure pause the line without hijacking the camera.
		brush = ""
		placing = ""
		ready_structure = item
		_say("%s READY - tap its sidebar icon to place." % String(item["name"]))
		play_ui_sfx("build_ready", -2.0)
		play_voice("construction_complete", 8.0)
		if hud != null:
			hud.refresh()
		return
	_complete_unit(item)

func _tick_production(delta: float) -> void:
	var low := not has_power(0)
	if low != _power_low:
		_power_low = low
		_say("Low power - construction slowed. Build a Wind Trap." if low else "Power restored - construction at full speed.")
		if low:
			play_ui_sfx("low_power", -5.0)
			play_voice("low_power", 20.0)
	# The three production lines are independent. A finished structure waiting
	# for READY placement pauses only the structure line; infantry and vehicles
	# keep training in parallel.
	if placing == "" and ready_structure.is_empty():
		_advance_queue(structure_queue, "structures", delta)
	_advance_queue(infantry_queue, "infantry", delta)
	_advance_queue(vehicle_queue, "vehicles", delta)

## Tap the flashing READY tile (or its READY badge) to enter placement. This is
## the only path that turns a completed structure into placement mode.
func begin_ready_placement() -> void:
	if game_over or ready_structure.is_empty():
		return
	placing = String(ready_structure["id"])
	brush = ""
	hover_world = get_global_mouse_position()
	_say("Placing %s - tap rock or concrete." % String(ready_structure["name"]))
	queue_redraw()
	if hud != null:
		hud.refresh()

## Leave placement without consuming or refunding the READY structure. The
## sidebar keeps flashing READY so the player can resume when ready.
func exit_placement() -> void:
	if placing == "":
		return
	touch_place_pending = false
	touch_place_index = -1
	var message := "Placement cancelled"
	if not ready_structure.is_empty() and String(ready_structure["id"]) == placing:
		message = "%s remains READY - tap its icon to place." % String(ready_structure["name"])
	placing = ""
	_say(message)
	queue_redraw()
	if hud != null:
		hud.refresh()

func cancel_current() -> void:
	touch_place_pending = false
	touch_place_index = -1
	if rally_mode:
		rally_mode = false
		rally_building = null
		_say("Rally cancelled.")
		queue_redraw()
		if hud != null:
			hud.refresh()
	elif placing != "":
		exit_placement()
	elif brush != "":
		brush = ""
		_say("Placement finished.")
		queue_redraw()
		if hud != null:
			hud.refresh()

func begin_brush(id: String) -> void:
	if game_over:
		return
	if placing != "":
		_say("Deploy the finished building first.")
		return
	var def: Dictionary = GameDefs.BRUSHES[id]
	if not can_build("brush", id):
		_say("Cannot place %s right now." % String(def["name"]))
		return
	brush = id
	_say("%s: tap tiles to place, CANCEL to stop." % String(def["name"]))
	queue_redraw()
	if hud != null:
		hud.refresh()

# ------------------------------------------------------------------ building

## Dune 2000 construction rule: new structures stay on explored ground and no
## more than two tiles from the base the player already holds.
const BUILD_RADIUS := 2

func _placement_explored(type_id: String, tile: Vector2i) -> bool:
	var span := GameDefs.size_of(type_id)
	for ty in range(tile.y, tile.y + span.y):
		for tx in range(tile.x, tile.x + span.x):
			if not terrain.is_seen_tile(tx, ty):
				return false
	return true

## Chebyshev distance from a tile to the nearest friendly footprint.
func _near_friendly_base(tile: Vector2i) -> bool:
	for b in buildings:
		if not is_instance_valid(b) or b.dead or b.team != 0:
			continue
		var origin: Vector2i = b.tile_origin()
		var dx := maxi(maxi(origin.x - tile.x, tile.x - (origin.x + b.span.x - 1)), 0)
		var dy := maxi(maxi(origin.y - tile.y, tile.y - (origin.y + b.span.y - 1)), 0)
		if maxi(dx, dy) <= BUILD_RADIUS:
			return true
	return false

func _near_concrete(tile: Vector2i) -> bool:
	for dy in range(-BUILD_RADIUS, BUILD_RADIUS + 1):
		for dx in range(-BUILD_RADIUS, BUILD_RADIUS + 1):
			var tx := tile.x + dx
			var ty := tile.y + dy
			if tx < 0 or ty < 0 or tx >= MAP or ty >= MAP:
				continue
			if terrain.concrete[ty * MAP + tx] == 1:
				return true
	return false

func _placement_in_range(type_id: String, tile: Vector2i) -> bool:
	var span := GameDefs.size_of(type_id)
	for ty in range(tile.y, tile.y + span.y):
		for tx in range(tile.x, tile.x + span.x):
			var probe := Vector2i(tx, ty)
			if _near_friendly_base(probe) or _near_concrete(probe):
				return true
	return false

func can_place(type_id: String, tile: Vector2i) -> bool:
	if not _placement_explored(type_id, tile) or not _placement_in_range(type_id, tile):
		return false
	var span := GameDefs.size_of(type_id)
	for ty in range(tile.y, tile.y + span.y):
		for tx in range(tile.x, tile.x + span.x):
			if not terrain.is_tile_buildable(tx, ty):
				return false
	var rect := Rect2(Vector2(tile) * float(TILE), Vector2(span) * float(TILE))
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.world_rect().intersects(rect):
			return false
	for u in units:
		if is_instance_valid(u) and not u.dead and rect.grow(8.0).has_point(u.global_position):
			return false
	return true

func _can_pave_tile(tile: Vector2i) -> bool:
	if not terrain.can_pave(tile):
		return false
	if not terrain.is_seen_tile(tile.x, tile.y):
		return false
	if not _near_friendly_base(tile) and not _near_concrete(tile):
		return false
	var rect := Rect2(Vector2(tile) * float(TILE), Vector2(float(TILE), float(TILE)))
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.world_rect().intersects(rect):
			return false
	for u in units:
		if is_instance_valid(u) and not u.dead and rect.has_point(u.global_position):
			return false
	return true

func try_place(world: Vector2) -> void:
	if placing == "":
		return
	var span := GameDefs.size_of(placing)
	var tile := terrain.tile_of(world) - span / 2
	if not can_place(placing, tile):
		if not _placement_explored(placing, tile):
			_say("Cannot build in unexplored territory.")
		elif not _placement_in_range(placing, tile):
			_say("Must build adjacent to existing base or concrete.")
		else:
			_say("Cannot build there - need clear rock or concrete.")
		return
	add_building(placing, 0, tile)
	_say("%s deployed." % String(GameDefs.STRUCTURES[placing]["name"]))
	if placing == "rocketturret" and not has_power(0):
		_say("Rocket Turret: NO POWER - build a Wind Trap.")
	play_ui_sfx("build_place", -2.0)
	ready_structure = {}
	placing = ""
	queue_redraw()
	if hud != null:
		hud.refresh()

func try_brush(world: Vector2) -> void:
	if brush == "":
		return
	if brush == "slab":
		var center := terrain.tile_of(world)
		var cost := int(GameDefs.BRUSHES["slab"]["cost"])
		var placed := 0
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if credits[0] < cost:
					break
				var tile := center + Vector2i(dx, dy)
				if _can_pave_tile(tile):
					terrain.pave(tile)
					credits[0] -= cost
					placed += 1
		if placed > 0:
			_say("Paved %d tiles." % placed)
			play_ui_sfx("build_place", -4.0)
		else:
			_say("Cannot pave there - too far from base or blocked.")
		if hud != null:
			hud.refresh()
	elif brush == "wall":
		var cost := int(GameDefs.BRUSHES["wall"]["cost"])
		if credits[0] < cost:
			_say("Not enough credits.")
			return
		var tile := terrain.tile_of(world)
		if not can_place("wall", tile):
			if not _placement_explored("wall", tile):
				_say("Cannot build in unexplored territory.")
			elif not _placement_in_range("wall", tile):
				_say("Must build adjacent to existing base or concrete.")
			else:
				_say("Walls need clear rock or concrete.")
			return
		add_building("wall", 0, tile)
		credits[0] -= cost
		_say("Wall built.")
		play_ui_sfx("build_place", -3.0)
		if hud != null:
			hud.refresh()

# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if hud != null and hud.overlay_visible():
		return
	if event is InputEventMagnifyGesture:
		return
	# A second finger cancels whatever the first finger started. Keep rejecting
	# touches until the whole pinch has lifted, so its final release cannot turn
	# into a move order, placement or selection box.
	if camera != null and camera.is_gesture_suppressed():
		if event is InputEventScreenTouch or event is InputEventScreenDrag:
			cancel_touch_gesture()
			return
	if event is InputEventKey:
		if event.pressed and not event.echo:
			_handle_key(event)
		return
	if event is InputEventScreenTouch:
		if placing != "" or brush != "":
			hover_world = world_from_screen(event.position)
			# Place on release, after we know this was a tap rather than the first
			# finger of a pinch or a camera pan.
			if event.pressed:
				touch_place_pending = true
				touch_place_index = event.index
				touch_place_start = event.position
			else:
				if touch_place_pending and touch_place_index == event.index:
					var place_ok: bool = event.position.distance_to(touch_place_start) <= 18.0
					touch_place_pending = false
					touch_place_index = -1
					if place_ok:
						if placing != "":
							try_place(world_from_screen(event.position))
						elif brush != "":
							try_brush(world_from_screen(event.position))
			return
		if event.pressed:
			_press(event.position, true)
		else:
			_release(event.position, true)
		return
	if event is InputEventScreenDrag:
		drag_now = event.position
		hover_world = world_from_screen(event.position)
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# Left click only selects; the right button gives orders.
			if event.pressed:
				_press(event.position)
			else:
				_release(event.position, false)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if placing != "" or brush != "":
				cancel_current()
			elif not selected.is_empty():
				_command(world_from_screen(event.position))
		return
	if event is InputEventMouseMotion:
		hover_world = world_from_screen(event.position)
		if drag_active:
			drag_now = event.position
			queue_redraw()

## Called by CameraRig as soon as a second finger lands. Do not clear a READY
## building or a brush here; only abandon the in-flight map gesture.
func cancel_touch_gesture() -> void:
	drag_active = false
	press_touch = false
	touch_place_pending = false
	touch_place_index = -1
	if camera != null:
		camera.pan_locked = false
	queue_redraw()

func _handle_key(event: InputEventKey) -> void:
	var key := event.keycode
	if key == KEY_ESCAPE:
		if rally_mode:
			rally_mode = false
			rally_building = null
			_say("Rally cancelled.")
			if hud != null:
				hud.refresh()
		elif placing != "" or brush != "":
			cancel_current()
		else:
			selected.clear()
			selected_build = null
			repair_mode = false
			_after_select()
	elif key == KEY_R:
		toggle_repair()
	elif key == KEY_A:
		select_all_army()
	elif key == KEY_H:
		select_all_harvesters()
	elif key == KEY_B or key == KEY_SPACE:
		focus_home()
	elif key == KEY_Q:
		camera.zoom_by(0.9)
	elif key == KEY_E:
		camera.zoom_by(1.1)

func select_all_army() -> void:
	selected = units.filter(func(u): return is_instance_valid(u) and not u.dead and u.team == 0 and u.type_id != "harvester")
	_after_select()
	_say(("Army selected: %d units" % selected.size()) if not selected.is_empty() else "No army to select yet.")

func select_all_harvesters() -> void:
	selected = units.filter(func(u): return is_instance_valid(u) and not u.dead and u.team == 0 and u.type_id == "harvester")
	_after_select()
	_say(("Harvesters selected: %d" % selected.size()) if not selected.is_empty() else "No harvesters to select.")

func _press(pos: Vector2, touch := false) -> void:
	if game_over:
		return
	if placing != "":
		try_place(world_from_screen(pos))
		return
	if brush != "":
		try_brush(world_from_screen(pos))
		return
	drag_active = true
	drag_start = pos
	drag_now = pos
	press_touch = touch
	# While the box tool is armed the view stays put, so the rectangle matches
	# what the player actually drew.
	camera.pan_locked = press_touch and box_armed

func _release(pos: Vector2, allow_command: bool) -> void:
	if not drag_active:
		return
	drag_active = false
	camera.pan_locked = false
	drag_now = pos
	var moved := drag_start.distance_to(pos)
	# Mouse keeps its instant box drag. On touch the box only happens while the
	# BOX button is armed; every other drag is a camera pan.
	var box := not press_touch and moved > 16.0
	if press_touch and box_armed:
		box = moved > 8.0
		box_armed = false
		if hud != null:
			hud.refresh()
	if box:
		if moved > 8.0:
			_box_select(drag_start, pos)
	elif press_touch and moved > 24.0:
		pass
	else:
		_click(world_from_screen(pos), Input.is_key_pressed(KEY_SHIFT), allow_command)
	queue_redraw()

func _box_select(a: Vector2, b: Vector2) -> void:
	var wa := world_from_screen(a)
	var wb := world_from_screen(b)
	var rect := Rect2(wa, Vector2.ZERO).expand(wb)
	var picked: Array = []
	for u in units:
		if is_instance_valid(u) and not u.dead and u.team == 0 and rect.has_point(u.global_position):
			picked.append(u)
	if not picked.is_empty():
		selected = picked
		_after_select()

func _click(world: Vector2, additive: bool, allow_command := true) -> void:
	if rally_mode:
		_set_rally(world)
		return
	var structure = _building_at(world)
	if structure != null and not additive:
		play_ui_sfx("ui_click", -12.0)
		if repair_mode:
			_start_repair(structure)
			return
		if structure == selected_build:
			# Tapping the already-selected producer nominates its spawn point.
			_set_primary_producer(structure)
			return
		selected.clear()
		selected_build = structure
		_after_select()
		return
	var own = _unit_at(world, 0)
	if own != null:
		play_ui_sfx("ui_click", -12.0)
		if additive:
			if selected.has(own):
				selected.erase(own)
			else:
				selected.append(own)
		else:
			selected = [own]
		_after_select()
		return
	if not selected.is_empty() and allow_command:
		_command(world)
		return
	selected.clear()
	_after_select()

func _building_at(world: Vector2, team := 0):
	for b in buildings:
		if not is_instance_valid(b) or b.dead or b.team != team:
			continue
		if not b.visible:
			continue
		if b.world_rect().has_point(world):
			return b
	return null

func _unit_at(world: Vector2, team: int):
	var best = null
	var best_d := 30.0
	for u in units:
		if not is_instance_valid(u) or u.dead or u.team != team:
			continue
		if not u.visible:
			continue
		var d: float = u.global_position.distance_to(world)
		if d < best_d + u.radius:
			best_d = d
			best = u
	return best

func _enemy_at(world: Vector2):
	var u = _unit_at(world, 1)
	if u != null:
		return u
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == 1 and b.visible and b.world_rect().has_point(world):
			return b
	return null

## Repair toggle: while it is on, clicking one of your damaged buildings
## starts fixing it, and credits are spent until it is whole again.
func toggle_repair() -> void:
	rally_mode = false
	rally_building = null
	repair_mode = not repair_mode
	if repair_mode:
		_say("Repair: tap a damaged building.")
	else:
		_say("Repair mode off.")
	if hud != null:
		hud.refresh()

func _start_repair(b) -> void:
	var label := String(GameDefs.STRUCTURES[b.type_id]["name"])
	selected.clear()
	selected_build = b
	if b.hp >= b.max_hp:
		_say("%s is undamaged." % label)
		_after_select()
		return
	b.repairing = true
	_say("Repairing %s." % label)
	_after_select()

## Dune 2000 sell action: cash out half the structure's value and field the
## crew as two infantry. Queue state, credits and navigation all update through
## the normal helpers; only the destruction callback is deliberately skipped.
func sell_selected_building() -> void:
	if game_over:
		return
	var b = selected_build
	if b == null or not is_instance_valid(b) or b.dead or b.team != 0:
		_say("Select one of your structures to sell.")
		if hud != null:
			hud.refresh()
		return
	var label := String(GameDefs.STRUCTURES[b.type_id]["name"])
	var refund := int(float(GameDefs.STRUCTURES[b.type_id]["cost"]) * 0.5)
	var center: Vector2 = b.global_position
	var wall_tile: Vector2i = b.tile_origin()
	var was_wall: bool = b.type_id == "wall"
	var wall_team: int = b.team
	var span: Vector2i = b.span
	buildings.erase(b)
	if selected_build == b:
		selected_build = null
	if primary_barracks == b:
		primary_barracks = null
	if primary_factory == b:
		primary_factory = null
	if rally_building == b:
		rally_building = null
		rally_mode = false
	b.repairing = false
	b.dead = true
	b.queue_free()
	credits[0] += refund
	if was_wall:
		_refresh_wall_neighbours(wall_tile, wall_team)
	# A wall is only real estate: selling it returns credits and nothing else,
	# which closes the old sell-a-wall-for-free-infantry loop. Turrets field one
	# crewman, larger structures two.
	var crew := 0
	if not was_wall:
		crew = 1 if span.x * span.y <= 1 else 2
	# Rebuild the navigation grid before finding the crew spawn tiles: the sold
	# footprint must be walkable immediately.
	_buildings_changed()
	var base_tile := terrain.tile_of(center)
	var mustered := 0
	for offset in [Vector2i(-1, 1), Vector2i(1, 1), Vector2i(0, 2), Vector2i(-2, 1)]:
		if mustered >= crew:
			break
		var open := _open_tile(base_tile + offset)
		if open.x < 0:
			continue
		spawn_unit("infantry", 0, terrain.tile_center(open) + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0)))
		mustered += 1
	if fx != null:
		fx.popup("+%d CR" % refund, center + Vector2(0.0, -20.0))
	play_ui_sfx("ui_click", -4.0)
	if crew > 0:
		_say("Sold %s (+%d credits). %d infantry mustered." % [label, refund, crew])
	else:
		_say("Sold %s (+%d credits)." % [label, refund])
	if hud != null:
		hud.refresh()

## Context action for the classic Guard/Rally icon. A selected structure enters
## rally placement; selected units hold their current ground and return to it
## after chasing attackers.
func guard_or_rally() -> void:
	if game_over:
		return
	var b = selected_build
	if b != null and is_instance_valid(b) and not b.dead and b.team == 0:
		if rally_mode and rally_building == b:
			rally_mode = false
			rally_building = null
			_say("Rally cancelled.")
		else:
			repair_mode = false
			rally_mode = true
			rally_building = b
			_say("Rally %s - tap the destination." % String(GameDefs.STRUCTURES[b.type_id]["name"]))
		queue_redraw()
		if hud != null:
			hud.refresh()
		return
	if not selected.is_empty():
		var n := 0
		for u in selected:
			if is_instance_valid(u) and not u.dead and u.has_method("order_guard"):
				u.order_guard()
				n += 1
		if n > 0:
			_say("%d units guarding their positions." % n)
			if hud != null:
				hud.refresh()
			return
	_say("Select units to guard, or a structure to set a rally.")

func _set_primary_producer(b, quiet := false) -> void:
	if b == null or not is_instance_valid(b) or b.dead or b.team != 0:
		return
	if b.type_id == "barracks":
		primary_barracks = b
	elif b.type_id == "factory":
		primary_factory = b
	else:
		return
	if not quiet:
		_say("%s is now the primary spawn." % String(GameDefs.STRUCTURES[b.type_id]["name"]))
		if hud != null:
			hud.refresh()
	queue_redraw()

func _set_rally(world: Vector2) -> void:
	if rally_building == null or not is_instance_valid(rally_building) or rally_building.dead:
		rally_mode = false
		rally_building = null
		return
	var open := _open_tile(terrain.tile_of(world))
	if open.x < 0:
		_say("Cannot set a rally there.")
		return
	rally_building.has_rally = true
	rally_building.rally_point = terrain.tile_center(open)
	# Setting a rally on a producer also makes it the primary spawn building.
	_set_primary_producer(rally_building, true)
	_say("%s rally set." % String(GameDefs.STRUCTURES[rally_building.type_id]["name"]))
	rally_mode = false
	rally_building = null
	queue_redraw()
	if hud != null:
		hud.refresh()

func _tick_repair(delta: float) -> void:
	for b in buildings:
		if not is_instance_valid(b) or b.dead or not b.repairing:
			continue
		if b.hp >= b.max_hp:
			b.hp = b.max_hp
			b.repairing = false
			b.queue_redraw()
			_say("%s repairs complete." % String(GameDefs.STRUCTURES[b.type_id]["name"]))
			continue
		if credits[0] <= 0:
			b.repairing = false
			b.queue_redraw()
			_say("Out of credits - repairs halted.")
			continue
		var heal: float = minf(b.max_hp * REPAIR_RATE * delta, b.max_hp - b.hp)
		b.hp += heal
		b.repair_debt += heal * REPAIR_COST_PER_HP
		var pay := mini(int(b.repair_debt), credits[0])
		if pay > 0:
			credits[0] -= pay
			b.repair_debt -= float(pay)
		b.queue_redraw()

## BOX tool: the next drag on the battlefield selects everything inside the
## rectangle, then the tool switches itself off again.
func toggle_box() -> void:
	box_armed = not box_armed
	_say("Box select on: drag a box." if box_armed else "Box select off.")
	if hud != null:
		hud.refresh()

func _command(world: Vector2) -> void:
	var target = _enemy_at(world)
	if target != null:
		for u in selected:
			if is_instance_valid(u) and not u.dead:
				u.order_attack(target)
		_say("Attack order issued.")
		return
	var live: Array = []
	for u in selected:
		if is_instance_valid(u) and not u.dead:
			live.append(u)
	if live.is_empty():
		selected.clear()
		_after_select()
		return
	var cols := int(ceil(sqrt(float(live.size()))))
	for i in live.size():
		var col := i % cols
		var row := int(floor(float(i) / float(cols)))
		var offset := Vector2((float(col) - (float(cols) - 1.0) * 0.5) * 30.0, (float(row) - (float(cols) - 1.0) * 0.5) * 30.0)
		# Send them to open ground: an order into a building would otherwise
		# leave the unit grinding against the wall for ever.
		var spot := world + offset
		var open := _open_tile(terrain.tile_of(spot))
		if open.x >= 0:
			spot = terrain.tile_center(open)
		live[i].order_move(spot.clamp(Vector2(10.0, 10.0), Vector2(float(MAP * TILE) - 10.0, float(MAP * TILE) - 10.0)))

func _after_select() -> void:
	if selected_build != null:
		rally_mode = false
		rally_building = null
	if not selected.is_empty():
		selected_build = null
	for u in units:
		if is_instance_valid(u):
			u.selected = selected.has(u)
	for b in buildings:
		if is_instance_valid(b):
			b.queue_redraw()
	if hud != null:
		hud.refresh()

func world_from_screen(pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * pos

func focus_world(pos: Vector2) -> void:
	var target: Vector2 = pos - camera.offset
	camera.position = target.clamp(Vector2(0.0, 0.0), Vector2(float(MAP * TILE), float(MAP * TILE)))

func focus_home() -> void:
	# Frame the whole base, not just the Construction Yard.
	var span := Vector2.ZERO
	var count := 0
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == 0:
			span += b.global_position
			count += 1
	if count > 0:
		camera.position = span / float(count) - camera.offset

# ----------------------------------------------------------------------- AI

## The enemy plays the same game you do: its harvesters fill its treasury, and
## it spends that treasury on harvesters, structures and units. Anything you
## destroy gets rebuilt, so raids on its economy actually buy you time.

const AI_THINK := 2.0
const AI_MAX_ARMY := 16
const AI_REBUILD := ["refinery", "barracks", "factory"]

## SANDWAR_AI_TRACE=1 prints what the enemy is doing, for testing a match.
var ai_trace := OS.get_environment("SANDWAR_AI_TRACE") == "1"

func _ai_log(msg: String) -> void:
	if ai_trace:
		print("[ai %6.1fs cr %d] %s" % [elapsed, int(credits[1]), msg])

func _tick_ai(delta: float) -> void:
	if _building_of(1, "cy") == null:
		return
	_tick_ai_queue(delta)
	ai_attack_timer = maxf(0.0, ai_attack_timer - delta)
	ai_think -= delta
	if ai_think > 0.0:
		return
	ai_think = ai_think_base
	_ai_decide()
	_ai_maybe_attack()

func _ai_decide() -> void:
	# One job at a time, so a raid on the treasury is felt.
	if ai_queue.size() >= 2:
		return
	# No refinery means no income; if the treasury cannot cover a new one, scrap
	# something to get the spice flowing again instead of stalling for ever.
	if not _has_building(1, "refinery") and _ai_queued("refinery") == 0 \
			and credits[1] < int(GameDefs.STRUCTURES["refinery"]["cost"]):
		if _ai_scrap():
			return
	# Replace lost harvesters: without them the treasury dries up.
	if _has_building(1, "refinery") and _has_building(1, "factory") \
			and _count_units(1, "harvester") + _ai_queued("harvester") < 2 \
			and _ai_buy_unit("harvester"):
		return
	# Rebuild production before anything else, but only what this mission's tech
	# level has unlocked: no Light Factory on Mission 1.
	for id in AI_REBUILD:
		if not GameDefs.tech_available("structure", id):
			continue
		if not _has_building(1, id) and _ai_buy_structure(id):
			return
	# Turrets around the yard, more as the game goes on. Rocket turrets join the
	# mix once the tech level allows them.
	var turrets := _count_buildings(1, "turret") + _count_buildings(1, "rocketturret")
	var turret_goal := mini(8, 3 + int(float(ai_wave) / 2.0))
	if turrets + _ai_queued("turret") + _ai_queued("rocketturret") < turret_goal:
		var turret_id := "turret"
		if GameDefs.tech_level >= 4 and GameDefs.tech_available("structure", "rocketturret") and turrets % 2 == 1:
			turret_id = "rocketturret"
		if GameDefs.tech_available("structure", turret_id) and _ai_buy_structure(turret_id):
			return
	# A starved grid gets another trap immediately; otherwise one trap early on
	# keeps the yard running. Six is enough for any base the AI can afford.
	if GameDefs.tech_available("structure", "windtrap"):
		var traps := _count_buildings(1, "windtrap") + _ai_queued("windtrap")
		if (not has_power(1) and traps < 6) or (ai_wave >= 1 and traps < 1):
			if _ai_buy_structure("windtrap"):
				return
	if _team_combat_units(1).size() + ai_queue.size() >= ai_army_cap:
		return
	# Keep a mixed army drawn from the enemy House's own roster. The unit
	# furthest behind its share of the force goes next, so the AI fields its
	# unique units instead of a generic mirror of the player's army.
	var house := GameDefs.house_for_team(1)
	var roster: Array = []
	for id in GameDefs.unit_roster(house):
		if id == "harvester":
			continue
		if not _has_building(1, String(GameDefs.UNITS[id]["producer"])):
			continue
		# Expensive uniques wait until the economy and the first wave are up.
		if int(GameDefs.UNITS[id]["cost"]) >= 700 and ai_wave < 2:
			continue
		roster.append(id)
	if roster.is_empty():
		roster = ["infantry", "rocket"]
	var pick := String(roster[0])
	var pick_ratio := 1.0e9
	for id in roster:
		var share := 2.1
		var cost := int(GameDefs.UNITS[id]["cost"])
		if id == "infantry" or id == "rocket":
			share = 2.4
		elif cost >= 700:
			share = 0.75
		elif cost >= 500:
			share = 1.25
		var ratio := float(_count_units(1, id) + _ai_queued(id)) / share
		if ratio < pick_ratio:
			pick_ratio = ratio
			pick = id
	if not _ai_buy_unit(pick):
		for id in ["infantry", "rocket"]:
			if _ai_buy_unit(id):
				break

## Sell a structure for half its price, the way a player would, to fund the
## refinery that keeps the harvesters working.
func _ai_scrap() -> bool:
	for id in ["turret", "barracks", "factory"]:
		for b in buildings:
			if not is_instance_valid(b) or b.dead or b.team != 1 or b.type_id != id:
				continue
			var refund := int(float(GameDefs.STRUCTURES[id]["cost"]) * 0.5)
			credits[1] += refund
			_ai_log("scrapped %s for %d" % [id, refund])
			b.die()
			return true
	return false

func _ai_buy_unit(id: String) -> bool:
	var def: Dictionary = GameDefs.UNITS[id]
	if not _has_building(1, String(def["producer"])):
		return false
	if credits[1] < int(def["cost"]):
		return false
	credits[1] -= int(def["cost"])
	ai_queue.append({"kind": "unit", "id": id, "left": float(def["build"])})
	_ai_log("queued %s" % id)
	return true

func _ai_buy_structure(id: String) -> bool:
	if not GameDefs.tech_available("structure", id):
		return false
	var def: Dictionary = GameDefs.STRUCTURES[id]
	if credits[1] < int(def["cost"]):
		return false
	credits[1] -= int(def["cost"])
	ai_queue.append({"kind": "structure", "id": id, "left": float(def["build"])})
	_ai_log("queued %s" % id)
	return true

func _tick_ai_queue(delta: float) -> void:
	if ai_queue.is_empty():
		return
	var item: Dictionary = ai_queue[0]
	item["left"] = float(item["left"]) - delta * production_rate(1)
	if float(item["left"]) > 0.0:
		return
	ai_queue.pop_front()
	var id := String(item["id"])
	if String(item["kind"]) == "structure":
		var tile := _ai_free_tile(id)
		if tile.x < 0:
			credits[1] += int(GameDefs.STRUCTURES[id]["cost"])
			return
		add_building(id, 1, tile)
		_ai_log("built %s at %s" % [id, str(tile)])
		play_ui_sfx("build_place", -8.0)
		return
	var producer = _building_of(1, String(GameDefs.UNITS[id]["producer"]))
	var origin := terrain.tile_center(_base_anchor(1))
	if producer != null:
		origin = producer.global_position + Vector2(0.0, producer.size_px * 0.5 + 26.0)
	spawn_unit(id, 1, origin + Vector2(rng.randf_range(-18.0, 18.0), rng.randf_range(0.0, 14.0)))

## Nearest free plot to the enemy Construction Yard, on rock or concrete when
## possible, otherwise anywhere it can pave.
func _ai_free_tile(id: String) -> Vector2i:
	var base = _building_of(1, "cy")
	if base == null:
		return Vector2i(-1, -1)
	var span := GameDefs.size_of(id)
	var center: Vector2i = terrain.tile_of(base.global_position)
	var fallback := Vector2i(-1, -1)
	for r in range(2, 13):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var tile: Vector2i = center + Vector2i(dx, dy) - span / 2
				if not _ai_plot_free(span, tile):
					continue
				if terrain.is_tile_buildable(tile.x, tile.y):
					return tile
				if fallback.x < 0 and terrain.spice_at(tile) < 5.0:
					fallback = tile
	if fallback.x >= 0:
		return fallback
	return Vector2i(-1, -1)

func _ai_plot_free(span: Vector2i, tile: Vector2i) -> bool:
	if tile.x < 0 or tile.y < 0 or tile.x + span.x > MAP or tile.y + span.y > MAP:
		return false
	var rect := Rect2(Vector2(tile) * float(TILE), Vector2(span) * float(TILE))
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.world_rect().grow(8.0).intersects(rect):
			return false
	return true

## Push once enough of an army has gathered. Waiting longer means bigger pushes.
func _ai_maybe_attack() -> void:
	if ai_attack_timer > 0.0:
		return
	var army := _team_combat_units(1)
	var need := maxi(3, int(round(float(4 + ai_wave) * ai_aggression)))
	if army.size() < need:
		return
	var target = _ai_pick_target()
	if target == null:
		return
	for u in army:
		u.order_attack(target)
	ai_wave += 1
	ai_attack_timer = maxf(22.0, (55.0 - float(ai_wave) * 3.0) / maxf(ai_aggression, 0.5))
	_ai_log("wave %d: %d units -> %s" % [ai_wave, army.size(), String(target.type_id) if target.get("type_id") != null else "unit"])
	_say("Enemy attack wave %d incoming." % ai_wave)
	if sfx != null:
		sfx.ui("alarm", -4.0)

## Hit the economy first: harvesters, then whatever it can reach.
func _ai_pick_target():
	var base = _building_of(1, "cy")
	var from := terrain.tile_center(_base_anchor(1))
	if base != null:
		from = base.global_position
	# Early waves hit buildings; raiding the harvesters comes once you have had
	# time to put a turret next to your spice field.
	if ai_wave >= 2:
		var best = null
		var best_d := 1.0e9
		for u in units:
			if not is_instance_valid(u) or u.dead or u.team != 0 or u.type_id != "harvester":
				continue
			var d: float = from.distance_to(u.global_position)
			if d < best_d:
				best_d = d
				best = u
		if best != null:
			return best
	for id in ["refinery", "factory", "barracks", "turret", "cy"]:
		var pick = null
		var pick_d := 1.0e9
		for b in buildings:
			if not is_instance_valid(b) or b.dead or b.team != 0 or b.type_id != id:
				continue
			var d: float = from.distance_to(b.global_position)
			if d < pick_d:
				pick_d = d
				pick = b
		if pick != null:
			return pick
	return null

func _count_units(team: int, id: String) -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u) and not u.dead and u.team == team and u.type_id == id:
			n += 1
	return n

func _count_buildings(team: int, id: String) -> int:
	var n := 0
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == team and b.type_id == id:
			n += 1
	return n

func _team_combat_units(team: int) -> Array:
	var out: Array = []
	for u in units:
		if is_instance_valid(u) and not u.dead and u.team == team and u.damage > 0.0:
			out.append(u)
	return out

func _ai_queued(id: String) -> int:
	var n := 0
	for item in ai_queue:
		if String(item["id"]) == id:
			n += 1
	return n

# ------------------------------------------------------------------ victory

func _team_has_anything(team: int) -> bool:
	for u in units:
		if is_instance_valid(u) and not u.dead and u.team == team:
			return true
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == team:
			return true
	return false

func _enemy_units() -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u) and not u.dead and u.team == 1:
			n += 1
	return n

func _enemy_structures() -> int:
	var n := 0
	for b in buildings:
		if is_instance_valid(b) and not b.dead and b.team == 1:
			n += 1
	return n

func _objective_met() -> bool:
	if objective.is_empty():
		return not _has_building(1, "cy")
	match String(objective.get("type", "")):
		"harvest":
			return harvested >= int(objective.get("credits", 0))
		"harvest_or_clear":
			return harvested >= int(objective.get("credits", 0)) \
				or enemy_units_destroyed >= int(objective.get("kills", 4)) \
				or _enemy_units() == 0
		"destroy_units":
			return _enemy_units() == 0
		"destroy_structures":
			return _enemy_structures() == 0
		"destroy_all", "stronghold":
			return _enemy_units() == 0 and _enemy_structures() == 0
	return not _has_building(1, "cy")

func _check_victory() -> void:
	if game_over:
		return
	if campaign_mission:
		if not _team_has_anything(0):
			_finish(false)
			return
		if _objective_met():
			_finish(true)
		return
	if not _has_building(0, "cy"):
		_finish(false)
	elif not _has_building(1, "cy"):
		_finish(true)

func _stats() -> Dictionary:
	return {
		"time": elapsed,
		"units_destroyed": enemy_units_destroyed,
		"structures_destroyed": enemy_buildings_destroyed,
		"spice": harvested,
		"units_built": units_built,
		"units_lost": player_units_lost,
	}

func _finish(win: bool) -> void:
	if game_over:
		return
	game_over = true
	var stats := _stats()
	var time_text := "%d:%02d" % [int(elapsed) / 60, int(elapsed) % 60]
	var body := "Time %s    Units destroyed %d    Spice harvested %d" % [time_text, enemy_units_destroyed, harvested]
	var buttons: Array = []
	var title := "VICTORY" if win else "DEFEAT"
	if campaign_mission:
		title = "MISSION VICTORY" if win else "MISSION DEFEAT"
		var state = GameDefs.campaign
		if state != null:
			state.call("record_mission_result", win, stats)
		if win:
			body += "\n%s is ours. The next front is unlocked." % String(mission.get("region_name", "The province"))
			buttons = [{"text": "CONTINUE TO MAP", "method": "continue_to_map", "primary": true}]
		else:
			body += "\nThe battle is lost. The province remains in enemy hands."
			buttons = [
				{"text": "RETRY MISSION", "method": "retry_mission", "primary": true},
				{"text": "BACK TO MAP", "method": "back_to_map"},
			]
	else:
		if win:
			body = "You held the desert.\nTime %s    Units built %d    Spice delivered %d" % [time_text, units_built, harvested]
		else:
			body = "Your Construction Yard has fallen.\nTime %s    Units built %d    Spice delivered %d" % [time_text, units_built, harvested]
		buttons = [
			{"text": "FIGHT AGAIN", "method": "restart", "primary": true},
			{"text": "MAIN MENU", "method": "main_menu"},
		]
	if hud != null:
		hud.show_result(win, body, buttons, title)
	if sfx != null:
		sfx.ui("alarm", -2.0, 1.3 if win else 0.7)

func debug_win_mission() -> void:
	if game_over:
		return
	_finish(true)

func _stop_battle_audio() -> void:
	if audio != null and audio.has_method("stop_all"):
		audio.call("stop_all")

func continue_to_map() -> void:
	_stop_battle_audio()
	var state = GameDefs.campaign
	if state != null:
		state.call("return_to_map")
	get_tree().change_scene_to_file("res://scenes/campaign_map.tscn")

func back_to_map() -> void:
	continue_to_map()

func retry_mission() -> void:
	get_tree().reload_current_scene()

func main_menu() -> void:
	_stop_battle_audio()
	var state = GameDefs.campaign
	if state != null:
		state.call("cancel_battle")
	get_tree().change_scene_to_file("res://scenes/house_select.tscn")

func restart() -> void:
	get_tree().reload_current_scene()

func _exit_tree() -> void:
	_stop_battle_audio()

# ------------------------------------------------------------------ messages

func _say(msg: String) -> void:
	messages.append(msg)
	while messages.size() > 2:
		messages.pop_front()
	if hud != null:
		hud.refresh()

func recent_messages() -> Array:
	return messages

func hud_status() -> String:
	if rally_mode and rally_building != null and is_instance_valid(rally_building):
		return "RALLY %s - tap the destination" % String(GameDefs.STRUCTURES[rally_building.type_id]["name"]).to_upper()
	if placing != "":
		return "PLACE %s - tap rock or concrete, CANCEL to keep READY" % String(GameDefs.STRUCTURES[placing]["name"])
	if not ready_structure.is_empty():
		return "%s READY - tap its icon to place" % String(ready_structure["name"]).to_upper()
	if brush != "":
		return "%s - tap tiles to place" % String(GameDefs.BRUSHES[brush]["name"]).to_upper()
	if selected_build != null and is_instance_valid(selected_build) and not selected_build.dead:
		var b_name := String(GameDefs.STRUCTURES[selected_build.type_id]["name"])
		var power_note := ""
		if selected_build.type_id == "rocketturret" and not has_power(0):
			power_note = "  NO POWER"
		if selected_build.repairing:
			return "%s - repairing  %d/%d HP%s" % [b_name, int(selected_build.hp), int(selected_build.max_hp), power_note]
		return "%s - %d/%d HP%s" % [b_name, int(selected_build.hp), int(selected_build.max_hp), power_note]
	var active: Array[String] = []
	for category in ["structures", "infantry", "vehicles"]:
		var q := _queue_for_category(category)
		if q.is_empty():
			continue
		var item: Dictionary = q[0]
		var pct := int(clampf(1.0 - float(item["left"]) / maxf(float(item["total"]), 0.01), 0.0, 1.0) * 100.0)
		var short := String({"structures": "BLD", "infantry": "INF", "vehicles": "VEH"}[category])
		active.append("%s %s %d%% x%d" % [short, String(item["name"]), pct, q.size()])
	if not active.is_empty():
		var note := "" if has_power(0) else "  LOW POWER"
		return " | ".join(active) + note
	if selected.size() == 1:
		var u = selected[0]
		if is_instance_valid(u):
			return "%s selected - %d/%d HP" % [String(GameDefs.UNITS[u.type_id]["name"]), int(u.hp), int(u.max_hp)]
	elif selected.size() > 1:
		return "%d units selected" % selected.size()
	return hint

# -------------------------------------------------------------------- overlay

func _draw() -> void:
	if placing != "":
		var span := GameDefs.size_of(placing)
		var tile := terrain.tile_of(hover_world) - span / 2
		var ok := can_place(placing, tile)
		var world_rect := Rect2(Vector2(tile) * float(TILE), Vector2(span) * float(TILE))
		var fill := Color(0.3, 1.0, 0.4, 0.22) if ok else Color(1.0, 0.3, 0.3, 0.22)
		var edge := Color(0.35, 1.0, 0.45, 0.9) if ok else Color(1.0, 0.35, 0.3, 0.9)
		draw_rect(world_rect, fill)
		draw_rect(world_rect, edge, false, 2.0)
	elif brush != "":
		var center := terrain.tile_of(hover_world)
		var radius := 1 if brush == "slab" else 0
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var tile := center + Vector2i(dx, dy)
				var ok := _can_pave_tile(tile) if brush == "slab" else can_place("wall", tile)
				var rect := Rect2(Vector2(tile) * float(TILE), Vector2(float(TILE), float(TILE)))
				var fill := Color(0.3, 1.0, 0.4, 0.20) if ok else Color(1.0, 0.3, 0.3, 0.20)
				var edge := Color(0.35, 1.0, 0.45, 0.85) if ok else Color(1.0, 0.35, 0.3, 0.85)
				draw_rect(rect, fill)
				draw_rect(rect, edge, false, 1.5)
	if drag_active and (box_armed or not press_touch):
		var a := world_from_screen(drag_start)
		var b := world_from_screen(drag_now)
		var rect := Rect2(a, Vector2.ZERO).expand(b)
		draw_rect(rect, Color(0.4, 1.0, 0.5, 0.10))
		draw_rect(rect, Color(0.4, 1.0, 0.5, 0.75), false, 1.5)
	# Rally flags and the armed rally target. These are map annotations only;
	# production and movement still use the normal collision-aware helpers.
	for b in buildings:
		if not is_instance_valid(b) or b.dead or b.team != 0 or not b.has_rally:
			continue
		var p: Vector2 = b.rally_point
		var pulse := 0.68 + 0.32 * absf(sin(Time.get_ticks_msec() * 0.004))
		var house_col := GameDefs.team_color(b.team)
		var flag_col := Color(house_col.r, house_col.g, house_col.b, 1.0)
		var line_col := Color(house_col.r, house_col.g, house_col.b, 0.38)
		draw_dashed_line(b.global_position, p, line_col, 1.0, 6.0, true, true)
		draw_circle(p, 13.0, Color(0.06, 0.09, 0.13, 0.60))
		draw_arc(p, 11.0, 0.0, TAU, 24, Color(flag_col.r, flag_col.g, flag_col.b, pulse), 2.0)
		draw_line(p, p + Vector2(0.0, -20.0), Color(0.86, 0.90, 0.96, 0.95), 2.0)
		draw_colored_polygon(PackedVector2Array([p + Vector2(0.0, -20.0), p + Vector2(13.0, -15.0), p + Vector2(0.0, -9.0)]), flag_col)
	if rally_mode and rally_building != null and is_instance_valid(rally_building):
		var box: Rect2 = rally_building.world_rect().grow(4.0)
		var pulse := 0.55 + 0.45 * absf(sin(Time.get_ticks_msec() * 0.006))
		draw_rect(box, Color(0.35, 0.72, 1.0, pulse), false, 2.0)
