class_name UnitArt
extends RefCounted

## Blender Cycles unit art produced by tools/blender_bake_units.py.
##
## Vehicles use 16 horizontal facing cells. Infantry use an 8-row compass
## grid with four poses per row: idle, walk-left, walk-right and fire. The
## Siege Tank has a separate turret strip so its hull can face travel while the
## gun tracks a target. Magenta house trim is recoloured by the same faction
## shader used by the buildings.

const BASE_DIR := "res://assets/sprites/units"
const ICON_DIR := "res://assets/icons/units"
const SHADER_PATH := "res://shaders/faction_remap.gdshader"

## Baked texture pixels per logical footprint pixel. The baker now renders
## cells at 4x; draw_rect() still returns the unchanged logical CELLS size, so
## the 2x texture-density increase is cancelled at draw time and collision
## spacing is untouched.
const SCALE := 4
const VEHICLE_FRAMES := 16
const INFANTRY_DIRS := 8
const INFANTRY_FRAMES := 4

## Footprint of one baked cell in logical pixels. Every id the baker writes must
## be listed here, otherwise draw_rect() falls back to 44 px and clips it.
const CELLS := {
	"infantry": 36,
	"rocket": 38,
	"fremen": 38,
	"sardaukar": 40,
	"saboteur": 36,
	"trike": 48,
	"raider_trike": 48,
	"quad": 50,
	"tank": 64,
	"atreides_tank": 60,
	"harkonnen_tank": 62,
	"ordos_tank": 58,
	"sonic_tank": 62,
	# The Devastator renders 1.3x a combat tank's hull width/length; its radius
	# stays 22, so only the visual footprint grows.
	"devastator": 84,
	"deviator": 60,
	# Longer industrial rig with a wide dozer blade; 1.31x the tank cell so
	# the baked silhouette reads at the required 1.25-1.35x scale.
	"harvester": 84,
	# Mobile base rig: bulkier than a Devastator and deliberately slow-looking.
	"mcv": 88,
	"carryall": 96,
	# CHOAM frigate and the Atreides ornithopter are baked at a larger visual
	# footprint than their gameplay radius; both are airborne set pieces.
	"frigate": 150,
	"ornithopter": 82,
}

const INFANTRY_IDS := ["infantry", "rocket", "fremen", "sardaukar", "saboteur"]

static var _sheets: Dictionary = {}
static var _icons: Dictionary = {}
static var _shader: Shader
static var _hud_mats: Dictionary = {}

static func cell(id: String) -> float:
	return float(CELLS.get(id, 44))

static func has_art(id: String) -> bool:
	return ResourceLoader.exists(_sheet_path(id))

static func _sheet_path(id: String) -> String:
	if id == "tank":
		return "%s/tank_hull.png" % BASE_DIR
	if id == "harvester":
		return "%s/harvester_empty.png" % BASE_DIR
	return "%s/%s.png" % [BASE_DIR, id]

static func sheet(id: String) -> Texture2D:
	if not _sheets.has(id):
		_sheets[id] = load(_sheet_path(id)) if ResourceLoader.exists(_sheet_path(id)) else null
	return _sheets[id]

static func tank_turret() -> Texture2D:
	if not _sheets.has("tank_turret"):
		var path := "%s/tank_turret.png" % BASE_DIR
		_sheets["tank_turret"] = load(path) if ResourceLoader.exists(path) else null
	return _sheets["tank_turret"]

static func harvester_sheet(fill: float) -> Texture2D:
	var level := "full" if fill >= 0.62 else ("half" if fill >= 0.18 else "empty")
	var key := "harvester_" + level
	if not _sheets.has(key):
		var path := "%s/%s.png" % [BASE_DIR, key]
		_sheets[key] = load(path) if ResourceLoader.exists(path) else null
	return _sheets[key]

static func icon(id: String) -> Texture2D:
	if not _icons.has(id):
		var path := "%s/%s_icon.png" % [ICON_DIR, id]
		_icons[id] = load(path) if ResourceLoader.exists(path) else null
	return _icons[id]

static func has_icon(id: String) -> bool:
	return ResourceLoader.exists("%s/%s_icon.png" % [ICON_DIR, id])

## The house colour for a team, driven by CampaignState through GameDefs.
static func faction_color(team: int) -> Color:
	return GameDefs.team_color(team)

static func material(team: int) -> ShaderMaterial:
	if _shader == null:
		_shader = load(SHADER_PATH) as Shader
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("faction_color", faction_color(team))
	return mat

static func hud_material(team: int) -> ShaderMaterial:
	# Key by live House as well as team: House Select can begin a new campaign
	# in the same process, and the sidebar must adopt the new banner colour.
	var key := "%d:%s" % [team, GameDefs.house_for_team(team)]
	if not _hud_mats.has(key):
		var mat := material(team)
		mat.set_shader_parameter("icon_blue_trim", 1.0)
		_hud_mats[key] = mat
	return _hud_mats[key]

## Direction index in the same convention as Unit.facing: 0 = east, positive
## angles turn south in Godot's screen coordinates.
##
## The baker looks at the model from the south (Blender -Y) and rotates it
## counter-clockwise around +Z. Blender's +Y is north, which is Godot's -Y, so
## a model rotation of +a shows a Godot facing of -a. Cell 0 is therefore the
## true east frame; turret-head sheets are handled separately in Building.
static func direction_index(angle: float, count: int) -> int:
	if count <= 1:
		return 0
	var step := TAU / float(count)
	return posmod(int(round(-angle / step)), count)

static func frame_region(id: String, facing: float, anim := 0) -> Rect2:
	var px := cell(id) * float(SCALE)
	if is_infantry(id):
		var dir := direction_index(facing, INFANTRY_DIRS)
		var col := clampi(anim, 0, INFANTRY_FRAMES - 1)
		return Rect2(float(col) * px, float(dir) * px, px, px)
	return Rect2(float(direction_index(facing, VEHICLE_FRAMES)) * px, 0.0, px, px)

static func tank_turret_region(facing: float) -> Rect2:
	var px := cell("tank") * float(SCALE)
	return Rect2(float(direction_index(facing, VEHICLE_FRAMES)) * px, 0.0, px, px)

## Harvester sheets hold two pose rows: row 0 driving, row 1 harvesting with
## the dozer blade dropped into the ore. Live dust, exhaust and spice spray in
## Harvester._process supply the continuous motion between poses.
static func harvester_region(facing: float, harvesting := false) -> Rect2:
	var px := cell("harvester") * float(SCALE)
	var row := 1.0 if harvesting else 0.0
	return Rect2(float(direction_index(facing, VEHICLE_FRAMES)) * px, row * px, px, px)

static func draw_rect(id: String) -> Rect2:
	var c := cell(id)
	return Rect2(Vector2(-c, -c) * 0.5, Vector2(c, c))

static func muzzle_distance(id: String, radius: float) -> float:
	match id:
		"devastator":
			return radius * 2.05
		"tank":
			# Siege artillery: extra-long barrel muzzle.
			return radius * 2.0
		"atreides_tank", "harkonnen_tank", "ordos_tank":
			return radius * 1.86
		"sonic_tank":
			return radius * 1.70
		"deviator":
			return radius * 1.55
		"rocket", "fremen", "sardaukar":
			return radius * 1.58
		"infantry", "saboteur":
			return radius * 1.46
		"trike", "raider_trike", "quad":
			return radius * 1.42
		"ornithopter":
			return radius * 1.55
		"frigate":
			return radius * 1.2
	return radius * 1.2

static func is_infantry(id: String) -> bool:
	return INFANTRY_IDS.has(id)
