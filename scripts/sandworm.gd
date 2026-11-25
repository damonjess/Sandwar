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
## Baked animation strips. Prowl is a top-down dune ridge rotated to travel;
## breach, bite and burrow are cinematic 3/4 views facing the camera.
var prowl_tex: Texture2D
var breach_tex: Texture2D
var bite_tex: Texture2D
var burrow_tex: Texture2D
var bite_time := 0.0
var dig_anim := 0.0

## Only nearby work is felt through the sand, not the whole map.
const SENSE_TILES := 9.0
## Distance a target must run from the lock point to escape.
const ESCAPE_TILES := 5.0
const WARN_MIN := 7.0
const WARN_MAX := 9.0
## Keep the visible body, not just its centre point, clear of cliff walls.
## These samples cover the prowl ridge footprint plus a strict 1.5 tile margin.
const CLIFF_CLEARANCE_TILES := 1.5
const BODY_HALF_LENGTH := 96.0
const BODY_HALF_WIDTH := 40.0
const SURFACE_CLEARANCE_TILES := 1.5
## Multi-frame cinematic timing: the full breach arc, the jaw snap, then the
## slide back under. Gameplay is unchanged; the bite still lands once.
const BREACH_TIME := 1.25
const BITE_TIME := 0.58
const DIG_ANIM_TIME := 1.05
## The baked cell's ground contact is 65% of the way down the square. Anchoring
## the quad there puts the crater on the worm's world position instead of
## sinking the whole body below the map point.
const WORM_TOP_FACTOR := 0.65
const WORM_DRAW_SIZE := 420.0

func setup(g, index := 0) -> void:
	game = g
	variant = index
	art_phase = float(index) * 1.73
	if prowl_tex == null:
		prowl_tex = load("res://assets/sprites/sandworm/prowl.png")
	if breach_tex == null:
		breach_tex = load("res://assets/sprites/sandworm/breach.png")
	if bite_tex == null:
		bite_tex = load("res://assets/sprites/sandworm/bite.png")
	if burrow_tex == null:
		burrow_tex = load("res://assets/sprites/sandworm/burrow.png")
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
	var seen: bool = game.terrain.is_seen_tile(tile.x, tile.y)
	var burrow_visible: bool = state == "dig" and dig_anim < DIG_ANIM_TIME
	visible = seen and state != "dormant" and (state != "dig" or burrow_visible)
	match state:
		"dormant":
			wake_timer -= delta
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
			if surface_time >= BREACH_TIME:
				_bite()
		"bite":
			bite_time += delta
			if bite_time >= BITE_TIME:
				_dig(game.rng.randf_range(55.0, 75.0))
		"dig":
			dig_timer -= delta
			dig_anim += delta
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

## The breach finishes with a lunge and snap. Damage lands here, then the
## bite strip plays out before the worm slides under.
func _bite() -> void:
	state = "bite"
	bite_time = 0.0
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
			game.fx.sand_burst(global_position, 86.0, 0.95)
		# Give the player room to rebuild after a loss: no worm may hunt again
		# for a while, not just the one that fed.
		game.worm_quiet_until = game.elapsed + 80.0
	if game.camera != null:
		game.camera.shake(0.35, 6.0)
	queue_redraw()

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
	dig_anim = 0.0
	suppression = 0.0
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

## Each sheet is one row of square frames. Height gives the cell size, so the
## frame count follows from the strip width without a second asset.
func _frame_region(tex: Texture2D, frame: int) -> Rect2:
	var px := float(tex.get_height())
	var count := maxi(1, int(round(float(tex.get_width()) / px)))
	return Rect2(float(posmod(frame, count)) * px, 0.0, px, px)

func _frame_count(tex: Texture2D) -> int:
	if tex == null:
		return 1
	return maxi(1, int(round(float(tex.get_width()) / float(tex.get_height()))))

func _draw() -> void:
	match state:
		"surface":
			_draw_breach()
		"bite":
			_draw_bite()
		"dig":
			_draw_burrow()
		_:
			_draw_prowl()

## A high, wide shadow that tightens and darkens as the body rises. Without
## this the cinematic breach reads as a pasted cut-out.
func _draw_ground_shadow(size: float, surge: float) -> void:
	var k := clampf(surge, 0.0, 1.0)
	draw_set_transform(Vector2(0.0, 5.0), 0.0, Vector2(1.0, 0.40))
	draw_circle(Vector2.ZERO, size * (0.20 + 0.11 * k), Color(0.11, 0.075, 0.040, 0.20 + 0.12 * k))
	draw_circle(Vector2.ZERO, size * (0.12 + 0.06 * k), Color(0.06, 0.040, 0.022, 0.22 + 0.12 * k))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_worm_sheet(tex: Texture2D, frame: int, size: float, surge: float) -> void:
	if tex == null:
		return
	_draw_ground_shadow(size, surge)
	# The bake camera centres above the sandline; this crop fraction puts the
	# baked crater on the node while the head and maw tower above it.
	var top := -size * WORM_TOP_FACTOR
	draw_texture_rect_region(tex, Rect2(Vector2(-size * 0.5, top), Vector2(size, size)),
		_frame_region(tex, frame))

func _draw_breach() -> void:
	var k := clampf(surface_time / BREACH_TIME, 0.0, 1.0)
	var frame := int(round(k * float(_frame_count(breach_tex) - 1)))
	# Sand shockwave under the eruption.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.60))
	for i in 3:
		var reach := 46.0 + float(i) * 24.0 + k * 68.0
		draw_arc(Vector2.ZERO, reach, 0.0, TAU, 40,
			Color(0.94, 0.79, 0.50, maxf(0.0, 0.40 - float(i) * 0.11) * (1.0 - k * 0.25)), 3.2, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_worm_sheet(breach_tex, frame, WORM_DRAW_SIZE, k)
	# Grit thrown clear of the crater; the count and reach grow with the surge.
	for i in 26:
		var a := TAU * float(i) / 26.0 + 0.23
		var phase := fmod(clock * 1.5 + float(i) * 0.09, 1.0)
		var dir := Vector2(cos(a), sin(a) * 0.72)
		var d := 58.0 + k * 40.0 + phase * 62.0
		var p := dir * d
		draw_line(p, p + dir * (7.0 + phase * 12.0),
			Color(0.97, 0.84, 0.56, (1.0 - phase) * 0.46), 1.2 + phase * 1.3, true)
		draw_circle(p, 1.0 + phase * 2.4, Color(0.97, 0.85, 0.59, (1.0 - phase) * 0.48))
	_draw_breach_debris(k)

func _draw_bite() -> void:
	var k := clampf(bite_time / BITE_TIME, 0.0, 1.0)
	var frame := int(round(k * float(_frame_count(bite_tex) - 1)))
	# The lunge throws a hard sand wave forward.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.55))
	for i in 2:
		var reach := 62.0 + k * 86.0 + float(i) * 26.0
		draw_arc(Vector2(0.0, 4.0), reach, 0.0, TAU, 36,
			Color(0.96, 0.82, 0.56, (0.40 - float(i) * 0.14) * (1.0 - k * 0.5)), 3.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_worm_sheet(bite_tex, frame, WORM_DRAW_SIZE, 1.0)
	for i in 18:
		var a := TAU * float(i) / 18.0 + 0.4
		var phase := fmod(clock * 2.6 + float(i) * 0.12, 1.0)
		var dir := Vector2(cos(a), sin(a) * 0.66)
		var p := dir * (54.0 + phase * 74.0)
		draw_circle(p, 1.2 + phase * 2.2, Color(0.98, 0.87, 0.62, (1.0 - phase) * 0.52))
	_draw_breach_debris(0.82)

func _draw_burrow() -> void:
	var k := clampf(dig_anim / DIG_ANIM_TIME, 0.0, 1.0)
	var frame := int(round(k * float(_frame_count(burrow_tex) - 1)))
	# Trailing whirlpool: the crater draws the body down with it.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.55))
	for i in 4:
		var reach := 36.0 + float(i) * 19.0 + k * 82.0
		var fade := (0.38 - float(i) * 0.07) * (1.0 - k * 0.65)
		var a0 := clock * 1.4 + float(i) * 1.2
		for seg in 4:
			var a := a0 + float(seg) * TAU / 4.0
			draw_arc(Vector2.ZERO, reach, a, a + 0.62, 12, Color(0.92, 0.77, 0.51, fade), 2.4, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_worm_sheet(burrow_tex, frame, WORM_DRAW_SIZE, 1.0 - k)
	for i in 20:
		var a := TAU * float(i) / 20.0 + clock * 1.6
		var phase := fmod(clock * 2.2 + float(i) * 0.13, 1.0)
		var p := Vector2(cos(a), sin(a) * 0.58) * (44.0 + phase * 58.0)
		draw_circle(p, 1.0 + phase * 2.0, Color(0.95, 0.81, 0.56, (1.0 - phase) * 0.42))
	if k < 0.72:
		_draw_breach_debris((1.0 - k) * 0.9)

func _draw_prowl() -> void:
	var angle := move_dir.angle()
	var pulse := 1.0 + 0.018 * sin(clock * 2.4)
	# Local +X is the direction of travel. Draw the ridge in that frame, then
	# reset for the world-space warning rings.
	draw_set_transform(Vector2(0.0, 4.0), angle, Vector2(pulse, 0.95 * pulse))
	var sway := 2.4 * sin(clock * 1.5 + art_phase * 1.3)
	if prowl_tex != null:
		# The bake supplies soft grain under the hand-drawn ridge. Keep it faint:
		# the vector crest is what makes the wormsign sit inside the sand palette.
		var frame := int(clock * 6.0 + art_phase * 2.0) % _frame_count(prowl_tex)
		draw_texture_rect_region(prowl_tex, Rect2(Vector2(-115.0, -115.0), Vector2(230.0, 230.0)),
			_frame_region(prowl_tex, frame), Color(1.0, 0.94, 0.84, 0.12))
	_draw_wormsign_ridge(sway)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if state == "stalk":
		_draw_wormsign_ripples(1.0)
	elif state == "prowl":
		_draw_wormsign_ripples(0.46)

## A tapered, sinuous dune ridge in the same golden-peach family as the terrain.
## Opaque vector sand is used instead of the baked top-down sheet alone because
## an opaque billboard reads as a pasted pancake at gameplay zoom; the bake is
## kept as a faint grain layer underneath.
func _draw_wormsign_ridge(sway: float) -> void:
	# Translucent displaced-sand bands, not a solid body: the ground and spice
	# must stay visible through the wake or the wormsign reads as a pasted fish.
	draw_colored_polygon(_dune_polygon(190.0, 29.0, sway + 2.0, -5.0),
		Color(0.40, 0.26, 0.14, 0.12))
	draw_colored_polygon(_dune_polygon(182.0, 23.0, sway, 1.0),
		Color(0.87, 0.70, 0.47, 0.18))
	draw_colored_polygon(_dune_polygon(168.0, 9.0, sway - 2.0, 7.0),
		Color(0.99, 0.86, 0.62, 0.30))
	draw_colored_polygon(_dune_polygon(160.0, 7.0, sway + 4.0, -7.0),
		Color(0.52, 0.35, 0.18, 0.12))
	var crest := PackedVector2Array()
	for i in 18:
		var t := -1.0 + 2.0 * float(i) / 17.0
		crest.append(Vector2(t * 74.0, sway * sin(t * 2.6 + 0.6) - 8.0))
	draw_polyline(crest, Color(1.0, 0.92, 0.70, 0.38), 1.7, true)
	# A broken dark dorsal line is all that shows of the body: a continuous row
	# of plates at this scale reads as beads or rivets, not a buried animal.
	var spine := PackedVector2Array()
	for i in 18:
		var t := -0.90 + 1.78 * float(i) / 17.0
		spine.append(Vector2(t * 80.0, sway * sin(t * 2.6 + 0.6) - 3.2))
	draw_polyline(spine, Color(0.27, 0.16, 0.085, 0.34), 3.2, true)
	for i in 4:
		var t := -0.58 + 1.18 * float(i) / 3.0 + 0.04 * sin(float(i) * 2.1)
		var x := t * 78.0
		var y := sway * sin(t * 2.6 + 0.6) - 3.6
		_draw_ellipse(Vector2(x, y), 6.5 - absf(t) * 1.6, 4.2 - absf(t) * 0.8,
			Color(0.27, 0.16, 0.085, 0.18))
	# A blunt, half-buried head under a broad sand crown. Keep it low-contrast:
	# it is a shadow in the sand, not a solid grey ball on top of it.
	_draw_ellipse(Vector2(75.0, sway + 0.5), 9.5, 7.0,
		Color(0.25, 0.14, 0.075, 0.26))
	_draw_ellipse(Vector2(71.5, sway - 2.0), 8.0, 4.8,
		Color(0.94, 0.79, 0.55, 0.32))
	# Displaced-sand V and rising grit behind the travelling bulge.
	for s in [-1.0, 1.0]:
		draw_line(Vector2(-54.0, s * 12.0), Vector2(-110.0, s * 30.0),
			Color(0.95, 0.82, 0.58, 0.26), 2.0, true)
		draw_line(Vector2(-50.0, s * 8.0), Vector2(-96.0, s * 20.0),
			Color(0.55, 0.38, 0.20, 0.22), 1.4, true)
	for i in 16:
		var phase := fmod(clock * 1.2 + float(i) * 0.16, 1.0)
		var p := Vector2(-42.0 - phase * 58.0,
			-4.0 + sin(float(i) * 2.1 + clock * 2.2) * 14.0)
		draw_circle(p, 0.9 + phase * 2.1, Color(1.0, 0.90, 0.68, (1.0 - phase) * 0.34))

## Build a closed, tapered dune outline from two width profiles. The ends meet
## at a point, so no square cap can appear at either end of the ridge.
func _dune_polygon(length: float, half_width: float, sway: float, lift: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := 24
	for i in steps:
		var t := -1.0 + 2.0 * float(i) / float(steps - 1)
		var y := sway * sin(t * 2.6 + 0.6) - lift
		var w := half_width * pow(maxf(0.0, 1.0 - t * t), 0.58)
		w *= 1.0 + 0.08 * sin(t * 7.0 + clock * 1.2)
		pts.append(Vector2(t * length * 0.5, y - w))
	for i in range(steps - 1, -1, -1):
		var t := -1.0 + 2.0 * float(i) / float(steps - 1)
		var y := sway * sin(t * 2.6 + 0.6) - lift
		var w := half_width * pow(maxf(0.0, 1.0 - t * t), 0.58)
		w *= 1.0 + 0.08 * sin(t * 7.0 + clock * 1.2)
		pts.append(Vector2(t * length * 0.5, y + w * 0.96))
	return pts

func _draw_ellipse(center: Vector2, rx: float, ry: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * float(i) / 16.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, color)

## Broken sand ripples replace a target circle. The minimap ping remains the
## tactical alert; this stays environmental.
func _draw_wormsign_ripples(strength := 1.0) -> void:
	var pulse := 0.5 + 0.5 * sin(clock * 3.2)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.70))
	for i in 3:
		var radius := 46.0 + float(i) * 15.0 + pulse * 2.5
		var start := clock * 0.10 + float(i) * 0.7
		for segment in 4:
			var a := start + float(segment) * TAU / 4.0
			draw_arc(Vector2.ZERO, radius, a, a + 0.52, 12,
				Color(0.91, 0.76, 0.51, (0.20 - float(i) * 0.042) * strength), 1.5, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Dark clods and warm grit thrown out around the crater. The particles are
## drawn in screen-space around the node, so they keep flying even while the
## baked worm frame is momentarily still.
func _draw_breach_debris(intensity: float) -> void:
	var power := clampf(intensity, 0.0, 1.0)
	if power <= 0.02:
		return
	for i in 22:
		var a := TAU * float(i) / 22.0 + 0.27
		var phase := fmod(clock * 1.35 + float(i) * 0.137, 1.0)
		var dir := Vector2(cos(a), sin(a) * 0.62)
		var reach := (26.0 + phase * 88.0) * (0.55 + 0.45 * power)
		var p := dir * reach + Vector2(0.0, -sin(phase * PI) * 22.0 * power)
		var size := (2.1 + 2.3 * fmod(float(i) * 0.37, 1.0)) * (0.78 + 0.30 * power)
		var fade := (1.0 - phase) * (0.50 + 0.50 * power)
		draw_set_transform(p + Vector2(1.2, 1.6), 0.0, Vector2(1.0, 0.55))
		draw_circle(Vector2.ZERO, size * 0.90, Color(0.10, 0.060, 0.030, 0.26 * fade))
		draw_set_transform(p, a + phase * 3.4, Vector2(1.10, 0.78))
		draw_rect(Rect2(Vector2(-size * 0.5, -size * 0.42), Vector2(size, size * 0.84)),
			Color(0.20, 0.125, 0.070, 0.80 * fade))
		draw_line(Vector2(-size * 0.48, -size * 0.40), Vector2(size * 0.34, -size * 0.34),
			Color(0.39, 0.255, 0.145, 0.72 * fade), 1.0)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
