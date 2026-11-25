class_name ChoamFrigate
extends Node2D

## CHOAM heavy dropship. Unlike the Carryall it is a set-piece: it descends
## from high altitude onto the Starport pad, unloads the whole manifest through
## the game, then climbs back to orbit. The shadow and engine wash are drawn in
## world space so the landing reads even when the camera is focusing the pad.

const CRUISE_HEIGHT := 176.0
const SHADOW_OFFSET := Vector2(42.0, 32.0)

var game
var team := 0
var port = null
var target := Vector2.ZERO
var exit_pos := Vector2.ZERO
var state := "inbound"
var altitude := 1.0
var speed := 250.0
var facing := 0.0
var delivered := false
var _state_time := 0.0
var _rumble_clock := 0.0
var _dust_clock := 0.0

func setup(g, team_id: int, starport) -> void:
	game = g
	team = team_id
	port = starport
	target = starport.global_position
	var from: Vector2 = game._edge_point(target)
	position = from
	exit_pos = game._exit_point(from, target)
	facing = (target - from).angle()
	altitude = 1.0
	z_index = 72
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if UnitArt.has_art("frigate"):
		material = UnitArt.material(team)

func _process(delta: float) -> void:
	_dust_clock += delta
	_rumble_clock -= delta
	if _rumble_clock <= 0.0:
		_rumble_clock = 1.15
		if game != null:
			game.play_sfx("frigate_rumble", position, 1.0, 0.78)
	match state:
		"inbound":
			if _fly_to(target, delta, speed):
				_enter("descend")
		"descend":
			_state_time += delta
			altitude = move_toward(altitude, 0.04, delta * 0.82)
			_fly_to(target, delta, speed * 0.42)
			if _state_time >= 1.35:
				_touchdown()
				_enter("landed")
		"landed":
			_state_time += delta
			altitude = 0.04
			if _state_time >= 1.3:
				_enter("lift")
		"lift":
			_state_time += delta
			altitude = move_toward(altitude, 1.0, delta * 0.54)
			if _state_time >= 1.8:
				_enter("exit")
		"exit":
			altitude = move_toward(altitude, 1.0, delta)
			if _fly_to(exit_pos, delta, speed):
				queue_free()
	queue_redraw()

func _enter(next: String) -> void:
	state = next
	_state_time = 0.0

func _fly_to(destination: Vector2, delta: float, move_speed: float) -> bool:
	var to := destination - position
	var dist := to.length()
	if dist <= 9.0:
		return true
	facing = to.angle()
	position += to / dist * minf(move_speed * delta, dist)
	return position.distance_to(destination) <= 9.0

func _touchdown() -> void:
	if delivered:
		return
	delivered = true
	if game == null:
		return
	game.choam_frigate_touchdown(self)
	if game.fx != null:
		game.fx.sand_burst(target, 138.0, 1.2)
		game.fx.impact(target, "light", 1.4)
	game.play_sfx("build_place", target, 1.0, 0.72)
	if game.camera != null:
		game.camera.shake(0.7, 7.0)

func _draw() -> void:
	var alt := clampf(altitude, 0.0, 1.0)
	# Broad, soft ground shadow: tighter and darker as the ship settles.
	draw_set_transform(SHADOW_OFFSET * alt, 0.0, Vector2(1.0, 0.40))
	draw_circle(Vector2.ZERO, 52.0 + 26.0 * alt, Color(0.055, 0.040, 0.022, 0.32 + 0.10 * alt))
	draw_circle(Vector2.ZERO, 28.0 + 14.0 * alt, Color(0.035, 0.025, 0.014, 0.30))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Engine wash under the nacelles.
	if alt < 0.72:
		var fade := 1.0 - alt / 0.72
		for i in 10:
			var a := TAU * float(i) / 10.0 + _dust_clock * 0.35
			var phase := fmod(_dust_clock * 1.25 + float(i) * 0.13, 1.0)
			var reach := 34.0 + phase * 72.0
			draw_circle(Vector2(cos(a), sin(a)) * reach + Vector2(0.0, 10.0),
				6.0 + phase * 13.0, Color(0.82, 0.67, 0.42, (1.0 - phase) * 0.28 * fade))
	var origin := Vector2(0.0, -alt * CRUISE_HEIGHT)
	var tex := UnitArt.sheet("frigate")
	var hull := UnitArt.cell("frigate")
	if tex != null:
		var screen_box := Rect2(origin - Vector2(hull, hull) * 0.5, Vector2(hull, hull))
		draw_texture_rect_region(tex, screen_box, UnitArt.frame_region("frigate", facing))
	# Four hot engine bells and their exhaust spikes.
	var rocket_axis := Vector2.RIGHT.rotated(facing)
	var side_axis := Vector2(-rocket_axis.y, rocket_axis.x)
	for side in [-1.0, 1.0]:
		var bell: Vector2 = origin - rocket_axis * hull * 0.28 + side_axis * hull * 0.23 * float(side)
		draw_circle(bell, 5.0, Color(0.55, 1.0, 0.88, 0.62))
		draw_line(bell, bell - rocket_axis * (10.0 + alt * 18.0 + sin(_dust_clock * 18.0) * 4.0),
			Color(0.42, 0.92, 1.0, 0.36), 3.0)
