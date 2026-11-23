extends Control

## Interactive strategic map of Arrakis. Fifteen polygon provinces, a live
## front-line briefing, conquest progress and a short victory flip animation.
##
## Everything is drawn in local coordinates so the same screen works at
## 1280x720, 960x540 and wider phone viewports. Province polygons, clicks and
## owner colours all come from ArrakisMap / CampaignState.

const INK := Color(0.024, 0.031, 0.034)
const PANEL := Color(0.074, 0.062, 0.045)
const PANEL_DARK := Color(0.040, 0.035, 0.027)
const GOLD := Color(0.84, 0.68, 0.36)
const GOLD_DIM := Color(0.52, 0.41, 0.24)
const BONE := Color(0.92, 0.86, 0.72)
const DIM := Color(0.62, 0.57, 0.47)
const NEUTRAL := Color(0.58, 0.49, 0.34)
const DANGER := Color(0.94, 0.42, 0.26)
# Mobile readability palette: bright cream map labels, gold headings, bone body.
const CREAM := Color("F7E7C0")
const GOLD_TEXT := Color("FFD466")
const BODY := Color("F2E8D2")
const PANEL_BODY := Color("F2E8D2")

var state
var map_rect := Rect2(28, 88, 776, 558)
var panel_rect := Rect2(822, 88, 430, 558)
var progress_rect := Rect2(28, 662, 1224, 34)
var polygons: Dictionary = {}
var available: Array = []
var selected := 0
var clock := 0.0

var animating := false
var anim_t := 0.0
var pending: Dictionary = {}
var banner_timer := 0.0
var banner_text := ""
var victory_delay := 0.0
var victory_shown := false
var status := ""
var _launching := false

var deploy_button: TouchButton
var menu_button: TouchButton
var victory_overlay: Control
var victory_title: Label
var victory_body: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	state = GameDefs.campaign
	if state == null:
		return
	var owners: Dictionary = state.get("territory_owners")
	if not bool(state.get("campaign_active")) or owners.is_empty():
		# Prefer the saved war if one exists. Only open a fresh campaign when
		# there is no file to resume (e.g. a direct scene boot).
		if not bool(state.call("load_campaign")):
			state.call("new_campaign", String(state.get("player_house")))
	if not bool(state.get("active_mission").is_empty()):
		state.call("return_to_map")
	_build_ui()
	resized.connect(_layout)
	_layout()
	_refresh_front()
	var p: Dictionary = state.get("pending_conquest")
	if not p.is_empty():
		pending = p.duplicate(true)
		animating = true
		anim_t = 0.0
		banner_text = "%s SECURED" % ArrakisMap.short_name(String(pending.get("region", "")))
		banner_timer = 0.0
		if bool(pending.get("final", false)):
			victory_delay = 2.2
	if bool(state.get("campaign_complete")) and pending.is_empty():
		_show_victory()
	_update_deploy()
	set_process(true)

func _build_ui() -> void:
	deploy_button = TouchButton.new()
	deploy_button.text = "DEPLOY / LAUNCH MISSION"
	deploy_button.font_size = GameDefs.fs(16)
	deploy_button.primary = true
	deploy_button.accent = Factions.color(String(state.get("player_house")))
	deploy_button.pressed.connect(_deploy)
	add_child(deploy_button)

	menu_button = TouchButton.new()
	menu_button.text = "MAIN MENU"
	menu_button.font_size = GameDefs.fs(13)
	menu_button.pressed.connect(_main_menu)
	add_child(menu_button)

	victory_overlay = Control.new()
	victory_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	victory_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	victory_overlay.visible = false
	add_child(victory_overlay)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.018, 0.012, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	victory_overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	victory_overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)
	victory_title = Label.new()
	victory_title.text = "ARRAKIS CONQUERED"
	victory_title.add_theme_font_size_override("font_size", 48)
	victory_title.add_theme_color_override("font_color", Color(0.96, 0.82, 0.48))
	victory_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(victory_title)
	victory_body = Label.new()
	victory_body.add_theme_font_size_override("font_size", GameDefs.fs(18))
	victory_body.add_theme_color_override("font_color", BONE)
	victory_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	victory_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	victory_body.custom_minimum_size = Vector2(680.0, 0.0)
	box.add_child(victory_body)
	var title_button := TouchButton.new()
	title_button.text = "NEW CAMPAIGN"
	title_button.font_size = 17
	title_button.primary = true
	title_button.custom_minimum_size = Vector2(380.0, 54.0)
	title_button.pressed.connect(_back_to_title)
	box.add_child(title_button)
	var view_button := TouchButton.new()
	view_button.text = "VIEW ARRAKIS"
	view_button.font_size = 13
	view_button.custom_minimum_size = Vector2(380.0, 46.0)
	view_button.pressed.connect(_dismiss_victory)
	box.add_child(view_button)

func _layout() -> void:
	var w := size.x
	var h := size.y
	var margin := 28.0
	var panel_w := 430.0
	var header_h := 88.0
	var bottom_h := 86.0
	if w < 1120.0:
		panel_w = 380.0
		margin = 18.0
		header_h = 88.0
		bottom_h = 80.0
	var gap := 18.0
	var map_w := maxf(w - margin * 2.0 - panel_w - gap, 380.0)
	var content_h := maxf(h - header_h - bottom_h, 360.0)
	map_rect = Rect2(margin, header_h, map_w, content_h)
	panel_rect = Rect2(margin + map_w + gap, header_h, panel_w, content_h)
	progress_rect = Rect2(margin, h - bottom_h + 8.0, w - margin * 2.0, bottom_h - 16.0)
	polygons = ArrakisMap.polygons(map_rect)
	if deploy_button != null:
		deploy_button.position = Vector2(panel_rect.position.x + 18.0, panel_rect.end.y - 68.0)
		deploy_button.size = Vector2(panel_rect.size.x - 36.0, maxf(52.0, float(GameDefs.fs(16)) + 30.0))
	if menu_button != null:
		menu_button.position = Vector2(w - 196.0, 22.0)
		menu_button.size = Vector2(170.0, maxf(38.0, float(GameDefs.fs(13)) + 20.0))
	_update_deploy()
	queue_redraw()

func _refresh_front() -> void:
	available = state.call("available_missions")
	if available.is_empty():
		selected = 0
	else:
		selected = clampi(selected, 0, available.size() - 1)
	status = ""
	_update_deploy()

func _update_deploy() -> void:
	if deploy_button == null or state == null:
		return
	if animating:
		deploy_button.text = "SECURING PROVINCE"
		deploy_button.subtext = "front line redrawing"
		deploy_button.enabled = false
		deploy_button.queue_redraw()
		return
	if available.is_empty():
		deploy_button.text = "NO FRONT-LINE TARGET"
		deploy_button.subtext = "return after the next campaign victory"
		deploy_button.enabled = false
	else:
		var m: Dictionary = available[selected]
		deploy_button.enabled = true
		deploy_button.text = "DEPLOY / LAUNCH MISSION"
		deploy_button.subtext = "M%d · %s" % [int(m.get("tier", 1)), String(m.get("region_name", ""))]
		deploy_button.accent = Factions.color(String(m.get("enemy_house", "harkonnen")))
	deploy_button.queue_redraw()

func _process(delta: float) -> void:
	clock += delta
	if animating:
		anim_t = minf(1.0, anim_t + delta / 1.25)
		if anim_t >= 1.0:
			animating = false
			banner_timer = 2.3
			pending = {}
			state.call("clear_pending_conquest")
			_refresh_front()
			if bool(state.get("campaign_complete")) and not victory_shown:
				victory_delay = maxf(victory_delay, 1.3)
	if banner_timer > 0.0:
		banner_timer = maxf(0.0, banner_timer - delta)
	if victory_delay > 0.0:
		victory_delay = maxf(0.0, victory_delay - delta)
		if victory_delay <= 0.0 and not victory_shown:
			_show_victory()
	queue_redraw()

# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or _launching:
		return
	if animating or (victory_overlay != null and victory_overlay.visible):
		return
	match key.keycode:
		KEY_LEFT, KEY_UP:
			_step_front(-1)
		KEY_RIGHT, KEY_DOWN:
			_step_front(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_deploy()
		KEY_ESCAPE:
			_main_menu()
		_:
			return
	get_viewport().set_input_as_handled()

func _step_front(step: int) -> void:
	if available.is_empty():
		return
	selected = posmod(selected + step, available.size())
	status = ""
	_click()
	_update_deploy()
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if animating:
		return
	if victory_overlay != null and victory_overlay.visible:
		return
	var pressed := false
	var released := false
	var pos := Vector2.ZERO
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pressed = event.pressed
		released = not event.pressed
		pos = event.position
	elif event is InputEventScreenTouch and event.index == 0:
		pressed = event.pressed
		released = not event.pressed
		pos = event.position
	if not pressed and not released:
		return
	if pressed:
		var hit := _hit_front(pos)
		if hit >= 0:
			selected = hit
			status = ""
			_update_deploy()
			_click()
			accept_event()
		else:
			status = "Select a pulsing front-line province."
			queue_redraw()
			accept_event()

func _hit_front(pos: Vector2) -> int:
	if animating:
		return -1
	for i in available.size():
		var id := String(available[i].get("region", ""))
		if ArrakisMap.point_in(id, pos, polygons):
			return i
	return -1

func _click() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_ui"):
		audio.call("play_ui", "ui_click", -12.0)

func _deploy() -> void:
	if _launching or available.is_empty() or animating:
		return
	var m: Dictionary = available[selected]
	_launching = true
	state.call("begin_mission", m)
	_click()
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("stop_all"):
		audio.call("stop_all")
	get_tree().change_scene_to_file("res://scenes/mission_briefing.tscn")

func _main_menu() -> void:
	if _launching:
		return
	_launching = true
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("stop_all"):
		audio.call("stop_all")
	get_tree().change_scene_to_file("res://scenes/house_select.tscn")

func _back_to_title() -> void:
	if _launching:
		return
	_launching = true
	get_tree().change_scene_to_file("res://scenes/house_select.tscn")

func _dismiss_victory() -> void:
	if victory_overlay != null:
		victory_overlay.visible = false

func _show_victory() -> void:
	if victory_shown or victory_overlay == null:
		return
	victory_shown = true
	victory_overlay.visible = true
	var player := String(state.get("player_house"))
	victory_title.text = "ARRAKIS CONQUERED"
	victory_title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.44))
	victory_body.text = "%s controls all fifteen provinces. The spice, the cities and the Imperial Basin belong to your House." % Factions.display_name(player)
	victory_overlay.move_to_front()

# ------------------------------------------------------------------- drawing

func _draw() -> void:
	if state == null:
		return
	_draw_background()
	_draw_header()
	_draw_planet()
	_draw_provinces()
	_draw_front_lines()
	_draw_progress()
	_draw_panel()
	_draw_banner()

func _draw_background() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(0.0, 0.0, w, h), INK)
	for i in 24:
		var t := float(i) / 23.0
		var col := Color(0.025, 0.035, 0.040).lerp(Color(0.13, 0.082, 0.044), t * 0.55)
		draw_rect(Rect2(0.0, h * float(i) / 24.0, w, h / 24.0 + 1.0), col)
	for i in 110:
		var x := fmod(float(i) * 173.0 + 31.0, w)
		var y := fmod(float(i) * 79.0 + 47.0, h * 0.86)
		var a := 0.025 + 0.06 * absf(sin(float(i) * 1.37))
		draw_circle(Vector2(x, y), 0.7 + float(i % 3) * 0.4, Color(0.90, 0.78, 0.54, a))
	# Radar graticule behind the planet and panel.
	for x in range(0, int(w) + 1, 72):
		draw_line(Vector2(float(x), 0.0), Vector2(float(x), h), Color(0.62, 0.48, 0.28, 0.025), 1.0)
	for y in range(0, int(h) + 1, 72):
		draw_line(Vector2(0.0, float(y)), Vector2(w, float(y)), Color(0.62, 0.48, 0.28, 0.022), 1.0)

func _draw_header() -> void:
	var font := ThemeDB.fallback_font
	var house_name := Factions.display_name(String(state.get("player_house")))
	var small_fs := GameDefs.fs(12)
	draw_string(font, Vector2(28.0, 43.0), "ARRAKIS", HORIZONTAL_ALIGNMENT_LEFT, -1, 30,
		Color(0.96, 0.88, 0.68))
	draw_string(font, Vector2(30.0, 64.0), "WAR FOR THE PLANET", HORIZONTAL_ALIGNMENT_LEFT,
		-1, small_fs, GOLD_TEXT)
	var hc := Factions.color(String(state.get("player_house")))
	draw_rect(Rect2(28.0, 71.0, 160.0, 3.0), hc)
	draw_string(font, Vector2(208.0, 43.0), house_name.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, GameDefs.fs(13),
		Color(hc.r, hc.g, hc.b, 1.0))
	draw_string(font, Vector2(208.0, 62.0), "CAMPAIGN COMMAND", HORIZONTAL_ALIGNMENT_LEFT, -1, small_fs,
		Color(0.82, 0.74, 0.58))
	draw_line(Vector2(28.0, 82.0), Vector2(size.x - 28.0, 82.0), Color(0.60, 0.45, 0.24, 0.50), 1.0)

func _draw_planet() -> void:
	var c := map_rect.get_center()
	var rx := map_rect.size.x * 0.49
	var ry := map_rect.size.y * 0.49
	# Dust halo.
	draw_colored_polygon(_ellipse(c, rx * 1.035, ry * 1.035, 64), Color(0.72, 0.42, 0.16, 0.075))
	draw_colored_polygon(_ellipse(c, rx * 1.018, ry * 1.018, 64), Color(0.90, 0.64, 0.28, 0.07))
	draw_colored_polygon(_ellipse(c, rx, ry, 64), Color(0.245, 0.165, 0.088))
	# Broad dune bands, clipped visually by drawing slightly inside the disc.
	for i in 7:
		var k := 0.18 + float(i) * 0.11
		var col := Color(0.46, 0.30, 0.15, 0.12) if i % 2 == 0 else Color(0.12, 0.09, 0.055, 0.16)
		draw_polyline(_ellipse(c + Vector2(0.0, ry * (k - 0.5) * 0.3), rx * (1.0 - k * 0.18), ry * (1.0 - k * 0.18), 64), col, 6.0, true)
	# A few long dune ridges.
	for band in 4:
		var pts := PackedVector2Array()
		var yy := c.y - ry * 0.55 + float(band) * ry * 0.36
		for i in 33:
			var t := float(i) / 32.0
			var x := c.x - rx + t * rx * 2.0
			var wave := sin(t * 11.0 + float(band) * 1.7) * ry * 0.035 + sin(t * 23.0) * ry * 0.012
			pts.append(Vector2(x, yy + wave))
		draw_polyline(pts, Color(0.08, 0.045, 0.022, 0.20), 2.0, true)
	# Graticule.
	for r in [0.31, 0.685, 0.985]:
		draw_polyline(_ellipse(c, rx * r, ry * r, 72), Color(0.84, 0.65, 0.34, 0.11), 1.0, true)
	for i in 12:
		var a := -PI * 0.5 + float(i) * TAU / 12.0
		var p := c + Vector2(cos(a) * rx, sin(a) * ry)
		draw_line(c, p, Color(0.84, 0.65, 0.34, 0.07), 1.0)
	# Planet rim.
	draw_polyline(_ellipse(c, rx, ry, 72), Color(0.86, 0.66, 0.34, 0.55), 2.0, true)
	draw_polyline(_ellipse(c, rx * 1.006, ry * 1.006, 72), Color(0.08, 0.05, 0.025, 0.72), 3.0, true)

func _draw_provinces() -> void:
	var font := ThemeDB.fallback_font
	var owners: Dictionary = state.get("territory_owners")
	var player := String(state.get("player_house"))
	var selected_id := ""
	if not available.is_empty():
		selected_id = String(available[selected].get("region", ""))
	for id in ArrakisMap.ORDER:
		if not polygons.has(id):
			continue
		var poly: PackedVector2Array = polygons[id]
		var owner := String(owners.get(id, "neutral"))
		var col := _owner_color(owner)
		if animating and not pending.is_empty():
			if bool(pending.get("final", false)):
				var before: Dictionary = pending.get("before", {})
				var old := String(before.get(id, owner))
				col = _owner_color(old).lerp(_owner_color(String(pending.get("to", player))), anim_t)
			elif id == String(pending.get("region", "")):
				col = _owner_color(String(pending.get("from", owner))).lerp(_owner_color(String(pending.get("to", player))), anim_t)
		var fill := Color(col.r, col.g, col.b, 0.60)
		var is_front := _front_index(id) >= 0 and not animating
		if is_front:
			var pulse := 0.5 + 0.5 * absf(sin(clock * 3.0))
			fill = Color(col.lightened(0.10).r, col.lightened(0.10).g, col.lightened(0.10).b, 0.72 + 0.10 * pulse)
		if is_front and selected_id == id:
			fill = fill.lightened(0.10)
		draw_colored_polygon(poly, fill)
		draw_polyline(_closed(poly), Color(0.045, 0.035, 0.022, 0.92), 2.0, true)
		# Inner brass hairline makes the political borders read at a glance.
		draw_polyline(_closed(_shrink(poly, 0.985)), Color(0.86, 0.70, 0.40, 0.17), 1.0, true)
		if is_front:
			_draw_front_border(poly)
		if id == selected_id and is_front:
			draw_polyline(_closed(_shrink(poly, 0.975)), Color(1.0, 0.92, 0.60, 0.95), 3.0, true)
		_draw_region_label(id, poly, owner, font)

func _draw_region_label(id: String, poly: PackedVector2Array, owner: String, font: Font) -> void:
	var c := ArrakisMap.polygon_center(poly)
	var name := ArrakisMap.short_name(id)
	var name_fs := GameDefs.fs(12) if ArrakisMap.kind_of(id) == "center" else GameDefs.fs(13)
	var tag_fs := GameDefs.fs(11)
	var name_y := c.y - 6.0
	var shadow := Color(0.0, 0.0, 0.0, 0.75)
	# A 1 px black drop shadow keeps names legible over blue, red and green fills.
	draw_string(font, Vector2(c.x - 89.0, name_y + 1.0), name, HORIZONTAL_ALIGNMENT_CENTER,
		178.0, name_fs, shadow)
	draw_string(font, Vector2(c.x - 90.0, name_y), name, HORIZONTAL_ALIGNMENT_CENTER,
		180.0, name_fs, CREAM)
	var tag := "FREE"
	var tc := NEUTRAL.lightened(0.35)
	if owner != "neutral":
		tag = String(Factions.data(owner)["short"]).substr(0, 3)
		tc = Factions.color(owner).lightened(0.40)
	elif _front_index(id) >= 0:
		tag = "CONTESTED"
	var tag_y := name_y + float(tag_fs) + 5.0
	draw_string(font, Vector2(c.x - 79.0, tag_y + 1.0), tag, HORIZONTAL_ALIGNMENT_CENTER,
		158.0, tag_fs, shadow)
	draw_string(font, Vector2(c.x - 80.0, tag_y), tag, HORIZONTAL_ALIGNMENT_CENTER,
		160.0, tag_fs, tc)
	if _front_index(id) >= 0 and not animating:
		var pulse := 0.55 + 0.45 * absf(sin(clock * 4.0))
		var pill_w := 72.0
		var pill_h := float(tag_fs) + 8.0
		var pill := Rect2(c.x - pill_w * 0.5, tag_y + 5.0, pill_w, pill_h)
		draw_rect(pill, Color(0.10, 0.06, 0.025, 0.92))
		draw_rect(pill, Color(1.0, 0.80, 0.32, pulse), false, 1.2)
		draw_string(font, Vector2(pill.position.x, pill.position.y + pill_h - 6.0), "ATTACK",
			HORIZONTAL_ALIGNMENT_CENTER, pill_w, tag_fs, Color(1.0, 0.87, 0.48, pulse))

func _draw_front_border(poly: PackedVector2Array) -> void:
	var pulse := 0.55 + 0.45 * absf(sin(clock * 3.4))
	draw_polyline(_closed(poly), Color(1.0, 0.78, 0.26, 0.25 + 0.35 * pulse), 5.0, true)
	draw_polyline(_closed(poly), Color(1.0, 0.90, 0.50, 0.72 + 0.28 * pulse), 2.0, true)

func _draw_front_lines() -> void:
	if animating:
		return
	var owners: Dictionary = state.get("territory_owners")
	var player := String(state.get("player_house"))
	for i in available.size():
		var m: Dictionary = available[i]
		var id := String(m.get("region", ""))
		if not polygons.has(id):
			continue
		var target := ArrakisMap.polygon_center(polygons[id])
		var source := _nearest_player_center(target, player, owners)
		if source == Vector2(-1.0, -1.0):
			continue
		var pulse := 0.55 + 0.45 * absf(sin(clock * 4.0 + float(i)))
		_draw_dashed_arrow(source, target, Color(1.0, 0.80, 0.34, pulse))
		# Target reticle.
		draw_circle(target, 13.0 + 3.0 * pulse, Color(1.0, 0.84, 0.42, 0.14), false, 2.0)
		draw_circle(target, 4.0, Color(1.0, 0.88, 0.50, pulse))

func _draw_dashed_arrow(from: Vector2, to: Vector2, col: Color) -> void:
	var delta := to - from
	var length := delta.length()
	if length < 20.0:
		return
	var dir := delta / length
	var side := Vector2(-dir.y, dir.x)
	var dash := 11.0
	var gap := 7.0
	var step := dash + gap
	var offset := fmod(clock * 22.0, step)
	var pos := offset
	while pos < length - 22.0:
		var a := from + dir * pos
		var b := from + dir * minf(pos + dash, length - 18.0)
		draw_line(a, b, col, 2.0, true)
		pos += step
	var tip := from + dir * (length - 4.0)
	var base := tip - dir * 17.0
	draw_colored_polygon(PackedVector2Array([tip, base + side * 8.0, base - side * 8.0]), col)
	draw_circle(from, 4.0, col)

func _nearest_player_center(to: Vector2, player: String, owners: Dictionary) -> Vector2:
	var best := Vector2(-1.0, -1.0)
	var best_d := 1.0e9
	for id in ArrakisMap.ORDER:
		if String(owners.get(id, "neutral")) != player or not polygons.has(id):
			continue
		var c := ArrakisMap.polygon_center(polygons[id])
		var d := c.distance_squared_to(to)
		if d < best_d:
			best_d = d
			best = c
	return best

func _draw_progress() -> void:
	var font := ThemeDB.fallback_font
	var r := progress_rect
	var label_fs := GameDefs.fs(12)
	var bar_h := maxf(13.0, float(label_fs) + 2.0)
	draw_rect(Rect2(r.position - Vector2(0.0, float(label_fs) + 8.0), Vector2(r.size.x, float(label_fs) + 8.0)),
		Color(0.045, 0.036, 0.025, 0.88))
	draw_string(font, Vector2(r.position.x, r.position.y - 5.0), "PLANETARY CONTROL", HORIZONTAL_ALIGNMENT_LEFT,
		-1, label_fs, GOLD_TEXT)
	var counts := ArrakisMap.counts(state.get("territory_owners"))
	var total := float(ArrakisMap.ORDER.size())
	var x := r.position.x
	var bar_y := r.position.y + 9.0
	var order := [
		["atreides", Factions.color("atreides")],
		["harkonnen", Factions.color("harkonnen")],
		["ordos", Factions.color("ordos")],
		["neutral", NEUTRAL],
	]
	for entry in order:
		var key := String(entry[0])
		var col: Color = entry[1]
		var n := int(counts.get(key, 0))
		var w := r.size.x * float(n) / total
		if w > 0.0:
			draw_rect(Rect2(x, bar_y, w, bar_h), Color(col.r, col.g, col.b, 0.88))
			draw_rect(Rect2(x, bar_y, w, bar_h), Color(0.02, 0.02, 0.015, 0.55), false, 1.0)
			if w > 40.0:
				draw_string(font, Vector2(x + 3.0, bar_y + bar_h - 4.0), "%d" % n, HORIZONTAL_ALIGNMENT_LEFT,
					w - 6.0, label_fs, Color(0.05, 0.04, 0.03, 0.95))
		x += w
	draw_rect(Rect2(r.position.x, bar_y, r.size.x, bar_h), Color(0.82, 0.66, 0.36, 0.45), false, 1.0)
	# Percentage legend on the right of the bar label line.
	var labels := [
		["ATREIDES", counts.get("atreides", 0), Factions.color("atreides")],
		["HARKONNEN", counts.get("harkonnen", 0), Factions.color("harkonnen")],
		["ORDOS", counts.get("ordos", 0), Factions.color("ordos")],
		["UNCLAIMED", counts.get("neutral", 0), NEUTRAL],
	]
	var lx := r.position.x + 190.0
	for entry in labels:
		var txt := "%s %d%%" % [String(entry[0]), int(round(100.0 * float(entry[1]) / total))]
		var col: Color = entry[2]
		var swatch := float(label_fs) - 4.0
		draw_rect(Rect2(lx - swatch - 4.0, r.position.y - swatch - 2.0, swatch, swatch), col)
		draw_string(font, Vector2(lx, r.position.y - 5.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, label_fs,
			CREAM)
		lx += font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, label_fs).x + 22.0

func _draw_panel() -> void:
	var r := panel_rect
	var font := ThemeDB.fallback_font
	draw_rect(r, PANEL)
	for i in 16:
		var t := float(i) / 15.0
		draw_rect(Rect2(r.position.x, r.position.y + r.size.y * t / 16.0, r.size.x, r.size.y / 16.0 + 1.0),
			PANEL.lerp(PANEL_DARK, t * 0.55))
	draw_rect(Rect2(r.position + Vector2(0.5, 0.5), r.size - Vector2(1.0, 1.0)), Color(0.02, 0.018, 0.012, 0.92), false, 3.0)
	draw_rect(Rect2(r.position + Vector2(4.0, 4.0), r.size - Vector2(8.0, 8.0)), Color(0.62, 0.46, 0.24, 0.52), false, 1.0)
	draw_rect(Rect2(r.position + Vector2(9.0, 9.0), r.size - Vector2(18.0, 18.0)), Color(0.38, 0.27, 0.15, 0.24), false, 1.0)
	var x := r.position.x + 20.0
	var width := r.size.x - 40.0
	var head_fs := GameDefs.fs(12)
	var body_fs := GameDefs.fs(15)
	var detail_fs := GameDefs.fs(12)
	var title_fs := GameDefs.fs(22)
	var y := r.position.y + 24.0
	draw_string(font, Vector2(x, y + float(head_fs)), "MISSION BRIEFING", HORIZONTAL_ALIGNMENT_LEFT, -1,
		head_fs, GOLD_TEXT)
	y += float(head_fs) + 8.0
	draw_line(Vector2(x, y), Vector2(x + width, y), Color(0.62, 0.46, 0.24, 0.40), 1.0)
	y += 12.0
	# Every block advances from the measured text height, and drawing stops above
	# the deploy button, so scaled phone fonts can never collide with it.
	var bottom_limit := r.end.y - 76.0
	if status != "":
		bottom_limit -= float(detail_fs) + 8.0
	if available.is_empty():
		draw_string(font, Vector2(x, y + float(title_fs)), "FRONTIER SECURED", HORIZONTAL_ALIGNMENT_LEFT,
			width, title_fs, BONE)
		y += float(title_fs) + 8.0
		var finished := "No further enemy province is adjacent to your territory. The campaign is complete."
		_draw_wrapped(font, Vector2(x, y), finished, width, body_fs, DIM,
			_fit_lines(font, finished, width, body_fs, 4, bottom_limit - y))
		return
	var m: Dictionary = available[selected]
	var tier := int(m.get("tier", 1))
	var house := String(m.get("enemy_house", "harkonnen"))
	var hc := Factions.color(house)
	draw_string(font, Vector2(x, y + float(head_fs)), "MISSION %d / %d" % [tier, CampaignMissions.TIER_COUNT],
		HORIZONTAL_ALIGNMENT_LEFT, width, head_fs, Color(0.92, 0.76, 0.42))
	y += float(head_fs) + 10.0
	draw_string(font, Vector2(x, y + float(title_fs)), String(m.get("region_name", "Unknown Province")).to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, width, title_fs, BONE)
	y += float(title_fs) + 6.0
	draw_rect(Rect2(x, y, 26.0, 4.0), hc)
	y += 12.0
	draw_string(font, Vector2(x, y + float(head_fs)),
		"ENEMY  ·  %s" % String(m.get("enemy_name", Factions.display_name(house))).to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, width, head_fs, Color(hc.r, hc.g, hc.b, 1.0))
	y += float(head_fs) + 8.0
	draw_string(font, Vector2(x, y + float(head_fs)), String(m.get("title", "OPERATION")).to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, width, head_fs, CREAM)
	y += float(head_fs) + 9.0
	draw_line(Vector2(x, y), Vector2(x + width, y), Color(0.58, 0.43, 0.24, 0.35), 1.0)
	y += 12.0
	draw_string(font, Vector2(x, y + float(head_fs)), "OBJECTIVE", HORIZONTAL_ALIGNMENT_LEFT, -1,
		head_fs, GOLD_TEXT)
	y += float(head_fs) + 7.0
	var objective := String(m.get("objective_text", ""))
	y += _draw_wrapped(font, Vector2(x, y), objective, width, body_fs, PANEL_BODY,
		_fit_lines(font, objective, width, body_fs, 4, bottom_limit - y)) + 12.0
	draw_string(font, Vector2(x, y + float(head_fs)), "NEW TECHNOLOGY", HORIZONTAL_ALIGNMENT_LEFT, -1,
		head_fs, GOLD_TEXT)
	y += float(head_fs) + 7.0
	var unlock := String(m.get("unlock_text", ""))
	y += _draw_wrapped(font, Vector2(x, y), unlock, width, body_fs, PANEL_BODY,
		_fit_lines(font, unlock, width, body_fs, 3, bottom_limit - y)) + 12.0
	draw_line(Vector2(x, y), Vector2(x + width, y), Color(0.58, 0.43, 0.24, 0.35), 1.0)
	y += 11.0
	draw_string(font, Vector2(x, y + float(head_fs)), "BATTLEFIELD", HORIZONTAL_ALIGNMENT_LEFT, -1,
		head_fs, GOLD_TEXT)
	y += float(head_fs) + 8.0
	var ai: Dictionary = m.get("ai", {})
	var details := "MAP %d × %d   ·   SEED %d   ·   %d CR" % [
		int(m.get("map_size", 56)), int(m.get("map_size", 56)), int(m.get("map_seed", 0)),
		int(m.get("starting_credits", 2000)),
	]
	draw_string(font, Vector2(x, y + float(detail_fs)), details, HORIZONTAL_ALIGNMENT_LEFT, width,
		detail_fs, BODY)
	y += float(detail_fs) + 5.0
	var threat := "ENEMY AGGRESSION %d%%   ·   ARMY CAP %d" % [
		int(round(100.0 * float(ai.get("aggression", 1.0)))), int(ai.get("army_cap", 16)),
	]
	draw_string(font, Vector2(x, y + float(detail_fs)), threat, HORIZONTAL_ALIGNMENT_LEFT, width,
		detail_fs, BODY)
	y += float(detail_fs) + 7.0
	var brief := String(m.get("brief", ""))
	_draw_wrapped(font, Vector2(x, y), brief, width, detail_fs, Color(0.90, 0.86, 0.76),
		_fit_lines(font, brief, width, detail_fs, 3, bottom_limit - y))
	if status != "":
		draw_string(font, Vector2(x, r.end.y - 82.0), status, HORIZONTAL_ALIGNMENT_LEFT, width,
			detail_fs, DANGER)

## Draws word-wrapped text and returns the height it consumed. A line count of
## zero means there was no room, so nothing is drawn.
func _draw_wrapped(font: Font, pos: Vector2, text: String, width: float, font_size: int, color: Color, lines: int) -> float:
	if lines <= 0 or text.strip_edges() == "":
		return 0.0
	var shown := GameDefs.fit_text(font, text, width, font_size, lines)
	var measured := font.get_multiline_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, lines)
	draw_multiline_string(font, Vector2(pos.x, pos.y + float(font_size)), shown, HORIZONTAL_ALIGNMENT_LEFT,
		width, font_size, lines, color)
	return measured.y

## Largest line count (1..max_lines) whose measured height still fits the room.
func _fit_lines(font: Font, text: String, width: float, font_size: int, max_lines: int, room: float) -> int:
	if text.strip_edges() == "":
		return 0
	for lines in range(max_lines, 0, -1):
		if font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, lines).y <= room:
			return lines
	return 0

func _draw_banner() -> void:
	if banner_timer <= 0.0:
		return
	var font := ThemeDB.fallback_font
	var a := clampf(banner_timer / 0.4, 0.0, 1.0)
	var banner_fs := GameDefs.fs(16)
	var w := minf(560.0, map_rect.size.x - 40.0)
	var bh := float(banner_fs) + 24.0
	var r := Rect2(map_rect.get_center().x - w * 0.5, map_rect.position.y + 18.0, w, bh)
	draw_rect(r, Color(0.06, 0.045, 0.025, 0.90))
	draw_rect(r, Color(1.0, 0.80, 0.38, 0.62 * a), false, 1.2)
	var baseline := r.position.y + (bh + font.get_ascent(banner_fs) - font.get_descent(banner_fs)) * 0.5
	draw_string(font, Vector2(r.position.x, baseline), banner_text, HORIZONTAL_ALIGNMENT_CENTER,
		w, banner_fs, Color(1.0, 0.90, 0.62, a))
	if animating:
		var c := ArrakisMap.polygon_center(polygons.get(String(pending.get("region", "")), PackedVector2Array()))
		for i in 2:
			var rad := 16.0 + anim_t * (60.0 + float(i) * 28.0)
			draw_circle(c, rad, Color(1.0, 0.82, 0.36, (1.0 - anim_t) * 0.35), false, 2.0)

# ------------------------------------------------------------------ helpers

func _owner_color(owner: String) -> Color:
	if owner == "neutral" or owner == "":
		return NEUTRAL
	return Factions.color(owner)

func _front_index(id: String) -> int:
	for i in available.size():
		if String(available[i].get("region", "")) == id:
			return i
	return -1

func _ellipse(c: Vector2, rx: float, ry: float, count := 48) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in count:
		var a := float(i) * TAU / float(count)
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts

func _closed(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(poly)
	if out.size() > 0:
		out.append(out[0])
	return out

func _shrink(poly: PackedVector2Array, factor: float) -> PackedVector2Array:
	var c := ArrakisMap.polygon_center(poly)
	var out := PackedVector2Array()
	for p in poly:
		out.append(c + (p - c) * factor)
	return out
