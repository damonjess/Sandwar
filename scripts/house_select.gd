extends Control

## Dune 2000 style House Selection / main menu.
##
## Three full-height banner cards, drawn procedurally so the screen ships
## without new texture assets. Every card accepts a mouse click or a phone tap;
## picking a House stores it in CampaignState and launches the battle.

const GOLD := Color(0.84, 0.68, 0.36)
const GOLD_DIM := Color(0.55, 0.44, 0.26)
const BONE := Color(0.90, 0.85, 0.74)
const DIM := Color(0.60, 0.56, 0.48)
const INK := Color(0.035, 0.040, 0.040)

var _launching := false
var _selected_house := Factions.ATREIDES
var _cards: Array = []
var _new_button: TouchButton
var _continue_button: TouchButton
var _skirmish_button: TouchButton
var _graphics_button: TouchButton
var _status_label: Label
var _actions: Array = []
var _action_focus := 0
var _keyboard_nav := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	var state = GameDefs.campaign
	if state != null and bool(state.call("has_campaign_save")):
		# A quick skirmish may have changed the in-memory House. Reload the
		# saved war so Continue and its summary always describe the real file.
		state.call("load_campaign")
	if state != null and Factions.exists(String(state.get("player_house"))):
		_selected_house = String(state.get("player_house"))
	_build()
	_update_actions()
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_menu_music"):
		audio.call("play_menu_music")

func _build() -> void:
	var backdrop := Backdrop.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var cards := HBoxContainer.new()
	cards.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cards.offset_left = 38.0
	cards.offset_right = -38.0
	cards.offset_top = 130.0
	cards.offset_bottom = -176.0
	cards.add_theme_constant_override("separation", 20)
	cards.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(cards)
	_cards.clear()
	for house in Factions.HOUSE_ORDER:
		var card := HouseCard.new()
		card.house = house
		card.current_house = _selected_house == house
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size = Vector2(280.0, 390.0)
		card.chosen.connect(_select_card)
		cards.add_child(card)
		_cards.append(card)

	_status_label = Label.new()
	_status_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status_label.offset_left = 180.0
	_status_label.offset_right = -180.0
	_status_label.offset_top = -170.0
	_status_label.offset_bottom = -146.0
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", GameDefs.fs(13))
	_status_label.add_theme_color_override("font_color", Color(0.90, 0.80, 0.58, 0.96))
	add_child(_status_label)

	var actions := HBoxContainer.new()
	actions.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	actions.offset_left = 180.0
	actions.offset_right = -180.0
	actions.offset_top = -142.0
	actions.offset_bottom = -76.0
	actions.add_theme_constant_override("separation", 18)
	actions.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(actions)

	_new_button = TouchButton.new()
	_new_button.text = "NEW CAMPAIGN"
	_new_button.subtext = "7 missions · conquer Arrakis"
	_new_button.font_size = GameDefs.fs(15)
	_new_button.primary = true
	_new_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_button.custom_minimum_size = Vector2(260.0, 62.0)
	_new_button.pressed.connect(_new_campaign)
	actions.add_child(_new_button)

	_continue_button = TouchButton.new()
	_continue_button.text = "CONTINUE CAMPAIGN"
	_continue_button.font_size = GameDefs.fs(15)
	_continue_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_continue_button.custom_minimum_size = Vector2(260.0, 62.0)
	_continue_button.pressed.connect(_continue_campaign)
	actions.add_child(_continue_button)

	_skirmish_button = TouchButton.new()
	_skirmish_button.text = "QUICK SKIRMISH"
	_skirmish_button.subtext = "max tech · random opponent"
	_skirmish_button.font_size = GameDefs.fs(15)
	_skirmish_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skirmish_button.custom_minimum_size = Vector2(260.0, 62.0)
	_skirmish_button.pressed.connect(_quick_skirmish)
	actions.add_child(_skirmish_button)
	_actions = [_new_button, _continue_button, _skirmish_button]

	# Title, footer and corner brackets live on a top layer: a parent Control
	# draws before its children, so drawing them on the root would put them
	# behind the backdrop and the cards.
	var chrome := Chrome.new()
	chrome.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(chrome)

	# The presentation switch belongs to the player's shared settings, so it is
	# available before a campaign or skirmish starts as well as inside battle.
	_graphics_button = TouchButton.new()
	_graphics_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_graphics_button.offset_left = -242.0
	_graphics_button.offset_right = -22.0
	_graphics_button.offset_top = 16.0
	_graphics_button.offset_bottom = 74.0
	_graphics_button.font_size = GameDefs.fs(13)
	_graphics_button.tooltip_text = "Switch the live battlefield between Classic 2D and Modern 3D"
	_graphics_button.pressed.connect(_toggle_graphics)
	add_child(_graphics_button)
	_update_graphics_button()

func _update_graphics_button() -> void:
	if _graphics_button == null:
		return
	var state = GameDefs.campaign
	var modern := state != null and bool(state.call("is_modern_3d"))
	_graphics_button.text = "GRAPHICS: %s" % ("MODERN 3D" if modern else "CLASSIC 2D")
	_graphics_button.subtext = "tap to switch renderer"
	_graphics_button.queue_redraw()

func _toggle_graphics() -> void:
	var state = GameDefs.campaign
	if state == null:
		return
	state.call("toggle_graphics_mode")
	_update_graphics_button()
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_ui"):
		audio.call("play_ui", "ui_click", -10.0)

func _unhandled_input(event: InputEvent) -> void:
	if _launching or not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	var handled := true
	match key.keycode:
		KEY_LEFT:
			_cycle_house(-1)
		KEY_RIGHT:
			_cycle_house(1)
		KEY_UP:
			_cycle_action(-1)
		KEY_DOWN:
			_cycle_action(1)
		KEY_TAB:
			_cycle_action(-1 if key.shift_pressed else 1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_activate_action()
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()

func _cycle_house(step: int) -> void:
	var order: Array = Factions.HOUSE_ORDER
	if order.is_empty():
		return
	var index := order.find(_selected_house)
	index = posmod(index + step, order.size())
	_select_card(String(order[index]))
	_show_keyboard_focus()

func _cycle_action(step: int) -> void:
	if _actions.is_empty():
		return
	for offset in range(1, _actions.size() + 1):
		var index := posmod(_action_focus + step * offset, _actions.size())
		var action = _actions[index]
		if action != null and action.enabled:
			_action_focus = index
			break
	_show_keyboard_focus()

func _show_keyboard_focus() -> void:
	_keyboard_nav = true
	for index in _actions.size():
		var action = _actions[index]
		if action != null:
			action.keyboard_focused = index == _action_focus

func _activate_action() -> void:
	if _actions.is_empty():
		return
	var action = _actions[_action_focus]
	if action == null:
		return
	if not action.enabled:
		_cycle_action(1)
		return
	action.pressed.emit()

func _select_card(house: String) -> void:
	if _launching or not Factions.exists(house):
		return
	_selected_house = house
	for card in _cards:
		if is_instance_valid(card):
			card.current_house = card.house == house
			card.queue_redraw()
	_update_actions()
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_ui"):
		audio.call("play_ui", "ui_click", -12.0)

func _update_actions() -> void:
	if _continue_button == null:
		return
	var state = GameDefs.campaign
	var has_save := state != null and bool(state.call("has_campaign_save"))
	_continue_button.enabled = has_save
	if not has_save and _action_focus == 1:
		_action_focus = 0
	if _keyboard_nav:
		_show_keyboard_focus()
	if has_save and state != null:
		var summary := String(state.call("campaign_summary"))
		_status_label.text = summary
		if bool(state.get("campaign_complete")):
			_continue_button.subtext = "planet conquered"
		else:
			var tier := int(state.get("mission_tier"))
			_continue_button.subtext = "mission %d / %d" % [mini(tier + 1, CampaignMissions.TIER_COUNT), CampaignMissions.TIER_COUNT]
	else:
		_status_label.text = "NO CAMPAIGN SAVE · SELECT A HOUSE AND BEGIN"
		_continue_button.subtext = "no saved campaign"
	_continue_button.queue_redraw()

func _play_launch() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_ui"):
		audio.call("play_ui", "build_ready", -5.0)

func _new_campaign() -> void:
	if _launching:
		return
	var state = GameDefs.campaign
	if state == null:
		return
	_launching = true
	state.call("new_campaign", _selected_house)
	_play_launch()
	get_tree().change_scene_to_file("res://scenes/campaign_map.tscn")

func _continue_campaign() -> void:
	if _launching:
		return
	var state = GameDefs.campaign
	if state == null:
		return
	if not bool(state.call("load_campaign")):
		_launching = false
		_update_actions()
		return
	_launching = true
	_play_launch()
	get_tree().change_scene_to_file("res://scenes/campaign_map.tscn")

func _quick_skirmish() -> void:
	if _launching:
		return
	var state = GameDefs.campaign
	if state == null:
		return
	_launching = true
	state.call("start_quick_skirmish", _selected_house)
	_play_launch()
	get_tree().change_scene_to_file("res://main.tscn")

## Title, footer and briefing brackets, drawn above the cards.
class Chrome:
	extends Control

	func _draw() -> void:
		var w := size.x
		var font := ThemeDB.fallback_font
		var title_y := 76.0
		# Letter-spaced title built by hand so it does not depend on font
		# features that the fallback font may not expose.
		var title := "S A N D W A R"
		draw_string(font, Vector2(0.0, title_y), title, HORIZONTAL_ALIGNMENT_CENTER, w, 42,
			Color(0.94, 0.84, 0.63))
		draw_string(font, Vector2(0.0, title_y + 26.0), "CHOOSE YOUR HOUSE", HORIZONTAL_ALIGNMENT_CENTER, w,
			GameDefs.fs(14), Color(0.94, 0.80, 0.48))
		draw_line(Vector2(w * 0.5 - 250.0, title_y + 38.0), Vector2(w * 0.5 + 250.0, title_y + 38.0),
			Color(0.62, 0.46, 0.22, 0.55), 1.0)
		draw_line(Vector2(w * 0.5 - 130.0, title_y + 41.0), Vector2(w * 0.5 + 130.0, title_y + 41.0),
			Color(0.26, 0.19, 0.11, 0.7), 1.0)

		var foot_y := size.y - 40.0
		draw_string(font, Vector2(0.0, foot_y), "ARROWS: HOUSE / ACTION   ·   ENTER: CONFIRM   ·   MOUSE / TOUCH", HORIZONTAL_ALIGNMENT_CENTER, w, GameDefs.fs(13),
			Color(0.94, 0.82, 0.56, 0.96))
		draw_string(font, Vector2(0.0, foot_y + 21.0), "Campaign progress auto-saves on every victory · Skirmish uses maximum tech",
			HORIZONTAL_ALIGNMENT_CENTER, w, GameDefs.fs(13), Color(0.78, 0.72, 0.60, 0.96))
		# Small brass corner brackets keep the screen framed like a Dune briefing.
		var margin := 18.0
		for corner in [Vector2(margin, margin), Vector2(w - margin, margin),
				Vector2(margin, size.y - margin), Vector2(w - margin, size.y - margin)]:
			var sx := 1.0 if corner.x < w * 0.5 else -1.0
			var sy := 1.0 if corner.y < size.y * 0.5 else -1.0
			draw_line(corner, corner + Vector2(28.0 * sx, 0.0), Color(GOLD_DIM.r, GOLD_DIM.g, GOLD_DIM.b, 0.55), 1.0)
			draw_line(corner, corner + Vector2(0.0, 28.0 * sy), Color(GOLD_DIM.r, GOLD_DIM.g, GOLD_DIM.b, 0.55), 1.0)


## Dark desert-night plate: metal-blue top, dust horizon, dune silhouettes.
class Backdrop:
	extends Control

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var top := Color(0.035, 0.045, 0.050)
		var mid := Color(0.095, 0.080, 0.062)
		var low := Color(0.145, 0.095, 0.055)
		var bands := 40
		for i in bands:
			var t := float(i) / float(bands - 1)
			var col: Color
			if t < 0.55:
				col = top.lerp(mid, t / 0.55)
			else:
				col = mid.lerp(low, (t - 0.55) / 0.45)
			draw_rect(Rect2(0.0, h * float(i) / float(bands), w, h / float(bands) + 1.0), col)
		# Low sun behind the cards, wide and dusty.
		draw_circle(Vector2(w * 0.50, h * 0.30), h * 0.44, Color(0.72, 0.38, 0.12, 0.055))
		draw_circle(Vector2(w * 0.50, h * 0.30), h * 0.26, Color(0.86, 0.50, 0.18, 0.040))
		# Faint structural grid, like a hangar wall behind the banners.
		for x in range(0, int(w) + 1, 64):
			draw_line(Vector2(float(x), 0.0), Vector2(float(x), h),
				Color(0.55, 0.42, 0.24, 0.028), 1.0)
		for y in range(0, int(h) + 1, 64):
			draw_line(Vector2(0.0, float(y)), Vector2(w, float(y)),
				Color(0.55, 0.42, 0.24, 0.026), 1.0)
		# Two dune ridges at the foot.
		var ridge := PackedVector2Array([Vector2(0.0, h * 0.80)])
		for i in 13:
			var x := w * float(i) / 12.0
			ridge.append(Vector2(x, h * 0.80 - sin(float(i) * 0.83 + 0.6) * h * 0.055 - cos(float(i) * 0.47) * h * 0.02))
		ridge.append(Vector2(w, h))
		ridge.append(Vector2(0.0, h))
		draw_colored_polygon(ridge, Color(0.090, 0.058, 0.036))
		var ridge2 := PackedVector2Array([Vector2(0.0, h * 0.90)])
		for i in 17:
			var x := w * float(i) / 16.0
			ridge2.append(Vector2(x, h * 0.90 - sin(float(i) * 0.61 + 2.1) * h * 0.040))
		ridge2.append(Vector2(w, h))
		ridge2.append(Vector2(0.0, h))
		draw_colored_polygon(ridge2, Color(0.060, 0.039, 0.026))
		# Dust motes.
		for i in 70:
			var px := fmod(float(i) * 197.0 + 31.0, w)
			var py := fmod(float(i) * 83.0 + 47.0, h * 0.78)
			var a := 0.025 + 0.035 * absf(sin(float(i) * 1.7))
			draw_circle(Vector2(px, py), 1.0 + float(i % 3) * 0.4, Color(0.88, 0.70, 0.42, a))
		# Vignette.
		draw_rect(Rect2(0.0, 0.0, w, 90.0), Color(0.0, 0.0, 0.0, 0.28))
		draw_rect(Rect2(0.0, h - 110.0, w, 110.0), Color(0.0, 0.0, 0.0, 0.32))


## One House banner. Drawn entirely in _draw so it scales cleanly at 1280x720,
## 960x540 and phone aspect ratios.
class HouseCard:
	extends Control

	signal chosen(house: String)

	var house := Factions.ATREIDES
	var current_house := false
	var hovered := false
	var pressing := false
	var _press_pos := Vector2.ZERO
	var _clock := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		set_process(true)

	func _process(delta: float) -> void:
		_clock += delta
		if current_house or hovered or pressing:
			queue_redraw()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			hovered = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			hovered = false
			queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				pressing = true
				_press_pos = event.position
				accept_event()
			else:
				var tap: bool = pressing and event.position.distance_to(_press_pos) <= 18.0
				pressing = false
				queue_redraw()
				if tap:
					accept_event()
					chosen.emit(house)
			return
		if event is InputEventScreenTouch:
			if event.index > 0:
				return
			if event.pressed:
				pressing = true
				_press_pos = event.position
				accept_event()
			else:
				var tap: bool = pressing and event.position.distance_to(_press_pos) <= 24.0
				pressing = false
				queue_redraw()
				if tap:
					accept_event()
					chosen.emit(house)

	func _draw() -> void:
		var data: Dictionary = Factions.data(house)
		var col: Color = data["color"]
		var w := size.x
		var h := size.y
		var rect := Rect2(Vector2(1.0, 1.0), size - Vector2(2.0, 2.0))
		var font := ThemeDB.fallback_font
		var lift := 3.0 if pressing else (2.0 if hovered else 0.0)

		# Panel body: near-black steel with a warm dust wash at the foot.
		var top := Color(0.055, 0.058, 0.055)
		var bottom := Color(0.135, 0.088, 0.050)
		for i in 20:
			var t := float(i) / 19.0
			draw_rect(Rect2(0.0, h * float(i) / 20.0, w, h / 20.0 + 1.0), top.lerp(bottom, t))
		# House colour bleeds down from the top edge.
		for i in 8:
			var a := 0.18 * (1.0 - float(i) / 8.0)
			draw_rect(Rect2(0.0, float(i) * 3.0, w, 3.0), Color(col.r, col.g, col.b, a))
		draw_rect(Rect2(0.0, 0.0, w, 4.0), col)
		# Metal sheen and a structural line behind the emblem.
		draw_line(Vector2(18.0, 118.0), Vector2(w - 18.0, 118.0), Color(0.52, 0.39, 0.21, 0.35), 1.0)
		draw_line(Vector2(18.0, 121.0), Vector2(w - 18.0, 121.0), Color(0.03, 0.03, 0.03, 0.55), 1.0)
		# Frame: brass outer, house-colour inner hairline.
		draw_rect(Rect2(Vector2(0.5, 0.5), size - Vector2(1.0, 1.0)), Color(0.03, 0.025, 0.018, 0.9), false, 3.0)
		var border := Color(0.52, 0.39, 0.21, 0.85) if not hovered else Color(0.86, 0.70, 0.38, 1.0)
		draw_rect(rect, border, false, 1.6)
		draw_rect(rect.grow(-5.0), Color(col.r, col.g, col.b, 0.34), false, 1.0)
		# Corner rivets.
		for p in [Vector2(10.0, 10.0), Vector2(w - 10.0, 10.0), Vector2(10.0, h - 10.0), Vector2(w - 10.0, h - 10.0)]:
			draw_circle(p, 2.6, Color(0.62, 0.48, 0.26))
			draw_circle(p - Vector2(0.5, 0.6), 1.0, Color(0.96, 0.86, 0.62))

		# Emblem and identity block, sized from the card height so the enlarged
		# mobile text blocks still fit above the roster.
		var emblem_r := minf(w * 0.125, minf(32.0, h * 0.085))
		var emblem_c := Vector2(w * 0.5, emblem_r + 22.0 - lift)
		draw_circle(emblem_c, emblem_r + 8.0, Color(0.025, 0.025, 0.023, 0.9))
		draw_arc(emblem_c, emblem_r + 8.0, 0.0, TAU, 48, Color(0.58, 0.45, 0.25, 0.8), 1.4)
		draw_circle(emblem_c, emblem_r, Color(col.r * 0.10 + 0.02, col.g * 0.10 + 0.02, col.b * 0.10 + 0.02))
		var glow := (0.10 + 0.05 * absf(sin(_clock * 1.4))) if current_house else 0.0
		draw_circle(emblem_c, emblem_r - 2.0, Color(col.r, col.g, col.b, 0.10 + glow))
		_draw_emblem(emblem_c, emblem_r * 0.82, col)

		# Name and identity.
		var name_fs := 24
		var style_fs := GameDefs.fs(12)
		var summary_fs := GameDefs.fs(14)
		var roster_fs := GameDefs.fs(13)
		var tag_fs := GameDefs.fs(12)
		var name_y := emblem_c.y + emblem_r + 22.0 - lift
		draw_string(font, Vector2(0.0, name_y), String(data["short"]), HORIZONTAL_ALIGNMENT_CENTER, w, name_fs,
			Color(0.97, 0.92, 0.80))
		draw_string(font, Vector2(0.0, name_y + float(style_fs) + 8.0), String(data["style"]).to_upper(),
			HORIZONTAL_ALIGNMENT_CENTER, w, style_fs, Color(0.92, 0.78, 0.46))
		# Colour chip and exact hex.
		var chip_w := 34.0
		var chip_y := name_y + float(style_fs) + 22.0
		var chip_c := Vector2(w * 0.5 - 38.0, chip_y)
		draw_rect(Rect2(chip_c - Vector2(chip_w * 0.5, 5.0), Vector2(chip_w, 10.0)),
			Color(col.r, col.g, col.b, 0.95))
		draw_rect(Rect2(chip_c - Vector2(chip_w * 0.5, 5.0), Vector2(chip_w, 10.0)),
			Color(0.02, 0.02, 0.02, 0.8), false, 1.0)
		draw_string(font, Vector2(w * 0.5 - 13.0, chip_y + 4.0), String(data["hex"]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, style_fs, Color(0.80, 0.75, 0.64))

		# Bottom-up roster and doctrine anchors, so no line can drift into another
		# on a short phone card or a wide 16:9 desktop card.
		var roster: Array = data["signature"]
		var roster_line := float(roster_fs) + 3.0
		var tag_y := h - 14.0
		var tag := "SELECTED HOUSE" if current_house else "TAP TO SELECT"
		var tag_col := Color(0.98, 0.82, 0.42, 0.96) if current_house else Color(0.76, 0.72, 0.62, 0.94)
		var roster_last := tag_y - float(tag_fs) - 16.0
		var roster_first := roster_last - roster_line * float(maxi(roster.size() - 1, 0))
		var roster_head := roster_first - float(roster_fs) - 8.0
		var divider_y := roster_head - 12.0
		var doctrine_y := divider_y - 12.0

		# Tactical brief fills whatever sits between the identity block and the
		# doctrine line; the measured line count prevents any collision.
		var summary_top := chip_y + float(style_fs) + 12.0
		var summary_text := String(data["summary"])
		var summary_lines := _fit_lines(font, summary_text, w - 40.0, summary_fs, 6,
			doctrine_y - 16.0 - summary_top)
		if summary_lines > 0:
			var shown := GameDefs.fit_text(font, summary_text, w - 40.0, summary_fs, summary_lines)
			draw_multiline_string(font, Vector2(20.0, summary_top + float(summary_fs)), shown,
				HORIZONTAL_ALIGNMENT_LEFT, w - 40.0, summary_fs, summary_lines,
				Color(0.90, 0.86, 0.76, 0.98))
		draw_string(font, Vector2(0.0, doctrine_y), String(data["doctrine"]), HORIZONTAL_ALIGNMENT_CENTER, w,
			GameDefs.fs(12), Color(0.94, 0.78, 0.44, 0.96))
		draw_line(Vector2(20.0, divider_y), Vector2(w - 20.0, divider_y),
			Color(0.56, 0.42, 0.23, 0.48), 1.0)

		# Signature roster.
		draw_string(font, Vector2(22.0, roster_head), "HOUSE ROSTER", HORIZONTAL_ALIGNMENT_LEFT, -1,
			GameDefs.fs(12), Color(0.86, 0.74, 0.50))
		for i in roster.size():
			var unit_id := String(roster[i])
			var unit_name := String(GameDefs.UNITS.get(unit_id, {}).get("name", unit_id))
			var uy := roster_first + float(i) * roster_line
			draw_colored_polygon(PackedVector2Array([
				Vector2(24.0, uy - 4.0), Vector2(28.0, uy - 8.0), Vector2(32.0, uy - 4.0), Vector2(28.0, uy),
			]), Color(col.r, col.g, col.b, 0.95))
			draw_string(font, Vector2(38.0, uy), unit_name, HORIZONTAL_ALIGNMENT_LEFT, w - 58.0, roster_fs,
				Color(0.92, 0.88, 0.78))

		# Selection marker. The three action buttons below the cards launch the
		# chosen mode; a tap on a banner only changes the selected House.
		draw_string(font, Vector2(0.0, tag_y), tag, HORIZONTAL_ALIGNMENT_CENTER, w, tag_fs, tag_col)

		if hovered or pressing:
			draw_rect(rect, Color(col.r, col.g, col.b, 0.5 if pressing else 0.28), false, 2.4)

	## Largest line count (1..max_lines) whose measured height still fits the room.
	func _fit_lines(font: Font, text: String, width: float, font_size: int, max_lines: int, room: float) -> int:
		if text.strip_edges() == "":
			return 0
		for lines in range(max_lines, 0, -1):
			if font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, lines).y <= room:
				return lines
		return 0

	func _draw_emblem(c: Vector2, r: float, col: Color) -> void:
		var gold := Color(0.86, 0.70, 0.38)
		match house:
			"atreides":
				# Spread-winged hawk: two swept wings, a narrow body and tail.
				var left := PackedVector2Array([
					c + Vector2(-r * 0.08, -r * 0.34),
					c + Vector2(-r * 0.58, -r * 0.70),
					c + Vector2(-r * 0.99, -r * 0.50),
					c + Vector2(-r * 0.62, -r * 0.04),
					c + Vector2(-r * 0.94, r * 0.38),
					c + Vector2(-r * 0.42, r * 0.24),
					c + Vector2(-r * 0.14, r * 0.34),
				])
				var right := PackedVector2Array()
				for p in left:
					right.append(Vector2(c.x * 2.0 - p.x, p.y))
				draw_colored_polygon(left, col.lightened(0.04))
				draw_colored_polygon(right, col.lightened(0.04))
				draw_polyline(left, gold, 1.2)
				draw_polyline(right, gold, 1.2)
				var body := PackedVector2Array([
					c + Vector2(0.0, -r * 0.80),
					c + Vector2(r * 0.17, -r * 0.38),
					c + Vector2(r * 0.11, r * 0.16),
					c + Vector2(0.0, r * 0.90),
					c + Vector2(-r * 0.11, r * 0.16),
					c + Vector2(-r * 0.17, -r * 0.38),
				])
				draw_colored_polygon(body, col.lightened(0.16))
				draw_polyline(body, gold, 1.3)
				draw_circle(c + Vector2(0.0, -r * 0.50), r * 0.11, col.lightened(0.30))
				draw_circle(c + Vector2(r * 0.035, -r * 0.53), r * 0.025, Color(0.06, 0.05, 0.04))
			"harkonnen":
				# Bull skull and heavy horns.
				var horns := PackedVector2Array([
					c + Vector2(-r * 0.18, -r * 0.26),
					c + Vector2(-r * 0.92, r * 0.10),
					c + Vector2(-r * 0.70, -r * 0.62),
					c + Vector2(-r * 0.30, -r * 0.40),
				])
				draw_colored_polygon(horns, col.lightened(0.10))
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(r * 0.18, -r * 0.26),
					c + Vector2(r * 0.92, r * 0.10),
					c + Vector2(r * 0.70, -r * 0.62),
					c + Vector2(r * 0.30, -r * 0.40),
				]), col.lightened(0.10))
				var skull := PackedVector2Array([
					c + Vector2(-r * 0.34, -r * 0.36), c + Vector2(r * 0.34, -r * 0.36),
					c + Vector2(r * 0.30, r * 0.20), c + Vector2(r * 0.12, r * 0.34),
					c + Vector2(r * 0.10, r * 0.72), c + Vector2(0.0, r * 0.86),
					c + Vector2(-r * 0.10, r * 0.72), c + Vector2(-r * 0.12, r * 0.34),
					c + Vector2(-r * 0.30, r * 0.20),
				])
				draw_colored_polygon(skull, col.lightened(0.04))
				draw_polyline(PackedVector2Array([skull[0], skull[1], skull[2], skull[3], skull[5], skull[6], skull[8]]), gold, 1.2)
				draw_circle(c + Vector2(-r * 0.14, -r * 0.10), r * 0.075, Color(0.03, 0.02, 0.02))
				draw_circle(c + Vector2(r * 0.14, -r * 0.10), r * 0.075, Color(0.03, 0.02, 0.02))
			"ordos":
				# Coiled serpent with a raised head.
				var pts := PackedVector2Array()
				for i in 17:
					var t := float(i) / 16.0
					var a := t * TAU * 1.25 - PI * 0.5
					var rad := r * (0.62 - t * 0.36)
					pts.append(c + Vector2(cos(a) * rad, sin(a) * rad * 0.78 + r * 0.20))
				draw_polyline(pts, col.lightened(0.10), 7.0, true)
				draw_polyline(pts, col.lightened(0.30), 3.0, true)
				# Rearing neck and a larger viper head, joined to the coil.
				var head := c + Vector2(r * 0.46, -r * 0.50)
				var neck := c + Vector2(r * 0.24, r * 0.10)
				draw_line(neck, head, col.lightened(0.12), 7.0)
				draw_line(neck, head, col.lightened(0.34), 2.5)
				draw_circle(head, r * 0.15, col.lightened(0.18))
				draw_colored_polygon(PackedVector2Array([
					head + Vector2(r * 0.02, r * 0.12),
					head + Vector2(r * 0.42, -r * 0.02),
					head + Vector2(r * 0.02, -r * 0.17),
				]), col.lightened(0.22))
				draw_circle(head + Vector2(r * 0.05, -r * 0.05), r * 0.032, gold)
				draw_line(head + Vector2(r * 0.34, 0.0), head + Vector2(r * 0.62, r * 0.06),
					Color(0.90, 0.34, 0.28), 1.4)
				draw_line(head + Vector2(r * 0.34, 0.04), head + Vector2(r * 0.60, r * 0.20),
					Color(0.90, 0.34, 0.28), 1.0)
