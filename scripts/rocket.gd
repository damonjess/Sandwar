class_name RocketProjectile
extends Node2D

## Homing rocket for the Rocket Turret.
##
## There is deliberately no physics body or collision layer here: the rocket
## steers at its locked target and only checks range to that target, so it can
## never collide with the turret that launched it. Splash damage skips the
## source team as well.

const LIFETIME := 5.0
const TRAIL_LIFE := 0.65
const SPLASH_FLOOR := 0.45

var game
var source_team := 0
var target = null
var target_pos := Vector2.ZERO
var velocity := Vector2.ZERO
var damage := 26.0
var weapon := "rocket"
var splash_radius := 56.0
var splash_fraction := 0.6
var speed := 380.0
var turn_rate := 3.5
var age := 0.0
var trail_timer := 0.0
var trail: Array = []
var impact_done := false
var visual_scale := 1.0
var blast_power := 1.8
## "deviate" marks a Deviator gas missile; it converts the primary vehicle.
var special := ""

func setup(g, from_team: int, victim, pos: Vector2, dir: Vector2, dmg: float,
		weapon_id: String, splash: float, splash_share: float, spd: float, turn: float,
		scale := 1.0, blast := 1.8, special_id := "") -> void:
	game = g
	source_team = from_team
	target = victim
	if target != null:
		target_pos = target.global_position
	global_position = pos
	speed = maxf(spd, 1.0)
	velocity = dir.normalized() * speed
	damage = dmg
	weapon = weapon_id
	splash_radius = splash
	splash_fraction = splash_share
	turn_rate = maxf(turn, 0.1)
	visual_scale = maxf(scale, 0.2)
	blast_power = blast
	special = special_id
	z_index = 15

func _process(delta: float) -> void:
	if impact_done:
		return
	age += delta
	trail_timer += delta
	if trail_timer >= 0.025:
		trail_timer = 0.0
		trail.append({"p": global_position, "t": 0.0})
	for t in trail:
		t["t"] = float(t["t"]) + delta
	trail = trail.filter(func(t): return float(t["t"]) < TRAIL_LIFE)
	if is_instance_valid(target) and target.has_method("is_alive") and target.is_alive():
		target_pos = target.global_position
	var to_target := target_pos - global_position
	if to_target.length() <= maxf(7.0, speed * delta * 1.5):
		_impact()
		return
	var desired := to_target.angle()
	var diff := angle_difference(velocity.angle(), desired)
	var turn := clampf(diff, -turn_rate * delta, turn_rate * delta)
	velocity = Vector2.RIGHT.rotated(velocity.angle() + turn) * speed
	global_position += velocity * delta
	if age >= LIFETIME:
		_impact()
		return
	queue_redraw()

func _impact() -> void:
	if impact_done:
		return
	impact_done = true
	var hit_pos := global_position
	if is_instance_valid(target) and target.has_method("is_alive") and target.is_alive():
		if special == "deviate" and target.has_method("charm"):
			target.charm(source_team, 12.0)
		_apply_damage(target, 1.0)
	for u in game.units:
		if u == target or not is_instance_valid(u) or u.dead or u.team == source_team:
			continue
		_splash_at(u, hit_pos, u.radius)
	for b in game.buildings:
		if b == target or not is_instance_valid(b) or b.dead or b.team == source_team:
			continue
		_splash_at(b, hit_pos, b.size_px * 0.5)
	if game.fx != null:
		game.fx.impact(hit_pos, "gas" if special == "deviate" else "rocket", blast_power)
		if special == "deviate":
			# The warhead leaves a lingering emerald cloud, not just a flash.
			game.fx.gas_cloud(hit_pos, maxf(splash_radius, 56.0))
	if game.scorch_layer != null:
		game.scorch_layer.add(hit_pos, 13.0 * visual_scale)
	if special == "deviate":
		game.play_sfx("explosion_small", hit_pos, -5.0, 0.82)
	else:
		# Quad mini-rockets are much quieter than a full Rocket Trooper tube.
		game.play_sfx("explosion_small", hit_pos, -8.0 if visual_scale < 0.7 else -2.0)
	queue_free()

func _splash_at(victim, hit_pos: Vector2, body_radius: float) -> void:
	var reach := splash_radius + body_radius
	var d := hit_pos.distance_to(victim.global_position)
	if d > reach:
		return
	var falloff := clampf(1.0 - d / maxf(reach, 1.0), 0.0, 1.0)
	var share := splash_fraction * (SPLASH_FLOOR + (1.0 - SPLASH_FLOOR) * falloff)
	_apply_damage(victim, share)

func _apply_damage(victim, share: float) -> void:
	var target_class := "building"
	if victim.has_method("damage_class"):
		target_class = victim.damage_class()
	victim.take_damage(damage * share * GameDefs.damage_multiplier(weapon, target_class))

func _draw() -> void:
	var s := visual_scale
	# Smoke is drawn only as separate puffs. No line is ever stroked back from
	# the missile to its launcher.
	for t in trail:
		var k := clampf(1.0 - float(t["t"]) / TRAIL_LIFE, 0.0, 1.0)
		var p := to_local(t["p"])
		draw_circle(p, (2.0 + (1.0 - k) * 6.0) * s, Color(0.45, 0.43, 0.39, 0.45 * k))
		draw_circle(p + Vector2(-1.0, -1.0) * s, (1.2 + (1.0 - k) * 3.2) * s,
			Color(0.78, 0.74, 0.66, 0.24 * k))
	var ang := velocity.angle()
	draw_set_transform(Vector2.ZERO, ang, Vector2.ONE * s)
	draw_rect(Rect2(-6.0, -2.0, 10.0, 4.0), Color(0.54, 0.52, 0.49))
	draw_rect(Rect2(-5.0, -1.0, 8.0, 2.0), Color(0.82, 0.79, 0.72))
	draw_colored_polygon(PackedVector2Array([
		Vector2(3.0, -2.0), Vector2(9.0, 0.0), Vector2(3.0, 2.0),
	]), Color(0.72, 0.28, 0.20))
	var team_col: Color = GameDefs.team_color(source_team)
	if special == "deviate":
		# A fat green gas canister instead of a pointed warhead.
		draw_rect(Rect2(-1.0, -3.0, 7.0, 6.0), Color(0.12, 0.48, 0.18))
		draw_rect(Rect2(0.0, -2.0, 5.0, 4.0), Color(0.24, 0.78, 0.32))
		draw_circle(Vector2(6.0, 0.0), 2.4, Color(0.40, 0.95, 0.45, 0.85))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-5.0, -2.0), Vector2(-8.0, -4.5), Vector2(-3.0, -1.0),
	]), team_col)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-5.0, 2.0), Vector2(-8.0, 4.5), Vector2(-3.0, 1.0),
	]), team_col)
	var flame := 0.7 + 0.3 * sin(age * 45.0)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6.0, -1.5), Vector2(-13.0 * flame, 0.0), Vector2(-6.0, 1.5),
	]), Color(1.0, 0.72, 0.22, 0.9))
	draw_circle(Vector2(-8.0, 0.0), 2.0, Color(1.0, 0.93, 0.50, 0.95))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
