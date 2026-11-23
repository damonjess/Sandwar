class_name Carryall
extends Node2D

## Dune 2000 style airborne dropship.
##
## Flies in from a map edge with its load slung under the grapple bay, slows
## over the drop point while the ground shadow tightens beneath it, sets the
## cargo down with a thud, then climbs away. The game owns job assignment:
## refinery deliveries, long-haul harvester ferries and reinforcement drops.

## Hover height in world pixels at full altitude.
const CRUISE_HEIGHT := 94.0
## Shadow drift at full altitude; shrinks to zero as the ship touches down.
const SHADOW_OFFSET := Vector2(22.0, 26.0)

var game
var team := 0
var state := "inbound"
var altitude := 1.0
var speed := 240.0
var drop_pos := Vector2.ZERO
var exit_pos := Vector2.ZERO
var cargo: Array = []
## "harvester" draws a slung harvester; "unit" keeps an empty bay.
var carry_kind := "unit"
## refinery / ferry / reinforce. Ferry drops resume the harvester's run.
var job := "refinery"
var announce := false
var facing := 0.0
var released := false
var dust_clock := 0.0

var _state_time := 0.0

func setup(g, team_id: int, from: Vector2, drop: Vector2, load: Array, exit_at: Vector2, kind := "unit") -> void:
	game = g
	team = team_id
	position = from
	drop_pos = drop
	exit_pos = exit_at
	cargo = load
	carry_kind = kind
	facing = (drop - from).angle()
	altitude = 1.0
	z_index = 60
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if UnitArt.has_art("carryall"):
		material = UnitArt.material(team)

func _process(delta: float) -> void:
	dust_clock += delta
	match state:
		"inbound":
			if _fly_to(drop_pos, delta, speed):
				_enter("descend")
		"descend":
			_state_time += delta
			altitude = move_toward(altitude, 0.05, delta * 1.35)
			_fly_to(drop_pos, delta, speed * 0.5)
			if _state_time >= 1.05:
				_release()
				_enter("lift")
		"lift":
			_state_time += delta
			altitude = move_toward(altitude, 1.0, delta * 0.62)
			if _state_time >= 1.5:
				_enter("exit")
		"exit":
			altitude = move_toward(altitude, 1.0, delta * 1.1)
			if _fly_to(exit_pos, delta, speed):
				queue_free()
	queue_redraw()

func _enter(next: String) -> void:
	state = next
	_state_time = 0.0

## True once the ship is within a few pixels of its target.
func _fly_to(target: Vector2, delta: float, move_speed: float) -> bool:
	var to := target - position
	var dist := to.length()
	if dist <= 8.0:
		return true
	facing = to.angle()
	position += to / dist * minf(move_speed * delta, dist)
	return position.distance_to(target) <= 8.0

func _release() -> void:
	released = true
	var count := cargo.size()
	for i in count:
		var u = cargo[i]
		if not is_instance_valid(u):
			continue
		var spread := Vector2.ZERO
		if count > 1:
			spread = Vector2(float(i) - float(count - 1) * 0.5, 0.0) * 26.0
		u.position = drop_pos + spread
		u.airborne = false
		u.visible = u.team == 0
		u.set_process(true)
		u.set_physics_process(true)
		if job == "ferry" and u.type_id == "harvester":
			# Touchdown cancels the lift: the harvester simply resumes its run
			# to the refinery, which is now right beside it.
			u.state = "to_refinery"
			u.has_move = false
			u.path.clear()
		u.queue_redraw()
	cargo.clear()
	if game == null:
		return
	if game.fx != null:
		game.fx.impact(drop_pos, "light", 1.2)
		game.fx.sand_burst(drop_pos, 46.0, 0.55)
	game.play_sfx("build_place", drop_pos, -2.0, 0.9)
	if announce:
		game.play_voice("reinforcements")
		game._say("Reinforcements have arrived.")
		if game.hud != null and game.hud.minimap != null:
			game.hud.minimap.ping(drop_pos, Color(0.42, 1.0, 0.46))
		if game.fx != null:
			game.fx.popup("REINFORCEMENTS", drop_pos + Vector2(0.0, -32.0))

func _draw() -> void:
	var alt := clampf(altitude, 0.0, 1.0)
	# Offset ground shadow: directly underneath at touchdown, drifting to the
	# south-east and softening as the dropship climbs back to cruising height.
	draw_set_transform(SHADOW_OFFSET * alt, 0.0, Vector2(1.0, 0.46))
	draw_circle(Vector2.ZERO, 26.0 + 10.0 * alt, Color(0.07, 0.05, 0.03, 0.30 + 0.08 * alt))
	draw_circle(Vector2.ZERO, (26.0 + 10.0 * alt) * 0.62, Color(0.05, 0.035, 0.02, 0.26))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Thruster wash and grit near the ground.
	if alt < 0.6:
		var fade := 1.0 - alt / 0.6
		for i in 8:
			var a := TAU * float(i) / 8.0 + dust_clock * 0.7
			var phase := fmod(dust_clock * 1.8 + float(i) * 0.17, 1.0)
			var reach := 16.0 + phase * 42.0
			draw_circle(Vector2(cos(a), sin(a)) * reach + Vector2(0.0, 6.0),
				4.0 + phase * 8.0, Color(0.80, 0.66, 0.44, (1.0 - phase) * 0.32 * fade))
	var origin := Vector2(0.0, -alt * CRUISE_HEIGHT)
	var tex := UnitArt.sheet("carryall")
	var hull := UnitArt.cell("carryall")
	if tex != null:
		draw_texture_rect_region(tex, Rect2(origin - Vector2(hull, hull) * 0.5, Vector2(hull, hull)),
			UnitArt.frame_region("carryall", facing))
	# The load hangs visibly in the grapple bay until touchdown.
	if not released and not cargo.is_empty():
		var u = cargo[0]
		if not is_instance_valid(u):
			return
		var load_tex: Texture2D = null
		var region := Rect2()
		if u.type_id == "harvester":
			load_tex = UnitArt.harvester_sheet(0.0)
			region = UnitArt.harvester_region(u.facing)
		else:
			load_tex = UnitArt.sheet(u.type_id)
			region = UnitArt.frame_region(u.type_id, u.facing)
		if load_tex == null:
			return
		var hang := origin + Vector2(0.0, hull * 0.38 + sin(dust_clock * 2.3) * 2.0)
		# Two grapple straps from the bay to the load.
		draw_line(origin + Vector2(-12.0, 8.0), hang + Vector2(-10.0, -14.0), Color(0.18, 0.16, 0.13, 0.85), 2.0)
		draw_line(origin + Vector2(12.0, 8.0), hang + Vector2(10.0, -14.0), Color(0.18, 0.16, 0.13, 0.85), 2.0)
		draw_set_transform(hang, 0.0, Vector2(0.72, 0.72))
		draw_texture_rect_region(load_tex, Rect2(Vector2(-31.0, -31.0), Vector2(62.0, 62.0)), region)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
