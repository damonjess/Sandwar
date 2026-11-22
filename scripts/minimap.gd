class_name Minimap
extends Control

## Live map view: terrain, bases, units and the current camera rectangle.
## Click or tap to jump the camera.

var game
var redraw_timer := 0.0

func setup(g) -> void:
	game = g
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	queue_redraw()

func map_rect() -> Rect2:
	var side := minf(size.x, size.y)
	return Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side))

func _process(delta: float) -> void:
	redraw_timer += delta
	var interval := 0.09 if (game == null or not game.has_power(GameDefs.PLAYER)) else 0.2
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
	if not game.has_power(GameDefs.PLAYER):
		return
	var r := map_rect()
	if r.has_point(pos):
		game.focus_world((pos - r.position) / r.size.x * float(GameDefs.WORLD))

func _draw() -> void:
	if game == null or game.terrain == null:
		return
	if not game.has_power(GameDefs.PLAYER):
		_draw_static()
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.032, 0.028))
	var r := map_rect()
	draw_rect(r, Color(0.08, 0.065, 0.05))
	draw_rect(r.grow(1.0), Color(0.48, 0.38, 0.23), false, 2.0)
	var k := r.size.x / float(GameDefs.WORLD)
	var tile_px := float(GameDefs.TILE) * k

	for y in GameDefs.MAP:
		for x in GameDefs.MAP:
			var i := y * GameDefs.MAP + x
			if game.terrain.seen[i] == 0:
				draw_rect(Rect2(r.position + Vector2(float(x), float(y)) * tile_px, Vector2(tile_px + 0.6, tile_px + 0.6)), Color(0.025, 0.022, 0.018))
				continue
			var c: Color
			if game.terrain.concrete[i] == 1:
				c = Color("c99a74")
			elif game.terrain.types[i] == GameDefs.ROCK:
				c = Color("ba6d3e")
			else:
				c = Color("d8b888")
			if game.terrain.spice[i] > 6.0:
				c = Color("a94b18")
			if game.terrain.lit[i] == 0:
				c = c.darkened(0.48)
			draw_rect(Rect2(r.position + Vector2(float(x), float(y)) * tile_px, Vector2(tile_px + 0.6, tile_px + 0.6)), c)

	for b in game.buildings:
		if is_instance_valid(b) and not b.dead and b.visible:
			var p: Vector2 = r.position + b.global_position / float(GameDefs.WORLD) * r.size
			draw_rect(Rect2(p - Vector2(2.0, 2.0), Vector2(4.0, 4.0)), GameDefs.TEAM_COLORS[b.team])

	for u in game.units:
		if is_instance_valid(u) and not u.dead and u.visible:
			var p: Vector2 = r.position + u.global_position / float(GameDefs.WORLD) * r.size
			draw_rect(Rect2(p - Vector2(1.0, 1.0), Vector2(2.0, 2.0)), GameDefs.TEAM_COLORS[u.team])

	# Camera frame: transform screen corners back into world space so zoom,
	# offset and map limits are all accounted for.
	var vp: Vector2 = get_viewport_rect().size
	var inv: Transform2D = get_viewport().get_canvas_transform().affine_inverse()
	var w0: Vector2 = inv * Vector2.ZERO
	var w1: Vector2 = inv * Vector2(maxf(vp.x - GameHUD.PANEL_WIDTH, 1.0), vp.y)
	var world_rect := Rect2(w0, w1 - w0)
	var frame_pos: Vector2 = r.position + world_rect.position / float(GameDefs.WORLD) * r.size
	var frame_size: Vector2 = world_rect.size / float(GameDefs.WORLD) * r.size
	draw_rect(Rect2(frame_pos, frame_size), Color(0.62, 0.92, 0.35, 0.95), false, 2.0)
	# Subtle live-radar glass: one slow horizontal scanline and an inner vignette.
	var sy := r.position.y + fmod(Time.get_ticks_msec() * 0.022, r.size.y)
	draw_line(Vector2(r.position.x, sy), Vector2(r.end.x, sy), Color(0.55, 0.95, 0.55, 0.22), 1.0)
	draw_rect(r.grow(-1.0), Color(0.02, 0.02, 0.012, 0.32), false, 1.0)
	var lamp := r.position + Vector2(9.0, 9.0)
	draw_circle(lamp, 3.4, Color(0.30, 0.95, 0.38))
	draw_circle(lamp, 1.4, Color(0.92, 1.0, 0.72))

func _draw_static() -> void:
	# Unpowered radar is a dead screen, not a dim live map.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.033, 0.03))
	var r := map_rect()
	draw_rect(r, Color(0.018, 0.018, 0.016))
	var ticks := Time.get_ticks_msec()
	var rng := RandomNumberGenerator.new()
	for row in range(1, 22):
		rng.seed = ticks / 90 + row * 977
		var y := r.position.y + r.size.y * float(row) / 22.0
		var x0 := r.position.x + rng.randf_range(0.0, r.size.x * 0.36)
		var x1 := r.end.x - rng.randf_range(0.0, r.size.x * 0.44)
		var a := rng.randf_range(0.035, 0.13)
		draw_line(Vector2(x0, y), Vector2(x1, y), Color(0.62, 0.72, 0.68, a), rng.randf_range(1.0, 2.0))
	for i in 38:
		rng.seed = ticks / 120 + i * 431
		var p := r.position + Vector2(rng.randf() * r.size.x, rng.randf() * r.size.y)
		draw_rect(Rect2(p, Vector2(rng.randf_range(1.0, 3.0), 1.0)), Color(0.74, 0.78, 0.70, rng.randf_range(0.08, 0.24)))
	draw_rect(r.grow(-8.0), Color(0.20, 0.14, 0.08, 0.48), false, 1.0)
	var font := ThemeDB.fallback_font
	if font != null:
		draw_string(font, Vector2(r.position.x, r.position.y + r.size.y * 0.5 - 3.0), "NO SIGNAL", HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, 15, Color(0.86, 0.43, 0.30, 0.88))
		draw_string(font, Vector2(r.position.x, r.position.y + r.size.y * 0.5 + 15.0), "POWER OFFLINE", HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, 11, Color(0.55, 0.49, 0.39, 0.85))
	var lamp_pos := r.position + Vector2(9.0, 9.0)
	var pulse := 0.45 + 0.55 * absf(sin(float(ticks) * 0.004))
	draw_circle(lamp_pos, 3.4, Color(0.82, 0.20, 0.14, pulse))
