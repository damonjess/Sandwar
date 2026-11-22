class_name Terrain
extends Node2D

## Tile grid: cream desert, terracotta rock mesas and rust spice fields.
##
## The palette follows the Dune 2000 Atreides read: high-key sand, warm
## buildable stone, dark crag transitions and concrete that belongs to the
## same desert instead of reading as a separate grey tileset.

const SAND_LIGHT := Color("e6cca3")
const SAND_DARK := Color("d8b888")
const ROCK_LIGHT := Color("c87e4e")
const ROCK_DARK := Color("ba6d3e")
const CLIFF := Color(0.40, 0.22, 0.12)
const CLIFF_DARK := Color(0.16, 0.08, 0.04)
const SLAB := Color("c99a74")
const SLAB_INNER := Color("d7b18d")

var types := PackedByteArray()
var seen := PackedByteArray()
var lit := PackedByteArray()
var spice := PackedFloat32Array()
var spice_max := PackedFloat32Array()
var concrete := PackedByteArray()
var regrow := 0.0

var sand_tint: FastNoiseLite
var rock_tint: FastNoiseLite

## Baked tile strips (40 px cells). The cliff atlas is a 16-frame autotile: one
## frame for every combination of orthogonal rock neighbours (N=1 E=2 S=4 W=8).
## Concrete is re-baked by tools/bake_buildings_3d.gd at the same time as the
## buildings, so the slab seams and the structure foundations share a palette.
const TEX_SAND := "res://assets/sprites/d2/terrain_sand.png"
const TEX_ROCK := "res://assets/sprites/d2/terrain_rock.png"
const TEX_CONCRETE := "res://assets/sprites/buildings/slab_pavement.png"
const TEX_SPICE := "res://assets/sprites/d2/terrain_spice.png"
const TEX_CLIFF := "res://assets/sprites/d2/terrain_cliff.png"
const CLIFF_N := 1
const CLIFF_E := 2
const CLIFF_S := 4
const CLIFF_W := 8

var sand_tex: Texture2D
var rock_tex: Texture2D
var concrete_tex: Texture2D
var spice_tex: Texture2D
var cliff_tex: Texture2D

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	sand_tex = _load_tex(TEX_SAND)
	rock_tex = _load_tex(TEX_ROCK)
	concrete_tex = _load_tex(TEX_CONCRETE)
	spice_tex = _load_tex(TEX_SPICE)
	cliff_tex = _load_tex(TEX_CLIFF)

static func _load_tex(path: String) -> Texture2D:
	return load(path) if ResourceLoader.exists(path) else null

func generate(seed_value: int) -> void:
	var total := GameDefs.MAP * GameDefs.MAP
	types.resize(total)
	types.fill(GameDefs.SAND)
	spice.resize(total)
	spice.fill(0.0)
	spice_max.resize(total)
	spice_max.fill(0.0)
	concrete.resize(total)
	concrete.fill(0)
	seen.resize(total)
	seen.fill(0)
	lit.resize(total)
	lit.fill(0)

	var rock_noise := FastNoiseLite.new()
	rock_noise.seed = seed_value
	rock_noise.frequency = 0.045
	rock_noise.fractal_octaves = 3

	var spice_noise := FastNoiseLite.new()
	spice_noise.seed = seed_value + 977
	spice_noise.frequency = 0.08

	# Soft wide noise so the desert shades in dunes instead of one flat colour.
	sand_tint = FastNoiseLite.new()
	sand_tint.seed = seed_value + 31
	sand_tint.frequency = 0.09
	sand_tint.fractal_octaves = 2
	rock_tint = FastNoiseLite.new()
	rock_tint.seed = seed_value + 57
	rock_tint.frequency = 0.16
	rock_tint.fractal_octaves = 2

	for y in GameDefs.MAP:
		for x in GameDefs.MAP:
			var i := y * GameDefs.MAP + x
			if rock_noise.get_noise_2d(float(x), float(y)) > 0.24:
				types[i] = GameDefs.ROCK
			var s := spice_noise.get_noise_2d(float(x) + 300.0, float(y) + 300.0)
			if s > 0.30 and types[i] == GameDefs.SAND:
				var amount := clampf((s - 0.30) * 620.0, 60.0, 260.0)
				spice[i] = amount
				spice_max[i] = amount

	# Guaranteed rock plateaus under both starting bases.
	_force_rock(Vector2i(17, 41), 10)
	_force_rock(Vector2i(42, 14), 11)
	# Spice fields close enough to reach in the opening minute.
	_add_spice(Vector2i(32, 47), 5)
	_add_spice(Vector2i(26, 30), 6)
	_add_spice(Vector2i(32, 22), 6)
	queue_redraw()

func _force_rock(center: Vector2i, radius: int) -> void:
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			if not in_bounds(x, y):
				continue
			if Vector2i(x, y).distance_to(center) <= float(radius):
				var i := y * GameDefs.MAP + x
				types[i] = GameDefs.ROCK
				spice[i] = 0.0
				spice_max[i] = 0.0

func _add_spice(center: Vector2i, radius: int) -> void:
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			if not in_bounds(x, y):
				continue
			var d := Vector2i(x, y).distance_to(center)
			if d > float(radius):
				continue
			var i := y * GameDefs.MAP + x
			types[i] = GameDefs.SAND
			var amount := 110.0 + 16.0 * (float(radius) - d)
			spice[i] = maxf(spice[i], amount)
			spice_max[i] = maxf(spice_max[i], amount)

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < GameDefs.MAP and y < GameDefs.MAP

# ------------------------------------------------------------------- vision

func clear_visible() -> void:
	lit.fill(0)

## Light every tile within radius of pos; also sets the remembered "seen" flag.
func reveal(pos: Vector2, radius: float) -> void:
	var t := float(GameDefs.TILE)
	var cx := int(pos.x / t)
	var cy := int(pos.y / t)
	var reach := int(ceil(radius / t))
	var r2 := radius * radius
	for y in range(cy - reach, cy + reach + 1):
		for x in range(cx - reach, cx + reach + 1):
			if not in_bounds(x, y):
				continue
			var dx := (float(x) + 0.5) * t - pos.x
			var dy := (float(y) + 0.5) * t - pos.y
			if dx * dx + dy * dy > r2:
				continue
			var i := y * GameDefs.MAP + x
			lit[i] = 1
			seen[i] = 1

func is_visible_tile(x: int, y: int) -> bool:
	if not in_bounds(x, y):
		return false
	return lit[y * GameDefs.MAP + x] == 1

func is_visible_at(pos: Vector2) -> bool:
	var tile := tile_of(pos)
	return is_visible_tile(tile.x, tile.y)

func is_seen_tile(x: int, y: int) -> bool:
	if not in_bounds(x, y):
		return false
	return seen[y * GameDefs.MAP + x] == 1

func tile_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(pos.x / float(GameDefs.TILE))), int(floor(pos.y / float(GameDefs.TILE))))

func tile_center(tile: Vector2i) -> Vector2:
	return Vector2(tile) * float(GameDefs.TILE) + Vector2(GameDefs.TILE, GameDefs.TILE) * 0.5

func is_tile_buildable(tx: int, ty: int) -> bool:
	if not in_bounds(tx, ty):
		return false
	var i := ty * GameDefs.MAP + tx
	if spice[i] >= 5.0:
		return false
	return types[i] == GameDefs.ROCK or concrete[i] == 1

func can_pave(tile: Vector2i) -> bool:
	if not in_bounds(tile.x, tile.y):
		return false
	var i := tile.y * GameDefs.MAP + tile.x
	return concrete[i] == 0 and spice[i] < 5.0

func pave(tile: Vector2i) -> void:
	if not in_bounds(tile.x, tile.y):
		return
	concrete[tile.y * GameDefs.MAP + tile.x] = 1
	queue_redraw()

func pave_rect(tile: Vector2i, size: int) -> void:
	pave_span(tile, Vector2i(size, size))

func pave_span(tile: Vector2i, span: Vector2i) -> void:
	for ty in range(tile.y, tile.y + span.y):
		for tx in range(tile.x, tile.x + span.x):
			if in_bounds(tx, ty):
				concrete[ty * GameDefs.MAP + tx] = 1
	queue_redraw()

func spice_at(tile: Vector2i) -> float:
	if not in_bounds(tile.x, tile.y):
		return 0.0
	return spice[tile.y * GameDefs.MAP + tile.x]

func take_spice(tile: Vector2i, amount: float) -> float:
	if not in_bounds(tile.x, tile.y):
		return 0.0
	var i := tile.y * GameDefs.MAP + tile.x
	var taken := minf(spice[i], amount)
	spice[i] -= taken
	return taken

func find_spice_tile(from: Vector2i, max_radius: int = 40) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := 1.0e9
	var limit := float(max_radius * max_radius)
	for y in GameDefs.MAP:
		for x in GameDefs.MAP:
			var i := y * GameDefs.MAP + x
			if spice[i] < 10.0:
				continue
			var d := Vector2(float(x - from.x), float(y - from.y)).length_squared()
			if d < best_d and d <= limit:
				best_d = d
				best = Vector2i(x, y)
	return best

func _process(delta: float) -> void:
	regrow += delta
	if regrow < 2.0:
		return
	regrow = 0.0
	var changed := false
	for i in spice.size():
		if spice_max[i] > 0.0 and spice[i] < spice_max[i]:
			spice[i] = minf(spice_max[i], spice[i] + 1.5)
			changed = true
	if changed:
		queue_redraw()

func _hash(x: int, y: int) -> int:
	return abs((x * 73856093) ^ (y * 19349663))

func _is_sand(x: int, y: int) -> bool:
	if not in_bounds(x, y):
		return false
	return types[y * GameDefs.MAP + x] == GameDefs.SAND

func _is_rock(x: int, y: int) -> bool:
	if not in_bounds(x, y):
		return false
	return types[y * GameDefs.MAP + x] == GameDefs.ROCK

## Neighbour mask used by the 16-frame cliff atlas. Missing bits are exposed
## mesa edges; corners therefore receive both the south face and the side rim
## in one blend instead of leaving square gaps.
func cliff_mask(x: int, y: int) -> int:
	var mask := 0
	if _is_rock(x, y - 1):
		mask |= CLIFF_N
	if _is_rock(x + 1, y):
		mask |= CLIFF_E
	if _is_rock(x, y + 1):
		mask |= CLIFF_S
	if _is_rock(x - 1, y):
		mask |= CLIFF_W
	return mask

func _draw() -> void:
	if sand_tint == null:
		return
	var m := GameDefs.MAP
	var t := float(GameDefs.TILE)
	var tile_size := Vector2(t, t)

	# One continuous seamless desert sheet behind the whole map; the plateau
	# and slab passes sit on top of it.
	if sand_tex != null:
		draw_texture_rect(sand_tex, Rect2(Vector2.ZERO, Vector2(GameDefs.WORLD, GameDefs.WORLD)), true)

	for y in m:
		for x in m:
			var i := y * m + x
			var pos := Vector2(float(x), float(y)) * t
			if concrete[i] == 1:
				if concrete_tex != null:
					# Each tile is one baked plate; the sheet contains four variants
					# so long runs of concrete do not look stamped.
					var variants := maxi(concrete_tex.get_width() / GameDefs.TILE, 1)
					var variant := _hash(x, y) % variants
					draw_texture_rect_region(concrete_tex, Rect2(pos, tile_size),
						Rect2(Vector2(float(variant * GameDefs.TILE), 0.0), tile_size))
				else:
					draw_rect(Rect2(pos, tile_size), SLAB)
					draw_rect(Rect2(pos + Vector2(2, 2), tile_size - Vector2(4, 4)), SLAB_INNER)
			elif types[i] == GameDefs.ROCK:
				if rock_tex != null:
					# Sample the seamless sheet in world space, so adjacent plateau
					# tiles are continuous instead of a mosaic of 40 px stamps.
					var rx := (x * GameDefs.TILE) % rock_tex.get_width()
					var ry := (y * GameDefs.TILE) % rock_tex.get_height()
					draw_texture_rect_region(rock_tex, Rect2(pos, tile_size),
						Rect2(Vector2(float(rx), float(ry)), tile_size))
				else:
					var rn2 := rock_tint.get_noise_2d(float(x), float(y))
					draw_rect(Rect2(pos, tile_size), ROCK_LIGHT.lerp(ROCK_DARK, clampf(0.5 + rn2 * 0.7, 0.0, 1.0)))
			else:
				if sand_tex == null:
					var sn2 := sand_tint.get_noise_2d(float(x), float(y))
					draw_rect(Rect2(pos, tile_size), SAND_LIGHT.lerp(SAND_DARK, clampf(0.5 + sn2 * 0.6, 0.0, 1.0)))

	# Plateau edges: one jagged 16-mask cliff tile per exposed mesa lip. The
	# atlas supplies the south rock face, shaded east wall and sunlit N/W rim;
	# separate cast shadows fall onto the lower desert below and to the right.
	for y in m:
		for x in m:
			if types[y * m + x] != GameDefs.ROCK:
				continue
			var pos := Vector2(float(x), float(y)) * t
			var mask := cliff_mask(x, y)
			if cliff_tex != null and cliff_tex.get_width() >= (mask + 1) * GameDefs.TILE:
				draw_texture_rect_region(cliff_tex, Rect2(pos, tile_size),
					Rect2(Vector2(float(mask * GameDefs.TILE), 0.0), tile_size))
			else:
				if not (mask & CLIFF_S):
					draw_rect(Rect2(pos + Vector2(0, t - 14), Vector2(t, 14)), CLIFF)
					draw_rect(Rect2(pos + Vector2(0, t), Vector2(t, 5)), Color(0, 0, 0, 0.20))
				if not (mask & CLIFF_N):
					draw_rect(Rect2(pos, Vector2(t, 2)), Color(0.80, 0.74, 0.60, 0.45))
				if not (mask & CLIFF_W):
					draw_rect(Rect2(pos, Vector2(2, t)), Color(0.72, 0.65, 0.52, 0.30))
				if not (mask & CLIFF_E):
					draw_rect(Rect2(pos + Vector2(t - 2, 0), Vector2(2, t)), Color(0.12, 0.10, 0.08, 0.34))
			# Cast shadow on the lower sand, offset south-east from the NW key.
			if not _is_rock(x, y + 1):
				draw_rect(Rect2(pos + Vector2(0.0, t), Vector2(t, 5.0)), Color(0.09, 0.04, 0.02, 0.22))
				draw_rect(Rect2(pos + Vector2(0.0, t + 5.0), Vector2(t, 3.0)), Color(0.09, 0.04, 0.02, 0.10))
			if not _is_rock(x + 1, y):
				draw_rect(Rect2(pos + Vector2(t, 0.0), Vector2(4.0, t)), Color(0.09, 0.04, 0.02, 0.15))

	# Spice overlay: density baked into the granules, scaled by amount.
	for y in m:
		for x in m:
			var i := y * m + x
			var amount := spice[i]
			if amount <= 4.0:
				continue
			var pos := Vector2(float(x), float(y)) * t
			if spice_tex != null:
				var sidx := _hash(x, y) % 4
				var a := clampf(amount / 150.0, 0.22, 0.95)
				draw_texture_rect_region(spice_tex, Rect2(pos, tile_size), _atlas(sidx, 4), Color(1, 1, 1, a))
			else:
				draw_rect(Rect2(pos, tile_size), Color(0.66, 0.27, 0.08, 0.16 + clampf(amount / 170.0, 0.0, 1.0) * 0.50))

	draw_rect(Rect2(Vector2.ZERO, Vector2(GameDefs.WORLD, GameDefs.WORLD)), Color(0.08, 0.07, 0.05), false, 4.0)

func _atlas(index: int, cols: int) -> Rect2:
	return Rect2(Vector2(float(index % cols), float(index / cols)) * float(GameDefs.TILE),
		Vector2(GameDefs.TILE, GameDefs.TILE))
