class_name BallisticProjectile
extends Node2D

## Fast traveling bullet/shell used by rifles, light vehicles, cannons, siege
## artillery and Devastator plasma.
##
## Damage is applied on impact using the same weapon multipliers and numbers as
## the old hitscan path. There is no physics body, so projectiles cannot hit the
## shooter or unrelated scenery; they only home to their locked enemy target.
## Artillery renders a visible ballistic arc above its ground shadow while the
## actual hit point travels along the ground.

const LIFETIME := 4.5
const TRAIL_LIFE := 0.55

var game
var target = null
var target_pos := Vector2.ZERO
var velocity := Vector2.ZERO
var damage := 7.0
var weapon := "small_arms"
var style := "rifle"
var speed := 1100.0
var turn_rate := 18.0
var source_team := 0
var age := 0.0
var done := false
## Optional blast for super-heavy cannons (the Devastator). Zero for rifles.
var splash_radius := 0.0
var splash_fraction := 0.0
## Artillery trajectory, measured in screen pixels above the ground path.
var arc_height := 0.0
var flight_time := 0.0
var origin_pos := Vector2.ZERO
var trail: Array = []
var trail_timer := 0.0

func setup(g, from_team: int, victim, pos: Vector2, dir: Vector2, dmg: float,
		weapon_id: String, style_id: String, spd: float, turn: float,
		splash := 0.0, splash_share := 0.0) -> void:
	game = g
	source_team = from_team
	target = victim
	if victim != null:
		target_pos = victim.global_position
	else:
		target_pos = pos + dir.normalized() * 100.0
	global_position = pos
	speed = maxf(spd, 1.0)
	velocity = dir.normalized() * speed
	damage = dmg
	weapon = weapon_id
	style = style_id
	turn_rate = maxf(turn, 0.1)
	splash_radius = splash
	splash_fraction = splash_share
	origin_pos = pos
	flight_time = maxf(pos.distance_to(target_pos) / speed, 0.35)
	if style == "artillery":
		arc_height = clampf(pos.distance_to(target_pos) * 0.24, 34.0, 104.0)
	z_index = 16

func _process(delta: float) -> void:
	if done:
		return
	age += delta
	if style == "artillery":
		trail_timer += delta
		if trail_timer >= 0.035:
			trail_timer = 0.0
			var k := clampf(age / flight_time, 0.0, 1.0)
			trail.append({"p": global_position, "h": sin(k * PI) * arc_height, "t": 0.0})
		for puff in trail:
			puff["t"] = float(puff["t"]) + delta
		trail = trail.filter(func(puff): return float(puff["t"]) < TRAIL_LIFE)
	if is_instance_valid(target) and target.has_method("is_alive") and target.is_alive():
		target_pos = target.global_position
	var to_target := target_pos - global_position
	if to_target.length() <= maxf(5.0, speed * delta * 1.5):
		global_position = target_pos
		_impact()
		return
	var desired := to_target.angle()
	var diff := angle_difference(velocity.angle(), desired)
	velocity = Vector2.RIGHT.rotated(velocity.angle() + clampf(diff, -turn_rate * delta, turn_rate * delta)) * speed
	global_position += velocity * delta
	if age >= LIFETIME:
		_impact()
		return
	queue_redraw()

func _impact() -> void:
	if done:
		return
	done = true
	var hit_pos := global_position
	if is_instance_valid(target) and target.has_method("is_alive") and target.is_alive():
		var target_class := "building"
		if target.has_method("damage_class"):
			target_class = target.damage_class()
		target.take_damage(damage * GameDefs.damage_multiplier(weapon, target_class))
	if splash_radius > 0.0:
		for u in game.units:
			if u == target or not is_instance_valid(u) or u.dead or u.team == source_team:
				continue
			_splash_at(u, hit_pos, u.radius)
		for b in game.buildings:
			if b == target or not is_instance_valid(b) or b.dead or b.team == source_team:
				continue
			_splash_at(b, hit_pos, b.size_px * 0.5)
	if game.fx != null:
		match style:
			"artillery":
				game.fx.impact(hit_pos, "artillery", 2.3)
				game.fx.sand_burst(hit_pos, 64.0, 0.9)
			"plasma":
				game.fx.impact(hit_pos, "plasma", 1.45)
			_:
				game.fx.impact(hit_pos, style, 1.6 if splash_radius > 0.0 else 1.0)
	if game.scorch_layer != null:
		match style:
			"artillery":
				# Heavy shells dig a wide dark crater into the sand.
				game.scorch_layer.add(hit_pos, 24.0)
			"plasma":
				game.scorch_layer.add(hit_pos, 13.0)
			"cannon":
				game.scorch_layer.add(hit_pos, 11.0)
	# Artillery lands with a bassy medium explosion; plasma thumps with a lower
	# pitched blast. Bullets stay a dry, quiet tick.
	match style:
		"artillery":
			game.play_sfx("explosion_medium", hit_pos, 0.0, 0.72)
		"plasma":
			game.play_sfx("explosion_medium", hit_pos, -2.0, 0.82)
		"cannon":
			game.play_sfx("explosion_small", hit_pos, -4.0)
		_:
			game.play_sfx("rifle", hit_pos, -15.0)
	queue_free()

func _splash_at(victim, hit_pos: Vector2, body_radius: float) -> void:
	var reach := splash_radius + body_radius
	var d := hit_pos.distance_to(victim.global_position)
	if d > reach:
		return
	var falloff := clampf(1.0 - d / maxf(reach, 1.0), 0.0, 1.0)
	var target_class := "building"
	if victim.has_method("damage_class"):
		target_class = victim.damage_class()
	victim.take_damage(damage * splash_fraction * (0.45 + 0.55 * falloff)
		* GameDefs.damage_multiplier(weapon, target_class))

func _draw() -> void:
	if style == "artillery":
		_draw_artillery()
		return
	var ang := velocity.angle()
	draw_set_transform(Vector2.ZERO, ang, Vector2.ONE)
	match style:
		"plasma":
			# Parallel twin bolts: a crimson-orange envelope around a white-hot
			# core, with a short plasma ember wake.
			for i in 3:
				var back := Vector2(-13.0 - float(i) * 5.0, sin(age * 40.0 + float(i)) * 1.8)
				draw_circle(back, 4.4 - float(i) * 0.8, Color(1.0, 0.24, 0.05, 0.34 - float(i) * 0.08))
			draw_circle(Vector2.ZERO, 9.0, Color(1.0, 0.18, 0.04, 0.28))
			draw_rect(Rect2(-11.0, -3.6, 18.0, 7.2), Color(1.0, 0.30, 0.05, 0.96))
			draw_rect(Rect2(-8.0, -2.1, 15.0, 4.2), Color(1.0, 0.58, 0.16))
			draw_rect(Rect2(-5.0, -1.3, 12.0, 2.6), Color(1.0, 0.94, 0.74))
			draw_rect(Rect2(-3.0, -0.7, 9.0, 1.4), Color(1.0, 1.0, 0.96))
			draw_circle(Vector2(8.0, 0.0), 3.0, Color(1.0, 0.90, 0.70, 0.98))
		"cannon":
			# A short exhaust smear, then the golden shell itself. No beam.
			draw_line(Vector2(-12.0, 0.0), Vector2(-3.0, 0.0),
				Color(1.0, 0.46, 0.10, 0.38), 3.0)
			draw_rect(Rect2(-4.0, -2.0, 7.0, 4.0), Color(0.50, 0.36, 0.13))
			draw_rect(Rect2(-2.0, -1.0, 5.0, 2.0), Color(1.0, 0.63, 0.12))
			draw_circle(Vector2(3.0, 0.0), 2.4, Color(1.0, 0.93, 0.48, 0.98))
		"light":
			# Rapid yellow-white tracer pips; one logical shot per pair.
			for sy in [-1.5, 1.5]:
				draw_line(Vector2(-7.0, sy), Vector2(3.0, sy),
					Color(1.0, 0.90, 0.42, 0.90), 1.5)
				draw_rect(Rect2(-2.0, sy - 0.7, 4.0, 1.4), Color(1.0, 1.0, 0.82))
			draw_circle(Vector2(-9.0, 0.0), 2.0, Color(0.85, 0.78, 0.62, 0.20))
		_:
			# Rifle: a tiny yellow-white tracer pip, not a connecting line.
			draw_line(Vector2(-5.0, 0.0), Vector2(2.0, 0.0),
				Color(1.0, 0.96, 0.68, 0.95), 1.5)
			draw_rect(Rect2(-1.0, -1.0, 3.0, 2.0), Color(1.0, 0.91, 0.46))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Heavy artillery: the shell rides a sine arc while its shadow stays on the
## ground path. Smoke puffs mark the whole trajectory, so the lob is readable
## from the RTS camera.
func _draw_artillery() -> void:
	# Faint dotted trajectory: shows the whole lob even when the shell itself is
	# near the top of the arc and its shadow is far below it.
	for i in range(1, 11):
		var t := float(i) / 11.0
		var ground := origin_pos.lerp(target_pos, t)
		var arc := sin(t * PI) * arc_height
		draw_circle(to_local(ground) + Vector2(0.0, -arc), 1.6,
			Color(1.0, 0.78, 0.38, 0.20))
		draw_circle(to_local(ground), 1.8, Color(0.10, 0.08, 0.05, 0.12))
	for puff in trail:
		var k := clampf(1.0 - float(puff["t"]) / TRAIL_LIFE, 0.0, 1.0)
		var p := to_local(puff["p"]) + Vector2(0.0, -float(puff["h"]))
		draw_circle(p, 2.2 + (1.0 - k) * 5.2, Color(0.50, 0.47, 0.41, 0.38 * k))
		draw_circle(p + Vector2(-1.5, -1.0), 1.2 + (1.0 - k) * 2.6,
			Color(0.76, 0.71, 0.62, 0.22 * k))
	var k := clampf(age / maxf(flight_time, 0.01), 0.0, 1.0)
	var h := sin(k * PI) * arc_height
	# Soft shadow directly beneath the shell: shrinks as the shell climbs.
	var shrink := clampf(1.0 - h / maxf(arc_height, 1.0) * 0.55, 0.35, 1.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.52))
	draw_circle(Vector2.ZERO, 6.0 * shrink, Color(0.03, 0.02, 0.01, 0.30))
	draw_set_transform(Vector2(0.0, -h), velocity.angle(), Vector2.ONE)
	draw_line(Vector2(-20.0, 0.0), Vector2(-9.0, 0.0), Color(0.95, 0.55, 0.16, 0.45), 3.5)
	draw_rect(Rect2(-10.0, -4.5, 19.0, 9.0), Color(0.20, 0.17, 0.13))
	draw_rect(Rect2(-8.0, -3.2, 15.0, 6.4), Color(0.66, 0.55, 0.31))
	draw_rect(Rect2(2.0, -2.4, 8.0, 4.8), Color(0.94, 0.71, 0.22))
	draw_rect(Rect2(5.0, -1.1, 6.0, 2.2), Color(1.0, 0.95, 0.72))
	draw_circle(Vector2(10.0, 0.0), 2.4, Color(1.0, 0.88, 0.52, 0.95))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
