class_name Building
extends Node2D

## Static structure: construction yard, refinery, barracks, factory, turret.

const AIM_TOLERANCE := 0.12
const RocketScript = preload("res://scripts/rocket.gd")
const BallisticScript = preload("res://scripts/projectile.gd")

var game
var type_id := "cy"
var team := 0
var cfg := {}
var hp := 500.0
var max_hp := 500.0
var span := Vector2i(2, 2)
var size_px := 80.0
var dead := false
var turret_cd := 0.0
var aim := 0.0
var anim := 0.0
var powered := true
var _barrel_side := 1.0
var _salvo_left := 0
var _salvo_timer := 0.0
var _salvo_target = null
var repairing := false
var repair_debt := 0.0
## Production rally destination set from the sidebar. The Building remains a
## static structure; this only changes where its completed units emerge.
var has_rally := false
var rally_point := Vector2.ZERO
## The baked art driver is used by every structure except walls, which use the
## 16-mask WallView autotile. The two turrets add a separately baked 16-direction
## head on top of the fixed bunker base.
var view = null
var turret_head: Sprite2D = null

func configure(id: String, team_id: int, g) -> void:
	type_id = id
	team = team_id
	game = g
	cfg = GameDefs.STRUCTURES[id]
	span = GameDefs.size_of(id)
	size_px = float(maxi(span.x, span.y) * GameDefs.TILE)
	max_hp = float(cfg["hp"])
	hp = max_hp
	z_index = 0
	var scene_path := GameDefs.scene_of(id)
	if scene_path != "" and ResourceLoader.exists(scene_path):
		var packed := load(scene_path) as PackedScene
		if packed != null:
			view = packed.instantiate()
	if view == null:
		if id == "wall":
			# Walls use a dedicated 16-mask, 40 px autotile sheet. Their frame is
			# their neighbour mask, not an animated building frame.
			view = WallView.new()
			view.art_top = BuildingArt.art_top(id)
		else:
			# All non-scene structures use the same baked sheet driver. This is what
			# replaces the old flat blue procedural boxes.
			view = StructureView.new()
			view.structure_id = id
			view.art_top = BuildingArt.art_top(id)
	var visual_scale := BuildingArt.turret_visual_scale(id)
	if view != null:
		# Behind the Building so the smoke, selection and health bar stay on top.
		view.z_index = -1
		if view is StructureView:
			view.visual_scale = visual_scale
		add_child(view)
		if view.has_method("setup"):
			view.setup(team)
	if id == "turret" or id == "rocketturret":
		var head_tex := BuildingArt.head(id)
		if head_tex != null:
			turret_head = Sprite2D.new()
			turret_head.texture = head_tex
			turret_head.hframes = 16
			turret_head.vframes = 1
			turret_head.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			turret_head.material = BuildingArt.material(team)
			turret_head.z_index = -1
			turret_head.scale = Vector2(visual_scale, visual_scale)
			turret_head.position = Vector2(0.0, -2.0 * visual_scale)
			add_child(turret_head)
			_update_turret_frame()

func is_alive() -> bool:
	return not dead and hp > 0.0

func damage_class() -> String:
	# Wind traps are a soft target: light armour, hit hard by almost anything.
	return String(GameDefs.STRUCTURES[type_id].get("armour", "building"))

func world_rect() -> Rect2:
	var box := Vector2(span) * float(GameDefs.TILE)
	return Rect2(global_position - box * 0.5, box)

## Top-left tile occupied by the structure footprint.
func tile_origin() -> Vector2i:
	if game != null and game.terrain != null:
		return game.terrain.tile_of(world_rect().position)
	return Vector2i(roundi(global_position.x / float(GameDefs.TILE) - float(span.x) * 0.5),
		roundi(global_position.y / float(GameDefs.TILE) - float(span.y) * 0.5))

func set_wall_mask(mask: int) -> void:
	if view != null and view.has_method("set_wall_mask"):
		view.set_wall_mask(mask)

func take_damage(amount: float) -> void:
	if dead:
		return
	hp -= amount
	if hp <= 0.0:
		die()
	queue_redraw()

func die() -> void:
	if dead:
		return
	dead = true
	hp = 0.0
	if game != null:
		game.on_building_destroyed(self)
	queue_free()

func _process(delta: float) -> void:
	if dead or game == null:
		return
	if view != null and view.has_method("set_damage"):
		# Baked art swaps to its battle-damaged row under half health.
		view.set_damage(clampf(1.0 - hp / max_hp, 0.0, 1.0))
	if bool(cfg.get("power_dependent", false)) and type_id != "turret" and type_id != "rocketturret":
		anim += delta
		queue_redraw()
	if type_id == "windtrap":
		# Soot and smoke pulse for the trap; the view animates its louvres.
		anim += delta
		queue_redraw()
		return
	if type_id != "turret" and type_id != "rocketturret":
		return
	anim += delta
	# Rocket turrets feed off the base grid. Keep drawing them while dark so
	# the dimmed sheet and the blinking red lamp show why they are silent.
	var was_powered := powered
	powered = type_id != "rocketturret" or game.has_power(team)
	if powered != was_powered:
		queue_redraw()
	turret_cd = maxf(0.0, turret_cd - delta)
	if not powered:
		_salvo_left = 0
		queue_redraw()
		return
	var target = game.nearest_enemy(global_position, team, float(cfg["range"]))
	if target != null:
		var want: float = (target.global_position - global_position).angle()
		var turn_rate := float(cfg.get("turn_rate", 8.0))
		var diff := angle_difference(aim, want)
		aim = wrapf(aim + clampf(diff, -turn_rate * delta, turn_rate * delta), -PI, PI)
	_update_turret_frame()
	queue_redraw()
	# The second rocket of a salvo follows 0.12s behind the first. It is launched
	# even if the first has already killed the original target, so every salvo is
	# visibly a pair.
	if type_id == "rocketturret" and _salvo_left > 0:
		_salvo_timer -= delta
		if _salvo_timer <= 0.0:
			var follow = _salvo_target
			if not is_instance_valid(follow) or not follow.is_alive():
				follow = target
			if follow != null:
				_launch_rocket(follow, 0.5)
			_salvo_left = 0
	if target == null:
		_salvo_left = 0
		return
	var want: float = (target.global_position - global_position).angle()
	if turret_cd > 0.0:
		return
	# A rocket leaves the tube only after the launcher has swung onto the target.
	if type_id == "rocketturret" and absf(angle_difference(aim, want)) > AIM_TOLERANCE:
		return
	turret_cd = float(cfg["cooldown"])
	if type_id == "rocketturret":
		# Two missiles, each carrying half the existing 26 damage, so the salvo
		# total stays exactly the same as the old single hit.
		_salvo_target = target
		_salvo_left = 1
		_salvo_timer = 0.12
		_launch_rocket(target, 0.5)
		return
	_fire_cannon(target)

func _update_turret_frame() -> void:
	if turret_head == null:
		return
	# The building-head baker rotates models with `rotation.y = +angle` and a
	# fixed south camera. Positive Y rotation runs east -> north -> west ->
	# south, the opposite of screen angle: cell 4 points north and cell 12
	# points south. Negate the 2D aim angle before selecting the cell. The unit
	# sheets use the opposite baker rotation and get their own offset in
	# UnitArt.direction_index.
	var f := posmod(int(round(-aim / TAU * 16.0)), 16)
	turret_head.frame_coords = Vector2i(f, 0)

func _fire_cannon(target) -> void:
	var dir := Vector2.RIGHT.rotated(aim)
	var side := _barrel_side
	var perp := Vector2(-dir.y, dir.x)
	# The visible head is scaled down in StructureView, so use its matched
	# muzzle distance rather than the old unscaled 1x1 sheet offset.
	var muzzle := global_position + dir * BuildingArt.turret_muzzle_distance(type_id) + perp * (2.0 * side)
	_barrel_side = -_barrel_side
	var shell := BallisticScript.new()
	game.add_child(shell)
	shell.setup(game, team, target, muzzle, dir, float(cfg["damage"]),
		String(cfg.get("weapon", "cannon")), "cannon", 680.0, 10.0)
	game.fx.muzzle(muzzle, aim, "cannon", side)
	game.play_sfx("cannon", global_position, -1.0)

func _launch_rocket(target, share := 1.0) -> void:
	var dir := Vector2.RIGHT.rotated(aim)
	var side := _barrel_side
	var perp := Vector2(-dir.y, dir.x)
	var muzzle := global_position + dir * BuildingArt.turret_muzzle_distance(type_id) + perp * (3.0 * side)
	_barrel_side = -_barrel_side
	var rocket := RocketScript.new()
	game.add_child(rocket)
	rocket.setup(game, team, target, muzzle, dir, float(cfg["damage"]) * share,
		String(cfg.get("weapon", "rocket")), float(cfg.get("splash", 56.0)),
		float(cfg.get("splash_fraction", 0.6)), float(cfg.get("rocket_speed", 380.0)),
		float(cfg.get("turn_rate", 3.5)), 1.0, 1.4)
	game.fx.muzzle(muzzle, aim, "rocket", side)
	game.play_sfx("rocket_launch", global_position, -2.0)

func _draw() -> void:
	# The building art itself is a baked 3D sheet on the child StructureView.
	if type_id == "rocketturret" and not powered:
		# Blinking red status lamp: the launcher is built but has no grid power.
		var blink := 0.45 + 0.55 * absf(sin(anim * 5.0))
		var lamp := Vector2(11.0, -11.0)
		draw_circle(lamp, 4.2, Color(0.90, 0.18, 0.10, blink))
		draw_circle(lamp, 1.8, Color(1.0, 0.82, 0.50, blink))
	if bool(cfg.get("power_dependent", false)) and game != null and not game.has_power(team):
		_draw_power_badge()
	if game != null and game.selected_build == self:
		var box := Vector2(span) * float(GameDefs.TILE)
		var sel := Rect2(-box * 0.5, box)
		draw_rect(sel, Color(1.0, 0.86, 0.35, 0.10))
		draw_rect(sel, Color(1.0, 0.86, 0.35, 0.95), false, 2.5)
		var arm := 12.0
		for corner in [sel.position, Vector2(sel.end.x, sel.position.y), Vector2(sel.position.x, sel.end.y), sel.end]:
			draw_line(corner, corner + Vector2(arm * (1.0 if corner.x < 0.0 else -1.0), 0.0), Color(1.0, 0.9, 0.5), 3.0)
	if type_id == "windtrap" and hp < max_hp * 0.62:
		var dmg := clampf(1.0 - hp / max_hp, 0.0, 1.0)
		var box := Vector2(span) * float(GameDefs.TILE)
		var top := -box.y * 0.5 + 4.0
		for i in 3:
			var ph := fmod(anim * 0.55 + float(i) * 0.33, 1.0)
			var puff := Vector2(sin(float(i) * 2.1 + anim * 0.8) * 12.0, top - ph * 44.0)
			draw_circle(puff, 7.0 + ph * 16.0, Color(0.10, 0.09, 0.08, (1.0 - ph) * 0.60 * dmg))
			draw_circle(puff - Vector2(2.0, 2.0), 4.0 + ph * 8.0, Color(0.55, 0.52, 0.48, (1.0 - ph) * 0.22 * dmg))
		if dmg > 0.45:
			var flick := 0.75 + 0.25 * sin(anim * 9.0)
			draw_circle(Vector2(0.0, top + 12.0), 9.0 * flick, Color(1.0, 0.50, 0.10, 0.65))
			draw_circle(Vector2(0.0, top + 10.0), 4.6 * flick, Color(1.0, 0.88, 0.48, 0.85))
	_draw_health_bar()

func _draw_health_bar() -> void:
	var selected_now: bool = game != null and game.selected_build == self
	if hp >= max_hp and not selected_now:
		return
	var w := Vector2(span).x * float(GameDefs.TILE) * 0.9
	var y := -size_px * 0.5 - 4.0
	if view != null and "art_top" in view:
		y = float(view.art_top) - 9.0
	var ratio := clampf(hp / maxf(max_hp, 1.0), 0.0, 1.0)
	var col := Color(0.95, 0.25, 0.18)
	if ratio > 0.66:
		col = Color(0.42, 0.92, 0.32)
	elif ratio > 0.33:
		col = Color(0.96, 0.78, 0.20)
	if repairing:
		col = col.lerp(Color(0.30, 0.75, 1.0), 0.35)
	var segments := 10
	var gap := 1.0
	var seg_w := (w - gap * float(segments - 1)) / float(segments)
	draw_rect(Rect2(Vector2(-w * 0.5 - 2.0, y - 2.0), Vector2(w + 4.0, 8.0)), Color(0.02, 0.02, 0.02, 0.78))
	for i in segments:
		var lit := float(i + 1) / float(segments) <= ratio + 0.001
		var x := -w * 0.5 + float(i) * (seg_w + gap)
		draw_rect(Rect2(Vector2(x, y), Vector2(seg_w, 4.0)), col if lit else Color(0.13, 0.10, 0.07, 0.92))
	draw_rect(Rect2(Vector2(-w * 0.5 - 2.0, y - 2.0), Vector2(w + 4.0, 8.0)), Color(0.02, 0.02, 0.02, 0.95), false, 1.0)

func _draw_power_badge() -> void:
	var pulse := 0.55 + 0.45 * absf(sin(Time.get_ticks_msec() * 0.008))
	var top := -size_px * 0.5 - 18.0
	if view != null and "art_top" in view:
		top = float(view.art_top) - 12.0
	var p := Vector2(size_px * 0.39, top)
	draw_circle(p, 9.0, Color(0.05, 0.04, 0.02, 0.92))
	draw_circle(p, 8.0, Color(0.96, 0.70, 0.12, pulse), false, 1.8)
	var bolt := PackedVector2Array([
		p + Vector2(1.0, -5.5), p + Vector2(-3.0, 0.5), p + Vector2(-0.5, 0.5),
		p + Vector2(-1.5, 5.5), p + Vector2(3.5, -0.5), p + Vector2(0.7, -0.5),
	])
	draw_colored_polygon(bolt, Color(1.0, 0.90, 0.38, 0.92))
