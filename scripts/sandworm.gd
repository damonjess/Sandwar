class_name Sandworm
extends Node2D

## Shai-Hulud. A sand-only apex predator.
##
## It prowls open desert as a travelling dune ridge, locks onto vibrations,
## warns the player, and surfaces under anything still standing on open sand
## when it arrives. Rock plateaus and concrete are absolute safety, and heavy
## nearby gunfire makes it recoil and burrow.

var game
var state := "prowl"
var target = null
var waypoint := Vector2.ZERO
var move_dir := Vector2.RIGHT
var clock := 0.0
var speed := 58.0
## Slower than before: the ridge still closes on a stationary harvester, but
## a player who reacts at the wormsign has time to break the lock.
var stalk_speed := 120.0
## Fair warning window, rolled fresh each lock-on.
var window := 7.0
var stalk_time := 0.0
var surface_time := 0.0
var dig_timer := 0.0
## Time left before this worm wakes at the start of a battle.
var wake_timer := 0.0
## Where the target was standing when the lock began. Running far enough
## from this point breaks the vibration trail and the worm dives.
var lock_pos := Vector2.ZERO
var suppression := 0.0
var scan_timer := 0.0
var wander_timer := 0.0

## Only nearby work is felt through the sand, not the whole map.
const SENSE_TILES := 9.0
## Distance a target must run from the lock point to escape.
const ESCAPE_TILES := 5.0
const WARN_MIN := 7.0
const WARN_MAX := 9.0

func setup(g, index := 0) -> void:
	game = g
	# Start far from the player's opening base and field, and stay under the
	# sand for a while so the first harvest is never an instant ambush.
	position = _random_sand_position(22.0, 12.0)
	state = "dormant"
	wake_timer = 70.0 + float(index) * 70.0
	z_index = 4
	visible = false
	_pick_waypoint()
	queue_redraw()

func _process(delta: float) -> void:
	if game == null or game.game_over:
		return
	clock += delta
	var tile: Vector2i = game.terrain.tile_of(global_position)
	visible = game.terrain.is_seen_tile(tile.x, tile.y) and state != "dig" and state != "dormant"
	match state:
		"dormant":
			wake_timer -= delta
			visible = false
			if wake_timer <= 0.0:
				state = "prowl"
				scan_timer = 1.5
				_pick_waypoint()
		"prowl":
			_prowl(delta)
		"stalk":
			stalk_time += delta
			_stalk(delta)
		"surface":
			surface_time += delta
			if surface_time >= 0.95:
				_bite()
		"dig":
			dig_timer -= delta
			visible = false
			if dig_timer <= 0.0:
				_relocate()
	queue_redraw()

# ------------------------------------------------------------------- prowling

func _prowl(delta: float) -> void:
	scan_timer -= delta
	if scan_timer <= 0.0:
		scan_timer = 0.7
		var found = _find_vibration()
		if found != null:
			_lock(found)
			return
	wander_timer += delta
	if position.distance_to(waypoint) < 18.0 or wander_timer > 6.0:
		_pick_waypoint()
	_move_sand((waypoint - position).normalized(), speed, delta)

## Only moving or working ground traffic on open sand makes a vibration.
func _find_vibration():
	# A full worm cannot share the hunt, and after a meal the whole desert
	# goes quiet for a while. One busy worm is tension; two are a lockdown.
	if game.elapsed < game.worm_quiet_until:
		return null
	if game.worm_hunting != null and game.worm_hunting != self:
		return null
	var best = null
	var best_d := SENSE_TILES * float(GameDefs.TILE)
	for u in game.units:
		if not is_instance_valid(u) or u.dead or u.airborne:
			continue
		if not u.visible:
			continue
		if not _vibrating(u):
			continue
		if not _on_sand(u.global_position):
			continue
		var d: float = u.global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best = u
	return best

func _vibrating(u) -> bool:
	if u.has_move or u.locomoting:
		return true
	if u.type_id == "harvester":
		var st := String(u.get("state"))
		return st == "harvest" or st == "to_spice" or st == "to_refinery"
	return false

func _lock(t) -> void:
	if game.worm_hunting != null and game.worm_hunting != self:
		return
	game.worm_hunting = self
	target = t
	state = "stalk"
	stalk_time = 0.0
	lock_pos = t.global_position
	window = game.rng.randf_range(WARN_MIN, WARN_MAX)
	if int(t.team) == 0:
		game.worm_warning(global_position)
	# The ridge visibly turns toward its prey.
	move_dir = (t.global_position - position).normalized()
	queue_redraw()

# ---------------------------------------------------------------- stalking

func _stalk(delta: float) -> void:
	if not _valid_target():
		_abort()
		return
	# Stepping onto rock or concrete breaks the lock immediately: retreating
	# is always a clean save.
	if not _on_sand(target.global_position):
		_abort()
		return
	# Driving away from the disturbance breaks the trail. This is the mobile-
	# friendly escape hatch: a player who reacts to the wormsign can save the
	# harvester without needing a rock outcrop within a few tiles.
	if target.global_position.distance_to(lock_pos) > ESCAPE_TILES * float(GameDefs.TILE):
		_abort()
		return
	var to: Vector2 = target.global_position - position
	if to.length() > 4.0:
		_move_sand(to.normalized(), stalk_speed, delta)
	if stalk_time >= window and position.distance_to(target.global_position) <= 46.0:
		_surface()
		return
	if stalk_time > 14.0:
		_abort()
		return
	_suppression(delta)

func _valid_target() -> bool:
	return target != null and is_instance_valid(target) and not target.dead and not target.airborne

## Fire from several nearby squads makes the worm recoil and burrow early.
func _suppression(delta: float) -> void:
	var shooters := 0
	for u in game.units:
		if not is_instance_valid(u) or u.dead or u.airborne:
			continue
		if u.damage <= 0.0 or u.type_id == "harvester":
			continue
		if u.global_position.distance_to(global_position) <= 190.0:
			shooters += 1
	if shooters >= 3:
		suppression += delta * (0.5 + 0.25 * float(shooters - 2))
	else:
		suppression = maxf(0.0, suppression - delta * 0.7)
	if suppression >= 2.0:
		if game.fx != null:
			game.fx.popup("RECOIL", global_position + Vector2(0.0, -34.0))
			game.fx.sand_burst(global_position, 54.0, 0.7)
		game.play_sfx("build_place", global_position, -4.0, 0.62)
		_dig(game.rng.randf_range(45.0, 65.0))

# ------------------------------------------------------------- surfacing

func _surface() -> void:
	state = "surface"
	surface_time = 0.0
	if game.fx != null:
		game.fx.sand_burst(global_position, 92.0, 1.0)
	game.play_sfx("worm_roar", global_position, 3.0, 0.85)
	game.play_voice("worm_attack", 15.0)
	if game.camera != null:
		game.camera.shake(0.55, 8.0)
	queue_redraw()

func _bite() -> void:
	var meal = target
	if meal != null and is_instance_valid(meal) and not meal.dead and not meal.airborne \
			and _on_sand(meal.global_position):
		if int(meal.team) == 0 and meal.type_id == "harvester":
			game.play_voice("harvester_under_attack", 15.0)
		if game.fx != null:
			game.fx.popup("SWALLOWED", meal.global_position + Vector2(0.0, -22.0))
		meal.swallowed = true
		meal.die()
		if game.fx != null:
			game.fx.sand_burst(global_position, 70.0, 0.85)
		# Give the player room to rebuild after a loss: no worm may hunt again
		# for a while, not just the one that fed.
		game.worm_quiet_until = game.elapsed + 80.0
	# One meal per surfacing: the worm always leaves the table after a bite.
	_dig(game.rng.randf_range(55.0, 75.0))

func _abort() -> void:
	# Target reached rock, went airborne or outran the vibration trail. Dive,
	# move away and give the harvester time to get back to work.
	if game.fx != null:
		game.fx.sand_burst(global_position, 38.0, 0.5)
	_dig(18.0)

func _dig(seconds: float) -> void:
	if game.worm_hunting == self:
		game.worm_hunting = null
	state = "dig"
	target = null
	dig_timer = seconds
	suppression = 0.0
	visible = false
	queue_redraw()

func _relocate() -> void:
	position = _random_sand_position(16.0, 8.0)
	state = "prowl"
	stalk_time = 0.0
	scan_timer = 1.2
	visible = true
	_pick_waypoint()
	queue_redraw()

# -------------------------------------------------------------- sand movement

func _on_sand(p: Vector2) -> bool:
	return game.terrain.is_open_sand(game.terrain.tile_of(p))

## Step only onto open sand. If the direct line is blocked by rock, slide
## around it rather than ever crossing the plateau.
func _move_sand(dir: Vector2, move_speed: float, delta: float) -> void:
	if dir.length() < 0.01:
		return
	var step := move_speed * delta
	var options := [dir, dir.rotated(0.45), dir.rotated(-0.45), dir.rotated(0.95), dir.rotated(-0.95)]
	for option in options:
		var d: Vector2 = option.normalized()
		var p: Vector2 = position + d * step
		if _on_sand(p):
			position = p
			move_dir = d
			return
	# Boxed in by rock: pick a fresh patch of sand and try again next frame.
	move_dir = dir.rotated(1.1)
	_pick_waypoint()

func _pick_waypoint() -> void:
	var best := position
	for i in 24:
		var a: float = game.rng.randf() * TAU
		var d: float = game.rng.randf_range(3.0, 10.0) * float(GameDefs.TILE)
		var p: Vector2 = position + Vector2.RIGHT.rotated(a) * d
		if _on_sand(p):
			best = p
			break
	waypoint = best
	wander_timer = 0.0

func _random_sand_position(min_from_base := 16.0, min_from_units := 8.0) -> Vector2:
	var anchor_tile: Vector2i = game._base_anchor(0)
	var anchor: Vector2 = game.terrain.tile_center(anchor_tile)
	var fallback := position
	for i in 160:
		var tile := Vector2i(game.rng.randi_range(1, GameDefs.MAP - 2), game.rng.randi_range(1, GameDefs.MAP - 2))
		if not game.terrain.is_open_sand(tile):
			continue
		var p: Vector2 = game.terrain.tile_center(tile)
		fallback = p
		if p.distance_to(anchor) < min_from_base * float(GameDefs.TILE):
			continue
		var clear := true
		for u in game.units:
			if is_instance_valid(u) and not u.dead and not u.airborne and int(u.team) == 0:
				if p.distance_to(u.global_position) < min_from_units * float(GameDefs.TILE):
					clear = false
					break
		if clear:
			return p
	return fallback

# ------------------------------------------------------------------- drawing

func _draw() -> void:
	if state == "surface":
		_draw_maw()
		return
	_draw_ridge()

func _draw_ridge() -> void:
	var side := Vector2(-move_dir.y, move_dir.x)
	# Trailing dust: the tell that something huge is moving under the sand.
	for i in 5:
		var phase := fmod(clock * 1.35 + float(i) * 0.21, 1.0)
		var back := -move_dir * (22.0 + phase * 50.0)
		var drift := side * sin(clock * 4.2 + float(i) * 1.9) * (4.0 + phase * 8.0)
		draw_circle(back + drift + Vector2(0.0, 4.0), 4.0 + phase * 10.0,
			Color(0.80, 0.66, 0.44, (1.0 - phase) * 0.26))
	var pulse := 0.9 + 0.1 * sin(clock * 2.4)
	# One long, low dune ridge aligned with travel, with a darker trough on
	# the lee side and a pale crest catching the sun. The whole shape breathes
	# and slides, so it reads as sand being pushed up from below.
	var angle := move_dir.angle()
	draw_set_transform(Vector2(0.0, 5.0), angle, Vector2(1.95, 0.62) * pulse)
	draw_circle(Vector2.ZERO, 22.0, Color(0.44, 0.32, 0.19, 0.45))
	draw_circle(Vector2.ZERO, 18.0, Color(0.60, 0.45, 0.27, 0.96))
	draw_set_transform(Vector2(-3.0, -2.0), angle, Vector2(1.55, 0.48) * pulse)
	draw_circle(Vector2.ZERO, 15.0, Color(0.76, 0.60, 0.39, 0.97))
	draw_set_transform(Vector2(-7.0, -4.0), angle, Vector2(1.15, 0.34) * pulse)
	draw_circle(Vector2.ZERO, 12.0, Color(0.88, 0.74, 0.52, 0.95))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Slip-face shadow along the trailing edge.
	draw_set_transform(-move_dir * 14.0, angle, Vector2(1.0, 0.30))
	draw_circle(Vector2.ZERO, 12.0, Color(0.36, 0.25, 0.14, 0.45))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Ripple rings shed off the crest.
	for i in 3:
		var a := clock * 1.6 + float(i) * 2.1
		var p := side * sin(a) * 22.0 - move_dir * (2.0 + cos(a) * 16.0)
		draw_arc(p, 16.0 + float(i) * 7.0, a, a + 1.2, 9, Color(0.86, 0.72, 0.50, 0.24), 1.6)
	# Dark churn right under the crest.
	draw_circle(-move_dir * 6.0, 7.0, Color(0.38, 0.27, 0.15, 0.52))
	# Mark the quarry during the warning window so the player knows exactly
	# which harvester or squad needs to move.
	if state == "stalk" and _valid_target():
		var rel: Vector2 = target.global_position - global_position
		var alert := 0.55 + 0.45 * sin(clock * 6.0)
		draw_arc(rel, 27.0 + alert * 4.0, 0.0, TAU, 28,
			Color(1.0, 0.72, 0.18, 0.35 + alert * 0.30), 2.0)
		draw_circle(rel, 2.5, Color(1.0, 0.84, 0.36, 0.90))

func _draw_maw() -> void:
	var k := clampf(surface_time / 0.95, 0.0, 1.0)
	var r := lerpf(14.0, 46.0, k)
	# Concentric sand shockwave racing out across the desert.
	for i in 3:
		var reach := r + 16.0 + float(i) * 20.0 + surface_time * 32.0
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.62))
		draw_arc(Vector2.ZERO, reach, 0.0, TAU, 34,
			Color(0.88, 0.74, 0.48, maxf(0.0, 0.58 - float(i) * 0.16) * (1.0 - k * 0.45)), 4.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Sand mound heaped around the throat.
	draw_circle(Vector2.ZERO, r + 17.0, Color(0.50, 0.36, 0.21))
	draw_circle(Vector2.ZERO, r + 8.0, Color(0.64, 0.48, 0.28))
	draw_circle(Vector2(0.0, -3.0), r + 3.0, Color(0.74, 0.57, 0.36))
	# Gaping maw with a pale muscular rim.
	draw_circle(Vector2.ZERO, r, Color(0.72, 0.57, 0.38))
	draw_circle(Vector2.ZERO, r - 4.0, Color(0.09, 0.05, 0.035))
	draw_circle(Vector2.ZERO, r * 0.72, Color(0.22, 0.10, 0.06))
	draw_circle(Vector2(0.0, r * 0.12), r * 0.34, Color(0.025, 0.015, 0.012))
	# Ten thick pale teeth curving inward around the rim, all swept the same
	# way so the maw looks like it is twisting shut.
	for i in 10:
		var a := TAU * float(i) / 10.0 + 0.18
		var dir := Vector2(cos(a), sin(a))
		var tangent := Vector2(-sin(a), cos(a))
		var base := dir * (r + 1.0)
		var tip := dir * (r - 17.0) + tangent * 5.0
		draw_colored_polygon(PackedVector2Array([
			base + tangent * 6.0, base - tangent * 6.0, tip
		]), Color(0.95, 0.89, 0.72, 0.98))
		draw_line(base + tangent * 2.0, tip, Color(0.72, 0.62, 0.44, 0.7), 1.0)
