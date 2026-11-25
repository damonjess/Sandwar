extends Control

## Dune 2000 style Mentat briefing. Used as a dedicated scene between the
## strategic map and the battlefield, and re-used as an in-match overlay from
## the OPTIONS menu. All portrait text and unlock data comes from CampaignMissions.

signal closed

const PORTRAITS := {
	"atreides": "res://assets/ui/mentat_atreides.jpg",
	"harkonnen": "res://assets/ui/mentat_harkonnen.jpg",
	"ordos": "res://assets/ui/mentat_ordos.jpg",
}

const C_BRONZE := Color(0.55, 0.40, 0.20)
const C_BONE := Color(0.92, 0.86, 0.71)
const C_AMBER := Color(0.93, 0.74, 0.37)
const C_DIM := Color(0.58, 0.53, 0.43)
const C_GREEN := Color(0.43, 0.92, 0.65)

var embedded := false
var mission_override: Dictionary = {}

var state
var mission: Dictionary = {}
var house := Factions.ATREIDES
var tier := 1
var region_name := "ARRAKIS"
var enemy_house := Factions.HARKONNEN
var objective_text := ""
var mentat_text := ""
var unlock_icons: Array = []
var unlock_title := "NEWLY UNLOCKED TECHNOLOGY"

var portrait: MentatPortrait
var transmission_label: Label
var skip_hint: Label
var proceed_button: TouchButton
var back_button: TouchButton
var replay_button: TouchButton
var left_panel: PanelContainer
var _voice_available := false
var _actions: Array = []
var _action_focus := 0

var typing := false
var _type_progress := 0.0
var _char_count := 0
var _last_blip := 0
var _finished := false
var _closing := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 200
	if embedded:
		process_mode = Node.PROCESS_MODE_ALWAYS
	state = GameDefs.campaign
	_resolve_context()
	_voice_available = _resolve_voice_available()
	_build()
	_start_transmission()
	_begin_voice_session()
	resized.connect(_layout)
	_layout()
	set_process(true)

func _resolve_context() -> void:
	if not mission_override.is_empty():
		mission = mission_override.duplicate(true)
	elif state != null:
		var active = state.get("active_mission")
		if typeof(active) == TYPE_DICTIONARY and not active.is_empty():
			mission = active.duplicate(true)
		else:
			var available: Array = state.call("available_missions")
			if not available.is_empty():
				mission = available[0].duplicate(true)
				state.call("begin_mission", mission)
	if mission.is_empty():
		mission = {
			"tier": 1,
			"player_house": Factions.ATREIDES,
			"region_name": "ARRAKIS",
			"enemy_house": Factions.HARKONNEN,
			"objective_text": "Secure the province and break the enemy.",
			"mentat_text": "Commander, the link is open. The desert is listening; take the field and make your House proud.",
			"unlock_icons": [],
		}
	house = String(mission.get("player_house", Factions.ATREIDES))
	if not Factions.exists(house):
		house = Factions.ATREIDES
	tier = int(mission.get("tier", 1))
	region_name = String(mission.get("region_name", "ARRAKIS")).to_upper()
	enemy_house = String(mission.get("enemy_house", Factions.HARKONNEN))
	if not Factions.exists(enemy_house) or enemy_house == house:
		enemy_house = CampaignMissions.rival_for(house)
	objective_text = String(mission.get("objective_text", "Secure the province."))
	mentat_text = String(mission.get("mentat_text", ""))
	if mentat_text == "":
		mentat_text = "Commander, the desert is listening. Take the field and make House %s proud." % Factions.display_name(house)
	var icons = mission.get("unlock_icons", [])
	if typeof(icons) == TYPE_ARRAY:
		unlock_icons = icons
	else:
		unlock_icons = []
	unlock_title = String(mission.get("unlock_title", "NEWLY UNLOCKED TECHNOLOGY")).to_upper()

func _build() -> void:
	var accent := Factions.color(house)
	var backdrop := BriefingBackdrop.new()
	backdrop.accent = accent
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 34)
	margin.add_theme_constant_override("margin_right", 34)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 22)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var header := HBoxContainer.new()
	header.custom_minimum_size = Vector2(0.0, 58.0)
	header.add_theme_constant_override("separation", 16)
	column.add_child(header)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 1)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	var overline := Label.new()
	overline.text = "ARRAKIS HIGH COMMAND  //  MENTAT SECURE LINK"
	overline.add_theme_font_size_override("font_size", GameDefs.fs(12))
	overline.add_theme_color_override("font_color", C_DIM)
	titles.add_child(overline)
	var title := Label.new()
	title.text = "MENTAT BRIEFING"
	title.add_theme_font_size_override("font_size", GameDefs.fs(27))
	title.add_theme_color_override("font_color", C_BONE)
	titles.add_child(title)
	var house_block := VBoxContainer.new()
	house_block.add_theme_constant_override("separation", 1)
	header.add_child(house_block)
	var house_label := Label.new()
	house_label.text = Factions.display_name(house).to_upper()
	house_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	house_label.add_theme_font_size_override("font_size", GameDefs.fs(16))
	house_label.add_theme_color_override("font_color", accent.lightened(0.30))
	house_block.add_child(house_label)
	var link_label := Label.new()
	link_label.text = "ENCRYPTED CHANNEL 07  ·  SIGNAL STRONG"
	link_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	link_label.add_theme_font_size_override("font_size", GameDefs.fs(12))
	link_label.add_theme_color_override("font_color", C_DIM)
	house_block.add_child(link_label)

	var rule := ColorRect.new()
	rule.color = Color(C_BRONZE.r, C_BRONZE.g, C_BRONZE.b, 0.62)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	column.add_child(rule)

	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 26)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(content)

	left_panel = PanelContainer.new()
	left_panel.custom_minimum_size = Vector2(420.0, 0.0)
	left_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var monitor_style := StyleBoxFlat.new()
	monitor_style.bg_color = Color(0.030, 0.028, 0.021, 0.98)
	monitor_style.border_color = C_BRONZE
	monitor_style.set_border_width_all(3)
	monitor_style.content_margin_left = 10.0
	monitor_style.content_margin_right = 10.0
	monitor_style.content_margin_top = 10.0
	monitor_style.content_margin_bottom = 10.0
	left_panel.add_theme_stylebox_override("panel", monitor_style)
	content.add_child(left_panel)

	var monitor_column := VBoxContainer.new()
	monitor_column.add_theme_constant_override("separation", 7)
	left_panel.add_child(monitor_column)
	var screen := Control.new()
	screen.custom_minimum_size = Vector2(0.0, 360.0)
	screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	screen.clip_contents = true
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	monitor_column.add_child(screen)
	portrait = MentatPortrait.new()
	portrait.house = house
	portrait.typing = true
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(portrait)
	var scan := MonitorRivets.new()
	scan.accent = accent
	scan.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(scan)
	var name_label := Label.new()
	name_label.text = Factions.mentat_name(house)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", GameDefs.fs(16))
	name_label.add_theme_color_override("font_color", accent.lightened(0.32))
	monitor_column.add_child(name_label)
	var mentat_title := Label.new()
	mentat_title.text = Factions.mentat_title(house)
	mentat_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mentat_title.add_theme_font_size_override("font_size", GameDefs.fs(12))
	mentat_title.add_theme_color_override("font_color", C_DIM)
	monitor_column.add_child(mentat_title)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 7)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(right)

	var incoming := Label.new()
	incoming.text = "INCOMING TRANSMISSION  //  PRIORITY MENTAT EYES ONLY"
	incoming.add_theme_font_size_override("font_size", GameDefs.fs(12))
	incoming.add_theme_color_override("font_color", C_GREEN)
	right.add_child(incoming)
	var mission_header := Label.new()
	mission_header.text = "MISSION %d OF %d  —  %s" % [tier, CampaignMissions.TIER_COUNT, region_name]
	mission_header.add_theme_font_size_override("font_size", GameDefs.fs(22))
	mission_header.add_theme_color_override("font_color", C_BONE)
	mission_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(mission_header)
	var enemy_label := Label.new()
	enemy_label.text = "OPPOSITION  %s     ·     CHANNEL 07 / CIPHER LOCKED" % Factions.display_name(enemy_house).to_upper()
	enemy_label.add_theme_font_size_override("font_size", GameDefs.fs(12))
	enemy_label.add_theme_color_override("font_color", Factions.color(enemy_house).lightened(0.25))
	right.add_child(enemy_label)
	var trans_rule := ColorRect.new()
	trans_rule.color = Color(C_BRONZE.r, C_BRONZE.g, C_BRONZE.b, 0.36)
	trans_rule.custom_minimum_size = Vector2(0.0, 1.0)
	right.add_child(trans_rule)

	transmission_label = Label.new()
	transmission_label.text = mentat_text
	transmission_label.visible_characters = 0
	transmission_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	transmission_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	transmission_label.add_theme_font_size_override("font_size", GameDefs.fs(18))
	transmission_label.add_theme_constant_override("line_spacing", 6)
	transmission_label.add_theme_color_override("font_color", Color(0.96, 0.91, 0.79))
	transmission_label.custom_minimum_size = Vector2(0.0, 120.0)
	transmission_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	transmission_label.mouse_filter = Control.MOUSE_FILTER_STOP
	transmission_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	transmission_label.tooltip_text = "Tap to reveal the full transmission immediately"
	transmission_label.gui_input.connect(_on_transmission_input)
	right.add_child(transmission_label)

	skip_hint = Label.new()
	skip_hint.text = "▸  TAP TRANSMISSION TO REVEAL FULL ORDERS"
	skip_hint.add_theme_font_size_override("font_size", GameDefs.fs(12))
	skip_hint.add_theme_color_override("font_color", C_AMBER)
	right.add_child(skip_hint)

	var objective_panel := PanelContainer.new()
	var objective_style := StyleBoxFlat.new()
	objective_style.bg_color = Color(0.055, 0.047, 0.030, 0.98)
	objective_style.border_color = Color(C_BRONZE.r, C_BRONZE.g, C_BRONZE.b, 0.85)
	objective_style.set_border_width_all(1)
	objective_style.border_width_left = 4
	objective_style.content_margin_left = 12.0
	objective_style.content_margin_right = 12.0
	objective_style.content_margin_top = 7.0
	objective_style.content_margin_bottom = 7.0
	objective_panel.add_theme_stylebox_override("panel", objective_style)
	right.add_child(objective_panel)
	var objective_col := VBoxContainer.new()
	objective_col.add_theme_constant_override("separation", 2)
	objective_panel.add_child(objective_col)
	var objective_heading := Label.new()
	objective_heading.text = "PRIMARY OBJECTIVE"
	objective_heading.add_theme_font_size_override("font_size", GameDefs.fs(12))
	objective_heading.add_theme_color_override("font_color", C_AMBER)
	objective_col.add_child(objective_heading)
	var objective := Label.new()
	objective.text = objective_text
	objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective.add_theme_font_size_override("font_size", GameDefs.fs(16))
	objective.add_theme_color_override("font_color", Color(0.96, 0.92, 0.82))
	objective_col.add_child(objective)

	var unlock_heading := Label.new()
	unlock_heading.text = unlock_title
	unlock_heading.add_theme_font_size_override("font_size", GameDefs.fs(13))
	unlock_heading.add_theme_color_override("font_color", C_AMBER)
	right.add_child(unlock_heading)
	var tech_flow := HFlowContainer.new()
	tech_flow.add_theme_constant_override("h_separation", 7)
	tech_flow.add_theme_constant_override("v_separation", 6)
	tech_flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(tech_flow)
	for item in unlock_icons:
		if typeof(item) != TYPE_ARRAY or item.size() < 2:
			continue
		var chip := _make_tech_chip(String(item[0]), String(item[1]))
		if chip != null:
			tech_flow.add_child(chip)
	if tech_flow.get_child_count() == 0:
		var none := Label.new()
		none.text = "NO NEW HARDWARE ON THIS FRONT"
		none.add_theme_font_size_override("font_size", GameDefs.fs(12))
		none.add_theme_color_override("font_color", Color(0.78, 0.72, 0.60))
		tech_flow.add_child(none)

	var footer := HBoxContainer.new()
	footer.custom_minimum_size = Vector2(0.0, 52.0)
	footer.add_theme_constant_override("separation", 10)
	column.add_child(footer)
	var footer_status := Label.new()
	footer_status.text = "CHANNEL SECURE  ·  MENTAT LINK 07"
	footer_status.add_theme_font_size_override("font_size", GameDefs.fs(12))
	footer_status.add_theme_color_override("font_color", C_DIM)
	footer_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(footer_status)
	replay_button = TouchButton.new()
	replay_button.text = "REPLAY VOICE"
	replay_button.tooltip_text = "Replay this Mentat's briefing transmission"
	replay_button.font_size = GameDefs.fs(13)
	replay_button.accent = C_AMBER
	replay_button.custom_minimum_size = Vector2(168.0, 48.0)
	replay_button.enabled = _voice_available
	replay_button.pressed.connect(_on_replay_voice)
	footer.add_child(replay_button)
	if not embedded:
		back_button = TouchButton.new()
		back_button.text = "BACK TO MAP"
		back_button.font_size = GameDefs.fs(14)
		back_button.accent = C_BRONZE
		back_button.custom_minimum_size = Vector2(200.0, 48.0)
		back_button.pressed.connect(_on_back)
		footer.add_child(back_button)
	proceed_button = TouchButton.new()
	proceed_button.text = "RETURN TO BATTLE" if embedded else "PROCEED / START MISSION"
	proceed_button.subtext = "REVIEW COMPLETE" if embedded else "PROCEED TO BATTLE"
	proceed_button.font_size = GameDefs.fs(16)
	proceed_button.primary = true
	proceed_button.accent = accent
	proceed_button.custom_minimum_size = Vector2(360.0, 48.0)
	proceed_button.pressed.connect(_on_proceed)
	footer.add_child(proceed_button)
	_actions = [proceed_button]
	if replay_button != null:
		_actions.append(replay_button)
	if back_button != null:
		_actions.append(back_button)

func _layout() -> void:
	if left_panel == null:
		return
	left_panel.custom_minimum_size.x = clampf(size.x * 0.345, 330.0, 440.0)

func _start_transmission() -> void:
	if transmission_label == null:
		return
	transmission_label.text = mentat_text
	transmission_label.visible_characters = 0
	_type_progress = 0.0
	_char_count = 0
	_last_blip = 0
	_finished = mentat_text == ""
	typing = not _finished
	if portrait != null:
		portrait.typing = typing
	if skip_hint != null:
		skip_hint.visible = typing
	if _finished:
		_finish_typing()

func _process(delta: float) -> void:
	_sync_voice_monitor()
	if not typing:
		return
	_type_progress += delta * 38.0
	var chars := int(_type_progress)
	if chars > _char_count:
		_char_count = chars
		transmission_label.visible_characters = _char_count
		if _char_count - _last_blip >= 3:
			_last_blip = _char_count
			_play_blip()
	if _char_count >= mentat_text.length():
		_finish_typing()

func _audio() -> Node:
	return get_node_or_null("/root/AudioManager")

func _voice_path() -> String:
	return "res://assets/sfx/mentat/%s_mission_%02d.ogg" % [house, tier]

func _resolve_voice_available() -> bool:
	var audio := _audio()
	if audio != null and audio.has_method("has_mentat"):
		return bool(audio.call("has_mentat", house, tier))
	return ResourceLoader.exists(_voice_path())

func _begin_voice_session() -> void:
	var audio := _audio()
	if audio != null and audio.has_method("play_menu_music"):
		audio.call("play_menu_music")
	if _voice_available and audio != null and audio.has_method("play_mentat"):
		audio.call("play_mentat", house, tier)
	_sync_voice_monitor()

func _sync_voice_monitor() -> void:
	var audio := _audio()
	var active := false
	if audio != null and audio.has_method("is_mentat_playing"):
		active = bool(audio.call("is_mentat_playing"))
	if portrait != null and portrait.speaking != active:
		portrait.speaking = active

func _stop_voice() -> void:
	var audio := _audio()
	if audio != null and audio.has_method("stop_mentat"):
		audio.call("stop_mentat")
	if portrait != null:
		portrait.speaking = false

func _on_replay_voice() -> void:
	if _closing or not _voice_available:
		return
	var audio := _audio()
	if audio != null and audio.has_method("play_mentat"):
		if bool(audio.call("play_mentat", house, tier)):
			_sync_voice_monitor()
			_play_blip()

func _play_blip() -> void:
	var audio := _audio()
	if audio != null:
		audio.call("play_ui", "comms_blip", -20.0, 1.0)

func _finish_typing() -> void:
	typing = false
	_finished = true
	_type_progress = float(mentat_text.length())
	_char_count = mentat_text.length()
	if transmission_label != null:
		transmission_label.visible_characters = -1
	if skip_hint != null:
		skip_hint.visible = false
	if portrait != null:
		portrait.typing = false

func _reveal() -> void:
	if not _finished:
		_finish_typing()

func _on_transmission_input(event: InputEvent) -> void:
	var press := false
	if event is InputEventMouseButton:
		press = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventScreenTouch:
		press = event.pressed and event.index <= 0
	if press:
		accept_event()
		_reveal()

func _on_proceed() -> void:
	if _closing:
		return
	_closing = true
	_stop_voice()
	var audio := _audio()
	if audio != null and audio.has_method("stop_all"):
		audio.call("stop_all")
	if embedded:
		closed.emit()
	else:
		get_tree().change_scene_to_file("res://main.tscn")

func _on_back() -> void:
	if _closing:
		return
	_closing = true
	_stop_voice()
	var audio := _audio()
	if audio != null and audio.has_method("stop_all"):
		audio.call("stop_all")
	if embedded:
		closed.emit()
		return
	if state != null:
		state.call("return_to_map")
	get_tree().change_scene_to_file("res://scenes/campaign_map.tscn")

func _exit_tree() -> void:
	_stop_voice()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or _closing:
		return
	var confirm := key.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]
	if typing and confirm:
		get_viewport().set_input_as_handled()
		_reveal()
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_back()
		return
	if confirm:
		get_viewport().set_input_as_handled()
		_activate_action()
		return
	if key.keycode in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_TAB]:
		get_viewport().set_input_as_handled()
		_cycle_action(-1 if key.shift_pressed else 1)

func _cycle_action(step: int) -> void:
	if _actions.is_empty():
		return
	for offset in range(1, _actions.size() + 1):
		var index := posmod(_action_focus + step * offset, _actions.size())
		if _actions[index].enabled:
			_action_focus = index
			break
	for index in _actions.size():
		_actions[index].keyboard_focused = index == _action_focus

func _activate_action() -> void:
	if _actions.is_empty():
		return
	var action = _actions[_action_focus]
	if action != null and action.enabled:
		action.pressed.emit()

func _make_tech_chip(kind: String, id: String) -> Control:
	var def: Dictionary = {}
	var icon: Texture2D = null
	if kind == "structure":
		def = GameDefs.STRUCTURES.get(id, {})
		icon = BuildingArt.icon(id)
	elif kind == "brush":
		def = GameDefs.BRUSHES.get(id, {})
		icon = BuildingArt.icon(id)
	else:
		def = GameDefs.UNITS.get(id, {})
		icon = UnitArt.icon(id)
	if def.is_empty():
		return null
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(156.0, 58.0)
	chip.tooltip_text = String(def.get("name", id))
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.030, 0.034, 0.028, 0.97)
	style.border_color = Color(C_BRONZE.r, C_BRONZE.g, C_BRONZE.b, 0.62)
	style.set_border_width_all(1)
	style.content_margin_left = 4.0
	style.content_margin_right = 4.0
	style.content_margin_top = 3.0
	style.content_margin_bottom = 3.0
	chip.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(row)
	var image := TextureRect.new()
	image.texture = icon
	image.custom_minimum_size = Vector2(30.0, 30.0)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if icon != null:
		image.material = UnitArt.hud_material(0) if kind == "unit" else BuildingArt.hud_material(0)
	row.add_child(image)
	var caption := Label.new()
	caption.text = String(def.get("name", id)).to_upper()
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", GameDefs.fs(12))
	caption.add_theme_color_override("font_color", C_BONE)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(caption)
	return chip


# ---------------------------------------------------------------- background

class BriefingBackdrop:
	extends Control

	var accent := Color(0.25, 0.55, 0.95)

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0.0, 0.0, w, h), Color(0.025, 0.028, 0.025))
		for i in 24:
			var t := float(i) / 23.0
			var band := Color(0.018, 0.026, 0.024).lerp(Color(0.10, 0.064, 0.036), t * 0.58)
			draw_rect(Rect2(0.0, h * float(i) / 24.0, w, h / 24.0 + 1.0), band)
		for x in range(0, int(w) + 1, 64):
			draw_line(Vector2(float(x), 0.0), Vector2(float(x), h), Color(0.68, 0.51, 0.28, 0.022), 1.0)
		for y in range(0, int(h) + 1, 64):
			draw_line(Vector2(0.0, float(y)), Vector2(w, float(y)), Color(0.68, 0.51, 0.28, 0.018), 1.0)
		for i in 30:
			var x := fmod(float(i) * 191.0 + 37.0, w)
			var y := fmod(float(i) * 73.0 + 21.0, h)
			draw_circle(Vector2(x, y), 0.8 + float(i % 2) * 0.5, Color(0.92, 0.78, 0.48, 0.035))
		# Deep vertical rails and rivets frame the terminal.
		for side in [0.0, w - 13.0]:
			draw_rect(Rect2(side, 0.0, 13.0, h), Color(0.030, 0.022, 0.014, 0.86))
			draw_line(Vector2(side + (0.5 if side == 0.0 else 12.5), 0.0),
				Vector2(side + (0.5 if side == 0.0 else 12.5), h), Color(0.52, 0.37, 0.17, 0.50), 1.0)
		for i in 13:
			var y := 18.0 + float(i) * (h - 36.0) / 12.0
			for x in [6.0, w - 6.0]:
				draw_circle(Vector2(x, y), 2.2, Color(0.08, 0.05, 0.03))
				draw_circle(Vector2(x, y), 1.4, Color(0.70, 0.52, 0.26))
		# A faint house-coloured tactical rose behind the transmission.
		var c := Vector2(w * 0.67, h * 0.48)
		for radius in [190.0, 145.0, 100.0]:
			draw_arc(c, radius, -PI, PI, 64, Color(accent.r, accent.g, accent.b, 0.035), 1.0)
		for i in 12:
			var a := TAU * float(i) / 12.0
			draw_line(c, c + Vector2(cos(a), sin(a)) * 190.0, Color(accent.r, accent.g, accent.b, 0.025), 1.0)
		for y in range(0, int(h), 5):
			draw_line(Vector2(0.0, float(y)), Vector2(w, float(y)), Color(0.0, 0.0, 0.0, 0.045), 1.0)
		draw_rect(Rect2(0.0, 0.0, w, h), Color(0.0, 0.0, 0.0, 0.18), false, 8.0)


class MonitorRivets:
	extends Control

	var accent := Color(0.25, 0.55, 0.95)

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0.5, 0.5, w - 1.0, h - 1.0), Color(0.02, 0.015, 0.01, 0.92), false, 3.0)
		draw_rect(Rect2(3.0, 3.0, w - 6.0, h - 6.0), Color(0.48, 0.33, 0.15, 0.65), false, 1.0)
		for p in [Vector2(7.0, 7.0), Vector2(w - 7.0, 7.0), Vector2(7.0, h - 7.0), Vector2(w - 7.0, h - 7.0)]:
			draw_circle(p, 3.0, Color(0.06, 0.04, 0.025))
			draw_circle(p, 1.7, Color(0.78, 0.59, 0.31))
		var led := 0.45 + 0.55 * absf(sin(Time.get_ticks_msec() * 0.004))
		draw_circle(Vector2(w - 15.0, 13.0), 2.5, Color(0.20, 0.86, 0.38, led))
		draw_circle(Vector2(w - 15.0, 13.0), 5.0, Color(0.20, 0.86, 0.38, led * 0.12))
		draw_line(Vector2(12.0, h - 12.0), Vector2(w - 12.0, h - 12.0), Color(accent.r, accent.g, accent.b, 0.35), 1.0)


# ------------------------------------------------------------------- portrait

class MentatPortrait:
	extends Control

	const PORTRAITS := {
		"atreides": "res://assets/ui/mentat_atreides.jpg",
		"harkonnen": "res://assets/ui/mentat_harkonnen.jpg",
		"ordos": "res://assets/ui/mentat_ordos.jpg",
	}

	var house := "atreides"
	var typing := false
	var speaking := false
	var _clock := 0.0
	var _texture: Texture2D
	var _image_rect := Rect2()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_texture = load(PORTRAITS.get(house, PORTRAITS["atreides"]))
		set_process(true)

	func _process(delta: float) -> void:
		_clock += delta
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if w < 4.0 or h < 4.0:
			return
		var house_col := Factions.color(house)
		draw_rect(Rect2(0.0, 0.0, w, h), Color(0.012, 0.020, 0.018))
		if _texture != null:
			var ts := _texture.get_size()
			var cover := maxf(w / maxf(ts.x, 1.0), h / maxf(ts.y, 1.0))
			var ds := ts * cover
			_image_rect = Rect2((w - ds.x) * 0.5, (h - ds.y) * 0.5, ds.x, ds.y)
			draw_texture_rect(_texture, _image_rect, false)
		else:
			_image_rect = Rect2(0.0, 0.0, w, h)
			draw_circle(Vector2(w * 0.5, h * 0.42), minf(w, h) * 0.28, house_col.darkened(0.45))
			draw_rect(Rect2(w * 0.28, h * 0.65, w * 0.44, h * 0.25), house_col.darkened(0.55))
		_draw_face_effect(house_col)
		_draw_crt(w, h, house_col)

	func _draw_face_effect(house_col: Color) -> void:
		var active := typing or speaking
		var pulse := 0.55 + 0.45 * absf(sin(_clock * (7.0 if active else 2.2)))
		var iw := _image_rect.size.x
		var ih := _image_rect.size.y
		var cx := _image_rect.position.x + iw * 0.5
		if house == "ordos":
			# The ocular band sits at 39% of the baked portrait; the jaw grille
			# at 59%. Map through the cover rect so it tracks any crop/resize.
			var vy := _image_rect.position.y + ih * 0.390
			draw_rect(Rect2(cx - iw * 0.18, vy - ih * 0.012, iw * 0.36, ih * 0.024),
				Color(0.10, 0.95, 0.42, 0.035 + 0.055 * pulse))
			# Two ocular halos pulse in sync with the voice feed.
			for ex in [0.405, 0.595]:
				draw_circle(Vector2(_image_rect.position.x + iw * ex, vy), iw * 0.018,
					Color(0.35, 1.0, 0.58, 0.07 + 0.14 * pulse))
			var scan_x := fmod(_clock * iw * 0.30, iw * 0.36)
			draw_line(Vector2(cx - iw * 0.18 + scan_x, vy - ih * 0.011),
				Vector2(cx - iw * 0.18 + scan_x, vy + ih * 0.011),
				Color(0.66, 1.0, 0.76, 0.40), 1.5)
			var jaw := _image_rect.position.y + ih * 0.590
			var open := (0.5 + 0.5 * absf(sin(_clock * 16.0))) if active else 0.0
			var jaw_h := ih * 0.003 + ih * 0.009 * open
			draw_rect(Rect2(cx - iw * 0.07, jaw - jaw_h * 0.5, iw * 0.14, jaw_h),
				Color(0.18, 0.98, 0.48, 0.20 + 0.25 * open))
		else:
			var mouth_norm := 0.515 if house == "atreides" else 0.552
			var my := _image_rect.position.y + ih * mouth_norm
			var open := (0.5 + 0.5 * absf(sin(_clock * 15.0))) if active else 0.0
			var mw := iw * 0.080
			var mh := ih * 0.0035 + ih * 0.017 * open
			# An oval reads as a moving mouth instead of a blocky missing patch.
			_draw_oval(Vector2(cx, my), mw * 0.5, mh * 0.5,
				Color(0.035, 0.012, 0.008, 0.50 + 0.25 * open))
			draw_line(Vector2(cx - mw * 0.42, my + mh * 0.55),
				Vector2(cx + mw * 0.42, my + mh * 0.55),
				Color(house_col.r, house_col.g, house_col.b, 0.18 + 0.30 * open), 1.5)
			# A tiny jawline highlight keeps the lip-sync readable at 960x540.
			draw_line(Vector2(cx - mw * 0.22, my + mh * 0.55 + 2.0),
				Vector2(cx + mw * 0.22, my + mh * 0.55 + 2.0),
				Color(0.98, 0.78, 0.48, 0.16 + 0.22 * open), 1.0)

	func _draw_oval(center: Vector2, rx: float, ry: float, color: Color) -> void:
		var pts := PackedVector2Array()
		for i in 16:
			var a := TAU * float(i) / 16.0
			pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
		draw_colored_polygon(pts, color)

	func _draw_crt(w: float, h: float, house_col: Color) -> void:
		for y in range(0, int(h), 3):
			draw_line(Vector2(0.0, float(y)), Vector2(w, float(y)), Color(0.0, 0.0, 0.0, 0.13), 1.0)
		var scan_y := fmod(_clock * 29.0, h)
		draw_rect(Rect2(0.0, scan_y, w, 2.0), Color(0.40, 1.0, 0.72, 0.035))
		for i in 7:
			var a := 0.035 * (1.0 - float(i) / 7.0)
			draw_rect(Rect2(float(i) * 5.0, 0.0, 5.0, h), Color(0.0, 0.0, 0.0, a))
			draw_rect(Rect2(w - float(i + 1) * 5.0, 0.0, 5.0, h), Color(0.0, 0.0, 0.0, a))
			draw_rect(Rect2(0.0, float(i) * 5.0, w, 5.0), Color(0.0, 0.0, 0.0, a))
			draw_rect(Rect2(0.0, h - float(i + 1) * 5.0, w, 5.0), Color(0.0, 0.0, 0.0, a))
		for i in 22:
			var x := fmod(float(i) * 83.0 + floor(_clock * 7.0) * 19.0, w)
			var y := fmod(float(i) * 47.0 + floor(_clock * 11.0) * 13.0, h)
			draw_rect(Rect2(x, y, 1.3, 1.0), Color(0.92, 1.0, 0.82, 0.045))
		draw_rect(Rect2(0.0, 0.0, w, h), Color(0.0, 0.0, 0.0, 0.24), false, 5.0)
		draw_rect(Rect2(1.5, 1.5, w - 3.0, h - 3.0), Color(house_col.r, house_col.g, house_col.b, 0.42), false, 1.0)
		var live := 0.55 + 0.45 * absf(sin(_clock * 4.0))
		draw_circle(Vector2(15.0, 14.0), 3.0, Color(0.28, 1.0, 0.46, live))
		draw_circle(Vector2(15.0, 14.0), 6.0, Color(0.28, 1.0, 0.46, live * 0.12))
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(23.0, 20.0), "LIVE", HORIZONTAL_ALIGNMENT_LEFT, -1, GameDefs.fs(11),
			Color(0.68, 1.0, 0.78, 0.94))
		for i in 4:
			var bh := 3.0 + float(i) * 2.2
			draw_rect(Rect2(w - 38.0 + float(i) * 5.0, 17.0 - bh, 3.0, bh),
				Color(0.44, 0.92, 0.58, 0.65))
		draw_string(font, Vector2(w - 82.0, 20.0), "CH 07", HORIZONTAL_ALIGNMENT_LEFT, -1, GameDefs.fs(11),
			Color(0.58, 0.98, 0.70, 0.86))
		var feed_text := "MENTAT VOICE FEED" if speaking else "MENTAT SECURE FEED"
		draw_string(font, Vector2(12.0, h - 9.0), feed_text, HORIZONTAL_ALIGNMENT_LEFT, -1, GameDefs.fs(11),
			Color(0.72, 0.62, 0.44, 0.92))
		# Four-bar voice monitor beside the feed label.
		for i in 4:
			var amp := (0.28 + 0.72 * absf(sin(_clock * 9.0 + float(i) * 1.7))) if typing or speaking else 0.14
			var bh := 2.0 + amp * 8.0
			draw_rect(Rect2(w - 48.0 + float(i) * 7.0, h - 10.0 - bh, 3.0, bh),
				Color(0.35, 0.95, 0.56, 0.46 + 0.30 * amp))
