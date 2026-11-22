extends Node

## Sandwar 3D-to-2D building baker.
##
## Run this scene (not --headless) when the 3D assets need regenerating:
##
##   ~/.local/bin/godot --path . tools/bake_buildings_3d.tscn
##
## The fixed camera looks straight north from +Z with no yaw. This is a
## square-grid 3/4 oblique view, not diamond isometric: footprint edges stay
## parallel to the screen's horizontal and vertical axes. The NW key light
## stays fixed while each building is rendered for four idle and four damaged
## frames. Turret heads are rendered separately in 16 directions.

const TILE := 40
const MARGIN := 72
const FRAMES := 4
const OUT_DIR := "res://assets/sprites/buildings"
const PREVIEW_PATH := "res://build/buildings3d_preview.png"
const SLAB_PAVEMENT_PATH := "res://assets/sprites/buildings/slab_pavement.png"
const SLAB_PAVEMENT_FRAMES := 4
const RENDER_SCALE := 2
const HEAD_FRAMES := 16
const MAT_SIZE := 256

const SPECS := {
	"cy": {"span": Vector2i(3, 3)},
	"refinery": {"span": Vector2i(3, 2)},
	"windtrap": {"span": Vector2i(2, 2)},
	"barracks": {"span": Vector2i(2, 2)},
	"factory": {"span": Vector2i(3, 2)},
	"turret": {"span": Vector2i(1, 1)},
	"rocketturret": {"span": Vector2i(1, 1)},
	"wall": {"span": Vector2i(1, 1)},
	"slab": {"span": Vector2i(1, 1)},
}

var viewport: SubViewport
var camera: Camera3D
var stage: Node3D
var sun: DirectionalLight3D
var fill: OmniLight3D
var rim: DirectionalLight3D
var assembly: Node3D
var mats: Dictionary = {}
var preview_tiles: Array[Image] = []


func _ready() -> void:
	_build_renderer()
	await _bake_all()
	get_tree().quit()


func _build_renderer() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(512, 512)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	# A little multisampling makes the tiny bolts and seams survive downscale.
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.43, 0.47, 0.50)
	environment.ambient_light_energy = 0.82
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	# Forward+ supports this; the GL Compatibility baker ignores it, so the
	# material seams and the post-pass remain responsible for crevice contrast.
	environment.ssao_enabled = true
	environment.ssao_radius = 1.2
	environment.ssao_intensity = 2.2
	environment.ssao_power = 2.0
	env.environment = environment
	viewport.add_child(env)

	sun = DirectionalLight3D.new()
	# Fixed NW key: light travels towards the south-east, so the baked soft
	# drop shadow and the crisp geometry shadow both fall bottom-right.
	sun.rotation_degrees = Vector3(-52.0, -34.0, 0.0)
	sun.light_color = Color(1.0, 0.93, 0.80)
	sun.light_energy = 1.40
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	viewport.add_child(sun)

	fill = OmniLight3D.new()
	fill.position = Vector3(-2.8, 3.8, 3.2)
	fill.light_color = Color(0.92, 0.55, 0.30)
	fill.light_energy = 0.34
	fill.omni_range = 15.0
	fill.shadow_enabled = false
	viewport.add_child(fill)

	rim = DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-24.0, 142.0, 0.0)
	rim.light_color = Color(0.40, 0.50, 0.60)
	rim.light_energy = 0.48
	rim.shadow_enabled = false
	viewport.add_child(rim)

	# A soft front-side fill keeps the south-facing walls readable. Without it
	# the NW key leaves the whole camera-facing wall in near-black shadow.
	var front_fill := DirectionalLight3D.new()
	front_fill.rotation_degrees = Vector3(-18.0, 174.0, 0.0)
	front_fill.light_color = Color(0.64, 0.68, 0.72)
	front_fill.light_energy = 0.58
	front_fill.shadow_enabled = false
	viewport.add_child(front_fill)

	stage = Node3D.new()
	viewport.add_child(stage)

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.05
	camera.far = 60.0
	camera.look_at_from_position(Vector3(0.0, 9.0, 7.5), Vector3(0.0, 0.7, 0.0), Vector3.UP)
	viewport.add_child(camera)

	_build_materials()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))


# --------------------------------------------------------------- surfaces

func _build_materials() -> void:
	mats = {
		"concrete": _surface("concrete", Color(0.60, 0.45, 0.31), 0.91, 0.03, 11, 2.2, 1.45),
		"concrete_light": _surface("concrete", Color(0.76, 0.62, 0.46), 0.87, 0.03, 12, 2.4, 1.35),
		"pave": _surface("pave", Color("c99a74"), 0.93, 0.02, 13, 2.0, 1.0),
		"pave_light": _surface("pave", Color("ddb68d"), 0.89, 0.02, 14, 2.1, 1.0),
		"metal": _surface("metal", Color(0.50, 0.56, 0.58), 0.48, 0.20, 21, 3.0, 1.7),
		"metal_light": _surface("metal", Color(0.76, 0.81, 0.81), 0.42, 0.14, 22, 3.2, 1.5),
		"armor": _surface("armor", Color(0.84, 0.86, 0.83), 0.58, 0.10, 23, 2.4, 1.0),
		"roof": _surface("roof", Color(0.70, 0.76, 0.77), 0.46, 0.14, 24, 4.0, 1.4),
		"steel_dark": _surface("metal", Color(0.26, 0.32, 0.34), 0.50, 0.28, 27, 2.7, 1.5),
		"dark": _surface("dark", Color(0.09, 0.11, 0.11), 0.71, 0.24, 31, 2.4, 1.2),
		"crack": _surface("crack", Color(0.18, 0.16, 0.13), 0.96, 0.02, 32, 1.8, 1.0),
		"rust": _surface("rust", Color(0.27, 0.14, 0.07), 0.88, 0.16, 41, 2.5, 1.4),
		"trim": _surface("trim", Color(0.86, 0.055, 0.58), 0.47, 0.33, 51, 2.2, 1.4),
		"hazard": _surface("hazard", Color(0.55, 0.38, 0.14), 0.66, 0.18, 61, 2.6, 1.4),
		"cyan": _surface("emissive", Color(0.02, 0.76, 0.70), 0.25, 0.10, 71, 2.0, 1.0, Color(0.03, 1.0, 0.82)),
		"amber": _surface("emissive", Color(0.98, 0.48, 0.08), 0.30, 0.16, 81, 2.0, 1.0, Color(1.0, 0.32, 0.03)),
		"white": _surface("concrete", Color(0.84, 0.85, 0.82), 0.66, 0.04, 91, 2.0, 1.2),
		"sand": _surface("concrete", Color(0.70, 0.59, 0.43), 0.97, 0.02, 101, 2.0, 0.8),
		"grill": _surface("grill", Color(0.10, 0.17, 0.17), 0.46, 0.52, 111, 2.4, 1.3),
		"black": _surface("dark", Color(0.045, 0.055, 0.052), 0.79, 0.20, 121, 1.8, 1.0),
	}
	# Bright yellow survives only as tiny docking/status lamps, never as broad
	# stripes across the armor.
	mats["yellow"] = mats["amber"]


func _surface(kind: String, base: Color, roughness: float, metallic: float,
		seed_value: int, tile_scale: float, normal_strength: float,
		emission := Color.TRANSPARENT) -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.021
	noise.fractal_octaves = 4
	var fine := FastNoiseLite.new()
	fine.seed = seed_value + 97
	fine.frequency = 0.57
	fine.fractal_octaves = 2

	var albedo := Image.create(MAT_SIZE, MAT_SIZE, false, Image.FORMAT_RGBA8)
	var normal := Image.create(MAT_SIZE, MAT_SIZE, false, Image.FORMAT_RGBA8)
	var rough := Image.create(MAT_SIZE, MAT_SIZE, false, Image.FORMAT_RGBA8)
	var heights := PackedFloat32Array()
	heights.resize(MAT_SIZE * MAT_SIZE)
	for y in MAT_SIZE:
		for x in MAT_SIZE:
			var n := noise.get_noise_2d(float(x), float(y))
			var f := fine.get_noise_2d(float(x), float(y))
			var sample := _sample_surface(kind, x, y, base, n, f, seed_value)
			var col := Color(clampf(sample.x, 0.0, 1.0), clampf(sample.y, 0.0, 1.0),
				clampf(sample.z, 0.0, 1.0), 1.0)
			albedo.set_pixel(x, y, col)
			var h := sample.w
			heights[y * MAT_SIZE + x] = h
			var rv := clampf(roughness + (1.0 - h) * 0.22 + absf(f) * 0.08, 0.08, 0.99)
			if kind == "rust" or kind == "concrete" or kind == "pave":
				rv = clampf(rv + 0.06, 0.08, 0.99)
			rough.set_pixel(x, y, Color(rv, rv, rv, 1.0))

	for y in MAT_SIZE:
		for x in MAT_SIZE:
			var h := heights[y * MAT_SIZE + x]
			var hl := heights[y * MAT_SIZE + maxi(x - 1, 0)]
			var hr := heights[y * MAT_SIZE + mini(x + 1, MAT_SIZE - 1)]
			var hu := heights[maxi(y - 1, 0) * MAT_SIZE + x]
			var hd := heights[mini(y + 1, MAT_SIZE - 1) * MAT_SIZE + x]
			var nv := Vector3(-(hr - hl) * normal_strength * 5.0,
				-(hd - hu) * normal_strength * 5.0, 1.0).normalized()
			normal.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5,
				nv.z * 0.5 + 0.5, 1.0))

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(albedo)
	mat.normal_enabled = true
	mat.normal_texture = ImageTexture.create_from_image(normal)
	mat.normal_scale = normal_strength
	mat.roughness_texture = ImageTexture.create_from_image(rough)
	mat.roughness_texture_channel = 0
	mat.roughness = roughness
	mat.metallic = metallic
	mat.metallic_specular = 0.45
	mat.uv1_triplanar = false
	mat.uv1_scale = Vector3(tile_scale, tile_scale, tile_scale)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if emission.a > 0.0:
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = 2.2
	return mat


## One procedural texel. Returns (albedo.r, albedo.g, albedo.b, height).
## The pattern is repeated across UVs, with panel seams, rivets, grime and
## chipped paint encoded into both the colour and the bump map.
func _sample_surface(kind: String, x: int, y: int, base: Color, n: float,
		f: float, seed_value: int) -> Vector4:
	var r := base.r
	var g := base.g
	var b := base.b
	var h := 0.5
	var panel := 32
	var sx := x % panel
	var sy := y % panel
	var seam := 1.0 if sx < 2 or sy < 2 else 0.0
	var rivet := 0.0
	if mini(sx, panel - sx) < 2 and mini(sy, panel - sy) < 2:
		rivet = 1.0
	var speck := _hash2(x, y, seed_value)
	var rust := _sstep(0.28, 0.82, n * 0.5 + 0.5)
	var grime := _sstep(0.15, 0.85, f * 0.5 + 0.5)

	match kind:
		"armor":
			# Sun-bleached brushed plate for round keep walls, turbine pods and
			# silos. No rectangular panel grid: only fine directional brushing.
			var brushed := 0.5 + 0.5 * f
			var pitting := 1.0 if speck > 0.991 else 0.0
			var factor := 0.90 + 0.045 * brushed + n * 0.030 - pitting * 0.16
			r = clampf(base.r * factor, 0.0, 1.0)
			g = clampf(base.g * factor, 0.0, 1.0)
			b = clampf(base.b * factor, 0.0, 1.0)
			r = lerpf(r, base.r * 1.04, _sstep(0.80, 0.96, f * 0.5 + 0.5) * 0.35)
			g = lerpf(g, base.g * 1.04, _sstep(0.80, 0.96, f * 0.5 + 0.5) * 0.35)
			b = lerpf(b, base.b * 1.04, _sstep(0.80, 0.96, f * 0.5 + 0.5) * 0.35)
			h = 0.52 + f * 0.026 - pitting * 0.025
		"roof":
			# Longitudinal ribbing, not a square panel grid, so the barrel
			# vault keeps a readable curved silhouette under the NW key light.
			var rib := 1.0 if (x % 14) < 2 else 0.0
			var streak := 0.5 + 0.5 * f
			var factor := 0.90 + 0.10 * (n * 0.5 + 0.5) + 0.035 * streak - rib * 0.10
			r = clampf(base.r * factor, 0.0, 1.0)
			g = clampf(base.g * factor, 0.0, 1.0)
			b = clampf(base.b * factor, 0.0, 1.0)
			r = lerpf(r, 0.48, _sstep(0.80, 0.94, f * 0.5 + 0.5) * 0.06)
			g = lerpf(g, 0.50, _sstep(0.80, 0.94, f * 0.5 + 0.5) * 0.06)
			b = lerpf(b, 0.50, _sstep(0.80, 0.94, f * 0.5 + 0.5) * 0.06)
			h = 0.52 + f * 0.028 - rib * 0.14
		"metal", "dark", "crack":
			panel = 32 if kind == "metal" else 24
			sx = x % panel
			sy = y % panel
			seam = 1.0 if sx < 2 or sy < 2 else 0.0
			rivet = 0.0
			if mini(sx, panel - sx) < 2 and mini(sy, panel - sy) < 2:
				rivet = 1.0
			var brushed := 0.72 + 0.28 * (f * 0.5 + 0.5)
			var rust_patch := _sstep(0.38, 0.82, n * 0.5 + 0.5)
			var oil := _sstep(0.48, 0.90, f * -0.5 + 0.5) * 0.35
			var factor := 0.82 + 0.20 * brushed - 0.34 * seam - 0.14 * oil
			r = base.r * factor
			g = base.g * factor
			b = base.b * factor
			r = lerpf(r, 0.30, rust_patch * (0.26 if kind == "metal" else 0.12))
			g = lerpf(g, 0.13, rust_patch * (0.18 if kind == "metal" else 0.10))
			b = lerpf(b, 0.055, rust_patch * (0.10 if kind == "metal" else 0.07))
			r = lerpf(r, base.r * 1.42, rivet * 0.62)
			g = lerpf(g, base.g * 1.40, rivet * 0.62)
			b = lerpf(b, base.b * 1.34, rivet * 0.62)
			h = 0.50 + f * 0.05 - seam * 0.23 + rivet * 0.14 - rust_patch * 0.035
		"concrete", "pave", "white", "sand":
			panel = 64 if kind != "pave" else 32
			sx = x % panel
			sy = y % panel
			seam = 1.0 if sx < 2 or sy < 2 else 0.0
			var pit := 1.0 if speck > (0.973 if kind != "pave" else 0.962) else 0.0
			var crack := 1.0 if absf(n) < 0.038 or (absf(n) < 0.052 and speck > 0.82) else 0.0
			var grit := (speck - 0.5) * 0.20
			var factor := 0.80 + 0.20 * (n * 0.5 + 0.5) + grit - seam * 0.34
			r = base.r * factor
			g = base.g * factor
			b = base.b * factor
			if crack > 0.0:
				r *= 0.44
				g *= 0.43
				b *= 0.41
			if pit > 0.0:
				r *= 0.66
				g *= 0.64
				b *= 0.60
			r = lerpf(r, 0.70, _sstep(0.73, 0.93, f * 0.5 + 0.5) * 0.10)
			g = lerpf(g, 0.66, _sstep(0.73, 0.93, f * 0.5 + 0.5) * 0.09)
			b = lerpf(b, 0.56, _sstep(0.73, 0.93, f * 0.5 + 0.5) * 0.08)
			h = 0.52 + n * 0.025 + f * 0.025 - seam * 0.18 - crack * 0.18 - pit * 0.08
		"trim":
			panel = 28
			sx = x % panel
			sy = y % panel
			seam = 1.0 if sx < 2 or sy < 2 else 0.0
			rivet = 0.0
			if mini(sx, panel - sx) < 2 and mini(sy, panel - sy) < 2:
				rivet = 1.0
			var paint := 0.84 + 0.13 * (n * 0.5 + 0.5) - seam * 0.22
			# Keep the magenta key strongly saturated so the faction shader can
			# recover blue/red/green house paint without losing panel wear.
			r = clampf(base.r * paint, 0.0, 1.0)
			g = clampf(base.g * paint, 0.0, 1.0)
			b = clampf(base.b * paint, 0.0, 1.0)
			if rivet > 0.0:
				r = lerpf(r, 1.0, 0.38)
				g = lerpf(g, 0.43, 0.24)
				b = lerpf(b, 0.86, 0.30)
			h = 0.50 + f * 0.025 - seam * 0.16 + rivet * 0.11
		"hazard":
			panel = 40
			var stripe := 1.0 if ((x + y) % panel) < panel * 0.5 else 0.0
			var chip := 1.0 if speck > 0.88 or absf(f) > 0.89 else 0.0
			if stripe > 0.0:
				r = 0.38
				g = 0.28
				b = 0.11
			else:
				r = 0.085
				g = 0.078
				b = 0.060
			if chip > 0.0:
				r = lerpf(r, 0.38, 0.70)
				g = lerpf(g, 0.18, 0.70)
				b = lerpf(b, 0.07, 0.70)
			r *= 0.78 + 0.24 * (n * 0.5 + 0.5)
			g *= 0.78 + 0.24 * (n * 0.5 + 0.5)
			b *= 0.82 + 0.20 * (n * 0.5 + 0.5)
			h = 0.50 - chip * 0.08 + f * 0.025
		"grill":
			panel = 16
			var bar := 1.0 if (y % panel) < 4 else 0.0
			var cross := 1.0 if (x % 42) < 2 else 0.0
			var glow := 0.0
			r = 0.055
			g = 0.060
			b = 0.055
			if bar > 0.0:
				r = 0.21
				g = 0.23
				b = 0.22
				h = 0.64
			if cross > 0.0:
				r = 0.30
				g = 0.32
				b = 0.30
				h = 0.72
			r += glow
			g += glow
			b += glow
			r *= 0.86 + 0.26 * (n * 0.5 + 0.5)
			g *= 0.86 + 0.26 * (n * 0.5 + 0.5)
			b *= 0.86 + 0.26 * (n * 0.5 + 0.5)
			h = 0.50 + bar * 0.16 + cross * 0.06 + f * 0.02
		"rust":
			var peel := 1.0 if speck > 0.90 else 0.0
			r = 0.36 + 0.12 * (n * 0.5 + 0.5) + peel * 0.18
			g = 0.14 + 0.08 * (f * 0.5 + 0.5) + peel * 0.10
			b = 0.045 + 0.035 * (n * 0.5 + 0.5)
			h = 0.48 + f * 0.08 - peel * 0.08
		"emissive":
			var pulse := 0.70 + 0.30 * absf(sin(float(x + y) * 0.07))
			r = base.r * pulse
			g = base.g * pulse
			b = base.b * pulse
			h = 0.55 + f * 0.03
		_:
			r = base.r * (0.76 + 0.22 * (n * 0.5 + 0.5))
			g = base.g * (0.76 + 0.22 * (n * 0.5 + 0.5))
			b = base.b * (0.76 + 0.22 * (n * 0.5 + 0.5))
			h = 0.50 + f * 0.04

	# Fine dust in the recesses and a touch of warm bounce on upward wear.
	var dust := _sstep(0.72, 0.96, f * 0.5 + 0.5) * 0.055
	r = clampf(r + dust * 0.75, 0.0, 1.0)
	g = clampf(g + dust * 0.62, 0.0, 1.0)
	b = clampf(b + dust * 0.48, 0.0, 1.0)
	if kind == "trim":
		# Never let the dust pass desaturate the faction key.
		r = maxf(r, base.r * 0.60)
		g = minf(g, base.g * 1.14)
		b = maxf(b, base.b * 0.60)
	return Vector4(r, g, b, h)


func _hash2(x: int, y: int, seed_value: int) -> float:
	var h: int = (x * 73856093) ^ (y * 19349663) ^ (seed_value * 83492791)
	h = abs(h)
	return float(h % 1000003) / 1000003.0


func _sstep(e0: float, e1: float, value: float) -> float:
	if e1 <= e0:
		return 1.0 if value >= e1 else 0.0
	var t := clampf((value - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


# --------------------------------------------------------------- primitives

func make_box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material,
		rot := Vector3.ZERO) -> CSGBox3D:
	var node := CSGBox3D.new()
	node.size = size
	node.position = pos
	node.rotation_degrees = rot
	node.material = mat
	node.use_collision = false
	parent.add_child(node)
	return node


func make_cyl(parent: Node3D, radius: float, height: float, pos: Vector3,
		mat: Material, rot := Vector3.ZERO, sides := 16) -> CSGCylinder3D:
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


func make_sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material,
		scale := Vector3.ONE) -> CSGSphere3D:
	var node := CSGSphere3D.new()
	node.radius = radius
	node.position = pos
	node.scale = scale
	node.material = mat
	node.use_collision = false
	parent.add_child(node)
	return node


## A barrel vault is a long cylinder partly buried in the building body. Only
## the top half reads, giving the broad curved hangar roofs of Dune 2000.
## Thin oversized discs become the ribbed armor collars along the vault.
func add_barrel_vault(root: Node3D, center: Vector3, radius: float, length: float,
		axis: String, body_mat: Material, rib_mat: Material, rib_count := 5) -> void:
	var rot := Vector3(0.0, 0.0, 90.0) if axis == "x" else Vector3(90.0, 0.0, 0.0)
	make_cyl(root, radius, length, center, body_mat, rot, 28)
	for i in rib_count:
		var t := (float(i) + 0.5) / float(rib_count)
		var p := center
		if axis == "x":
			p.x += lerpf(-length * 0.5, length * 0.5, t)
		else:
			p.z += lerpf(-length * 0.5, length * 0.5, t)
		make_cyl(root, radius * 1.018, 0.035, p, rib_mat, rot, 28)
	for end in [-1.0, 1.0]:
		var p := center
		if axis == "x":
			p.x += end * (length * 0.5 - 0.02)
		else:
			p.z += end * (length * 0.5 - 0.02)
		make_cyl(root, radius * 1.025, 0.055, p, mats["metal_light"], rot, 28)


func bolts_x(root: Node3D, x0: float, x1: float, y: float, z: float, count: int,
		mat: Material) -> void:
	for i in count:
		var x := lerpf(x0, x1, float(i) / float(maxi(count - 1, 1)))
		make_cyl(root, 0.018, 0.026, Vector3(x, y, z), mat, Vector3(90.0, 0.0, 0.0), 6)


func bolts_z(root: Node3D, z0: float, z1: float, x: float, y: float, count: int,
		mat: Material) -> void:
	for i in count:
		var z := lerpf(z0, z1, float(i) / float(maxi(count - 1, 1)))
		make_cyl(root, 0.018, 0.026, Vector3(x, y, z), mat, Vector3(0.0, 0.0, 90.0), 6)


func add_foundation(root: Node3D, span: Vector2i, solid := true) -> void:
	var sx := float(span.x)
	var sz := float(span.y)
	# Axis-aligned grout skirt, concrete plinth and a raised inset face. There
	# are deliberately no 45-degree corner boxes: every edge follows the tile grid.
	make_box(root, Vector3(sx - 0.035, 0.10, sz - 0.035), Vector3(0.0, -0.03, 0.0), mats["dark"])
	make_box(root, Vector3(sx - 0.15, 0.16, sz - 0.15), Vector3(0.0, 0.07, 0.0), mats["concrete"])
	make_box(root, Vector3(sx - 0.27, 0.07, sz - 0.27), Vector3(0.0, 0.18, 0.0), mats["concrete_light"])
	# Bevel rails catch the key light and separate the pad from the terrain.
	for side in PackedFloat32Array([-1.0, 1.0]):
		make_box(root, Vector3(sx - 0.28, 0.035, 0.045),
			Vector3(0.0, 0.22, side * (sz * 0.5 - 0.20)), mats["metal_light"])
		make_box(root, Vector3(0.045, 0.035, sz - 0.28),
			Vector3(side * (sx * 0.5 - 0.20), 0.22, 0.0), mats["metal_light"])
	# Armored corner pads, still square to the grid.
	for sx_sign in PackedFloat32Array([-1.0, 1.0]):
		for sz_sign in PackedFloat32Array([-1.0, 1.0]):
			var x := sx_sign * (sx * 0.5 - 0.24)
			var z := sz_sign * (sz * 0.5 - 0.24)
			make_box(root, Vector3(0.30, 0.12, 0.30), Vector3(x, 0.17, z), mats["metal"])
			make_cyl(root, 0.026, 0.035, Vector3(x, 0.25, z), mats["metal_light"], Vector3.ZERO, 6)
	if not solid:
		return
	# Small hazard plates make the foundation read as an industrial service pad.
	for side in PackedFloat32Array([-1.0, 1.0]):
		make_box(root, Vector3(0.28, 0.035, 0.15),
			Vector3(side * (sx * 0.5 - 0.52), 0.23, sz * 0.5 - 0.16), mats["hazard"])
	# Sparse hairline cracks and windblown drift break up the broad service pad.
	for i in 3:
		var cx := -sx * 0.28 + float(i) * sx * 0.25
		var cz := sz * 0.22 + sin(float(i) * 2.3) * 0.15
		make_box(root, Vector3(0.24, 0.012, 0.018), Vector3(cx, 0.225, cz),
			mats["crack"], Vector3(0.0, 18.0 + float(i) * 31.0, 0.0))
	make_cyl(root, 0.09, 0.014, Vector3(-sx * 0.28, 0.23, -sz * 0.26), mats["sand"], Vector3.ZERO, 10)


func add_roof_pipes(root: Node3D, phase: float) -> void:
	for i in 3:
		var x := -0.7 + float(i) * 0.7
		make_cyl(root, 0.055, 1.1, Vector3(x, 0.50, -0.45), mats["rust"], Vector3(0.0, 0.0, 90.0), 10)
		make_cyl(root, 0.13, 0.07, Vector3(x - 0.54, 0.50, -0.45), mats["metal_light"], Vector3(0.0, 0.0, 90.0), 12)
		make_cyl(root, 0.13, 0.07, Vector3(x + 0.54, 0.50, -0.45), mats["metal_light"], Vector3(0.0, 0.0, 90.0), 12)
	var blink := 0.64 + 0.36 * absf(sin(phase * TAU))
	var lamp := make_cyl(root, 0.09, 0.07, Vector3(0.55, 1.05, 0.55), mats["amber"], Vector3.ZERO, 10)
	lamp.scale = Vector3(blink, 1.0, blink)


func add_sandbags(root: Node3D, span: Vector2i) -> void:
	var sx := float(span.x)
	var sz := float(span.y)
	for side in PackedFloat32Array([-1.0, 1.0]):
		for i in 6:
			var x := -sx * 0.38 + float(i) * (sx * 0.152)
			make_cyl(root, 0.085, 0.15, Vector3(x, 0.15, side * sz * 0.38),
				mats["concrete_light"], Vector3(0.0, 0.0, 90.0), 8)
			make_box(root, Vector3(0.11, 0.075, 0.16),
				Vector3(x + 0.055, 0.13, side * sz * 0.38), mats["sand"])


func add_ladder(root: Node3D, x: float, z: float, y0: float, y1: float) -> void:
	var h := y1 - y0
	make_box(root, Vector3(0.025, h, 0.025), Vector3(x - 0.10, y0 + h * 0.5, z), mats["metal_light"])
	make_box(root, Vector3(0.025, h, 0.025), Vector3(x + 0.10, y0 + h * 0.5, z), mats["metal_light"])
	for i in 5:
		var y := lerpf(y0 + 0.08, y1 - 0.08, float(i) / 4.0)
		make_box(root, Vector3(0.19, 0.022, 0.022), Vector3(x, y, z), mats["rust"])


func add_pipe(root: Node3D, start: Vector3, length: float, axis: Vector3,
		radius: float, mat: Material) -> void:
	var rot := Vector3.ZERO
	if absf(axis.x) > 0.5:
		rot.z = 90.0
	elif absf(axis.z) > 0.5:
		rot.x = 90.0
	var mid := start + axis * length * 0.5
	make_cyl(root, radius, length, mid, mat, rot, 12)
	for end in [start, start + axis * length]:
		make_cyl(root, radius * 1.30, 0.035, end, mats["metal_light"], rot, 12)


func add_vent(root: Node3D, pos: Vector3, size: Vector3) -> void:
	make_box(root, size, pos, mats["dark"])
	for i in 4:
		var y := pos.y - size.y * 0.30 + float(i) * size.y * 0.20
		make_box(root, Vector3(size.x * 0.86, 0.022, 0.026),
			Vector3(pos.x, y, pos.z + size.z * 0.5 + 0.012), mats["grill"])
	for sx in PackedFloat32Array([-1.0, 1.0]):
		make_box(root, Vector3(0.025, size.y, size.z),
			Vector3(pos.x + sx * size.x * 0.48, pos.y, pos.z), mats["metal_light"])


func add_catwalk(root: Node3D, start: Vector3, length: float, axis: Vector3,
		y: float) -> void:
	var mid := Vector3(start.x, y, start.z) + axis * length * 0.5
	make_box(root, Vector3(length if axis.x != 0.0 else 0.22, 0.06,
		0.22 if axis.x != 0.0 else length), mid, mats["metal_light"])
	for i in 3:
		var t := float(i) / 2.0
		var p := Vector3(start.x, y, start.z) + axis * length * t
		make_box(root, Vector3(0.028, 0.30, 0.028), p + Vector3(0, 0.16, 0), mats["rust"])
	var rail_start := Vector3(start.x, y + 0.30, start.z)
	var rail_end := rail_start + axis * length
	make_box(root, Vector3(length if axis.x != 0.0 else 0.025, 0.025,
		0.025 if axis.x != 0.0 else length), (rail_start + rail_end) * 0.5, mats["metal"])


func add_banner(root: Node3D, pos: Vector3, width: float, height: float) -> void:
	make_cyl(root, 0.022, height + 0.22, pos + Vector3(0.0, height * 0.5 - 0.06, 0.0),
		mats["metal_light"], Vector3.ZERO, 6)
	make_box(root, Vector3(width, height, 0.025), pos + Vector3(0.0, height * 0.5, 0.02),
		mats["trim"])
	make_box(root, Vector3(width + 0.035, 0.035, 0.03),
		pos + Vector3(0.0, height * 0.98, 0.02), mats["metal_light"])
	make_box(root, Vector3(width * 0.78, 0.045, 0.03),
		pos + Vector3(0.0, height * 0.18, 0.02), mats["black"])


func add_antenna(root: Node3D, pos: Vector3, height: float) -> void:
	make_cyl(root, 0.025, height, pos + Vector3(0, height * 0.5, 0), mats["metal_light"], Vector3.ZERO, 6)
	for i in 2:
		make_box(root, Vector3(0.32 - float(i) * 0.10, 0.018, 0.018),
			pos + Vector3(0, height * (0.50 + float(i) * 0.18), 0), mats["rust"])
	if height > 0.65:
		make_cyl(root, 0.12, 0.035, pos + Vector3(0, height * 0.92, 0), mats["metal_light"],
			Vector3(90.0, 0.0, 0.0), 12)
	make_cyl(root, 0.035, 0.035, pos + Vector3(0, height + 0.02, 0), mats["amber"], Vector3.ZERO, 6)


func add_window_slit(root: Node3D, pos: Vector3, width: float, vertical := false) -> void:
	make_box(root, Vector3(width + 0.045, 0.10 if not vertical else 0.045, 0.055),
		pos, mats["black"])
	var inner := Vector3(width, 0.038, 0.025) if not vertical else Vector3(0.025, width, 0.055)
	make_box(root, inner, pos + Vector3(0, 0, 0.025), mats["cyan"])


func add_stack(root: Node3D, pos: Vector3, height: float, radius: float) -> void:
	make_cyl(root, radius, height, pos + Vector3(0, height * 0.5, 0), mats["rust"], Vector3.ZERO, 14)
	for i in 3:
		make_cyl(root, radius * 1.10, 0.035,
			pos + Vector3(0, height * (0.24 + 0.20 * float(i)), 0), mats["dark"], Vector3.ZERO, 14)
	make_cyl(root, radius * 1.18, 0.06, pos + Vector3(0, height + 0.03, 0), mats["metal_light"],
		Vector3.ZERO, 14)
	add_ladder(root, pos.x + radius * 1.15, pos.z, pos.y + 0.10, height * 0.86)
	make_cyl(root, 0.035, 0.035, pos + Vector3(radius * 0.85, height * 0.95, 0), mats["amber"],
		Vector3.ZERO, 6)


func add_buttress(root: Node3D, x: float, z: float, height: float, mat: Material) -> void:
	make_box(root, Vector3(0.16, height, 0.24), Vector3(x, height * 0.5 + 0.18, z), mat,
		Vector3(0.0, 0.0, -12.0 if x < 0.0 else 12.0))
	make_box(root, Vector3(0.28, 0.10, 0.28), Vector3(x, 0.26, z), mats["metal"])


# ------------------------------------------------------------------ buildings

func build_base(id: String, span: Vector2i, phase: float, damaged: bool) -> Node3D:
	var root := Node3D.new()
	root.name = "Base"
	if id != "slab":
		add_foundation(root, span)
	match id:
		"cy":
			build_cy(root, span, phase)
		"refinery":
			build_refinery(root, span, phase)
		"windtrap":
			build_windtrap(root, span, phase)
		"barracks":
			build_barracks(root, span, phase)
		"factory":
			build_factory(root, span, phase)
		"turret":
			build_turret_base(root, span, phase)
		"rocketturret":
			build_rocket_base(root, span, phase)
		"wall":
			build_wall(root, span, phase)
		"slab":
			build_slab(root, span, phase)
	if damaged:
		add_damage(root, span, phase)
	return root


func build_cy(root: Node3D, span: Vector2i, phase: float) -> void:
	# Pale armored command keep with chamfered corner pylons. The assembly pad
	# is a true recess in the front deck, and the crane is deliberately compact
	# so the silhouette reads as a command vehicle, not a scaffold.
	make_box(root, Vector3(2.42, 0.20, 2.34), Vector3(0.0, 0.24, 0.0), mats["concrete_light"])
	make_box(root, Vector3(2.18, 0.06, 2.10), Vector3(0.0, 0.35, 0.0), mats["pave"])
	# Recessed dark assembly square.
	make_box(root, Vector3(1.20, 0.055, 0.78), Vector3(0.0, 0.395, 0.62), mats["black"])
	make_box(root, Vector3(1.04, 0.035, 0.64), Vector3(0.0, 0.425, 0.62), mats["steel_dark"])
	for i in 4:
		make_box(root, Vector3(0.90, 0.014, 0.025), Vector3(0.0, 0.45, 0.39 + float(i) * 0.15), mats["metal_light"])
	for sx in [-1.0, 1.0]:
		make_box(root, Vector3(0.035, 0.018, 0.64), Vector3(sx * 0.44, 0.45, 0.62), mats["trim"])
	# Chamfered corner pylons: eight-sided pale stone drums with steel caps.
	for corner in [Vector2(-1.04, -0.92), Vector2(1.04, -0.92), Vector2(-1.04, 0.92), Vector2(1.04, 0.92)]:
		make_cyl(root, 0.27, 0.78, Vector3(corner.x, 0.73, corner.y), mats["concrete_light"], Vector3.ZERO, 8)
		make_cyl(root, 0.245, 0.055, Vector3(corner.x, 1.14, corner.y), mats["metal_light"], Vector3.ZERO, 8)
		make_cyl(root, 0.135, 0.04, Vector3(corner.x, 1.19, corner.y), mats["armor"], Vector3.ZERO, 8)
		make_box(root, Vector3(0.055, 0.15, 0.30), Vector3(corner.x, 0.75, corner.y - 0.24), mats["trim"])
		make_cyl(root, 0.021, 0.03, Vector3(corner.x, 1.12, corner.y + 0.25), mats["amber"], Vector3.ZERO, 6)
	# Central rounded armored keep and layered roof.
	make_box(root, Vector3(1.58, 0.54, 1.44), Vector3(0.0, 0.69, -0.18), mats["concrete_light"])
	make_cyl(root, 0.70, 0.98, Vector3(0.0, 1.27, -0.18), mats["armor"], Vector3.ZERO, 16)
	make_cyl(root, 0.76, 0.12, Vector3(0.0, 1.82, -0.18), mats["metal_light"], Vector3.ZERO, 20)
	make_cyl(root, 0.50, 0.09, Vector3(0.0, 1.92, -0.18), mats["metal"], Vector3.ZERO, 16)
	make_cyl(root, 0.24, 0.035, Vector3(0.0, 1.985, -0.18), mats["metal_light"], Vector3.ZERO, 16)
	make_cyl(root, 0.135, 0.035, Vector3(0.0, 2.005, -0.18), mats["grill"], Vector3.ZERO, 16)
	for i in 4:
		make_box(root, Vector3(0.30, 0.018, 0.035), Vector3(0.0, 1.99, -0.54 + float(i) * 0.36), mats["trim"])
	for i in 6:
		var a := TAU * float(i) / 6.0
		make_box(root, Vector3(0.18, 0.025, 0.30), Vector3(cos(a) * 0.49, 1.88, -0.18 + sin(a) * 0.49),
			mats["metal_light"], Vector3(0.0, -rad_to_deg(a) + 90.0, 0.0))
	# Pale side turbine/generator pods.
	for sx in [-1.0, 1.0]:
		make_cyl(root, 0.24, 0.52, Vector3(sx * 0.82, 0.72, 0.28), mats["metal"], Vector3(90.0, 0.0, 0.0), 14)
		make_cyl(root, 0.18, 0.06, Vector3(sx * 0.82, 0.72, 0.56), mats["grill"], Vector3(90.0, 0.0, 0.0), 14)
		make_box(root, Vector3(0.18, 0.018, 0.02), Vector3(sx * 0.82, 0.76, 0.59), mats["trim"])
		make_box(root, Vector3(0.18, 0.018, 0.02), Vector3(sx * 0.82, 0.68, 0.59), mats["trim"])
		for i in 3:
			make_cyl(root, 0.213, 0.028, Vector3(sx * 0.82, 0.72, 0.18 + float(i) * 0.14), mats["metal_light"], Vector3(90.0, 0.0, 0.0), 14)
		make_box(root, Vector3(0.20, 0.07, 0.58), Vector3(sx * 0.82, 0.99, 0.28), mats["trim"])
	# Sleek single-jib service crane with its hook over the assembly square.
	make_box(root, Vector3(0.12, 1.42, 0.12), Vector3(0.82, 2.18, -0.62), mats["metal_light"])
	make_box(root, Vector3(0.18, 0.10, 0.30), Vector3(0.82, 2.92, -0.52), mats["trim"])
	make_box(root, Vector3(1.48, 0.11, 0.13), Vector3(0.12, 2.88, 0.02), mats["metal_light"], Vector3(0.0, 0.0, -4.0))
	make_box(root, Vector3(1.22, 0.045, 0.15), Vector3(0.20, 2.80, 0.02), mats["trim"])
	make_box(root, Vector3(0.34, 0.07, 0.16), Vector3(0.38, 2.95, 0.02), mats["steel_dark"])
	add_pipe(root, Vector3(0.18, 1.28, 0.02), 0.76, Vector3(0.0, 1.0, 0.0), 0.012, mats["metal_light"])
	make_box(root, Vector3(0.20, 0.14, 0.18), Vector3(0.18, 1.19, 0.02), mats["trim"])
	make_box(root, Vector3(0.08, 0.12, 0.08), Vector3(0.18, 1.06, 0.02), mats["black"])
	# Windows, vents, radar and restrained blue trim.
	add_window_slit(root, Vector3(-0.30, 1.45, 0.47), 0.28)
	add_window_slit(root, Vector3(0.12, 1.45, 0.47), 0.22)
	add_vent(root, Vector3(-0.46, 1.89, -0.28), Vector3(0.30, 0.12, 0.26))
	add_antenna(root, Vector3(-0.50, 1.92, -0.62), 0.60)
	make_cyl(root, 0.20, 0.055, Vector3(-0.22, 1.98, -0.43), mats["metal_light"], Vector3(90.0, 0.0, 0.0), 16)
	make_box(root, Vector3(0.52, 0.055, 0.10), Vector3(0.0, 1.02, 0.97), mats["trim"])
	make_box(root, Vector3(0.24, 0.10, 0.08), Vector3(-0.74, 0.77, 0.96), mats["steel_dark"])
	bolts_x(root, -0.70, 0.70, 1.10, 0.54, 8, mats["metal_light"])
	bolts_z(root, -0.54, 0.54, 0.72, 1.10, 6, mats["metal_light"])


func build_refinery(root: Node3D, span: Vector2i, phase: float) -> void:
	# 3x2 spice refinery: two pale riveted silos at the rear, a low processing
	# house and a flush open concrete dock across the front.
	make_box(root, Vector3(2.56, 0.20, 1.78), Vector3(0.0, 0.23, 0.0), mats["concrete_light"])
	make_box(root, Vector3(2.34, 0.06, 1.60), Vector3(0.0, 0.34, -0.06), mats["pave"])
	# Open Harvester dock, deliberately flush with the foundation.
	make_box(root, Vector3(2.28, 0.025, 0.68), Vector3(0.0, 0.375, 0.50), mats["black"])
	make_box(root, Vector3(2.18, 0.018, 0.60), Vector3(0.0, 0.392, 0.50), mats["pave_light"])
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.045, 0.022, 0.66), Vector3(side * 1.08, 0.40, 0.50), mats["metal_light"])
		make_box(root, Vector3(0.055, 0.022, 0.52), Vector3(side * 1.08, 0.405, 0.50), mats["trim"])
	for x in [-0.96, 0.96]:
		for z in [0.20, 0.80]:
			make_cyl(root, 0.048, 0.06, Vector3(x, 0.43, z), mats["amber"], Vector3.ZERO, 8)
	# Subtle docking chevrons, not broad hazard striping.
	for i in 3:
		make_box(root, Vector3(0.18, 0.012, 0.035), Vector3(-0.42 + float(i) * 0.42, 0.408, 0.40), mats["hazard"], Vector3(0.0, 45.0, 0.0))
		make_box(root, Vector3(0.18, 0.012, 0.035), Vector3(-0.42 + float(i) * 0.42, 0.408, 0.60), mats["hazard"], Vector3(0.0, 45.0, 0.0))
	# Processing house and twin silos.
	make_box(root, Vector3(0.86, 0.76, 0.92), Vector3(0.58, 0.88, -0.38), mats["metal"])
	make_box(root, Vector3(0.92, 0.09, 0.98), Vector3(0.58, 1.28, -0.38), mats["metal_light"])
	add_window_slit(root, Vector3(0.58, 1.01, 0.10), 0.30)
	add_vent(root, Vector3(0.57, 1.33, -0.36), Vector3(0.32, 0.12, 0.30))
	for data in [[-0.78, 0.0, 1.54], [0.28, 0.16, 1.54]]:
		var x: float = data[0]
		var height: float = data[2]
		make_cyl(root, 0.38, height, Vector3(x, 0.38 + height * 0.5, -0.47), mats["armor"], Vector3.ZERO, 24)
		make_cyl(root, 0.40, 0.06, Vector3(x, 1.62, -0.47), mats["metal_light"], Vector3.ZERO, 24)
		make_sphere(root, 0.385, Vector3(x, 1.64, -0.47), mats["metal_light"], Vector3(1.0, 0.36, 1.0))
		for k in 3:
			make_cyl(root, 0.398, 0.035, Vector3(x, 0.55 + float(k) * 0.38, -0.47), mats["metal_light"] if k != 1 else mats["steel_dark"], Vector3.ZERO, 24)
		for k in 8:
			var a := TAU * float(k) / 8.0
			make_cyl(root, 0.018, 0.025, Vector3(x + cos(a) * 0.36, 1.20, -0.47 + sin(a) * 0.36), mats["metal_light"], Vector3(0.0, 0.0, 90.0), 6)
		# Narrow exhaust stack on the silo cap.
		make_cyl(root, 0.09, 0.60, Vector3(x, 1.94, -0.47), mats["steel_dark"], Vector3.ZERO, 12)
		make_cyl(root, 0.115, 0.045, Vector3(x, 2.25, -0.47), mats["metal_light"], Vector3.ZERO, 12)
		make_cyl(root, 0.045, 0.035, Vector3(x, 2.28, -0.47), mats["amber"], Vector3.ZERO, 6)
		make_box(root, Vector3(0.12, 0.045, 0.12), Vector3(x, 0.70, 0.44), mats["trim"])
		add_ladder(root, x + 0.42, -0.47, 0.18, 1.52)
	# Pipework, maintenance catwalk, antenna and restrained blue trim.
	add_pipe(root, Vector3(-0.40, 1.65, -0.47), 0.76, Vector3(1.0, 0.0, 0.0), 0.065, mats["metal_light"])
	add_pipe(root, Vector3(-0.40, 0.65, -0.20), 0.72, Vector3(1.0, 0.0, 0.0), 0.045, mats["rust"])
	add_catwalk(root, Vector3(-0.96, 0.42, -0.02), 0.92, Vector3(1.0, 0.0, 0.0), 1.30)
	make_box(root, Vector3(1.88, 0.05, 0.12), Vector3(0.0, 1.34, -0.03), mats["metal_light"])
	make_box(root, Vector3(0.52, 0.055, 0.08), Vector3(0.60, 1.31, 0.08), mats["trim"])
	add_antenna(root, Vector3(1.00, 0.36, -0.45), 0.86)
	make_box(root, Vector3(0.48, 0.06, 0.15), Vector3(-0.28, 0.42, 0.92), mats["trim"])
	bolts_x(root, -1.00, 1.00, 0.45, 0.23, 10, mats["metal_light"])
	bolts_z(root, -0.72, 0.72, 0.86, 0.31, 8, mats["metal_light"])


func build_windtrap(root: Node3D, span: Vector2i, phase: float) -> void:
	# Two aerodynamic turbine nacelles with circular front intakes. The visible
	# louvres are cyan and the rear condenser is deliberately exposed so the
	# Wind Trap reads even at 1x zoom.
	make_box(root, Vector3(1.78, 0.38, 1.80), Vector3(0.0, 0.31, 0.0), mats["concrete_light"])
	make_box(root, Vector3(1.62, 0.08, 1.66), Vector3(0.0, 0.51, 0.0), mats["metal_light"])
	for sx in [-0.43, 0.43]:
		# Curved silver-white turbine hood.
		make_cyl(root, 0.38, 1.35, Vector3(sx, 1.06, 0.02), mats["armor"], Vector3(90.0, 0.0, 0.0), 24)
		make_sphere(root, 0.375, Vector3(sx, 1.06, -0.66), mats["armor"], Vector3(1.0, 1.0, 0.70))
		make_cyl(root, 0.40, 0.08, Vector3(sx, 1.06, 0.71), mats["metal_light"], Vector3(90.0, 0.0, 0.0), 24)
		make_cyl(root, 0.325, 0.055, Vector3(sx, 1.06, 0.76), mats["black"], Vector3(90.0, 0.0, 0.0), 24)
		# Cyan louver bank set into the black intake. The bars sit proud of the
		# opening so the glow survives the 2x downsample.
		for k in 5:
			var width := 0.50 - absf(float(k) - 2.0) * 0.085
			make_box(root, Vector3(width, 0.036, 0.045), Vector3(sx, 0.85 + float(k) * 0.105, 0.79), mats["cyan"])
		make_cyl(root, 0.26, 0.035, Vector3(sx, 1.06, 0.795), mats["grill"], Vector3(90.0, 0.0, 0.0), 20)
		make_cyl(root, 0.05, 0.04, Vector3(sx, 1.06, 0.815), mats["cyan"], Vector3(90.0, 0.0, 0.0), 12)
		# Dorsal fin and pale structural shoes.
		make_box(root, Vector3(0.022, 0.13, 0.50), Vector3(sx, 1.40, -0.10), mats["metal_light"], Vector3(-9.0, 0.0, 0.0))
		make_box(root, Vector3(0.028, 0.055, 0.18), Vector3(sx, 1.47, -0.33), mats["trim"], Vector3(-9.0, 0.0, 0.0))
		make_box(root, Vector3(0.28, 0.09, 0.34), Vector3(sx, 0.78, 0.34), mats["steel_dark"])
		for z in [-0.22, 0.36]:
			make_box(root, Vector3(0.11, 0.27, 0.16), Vector3(sx + (0.34 if sx > 0.0 else -0.34), 0.66, z), mats["metal"])
		# Ribbed collar and service ring.
		make_cyl(root, 0.39, 0.055, Vector3(sx, 1.06, 0.25), mats["metal_light"], Vector3(90.0, 0.0, 0.0), 24)
		make_cyl(root, 0.39, 0.035, Vector3(sx, 1.06, -0.28), mats["steel_dark"], Vector3(90.0, 0.0, 0.0), 24)
		make_cyl(root, 0.028, 0.03, Vector3(sx + 0.20, 1.39, 0.43), mats["amber"], Vector3.ZERO, 8)
	# Spine and rear condenser assembly.
	make_box(root, Vector3(0.48, 0.18, 1.34), Vector3(0.0, 0.66, -0.12), mats["metal"])
	for i in 3:
		make_box(root, Vector3(0.38, 0.035, 0.04), Vector3(0.0, 0.57 + float(i) * 0.10, 0.48), mats["trim"])
	make_cyl(root, 0.17, 0.16, Vector3(0.0, 1.27, -0.80), mats["metal_light"], Vector3.ZERO, 16)
	add_pipe(root, Vector3(0.0, 0.55, -0.82), 0.62, Vector3(0.0, 1.0, 0.0), 0.075, mats["metal_light"])
	add_pipe(root, Vector3(0.0, 1.16, -0.82), 0.32, Vector3(0.0, 0.0, 1.0), 0.060, mats["rust"])
	make_cyl(root, 0.115, 0.04, Vector3(0.0, 1.46, -0.82), mats["cyan"], Vector3.ZERO, 12)
	make_box(root, Vector3(1.40, 0.05, 0.11), Vector3(0.0, 0.53, 0.88), mats["metal"])
	make_box(root, Vector3(0.38, 0.035, 0.08), Vector3(0.0, 0.58, 0.90), mats["trim"])
	make_box(root, Vector3(0.90, 0.04, 0.20), Vector3(0.0, 0.52, -0.92), mats["pave"])
	bolts_z(root, -0.78, 0.78, -0.72, 0.53, 10, mats["metal_light"])
	make_box(root, Vector3(0.20, 0.16, 0.12), Vector3(0.60, 0.65, -0.88), mats["steel_dark"])
	add_vent(root, Vector3(0.60, 0.62, -0.70), Vector3(0.22, 0.15, 0.12))


func build_barracks(root: Node3D, span: Vector2i, phase: float) -> void:
	# Winged, arched-roof barracks. The barrel vault is ribbed pale armor and
	# the entry is a deeply recessed bay under a royal-blue lintel.
	make_box(root, Vector3(1.74, 0.32, 1.66), Vector3(0.0, 0.30, 0.0), mats["concrete_light"])
	make_box(root, Vector3(1.54, 0.56, 1.34), Vector3(0.0, 0.64, -0.05), mats["armor"])
	make_box(root, Vector3(1.44, 0.07, 1.26), Vector3(0.0, 0.95, -0.05), mats["metal_light"])
	add_barrel_vault(root, Vector3(0.0, 1.22, -0.05), 0.78, 1.38, "x", mats["roof"], mats["metal"], 5)
	# Swept side wing plates, with blue leading edges.
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.30, 0.13, 1.08), Vector3(side * 0.82, 1.06, 0.02), mats["armor"], Vector3(0.0, 0.0, side * 13.0))
		make_box(root, Vector3(0.09, 0.07, 0.92), Vector3(side * 0.96, 1.00, 0.02), mats["trim"], Vector3(0.0, 0.0, side * 13.0))
		make_box(root, Vector3(0.06, 0.32, 0.28), Vector3(side * 0.92, 0.70, -0.56), mats["steel_dark"])
		add_window_slit(root, Vector3(side * 0.59, 0.70, 0.63), 0.20)
	# Recessed entry bay and blue lintel.
	make_box(root, Vector3(0.78, 0.66, 0.08), Vector3(0.0, 0.61, 0.645), mats["black"])
	make_box(root, Vector3(0.62, 0.50, 0.04), Vector3(0.0, 0.56, 0.69), mats["steel_dark"])
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.11, 0.74, 0.15), Vector3(side * 0.48, 0.68, 0.64), mats["metal_light"])
		make_box(root, Vector3(0.07, 0.46, 0.04), Vector3(side * 0.36, 0.58, 0.705), mats["trim"])
	make_box(root, Vector3(0.92, 0.09, 0.14), Vector3(0.0, 0.99, 0.64), mats["trim"])
	make_box(root, Vector3(0.48, 0.025, 0.24), Vector3(0.0, 0.37, 0.78), mats["pave_light"])
	# Roof crest stripe, hatches and light antenna.
	make_box(root, Vector3(1.12, 0.035, 0.08), Vector3(0.0, 2.00, -0.05), mats["trim"])
	make_cyl(root, 0.30, 0.08, Vector3(-0.22, 1.96, -0.02), mats["metal"], Vector3.ZERO, 12)
	make_cyl(root, 0.225, 0.06, Vector3(-0.22, 2.02, -0.02), mats["steel_dark"], Vector3.ZERO, 12)
	add_vent(root, Vector3(0.30, 1.96, -0.10), Vector3(0.23, 0.08, 0.24))
	add_antenna(root, Vector3(0.48, 1.93, -0.48), 0.58)
	make_cyl(root, 0.027, 0.03, Vector3(-0.48, 0.97, 0.74), mats["amber"], Vector3.ZERO, 8)
	bolts_x(root, -0.62, 0.62, 0.86, 0.42, 8, mats["metal_light"])
	bolts_z(root, -0.58, 0.58, 0.67, 0.48, 6, mats["metal_light"])


func build_factory(root: Node3D, span: Vector2i, phase: float) -> void:
	# Broad barrel-vaulted vehicle works. The entire south face opens as a
	# roll-out bay; ribbed armor seams carry across the curved silver-tan roof.
	make_box(root, Vector3(2.60, 0.28, 1.86), Vector3(0.0, 0.28, 0.0), mats["concrete_light"])
	make_box(root, Vector3(2.38, 0.58, 1.52), Vector3(0.0, 0.66, -0.10), mats["armor"])
	make_box(root, Vector3(2.26, 0.07, 1.46), Vector3(0.0, 0.99, -0.10), mats["metal_light"])
	add_barrel_vault(root, Vector3(0.0, 1.30, -0.10), 0.84, 2.12, "x", mats["roof"], mats["metal"], 7)
	# Reinforced side buttresses and dark steel service doors.
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.24, 1.02, 0.18), Vector3(side * 1.13, 0.86, 0.53), mats["concrete_light"])
		make_box(root, Vector3(0.18, 0.65, 1.15), Vector3(side * 1.14, 0.76, -0.28), mats["concrete"])
		make_box(root, Vector3(0.04, 0.10, 1.02), Vector3(side * 1.245, 1.00, -0.20), mats["trim"])
		make_cyl(root, 0.16, 0.50, Vector3(side * 1.02, 1.77, -0.36), mats["steel_dark"], Vector3(0.0, 0.0, 90.0), 12)
		add_window_slit(root, Vector3(side * 0.91, 0.72, 0.68), 0.20)
	# Wide open roll-out bay and raised segmented door.
	make_box(root, Vector3(1.62, 0.68, 0.08), Vector3(0.0, 0.59, 0.67), mats["black"])
	make_box(root, Vector3(1.40, 0.54, 0.03), Vector3(0.0, 0.53, 0.715), mats["steel_dark"])
	for i in 4:
		make_box(root, Vector3(1.34, 0.012, 0.02), Vector3(0.0, 0.37 + float(i) * 0.10, 0.733), mats["metal"])
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.16, 0.80, 0.18), Vector3(side * 0.88, 0.66, 0.64), mats["metal_light"])
		make_box(root, Vector3(0.075, 0.56, 0.03), Vector3(side * 0.82, 0.56, 0.72), mats["trim"])
	# Segmented shutter lip, lintel marking and a shallow concrete apron.
	make_box(root, Vector3(1.56, 0.075, 0.14), Vector3(0.0, 1.05, 0.63), mats["trim"])
	for i in 3:
		make_box(root, Vector3(0.34, 0.02, 0.04), Vector3(-0.40 + float(i) * 0.40, 1.10, 0.71), mats["metal_light"])
	make_box(root, Vector3(1.80, 0.025, 0.30), Vector3(0.0, 0.405, 0.84), mats["pave"])
	for side in [-1.0, 1.0]:
		make_cyl(root, 0.030, 0.04, Vector3(side * 0.78, 0.43, 0.94), mats["amber"], Vector3.ZERO, 8)
	# Roof vents, antenna, sensor pods and a restrained blue spine.
	make_box(root, Vector3(1.48, 0.035, 0.10), Vector3(0.0, 2.11, -0.10), mats["trim"])
	add_vent(root, Vector3(-0.54, 1.96, -0.34), Vector3(0.34, 0.12, 0.30))
	add_vent(root, Vector3(0.58, 1.94, -0.52), Vector3(0.26, 0.11, 0.24))
	add_antenna(root, Vector3(0.86, 1.94, -0.70), 0.70)
	for x in [-0.72, 0.72]:
		make_cyl(root, 0.20, 0.10, Vector3(x, 1.94, 0.14), mats["metal_light"], Vector3(90.0, 0.0, 0.0), 14)
		make_cyl(root, 0.13, 0.05, Vector3(x, 1.94, 0.20), mats["cyan"], Vector3(90.0, 0.0, 0.0), 14)
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.09, 0.52, 0.06), Vector3(side * 1.02, 0.62, -0.92), mats["rust"])
	bolts_x(root, -1.04, 1.04, 0.46, 0.29, 12, mats["metal_light"])
	bolts_z(root, -0.82, 0.82, 0.84, 0.36, 8, mats["metal_light"])


func build_turret_base(root: Node3D, span: Vector2i, phase: float) -> void:
	# Compact eight-sided Atreides pillbox: pale stone skirt, steel armor ring
	# and a narrow blue identifier band instead of hazard striping.
	make_box(root, Vector3(0.96, 0.13, 0.96), Vector3(0.0, 0.17, 0.0), mats["concrete_light"])
	make_cyl(root, 0.53, 0.20, Vector3(0.0, 0.25, 0.0), mats["concrete_light"], Vector3.ZERO, 8)
	make_cyl(root, 0.46, 0.16, Vector3(0.0, 0.41, 0.0), mats["armor"], Vector3.ZERO, 8)
	make_cyl(root, 0.395, 0.055, Vector3(0.0, 0.515, 0.0), mats["metal_light"], Vector3.ZERO, 8)
	make_cyl(root, 0.285, 0.045, Vector3(0.0, 0.55, 0.0), mats["steel_dark"], Vector3.ZERO, 8)
	for i in 8:
		var a := TAU * float(i) / 8.0
		var x := cos(a) * 0.43
		var z := sin(a) * 0.43
		make_box(root, Vector3(0.17, 0.19, 0.10), Vector3(x, 0.30, z), mats["metal"], Vector3(0.0, -rad_to_deg(a) + 90.0, 0.0))
		make_cyl(root, 0.017, 0.024, Vector3(x, 0.405, z), mats["metal_light"], Vector3.ZERO, 6)
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.045, 0.045, 0.35), Vector3(side * 0.44, 0.44, 0.0), mats["trim"])
		make_box(root, Vector3(0.34, 0.045, 0.045), Vector3(0.0, 0.44, side * 0.44), mats["trim"])
	make_cyl(root, 0.034, 0.035, Vector3(0.33, 0.53, 0.26), mats["amber"], Vector3.ZERO, 8)
	bolts_x(root, -0.28, 0.28, 0.56, 0.30, 6, mats["metal_light"])
	bolts_z(root, -0.28, 0.28, 0.56, 0.30, 6, mats["metal_light"])


func build_rocket_base(root: Node3D, span: Vector2i, phase: float) -> void:
	# Matching octagonal rocket emplacement, slightly broader to index as the
	# heavier of the two defensive structures at a glance.
	make_box(root, Vector3(0.97, 0.15, 0.97), Vector3(0.0, 0.17, 0.0), mats["concrete_light"])
	make_cyl(root, 0.55, 0.19, Vector3(0.0, 0.26, 0.0), mats["concrete_light"], Vector3.ZERO, 8)
	make_cyl(root, 0.47, 0.15, Vector3(0.0, 0.42, 0.0), mats["armor"], Vector3.ZERO, 8)
	make_cyl(root, 0.40, 0.055, Vector3(0.0, 0.525, 0.0), mats["metal_light"], Vector3.ZERO, 8)
	make_cyl(root, 0.30, 0.045, Vector3(0.0, 0.56, 0.0), mats["steel_dark"], Vector3.ZERO, 8)
	for i in 8:
		var a := TAU * float(i) / 8.0
		var x := cos(a) * 0.44
		var z := sin(a) * 0.44
		make_box(root, Vector3(0.185, 0.18, 0.10), Vector3(x, 0.30, z), mats["metal"], Vector3(0.0, -rad_to_deg(a) + 90.0, 0.0))
		make_cyl(root, 0.017, 0.024, Vector3(x, 0.40, z), mats["metal_light"], Vector3.ZERO, 6)
	for side in [-1.0, 1.0]:
		make_box(root, Vector3(0.05, 0.05, 0.32), Vector3(side * 0.44, 0.45, 0.0), mats["trim"])
		make_box(root, Vector3(0.28, 0.06, 0.05), Vector3(0.0, 0.45, side * 0.44), mats["trim"])
	make_cyl(root, 0.036, 0.035, Vector3(-0.34, 0.54, 0.25), mats["amber"], Vector3.ZERO, 8)
	bolts_x(root, -0.29, 0.29, 0.56, 0.31, 6, mats["metal_light"])
	bolts_z(root, -0.29, 0.29, 0.56, 0.31, 6, mats["metal_light"])


func build_wall(root: Node3D, span: Vector2i, phase: float) -> void:
	# A thick interlocking foot and cap: no rotated keys, only square-grid joints.
	make_box(root, Vector3(0.94, 0.16, 0.78), Vector3(0.0, 0.10, 0.0), mats["concrete"])
	make_box(root, Vector3(0.76, 0.56, 0.48), Vector3(0.0, 0.45, 0.0), mats["concrete_light"])
	make_box(root, Vector3(0.90, 0.12, 0.58), Vector3(0.0, 0.78, 0.0), mats["metal"])
	for sx in PackedFloat32Array([-1.0, 1.0]):
		make_box(root, Vector3(0.12, 0.24, 0.24), Vector3(sx * 0.39, 0.84, 0.0), mats["metal_light"])
		make_box(root, Vector3(0.20, 0.18, 0.60), Vector3(sx * 0.40, 0.30, 0.0), mats["metal"])
		make_cyl(root, 0.035, 0.50, Vector3(sx * 0.34, 0.46, 0.28), mats["rust"], Vector3.ZERO, 8)
	for i in 4:
		make_box(root, Vector3(0.18, 0.04, 0.035), Vector3(-0.26 + float(i) * 0.17, 0.51, 0.255),
			mats["dark"])
	make_box(root, Vector3(0.44, 0.12, 0.15), Vector3(0.0, 0.38, 0.30), mats["hazard"])
	make_box(root, Vector3(0.24, 0.06, 0.18), Vector3(-0.30, 0.88, -0.20), mats["yellow"])
	make_cyl(root, 0.045, 0.04, Vector3(0.23, 0.86, -0.18), mats["amber"], Vector3.ZERO, 8)


func build_slab(root: Node3D, span: Vector2i, phase: float) -> void:
	# Warm concrete service panel, beveled and grouted, without a separate plinth.
	make_box(root, Vector3(0.99, 0.10, 0.99), Vector3(0.0, 0.03, 0.0), mats["crack"])
	make_box(root, Vector3(0.92, 0.07, 0.92), Vector3(0.0, 0.11, 0.0), mats["pave"])
	make_box(root, Vector3(0.84, 0.035, 0.84), Vector3(0.0, 0.16, 0.0), mats["pave_light"])
	for side in PackedFloat32Array([-1.0, 1.0]):
		make_box(root, Vector3(0.84, 0.018, 0.025), Vector3(0.0, 0.185, side * 0.41), mats["concrete_light"])
		make_box(root, Vector3(0.025, 0.018, 0.84), Vector3(side * 0.41, 0.185, 0.0), mats["concrete_light"])
	make_box(root, Vector3(0.68, 0.012, 0.68), Vector3(0.0, 0.184, 0.0), mats["pave"])
	for sx in PackedFloat32Array([-1.0, 1.0]):
		for sz in PackedFloat32Array([-1.0, 1.0]):
			make_cyl(root, 0.026, 0.022, Vector3(sx * 0.34, 0.19, sz * 0.34), mats["metal_light"], Vector3.ZERO, 8)
	make_cyl(root, 0.052, 0.012, Vector3(-0.24, 0.19, -0.28), mats["sand"], Vector3.ZERO, 10)


func add_damage(root: Node3D, span: Vector2i, phase: float) -> void:
	var sx := float(span.x)
	var sz := float(span.y)
	for i in 4:
		var x := -sx * 0.30 + float(i) * sx * 0.20
		var z := -sz * 0.10 + sin(phase * TAU + float(i)) * 0.20
		make_box(root, Vector3(0.22, 0.035, 0.16), Vector3(x, 0.16, z), mats["black"],
			Vector3(0.0, float(i) * 31.0, 0.0))
		make_box(root, Vector3(0.11, 0.035, 0.12), Vector3(x + 0.12, 0.20, z + 0.09),
			mats["rust"], Vector3(0.0, float(i) * 19.0, 0.0))
	make_cyl(root, 0.08, 0.45, Vector3(sx * 0.25, 0.20, -sz * 0.25), mats["rust"],
		Vector3(0.0, 0.0, 64.0), 8)
	var scorch := make_box(root, Vector3(sx * 0.36, 0.018, sz * 0.28),
		Vector3(-sx * 0.10, 0.23, sz * 0.16), mats["black"], Vector3(0.0, 12.0, 0.0))
	scorch.scale = Vector3(1.0, 1.0, 0.86)


## A terrain-sized slab plate, rendered from straight above so adjacent 40 px
## pavement cells meet cleanly. It deliberately stays outside the 0-yaw
## building projection because it is a top-down floor texture, not a structure.
func build_slab_pavement(phase: float) -> Node3D:
	var root := Node3D.new()
	root.name = "SlabPavement"
	# Warm sandstone concrete: four clean beveled edges and a recessed inner
	# panel. Adjacent cells make the regular expansion-joint grid with no cracks.
	make_box(root, Vector3(1.02, 0.075, 1.02), Vector3(0.0, -0.038, 0.0), mats["crack"])
	make_box(root, Vector3(0.955, 0.065, 0.955), Vector3(0.0, 0.018, 0.0), mats["pave"])
	make_box(root, Vector3(0.875, 0.030, 0.875), Vector3(0.0, 0.058, 0.0), mats["pave_light"])
	# Crisp bevel rails: lit on the north/west, shadowed on the south/east.
	make_box(root, Vector3(0.84, 0.016, 0.022), Vector3(0.0, 0.080, -0.414), mats["concrete_light"])
	make_box(root, Vector3(0.022, 0.016, 0.84), Vector3(-0.414, 0.080, 0.0), mats["concrete_light"])
	make_box(root, Vector3(0.84, 0.014, 0.018), Vector3(0.0, 0.077, 0.414), mats["pave"])
	make_box(root, Vector3(0.018, 0.014, 0.84), Vector3(0.414, 0.077, 0.0), mats["pave"])
	# Recessed center square and four square corner pads complete the panel seam.
	make_box(root, Vector3(0.64, 0.009, 0.64), Vector3(0.0, 0.074, 0.0), mats["pave"])
	for side in PackedFloat32Array([-1.0, 1.0]):
		make_box(root, Vector3(0.66, 0.009, 0.014), Vector3(0.0, 0.080, side * 0.322), mats["pave_light"])
		make_box(root, Vector3(0.014, 0.009, 0.66), Vector3(side * 0.322, 0.080, 0.0), mats["pave_light"])
	for sx in PackedFloat32Array([-1.0, 1.0]):
		for sz in PackedFloat32Array([-1.0, 1.0]):
			make_cyl(root, 0.026, 0.022, Vector3(sx * 0.352, 0.082, sz * 0.352), mats["metal_light"], Vector3.ZERO, 8)
	# Windblown sand gathers on the protected north edge only.
	var turn := phase * TAU
	make_cyl(root, 0.060 + 0.005 * sin(turn), 0.010, Vector3(-0.27 + 0.02 * sin(turn), 0.085, -0.33), mats["sand"], Vector3.ZERO, 10)
	make_cyl(root, 0.034, 0.009, Vector3(-0.22, 0.084, -0.30), mats["sand"], Vector3.ZERO, 8)
	return root


# -------------------------------------------------------------------- heads

func build_head(id: String, angle: float, phase: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Head"
	if id == "turret":
		# Sleek dark-steel cannon pod in a pale armored race ring.
		make_cyl(root, 0.31, 0.16, Vector3(0.0, 0.43, 0.0), mats["metal_light"], Vector3.ZERO, 12)
		make_cyl(root, 0.255, 0.06, Vector3(0.0, 0.52, 0.0), mats["steel_dark"], Vector3.ZERO, 12)
		make_box(root, Vector3(0.40, 0.19, 0.38), Vector3(0.02, 0.60, 0.0), mats["metal"])
		make_box(root, Vector3(0.32, 0.12, 0.44), Vector3(0.14, 0.715, 0.0), mats["metal_light"])
		make_box(root, Vector3(0.25, 0.045, 0.34), Vector3(0.12, 0.775, 0.0), mats["trim"])
		make_box(root, Vector3(0.14, 0.055, 0.09), Vector3(-0.10, 0.77, 0.13), mats["trim"])
		# Long cannon with a recoil sleeve and crisp muzzle brake.
		make_cyl(root, 0.072, 0.70, Vector3(0.50, 0.60, 0.0), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
		make_cyl(root, 0.098, 0.24, Vector3(0.22, 0.60, 0.0), mats["steel_dark"], Vector3(0.0, 0.0, 90.0), 12)
		make_cyl(root, 0.087, 0.16, Vector3(0.48, 0.60, 0.0), mats["metal_light"], Vector3(0.0, 0.0, 90.0), 12)
		make_box(root, Vector3(0.14, 0.13, 0.20), Vector3(0.91, 0.60, 0.0), mats["steel_dark"])
		make_box(root, Vector3(0.055, 0.065, 0.28), Vector3(0.99, 0.60, 0.0), mats["black"])
		for side in [-1.0, 1.0]:
			make_box(root, Vector3(0.24, 0.07, 0.055), Vector3(0.18, 0.50, side * 0.21), mats["metal_light"])
		add_window_slit(root, Vector3(0.12, 0.665, 0.235), 0.16)
		add_antenna(root, Vector3(-0.17, 0.70, -0.17), 0.28)
		make_cyl(root, 0.028, 0.025, Vector3(-0.15, 0.60, 0.23), mats["amber"], Vector3.ZERO, 6)
	else:
		# Squared launcher pod, four deep tubes and blue armored roof.
		make_cyl(root, 0.29, 0.15, Vector3(0.0, 0.43, 0.0), mats["metal_light"], Vector3.ZERO, 12)
		make_box(root, Vector3(0.58, 0.27, 0.58), Vector3(0.0, 0.58, 0.0), mats["steel_dark"])
		make_box(root, Vector3(0.48, 0.10, 0.66), Vector3(0.03, 0.735, 0.0), mats["metal"])
		make_box(root, Vector3(0.36, 0.045, 0.54), Vector3(0.03, 0.79, 0.0), mats["trim"])
		for z in PackedFloat32Array([-0.19, 0.19]):
			for y in PackedFloat32Array([0.52, 0.68]):
				make_cyl(root, 0.072, 0.46, Vector3(0.34, y, z), mats["black"], Vector3(0.0, 0.0, 90.0), 12)
				make_cyl(root, 0.088, 0.055, Vector3(0.57, y, z), mats["metal_light"], Vector3(0.0, 0.0, 90.0), 12)
				make_cyl(root, 0.043, 0.075, Vector3(0.12, y, z), mats["dark"], Vector3(0.0, 0.0, 90.0), 12)
		for z in PackedFloat32Array([-0.27, 0.27]):
			make_box(root, Vector3(0.30, 0.045, 0.035), Vector3(0.04, 0.62, z), mats["trim"])
			make_cyl(root, 0.033, 0.03, Vector3(-0.16, 0.75, z), mats["amber"], Vector3.ZERO, 8)
		make_box(root, Vector3(0.20, 0.055, 0.16), Vector3(-0.16, 0.79, 0.16), mats["metal_light"])
		make_cyl(root, 0.070, 0.032, Vector3(-0.17, 0.84, -0.15), mats["metal_light"], Vector3(90.0, 0.0, 0.0), 10)
		add_window_slit(root, Vector3(0.16, 0.56, 0.30), 0.18)
		add_antenna(root, Vector3(-0.20, 0.73, -0.24), 0.24)
	root.rotation.y = angle
	return root


# -------------------------------------------------------------------- frames

func _set_camera(span: Vector2i, is_head := false) -> void:
	var span_max := float(maxi(span.x, span.y))
	camera.size = maxf((2.2 if is_head else span_max * 1.38 + 1.30), 2.55)
	# Fixed +Z (south) camera, zero Y rotation. Looking north with a 50-degree
	# downward pitch gives a square-grid 3/4 oblique read: X is screen-horizontal,
	# Z is depth, and no footprint is rotated into a 45-degree diamond.
	var target := Vector3(0.0, 0.56 if is_head else 0.70, 0.0)
	var dist := 7.5
	var height := dist * tan(deg_to_rad(50.0))
	camera.position = target + Vector3(0.0, height, dist)
	camera.look_at(target, Vector3.UP)
	camera.h_offset = 0.0


func _render(span: Vector2i, is_head := false, seed_value := 0, shadow := true) -> Image:
	var base_cell := cell_for_spec("", span)
	viewport.size = Vector2i(base_cell.x * RENDER_SCALE, base_cell.y * RENDER_SCALE)
	_set_camera(span, is_head)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	img.resize(base_cell.x, base_cell.y, Image.INTERPOLATE_LANCZOS)
	return _post_process(img, shadow, seed_value)


func _replace_assembly(root: Node3D) -> void:
	if assembly != null:
		assembly.queue_free()
		await get_tree().process_frame
	assembly = root
	stage.add_child(assembly)


func _bake_sheet(id: String, span: Vector2i) -> void:
	var cell := cell_for_spec(id, span)
	var sheet := Image.create(cell.x * FRAMES, cell.y * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for row in 2:
		for frame in FRAMES:
			var phase := float(frame) / float(FRAMES)
			await _replace_assembly(build_base(id, span, phase, row == 1))
			var img := await _render(span, false, 900 + id.hash() + frame * 7, true)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, cell), Vector2i(frame * cell.x, row * cell.y))
	var path := "%s/%s.png" % [OUT_DIR, id]
	sheet.save_png(ProjectSettings.globalize_path(path))
	var first := sheet.get_region(Rect2i(0, 0, cell.x, cell.y))
	var used := first.get_used_rect()
	var icon := _make_icon(sheet, cell)
	if id == "turret" or id == "rocketturret":
		# The base sheet deliberately omits the rotating head. Compose the
		# icon from the bunker and the head so the sidebar portrait shows the
		# complete weapon, not a dark pillbox.
		icon = await _make_turret_icon(id, span, cell)
	icon.save_png(ProjectSettings.globalize_path("%s/%s_icon.png" % [OUT_DIR, id]))
	preview_tiles.append(icon)
	print("BAKED %-14s sheet=%dx%d cell=%dx%d icon=64 art_top=%.1f" %
		[id, sheet.get_width(), sheet.get_height(), cell.x, cell.y,
		float(used.position.y) - float(cell.y) * 0.5])


func _bake_slab_pavement() -> void:
	# Concrete is a top-down floor material, not a miniature 3D building. Drawing
	# it directly keeps the 40 px cells clean: one pale warm panel, a crisp grout
	# seam and a low-contrast inner bevel, with no brick pattern or filter blur.
	var sheet := Image.create(TILE * SLAB_PAVEMENT_FRAMES, TILE, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for f in SLAB_PAVEMENT_FRAMES:
		var tile := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
		for y in TILE:
			for x in TILE:
				var n := float((x * 37 + y * 61 + f * 101) % 17) / 16.0
				var grain := int(round((n - 0.5) * 5.0))
				var c := Color8(201 + grain, 154 + grain, 116 + grain)
				var edge := mini(mini(x, TILE - 1 - x), mini(y, TILE - 1 - y))
				if edge == 0:
					c = Color8(122, 86, 62)
				elif x == 1 or y == 1:
					c = Color8(232, 196, 159)
				elif x == TILE - 2 or y == TILE - 2:
					c = Color8(161, 117, 84)
				# Faint inner panel seam: a square bevel, not a noisy brick.
				if (x == 7 or y == 7) and x >= 7 and x <= TILE - 8 and y >= 7 and y <= TILE - 8:
					c = c.lightened(0.055)
				elif (x == TILE - 8 or y == TILE - 8) and x >= 7 and x <= TILE - 8 and y >= 7 and y <= TILE - 8:
					c = c.darkened(0.045)
				tile.set_pixel(x, y, c)
		# Windblown pale sand on the sheltered north edge, varied per cell.
		for k in 4 + f:
			var sx := (k * 11 + f * 7) % (TILE - 4) + 2
			var sy := 2 + ((k + f) % 2)
			tile.set_pixel(sx, sy, Color8(226, 204, 170))
			tile.set_pixel(sx + 1, sy, Color8(214, 186, 148))
		if f % 2 == 0:
			tile.set_pixel(5 + f, 4, Color8(180, 139, 103))
		sheet.blit_rect(tile, Rect2i(0, 0, TILE, TILE), Vector2i(f * TILE, 0))
	sheet.save_png(ProjectSettings.globalize_path(SLAB_PAVEMENT_PATH))
	print("BAKED slab_pavement  sheet=%dx%d cell=%dx%d frames=%d" %
		[sheet.get_width(), sheet.get_height(), TILE, TILE, SLAB_PAVEMENT_FRAMES])


func _bake_head(id: String, span: Vector2i) -> void:
	var cell := cell_for_spec(id, span)
	var sheet := Image.create(cell.x * HEAD_FRAMES, cell.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for i in HEAD_FRAMES:
		var angle := float(i) / float(HEAD_FRAMES) * TAU
		await _replace_assembly(build_head(id, angle, float(i % FRAMES) / float(FRAMES)))
		var img := await _render(span, true, 2300 + id.hash() + i * 3, false)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, cell), Vector2i(i * cell.x, 0))
	var path := "%s/%s_head.png" % [OUT_DIR, id]
	sheet.save_png(ProjectSettings.globalize_path(path))
	print("BAKED %-14s head sheet=%dx%d frames=%d" %
		[id, sheet.get_width(), sheet.get_height(), HEAD_FRAMES])


func _make_icon(sheet: Image, cell: Vector2i) -> Image:
	var frame := sheet.get_region(Rect2i(0, 0, cell.x, cell.y))
	var used := frame.get_used_rect()
	if used.size.x <= 1 or used.size.y <= 1:
		used = Rect2i(0, 0, cell.x, cell.y)
	var crop := frame.get_region(used)
	var max_side := 60.0
	var scale := minf(max_side / float(crop.get_width()), max_side / float(crop.get_height()))
	var w := maxi(int(round(float(crop.get_width()) * scale)), 1)
	var h := maxi(int(round(float(crop.get_height()) * scale)), 1)
	crop.resize(w, h, Image.INTERPOLATE_LANCZOS)
	# Transparent hero cut-out: the HUD draws the recessed steel well and brass
	# corner brackets, so baking a second frame inside the portrait only shrank
	# the model. The render already carries its own contact shadow.
	var icon := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	icon.fill(Color(0, 0, 0, 0))
	# A faint cool halo lifts dark barrels and tracks off the charcoal slot.
	for y in 64:
		for x in 64:
			var dx := (float(x) - 31.5) / 31.0
			var dy := (float(y) - 32.0) / 31.0
			var glow := clampf(1.0 - sqrt(dx * dx + dy * dy * 1.25), 0.0, 1.0)
			if glow > 0.0:
				icon.set_pixel(x, y, Color(0.10, 0.18, 0.23, glow * 0.20))
	var ox := (64 - w) / 2
	var oy := maxi(2, (64 - h) / 2)
	icon.blend_rect(crop, Rect2i(0, 0, w, h), Vector2i(ox, oy))
	return _factionize_icon(icon)


func _factionize_icon(icon: Image) -> Image:
	for y in icon.get_height():
		for x in icon.get_width():
			var c := icon.get_pixel(x, y)
			if c.a <= 0.04:
				continue
			if c.r > c.g * 1.22 and c.b > c.g * 1.08 and c.r > 0.07:
				var k := clampf(0.42 + c.get_luminance() * 1.65, 0.34, 1.18)
				icon.set_pixel(x, y, Color(0.24 * k, 0.46 * k, 0.93 * k, c.a))
	return icon


func _make_turret_icon(id: String, span: Vector2i, cell: Vector2i) -> Image:
	var combined := Node3D.new()
	combined.add_child(build_base(id, span, 0.0, false))
	combined.add_child(build_head(id, 0.0, 0.0))
	await _replace_assembly(combined)
	var frame := await _render(span, false, 3400 + id.hash(), true)
	var one := Image.create(cell.x, cell.y, false, Image.FORMAT_RGBA8)
	one.fill(Color(0, 0, 0, 0))
	one.blit_rect(frame, Rect2i(Vector2i.ZERO, cell), Vector2i.ZERO)
	return _make_icon(one, cell)


func _make_preview() -> void:
	var cols := 3
	var icon_size := 64
	var rows := int(ceil(float(preview_tiles.size()) / float(cols)))
	var preview := Image.create(cols * icon_size, rows * icon_size, false, Image.FORMAT_RGBA8)
	preview.fill(Color(0.08, 0.06, 0.04, 1.0))
	for i in preview_tiles.size():
		preview.blit_rect(preview_tiles[i], Rect2i(0, 0, icon_size, icon_size),
			Vector2i((i % cols) * icon_size, (i / cols) * icon_size))
	preview.save_png(ProjectSettings.globalize_path(PREVIEW_PATH))


func cell_for_spec(id: String, span: Vector2i) -> Vector2i:
	return Vector2i(span.x * TILE + MARGIN * 2, span.y * TILE + MARGIN * 2)


# ---------------------------------------------------------------- post-pass

## Pixel finish applied after the SubViewport downsample: a soft bottom-right
## drop shadow, a hard 1 px silhouette edge, restrained unsharp masking and a
## deterministic micro-grit dither. This is what keeps the panel seams and
## rivets readable once the whole base is shown at gameplay zoom.
func _post_process(src: Image, shadow := true, seed_value := 0) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	if shadow:
		var lw := maxi(w / 4, 1)
		var lh := maxi(h / 4, 1)
		var low := Image.create(lw, lh, false, Image.FORMAT_RGBA8)
		low.fill(Color(0, 0, 0, 0))
		for y in lh:
			for x in lw:
				var sx := clampi(x * 4 - 5, 0, w - 1)
				var sy := clampi(y * 4 - 4, 0, h - 1)
				var a := src.get_pixel(sx, sy).a
				if a > 0.02:
					low.set_pixel(x, y, Color(0.015, 0.012, 0.009, clampf(a * 0.52, 0.0, 0.52)))
		low.resize(w, h, Image.INTERPOLATE_BILINEAR)
		out.blend_rect(low, Rect2i(0, 0, w, h), Vector2i.ZERO)
	# Dark edge silhouette, rendered outside the opaque art.
	var outline := Image.create(w, h, false, Image.FORMAT_RGBA8)
	outline.fill(Color(0, 0, 0, 0))
	for y in h:
		for x in w:
			if src.get_pixel(x, y).a < 0.12:
				continue
			var edge := false
			if x <= 0 or y <= 0 or x >= w - 1 or y >= h - 1:
				edge = true
			else:
				edge = src.get_pixel(x - 1, y).a < 0.10 or src.get_pixel(x + 1, y).a < 0.10 \
					or src.get_pixel(x, y - 1).a < 0.10 or src.get_pixel(x, y + 1).a < 0.10
			if edge:
				outline.set_pixel(x, y, Color(0.012, 0.010, 0.008, 0.68))
	out.blend_rect(outline, Rect2i(0, 0, w, h), Vector2i.ZERO)
	# Unsharp + grit pass on opaque texels.
	var sharp := Image.create(w, h, false, Image.FORMAT_RGBA8)
	sharp.fill(Color(0, 0, 0, 0))
	for y in h:
		for x in w:
			var c := src.get_pixel(x, y)
			if c.a <= 0.01:
				continue
			var avg := Color(0.0, 0.0, 0.0, 0.0)
			var samples := 0
			for oy in range(-1, 2):
				for ox in range(-1, 2):
					if ox == 0 and oy == 0:
						continue
					var nx := clampi(x + ox, 0, w - 1)
					var ny := clampi(y + oy, 0, h - 1)
					var nc := src.get_pixel(nx, ny)
					if nc.a > 0.05:
						avg += nc
						samples += 1
			if samples > 0:
				avg /= float(samples)
			var amount := 0.30
			var r := clampf(c.r + (c.r - avg.r) * amount + (_hash2(x, y, seed_value) - 0.5) * 0.022, 0.0, 1.0)
			var g := clampf(c.g + (c.g - avg.g) * amount + (_hash2(x + 17, y, seed_value) - 0.5) * 0.022, 0.0, 1.0)
			var b := clampf(c.b + (c.b - avg.b) * amount + (_hash2(x, y + 31, seed_value) - 0.5) * 0.022, 0.0, 1.0)
			sharp.set_pixel(x, y, Color(r, g, b, c.a))
	# Keep a hard edge only where the source silhouette is opaque; shadows stay
	# underneath instead of haloing.
	for y in h:
		for x in w:
			var c := sharp.get_pixel(x, y)
			if c.a > 0.04:
				out.set_pixel(x, y, c)
	return out


func _bake_all() -> void:
	for id in ["cy", "refinery", "windtrap", "barracks", "factory", "turret", "rocketturret", "wall", "slab"]:
		var span: Vector2i = SPECS[id]["span"]
		await _bake_sheet(id, span)
		if id == "turret" or id == "rocketturret":
			await _bake_head(id, span)
	await _bake_slab_pavement()
	_make_preview()
	print("BAKE COMPLETE: %s" % ProjectSettings.globalize_path(OUT_DIR))
