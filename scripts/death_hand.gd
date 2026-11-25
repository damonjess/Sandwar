class_name DeathHand
extends Node2D

## Harkonnen Palace superweapon. The missile is drawn procedurally because it
## spends most of its life above the playfield; the important read is the
## parabolic arc, the burning trail, and the ground shadow racing below it.

var game
var start := Vector2.ZERO
var target := Vector2.ZERO
var t := 0.0
var duration := 3.1
var altitude := 340.0
var _trail: Array[Vector2] = []
var _clock := 0.0

func setup(g, from: Vector2, aim: Vector2) -> void:
	game = g
	start = from
	target = aim
	position = Vector2.ZERO
	z_index = 90
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _process(delta: float) -> void:
	_clock += delta
	t = clampf(t + delta / duration, 0.0, 1.0)
	var flight := start.lerp(target, t)
	flight.y -= sin(t * PI) * altitude
	position = Vector2.ZERO
	# Keep a bounded trail in world coordinates; a launch from one side of the
	# map reads as a rising smoke line even before the missile enters the view.
	_trail.append(flight)
	if _trail.size() > 34:
		_trail.pop_front()
	if t >= 1.0:
		if game != null:
			game.death_hand_impact(target)
		queue_free()
	queue_redraw()

func _draw() -> void:
	var flight := start.lerp(target, t)
	flight.y -= sin(t * PI) * altitude
	for i in range(1, _trail.size()):
		var k := float(i) / float(maxi(_trail.size() - 1, 1))
		draw_line(_trail[i - 1], _trail[i],
			Color(0.98, 0.44, 0.12, 0.04 + k * 0.18), 1.0 + k * 3.0)
	# Ground shadow below the missile's current horizontal position.
	var ground := Vector2(flight.x, start.lerp(target, t).y)
	var shrink := 1.0 - 0.45 * sin(t * PI)
	draw_set_transform(ground, 0.0, Vector2(1.0, 0.42))
	draw_circle(Vector2.ZERO, 24.0 * shrink + 8.0, Color(0.03, 0.02, 0.012, 0.30))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Heavy ballistic casing, nose and fins.
	var dir := (target - start).normalized()
	var side := Vector2(-dir.y, dir.x)
	var tail := flight - dir * 22.0
	draw_colored_polygon(PackedVector2Array([
		flight + dir * 28.0, flight + side * 10.0, tail + side * 8.0,
		tail + dir * 3.0, tail - side * 8.0, flight - side * 10.0,
	]), Color(0.62, 0.62, 0.55))
	draw_line(flight + dir * 28.0, tail + dir * 3.0, Color(0.92, 0.88, 0.72, 0.8), 2.0)
	draw_line(tail + dir * 3.0 + side * 8.0, tail - dir * 15.0 + side * 19.0,
		Color(0.28, 0.26, 0.21), 4.0)
	draw_line(tail + dir * 3.0 - side * 8.0, tail - dir * 15.0 - side * 19.0,
		Color(0.28, 0.26, 0.21), 4.0)
	draw_circle(tail, 9.0, Color(1.0, 0.36, 0.04, 0.9))
	draw_circle(tail - dir * 9.0, 5.0, Color(1.0, 0.88, 0.36, 0.95))
	draw_line(tail, tail - dir * (26.0 + sin(_clock * 20.0) * 5.0),
		Color(1.0, 0.50, 0.06, 0.55), 5.0)
