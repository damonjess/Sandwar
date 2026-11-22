@tool
class_name WallView
extends Node2D

## Draws the dedicated 16-mask wall sheet. The Building still owns placement,
## collision, health and selection; this node only selects the connection frame
## and the damage row.

@export var art_top := -20.0

var _housing: Sprite2D
var _team := 0
var _mask := 0
var _damage := 0.0
var _mat: ShaderMaterial

func _ready() -> void:
	_refresh()

func setup(team: int) -> void:
	_team = team
	if _mat == null:
		_mat = BuildingArt.material(_team)
	_refresh()

func set_wall_mask(mask: int) -> void:
	mask = clampi(mask, 0, WallArt.FRAME_COUNT - 1)
	if mask == _mask:
		return
	_mask = mask
	_apply_frame()

func set_damage(dmg: float) -> void:
	var d := clampf(dmg, 0.0, 1.0)
	if absf(d - _damage) < 0.02:
		return
	_damage = d
	_apply_frame()

func _refresh() -> void:
	if _housing == null:
		_housing = Sprite2D.new()
		_housing.name = "Housing"
		_housing.centered = true
		_housing.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_housing)
	_housing.texture = WallArt.sheet()
	_housing.hframes = WallArt.FRAME_COUNT
	_housing.vframes = WallArt.ROW_COUNT
	_housing.position = Vector2.ZERO
	if _mat == null:
		_mat = BuildingArt.material(_team)
	_housing.material = _mat
	_mat.set_shader_parameter("faction_color", BuildingArt.faction_color(_team))
	_apply_frame()

func _apply_frame() -> void:
	if _housing == null:
		return
	var row := WallArt.DAMAGE_ROW if _damage >= 0.5 else 0
	_housing.frame_coords = Vector2i(_mask, row)
