class_name WallArt
extends RefCounted

## Dedicated 1x1 wall autotiles.
##
## The old wall borrowed the 184x184 general building sheet, so one 40 px tile
## rendered a whole standalone block. This sheet is exactly 16 cells wide and
## two damage rows tall, with each 40x40 cell fitting one map tile.
##
## Frame layout uses N=1, E=2, S=4, W=8. Connected sides run all the way to the
## cell edge and deliberately have no bevel or outline there, so adjacent cells
## fuse into a continuous wall. Disconnected sides get the cap bevel, dark face
## and a small exterior shadow.

const TILE := 40
const FRAME_COUNT := 16
const ROW_COUNT := 2
const DAMAGE_ROW := 1

const N := 1
const E := 2
const S := 4
const W := 8

## 30 px concrete body through the middle of the tile, with 5 px of clearance
## either side, plus a raised 12 px steel cap rail down its centre.
const BODY_LO := 5
const BODY_HI := 35
const BODY_MID := 20
const CAP_LO := 14
const CAP_HI := 26

const C_TOP := Color(0.56, 0.52, 0.44)
const C_TOP_DAMAGED := Color(0.41, 0.38, 0.33)
const C_CAP := Color(0.29, 0.30, 0.28)
const C_CAP_DAMAGED := Color(0.20, 0.21, 0.20)
const C_RUST := Color(0.39, 0.19, 0.07)
const C_CRACK := Color(0.13, 0.11, 0.08)
const C_SHADOW := Color(0.035, 0.028, 0.020, 0.44)

static var _sheet: ImageTexture
static var _icon: ImageTexture

static func sheet() -> Texture2D:
	if _sheet == null:
		_sheet = ImageTexture.create_from_image(_make_sheet())
	return _sheet

## Sidebar portrait uses a straight 1x1 wall segment from the same sheet, so the
## build tile does not keep advertising the old standalone-block artwork.
static func icon() -> Texture2D:
	if _icon == null:
		var plate := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		for y in 64:
			for x in 64:
				var n := 0.035 + 0.018 * float((x * 13 + y * 7) % 11) / 10.0
				var edge := 1.0 if x < 2 or y < 2 or x > 61 or y > 61 else 0.0
				plate.set_pixel(x, y, Color(n + edge * 0.035, n * 0.86 + edge * 0.025,
					n * 0.65 + edge * 0.015, 1.0))
		var segment := _make_tile(E | W, false)
		segment.resize(54, 54, Image.INTERPOLATE_NEAREST)
		plate.blend_rect(segment, Rect2i(0, 0, 54, 54), Vector2i(5, 5))
		_icon = ImageTexture.create_from_image(plate)
	return _icon

static func mask_for(north: bool, east: bool, south: bool, west: bool) -> int:
	var mask := 0
	if north:
		mask |= N
	if east:
		mask |= E
	if south:
		mask |= S
	if west:
		mask |= W
	return mask

static func _make_sheet() -> Image:
	var sheet := Image.create(TILE * FRAME_COUNT, TILE * ROW_COUNT, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.0, 0.0, 0.0, 0.0))
	for row in ROW_COUNT:
		for mask in FRAME_COUNT:
			var tile := _make_tile(mask, row == DAMAGE_ROW)
			sheet.blit_rect(tile, Rect2i(0, 0, TILE, TILE), Vector2i(mask * TILE, row * TILE))
	return sheet

static func _make_tile(mask: int, damaged: bool) -> Image:
	var seed_value := 4400 + mask * 97 + (701 if damaged else 0)
	var solid := PackedByteArray()
	solid.resize(TILE * TILE)
	solid.fill(0)

	# Central post, then a full-thickness arm for every connected neighbour.
	_solid_rect(solid, BODY_LO, BODY_LO, BODY_HI, BODY_HI)
	if mask & N:
		_solid_rect(solid, BODY_LO, 0, BODY_HI, BODY_MID)
	if mask & E:
		_solid_rect(solid, BODY_MID, BODY_LO, TILE, BODY_HI)
	if mask & S:
		_solid_rect(solid, BODY_LO, BODY_MID, BODY_HI, TILE)
	if mask & W:
		_solid_rect(solid, 0, BODY_LO, BODY_MID, BODY_HI)

	# Raised cap rail down the middle of every arm. It is narrower than the
	# concrete body, so the shoulders and the cap's shadow stay readable.
	var cap := PackedByteArray()
	cap.resize(TILE * TILE)
	cap.fill(0)
	_solid_rect(cap, CAP_LO, CAP_LO, CAP_HI, CAP_HI)
	if mask & N:
		_solid_rect(cap, CAP_LO, 0, CAP_HI, BODY_MID)
	if mask & E:
		_solid_rect(cap, BODY_MID, CAP_LO, TILE, CAP_HI)
	if mask & S:
		_solid_rect(cap, CAP_LO, BODY_MID, CAP_HI, TILE)
	if mask & W:
		_solid_rect(cap, 0, CAP_LO, BODY_MID, CAP_HI)

	var img := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))

	for y in TILE:
		for x in TILE:
			if solid[y * TILE + x] == 0:
				continue
			var h := _hash(x, y, seed_value)
			var grain := (h - 0.5) * 0.12
			var broad := sin(float(x) * 0.21 + float(y) * 0.13 + float(seed_value) * 0.017)
			var base: Color = C_TOP_DAMAGED if damaged else C_TOP
			base = base.lightened(grain) if grain > 0.0 else base.darkened(-grain)
			if broad > 0.0:
				base = base.lightened(broad * 0.035)
			else:
				base = base.darkened(-broad * 0.030)

			# Scattered aggregate and worn chips. These stay inside the wall, so
			# no cell-edge texture can open a seam between neighbouring tiles.
			if h > 0.978:
				base = base.darkened(0.24)
			elif h < 0.018:
				base = base.lightened(0.15)
			if h > 0.905 and h < 0.918 and y > 14:
				base = base.lerp(C_RUST, 0.28)
			if damaged:
				base = base.lerp(Color(0.20, 0.18, 0.14), 0.14)

			# Outer concrete bevel. A connected side is treated as opaque
			# outside the cell, which keeps that edge flat and seamless.
			var edge_n := not _opaque(solid, mask, x, y - 1)
			var edge_e := not _opaque(solid, mask, x + 1, y)
			var edge_s := not _opaque(solid, mask, x, y + 1)
			var edge_w := not _opaque(solid, mask, x - 1, y)
			if edge_n:
				base = base.lightened(0.20)
			if edge_w:
				base = base.lightened(0.10)
			if edge_s:
				base = base.darkened(0.34)
			if edge_e:
				base = base.darkened(0.20)
			if (edge_n or edge_w) and (edge_s or edge_e):
				base = base.lightened(0.035)

			# The exposed south/east edges are genuinely vertical faces, not just
			# a one-pixel outline. Three pixels of darker, streaked concrete give
			# the flat top-down tile a readable parapet height. If that side is
			# connected, no face is drawn and the neighbouring top surface meets
			# this cell without a seam.
			var face_s := not _opaque(solid, mask, x, y + 1) \
				or not _opaque(solid, mask, x, y + 2) \
				or not _opaque(solid, mask, x, y + 3)
			var face_e := not _opaque(solid, mask, x + 1, y) \
				or not _opaque(solid, mask, x + 2, y) \
				or not _opaque(solid, mask, x + 3, y)
			if face_s or face_e:
				var face := Color(0.245, 0.225, 0.185)
				if face_s and face_e:
					face = face.darkened(0.08)
				var streak := (x * 5 + y * 3 + seed_value) % 9
				if streak < 2:
					face = face.darkened(0.14)
				elif streak == 8:
					face = face.lightened(0.10)
				if face_s and not _opaque(solid, mask, x, y - 1):
					face = face.lightened(0.12)
				if face_e and not _opaque(solid, mask, x - 1, y):
					face = face.lightened(0.08)
				base = face

			# Masonry joints. The positions sit inside the tile, never on a
			# joined edge, so two adjacent walls do not produce a seam.
			if cap[y * TILE + x] == 0:
				if (mask & (N | S)) != 0 and y % 20 == 10:
					base = base.darkened(0.14)
				if (mask & (E | W)) != 0 and x % 20 == 10:
					base = base.darkened(0.14)
				# Shadow cast by the raised cap onto the concrete shoulders.
				if (x + 1 < TILE and cap[y * TILE + x + 1] != 0) or (y + 1 < TILE and cap[(y + 1) * TILE + x] != 0):
					base = base.darkened(0.15)

			img.set_pixel(x, y, base)

	# Raised steel cap, with strong top-light and under-shadow.
	for y in TILE:
		for x in TILE:
			if cap[y * TILE + x] == 0:
				continue
			var h := _hash(x, y, seed_value + 313)
			var base: Color = C_CAP_DAMAGED if damaged else C_CAP
			if h >= 0.5:
				base = base.lightened((h - 0.5) * 0.15)
			else:
				base = base.darkened((0.5 - h) * 0.15)
			if h > 0.965:
				base = base.darkened(0.25)
			elif h < 0.025:
				base = base.lightened(0.22)
			var edge_n := not _opaque(cap, mask, x, y - 1)
			var edge_e := not _opaque(cap, mask, x + 1, y)
			var edge_s := not _opaque(cap, mask, x, y + 1)
			var edge_w := not _opaque(cap, mask, x - 1, y)
			if edge_n:
				base = base.lightened(0.36)
			if edge_w:
				base = base.lightened(0.12)
			if edge_s:
				base = base.darkened(0.46)
			if edge_e:
				base = base.darkened(0.26)
			# Sparse rail joints rather than a dotted centre line. Positions stay
			# inside the cell so a connected end never gets a half joint.
			if (x == 19 or x == 20) and y % 20 == 8 and (mask & (N | S)) != 0:
				base = base.darkened(0.24)
			if (y == 19 or y == 20) and x % 20 == 8 and (mask & (E | W)) != 0:
				base = base.darkened(0.24)
			img.set_pixel(x, y, base)

	# A two-step cast shadow on exposed south/east faces. Connected edges never
	# reach this pass because the arm continues across the cell boundary.
	for y in TILE:
		for x in TILE:
			if solid[y * TILE + x] != 0:
				continue
			var shadowed := false
			if y > 0 and solid[(y - 1) * TILE + x] != 0:
				shadowed = true
			if x > 0 and solid[y * TILE + x - 1] != 0:
				shadowed = true
			var near_shadow := false
			if y > 1 and solid[(y - 2) * TILE + x] != 0:
				near_shadow = true
			if x > 1 and solid[y * TILE + x - 2] != 0:
				near_shadow = true
			if shadowed:
				img.set_pixel(x, y, C_SHADOW)
			elif near_shadow:
				img.set_pixel(x, y, Color(C_SHADOW.r, C_SHADOW.g, C_SHADOW.b, 0.20))

	if damaged:
		_damage_tile(img, solid, seed_value)
	return img

static func _solid_rect(solid: PackedByteArray, x0: int, y0: int, x1: int, y1: int) -> void:
	for y in range(maxi(y0, 0), mini(y1, TILE)):
		for x in range(maxi(x0, 0), mini(x1, TILE)):
			solid[y * TILE + x] = 1

## Treat the world beyond a connected cell edge as wall, not empty ground. This
## is what removes the otherwise unavoidable one-pixel outline at every seam.
static func _opaque(solid: PackedByteArray, mask: int, x: int, y: int) -> bool:
	if x < 0:
		return (mask & W) != 0
	if x >= TILE:
		return (mask & E) != 0
	if y < 0:
		return (mask & N) != 0
	if y >= TILE:
		return (mask & S) != 0
	return solid[y * TILE + x] != 0

static func _damage_tile(img: Image, solid: PackedByteArray, seed_value: int) -> void:
	# Soot on both sides of the post.
	for spot in 2:
		var cx := 16 + int(_hash(spot, 3, seed_value) * 9.0)
		var cy := 13 + int(_hash(spot, 8, seed_value) * 14.0)
		for oy in range(-2, 3):
			for ox in range(-2, 3):
				var x := cx + ox
				var y := cy + oy
				if x < 0 or y < 0 or x >= TILE or y >= TILE:
					continue
				if solid[y * TILE + x] == 0:
					continue
				var falloff := 1.0 - float(ox * ox + oy * oy) / 8.0
				var c := img.get_pixel(x, y)
				img.set_pixel(x, y, c.lerp(Color(0.055, 0.048, 0.035), falloff * 0.55))

	# Two jagged cracks, drawn only over wall pixels.
	for crack in 2:
		var x := 12 + int(_hash(crack, 21, seed_value) * 16.0)
		var y := 10 + int(_hash(crack, 29, seed_value) * 10.0)
		for step in 9:
			if x >= 0 and y >= 0 and x < TILE and y < TILE and solid[y * TILE + x] != 0:
				img.set_pixel(x, y, C_CRACK)
			var sideways := 1 if _hash(x, y + step, seed_value) > 0.46 else -1
			x += sideways
			if step % 2 == 1:
				y += 1
	# Rust weeping from one exposed end.
	for i in 6:
		var rx := 10 + int(_hash(i, 41, seed_value) * 5.0)
		var ry := 24 + i
		if rx < TILE and ry < TILE and solid[ry * TILE + rx] != 0:
			img.set_pixel(rx, ry, img.get_pixel(rx, ry).lerp(C_RUST, 0.62))

static func _hash(x: int, y: int, seed_value: int) -> float:
	var h: int = (x * 73856093) ^ (y * 19349663) ^ (seed_value * 83492791)
	h = abs(h)
	return float(h % 1000003) / 1000003.0
