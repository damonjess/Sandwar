class_name Minimap
extends Control

## Live map view: terrain, bases, units and the current camera rectangle.
## Click or tap to jump the camera.

var game
var redraw_timer := 0.0
## Tactical radar pings: expanding rings at an alert's world position.
const PING_LIFE := 2.4
var pings: Array = []

func setup(g) -> void:
	game = g
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	queue_redraw()

func map_rect() -> Rect2:
	var side := minf(size.x, size.y)
	return Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side))

## Called by Game for "enemy approaching", base and harvester alerts.
func ping(world_pos: Vector2, color := Color(1.0, 0.28, 0.18)) -> void:
	pings.append({"p": world_pos, "c": color, "t": 0.0})
	if pings.size() > 8:
		pings.pop_front()
	queue_redraw()

func _process(delta: float) -> void:
	for ping in pings:
		ping["t"] = float(ping["t"]) + delta
	pings = pings.filter(func(p): return float(p["t"]) < PING_LIFE)
	redraw_timer += delta
	var interval := 0.09 if (game == null or not game.radar_online(GameDefs.PLAYER)) else 0.2
	if redraw_timer >= interval:
		redraw_timer = 0.0
		queue_redraw()

func _gui_input(event: InputEvent) -> void:
	var hit := false
	var pos := Vector2.ZERO
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		hit = true
		pos = event.position
	elif event is InputEventScreenTouch and event.pressed:
		hit = true
		pos = event.position
	if not hit:
		return
	if not game.radar_online(GameDefs.PLAYER):
		return
	var r := map_rect()
	if r.has_point(pos):
		game.focus_world((pos - r.position) / r.size.x * float(GameDefs.WORLD))

func _draw() -> void:
	if game == null or game.terrain == null:
		return
	if not game.radar_online(GameDefs.PLAYER):
		_draw_static()
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.006, 0.010, 0.008))
	var r := map_rect()
	draw_rect(r, Color(0.006, 0.013, 0.008))
	# Faint phosphor graph paper beneath the live sweep.
	for gx in range(0, int(r.size.x) + 1, 16):
		draw_line(Vector2(r.position.x + gx, r.position.y), Vector2(r.position.x + gx, r.end.y),
			Color(0.18, 0.38, 0.18, 0.055), 1.0)
	for gy in range(0, int(r.size.y) + 1, 16):
		draw_line(Vector2(r.position.x, r.position.y + gy), Vector2(r.end.x, r.position.y + gy),
			Color(0.18, 0.38, 0.18, 0.055), 1.0)
	var k := r.size.x / float(GameDefs.WORLD)
	var tile_px := float(GameDefs.TILE) * k

	for y in GameDefs.MAP:
		for x in GameDefs.MAP:
			var i := y * GameDefs.MAP + x
			if game.terrain.seen[i] == 0:
				draw_rect(Rect2(r.position + Vector2(float(x), float(y)) * tile_px, Vector2(tile_px + 0.6, tile_px + 0.6)), Color(0.004, 0.008, 0.006))
				continue
			var c: Color
			if game.terrain.concrete[i] == 1:
				c = Color(0.25, 0.32, 0.16)
			elif game.terrain.types[i] == GameDefs.ROCK:
				c = Color(0.14, 0.22, 0.11)
			else:
				c = Color(0.10, 0.17, 0.085)
			if game.terrain.spice[i] > 6.0:
				c = Color(0.32, 0.22, 0.08)
			if game.terrain.lit[i] == 0:
				c = c.darkened(0.54)
			draw_rect(Rect2(r.position + Vector2(float(x), float(y)) * tile_px, Vector2(tile_px + 0.6, tile_px + 0.6)), c)

	# House colours, brightened for the dark radar glass.
	for b in game.buildings:
		if is_instance_valid(b) and not b.dead and b.visible:
			var p: Vector2 = r.position + b.global_position / float(GameDefs.WORLD) * r.size
			var col := GameDefs.team_color(b.team).lightened(0.18)
			if b.type_id == "cy" and b.team == GameDefs.PLAYER:
				# The reference radar's bright base bracket, in the player's House colour.
				draw_rect(Rect2(p - Vector2(8.0, 8.0), Vector2(16.0, 16.0)), Color(col.r, col.g, col.b, 0.88), false, 1.2)
			draw_rect(Rect2(p - Vector2(2.5, 2.5), Vector2(5.0, 5.0)), col)
	for u in game.units:
		if is_instance_valid(u) and not u.dead and u.visible:
			var p: Vector2 = r.position + u.global_position / float(GameDefs.WORLD) * r.size
			var col := GameDefs.team_color(u.team).lightened(0.28)
			draw_rect(Rect2(p - Vector2(1.0, 1.0), Vector2(2.0, 2.0)), col)

	# Alert pings: a hard contact on the glass, fading over PING_LIFE seconds.
	for ping in pings:
		var fade: float = clampf(float(ping["t"]) / PING_LIFE, 0.0, 1.0)
		var pp: Vector2 = r.position + Vector2(ping["p"]) / float(GameDefs.WORLD) * r.size
		var pc: Color = ping["c"]
		var reach := 3.0 + fade * 17.0
		draw_arc(pp, reach, 0.0, TAU, 22, Color(pc.r, pc.g, pc.b, (1.0 - fade) * 0.92), 2.0, true)
		draw_arc(pp, reach * 0.55, 0.0, TAU, 18, Color(pc.r, pc.g, pc.b, (1.0 - fade) * 0.48), 1.2, true)
		draw_circle(pp, 1.8, Color(pc.r, pc.g, pc.b, (1.0 - fade) * 0.95))

	# Fine CRT scan lines, a single bright sweep, and a dark glass vignette.
	# Dune's radar glass is black with fine warm-grey raster lines, not a green wash.
	for sy in range(0, int(size.y) + 1, 3):
		draw_line(Vector2(0.0, float(sy)), Vector2(size.x, float(sy)), Color(0.15, 0.10, 0.09, 0.72), 1.0)
	draw_rect(r.grow(-0.5), Color(0.08, 0.16, 0.07, 0.30), false, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.01, 0.0, 0.16))


func _draw_static() -> void:
	# Unpowered radar is a dead black screen, not a dim live map.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.003, 0.005, 0.004))
	var r := map_rect()
	draw_rect(r, Color(0.004, 0.007, 0.005))
	var ticks := Time.get_ticks_msec()
	var rng := RandomNumberGenerator.new()
	for row in range(1, 22):
		rng.seed = ticks / 90 + row * 977
		var y := r.position.y + r.size.y * float(row) / 22.0
		var x0 := r.position.x + rng.randf_range(0.0, r.size.x * 0.34)
		var x1 := r.end.x - rng.randf_range(0.0, r.size.x * 0.44)
		var a := rng.randf_range(0.025, 0.09)
		draw_line(Vector2(x0, y), Vector2(x1, y), Color(0.40, 0.60, 0.36, a), rng.randf_range(1.0, 2.0))
	for i in 30:
		rng.seed = ticks / 120 + i * 431
		var p := r.position + Vector2(rng.randf() * r.size.x, rng.randf() * r.size.y)
		draw_rect(Rect2(p, Vector2(rng.randf_range(1.0, 3.0), 1.0)), Color(0.47, 0.62, 0.40, rng.randf_range(0.05, 0.16)))
	for sy in range(0, int(size.y) + 1, 3):
		draw_line(Vector2(0.0, float(sy)), Vector2(size.x, float(sy)), Color(0.0, 0.025, 0.0, 0.40), 1.0)
	var font := ThemeDB.fallback_font
	if font != null:
		var has_dish: bool = game.has_outpost(GameDefs.PLAYER)
		var line := "LOW POWER" if has_dish else "RADAR OFFLINE"
		var sub := "RESTORE GRID" if has_dish else "BUILD OUTPOST"
		draw_string(font, Vector2(r.position.x, r.position.y + r.size.y * 0.5 - 2.0), line,
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 12, Color(0.72, 0.78, 0.52, 0.80))
		draw_string(font, Vector2(r.position.x, r.position.y + r.size.y * 0.5 + 13.0), sub,
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 11, Color(0.48, 0.58, 0.38, 0.68))
	var pulse := 0.45 + 0.55 * absf(sin(float(ticks) * 0.004))
	draw_circle(r.position + Vector2(9.0, 9.0), 2.6, Color(0.68, 0.18, 0.12, pulse))
	# Power-off state is a bare radar, deliberately quieter than the live screen.
