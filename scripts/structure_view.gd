@tool
class_name StructureView
extends Node2D

## Drives the baked 3D building sprite for every structure.
##
## Scene-backed structures use this node inside construction_yard.tscn,
## refinery.tscn and wind_trap.tscn; building.gd creates it dynamically for the
## rest. The Building still owns placement, health, selection and damage smoke.
## This view swaps to the damaged row below half health and cycles four frames.

@export var structure_id: String = "cy"
@export var frame_count: int = BuildingArt.FRAMES
@export var fps: float = BuildingArt.FPS
## Top of the artwork relative to the pad centre, so the health bar clears it.
@export var art_top: float = -96.0
## The sheets bake at 2x pixel density; 0.5 keeps every world footprint
## identical. The 1x1 turrets override this with their tighter scale.
@export var visual_scale := 0.5

var _housing: Sprite2D
var _guide: CanvasItem
var _team := 0
var _damage := 0.0
var _frame := 0
var _clock := 0.0
var _mat: ShaderMaterial

func _ready() -> void:
	_refresh()

func setup(team: int) -> void:
	_team = team
	if _mat == null:
		_mat = BuildingArt.material(_team)
	_refresh()

## The actual scaled roof top for this structure, measured from the baked
## sheet's alpha bounds. Building uses this for the health bar and badges, so
## 1x1 bunkers and 3x3 yards both get the same snug 10 px clearance.
func visible_top() -> float:
	return BuildingArt.visual_top(structure_id, visual_scale)

func set_damage(dmg: float) -> void:
	var d := clampf(dmg, 0.0, 1.0)
	if absf(d - _damage) < 0.02:
		return
	_damage = d
	_apply_row()
	_apply_tint()

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _housing == null or frame_count <= 1:
		return
	_clock += delta
	var f := int(_clock * fps) % frame_count
	if f != _frame:
		_frame = f
		_housing.frame_coords = Vector2i(f, _housing.frame_coords.y)

func _refresh() -> void:
	scale = Vector2(visual_scale, visual_scale)
	_housing = get_node_or_null("Housing")
	if _guide == null:
		_guide = get_node_or_null("Footprint")
	if _guide == null:
		_guide = get_node_or_null("Footprint2x3")
	if _guide != null:
		# Editor-only footprint guide; the Building draws the real footprint.
		_guide.visible = Engine.is_editor_hint()
	if _housing == null:
		# Barracks, the factory and the turrets are created dynamically from this
		# script. Give them the same Sprite2D the scene-backed structures declare
		# in their .tscn files, otherwise their baked sheet has no node to draw
		# into and only the concrete pad remains. Walls use WallView instead.
		_housing = Sprite2D.new()
		_housing.name = "Housing"
		_housing.centered = true
		_housing.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_housing)
	var tex := BuildingArt.sheet(structure_id)
	if tex != null:
		_housing.texture = tex
	_housing.hframes = maxi(frame_count, 1)
	_housing.vframes = 2
	_housing.frame_coords = Vector2i(_frame, _housing.frame_coords.y)
	_housing.centered = true
	_housing.position = Vector2.ZERO
	_housing.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if _mat == null:
		_mat = BuildingArt.material(_team)
	_housing.material = _mat
	_mat.set_shader_parameter("faction_color", BuildingArt.faction_color(_team))
	_apply_row()
	_apply_tint()

func _apply_row() -> void:
	if _housing == null:
		return
	var row := 1 if _damage >= 0.5 else 0
	_housing.frame_coords = Vector2i(_housing.frame_coords.x, row)

func _apply_tint() -> void:
	if _mat == null:
		return
	# A light soot grade on top of the damaged row; the art does the rest.
	var k := 1.0 - 0.45 * clampf((_damage - 0.5) / 0.5, 0.0, 1.0)
	_mat.set_shader_parameter("damage_tint", Color(k, k * 0.96, k * 0.92, 1.0))
