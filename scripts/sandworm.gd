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
## Subtle per-worm variation keeps two Shai-Hulud from looking like copies.
var variant := 0
var art_phase := 0.0
var ridge_tex: Texture2D
var maw_tex: Texture2D

## Only nearby work is felt through the sand, not the whole map.
const SENSE_TILES := 9.0
## Distance a target must run from the lock point to escape.
const ESCAPE_TILES := 5.0
const WARN_MIN := 7.0
const WARN_MAX := 9.0
## Keep the visible body, not just its centre point, clear of cliff walls.
## The alpha silhouette of ridge.png spans about 193 px at its 205 px draw
## size; these samples cover that footprint plus a 1.4 tile safety margin.
const CLIFF_CLEARANCE_TILES := 1.4
const BODY_HALF_LENGTH := 96.0
const BODY_HALF_WIDTH := 32.0
const SURFACE_CLEARANCE_TILES := 1.5

func setup(g, index := 0) -> void:
	game = g
	variant = index
	art_phase = float(index) * 1.73
	if ridge_tex == null:
		ridge_tex = load("res://assets/sprites/sandworm/ridge.png")
	if maw_tex == null:
		maw_tex = load("res://assets/sprites/sandworm/maw.png")
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
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
	# is always a clean save. Standing on sand right beside a cliff is also safe;
	# the ridge must not surface with its mouth or body over the wall.
	if not _on_sand(target.global_position):
		_abort()
		return
	if not _clear_of_cliffs(target.global_position, SURFACE_CLEARANCE_TILES * float(GameDefs.TILE)):
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
	# Final defensive check: steering normally keeps the ridge clear, but a
	# target that moved beside a cliff during the warning window must not pull
	# the eruption plate across the rock face.
	if not _body_clear_at(global_position, move_dir) \
			or not _clear_of_cliffs(global_position, SURFACE_CLEARANCE_TILES * float(GameDefs.TILE)):
		_dig(1.0)
		return
	if target != null and is_instance_valid(target) \
			and not _clear_of_cliffs(target.global_position, SURFACE_CLEARANCE_TILES * float(GameDefs.TILE)):
		_abort()
		return
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

## Euclidean distance from a point to the nearest ROCK tile rectangle. A
## centre-only sand check lets the long ridge art spill over a cliff, so this
## is used on several points along the body instead.
func _clear_of_cliffs(p: Vector2, margin := CLIFF_CLEARANCE_TILES * float(GameDefs.TILE)) -> bool:
	var t := float(GameDefs.TILE)
	var tile: Vector2i = game.terrain.tile_of(p)
	var reach := int(ceil(margin / t)) + 1
	for y in range(tile.y - reach, tile.y + reach + 1):
		for x in range(tile.x - reach, tile.x + reach + 1):
			if not game.terrain.in_bounds(x, y):
				continue
			if game.terrain.types[y * GameDefs.MAP + x] != GameDefs.ROCK:
				continue
			var rect_pos := Vector2(float(x), float(y)) * t
			var closest := Vector2(
				clampf(p.x, rect_pos.x, rect_pos.x + t),
				clampf(p.y, rect_pos.y, rect_pos.y + t))
			if p.distance_squared_to(closest) < margin * margin:
				return false
	return true

## Sample the ridge footprint along its facing direction. This prevents the
## head or tail sweeping over a plateau during a turn as well as stopping the
## centre from entering rock.
func _body_clear_at(p: Vector2, direction: Vector2) -> bool:
	var d := direction.normalized()
	if d.length_squared() < 0.01:
		d = move_dir.normalized()
	var side := Vector2(-d.y, d.x)
	for along in [-BODY_HALF_LENGTH, -48.0, 0.0, 48.0, BODY_HALF_LENGTH]:
		for across in [-BODY_HALF_WIDTH, 0.0, BODY_HALF_WIDTH]:
			var q: Vector2 = p + d * along + side * across
			if not _on_sand(q):
				return false
			if not _clear_of_cliffs(q):
				return false
	return true

## Step only onto open sand with the whole ridge clear of cliffs. If the
## direct line is blocked, slide around it rather than ever crossing a wall.
func _move_sand(dir: Vector2, move_speed: float, delta: float) -> void:
	if dir.length() < 0.01:
		return
	var step := move_speed * delta
	var options := [dir, dir.rotated(0.45), dir.rotated(-0.45), dir.rotated(0.95), dir.rotated(-0.95)]
	for option in options:
		var d: Vector2 = option.normalized()
		var p: Vector2 = position + d * step
		if _body_clear_at(p, d):
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
		if _body_clear_at(p, (p - position).normalized()):
			best = p
			break
	waypoint = best
	wander_timer = 0.0

func _random_sand_position(min_from_base := 16.0, min_from_units := 8.0) -> Vector2:
	var anchor_tile: Vector2i = game._base_anchor(0)
	var anchor: Vector2 = game.terrain.tile_center(anchor_tile)
	# Spawn at least a body length plus the safety margin from every cliff. This
	# is orientation-independent, so a new ridge cannot emerge halfway over rock.
	var body_clearance := (BODY_HALF_LENGTH / float(GameDefs.TILE) + CLIFF_CLEARANCE_TILES) * float(GameDefs.TILE)
	var fallback := position
	for i in 160:
		var tile := Vector2i(game.rng.randi_range(1, GameDefs.MAP - 2), game.rng.randi_range(1, GameDefs.MAP - 2))
		if not game.terrain.is_open_sand(tile):
			continue
		var p: Vector2 = game.terrain.tile_center(tile)
		if not _clear_of_cliffs(p, body_clearance):
			continue
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

func _ridge_shape(offset: float, rx: float, ry: float, front_taper: float,
		back_taper: float, wobble: float, phase: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 40:
		var a := TAU * float(i) / 40.0
		var x := cos(a)
		var y := sin(a)
		var front := maxf(x, 0.0)
		var back := maxf(-x, 0.0)
		var width := 1.0 - front_taper * pow(front, 1.55) - back_taper * pow(back, 2.1)
		width = maxf(width, 0.035)
		var length := 1.0 + 0.12 * front - 0.05 * back
		var wob := 1.0 + wobble * sin(a * 4.0 + phase) + wobble * 0.45 * sin(a * 7.0 - 1.6)
		pts.append(Vector2(offset + x * length * rx, y * width * ry * wob))
	return pts

func _maw_blob(radius: float, wobble: float, phase: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 40:
		var a := TAU * float(i) / 40.0
		var rr := radius * (1.0 + wobble * sin(a * 5.0 + phase) + wobble * 0.42 * sin(a * 3.0 - phase * 0.7))
		pts.append(Vector2(cos(a) * rr, sin(a) * rr * 0.84))
	return pts

func _draw_ridge_sprite() -> void:
	var angle := move_dir.angle()
	var pulse := 1.0 + 0.015 * sin(clock * 2.4)
	var tint := Color(1.0, 1.0, 1.0, 0.98)
	if variant % 2 == 1:
		tint = Color(0.90, 0.82, 0.70, 0.98)
	# The baked/plate art is a long vertical teardrop; turn its pointed end into
	# the trailing end and let the long axis follow travel.
	draw_set_transform(Vector2(0.0, 4.0), angle - PI * 0.5, Vector2(pulse, 0.94 * pulse))
	var size := 205.0
	draw_texture_rect(ridge_tex, Rect2(Vector2(-size * 0.5, -size * 0.5), Vector2(size, size)), false, tint)

	# Wind-blown grit and the V-shaped wake sit above the plate.
	draw_set_transform(Vector2.ZERO, angle, Vector2.ONE)
	for i in 14:
		var phase := fmod(clock * 1.2 + float(i) * 0.16, 1.0)
		var p := Vector2(-8.0 - phase * 50.0, -4.0 + sin(float(i) * 2.1 + clock * 2.2) * 12.0)
		draw_circle(p, 0.9 + phase * 2.0, Color(1.0, 0.90, 0.68, (1.0 - phase) * 0.38))
	for s in [-1.0, 1.0]:
		draw_line(Vector2(-20.0, s * 10.0), Vector2(-58.0, s * 25.0),
			Color(1.0, 0.88, 0.64, 0.16), 1.4, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for i in 3:
		draw_arc(Vector2(-4.0, 3.0), 35.0 + float(i) * 10.0, angle - 1.18, angle + 1.18, 18,
			Color(0.94, 0.79, 0.53, 0.20 - float(i) * 0.04), 1.5, true)

	if state == "stalk":
		_draw_wormsign_ripples()

## Subtle broken sand ripples replace the old orange target circle and yellow
## dot. The minimap ping remains the tactical alert; this stays environmental.
func _draw_wormsign_ripples() -> void:
	var pulse := 0.5 + 0.5 * sin(clock * 3.2)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.70))
	for i in 3:
		var radius := 46.0 + float(i) * 15.0 + pulse * 2.5
		var start := clock * 0.10 + float(i) * 0.7
		for segment in 4:
			var a := start + float(segment) * TAU / 4.0
			draw_arc(Vector2.ZERO, radius, a, a + 0.52, 12,
				Color(0.91, 0.76, 0.51, 0.20 - float(i) * 0.042), 1.5, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_ridge() -> void:
	if ridge_tex != null:
		_draw_ridge_sprite()
		return
	var angle := move_dir.angle()
	var deep := Color(0.40, 0.26, 0.14)
	var wet := Color(0.57, 0.39, 0.22)
	var sand := Color(0.79, 0.62, 0.39)
	var crest := Color(0.94, 0.79, 0.53)
	var pale := Color(1.0, 0.90, 0.68)
	if variant % 2 == 1:
		deep = deep.darkened(0.06)
		wet = wet.darkened(0.04)
		sand = sand.darkened(0.03)
		crest = crest.darkened(0.02)
	var pulse := 1.0 + 0.018 * sin(clock * 2.4)

	# The wake is a set of shrinking sand waves, not a row of floating discs.
	draw_set_transform(Vector2(0.0, 5.0), angle, Vector2(pulse, 0.82 * pulse))
	for h in range(3, -1, -1):
		var s := 1.0 - float(h) * 0.16
		var off := -18.0 - float(h) * 21.0
		var alpha := 0.12 + 0.06 * float(3 - h)
		draw_colored_polygon(_ridge_shape(off, 43.0 * s, 17.0 * s, 0.82, 0.38, 0.14, 0.7 + float(h)),
			Color(deep.r, deep.g, deep.b, alpha))
		draw_colored_polygon(_ridge_shape(off + 1.0, 31.0 * s, 11.0 * s, 0.80, 0.36, 0.10, 1.1 + float(h)),
			Color(wet.r, wet.g, wet.b, alpha + 0.08))

	# A long teardrop dune: broad shoulders, a pointed nose, layered crest.
	draw_colored_polygon(_ridge_shape(0.0, 60.0, 26.0, 0.93, 0.18, 0.10, 0.3),
		Color(deep.r, deep.g, deep.b, 0.34))
	draw_colored_polygon(_ridge_shape(1.0, 54.0, 22.0, 0.91, 0.24, 0.08, 0.8),
		Color(wet.r, wet.g, wet.b, 0.94))
	draw_colored_polygon(_ridge_shape(3.0, 45.0, 17.0, 0.87, 0.30, 0.06, 1.5),
		Color(sand.r, sand.g, sand.b, 0.98))
	draw_colored_polygon(_ridge_shape(5.0, 32.0, 11.0, 0.80, 0.36, 0.05, 2.1),
		Color(crest.r, crest.g, crest.b, 0.94))

	# A bright winding crest, plus the shadowed slip face on the lee side.
	var crest_line := PackedVector2Array()
	for i in 12:
		var t := float(i) / 11.0
		crest_line.append(Vector2(lerpf(-27.0, 28.0, t), -5.5 - 2.2 * sin(t * PI) + 0.8 * sin(t * 7.0 + art_phase)))
	draw_polyline(crest_line, Color(1.0, 0.93, 0.72, 0.44), 2.1, true)
	draw_set_transform(Vector2(-9.0, 7.0), angle, Vector2(0.92, 0.48))
	draw_circle(Vector2.ZERO, 24.0, Color(0.22, 0.13, 0.06, 0.26))

	# A buried dorsal spine: small plates, not a row of black sails.
	draw_set_transform(Vector2.ZERO, angle, Vector2.ONE)
	for i in 5:
		var x := -14.0 + float(i) * 7.0
		var ph := 3.0 + 1.5 * sin(float(i) * 1.8 + art_phase)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - 3.0, 0.5), Vector2(x, -ph), Vector2(x + 3.0, 0.5)
		]), Color(deep.r, deep.g, deep.b, 0.46))

	# Wind-blown grit streaming off the crest.
	draw_set_transform(Vector2.ZERO, angle, Vector2.ONE)
	for i in 14:
		var phase := fmod(clock * 1.2 + float(i) * 0.16, 1.0)
		var p := Vector2(-8.0 - phase * 50.0, -4.0 + sin(float(i) * 2.1 + clock * 2.2) * 12.0)
		draw_circle(p, 0.9 + phase * 2.0, Color(pale.r, pale.g, pale.b, (1.0 - phase) * 0.40))
	for s in [-1.0, 1.0]:
		draw_line(Vector2(-20.0, s * 10.0), Vector2(-58.0, s * 25.0),
			Color(pale.r, pale.g, pale.b, 0.18), 1.4, true)

	# Broad sand ripples outrun the dune.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for i in 3:
		draw_arc(Vector2(-4.0, 3.0), 35.0 + float(i) * 10.0, angle - 1.18, angle + 1.18, 18,
			Color(crest.r, crest.g, crest.b, 0.22 - float(i) * 0.045), 1.5, true)

	if state == "stalk":
		_draw_wormsign_ripples()

func _draw_maw_sprite() -> void:
	var k := clampf(surface_time / 0.95, 0.0, 1.0)
	var r := lerpf(17.0, 50.0, k)
	var pulse := 1.0 + 0.025 * sin(clock * 5.0)
	var angle := move_dir.angle()
	# Shockwave belongs to the sand, under the erupting plate.
	for i in 3:
		var reach := r + 28.0 + float(i) * 21.0 + surface_time * 32.0
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.74))
		draw_arc(Vector2.ZERO, reach, 0.0, TAU, 40,
			Color(0.94, 0.79, 0.50, maxf(0.0, 0.42 - float(i) * 0.12) * (1.0 - k * 0.35)), 3.0, true)
	# The mouth plate includes the neck and eroded sand collar; rotate its neck
	# directly behind the direction the worm arrived from.
	var size := lerpf(105.0, 250.0, k)
	draw_set_transform(Vector2.ZERO, angle - PI * 0.5, Vector2(pulse, 0.95 * pulse))
	draw_texture_rect(maw_tex, Rect2(Vector2(-size * 0.5, -size * 0.5), Vector2(size, size)), false,
		Color(1.0, 1.0, 1.0, 0.99))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Sand thrown clear of the crater.
	for i in 24:
		var a := TAU * float(i) / 24.0 + 0.25
		var phase := fmod(clock * 1.8 + float(i) * 0.11, 1.0)
		var dir := Vector2(cos(a), sin(a) * 0.78)
		var d := r + 26.0 + phase * 46.0
		var p := dir * d
		var q := dir * (d + 7.0 + phase * 11.0)
		draw_line(p, q, Color(0.97, 0.84, 0.56, (1.0 - phase) * 0.50), 1.2 + phase * 1.2, true)
		draw_circle(p, 1.0 + phase * 2.2, Color(0.97, 0.85, 0.59, (1.0 - phase) * 0.50))

func _draw_maw() -> void:
	if maw_tex != null:
		_draw_maw_sprite()
		return
	var k := clampf(surface_time / 0.95, 0.0, 1.0)
	var r := lerpf(17.0, 50.0, k)
	var pulse := 1.0 + 0.025 * sin(clock * 5.0)
	var shudder := sin(clock * 17.0) * 0.014 * k
	var deep := Color(0.38, 0.24, 0.13)
	var wet := Color(0.54, 0.36, 0.20)
	var sand := Color(0.79, 0.61, 0.38)
	var crest := Color(0.94, 0.78, 0.51)
	var bone := Color(0.97, 0.89, 0.70)
	var gum := Color(0.33, 0.10, 0.065)
	if variant % 2 == 1:
		deep = deep.darkened(0.05)
		wet = wet.darkened(0.03)
		sand = sand.darkened(0.025)
		crest = crest.darkened(0.015)

	# Shockwave belongs to the sand, so it goes under the body.
	for i in 3:
		var reach := r + 28.0 + float(i) * 21.0 + surface_time * 32.0
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.74))
		draw_arc(Vector2.ZERO, reach, 0.0, TAU, 40,
			Color(0.94, 0.79, 0.50, maxf(0.0, 0.42 - float(i) * 0.12) * (1.0 - k * 0.35)), 3.0, true)

	# The worm's back rises behind the crater; only its upper arc is visible.
	draw_set_transform(Vector2(0.0, -r * 0.50), 0.0, Vector2(1.36 * pulse, 0.58))
	draw_circle(Vector2.ZERO, r + 40.0, Color(deep.r, deep.g, deep.b, 0.82))
	draw_circle(Vector2(0.0, -4.0), r + 32.0, Color(wet.r, wet.g, wet.b, 0.95))
	draw_circle(Vector2(0.0, -8.0), r + 24.0, Color(sand.r, sand.g, sand.b, 0.92))
	for i in 3:
		draw_arc(Vector2(0.0, -6.0), r + 28.0 - float(i) * 8.0, PI * 0.12, PI * 0.88, 16,
			Color(deep.r, deep.g, deep.b, 0.20), 3.0, true)
	for i in 5:
		var a := PI + 0.46 + (PI - 0.92) * float(i) / 4.0
		var p := Vector2(cos(a), sin(a) * 0.58) * (r + 29.0)
		var tangent := Vector2(-sin(a), cos(a) * 0.58)
		draw_colored_polygon(PackedVector2Array([
			p - tangent * 4.0, p + tangent * 4.0, p + Vector2(cos(a), sin(a) * 0.58) * 5.0
		]), Color(deep.r, deep.g, deep.b, 0.50))

	# The crater is a sand collar with a wet, irregular lip, not a brown disc.
	draw_set_transform(Vector2(0.0, 6.0), 0.0, Vector2(1.0, 0.84))
	draw_colored_polygon(_maw_blob(r + 31.0, 0.06, 0.4), Color(deep.r, deep.g, deep.b, 0.38))
	draw_set_transform(Vector2.ZERO, shudder, Vector2(1.0, 0.84))
	draw_colored_polygon(_maw_blob(r + 31.0, 0.07, 0.4), Color(deep.r, deep.g, deep.b, 0.68))
	draw_colored_polygon(_maw_blob(r + 24.0, 0.06, 1.2), Color(wet.r, wet.g, wet.b, 0.93))
	draw_colored_polygon(_maw_blob(r + 16.0, 0.055, 2.1), Color(sand.r, sand.g, sand.b, 0.98))
	draw_colored_polygon(_maw_blob(r + 9.0, 0.045, 2.8), Color(crest.r, crest.g, crest.b, 0.95))

	# Radial cracks and displaced sand clods around the rim.
	for i in 14:
		var a := TAU * float(i) / 14.0 + 0.09 + 0.04 * sin(float(i) * 2.2)
		var p0 := Vector2(cos(a), sin(a) * 0.84) * (r + 10.0)
		var p1 := Vector2(cos(a), sin(a) * 0.84) * (r + 27.0 + 3.0 * sin(float(i) * 1.7))
		draw_line(p0, p1, Color(deep.r, deep.g, deep.b, 0.22), 1.4, true)
	for i in 24:
		var a := TAU * float(i) / 24.0 + 0.21
		if i % 3 == 0:
			var p := Vector2(cos(a), sin(a) * 0.84) * (r + 13.0 + 5.0 * sin(float(i) * 1.3))
			draw_colored_polygon(PackedVector2Array([
				p, p + Vector2(cos(a + 0.12), sin(a + 0.12) * 0.84) * 5.0,
				p + Vector2(cos(a), sin(a) * 0.84) * 7.0
			]), Color(crest.r, crest.g, crest.b, 0.72))

	# Fleshy rim and deep throat.
	draw_circle(Vector2.ZERO, r + 7.0, Color(0.85, 0.67, 0.43))
	draw_circle(Vector2.ZERO, r + 1.0, Color(0.57, 0.39, 0.22))
	draw_circle(Vector2.ZERO, r - 3.0, Color(0.31, 0.15, 0.08))
	draw_circle(Vector2.ZERO, r - 8.0, Color(0.10, 0.035, 0.018))
	draw_circle(Vector2(0.0, r * 0.08), r * 0.62, Color(0.022, 0.010, 0.006))
	draw_circle(Vector2(0.0, r * 0.10), r * 0.34, Color(0.008, 0.004, 0.003))

	# Radial muscle folds in the throat, and gum wedges between the fangs.
	for i in 20:
		var a := TAU * float(i) / 20.0 + 0.08
		draw_arc(Vector2.ZERO, r * 0.62, a, a + 0.20, 4,
			Color(0.40, 0.11, 0.055, 0.58), 2.0, true)
	for i in 12:
		var a := TAU * float(i) / 12.0 + 0.31
		draw_arc(Vector2.ZERO, r * 0.38, a, a + 0.25, 3,
			Color(0.30, 0.075, 0.040, 0.48), 2.0, true)
	for i in 18:
		var a := TAU * float(i) / 18.0 + 0.07
		var dir := Vector2(cos(a), sin(a))
		var tangent := Vector2(-sin(a), cos(a))
		var base := dir * (r + 1.0)
		draw_colored_polygon(PackedVector2Array([
			base + tangent * 5.5, base - tangent * 5.5,
			dir * (r - 5.0) + tangent * 2.0
		]), Color(gum.r, gum.g, gum.b, 0.88))

	# Outer fangs: curved, uneven, with gaps where the gum shows through.
	var bite := clampf((k - 0.78) / 0.22, 0.0, 1.0)
	for i in 18:
		var a := TAU * float(i) / 18.0 + 0.07 + 0.035 * sin(float(i) * 2.4 + art_phase)
		var dir := Vector2(cos(a), sin(a))
		var tangent := Vector2(-sin(a), cos(a))
		var base := dir * (r + 2.0)
		if i == 3 or i == 10 or i == 15:
			draw_colored_polygon(PackedVector2Array([
				base + tangent * 7.0, base - tangent * 7.0, dir * (r - 6.0)
			]), Color(0.28, 0.075, 0.038, 0.90))
			continue
		var length := 18.0 + 6.0 * sin(float(i) * 2.1 + art_phase)
		var width := 4.0 + 1.3 * sin(float(i) * 1.7 + 0.6)
		if i % 5 == 0:
			length += 4.5
			width += 0.8
		var bend := 4.0 + 2.5 * sin(float(i) * 1.5 + clock * 2.0)
		var mid := dir * (r - length * 0.46) + tangent * bend
		var tip := dir * (r - length - bite * 6.0) + tangent * (bend + 3.5)
		var tooth := bone if i % 3 != 0 else Color(0.82, 0.72, 0.52)
		draw_colored_polygon(PackedVector2Array([
			base + tangent * width, base - tangent * width, mid - tangent * width * 0.55, tip
		]), tooth)
		draw_line(base + tangent * (width * 0.15), mid, Color(0.48, 0.38, 0.24, 0.50), 1.0, true)

	# Inner saw teeth give the throat a second row and a clear sense of depth.
	for i in 12:
		var a := TAU * float(i) / 12.0 + 0.34
		var dir := Vector2(cos(a), sin(a))
		var tangent := Vector2(-sin(a), cos(a))
		var base := dir * (r * 0.72)
		var tip := dir * (r * 0.45) + tangent * 2.5
		draw_colored_polygon(PackedVector2Array([
			base + tangent * 2.6, base - tangent * 2.6, tip
		]), Color(0.72, 0.62, 0.44, 0.96))

	# Wet highlight on the upper lip.
	draw_circle(Vector2(-r * 0.23, -r * 0.20), r * 0.14, Color(0.65, 0.31, 0.15, 0.22))

	# Sand thrown out of the crater; reset the squash so the spray is round.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for i in 24:
		var a := TAU * float(i) / 24.0 + 0.25
		var phase := fmod(clock * 1.8 + float(i) * 0.11, 1.0)
		var dir := Vector2(cos(a), sin(a) * 0.78)
		var d := r + 26.0 + phase * 46.0
		var p := dir * d
		var q := dir * (d + 7.0 + phase * 11.0)
		draw_line(p, q, Color(0.97, 0.84, 0.56, (1.0 - phase) * 0.52), 1.2 + phase * 1.2, true)
		draw_circle(p, 1.0 + phase * 2.2, Color(0.97, 0.85, 0.59, (1.0 - phase) * 0.52))
