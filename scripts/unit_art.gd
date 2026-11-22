class_name UnitArt
extends RefCounted

## 3D-baked unit art produced by tools/bake_units_3d.gd.
##
## Vehicles use 16 horizontal facing cells. Infantry use an 8-row compass
## grid with four poses per row: idle, walk-left, walk-right and fire. The
## Siege Tank has a separate turret strip so its hull can face travel while the
## gun tracks a target. Magenta house trim is recoloured by the same faction
## shader used by the buildings.

const BASE_DIR := "res://assets/sprites/units"
const ICON_DIR := "res://assets/icons/units"
const SHADER_PATH := "res://shaders/faction_remap.gdshader"

const SCALE := 2
const VEHICLE_FRAMES := 16
const INFANTRY_DIRS := 8
const INFANTRY_FRAMES := 4

const CELLS := {
	"infantry": 36,
	"rocket": 38,
	"trike": 48,
	"quad": 50,
	"tank": 60,
	"harvester": 62,
}

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

static func faction_color(team: int) -> Color:
	if team == 2:
		return Color(0.16, 0.80, 0.46)
	return GameDefs.TEAM_COLORS[clampi(team, 0, GameDefs.TEAM_COLORS.size() - 1)]

static func material(team: int) -> ShaderMaterial:
	if _shader == null:
		_shader = load(SHADER_PATH) as Shader
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("faction_color", faction_color(team))
	return mat

static func hud_material(team: int) -> ShaderMaterial:
	if not _hud_mats.has(team):
		_hud_mats[team] = material(team)
	return _hud_mats[team]

## Direction index in the same convention as Unit.facing: 0 = east, positive
## angles turn south in Godot's screen coordinates.
##
## The unit baker rotates the model with `rotation.y = -facing` while the
## camera is fixed on the south-east 3/4 axis. That makes the first baked cell
## one step clockwise from east, and the final cell the true east frame. The
## runtime used to round directly, so every unit was one cell (22.5 degrees)
## clockwise of its movement/target vector. Turret-head sheets are baked with
## the opposite rotation and are handled separately in Building.
static func direction_index(angle: float, count: int) -> int:
	if count <= 1:
		return 0
	var step := TAU / float(count)
	return posmod(int(round(angle / step)) - 1, count)

static func frame_region(id: String, facing: float, anim := 0) -> Rect2:
	var px := cell(id) * float(SCALE)
	if id == "infantry" or id == "rocket":
		var dir := direction_index(facing, INFANTRY_DIRS)
		var col := clampi(anim, 0, INFANTRY_FRAMES - 1)
		return Rect2(float(col) * px, float(dir) * px, px, px)
	return Rect2(float(direction_index(facing, VEHICLE_FRAMES)) * px, 0.0, px, px)

static func tank_turret_region(facing: float) -> Rect2:
	var px := cell("tank") * float(SCALE)
	return Rect2(float(direction_index(facing, VEHICLE_FRAMES)) * px, 0.0, px, px)

static func harvester_region(facing: float) -> Rect2:
	var px := cell("harvester") * float(SCALE)
	return Rect2(float(direction_index(facing, VEHICLE_FRAMES)) * px, 0.0, px, px)

static func draw_rect(id: String) -> Rect2:
	var c := cell(id)
	return Rect2(Vector2(-c, -c) * 0.5, Vector2(c, c))

static func muzzle_distance(id: String, radius: float) -> float:
	match id:
		"tank":
			return radius * 1.86
		"rocket":
			return radius * 1.58
		"infantry":
			return radius * 1.46
		"trike", "quad":
			return radius * 1.42
	return radius * 1.2

static func is_infantry(id: String) -> bool:
	return id == "infantry" or id == "rocket"
