class_name Ornithopter
extends Node2D

## Atreides airstrike aircraft. It flies a straight high-speed lane across the
## target, fires three two-missile salvos on the way, then banks off-map.
## Rocket turrets and Rocket Troopers can acquire it through the game's
## nearest_air_target() helper, so it is a real aircraft rather than an effect.

const CRUISE_HEIGHT := 96.0
const SHADOW_OFFSET := Vector2(26.0, 22.0)

var game
var team := 0
var target := Vector2.ZERO
var dead := false
var hp := 135.0
var max_hp := 135.0
var facing := 0.0
var altitude := 1.0
var lane := 0
var delay := 0.0

var _start := Vector2.ZERO
var _end := Vector2.ZERO
var _t := 0.0
var _duration := 5.4
var _fire_clock := 0.0
var _salvos := 0
var _flash := 0.0
var _clock := 0.0
var _visible_now := false

func setup(g, team_id: int, aim: Vector2, lane_index: int) -> void:
	game = g
	team = team_id
	target = aim
	lane = lane_index
	var from: Vector2 = game._edge_point(aim)
	from += Vector2(0.0, (float(lane) - 1.0) * 54.0)
	position = from
	_start = from
	_end = game._exit_point(from, aim)
	_end += Vector2(0.0, (float(lane) - 1.0) * 70.0)
	_duration = 5.2 + float(lane) * 0.25
	delay = float(lane) * 0.30
	_visible_now = delay <= 0.0
	visible = _visible_now
	facing = (aim - from).angle()
	altitude = 1.0
	z_index = 74
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if UnitArt.has_art("ornithopter"):
		material = UnitArt.material(team)

func is_alive() -> bool:
	return not dead and hp > 0.0

func damage_class() -> String:
	return "vehicle"

func take_damage(amount: float, _weapon := "") -> void:
	if dead:
		return
	hp -= amount
	_flash = 1.0
	if hp <= 0.0:
		die()
	queue_redraw()

func die() -> void:
	if dead:
		return
	dead = true
	if game != null:
		game.on_ornithopter_downed(self)
		if game.fx != null:
			game.fx.blast(global_position, 0.85)
			game.fx.sand_burst(global_position, 58.0, 0.55)
		game.play_sfx("explosion_small", global_position, -1.0, 1.15)
	queue_free()

func _process(delta: float) -> void:
	_clock += delta
	_flash = maxf(0.0, _flash - delta * 4.0)
	if delay > 0.0:
		delay = maxf(0.0, delay - delta)
		if delay <= 0.0:
			visible = true
			_visible_now = true
		return
	_t = clampf(_t + delta / _duration, 0.0, 1.0)
	var path := _start.lerp(_end, _t)
	position = path
	var dir := _end - _start
	if dir.length() > 0.1:
		facing = dir.angle()
	# Fire only while approaching and crossing the target. Each salvo is a pair
	# of missiles; after three the aircraft commits to its bank-out.
	var distance := global_position.distance_to(target)
	if _salvos < 3 and distance < 540.0:
		_fire_clock -= delta
		if _fire_clock <= 0.0:
			_fire_clock = 0.38
			_salvos += 1
			if game != null:
				game.ornithopter_volley(self)
	if _t >= 1.0:
		queue_free()
	queue_redraw()

func _draw() -> void:
	var alt := clampf(altitude, 0.0, 1.0)
	draw_set_transform(SHADOW_OFFSET * alt, 0.0, Vector2(1.0, 0.40))
	draw_circle(Vector2.ZERO, 20.0 + 8.0 * alt, Color(0.06, 0.045, 0.025, 0.32))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var origin := Vector2(0.0, -alt * CRUISE_HEIGHT + sin(_clock * 7.0 + float(lane)) * 2.2)
	var tex := UnitArt.sheet("ornithopter")
	var hull := UnitArt.cell("ornithopter")
	if tex != null:
		draw_set_transform(origin, 0.0, Vector2(1.0, 1.0))
		draw_texture_rect_region(tex, Rect2(Vector2(-hull, -hull) * 0.5, Vector2(hull, hull)),
			UnitArt.frame_region("ornithopter", facing))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Twin contrail streaks behind the wings.
	var back := Vector2.RIGHT.rotated(facing)
	var side := Vector2(-back.y, back.x)
	for s in [-1.0, 1.0]:
		var p: Vector2 = origin + side * (hull * 0.26 * float(s)) - back * hull * 0.18
		draw_line(p, p - back * 28.0, Color(0.78, 0.88, 0.92, 0.24), 2.0)
	if _flash > 0.0:
		draw_circle(origin, 20.0, Color(1.0, 0.48, 0.14, 0.32 * _flash))
	if hp < max_hp:
		var w := 44.0
		var y := origin.y - hull * 0.6
		draw_rect(Rect2(Vector2(-w * 0.5, y), Vector2(w, 4.0)), Color(0.02, 0.02, 0.02, 0.85))
		draw_rect(Rect2(Vector2(-w * 0.5, y), Vector2(w * clampf(hp / max_hp, 0.0, 1.0), 4.0)),
			Color(0.40, 0.92, 0.36))
