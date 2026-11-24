extends SceneTree

## Dev harness for the Rocket Turret. It builds one next to the starting base,
## proves it stays silent while the grid is short, then adds a Wind Trap and
## checks the two-missile salvo, smoke trails, impact fireball and splash.
##
##   ~/.local/bin/godot --path . --script res://tools/test_rocket_turret.gd

const RocketScript = preload("res://scripts/rocket.gd")
const OUT_DIR := "res://build/screens"
const OUT_UNPOWERED := OUT_DIR + "/rocket-unpowered.png"
const OUT_FIRING := OUT_DIR + "/rocket-firing.png"
const OUT_IMPACT := OUT_DIR + "/rocket-impact.png"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	for i in 10:
		await process_frame

	# Keep the scene still for the test: no AI waves, fog refresh or auto-orders.
	scene.set_process(false)
	scene.shroud.visible = false
	for b in scene.buildings:
		b.visible = true
	for u in scene.units:
		u.visible = true

	# The starting base is deliberately short on power: CY 70 vs 80 used once
	# this turret exists (refinery 40 + barracks 20 + turret 20).
	var turret = scene.add_building("rocketturret", 0, Vector2i(22, 40))
	var tank = scene.spawn_unit("tank", 1, Vector2(26.5, 37.5) * GameDefs.TILE)
	var support = scene.spawn_unit("infantry", 1, tank.global_position + Vector2(30.0, 0.0))
	var far = scene.spawn_unit("infantry", 1, tank.global_position + Vector2(150.0, 0.0))
	for u in [tank, support, far]:
		u.speed = 0.0
		u.damage = 0.0
		u.attack_range = 0.0
	scene.terrain.reveal(tank.global_position, 180.0)

	var cam = scene.camera
	cam.user_zoomed = true
	cam.zoom = Vector2(2.0, 2.0)
	cam.position = Vector2(24.5, 39.0) * GameDefs.TILE
	cam.offset = Vector2(GameHUD.PANEL_WIDTH * 0.5 / 2.0, 0.0)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	await create_timer(0.8).timeout
	var head := BuildingArt.head("rocketturret")
	var head_frames := 0 if head == null else int(head.get_width() / 368)
	print("ROCKET head_frames=", head_frames, " head_ok=", head_frames == 16,
		" power=", scene.power_out(0), "/", scene.power_used(0),
		" powered=", turret.powered, " aim=", turret.aim,
		" tank_hp=", tank.hp, " support_hp=", support.hp)
	var hp_before: float = tank.hp
	await RenderingServer.frame_post_draw
	var unpowered := root.get_texture().get_image()
	print("capture: ", OUT_UNPOWERED, " err=",
		unpowered.save_png(ProjectSettings.globalize_path(OUT_UNPOWERED)))

	# Wind Trap turns the grid on; the turret must swing onto the tank, wait for
	# alignment, then launch both missiles of the salvo.
	scene.add_building("windtrap", 0, Vector2i(20, 44))
	var rockets: Array = []
	var salvo_wait := 0.0
	while rockets.size() < 2 and salvo_wait < 0.7:
		await create_timer(0.02).timeout
		salvo_wait += 0.02
		rockets.clear()
		for c in scene.get_children():
			if c.get_script() == RocketScript:
				rockets.append(c)
	var dual_ok := rockets.size() >= 2
	print("ROCKET powered=", turret.powered, " out=", scene.power_out(0), "/", scene.power_used(0),
		" aim=", turret.aim, " in_flight=", rockets.size(), " dual_ok=", dual_ok,
		" salvo_wait=", salvo_wait, " unpowered_shot_damage=", hp_before - tank.hp)
	await RenderingServer.frame_post_draw
	var firing := root.get_texture().get_image()
	print("capture: ", OUT_FIRING, " err=", firing.save_png(ProjectSettings.globalize_path(OUT_FIRING)))

	var impact_wait := 0.0
	while tank.hp >= tank.max_hp and impact_wait < 2.0:
		await create_timer(0.04).timeout
		impact_wait += 0.04
	var first_hit_damage: float = tank.max_hp - tank.hp
	await create_timer(0.04).timeout
	print("ROCKET impact_wait=", impact_wait, " first_hit_damage=", first_hit_damage,
		" impacts=", scene.fx.impacts.size())
	await RenderingServer.frame_post_draw
	var impact := root.get_texture().get_image()
	print("capture: ", OUT_IMPACT, " err=", impact.save_png(ProjectSettings.globalize_path(OUT_IMPACT)))

	await create_timer(1.0).timeout
	var total_damage: float = tank.max_hp - tank.hp
	print("ROCKET result tank_hp=", tank.hp, " support_hp=", support.hp,
		" far_hp=", far.hp, " tank_damage=", total_damage,
		" support_damage=", support.max_hp - support.hp,
		" far_damage=", far.max_hp - far.hp,
		" damage_ok=", is_equal_approx(total_damage, 26.0))
	quit()
