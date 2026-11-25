class_name Fx
extends Node2D

## Muzzle flashes, impact puffs/fireballs, death blasts and floating text.
## There are deliberately no shots/beams drawn between shooter and target.

var flashes: Array = []
var impacts: Array = []
var blasts: Array = []
var texts: Array = []
var waves: Array = []
## Floating text stays legible over sunlit sand: a crisp dark outline plus a
## 2 px drop shadow, bright gold for credit gains and hot orange-red for
## combat/status callouts.
const POPUP_FONT_SIZE := 16
const POPUP_GOLD := Color(1.0, 0.84, 0.30)
const POPUP_COMBAT := Color(1.0, 0.40, 0.267)
const POPUP_OUTLINE := Color(0.035, 0.018, 0.008, 0.98)
## Expanding sand shockwaves for Sandworm surfacing and Carryall touchdown.
var bursts: Array = []
## Lingering Deviator chemical clouds and Devastator reactor detonations.
var gas_clouds: Array = []
var nukes: Array = []
## Drifting desert dust motes. Positions live in world space and wrap inside
## the camera's visible rectangle, so the effect follows the view for free.
var wind: Array = []
var wind_clock := 0.0
const WIND_COUNT := 52
## Harvester machinery: dark stack smoke and track-sponson sand spray. Both are
## emitter-fed, so a working rig streams continuously without a node per puff.
var exhausts: Array = []
var dust_kicks: Array = []
## Slow, soft sand clouds that rise behind moving heavy vehicles.
var trail_dusts: Array = []
## Bright ore thrown forward by the dozer scoop while mining.
var spice_kicks: Array = []
const EXHAUST_LIMIT := 190
const DUST_LIMIT := 170
const TRAIL_DUST_LIMIT := 150
const SPICE_LIMIT := 120

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 19980101
	for i in WIND_COUNT:
		wind.append({
			"p": Vector2(rng.randf_range(64.0, float(GameDefs.WORLD) - 64.0),
				rng.randf_range(64.0, float(GameDefs.WORLD) - 64.0)),
			"v": Vector2(rng.randf_range(16.0, 36.0), rng.randf_range(3.0, 9.0)),
			"a": rng.randf_range(0.035, 0.095),
			"r": rng.randf_range(0.8, 1.8),
			"ph": rng.randf() * TAU,
		})

## Short pixel muzzle flash. kind: rifle / light / cannon / rocket.
func muzzle(pos: Vector2, angle: float, kind: String, side := 1.0) -> void:
	var life := 0.07
	if kind == "cannon":
		life = 0.16
	elif kind == "rocket":
		life = 0.12
	flashes.append({"p": pos, "a": angle, "kind": kind, "side": side, "t": 0.0, "life": life})

## Impact FX. kind: rifle / light / cannon / rocket.
func impact(pos: Vector2, kind: String, power := 1.0) -> void:
	var life := 0.28
	if kind == "cannon":
		life = 0.42
	elif kind == "rocket":
		life = 0.50
	impacts.append({"p": pos, "kind": kind, "power": power, "t": 0.0, "life": life})

## Large death explosion, kept separate from weapon impacts.
func blast(pos: Vector2, power := 1.0) -> void:
	blasts.append({"p": pos, "t": 0.0, "power": power})

## Deviator impact: a bright emerald cloud that lingers and billows, so the
## converted zone stays visible after the flash is gone.
func gas_cloud(pos: Vector2, radius := 56.0) -> void:
	gas_clouds.append({"p": pos, "r": radius, "t": 0.0, "life": 2.8})

## Devastator reactor meltdown: a multi-stage nuclear blast, far larger than
## any ordinary death fireball.
func nuke(pos: Vector2) -> void:
	nukes.append({"p": pos, "t": 0.0, "life": 1.5})

func popup(text: String, pos: Vector2) -> void:
	texts.append({"text": text, "p": pos, "t": 0.0})

## One heavy soot puff from a harvester exhaust stack. `drift` is the hull's
## backward direction, so the plume trails the rig while it works.
func exhaust_plume(pos: Vector2, drift := Vector2.ZERO, power := 1.0) -> void:
	if exhausts.size() >= EXHAUST_LIMIT:
		exhausts.pop_front()
	exhausts.append({
		"p": pos,
		"v": drift.normalized() * randf_range(7.0, 15.0) + Vector2(randf_range(-5.0, 5.0), -randf_range(17.0, 30.0)),
		"r": randf_range(2.6, 4.2) * power,
		"t": 0.0,
		"life": randf_range(0.85, 1.35),
		"power": power,
	})

## Sand and grit thrown out from under a track sponson.
func track_dust(pos: Vector2, drift := Vector2.ZERO, power := 1.0) -> void:
	if dust_kicks.size() >= DUST_LIMIT:
		dust_kicks.pop_front()
	dust_kicks.append({
		"p": pos,
		"v": drift.normalized() * randf_range(10.0, 26.0) + Vector2(randf_range(-8.0, 8.0), randf_range(-10.0, -2.0)),
		"r": randf_range(2.2, 4.0) * power,
		"t": 0.0,
		"life": randf_range(0.45, 0.85),
		"chunk": randf_range(0.0, 1.0) < 0.45,
	})

## A soft desert plume dragged behind heavy tracks. Unlike the short grit
## spray above, this rises and expands for over a second, so a moving column
## leaves a warm dust trail without a node per puff.
func trail_dust(pos: Vector2, drift := Vector2.ZERO, power := 1.0) -> void:
	if trail_dusts.size() >= TRAIL_DUST_LIMIT:
		trail_dusts.pop_front()
	trail_dusts.append({
		"p": pos,
		"v": drift.normalized() * randf_range(2.0, 9.0) + Vector2(randf_range(-5.0, 5.0), -randf_range(12.0, 24.0)),
		"r": randf_range(3.4, 6.2) * power,
		"t": 0.0,
		"life": randf_range(1.0, 1.75),
	})

## Orange spice granules thrown off the harvester's cutting edge. Kept
## separate from sand so the load reads even over warm desert ground.
func spice_kick(pos: Vector2, drift := Vector2.ZERO, power := 1.0) -> void:
	if spice_kicks.size() >= SPICE_LIMIT:
		spice_kicks.pop_front()
	spice_kicks.append({
		"p": pos,
		"v": drift.normalized() * randf_range(12.0, 30.0) + Vector2(randf_range(-13.0, 13.0), randf_range(-25.0, -8.0)),
		"r": randf_range(1.4, 2.9) * power,
		"t": 0.0,
		"life": randf_range(0.35, 0.72),
	})

## A desert shockwave: concentric ellipses plus a spray of sand chunks.
func sand_burst(pos: Vector2, radius := 72.0, power := 1.0) -> void:
	bursts.append({"p": pos, "r": radius, "power": power, "t": 0.0})

## Sonic Tank shockwave: three expanding arcs along the firing line.
func sonic_wave(from: Vector2, dir: Vector2, length: float, team: int) -> void:
	waves.append({"p": from, "a": dir.angle(), "len": length, "team": team, "t": 0.0, "life": 0.42})

func _process(delta: float) -> void:
	_advance_wind(delta)
	if flashes.is_empty() and impacts.is_empty() and blasts.is_empty() and texts.is_empty() \
			and waves.is_empty() and bursts.is_empty() and gas_clouds.is_empty() and nukes.is_empty() \
			and wind.is_empty() and exhausts.is_empty() and dust_kicks.is_empty() \
			and trail_dusts.is_empty() and spice_kicks.is_empty():
		return
	for f in flashes:
		f["t"] = float(f["t"]) + delta
	for i in impacts:
		i["t"] = float(i["t"]) + delta
	for b in blasts:
		b["t"] = float(b["t"]) + delta
	for t in texts:
		t["t"] = float(t["t"]) + delta
		t["p"] = t["p"] + Vector2(0.0, -30.0 * delta)
	for w in waves:
		w["t"] = float(w["t"]) + delta
	for s in bursts:
		s["t"] = float(s["t"]) + delta
	for c in gas_clouds:
		c["t"] = float(c["t"]) + delta
	for n in nukes:
		n["t"] = float(n["t"]) + delta
	for e in exhausts:
		e["t"] = float(e["t"]) + delta
		e["p"] = e["p"] + e["v"] * delta
		e["v"] = Vector2(float(e["v"].x) * 0.985, float(e["v"].y) - 4.0 * delta)
	for d in dust_kicks:
		d["t"] = float(d["t"]) + delta
		d["p"] = d["p"] + d["v"] * delta
		d["v"] = Vector2(float(d["v"].x) * 0.90, float(d["v"].y) + 22.0 * delta)
	for d in trail_dusts:
		d["t"] = float(d["t"]) + delta
		d["p"] = d["p"] + d["v"] * delta
		d["v"] = Vector2(float(d["v"].x) * 0.985, float(d["v"].y) * 0.975)
	for s in spice_kicks:
		s["t"] = float(s["t"]) + delta
		s["p"] = s["p"] + s["v"] * delta
		s["v"] = Vector2(float(s["v"].x) * 0.96, float(s["v"].y) + 120.0 * delta)
	flashes = flashes.filter(func(f): return float(f["t"]) < float(f["life"]))
	impacts = impacts.filter(func(i): return float(i["t"]) < float(i["life"]))
	blasts = blasts.filter(func(b): return float(b["t"]) < 0.5)
	texts = texts.filter(func(t): return float(t["t"]) < 1.6)
	waves = waves.filter(func(w): return float(w["t"]) < float(w["life"]))
	bursts = bursts.filter(func(s): return float(s["t"]) < 0.9)
	gas_clouds = gas_clouds.filter(func(c): return float(c["t"]) < float(c["life"]))
	nukes = nukes.filter(func(n): return float(n["t"]) < float(n["life"]))
	exhausts = exhausts.filter(func(e): return float(e["t"]) < float(e["life"]))
	dust_kicks = dust_kicks.filter(func(d): return float(d["t"]) < float(d["life"]))
	trail_dusts = trail_dusts.filter(func(d): return float(d["t"]) < float(d["life"]))
	spice_kicks = spice_kicks.filter(func(s): return float(s["t"]) < float(s["life"]))
	queue_redraw()

func _draw() -> void:
	_draw_wind()
	_draw_dust_kicks()
	_draw_trail_dusts()
	_draw_spice_kicks()
	for s in bursts:
		_draw_sand_burst(s)
	for c in gas_clouds:
		_draw_gas_cloud(c)
	for i in impacts:
		_draw_impact(i)
	for b in blasts:
		var k := clampf(1.0 - float(b["t"]) / 0.5, 0.0, 1.0)
		var power := float(b.get("power", 1.0))
		var r := (18.0 * (1.0 - k) + 4.0) * power
		draw_circle(b["p"], r, Color(1.0, 0.50, 0.12, k * 0.78))
		draw_circle(b["p"], r * 0.55, Color(1.0, 0.86, 0.34, k * 0.88))
	for n in nukes:
		_draw_nuke(n)
	_draw_exhausts()
	for w in waves:
		_draw_wave(w)
	for f in flashes:
		_draw_muzzle(f)
	for t in texts:
		var k := clampf(1.0 - float(t["t"]) / 1.6, 0.0, 1.0)
		var font := ThemeDB.fallback_font
		var text := String(t["text"])
		var fill := POPUP_GOLD if text.begins_with("+") else POPUP_COMBAT
		var p: Vector2 = t["p"]
		# Offset shadow first, then a true 2 px outline so the glyphs remain
		# crisp even when several popups overlap bright spice or rock.
		draw_string(font, p + Vector2(2.0, 2.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			POPUP_FONT_SIZE, Color(0.0, 0.0, 0.0, 0.62 * k))
		draw_string_outline(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			POPUP_FONT_SIZE, 2, Color(POPUP_OUTLINE.r, POPUP_OUTLINE.g, POPUP_OUTLINE.b, 0.96 * k))
		draw_string(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			POPUP_FONT_SIZE, Color(fill.r, fill.g, fill.b, k))

## Track spray sits low and settles fast: pale sand puffs plus tumbling grit.
func _draw_dust_kicks() -> void:
	for d in dust_kicks:
		var k := clampf(float(d["t"]) / float(d["life"]), 0.0, 1.0)
		var fade := 1.0 - k
		var p: Vector2 = d["p"]
		var r := float(d["r"]) * (1.0 + k * 1.7)
		draw_circle(p, r, Color(0.68, 0.55, 0.37, 0.20 * fade))
		draw_circle(p + Vector2(-1.0, -1.5), r * 0.58, Color(0.86, 0.73, 0.52, 0.20 * fade))
		if bool(d["chunk"]):
			draw_rect(Rect2(p + Vector2(r * 0.3, -k * 5.0), Vector2(2.0, 2.0)),
				Color(0.45, 0.33, 0.19, 0.55 * fade))

## Warm dust veils that soften as they rise. Three low-alpha discs per puff
## keep the plume volumetric without turning into a solid orange circle.
func _draw_trail_dusts() -> void:
	for d in trail_dusts:
		var k := clampf(float(d["t"]) / float(d["life"]), 0.0, 1.0)
		var fade := pow(1.0 - k, 1.25)
		var p: Vector2 = d["p"]
		var r := float(d["r"]) * (1.0 + k * 3.0)
		draw_circle(p, r, Color(0.55, 0.42, 0.27, 0.13 * fade))
		draw_circle(p + Vector2(-1.2, -1.8), r * 0.78, Color(0.72, 0.58, 0.40, 0.14 * fade))
		draw_circle(p + Vector2(-2.6, -3.4), r * 0.42, Color(0.90, 0.77, 0.56, 0.12 * fade))

## A bright orange granule with a dark rim so it pops over tan sand.
func _draw_spice_kicks() -> void:
	for s in spice_kicks:
		var k := clampf(float(s["t"]) / float(s["life"]), 0.0, 1.0)
		var fade := 1.0 - k
		var p: Vector2 = s["p"]
		var r := float(s["r"]) * (1.0 + k * 0.35)
		draw_circle(p, r + 0.8, Color(0.30, 0.12, 0.02, 0.45 * fade))
		draw_circle(p, r, Color(0.98, 0.46, 0.08, 0.82 * fade))
		draw_circle(p + Vector2(-0.5, -0.5), r * 0.42,
			Color(1.0, 0.78, 0.28, 0.75 * fade))

## Volumetric diesel smoke: a dark core, a warm dusty shell and a thinning
## crown. The plume expands as it rises so it reads as volume, not dots.
func _draw_exhausts() -> void:
	for e in exhausts:
		var k := clampf(float(e["t"]) / float(e["life"]), 0.0, 1.0)
		var fade := 1.0 - k
		var p: Vector2 = e["p"]
		var r := float(e["r"]) * (1.0 + k * 3.4) * float(e["power"])
		draw_circle(p, r * 1.30, Color(0.16, 0.135, 0.105, 0.13 * fade))
		draw_circle(p + Vector2(0.6, -0.8), r * 0.92, Color(0.20, 0.170, 0.130, 0.24 * fade))
		draw_circle(p + Vector2(-0.4, -1.6), r * 0.52, Color(0.33, 0.290, 0.240, 0.20 * fade))

func _draw_sand_burst(s: Dictionary) -> void:
	var k := clampf(float(s["t"]) / 0.9, 0.0, 1.0)
	var p: Vector2 = s["p"]
	var radius := float(s["r"]) * float(s["power"])
	var alpha := (1.0 - k) * 0.72
	draw_set_transform(p, 0.0, Vector2(1.0, 0.55))
	for ring in 3:
		var reach := radius * (0.28 + k * 0.95 + float(ring) * 0.22)
		draw_arc(Vector2.ZERO, reach, 0.0, TAU, 30,
			Color(0.88, 0.74, 0.48, alpha * (0.9 - float(ring) * 0.24)), 3.4 - float(ring) * 0.7)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Chunks thrown up and falling back through the dust.
	for i in 9:
		var a := TAU * float(i) / 9.0 + 0.4
		var reach := radius * (0.22 + k * 0.85)
		var drop := sin(k * PI) * (10.0 + float(i % 3) * 6.0)
		var chunk := p + Vector2(cos(a) * reach, sin(a) * reach * 0.55 - drop)
		draw_circle(chunk, maxf(1.5, 3.6 * (1.0 - k)), Color(0.62, 0.47, 0.29, alpha * 0.9))

## Sonic Tank: a broad, shimmering cyan-white acoustic cone that travels down
## the firing line, reading as a directed pressure wave rather than a bullet.
func _draw_wave(w: Dictionary) -> void:
	var k := clampf(float(w["t"]) / float(w["life"]), 0.0, 1.0)
	var fade := 1.0 - k
	var origin: Vector2 = w["p"]
	var angle := float(w["a"])
	var length := float(w["len"])
	var dir := Vector2.RIGHT.rotated(angle)
	var perp := Vector2(-dir.y, dir.x)
	var head := length * (0.20 + 0.80 * k)
	var half_width := 20.0 + 62.0 * k
	# Translucent fan body, widening as the wavefront advances.
	draw_colored_polygon(PackedVector2Array([
		origin + perp * 7.0,
		origin + dir * head + perp * half_width,
		origin + dir * head - perp * half_width,
		origin - perp * 7.0,
	]), Color(0.42, 0.92, 1.0, 0.13 * fade))
	draw_colored_polygon(PackedVector2Array([
		origin + perp * 4.0,
		origin + dir * head + perp * half_width * 0.62,
		origin + dir * head - perp * half_width * 0.62,
		origin - perp * 4.0,
	]), Color(0.78, 0.99, 1.0, 0.10 * fade))
	# Bright wavefront arcs, plus a white leading edge.
	for i in 3:
		draw_arc(origin + dir * head, 7.0 + float(i) * 9.0, angle - 1.05, angle + 1.05, 16,
			Color(0.68, 0.97, 1.0, (0.66 - float(i) * 0.16) * fade), 2.8 - float(i) * 0.6)
	draw_line(origin + dir * head + perp * half_width,
		origin + dir * head - perp * half_width,
		Color(0.92, 1.0, 1.0, 0.56 * fade), 1.8)
	# Shimmering transverse bands travelling inside the cone.
	for j in 5:
		var at := clampf(float(j) / 5.0 + fmod(k * 2.4, 0.20), 0.0, 1.0)
		var d := at * head
		var width := lerpf(6.0, half_width, at)
		draw_line(origin + dir * d + perp * width, origin + dir * d - perp * width,
			Color(0.72, 0.98, 1.0, 0.20 * fade), 1.2)
	draw_line(origin, origin + dir * head,
		Color(0.95, 1.0, 1.0, 0.28 * fade), 2.0)

func _draw_gas_cloud(c: Dictionary) -> void:
	var life := float(c["life"])
	var t := float(c["t"])
	var k := clampf(t / life, 0.0, 1.0)
	var fade := clampf(1.0 - k, 0.0, 1.0)
	var p: Vector2 = c["p"]
	var radius := float(c["r"])
	var billow := clampf(t / 0.35, 0.0, 1.0)
	# Low, heavy chemical cloud with brighter rolling tops.
	for i in 7:
		var a := TAU * float(i) / 7.0 + 0.35
		var orbit := radius * (0.18 + 0.55 * billow) * (0.75 + 0.25 * sin(float(i) * 1.7 + t * 2.2))
		var cp := p + Vector2(cos(a), sin(a) * 0.62) * orbit
		var puff := radius * (0.42 + 0.16 * sin(t * 3.0 + float(i)))
		draw_circle(cp, puff, Color(0.16, 0.68, 0.24, 0.20 * fade))
		draw_circle(cp + Vector2(-2.0, -3.0), puff * 0.68, Color(0.34, 0.92, 0.38, 0.22 * fade))
		draw_circle(cp + Vector2(-3.0, -5.0), puff * 0.34, Color(0.72, 1.0, 0.62, 0.28 * fade))
	draw_circle(p, radius * 0.52, Color(0.20, 0.82, 0.30, 0.16 * fade))
	draw_circle(p, radius * 0.24, Color(0.58, 1.0, 0.48, 0.20 * fade))

func _draw_nuke(n: Dictionary) -> void:
	var life := float(n["life"])
	var t := float(n["t"])
	var k := clampf(t / life, 0.0, 1.0)
	var fade := 1.0 - k
	var p: Vector2 = n["p"]
	# White-hot flash, then a rising orange-red fireball with shock rings.
	if k < 0.30:
		var flash := 1.0 - k / 0.30
		draw_circle(p, 100.0 * flash + 20.0, Color(1.0, 0.98, 0.90, 0.85 * flash))
	draw_circle(p, (34.0 + 150.0 * k), Color(1.0, 0.44, 0.08, 0.66 * fade))
	draw_circle(p, (22.0 + 92.0 * k), Color(1.0, 0.72, 0.22, 0.74 * fade))
	draw_circle(p, (12.0 + 46.0 * k), Color(1.0, 0.94, 0.72, 0.82 * fade))
	for i in 3:
		var reach := 52.0 + 170.0 * k + float(i) * 26.0
		draw_arc(p, reach, 0.0, TAU, 34,
			Color(1.0, 0.72, 0.30, (0.42 - float(i) * 0.10) * fade), 3.2 - float(i) * 0.7)
	# Mushroom column and tumbling smoke balls.
	for i in 6:
		var a := TAU * float(i) / 6.0 + float(i) * 0.4
		var orbit := 26.0 + 88.0 * k
		var smoke := p + Vector2(cos(a) * orbit, sin(a) * orbit * 0.55)
		draw_circle(smoke, 16.0 + 16.0 * k, Color(0.18, 0.15, 0.12, 0.42 * fade))
	var rise := 110.0 * k
	draw_circle(p + Vector2(0.0, -rise), 30.0 + 36.0 * k, Color(0.30, 0.19, 0.12, 0.36 * fade))
	draw_circle(p + Vector2(0.0, -rise * 1.5), 18.0 + 26.0 * k, Color(0.24, 0.18, 0.13, 0.28 * fade))

func _draw_muzzle(f: Dictionary) -> void:
	var k := clampf(1.0 - float(f["t"]) / float(f["life"]), 0.0, 1.0)
	var p: Vector2 = f["p"]
	var dir := Vector2.RIGHT.rotated(float(f["a"]))
	var perp := Vector2(-dir.y, dir.x)
	var side := float(f["side"])
	match String(f["kind"]):
		"cannon":
			draw_circle(p, 8.5 * k + 2.0, Color(1.0, 0.45, 0.08, 0.85 * k))
			draw_circle(p, 4.2 * k + 1.0, Color(1.0, 0.92, 0.55, 0.95 * k))
			for i in 3:
				var off: Vector2 = p + dir * (4.0 + float(i) * 3.0) + perp * (side * float(i) - 2.0)
				draw_circle(off, 4.5 - float(i), Color(0.48, 0.46, 0.42, 0.38 * k))
		"rocket":
			draw_circle(p, 6.0 * k + 2.0, Color(1.0, 0.58, 0.14, 0.85 * k))
			draw_circle(p, 2.5 * k + 1.0, Color(1.0, 0.94, 0.64, 0.95 * k))
			draw_circle(p + dir * 4.0 + perp * side * 2.0, 4.0,
				Color(0.56, 0.53, 0.48, 0.42 * k))
		"plasma":
			draw_circle(p, 10.0 * k + 2.0, Color(1.0, 0.18, 0.04, 0.55 * k))
			draw_circle(p, 6.0 * k + 1.5, Color(1.0, 0.52, 0.10, 0.90 * k))
			draw_circle(p, 3.0 * k + 1.0, Color(1.0, 0.96, 0.82, 0.98 * k))
			draw_line(p, p + dir * 8.0, Color(1.0, 0.46, 0.10, 0.82 * k), 2.0)
		"sonic":
			for i in 3:
				draw_arc(p, 4.0 + float(i) * 4.0 + (1.0 - k) * 5.0, -0.9, 0.9, 10,
					Color(0.60, 0.98, 1.0, (0.70 - float(i) * 0.18) * k), 2.4 - float(i) * 0.5)
			draw_circle(p, 5.0 * k + 1.5, Color(0.70, 0.99, 1.0, 0.60 * k))
			draw_circle(p, 2.0, Color(1.0, 1.0, 1.0, 0.95 * k))
		"light":
			draw_circle(p, 4.5 * k + 1.5, Color(1.0, 0.62, 0.10, 0.85 * k))
			draw_circle(p, 2.0 * k + 1.0, Color(1.0, 1.0, 0.72, 0.98 * k))
			draw_line(p, p + dir * 6.0, Color(1.0, 0.94, 0.52, 0.95 * k), 1.6)
		_:
			draw_circle(p, 3.6 * k + 1.2, Color(1.0, 0.68, 0.20, 0.85 * k))
			draw_circle(p, 1.8 * k + 0.8, Color(1.0, 0.97, 0.72, 0.98 * k))
			draw_line(p, p + dir * 4.0, Color(1.0, 0.91, 0.52, 0.90 * k), 1.2)

## Keep the low-alpha motes inside the current camera view. Wrapping rather
## than spawning keeps the cost constant and leaves no pop when the camera pans.
func _advance_wind(delta: float) -> void:
	if wind.is_empty():
		return
	wind_clock += delta
	var rect := _wind_rect()
	for mote in wind:
		var v: Vector2 = mote["v"]
		var p: Vector2 = mote["p"] + v * delta
		p.y += sin(wind_clock * 0.8 + float(mote["ph"])) * 5.0 * delta
		if p.x < rect.position.x:
			p.x = rect.end.x
		elif p.x > rect.end.x:
			p.x = rect.position.x
		if p.y < rect.position.y:
			p.y = rect.end.y
		elif p.y > rect.end.y:
			p.y = rect.position.y
		mote["p"] = p

func _wind_rect() -> Rect2:
	var world := Rect2(Vector2.ZERO, Vector2(GameDefs.WORLD, GameDefs.WORLD))
	var vp := get_viewport()
	if vp == null:
		return world
	var rect: Rect2 = get_viewport_transform().affine_inverse() * vp.get_visible_rect()
	if rect.size.x < 8.0 or rect.size.y < 8.0:
		return world
	return rect.grow(80.0)

func _draw_wind() -> void:
	for mote in wind:
		var p: Vector2 = mote["p"]
		var a := float(mote["a"])
		var dir := Vector2.RIGHT.rotated(0.10 + sin(float(mote["ph"])) * 0.05)
		var length := 3.0 + a * 55.0
		draw_line(p, p - dir * length, Color(0.93, 0.85, 0.69, a), float(mote["r"]))

func _draw_impact(i: Dictionary) -> void:
	var k := clampf(1.0 - float(i["t"]) / float(i["life"]), 0.0, 1.0)
	var p: Vector2 = i["p"]
	var power := float(i["power"])
	match String(i["kind"]):
		"cannon":
			var r := (11.0 * (1.0 - k) + 5.0) * power
			draw_circle(p, r, Color(1.0, 0.39, 0.08, 0.72 * k))
			draw_circle(p, r * 0.58, Color(1.0, 0.82, 0.27, 0.90 * k))
			draw_circle(p + Vector2(-4.0, 2.0), r * 0.85, Color(0.40, 0.37, 0.33, 0.45 * k))
			draw_circle(p + Vector2(4.0, -3.0), r * 0.58, Color(0.55, 0.51, 0.45, 0.36 * k))
			draw_rect(Rect2(p - Vector2(2.0, 2.0), Vector2(4.0, 4.0)),
				Color(1.0, 0.95, 0.68, 0.75 * k))
		"artillery":
			# Heavy shell: white flash, wide fiery shock ring and a dark crater.
			var r := (26.0 * (1.0 - k) + 7.0) * power
			draw_circle(p, r, Color(1.0, 0.34, 0.05, 0.80 * k))
			draw_circle(p, r * 0.64, Color(1.0, 0.70, 0.18, 0.92 * k))
			draw_circle(p, r * 0.28, Color(1.0, 0.97, 0.78, 0.98 * k))
			for ring in 3:
				draw_arc(p, r * (1.20 + float(ring) * 0.34), 0.0, TAU, 30,
					Color(1.0, 0.66, 0.24, (0.42 - float(ring) * 0.11) * k), 3.0 - float(ring) * 0.7)
			for chunk in 4:
				var ca := TAU * float(chunk) / 4.0 + 0.7
				draw_circle(p + Vector2(cos(ca), sin(ca) * 0.7) * r * 0.9,
					r * 0.28, Color(0.22, 0.19, 0.16, 0.42 * k))
		"plasma":
			var r := (19.0 * (1.0 - k) + 6.0) * power
			draw_circle(p, r, Color(1.0, 0.24, 0.04, 0.82 * k))
			draw_circle(p, r * 0.62, Color(1.0, 0.62, 0.14, 0.94 * k))
			draw_circle(p, r * 0.30, Color(1.0, 0.98, 0.86, 0.98 * k))
			for ember in 5:
				var ea := TAU * float(ember) / 5.0 + float(ember) * 0.5
				draw_circle(p + Vector2(cos(ea), sin(ea)) * r * 1.25, 2.2 + 1.8 * k,
					Color(1.0, 0.55, 0.12, 0.55 * k))
			for halo in 2:
				draw_arc(p, r * (1.35 + float(halo) * 0.45), 0.0, TAU, 26,
					Color(1.0, 0.48, 0.10, (0.36 - float(halo) * 0.12) * k), 2.4)
		"rocket":
			var r := (14.0 * (1.0 - k) + 6.0) * power
			draw_circle(p, r, Color(1.0, 0.44, 0.09, 0.78 * k))
			draw_circle(p, r * 0.55, Color(1.0, 0.88, 0.40, 0.92 * k))
			draw_circle(p + Vector2(-5.0, 3.0), r * 0.82, Color(0.44, 0.41, 0.36, 0.50 * k))
			draw_circle(p + Vector2(5.0, -4.0), r * 0.56, Color(0.62, 0.58, 0.51, 0.38 * k))
		"gas":
			var r := (15.0 * (1.0 - k) + 6.0) * power
			draw_circle(p, r, Color(0.22, 0.74, 0.30, 0.34 * k))
			draw_circle(p, r * 0.72, Color(0.34, 0.88, 0.36, 0.34 * k))
			draw_circle(p, r * 0.40, Color(0.68, 1.0, 0.58, 0.46 * k))
			for puff in 5:
				var a := TAU * float(puff) / 5.0 + float(puff)
				draw_circle(p + Vector2(cos(a), sin(a)) * r * 0.8, 2.4 * k + 1.0,
					Color(0.36, 0.90, 0.44, 0.30 * k))
		"light", "rifle":
			draw_circle(p, 4.0 * k + 1.5, Color(0.72, 0.58, 0.36, 0.62 * k))
			draw_circle(p + Vector2(3.0, 1.0), 2.2 * k + 0.8, Color(0.82, 0.70, 0.48, 0.46 * k))
			draw_line(p, p + Vector2(3.0, -2.0), Color(1.0, 0.92, 0.55, 0.88 * k), 1.2)
