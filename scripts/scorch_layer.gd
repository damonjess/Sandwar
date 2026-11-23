class_name ScorchLayer
extends Node2D

## Ground scars below structures and units: brief cannon/rocket craters and
## long-lived dusty tread marks left by tracked vehicles on open sand.
##
## Treads fade over twelve seconds and are deliberately faint; they are a mood
## layer, not a decal that competes with units for attention.

const LIFE := 2.4
const TREAD_LIFE := 12.0
const MAX_MARKS := 420

var marks: Array = []

func add(pos: Vector2, radius: float) -> void:
	marks.append({"kind": "scorch", "p": pos, "r": radius, "t": 0.0})
	_trim()

## One track stamp. The Unit calls this every few pixels of travel; repeated
## stamps form the dashed parallel pair of a tank track.
func tread(pos: Vector2, angle: float, width := 1.0) -> void:
	marks.append({"kind": "tread", "p": pos, "a": angle, "w": width, "t": 0.0})
	_trim()

func _trim() -> void:
	if marks.size() > MAX_MARKS:
		marks = marks.slice(marks.size() - MAX_MARKS)

func _process(delta: float) -> void:
	if marks.is_empty():
		return
	for m in marks:
		m["t"] = float(m["t"]) + delta
	marks = marks.filter(_alive)
	queue_redraw()

func _alive(m: Dictionary) -> bool:
	var life := TREAD_LIFE if String(m.get("kind", "scorch")) == "tread" else LIFE
	return float(m["t"]) < life

func _draw() -> void:
	for m in marks:
		if String(m.get("kind", "scorch")) == "tread":
			_draw_tread(m)
			continue
		var k := clampf(1.0 - float(m["t"]) / LIFE, 0.0, 1.0)
		var p: Vector2 = m["p"]
		var r := float(m["r"])
		draw_circle(p, r, Color(0.06, 0.05, 0.04, 0.40 * k))
		draw_circle(p, r * 0.68, Color(0.12, 0.09, 0.06, 0.32 * k))
		draw_rect(Rect2(p - Vector2(r * 0.42, r * 0.16), Vector2(r * 0.84, r * 0.32)),
			Color(0.03, 0.02, 0.02, 0.34 * k))

## Two dusty, slightly irregular lines. Alpha is low and falls away over the
## full twelve seconds so old tracks blend back into the sand.
func _draw_tread(m: Dictionary) -> void:
	var k := clampf(1.0 - float(m["t"]) / TREAD_LIFE, 0.0, 1.0)
	if k <= 0.0:
		return
	var p: Vector2 = m["p"]
	var dir := Vector2.RIGHT.rotated(float(m["a"]))
	var perp := Vector2(-dir.y, dir.x)
	var w := float(m.get("w", 1.0))
	var dash := 6.5 * w
	var gap := 3.8 * w
	for side in PackedFloat32Array([-1.0, 1.0]):
		var c := p + perp * (side * gap)
		draw_line(c - dir * dash * 0.5, c + dir * dash * 0.5,
			Color(0.20, 0.15, 0.10, 0.15 * k), 1.7 * w)
		draw_line(c - dir * dash * 0.4 + perp * 0.9, c + dir * dash * 0.4 + perp * 0.9,
			Color(0.52, 0.42, 0.28, 0.07 * k), 1.0)
