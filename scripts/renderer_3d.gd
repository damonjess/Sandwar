class_name Renderer3D
extends CanvasLayer

## Modern 3D presentation layer.
##
## The Node2D battlefield remains the single simulation: range checks, pathing,
## economy, fog, campaign state and orders never leave it. This renderer mirrors
## live positions into a SubViewport and routes map input through the 3D camera.
## Classic mode simply switches the viewport off and restores the 2D layers.

const TILE := GameDefs.TILE
const WORLD_SCALE := 1.0 / float(TILE)
const PANEL_WIDTH := GameHUD.PANEL_WIDTH
const MAP_UNITS := 1.0
const ROCK_HEIGHT := 0.45
const SAND_HEIGHT := 0.0
const TERRAIN_SUBDIV := 2
const PAD_MARGIN := 0.26
const FOUNDATION_TOP := 0.030
const FOUNDATION_LIFT := 0.035

const CAMERA_START_YAW := deg_to_rad(45.0)
const CAMERA_PITCH := deg_to_rad(40.0)
const AUTO_ORBIT_SPEED := deg_to_rad(26.0)
const CAMERA_FOV := 32.0
const CAMERA_BASE_DISTANCE := 18.2
const CAMERA_MIN_ZOOM := 0.52
## Close enough to read vehicle detail without letting the camera leave the
## playfield or push through the distant dune backdrop.
const CAMERA_MAX_ZOOM := 1.85
const PAN_SPEED := 760.0

const BUILDING_DIR := "res://assets/models/buildings/"
const UNIT_DIR := "res://assets/models/units/"
const TERRAIN_SHADER := "res://shaders/terrain_3d.gdshader"
const INK_SHADER := "res://shaders/ink_outline_3d.gdshader"
const TREAD_SHADER := "res://shaders/tread_track_3d.gdshader"
const CRATER_SHADER := "res://shaders/crater_3d.gdshader"
const PEBBLE_SHADER := "res://shaders/pebble_3d.gdshader"
const SCATTER_SHADER := "res://shaders/scatter_3d.gdshader"
const POST_DUST_SHADER := "res://shaders/post_dust_3d.gdshader"
const PBR_DIR := "res://assets/textures/pbr/"
const KIT_PROP_DIR := "res://assets/models/kitprops/"
const KIT_SHADER := "res://shaders/kit_prop_3d.gdshader"
## The Space Station kit ships its palette as an external atlas. Godot's GLB
## import can miss that dependency if the raw download lacked the Textures
## folder, so the runtime loader can attach the copied atlas itself.
const KIT_ATLAS_FALLBACK := {
	"container.glb": "Textures/colormap.png",
	"pipe.glb": "Textures/colormap.png",
}

## Pooled, GPU-faded ground decals. No Decal nodes are used: inverted-hull ink
## outlines, tread marks and craters are all plain meshes, so the whole Modern
## look runs on the gl_compatibility backend used by the Android build.
const TRACK_POOL := 900
const TRACK_LIFETIME := 25.0
const CRATER_POOL := 96
const CRATER_LIFETIME := 120.0
## Dense but still five-draw-call scatter. These caps are intentionally lower
## than a desktop-only field: the GTX 970 / 4 GB target and the GL compatibility
## path both need to fit alongside the live unit and structure meshes.
const SCATTER_ROCK_CAP := 3600
const SCATTER_GRAVEL_CAP := 6200
const SCATTER_SCRAP_CAP := 820
const SCATTER_SHRUB_CAP := 650
const SCATTER_CRATE_CAP := 220
const SCATTER_CANISTER_CAP := 180
const TRACK_TYPES := ["tank", "atreides_tank", "harkonnen_tank", "ordos_tank",
	"sonic_tank", "devastator", "deviator", "harvester", "mcv", "trike",
	"raider_trike", "quad"]
const TRACK_WIDTHS := {
	"harvester": 1.34, "mcv": 1.22, "tank": 0.94, "atreides_tank": 0.94,
	"harkonnen_tank": 0.98, "ordos_tank": 0.92, "sonic_tank": 0.94,
	"devastator": 1.16, "deviator": 0.92, "trike": 0.56,
	"raider_trike": 0.56, "quad": 0.70,
}

const UNIT_SCALES := {
	"infantry": 0.50, "rocket": 0.50, "fremen": 0.50, "sardaukar": 0.52,
	"saboteur": 0.50, "trike": 0.48, "raider_trike": 0.48, "quad": 0.52,
	"tank": 0.50, "atreides_tank": 0.50, "harkonnen_tank": 0.50,
	"ordos_tank": 0.50, "sonic_tank": 0.52, "devastator": 0.48,
	"deviator": 0.50, "mcv": 0.48,
	# The hero dozer rig is authored at 2.63 model units; 0.88 keeps it a
	# readable foreground harvester against the structures without dwarfing the
	# 0.50-scaled Combat Tank.
	"harvester": 0.88,
	"carryall": 0.58, "frigate": 0.72, "ornithopter": 0.64,
	"sandworm": 0.55,
}

var game = null
var active := false
var built := false

var layer_root: Control
var container: SubViewportContainer
var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var env: WorldEnvironment

var terrain_mesh: MeshInstance3D
var terrain_mat: ShaderMaterial
var sim_image: Image
var sim_texture: ImageTexture
var map_size := 56
## Continuous, sub-tile height field shared by the mesh, decals and grounding.
var height_field := PackedFloat32Array()
var height_cells := 0
var height_size := 0
var terrain_dirty := false

var ink_material: ShaderMaterial
var ink_small_material: ShaderMaterial
var ink_building_material: ShaderMaterial
var foundation_mesh: ArrayMesh
var foundation_mat: StandardMaterial3D
var pebble_instance: MultiMeshInstance3D
var pebble_multimesh: MultiMesh
var rock_scatter: MultiMeshInstance3D
var gravel_scatter: MultiMeshInstance3D
var scrap_scatter: MultiMeshInstance3D
var shrub_scatter: MultiMeshInstance3D
var crate_scatter: MultiMeshInstance3D
var canister_scatter: MultiMeshInstance3D
var scatter_material: ShaderMaterial
var ambient_dust: CPUParticles3D
var dust_veil: CPUParticles3D
var post_rect: ColorRect
var post_material: ShaderMaterial
var tread_instance: MultiMeshInstance3D
var tread_multimesh: MultiMesh
var tread_next := 0
var tread_used := 0
var crater_instance: MultiMeshInstance3D
var crater_multimesh: MultiMesh
var crater_next := 0
var crater_used := 0
var bar_overlay: Control

var _soft_texture: GradientTexture2D
var _smoke_puff_mat: StandardMaterial3D
var _dust_puff_mat: StandardMaterial3D
var _fire_puff_mat: StandardMaterial3D
var _gas_puff_mat: StandardMaterial3D
var _debris_mat: StandardMaterial3D
var _tracer_mat: StandardMaterial3D
var _tracer_core_mat: StandardMaterial3D
var _plasma_glow_mat: StandardMaterial3D
var _plasma_core_mat: StandardMaterial3D
var _rocket_glow_mat: StandardMaterial3D
var _sonic_ring_mat: StandardMaterial3D
var _spice_mound_mat: StandardMaterial3D
var _spice_texture: ImageTexture
var _shock_ring_mat: StandardMaterial3D
var _ink_shader: Shader
var _scatter_shader: Shader
var _post_shader: Shader
var _tread_shader: Shader
var _crater_shader: Shader
var _pebble_shader: Shader
var _outlined_materials: Dictionary = {}
var _pbr_textures: Dictionary = {}
var _pbr_materials: Dictionary = {}
var _kit_props: Dictionary = {}
var _kit_materials: Dictionary = {}
var _kit_shader: Shader
var _kit_white: ImageTexture
var _atmosphere_clock := 0.0
var _fx_blast_memo: Array = []
var _fx_impact_memo: Array = []
var _fx_gas_memo: Array = []
var _fx_wave_memo: Array = []

var focus_px := Vector2.ZERO
var camera_yaw := CAMERA_START_YAW
var auto_orbit := false
var camera_zoom := 1.0
var _terrain_clock := 0.0

var _model_cache: Dictionary = {}
var _entities: Dictionary = {}
var _trim_materials: Dictionary = {}
var _selection_material: StandardMaterial3D
var _building_selection_material: StandardMaterial3D
var _ghost_green: StandardMaterial3D
var _ghost_red: StandardMaterial3D
var _ghost_box: MeshInstance3D
var _brush_boxes: Array = []
var _selection_box_mesh: ImmediateMesh
var _selection_box_instance: MeshInstance3D


func setup(g) -> void:
	game = g
	layer = 4
	name = "Modern3D"
	layer_root = Control.new()
	layer_root.name = "Modern3DLayer"
	layer_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(layer_root)
	container = SubViewportContainer.new()
	container.name = "BattlefieldViewport"
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.stretch = true
	layer_root.add_child(container)
	viewport = SubViewport.new()
	viewport.name = "World3D"
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.handle_input_locally = false
	container.add_child(viewport)
	bar_overlay = HealthBars.new()
	bar_overlay.host = self
	bar_overlay.name = "HealthBars2D"
	bar_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_overlay.clip_contents = true
	# Explicit size, not full-rect anchors: the battlefield viewport stops at
	# the sidebar, and health bars are projected into its pixel space.
	bar_overlay.anchor_right = 0.0
	bar_overlay.anchor_bottom = 0.0
	layer_root.add_child(bar_overlay)
	visible = false
	set_process(false)
	_layout()
	get_viewport().size_changed.connect(_layout)


func _layout() -> void:
	if container == null:
		return
	var screen := get_viewport().get_visible_rect().size
	var play := Vector2(maxf(screen.x - PANEL_WIDTH, 160.0), maxf(screen.y, 160.0))
	container.position = Vector2.ZERO
	container.size = play
	if post_rect != null:
		post_rect.position = Vector2.ZERO
		post_rect.size = play
	if bar_overlay != null:
		bar_overlay.position = Vector2.ZERO
		bar_overlay.size = play
	# With stretch enabled the container owns the SubViewport size. Setting it
	# manually would be overwritten and emits a warning every resize.
	if camera != null:
		camera.fov = CAMERA_FOV
		_update_camera()


func set_active(on: bool) -> void:
	active = on
	visible = on
	if on:
		if not built:
			_build_world()
		_layout()
		_terrain_clock = 999.0
		_sync_terrain()
		_sync_entities(0.0)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		set_process(true)
		_focus_from_2d_camera()
	else:
		if viewport != null:
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		auto_orbit = false
		set_process(false)


func _focus_from_2d_camera() -> void:
	if game == null or game.camera == null:
		return
	var center: Vector2 = game.camera.position + game.camera.offset
	focus_px = center.clamp(Vector2.ZERO, Vector2(float(game.MAP * TILE), float(game.MAP * TILE)))
	# The reference is a close, cinematic command view rather than a wide survey
	# shot; start slightly in so structures and the hero harvester carry weight.
	camera_zoom = 1.0
	_update_camera()


func _build_world() -> void:
	if built:
		return
	built = true
	world = Node3D.new()
	world.name = "SandwarWorld"
	viewport.add_child(world)

	camera = Camera3D.new()
	camera.name = "ModernCamera"
	camera.fov = CAMERA_FOV
	camera.near = 0.30
	camera.far = 180.0
	world.add_child(camera)
	# Register as current only after the camera is inside the SubViewport's
	# own World3D; assigning before add_child leaves the viewport camera-less.
	camera.current = true

	env = WorldEnvironment.new()
	var e := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.255, 0.375, 0.500)
	sky_mat.sky_horizon_color = Color(0.960, 0.780, 0.545)
	sky_mat.sky_curve = 0.12
	sky_mat.ground_bottom_color = Color(0.50, 0.335, 0.195)
	sky_mat.ground_horizon_color = Color(0.78, 0.575, 0.365)
	sky_mat.sun_angle_max = 16.0
	sky_mat.sun_curve = 0.09
	var sky := Sky.new()
	sky.sky_material = sky_mat
	e.sky = sky
	e.background_mode = Environment.BG_SKY
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Warm dusty bounce. With the softer sun below this keeps shaded hulls
	# readable instead of crushing them to black.
	e.ambient_light_color = Color("d4a574")
	e.ambient_light_energy = 0.68
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 0.95
	e.tonemap_white = 1.34
	e.fog_enabled = true
	e.fog_light_color = Color(0.86, 0.650, 0.420)
	e.fog_light_energy = 0.62
	e.fog_density = 0.0038
	e.fog_sky_affect = 0.26
	env.environment = e
	world.add_child(env)

	sun = DirectionalLight3D.new()
	sun.name = "DesertSunNW"
	sun.light_color = Color("fff0d6")
	sun.light_energy = 1.20
	sun.light_specular = 0.36
	sun.light_angular_distance = 0.42
	sun.rotation_degrees = Vector3(-50.0, -132.0, 0.0)
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.72
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 58.0
	sun.directional_shadow_split_1 = 0.18
	sun.directional_shadow_split_2 = 0.45
	sun.directional_shadow_split_3 = 0.75
	sun.shadow_bias = 0.035
	sun.shadow_normal_bias = 1.1
	sun.shadow_blur = 0.62
	world.add_child(sun)

	# Cool sky bounce from the opposite side keeps the unlit faces of vehicles
	# and infantry from collapsing into solid black. No shadows; this is fill.
	fill = DirectionalLight3D.new()
	fill.name = "DesertSkyFill"
	fill.light_color = Color(0.62, 0.72, 0.88)
	fill.light_energy = 0.30
	fill.light_specular = 0.18
	fill.rotation_degrees = Vector3(-28.0, 48.0, 0.0)
	fill.shadow_enabled = false
	world.add_child(fill)

	_build_terrain()
	_build_materials()
	_build_ground_decor()
	_build_atmosphere()
	_update_camera()


func _build_materials() -> void:
	_ink_shader = load(INK_SHADER)
	_tread_shader = load(TREAD_SHADER)
	_crater_shader = load(CRATER_SHADER)
	_pebble_shader = load(PEBBLE_SHADER)

	ink_material = ShaderMaterial.new()
	ink_material.resource_name = "InkOutline3D"
	ink_material.shader = _ink_shader
	ink_material.set_shader_parameter("ink_color", Color(0.078431, 0.050980, 0.031373, 1.0))
	# 40% thinner than the previous 0.018 extrusion; distant growth is reduced
	# too so the line stays a silhouette rather than a black halo.
	ink_material.set_shader_parameter("ink_width", 0.0108)
	ink_material.set_shader_parameter("distance_growth", 0.0144)
	ink_material.set_shader_parameter("max_depth", 70.0)
	ink_small_material = ShaderMaterial.new()
	ink_small_material.resource_name = "InkOutline3DSmall"
	ink_small_material.shader = _ink_shader
	ink_small_material.set_shader_parameter("ink_color", Color(0.078431, 0.050980, 0.031373, 1.0))
	ink_small_material.set_shader_parameter("ink_width", 0.0066)
	ink_small_material.set_shader_parameter("distance_growth", 0.008)
	ink_small_material.set_shader_parameter("max_depth", 70.0)
	# Structures contain many thin rails and bolt-sized disconnected faces. A
	# still finer hull keeps their silhouettes without leaving black flecks
	# floating above the foundation pad.
	ink_building_material = ShaderMaterial.new()
	ink_building_material.resource_name = "InkOutline3DBuilding"
	ink_building_material.shader = _ink_shader
	ink_building_material.set_shader_parameter("ink_color", Color(0.078431, 0.050980, 0.031373, 1.0))
	ink_building_material.set_shader_parameter("ink_width", 0.0042)
	ink_building_material.set_shader_parameter("distance_growth", 0.0045)
	ink_building_material.set_shader_parameter("max_depth", 70.0)

	# A single reusable beveled plinth is scaled to each structure footprint.
	# It gives every building a deliberate concrete base and hides the terrain
	# triangles that meet underneath the model.
	foundation_mesh = _make_foundation_mesh()
	foundation_mat = _pbr_material("concrete").duplicate()
	foundation_mat.resource_name = "FoundationPBRConcrete"
	foundation_mat.albedo_color = Color(1.24, 1.16, 1.05)
	foundation_mat.vertex_color_use_as_albedo = true
	# Slabs are non-uniformly scaled to each footprint, so world triplanar is
	# needed to keep the concrete grain square instead of stretching it.
	foundation_mat.uv1_triplanar = true
	foundation_mat.uv1_world_triplanar = true
	foundation_mat.uv1_scale = Vector3(0.60, 0.60, 0.60)
	foundation_mat.normal_scale = 0.78
	# The slab has separate top/side geometry; disabling culling avoids any
	# winding surprise on the gl_compatibility backend.
	foundation_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# A single soft radial falloff drives smoke, dust, fire and weapon glows.
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.28, 0.62, 1.0])
	grad.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0, 0.82),
		Color(1.0, 1.0, 1.0, 0.26), Color(1.0, 1.0, 1.0, 0.0)])
	_soft_texture = GradientTexture2D.new()
	_soft_texture.gradient = grad
	_soft_texture.width = 64
	_soft_texture.height = 64
	_soft_texture.fill = GradientTexture2D.FILL_RADIAL
	_soft_texture.fill_from = Vector2(0.5, 0.5)
	_soft_texture.fill_to = Vector2(1.0, 0.5)

	_smoke_puff_mat = _particle_material(Color(1.0, 1.0, 1.0, 1.0), false)
	_dust_puff_mat = _particle_material(Color(1.0, 1.0, 1.0, 1.0), false)
	_gas_puff_mat = _particle_material(Color(1.0, 1.0, 1.0, 1.0), false)
	_fire_puff_mat = _particle_material(Color(1.0, 1.0, 1.0, 1.0), true)

	_debris_mat = StandardMaterial3D.new()
	_debris_mat.albedo_color = Color(0.24, 0.17, 0.105)
	_debris_mat.roughness = 0.94
	_debris_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON

	_tracer_mat = _glow_material(Color(1.0, 0.70, 0.22, 0.92))
	_tracer_core_mat = _glow_material(Color(1.0, 0.96, 0.72, 1.0))
	_plasma_glow_mat = _glow_material(Color(1.0, 0.10, 0.025, 0.95))
	_plasma_core_mat = _glow_material(Color(1.0, 0.62, 0.24, 1.0))
	_rocket_glow_mat = _glow_material(Color(1.0, 0.42, 0.09, 0.92))

	_sonic_ring_mat = StandardMaterial3D.new()
	_sonic_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sonic_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_sonic_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	_sonic_ring_mat.albedo_color = Color(0.120, 0.650, 1.0, 0.55)
	_sonic_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_shock_ring_mat = StandardMaterial3D.new()
	_shock_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shock_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shock_ring_mat.albedo_color = Color(0.90, 0.78, 0.54, 0.30)
	_shock_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# A tiny deterministic grain map keeps the live hopper load from reading
	# as a smooth red balloon. It multiplies the burnt-orange base colour.
	var grain_img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	var grain_rng := RandomNumberGenerator.new()
	grain_rng.seed = 90210
	for gy in 32:
		for gx in 32:
			var v := grain_rng.randf_range(0.62, 1.0)
			grain_img.set_pixel(gx, gy, Color(v, v, v))
	_spice_texture = ImageTexture.create_from_image(grain_img)
	_spice_mound_mat = StandardMaterial3D.new()
	_spice_mound_mat.albedo_color = Color(0.660, 0.280, 0.062)
	_spice_mound_mat.albedo_texture = _spice_texture
	_spice_mound_mat.uv1_scale = Vector3(3.0, 3.0, 3.0)
	_spice_mound_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_spice_mound_mat.roughness = 0.94
	_spice_mound_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	_spice_mound_mat.emission_enabled = true
	_spice_mound_mat.emission = Color(0.40, 0.10, 0.008)
	_spice_mound_mat.emission_energy_multiplier = 0.16

	_selection_material = StandardMaterial3D.new()
	_selection_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_selection_material.vertex_color_use_as_albedo = true
	_selection_material.no_depth_test = true
	_selection_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_selection_material.albedo_color = Color(0.55, 1.0, 0.62, 0.95)

	_building_selection_material = StandardMaterial3D.new()
	_building_selection_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_building_selection_material.vertex_color_use_as_albedo = true
	_building_selection_material.no_depth_test = true
	_building_selection_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	_ghost_green = _transparent_material(Color(0.25, 1.0, 0.38, 0.34))
	_ghost_red = _transparent_material(Color(1.0, 0.28, 0.22, 0.38))
	_ghost_box = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	_ghost_box.mesh = box
	_ghost_box.material_override = _ghost_green
	_ghost_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost_box.visible = false
	world.add_child(_ghost_box)
	for i in 9:
		var tile_box := MeshInstance3D.new()
		tile_box.mesh = box
		tile_box.material_override = _ghost_green
		tile_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tile_box.visible = false
		world.add_child(tile_box)
		_brush_boxes.append(tile_box)

	_selection_box_mesh = ImmediateMesh.new()
	_selection_box_instance = MeshInstance3D.new()
	_selection_box_instance.mesh = _selection_box_mesh
	_selection_box_instance.material_override = _building_selection_material
	_selection_box_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_selection_box_instance.visible = false
	world.add_child(_selection_box_instance)


## Shared PBR material library. Every texture is a real 1K CC0 scan imported
## with VRAM compression; the maps stay cached so every building, vehicle and
## kit prop samples one copy of each texture on Android.
func _pbr_texture(role: String, file: String) -> Texture2D:
	var key := role + "/" + file
	if _pbr_textures.has(key):
		return _pbr_textures[key]
	var tex: Texture2D = null
	var path := PBR_DIR + key
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_pbr_textures[key] = tex
	return tex


func _pbr_material(role: String) -> StandardMaterial3D:
	if _pbr_materials.has(role):
		return _pbr_materials[role]
	var mat := StandardMaterial3D.new()
	mat.resource_name = "PBR_" + role
	var scale := 0.5
	var normal_scale := 0.75
	var metallic := 0.0
	var tint := Color(1.0, 1.0, 1.0)
	match role:
		"sand":
			scale = 0.34
			normal_scale = 0.62
			tint = Color(1.10, 0.965, 0.790)
		"rock":
			scale = 0.42
			normal_scale = 0.80
			tint = Color(1.32, 0.940, 0.680)
		"concrete":
			scale = 0.45
			normal_scale = 0.72
			tint = Color(1.04, 0.955, 0.830)
		"corrugated":
			scale = 0.62
			normal_scale = 0.85
			metallic = 0.38
			tint = Color(1.30, 1.18, 0.98)
		"metal_plates":
			scale = 0.58
			normal_scale = 0.78
			metallic = 0.50
			tint = Color(1.42, 1.30, 1.08)
		"rust":
			scale = 0.52
			normal_scale = 0.88
			metallic = 0.20
			tint = Color(1.20, 0.94, 0.68)
	mat.albedo_texture = _pbr_texture(role, "Color.jpg")
	mat.albedo_color = tint
	mat.normal_enabled = true
	mat.normal_texture = _pbr_texture(role, "NormalGL.jpg")
	mat.normal_scale = normal_scale
	mat.roughness_texture = _pbr_texture(role, "Roughness.jpg")
	mat.roughness = 1.0
	mat.metallic = metallic
	mat.metallic_specular = 0.5
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = false
	mat.uv1_scale = Vector3.ONE * scale
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	_pbr_materials[role] = mat
	return mat


## Assign a real PBR set to an imported GLB surface in place. The surface keeps
## its material resource (and therefore its FactionTrim contract and ink pass),
## but gains scanned albedo, normal and roughness in one shared texture.
func _apply_pbr_to_surface(mat: StandardMaterial3D, role: String) -> void:
	var pbr := _pbr_material(role)
	if pbr == null:
		return
	mat.albedo_texture = pbr.albedo_texture
	mat.albedo_color = pbr.albedo_color
	mat.normal_enabled = true
	mat.normal_texture = pbr.normal_texture
	mat.normal_scale = pbr.normal_scale
	mat.roughness_texture = pbr.roughness_texture
	mat.roughness = 1.0
	mat.metallic = pbr.metallic
	mat.metallic_specular = 0.5
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = false
	mat.uv1_scale = pbr.uv1_scale
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	# Painted / faction surfaces are deliberately excluded by _pbr_role_for;
	# the remaining industrial plating should read as lit metal, not toon fill.
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	mat.rim_enabled = true
	mat.rim = 0.12
	mat.rim_tint = 0.28


## Map authored material roles to the four architectural PBR sets. Painted
## livery (bone, ochre, sand, house colours) and every emissive/glass/cloth
## surface are skipped so the Dune palette and FactionTrim stay readable.
func _pbr_role_for(material_name: String, kind: String) -> String:
	var n := material_name.to_lower()
	if n.is_empty() or n.contains("faction") or n.contains("trim") or n.contains("runtime"):
		return ""
	# The sandworm is organic: keep its authored hide, scutes and gullet maps.
	if kind == "worm":
		return ""
	for skip in ["glass", "lamp", "glow", "plasma", "spice", "gas", "flame",
			"emitter", "eye", "tooth", "flesh", "gum", "hide", "cloth", "rubber",
			"cable", "banner", "screen", "status", "hazard", "yellow", "soot"]:
		if n.contains(skip):
			return ""
	if n.contains("rust"):
		return "rust"
	if n.contains("pad") or n.contains("concrete") or n.contains("slab"):
		return "concrete"
	if kind == "building" or kind == "turret_head":
		if n.contains("louver") or n.contains("roof") or n.contains("wall") or n.contains("corrugat"):
			return "corrugated"
		# Sun-baked paint and weathered umber panels are authored livery, not
		# bare structural metal; leave their baked maps intact.
		if n.contains("sun_baked") or n.contains("weathered") or n.contains("worn_"):
			return ""
		if n.contains("steel") or n.contains("gunmetal") or n.contains("armor") \
				or n.contains("grille") or n.contains("rim"):
			return "metal_plates"
		return ""
	if kind == "unit" or kind == "air":
		if n.contains("armor") or n.contains("hull") or n.contains("steel") \
				or n.contains("gunmetal") or n.contains("grille") or n.contains("rim"):
			return "metal_plates"
	return ""


## Unit-footprint beveled concrete plinth. Vertices are coloured per face so
## the chipped top edge catches the sun without a texture lookup (and therefore
## stays cheap on gl_compatibility).
func _make_foundation_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bottom := -0.060
	var top := FOUNDATION_TOP
	var inset := 0.075
	var top_col := Color(0.700, 0.620, 0.485)
	var side_col := Color(0.460, 0.395, 0.300)
	var dark_col := Color(0.21, 0.175, 0.13)
	var b0 := Vector3(-0.5, bottom, -0.5)
	var b1 := Vector3(0.5, bottom, -0.5)
	var b2 := Vector3(0.5, bottom, 0.5)
	var b3 := Vector3(-0.5, bottom, 0.5)
	var t0 := Vector3(-0.5 + inset, top, -0.5 + inset)
	var t1 := Vector3(0.5 - inset, top, -0.5 + inset)
	var t2 := Vector3(0.5 - inset, top, 0.5 - inset)
	var t3 := Vector3(-0.5 + inset, top, 0.5 - inset)
	_slab_tri(st, t0, t3, t2, Vector3.UP, top_col)
	_slab_tri(st, t0, t2, t1, Vector3.UP, top_col)
	_slab_quad(st, b0, b1, t1, t0, Vector3(0.0, 0.0, -1.0), side_col)
	_slab_quad(st, b1, b2, t2, t1, Vector3(1.0, 0.0, 0.0), side_col)
	_slab_quad(st, b2, b3, t3, t2, Vector3(0.0, 0.0, 1.0), side_col)
	_slab_quad(st, b3, b0, t0, t3, Vector3(-1.0, 0.0, 0.0), side_col)
	_slab_quad(st, b3, b2, b1, b0, Vector3.DOWN, dark_col)
	return st.commit()


func _slab_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		n: Vector3, col: Color) -> void:
	for p in [a, b, c]:
		st.set_normal(n)
		st.set_color(col)
		st.add_vertex(p)


func _slab_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		n: Vector3, col: Color) -> void:
	_slab_tri(st, a, b, c, n, col)
	_slab_tri(st, a, c, d, n, col)


func _add_foundation(rec: Dictionary, span: Vector2i) -> void:
	if foundation_mesh == null or foundation_mat == null:
		return
	var pad := MeshInstance3D.new()
	pad.name = "Foundation"
	pad.mesh = foundation_mesh
	pad.material_override = foundation_mat
	pad.scale = Vector3(float(span.x) + 0.20, 1.0, float(span.y) + 0.20)
	pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	rec["node"].add_child(pad)
	rec["foundation"] = pad


func _particle_material(color: Color, additive: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _soft_texture
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return mat


func _glow_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _transparent_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	return mat


# --------------------------------------------------------------- 3D terrain

func _build_terrain() -> void:
	map_size = int(GameDefs.MAP)
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load(TERRAIN_SHADER)
	sim_image = Image.create(map_size, map_size, false, Image.FORMAT_RGBA8)
	sim_texture = ImageTexture.create_from_image(sim_image)
	terrain_mat.set_shader_parameter("sim_map", sim_texture)
	terrain_mat.set_shader_parameter("map_size", float(map_size))
	# Real CC0 PBR scans replace the old flat procedural sand/rock/concrete
	# colour fields. The shader blends two world-space tiles per material so
	# the 1K scans never print a visible repeat across the 56-tile map.
	for role in ["sand", "rock", "concrete"]:
		terrain_mat.set_shader_parameter(role + "_color", _pbr_texture(role, "Color.jpg"))
		terrain_mat.set_shader_parameter(role + "_normal", _pbr_texture(role, "NormalGL.jpg"))
		terrain_mat.set_shader_parameter(role + "_rough", _pbr_texture(role, "Roughness.jpg"))

	_build_height_field()
	_build_terrain_geometry()

	# Hazy desert beyond the tactical grid keeps the map from reading as a
	# floating diorama. It is pure backdrop: no simulation values are read here.
	var backdrop := MeshInstance3D.new()
	backdrop.name = "DistantDesert"
	var plane := PlaneMesh.new()
	plane.size = Vector2(260.0, 260.0)
	backdrop.mesh = plane
	var haze_mat := StandardMaterial3D.new()
	haze_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	haze_mat.albedo_color = Color(0.42, 0.29, 0.18)
	haze_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	backdrop.material_override = haze_mat
	# Keep the haze plane below the deepest dune trough (-0.17) and the sand
	# base (0.0), otherwise it occludes low terrain as flat tile-shaped holes.
	backdrop.position.y = -0.35
	backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(backdrop)
	_build_distant_dunes()


## Long, soft dune ridges beyond the tactical grid. The playfield itself is a
## clean 56x56 plateau; without these the horizon reads as a flat orange wall.
## They are batched into one MultiMesh and sit outside the simulation bounds.
func _build_distant_dunes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 90417
	var center := float(map_size) * 0.5
	var transforms: Array[Transform3D] = []
	for i in 16:
		var angle := TAU * float(i) / 16.0 + rng.randf_range(-0.08, 0.08)
		var radius := rng.randf_range(78.0, 112.0)
		var p := Vector3(center + cos(angle) * radius, -0.4,
			center + sin(angle) * radius)
		var w := rng.randf_range(17.0, 31.0)
		var h := rng.randf_range(2.6, 6.0)
		var l := rng.randf_range(10.0, 22.0)
		var yaw := angle + rng.randf_range(-0.6, 0.6)
		var basis := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(w, h, l))
		transforms.append(Transform3D(basis, p))
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = transforms.size()
	var span := float(map_size) * 1.5
	mm.custom_aabb = AABB(Vector3(center - span, -8.0, center - span),
		Vector3(span * 2.0, 18.0, span * 2.0))
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var inst := MultiMeshInstance3D.new()
	inst.name = "DistantDuneRidges"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.61, 0.475, 0.335)
	mat.roughness = 0.98
	mat.metallic = 0.0
	mat.metallic_specular = 0.12
	inst.material_override = mat
	world.add_child(inst)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2,
		na: Vector3, nb: Vector3, nc: Vector3) -> void:
	st.set_uv(ua)
	st.set_normal(na)
	st.add_vertex(a)
	st.set_uv(ub)
	st.set_normal(nb)
	st.add_vertex(b)
	st.set_uv(uc)
	st.set_normal(nc)
	st.add_vertex(c)


func _build_terrain_geometry() -> void:
	if terrain_mesh != null and is_instance_valid(terrain_mesh):
		world.remove_child(terrain_mesh)
		terrain_mesh.queue_free()
	terrain_mesh = null
	if height_field.is_empty() or height_size <= 1:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cells := height_cells
	var denom := float(cells)
	for z in cells:
		for x in cells:
			var a := _field_vertex(x, z)
			var b := _field_vertex(x + 1, z)
			var c := _field_vertex(x, z + 1)
			var d := _field_vertex(x + 1, z + 1)
			var na := _field_normal(x, z)
			var nb := _field_normal(x + 1, z)
			var nc := _field_normal(x, z + 1)
			var nd := _field_normal(x + 1, z + 1)
			var u0 := float(x) / denom
			var v0 := float(z) / denom
			var u1 := float(x + 1) / denom
			var v1 := float(z + 1) / denom
			_tri(st, a, b, c, Vector2(u0, v0), Vector2(u1, v0), Vector2(u0, v1), na, nb, nc)
			_tri(st, b, d, c, Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1), nb, nd, nc)
	# Tangents let the shader's procedural ripple normal catch the low sun.
	st.generate_tangents()
	var mesh := st.commit()
	terrain_mesh = MeshInstance3D.new()
	terrain_mesh.name = "ModernTerrain"
	terrain_mesh.mesh = mesh
	terrain_mesh.material_override = terrain_mat
	# The terrain only receives shadows. Letting the dense dune mesh cast into
	# the directional shadow map produced per-triangle acne on gl_compatibility;
	# buildings and units still cast clean shadows onto it.
	terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(terrain_mesh)


func _field_index(ix: int, iz: int) -> int:
	var x := clampi(ix, 0, height_size - 1)
	var z := clampi(iz, 0, height_size - 1)
	return z * height_size + x


func _field_vertex(ix: int, iz: int) -> Vector3:
	return Vector3(float(ix) / float(TERRAIN_SUBDIV),
		height_field[_field_index(ix, iz)], float(iz) / float(TERRAIN_SUBDIV))


func _field_normal(ix: int, iz: int) -> Vector3:
	var hl := height_field[_field_index(ix - 1, iz)]
	var hr := height_field[_field_index(ix + 1, iz)]
	var hu := height_field[_field_index(ix, iz - 1)]
	var hd := height_field[_field_index(ix, iz + 1)]
	return Vector3(hl - hr, 2.0 / float(TERRAIN_SUBDIV), hu - hd).normalized()


func _build_height_field() -> void:
	height_cells = map_size * TERRAIN_SUBDIV
	height_size = height_cells + 1
	height_field.resize(height_size * height_size)
	for iz in height_size:
		for ix in height_size:
			height_field[iz * height_size + ix] = _raw_terrain_height(
				float(ix) / float(TERRAIN_SUBDIV), float(iz) / float(TERRAIN_SUBDIV))

	# 3x3 binomial smoothing before pads. This rounds the old one-tile stair
	# steps into broad mesa shoulders while preserving the flat tops.
	var smoothed := height_field.duplicate()
	for iz in height_size:
		for ix in height_size:
			var sum := 0.0
			var wsum := 0.0
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var wx := 4 if dx == 0 else (2 if absi(dx) == 1 else 1)
					var wz := 4 if dz == 0 else (2 if absi(dz) == 1 else 1)
					var w := float(wx * wz) / 16.0
					sum += height_field[_field_index(ix + dx, iz + dz)] * w
					wsum += w
			smoothed[iz * height_size + ix] = sum / wsum
	height_field = smoothed

	# Structures get a strictly flat pad. Rock pads sit at the exact plateau
	# height; sand/concrete pads sit at the highest raw sample under the hull
	# so no terrain triangle can rise into the foundation.
	if game != null:
		for b in game.buildings:
			if is_instance_valid(b) and not b.dead:
				_flatten_building_pad(b, _pad_height_for_building(b))


func _raw_terrain_height(gx: float, gz: float) -> float:
	var sand := _sand_height(gx, gz)
	var warp := _terrain_edge_warp(gx, gz)
	var mask := _rock_mask_at(gx + warp.x, gz + warp.y)
	var plateau := smoothstep(0.36, 0.68, mask)
	if plateau >= 0.985:
		return ROCK_HEIGHT
	return lerpf(sand, ROCK_HEIGHT, plateau)


func _sand_height(gx: float, gz: float) -> float:
	# Domain-warp the dune field so crests bend and breathe instead of running
	# as a perfectly regular sinusoid across the tactical grid.
	var wx := sin(gz * 1.70 + gx * 0.63) * 0.55 + sin(gx * 3.10 - gz * 1.90) * 0.18
	var wz := cos(gx * 1.30 - gz * 0.71) * 0.50 + sin(gz * 3.70 + gx * 2.20) * 0.16
	var px := gx + wx
	var pz := gz + wz
	var dune := sin(px * 0.67 + 0.8) * cos(pz * 0.53 - 0.4) * 0.135
	dune += sin((px + pz) * 0.27) * 0.085
	dune += sin(px * 0.19 - pz * 0.23) * 0.055
	return dune


func _terrain_edge_warp(gx: float, gz: float) -> Vector2:
	return Vector2(
		sin(gz * 1.43 + gx * 0.37) * 0.32 + sin(gx * 4.10 - gz * 2.70) * 0.09,
		sin(gx * 1.11 - gz * 0.51) * 0.30 + sin(gz * 3.80 + gx * 2.20) * 0.08)


func _rock_tile_at(x: int, z: int) -> bool:
	if game == null or game.terrain == null:
		return false
	var n := map_size
	if x < 0 or z < 0 or x >= n or z >= n:
		return false
	var i: int = z * n + x
	return game.terrain.types.size() > i and game.terrain.types[i] == GameDefs.ROCK


func _rock_mask_at(gx: float, gz: float) -> float:
	# Gaussian-ish footprint over neighbouring tile centres. Combined with the
	# warp above this gives plateau rims a curved, weathered contour rather
	# than a one-tile staircase.
	var cx := int(floor(gx))
	var cz := int(floor(gz))
	var sum := 0.0
	var wsum := 0.0
	for tz in range(cz - 2, cz + 3):
		for tx in range(cx - 2, cx + 3):
			var d := Vector2(float(tx) + 0.5, float(tz) + 0.5).distance_to(Vector2(gx, gz))
			if d > 2.05:
				continue
			var w := pow(1.0 - d / 2.05, 2.0)
			sum += (1.0 if _rock_tile_at(tx, tz) else 0.0) * w
			wsum += w
	return sum / maxf(wsum, 0.0001)


func _pad_height_for_building(b) -> float:
	if game == null or game.terrain == null:
		return ROCK_HEIGHT
	var span := GameDefs.size_of(b.type_id)
	var origin: Vector2i = b.tile_origin()
	var any_rock := false
	for tz in range(origin.y, origin.y + span.y):
		for tx in range(origin.x, origin.x + span.x):
			if _rock_tile_at(tx, tz):
				any_rock = true
				break
		if any_rock:
			break
	if any_rock:
		return ROCK_HEIGHT
	var center: Vector2 = b.global_position * WORLD_SCALE
	var half := Vector2(span) * 0.5
	var highest := _raw_terrain_height(center.x, center.y)
	for dz in [-0.5, 0.0, 0.5]:
		for dx in [-0.5, 0.0, 0.5]:
			highest = maxf(highest, _raw_terrain_height(
				center.x + dx * half.x, center.y + dz * half.y))
	return highest


func _flatten_building_pad(b, pad_y: float) -> void:
	var span := GameDefs.size_of(b.type_id)
	var center: Vector2 = b.global_position * WORLD_SCALE
	var half := Vector2(span) * 0.5
	var x0 := int(floor((center.x - half.x - PAD_MARGIN) * float(TERRAIN_SUBDIV)))
	var x1 := int(ceil((center.x + half.x + PAD_MARGIN) * float(TERRAIN_SUBDIV)))
	var z0 := int(floor((center.y - half.y - PAD_MARGIN) * float(TERRAIN_SUBDIV)))
	var z1 := int(ceil((center.y + half.y + PAD_MARGIN) * float(TERRAIN_SUBDIV)))
	for iz in range(maxi(0, z0), mini(height_size, z1 + 1)):
		for ix in range(maxi(0, x0), mini(height_size, x1 + 1)):
			height_field[_field_index(ix, iz)] = pad_y


func _sample_height_field(gx: float, gz: float) -> float:
	if height_field.is_empty():
		return _raw_terrain_height(gx, gz)
	var px := clampf(gx * float(TERRAIN_SUBDIV), 0.0, float(height_cells))
	var pz := clampf(gz * float(TERRAIN_SUBDIV), 0.0, float(height_cells))
	var x0 := int(floor(px))
	var z0 := int(floor(pz))
	var x1 := mini(x0 + 1, height_cells)
	var z1 := mini(z0 + 1, height_cells)
	var fx := px - float(x0)
	var fz := pz - float(z0)
	var h00 := height_field[_field_index(x0, z0)]
	var h10 := height_field[_field_index(x1, z0)]
	var h01 := height_field[_field_index(x0, z1)]
	var h11 := height_field[_field_index(x1, z1)]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)


func _height_at(x: int, z: int) -> float:
	return _sample_height_field(float(x), float(z))


func _update_sim_image() -> void:
	if sim_image == null or game == null or game.terrain == null:
		return
	var t = game.terrain
	var n := mini(map_size, int(sqrt(float(t.types.size()))))
	if n <= 0:
		return
	for y in n:
		for x in n:
			var i: int = y * n + x
			var rock := 255 if t.types[i] == GameDefs.ROCK else 0
			var spice := int(clampf(t.spice[i] / 220.0, 0.0, 1.0) * 255.0)
			var concrete := 255 if t.concrete[i] == 1 else 0
			var shroud := 0
			if t.seen[i] == 0:
				shroud = 255
			elif t.lit[i] == 0:
				shroud = 138
			sim_image.set_pixel(x, y, Color8(rock, spice, concrete, shroud))
	sim_texture.update(sim_image)


func _sync_terrain() -> void:
	_update_sim_image()


## Bilinear sample of the rendered sub-tile height field, so a unit cresting
## a dune or a structure pad on a plateau sits on the visible surface.
func ground_height(world: Vector2) -> float:
	if game == null or game.terrain == null:
		return SAND_HEIGHT
	var gx := world.x * WORLD_SCALE
	var gz := world.y * WORLD_SCALE
	if gx < 0.0 or gz < 0.0 or gx >= float(map_size) or gz >= float(map_size):
		return SAND_HEIGHT
	return _sample_height_field(gx, gz)


## Interpolated surface normal, used by ground decals so treads and craters
## follow dunes instead of floating flat across a slope.
func ground_normal(world: Vector2) -> Vector3:
	var e := 0.22
	var step := e * float(TILE)
	var hl := ground_height(world - Vector2(step, 0.0))
	var hr := ground_height(world + Vector2(step, 0.0))
	var hu := ground_height(world - Vector2(0.0, step))
	var hd := ground_height(world + Vector2(0.0, step))
	return Vector3(-(hr - hl) / (2.0 * e), 1.0, -(hd - hu) / (2.0 * e)).normalized()


# ------------------------------------------------------------------- camera

func _update_camera() -> void:
	if camera == null:
		return
	var center := Vector3(focus_px.x * WORLD_SCALE, 0.0, focus_px.y * WORLD_SCALE)
	var distance := CAMERA_BASE_DISTANCE / maxf(camera_zoom, 0.05)
	var offset := Vector3(
		sin(camera_yaw) * cos(CAMERA_PITCH),
		sin(CAMERA_PITCH),
		cos(camera_yaw) * cos(CAMERA_PITCH)) * distance
	camera.position = center + offset
	camera.look_at(center, Vector3.UP)


func _clamp_focus(p: Vector2) -> Vector2:
	# focus_px is stored in battlefield pixels, exactly like Camera2D.position.
	# Keep the camera footprint over the tactical map too: focusing on the map
	# edge at close zoom used to put the physical camera inside the distant
	# dune spheres, filling the screen with the underside of the backdrop.
	var distance := CAMERA_BASE_DISTANCE / maxf(camera_zoom, 0.05)
	var horizontal := distance * cos(CAMERA_PITCH)
	var limit := float(map_size * TILE)
	# horizontal is in world tiles; p and limit are in battlefield pixels.
	var margin_px := minf((horizontal + 0.8) * float(TILE), limit * 0.35)
	return p.clamp(Vector2(margin_px, margin_px),
		Vector2(limit - margin_px, limit - margin_px))


func focus_world(pos: Vector2) -> void:
	focus_px = _clamp_focus(pos)
	_update_camera()


func focus_home() -> void:
	if game == null:
		return
	var span := Vector2.ZERO
	var count := 0
	for b in game.buildings:
		if is_instance_valid(b) and not b.dead and b.team == 0:
			span += b.global_position
			count += 1
	if count > 0:
		focus_world(span / float(count))


## Free orbit. Used by Shift + middle-drag; manual control always stops the
## automatic base spin so the two controls never fight each other.
func orbit_by(radians: float) -> void:
	auto_orbit = false
	camera_yaw = wrapf(camera_yaw + radians, -PI, PI)
	_update_camera()


func set_auto_orbit(on: bool) -> void:
	auto_orbit = on and active


func zoom_by(factor: float) -> void:
	camera_zoom = clampf(camera_zoom * factor, CAMERA_MIN_ZOOM, CAMERA_MAX_ZOOM)
	_update_camera()


func zoom_at(factor: float, screen_pos: Vector2) -> void:
	var before := world_from_screen(screen_pos)
	camera_zoom = clampf(camera_zoom * factor, CAMERA_MIN_ZOOM, CAMERA_MAX_ZOOM)
	_update_camera()
	var after := world_from_screen(screen_pos)
	focus_px = _clamp_focus(focus_px + (before - after))
	_update_camera()


## Drag the ground with the pointer: the world point under the finger stays
## pinned. This naturally follows the 45-degree camera axes without special
## per-axis correction.
func pan_screen_drag(from: Vector2, to: Vector2) -> void:
	var before := world_from_screen(from)
	var after := world_from_screen(to)
	focus_px = _clamp_focus(focus_px + (before - after))
	_update_camera()


## Move the camera in screen space, used by arrow keys and keyboard panning.
func pan_camera_screen(delta: Vector2) -> void:
	if delta.length_squared() <= 0.0001:
		return
	var center := get_viewport().get_visible_rect().size * 0.5
	var before := world_from_screen(center)
	var after := world_from_screen(center + delta)
	focus_px = _clamp_focus(focus_px + (after - before))
	_update_camera()


func screen_to_ground(screen_pos: Vector2) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)
	if hit == null:
		return Vector3(focus_px.x * WORLD_SCALE, 0.0, focus_px.y * WORLD_SCALE)
	return hit


func world_from_screen(screen_pos: Vector2) -> Vector2:
	var hit := screen_to_ground(screen_pos)
	return Vector2(hit.x * float(TILE), hit.z * float(TILE))


## Click picking against the visible 3D models. A flat-ground ray lands behind
## the upper body of a tall unit or structure, which makes the model seem dead
## to clicks. Project each model's world AABB to screen space, choose the
## nearest one under the cursor and return its battlefield-pixel base. The
## game's normal ground raycast remains in charge of movement and placement.
func pick_entity(screen_pos: Vector2) -> Vector2:
	if not active or camera == null:
		return Vector2.INF
	var best := Vector2.INF
	var best_depth := INF
	for id in _entities:
		var rec: Dictionary = _entities[id]
		var kind := String(rec.get("kind", ""))
		if kind != "unit" and kind != "building":
			continue
		var node = rec.get("node")
		var holder = rec.get("holder")
		if node == null or not is_instance_valid(node) or not node.visible:
			continue
		if holder == null or not is_instance_valid(holder):
			continue
		var rect := _screen_rect(holder)
		if rect.size.x <= 0.0 or rect.size.y <= 0.0 or not rect.has_point(screen_pos):
			continue
		var depth := camera.global_position.distance_squared_to((node as Node3D).global_position)
		if depth < best_depth:
			best_depth = depth
			var p: Vector3 = (node as Node3D).global_position
			best = Vector2(p.x / WORLD_SCALE, p.z / WORLD_SCALE)
	return best


func _screen_rect(holder: Node3D) -> Rect2:
	var bounds := AABB()
	var has := false
	for child in holder.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = mi.global_transform * mi.mesh.get_aabb()
		if has:
			bounds = bounds.merge(box)
		else:
			bounds = box
			has = true
	if not has:
		return Rect2()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var any := false
	for i in 8:
		var corner := bounds.get_endpoint(i)
		if camera.is_position_behind(corner):
			continue
		var p := camera.unproject_position(corner)
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		any = true
	if not any:
		return Rect2()
	var pad := 4.0
	return Rect2(lo - Vector2(pad, pad), hi - lo + Vector2(pad * 2.0, pad * 2.0))


# --------------------------------------------------------------- entity sync

func _process(delta: float) -> void:
	if not active or not built:
		return
	if auto_orbit:
		camera_yaw = wrapf(camera_yaw + AUTO_ORBIT_SPEED * delta, -PI, PI)
		_update_camera()
	_terrain_clock += delta
	_atmosphere_clock += delta
	if _atmosphere_clock >= 0.50:
		_atmosphere_clock = 0.0
		_follow_atmosphere()
	if _terrain_clock >= 0.20:
		_terrain_clock = 0.0
		_sync_terrain()
	_sync_entities(delta)
	if terrain_dirty:
		terrain_dirty = false
		_build_height_field()
		_build_terrain_geometry()
	_sync_fx()
	_sync_ghost()
	_sync_selection_box()
	if bar_overlay != null:
		bar_overlay.queue_redraw()


func _sync_entities(delta: float) -> void:
	if game == null:
		return
	var alive: Dictionary = {}
	for b in game.buildings:
		if is_instance_valid(b) and not b.dead:
			alive[b.get_instance_id()] = true
			_sync_building(b, delta)
	for u in game.units:
		if is_instance_valid(u) and not u.dead:
			alive[u.get_instance_id()] = true
			_sync_unit(u, delta)
	for c in game.carryalls:
		if is_instance_valid(c):
			alive[c.get_instance_id()] = true
			_sync_aircraft_like(c, "carryall", 1.5 + float(c.altitude) * 1.7, delta)
	for f in game.frigates:
		if is_instance_valid(f):
			alive[f.get_instance_id()] = true
			_sync_aircraft_like(f, "frigate", 2.5 + float(f.altitude) * 4.0, delta)
	if is_instance_valid(game.choam_frigate):
		alive[game.choam_frigate.get_instance_id()] = true
		_sync_aircraft_like(game.choam_frigate, "frigate", 2.5 + float(game.choam_frigate.altitude) * 4.0, delta)
	for a in game.aircraft:
		if is_instance_valid(a):
			alive[a.get_instance_id()] = true
			if a is Ornithopter:
				_sync_aircraft_like(a, "ornithopter", 1.0 + float(a.altitude) * 1.7, delta)
	for w in game.worms:
		if is_instance_valid(w):
			alive[w.get_instance_id()] = true
			_sync_worm(w, delta)
	for child in game.get_children():
		if child is BallisticProjectile or child is RocketProjectile \
				or child is AirstrikeMissile or child is DeathHand:
			alive[child.get_instance_id()] = true
			_sync_projectile(child)
	for id in _entities.keys():
		if alive.has(id):
			continue
		var rec: Dictionary = _entities[id]
		if is_instance_valid(rec.get("node")):
			rec["node"].queue_free()
		_entities.erase(id)


func _sync_building(b, delta: float) -> void:
	var id: int = b.get_instance_id()
	var rec = _entities.get(id)
	if rec == null:
		rec = _spawn_model(b, "building", b.type_id, 1.0)
		if rec == null:
			return
		if b.type_id == "turret" or b.type_id == "rocketturret":
			var head_rec = _spawn_model(b, "turret_head", b.type_id + "_head", 1.0, false)
			if head_rec != null:
				# Parent the head holder inside the base holder so the base's
				# recursive FactionTrim pass also recolours the rotating head.
				var head_holder: Node3D = head_rec["holder"]
				var head_root: Node3D = head_rec["node"]
				head_holder.reparent(rec["holder"], false)
				head_holder.position = Vector3(0.0, 0.50, 0.0)
				head_root.queue_free()
				rec["head"] = head_holder
		rec["span"] = GameDefs.size_of(b.type_id)
		rec["height"] = float(rec.get("model_height", 1.4))
		rec["pad_y"] = _pad_height_for_building(b)
		if b.type_id != "wall":
			_add_foundation(rec, rec["span"])
		_add_building_kit_upgrades(rec, b)
		_add_health_bar(rec)
		_add_smoke(rec)
		_add_selection_ring(rec, 1.0)
		# The terrain mesh did not know about this footprint when it was first
		# built. Rebuild the height field once, outside the entity loop.
		terrain_dirty = true
		if b.type_id in ["refinery", "factory", "heavy_factory", "silo", "cy",
				"hightech", "ix", "palace", "outpost"]:
			# Live plant exhaust is the strongest cue that a 3D base is running,
			# not a static diorama. The measured roof height keeps the stack at the
			# crown of each authored model rather than a shared constant.
			var roof := float(rec.get("model_height", 1.4))
			var stack_x := float(GameDefs.size_of(b.type_id).x) * 0.18
			var stack_z := -float(GameDefs.size_of(b.type_id).y) * 0.16
			if b.type_id == "refinery":
				stack_x = float(GameDefs.size_of(b.type_id).x) * 0.28
				stack_z = float(GameDefs.size_of(b.type_id).y) * 0.26
			# Sample the real roof under the stack instead of a fraction of the
			# AABB, which includes cranes and antennae.
			var stack_y := _roof_surface_height(rec, stack_x, stack_z, roof * 0.55)
			var stack_pos := Vector3(stack_x, stack_y, stack_z)
			# Give the plume a real stack to rise from. The authored models have
			# vents and louvres, but no unmistakable chimney at this camera scale;
			# a short soot-dark pipe makes the live exhaust legible and plants it
			# physically on the roof instead of floating above the silhouette.
			var stack_h := 0.56 if b.type_id == "refinery" else 0.40
			if b.type_id in ["refinery", "factory", "heavy_factory", "silo", "hightech"]:
				stack_pos = _add_vent_stack(rec, stack_pos + Vector3(0.0, -0.10, 0.0), stack_h)
			_add_building_exhaust(rec, stack_pos,
				16 if b.type_id == "refinery" else 11)
	var root: Node3D = rec["node"]
	var fog_visible: bool = b.team == 0 or game.terrain.is_visible_at(b.global_position)
	root.visible = fog_visible
	if not fog_visible:
		return
	root.position = Vector3(b.global_position.x * WORLD_SCALE,
		float(rec.get("pad_y", ground_height(b.global_position))), b.global_position.y * WORLD_SCALE)
	root.rotation.y = 0.0
	var head = rec.get("head")
	if head != null and is_instance_valid(head):
		head.rotation.y = lerp_angle(head.rotation.y, -float(b.aim), clampf(delta * 12.0, 0.0, 1.0))
	_update_trim(rec, b.team)
	_update_selection(rec, game.selected_build == b)
	_update_health(rec, b.hp, b.max_hp, game.selected_build == b)
	var smoke = rec.get("smoke")
	if smoke != null and is_instance_valid(smoke):
		smoke.emitting = b.hp < b.max_hp * 0.60
	var exhaust = rec.get("exhaust")
	if exhaust != null and is_instance_valid(exhaust):
		var powered: bool = bool(b.get("powered"))
		exhaust.emitting = fog_visible and powered


func _sync_unit(u, delta: float) -> void:
	var id: int = u.get_instance_id()
	var rec = _entities.get(id)
	if rec == null:
		rec = _spawn_model(u, "unit", u.type_id, float(UNIT_SCALES.get(u.type_id, 0.5)))
		if rec == null:
			return
		rec["height"] = float(rec.get("model_height", 0.9))
		_add_health_bar(rec)
		_add_smoke(rec)
		_add_selection_ring(rec, 0.62 if u.type_id in ["infantry", "rocket", "fremen", "sardaukar", "saboteur"] else 1.0)
		if TRACK_TYPES.has(u.type_id):
			_add_track_dust(rec, u.type_id)
		if u.type_id == "harvester":
			_add_harvester_exhaust(rec)
		elif u.type_id in ["tank", "atreides_tank", "harkonnen_tank", "ordos_tank", "sonic_tank", "devastator", "mcv"]:
			_add_exhaust(rec, Vector3(-0.22, float(rec.get("model_height", 0.8)) * 0.92, 0.0),
				Color(0.55, 0.47, 0.38, 0.55), 6)
	var root: Node3D = rec["node"]
	var fog_visible: bool = u.team == 0 or game.terrain.is_visible_at(u.global_position)
	root.visible = fog_visible and not u.airborne
	if not root.visible:
		return
	root.position = Vector3(u.global_position.x * WORLD_SCALE,
		ground_height(u.global_position), u.global_position.y * WORLD_SCALE)
	root.rotation.y = lerp_angle(root.rotation.y, -float(u.facing), clampf(delta * 11.0, 0.0, 1.0))
	_update_trim(rec, u.team)
	_update_selection(rec, game.selected.has(u))
	_update_health(rec, u.hp, u.max_hp, game.selected.has(u))
	var smoke = rec.get("smoke")
	if smoke != null and is_instance_valid(smoke):
		smoke.emitting = u.hp < u.max_hp * 0.60
	_sync_vehicle_ground_fx(rec, u, delta)


func _sync_aircraft_like(entity, model_id: String, altitude: float, delta: float) -> void:
	var id: int = entity.get_instance_id()
	var rec = _entities.get(id)
	if rec == null:
		var scale: float = float(UNIT_SCALES.get(model_id, 0.6))
		rec = _spawn_model(entity, "air", model_id, scale)
		if rec == null:
			return
		rec["height"] = 1.0
		_add_selection_ring(rec, 1.15)
	var root: Node3D = rec["node"]
	var fog_visible := true
	if entity.get("team") != null:
		fog_visible = int(entity.get("team")) == 0 or game.terrain.is_visible_at(entity.global_position)
	if entity.get("delay") != null and float(entity.get("delay")) > 0.0:
		fog_visible = false
	root.visible = fog_visible
	if not fog_visible:
		return
	root.position = Vector3(entity.global_position.x * WORLD_SCALE,
		ground_height(entity.global_position) + altitude,
		entity.global_position.y * WORLD_SCALE)
	root.rotation.y = lerp_angle(root.rotation.y, -float(entity.get("facing")), clampf(delta * 4.5, 0.0, 1.0))
	if entity.get("team") != null:
		_update_trim(rec, int(entity.get("team")))
	if entity is Ornithopter:
		_update_health(rec, entity.hp, entity.max_hp, false)
	else:
		_update_selection(rec, false)
	if rec.get("exhaust") != null and is_instance_valid(rec["exhaust"]):
		rec["exhaust"].emitting = fog_visible


func _sync_worm(w, delta: float) -> void:
	var id: int = w.get_instance_id()
	var rec = _entities.get(id)
	if rec == null:
		rec = _spawn_model(w, "worm", "sandworm", float(UNIT_SCALES["sandworm"]))
		if rec == null:
			return
		rec["height"] = float(rec.get("model_height", 2.8))
		_add_selection_ring(rec, 1.8)
		_add_worm_sign(rec)
		rec["last_worm_state"] = ""
		rec["worm_burst_done"] = false
	var root: Node3D = rec["node"]
	var pivot: Node3D = rec.get("pivot")
	var sign_root: Node3D = rec.get("worm_sign")
	var tile: Vector2i = game.terrain.tile_of(w.global_position)
	var seen: bool = game.terrain.is_seen_tile(tile.x, tile.y)
	var state := String(w.state)
	var digging := state == "dig"
	var digging_visible := digging and float(w.get("dig_anim")) < 1.05
	var surfaced := state == "surface" or state == "bite"
	var show_model := seen and (surfaced or digging_visible)

	root.visible = show_model
	if sign_root != null and is_instance_valid(sign_root):
		sign_root.visible = seen and not show_model and state != "dormant"
	_update_selection(rec, false)
	rec["bar_show"] = false

	if String(rec["last_worm_state"]) != state:
		rec["last_worm_state"] = state
		rec["worm_burst_done"] = false
		if state == "surface":
			_stamp_crater(w.global_position, 1.7)
		elif state == "dig":
			_worm_debris_burst(w.global_position, 1.0)

	if not show_model:
		if sign_root != null and is_instance_valid(sign_root) and sign_root.visible:
			sign_root.position = Vector3(w.global_position.x * WORLD_SCALE,
				ground_height(w.global_position) + 0.012, w.global_position.y * WORLD_SCALE)
			sign_root.rotation.y = PI * 0.5 - float(w.move_dir.angle())
			var pulse := 1.0 + 0.045 * sin(float(w.clock) * 2.6)
			sign_root.scale = Vector3(1.0, 1.0, pulse)
			var ring = rec.get("worm_ring")
			if ring != null and is_instance_valid(ring):
				var wave := 0.5 + 0.5 * sin(float(w.clock) * 1.7)
				ring.scale = Vector3(1.0 + wave * 0.22, 1.0, 1.0 + wave * 0.22)
				ring.rotation.y = float(w.clock) * 0.35
			var dust = rec.get("worm_dust")
			if dust != null and is_instance_valid(dust):
				dust.emitting = true
		else:
			var dust = rec.get("worm_dust")
			if dust != null and is_instance_valid(dust):
				dust.emitting = false
		return

	if sign_root != null and is_instance_valid(sign_root):
		sign_root.visible = false
	var dust = rec.get("worm_dust")
	if dust != null and is_instance_valid(dust):
		dust.emitting = false

	var pos: Vector2 = w.global_position
	root.position = Vector3(pos.x * WORLD_SCALE, ground_height(pos), pos.y * WORLD_SCALE)
	var dir: Vector2 = w.move_dir
	if w.target != null and is_instance_valid(w.target):
		dir = w.target.global_position - pos
	if dir.length_squared() < 1.0:
		dir = w.move_dir
	if dir.length_squared() < 0.01:
		dir = Vector2.RIGHT
	# The GLB's maw and body arc along local +Z, so yaw is measured directly
	# from the world direction instead of the hull's -facing convention.
	# Present a three-quarter profile instead of aiming the maw straight down
	# the camera axis: the curving body, layered scutes and raised head must all
	# read in silhouette during the breach.
	var want_yaw := atan2(dir.x, dir.y) + 0.62 + sin(float(w.clock) * 1.6) * 0.05
	root.rotation.y = lerp_angle(root.rotation.y, want_yaw, clampf(delta * 6.0, 0.0, 1.0))

	var lift := 0.0
	var tilt := 0.0
	var lunge := 0.0
	var stretch := 1.0
	if state == "surface":
		var k := clampf(float(w.get("surface_time")) / 1.25, 0.0, 1.0)
		var rise := 1.0 - pow(1.0 - k, 3.0)
		lift = lerpf(-2.7, 0.0, rise)
		tilt = lerpf(-0.34, 0.06, rise)
		stretch = lerpf(0.80, 1.0, rise)
		if not bool(rec["worm_burst_done"]) and k > 0.20:
			rec["worm_burst_done"] = true
			_worm_debris_burst(pos, 1.35)
			_stamp_crater(pos, 1.9)
	elif state == "bite":
		var k := clampf(float(w.get("bite_time")) / 0.58, 0.0, 1.0)
		if k < 0.34:
			var rear := k / 0.34
			tilt = lerpf(0.06, -0.36, rear)
			lunge = lerpf(0.0, -0.30, rear)
			lift = lerpf(0.0, 0.18, rear)
		else:
			var snap := (k - 0.34) / 0.66
			var drive := 1.0 - pow(1.0 - snap, 2.0)
			tilt = lerpf(-0.36, 0.30, drive)
			lunge = lerpf(-0.30, 0.95, drive)
			lift = lerpf(0.18, -0.06, drive)
			stretch = lerpf(1.0, 1.04, sin(snap * PI))
			if not bool(rec["worm_burst_done"]) and snap > 0.08:
				rec["worm_burst_done"] = true
				_worm_debris_burst(pos + dir.normalized() * 42.0, 1.55)
				_stamp_crater(pos + dir.normalized() * 30.0, 1.4)
	elif digging:
		var k := clampf(float(w.get("dig_anim")) / 1.05, 0.0, 1.0)
		lift = lerpf(0.0, -2.8, pow(k, 1.5))
		tilt = lerpf(0.06, 0.34, k)
		stretch = lerpf(1.0, 0.90, k)

	if pivot != null and is_instance_valid(pivot):
		pivot.position = Vector3(0.0, lift, lunge)
		pivot.rotation.x = tilt
	root.scale = Vector3(stretch, stretch, stretch)


func _sync_projectile(p) -> void:
	var id: int = p.get_instance_id()
	var rec = _entities.get(id)
	if rec == null:
		rec = _spawn_projectile_visual(p)
		if rec == null:
			return
		_entities[id] = rec
	var root: Node3D = rec["node"]
	root.visible = true
	var pos: Vector2 = p.global_position
	var height := 0.22
	if p is BallisticProjectile:
		var progress := clampf(float(p.age) / maxf(float(p.flight_time), 0.001), 0.0, 1.0)
		height = 0.25 + sin(progress * PI) * (float(p.arc_height) / float(TILE))
	elif p is RocketProjectile:
		height = 0.38
	elif p is AirstrikeMissile:
		height = 2.2
	elif p is DeathHand:
		var flight: Vector2 = p.start.lerp(p.target, float(p.t))
		pos = flight
		height = sin(float(p.t) * PI) * float(p.altitude) / float(TILE)
	root.position = Vector3(pos.x * WORLD_SCALE, ground_height(pos) + height, pos.y * WORLD_SCALE)
	var vel = p.get("velocity")
	if vel is Vector2 and (vel as Vector2).length_squared() > 1.0:
		root.rotation.y = -(vel as Vector2).angle()


func _spawn_model(entity, kind: String, model_id: String, scale: float, register := true) -> Dictionary:
	var root := Node3D.new()
	root.name = "%s_%s" % [kind, model_id]
	world.add_child(root)
	# The pivot isolates presentation-only animation (worm rear/lunge, harvester
	# load bounce) from the yaw root and from the model's authored scale.
	var pivot := Node3D.new()
	pivot.name = "Pivot"
	root.add_child(pivot)
	var holder := Node3D.new()
	holder.scale = Vector3.ONE * scale
	pivot.add_child(holder)
	var path := (BUILDING_DIR if kind == "building" or kind == "turret_head" else UNIT_DIR) + model_id + ".glb"
	var scene: PackedScene = _load_model(path)
	if scene != null:
		var node = scene.instantiate()
		holder.add_child(node)
	else:
		# A missing import must never make a unit disappear from the battlefield.
		var fallback := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.8, 0.5, 0.8) if kind != "building" else Vector3(1.6, 1.2, 1.6)
		fallback.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.55, 0.39, 0.22)
		mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		mat.next_pass = ink_material
		fallback.material_override = mat
		holder.add_child(fallback)
	_apply_model_style(holder, kind, model_id)
	_apply_ink_variant(holder, kind, model_id)
	var rec := {
		"node": root,
		"root": root,
		"pivot": pivot,
		"holder": holder,
		"kind": kind,
		"model_id": model_id,
		"team": -99,
		"selected": false,
	}
	rec["model_height"] = _measure_model_height(holder)
	if kind == "building" and model_id != "wall":
		# Sit the authored hull on the top face of the beveled foundation,
		# measured from its own AABB rather than assuming every GLB bottoms
		# out at exactly y = 0.
		var bottom := _model_bottom(holder)
		holder.position.y = FOUNDATION_LIFT - bottom
	if register:
		_entities[entity.get_instance_id()] = rec
	return rec


## Give every imported surface the shared concept-art treatment: an inverted
## hull ink pass plus a crisp, warm toon ramp. Materials are shared by the
## cached GLB scene, so each resource is touched once.
func _apply_model_style(holder: Node3D, kind := "", model_id := "") -> void:
	if ink_material == null or holder == null:
		return
	for child in holder.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var source = mi.get_active_material(i)
			if not (source is StandardMaterial3D):
				continue
			var mat := source as StandardMaterial3D
			var key := mat.get_instance_id()
			if _outlined_materials.has(key):
				continue
			_outlined_materials[key] = true
			mat.next_pass = ink_material
			mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
			mat.specular_mode = BaseMaterial3D.SPECULAR_TOON
			mat.rim_enabled = true
			mat.rim = 0.20
			mat.rim_tint = 0.38
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			# The GLB palette is authored to match the sunlit 2D art. In the
			# cinematic pass a straight 1:1 albedo looks chalky against the
			# reference, so pull the imported hulls toward warm weathered metal.
			# FactionTrim is recoloured at runtime and stays untouched.
			if not String(mat.resource_name).contains("FactionTrim"):
				mat.albedo_color = mat.albedo_color * Color(0.68, 0.66, 0.62, 1.0)
			if mat.normal_texture != null:
				mat.normal_scale = maxf(mat.normal_scale, 0.82)
			# Swap the baked 128px weathering map for a real CC0 PBR set where
			# the authored material is structural metal, roof, wall or slab.
			# FactionTrim, painted livery and emissive surfaces are untouched.
			var pbr_role := _pbr_role_for(String(mat.resource_name), kind)
			if not pbr_role.is_empty():
				_apply_pbr_to_surface(mat, pbr_role)


func _measure_model_height(holder: Node3D) -> float:
	var bounds := _model_bounds(holder)
	if bounds.size.y <= 0.0:
		return 1.0
	return maxf(0.35, bounds.size.y * holder.scale.y)


## Highest authored surface under a local X/Z point, in the building root's
## space. Roof props, trim and exhaust pipes use this instead of fractions of
## the whole AABB: a crane mast or antenna can make the AABB much taller than
## the actual roof, which is how hardware ended up hanging in mid-air.
func _roof_surface_height(rec: Dictionary, x: float, z: float, fallback := -INF) -> float:
	var node: Node3D = rec.get("node")
	var holder: Node3D = rec.get("holder")
	if node == null or holder == null or not is_instance_valid(node) \
			or not is_instance_valid(holder):
		return fallback
	var top := float(rec.get("model_height", 1.4)) + 2.0
	var from_node := Vector3(x, top, z)
	var best := -INF
	for child in holder.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var inv := mi.global_transform.affine_inverse() * node.global_transform
		var to_node := inv.affine_inverse()
		var local_from := inv * from_node
		var local_dir := inv.basis * Vector3.DOWN
		var mesh := mi.mesh
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts.is_empty():
				continue
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var indexed := not indices.is_empty()
			var count := indices.size() if indexed else verts.size()
			for t in range(0, count, 3):
				var i0 := indices[t] if indexed else t
				var i1 := indices[t + 1] if indexed else t + 1
				var i2 := indices[t + 2] if indexed else t + 2
				var hit = Geometry3D.ray_intersects_triangle(local_from, local_dir,
					verts[i0], verts[i1], verts[i2])
				if hit == null:
					continue
				var hit_node: Vector3 = to_node * (hit as Vector3)
				best = maxf(best, hit_node.y)
	if best == -INF:
		return fallback
	return best


func _model_bounds(holder: Node3D) -> AABB:
	var inv := holder.global_transform.affine_inverse()
	var bounds := AABB()
	var has := false
	for child in holder.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = (inv * mi.global_transform) * mi.mesh.get_aabb()
		if has:
			bounds = bounds.merge(box)
		else:
			bounds = box
			has = true
	if not has:
		return AABB()
	return bounds


func _model_bottom(holder: Node3D) -> float:
	var bounds := _model_bounds(holder)
	return bounds.position.y * holder.scale.y


func _apply_ink_variant(holder: Node3D, kind: String, model_id: String) -> void:
	if ink_small_material == null:
		return
	var variant: ShaderMaterial = null
	if kind == "building" or kind == "turret_head":
		variant = ink_building_material
	elif kind == "unit" and model_id in ["infantry", "rocket", "fremen", "sardaukar",
			"saboteur", "trike", "raider_trike"]:
		variant = ink_small_material
	if variant == null:
		return
	for child in holder.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var source = mi.get_active_material(i)
			if not (source is StandardMaterial3D):
				continue
			var mat := source as StandardMaterial3D
			if mat.next_pass == ink_material:
				mat.next_pass = variant


func _load_model(path: String) -> PackedScene:
	if _model_cache.has(path):
		return _model_cache[path]
	var scene: PackedScene = null
	if ResourceLoader.exists(path):
		scene = load(path) as PackedScene
	_model_cache[path] = scene
	return scene


func _update_trim(rec: Dictionary, team: int) -> void:
	if int(rec.get("team", -99)) == team:
		return
	rec["team"] = team
	var holder: Node3D = rec["holder"]
	if holder == null or not is_instance_valid(holder):
		return
	var mat := _trim_material(team)
	var kit_panel = rec.get("kit_trim")
	if kit_panel != null and is_instance_valid(kit_panel):
		kit_panel.material_override = mat
	for child in holder.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var source := mi.get_active_material(i)
			if source != null and String(source.resource_name).findn("FactionTrim") >= 0:
				mi.set_surface_override_material(i, mat)


func _trim_material(team: int) -> StandardMaterial3D:
	if _trim_materials.has(team):
		return _trim_materials[team]
	var col := Color(0.70, 0.52, 0.30)
	if team >= 0:
		col = GameDefs.team_color(team)
	elif team == -1:
		col = Color(0.55, 0.46, 0.34)
	var mat := StandardMaterial3D.new()
	mat.resource_name = "FactionTrimRuntime"
	mat.albedo_color = col
	mat.metallic = 0.26
	mat.roughness = 0.42
	mat.emission_enabled = true
	mat.emission = col.darkened(0.45)
	mat.emission_energy_multiplier = 0.32
	mat.next_pass = ink_small_material if ink_small_material != null else ink_material
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	mat.specular_mode = BaseMaterial3D.SPECULAR_TOON
	mat.rim_enabled = true
	mat.rim = 0.24
	mat.rim_tint = 0.40
	_trim_materials[team] = mat
	return mat


# ---------------------------------------------------------------- overlays

func _add_health_bar(rec: Dictionary) -> void:
	# Health is drawn as crisp 2D rectangles projected from the 3D anchor. No
	# billboarded 3D quads are used, so the bar never samples a texture or
	# shimmers with the camera.
	var width := 32.0
	if rec.get("kind") == "building":
		var span: Vector2i = rec.get("span", Vector2i.ONE)
		width = clampf(26.0 + float(maxi(span.x, span.y)) * 5.0, 30.0, 62.0)
	elif String(rec.get("model_id", "")) in ["harvester", "mcv", "devastator"]:
		width = 44.0
	rec["bar_w"] = width
	rec["bar_show"] = false
	rec["bar_ratio"] = 1.0
	rec["bar_band"] = 0


func _update_health(rec: Dictionary, hp: float, max_hp: float, force: bool) -> void:
	var ratio := clampf(hp / maxf(max_hp, 1.0), 0.0, 1.0)
	rec["bar_show"] = force or ratio < 0.999
	rec["bar_ratio"] = ratio
	var band := 0
	if ratio <= 0.33:
		band = 2
	elif ratio <= 0.66:
		band = 1
	rec["bar_band"] = band


func _add_smoke(rec: Dictionary) -> void:
	var smoke := _make_particles(12, 3.4, _smoke_puff_mat, 0.62)
	smoke.emission_sphere_radius = 0.42
	smoke.spread = 26.0
	smoke.initial_velocity_min = 0.22
	smoke.initial_velocity_max = 0.70
	smoke.gravity = Vector3(0.10, 0.32, 0.0)
	smoke.scale_amount_min = 0.55
	smoke.scale_amount_max = 1.55
	smoke.scale_amount_curve = _growth_curve(0.55, 1.9)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.22, 1.0])
	grad.colors = PackedColorArray([
		Color(0.34, 0.30, 0.25, 0.0), Color(0.23, 0.20, 0.17, 0.72),
		Color(0.42, 0.37, 0.31, 0.0)])
	smoke.color_ramp = grad
	smoke.preprocess = 1.1
	smoke.position.y = float(rec.get("height", 1.0)) * 0.82
	smoke.emitting = false
	rec["node"].add_child(smoke)
	rec["smoke"] = smoke


## Shared soft-particle factory. `size` is the quad width in world units.
func _make_particles(amount: int, lifetime: float, mat: StandardMaterial3D, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.10
	p.direction = Vector3.UP
	p.spread = 35.0
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 0.8
	p.gravity = Vector3(0.0, 0.2, 0.0)
	p.damping_min = 0.05
	p.damping_max = 0.20
	p.scale_amount_min = 0.30
	p.scale_amount_max = 0.80
	p.angle_min = -180.0
	p.angle_max = 180.0
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	p.mesh = quad
	p.material_override = mat
	# CPUParticles3D defaults to a zero visibility AABB. That culls the whole
	# system as soon as its origin leaves the camera frustum, even while its
	# world-space puffs are still visible; every smoke/dust system here needs a
	# generous local box because particles rise and drift after birth.
	p.visibility_aabb = AABB(Vector3(-8.0, -4.0, -8.0), Vector3(16.0, 14.0, 16.0))
	# Soft billboards must never write into the shadow map: a single large dust
	# puff casting a hard round shadow looked like a hole punched in the sand.
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emitting = true
	return p


func _growth_curve(start: float, finish: float) -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, start))
	curve.add_point(Vector2(0.55, lerpf(start, finish, 0.72)))
	curve.add_point(Vector2(1.0, finish))
	return curve


func _add_exhaust(rec: Dictionary, local_pos: Vector3, color: Color, amount: int) -> void:
	var ex := _make_particles(amount, 2.2, _smoke_puff_mat, 0.34)
	ex.emitting = false
	ex.position = local_pos
	ex.emission_sphere_radius = 0.06
	ex.direction = Vector3(0.0, 1.0, 0.0)
	ex.spread = 12.0
	ex.initial_velocity_min = 0.28
	ex.initial_velocity_max = 0.72
	ex.gravity = Vector3(0.0, 0.40, 0.0)
	ex.scale_amount_min = 0.24
	ex.scale_amount_max = 0.62
	ex.scale_amount_curve = _growth_curve(0.45, 1.7)
	ex.color = Color(1.0, 1.0, 1.0, 1.0)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.18, 1.0])
	grad.colors = PackedColorArray([
		Color(color.r, color.g, color.b, 0.0), Color(color.r, color.g, color.b, color.a),
		Color(color.r * 1.25, color.g * 1.25, color.b * 1.25, 0.0)])
	ex.color_ramp = grad
	rec["node"].add_child(ex)
	rec["exhaust"] = ex


## Extra pipe runs and a walkway on the process buildings. The authored GLBs
## carry the main silhouette; this catch-light steelwork gives the refinery
## the layered, working-plant read of the reference at the normal RTS zoom.
func _add_process_dressing(rec: Dictionary) -> void:
	var span: Vector2i = rec.get("span", Vector2i(3, 3))
	var height := float(rec.get("model_height", 2.4))
	var root: Node3D = rec["node"]
	var pipe_mat := StandardMaterial3D.new()
	pipe_mat.albedo_color = Color(0.27, 0.215, 0.155)
	pipe_mat.metallic = 0.58
	pipe_mat.roughness = 0.48
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.37, 0.285, 0.19)
	wood_mat.roughness = 0.78
	var steel_mat := StandardMaterial3D.new()
	steel_mat.albedo_color = Color(0.46, 0.39, 0.30)
	steel_mat.metallic = 0.48
	steel_mat.roughness = 0.44
	var side_x := float(span.x) * 0.37
	var north_z := -float(span.y) * 0.31
	for sx in [-1.0, 1.0]:
		var pipe := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.045
		mesh.bottom_radius = 0.055
		mesh.height = height * 0.62
		mesh.radial_segments = 8
		pipe.mesh = mesh
		pipe.position = Vector3(sx * side_x, height * 0.31 + 0.18, north_z)
		pipe.material_override = pipe_mat
		pipe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(pipe)
		var foot := MeshInstance3D.new()
		var foot_mesh := BoxMesh.new()
		foot_mesh.size = Vector3(0.18, 0.08, 0.18)
		foot.mesh = foot_mesh
		foot.position = Vector3(sx * side_x, 0.18, north_z)
		foot.material_override = steel_mat
		root.add_child(foot)
	var cross := MeshInstance3D.new()
	var cross_mesh := CylinderMesh.new()
	cross_mesh.top_radius = 0.035
	cross_mesh.bottom_radius = 0.035
	cross_mesh.height = side_x * 1.9
	cross_mesh.radial_segments = 8
	cross.mesh = cross_mesh
	cross.rotation.z = PI * 0.5
	cross.position = Vector3(0.0, height * 0.57, north_z)
	cross.material_override = pipe_mat
	root.add_child(cross)
	# Front catwalk over the service apron, with visible posts and a handrail.
	var walk := MeshInstance3D.new()
	var walk_mesh := BoxMesh.new()
	walk_mesh.size = Vector3(float(span.x) * 0.62, 0.05, 0.34)
	walk.mesh = walk_mesh
	walk.position = Vector3(0.0, height * 0.44, float(span.y) * 0.31)
	walk.material_override = wood_mat
	walk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(walk)
	for sx in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.05, height * 0.35, 0.05)
		post.mesh = post_mesh
		post.position = Vector3(sx * float(span.x) * 0.27, height * 0.44 + height * 0.175,
			float(span.y) * 0.31)
		post.material_override = steel_mat
		root.add_child(post)
	var rail := MeshInstance3D.new()
	var rail_mesh := BoxMesh.new()
	rail_mesh.size = Vector3(float(span.x) * 0.62, 0.045, 0.045)
	rail.mesh = rail_mesh
	rail.position = Vector3(0.0, height * 0.62, float(span.y) * 0.31)
	rail.material_override = steel_mat
	root.add_child(rail)


## Bake a downloaded CC0 kit GLB down to one surface, normalise its footprint
## to one tile, centre it on X/Z and ground its bottom at y = 0. Normalising at
## load time is what lets the same mesh be scaled to a building span, a vehicle
## radius or a prop cluster without any floating or sinking.
func _kit_prop(file: String) -> Dictionary:
	if _kit_props.has(file):
		return _kit_props[file]
	var result := {"mesh": null, "texture": null, "height": 1.0}
	var path := KIT_PROP_DIR + file
	if not ResourceLoader.exists(path):
		_kit_props[file] = result
		return result
	var scene := load(path) as PackedScene
	if scene == null:
		_kit_props[file] = result
		return result
	var inst := scene.instantiate()
	var acc := {"bounds": AABB(), "has": false, "material": null}
	_kit_collect(inst, Transform3D.IDENTITY, acc)
	if not bool(acc["has"]):
		inst.free()
		_kit_props[file] = result
		return result
	var bounds: AABB = acc["bounds"]
	var width := maxf(bounds.size.x, bounds.size.z)
	if width <= 0.0001:
		width = 1.0
	var s := 1.0 / width
	var center := bounds.get_center()
	var fit := Transform3D(Basis.from_scale(Vector3.ONE * s),
		Vector3(-center.x * s, -bounds.position.y * s, -center.z * s))
	var baked := {"v": PackedVector3Array(), "n": PackedVector3Array(),
		"uv": PackedVector2Array(), "c": PackedColorArray(), "i": PackedInt32Array()}
	_kit_append(inst, Transform3D.IDENTITY, fit, baked)
	var mesh := ArrayMesh.new()
	var verts: PackedVector3Array = baked["v"]
	if not verts.is_empty():
		var surface := []
		surface.resize(Mesh.ARRAY_MAX)
		surface[Mesh.ARRAY_VERTEX] = verts
		surface[Mesh.ARRAY_NORMAL] = baked["n"]
		surface[Mesh.ARRAY_TEX_UV] = baked["uv"]
		surface[Mesh.ARRAY_COLOR] = baked["c"]
		surface[Mesh.ARRAY_INDEX] = baked["i"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface)
	var source = acc.get("material")
	var tex: Texture2D = null
	if source is BaseMaterial3D:
		tex = (source as BaseMaterial3D).albedo_texture
	if tex == null and KIT_ATLAS_FALLBACK.has(file):
		var atlas := KIT_PROP_DIR + String(KIT_ATLAS_FALLBACK[file])
		if ResourceLoader.exists(atlas):
			tex = load(atlas) as Texture2D
	if mesh != null and source != null:
		mesh.surface_set_material(0, source)
	result["mesh"] = mesh
	result["texture"] = tex
	result["height"] = bounds.size.y * s
	inst.free()
	_kit_props[file] = result
	return result


func _kit_collect(node: Node, xform: Transform3D, acc: Dictionary) -> void:
	var xf := xform
	if node is Node3D:
		xf = xform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var box: AABB = xf * mi.mesh.get_aabb()
			if bool(acc["has"]):
				var current: AABB = acc["bounds"]
				acc["bounds"] = current.merge(box)
			else:
				acc["bounds"] = box
				acc["has"] = true
			if acc["material"] == null:
				for si in mi.mesh.get_surface_count():
					var mat = mi.get_active_material(si)
					if mat != null:
						acc["material"] = mat
						break
	for child in node.get_children():
		_kit_collect(child, xf, acc)


## Manual merge instead of SurfaceTool.append_from: several downloaded kits
## carry a 4-bone skin on one surface and none on another, which makes
## SurfaceTool's shared vertex format fail. Kit props are static, so skinning
## and tangents are dropped and only position/normal/UV/indices are baked.
func _kit_append(node: Node, xform: Transform3D, fit: Transform3D, acc: Dictionary) -> void:
	var xf := xform
	if node is Node3D:
		xf = xform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var verts: PackedVector3Array = acc["v"]
			var normals: PackedVector3Array = acc["n"]
			var uvs: PackedVector2Array = acc["uv"]
			var colors: PackedColorArray = acc["c"]
			var indices: PackedInt32Array = acc["i"]
			var xform_full := fit * xf
			var basis := xform_full.basis
			for si in mi.mesh.get_surface_count():
				var arrays: Array = mi.mesh.surface_get_arrays(si)
				if arrays == null or arrays.size() < Mesh.ARRAY_MAX:
					continue
				var src_verts = arrays[Mesh.ARRAY_VERTEX]
				if src_verts == null:
					continue
				var src_normals = arrays[Mesh.ARRAY_NORMAL]
				var src_uvs = arrays[Mesh.ARRAY_TEX_UV]
				var src_indices = arrays[Mesh.ARRAY_INDEX]
				var src_colors = arrays[Mesh.ARRAY_COLOR]
				var source_mat = mi.get_active_material(si)
				var surface_col = Color.WHITE
				if source_mat is BaseMaterial3D:
					surface_col = (source_mat as BaseMaterial3D).albedo_color
				var base := verts.size()
				for vi in src_verts.size():
					verts.append(xform_full * (src_verts[vi] as Vector3))
					var n := Vector3.UP
					if src_normals != null and vi < src_normals.size():
						n = src_normals[vi]
					normals.append((basis * n).normalized())
					var uv := Vector2.ZERO
					if src_uvs != null and vi < src_uvs.size():
						uv = src_uvs[vi]
					uvs.append(uv)
					var vcol := Color.WHITE
					if src_colors != null and vi < src_colors.size():
						vcol = src_colors[vi]
					colors.append(surface_col * vcol)
				if src_indices == null:
					for vi in src_verts.size():
						indices.append(base + vi)
				else:
					for idx in src_indices:
						indices.append(base + int(idx))
			acc["v"] = verts
			acc["n"] = normals
			acc["uv"] = uvs
			acc["c"] = colors
			acc["i"] = indices
	for child in node.get_children():
		_kit_append(child, xf, fit, acc)


func _kit_tint(file: String) -> Color:
	match file:
		"crystal_rock.glb":
			return Color(0.95, 0.80, 0.62)
		"container.glb":
			return Color(0.80, 0.72, 0.58)
		"pipe.glb":
			return Color(0.74, 0.66, 0.54)
		"barrel.glb":
			return Color(0.70, 0.58, 0.44)
		"barrel_stack.glb":
			return Color(0.78, 0.66, 0.50)
		"dish.glb":
			return Color(0.78, 0.74, 0.66)
		"generator.glb":
			return Color(0.78, 0.72, 0.60)
		"cargo_shuttle.glb":
			return Color(0.86, 0.76, 0.62)
		"wreck_tank.glb":
			return Color(0.85, 0.74, 0.60)
	return Color(0.84, 0.74, 0.60)


func _kit_material(file: String) -> Material:
	if _kit_materials.has(file):
		return _kit_materials[file]
	var prop := _kit_prop(file)
	var tex: Texture2D = prop.get("texture")
	if _kit_shader == null:
		_kit_shader = load(KIT_SHADER)
	if _kit_white == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_kit_white = ImageTexture.create_from_image(img)
	var mat := ShaderMaterial.new()
	mat.resource_name = "KitProp_" + file.get_basename()
	mat.shader = _kit_shader
	mat.set_shader_parameter("albedo_tex", tex if tex != null else _kit_white)
	mat.set_shader_parameter("sim_map", sim_texture)
	mat.set_shader_parameter("map_size", float(map_size))
	mat.set_shader_parameter("tint", _kit_tint(file))
	var rough := 0.78
	var metal := 0.16
	if file == "wreck_tank.glb":
		rough = 0.72
		metal = 0.38
	elif file == "dish.glb" or file == "generator.glb":
		metal = 0.32
	elif file == "crystal_rock.glb":
		rough = 0.62
		metal = 0.02
	mat.set_shader_parameter("prop_roughness", rough)
	mat.set_shader_parameter("prop_metallic", metal)
	_kit_materials[file] = mat
	return mat


func _kit_prop_node(file: String, parent: Node3D, size: float, local_pos: Vector3,
		yaw: float, shadow := true) -> MeshInstance3D:
	var prop := _kit_prop(file)
	if prop.get("mesh") == null:
		return null
	var mi := MeshInstance3D.new()
	mi.name = "Kit_" + file.get_basename()
	mi.mesh = prop["mesh"]
	var mat := _kit_material(file)
	if mat != null:
		mi.material_override = mat
	mi.position = local_pos
	mi.rotation.y = yaw
	mi.scale = Vector3.ONE * size
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _pad_props_for(type_id: String) -> Array:
	match type_id:
		"refinery", "silo":
			return ["container.glb", "pipe.glb", "barrel_stack.glb"]
		"factory", "heavy_factory", "cy", "ix", "hightech":
			return ["generator.glb", "container.glb", "barrel_stack.glb"]
		"starport", "repair_pad":
			return ["container.glb", "barrel_stack.glb", "pipe.glb"]
		"outpost":
			return ["generator.glb", "barrel_stack.glb", "container.glb"]
		"barracks":
			return ["barrel_stack.glb", "container.glb", "barrel_stack.glb"]
	return ["barrel_stack.glb", "container.glb", "pipe.glb"]


## Dress each finished structure with kit props that are parented to the
## building root, so fog visibility and demolition apply automatically. Props
## are grounded against the live height field just outside the pad lip.
func _add_building_kit_upgrades(rec: Dictionary, b) -> void:
	if bool(rec.get("kit_done", false)):
		return
	rec["kit_done"] = true
	if b.type_id == "wall":
		return
	var span: Vector2i = rec.get("span", Vector2i.ONE)
	var height := float(rec.get("model_height", 1.4))
	var node: Node3D = rec["node"]
	var pad_y := float(rec.get("pad_y", 0.0))
	var base: Vector2 = b.global_position
	var team := int(b.get("team"))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(b.get_instance_id()) & 0x7fffffff

	# House accent panel on the front foundation lip. _update_trim keeps this
	# in sync with Atreides blue, Harkonnen red and Ordos green at runtime.
	var panel := MeshInstance3D.new()
	panel.name = "KitFactionTrim"
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(0.50, 0.055, 0.16)
	panel.mesh = panel_mesh
	panel.material_override = _trim_material(team)
	# Sit the livery bar on the front lip of the authored foundation. The old
	# fixed height left it hovering over the sand just outside the pad.
	var panel_x := float(span.x) * 0.26
	var panel_z := float(span.y) * 0.5 - 0.18
	var panel_y := _roof_surface_height(rec, panel_x, panel_z, FOUNDATION_TOP + 0.04)
	panel.position = Vector3(panel_x, panel_y + 0.028, panel_z)
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(panel)
	rec["kit_trim"] = panel

	var props := _pad_props_for(String(b.type_id))
	var offsets := [
		Vector2(float(span.x) * 0.5 + 0.34, float(span.y) * 0.22),
		Vector2(-float(span.x) * 0.5 - 0.34, -float(span.y) * 0.18),
		Vector2(float(span.x) * 0.12, -float(span.y) * 0.5 - 0.36),
	]
	for i in mini(props.size(), offsets.size()):
		var off: Vector2 = offsets[i]
		var wp := base + off * TILE
		if wp.x < TILE or wp.y < TILE or wp.x > float(map_size * TILE) - TILE \
				or wp.y > float(map_size * TILE) - TILE:
			continue
		var ly := ground_height(wp) - pad_y
		_kit_prop_node(String(props[i]), node, rng.randf_range(0.32, 0.46),
			Vector3(off.x, ly + 0.008, off.y), rng.randf() * TAU)

	# Rooftop hardware. A House uplink dish on command structures and a plant
	# generator on production roofs read clearly at the default RTS zoom.
	var roof_file := ""
	match String(b.type_id):
		"outpost", "hightech", "ix", "palace", "starport":
			roof_file = "dish.glb"
		"cy", "factory", "heavy_factory":
			roof_file = "generator.glb"
	if roof_file != "":
		var roof_x := float(span.x) * 0.19
		var roof_z := -float(span.y) * 0.18
		var roof_y := _roof_surface_height(rec, roof_x, roof_z)
		# If no authored surface is under that point (an open gantry, for
		# example), omit the prop instead of parking it in the sky.
		if roof_y > -1000.0:
			_kit_prop_node(roof_file, node, 0.46 if roof_file == "dish.glb" else 0.30,
				Vector3(roof_x, roof_y + 0.006, roof_z), rng.randf() * TAU)

	# Landed cargo shuttle beside the landing pads. It is normalised to just
	# under a tile so it never overlaps the building footprint.
	if String(b.type_id) in ["starport", "repair_pad"]:
		var off := Vector2(float(span.x) * 0.5 + 1.05, -float(span.y) * 0.18)
		var wp := base + off * TILE
		if wp.x > TILE and wp.y > TILE and wp.x < float(map_size * TILE) - TILE \
				and wp.y < float(map_size * TILE) - TILE:
			_kit_prop_node("cargo_shuttle.glb", node, 0.95,
				Vector3(off.x, ground_height(wp) - pad_y + 0.01, off.y),
				rng.randf() * TAU)


## Static kit clutter, batched into one MultiMesh per silhouette. It replaces
## nothing: it sits alongside the existing procedural scatter and gives the
## desert real sci-fi cargo, drums, crystal outcrops and wrecked armour.
func _build_kit_clutter() -> void:
	if game == null or game.terrain == null or sim_texture == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 661903
	var limit := float(map_size * TILE)
	var containers: Array[Transform3D] = []
	var barrels: Array[Transform3D] = []
	var crystals: Array[Transform3D] = []
	var wrecks: Array[Transform3D] = []

	# Cargo containers spilled on open sand.
	for i in 90:
		var p := Vector2(rng.randf_range(2.0 * TILE, limit - 2.0 * TILE),
			rng.randf_range(2.0 * TILE, limit - 2.0 * TILE))
		if _inside_building_pad(p):
			continue
		var tile: Vector2i = game.terrain.tile_of(p)
		if tile.x < 0 or tile.y < 0 or tile.x >= map_size or tile.y >= map_size:
			continue
		var idx: int = tile.y * map_size + tile.x
		if game.terrain.types.size() <= idx or game.terrain.types[idx] == GameDefs.ROCK:
			continue
		if game.terrain.concrete.size() > idx and game.terrain.concrete[idx] == 1:
			continue
		var cs := rng.randf_range(0.30, 0.54)
		containers.append(_scatter_ground_transform(p, rng.randf() * TAU,
			Vector3.ONE * cs, 0.01))

	# Fuel drums around working pads, just past the foundation lip.
	for b in game.buildings:
		if not is_instance_valid(b) or b.dead or b.type_id == "wall":
			continue
		for k in 6:
			var p := _base_scatter_point(b, rng)
			if p.x < 2.0 * TILE or p.y < 2.0 * TILE or p.x > limit - 2.0 * TILE or p.y > limit - 2.0 * TILE:
				continue
			if _inside_building_pad(p):
				continue
			if barrels.size() >= 150:
				break
			var bs := rng.randf_range(0.16, 0.28)
			barrels.append(_scatter_ground_transform(p, rng.randf() * TAU,
				Vector3.ONE * bs, 0.006))

	# Warm crystal outcrops on plateau edges.
	for z in map_size:
		for x in map_size:
			if not _rock_tile_edge(x, z, map_size) or rng.randf() > 0.13:
				continue
			if crystals.size() >= 140:
				break
			var p := _scatter_point_in_tile(x, z, rng)
			if _inside_building_pad(p):
				continue
			var ks := rng.randf_range(0.20, 0.46)
			crystals.append(_scatter_ground_transform(p, rng.randf() * TAU,
				Vector3.ONE * ks, 0.012))

	# A handful of destroyed Quaternius hulls for battlefield archaeology.
	for i in 4:
		var p := Vector2(rng.randf_range(6.0 * TILE, limit - 6.0 * TILE),
			rng.randf_range(6.0 * TILE, limit - 6.0 * TILE))
		if _inside_building_pad(p):
			continue
		var ws := rng.randf_range(0.62, 0.88)
		wrecks.append(_scatter_ground_transform(p, rng.randf() * TAU,
			Vector3.ONE * ws, 0.012))

	_add_kit_batch("KitCargoClutter", "container.glb", containers)
	_add_kit_batch("KitDrumClutter", "barrel.glb", barrels)
	_add_kit_batch("KitCrystalClutter", "crystal_rock.glb", crystals)
	_add_kit_batch("KitTankWrecks", "wreck_tank.glb", wrecks)


func _add_kit_batch(name: String, file: String, transforms: Array[Transform3D]) -> void:
	if transforms.is_empty():
		return
	var prop := _kit_prop(file)
	if prop.get("mesh") == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = prop["mesh"]
	mm.instance_count = transforms.size()
	mm.custom_aabb = AABB(Vector3(-8.0, -4.0, -8.0),
		Vector3(float(map_size) + 16.0, 10.0, float(map_size) + 16.0))
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var inst := MultiMeshInstance3D.new()
	inst.name = name
	inst.multimesh = mm
	inst.material_override = _kit_material(file)
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(inst)


func _add_vent_stack(rec: Dictionary, base_pos: Vector3, height: float) -> Vector3:
	var stack := MeshInstance3D.new()
	stack.name = "LiveExhaustStack"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.095
	mesh.bottom_radius = 0.135
	mesh.height = height
	mesh.radial_segments = 12
	mesh.rings = 1
	stack.mesh = mesh
	stack.position = base_pos + Vector3(0.0, height * 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.135, 0.11)
	mat.metallic = 0.62
	mat.roughness = 0.48
	mat.next_pass = ink_small_material if ink_small_material != null else ink_material
	stack.material_override = mat
	stack.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	rec["node"].add_child(stack)
	# A lighter rim catches the low sun and separates the stack from the roof.
	var rim_band := MeshInstance3D.new()
	var rim_mesh := CylinderMesh.new()
	rim_mesh.top_radius = 0.112
	rim_mesh.bottom_radius = 0.112
	rim_mesh.height = 0.045
	rim_mesh.radial_segments = 12
	rim_mesh.rings = 1
	rim_band.mesh = rim_mesh
	rim_band.position = base_pos + Vector3(0.0, height - 0.025, 0.0)
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.40, 0.34, 0.25)
	rim_mat.metallic = 0.55
	rim_mat.roughness = 0.38
	rim_band.material_override = rim_mat
	rim_band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rec["node"].add_child(rim_band)
	return base_pos + Vector3(0.0, height + 0.02, 0.0)


func _add_building_exhaust(rec: Dictionary, local_pos: Vector3, amount: int) -> void:
	# Buildings need a pre-warmed, longer-lived column so the base reads as a
	# running industrial site immediately, not a static diorama. Vehicle exhaust
	# stays short and low; this plume is specifically for roof stacks.
	var ex := _make_particles(maxi(amount, 12), 4.0, _smoke_puff_mat, 0.50)
	ex.name = "BuildingExhaust"
	ex.emitting = false
	ex.position = local_pos
	ex.emission_sphere_radius = 0.09
	ex.direction = Vector3(0.0, 1.0, 0.0)
	ex.spread = 14.0
	ex.initial_velocity_min = 0.18
	ex.initial_velocity_max = 0.48
	ex.gravity = Vector3(0.03, 0.24, 0.01)
	ex.damping_min = 0.0
	ex.damping_max = 0.05
	ex.scale_amount_min = 0.50
	ex.scale_amount_max = 1.10
	ex.scale_amount_curve = _growth_curve(0.55, 2.15)
	ex.preprocess = 1.8
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.14, 0.55, 1.0])
	grad.colors = PackedColorArray([
		Color(0.28, 0.245, 0.215, 0.0), Color(0.29, 0.255, 0.225, 0.70),
		Color(0.40, 0.36, 0.31, 0.48), Color(0.56, 0.50, 0.43, 0.0)])
	ex.color_ramp = grad
	rec["node"].add_child(ex)
	rec["exhaust"] = ex


func _add_harvester_exhaust(rec: Dictionary) -> void:
	_add_exhaust(rec, Vector3(-0.30, float(rec.get("model_height", 1.0)) * 0.80, 0.18),
		Color(0.245, 0.205, 0.175, 0.82), 14)
	var ex = rec.get("exhaust")
	if ex != null and is_instance_valid(ex):
		ex.initial_velocity_max = 0.95
		ex.scale_amount_max = 0.86
		ex.preprocess = 1.2
		ex.scale_amount_curve = _growth_curve(0.7, 1.9)


func _add_track_dust(rec: Dictionary, type_id: String) -> void:
	var heavy := type_id in ["harvester", "mcv", "tank", "atreides_tank", "harkonnen_tank",
		"ordos_tank", "sonic_tank", "devastator", "deviator"]
	var dust := _make_particles(9 if heavy else 6, 1.35, _dust_puff_mat, 0.38 if heavy else 0.28)
	dust.emitting = false
	dust.position = Vector3(-0.30, 0.10, 0.0)
	dust.emission_sphere_radius = 0.20
	dust.direction = Vector3(-1.0, 0.42, 0.0)
	dust.spread = 34.0
	dust.initial_velocity_min = 0.35
	dust.initial_velocity_max = 1.15
	dust.gravity = Vector3(0.0, 0.02, 0.0)
	dust.scale_amount_min = 0.40
	dust.scale_amount_max = 1.05
	dust.scale_amount_curve = _growth_curve(0.9, 2.2)
	dust.color = Color(1.0, 1.0, 1.0, 1.0)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.16, 1.0])
	grad.colors = PackedColorArray([
		Color(0.78, 0.66, 0.47, 0.0), Color(0.74, 0.61, 0.42, 0.38),
		Color(0.90, 0.78, 0.58, 0.0)])
	dust.color_ramp = grad
	rec["node"].add_child(dust)
	rec["dust"] = dust


func _on_open_sand(pos: Vector2) -> bool:
	if game == null or game.terrain == null:
		return false
	return game.terrain.is_open_sand(game.terrain.tile_of(pos))


func _sync_vehicle_ground_fx(rec: Dictionary, u, delta: float) -> void:
	var visible: bool = u.team == 0 or game.terrain.is_visible_at(u.global_position)
	var on_sand := _on_open_sand(u.global_position)
	var dust = rec.get("dust")
	if dust != null and is_instance_valid(dust):
		dust.emitting = bool(u.locomoting) and on_sand and visible
	var exhaust = rec.get("exhaust")
	if exhaust != null and is_instance_valid(exhaust):
		if String(u.type_id) == "harvester":
			exhaust.emitting = (String(u.get("state")) == "harvest" or bool(u.locomoting) or bool(u.has_move)) and visible
		else:
			exhaust.emitting = bool(u.locomoting) and visible
	if u.type_id == "harvester":
		_sync_harvester_fill(rec, u)
	if not TRACK_TYPES.has(u.type_id) or bool(u.airborne):
		return
	var last: Vector2 = rec.get("track_last", u.global_position)
	var moved := float(rec.get("track_accum", 0.0))
	if delta > 0.0:
		moved += last.distance_to(u.global_position) * WORLD_SCALE
	rec["track_last"] = u.global_position
	if bool(u.locomoting) and on_sand and visible and moved >= 0.46:
		moved = 0.0
		_stamp_tread(u.global_position, float(u.facing), float(TRACK_WIDTHS.get(u.type_id, 0.90)))
	rec["track_accum"] = moved


## The hopper is exported empty; the visible spice load grows from a flat damp
## bed to a heaped glowing mound as the harvester fills up.
func _sync_harvester_fill(rec: Dictionary, u) -> void:
	var mesh = rec.get("cargo_mesh")
	if mesh == null or not is_instance_valid(mesh):
		mesh = MeshInstance3D.new()
		var dome := SphereMesh.new()
		dome.radius = 0.46
		dome.height = 0.46
		dome.is_hemisphere = true
		dome.radial_segments = 20
		dome.rings = 8
		mesh.mesh = dome
		mesh.material_override = _spice_mound_mat.duplicate()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.position = Vector3(-0.48, 0.745, 0.0)
		rec["holder"].add_child(mesh)
		rec["cargo_mesh"] = mesh
	var capacity := maxf(float(u.get("capacity")), 1.0)
	var ratio := clampf(float(u.get("cargo")) / capacity, 0.0, 1.0)
	mesh.visible = ratio > 0.015
	mesh.scale = Vector3(1.04, maxf(ratio, 0.01) * 0.70, 1.08)
	var mat := mesh.material_override as StandardMaterial3D
	if mat != null:
		mat.emission_energy_multiplier = 0.05 + ratio * 0.13


func _add_selection_ring(rec: Dictionary, radius: float) -> void:
	if rec.get("kind") == "building":
		rec["sel_mesh"] = _make_box_outline(rec.get("span", Vector2i.ONE))
		var mi := MeshInstance3D.new()
		mi.mesh = rec["sel_mesh"]
		mi.material_override = _building_selection_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		rec["node"].add_child(mi)
		rec["sel_node"] = mi
		return
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = radius
	torus.outer_radius = radius + 0.055
	torus.rings = 32
	torus.ring_segments = 8
	ring.mesh = torus
	ring.material_override = _selection_material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position.y = 0.035
	ring.visible = false
	rec["node"].add_child(ring)
	rec["sel_node"] = ring


func _make_box_outline(span: Vector2i) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _building_selection_material)
	var hx := float(span.x) * 0.5
	var hz := float(span.y) * 0.5
	var pts := [
		Vector3(-hx, 0.06, -hz), Vector3(hx, 0.06, -hz),
		Vector3(hx, 0.06, -hz), Vector3(hx, 0.06, hz),
		Vector3(hx, 0.06, hz), Vector3(-hx, 0.06, hz),
		Vector3(-hx, 0.06, hz), Vector3(-hx, 0.06, -hz),
	]
	for p in pts:
		mesh.surface_set_color(Color(1.0, 0.84, 0.30, 0.95))
		mesh.surface_add_vertex(p)
	mesh.surface_end()
	return mesh


func _update_selection(rec: Dictionary, selected: bool) -> void:
	var node = rec.get("sel_node")
	if node != null and is_instance_valid(node):
		node.visible = selected


func _sync_selection_box() -> void:
	if game == null or not game.drag_active:
		_selection_box_instance.visible = false
		return
	if game.press_touch and not game.box_armed:
		_selection_box_instance.visible = false
		return
	var a: Vector2 = world_from_screen(game.drag_start)
	var b: Vector2 = world_from_screen(game.drag_now)
	var min_x := minf(a.x, b.x) * WORLD_SCALE
	var max_x := maxf(a.x, b.x) * WORLD_SCALE
	var min_z := minf(a.y, b.y) * WORLD_SCALE
	var max_z := maxf(a.y, b.y) * WORLD_SCALE
	var y := maxf(maxf(ground_height(Vector2(min_x, min_z) * TILE),
		ground_height(Vector2(max_x, min_z) * TILE)),
		maxf(ground_height(Vector2(min_x, max_z) * TILE),
			ground_height(Vector2(max_x, max_z) * TILE))) + 0.08
	var pts := [
		Vector3(min_x, y, min_z), Vector3(max_x, y, min_z),
		Vector3(max_x, y, min_z), Vector3(max_x, y, max_z),
		Vector3(max_x, y, max_z), Vector3(min_x, y, max_z),
		Vector3(min_x, y, max_z), Vector3(min_x, y, min_z),
	]
	_selection_box_mesh.clear_surfaces()
	_selection_box_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _building_selection_material)
	for p in pts:
		_selection_box_mesh.surface_set_color(Color(0.45, 1.0, 0.55, 0.9))
		_selection_box_mesh.surface_add_vertex(p)
	_selection_box_mesh.surface_end()
	_selection_box_instance.visible = true


func _sync_ghost() -> void:
	if game == null:
		return
	for b in _brush_boxes:
		b.visible = false
	if game.placing != "":
		var span: Vector2i = GameDefs.size_of(game.placing)
		var tile: Vector2i = game.terrain.tile_of(game.hover_world) - span / 2
		var center := Vector2(tile) + Vector2(span) * 0.5
		var pos := Vector3(center.x, ground_height(game.terrain.tile_center(tile)) + 0.06, center.y)
		_ghost_box.position = pos
		_ghost_box.scale = Vector3(float(span.x), 0.12, float(span.y))
		_ghost_box.material_override = _ghost_green if game.can_place(game.placing, tile) else _ghost_red
		_ghost_box.visible = true
	elif game.brush != "":
		var center: Vector2i = game.terrain.tile_of(game.hover_world)
		var radius := 1 if game.brush == "slab" else 0
		var index := 0
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if index >= _brush_boxes.size():
					break
				var tile: Vector2i = center + Vector2i(dx, dz)
				var ok: bool = game._can_pave_tile(tile) if game.brush == "slab" else game.can_place("wall", tile)
				var mi: MeshInstance3D = _brush_boxes[index]
				mi.position = Vector3(float(tile.x) + 0.5, ground_height(game.terrain.tile_center(tile)) + 0.05,
					float(tile.y) + 0.5)
				mi.scale = Vector3(0.94, 0.08, 0.94)
				mi.material_override = _ghost_green if ok else _ghost_red
				mi.visible = true
				index += 1
	else:
		_ghost_box.visible = false
	if game.placing == "" and game.brush == "":
		_ghost_box.visible = false


# ------------------------------------------------------ ground detail & decals

## One MultiMesh for every pebble, one for the tread-print pool and one for the
## crater pool. Three draw calls replace what would otherwise be thousands of
## individual ground nodes, which is what keeps Modern 3D viable on a phone.
func _build_ground_decor() -> void:
	if game == null or game.terrain == null:
		return
	_build_pebbles()
	_build_scatter()
	_build_kit_clutter()
	_build_gantry_crane()
	_build_tread_pool()
	_build_crater_pool()


func _inside_building_pad(pos: Vector2) -> bool:
	if game == null:
		return false
	for b in game.buildings:
		if is_instance_valid(b) and not b.dead and b.world_rect().grow(4.0).has_point(pos):
			return true
	return false


func _build_pebbles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 881122
	var transforms: Array[Transform3D] = []
	var n := map_size
	for z in n:
		for x in n:
			var i: int = z * n + x
			if game.terrain.types.size() <= i:
				continue
			var is_rock: bool = game.terrain.types[i] == GameDefs.ROCK
			var paved: bool = game.terrain.concrete.size() > i and game.terrain.concrete[i] == 1
			var edge := false
			if is_rock:
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = x + d.x
					var nz: int = z + d.y
					if nx < 0 or nz < 0 or nx >= n or nz >= n:
						continue
					if game.terrain.types[nz * n + nx] != GameDefs.ROCK:
						edge = true
						break
			var chance := 0.45 if edge else (0.13 if (not is_rock and not paved) else 0.0)
			if rng.randf() > chance:
				continue
			var px := (float(x) + rng.randf_range(0.08, 0.92)) * TILE
			var pz := (float(z) + rng.randf_range(0.08, 0.92)) * TILE
			if _inside_building_pad(Vector2(px, pz)):
				continue
			var height := ground_height(Vector2(px, pz))
			var size := rng.randf_range(0.060, 0.135) if edge else rng.randf_range(0.022, 0.060)
			var sx := size * rng.randf_range(0.85, 1.55)
			var sy := size * rng.randf_range(0.32, 0.62)
			var sz := size * rng.randf_range(0.85, 1.55)
			var basis := Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(sx, sy, sz))
			# Sit them slightly into the sand; a floating sphere reads as an egg.
			transforms.append(Transform3D(basis, Vector3(px * WORLD_SCALE, height - sy * 0.22,
				pz * WORLD_SCALE)))

	var rock_mesh := SphereMesh.new()
	rock_mesh.radius = 1.0
	rock_mesh.height = 2.0
	rock_mesh.radial_segments = 6
	rock_mesh.rings = 3
	pebble_multimesh = MultiMesh.new()
	pebble_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	pebble_multimesh.mesh = rock_mesh
	pebble_multimesh.instance_count = transforms.size()
	pebble_multimesh.custom_aabb = AABB(Vector3(-2.0, -1.0, -2.0),
		Vector3(float(map_size) + 4.0, 5.0, float(map_size) + 4.0))
	for i in transforms.size():
		pebble_multimesh.set_instance_transform(i, transforms[i])

	pebble_instance = MultiMeshInstance3D.new()
	pebble_instance.name = "DesertPebbles"
	pebble_instance.multimesh = pebble_multimesh
	pebble_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = _pebble_shader
	mat.set_shader_parameter("sim_map", sim_texture)
	mat.set_shader_parameter("map_size", float(map_size))
	pebble_instance.material_override = mat
	world.add_child(pebble_instance)


## Deterministic, batched desert dressing. One MultiMesh per silhouette keeps
## the whole field at five draw calls while still giving the camera close-up
## rocks, gravel, rusted plate, scrub and supply clutter around bases.
func _build_scatter() -> void:
	if game == null or game.terrain == null:
		return
	_scatter_shader = load(SCATTER_SHADER)
	if _scatter_shader == null:
		return
	scatter_material = ShaderMaterial.new()
	scatter_material.shader = _scatter_shader
	scatter_material.set_shader_parameter("sim_map", sim_texture)
	scatter_material.set_shader_parameter("map_size", float(map_size))

	var rng := RandomNumberGenerator.new()
	rng.seed = 771133
	var rocks: Array[Transform3D] = []
	var rock_tones: Array[float] = []
	var gravel: Array[Transform3D] = []
	var gravel_tones: Array[float] = []
	var scrap: Array[Transform3D] = []
	var scrap_tones: Array[float] = []
	var shrubs: Array[Transform3D] = []
	var shrub_tones: Array[float] = []
	var crates: Array[Transform3D] = []
	var crate_tones: Array[float] = []
	var canisters: Array[Transform3D] = []
	var canister_tones: Array[float] = []

	var n := map_size
	for z in n:
		for x in n:
			var i: int = z * n + x
			if game.terrain.types.size() <= i:
				continue
			var is_rock: bool = game.terrain.types[i] == GameDefs.ROCK
			var paved: bool = game.terrain.concrete.size() > i and game.terrain.concrete[i] == 1
			if paved:
				continue
			if is_rock:
				if _rock_tile_edge(x, z, n) and rng.randf() < 0.88 and rocks.size() < SCATTER_ROCK_CAP:
					var rp := _scatter_point_in_tile(x, z, rng)
					if _inside_building_pad(rp):
						continue
					var rs := rng.randf_range(0.16, 0.52)
					rocks.append(_scatter_ground_transform(rp, rng.randf() * TAU,
						Vector3(rs * rng.randf_range(0.72, 1.28), rs * rng.randf_range(0.55, 1.15),
							rs * rng.randf_range(0.72, 1.28)), 0.012))
					rock_tones.append(rng.randf())
				continue

			var spice := 0.0
			if game.terrain.spice.size() > i:
				spice = float(game.terrain.spice[i])
			var cluster := _scatter_cluster(float(x), float(z))
			var density := 0.24 + cluster * 0.46
			if spice > 35.0:
				density *= 0.30
			for sample in 8:
				if rng.randf() > density:
					continue
				var p := _scatter_point_in_tile(x, z, rng)
				if _inside_building_pad(p):
					continue
				var roll := rng.randf()
				if roll < 0.42 and gravel.size() < SCATTER_GRAVEL_CAP:
					var gs := rng.randf_range(0.011, 0.038)
					gravel.append(_scatter_ground_transform(p, rng.randf() * TAU,
						Vector3(gs * rng.randf_range(0.8, 1.5), gs * rng.randf_range(0.45, 0.9),
							gs * rng.randf_range(0.8, 1.5)), 0.006))
					gravel_tones.append(rng.randf())
				elif roll < 0.68 and rocks.size() < SCATTER_ROCK_CAP:
					var rs := rng.randf_range(0.035, 0.19)
					rocks.append(_scatter_ground_transform(p, rng.randf() * TAU,
						Vector3(rs * rng.randf_range(0.72, 1.35), rs * rng.randf_range(0.5, 1.0),
							rs * rng.randf_range(0.72, 1.35)), 0.012))
					rock_tones.append(rng.randf())
				elif roll < 0.82 and scrap.size() < SCATTER_SCRAP_CAP:
					var ss := rng.randf_range(0.055, 0.19)
					scrap.append(_scatter_ground_transform(p, rng.randf() * TAU,
						Vector3(ss * rng.randf_range(0.9, 1.6), rng.randf_range(0.04, 0.11),
							ss * rng.randf_range(0.55, 1.15)), 0.016))
					scrap_tones.append(rng.randf())
				elif roll < 0.94 and shrubs.size() < SCATTER_SHRUB_CAP:
					var hs := rng.randf_range(0.045, 0.15)
					shrubs.append(_scatter_ground_transform(p, rng.randf() * TAU,
						Vector3(hs * rng.randf_range(0.7, 1.3), hs * rng.randf_range(0.7, 1.35),
							hs * rng.randf_range(0.7, 1.3)), 0.004))
					shrub_tones.append(rng.randf())

	# A low-density industrial debris ring outside every structure footprint.
	# Nothing is placed on the concrete pad or inside the wall line; the props
	# sit on the sand just past the foundation lip, where they read as spilled
	# cargo rather than collision blockers.
	for b in game.buildings:
		if not is_instance_valid(b) or b.dead or b.type_id == "wall":
			continue
		var span: Vector2i = GameDefs.size_of(b.type_id)
		var prop_count := 13 + mini(maxi(span.x, span.y), 4) * 2
		for k in prop_count:
			var p := _base_scatter_point(b, rng)
			if p.x < 0.0 or p.y < 0.0 or p.x >= float(map_size * TILE) or p.y >= float(map_size * TILE):
				continue
			if _inside_building_pad(p):
				continue
			var roll := rng.randf()
			if roll < 0.34 and crates.size() < SCATTER_CRATE_CAP:
				var cs := rng.randf_range(0.14, 0.27)
				var cs_y := cs * rng.randf_range(0.62, 1.0)
				var stack_count := rng.randi_range(1, 3)
				# One footprint per pile. Re-randomising X/Z and adding a gap for
				# every upper level left boxes hovering beside the pad.
				var stack_p := p + Vector2(rng.randf_range(-0.65, 0.65),
					rng.randf_range(-0.65, 0.65))
				for stack_i in stack_count:
					if crates.size() >= SCATTER_CRATE_CAP:
						break
					crates.append(_scatter_ground_transform(stack_p, rng.randf() * TAU,
						Vector3(cs, cs_y, cs * rng.randf_range(0.65, 1.1)),
						cs_y * (0.5 + float(stack_i))))
					crate_tones.append(rng.randf())
			elif roll < 0.58 and canisters.size() < SCATTER_CANISTER_CAP:
				var hs := rng.randf_range(0.10, 0.17)
				var hs_y := hs * rng.randf_range(1.25, 2.0)
				canisters.append(_scatter_ground_transform(p, rng.randf() * TAU,
					Vector3(hs, hs_y, hs), hs_y * 0.5))
				canister_tones.append(rng.randf())
			elif roll < 0.80 and scrap.size() < SCATTER_SCRAP_CAP:
				var ss := rng.randf_range(0.085, 0.21)
				scrap.append(_scatter_ground_transform(p, rng.randf() * TAU,
					Vector3(ss * rng.randf_range(0.8, 1.5), rng.randf_range(0.04, 0.09),
						ss * rng.randf_range(0.55, 1.1)), 0.020))
				scrap_tones.append(rng.randf())
			elif rocks.size() < SCATTER_ROCK_CAP:
				var rs := rng.randf_range(0.045, 0.13)
				rocks.append(_scatter_ground_transform(p, rng.randf() * TAU,
					Vector3(rs * 1.2, rs * 0.55, rs), 0.010))
				rock_tones.append(rng.randf())

	rock_scatter = _add_scatter_group("DesertRocks", _make_scatter_rock_mesh(), rocks, rock_tones, 0)
	gravel_scatter = _add_scatter_group("DesertGravel", _make_scatter_rock_mesh(), gravel, gravel_tones, 0)
	scrap_scatter = _add_scatter_group("RustedScrap", _make_scatter_scrap_mesh(), scrap, scrap_tones, 1)
	shrub_scatter = _add_scatter_group("DryScrub", _make_scatter_shrub_mesh(), shrubs, shrub_tones, 2)
	crate_scatter = _add_scatter_group("SupplyCrates", _make_scatter_crate_mesh(), crates, crate_tones, 3)
	canister_scatter = _add_scatter_group("FuelCanisters", _make_scatter_canister_mesh(), canisters, canister_tones, 4)


## A single batched service gantry on open staging ground beside the base.
## Keep this out of the structure footprints: the previous refinery-relative
## anchor put the lattice directly over the Construction Yard, so zooming in
## showed a cage around the building instead of a background crane.
func _build_gantry_crane() -> void:
	if game == null:
		return
	var anchor := Vector2(-1.0, -1.0)
	for b in game.buildings:
		if is_instance_valid(b) and not b.dead and b.team == 0 and b.type_id == "cy":
			anchor = b.global_position
			break
	if anchor.x < 0.0:
		var span := Vector2.ZERO
		var count := 0
		for b in game.buildings:
			if is_instance_valid(b) and not b.dead and b.team == 0:
				span += b.global_position
				count += 1
		if count > 0:
			anchor = span / float(count)
	if anchor.x < 0.0:
		return
	# West/north of the command yard, clear of every starting footprint.
	var center := anchor + Vector2(-6.6, -5.4) * TILE
	var limit := float(map_size * TILE)
	center = center.clamp(Vector2(4.2 * TILE, 4.2 * TILE),
		Vector2(limit - 4.2 * TILE, limit - 4.2 * TILE))
	var base := Vector3(center.x * WORLD_SCALE, ground_height(center),
		center.y * WORLD_SCALE)
	var dark := Color(0.30, 0.255, 0.205)
	var steel := Color(0.46, 0.385, 0.290)
	var rust := Color(0.43, 0.235, 0.115)
	var hazard := Color(0.82, 0.50, 0.045)

	# Slightly sunken concrete apron with a few edge blocks.
	var deck := MeshInstance3D.new()
	var deck_mesh := BoxMesh.new()
	deck_mesh.size = Vector3(3.0, 0.12, 1.35)
	deck.mesh = deck_mesh
	deck.position = base + Vector3(0.0, 0.07, 0.0)
	var deck_mat := StandardMaterial3D.new()
	deck_mat.albedo_color = Color(0.285, 0.245, 0.195)
	deck_mat.roughness = 0.88
	deck.material_override = deck_mat
	deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	world.add_child(deck)
	# Load the staging deck with a couple of crates and a spare pipe run so the
	# gantry reads as a working yard instead of an empty scaffold.
	var prop_mat := StandardMaterial3D.new()
	prop_mat.albedo_color = Color(0.33, 0.265, 0.185)
	prop_mat.roughness = 0.82
	prop_mat.metallic = 0.10
	for spec in [Vector3(-0.82, 0.31, 0.42), Vector3(0.58, 0.31, -0.36),
			Vector3(-0.28, 0.31, -0.50)]:
		var crate := MeshInstance3D.new()
		var crate_mesh := BoxMesh.new()
		crate_mesh.size = Vector3(0.42, 0.34, 0.36)
		crate.mesh = crate_mesh
		crate.position = base + spec
		crate.material_override = prop_mat
		crate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		world.add_child(crate)
	var pipe_rack := MeshInstance3D.new()
	var pipe_mesh := CylinderMesh.new()
	pipe_mesh.top_radius = 0.075
	pipe_mesh.bottom_radius = 0.075
	pipe_mesh.height = 2.1
	pipe_mesh.radial_segments = 10
	pipe_rack.mesh = pipe_mesh
	pipe_rack.rotation.z = PI * 0.5
	pipe_rack.position = base + Vector3(0.05, 0.22, 0.64)
	var pipe_mat := StandardMaterial3D.new()
	pipe_mat.albedo_color = Color(0.30, 0.17, 0.09)
	pipe_mat.metallic = 0.52
	pipe_mat.roughness = 0.56
	pipe_rack.material_override = pipe_mat
	pipe_rack.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	world.add_child(pipe_rack)

	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var add_bar := func(a: Vector3, b: Vector3, thickness: float, color: Color) -> void:
		var d := b - a
		var length := d.length()
		if length < 0.001:
			return
		var up := Vector3.UP if absf(d.normalized().dot(Vector3.UP)) < 0.96 else Vector3.RIGHT
		var basis := Basis.looking_at(d.normalized(), up)
		basis = basis * Basis.from_scale(Vector3(thickness, thickness, length))
		transforms.append(Transform3D(basis, (a + b) * 0.5))
		colors.append(color)

	var sx := 1.05
	var sz := 0.42
	var top := 1.95
	# Four splayed legs, footings and a full perimeter of lattice bracing.
	for x in [-sx, sx]:
		for z in [-sz, sz]:
			var foot := base + Vector3(x, 0.0, z)
			add_bar.call(foot + Vector3(0.0, 0.06, 0.0), foot + Vector3(0.0, top, 0.0), 0.17, dark)
			add_bar.call(foot + Vector3(-0.24, 0.02, 0.0), foot + Vector3(0.24, 0.02, 0.0), 0.22, steel)
	# Stay below the top chord. The old 3.25 level floated a second cage
	# above a 2.35-high frame and dominated the mobile close-up.
	for level in [0.45, 0.95, 1.45, 1.95]:
		for z in [-sz, sz]:
			add_bar.call(base + Vector3(-sx, level, z), base + Vector3(sx, level, z), 0.075, steel)
		for x in [-sx, sx]:
			add_bar.call(base + Vector3(x, level, -sz), base + Vector3(x, level, sz), 0.075, steel)
	for z in [-sz, sz]:
		add_bar.call(base + Vector3(-sx, 0.20, z), base + Vector3(sx, 1.10, z), 0.048, rust)
		add_bar.call(base + Vector3(sx, 0.20, z), base + Vector3(-sx, 1.10, z), 0.048, steel)
		add_bar.call(base + Vector3(-sx, 1.25, z), base + Vector3(sx, top, z), 0.048, rust)
		add_bar.call(base + Vector3(sx, 1.25, z), base + Vector3(-sx, top, z), 0.048, steel)

	# Twin top chords and a zig-zag truss, with the hoist trolley on top.
	for z in [-sz, sz]:
		add_bar.call(base + Vector3(-sx, top, z), base + Vector3(sx, top, z), 0.16, steel)
		for i in 6:
			var x0 := -sx + (float(i) / 6.0) * sx * 2.0
			var x1 := -sx + (float(i + 1) / 6.0) * sx * 2.0
			add_bar.call(base + Vector3(x0, top, z), base + Vector3(x1, top + (0.62 if i % 2 == 0 else -0.0), z), 0.060, dark)
			add_bar.call(base + Vector3(x0, top, z), base + Vector3(x1, top - 0.44, z), 0.060, dark)
	for x in [-sx, -sx * 0.5, 0.0, sx * 0.5, sx]:
		add_bar.call(base + Vector3(x, top, -sz), base + Vector3(x, top, sz), 0.060, steel)
	add_bar.call(base + Vector3(-sx, top - 0.38, -sz), base + Vector3(-sx, top - 0.38, sz), 0.050, dark)
	add_bar.call(base + Vector3(sx, top - 0.38, -sz), base + Vector3(sx, top - 0.38, sz), 0.050, dark)
	# A short cantilevered jib gives the silhouette a crane read instead of a
	# closed scaffold box.
	for z in [-0.14, 0.14]:
		add_bar.call(base + Vector3(sx, top, z), base + Vector3(sx + 1.55, top, z), 0.070, steel)
		add_bar.call(base + Vector3(sx, top - 0.34, z), base + Vector3(sx + 1.30, top - 0.34, z), 0.040, dark)
	add_bar.call(base + Vector3(sx + 1.40, top, 0.0), base + Vector3(sx + 1.40, top - 1.05, 0.0), 0.022, rust)
	add_bar.call(base + Vector3(sx + 1.24, top - 1.05, 0.0), base + Vector3(sx + 1.56, top - 1.05, 0.0), 0.085, hazard)

	# Hoist trolley, cable and hook; hazard bands at the base of each leg.
	add_bar.call(base + Vector3(-0.35, top + 0.10, 0.0), base + Vector3(0.35, top + 0.10, 0.0), 0.30, dark)
	add_bar.call(base + Vector3(0.0, top + 0.10, 0.0), base + Vector3(0.0, top - 1.65, 0.0), 0.026, rust)
	add_bar.call(base + Vector3(-0.20, top - 1.60, 0.0), base + Vector3(0.20, top - 1.60, 0.0), 0.12, hazard)
	add_bar.call(base + Vector3(-0.10, top - 1.75, 0.0), base + Vector3(0.10, top - 1.75, 0.0), 0.10, dark)
	for level in [0.38, 0.58]:
		for x in [-sx, sx]:
			for z in [-sz, sz]:
				add_bar.call(base + Vector3(x - 0.14, level, z), base + Vector3(x + 0.14, level, z), 0.045, hazard)
	# Rungs on the east leg read as a service ladder.
	for i in 4:
		var y := 0.45 + i * 0.34
		add_bar.call(base + Vector3(sx + 0.12, y, -sz + 0.08), base + Vector3(sx + 0.12, y, sz - 0.08), 0.024, steel)
	add_bar.call(base + Vector3(sx + 0.12, 0.45, -sz), base + Vector3(sx + 0.12, 1.82, -sz), 0.024, steel)
	add_bar.call(base + Vector3(sx + 0.12, 0.45, sz), base + Vector3(sx + 0.12, 1.82, sz), 0.024, steel)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3.ONE
	mm.mesh = bar_mesh
	mm.instance_count = transforms.size()
	mm.custom_aabb = AABB(base + Vector3(-7.0, -1.0, -5.0), Vector3(14.0, 9.0, 10.0))
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_color(i, colors[i])
	var inst := MultiMeshInstance3D.new()
	inst.name = "StagingGantry"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	mat.metallic = 0.50
	mat.roughness = 0.46
	inst.material_override = mat
	world.add_child(inst)


func _scatter_point_in_tile(x: int, z: int, rng: RandomNumberGenerator) -> Vector2:
	return Vector2((float(x) + rng.randf_range(0.06, 0.94)) * TILE,
		(float(z) + rng.randf_range(0.06, 0.94)) * TILE)


func _rock_tile_edge(x: int, z: int, n: int) -> bool:
	if not _rock_tile_at(x, z):
		return false
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = x + d.x
		var nz: int = z + d.y
		if nx < 0 or nz < 0 or nx >= n or nz >= n:
			return true
		if not _rock_tile_at(nx, nz):
			return true
	return false


func _scatter_cluster(x: float, z: float) -> float:
	var a := sin(x * 1.31 + z * 0.83) * 0.5 + 0.5
	var b := sin(x * 0.37 - z * 1.17 + 2.1) * 0.5 + 0.5
	var c := sin(x * 2.43 + z * 1.77 - 0.8) * 0.5 + 0.5
	return clampf(a * 0.44 + b * 0.34 + c * 0.22, 0.0, 1.0)


func _scatter_ground_transform(pos: Vector2, yaw: float, scale: Vector3, lift: float) -> Transform3D:
	var up := ground_normal(pos)
	var basis := Basis(up, yaw) * Basis.from_scale(scale)
	return Transform3D(basis, Vector3(pos.x * WORLD_SCALE, ground_height(pos) + lift,
		pos.y * WORLD_SCALE))


func _base_scatter_point(b, rng: RandomNumberGenerator) -> Vector2:
	var rect: Rect2 = b.world_rect()
	var side := rng.randi_range(0, 3)
	var margin := rng.randf_range(7.0, 27.0)
	var p := rect.position
	var size := rect.size
	match side:
		0:
			p.x -= margin
			p.y += rng.randf_range(0.12, 0.88) * size.y
		1:
			p.x += size.x + margin
			p.y += rng.randf_range(0.12, 0.88) * size.y
		2:
			p.x += rng.randf_range(0.12, 0.88) * size.x
			p.y -= margin
		_:
			p.x += rng.randf_range(0.12, 0.88) * size.x
			p.y += size.y + margin
	return p


func _add_scatter_group(name: String, mesh: Mesh, transforms: Array[Transform3D],
		tones: Array[float], kind: int) -> MultiMeshInstance3D:
	if transforms.is_empty() or mesh == null:
		var empty := MultiMeshInstance3D.new()
		empty.name = name
		empty.visible = false
		world.add_child(empty)
		return empty
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	mm.custom_aabb = AABB(Vector3(-4.0, -2.0, -4.0),
		Vector3(float(map_size) + 8.0, 8.0, float(map_size) + 8.0))
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		mm.set_instance_custom_data(i, Color(tones[i], float(kind) / 4.0, 0.0, 0.0))
	var instance := MultiMeshInstance3D.new()
	instance.name = name
	instance.multimesh = mm
	instance.material_override = scatter_material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(instance)
	return instance


func _scatter_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, center: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 0.000001:
		return
	n = n.normalized()
	if n.dot((a + b + c) / 3.0 - center) < 0.0:
		n = -n
	for p in [a, b, c]:
		st.set_normal(n)
		st.add_vertex(p)


func _make_scatter_rock_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(0.0, 0.44, 0.0)
	var sides := 8
	var lower: Array[Vector3] = []
	var middle: Array[Vector3] = []
	var upper: Array[Vector3] = []
	for i in sides:
		var a := TAU * float(i) / float(sides) + 0.12
		var r := 0.70 + 0.22 * sin(float(i) * 2.7)
		lower.append(Vector3(cos(a) * r * 0.72, 0.03, sin(a) * r * 0.72))
		middle.append(Vector3(cos(a) * r, 0.40 + 0.08 * sin(float(i) * 1.7),
			sin(a) * r))
		upper.append(Vector3(cos(a) * r * 0.72, 0.74 + 0.09 * cos(float(i) * 2.1),
			sin(a) * r * 0.72))
	var apex := Vector3(0.03, 1.0, -0.02)
	var bottom := Vector3(0.0, 0.0, 0.0)
	for i in sides:
		var j := (i + 1) % sides
		_scatter_tri(st, bottom, lower[i], middle[i], center)
		_scatter_tri(st, bottom, middle[i], middle[j], center)
		_scatter_tri(st, lower[i], lower[j], middle[j], center)
		_scatter_tri(st, middle[i], middle[j], upper[j], center)
		_scatter_tri(st, middle[i], upper[j], upper[i], center)
		_scatter_tri(st, upper[i], upper[j], apex, center)
	return st.commit()


func _make_scatter_scrap_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(-0.5, 0.02, -0.34)
	var b := Vector3(0.5, 0.07, -0.46)
	var c := Vector3(0.42, 0.10, 0.42)
	var d := Vector3(-0.42, 0.03, 0.30)
	var center := Vector3(0.0, 0.05, 0.0)
	_scatter_tri(st, a, b, c, center)
	_scatter_tri(st, a, c, d, center)
	# A short folded return lip turns the sheet from a flat sticker into plate.
	var e := Vector3(0.5, 0.07, -0.46)
	var f := Vector3(0.44, 0.03, -0.60)
	var g := Vector3(0.36, 0.05, -0.52)
	_scatter_tri(st, e, f, g, center)
	return st.commit()


func _make_scatter_shrub_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(0.0, 0.28, 0.0)
	for i in 6:
		var a := TAU * float(i) / 6.0 + 0.17
		var side := Vector3(cos(a), 0.0, sin(a))
		var across := Vector3(-side.z, 0.0, side.x) * 0.045
		var tip := side * (0.34 + 0.1 * sin(float(i) * 2.3)) + Vector3(0.0, 0.68 + 0.16 * cos(float(i)), 0.0)
		_scatter_tri(st, Vector3(0.0, 0.02, 0.0), across, tip, center)
		_scatter_tri(st, Vector3(0.0, 0.02, 0.0), -across, tip, center)
	return st.commit()


func _make_scatter_crate_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.0, 1.0, 1.0)
	return mesh


func _make_scatter_canister_mesh() -> Mesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.5
	mesh.bottom_radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 10
	mesh.rings = 1
	return mesh


func _build_atmosphere() -> void:
	if env == null or env.environment == null or world == null:
		return
	var e := env.environment
	# A little more aerial depth than the terrain-only pass, but not enough to
	# flatten the plateau silhouettes into a milky backdrop.
	e.fog_density = maxf(e.fog_density, 0.0065)
	e.fog_light_energy = maxf(e.fog_light_energy, 0.72)
	e.adjustment_enabled = true
	e.adjustment_brightness = 1.015
	e.adjustment_contrast = 1.075
	e.adjustment_saturation = 0.945

	# Fine wind-blown motes. The emitter follows the camera focus, but each mote
	# lives in world space, so the field keeps its spatial parallax instead of
	# sticking to the lens.
	ambient_dust = _make_particles(120, 8.5, _dust_puff_mat, 0.20)
	ambient_dust.name = "AmbientDesertDust"
	ambient_dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	ambient_dust.emission_box_extents = Vector3(13.5, 2.2, 13.5)
	ambient_dust.direction = Vector3(0.94, 0.10, 0.32)
	ambient_dust.spread = 24.0
	ambient_dust.initial_velocity_min = 0.45
	ambient_dust.initial_velocity_max = 1.45
	ambient_dust.gravity = Vector3(0.0, 0.015, 0.0)
	ambient_dust.damping_min = 0.0
	ambient_dust.damping_max = 0.04
	ambient_dust.scale_amount_min = 0.35
	ambient_dust.scale_amount_max = 1.05
	ambient_dust.scale_amount_curve = _growth_curve(0.7, 1.7)
	ambient_dust.preprocess = 4.0
	ambient_dust.visibility_aabb = AABB(Vector3(-26.0, -4.0, -26.0), Vector3(52.0, 14.0, 52.0))
	ambient_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ambient_dust.emitting = true
	var dust_grad := Gradient.new()
	dust_grad.offsets = PackedFloat32Array([0.0, 0.18, 0.72, 1.0])
	dust_grad.colors = PackedColorArray([
		Color(0.92, 0.81, 0.65, 0.0), Color(0.90, 0.78, 0.61, 0.16),
		Color(0.82, 0.69, 0.52, 0.09), Color(0.72, 0.59, 0.44, 0.0)])
	ambient_dust.color_ramp = dust_grad
	world.add_child(ambient_dust)
	# Larger, much fainter puffs behind the motes. These are the actual visible
	# dust haze: soft ochre sheets that drift across the staging ground, not
	# hard specks. Kept at low alpha so the base stays readable.
	dust_veil = _make_particles(32, 13.0, _dust_puff_mat, 1.40)
	dust_veil.name = "GroundDustVeil"
	dust_veil.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	dust_veil.emission_box_extents = Vector3(14.0, 2.0, 14.0)
	dust_veil.direction = Vector3(0.92, 0.08, 0.38)
	dust_veil.spread = 30.0
	dust_veil.initial_velocity_min = 0.20
	dust_veil.initial_velocity_max = 0.55
	dust_veil.gravity = Vector3(0.0, 0.012, 0.0)
	dust_veil.damping_min = 0.0
	dust_veil.damping_max = 0.02
	dust_veil.scale_amount_min = 0.75
	dust_veil.scale_amount_max = 1.55
	dust_veil.scale_amount_curve = _growth_curve(0.8, 1.8)
	dust_veil.preprocess = 6.0
	dust_veil.visibility_aabb = AABB(Vector3(-28.0, -4.0, -28.0), Vector3(56.0, 14.0, 56.0))
	dust_veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var veil_grad := Gradient.new()
	veil_grad.offsets = PackedFloat32Array([0.0, 0.25, 0.72, 1.0])
	veil_grad.colors = PackedColorArray([
		Color(0.96, 0.84, 0.67, 0.0), Color(0.93, 0.81, 0.64, 0.13),
		Color(0.85, 0.72, 0.55, 0.08), Color(0.76, 0.63, 0.47, 0.0)])
	dust_veil.color_ramp = veil_grad
	world.add_child(dust_veil)
	_follow_atmosphere()

	_post_shader = load(POST_DUST_SHADER)
	if _post_shader != null:
		post_material = ShaderMaterial.new()
		post_material.shader = _post_shader
		post_rect = ColorRect.new()
		post_rect.name = "CinematicDustGrade"
		post_rect.color = Color(1.0, 1.0, 1.0, 1.0)
		post_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		post_rect.material = post_material
		layer_root.add_child(post_rect)
		if bar_overlay != null:
			layer_root.move_child(post_rect, bar_overlay.get_index())
		post_rect.size = Vector2(maxf(get_viewport().get_visible_rect().size.x - PANEL_WIDTH, 160.0),
			maxf(get_viewport().get_visible_rect().size.y, 160.0))


func _follow_atmosphere() -> void:
	if ambient_dust == null or not is_instance_valid(ambient_dust):
		return
	var focus := focus_px * WORLD_SCALE
	ambient_dust.position = Vector3(focus.x, ground_height(focus_px) + 1.0, focus.y)
	if dust_veil != null and is_instance_valid(dust_veil):
		dust_veil.position = Vector3(focus.x, ground_height(focus_px) + 1.8, focus.y)


func _build_tread_pool() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.0, 1.0)
	plane.subdivide_width = 0
	plane.subdivide_depth = 0
	tread_multimesh = MultiMesh.new()
	tread_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	tread_multimesh.use_custom_data = true
	tread_multimesh.mesh = plane
	tread_multimesh.instance_count = TRACK_POOL
	tread_multimesh.visible_instance_count = 0
	tread_multimesh.custom_aabb = AABB(Vector3(-4.0, -2.0, -4.0),
		Vector3(float(map_size) + 8.0, 8.0, float(map_size) + 8.0))
	tread_instance = MultiMeshInstance3D.new()
	tread_instance.name = "TreadMarks"
	tread_instance.multimesh = tread_multimesh
	tread_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = _tread_shader
	mat.set_shader_parameter("lifetime", TRACK_LIFETIME)
	mat.set_shader_parameter("rib_count", 9.0)
	mat.set_shader_parameter("tread_color", Color(0.245, 0.168, 0.102))
	tread_instance.material_override = mat
	world.add_child(tread_instance)


func _build_crater_pool() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.0, 1.0)
	plane.subdivide_width = 0
	plane.subdivide_depth = 0
	crater_multimesh = MultiMesh.new()
	crater_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	crater_multimesh.use_custom_data = true
	crater_multimesh.mesh = plane
	crater_multimesh.instance_count = CRATER_POOL
	crater_multimesh.visible_instance_count = 0
	crater_multimesh.custom_aabb = AABB(Vector3(-4.0, -2.0, -4.0),
		Vector3(float(map_size) + 8.0, 8.0, float(map_size) + 8.0))
	crater_instance = MultiMeshInstance3D.new()
	crater_instance.name = "BlastCraters"
	crater_instance.multimesh = crater_multimesh
	crater_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = _crater_shader
	mat.set_shader_parameter("lifetime", CRATER_LIFETIME)
	crater_instance.material_override = mat
	world.add_child(crater_instance)


func _stamp_tread(pos: Vector2, facing: float, width: float) -> void:
	if tread_multimesh == null:
		return
	# Follow the interpolated surface normal, not just its height. A flat quad
	# at a fixed y clips through dunes at tile seams; this keeps every grouser
	# print 0.04 above the local surface and tangent to the slope.
	var up := ground_normal(pos)
	var yaw := PI * 0.5 - facing
	var forward := Vector3(sin(yaw), 0.0, cos(yaw))
	forward = (forward - up * forward.dot(up)).normalized()
	var right := up.cross(forward).normalized()
	var basis := Basis(right, up, forward) * Basis.from_scale(Vector3(width, 1.0, 0.86))
	var at := Vector3(pos.x * WORLD_SCALE, ground_height(pos), pos.y * WORLD_SCALE) + up * 0.040
	var i := tread_next
	tread_multimesh.set_instance_transform(i, Transform3D(basis, at))
	tread_multimesh.set_instance_custom_data(i, Color(Time.get_ticks_msec() * 0.001, 0.0, 0.0, 0.0))
	tread_next = (tread_next + 1) % TRACK_POOL
	tread_used = mini(tread_used + 1, TRACK_POOL)
	tread_multimesh.visible_instance_count = tread_used


func _stamp_crater(pos: Vector2, radius: float) -> void:
	if crater_multimesh == null:
		return
	var y := ground_height(pos) + 0.022
	var yaw := float((crater_next * 47) % 360) * PI / 180.0
	var basis := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(radius, 1.0, radius))
	var i := crater_next
	crater_multimesh.set_instance_transform(i, Transform3D(basis,
		Vector3(pos.x * WORLD_SCALE, y, pos.y * WORLD_SCALE)))
	crater_multimesh.set_instance_custom_data(i, Color(Time.get_ticks_msec() * 0.001, 0.0, 0.0, 0.0))
	crater_next = (crater_next + 1) % CRATER_POOL
	crater_used = mini(crater_used + 1, CRATER_POOL)
	crater_multimesh.visible_instance_count = crater_used


# ------------------------------------------------------------- sandworm sign

## A travelling pair of sand ripples and trailing dust read the buried worm's
## position without revealing the hidden GLB. A translucent dome was tried and
## read as a glowing egg; concentric ground rings blend into the dunes instead.
func _add_worm_sign(rec: Dictionary) -> void:
	var sign_root := Node3D.new()
	sign_root.name = "WormSign"
	world.add_child(sign_root)

	var ripple_mat := StandardMaterial3D.new()
	ripple_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ripple_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ripple_mat.albedo_color = Color(0.50, 0.375, 0.235, 0.30)
	ripple_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.02
	torus.outer_radius = 1.09
	torus.rings = 40
	torus.ring_segments = 6
	ring.mesh = torus
	ring.material_override = ripple_mat
	ring.position.y = 0.020
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sign_root.add_child(ring)

	var inner_ring := MeshInstance3D.new()
	var inner_torus := TorusMesh.new()
	inner_torus.inner_radius = 0.60
	inner_torus.outer_radius = 0.655
	inner_torus.rings = 32
	inner_torus.ring_segments = 6
	inner_ring.mesh = inner_torus
	inner_ring.material_override = ripple_mat
	inner_ring.position.y = 0.018
	inner_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sign_root.add_child(inner_ring)

	var dust := _make_particles(13, 1.55, _dust_puff_mat, 0.44)
	dust.emitting = false
	dust.position = Vector3(0.0, 0.10, 0.0)
	dust.emission_sphere_radius = 0.70
	dust.spread = 55.0
	dust.direction = Vector3.UP
	dust.initial_velocity_min = 0.20
	dust.initial_velocity_max = 0.80
	dust.gravity = Vector3(0.0, 0.45, 0.0)
	dust.scale_amount_min = 0.45
	dust.scale_amount_max = 1.35
	dust.scale_amount_curve = _growth_curve(0.8, 2.4)
	dust.color = Color(1.0, 1.0, 1.0, 1.0)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.18, 1.0])
	grad.colors = PackedColorArray([
		Color(0.84, 0.72, 0.52, 0.0), Color(0.80, 0.67, 0.47, 0.28),
		Color(0.92, 0.81, 0.62, 0.0)])
	dust.color_ramp = grad
	sign_root.add_child(dust)

	rec["worm_sign"] = sign_root
	rec["worm_ring"] = ring
	rec["worm_dust"] = dust
	sign_root.visible = false


func _worm_debris_burst(pos_px: Vector2, power: float) -> void:
	var root := Node3D.new()
	root.name = "WormDebris"
	root.position = Vector3(pos_px.x * WORLD_SCALE, ground_height(pos_px) + 0.10,
		pos_px.y * WORLD_SCALE)
	world.add_child(root)
	var debris := _make_particles(26, 1.2, _debris_mat, 0.11)
	debris.one_shot = true
	debris.explosiveness = 1.0
	debris.emitting = false
	debris.spread = 86.0
	debris.initial_velocity_min = 2.0 * power
	debris.initial_velocity_max = 5.2 * power
	debris.gravity = Vector3(0.0, -9.0, 0.0)
	debris.scale_amount_min = 0.55
	debris.scale_amount_max = 1.45
	debris.angle_min = 0.0
	debris.angle_max = 360.0
	root.add_child(debris)
	debris.emitting = true
	var dust := _make_particles(20, 1.8, _dust_puff_mat, 0.95)
	dust.one_shot = true
	dust.explosiveness = 0.82
	dust.emitting = false
	dust.spread = 82.0
	dust.initial_velocity_min = 0.9 * power
	dust.initial_velocity_max = 3.0 * power
	dust.gravity = Vector3(0.0, 0.35, 0.0)
	dust.scale_amount_min = 0.8
	dust.scale_amount_max = 2.5
	dust.scale_amount_curve = _growth_curve(1.0, 2.8)
	dust.color = Color(1.0, 1.0, 1.0, 1.0)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.24, 1.0])
	grad.colors = PackedColorArray([
		Color(0.52, 0.40, 0.27, 0.0), Color(0.55, 0.43, 0.30, 0.62),
		Color(0.72, 0.60, 0.44, 0.0)])
	dust.color_ramp = grad
	root.add_child(dust)
	dust.emitting = true
	var cleanup := root.create_tween()
	cleanup.tween_interval(2.4)
	cleanup.tween_callback(root.queue_free)


# ------------------------------------------------------------------ weapons

func _spawn_projectile_visual(p) -> Dictionary:
	var root := Node3D.new()
	root.name = "Projectile3D"
	world.add_child(root)
	var style := "rifle"
	var big := false
	if p is BallisticProjectile:
		style = String(p.style)
	elif p is RocketProjectile:
		style = "rocket"
	elif p is AirstrikeMissile:
		style = "rocket"
		big = true
	elif p is DeathHand:
		style = "deathhand"
		big = true
	match style:
		"plasma":
			_build_plasma_bolts(root)
		"artillery":
			_build_artillery_shell(root)
		"rocket", "deathhand":
			_build_rocket(root, big)
		"light":
			_build_tracer(root, 0.46, 0.060)
		"cannon":
			_build_tracer(root, 0.40, 0.100)
		_:
			_build_tracer(root, 0.30, 0.040)
	return {"node": root, "kind": "projectile", "selected": false, "height": 0.0}


func _add_box_mesh(parent: Node3D, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _build_tracer(root: Node3D, length: float, thickness: float) -> void:
	var core := _add_box_mesh(root, Vector3(length, thickness, thickness), _tracer_mat)
	core.name = "Tracer"
	var streak := _add_box_mesh(root, Vector3(length * 2.2, thickness * 0.45, thickness * 0.45),
		_tracer_mat)
	streak.position.x = -length * 0.55
	streak.name = "TracerWake"
	var pip := _add_box_mesh(root, Vector3(length * 0.42, thickness * 1.15, thickness * 1.15),
		_tracer_core_mat)
	pip.position.x = length * 0.34


func _build_plasma_bolts(root: Node3D) -> void:
	for side in [-1.0, 1.0]:
		var bolt := _add_box_mesh(root, Vector3(0.66, 0.075, 0.075), _plasma_glow_mat)
		bolt.position.z = 0.080 * float(side)
		var core := _add_box_mesh(root, Vector3(0.48, 0.034, 0.034), _plasma_core_mat)
		core.position = Vector3(0.0, 0.0, 0.080 * float(side))
		var ember := _add_box_mesh(root, Vector3(0.24, 0.14, 0.14), _plasma_glow_mat)
		ember.position = Vector3(-0.38, 0.0, 0.080 * float(side))


func _build_artillery_shell(root: Node3D) -> void:
	var body := _add_box_mesh(root, Vector3(0.26, 0.13, 0.13), _debris_mat)
	body.name = "Shell"
	var band := _add_box_mesh(root, Vector3(0.05, 0.15, 0.15), _tracer_mat)
	band.position.x = 0.10
	var nose := _add_box_mesh(root, Vector3(0.10, 0.08, 0.08), _rocket_glow_mat)
	nose.position.x = 0.17
	_add_projectile_trail(root, 26, 1.0, 0.56, Color(0.30, 0.28, 0.25, 0.42))


func _build_rocket(root: Node3D, big: bool) -> void:
	var scale := 1.6 if big else 1.0
	var body := _add_box_mesh(root, Vector3(0.42, 0.10, 0.10) * scale, _debris_mat)
	body.name = "RocketBody"
	var nose := _add_box_mesh(root, Vector3(0.14, 0.065, 0.065) * scale, _tracer_core_mat)
	nose.position.x = 0.26 * scale
	var flame := _add_box_mesh(root, Vector3(0.22, 0.11, 0.11) * scale, _rocket_glow_mat)
	flame.position.x = -0.26 * scale
	_add_projectile_trail(root, 22 if big else 14, 0.85, 0.46 * scale,
		Color(0.42, 0.31, 0.23, 0.40))


func _add_projectile_trail(root: Node3D, amount: int, lifetime: float, size: float, tint: Color) -> void:
	var trail := _make_particles(amount, lifetime, _smoke_puff_mat, size)
	trail.position = Vector3.ZERO
	trail.emission_sphere_radius = 0.03
	trail.spread = 18.0
	trail.direction = Vector3.UP
	trail.initial_velocity_min = 0.02
	trail.initial_velocity_max = 0.28
	trail.gravity = Vector3(0.0, 0.22, 0.0)
	trail.scale_amount_min = 0.22
	trail.scale_amount_max = 0.72
	trail.scale_amount_curve = _growth_curve(0.5, 2.0)
	trail.color = Color(1.0, 1.0, 1.0, 1.0)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.18, 1.0])
	grad.colors = PackedColorArray([
		Color(tint.r, tint.g, tint.b, 0.0), tint, Color(tint.r, tint.g, tint.b, 0.0)])
	trail.color_ramp = grad
	root.add_child(trail)
	trail.emitting = true


# --------------------------------------------------------------- mirrored FX

## The 2D simulation owns every explosion, muzzle flash and status effect. The
## renderer only reads those effect arrays and mirrors each event once into a
## 3D burst, so no gameplay code is touched and switching back to Classic never
## leaves duplicate 3D effects running.
func _sync_fx() -> void:
	if game == null or game.fx == null:
		return
	var fx = game.fx
	for b in fx.blasts:
		if _fx_once(_fx_blast_memo, b):
			var pos: Vector2 = b.get("p", Vector2.ZERO)
			var power := clampf(float(b.get("power", 1.0)), 0.55, 2.4)
			_spawn_explosion(pos, power, true)
			_stamp_crater(pos, clampf(power * 1.15, 0.7, 2.6))
	for i in fx.impacts:
		if _fx_once(_fx_impact_memo, i):
			_spawn_impact(Vector2(i.get("p", Vector2.ZERO)), String(i.get("kind", "rifle")),
				clampf(float(i.get("power", 1.0)), 0.5, 2.4))
	for c in fx.gas_clouds:
		if _fx_once(_fx_gas_memo, c):
			_spawn_gas_cloud(Vector2(c.get("p", Vector2.ZERO)), float(c.get("r", 56.0)))
	for w in fx.waves:
		if _fx_once(_fx_wave_memo, w):
			_spawn_sonic_wave(Vector2(w.get("p", Vector2.ZERO)),
				Vector2.RIGHT.rotated(float(w.get("a", 0.0))), float(w.get("len", 120.0)))


func _fx_once(memo: Array, ref) -> bool:
	for old in memo:
		if is_same(old, ref):
			return false
	memo.append(ref)
	if memo.size() > 96:
		memo.pop_front()
	return true


func _spawn_impact(pos: Vector2, kind: String, power: float) -> void:
	match kind:
		"artillery":
			_spawn_explosion(pos, 1.75 * power, true)
			_stamp_crater(pos, 1.7 * power)
		"plasma":
			_spawn_explosion(pos, 1.20 * power, true)
			_spawn_flash(pos, Color(1.0, 0.16, 0.03, 0.85), 1.9, 0.24)
			_stamp_crater(pos, 1.1 * power)
		"cannon", "rocket":
			_spawn_explosion(pos, 0.90 * power, true)
			_stamp_crater(pos, 0.95 * power)
		_:
			_spawn_dust_puff(pos, 0.35 * power, Color(0.72, 0.60, 0.43, 0.55))


func _spawn_explosion(pos_px: Vector2, power: float, debris: bool) -> void:
	var pos := Vector3(pos_px.x * WORLD_SCALE, ground_height(pos_px) + 0.12,
		pos_px.y * WORLD_SCALE)
	var root := Node3D.new()
	root.name = "Explosion3D"
	root.position = pos
	world.add_child(root)

	var fire := _make_particles(int(22.0 * clampf(power, 0.6, 2.2)), 0.66, _fire_puff_mat, 0.56)
	fire.one_shot = true
	fire.explosiveness = 0.96
	fire.emitting = false
	fire.emission_sphere_radius = 0.32
	fire.spread = 78.0
	fire.initial_velocity_min = 0.8 * power
	fire.initial_velocity_max = 2.8 * power
	fire.gravity = Vector3(0.0, 1.2, 0.0)
	fire.scale_amount_min = 0.42 * power
	fire.scale_amount_max = 1.30 * power
	fire.scale_amount_curve = _growth_curve(0.7, 2.1)
	fire.color = Color(1.0, 1.0, 1.0, 1.0)
	var hot := Gradient.new()
	hot.offsets = PackedFloat32Array([0.0, 0.22, 0.62, 1.0])
	hot.colors = PackedColorArray([
		Color(1.0, 0.97, 0.78, 0.95), Color(1.0, 0.62, 0.10, 0.85),
		Color(0.86, 0.22, 0.03, 0.42), Color(0.20, 0.12, 0.07, 0.0)])
	fire.color_ramp = hot
	root.add_child(fire)
	fire.emitting = true

	var smoke := _make_particles(int(10.0 * clampf(power, 0.6, 2.0)), 1.9, _smoke_puff_mat, 0.92)
	smoke.one_shot = true
	smoke.explosiveness = 0.86
	smoke.emitting = false
	smoke.emission_sphere_radius = 0.38
	smoke.spread = 72.0
	smoke.initial_velocity_min = 0.55 * power
	smoke.initial_velocity_max = 2.3 * power
	smoke.gravity = Vector3(0.0, 0.50, 0.0)
	smoke.scale_amount_min = 0.80
	smoke.scale_amount_max = 2.7
	smoke.scale_amount_curve = _growth_curve(1.0, 3.2)
	smoke.color = Color(1.0, 1.0, 1.0, 1.0)
	var soot := Gradient.new()
	soot.offsets = PackedFloat32Array([0.0, 0.20, 1.0])
	soot.colors = PackedColorArray([
		Color(0.42, 0.365, 0.30, 0.0), Color(0.40, 0.35, 0.30, 0.30),
		Color(0.54, 0.48, 0.40, 0.0)])
	smoke.color_ramp = soot
	root.add_child(smoke)
	smoke.emitting = true

	_spawn_flash(pos_px, Color(1.0, 0.52, 0.10, 0.72), 1.85 * power, 0.26)
	if debris:
		_spawn_debris(root, power)
	var cleanup := root.create_tween()
	cleanup.tween_interval(2.6)
	cleanup.tween_callback(root.queue_free)


func _spawn_flash(pos_px: Vector2, color: Color, size: float, life: float) -> void:
	var pos := Vector3(pos_px.x * WORLD_SCALE, ground_height(pos_px) + 0.35,
		pos_px.y * WORLD_SCALE)
	var flash := MeshInstance3D.new()
	flash.name = "BlastFlash"
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 12
	sphere.rings = 6
	flash.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = color
	flash.material_override = mat
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.position = pos
	world.add_child(flash)
	var tw := flash.create_tween()
	tw.set_parallel(true)
	tw.tween_property(flash, "scale", Vector3.ONE * size, life)
	tw.tween_property(mat, "albedo_color", Color(color.r, color.g, color.b, 0.0), life)
	tw.tween_property(flash, "position:y", pos.y + 0.55 * size, life)
	var cleanup := flash.create_tween()
	cleanup.tween_interval(life + 0.1)
	cleanup.tween_callback(flash.queue_free)


func _spawn_debris(parent: Node3D, power: float) -> void:
	var debris := _make_particles(int(9.0 * clampf(power, 0.6, 2.2)), 1.05, _debris_mat, 0.10)
	debris.one_shot = true
	debris.explosiveness = 1.0
	debris.emitting = false
	debris.spread = 70.0
	debris.initial_velocity_min = 1.4 * power
	debris.initial_velocity_max = 4.0 * power
	debris.gravity = Vector3(0.0, -9.0, 0.0)
	debris.scale_amount_min = 0.45
	debris.scale_amount_max = 1.25
	parent.add_child(debris)
	debris.emitting = true


func _spawn_dust_puff(pos_px: Vector2, power: float, tint: Color) -> void:
	var pos := Vector3(pos_px.x * WORLD_SCALE, ground_height(pos_px) + 0.08,
		pos_px.y * WORLD_SCALE)
	var root := Node3D.new()
	root.position = pos
	world.add_child(root)
	var dust := _make_particles(7, 0.9, _dust_puff_mat, 0.42)
	dust.one_shot = true
	dust.explosiveness = 0.9
	dust.emitting = false
	dust.spread = 58.0
	dust.initial_velocity_min = 0.3 * power
	dust.initial_velocity_max = 1.4 * power
	dust.gravity = Vector3(0.0, 0.35, 0.0)
	dust.scale_amount_min = 0.4
	dust.scale_amount_max = 1.2
	dust.scale_amount_curve = _growth_curve(0.8, 2.2)
	dust.color = Color(1.0, 1.0, 1.0, 1.0)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.20, 1.0])
	grad.colors = PackedColorArray([
		Color(tint.r, tint.g, tint.b, 0.0), tint, Color(tint.r, tint.g, tint.b, 0.0)])
	dust.color_ramp = grad
	root.add_child(dust)
	dust.emitting = true
	var cleanup := root.create_tween()
	cleanup.tween_interval(1.4)
	cleanup.tween_callback(root.queue_free)


func _spawn_gas_cloud(pos_px: Vector2, radius_px: float) -> void:
	var pos := Vector3(pos_px.x * WORLD_SCALE, ground_height(pos_px) + 0.35,
		pos_px.y * WORLD_SCALE)
	var root := Node3D.new()
	root.name = "DeviatorGas3D"
	root.position = pos
	world.add_child(root)
	var gas := _make_particles(26, 2.6, _gas_puff_mat, 1.02)
	gas.one_shot = true
	gas.explosiveness = 0.32
	gas.emitting = false
	gas.emission_sphere_radius = radius_px * WORLD_SCALE * 0.42
	gas.spread = 180.0
	gas.direction = Vector3.UP
	gas.initial_velocity_min = 0.20
	gas.initial_velocity_max = 1.05
	gas.gravity = Vector3(0.0, 0.36, 0.0)
	gas.scale_amount_min = 0.65
	gas.scale_amount_max = 1.85
	gas.scale_amount_curve = _growth_curve(1.0, 3.0)
	gas.color = Color(1.0, 1.0, 1.0, 1.0)
	var green := Gradient.new()
	green.offsets = PackedFloat32Array([0.0, 0.16, 0.70, 1.0])
	green.colors = PackedColorArray([
		Color(0.24, 1.0, 0.36, 0.0), Color(0.06, 0.72, 0.20, 0.68),
		Color(0.04, 0.54, 0.14, 0.44), Color(0.34, 1.0, 0.40, 0.0)])
	gas.color_ramp = green
	root.add_child(gas)
	gas.emitting = true
	var cleanup := root.create_tween()
	cleanup.tween_interval(3.4)
	cleanup.tween_callback(root.queue_free)


func _spawn_sonic_wave(pos_px: Vector2, dir_px: Vector2, length_px: float) -> void:
	var start := Vector3(pos_px.x * WORLD_SCALE, ground_height(pos_px) + 0.10,
		pos_px.y * WORLD_SCALE)
	var dir := Vector3(dir_px.x, 0.0, dir_px.y).normalized()
	var root := Node3D.new()
	root.name = "SonicWave3D"
	world.add_child(root)
	var travel := length_px * WORLD_SCALE
	for i in 3:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.30 + float(i) * 0.08
		torus.outer_radius = 0.37 + float(i) * 0.10
		torus.rings = 28
		torus.ring_segments = 6
		ring.mesh = torus
		var mat := _sonic_ring_mat.duplicate() as StandardMaterial3D
		ring.material_override = mat
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.position = start + dir * (0.35 + float(i) * 0.36)
		ring.scale = Vector3(1.0, 0.75, 1.0)
		root.add_child(ring)
		var tw := ring.create_tween()
		tw.set_parallel(true)
		tw.tween_property(ring, "position", start + dir * (travel * (0.55 + 0.18 * float(i))), 0.46)
		tw.tween_property(ring, "scale", Vector3(3.1 + float(i) * 0.8, 1.0, 3.1 + float(i) * 0.8), 0.46)
		tw.tween_property(mat, "albedo_color", Color(0.14, 0.58, 0.96, 0.0), 0.48)
	var cleanup := root.create_tween()
	cleanup.tween_interval(0.58)
	cleanup.tween_callback(root.queue_free)


# ------------------------------------------------------------ 2D health bars

func draw_health_bars(ci: CanvasItem) -> void:
	if not active or camera == null or viewport == null:
		return
	var play := viewport.size
	var ui_scale := clampf(float(play.y) / 720.0, 0.85, 1.30)
	for id in _entities:
		var rec: Dictionary = _entities[id]
		if not bool(rec.get("bar_show", false)):
			continue
		var node = rec.get("node")
		if node == null or not is_instance_valid(node) or not node.visible:
			continue
		var anchor: Vector3 = (node as Node3D).global_position \
			+ Vector3(0.0, float(rec.get("height", 1.0)) + 0.18, 0.0)
		if camera.is_position_behind(anchor):
			continue
		var p := camera.unproject_position(anchor)
		if p.x < -60.0 or p.y < -30.0 or p.x > float(play.x) + 60.0 or p.y > float(play.y) + 30.0:
			continue
		var w := float(rec.get("bar_w", 32.0)) * ui_scale
		var h := 5.0 * ui_scale
		var x := p.x - w * 0.5
		var y := p.y - h * 0.5
		var ratio := clampf(float(rec.get("bar_ratio", 1.0)), 0.0, 1.0)
		var band := int(rec.get("bar_band", 0))
		var fill: Color = [Color(0.42, 0.88, 0.26), Color(0.98, 0.75, 0.12),
			Color(0.95, 0.22, 0.12)][band]
		# Crisp black contour, dark recessed trough, then the coloured fill.
		ci.draw_rect(Rect2(x - 1.5 * ui_scale, y - 1.5 * ui_scale,
			w + 3.0 * ui_scale, h + 3.0 * ui_scale), Color(0.050, 0.030, 0.014, 0.97), true)
		ci.draw_rect(Rect2(x, y, w, h), Color(0.105, 0.078, 0.046, 0.95), true)
		var inner_w := maxf((w - 1.2 * ui_scale) * ratio, 0.0)
		ci.draw_rect(Rect2(x + 0.6 * ui_scale, y + 0.6 * ui_scale,
			inner_w, h - 1.2 * ui_scale), fill, true)
		ci.draw_line(Vector2(x + 0.6 * ui_scale, y + 0.85 * ui_scale),
			Vector2(x + 0.6 * ui_scale + inner_w, y + 0.85 * ui_scale),
			fill.lightened(0.42), maxf(1.0, ui_scale))


class HealthBars extends Control:
	var host = null

	func _draw() -> void:
		if host != null:
			host.draw_health_bars(self)
