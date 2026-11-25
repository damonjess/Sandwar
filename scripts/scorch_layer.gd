class_name ScorchLayer
extends Node2D

## Ground scars below structures and units: brief cannon/rocket craters and
## long-lived, crisp parallel track impressions left by every ground vehicle.
##
## The tracks are batched into a handful of multiline draws, so even a busy
## armour push at the ring-buffer cap costs only a few draw calls. They fade
## over 27 seconds; the cap drops the oldest stamp first and keeps mobile frame
## time stable.

const LIFE := 2.4
const TREAD_LIFE := 27.0
## 720 stamps around 12 px apart is more than enough fresh trail for a full
## armour column while keeping the batched vertex count comfortably bounded.
const MAX_MARKS := 720
const STAMP_LENGTH := 12.4
const RIB_STEP := 3.1
const TREAD_COLOR := Color(0.32, 0.20, 0.10, 0.42)
const RIB_COLOR := Color(0.16, 0.095, 0.045, 0.30)

var marks: Array = []

func add(pos: Vector2, radius: float) -> void:
	marks.append({"kind": "scorch", "p": pos, "r": radius, "t": 0.0})
	_trim()

## One short section of a vehicle's twin track. Units call this every 12 px of
## travel; adjacent stamps join into continuous parallel bands while each
## section keeps its own age for the gradual fade.
func tread(pos: Vector2, angle: float, width := 1.0, gap := 8.0) -> void:
	marks.append({
		"kind": "tread", "p": pos, "a": angle, "w": width, "g": gap, "t": 0.0,
	})
	_trim()

func _trim() -> void:
	while marks.size() > MAX_MARKS:
		marks.pop_front()

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

func _fade(m: Dictionary) -> float:
	var life := TREAD_LIFE if String(m.get("kind", "scorch")) == "tread" else LIFE
	return pow(clampf(1.0 - float(m["t"]) / life, 0.0, 1.0), 0.82)

func _draw() -> void:
	_draw_treads()
	for m in marks:
		if String(m.get("kind", "scorch")) == "tread":
			continue
		_draw_scorch(m)

func _draw_scorch(m: Dictionary) -> void:
	var k := clampf(1.0 - float(m["t"]) / LIFE, 0.0, 1.0)
	var p: Vector2 = m["p"]
	var r := float(m["r"])
	draw_circle(p, r, Color(0.06, 0.05, 0.04, 0.40 * k))
	draw_circle(p, r * 0.68, Color(0.12, 0.09, 0.06, 0.32 * k))
	draw_rect(Rect2(p - Vector2(r * 0.42, r * 0.16), Vector2(r * 0.84, r * 0.32)),
		Color(0.03, 0.02, 0.02, 0.34 * k))

## Draw every track section in four batches: three band widths plus all ribs.
## Each band is a warm umber strip; small perpendicular ribs give the tread its
## mechanical bite without a texture lookup or a node per mark.
func _draw_treads() -> void:
	if marks.is_empty():
		return
	for bucket in 3:
		var band_width := 2.3 + float(bucket) * 0.5
		var points := PackedVector2Array()
		var colors := PackedColorArray()
		for m in marks:
			if String(m.get("kind", "scorch")) != "tread":
				continue
			var w := float(m.get("w", 1.0))
			var slot := 0 if w < 0.86 else (1 if w < 1.12 else 2)
			if slot != bucket:
				continue
			var k := _fade(m)
			if k <= 0.0:
				continue
			var p: Vector2 = m["p"]
			var direction := Vector2.RIGHT.rotated(float(m["a"]))
			var across := Vector2(-direction.y, direction.x)
			var gap := float(m.get("g", 8.0))
			var half := STAMP_LENGTH * 0.5
			var col := Color(TREAD_COLOR.r, TREAD_COLOR.g, TREAD_COLOR.b, TREAD_COLOR.a * k)
			for side in [-1.0, 1.0]:
				var center: Vector2 = p + across * (side * gap)
				points.append(center - direction * half)
				points.append(center + direction * half)
				colors.append(col)
		if not points.is_empty():
			draw_multiline_colors(points, colors, band_width)

	var ribs := PackedVector2Array()
	var rib_colors := PackedColorArray()
	for m in marks:
		if String(m.get("kind", "scorch")) != "tread":
			continue
		var k := _fade(m)
		if k <= 0.0:
			continue
		var p: Vector2 = m["p"]
		var direction := Vector2.RIGHT.rotated(float(m["a"]))
		var across := Vector2(-direction.y, direction.x)
		var gap := float(m.get("g", 8.0))
		var band := 2.0 + float(m.get("w", 1.0)) * 0.9
		var col := Color(RIB_COLOR.r, RIB_COLOR.g, RIB_COLOR.b, RIB_COLOR.a * k)
		for side in [-1.0, 1.0]:
			var center: Vector2 = p + across * (side * gap)
			for i in 4:
				var along := (float(i) - 1.5) * RIB_STEP
				var q: Vector2 = center + direction * along
				ribs.append(q - across * (band * 0.52))
				ribs.append(q + across * (band * 0.52))
				rib_colors.append(col)
	if not ribs.is_empty():
		draw_multiline_colors(ribs, rib_colors, 1.0)
