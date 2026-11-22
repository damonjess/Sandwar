class_name BallisticProjectile
extends Node2D

## Fast traveling bullet/shell used by rifles, light vehicles and cannons.
## Damage is applied on impact using the same weapon multipliers and numbers as
## the old hitscan path. There is no physics body, so projectiles cannot hit the
## shooter or unrelated scenery; they only home to their locked enemy target.

const LIFETIME := 3.5

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

func setup(g, from_team: int, victim, pos: Vector2, dir: Vector2, dmg: float,
		weapon_id: String, style_id: String, spd: float, turn: float) -> void:
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
	z_index = 16

func _process(delta: float) -> void:
	if done:
		return
	age += delta
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
	if game.fx != null:
		game.fx.impact(hit_pos, style, 1.0)
	if style == "cannon" and game.scorch_layer != null:
		game.scorch_layer.add(hit_pos, 11.0)
	# Shells get the small impact explosion; bullet puffs use a dry, quiet tick.
	if style == "cannon":
		game.play_sfx("explosion_small", hit_pos, -4.0)
	else:
		game.play_sfx("rifle", hit_pos, -15.0)
	queue_free()

func _draw() -> void:
	var ang := velocity.angle()
	draw_set_transform(Vector2.ZERO, ang, Vector2.ONE)
	match style:
		"cannon":
			# A short exhaust smear, then the shell itself. No beam.
			draw_line(Vector2(-12.0, 0.0), Vector2(-3.0, 0.0),
				Color(1.0, 0.46, 0.10, 0.38), 3.0)
			draw_rect(Rect2(-4.0, -2.0, 7.0, 4.0), Color(0.36, 0.32, 0.27))
			draw_rect(Rect2(-2.0, -1.0, 5.0, 2.0), Color(1.0, 0.58, 0.12))
			draw_circle(Vector2(3.0, 0.0), 2.2, Color(1.0, 0.91, 0.36, 0.95))
		"light":
			# Twin barrel pips; one logical shot, so damage is not doubled.
			for sy in [-1.5, 1.5]:
				draw_line(Vector2(-6.0, sy), Vector2(2.0, sy),
					Color(1.0, 0.76, 0.20, 0.95), 1.5)
				draw_rect(Rect2(-2.0, sy - 0.7, 3.0, 1.4), Color(1.0, 0.95, 0.58))
		_:
			# Rifle: a tiny yellow-white tracer pip, not a connecting line.
			draw_line(Vector2(-5.0, 0.0), Vector2(2.0, 0.0),
				Color(1.0, 0.96, 0.68, 0.95), 1.5)
			draw_rect(Rect2(-1.0, -1.0, 3.0, 2.0), Color(1.0, 0.91, 0.46))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
