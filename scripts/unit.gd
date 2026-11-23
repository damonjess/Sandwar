class_name Unit
extends Node2D

## Mobile fighting unit. Harvesters extend this with an economy brain.

const BallisticScript = preload("res://scripts/projectile.gd")
const RocketScript = preload("res://scripts/rocket.gd")

var game
var type_id := "infantry"
var team := 0
var cfg := {}
var hp := 60.0
var max_hp := 60.0
var speed := 55.0
var damage := 6.0
var attack_range := 105.0
var cooldown_time := 0.7
var weapon := "small_arms"
var radius := 8.0
var dead := false
## Set when a tracked vehicle runs this unit over, so the death FX is a dust
## squish instead of a full explosion.
var crushed := false
## Carried under a Carryall: hidden, untouchable and ignored by ground traffic
## and Sandworm vibration until it is set down again.
var airborne := false
## Swallowed by a Sandworm, so the death FX is a sand burst, not a fireball.
var swallowed := false

var move_target := Vector2.ZERO
var nav_target := Vector2.ZERO
var path: Array = []
var path_i := 0
var has_move := false
var attack_target = null
var cooldown := 0.0
var selected := false
## Context Guard action: hold the current patch and return to it after any
## automatic engagement. A normal move or attack order clears this state.
var guarding := false
var guard_anchor := Vector2.ZERO
var facing := 0.0
var barrel_side := 1.0
var rocket_salvo_left := 0
var rocket_salvo_timer := 0.0
var rocket_salvo_target = null
var flash := 0.0
var bob := 0.0
var stuck_time := 0.0
var stuck_anchor := Vector2.ZERO
## Hull direction is `facing`; the Siege Tank's gun uses its own angle so the
## hull can keep driving while the turret tracks a target.
var turret_facing := 0.0
var locomoting := false
var anim_clock := 0.0
## House-unique behaviour flags, copied from GameDefs.UNITS.
var special := ""
var stealth := 0.0
var splash_radius := 0.0
var splash_fraction := 0.0
## Deviator conversion: the unit fights for another house until the timer
## expires, then reverts to its original owner.
var charm_timer := 0.0
var charm_team := -1
## Tracked hulls leave faint dust tracks on open sand; the heavy ones also puff
## exhaust while driving. Infantry and wheeled scouts stay clean.
const TRACKED_TYPES := ["tank", "atreides_tank", "harkonnen_tank", "ordos_tank", "sonic_tank", "devastator", "harvester"]
const EXHAUST_TYPES := ["tank", "atreides_tank", "harkonnen_tank", "ordos_tank", "sonic_tank", "devastator"]
const TREAD_SPACING := 14.0
var _tread_accum := 0.0

func configure(id: String, team_id: int, g) -> void:
	type_id = id
	team = team_id
	game = g
	cfg = GameDefs.UNITS[id]
	max_hp = float(cfg["hp"])
	hp = max_hp
	speed = float(cfg["speed"])
	damage = float(cfg["damage"])
	attack_range = float(cfg["range"])
	cooldown_time = float(cfg["cooldown"])
	weapon = String(cfg.get("weapon", "small_arms"))
	radius = float(cfg["radius"])
	special = String(cfg.get("special", ""))
	stealth = float(cfg.get("stealth", 0.0))
	splash_radius = float(cfg.get("splash", 0.0))
	splash_fraction = float(cfg.get("splash_fraction", 0.0))
	bob = randf() * TAU
	anim_clock = randf() * TAU
	_tread_accum = randf() * TREAD_SPACING
	turret_facing = facing
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if UnitArt.has_art(id):
		material = UnitArt.material(team)
	z_index = 1

func is_alive() -> bool:
	return not dead and hp > 0.0

## What the weapon counter table calls this unit when something shoots it.
func damage_class() -> String:
	return String(GameDefs.ARMOUR_CLASS.get(type_id, "vehicle"))

## Deviator gas: vehicles only, and only while not already converted. The
## harvester counts as a vehicle, which makes stealing one a real raid.
func charm(new_team: int, duration: float) -> bool:
	if dead or new_team == team or charm_timer > 0.0:
		return false
	if damage_class() != "vehicle":
		return false
	charm_team = team
	charm_timer = duration
	team = new_team
	material = UnitArt.material(team)
	attack_target = null
	has_move = false
	path.clear()
	guarding = false
	if game != null:
		if game.fx != null:
			game.fx.popup("CONVERTED", global_position + Vector2(0.0, -24.0))
		game.play_sfx("low_power", global_position, -6.0, 1.45)
	queue_redraw()
	return true

func _revert_charm() -> void:
	if charm_team < 0:
		return
	team = charm_team
	charm_team = -1
	charm_timer = 0.0
	material = UnitArt.material(team)
	attack_target = null
	has_move = false
	path.clear()
	if game != null:
		if game.selected.has(self):
			game.selected.erase(self)
			game._after_select()
		if game.fx != null:
			game.fx.popup("CONTROL LOST", global_position + Vector2(0.0, -24.0))
	queue_redraw()

func order_move(pos: Vector2) -> void:
	guarding = false
	attack_target = null
	set_destination(pos)

func order_attack(target) -> void:
	if target == null:
		return
	guarding = false
	attack_target = target
	has_move = false
	path.clear()

func order_guard() -> void:
	guarding = true
	guard_anchor = global_position
	attack_target = null
	has_move = false
	move_target = global_position
	nav_target = global_position
	path.clear()
	path_i = 0

func set_destination(pos: Vector2) -> void:
	move_target = pos
	nav_target = pos
	path_i = 0
	stuck_time = 0.0
	stuck_anchor = global_position
	has_move = true
	if game != null:
		path = game.find_path(global_position, pos)
	else:
		path = []

func take_damage(amount: float) -> void:
	if dead or airborne:
		return
	hp -= amount
	flash = 1.0
	if game != null:
		game.on_unit_damaged(self)
	if hp <= 0.0:
		die()
	queue_redraw()

func die() -> void:
	if dead:
		return
	dead = true
	hp = 0.0
	if game != null:
		game.on_unit_destroyed(self)
	queue_free()

func _process(delta: float) -> void:
	if dead or game == null:
		return
	bob += delta * 5.0
	anim_clock += delta
	if charm_timer > 0.0:
		charm_timer -= delta
		if charm_timer <= 0.0:
			_revert_charm()
	locomoting = false
	cooldown = maxf(0.0, cooldown - delta)
	flash = maxf(0.0, flash - delta * 4.0)
	_tick_orders(delta)
	_tick_combat(delta)
	# Idle bodies fan out instead of sharing a pixel, as long as the step stays
	# on open ground.
	_settle_separation(delta)
	queue_redraw()

func _tick_orders(delta: float) -> void:
	if attack_target != null:
		if not is_instance_valid(attack_target) or not attack_target.is_alive():
			attack_target = null
	if attack_target != null:
		var d := global_position.distance_to(attack_target.global_position)
		if d > attack_range * 0.8:
			_advance_toward(attack_target.global_position, delta)
		else:
			has_move = false
		return
	if guarding and attack_target == null and not has_move and global_position.distance_to(guard_anchor) > 18.0:
		set_destination(guard_anchor)
	if has_move:
		_follow_path(delta)
	elif damage > 0.0:
		var enemy = game.nearest_enemy(global_position, team, attack_range * 1.7)
		if enemy != null:
			attack_target = enemy

func _follow_path(delta: float) -> void:
	stuck_time += delta
	if stuck_time >= 1.0:
		if not path.is_empty() and global_position.distance_to(stuck_anchor) < 5.0:
			path = game.find_path(global_position, nav_target)
			path_i = 0
			stuck_time = 0.0
			stuck_anchor = global_position
			if path.is_empty() and global_position.distance_to(nav_target) > 40.0:
				# No route at all: stop grinding against the scenery.
				has_move = false
	if path.is_empty():
		if global_position.distance_to(nav_target) <= 8.0:
			_settle_at_destination()
			has_move = false
		else:
			_advance_toward(nav_target, delta)
		return
	if path_i >= path.size():
		path.clear()
		_settle_at_destination()
		has_move = false
		return
	var wp: Vector2 = path[path_i]
	if global_position.distance_to(wp) <= 9.0:
		path_i += 1
		if path_i >= path.size():
			path.clear()
			has_move = false
			return
		wp = path[path_i]
	_advance_toward(wp, delta)

func _advance_toward(target: Vector2, delta: float) -> void:
	var before := global_position
	var offset := target - global_position
	if offset.length() < 0.5:
		return
	var dir := offset.normalized()
	var step := speed * delta
	var move := _free_step(dir * step, dir)
	if move == Vector2.ZERO:
		move = _escape_buildings(step)
	# Crowd pressure is only applied when the whole step stays on open ground.
	var shove := _separation() * step
	if not _safe_position(global_position + move + shove):
		shove = Vector2.ZERO
	var next_pos := global_position + move + shove
	next_pos.x = clampf(next_pos.x, 16.0, float(GameDefs.WORLD) - 16.0)
	next_pos.y = clampf(next_pos.y, 16.0, float(GameDefs.WORLD) - 16.0)
	if not _safe_position(next_pos):
		next_pos = global_position + move
	global_position = next_pos
	locomoting = true
	_stamp_treads(global_position.distance_to(before))
	facing = lerp_angle(facing, dir.angle(), 0.22)
	_crush_enemies()

## A step of the wanted length that ends outside every building, turning further
## away from the target until one fits, so units slide around corners instead of
## stopping dead against a wall.
func _free_step(want: Vector2, dir: Vector2) -> Vector2:
	for a in [0.0, 0.4, -0.4, 0.85, -0.85, 1.3, -1.3, 1.75, -1.75]:
		var v := want.rotated(a)
		if not _blocked_at(global_position + v):
			return v
	return Vector2.ZERO

## A crowd can push a unit partway into a building's keep-out box, and from
## there no ordinary step ever leaves it again: step straight back out.
func _escape_buildings(step: float) -> Vector2:
	for b in game.buildings:
		if not is_instance_valid(b) or b.dead:
			continue
		var box: Rect2 = b.world_rect().grow(radius * 0.8)
		if not box.has_point(global_position):
			continue
		var out := global_position - box.get_center()
		if out.length() < 0.5:
			out = Vector2.UP
		var v := out.normalized() * step
		return v.rotated(0.8) if _blocked_at(global_position + v) else v
	return Vector2.ZERO

## A position is safe when it is inside the map, not on a solid navigation
## tile and not inside a structure's keep-out box. Every nudge is checked here,
## so neither steering nor crowd pressure can bury a unit in steel.
func _safe_position(p: Vector2) -> bool:
	if p.x < 16.0 or p.y < 16.0 or p.x > float(GameDefs.WORLD) - 16.0 or p.y > float(GameDefs.WORLD) - 16.0:
		return false
	if game.astar != null:
		var tile: Vector2i = game.terrain.tile_of(p)
		if game.astar.is_point_solid(tile):
			return false
	for b in game.buildings:
		if not is_instance_valid(b) or b.dead:
			continue
		if b.world_rect().grow(radius * 0.8).has_point(p):
			return false
	return true

func _blocked_at(p: Vector2) -> bool:
	return not _safe_position(p)

func _separation() -> Vector2:
	var push := Vector2.ZERO
	for other in game.units:
		if other == self or not is_instance_valid(other) or other.dead or other.airborne:
			continue
		# Heavy tracks never yield to enemy infantry: they are about to crush it.
		if is_crusher() and other.team != team and other.damage_class() == "infantry":
			continue
		var d := global_position.distance_to(other.global_position)
		if d <= 0.01:
			# Exactly stacked: split along the golden angle by roster index, so
			# any number of bodies fans out evenly instead of sharing a pixel.
			var my_i: int = game.units.find(self)
			var other_i: int = game.units.find(other)
			push += Vector2.RIGHT.rotated(float(my_i - other_i) * 2.399963)
			continue
		var want: float = radius + other.radius + 4.0
		if d < want:
			push += (global_position - other.global_position) / d * (1.0 - d / want)
	return push.limit_length(1.0)

## Smooth idle separation: overlapping bodies drift apart at a walking pace so a
## squad ordered onto one point fans out shoulder-to-shoulder.
func _settle_separation(delta: float) -> void:
	if locomoting or has_move or attack_target != null:
		return
	var push := _separation()
	if push.length() < 0.05:
		return
	var step := minf(speed * delta * 0.9, 3.0)
	for dir in [push, Vector2(push.x, 0.0), Vector2(0.0, push.y)]:
		var d: Vector2 = dir
		if d.length() < 0.01:
			continue
		var p: Vector2 = global_position + d.normalized() * step
		if _safe_position(p):
			global_position = p
			return

## A group ordered onto one point cannot all stand on it. The first unit keeps
## the spot; the rest slide to the nearest free shoulder and stop there instead
## of jittering against each other for ever.
func _settle_at_destination() -> void:
	if _position_open(global_position):
		return
	var best := Vector2.ZERO
	var best_d := 1.0e9
	for ring in [1.0, 2.0]:
		var fill: float = ring
		for i in 8:
			var a: float = TAU * float(i) / 8.0 + fill * 0.39
			var p: Vector2 = nav_target + Vector2.RIGHT.rotated(a) * (radius * 2.0 + 6.0) * fill
			if not _position_open(p):
				continue
			var d := p.distance_to(global_position)
			if d < best_d:
				best_d = d
				best = p
	if best_d < 1.0e9:
		facing = (best - global_position).angle()
		global_position = best

func _position_open(p: Vector2) -> bool:
	if not _safe_position(p):
		return false
	for other in game.units:
		if other == self or not is_instance_valid(other) or other.dead or other.airborne:
			continue
		if p.distance_to(other.global_position) < radius + other.radius * 0.75:
			return false
	return true

## Classic Dune 2000 tracks: heavy vehicles flatten enemy infantry instead of
## being stopped by them.
const CRUSH_TYPES := ["tank", "atreides_tank", "harkonnen_tank", "ordos_tank", "sonic_tank", "devastator", "harvester"]

func is_crusher() -> bool:
	return CRUSH_TYPES.has(type_id)

func is_tracked() -> bool:
	return TRACKED_TYPES.has(type_id)

## Stamp a dusty twin track every few pixels driven over open sand only.
func _stamp_treads(moved: float) -> void:
	if game == null or game.scorch_layer == null or not is_tracked():
		return
	_tread_accum += moved
	if _tread_accum < TREAD_SPACING:
		return
	_tread_accum = 0.0
	var tile: Vector2i = game.terrain.tile_of(global_position)
	if game.terrain.is_open_sand(tile):
		game.scorch_layer.tread(global_position, facing, clampf(radius / 9.0, 0.7, 1.3))

func _crush_enemies() -> void:
	if not is_crusher():
		return
	for other in game.units.duplicate():
		if other == self or not is_instance_valid(other) or other.dead:
			continue
		if other.team == team or other.damage_class() != "infantry":
			continue
		if global_position.distance_to(other.global_position) <= radius + other.radius * 0.45:
			other.crushed_by(self)

func crushed_by(crusher) -> void:
	if dead:
		return
	crushed = true
	die()

func _tick_combat(delta: float) -> void:
	# Rocket troopers carry two small tubes: the second missile follows the
	# first, and each carries half the original 17 damage.
	if weapon == "rocket" and rocket_salvo_left > 0:
		rocket_salvo_timer -= delta
		if rocket_salvo_timer <= 0.0:
			var follow = rocket_salvo_target
			if not is_instance_valid(follow) or not follow.is_alive():
				follow = attack_target if is_instance_valid(attack_target) and attack_target.is_alive() else null
			if follow != null:
				# Spawn from the visible tube, not from a fresh line to the target:
				# the body may still be halfway through its turn.
				var fdir := Vector2.RIGHT.rotated(facing)
				var fperp := Vector2(-fdir.y, fdir.x)
				var fmuzzle := global_position + fdir * UnitArt.muzzle_distance(type_id, radius) + fperp * (2.5 * barrel_side)
				_launch_rocket(follow, fmuzzle, fdir, 0.5)
				flash = 1.0
			rocket_salvo_left = 0
	if attack_target == null or not is_instance_valid(attack_target) or not attack_target.is_alive():
		return
	var to_target: Vector2 = attack_target.global_position - global_position
	var aim := to_target.angle()
	# The Siege Tank's hull keeps its travel heading; only its turret tracks.
	# Every other unit turns its whole chassis/body toward the target.
	if type_id == "tank":
		turret_facing = lerp_angle(turret_facing, aim, minf(1.0, delta * 9.0))
	else:
		facing = lerp_angle(facing, aim, minf(1.0, delta * 12.0))
	var d := to_target.length()
	if d > attack_range or cooldown > 0.0 or damage <= 0.0:
		return
	cooldown = cooldown_time
	flash = 1.0
	# Sonic Tank: a short piercing shockwave down the barrel line. It is not a
	# projectile, so every enemy body and structure along the path is struck.
	if special == "sonic":
		_fire_sonic(Vector2.RIGHT.rotated(facing))
		game.play_sfx("cannon", global_position, -3.0, 0.68)
		if game.fx != null:
			game.fx.muzzle(global_position + Vector2.RIGHT.rotated(facing) * UnitArt.muzzle_distance(type_id, radius),
				facing, "cannon", 1.0)
		return
	var style := "rifle"
	if weapon == "cannon" or weapon == "demolition":
		style = "cannon"
	elif type_id == "trike" or type_id == "quad" or type_id == "raider_trike":
		style = "light"
	# Fire along the direction the baked sprite is actually showing. On the
	# tank that is the tracking turret; on every other unit it is the body. The
	# old code used `aim` here, so a fast target could produce a muzzle flash
	# and projectile from a barrel that had not visually reached the target yet.
	var shot_angle := facing
	if type_id == "tank":
		shot_angle = turret_facing
	var dir := Vector2.RIGHT.rotated(shot_angle)
	var perp := Vector2(-dir.y, dir.x)
	var side_offset := 2.5 if style == "light" else 0.0
	var muzzle := global_position + dir * UnitArt.muzzle_distance(type_id, radius) + perp * (side_offset * barrel_side)
	if weapon == "rocket":
		_launch_rocket(attack_target, muzzle, dir, 0.5)
		rocket_salvo_left = 1
		rocket_salvo_timer = 0.12
		rocket_salvo_target = attack_target
	elif weapon == "gas":
		# Deviator: a single green gas missile. On impact the primary vehicle
		# target is converted to our house for twelve seconds.
		_launch_rocket(attack_target, muzzle, dir, 1.0)
	elif style == "cannon":
		var shell := BallisticScript.new()
		game.add_child(shell)
		shell.setup(game, team, attack_target, muzzle, dir, damage, weapon, "cannon", 680.0, 10.0,
			splash_radius, splash_fraction)
		game.fx.muzzle(muzzle, shot_angle, "cannon", barrel_side)
	else:
		var speed := 1000.0
		var turn := 16.0
		if style == "rifle":
			speed = 1200.0
			turn = 20.0
		var shot := BallisticScript.new()
		game.add_child(shot)
		shot.setup(game, team, attack_target, muzzle, dir, damage, weapon, style, speed, turn)
		game.fx.muzzle(muzzle, shot_angle, style, barrel_side)
	barrel_side = -barrel_side
	var sound := "rifle"
	if style == "light":
		sound = "mg_burst"
	elif style == "cannon":
		sound = "cannon"
	if weapon == "rocket":
		sound = "rocket_launch"
	elif weapon == "gas":
		sound = "rocket_launch"
	game.play_sfx(sound, global_position, -4.0)

func _launch_rocket(target, muzzle: Vector2, dir: Vector2, share := 1.0) -> void:
	var rocket := RocketScript.new()
	game.add_child(rocket)
	rocket.setup(game, team, target, muzzle, dir, damage * share, weapon,
		0.0, 0.0, 340.0, 4.0, 0.55, 0.8, special)
	game.fx.muzzle(muzzle, dir.angle(), "rocket", barrel_side)

## Acoustic shockwave: every enemy whose body intersects the beam line takes
## full sonic damage. Buildings are clipped by their footprint radius.
func _fire_sonic(dir: Vector2) -> void:
	var start := global_position
	var reach := attack_range * 1.2
	var end := start + dir * reach
	if game.fx != null:
		game.fx.sonic_wave(start, dir, reach, team)
	# Snapshot the lists: a lethal hit erases the victim from game.units during
	# the loop, which would otherwise skip the next body in the beam.
	var targets: Array = game.units.duplicate()
	for other in targets:
		if other == self or not is_instance_valid(other) or other.dead or other.team == team:
			continue
		if _line_distance(other.global_position, start, end) <= 24.0 + other.radius:
			other.take_damage(damage * GameDefs.damage_multiplier("sonic", other.damage_class()))
	var structures: Array = game.buildings.duplicate()
	for b in structures:
		if not is_instance_valid(b) or b.dead or b.team == team:
			continue
		if _line_distance(b.global_position, start, end) <= 24.0 + b.size_px * 0.28:
			b.take_damage(damage * GameDefs.damage_multiplier("sonic", b.damage_class()))
	if game.scorch_layer != null:
		game.scorch_layer.add(end, 10.0)

func _line_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((point - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return point.distance_to(a + ab * t)

func _draw() -> void:
	if selected:
		draw_arc(Vector2.ZERO, radius + 6.0, 0.0, TAU, 28, Color(0.55, 1.0, 0.65, 0.95), 2.0)
	draw_baked_unit()
	_draw_exhaust()
	if hp < max_hp:
		var w := radius * 2.6
		var y := -radius - 9.0
		draw_rect(Rect2(Vector2(-w * 0.5, y), Vector2(w, 3.0)), Color(0.0, 0.0, 0.0, 0.6))
		draw_rect(Rect2(Vector2(-w * 0.5, y), Vector2(w * clampf(hp / max_hp, 0.0, 1.0), 3.0)), Color(0.4, 0.95, 0.4))

## Soft exhaust puffs behind a heavy hull while it is actually moving.
func _draw_exhaust() -> void:
	if not EXHAUST_TYPES.has(type_id) or not locomoting:
		return
	var back := -Vector2.RIGHT.rotated(facing)
	var perp := Vector2(-back.y, back.x)
	for i in 3:
		var ph := fmod(anim_clock * 1.7 + float(i) / 3.0, 1.0)
		var p := back * (radius * 0.55 + ph * 9.0) + perp * (float(i) - 1.0) * 2.6 + Vector2(0.0, -ph * 3.0)
		draw_circle(p, 2.0 + ph * 3.4, Color(0.20, 0.18, 0.15, (1.0 - ph) * 0.20))

## Draw the authoritative unit-sprites. There is deliberately no Sprite2D.rotation
## here: all headings are selected from baked direction cells, never a rotated
## 2D sprite.
func draw_baked_unit() -> void:
	var dest := UnitArt.draw_rect(type_id)
	if type_id == "tank":
		var hull := UnitArt.sheet("tank")
		if hull != null:
			draw_texture_rect_region(hull, dest, UnitArt.frame_region("tank", facing))
		var turret := UnitArt.tank_turret()
		if turret != null:
			draw_texture_rect_region(turret, dest, UnitArt.tank_turret_region(turret_facing))
		return
	if type_id == "harvester":
		var fill: float = clampf(float(get("cargo")) / maxf(float(get("capacity")), 1.0), 0.0, 1.0)
		var harvest_tex := UnitArt.harvester_sheet(fill)
		if harvest_tex != null:
			draw_texture_rect_region(harvest_tex, dest, UnitArt.harvester_region(facing))
		return
	if UnitArt.is_infantry(type_id):
		var anim := 0
		if flash > 0.55:
			anim = 3
		elif locomoting:
			anim = 1 + int(anim_clock * 7.0) % 2
		var tex := UnitArt.sheet(type_id)
		if tex != null:
			draw_texture_rect_region(tex, dest, UnitArt.frame_region(type_id, facing, anim))
		return
	var tex := UnitArt.sheet(type_id)
	if tex != null:
		draw_texture_rect_region(tex, dest, UnitArt.frame_region(type_id, facing))
