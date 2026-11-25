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
## The baked hull has drive/harvest poses. Live dust, exhaust and ore spray
## supply the continuous motion between them.
var _exhaust_accum := 0.0
var _dust_accum := 0.0
var _plume_accum := 0.0
var _spice_accum := 0.0

func configure(id: String, team_id: int, g) -> void:
	super.configure(id, team_id, g)
	has_move = false
	capacity = 300.0

func _tick_orders(delta: float) -> void:
	if service_repair_pad(delta):
		return
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
			# A long haul home is exactly what the Carryall ferry is for. The
			# request is ignored while another dropship already has this hull.
			if not airborne and game != null:
				game.maybe_request_ferry(self)
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
	var working := state == "harvest"
	if game == null or game.fx == null:
		return
	var moving := locomoting or has_move
	if not working and not moving:
		return
	var back := -Vector2.RIGHT.rotated(facing)
	# The tall rear stack belches hard under load and idles softer on the move.
	_exhaust_accum += delta
	var exhaust_gap := 0.085 if working else 0.19
	if _exhaust_accum >= exhaust_gap:
		_exhaust_accum = 0.0
		# One tall rear stack on the left sponson.
		var stack: Vector2 = Vector2(-24.0, -12.0).rotated(facing)
		game.fx.exhaust_plume(global_position + stack, back, 1.35 if working else 0.9)
	# Ore spray belongs to the cutting edge, not to the ground type, so it is
	# emitted before the open-sand gate below.
	if working:
		var scoop: Vector2 = Vector2(33.0, 0.0).rotated(facing)
		_spice_accum += delta
		if _spice_accum >= 0.055:
			_spice_accum = 0.0
			game.fx.spice_kick(global_position + scoop + Vector2(0.0, -2.0), -back, 1.0)
			game.fx.spice_kick(global_position + scoop + Vector2(0.0, 3.0), back, 0.75)
	# Only open sand throws a dust plume; concrete pads and spice patches do not.
	var on_sand: bool = game.terrain != null \
			and game.terrain.is_open_sand(game.terrain.tile_of(global_position))
	if not on_sand:
		return
	_dust_accum += delta
	_plume_accum += delta if moving else 0.0
	if moving and _plume_accum >= 0.13:
		_plume_accum = 0.0
		var tail: Vector2 = global_position + back * (radius * 0.95) + Vector2(0.0, 2.0)
		game.fx.trail_dust(tail, back, 1.15)
	var dust_gap := 0.075 if working else 0.14
	if _dust_accum < dust_gap:
		return
	_dust_accum = 0.0
	for side in [-1.0, 1.0]:
		var sponson: Vector2 = Vector2(-8.0, float(side) * 11.0).rotated(facing)
		game.fx.track_dust(global_position + sponson, back, 1.0)
	game.fx.track_dust(global_position + Vector2(33.0, 0.0).rotated(facing), -back, 0.9)

func _idle(delta: float) -> void:
	has_move = false
	idle_timer += delta
	if idle_timer > 1.5:
		idle_timer = 0.0
		state = "seek"

## Live feedback over the baked dozer row: a vibrating cutting edge and warm
## ore motes, plus the full-hopper heat glow. The blade itself is baked, so no
## fake drums are drawn on top of the new model.
func _draw_machinery() -> void:
	var front := Vector2.RIGHT.rotated(facing)
	var side := Vector2(-front.y, front.x)
	if state == "harvest":
		var jitter := sin(dust_clock * 22.0) * 1.2
		var edge: Vector2 = front * 33.0 + Vector2(0.0, 1.0 + jitter)
		draw_line(edge - side * 9.0, edge + side * 9.0,
			Color(0.98, 0.80, 0.20, 0.50), 1.1, true)
		for i in 4:
			var phase := fmod(dust_clock * 2.3 + float(i) * 0.27, 1.0)
			var p: Vector2 = front * (30.0 + phase * 7.0) \
				+ side * sin(dust_clock * 8.0 + float(i)) * 7.0 \
				+ Vector2(0.0, -phase * 13.0)
			draw_circle(p, 1.1 + phase * 1.5,
				Color(0.98, 0.52, 0.10, (1.0 - phase) * 0.48))
	# A faint hot glow from the loaded hopper.
	if cargo > capacity * 0.30:
		var k := clampf(cargo / capacity, 0.0, 1.0)
		var glow := Vector2(-7.0, 0.0)
		var pulse := 0.75 + 0.25 * sin(dust_clock * 4.0)
		draw_circle(glow, 7.5 * k * pulse, Color(1.0, 0.42, 0.06, 0.10 + 0.10 * k))

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
	_draw_machinery()
	if cargo > 1.0:
		var w := 30.0
		var k := clampf(cargo / capacity, 0.0, 1.0)
		draw_rect(Rect2(Vector2(-w * 0.5, radius + 4.0), Vector2(w, 4.0)), Color(0.0, 0.0, 0.0, 0.55))
		draw_rect(Rect2(Vector2(-w * 0.5, radius + 4.0), Vector2(w * k, 4.0)), Color(0.95, 0.6, 0.12))
