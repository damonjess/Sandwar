class_name ScorchLayer
extends Node2D

## Brief ground scars left by cannon and rocket impacts. It sits above terrain
## and below structures/units, so the crater does not draw over vehicles.

const LIFE := 2.4

var marks: Array = []

func add(pos: Vector2, radius: float) -> void:
	marks.append({"p": pos, "r": radius, "t": 0.0})

func _process(delta: float) -> void:
	if marks.is_empty():
		return
	for m in marks:
		m["t"] = float(m["t"]) + delta
	marks = marks.filter(func(m): return float(m["t"]) < LIFE)
	queue_redraw()

func _draw() -> void:
	for m in marks:
		var k := clampf(1.0 - float(m["t"]) / LIFE, 0.0, 1.0)
		var p: Vector2 = m["p"]
		var r := float(m["r"])
		draw_circle(p, r, Color(0.06, 0.05, 0.04, 0.40 * k))
		draw_circle(p, r * 0.68, Color(0.12, 0.09, 0.06, 0.32 * k))
		draw_rect(Rect2(p - Vector2(r * 0.42, r * 0.16), Vector2(r * 0.84, r * 0.32)),
			Color(0.03, 0.02, 0.02, 0.34 * k))
