class_name Harvester
extends Unit

## Gathers spice, drives it back to a refinery and converts it into credits.

var cargo := 0.0
var capacity := 300.0
var state := "seek"
var spice_tile := Vector2i(-1, -1)
var harvest_tick := 0.0
var idle_timer := 0.0
var dust_clock := 0.0

func configure(id: String, team_id: int, g) -> void:
	super.configure(id, team_id, g)
	has_move = false
	capacity = 300.0

func _tick_orders(delta: float) -> void:
	match state:
		"seek":
			var tile: Vector2i = game.terrain.find_spice_tile(game.terrain.tile_of(global_position), 40)
			if tile.x >= 0:
				spice_tile = tile
				set_destination(game.terrain.tile_center(tile))
				state = "to_spice"
			else:
				_idle(delta)
		"to_spice":
			if game.terrain.spice_at(spice_tile) < 8.0:
				state = "seek"
				return
			if global_position.distance_to(move_target) <= 12.0:
				has_move = false
				state = "harvest"
				harvest_tick = 0.0
			elif not has_move:
				state = "seek"
			else:
				_follow_path(delta)
		"harvest":
			has_move = false
			harvest_tick += delta
			if harvest_tick >= 0.4:
				harvest_tick = 0.0
				var got: float = game.terrain.take_spice(spice_tile, minf(5.0, capacity - cargo))
				cargo += got
				game.terrain.queue_redraw()
				if got > 0.0 and game.sfx != null:
					game.sfx.play_at("harvest", global_position, -10.0)
				if cargo >= capacity:
					_head_to_refinery()
				elif got <= 0.0:
					# This patch is mined out. Drive to the next one and keep
					# filling the hopper instead of going home half empty.
					if not _next_patch():
						if cargo > 0.0:
							_head_to_refinery()
						else:
							state = "seek"
		"to_refinery":
			# Spice only changes hands at the refinery itself, never at whatever
			# point the unit happens to stop on.
			var refinery = game.nearest_building(global_position, team, "refinery")
			var at_refinery: bool = refinery != null \
					and global_position.distance_to(refinery.global_position) <= refinery.size_px * 0.5 + 70.0
			if at_refinery:
				has_move = false
				if cargo > 0.0:
					game.add_credits(team, cargo)
					if game.sfx != null:
						game.sfx.play_at("coin", global_position, -8.0)
					game.fx.popup("+%d" % int(cargo), global_position + Vector2(0.0, -18.0))
				cargo = 0.0
				state = "seek"
			elif not has_move:
				state = "seek"
			else:
				_follow_path(delta)
		"ordered":
			if not has_move:
				# A full hopper goes home once the order has been carried out.
				if cargo >= capacity:
					_head_to_refinery()
				else:
					state = "seek"
			else:
				_follow_path(delta)

## Player orders take over: drop the mining run, otherwise the delivery state
## would keep running and pay the load out wherever the new target is.
func order_move(pos: Vector2) -> void:
	super.order_move(pos)
	state = "ordered"
	harvest_tick = 0.0
	idle_timer = 0.0

## Nearest patch that still has spice, searching further out each time.
## False when there is nothing worth the drive.
func _next_patch() -> bool:
	for radius in [8, 16, 28]:
		var tile: Vector2i = game.terrain.find_spice_tile(spice_tile, radius)
		if tile.x >= 0:
			spice_tile = tile
			set_destination(game.terrain.tile_center(tile))
			state = "to_spice"
			return true
	return false

func _head_to_refinery() -> void:
	var refinery = game.nearest_building(global_position, team, "refinery")
	if refinery == null:
		state = "seek"
		return
	var drop: Vector2 = refinery.global_position + Vector2(0.0, refinery.size_px * 0.5 + float(GameDefs.TILE) * 0.7)
	set_destination(game.terrain.tile_center(game.terrain.tile_of(drop)))
	state = "to_refinery"

func _process(delta: float) -> void:
	super._process(delta)
	dust_clock += delta

func _idle(delta: float) -> void:
	has_move = false
	idle_timer += delta
	if idle_timer > 1.5:
		idle_timer = 0.0
		state = "seek"

func _draw() -> void:
	# Baked hull direction handles the facing; this live dust and scoop jitter
	# gives the mining state readable feedback without touching harvesting logic.
	if state == "harvest" or locomoting:
		var back := Vector2.RIGHT.rotated(facing + PI)
		for i in 3:
			var phase := fmod(dust_clock * (1.7 if state == "harvest" else 1.1) + float(i) * 0.31, 1.0)
			var p := back * (radius * (0.65 + phase * 0.75)) + Vector2(0.0, -6.0 - phase * 8.0)
			p += Vector2(sin(dust_clock * 11.0 + float(i)) * 4.0, 0.0)
			draw_circle(p, 2.5 + phase * 5.5, Color(0.72, 0.58, 0.38, 0.26 * (1.0 - phase)))
		if state == "harvest":
			var front := Vector2.RIGHT.rotated(facing)
			var jitter := sin(dust_clock * 16.0) * 1.5
			draw_circle(front * (radius * 0.9) + Vector2(0.0, 4.0 + jitter), 3.0,
				Color(0.95, 0.62, 0.20, 0.55))
	super._draw()
	if cargo > 1.0:
		var w := 30.0
		var k := clampf(cargo / capacity, 0.0, 1.0)
		draw_rect(Rect2(Vector2(-w * 0.5, radius + 4.0), Vector2(w, 4.0)), Color(0.0, 0.0, 0.0, 0.55))
		draw_rect(Rect2(Vector2(-w * 0.5, radius + 4.0), Vector2(w * k, 4.0)), Color(0.95, 0.6, 0.12))
