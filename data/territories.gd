class_name ArrakisMap
extends RefCounted

## The strategic map of Arrakis: eight outer provinces, six inner provinces and
## the Imperial Basin at the centre. The campaign starts on the player's outer
## home and pushes inward one province at a time toward the rival stronghold.
##
## The regions are deliberately a ring partition rather than a rectangular
## grid, so the map reads as a planet instead of a board game.

const CENTER := "imperial_basin"
const OUTER_COUNT := 8
const INNER_COUNT := 6

const DEFS := {
	"outer_0": {"name": "Arrakeen", "short": "ARRAKEEN", "kind": "outer", "index": 0},
	"outer_1": {"name": "Wind Pass", "short": "WIND PASS", "kind": "outer", "index": 1},
	"outer_2": {"name": "Shield Wall", "short": "SHIELD WALL", "kind": "outer", "index": 2},
	"outer_3": {"name": "Carthag", "short": "CARTHAG", "kind": "outer", "index": 3},
	"outer_4": {"name": "Cielago North", "short": "CIELAGO N.", "kind": "outer", "index": 4},
	"outer_5": {"name": "Red Wall Sink", "short": "RED WALL", "kind": "outer", "index": 5},
	"outer_6": {"name": "Habbanya Ridge", "short": "HABBANYA", "kind": "outer", "index": 6},
	"outer_7": {"name": "Tuono Basin", "short": "TUONO", "kind": "outer", "index": 7},
	"inner_0": {"name": "Old Gap", "short": "OLD GAP", "kind": "inner", "index": 0},
	"inner_1": {"name": "Sietch Tabr", "short": "SIETCH TABR", "kind": "inner", "index": 1},
	"inner_2": {"name": "Hagga Basin", "short": "HAGGA", "kind": "inner", "index": 2},
	"inner_3": {"name": "Funeral Plain", "short": "FUNERAL PL.", "kind": "inner", "index": 3},
	"inner_4": {"name": "Cielago East", "short": "CIELAGO E.", "kind": "inner", "index": 4},
	"inner_5": {"name": "Central Sink", "short": "CENTRAL SINK", "kind": "inner", "index": 5},
	CENTER: {"name": "Imperial Basin", "short": "IMPERIAL BASIN", "kind": "center", "index": 0},
}

const ORDER := [
	"outer_0", "outer_1", "outer_2", "outer_3", "outer_4", "outer_5", "outer_6", "outer_7",
	"inner_0", "inner_1", "inner_2", "inner_3", "inner_4", "inner_5",
	CENTER,
]

## Which inner provinces share a rim with each outer province. The asymmetry is
## intentional: it gives the 8/6 ring a hand-drawn, uneven frontier.
const OUTER_INNER := {
	0: [0, 5],
	1: [0],
	2: [1],
	3: [1, 2],
	4: [2],
	5: [3],
	6: [3, 4],
	7: [4, 5],
}

const HOMES := {
	"atreides": "outer_0",   # Arrakeen
	"harkonnen": "outer_3",  # Carthag
	"ordos": "outer_6",      # Habbanya Ridge
}

static func exists(id: String) -> bool:
	return DEFS.has(id)

static func data(id: String) -> Dictionary:
	return DEFS.get(id, DEFS[CENTER])

static func display_name(id: String) -> String:
	return String(data(id)["name"])

static func short_name(id: String) -> String:
	return String(data(id)["short"])

static func home_for(house: String) -> String:
	return String(HOMES.get(house, HOMES["atreides"]))

static func kind_of(id: String) -> String:
	return String(data(id).get("kind", "outer"))

static func outer_id(index: int) -> String:
	return "outer_%d" % posmod(index, OUTER_COUNT)

static func inner_id(index: int) -> String:
	return "inner_%d" % posmod(index, INNER_COUNT)

## All orthogonally touching provinces. The centre only touches the inner ring.
static func neighbors(id: String) -> Array:
	var out: Array = []
	if id == CENTER:
		for j in INNER_COUNT:
			out.append(inner_id(j))
		return out
	var d: Dictionary = data(id)
	var index := int(d["index"])
	if String(d["kind"]) == "outer":
		out.append(outer_id(index - 1))
		out.append(outer_id(index + 1))
		for j in OUTER_INNER.get(index, []):
			out.append(inner_id(int(j)))
	else:
		out.append(inner_id(index - 1))
		out.append(inner_id(index + 1))
		out.append(CENTER)
		for o in OUTER_COUNT:
			if int(index) in OUTER_INNER.get(o, []):
				out.append(outer_id(o))
	var unique: Array = []
	for n in out:
		if n != id and not unique.has(n):
			unique.append(n)
	return unique

static func adjacent_to_owner(id: String, owner: String, owners: Dictionary) -> bool:
	for n in neighbors(id):
		if String(owners.get(n, "neutral")) == owner:
			return true
	return false

## Unclaimed or enemy provinces that touch at least one province of `owner`.
static func frontier(owner: String, owners: Dictionary) -> Array:
	var out: Array = []
	for id in ORDER:
		if String(owners.get(id, "neutral")) == owner:
			continue
		if adjacent_to_owner(id, owner, owners):
			out.append(id)
	return out

static func counts(owners: Dictionary) -> Dictionary:
	var out := {"atreides": 0, "harkonnen": 0, "ordos": 0, "neutral": 0}
	for id in ORDER:
		var owner := String(owners.get(id, "neutral"))
		out[owner] = int(out.get(owner, 0)) + 1
	return out

## Initial strategic situation for a campaign. The player holds their home;
## the rival has dug into the inner ring and the two gates next door; the third
## House holds its own home plus one neighbour; the rest is unclaimed desert.
static func initial_owners(player: String, rival: String, third: String) -> Dictionary:
	var owners: Dictionary = {}
	for id in ORDER:
		owners[id] = "neutral"
	var home := home_for(player)
	owners[home] = player
	owners[home_for(rival)] = rival
	owners[home_for(third)] = third
	owners[CENTER] = rival
	for j in INNER_COUNT:
		owners[inner_id(j)] = rival
	var h := int(data(home)["index"])
	for offset in [1, 2, 3, 7]:
		var id := outer_id(h + offset)
		if String(owners[id]) == "neutral":
			owners[id] = rival
	# Give the third House one foothold next to its capital, without stealing
	# the player's home or the rival's gate provinces.
	var t_home := home_for(third)
	var t := int(data(t_home)["index"])
	for offset in [1, 7]:
		var id := outer_id(t + offset)
		if String(owners[id]) == "neutral":
			owners[id] = third
			break
	return owners

static func house_owned(owners: Dictionary, house: String) -> int:
	return int(counts(owners).get(house, 0))

# ------------------------------------------------------------------ geometry

## Build every province polygon in map-local coordinates. The cache key is the
## rectangle, so the map canvas can rebuild on resize without cumulative drift.
static func polygons(rect: Rect2) -> Dictionary:
	var center := rect.position + rect.size * 0.5
	var rx := rect.size.x * 0.465
	var ry := rect.size.y * 0.455
	var out: Dictionary = {}
	for i in OUTER_COUNT:
		var a0 := -PI * 0.5 + float(i) * TAU / float(OUTER_COUNT)
		var a1 := a0 + TAU / float(OUTER_COUNT)
		out[outer_id(i)] = _sector(center, rx, ry, a0, a1, 0.685, 1.0, "o%d" % i)
	var inner_start := -PI * 0.5 + PI / 6.0
	for j in INNER_COUNT:
		var a0 := inner_start + float(j) * TAU / float(INNER_COUNT)
		var a1 := a0 + TAU / float(INNER_COUNT)
		out[inner_id(j)] = _sector(center, rx, ry, a0, a1, 0.305, 0.685, "i%d" % j)
	out[CENTER] = _center_polygon(center, rx, ry)
	return out

static func polygon_center(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p in poly:
		sum += p
	return sum / float(poly.size())

static func point_in(id: String, pos: Vector2, polys: Dictionary) -> bool:
	if not polys.has(id):
		return false
	return Geometry2D.is_point_in_polygon(pos, polys[id])

static func _noise(key: String, salt := 0) -> float:
	var h := hash(key) + salt * 374761393
	h = absi(h ^ (h >> 13))
	return (float(posmod(h, 2000)) / 1000.0) - 1.0

static func _radial(center: Vector2, rx: float, ry: float, angle: float, norm: float, key: String) -> Vector2:
	var r := norm + _noise(key) * 0.013
	var a := angle + _noise(key, 7) * 0.006
	return center + Vector2(cos(a) * rx * r, sin(a) * ry * r)

static func _sector(center: Vector2, rx: float, ry: float, a0: float, a1: float,
		inner_norm: float, outer_norm: float, key: String) -> PackedVector2Array:
	var mid := (a0 + a1) * 0.5
	var inner0 := _radial(center, rx, ry, a0, inner_norm, key + ":i0")
	var inner1 := _radial(center, rx, ry, a1, inner_norm, key + ":i1")
	var inner_mid := _radial(center, rx, ry, mid, inner_norm, key + ":im")
	var outer0 := _radial(center, rx, ry, a0, outer_norm, key + ":o0")
	var outer1 := _radial(center, rx, ry, a1, outer_norm, key + ":o1")
	var outer_mid := _radial(center, rx, ry, mid, outer_norm, key + ":om")
	var radial1 := (inner1 + outer1) * 0.5 + Vector2(
		_noise(key + ":r1", 3) * 4.0, _noise(key + ":r1", 5) * 4.0)
	var radial0 := (inner0 + outer0) * 0.5 + Vector2(
		_noise(key + ":r0", 3) * 4.0, _noise(key + ":r0", 5) * 4.0)
	return PackedVector2Array([
		inner0, inner_mid, inner1, radial1, outer1, outer_mid, outer0, radial0,
	])

static func _center_polygon(center: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var count := 14
	for i in count:
		var a := -PI * 0.5 + float(i) * TAU / float(count)
		var r := 0.305 + _noise("center:%d" % i) * 0.012
		points.append(center + Vector2(cos(a) * rx * r, sin(a) * ry * r))
	return points
