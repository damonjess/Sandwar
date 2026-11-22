extends SceneTree

## Dev harness: boots Sandwar, adds a Wind Trap to the player base for the shot,
## waits for the camera, and saves a PNG of the frame. Run windowed (not headless):
##
##   ~/.local/bin/godot --path . --script res://tools/capture_scene.gd
##
## Output: build/screens/d2-01.png

const OUT := "res://build/screens/d2-01.png"
const OUT_CLOSE := "res://build/screens/d2-02.png"
const OUT_ENEMY := "res://build/screens/d2-03.png"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	for i in 10:
		await process_frame
	# The starting base has no Wind Trap; add one only in this capture scene.
	scene.add_building("windtrap", 0, Vector2i(15, 40))
	scene.focus_home()
	await create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build/screens"))
	var img := root.get_texture().get_image()
	print("capture: ", OUT, " err=", img.save_png(ProjectSettings.globalize_path(OUT)), " size=", img.get_size())

	# Close shot: 2x zoom on the base for inspecting the new building art.
	var cam = scene.camera
	cam.user_zoomed = true
	cam.zoom = Vector2(2.0, 2.0)
	cam.position = Vector2(16.5 * GameDefs.TILE, 40.0 * GameDefs.TILE)
	cam.offset = Vector2(GameHUD.PANEL_WIDTH * 0.5 / 2.0, 0.0)
	await create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	var close := root.get_texture().get_image()
	print("capture: ", OUT_CLOSE, " err=", close.save_png(ProjectSettings.globalize_path(OUT_CLOSE)),
		" size=", close.get_size())

	# Enemy base, shroud lifted and fog visibility cleared for the shot:
	# checks the Harkonnen red remap.
	scene.shroud.visible = false
	scene.set_process(false)  # stop the fog pass from re-hiding unseen enemies
	for b in scene.buildings:
		b.visible = true
	for u in scene.units:
		u.visible = true
	cam.position = Vector2(42.0 * GameDefs.TILE, 12.5 * GameDefs.TILE)
	await create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	var enemy := root.get_texture().get_image()
	print("capture: ", OUT_ENEMY, " err=", enemy.save_png(ProjectSettings.globalize_path(OUT_ENEMY)),
		" size=", enemy.get_size())
	quit()
