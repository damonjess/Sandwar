class_name Fx
extends Node2D

## Muzzle flashes, impact puffs/fireballs, death blasts and floating text.
## There are deliberately no shots/beams drawn between shooter and target.

var flashes: Array = []
var impacts: Array = []
var blasts: Array = []
var texts: Array = []

## Short pixel muzzle flash. kind: rifle / light / cannon / rocket.
func muzzle(pos: Vector2, angle: float, kind: String, side := 1.0) -> void:
	var life := 0.07
	if kind == "cannon":
		life = 0.16
	elif kind == "rocket":
		life = 0.12
	flashes.append({"p": pos, "a": angle, "kind": kind, "side": side, "t": 0.0, "life": life})

## Impact FX. kind: rifle / light / cannon / rocket.
func impact(pos: Vector2, kind: String, power := 1.0) -> void:
	var life := 0.28
	if kind == "cannon":
		life = 0.42
	elif kind == "rocket":
		life = 0.50
	impacts.append({"p": pos, "kind": kind, "power": power, "t": 0.0, "life": life})

## Large death explosion, kept separate from weapon impacts.
func blast(pos: Vector2, power := 1.0) -> void:
	blasts.append({"p": pos, "t": 0.0, "power": power})

func popup(text: String, pos: Vector2) -> void:
	texts.append({"text": text, "p": pos, "t": 0.0})

func _process(delta: float) -> void:
	if flashes.is_empty() and impacts.is_empty() and blasts.is_empty() and texts.is_empty():
		return
	for f in flashes:
		f["t"] = float(f["t"]) + delta
	for i in impacts:
		i["t"] = float(i["t"]) + delta
	for b in blasts:
		b["t"] = float(b["t"]) + delta
	for t in texts:
		t["t"] = float(t["t"]) + delta
		t["p"] = t["p"] + Vector2(0.0, -30.0 * delta)
	flashes = flashes.filter(func(f): return float(f["t"]) < float(f["life"]))
	impacts = impacts.filter(func(i): return float(i["t"]) < float(i["life"]))
	blasts = blasts.filter(func(b): return float(b["t"]) < 0.5)
	texts = texts.filter(func(t): return float(t["t"]) < 1.6)
	queue_redraw()

func _draw() -> void:
	for i in impacts:
		_draw_impact(i)
	for b in blasts:
		var k := clampf(1.0 - float(b["t"]) / 0.5, 0.0, 1.0)
		var power := float(b.get("power", 1.0))
		var r := (18.0 * (1.0 - k) + 4.0) * power
		draw_circle(b["p"], r, Color(1.0, 0.50, 0.12, k * 0.78))
		draw_circle(b["p"], r * 0.55, Color(1.0, 0.86, 0.34, k * 0.88))
	for f in flashes:
		_draw_muzzle(f)
	for t in texts:
		var k := clampf(1.0 - float(t["t"]) / 1.6, 0.0, 1.0)
		draw_string(ThemeDB.fallback_font, t["p"], String(t["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1.0, 1.0, 0.85, k))

func _draw_muzzle(f: Dictionary) -> void:
	var k := clampf(1.0 - float(f["t"]) / float(f["life"]), 0.0, 1.0)
	var p: Vector2 = f["p"]
	var dir := Vector2.RIGHT.rotated(float(f["a"]))
	var perp := Vector2(-dir.y, dir.x)
	var side := float(f["side"])
	match String(f["kind"]):
		"cannon":
			draw_circle(p, 8.5 * k + 2.0, Color(1.0, 0.45, 0.08, 0.85 * k))
			draw_circle(p, 4.2 * k + 1.0, Color(1.0, 0.92, 0.55, 0.95 * k))
			for i in 3:
				var off: Vector2 = p + dir * (4.0 + float(i) * 3.0) + perp * (side * float(i) - 2.0)
				draw_circle(off, 4.5 - float(i), Color(0.48, 0.46, 0.42, 0.38 * k))
		"rocket":
			draw_circle(p, 6.0 * k + 2.0, Color(1.0, 0.58, 0.14, 0.85 * k))
			draw_circle(p, 2.5 * k + 1.0, Color(1.0, 0.94, 0.64, 0.95 * k))
			draw_circle(p + dir * 4.0 + perp * side * 2.0, 4.0,
				Color(0.56, 0.53, 0.48, 0.42 * k))
		"light":
			draw_circle(p, 4.5 * k + 1.5, Color(1.0, 0.58, 0.10, 0.85 * k))
			draw_circle(p, 2.0 * k + 1.0, Color(1.0, 0.94, 0.58, 0.95 * k))
			draw_line(p, p + dir * 5.0, Color(1.0, 0.82, 0.30, 0.90 * k), 1.5)
		_:
			draw_circle(p, 3.6 * k + 1.2, Color(1.0, 0.68, 0.20, 0.85 * k))
			draw_circle(p, 1.8 * k + 0.8, Color(1.0, 0.97, 0.72, 0.98 * k))
			draw_line(p, p + dir * 4.0, Color(1.0, 0.91, 0.52, 0.90 * k), 1.2)

func _draw_impact(i: Dictionary) -> void:
	var k := clampf(1.0 - float(i["t"]) / float(i["life"]), 0.0, 1.0)
	var p: Vector2 = i["p"]
	var power := float(i["power"])
	match String(i["kind"]):
		"cannon":
			var r := (11.0 * (1.0 - k) + 5.0) * power
			draw_circle(p, r, Color(1.0, 0.39, 0.08, 0.72 * k))
			draw_circle(p, r * 0.58, Color(1.0, 0.82, 0.27, 0.90 * k))
			draw_circle(p + Vector2(-4.0, 2.0), r * 0.85, Color(0.40, 0.37, 0.33, 0.45 * k))
			draw_circle(p + Vector2(4.0, -3.0), r * 0.58, Color(0.55, 0.51, 0.45, 0.36 * k))
			draw_rect(Rect2(p - Vector2(2.0, 2.0), Vector2(4.0, 4.0)),
				Color(1.0, 0.95, 0.68, 0.75 * k))
		"rocket":
			var r := (14.0 * (1.0 - k) + 6.0) * power
			draw_circle(p, r, Color(1.0, 0.44, 0.09, 0.78 * k))
			draw_circle(p, r * 0.55, Color(1.0, 0.88, 0.40, 0.92 * k))
			draw_circle(p + Vector2(-5.0, 3.0), r * 0.82, Color(0.44, 0.41, 0.36, 0.50 * k))
			draw_circle(p + Vector2(5.0, -4.0), r * 0.56, Color(0.62, 0.58, 0.51, 0.38 * k))
		"light", "rifle":
			draw_circle(p, 4.0 * k + 1.5, Color(0.72, 0.58, 0.36, 0.62 * k))
			draw_circle(p + Vector2(3.0, 1.0), 2.2 * k + 0.8, Color(0.82, 0.70, 0.48, 0.46 * k))
			draw_line(p, p + Vector2(3.0, -2.0), Color(1.0, 0.92, 0.55, 0.88 * k), 1.2)
