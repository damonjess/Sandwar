class_name Shroud
extends Node2D

## Fog of war: soft feathered black over ground never seen, a dim veil over
## remembered ground. The fog is built as one low-resolution mask texture and
## stretched over the map with linear filtering, so frontiers break up into a
## soft wind-blown edge instead of a staircase of hard 40 px blocks.

var terrain: Terrain

var _fog_image: Image
var _fog_texture: ImageTexture

const VEIL := Color(0.0, 0.0, 0.02, 0.46)

func setup(t: Terrain) -> void:
	terrain = t
	z_index = -5
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_fog_image = Image.create(GameDefs.MAP, GameDefs.MAP, false, Image.FORMAT_RGBA8)
	_fog_image.fill(Color(0, 0, 0, 0))
	_fog_texture = ImageTexture.create_from_image(_fog_image)
	refresh()

func refresh() -> void:
	if terrain == null:
		return
	if _fog_image == null:
		_fog_image = Image.create(GameDefs.MAP, GameDefs.MAP, false, Image.FORMAT_RGBA8)
		_fog_texture = ImageTexture.create_from_image(_fog_image)
	var m := GameDefs.MAP
	for y in m:
		for x in m:
			var i := y * m + x
			if terrain.lit[i] == 1:
				_fog_image.set_pixel(x, y, Color(0, 0, 0, 0))
			elif terrain.seen[i] == 0:
				_fog_image.set_pixel(x, y, Color(0, 0, 0, 1))
			else:
				_fog_image.set_pixel(x, y, VEIL)
	_fog_texture.update(_fog_image)
	queue_redraw()

func _draw() -> void:
	if terrain == null or _fog_texture == null:
		return
	# One sample per tile, linearly interpolated at map scale: the explored
	# frontier gets a feathered one-tile falloff without 3,136 overlapping
	# translucent quads or visible tile steps.
	draw_texture_rect(_fog_texture, Rect2(Vector2.ZERO, Vector2(GameDefs.WORLD, GameDefs.WORLD)), false)
