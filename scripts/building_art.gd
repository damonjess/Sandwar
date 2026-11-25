class_name BuildingArt
extends RefCounted

## Sprites baked by tools/blender_bake_buildings.py (Cycles).
##
## Each sheet is a 4 frame idle strip on row 0 and 4 damaged frames on row 1,
## painted neutral with magenta house trim. Views run the strip through
## shaders/faction_remap.gdshader so every house shares the same art.

const FRAMES := 4
const FPS := 2.2
## Sheets now bake at 2x pixel density. All StructureView nodes are scaled by
## WORLD_SPRITE_SCALE so their world footprint is unchanged; turret sheets have
## generous transparent margins, so their view is scaled down further to read
## as a true 1x1 bunker. Collision rects remain 1x1.
##
## Head-sheet convention: the building baker looks from +Y, which mirrors screen
## X. Cell 0 points west on screen; increasing cells run clockwise (4 = north,
## 8 = east, 12 = south). Building maps its aim into that strip.
const WORLD_SPRITE_SCALE := 0.5
const TURRET_VISUAL_SCALE := 0.23
## The compact gun head ends at roughly 0.72 model units; the old long barrel
## reached ~1.0. Keep the projectile origin at the new muzzle.
const TURRET_MUZZLE_DISTANCE := {"turret": 28.0, "rocketturret": 24.0}
## The head render is centered on the pivot; keep its world-space vertical
## alignment fixed even though the sheet resolution doubled.
const TURRET_HEAD_OFFSET_Y := -0.92
const SHADER_PATH := "res://shaders/faction_remap.gdshader"
const BASE_DIR := "res://assets/sprites/buildings"
const HEAD_DIR := "res://assets/sprites/buildings"

## Top of the rendered artwork relative to the pad centre. These are used by
## the health bar and power badge, so keep them in sync with the baker's
## camera framing.
const ART_TOPS := {
	"cy": -103.0,
	"refinery": -75.0,
	"windtrap": -66.5,
	"barracks": -63.5,
	"factory": -144.0,
	"heavy_factory": -202.0,
	"silo": -82.0,
	"outpost": -111.0,
	"repair_pad": -151.0,
	"starport": -236.0,
	"hightech": -159.0,
	"ix": -153.0,
	"palace": -180.0,
	"turret": -17.0,
	"rocketturret": -17.5,
	"wall": -23.0,
	"slab": -1.0,
}

static var _heads: Dictionary = {}
static var _sheets: Dictionary = {}
static var _icons: Dictionary = {}
static var _shader: Shader
static var _hud_mats: Dictionary = {}
## Measured roof height per structure, in world pixels relative to the pad
## centre. The old ART_TOPS constants were tuned by hand and drifted badly from
## the 2x high-DPI sheets, leaving health bars floating above tall buildings.
static var _visual_tops: Dictionary = {}

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

## Top of the visible roof in world pixels, measured from the baked sheet's
## real alpha bounds and scaled exactly like the StructureView that draws it.
## Falls back to the hand-tuned constant only when the image cannot be read.
static func visual_top(id: String, visual_scale := WORLD_SPRITE_SCALE) -> float:
	var key := "%s:%.4f" % [id, visual_scale]
	if _visual_tops.has(key):
		return float(_visual_tops[key])
	var top := art_top(id)
	var tex := sheet(id)
	if tex != null:
		var img := tex.get_image()
		if img != null:
			var used := img.get_used_rect()
			if used.size.y > 0 and tex.get_height() > 0:
				# used.position.y is the highest opaque pixel row of the whole
				# sheet, so the bar clears every idle and damaged frame.
				top = (float(used.position.y) - float(tex.get_height()) * 0.25) * visual_scale
	_visual_tops[key] = top
	return top

static func turret_visual_scale(id: String) -> float:
	return TURRET_VISUAL_SCALE if id == "turret" or id == "rocketturret" else WORLD_SPRITE_SCALE

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
