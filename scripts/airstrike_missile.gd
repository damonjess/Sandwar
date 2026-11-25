class_name AirstrikeMissile
extends Node2D

## Small Ornithopter air-to-ground missile. It streaks from the aircraft to a
## point, then asks the game to resolve splash damage through airstrike_impact.

var game
var target := Vector2.ZERO
var start := Vector2.ZERO
var t := 0.0
var duration := 0.34
var team := 0
var _damage := 0.0

func setup(g, team_id: int, from: Vector2, aim: Vector2, damage: float) -> void:
	game = g
	team = team_id
	start = from
	target = aim
	_damage = damage
	position = start
	z_index = 84

func _process(delta: float) -> void:
	t = clampf(t + delta / duration, 0.0, 1.0)
	position = start.lerp(target, t)
	if t >= 1.0:
		if game != null:
			game.airstrike_impact(target)
		queue_free()
	queue_redraw()

func _draw() -> void:
	var dir := (target - start).normalized()
	draw_line(Vector2.ZERO, -dir * 16.0, Color(1.0, 0.52, 0.10, 0.42), 2.0)
	draw_circle(Vector2.ZERO, 3.5, Color(0.96, 0.93, 0.76))
	draw_circle(-dir * 4.0, 2.6, Color(1.0, 0.55, 0.12, 0.9))
