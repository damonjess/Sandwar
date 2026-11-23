class_name BuildingArt
extends RefCounted

## Sprites baked by tools/blender_bake_buildings.py (Cycles).
##
## Each sheet is a 4 frame idle strip on row 0 and 4 damaged frames on row 1,
## painted neutral with magenta house trim. Views run the strip through
## shaders/faction_remap.gdshader so every house shares the same art.

const FRAMES := 4
const FPS := 2.2
## The baked turret sheets include generous transparent margins. Scale the
## runtime view down so both bunkers read as true 1x1 structures instead of
## spilling over most of a 2x2 footprint. The collision rect remains 1x1.
##
## Head-sheet convention: cell 0 = east, and increasing cells run
## counter-clockwise (4 = north, 8 = west, 12 = south) because the building
## baker uses rotation.y = +angle. Building negates aim when choosing a cell.
const TURRET_VISUAL_SCALE := 0.46
const TURRET_MUZZLE_DISTANCE := {"turret": 32.0, "rocketturret": 24.0}
const SHADER_PATH := "res://shaders/faction_remap.gdshader"
const BASE_DIR := "res://assets/sprites/buildings"
const HEAD_DIR := "res://assets/sprites/buildings"

## Top of the rendered artwork relative to the pad centre. These are used by
## the health bar and power badge, so keep them in sync with the baker's
## camera framing.
const ART_TOPS := {
	"cy": -103.0,
	"refinery": -75.0,
	"windtrap": -67.0,
	"barracks": -83.0,
	"factory": -85.0,
	"turret": -17.0,
	"rocketturret": -18.0,
	"wall": -23.0,
	"slab": -1.0,
}

static var _heads: Dictionary = {}
static var _sheets: Dictionary = {}
static var _icons: Dictionary = {}
static var _shader: Shader
static var _hud_mats: Dictionary = {}

static func has_art(id: String) -> bool:
	return ResourceLoader.exists(_sheet_path(id))

static func _sheet_path(id: String) -> String:
	return "%s/%s.png" % [BASE_DIR, id]

static func sheet(id: String) -> Texture2D:
	if not _sheets.has(id):
		_sheets[id] = load(_sheet_path(id)) if has_art(id) else null
	return _sheets[id]

static func icon(id: String) -> Texture2D:
	if id == "wall":
		return WallArt.icon()
	if not _icons.has(id):
		var path := "%s/%s_icon.png" % [BASE_DIR, id]
		_icons[id] = load(path) if ResourceLoader.exists(path) else null
	return _icons[id]

static func head(id: String) -> Texture2D:
	if not _heads.has(id):
		var path := "%s/%s_head.png" % [HEAD_DIR, id]
		_heads[id] = load(path) if ResourceLoader.exists(path) else null
	return _heads[id]

static func art_top(id: String) -> float:
	return float(ART_TOPS.get(id, -96.0))

static func turret_visual_scale(id: String) -> float:
	return TURRET_VISUAL_SCALE if id == "turret" or id == "rocketturret" else 1.0

static func turret_muzzle_distance(id: String) -> float:
	return float(TURRET_MUZZLE_DISTANCE.get(id, 0.0))

static func faction_color(team: int) -> Color:
	return GameDefs.team_color(team)

## One material per view (damage tint is per building). The HUD shares one.
static func material(team: int) -> ShaderMaterial:
	if _shader == null:
		_shader = load(SHADER_PATH) as Shader
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("faction_color", faction_color(team))
	return mat

static func hud_material(team: int) -> ShaderMaterial:
	# A campaign can switch Houses without restarting the process, so key by
	# the live House rather than only the team slot.
	var key := "%d:%s" % [team, GameDefs.house_for_team(team)]
	if not _hud_mats.has(key):
		var mat := material(team)
		mat.set_shader_parameter("icon_blue_trim", 1.0)
		_hud_mats[key] = mat
	return _hud_mats[key]
