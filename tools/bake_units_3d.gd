extends Node

## Sandwar 3D-to-2D unit baker.
##
## Run windowed (GPU required):
##
##   ~/.local/bin/godot --path . tools/bake_units_3d.tscn
##
## This reuses the building baker's orthographic 3/4 camera, fixed NW light,
## warm fill and procedural materials. The camera and lights never rotate:
## every frame rotates the unit root around Y so all facings are true 3D
## renders. A soft contact shadow is baked into every hull frame.
##
## Outputs:
##   assets/sprites/units/infantry.png       8 rows x 4 poses
##   assets/sprites/units/rocket.png          8 rows x 4 poses
##   assets/sprites/units/trike.png           16 directions
##   assets/sprites/units/quad.png            16 directions
##   assets/sprites/units/tank_hull.png       16 directions
##   assets/sprites/units/tank_turret.png     16 directions
##   assets/sprites/units/harvester_*.png     3 fill levels x 16 directions
##   assets/icons/units/*_icon.png            64 px hero icons

const OUT_DIR := "res://assets/sprites/units"
const ICON_DIR := "res://assets/icons/units"
const PREVIEW_PATH := "res://build/units3d_preview.png"
const RENDER_SCALE := 2
const VEHICLE_FRAMES := 16
const INFANTRY_DIRS := 8
const INFANTRY_FRAMES := 4
const ICON_PX := 64

var viewport: SubViewport
var camera: Camera3D
var stage: Node3D
var assembly: Node3D
var mats: Dictionary = {}
var _shadow_tex: Texture2D

func _ready() -> void:
	_build_renderer()
	await _bake_all()
	get_tree().quit()

# --------------------------------------------------------------- renderer

func _build_renderer() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(256, 256)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	add_child(viewport)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.34, 0.29, 0.23)
	environment.ambient_light_energy = 0.32
	env.environment = environment
	viewport.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -38.0, 0.0)
	sun.light_color = Color(1.0, 0.90, 0.73)
	sun.light_energy = 1.45
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	viewport.add_child(sun)

	var fill := OmniLight3D.new()
	fill.position = Vector3(-3.0, 4.0, 3.0)
	fill.light_color = Color(0.95, 0.55, 0.28)
	fill.light_energy = 0.55
	fill.omni_range = 13.0
	fill.shadow_enabled = false
	viewport.add_child(fill)

	stage = Node3D.new()
	viewport.add_child(stage)

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	viewport.add_child(camera)

	mats = {
		"trim": make_material(Color(0.82, 0.07, 0.61), 0.52, 0.32, 51, 0.20),
		"steel": make_material(Color(0.38, 0.43, 0.44), 0.50, 0.62, 111, 0.38),
		"steel_light": make_material(Color(0.62, 0.67, 0.66), 0.40, 0.55, 112, 0.34),
		"gunmetal": make_material(Color(0.15, 0.18, 0.19), 0.48, 0.72, 113, 0.46),
		"olive": make_material(Color(0.42, 0.47, 0.47), 0.72, 0.36, 114, 0.44),
		"olive_light": make_material(Color(0.57, 0.62, 0.60), 0.62, 0.34, 115, 0.38),
		"unit_armor": make_material(Color(0.55, 0.61, 0.61), 0.56, 0.46, 126, 0.38),
		"unit_highlight": make_material(Color(0.75, 0.79, 0.75), 0.46, 0.38, 127, 0.30),
		"rubber": make_material(Color(0.075, 0.075, 0.065), 0.98, 0.02, 116, 0.30),
		"rust": make_material(Color(0.38, 0.17, 0.08), 0.88, 0.20, 117, 0.58),
		"dark": make_material(Color(0.055, 0.055, 0.05), 0.86, 0.18, 118, 0.26),
		"glass": make_material(Color(0.025, 0.12, 0.13), 0.20, 0.35, 119, 0.12, Color(0.03, 0.34, 0.30)),
		"skin": make_material(Color(0.48, 0.31, 0.20), 0.92, 0.02, 120, 0.22),
		"yellow": make_material(Color(0.92, 0.58, 0.08), 0.60, 0.24, 121, 0.34),
		"cyan": make_material(Color(0.03, 0.68, 0.60), 0.34, 0.12, 122, 0.18, Color(0.04, 0.82, 0.62)),
		"amber": make_material(Color(0.95, 0.42, 0.08), 0.34, 0.20, 123, 0.18, Color(1.0, 0.27, 0.04)),
		"spice": make_material(Color(0.92, 0.34, 0.035), 0.58, 0.12, 124, 0.26, Color(0.95, 0.20, 0.02)),
		"white": make_material(Color(0.86, 0.83, 0.72), 0.72, 0.08, 125, 0.24),
	}
	_shadow_tex = _make_shadow_texture()
	var shadow_mat := StandardMaterial3D.new()
	shadow_mat.albedo_texture = _shadow_tex
	shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	shadow_mat.no_depth_test = false
	mats["shadow"] = shadow_mat

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ICON_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))

func make_material(base: Color, roughness: float, metallic: float, seed_value: int, bump: float, emission := Color.TRANSPARENT) -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.065
	noise.fractal_octaves = 4
	var albedo := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	var normal := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in 256:
		for x in 256:
			var n := noise.get_noise_2d(float(x), float(y))
			var grain := 0.80 + 0.28 * (n * 0.5 + 0.5)
			var streak := 0.93 + 0.10 * noise.get_noise_2d(float(x) * 0.35, float(y) * 3.0)
			albedo.set_pixel(x, y, Color(base.r * grain * streak, base.g * grain * streak, base.b * grain * streak, 1.0))
			var nx := noise.get_noise_2d(float(x + 1), float(y)) - n
			var ny := noise.get_noise_2d(float(x), float(y + 1)) - n
			var nv := Vector3(-nx * bump * 6.0, -ny * bump * 6.0, 1.0).normalized()
			normal.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5, 1.0))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(albedo)
	mat.normal_enabled = true
	mat.normal_texture = ImageTexture.create_from_image(normal)
	mat.normal_scale = bump
	mat.roughness = roughness
	mat.metallic = metallic
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(3.2, 3.2, 3.2)
	if emission.a > 0.0:
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = 1.7
	return mat

func _make_shadow_texture() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(float(x) - 31.5, float(y) - 31.5).length() / 31.5
			var a := pow(clampf(1.0 - d, 0.0, 1.0), 1.55) * 0.48
			img.set_pixel(x, y, Color(0.02, 0.015, 0.012, a))
	return ImageTexture.create_from_image(img)

# --------------------------------------------------------------- primitives

func make_box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> CSGBox3D:
	var node := CSGBox3D.new()
	node.size = size
	node.position = pos
	node.rotation_degrees = rot
	node.material = mat
	node.use_collision = false
	parent.add_child(node)
	return node

func make_cyl(parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material, rot := Vector3.ZERO, sides := 16) -> CSGCylinder3D:
	var node := CSGCylinder3D.new()
	node.radius = radius
	node.height = height
	node.position = pos
	node.rotation_degrees = rot
	node.sides = sides
	node.material = mat
	node.use_collision = false
	parent.add_child(node)
	return node

func make_sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material, height_scale := 1.0) -> CSGSphere3D:
	var node := CSGSphere3D.new()
	node.radius = radius
	node.position = pos
	node.material = mat
	node.use_collision = false
	node.radial_segments = 16
	node.rings = 8
	node.scale = Vector3(1.0, height_scale, 1.0)
	parent.add_child(node)
	return node

func add_shadow(root: Node3D, width: float, length: float) -> void:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(width, length)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = Vector3(0.0, 0.014, 0.0)
	node.material_override = mats["shadow"]
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(node)

func wheel(root: Node3D, x: float, z: float, radius: float, width: float) -> void:
	make_cyl(root, radius, width, Vector3(x, radius, z), mats["rubber"], Vector3(90.0, 0.0, 0.0), 18)
	make_cyl(root, radius * 0.42, width + 0.012, Vector3(x, radius, z), mats["steel_light"], Vector3(90.0, 0.0, 0.0), 12)

func track_side(root: Node3D, side: float, x0: float, x1: float, radius: float) -> void:
	var z: float = side * 0.39
	make_box(root, Vector3(absf(x1 - x0) + 0.10, 0.15, 0.16), Vector3((x0 + x1) * 0.5, radius, z), mats["rubber"])
	for i in 6:
		var t := float(i) / 5.0
		make_box(root, Vector3(0.12, 0.045, 0.18), Vector3(lerpf(x0, x1, t), radius * 2.0, z), mats["gunmetal"])
	for i in 4:
		wheel(root, lerpf(x0, x1, float(i) / 3.0), z, radius, 0.16)

# --------------------------------------------------------------- infantry

func build_infantry(id: String, facing: float, anim: int) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 0.72, 0.72)
	var heavy := id == "rocket"
	var stride := 0.0
	if anim == 1:
		stride = 0.09
	elif anim == 2:
		stride = -0.09
	var recoil := 0.045 if anim == 3 else 0.0
	var body: Material = mats["unit_armor"]
	# Boots and legs. The legs stay deliberately short and wide so the
	# silhouettes read at 36 px.
	for side in PackedFloat32Array([-1.0, 1.0]):
		var s: float = stride * side
		make_box(root, Vector3(0.13, 0.23, 0.13), Vector3(s, 0.13, side * 0.105), mats["steel"], Vector3(0.0, 0.0, side * 4.0))
		make_box(root, Vector3(0.16, 0.09, 0.14), Vector3(s + 0.035, 0.035, side * 0.105), mats["rubber"])
		make_box(root, Vector3(0.11, 0.10, 0.11), Vector3(s, 0.27, side * 0.105), body)
	# Torso, chest plate, belt and pelvis.
	make_box(root, Vector3(0.32, 0.36, 0.30), Vector3(0.0, 0.48, 0.0), body)
	make_box(root, Vector3(0.21, 0.23, 0.31), Vector3(0.10, 0.50, 0.0), mats["unit_highlight"])
	make_box(root, Vector3(0.27, 0.075, 0.31), Vector3(0.015, 0.33, 0.0), mats["gunmetal"])
	make_box(root, Vector3(0.055, 0.06, 0.26), Vector3(0.06, 0.68, 0.0), mats["trim"])
	# Backpack power cell and its little cable.
	make_box(root, Vector3(0.18, 0.27, 0.24), Vector3(-0.20, 0.52, 0.0), mats["gunmetal"])
	make_box(root, Vector3(0.07, 0.15, 0.08), Vector3(-0.225, 0.56, 0.11), mats["cyan"])
	make_cyl(root, 0.018, 0.22, Vector3(-0.11, 0.44, -0.12), mats["rust"], Vector3(0.0, 0.0, 90.0), 8)
	# Head and helmet.
	make_sphere(root, 0.105, Vector3(0.015, 0.79, 0.0), mats["skin"], 1.1)
	make_box(root, Vector3(0.19, 0.11, 0.19), Vector3(0.0, 0.885, 0.0), mats["unit_armor"])
	make_box(root, Vector3(0.10, 0.075, 0.20), Vector3(0.085, 0.84, 0.0), mats["glass"])
	make_box(root, Vector3(0.04, 0.035, 0.18), Vector3(0.155, 0.845, 0.0), mats["unit_highlight"])
	# Shoulder pads with small house-colour caps.
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.21, 0.11, 0.13), Vector3(0.02, 0.65, side * 0.21), mats["unit_highlight"])
		make_box(root, Vector3(0.17, 0.035, 0.12), Vector3(0.03, 0.71, side * 0.21), mats["trim"])
	# Arms and weapon.
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.16, 0.10, 0.10), Vector3(0.10 - recoil, 0.51, side * 0.20), body,
			Vector3(0.0, 0.0, side * 10.0))
	if heavy:
		# Reinforced chest rig and twin shoulder tubes.
		make_box(root, Vector3(0.18, 0.09, 0.33), Vector3(0.12, 0.59, 0.0), mats["steel"])
		for side in [-1.0, 1.0]:
			make_cyl(root, 0.065, 0.52, Vector3(0.31 - recoil, 0.70, side * 0.13),
				mats["gunmetal"], Vector3(0.0, 0.0, 90.0), 14)
			make_cyl(root, 0.080, 0.08, Vector3(0.58 - recoil, 0.70, side * 0.13),
				mats["rust"], Vector3(0.0, 0.0, 90.0), 14)
			make_cyl(root, 0.050, 0.06, Vector3(0.64 - recoil, 0.70, side * 0.13),
				mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
			make_box(root, Vector3(0.09, 0.08, 0.11), Vector3(-0.01, 0.59, side * 0.21), mats["trim"])
		make_cyl(root, 0.028, 0.18, Vector3(-0.27, 0.34, 0.0), mats["amber"], Vector3.ZERO, 8)
	else:
		# Chunky assault rifle held across the chest, with a box magazine.
		make_box(root, Vector3(0.54, 0.06, 0.07), Vector3(0.40 - recoil, 0.54, 0.15), mats["gunmetal"])
		make_box(root, Vector3(0.16, 0.12, 0.06), Vector3(0.18 - recoil, 0.53, 0.15), mats["steel"])
		make_box(root, Vector3(0.10, 0.10, 0.08), Vector3(0.31 - recoil, 0.47, 0.15), mats["rust"])
		make_cyl(root, 0.020, 0.12, Vector3(0.73 - recoil, 0.54, 0.15), mats["dark"], Vector3(0.0, 0.0, 90.0), 10)
		if anim == 3:
			make_sphere(root, 0.055, Vector3(0.79 - recoil, 0.54, 0.15), mats["amber"])
	return root

# --------------------------------------------------------------- vehicles

func build_trike(facing: float) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 0.95, 0.70)
	# Oversized knobby rear pair and single front wheel.
	wheel(root, -0.24, -0.40, 0.21, 0.15)
	wheel(root, -0.24, 0.40, 0.21, 0.15)
	wheel(root, 0.43, 0.0, 0.20, 0.15)
	# Low welded tub and armoured nose.
	make_box(root, Vector3(0.72, 0.16, 0.48), Vector3(-0.04, 0.30, 0.0), mats["olive"])
	make_box(root, Vector3(0.42, 0.11, 0.42), Vector3(-0.15, 0.42, 0.0), mats["olive_light"])
	make_box(root, Vector3(0.32, 0.16, 0.34), Vector3(0.40, 0.33, 0.0), mats["steel"])
	make_box(root, Vector3(0.14, 0.035, 0.16), Vector3(0.53, 0.39, 0.0), mats["trim"])
	make_box(root, Vector3(0.08, 0.12, 0.38), Vector3(0.52, 0.25, 0.0), mats["rust"])
	# Exposed roll cage.
	for x in [-0.28, 0.18]:
		for z in [-0.20, 0.20]:
			make_box(root, Vector3(0.045, 0.56, 0.045), Vector3(x, 0.59, z), mats["steel_light"])
	make_box(root, Vector3(0.55, 0.045, 0.045), Vector3(-0.05, 0.87, -0.20), mats["steel_light"])
	make_box(root, Vector3(0.55, 0.045, 0.045), Vector3(-0.05, 0.87, 0.20), mats["steel_light"])
	make_box(root, Vector3(0.045, 0.045, 0.44), Vector3(0.20, 0.87, 0.0), mats["steel_light"])
	# Rear engine pack and exhausts.
	make_box(root, Vector3(0.24, 0.18, 0.40), Vector3(-0.33, 0.43, 0.0), mats["gunmetal"])
	for z in [-0.14, 0.14]:
		make_cyl(root, 0.045, 0.32, Vector3(-0.47, 0.48, z), mats["rust"], Vector3(0.0, 0.0, 90.0), 10)
	# Roof LMG.
	make_box(root, Vector3(0.20, 0.08, 0.12), Vector3(0.02, 0.88, 0.0), mats["gunmetal"])
	make_cyl(root, 0.024, 0.42, Vector3(0.28, 0.91, 0.0), mats["dark"], Vector3(0.0, 0.0, 90.0), 10)
	make_cyl(root, 0.042, 0.08, Vector3(0.48, 0.91, 0.0), mats["steel_light"], Vector3(0.0, 0.0, 90.0), 10)
	return root

func build_quad(facing: float) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 1.02, 0.80)
	for x in [-0.32, 0.32]:
		for z in [-0.40, 0.40]:
			wheel(root, x, z, 0.20, 0.14)
	# Welded sloped hull with a distinct front glacis.
	make_box(root, Vector3(0.82, 0.20, 0.62), Vector3(0.0, 0.28, 0.0), mats["olive"])
	make_box(root, Vector3(0.56, 0.13, 0.52), Vector3(0.10, 0.42, 0.0), mats["olive_light"])
	make_box(root, Vector3(0.28, 0.15, 0.54), Vector3(0.48, 0.35, 0.0), mats["steel"])
	make_box(root, Vector3(0.13, 0.035, 0.30), Vector3(0.56, 0.44, 0.0), mats["trim"])
	make_box(root, Vector3(0.28, 0.17, 0.54), Vector3(-0.40, 0.42, 0.0), mats["gunmetal"])
	for z in [-0.18, 0.18]:
		make_box(root, Vector3(0.04, 0.12, 0.035), Vector3(-0.50, 0.42, z), mats["rubber"])
	# Rear vents.
	for i in 3:
		make_box(root, Vector3(0.035, 0.10, 0.40), Vector3(-0.30 + float(i) * 0.06, 0.50, 0.0), mats["dark"])
	# Twin autocannons, one per side of the turret cheek.
	make_box(root, Vector3(0.22, 0.17, 0.30), Vector3(0.16, 0.55, 0.0), mats["gunmetal"])
	for z in [-0.10, 0.10]:
		make_cyl(root, 0.035, 0.56, Vector3(0.54, 0.57, z), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
		make_cyl(root, 0.052, 0.10, Vector3(0.78, 0.57, z), mats["steel_light"], Vector3(0.0, 0.0, 90.0), 10)
	make_box(root, Vector3(0.10, 0.07, 0.20), Vector3(0.20, 0.67, 0.0), mats["trim"])
	return root

func build_tank_hull(facing: float, with_shadow := true) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	if with_shadow:
		add_shadow(root, 1.30, 1.00)
	# Wide tracks and bolted skirts.
	track_side(root, -1.0, -0.48, 0.48, 0.19)
	track_side(root, 1.0, -0.48, 0.48, 0.19)
	make_box(root, Vector3(1.02, 0.18, 0.72), Vector3(0.0, 0.36, 0.0), mats["olive"])
	make_box(root, Vector3(0.88, 0.13, 0.58), Vector3(0.02, 0.50, 0.0), mats["olive_light"])
	make_box(root, Vector3(0.34, 0.20, 0.66), Vector3(0.43, 0.44, 0.0), mats["steel"], Vector3(0.0, 0.0, -8.0))
	make_box(root, Vector3(0.88, 0.20, 0.085), Vector3(0.0, 0.32, -0.39), mats["steel"])
	make_box(root, Vector3(0.88, 0.20, 0.085), Vector3(0.0, 0.32, 0.39), mats["steel"])
	for i in 4:
		for side in [-1.0, 1.0]:
			make_box(root, Vector3(0.035, 0.035, 0.065), Vector3(-0.34 + float(i) * 0.22, 0.31, side * 0.435), mats["trim"])
	# Rear engine deck, grills and exhaust stacks.
	make_box(root, Vector3(0.40, 0.20, 0.66), Vector3(-0.44, 0.47, 0.0), mats["gunmetal"])
	for i in 4:
		make_box(root, Vector3(0.035, 0.10, 0.52), Vector3(-0.55 + float(i) * 0.075, 0.54, 0.0), mats["dark"])
	for z in [-0.24, 0.24]:
		make_cyl(root, 0.040, 0.28, Vector3(-0.58, 0.64, z), mats["rust"], Vector3(0.0, 0.0, 90.0), 10)
	# Small house stripe on the front fender.
	make_box(root, Vector3(0.26, 0.035, 0.12), Vector3(0.46, 0.56, -0.27), mats["trim"])
	make_box(root, Vector3(0.26, 0.035, 0.12), Vector3(0.46, 0.56, 0.27), mats["trim"])
	return root

func build_tank_turret(facing: float) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	# Angular cast turret and long cannon. This strip is drawn above the hull
	# strip at runtime, so it must not bake its own shadow.
	make_box(root, Vector3(0.40, 0.22, 0.42), Vector3(-0.02, 0.76, 0.0), mats["steel"])
	make_box(root, Vector3(0.28, 0.20, 0.34), Vector3(0.20, 0.79, 0.0), mats["steel_light"], Vector3(0.0, 0.0, -8.0))
	make_box(root, Vector3(0.15, 0.035, 0.28), Vector3(-0.09, 0.895, 0.0), mats["trim"])
	make_cyl(root, 0.065, 0.92, Vector3(0.64, 0.80, 0.0), mats["gunmetal"], Vector3(0.0, 0.0, 90.0), 14)
	make_cyl(root, 0.105, 0.16, Vector3(1.12, 0.80, 0.0), mats["rust"], Vector3(0.0, 0.0, 90.0), 12)
	make_cyl(root, 0.085, 0.07, Vector3(1.22, 0.80, 0.0), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
	make_cyl(root, 0.085, 0.075, Vector3(-0.06, 0.90, 0.0), mats["steel_light"], Vector3.ZERO, 12)
	make_cyl(root, 0.030, 0.20, Vector3(-0.22, 0.92, -0.16), mats["gunmetal"], Vector3.ZERO, 8)
	make_box(root, Vector3(0.18, 0.035, 0.08), Vector3(0.05, 0.92, 0.20), mats["trim"])
	return root

func build_tank(facing: float) -> Node3D:
	var root := build_tank_hull(facing)
	var turret := build_tank_turret(facing)
	root.add_child(turret)
	return root

func build_harvester(facing: float, fill: float) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 1.50, 1.08)
	track_side(root, -1.0, -0.56, 0.54, 0.20)
	track_side(root, 1.0, -0.56, 0.54, 0.20)
	# Main industrial chassis and front cab.
	make_box(root, Vector3(1.12, 0.24, 0.82), Vector3(0.0, 0.36, 0.0), mats["olive"])
	make_box(root, Vector3(0.50, 0.38, 0.62), Vector3(0.42, 0.58, 0.0), mats["olive_light"])
	make_box(root, Vector3(0.32, 0.20, 0.50), Vector3(0.55, 0.69, 0.0), mats["glass"])
	make_box(root, Vector3(0.05, 0.36, 0.64), Vector3(0.69, 0.58, 0.0), mats["steel"])
	make_box(root, Vector3(0.07, 0.05, 0.26), Vector3(0.48, 0.88, 0.0), mats["trim"])
	# Open dorsal hopper with a visible fill level and grate bars.
	make_box(root, Vector3(0.58, 0.30, 0.66), Vector3(-0.30, 0.62, 0.0), mats["gunmetal"])
	make_box(root, Vector3(0.48, 0.22, 0.54), Vector3(-0.30, 0.70, 0.0), mats["dark"])
	var fill_h := 0.035 if fill <= 0.05 else (0.12 if fill < 0.62 else 0.22)
	make_box(root, Vector3(0.42, fill_h, 0.48), Vector3(-0.30, 0.60 + fill_h * 0.5, 0.0), mats["spice"])
	for i in 3:
		make_box(root, Vector3(0.52, 0.025, 0.035), Vector3(-0.30, 0.84, -0.20 + float(i) * 0.20), mats["steel_light"])
	make_box(root, Vector3(0.58, 0.035, 0.045), Vector3(-0.30, 0.86, -0.20), mats["trim"])
	make_box(root, Vector3(0.58, 0.035, 0.045), Vector3(-0.30, 0.86, 0.20), mats["trim"])
	# Spice-stained outer panels make the load state legible even at 62 px.
	for z in [-0.34, 0.34]:
		make_box(root, Vector3(0.44, 0.13, 0.018), Vector3(-0.30, 0.68, z), mats["rust"])
		if fill > 0.05:
			make_box(root, Vector3(0.34, 0.065, 0.022), Vector3(-0.30, 0.72, z), mats["spice"])
	if fill > 0.05:
		make_box(root, Vector3(0.36, 0.012, 0.40), Vector3(-0.30, 0.835, 0.0), mats["spice"])
	# Twin exhaust stacks.
	for z in [-0.23, 0.23]:
		make_cyl(root, 0.052, 0.48, Vector3(-0.56, 0.80, z), mats["rust"], Vector3.ZERO, 10)
		make_cyl(root, 0.075, 0.07, Vector3(-0.56, 1.05, z), mats["dark"], Vector3.ZERO, 10)
	# Front intake scoop, hazard stripes and cutter teeth.
	make_box(root, Vector3(0.28, 0.15, 0.76), Vector3(0.72, 0.20, 0.0), mats["steel"], Vector3(0.0, 0.0, -14.0))
	make_box(root, Vector3(0.24, 0.035, 0.74), Vector3(0.74, 0.29, 0.0), mats["yellow"])
	for i in 5:
		make_box(root, Vector3(0.10, 0.07, 0.075), Vector3(0.88, 0.12, -0.28 + float(i) * 0.14),
			mats["steel_light"], Vector3(0.0, 0.0, -20.0))
	make_box(root, Vector3(0.38, 0.035, 0.15), Vector3(0.35, 0.49, -0.38), mats["trim"])
	make_box(root, Vector3(0.38, 0.035, 0.15), Vector3(0.35, 0.49, 0.38), mats["trim"])
	return root

# --------------------------------------------------------------- baking

func _bake_all() -> void:
	await _bake_infantry("infantry")
	await _bake_infantry("rocket")
	await _bake_vehicle("trike", 48)
	await _bake_vehicle("quad", 50)
	await _bake_tank()
	await _bake_harvester()
	await _bake_icons()
	print("UNIT BAKE COMPLETE: ", ProjectSettings.globalize_path(OUT_DIR))

func _render(cell: float, view_size := 2.05) -> Image:
	viewport.size = Vector2i(int(cell) * RENDER_SCALE, int(cell) * RENDER_SCALE)
	camera.size = view_size
	var target := Vector3(0.0, 0.52, 0.0)
	camera.look_at_from_position(target + Vector3(6.7, 7.7, 9.3), target, Vector3.UP)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	# Keep the 2x supersampled cell. UnitArt selects source regions at 2x and
	# the game downsamples them to the logical world cell, matching the building
	# sheets and the crisp 2x phone zoom.
	return viewport.get_texture().get_image()

func _replace_assembly(root: Node3D) -> void:
	if assembly != null:
		assembly.queue_free()
		await get_tree().process_frame
	assembly = root
	stage.add_child(assembly)

func _bake_infantry(id: String) -> void:
	var cell := 36.0 if id == "infantry" else 38.0
	var px := int(cell) * RENDER_SCALE
	var sheet := Image.create(px * INFANTRY_FRAMES, px * INFANTRY_DIRS, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for dir in INFANTRY_DIRS:
		var angle := TAU * float(dir) / float(INFANTRY_DIRS)
		for anim in INFANTRY_FRAMES:
			await _replace_assembly(build_infantry(id, angle, anim))
			var img := await _render(cell, 1.65)
			sheet.blit_rect(img, Rect2i(0, 0, px, px), Vector2i(anim * px, dir * px))
	var path := "%s/%s.png" % [OUT_DIR, id]
	sheet.save_png(ProjectSettings.globalize_path(path))
	print("UNIT BAKED %-12s sheet=%dx%d cell=%d dirs=%d poses=%d" % [id, sheet.get_width(), sheet.get_height(), px, INFANTRY_DIRS, INFANTRY_FRAMES])

func _bake_vehicle(id: String, cell: int) -> void:
	var px := cell * RENDER_SCALE
	var sheet := Image.create(px * VEHICLE_FRAMES, px, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for i in VEHICLE_FRAMES:
		var angle := TAU * float(i) / float(VEHICLE_FRAMES)
		var root: Node3D
		if id == "trike":
			root = build_trike(angle)
		else:
			root = build_quad(angle)
		await _replace_assembly(root)
		var img := await _render(float(cell))
		sheet.blit_rect(img, Rect2i(0, 0, px, px), Vector2i(i * px, 0))
	var path := "%s/%s.png" % [OUT_DIR, id]
	sheet.save_png(ProjectSettings.globalize_path(path))
	print("UNIT BAKED %-12s sheet=%dx%d cell=%d dirs=%d" % [id, sheet.get_width(), sheet.get_height(), px, VEHICLE_FRAMES])

func _bake_tank() -> void:
	var cell := 60
	var px := cell * RENDER_SCALE
	var hull_sheet := Image.create(px * VEHICLE_FRAMES, px, false, Image.FORMAT_RGBA8)
	var turret_sheet := Image.create(px * VEHICLE_FRAMES, px, false, Image.FORMAT_RGBA8)
	hull_sheet.fill(Color(0, 0, 0, 0))
	turret_sheet.fill(Color(0, 0, 0, 0))
	for i in VEHICLE_FRAMES:
		var angle := TAU * float(i) / float(VEHICLE_FRAMES)
		await _replace_assembly(build_tank_hull(angle))
		var hull := await _render(float(cell), 2.15)
		hull_sheet.blit_rect(hull, Rect2i(0, 0, px, px), Vector2i(i * px, 0))
		await _replace_assembly(build_tank_turret(angle))
		var turret := await _render(float(cell), 2.15)
		turret_sheet.blit_rect(turret, Rect2i(0, 0, px, px), Vector2i(i * px, 0))
	hull_sheet.save_png(ProjectSettings.globalize_path("%s/tank_hull.png" % OUT_DIR))
	turret_sheet.save_png(ProjectSettings.globalize_path("%s/tank_turret.png" % OUT_DIR))
	print("UNIT BAKED tank_hull   sheet=%dx%d cell=%d dirs=%d" % [hull_sheet.get_width(), hull_sheet.get_height(), px, VEHICLE_FRAMES])
	print("UNIT BAKED tank_turret sheet=%dx%d cell=%d dirs=%d" % [turret_sheet.get_width(), turret_sheet.get_height(), px, VEHICLE_FRAMES])

func _bake_harvester() -> void:
	var cell := 62
	var px := cell * RENDER_SCALE
	for level in [["empty", 0.0], ["half", 0.5], ["full", 1.0]]:
		var sheet := Image.create(px * VEHICLE_FRAMES, px, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0, 0, 0, 0))
		for i in VEHICLE_FRAMES:
			var angle := TAU * float(i) / float(VEHICLE_FRAMES)
			await _replace_assembly(build_harvester(angle, float(level[1])))
			var img := await _render(float(cell), 2.25)
			sheet.blit_rect(img, Rect2i(0, 0, px, px), Vector2i(i * px, 0))
		var path := "%s/harvester_%s.png" % [OUT_DIR, String(level[0])]
		sheet.save_png(ProjectSettings.globalize_path(path))
		print("UNIT BAKED harvester_%-5s sheet=%dx%d cell=%d dirs=%d" % [String(level[0]), sheet.get_width(), sheet.get_height(), px, VEHICLE_FRAMES])

func _bake_icons() -> void:
	var tiles: Array[Image] = []
	for id in ["infantry", "rocket", "trike", "quad", "tank", "harvester"]:
		var cell := 128.0
		await _replace_assembly(_icon_model(id))
		viewport.size = Vector2i(192, 192)
		camera.size = 1.25 if id in ["infantry", "rocket"] else 1.55
		var target := Vector3(0.0, 0.55, 0.0)
		camera.look_at_from_position(target + Vector3(6.7, 7.7, 9.3), target, Vector3.UP)
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var raw := viewport.get_texture().get_image()
		var icon := _make_unit_icon(raw, id)
		icon.save_png(ProjectSettings.globalize_path("%s/%s_icon.png" % [ICON_DIR, id]))
		tiles.append(icon)
		print("UNIT BAKED %-12s icon=%dx%d" % [id, icon.get_width(), icon.get_height()])
	_make_preview(tiles)

func _icon_model(id: String) -> Node3D:
	# 0 radians looks down-right on this southeast-facing 3/4 camera, which is
	# the requested southeast hero angle.
	var angle := 0.0
	match id:
		"infantry", "rocket":
			return build_infantry(id, angle, 0)
		"trike":
			return build_trike(angle)
		"quad":
			return build_quad(angle)
		"tank":
			return build_tank(angle)
	return build_harvester(angle, 1.0)

func _make_unit_icon(raw: Image, _id: String) -> Image:
	var used := raw.get_used_rect()
	if used.size.x <= 1 or used.size.y <= 1:
		used = Rect2i(0, 0, raw.get_width(), raw.get_height())
	var crop := raw.get_region(used)
	var max_side := 60.0
	var scale := minf(max_side / float(crop.get_width()), max_side / float(crop.get_height()))
	var w := maxi(int(round(float(crop.get_width()) * scale)), 1)
	var h := maxi(int(round(float(crop.get_height()) * scale)), 1)
	crop.resize(w, h, Image.INTERPOLATE_LANCZOS)
	var bg := Image.create(ICON_PX, ICON_PX, false, Image.FORMAT_RGBA8)
	bg.fill(Color(0, 0, 0, 0))
	# Faint cold halo; the recessed slot behind is drawn by the HUD.
	for y in ICON_PX:
		for x in ICON_PX:
			var dx := (float(x) - 31.5) / 31.0
			var dy := (float(y) - 32.0) / 31.0
			var glow := clampf(1.0 - sqrt(dx * dx + dy * dy * 1.25), 0.0, 1.0)
			if glow > 0.0:
				bg.set_pixel(x, y, Color(0.10, 0.18, 0.23, glow * 0.20))
	bg.blend_rect(crop, Rect2i(0, 0, w, h), Vector2i((ICON_PX - w) / 2, (ICON_PX - h) / 2 - 1))
	# HUD portraits bypass the unit shader, so convert the magenta house trim
	# to the royal Atreides blue directly.
	for y in ICON_PX:
		for x in ICON_PX:
			var c := bg.get_pixel(x, y)
			if c.a <= 0.04:
				continue
			if c.r > c.g * 1.22 and c.b > c.g * 1.08 and c.r > 0.07:
				var k := clampf(0.42 + c.get_luminance() * 1.65, 0.34, 1.18)
				bg.set_pixel(x, y, Color(0.24 * k, 0.46 * k, 0.93 * k, c.a))
	return bg

func _make_icon_backdrop() -> Image:
	var img := Image.create(ICON_PX, ICON_PX, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 909
	noise.frequency = 0.11
	for y in ICON_PX:
		for x in ICON_PX:
			var edge := minf(minf(float(x), float(ICON_PX - 1 - x)), minf(float(y), float(ICON_PX - 1 - y)))
			var n := noise.get_noise_2d(float(x), float(y))
			var shade := 0.035 + 0.018 * (n * 0.5 + 0.5)
			var glow := clampf(1.0 - Vector2(float(x) - 31.5, float(y) - 30.0).length() / 38.0, 0.0, 1.0)
			if x % 16 == 0 or y == 48:
				shade += 0.018
			if edge < 2.0:
				shade += 0.075
			var alpha := 1.0
			if edge < 1.0:
				alpha = 0.0
			img.set_pixel(x, y, Color(shade + glow * 0.012, shade * 1.16 + glow * 0.026, shade * 1.34 + glow * 0.044, alpha))
	# Muted brass corner brackets tie unit portraits to the bronze sidebar.
	for k in range(3, 13):
		img.set_pixel(2, k, Color(0.72, 0.54, 0.24, 0.95))
		img.set_pixel(ICON_PX - 3, k, Color(0.72, 0.54, 0.24, 0.95))
		img.set_pixel(k, 2, Color(0.72, 0.54, 0.24, 0.95))
		img.set_pixel(ICON_PX - 1 - k, 2, Color(0.72, 0.54, 0.24, 0.95))
	return img


func _make_preview(tiles: Array[Image]) -> void:
	var cols := 3
	var rows := int(ceil(float(tiles.size()) / float(cols)))
	var preview := Image.create(cols * ICON_PX, rows * ICON_PX, false, Image.FORMAT_RGBA8)
	preview.fill(Color(0.08, 0.06, 0.04, 1.0))
	for i in tiles.size():
		preview.blit_rect(tiles[i], Rect2i(0, 0, ICON_PX, ICON_PX),
			Vector2i((i % cols) * ICON_PX, (i / cols) * ICON_PX))
	preview.save_png(ProjectSettings.globalize_path(PREVIEW_PATH))
