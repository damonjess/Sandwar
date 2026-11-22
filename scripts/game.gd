extends Node2D

## Sandwar - a Dune 2000 style RTS foundation.
## Spice economy, concrete bases, walls, unit production, combat and an AI.

const TILE := GameDefs.TILE
const MAP := GameDefs.MAP

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
var credits := [2200, 1500]
var harvested := 0
var units_built := 0
var elapsed := 0.0
var game_over := false

var selected: Array = []
var selected_build = null
var repair_mode := false
## Armed by the Guard/Rally action when a structure is selected. The next map
## tap becomes that structure's production rally point.
var rally_mode := false
var rally_building = null
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

func _ready() -> void:
	rng.randomize()

	terrain = Terrain.new()
	terrain.z_index = -10
	add_child(terrain)
	terrain.generate(rng.randi())

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
	focus_home()

	hud = GameHUD.new()
	add_child(hud)
	hud.setup(self)

	hint = "Tap a unit, then tap the ground.  Build from the side panel."
	_say("Spice must flow. Destroy the enemy Construction Yard.")
	_update_vision()
	_apply_fog()

func _process(delta: float) -> void:
	elapsed += delta
	if not game_over:
		_tick_production(delta)
		_tick_ai(delta)
		check_timer += delta
		if check_timer >= 0.5:
			check_timer = 0.0
			_check_victory()
		vision_timer += delta
		if vision_timer >= 0.2:
			vision_timer = 0.0
			_update_vision()
			_apply_fog()
		_tick_repair(delta)
	if placing != "" or brush != "" or drag_active:
		queue_redraw()

# ---------------------------------------------------------------- world setup

func _build_starting_bases() -> void:
	add_building("cy", 0, Vector2i(12, 38))
	add_building("refinery", 0, Vector2i(17, 38))
	add_building("barracks", 0, Vector2i(12, 43))
	add_building("turret", 0, Vector2i(19, 42))
	spawn_unit("harvester", 0, Vector2(21.0, 44.0) * float(TILE))
	spawn_unit("infantry", 0, Vector2(16.0, 44.0) * float(TILE))
	spawn_unit("infantry", 0, Vector2(16.8, 44.9) * float(TILE))
	spawn_unit("trike", 0, Vector2(18.4, 45.6) * float(TILE))

	add_building("cy", 1, Vector2i(38, 10))
	add_building("refinery", 1, Vector2i(43, 10))
	add_building("barracks", 1, Vector2i(38, 15))
	add_building("factory", 1, Vector2i(42, 14))
	add_building("turret", 1, Vector2i(36, 16))
	add_building("turret", 1, Vector2i(46, 12))
	spawn_unit("harvester", 1, Vector2(41.0, 16.0) * float(TILE))
	spawn_unit("infantry", 1, Vector2(40.0, 18.0) * float(TILE))
	spawn_unit("infantry", 1, Vector2(40.7, 18.7) * float(TILE))
	spawn_unit("trike", 1, Vector2(39.0, 19.2) * float(TILE))

func add_building(id: String, team: int, tile: Vector2i):
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
	if id == "windtrap" and paved < 1.0:
		# Built off its slab the trap starts damaged, as it does in Dune 2000.
		b.hp = b.max_hp * 0.6
	_buildings_changed()
	return b

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

func on_unit_destroyed(u) -> void:
	units.erase(u)
	selected.erase(u)
	if fx != null:
		fx.blast(u.global_position)
	play_sfx("explosion_medium", u.global_position, -1.0)

func on_building_destroyed(b) -> void:
	var was_wall: bool = b.type_id == "wall"
	var wall_tile: Vector2i = b.tile_origin()
	var wall_team: int = b.team
	buildings.erase(b)
	if selected_build == b:
		selected_build = null
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
		if not is_instance_valid(u) or u.dead or u.team == team:
			continue
		if fogged and not terrain.is_visible_at(u.global_position):
			continue
		var d: float = u.global_position.distance_to(pos)
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
			u.visible = u.team == 0 or terrain.is_visible_at(u.global_position)
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
	return nearest_building(Vector2(17.0, 41.0) * float(TILE), 0, producer_id)

# ---------------------------------------------------------------- production

func can_build(kind: String, id: String) -> bool:
	if game_over:
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
	return 1.0 if has_power(team_id) else 0.55

func _complete_unit(item: Dictionary) -> void:
	var id := String(item["id"])
	var producer = _find_producer(id)
	var origin := Vector2(17.0, 41.0) * float(TILE)
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

func can_place(type_id: String, tile: Vector2i) -> bool:
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
			_say("Cannot pave there.")
		if hud != null:
			hud.refresh()
	elif brush == "wall":
		var cost := int(GameDefs.BRUSHES["wall"]["cost"])
		if credits[0] < cost:
			_say("Not enough credits.")
			return
		var tile := terrain.tile_of(world)
		if not can_place("wall", tile):
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
	buildings.erase(b)
	if selected_build == b:
		selected_build = null
	if rally_building == b:
		rally_building = null
		rally_mode = false
	b.repairing = false
	b.dead = true
	b.queue_free()
	credits[0] += refund
	if was_wall:
		_refresh_wall_neighbours(wall_tile, wall_team)
	# Rebuild the navigation grid before finding the two crew spawn tiles: the
	# sold footprint must be walkable immediately.
	_buildings_changed()
	var base_tile := terrain.tile_of(center)
	for offset in [Vector2i(-1, 1), Vector2i(1, 1), Vector2i(0, 2), Vector2i(-2, 1)]:
		var open := _open_tile(base_tile + offset)
		if open.x < 0:
			continue
		spawn_unit("infantry", 0, terrain.tile_center(open) + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0)))
		break
	# Spawn the second crew member from the opposite side; keep this explicit so
	# the refund cannot accidentally create a squad.
	var second := _open_tile(base_tile + Vector2i(1, 1))
	if second.x < 0:
		second = _open_tile(base_tile + Vector2i(-1, 1))
	if second.x >= 0:
		spawn_unit("infantry", 0, terrain.tile_center(second) + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0)))
	if fx != null:
		fx.popup("+%d CR" % refund, center + Vector2(0.0, -20.0))
	play_ui_sfx("ui_click", -4.0)
	_say("Sold %s (+%d credits). Two infantry mustered." % [label, refund])
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
	ai_think = AI_THINK
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
	# Rebuild production before anything else.
	for id in AI_REBUILD:
		if not _has_building(1, id):
			_ai_buy_structure(id)
			return
	# Turrets around the yard, more as the game goes on.
	if _count_buildings(1, "turret") + _ai_queued("turret") < mini(8, 3 + int(float(ai_wave) / 2.0)):
		if _ai_buy_structure("turret"):
			return
	# One wind trap to power the yard, once the economy is up and running.
	if ai_wave >= 1 and _count_buildings(1, "windtrap") + _ai_queued("windtrap") < 1:
		if _ai_buy_structure("windtrap"):
			return
	if _team_combat_units(1).size() + ai_queue.size() >= AI_MAX_ARMY:
		return
	# Keep a mixed army: the type furthest behind its share of the force goes
	# next, so rocketeers, quads and (from the second wave) tanks all show up.
	var roster := ["infantry", "rocket", "trike", "quad"]
	# Tanks only once the economy can carry them: otherwise the treasury never
	# grows past the price because every cycle buys another soldier.
	if ai_wave >= 2 and _count_units(1, "harvester") >= 2:
		roster.append("tank")
	var pick := "infantry"
	var pick_ratio := 1.0e9
	for id in roster:
		var share := 1.0 if id == "tank" else 2.0
		var ratio := float(_count_units(1, id) + _ai_queued(id)) / share
		if ratio < pick_ratio:
			pick_ratio = ratio
			pick = id
	if pick == "tank":
		if credits[1] < int(GameDefs.UNITS["tank"]["cost"]):
			return
		_ai_buy_unit("tank")
		return
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
	var origin := Vector2(38.0, 12.0) * float(TILE)
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
	if army.size() < 4 + ai_wave:
		return
	var target = _ai_pick_target()
	if target == null:
		return
	for u in army:
		u.order_attack(target)
	ai_wave += 1
	ai_attack_timer = maxf(30.0, 55.0 - float(ai_wave) * 3.0)
	_ai_log("wave %d: %d units -> %s" % [ai_wave, army.size(), String(target.type_id) if target.get("type_id") != null else "unit"])
	_say("Enemy attack wave %d incoming." % ai_wave)
	if sfx != null:
		sfx.ui("alarm", -4.0)

## Hit the economy first: harvesters, then whatever it can reach.
func _ai_pick_target():
	var base = _building_of(1, "cy")
	var from := Vector2(38.0, 12.0) * float(TILE)
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

func _check_victory() -> void:
	if game_over:
		return
	if not _has_building(0, "cy"):
		_finish(false)
	elif not _has_building(1, "cy"):
		_finish(true)

func _finish(win: bool) -> void:
	if game_over:
		return
	game_over = true
	var body := "You held the desert.\nUnits built %d  -  Spice delivered %d  -  Time %d:%02d" % [units_built, harvested, int(elapsed) / 60, int(elapsed) % 60]
	if not win:
		body = "Your Construction Yard has fallen.\nUnits built %d  -  Spice delivered %d  -  Time %d:%02d" % [units_built, harvested, int(elapsed) / 60, int(elapsed) % 60]
	if hud != null:
		hud.show_result(win, body)
	if sfx != null:
		sfx.ui("alarm", -2.0, 1.3 if win else 0.7)

func restart() -> void:
	get_tree().reload_current_scene()

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
		draw_dashed_line(b.global_position, p, Color(0.30, 0.62, 1.0, 0.34), 1.0, 6.0, true, true)
		draw_circle(p, 13.0, Color(0.06, 0.09, 0.13, 0.60))
		draw_arc(p, 11.0, 0.0, TAU, 24, Color(0.38, 0.76, 1.0, pulse), 2.0)
		draw_line(p, p + Vector2(0.0, -20.0), Color(0.72, 0.88, 1.0, 0.95), 2.0)
		draw_colored_polygon(PackedVector2Array([p + Vector2(0.0, -20.0), p + Vector2(13.0, -15.0), p + Vector2(0.0, -9.0)]), Color(0.25, 0.58, 1.0, 0.95))
	if rally_mode and rally_building != null and is_instance_valid(rally_building):
		var box: Rect2 = rally_building.world_rect().grow(4.0)
		var pulse := 0.55 + 0.45 * absf(sin(Time.get_ticks_msec() * 0.006))
		draw_rect(box, Color(0.35, 0.72, 1.0, pulse), false, 2.0)
