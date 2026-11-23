extends Node

## Sandwar 3D-to-2D unit baker.
##
## Run windowed (GPU required):
##
##   ~/.local/bin/godot --path . tools/bake_units_3d.tscn
##   ~/.local/bin/godot --path . tools/bake_units_3d.tscn -- --icons-only
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

## Cell size and camera framing per vehicle. Wider super-heavies get more
## room so their barrels and side armour are not clipped.
const VEHICLE_CELLS := {
	"trike": 48,
	"raider_trike": 48,
	"quad": 50,
	"atreides_tank": 60,
	"harkonnen_tank": 62,
	"ordos_tank": 58,
	"sonic_tank": 62,
	"devastator": 66,
	"deviator": 60,
}
const VEHICLE_VIEW := {
	"trike": 2.05,
	"raider_trike": 2.05,
	"quad": 2.05,
	"atreides_tank": 2.22,
	"harkonnen_tank": 2.30,
	"ordos_tank": 2.16,
	"sonic_tank": 2.32,
	"devastator": 2.50,
	"deviator": 2.20,
}
const FACTION_INFANTRY := ["fremen", "sardaukar", "saboteur"]
const FACTION_VEHICLES := ["raider_trike", "atreides_tank", "harkonnen_tank", "ordos_tank",
	"sonic_tank", "devastator", "deviator"]
const ALL_INFANTRY := ["infantry", "rocket", "fremen", "sardaukar", "saboteur"]
const ALL_ICONS := ["infantry", "rocket", "fremen", "sardaukar", "saboteur", "trike",
	"raider_trike", "quad", "atreides_tank", "harkonnen_tank", "ordos_tank", "sonic_tank",
	"devastator", "deviator", "harvester"]

var viewport: SubViewport
var camera: Camera3D
var stage: Node3D
var assembly: Node3D
var mats: Dictionary = {}
var _shadow_tex: Texture2D
var _environment: Environment
var _sun: DirectionalLight3D
var _fill: OmniLight3D
var _rim: OmniLight3D

func _ready() -> void:
	_build_renderer()
	var args := OS.get_cmdline_user_args()
	if args.has("--icons-only"):
		await _bake_icons()
		print("UNIT ICON BAKE COMPLETE: ", ProjectSettings.globalize_path(ICON_DIR))
	elif args.has("--faction-only"):
		# Re-bake only the House-unique sheets and the shared icon set, so the
		# existing core map sprites stay byte-identical.
		await _bake_factions()
		print("FACTION UNIT BAKE COMPLETE: ", ProjectSettings.globalize_path(OUT_DIR))
	else:
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
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.ambient_light_color = Color(0.34, 0.29, 0.23)
	_environment.ambient_light_energy = 0.32
	env.environment = _environment
	viewport.add_child(env)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-48.0, -38.0, 0.0)
	_sun.light_color = Color(1.0, 0.90, 0.73)
	_sun.light_energy = 1.45
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 40.0
	viewport.add_child(_sun)

	_fill = OmniLight3D.new()
	_fill.position = Vector3(-3.0, 4.0, 3.0)
	_fill.light_color = Color(0.95, 0.55, 0.28)
	_fill.light_energy = 0.55
	_fill.omni_range = 13.0
	_fill.shadow_enabled = false
	viewport.add_child(_fill)

	# Portrait-only rear-right rim. It is off for map-sprite bakes so their
	# existing silhouettes and faction shader output stay byte-identical.
	_rim = OmniLight3D.new()
	_rim.position = Vector3(3.2, 4.6, -3.2)
	_rim.light_color = Color(1.0, 0.84, 0.60)
	_rim.light_energy = 0.0
	_rim.omni_range = 10.0
	_rim.shadow_enabled = false
	viewport.add_child(_rim)

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
		# House-unique kit.
		"cloth": make_material(Color(0.31, 0.30, 0.25), 0.95, 0.02, 128, 0.26),
		"cloth_dark": make_material(Color(0.13, 0.14, 0.12), 0.97, 0.01, 129, 0.22),
		"fremen_suit": make_material(Color(0.18, 0.24, 0.28), 0.84, 0.04, 130, 0.24),
		"sardaukar": make_material(Color(0.28, 0.30, 0.29), 0.46, 0.56, 131, 0.36),
		"gas": make_material(Color(0.10, 0.42, 0.16), 0.42, 0.18, 132, 0.20, Color(0.05, 0.60, 0.16)),
		"sonic": make_material(Color(0.24, 0.40, 0.48), 0.34, 0.62, 133, 0.22, Color(0.10, 0.42, 0.55)),
		"ordos": make_material(Color(0.13, 0.33, 0.19), 0.54, 0.36, 134, 0.30),
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

func _apply_portrait_lighting(on: bool) -> void:
	if on:
		# Key sun is ~40% stronger than the map pass. A warm peach fill from
		# screen-left picks out the near chassis, while the cool-white rim from
		# rear-right traces tyres, roll cages and barrel edges.
		_sun.light_energy = 1.50
		_sun.light_color = Color(1.0, 0.94, 0.82)
		_fill.position = Vector3(-3.4, 3.3, 3.2)
		_fill.light_color = Color(1.0, 0.70, 0.44)
		_fill.light_energy = 0.45
		_fill.omni_range = 14.0
		_rim.light_energy = 0.62
		_environment.ambient_light_color = Color(0.46, 0.39, 0.31)
		_environment.ambient_light_energy = 0.30
	else:
		_sun.light_energy = 1.45
		_sun.light_color = Color(1.0, 0.90, 0.73)
		_fill.position = Vector3(-3.0, 4.0, 3.0)
		_fill.light_color = Color(0.95, 0.55, 0.28)
		_fill.light_energy = 0.55
		_fill.omni_range = 13.0
		_rim.light_energy = 0.0
		_environment.ambient_light_color = Color(0.34, 0.29, 0.23)
		_environment.ambient_light_energy = 0.32


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
	if id == "fremen":
		return build_fremen(facing, anim)
	if id == "sardaukar":
		return build_sardaukar(facing, anim)
	if id == "saboteur":
		return build_saboteur(facing, anim)
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

# ------------------------------------------------ house-unique infantry

func build_fremen(facing: float, anim: int) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 0.76, 0.76)
	var stride := 0.10 if anim == 1 else (-0.10 if anim == 2 else 0.0)
	var recoil := 0.05 if anim == 3 else 0.0
	# Wrapped legs and desert boots under a long robe.
	for side in [-1.0, 1.0]:
		var s: float = stride * side
		make_box(root, Vector3(0.12, 0.26, 0.12), Vector3(s, 0.14, side * 0.10), mats["fremen_suit"])
		make_box(root, Vector3(0.15, 0.08, 0.14), Vector3(s + 0.03, 0.035, side * 0.10), mats["cloth_dark"])
	make_box(root, Vector3(0.30, 0.30, 0.30), Vector3(0.0, 0.30, 0.0), mats["cloth"])
	make_box(root, Vector3(0.10, 0.26, 0.05), Vector3(-0.10, 0.28, 0.155), mats["cloth_dark"])
	make_box(root, Vector3(0.10, 0.26, 0.05), Vector3(0.10, 0.28, 0.155), mats["cloth_dark"])
	# Stillsuit torso with its ribbed catchpocket lines.
	make_box(root, Vector3(0.28, 0.34, 0.26), Vector3(0.0, 0.54, 0.0), mats["fremen_suit"])
	for i in 3:
		make_box(root, Vector3(0.04, 0.22, 0.015), Vector3(-0.07 + float(i) * 0.07, 0.54, 0.134), mats["steel"])
	# Atreides sash and tabard: magenta key, recoloured by the house shader.
	make_box(root, Vector3(0.07, 0.32, 0.02), Vector3(0.09, 0.52, 0.14), mats["trim"], Vector3(0.0, 0.0, -14.0))
	make_box(root, Vector3(0.20, 0.035, 0.02), Vector3(0.0, 0.68, 0.14), mats["trim"])
	# Cloak thrown over the back.
	make_box(root, Vector3(0.06, 0.55, 0.34), Vector3(-0.18, 0.42, 0.0), mats["cloth"], Vector3(0.0, 0.0, 8.0))
	# Arms and gloves.
	make_box(root, Vector3(0.15, 0.10, 0.10), Vector3(0.08 - recoil, 0.55, 0.19), mats["fremen_suit"], Vector3(0.0, 0.0, -10.0))
	make_box(root, Vector3(0.15, 0.10, 0.10), Vector3(0.07 - recoil, 0.58, -0.19), mats["fremen_suit"])
	# Hood, face mask and the blue eye slit.
	make_sphere(root, 0.115, Vector3(0.005, 0.80, 0.0), mats["cloth"], 1.15)
	make_box(root, Vector3(0.20, 0.14, 0.21), Vector3(-0.02, 0.84, 0.0), mats["cloth"])
	make_box(root, Vector3(0.10, 0.10, 0.21), Vector3(0.075, 0.78, 0.0), mats["cloth_dark"])
	make_box(root, Vector3(0.035, 0.03, 0.16), Vector3(0.125, 0.80, 0.0), mats["sonic"])
	# Long-barrelled sniper rifle, scope, bipod and muzzle.
	make_box(root, Vector3(0.85, 0.055, 0.06), Vector3(0.44 - recoil, 0.60, 0.12), mats["gunmetal"])
	make_box(root, Vector3(0.20, 0.10, 0.07), Vector3(0.08 - recoil, 0.57, 0.12), mats["cloth_dark"])
	make_cyl(root, 0.032, 0.30, Vector3(0.35 - recoil, 0.66, 0.12), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
	make_cyl(root, 0.025, 0.14, Vector3(0.86 - recoil, 0.60, 0.12), mats["steel_light"], Vector3(0.0, 0.0, 90.0), 10)
	make_box(root, Vector3(0.05, 0.20, 0.04), Vector3(0.58, 0.50, 0.12), mats["gunmetal"], Vector3(0.0, 0.0, 20.0))
	if anim == 3:
		make_sphere(root, 0.05, Vector3(0.92 - recoil, 0.60, 0.12), mats["amber"])
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.10, 0.10, 0.06), Vector3(-0.05, 0.40, side * 0.16), mats["cloth_dark"])
	return root

func build_sardaukar(facing: float, anim: int) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 0.82, 0.82)
	root.scale = Vector3(1.06, 1.05, 1.06)
	var stride := 0.08 if anim == 1 else (-0.08 if anim == 2 else 0.0)
	var recoil := 0.045 if anim == 3 else 0.0
	for side in [-1.0, 1.0]:
		var s: float = stride * side
		make_box(root, Vector3(0.17, 0.25, 0.17), Vector3(s, 0.13, side * 0.12), mats["gunmetal"])
		make_box(root, Vector3(0.20, 0.10, 0.18), Vector3(s + 0.035, 0.04, side * 0.12), mats["rubber"])
		make_box(root, Vector3(0.14, 0.12, 0.14), Vector3(s, 0.28, side * 0.12), mats["sardaukar"])
	# Broad armoured torso, belt plates and back power pack.
	make_box(root, Vector3(0.40, 0.38, 0.34), Vector3(0.0, 0.49, 0.0), mats["sardaukar"])
	make_box(root, Vector3(0.28, 0.24, 0.35), Vector3(0.10, 0.52, 0.0), mats["unit_highlight"])
	make_box(root, Vector3(0.33, 0.075, 0.35), Vector3(0.015, 0.32, 0.0), mats["gunmetal"])
	for i in 3:
		make_box(root, Vector3(0.05, 0.035, 0.30), Vector3(-0.07 + float(i) * 0.075, 0.39, 0.0), mats["steel"])
	make_box(root, Vector3(0.20, 0.30, 0.26), Vector3(-0.23, 0.53, 0.0), mats["gunmetal"])
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.07, 0.14, 0.10), Vector3(-0.245, 0.58, side * 0.11), mats["amber"])
	# Massive pauldrons with house-colour caps.
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.26, 0.15, 0.16), Vector3(0.02, 0.66, side * 0.235), mats["sardaukar"], Vector3(side * 6.0, 0.0, 0.0))
		make_box(root, Vector3(0.20, 0.045, 0.13), Vector3(0.03, 0.735, side * 0.235), mats["trim"])
	# Helmet with the Sardaukar crest and rebreather.
	make_sphere(root, 0.11, Vector3(0.02, 0.80, 0.0), mats["sardaukar"], 1.12)
	make_box(root, Vector3(0.22, 0.13, 0.21), Vector3(0.0, 0.885, 0.0), mats["sardaukar"])
	make_box(root, Vector3(0.05, 0.17, 0.20), Vector3(0.005, 0.985, 0.0), mats["trim"])
	make_box(root, Vector3(0.09, 0.06, 0.19), Vector3(0.10, 0.86, 0.0), mats["glass"])
	make_box(root, Vector3(0.07, 0.08, 0.10), Vector3(0.13, 0.77, 0.0), mats["gunmetal"])
	# Rapid heavy rifle with a drum magazine and cooling shroud.
	make_box(root, Vector3(0.66, 0.09, 0.09), Vector3(0.41 - recoil, 0.54, 0.16), mats["gunmetal"])
	make_box(root, Vector3(0.20, 0.14, 0.10), Vector3(0.16 - recoil, 0.52, 0.16), mats["sardaukar"])
	make_cyl(root, 0.075, 0.10, Vector3(0.30 - recoil, 0.45, 0.16), mats["steel_light"], Vector3(0.0, 0.0, 90.0), 14)
	make_box(root, Vector3(0.05, 0.20, 0.04), Vector3(0.24 - recoil, 0.62, 0.16), mats["steel"], Vector3(0.0, 0.0, 12.0))
	make_cyl(root, 0.030, 0.22, Vector3(0.82 - recoil, 0.54, 0.16), mats["dark"], Vector3(0.0, 0.0, 90.0), 10)
	if anim == 3:
		make_sphere(root, 0.055, Vector3(0.90 - recoil, 0.54, 0.16), mats["amber"])
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.17, 0.11, 0.12), Vector3(0.09 - recoil, 0.55, side * 0.22), mats["sardaukar"], Vector3(0.0, 0.0, side * 8.0))
	return root

func build_saboteur(facing: float, anim: int) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 0.72, 0.72)
	var stride := 0.12 if anim == 1 else (-0.12 if anim == 2 else 0.0)
	var recoil := 0.04 if anim == 3 else 0.0
	# Light boots and wrapped legs.
	for side in [-1.0, 1.0]:
		var s: float = stride * side
		make_box(root, Vector3(0.11, 0.24, 0.11), Vector3(s, 0.13, side * 0.10), mats["cloth_dark"])
		make_box(root, Vector3(0.14, 0.07, 0.13), Vector3(s + 0.035, 0.03, side * 0.10), mats["rubber"])
	# Slim tabard and chest harness.
	make_box(root, Vector3(0.26, 0.32, 0.24), Vector3(0.0, 0.49, 0.0), mats["cloth"])
	make_box(root, Vector3(0.22, 0.05, 0.26), Vector3(0.0, 0.35, 0.0), mats["gunmetal"])
	make_box(root, Vector3(0.05, 0.26, 0.02), Vector3(0.08, 0.50, 0.125), mats["trim"], Vector3(0.0, 0.0, -18.0))
	# Demolition satchel: three charges, a timer and a stubby antenna.
	make_box(root, Vector3(0.20, 0.28, 0.20), Vector3(-0.19, 0.44, 0.0), mats["cloth_dark"])
	for i in 3:
		make_cyl(root, 0.045, 0.20, Vector3(-0.19, 0.35 + float(i) * 0.075, 0.115), mats["amber"], Vector3.ZERO, 10)
	make_box(root, Vector3(0.075, 0.055, 0.05), Vector3(-0.19, 0.60, 0.10), mats["sonic"])
	make_cyl(root, 0.012, 0.26, Vector3(-0.19, 0.71, 0.10), mats["steel_light"], Vector3(0.0, 0.0, 8.0), 6)
	# Hooded head with a goggle strip.
	make_sphere(root, 0.105, Vector3(0.015, 0.76, 0.0), mats["cloth"], 1.1)
	make_box(root, Vector3(0.19, 0.10, 0.20), Vector3(0.0, 0.85, 0.0), mats["cloth"])
	make_box(root, Vector3(0.07, 0.05, 0.17), Vector3(0.10, 0.78, 0.0), mats["glass"])
	make_box(root, Vector3(0.03, 0.02, 0.15), Vector3(0.135, 0.79, 0.0), mats["sonic"])
	# Compact SMG.
	make_box(root, Vector3(0.42, 0.06, 0.06), Vector3(0.32 - recoil, 0.54, 0.13), mats["gunmetal"])
	make_box(root, Vector3(0.12, 0.10, 0.07), Vector3(0.10 - recoil, 0.52, 0.13), mats["steel"])
	make_box(root, Vector3(0.22, 0.05, 0.04), Vector3(0.08 - recoil, 0.46, 0.13), mats["dark"])
	if anim == 3:
		make_sphere(root, 0.045, Vector3(0.56 - recoil, 0.54, 0.13), mats["amber"])
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.14, 0.09, 0.09), Vector3(0.06 - recoil, 0.51, side * 0.17), mats["cloth"])
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

func build_raider_trike(facing: float) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 1.02, 0.76)
	# Bigger knobby rear pair, single front wheel, wide track.
	wheel(root, -0.30, -0.44, 0.23, 0.17)
	wheel(root, -0.30, 0.44, 0.23, 0.17)
	wheel(root, 0.47, 0.0, 0.215, 0.16)
	# Low open frame instead of the Trike's welded tub.
	make_box(root, Vector3(0.82, 0.12, 0.52), Vector3(-0.03, 0.27, 0.0), mats["olive"])
	make_box(root, Vector3(0.44, 0.10, 0.40), Vector3(-0.16, 0.38, 0.0), mats["olive_light"])
	make_box(root, Vector3(0.30, 0.12, 0.38), Vector3(0.44, 0.30, 0.0), mats["steel"], Vector3(0.0, 0.0, -6.0))
	make_box(root, Vector3(0.10, 0.03, 0.24), Vector3(0.58, 0.36, 0.0), mats["trim"])
	# Raked roll cage and rear wing.
	for z in [-0.22, 0.22]:
		make_box(root, Vector3(0.05, 0.46, 0.05), Vector3(-0.10, 0.56, z), mats["steel_light"], Vector3(0.0, 0.0, -10.0))
	make_box(root, Vector3(0.46, 0.045, 0.045), Vector3(0.06, 0.80, -0.22), mats["steel_light"])
	make_box(root, Vector3(0.46, 0.045, 0.045), Vector3(0.06, 0.80, 0.22), mats["steel_light"])
	make_box(root, Vector3(0.34, 0.025, 0.54), Vector3(-0.46, 0.66, 0.0), mats["trim"])
	# Exposed engine and twin exhausts.
	make_box(root, Vector3(0.22, 0.20, 0.38), Vector3(-0.40, 0.41, 0.0), mats["gunmetal"])
	for z in [-0.12, 0.12]:
		make_cyl(root, 0.045, 0.30, Vector3(-0.54, 0.48, z), mats["rust"], Vector3(0.0, 0.0, 90.0), 10)
	# Paired forward machine guns.
	for z in [-0.11, 0.11]:
		make_box(root, Vector3(0.20, 0.07, 0.07), Vector3(0.28, 0.47, z), mats["gunmetal"])
		make_cyl(root, 0.030, 0.46, Vector3(0.58, 0.47, z), mats["dark"], Vector3(0.0, 0.0, 90.0), 10)
		make_cyl(root, 0.050, 0.07, Vector3(0.80, 0.47, z), mats["steel_light"], Vector3(0.0, 0.0, 90.0), 10)
	make_box(root, Vector3(0.12, 0.04, 0.34), Vector3(0.24, 0.53, 0.0), mats["trim"])
	return root

## Each House's combat tank shares a layout but reads differently at 60 px:
## Atreides is long-barrelled and precise, Harkonnen broad and over-armoured,
## Ordos low and twin-gunned.
func build_combat_tank(facing: float, house: String) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	var wide := house == "harkonnen"
	add_shadow(root, 1.42 if wide else 1.30, 1.06 if wide else 0.98)
	track_side(root, -1.0, -0.50, 0.50, 0.19)
	track_side(root, 1.0, -0.50, 0.50, 0.19)
	if wide:
		make_box(root, Vector3(1.16, 0.22, 0.80), Vector3(0.0, 0.36, 0.0), mats["olive"])
		make_box(root, Vector3(1.16, 0.16, 0.10), Vector3(0.0, 0.34, -0.44), mats["steel"])
		make_box(root, Vector3(1.16, 0.16, 0.10), Vector3(0.0, 0.34, 0.44), mats["steel"])
		make_box(root, Vector3(0.34, 0.20, 0.72), Vector3(0.52, 0.42, 0.0), mats["steel"], Vector3(0.0, 0.0, -6.0))
		# Heavy bolted side plates.
		for z in [-0.47, 0.47]:
			make_box(root, Vector3(0.78, 0.24, 0.06), Vector3(-0.02, 0.40, z), mats["gunmetal"])
			for i in 3:
				make_box(root, Vector3(0.06, 0.06, 0.075), Vector3(-0.28 + float(i) * 0.26, 0.45, z), mats["trim"])
		# Squat turret and a thick cannon with a giant muzzle brake.
		make_box(root, Vector3(0.50, 0.24, 0.52), Vector3(-0.02, 0.59, 0.0), mats["sardaukar"])
		make_box(root, Vector3(0.30, 0.20, 0.40), Vector3(0.24, 0.61, 0.0), mats["steel"], Vector3(0.0, 0.0, -8.0))
		make_cyl(root, 0.085, 0.80, Vector3(0.68, 0.62, 0.0), mats["gunmetal"], Vector3(0.0, 0.0, 90.0), 14)
		make_cyl(root, 0.135, 0.18, Vector3(1.06, 0.62, 0.0), mats["rust"], Vector3(0.0, 0.0, 90.0), 12)
		make_cyl(root, 0.105, 0.07, Vector3(1.18, 0.62, 0.0), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
		make_box(root, Vector3(0.26, 0.035, 0.12), Vector3(0.50, 0.56, -0.30), mats["trim"])
		make_box(root, Vector3(0.26, 0.035, 0.12), Vector3(0.50, 0.56, 0.30), mats["trim"])
		for z in [-0.26, 0.26]:
			make_cyl(root, 0.055, 0.34, Vector3(-0.52, 0.70, z), mats["rust"], Vector3.ZERO, 10)
			make_cyl(root, 0.080, 0.07, Vector3(-0.52, 0.88, z), mats["dark"], Vector3.ZERO, 10)
	elif house == "ordos":
		# Low wedge hull with a sharp nose and twin light barrels.
		make_box(root, Vector3(1.00, 0.16, 0.66), Vector3(0.0, 0.34, 0.0), mats["ordos"])
		make_box(root, Vector3(0.38, 0.14, 0.58), Vector3(0.50, 0.39, 0.0), mats["olive_light"], Vector3(0.0, 0.0, -12.0))
		make_box(root, Vector3(0.56, 0.08, 0.40), Vector3(-0.12, 0.44, 0.0), mats["gunmetal"])
		for i in 4:
			make_box(root, Vector3(0.035, 0.09, 0.50), Vector3(-0.42 + float(i) * 0.06, 0.46, 0.0), mats["dark"])
		make_box(root, Vector3(0.34, 0.16, 0.36), Vector3(0.0, 0.54, 0.0), mats["steel"])
		make_box(root, Vector3(0.20, 0.12, 0.28), Vector3(0.20, 0.56, 0.0), mats["steel_light"], Vector3(0.0, 0.0, -10.0))
		for z in [-0.10, 0.10]:
			make_cyl(root, 0.038, 0.82, Vector3(0.64, 0.57, z), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
			make_cyl(root, 0.055, 0.08, Vector3(1.05, 0.57, z), mats["steel_light"], Vector3(0.0, 0.0, 90.0), 10)
		# Command antenna and dish.
		make_cyl(root, 0.012, 0.42, Vector3(-0.14, 0.84, 0.10), mats["steel_light"], Vector3(0.0, 0.0, 4.0), 6)
		make_cyl(root, 0.10, 0.035, Vector3(-0.12, 0.98, 0.12), mats["ordos"], Vector3(0.0, 0.0, 70.0), 14)
		make_box(root, Vector3(0.22, 0.03, 0.10), Vector3(0.48, 0.50, -0.28), mats["trim"])
		make_box(root, Vector3(0.22, 0.03, 0.10), Vector3(0.48, 0.50, 0.28), mats["trim"])
	else:
		# Atreides: clean long hull, precision cannon, sensor mast.
		make_box(root, Vector3(1.06, 0.18, 0.70), Vector3(0.0, 0.36, 0.0), mats["olive"])
		make_box(root, Vector3(0.88, 0.13, 0.56), Vector3(0.02, 0.49, 0.0), mats["olive_light"])
		make_box(root, Vector3(0.32, 0.16, 0.62), Vector3(0.52, 0.42, 0.0), mats["steel"], Vector3(0.0, 0.0, -9.0))
		for z in [-0.38, 0.38]:
			make_box(root, Vector3(0.80, 0.10, 0.06), Vector3(0.0, 0.34, z), mats["steel"])
		# Angular turret and a very long cannon.
		make_box(root, Vector3(0.40, 0.20, 0.42), Vector3(-0.02, 0.55, 0.0), mats["steel"])
		make_box(root, Vector3(0.26, 0.18, 0.32), Vector3(0.21, 0.58, 0.0), mats["steel_light"], Vector3(0.0, 0.0, -7.0))
		make_cyl(root, 0.060, 1.04, Vector3(0.74, 0.60, 0.0), mats["gunmetal"], Vector3(0.0, 0.0, 90.0), 14)
		make_cyl(root, 0.095, 0.15, Vector3(1.28, 0.60, 0.0), mats["rust"], Vector3(0.0, 0.0, 90.0), 12)
		make_cyl(root, 0.080, 0.06, Vector3(1.38, 0.60, 0.0), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
		make_box(root, Vector3(0.15, 0.035, 0.30), Vector3(-0.08, 0.66, 0.0), mats["trim"])
		# Fender stripes and the tall sensor mast.
		make_box(root, Vector3(0.24, 0.035, 0.10), Vector3(0.48, 0.51, -0.30), mats["trim"])
		make_box(root, Vector3(0.24, 0.035, 0.10), Vector3(0.48, 0.51, 0.30), mats["trim"])
		make_cyl(root, 0.012, 0.44, Vector3(-0.16, 0.86, 0.13), mats["steel_light"], Vector3(0.0, 0.0, 3.0), 6)
		make_box(root, Vector3(0.06, 0.06, 0.06), Vector3(-0.17, 1.08, 0.13), mats["cyan"])
		for z in [-0.23, 0.23]:
			make_cyl(root, 0.045, 0.26, Vector3(-0.55, 0.62, z), mats["rust"], Vector3(0.0, 0.0, 90.0), 10)
	return root

func build_sonic_tank(facing: float) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 1.34, 1.02)
	track_side(root, -1.0, -0.50, 0.50, 0.19)
	track_side(root, 1.0, -0.50, 0.50, 0.19)
	make_box(root, Vector3(1.04, 0.18, 0.70), Vector3(0.0, 0.35, 0.0), mats["olive"])
	make_box(root, Vector3(0.40, 0.22, 0.62), Vector3(0.40, 0.45, 0.0), mats["steel"], Vector3(0.0, 0.0, -8.0))
	# Rear generator with copper coils.
	make_box(root, Vector3(0.34, 0.34, 0.56), Vector3(-0.38, 0.53, 0.0), mats["gunmetal"])
	for i in 3:
		make_cyl(root, 0.10, 0.08, Vector3(-0.44 + float(i) * 0.06, 0.58, 0.0), mats["rust"], Vector3(0.0, 0.0, 90.0), 12)
	# Parabolic dish facing forward, built from stacked discs.
	make_box(root, Vector3(0.30, 0.16, 0.30), Vector3(0.02, 0.64, 0.0), mats["steel"])
	make_cyl(root, 0.46, 0.06, Vector3(0.18, 0.92, 0.0), mats["steel_light"], Vector3(0.0, 0.0, 90.0), 28)
	make_cyl(root, 0.40, 0.08, Vector3(0.21, 0.92, 0.0), mats["sonic"], Vector3(0.0, 0.0, 90.0), 28)
	make_cyl(root, 0.30, 0.10, Vector3(0.25, 0.92, 0.0), mats["dark"], Vector3(0.0, 0.0, 90.0), 24)
	make_cyl(root, 0.18, 0.12, Vector3(0.30, 0.92, 0.0), mats["sonic"], Vector3(0.0, 0.0, 90.0), 20)
	make_cyl(root, 0.48, 0.035, Vector3(0.15, 0.92, 0.0), mats["trim"], Vector3(0.0, 0.0, 90.0), 28)
	# Emitter prongs and support struts.
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		make_box(root, Vector3(0.34, 0.035, 0.035),
			Vector3(0.28, 0.92 + sin(a) * 0.46, cos(a) * 0.46), mats["steel_light"], Vector3(0.0, 0.0, -18.0))
	for z in [-0.30, 0.30]:
		make_cyl(root, 0.018, 0.34, Vector3(0.12, 0.79, z), mats["gunmetal"], Vector3(0.0, 0.0, 90.0), 6)
	make_cyl(root, 0.022, 0.44, Vector3(0.48, 0.92, 0.0), mats["sonic"], Vector3(0.0, 0.0, 90.0), 8)
	make_box(root, Vector3(0.22, 0.03, 0.10), Vector3(0.44, 0.53, -0.31), mats["trim"])
	make_box(root, Vector3(0.22, 0.03, 0.10), Vector3(0.44, 0.53, 0.31), mats["trim"])
	return root

func build_devastator(facing: float) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 1.70, 1.20)
	track_side(root, -1.0, -0.58, 0.58, 0.23)
	track_side(root, 1.0, -0.58, 0.58, 0.23)
	# Extra-wide battleship hull with a dozer blade.
	make_box(root, Vector3(1.34, 0.26, 0.96), Vector3(0.0, 0.40, 0.0), mats["olive"])
	make_box(root, Vector3(1.10, 0.18, 0.80), Vector3(0.02, 0.56, 0.0), mats["olive_light"])
	make_box(root, Vector3(0.28, 0.24, 0.98), Vector3(0.68, 0.36, 0.0), mats["steel"], Vector3(0.0, 0.0, -18.0))
	for z in [-0.52, 0.52]:
		make_box(root, Vector3(1.02, 0.28, 0.09), Vector3(-0.02, 0.42, z), mats["gunmetal"])
		for i in 4:
			make_box(root, Vector3(0.05, 0.05, 0.10), Vector3(-0.42 + float(i) * 0.26, 0.46, z), mats["trim"])
	# Huge turret with side-by-side main guns.
	make_box(root, Vector3(0.66, 0.28, 0.72), Vector3(-0.04, 0.68, 0.0), mats["sardaukar"])
	make_box(root, Vector3(0.40, 0.24, 0.58), Vector3(0.28, 0.70, 0.0), mats["steel"], Vector3(0.0, 0.0, -6.0))
	for z in [-0.20, 0.20]:
		make_cyl(root, 0.085, 0.96, Vector3(0.86, 0.70, z), mats["gunmetal"], Vector3(0.0, 0.0, 90.0), 14)
		make_cyl(root, 0.130, 0.20, Vector3(1.30, 0.70, z), mats["rust"], Vector3(0.0, 0.0, 90.0), 12)
		make_cyl(root, 0.100, 0.08, Vector3(1.44, 0.70, z), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
		make_cyl(root, 0.060, 0.14, Vector3(0.30, 0.84, z), mats["steel_light"], Vector3.ZERO, 10)
	make_box(root, Vector3(0.22, 0.04, 0.40), Vector3(-0.12, 0.86, 0.0), mats["trim"])
	# Rear engine block and four stacks.
	make_box(root, Vector3(0.36, 0.28, 0.90), Vector3(-0.58, 0.60, 0.0), mats["gunmetal"])
	for z in [-0.30, -0.10, 0.10, 0.30]:
		make_cyl(root, 0.045, 0.34, Vector3(-0.74, 0.80, z), mats["rust"], Vector3.ZERO, 10)
		make_cyl(root, 0.070, 0.08, Vector3(-0.74, 0.99, z), mats["dark"], Vector3.ZERO, 10)
	# Hazard stripes on the blade.
	for i in 4:
		make_box(root, Vector3(0.04, 0.20, 0.13), Vector3(0.80, 0.36, -0.36 + float(i) * 0.24), mats["yellow"], Vector3(0.0, 0.0, 18.0))
	return root

func build_deviator(facing: float) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = -facing
	add_shadow(root, 1.22, 0.92)
	for x in [-0.36, 0.02, 0.40]:
		for z in [-0.38, 0.38]:
			wheel(root, x, z, 0.19, 0.14)
	# Low wheeled chassis and cab.
	make_box(root, Vector3(0.94, 0.16, 0.62), Vector3(0.0, 0.29, 0.0), mats["ordos"])
	make_box(root, Vector3(0.34, 0.26, 0.50), Vector3(0.34, 0.48, 0.0), mats["olive_light"])
	make_box(root, Vector3(0.20, 0.14, 0.42), Vector3(0.47, 0.53, 0.0), mats["glass"], Vector3(0.0, 0.0, -8.0))
	make_box(root, Vector3(0.08, 0.20, 0.52), Vector3(0.56, 0.34, 0.0), mats["steel"])
	# Rear green-gas missile pod: two rows of two fat tubes, angled up.
	make_box(root, Vector3(0.42, 0.30, 0.60), Vector3(-0.27, 0.52, 0.0), mats["gunmetal"])
	for row in 2:
		for z in [-0.15, 0.15]:
			make_cyl(root, 0.075, 0.46, Vector3(-0.04, 0.54 + float(row) * 0.13, z),
				mats["gas"], Vector3(0.0, 0.0, 72.0), 14)
			make_cyl(root, 0.088, 0.05, Vector3(0.18, 0.60 + float(row) * 0.13, z),
				mats["trim"], Vector3(0.0, 0.0, 72.0), 14)
	make_box(root, Vector3(0.10, 0.05, 0.46), Vector3(-0.30, 0.70, 0.0), mats["ordos"])
	# Gas canisters along the flanks.
	for z in [-0.36, 0.36]:
		make_cyl(root, 0.065, 0.36, Vector3(-0.30, 0.38, z), mats["gas"], Vector3(0.0, 0.0, 90.0), 12)
	# Targeting dish and antenna.
	make_cyl(root, 0.012, 0.40, Vector3(-0.20, 0.80, 0.18), mats["steel_light"], Vector3(0.0, 0.0, 6.0), 6)
	make_cyl(root, 0.11, 0.03, Vector3(-0.19, 0.96, 0.20), mats["ordos"], Vector3(0.0, 0.0, 66.0), 14)
	make_box(root, Vector3(0.20, 0.03, 0.10), Vector3(0.46, 0.44, -0.26), mats["trim"])
	make_box(root, Vector3(0.20, 0.03, 0.10), Vector3(0.46, 0.44, 0.26), mats["trim"])
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
	for id in ALL_INFANTRY:
		await _bake_infantry(id)
	for id in VEHICLE_CELLS.keys():
		await _bake_vehicle(id, int(VEHICLE_CELLS[id]))
	await _bake_tank()
	await _bake_harvester()
	await _bake_icons()
	print("UNIT BAKE COMPLETE: ", ProjectSettings.globalize_path(OUT_DIR))

## House-unique sheets plus the shared icon set. Existing core vehicle and
## infantry map sheets are deliberately left untouched.
func _bake_factions() -> void:
	for id in FACTION_INFANTRY:
		await _bake_infantry(id)
	for id in FACTION_VEHICLES:
		await _bake_vehicle(id, int(VEHICLE_CELLS[id]))
	await _bake_icons()

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
	# Must match UnitArt.CELLS exactly, or the runtime samples a region wider or
	# narrower than the baked cell and clips neighbouring poses.
	var cell := UnitArt.cell(id)
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
	var view_size := float(VEHICLE_VIEW.get(id, 2.05))
	var sheet := Image.create(px * VEHICLE_FRAMES, px, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for i in VEHICLE_FRAMES:
		var angle := TAU * float(i) / float(VEHICLE_FRAMES)
		await _replace_assembly(build_vehicle_model(id, angle))
		var img := await _render(float(cell), view_size)
		sheet.blit_rect(img, Rect2i(0, 0, px, px), Vector2i(i * px, 0))
	var path := "%s/%s.png" % [OUT_DIR, id]
	sheet.save_png(ProjectSettings.globalize_path(path))
	print("UNIT BAKED %-12s sheet=%dx%d cell=%d dirs=%d" % [id, sheet.get_width(), sheet.get_height(), px, VEHICLE_FRAMES])

func build_vehicle_model(id: String, angle: float) -> Node3D:
	match id:
		"raider_trike":
			return build_raider_trike(angle)
		"quad":
			return build_quad(angle)
		"atreides_tank":
			return build_combat_tank(angle, "atreides")
		"harkonnen_tank":
			return build_combat_tank(angle, "harkonnen")
		"ordos_tank":
			return build_combat_tank(angle, "ordos")
		"sonic_tank":
			return build_sonic_tank(angle)
		"devastator":
			return build_devastator(angle)
		"deviator":
			return build_deviator(angle)
	return build_trike(angle)

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
	_apply_portrait_lighting(true)
	var tiles: Array[Image] = []
	for id in ALL_ICONS:
		await _replace_assembly(_icon_model(id))
		viewport.size = Vector2i(192, 192)
		var icon_size := 1.25
		if UnitArt.is_infantry(id):
			icon_size = 1.22
		elif id == "devastator":
			icon_size = 1.90
		elif id in ["sonic_tank", "harkonnen_tank", "atreides_tank", "deviator"]:
			icon_size = 1.72
		elif id == "harvester":
			icon_size = 1.65
		else:
			icon_size = 1.55
		camera.size = icon_size
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
	var root: Node3D
	match id:
		"infantry", "rocket", "fremen", "sardaukar", "saboteur":
			root = build_infantry(id, angle, 0)
		"trike":
			root = build_trike(angle)
		"raider_trike":
			root = build_raider_trike(angle)
		"quad":
			root = build_quad(angle)
		"tank":
			root = build_tank(angle)
		"atreides_tank":
			root = build_combat_tank(angle, "atreides")
		"harkonnen_tank":
			root = build_combat_tank(angle, "harkonnen")
		"ordos_tank":
			root = build_combat_tank(angle, "ordos")
		"sonic_tank":
			root = build_sonic_tank(angle)
		"devastator":
			root = build_devastator(angle)
		"deviator":
			root = build_deviator(angle)
		_:
			root = build_harvester(angle, 1.0)
	# The map sprites bake a shadow plane into their frame. For portraits that
	# plane would wash a dark square across the warm plate, so replace it with
	# the soft painted contact oval in _make_icon_backdrop().
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node.material_override == mats["shadow"]:
			node.visible = false
	return root

func _make_unit_icon(raw: Image, _id: String) -> Image:
	var used := raw.get_used_rect()
	if used.size.x <= 1 or used.size.y <= 1:
		used = Rect2i(0, 0, raw.get_width(), raw.get_height())
	var crop := raw.get_region(used)
	# Leave a little breathing room on the warm backdrop so the contact shadow
	# and the silhouette both read at 64 px.
	var max_side := 56.0
	var scale := minf(max_side / float(crop.get_width()), max_side / float(crop.get_height()))
	var w := maxi(int(round(float(crop.get_width()) * scale)), 1)
	var h := maxi(int(round(float(crop.get_height()) * scale)), 1)
	crop.resize(w, h, Image.INTERPOLATE_LANCZOS)
	# Portrait-only exposure lift, gentle gamma and a restrained unsharp pass.
	# The map sheets never go through this function.
	crop.adjust_bcs(1.08, 1.10, 1.06)
	for y in h:
		for x in w:
			var c := crop.get_pixel(x, y)
			if c.a <= 0.01:
				continue
			c.r = pow(c.r, 0.97)
			c.g = pow(c.g, 0.97)
			c.b = pow(c.b, 0.97)
			crop.set_pixel(x, y, c)
	crop = _sharpen(crop, 0.24)
	# The magenta house trim is deliberately left intact: BuildTile draws the
	# icon through the faction shader, so one shared portrait becomes blue,
	# red or green to match the side that is fielding it.
	var bg := _make_icon_backdrop()
	bg.blend_rect(crop, Rect2i(0, 0, w, h), Vector2i((ICON_PX - w) / 2, (ICON_PX - h) / 2))
	return bg


func _sharpen(img: Image, amount: float) -> Image:
	var h := img.get_height()
	var w := img.get_width()
	var src: Image = img.duplicate()
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var c: Color = src.get_pixel(x, y)
			if c.a <= 0.02:
				continue
			var avg := Color(0.0, 0.0, 0.0, c.a)
			for oy in [-1, 0, 1]:
				for ox in [-1, 0, 1]:
					if ox == 0 and oy == 0:
						continue
					avg += src.get_pixel(x + ox, y + oy)
			avg /= 8.0
			var out := Color(
				clampf(c.r + (c.r - avg.r) * amount, 0.0, 1.0),
				clampf(c.g + (c.g - avg.g) * amount, 0.0, 1.0),
				clampf(c.b + (c.b - avg.b) * amount, 0.0, 1.0), c.a)
			img.set_pixel(x, y, out)
	return img


func _make_icon_backdrop() -> Image:
	var img := Image.create(ICON_PX, ICON_PX, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 909
	noise.frequency = 0.085
	# Dusty tan concrete, close in value to the pads behind the building icons.
	# A broad warm centre glow and darker corners make a natural vignette.
	var top := Color(0.64, 0.49, 0.32)
	var bottom := Color(0.34, 0.24, 0.15)
	var warm := Color(0.84, 0.66, 0.43)
	for y in ICON_PX:
		for x in ICON_PX:
			var t := float(y) / float(ICON_PX - 1)
			var base := top.lerp(bottom, t)
			var dx := (float(x) - 30.0) / 34.0
			var dy := (float(y) - 25.0) / 34.0
			var glow := clampf(1.0 - sqrt(dx * dx + dy * dy), 0.0, 1.0)
			base = base.lerp(warm, glow * 0.30)
			var n := noise.get_noise_2d(float(x), float(y))
			base = base.lightened(0.025 * n)
			var edge := minf(minf(float(x), float(ICON_PX - 1 - x)), minf(float(y), float(ICON_PX - 1 - y)))
			if edge < 2.0:
				base = base.darkened(0.18)
			# Painted contact shadow: an even, soft oval is more legible than
			# the orthographic shadow plane at this size.
			var sx := (float(x) - 32.0) / 21.0
			var sy := (float(y) - 50.0) / 6.5
			var contact := maxf(0.0, 1.0 - (sx * sx + sy * sy))
			base = base.darkened(0.20 * contact * contact)
			img.set_pixel(x, y, Color(base.r, base.g, base.b, 1.0))
	# Sparse dust grains and a soft ground shadow keep the plate from looking
	# like a flat colour swatch.
	for i in 44:
		var px := int((i * 37 + 11) % ICON_PX)
		var py := int((i * 53 + 19) % ICON_PX)
		if px < 3 or px > ICON_PX - 4 or py < 3 or py > ICON_PX - 4:
			continue
		var c: Color = img.get_pixel(px, py)
		img.set_pixel(px, py, c.lightened(0.08) if i % 3 == 0 else c.darkened(0.06))
	for x in ICON_PX:
		for y in range(50, ICON_PX):
			var c: Color = img.get_pixel(x, y)
			var t := float(y - 50) / 13.0
			img.set_pixel(x, y, c.darkened(0.10 * t))
	return img

func _make_preview(tiles: Array[Image]) -> void:
	var cols := 5
	var rows := int(ceil(float(tiles.size()) / float(cols)))
	var preview := Image.create(cols * ICON_PX, rows * ICON_PX, false, Image.FORMAT_RGBA8)
	preview.fill(Color(0.08, 0.06, 0.04, 1.0))
	for i in tiles.size():
		preview.blit_rect(tiles[i], Rect2i(0, 0, ICON_PX, ICON_PX),
			Vector2i((i % cols) * ICON_PX, (i / cols) * ICON_PX))
	preview.save_png(ProjectSettings.globalize_path(PREVIEW_PATH))
