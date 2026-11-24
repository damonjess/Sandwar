class_name GameHUD
extends CanvasLayer

## Classic Dune 2000 command sidebar replica.
##
## The supplied 160x404 sidebar shell supplies the carved mahogany/bronze frame,
## large radar recess, five-icon command row and brass scrollers. Live radar,
## action states, production rows, queue badges and touch affordances are drawn
## on top of that shell. Gameplay and the existing touch contract are unchanged.

const PANEL_WIDTH := 285.0
const SHELL_REF_W := 160.0
const SHELL_REF_H := 404.0
const SHELL_SCALE := PANEL_WIDTH / SHELL_REF_W
const SHELL_TEXTURE := "res://assets/ui/dune_sidebar_shell.png"
const BUILD_ROW_REF_H := 40.0
const BUILD_ROW_REF_GAP := 4.0

const C_PANEL_TOP := Color("2b1911")
const C_PANEL_BOT := Color("120b07")
const C_FRAME := Color("75502c")
const C_FRAME_HI := Color("c59656")
const C_BRASS := Color("a87b3f")
const C_INSET := Color("0b0d0c")
const C_TEXT := Color("ecdcc0")
const C_DIM := Color("a08969")
const C_GOLD := Color("e8b65a")
const C_GREEN := Color("75c83c")
const C_BLUE := Color("3567d8")
const C_CYAN := Color("4ad9c6")
const C_TILE := Color("1b1814")
const C_TILE_OFF := Color("11100e")
const C_STEEL := Color("262a29")
const C_STEEL_HI := Color("77817c")
const C_DIGITAL := Color("8fffd2")
# High-contrast mobile typography: warm cream body text, bright gold accents.
const C_CREAM := Color("F7E7C0")
const C_GOLD_BRIGHT := Color("FFD466")
const C_STATUS := Color("F5E8CC")
const C_INFO := Color("D8C39E")
const C_OPTION_TEXT := Color("F4E6C8")

var game
var credits_label: Label
var info_label: Label
var status_label: Label
var log_label: Label
var header_label: Label
var structure_grid: VBoxContainer
var unit_grid: VBoxContainer
var structure_scroll: ScrollContainer
var unit_scroll: ScrollContainer
var buttons: Array = []
var minimap: Minimap
var power_bar: PowerBar
var cancel_button: Button
var box_button: Button
var repair_button: ActionIcon
var sell_button: ActionIcon
var guard_button: ActionIcon
var hammer_button: ActionIcon
var status_orb: StatusOrb
var options_button: Button
var options_popup: PanelContainer
var briefing_button: TouchButton
var mission_banner: Label
var objective_plate: ObjectivePlate
var toast_plate: ToastPlate
var toast_label: Label
var toast_timer := 0.0
var briefing_overlay: Control
var briefing_prev_game_mode := Node.PROCESS_MODE_INHERIT
var debug_win_button: TouchButton
var credits_plate: Control
var quick_strip: HBoxContainer
var screen_footer: PanelContainer
var tab := "all"

var overlay: Control
var overlay_title: Label
var overlay_body: Label
var overlay_buttons: VBoxContainer
var refresh_timer := 0.0

const STRUCTURE_ITEMS := [
	["structure", "windtrap"],
	["structure", "refinery"],
	["structure", "barracks"],
	["structure", "factory"],
	["structure", "turret"],
	["structure", "rocketturret"],
	["brush", "slab"],
	["brush", "wall"],
]
## Units come from the player's House roster at runtime, not a fixed list.

## Short labels for the sidebar tiles. They are sized to fit one line beside
## the build portrait; the full name stays in each tile's tooltip.
const TILE_NAMES := {
	"windtrap": "WIND TRAP", "refinery": "REFINERY", "barracks": "BARRACKS",
	"factory": "FACTORY", "turret": "GUN TURRET", "rocketturret": "ROCKET TURRET",
	"slab": "CONCRETE", "wall": "WALL", "infantry": "INFANTRY",
	"rocket": "ROCKET", "trike": "TRIKE", "raider_trike": "RAIDER TRIKE",
	"quad": "QUAD", "tank": "SIEGE TANK", "atreides_tank": "ATREIDES TANK",
	"harkonnen_tank": "HARK TANK", "ordos_tank": "ORDOS TANK",
	"sonic_tank": "SONIC TANK", "devastator": "DEVASTATOR",
	"deviator": "DEVIATOR", "harvester": "HARVESTER", "fremen": "FREMEN",
	"sardaukar": "SARDAUKAR", "saboteur": "SABOTEUR",
}

# ------------------------------------------------------------------ widgets

## Beveled mahogany and bronze frame with rivets, painted behind the panel.
class HudSkin:
	extends Control

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var bands := 18
		for i in bands:
			var t := float(i) / float(bands - 1)
			draw_rect(Rect2(0.0, h * float(i) / float(bands), w, h / float(bands) + 1.0),
				GameHUD.C_PANEL_TOP.lerp(GameHUD.C_PANEL_BOT, t))
		for i in 13:
			var y := h * (0.08 + float(i) * 0.071) + sin(float(i) * 4.7) * 5.0
			draw_line(Vector2(9.0, y), Vector2(w - 9.0, y + sin(float(i) * 2.1) * 3.0),
				Color(0.44, 0.25, 0.14, 0.055), 1.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.018, 0.012), false, 2.0)
		draw_rect(Rect2(3.0, 3.0, w - 6.0, h - 6.0), GameHUD.C_FRAME, false, 5.0)
		draw_line(Vector2(5.0, 5.0), Vector2(w - 5.0, 5.0), GameHUD.C_FRAME_HI, 2.0)
		draw_line(Vector2(5.0, 5.0), Vector2(5.0, h - 5.0), GameHUD.C_FRAME_HI, 1.0)
		draw_line(Vector2(5.0, h - 5.0), Vector2(w - 5.0, h - 5.0), Color(0.035, 0.018, 0.010), 3.0)
		draw_line(Vector2(w - 5.0, 5.0), Vector2(w - 5.0, h - 5.0), Color(0.08, 0.045, 0.025), 2.0)
		draw_rect(Rect2(9.0, 9.0, w - 18.0, h - 18.0), Color(0.03, 0.016, 0.010, 0.52), false, 1.0)
		draw_rect(Rect2(12.0, 12.0, w - 24.0, h - 24.0), Color(0.40, 0.27, 0.15, 0.30), false, 1.0)
		var rivets: Array[Vector2] = [
			Vector2(12.0, 14.0), Vector2(w - 12.0, 14.0), Vector2(12.0, h - 14.0), Vector2(w - 12.0, h - 14.0),
			Vector2(w * 0.5, 14.0), Vector2(w * 0.5, h - 14.0), Vector2(12.0, h * 0.5), Vector2(w - 12.0, h * 0.5),
		]
		for p in rivets:
			draw_circle(p, 4.0, Color(0.24, 0.14, 0.08))
			draw_circle(p, 3.0, Color(0.72, 0.54, 0.29))
			draw_circle(p - Vector2(0.6, 0.8), 1.2, Color(0.99, 0.89, 0.58))
			draw_circle(p + Vector2(0.8, 1.0), 1.4, Color(0.25, 0.14, 0.07))


## Tall blue-and-green Atreides power spine with a crystal at its foot.
class PowerBar:
	extends Control

	var generated := 0.0
	var used := 0.0
	var _clock := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		_clock += delta
		if used > generated + 0.01:
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var gem := Vector2(w * 0.5, h - 7.5)
		var span_top := 3.0
		var span_bottom := h - 17.0
		var span := maxf(span_bottom - span_top, 8.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.018, 0.014, 0.94))
		draw_rect(Rect2(Vector2(0.5, 0.5), size - Vector2(1.0, 1.0)), Color(0.38, 0.25, 0.12, 0.9), false, 1.0)
		var rail := Rect2(w * 0.20, span_top, w * 0.60, span)
		draw_rect(rail, Color(0.018, 0.045, 0.080, 1.0))
		draw_rect(Rect2(rail.position.x - 1.5, rail.position.y, 2.0, rail.size.y), Color(0.10, 0.30, 0.52, 0.96))
		draw_rect(Rect2(rail.end.x - 0.5, rail.position.y, 2.0, rail.size.y), Color(0.10, 0.30, 0.52, 0.96))
		var deficit := used > generated + 0.01
		var near := not deficit and (generated - used) <= maxf(generated * 0.15, 1.0)
		var lit_color := Color(0.94, 0.32, 0.20) if deficit else (Color(0.96, 0.76, 0.20) if near else Color(0.36, 0.68, 0.18))
		if deficit:
			lit_color.a = 0.58 + 0.42 * absf(sin(_clock * 7.0))
		var segments := 28
		var cap := maxf(maxf(generated, used), 1.0)
		var seg_step := span / float(segments)
		for i in segments:
			var threshold := float(i + 1) / float(segments) * cap
			var lit := generated + 0.01 >= threshold
			var y := span_bottom - float(i + 1) * seg_step + 1.2
			var sh := maxf(seg_step - 2.0, 1.0)
			draw_rect(Rect2(rail.position.x + 2.0, y, rail.size.x - 4.0, sh),
				lit_color if lit else Color(0.055, 0.032, 0.022, 1.0))
			if lit:
				draw_line(Vector2(rail.position.x + 3.0, y + 0.5), Vector2(rail.end.x - 3.0, y + 0.5),
					lit_color.lightened(0.34), 1.0)
		var drain_y := span_bottom - clampf(used / cap, 0.0, 1.0) * span
		draw_line(Vector2(0.0, drain_y), Vector2(w, drain_y), Color(1.0, 0.93, 0.63, 0.96), 1.5)
		draw_line(Vector2(0.0, drain_y + 1.0), Vector2(w, drain_y + 1.0), Color(0.02, 0.01, 0.005, 0.9), 1.0)
		# Bronze collar and blue Atreides crystal at the base.
		draw_circle(gem, 7.1, Color(0.10, 0.065, 0.035))
		draw_circle(gem, 6.2, Color(0.32, 0.22, 0.10))
		draw_circle(gem, 5.0, Color(0.04, 0.10, 0.22))
		draw_circle(gem, 4.2, Color(0.11, 0.32, 0.66))
		draw_circle(gem - Vector2(1.4, 1.6), 1.8, Color(0.58, 0.82, 1.0, 0.92))


## Gold credit orb next to the credit count.
class CoinIcon:
	extends Control

	func _draw() -> void:
		var c := size * 0.5
		draw_circle(c, size.x * 0.46, Color(0.12, 0.08, 0.05))
		draw_circle(c, size.x * 0.40, GameHUD.C_GOLD)
		draw_circle(c - Vector2(size.x * 0.10, size.x * 0.10), size.x * 0.16, Color(0.99, 0.90, 0.62))


## Transparent command hotspot drawn over the shell's baked action icon.
class ActionIcon:
	extends Control

	signal tapped
	var glyph := "repair"
	var caption := "REPAIR"
	var active := false
	var enabled := true
	var _hover := false
	var _clock := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _process(delta: float) -> void:
		_clock += delta
		if active:
			queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		var hit := false
		if event is InputEventMouseButton:
			hit = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
		elif event is InputEventScreenTouch:
			hit = event.pressed and event.index <= 0
		if hit:
			accept_event()
			if enabled:
				tapped.emit()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			_hover = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			_hover = false
			queue_redraw()

	func _arch_points(r: Rect2) -> PackedVector2Array:
		return PackedVector2Array([
			r.position + Vector2(2.0, r.size.y),
			r.position + Vector2(2.0, 5.0),
			r.position + Vector2(7.0, 1.0),
			r.position + Vector2(r.size.x - 7.0, 1.0),
			r.position + Vector2(r.size.x - 2.0, 5.0),
			r.position + Vector2(r.size.x - 2.0, r.size.y),
		])

	func _draw() -> void:
		var r := Rect2(Vector2(1.0, 1.0), size - Vector2(2.0, 2.0))
		if not enabled:
			var dim := _arch_points(r)
			draw_colored_polygon(dim, Color(0.02, 0.012, 0.008, 0.62))
			return
		if active:
			var pulse := 0.58 + 0.42 * absf(sin(_clock * 5.2))
			var pts := _arch_points(r)
			var closed := pts.duplicate()
			closed.append(pts[0])
			draw_colored_polygon(pts, Color(1.0, 0.76, 0.22, 0.06 + 0.05 * pulse))
			draw_polyline(closed, Color(1.0, 0.82, 0.36, 0.55 + 0.40 * pulse), 2.0)
		elif _hover:
			var pts := _arch_points(r)
			var closed := pts.duplicate()
			closed.append(pts[0])
			draw_colored_polygon(pts, Color(1.0, 0.82, 0.42, 0.07))
			draw_polyline(closed, Color(1.0, 0.90, 0.55, 0.88), 1.5)


## Glow over the shell's central amber orb; also focuses the home base.
class StatusOrb:
	extends Control

	signal tapped
	var level := "ok"
	var caption := "GRID OK"
	var _clock := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _gui_input(event: InputEvent) -> void:
		var hit := false
		if event is InputEventMouseButton:
			hit = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
		elif event is InputEventScreenTouch:
			hit = event.pressed and event.index <= 0
		if hit:
			accept_event()
			tapped.emit()

	func _process(delta: float) -> void:
		_clock += delta
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var rad := minf(size.x, size.y) * 0.39
		var col := Color(1.0, 0.73, 0.24)
		if level == "bad":
			col = Color(1.0, 0.30, 0.16)
		var pulse := 0.55 + 0.45 * absf(sin(_clock * (4.4 if level == "bad" else 1.9)))
		draw_circle(c, rad + 2.0, Color(col.r, col.g, col.b, 0.035 + 0.035 * pulse))
		draw_arc(c, rad, -PI * 0.80, PI * 0.80, 24, Color(1.0, 0.78, 0.32, 0.20 + 0.16 * pulse), 1.0)
		draw_arc(c, rad - 2.2, PI * 0.15, PI * 0.85, 14, Color(1.0, 0.91, 0.63, 0.42), 1.0)


## Dark bronze HUD plate behind the mission objective tracker. Matches the
## credits cradle so the tracker stays legible over bright sand and rock.
class ObjectivePlate:
	extends Control

	var accent := GameHUD.C_GOLD

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.022, 0.028, 0.025, 0.95))
		draw_rect(r, GameHUD.C_FRAME, false, 2.0)
		draw_line(Vector2(3.0, 3.0), Vector2(size.x - 3.0, 3.0), GameHUD.C_FRAME_HI, 1.0)
		draw_rect(Rect2(8.0, 7.0, size.x - 16.0, size.y - 14.0), Color(0.013, 0.018, 0.016), false, 1.0)
		draw_rect(Rect2(4.0, 5.0, 3.0, size.y - 10.0), Color(accent.r, accent.g, accent.b, 0.92))
		draw_rect(Rect2(7.0, 5.0, 1.0, size.y - 10.0), Color(accent.r, accent.g, accent.b, 0.24))
		for x in [9.0, size.x - 9.0]:
			for y in [8.0, size.y - 8.0]:
				draw_circle(Vector2(x, y), 2.1, GameHUD.C_BRASS)
				draw_circle(Vector2(x, y) + Vector2(-0.4, -0.5), 0.8, Color(1.0, 0.9, 0.58))
		draw_line(Vector2(12.0, size.y - 7.0), Vector2(size.x - 12.0, size.y - 7.0),
			Color(0.35, 0.22, 0.11, 0.58), 1.0)


## Compact opening objective flash, same bronze language as the tracker.
class ToastPlate:
	extends Control

	var accent := GameHUD.C_GOLD

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.020, 0.026, 0.023, 0.97))
		draw_rect(r, GameHUD.C_FRAME, false, 2.0)
		draw_line(Vector2(3.0, 3.0), Vector2(size.x - 3.0, 3.0), GameHUD.C_FRAME_HI, 1.0)
		draw_rect(Rect2(3.0, 3.0, 5.0, size.y - 6.0), Color(accent.r, accent.g, accent.b, 0.88))
		draw_rect(Rect2(size.x - 8.0, 3.0, 5.0, size.y - 6.0), Color(accent.r, accent.g, accent.b, 0.88))
		draw_rect(Rect2(11.0, 6.0, size.x - 22.0, size.y - 12.0), Color(0.010, 0.015, 0.013), false, 1.0)
		for x in [10.0, size.x - 10.0]:
			draw_circle(Vector2(x, 9.0), 2.0, GameHUD.C_BRASS)
			draw_circle(Vector2(x, size.y - 9.0), 2.0, GameHUD.C_BRASS)


## Dark steel digital credits cradle shown above the battlefield.
class CreditsPlate:
	extends Control

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.025, 0.032, 0.030, 0.96))
		draw_rect(r, GameHUD.C_FRAME, false, 2.0)
		draw_line(Vector2(3.0, 3.0), Vector2(size.x - 3.0, 3.0), GameHUD.C_FRAME_HI, 1.0)
		draw_rect(Rect2(8.0, 7.0, size.x - 16.0, size.y - 14.0), Color(0.015, 0.020, 0.019), false, 1.0)
		for x in [8.0, size.x - 8.0]:
			for y in [7.0, size.y - 7.0]:
				draw_circle(Vector2(x, y), 2.2, GameHUD.C_BRASS)
				draw_circle(Vector2(x, y) + Vector2(-0.4, -0.5), 0.9, Color(1.0, 0.9, 0.58))
		draw_line(Vector2(10.0, size.y - 10.0), Vector2(size.x - 10.0, size.y - 10.0), Color(0.35, 0.22, 0.11, 0.58), 1.0)


## Transparent hit area over the shell's baked brass scroll chevrons.
class ScrollArrow:
	extends Control

	signal tapped
	var direction := -1
	var _hover := false
	var _down := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _gui_input(event: InputEvent) -> void:
		var hit := false
		if event is InputEventMouseButton:
			if not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				_down = false
				queue_redraw()
				return
			hit = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
		elif event is InputEventScreenTouch:
			if not event.pressed:
				_down = false
				queue_redraw()
				return
			hit = event.pressed and event.index <= 0
		if hit:
			accept_event()
			_down = true
			queue_redraw()
			tapped.emit()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			_hover = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			_hover = false
			_down = false
			queue_redraw()

	func _draw() -> void:
		if not _hover and not _down:
			return
		var r := Rect2(Vector2(1.5, 2.0), size - Vector2(3.0, 4.0))
		draw_colored_polygon(PackedVector2Array([
			r.position, r.position + Vector2(r.size.x, 0.0),
			r.position + Vector2(r.size.x - 3.0, r.size.y - 2.0),
			r.position + Vector2(0.0, r.size.y - 2.0),
		]), Color(1.0, 0.78, 0.30, 0.12 if _hover else 0.18))
		draw_rect(r, Color(1.0, 0.86, 0.48, 0.54), false, 1.0)
		var c := size * 0.5
		var w := minf(size.x, size.y) * 0.20
		var tip := c + Vector2(0.0, -w * 0.65 if direction < 0 else w * 0.65)
		var base_y := c.y + w * 0.55 if direction < 0 else c.y - w * 0.55
		draw_colored_polygon(PackedVector2Array([
			Vector2(c.x - w, base_y), Vector2(c.x + w, base_y), tip,
		]), Color(1.0, 0.88, 0.48, 0.80))


## Small Atreides hawk crest beside the panel title.
class HouseCrest:
	extends Control

	func _draw() -> void:
		var c := size * 0.5
		var blue := GameHUD.C_BLUE.lightened(0.18)
		var gold := GameHUD.C_GOLD
		draw_circle(c, minf(size.x, size.y) * 0.48, Color(0.07, 0.08, 0.07))
		draw_circle(c, minf(size.x, size.y) * 0.44, Color(0.30, 0.22, 0.12), false, 1.5)
		var wings := PackedVector2Array([
			c + Vector2(0.0, -7.0), c + Vector2(4.0, -3.0), c + Vector2(9.0, -5.0),
			c + Vector2(5.0, 1.0), c + Vector2(8.0, 5.0), c + Vector2(2.0, 4.0),
			c + Vector2(0.0, 8.0), c + Vector2(-2.0, 4.0), c + Vector2(-8.0, 5.0),
			c + Vector2(-5.0, 1.0), c + Vector2(-9.0, -5.0), c + Vector2(-4.0, -3.0),
		])
		draw_colored_polygon(wings, blue)
		draw_polyline(wings + PackedVector2Array([wings[0]]), gold, 1.0)
		draw_circle(c + Vector2(0.0, -1.0), 2.0, gold)


## Portrait build slot with miniature status grid, production sweep, queue badge,
## READY flash and touch cancel badge.
class BuildTile:
	extends Control

	signal tapped
	signal secondary
	signal cancel_pressed

	var kind := "structure"
	var item_id := ""
	var cost := 0
	var caption := ""
	var accent := Color(0.25, 0.58, 0.95)
	var available := true
	var hovered := false
	var queue_count := 0
	var progress := 0.0
	var ready_state := false
	var game
	var touch_suppressed := false
	var cancel_flash := 0.0
	var _holding := false
	var _hold_index := -1
	var _hold_started_ms := 0
	var _hold_pos := Vector2.ZERO
	var _hold_fired := false
	var _ignore_release := false

	const TOP := Color("4b2a18")
	const BOTTOM := Color("1a0c09")
	const SAND_TEX := preload("res://assets/sprites/d2/terrain_sand.png")
	const ROCK_TEX := preload("res://assets/sprites/d2/terrain_rock.png")
	# #14100CE6 plate, #F2C96B afford / #E05252 cannot-afford text.
	const COST_PLATE := Color(20.0 / 255.0, 16.0 / 255.0, 12.0 / 255.0, 0.90)
	const COST_OUTLINE := Color(0.025, 0.018, 0.012, 0.94)
	const COST_GOLD := Color(242.0 / 255.0, 201.0 / 255.0, 107.0 / 255.0)
	const COST_RED := Color(224.0 / 255.0, 82.0 / 255.0, 82.0 / 255.0)
	const NAME_PLATE := Color(0.055, 0.030, 0.018, 0.96)
	const NAME_RULE := Color(0.55, 0.37, 0.18, 0.90)

	func can_cancel() -> bool:
		return queue_count > 0 or ready_state

	func _touch_blocked() -> bool:
		if touch_suppressed:
			return true
		return game != null and game.camera != null and game.camera.is_gesture_suppressed()

	func cancel_rect() -> Rect2:
		return Rect2(size.x - 30.0, 1.0, 29.0, 26.0)

	func _process(delta: float) -> void:
		if cancel_flash > 0.0:
			cancel_flash = maxf(0.0, cancel_flash - delta)
			queue_redraw()
		if _holding:
			if _touch_blocked():
				_holding = false
				_ignore_release = true
				return
			if not _hold_fired and Time.get_ticks_msec() - _hold_started_ms >= 400 and can_cancel():
				_hold_fired = true
				cancel_flash = 0.32
				cancel_pressed.emit()
				queue_redraw()

	func flash_cancel() -> void:
		cancel_flash = 0.32
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			hovered = true
			queue_redraw()
			return
		if _touch_blocked() and (event is InputEventScreenTouch or event is InputEventScreenDrag):
			if event is InputEventScreenTouch and not event.pressed:
				_holding = false
				_ignore_release = true
				_hold_fired = false
			return
		if event is InputEventMouseButton:
			if not event.pressed:
				if event.button_index != MOUSE_BUTTON_LEFT:
					return
				if _holding:
					_holding = false
					accept_event()
					if not _hold_fired and not _ignore_release:
						tapped.emit()
					_hold_fired = false
					_ignore_release = false
				return
			if event.button_index == MOUSE_BUTTON_RIGHT:
				accept_event()
				secondary.emit()
				return
			if event.button_index != MOUSE_BUTTON_LEFT:
				return
		elif event is InputEventScreenTouch:
			if event.index > 0:
				return
			if not event.pressed:
				if _holding and _hold_index == event.index:
					_holding = false
					accept_event()
					if not _hold_fired and not _ignore_release:
						tapped.emit()
					_hold_fired = false
					_ignore_release = false
				return
		else:
			return
		if can_cancel() and cancel_rect().has_point(event.position):
			accept_event()
			cancel_flash = 0.32
			cancel_pressed.emit()
			_hold_fired = true
			_ignore_release = true
			queue_redraw()
			return
		_holding = true
		_hold_index = event.index if event is InputEventScreenTouch else -1
		_hold_started_ms = Time.get_ticks_msec()
		_hold_pos = event.position
		_hold_fired = false
		_ignore_release = false
		accept_event()

	func _ready() -> void:
		clip_contents = true

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			hovered = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			hovered = false
			queue_redraw()

	func _ellipse(c: Vector2, rx: float, ry: float, col: Color) -> void:
		var pts := PackedVector2Array()
		for i in 18:
			var a := TAU * float(i) / 18.0
			pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
		draw_colored_polygon(pts, col)

	func _draw_portrait_background(w: float, h: float) -> void:
		# A cropped patch of the actual terrain gives each slot the warm, grainy
		# diorama backdrop of the original build portraits.
		var tex: Texture2D = SAND_TEX if kind == "unit" else ROCK_TEX
		var source := Vector2(150.0, 96.0)
		var tsz := tex.get_size()
		var hsh := absi(item_id.hash())
		var sx := float(hsh % maxi(1, int(tsz.x - source.x)))
		var sy := float((hsh / 7 + hsh / 31) % maxi(1, int(tsz.y - source.y)))
		draw_texture_rect_region(tex, Rect2(0.0, 0.0, w, h), Rect2(Vector2(sx, sy), source),
			Color(0.72, 0.52, 0.37, 1.0))
		for i in 7:
			var t := float(i) / 6.0
			draw_rect(Rect2(0.0, h * float(i) / 7.0, w, h / 7.0 + 1.0),
				Color(0.055, 0.020, 0.012, 0.08 + t * 0.13))
		draw_rect(Rect2(0.0, 0.0, w, 2.0), Color(0.04, 0.018, 0.010, 0.50))
		draw_rect(Rect2(0.0, h - 2.0, w, 2.0), Color(0.02, 0.010, 0.006, 0.72))
		_ellipse(Vector2(w * 0.5, h * 0.78), w * 0.36, h * 0.12, Color(0.02, 0.010, 0.006, 0.38))
		draw_circle(Vector2(w * 0.5, h * 0.42), h * 0.54, Color(1.0, 0.76, 0.38, 0.045))
		# Slightly darker edges keep the small hero model crisp against the sand.
		draw_rect(Rect2(0.0, 0.0, 2.0, h), Color(0.02, 0.010, 0.005, 0.24))
		draw_rect(Rect2(w - 2.0, 0.0, 2.0, h), Color(0.02, 0.010, 0.005, 0.24))


	func _draw_status_grid() -> void:
		var cell := 3.6
		var gap := 1.2
		var total := cell * 3.0 + gap * 2.0
		var origin := Vector2(4.0, 4.0)
		draw_rect(Rect2(origin - Vector2(1.0, 1.0), Vector2(total + 2.0, total + 2.0)), Color(0.02, 0.012, 0.008, 0.86))
		var lit := 9
		var col := Color(0.44, 0.80, 0.25)
		if not available:
			lit = 0
			col = Color(0.52, 0.17, 0.11)
		elif ready_state:
			col = Color(1.0, 0.80, 0.24)
		elif queue_count > 0:
			lit = clampi(int(ceil(clampf(progress, 0.06, 1.0) * 9.0)), 1, 9)
			col = Color(0.74, 0.88, 0.30)
		for row in 3:
			for column in 3:
				var i := row * 3 + column
				var r := Rect2(origin + Vector2(float(column) * (cell + gap), float(row) * (cell + gap)), Vector2(cell, cell))
				draw_rect(r, col if i < lit else Color(0.12, 0.07, 0.045, 0.92))
				if i < lit:
					draw_line(r.position, r.position + Vector2(r.size.x, 0.0), col.lightened(0.45), 0.8)

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var rect := Rect2(Vector2(1.0, 1.0), Vector2(w - 2.0, h - 2.0))
		_draw_portrait_background(w, h)
		var icon: Texture2D = null
		if kind == "unit":
			icon = UnitArt.icon(item_id)
		else:
			icon = BuildingArt.icon(item_id)
		if icon != null:
			# Structures are close-up dioramas; units keep their full silhouette,
			# matching the two visual treatments in the reference portraits.
			var box := minf(w * 1.28, h * 1.42) if kind != "unit" else minf(w * 1.02, h * 1.12)
			var aspect := float(icon.get_width()) / float(icon.get_height())
			var iw := box * minf(aspect, 1.0)
			var ih := box / maxf(aspect, 0.01)
			if ih > box:
				iw *= box / ih
				ih = box
			var center := Vector2(w * 0.5, h * 0.46)
			draw_texture_rect(icon, Rect2(center - Vector2(iw, ih) * 0.5, Vector2(iw, ih)), false)
		else:
			var cap := caption.to_upper()
			draw_string(get_theme_default_font(), Vector2(4.0, h * 0.55), cap, HORIZONTAL_ALIGNMENT_CENTER,
				w - 8.0, GameDefs.fs(12), Color(0.92, 0.83, 0.64, 0.95))
		if not available:
			draw_rect(rect, Color(0.02, 0.012, 0.008, 0.48))
		if progress > 0.001 and not ready_state:
			var lit_h := (h - 4.0) * clampf(progress, 0.0, 1.0)
			draw_rect(Rect2(2.0, h - 3.0 - lit_h, w - 4.0, lit_h), Color(0.48, 0.86, 0.20, 0.13))
			draw_line(Vector2(2.0, h - 2.0 - lit_h), Vector2(w - 2.0, h - 2.0 - lit_h), Color(0.88, 1.0, 0.52, 0.82), 1.4)
		if kind != "unit":
			_draw_status_grid()
		draw_rect(rect, Color(0.08, 0.045, 0.025, 0.98), false, 1.0)
		var font := get_theme_default_font()
		# Name plate: the portrait is cropped hero art, so a solid bottom strip
		# keeps every build and unit readable without shrinking the icon area.
		if icon != null and caption != "":
			var name_fs := GameDefs.fs(10)
			# Size the plate from real font metrics and reserve a clean 3 px
			# inside its bottom edge. Queue and cancel badges own the top-right,
			# so the label keeps this full-width bottom lane without crowding
			# the tile border on either desktop or the scaled phone UI.
			var name_ascent := font.get_ascent(name_fs)
			var name_descent := font.get_descent(name_fs)
			var name_pad_top := 2.0
			var name_pad_bottom := 3.0
			var band_h := name_ascent + name_descent + name_pad_top + name_pad_bottom
			var band := Rect2(2.0, h - band_h - 2.0, w - 4.0, band_h)
			draw_rect(band, NAME_PLATE)
			draw_line(Vector2(band.position.x, band.position.y),
				Vector2(band.end.x, band.position.y), NAME_RULE, 1.0)
			var name_col := GameHUD.C_CREAM if available else GameHUD.C_DIM
			var name_text := GameDefs.fit_text(font, caption, band.size.x - 6.0, name_fs, 1)
			var name_base := band.position.y + name_pad_top + name_ascent
			draw_string(font, Vector2(band.position.x + 3.0, name_base + 1.0), name_text,
				HORIZONTAL_ALIGNMENT_CENTER, band.size.x - 6.0, name_fs, Color(0.0, 0.0, 0.0, 0.95))
			draw_string(font, Vector2(band.position.x + 3.0, name_base), name_text,
				HORIZONTAL_ALIGNMENT_CENTER, band.size.x - 6.0, name_fs, name_col)
		if queue_count > 0:
			var badge := str(queue_count)
			var badge_fs := GameDefs.fs(13)
			var bw := maxf(22.0, font.get_string_size(badge, HORIZONTAL_ALIGNMENT_LEFT, -1, badge_fs).x + 9.0)
			var bh := float(badge_fs) + 8.0
			var reserve := 35.0 if can_cancel() else 3.0
			var br := Rect2(w - bw - reserve, 2.0, bw, bh)
			draw_rect(br, Color(0.035, 0.020, 0.012, 0.97))
			draw_rect(br, Color(0.90, 0.72, 0.36, 0.98), false, 1.0)
			var baseline := br.position.y + (bh + font.get_ascent(badge_fs) - font.get_descent(badge_fs)) * 0.5
			draw_string(font, Vector2(br.position.x, baseline), badge, HORIZONTAL_ALIGNMENT_CENTER,
				bw, badge_fs, Color(1.0, 0.95, 0.76))
		if can_cancel():
			var cr := cancel_rect()
			var pulse := 1.0 if cancel_flash > 0.0 else 0.84
			var c := cr.get_center()
			draw_circle(c, 10.5, Color(0.16, 0.028, 0.014, 0.97))
			draw_circle(c, 10.0, Color(1.0, 0.50, 0.26, pulse), false, 1.8)
			draw_circle(c, 9.0, Color(0.13, 0.022, 0.012, 0.96))
			draw_line(c + Vector2(-4.6, -4.6), c + Vector2(4.6, 4.6), Color(1.0, 0.94, 0.76, pulse), 2.4)
			draw_line(c + Vector2(4.6, -4.6), c + Vector2(-4.6, 4.6), Color(1.0, 0.94, 0.76, pulse), 2.4)
		if ready_state:
			var pulse := 0.58 + 0.42 * absf(sin(Time.get_ticks_msec() * 0.006))
			draw_rect(rect, Color(1.0, 0.84, 0.28, 0.52 + 0.38 * pulse), false, 1.6)
			var ready_fs := GameDefs.fs(13)
			var band_h := float(ready_fs) + 6.0
			var badge_bottom := 2.0 + float(GameDefs.fs(13)) + 8.0 if queue_count > 0 else 0.0
			var band := Rect2(3.0, maxf(h * 0.32, badge_bottom + 2.0), w - 6.0, band_h)
			draw_rect(band, Color(0.045, 0.030, 0.012, 0.92))
			var baseline := band.position.y + (band_h + font.get_ascent(ready_fs) - font.get_descent(ready_fs)) * 0.5
			draw_string(font, Vector2(band.position.x, baseline), "READY",
				HORIZONTAL_ALIGNMENT_CENTER, band.size.x, ready_fs, Color(1.0, 0.87, 0.32, pulse))
		# Top-right price plate: the bottom belongs to the name plate now, and
		# the already-paid price yields whenever a queue or READY badge needs
		# that corner. The text redraws every HUD refresh.
		if cost > 0 and not can_cancel():
			var cost_font := get_theme_default_font()
			var cost_fs := GameDefs.fs(13)
			var cost_text := "$%d" % cost
			var cost_size := cost_font.get_string_size(cost_text, HORIZONTAL_ALIGNMENT_LEFT, -1, cost_fs)
			var plate_w := maxf(26.0, ceilf(cost_size.x) + 9.0)
			var plate_h := float(cost_fs) + 6.0
			var plate := Rect2(w - plate_w - 3.0, 3.0, plate_w, plate_h)
			var affordable := true
			if game != null:
				affordable = int(game.credits[0]) >= cost
			var cost_col := COST_GOLD if affordable else COST_RED
			draw_rect(plate, COST_PLATE)
			draw_rect(plate, COST_OUTLINE, false, 1.0)
			var baseline := plate.position.y + (plate_h + cost_font.get_ascent(cost_fs) - cost_font.get_descent(cost_fs)) * 0.5
			var tx := plate.position.x + 4.5
			draw_string(cost_font, Vector2(tx + 1.0, baseline + 1.0), cost_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, cost_fs, Color(0.0, 0.0, 0.0, 0.95))
			draw_string(cost_font, Vector2(tx, baseline), cost_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, cost_fs, cost_col)
		if cancel_flash > 0.0:
			draw_rect(Rect2(Vector2(1.0, 1.0), size - Vector2(2.0, 2.0)), Color(1.0, 0.28, 0.12, 0.15))
			draw_rect(Rect2(Vector2(1.0, 1.0), size - Vector2(2.0, 2.0)), Color(1.0, 0.58, 0.28, 0.76), false, 1.5)
		if hovered:
			draw_rect(rect, Color(1.0, 0.85, 0.44, 0.86), false, 1.2)


# -------------------------------------------------------------------- setup

func setup(g) -> void:
	game = g
	layer = 5
	_build_panel()
	_build_overlay()
	_rebuild_grid()
	refresh()
	_show_objective_toast()

func _inset_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_INSET
	sb.border_color = C_FRAME
	sb.set_border_width_all(2)
	return sb

func _button_style(bg: Color, h_margin := 5.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = C_FRAME
	sb.set_border_width_all(1)
	sb.content_margin_left = h_margin
	sb.content_margin_right = h_margin
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	return sb

## Rusted maroon build recess that fills the middle of the replica shell.
class BuildBackdrop:
	extends Control

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var top := Color(0.25, 0.11, 0.075)
		var bottom := Color(0.105, 0.045, 0.032)
		for i in 12:
			var t := float(i) / 11.0
			draw_rect(Rect2(0.0, h * float(i) / 12.0, w, h / 12.0 + 1.0), top.lerp(bottom, t))
		for i in 17:
			var x := fmod(12.0 + float(i) * 47.0, w)
			var y := fmod(9.0 + float(i) * 71.0, h)
			draw_line(Vector2(x, y), Vector2(minf(w, x + 11.0), minf(h, y + 20.0)),
				Color(0.58, 0.30, 0.14, 0.10), 1.0)
		draw_line(Vector2(0.0, 2.0), Vector2(w, 2.0), Color(0.67, 0.45, 0.20, 0.46), 2.0)
		draw_line(Vector2(0.0, h - 3.0), Vector2(w, h - 3.0), Color(0.02, 0.01, 0.006, 0.85), 3.0)
		draw_rect(Rect2(Vector2(0.5, 0.5), size - Vector2(1.0, 1.0)), Color(0.45, 0.29, 0.13, 0.70), false, 1.0)
		var divider_x := 65.0 * GameHUD.SHELL_SCALE
		draw_line(Vector2(divider_x, 4.0), Vector2(divider_x, h - 4.0), Color(0.03, 0.015, 0.008, 0.82), 3.0)
		draw_line(Vector2(divider_x + 2.0, 4.0), Vector2(divider_x + 2.0, h - 4.0), Color(0.48, 0.30, 0.14, 0.42), 1.0)


func _ref_rect(x: float, y: float, w: float, h: float) -> Rect2:
	return Rect2(Vector2(x, y) * SHELL_SCALE, Vector2(w, h) * SHELL_SCALE)


func _add_action(parent: Control, glyph: String, caption: String, tip: String, rect: Rect2, action: Callable) -> ActionIcon:
	var b := ActionIcon.new()
	b.glyph = glyph
	b.caption = caption
	b.tooltip_text = tip
	b.position = rect.position
	b.size = rect.size
	b.tapped.connect(func(): _tap(); action.call())
	parent.add_child(b)
	return b


func _build_panel() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	root.offset_left = -PANEL_WIDTH
	root.offset_top = 0.0
	root.offset_right = 0.0
	root.offset_bottom = 0.0
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	# The supplied 160x404 shell is the visual master: its carved frame, radar
	# bezel, action icons and bottom brass scroll buttons remain pixel-faithful.
	var fallback := ColorRect.new()
	fallback.color = Color(0.055, 0.025, 0.018)
	fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fallback)
	var shell := TextureRect.new()
	shell.texture = load(SHELL_TEXTURE)
	shell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shell.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shell.stretch_mode = TextureRect.STRETCH_SCALE
	shell.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	shell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(shell)

	var radar_rect := _ref_rect(14.0, 13.0, 132.0, 130.0)
	minimap = Minimap.new()
	minimap.position = radar_rect.position
	minimap.size = radar_rect.size
	minimap.setup(game)
	root.add_child(minimap)

	repair_button = _add_action(root, "repair", "REPAIR", "Repair: tap a damaged building",
		_ref_rect(7.0, 142.0, 32.0, 37.0), func(): game.toggle_repair())
	sell_button = _add_action(root, "sell", "SELL", "Sell: 50% refund and two infantry",
		_ref_rect(39.0, 142.0, 32.0, 37.0), func(): game.sell_selected_building())
	guard_button = _add_action(root, "guard", "GUARD", "Guard units or set a structure rally",
		_ref_rect(103.0, 142.0, 32.0, 37.0), func(): game.guard_or_rally())
	hammer_button = _add_action(root, "options", "OPTIONS", "Command options",
		_ref_rect(135.0, 142.0, 20.0, 37.0), func(): _toggle_options())

	status_orb = StatusOrb.new()
	var orb_rect := _ref_rect(68.0, 139.0, 37.0, 43.0)
	status_orb.position = orb_rect.position
	status_orb.size = orb_rect.size
	status_orb.tooltip_text = "Power grid status - tap to focus the base"
	status_orb.tapped.connect(func(): _tap(); game.focus_home())
	root.add_child(status_orb)

	var build_rect := _ref_rect(18.0, 187.0, 131.0, 182.0)
	var build_bg := BuildBackdrop.new()
	build_bg.position = build_rect.position
	build_bg.size = build_rect.size
	build_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(build_bg)

	var left := _make_build_column(_ref_rect(21.0, 190.0, 59.0, 172.0))
	structure_scroll = left["scroll"]
	structure_grid = left["list"]
	root.add_child(left["control"])
	var right := _make_build_column(_ref_rect(85.0, 190.0, 60.0, 172.0))
	unit_scroll = right["scroll"]
	unit_grid = right["list"]
	root.add_child(right["control"])

	power_bar = PowerBar.new()
	var power_rect := _ref_rect(7.0, 191.0, 10.0, 179.0)
	power_bar.position = power_rect.position
	power_bar.size = power_rect.size
	root.add_child(power_bar)

	var arrow_specs := [
		[_ref_rect(21.0, 374.0, 29.0, 27.0), -1, structure_scroll, "Scroll structures up"],
		[_ref_rect(50.0, 374.0, 30.0, 27.0), 1, structure_scroll, "Scroll structures down"],
		[_ref_rect(85.0, 374.0, 30.0, 27.0), -1, unit_scroll, "Scroll units up"],
		[_ref_rect(115.0, 374.0, 30.0, 27.0), 1, unit_scroll, "Scroll units down"],
	]
	for spec in arrow_specs:
		var arrow := ScrollArrow.new()
		arrow.position = spec[0].position
		arrow.size = spec[0].size
		arrow.direction = int(spec[1])
		arrow.tooltip_text = String(spec[3])
		var scroll = spec[2]
		var dir := int(spec[1])
		arrow.tapped.connect(func(): _scroll_column(scroll, dir))
		root.add_child(arrow)

	_build_top_bar()
	_build_screen_overlay()


func _make_build_column(rect: Rect2) -> Dictionary:
	var scroll := ScrollContainer.new()
	scroll.position = rect.position
	scroll.size = rect.size
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.follow_focus = true
	var list := VBoxContainer.new()
	list.custom_minimum_size = Vector2(rect.size.x, 0.0)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", BUILD_ROW_REF_GAP * SHELL_SCALE)
	scroll.add_child(list)
	return {"control": scroll, "scroll": scroll, "list": list}


func _scroll_column(scroll: ScrollContainer, direction: int) -> void:
	if scroll == null:
		return
	var step := int(round((BUILD_ROW_REF_H + BUILD_ROW_REF_GAP) * SHELL_SCALE))
	_scroll_tween(scroll, scroll.scroll_vertical + direction * step)


func _build_screen_overlay() -> void:
	var ui := Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ui)

	var status_fs := GameDefs.fs(16)
	var info_fs := GameDefs.fs(13)
	var footer_pad := 6.0
	var footer_style := StyleBoxFlat.new()
	footer_style.bg_color = Color(0.045, 0.028, 0.018, 0.90)
	footer_style.border_color = Color(0.62, 0.45, 0.23, 0.80)
	footer_style.set_border_width_all(1)
	footer_style.content_margin_left = 10.0
	footer_style.content_margin_right = 10.0
	footer_style.content_margin_top = footer_pad
	footer_style.content_margin_bottom = footer_pad
	screen_footer = PanelContainer.new()
	screen_footer.anchor_left = 0.0
	screen_footer.anchor_top = 1.0
	screen_footer.anchor_right = 1.0
	screen_footer.anchor_bottom = 1.0
	screen_footer.offset_left = 12.0
	screen_footer.offset_right = -PANEL_WIDTH - 262.0
	# The panel grows with the font metrics so the two lines never clip.
	var status_h := float(status_fs) + 5.0
	var info_h := float(info_fs) + 4.0
	var footer_h := status_h + info_h + footer_pad * 2.0 + 2.0
	screen_footer.offset_top = -(footer_h + 8.0)
	screen_footer.offset_bottom = -8.0
	screen_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_footer.add_theme_stylebox_override("panel", footer_style)
	ui.add_child(screen_footer)
	var footer_col := VBoxContainer.new()
	footer_col.add_theme_constant_override("separation", 0)
	screen_footer.add_child(footer_col)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", status_fs)
	status_label.add_theme_color_override("font_color", C_STATUS)
	status_label.add_theme_color_override("font_shadow_color", Color(0.01, 0.01, 0.01, 0.95))
	status_label.add_theme_constant_override("shadow_offset_x", 1)
	status_label.add_theme_constant_override("shadow_offset_y", 2)
	status_label.clip_text = true
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_label.custom_minimum_size = Vector2(0.0, status_h)
	footer_col.add_child(status_label)
	info_label = Label.new()
	info_label.add_theme_font_size_override("font_size", info_fs)
	info_label.add_theme_color_override("font_color", C_INFO)
	info_label.add_theme_color_override("font_shadow_color", Color(0.01, 0.01, 0.01, 0.90))
	info_label.add_theme_constant_override("shadow_offset_x", 1)
	info_label.add_theme_constant_override("shadow_offset_y", 1)
	info_label.clip_text = true
	info_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info_label.custom_minimum_size = Vector2(0.0, info_h)
	footer_col.add_child(info_label)
	log_label = Label.new()
	log_label.add_theme_font_size_override("font_size", GameDefs.fs(12))
	log_label.visible = false
	ui.add_child(log_label)

	cancel_button = Button.new()
	cancel_button.text = "CANCEL"
	cancel_button.focus_mode = Control.FOCUS_NONE
	cancel_button.anchor_left = 1.0
	cancel_button.anchor_top = 1.0
	cancel_button.anchor_right = 1.0
	cancel_button.anchor_bottom = 1.0
	cancel_button.offset_left = -PANEL_WIDTH - 124.0
	cancel_button.offset_right = -PANEL_WIDTH - 12.0
	cancel_button.offset_top = -84.0
	cancel_button.offset_bottom = -52.0
	cancel_button.add_theme_font_size_override("font_size", GameDefs.fs(13))
	cancel_button.add_theme_color_override("font_color", C_OPTION_TEXT)
	cancel_button.add_theme_color_override("font_outline_color", Color(0.02, 0.012, 0.006, 0.95))
	cancel_button.add_theme_constant_override("outline_size", 2)
	cancel_button.add_theme_stylebox_override("normal", _button_style(Color(0.30, 0.19, 0.10)))
	cancel_button.add_theme_stylebox_override("hover", _button_style(Color(0.42, 0.28, 0.14)))
	cancel_button.add_theme_stylebox_override("pressed", _button_style(Color(0.20, 0.12, 0.06)))
	cancel_button.visible = false
	cancel_button.pressed.connect(func(): _tap(); game.cancel_current())
	ui.add_child(cancel_button)

	var quick_h := maxf(40.0, float(GameDefs.fs(14)) + 22.0)
	quick_strip = HBoxContainer.new()
	quick_strip.anchor_left = 1.0
	quick_strip.anchor_top = 1.0
	quick_strip.anchor_right = 1.0
	quick_strip.anchor_bottom = 1.0
	quick_strip.offset_left = -PANEL_WIDTH - 232.0
	quick_strip.offset_right = -PANEL_WIDTH - 12.0
	quick_strip.offset_top = -(quick_h + 8.0)
	quick_strip.offset_bottom = -8.0
	quick_strip.add_theme_constant_override("separation", 3)
	ui.add_child(quick_strip)
	for spec in [["BASE", "Focus the base", "focus_home"], ["ARMY", "Select all combat units", "select_all_army"], ["HARV", "Select harvesters", "select_all_harvesters"], ["BOX", "Next drag draws a selection box", "toggle_box"]]:
		var b := Button.new()
		b.text = String(spec[0])
		b.tooltip_text = String(spec[1])
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(46.0, quick_h)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", GameDefs.fs(14))
		b.add_theme_color_override("font_color", C_OPTION_TEXT)
		b.add_theme_color_override("font_outline_color", Color(0.02, 0.012, 0.006, 0.95))
		b.add_theme_constant_override("outline_size", 1)
		b.add_theme_stylebox_override("normal", _button_style(Color(0.15, 0.10, 0.055, 0.90), 3.0))
		b.add_theme_stylebox_override("hover", _button_style(Color(0.30, 0.21, 0.10, 0.96), 3.0))
		b.add_theme_stylebox_override("pressed", _button_style(Color(0.38, 0.28, 0.13, 0.98), 3.0))
		var method := String(spec[2])
		if method == "toggle_box":
			box_button = b
			b.toggle_mode = true
		b.pressed.connect(_on_quick.bind(method))
		quick_strip.add_child(b)


func _scroll_tween(scroll: ScrollContainer, target: int) -> void:
	var bar := scroll.get_v_scroll_bar()
	var max_scroll := int(maxf(bar.max_value - bar.page, 0.0))
	var tween := create_tween()
	tween.tween_property(scroll, "scroll_vertical", clampi(target, 0, max_scroll), 0.14).set_trans(Tween.TRANS_SINE)

func _build_top_bar() -> void:
	var top := Control.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)

	options_button = Button.new()
	options_button.text = "OPTIONS"
	options_button.focus_mode = Control.FOCUS_NONE
	options_button.position = Vector2(12.0, 10.0)
	options_button.size = Vector2(112.0, 40.0)
	options_button.add_theme_font_size_override("font_size", GameDefs.fs(14))
	options_button.add_theme_color_override("font_color", C_OPTION_TEXT)
	options_button.add_theme_color_override("font_outline_color", Color(0.02, 0.012, 0.006, 0.95))
	options_button.add_theme_constant_override("outline_size", 2)
	options_button.add_theme_stylebox_override("normal", _button_style(Color(0.12, 0.14, 0.13, 0.94)))
	options_button.add_theme_stylebox_override("hover", _button_style(Color(0.23, 0.25, 0.22, 0.98)))
	options_button.add_theme_stylebox_override("pressed", _button_style(Color(0.06, 0.08, 0.07, 0.98)))
	options_button.pressed.connect(func(): _tap(); _toggle_options())
	top.add_child(options_button)

	objective_plate = ObjectivePlate.new()
	objective_plate.anchor_left = 0.0
	objective_plate.anchor_right = 1.0
	objective_plate.offset_left = 200.0
	objective_plate.offset_right = -PANEL_WIDTH - 222.0
	objective_plate.offset_top = 7.0
	objective_plate.offset_bottom = 49.0
	objective_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	objective_plate.visible = false
	top.add_child(objective_plate)

	mission_banner = Label.new()
	mission_banner.anchor_left = 0.0
	mission_banner.anchor_right = 1.0
	mission_banner.offset_left = 208.0
	mission_banner.offset_right = -PANEL_WIDTH - 230.0
	mission_banner.offset_top = 9.0
	mission_banner.offset_bottom = 47.0
	mission_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mission_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mission_banner.add_theme_font_size_override("font_size", GameDefs.fs(16))
	mission_banner.add_theme_color_override("font_color", C_CREAM)
	mission_banner.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.98))
	mission_banner.add_theme_color_override("font_outline_color", Color(0.02, 0.012, 0.006, 0.96))
	mission_banner.add_theme_constant_override("outline_size", 2)
	mission_banner.add_theme_constant_override("shadow_offset_x", 1)
	mission_banner.add_theme_constant_override("shadow_offset_y", 2)
	mission_banner.clip_text = true
	mission_banner.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	mission_banner.visible = false
	top.add_child(mission_banner)

	toast_plate = ToastPlate.new()
	toast_plate.anchor_left = 0.5
	toast_plate.anchor_right = 0.5
	toast_plate.offset_left = -340.0
	toast_plate.offset_right = 340.0
	var toast_fs := GameDefs.fs(17)
	toast_plate.offset_top = 54.0
	toast_plate.offset_bottom = 54.0 + ThemeDB.fallback_font.get_height(toast_fs) * 2.0 + 12.0
	toast_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_plate.visible = false
	toast_plate.z_index = 2
	top.add_child(toast_plate)
	toast_label = Label.new()
	toast_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	toast_label.offset_left = 16.0
	toast_label.offset_right = -16.0
	toast_label.offset_top = 4.0
	toast_label.offset_bottom = -4.0
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast_label.add_theme_font_size_override("font_size", toast_fs)
	toast_label.add_theme_color_override("font_color", C_CREAM)
	toast_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.98))
	toast_label.add_theme_color_override("font_outline_color", Color(0.02, 0.012, 0.006, 0.96))
	toast_label.add_theme_constant_override("outline_size", 2)
	toast_label.add_theme_constant_override("shadow_offset_x", 1)
	toast_label.add_theme_constant_override("shadow_offset_y", 2)
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_label.max_lines_visible = 2
	toast_label.clip_text = true
	toast_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_plate.add_child(toast_label)

	credits_plate = CreditsPlate.new()
	credits_plate.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	credits_plate.offset_left = -PANEL_WIDTH - 208.0
	credits_plate.offset_right = -PANEL_WIDTH - 12.0
	credits_plate.offset_top = 9.0
	credits_plate.offset_bottom = 43.0
	credits_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(credits_plate)
	var coin := CoinIcon.new()
	coin.position = Vector2(10.0, 9.0)
	coin.size = Vector2(18.0, 18.0)
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	credits_plate.add_child(coin)
	credits_label = Label.new()
	credits_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	credits_label.offset_left = 34.0
	credits_label.offset_right = -10.0
	credits_label.offset_top = 5.0
	credits_label.offset_bottom = -3.0
	credits_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	credits_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	credits_label.add_theme_font_size_override("font_size", GameDefs.fs(19))
	credits_label.add_theme_color_override("font_color", C_DIGITAL)
	credits_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.12, 0.08, 0.95))
	credits_label.add_theme_constant_override("shadow_offset_x", 0)
	credits_label.add_theme_constant_override("shadow_offset_y", 1)
	credits_plate.add_child(credits_label)

	options_popup = PanelContainer.new()
	options_popup.position = Vector2(12.0, 54.0)
	options_popup.size = Vector2(286.0, 392.0)
	options_popup.z_index = 80
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.07, 0.06, 0.985)
	sb.border_color = C_FRAME_HI
	sb.set_border_width_all(2)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 9.0
	sb.content_margin_bottom = 9.0
	options_popup.add_theme_stylebox_override("panel", sb)
	options_popup.visible = false
	top.add_child(options_popup)
	var opt_col := VBoxContainer.new()
	opt_col.add_theme_constant_override("separation", 6)
	options_popup.add_child(opt_col)
	var opt_title := Label.new()
	opt_title.text = "COMMAND OPTIONS"
	opt_title.add_theme_font_size_override("font_size", GameDefs.fs(15))
	opt_title.add_theme_color_override("font_color", C_GOLD_BRIGHT)
	opt_col.add_child(opt_title)
	var opt_hint := Label.new()
	opt_hint.text = "Drag to pan. Pinch to zoom. Tap a unit, then the ground."
	opt_hint.add_theme_font_size_override("font_size", GameDefs.fs(12))
	opt_hint.add_theme_color_override("font_color", C_INFO)
	opt_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	opt_col.add_child(opt_hint)
	var resume := TouchButton.new()
	resume.text = "RESUME"
	resume.primary = true
	resume.font_size = GameDefs.fs(14)
	resume.custom_minimum_size = Vector2(0.0, 36.0)
	resume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resume.pressed.connect(func(): _tap(); options_popup.visible = false)
	opt_col.add_child(resume)
	briefing_button = TouchButton.new()
	briefing_button.text = "MISSION BRIEFING"
	briefing_button.tooltip_text = "Review the Mentat orders and primary objective"
	briefing_button.font_size = GameDefs.fs(13)
	briefing_button.custom_minimum_size = Vector2(0.0, 36.0)
	briefing_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	briefing_button.pressed.connect(func(): _tap(); _open_mission_briefing())
	opt_col.add_child(briefing_button)
	var restart := TouchButton.new()
	restart.text = "RESTART BATTLE"
	restart.font_size = GameDefs.fs(13)
	restart.custom_minimum_size = Vector2(0.0, 36.0)
	restart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restart.pressed.connect(func(): _tap(); game.restart())
	opt_col.add_child(restart)

	# House / main-menu navigation. Both land on the House Selection screen,
	# which is the campaign's front end; picking a House launches a fresh battle
	# with that roster and colour.
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 6)
	opt_col.add_child(nav)
	var change_house := TouchButton.new()
	change_house.text = "CHANGE HOUSE"
	change_house.tooltip_text = "Return to the House Selection / main menu"
	change_house.font_size = GameDefs.fs(12)
	change_house.custom_minimum_size = Vector2(0.0, 36.0)
	change_house.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	change_house.pressed.connect(func(): _tap(); _open_house_select())
	nav.add_child(change_house)
	var main_menu := TouchButton.new()
	main_menu.text = "MAIN MENU"
	main_menu.tooltip_text = "Leave the battle and choose a House"
	main_menu.font_size = GameDefs.fs(12)
	main_menu.custom_minimum_size = Vector2(0.0, 36.0)
	main_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_menu.pressed.connect(func(): _tap(); _open_house_select())
	nav.add_child(main_menu)

	# Deliberately tucked below the normal navigation, in the testing corner.
	debug_win_button = TouchButton.new()
	debug_win_button.text = "DEBUG: WIN MISSION"
	debug_win_button.font_size = GameDefs.fs(12)
	debug_win_button.accent = Color(0.92, 0.38, 0.22)
	debug_win_button.custom_minimum_size = Vector2(0.0, 36.0)
	debug_win_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	debug_win_button.tooltip_text = "Testing helper: immediately complete this mission"
	debug_win_button.pressed.connect(func(): _tap(); options_popup.visible = false; game.debug_win_mission())
	opt_col.add_child(debug_win_button)

	var test_note := Label.new()
	test_note.text = "TESTING HELPER — FORCE MISSION VICTORY"
	test_note.add_theme_font_size_override("font_size", GameDefs.fs(12))
	test_note.add_theme_color_override("font_color", Color(0.82, 0.52, 0.38))
	test_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	opt_col.add_child(test_note)

func _open_house_select() -> void:
	get_tree().change_scene_to_file("res://scenes/house_select.tscn")

func _toggle_options() -> void:
	if options_popup == null:
		return
	options_popup.visible = not options_popup.visible
	if options_popup.visible:
		options_popup.move_to_front()

func _open_mission_briefing() -> void:
	if game == null or not game.campaign_mission:
		return
	if briefing_overlay != null and is_instance_valid(briefing_overlay):
		return
	options_popup.visible = false
	var scene := load("res://scenes/mission_briefing.tscn").instantiate() as Control
	scene.set("embedded", true)
	scene.set("mission_override", game.mission.duplicate(true))
	scene.process_mode = Node.PROCESS_MODE_ALWAYS
	scene.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scene.connect("closed", _close_mission_briefing)
	briefing_overlay = scene
	add_child(scene)
	briefing_prev_game_mode = game.process_mode
	process_mode = Node.PROCESS_MODE_ALWAYS
	game.process_mode = Node.PROCESS_MODE_DISABLED

func _close_mission_briefing() -> void:
	if briefing_overlay != null and is_instance_valid(briefing_overlay):
		briefing_overlay.queue_free()
	briefing_overlay = null
	if game != null:
		game.process_mode = briefing_prev_game_mode
	process_mode = Node.PROCESS_MODE_INHERIT

func briefing_open() -> bool:
	return briefing_overlay != null and is_instance_valid(briefing_overlay)

func _on_quick(method: String) -> void:
	_tap()
	if game != null:
		game.call(method)

func _build_overlay() -> void:
	overlay = Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	add_child(overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.01, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	overlay_title = Label.new()
	overlay_title.add_theme_font_size_override("font_size", 44)
	overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(overlay_title)

	overlay_body = Label.new()
	overlay_body.add_theme_font_size_override("font_size", 18)
	overlay_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overlay_body.custom_minimum_size = Vector2(680.0, 0.0)
	box.add_child(overlay_body)

	var rule := ColorRect.new()
	rule.color = Color(0.62, 0.46, 0.22, 0.55)
	rule.custom_minimum_size = Vector2(680.0, 1.0)
	box.add_child(rule)

	overlay_buttons = VBoxContainer.new()
	overlay_buttons.add_theme_constant_override("separation", 8)
	overlay_buttons.custom_minimum_size = Vector2(360.0, 0.0)
	box.add_child(overlay_buttons)

# ------------------------------------------------------------------- actions

func _tap() -> void:
	if game != null:
		game.play_ui_sfx("ui_click", -10.0)

func _on_tab(_name: String) -> void:
	# Kept for compatibility. The classic layout has no hidden tabs: both
	# production columns are always visible.
	if game.placing != "":
		game.exit_placement()
	refresh()

func _set_tab(_name: String) -> void:
	tab = "all"
	if header_label != null:
		header_label.text = "COMMAND"
	_rebuild_grid()

func _rebuild_grid() -> void:
	if structure_grid == null or unit_grid == null:
		return
	for child in structure_grid.get_children():
		structure_grid.remove_child(child)
		child.queue_free()
	for child in unit_grid.get_children():
		unit_grid.remove_child(child)
		child.queue_free()
	buttons.clear()
	var tech: int = GameDefs.tech_level
	for item in GameDefs.structure_items(tech):
		_add_build_tile(structure_grid, item)
	# The right-hand column is the House roster, filtered by the mission's tech
	# level. Quick Skirmish uses max tech, so every unique is testable at once.
	for id in GameDefs.unit_roster(GameDefs.house_for_team(0), tech):
		_add_build_tile(unit_grid, ["unit", id])
	refresh()

func _add_build_tile(column: VBoxContainer, item: Array) -> void:
	var kind := String(item[0])
	var id := String(item[1])
	var def: Dictionary
	if kind == "structure":
		def = GameDefs.STRUCTURES[id]
	elif kind == "brush":
		def = GameDefs.BRUSHES[id]
	else:
		def = GameDefs.UNITS[id]
	var tile := BuildTile.new()
	tile.kind = kind
	tile.item_id = id
	tile.cost = int(def["cost"])
	tile.caption = _caption_for(id, String(def["name"]))
	tile.accent = GameDefs.team_color(0)
	tile.available = game.can_build(kind, id)
	var unit_word := " per tile" if kind == "brush" else ""
	tile.tooltip_text = "%s\n%d credits%s" % [String(def["name"]), int(def["cost"]), unit_word]
	if kind == "unit" and UnitArt.has_icon(id):
		tile.material = UnitArt.hud_material(0)
		tile.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	elif BuildingArt.icon(id) != null:
		tile.material = BuildingArt.hud_material(0)
		tile.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	tile.custom_minimum_size = Vector2(0.0, BUILD_ROW_REF_H * SHELL_SCALE)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.game = game
	tile.tapped.connect(func(): _on_item(kind, id))
	tile.secondary.connect(func(): _on_secondary(kind, id))
	tile.cancel_pressed.connect(func(): _on_cancel(kind, id))
	column.add_child(tile)
	buttons.append(tile)

func _caption_for(id: String, fallback: String) -> String:
	return String(TILE_NAMES.get(id, fallback)).to_upper()

func _on_secondary(kind: String, id: String) -> void:
	_tap()
	if kind == "structure" or kind == "unit":
		var cancelled: bool = game.cancel_icon(kind, id)
		if cancelled:
			Input.vibrate_handheld(35)
			_flash_cancelled_tile(kind, id)
	refresh()

func _on_cancel(kind: String, id: String) -> void:
	_tap()
	var cancelled: bool = game.cancel_icon(kind, id)
	if cancelled:
		Input.vibrate_handheld(35)
		_flash_cancelled_tile(kind, id)
	refresh()

func _flash_cancelled_tile(kind: String, id: String) -> void:
	for tile in buttons:
		if is_instance_valid(tile) and String(tile.kind) == kind and String(tile.item_id) == id:
			tile.flash_cancel()

func _on_item(kind: String, id: String) -> void:
	_tap()
	# Any sidebar tap while deploying keeps the built item READY.
	if game.placing != "":
		game.exit_placement()
		refresh()
		return
	# A completed structure is only picked up by tapping its flashing READY
	# tile. Ordinary taps still queue more units/structures.
	if kind == "structure" and game.queue_ready(kind, id):
		game.begin_ready_placement()
		refresh()
		return
	if kind == "structure":
		game.queue_structure(id)
	elif kind == "brush":
		game.begin_brush(id)
	else:
		game.queue_unit(id)
	refresh()

func show_result(win: bool, body: String, buttons: Array = [], title := "") -> void:
	overlay.visible = true
	if toast_plate != null:
		toast_plate.visible = false
		toast_timer = 0.0
	if options_popup != null:
		options_popup.visible = false
	overlay_title.text = title if title != "" else ("VICTORY" if win else "DEFEAT")
	overlay_title.add_theme_color_override("font_color", Color(0.55, 0.95, 0.6) if win else Color(0.95, 0.45, 0.4))
	overlay_body.text = body
	for child in overlay_buttons.get_children():
		overlay_buttons.remove_child(child)
		child.queue_free()
	var specs: Array = buttons
	if specs.is_empty():
		specs = [{"text": "FIGHT AGAIN", "method": "restart", "primary": true}]
	for spec in specs:
		var b := TouchButton.new()
		b.text = String(spec.get("text", "CONTINUE"))
		b.primary = bool(spec.get("primary", false))
		b.font_size = GameDefs.fs(18)
		b.accent = GameDefs.team_color(0)
		b.custom_minimum_size = Vector2(400.0, 56.0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var method := String(spec.get("method", "restart"))
		b.pressed.connect(func():
			if game != null:
				game.call(method)
		)
		overlay_buttons.add_child(b)

func overlay_visible() -> bool:
	return overlay != null and overlay.visible

func refresh() -> void:
	if game == null or credits_label == null:
		return
	credits_label.text = "%d CR" % int(game.credits[0])
	var out: float = game.power_out(0)
	var used: float = game.power_used(0)
	info_label.text = "UNITS %d   SPICE %d   GRID %d/%d" % [game.unit_count(0), game.harvested, int(out), int(used)]
	info_label.add_theme_color_override("font_color", C_INFO if out + 0.01 >= used else Color(0.98, 0.48, 0.34))
	var msgs: Array = game.recent_messages()
	log_label.text = String(msgs[msgs.size() - 1]) if not msgs.is_empty() else ""
	status_label.text = game.hud_status()
	if briefing_button != null:
		briefing_button.enabled = bool(game.campaign_mission)
	if mission_banner != null:
		mission_banner.visible = bool(game.campaign_mission)
		if objective_plate != null:
			objective_plate.visible = bool(game.campaign_mission)
			objective_plate.accent = GameDefs.team_color(0)
			objective_plate.queue_redraw()
		if game.campaign_mission:
			var m: Dictionary = game.mission
			var progress := CampaignMissions.objective_progress(game, game.objective)
			mission_banner.text = "M%d/%d  ·  %s  ·  %s" % [
				int(m.get("tier", 1)), CampaignMissions.TIER_COUNT,
				String(m.get("region_name", "ARRAKIS")).to_upper(), progress,
			]
			mission_banner.add_theme_color_override("font_color", C_CREAM)
			objective_plate.accent = C_GOLD_BRIGHT
	cancel_button.visible = game.placing != "" or game.brush != ""
	if game.placing != "":
		cancel_button.text = "KEEP READY"
	elif game.brush != "":
		cancel_button.text = "CANCEL"
	var touch_suppressed: bool = game.camera != null and game.camera.is_gesture_suppressed()
	var has_build: bool = game.selected_build != null and is_instance_valid(game.selected_build) and not game.selected_build.dead
	var has_units: bool = not game.selected.is_empty()
	if repair_button != null:
		repair_button.active = game.repair_mode
		repair_button.queue_redraw()
	if sell_button != null:
		sell_button.enabled = has_build and not game.game_over
		sell_button.queue_redraw()
	if guard_button != null:
		guard_button.caption = "RALLY" if has_build else "GUARD"
		guard_button.enabled = (has_build or has_units) and not game.game_over
		guard_button.active = game.rally_mode
		guard_button.queue_redraw()
	if status_orb != null:
		var building: bool = not game.structure_queue.is_empty() or not game.infantry_queue.is_empty() or not game.vehicle_queue.is_empty()
		if out + 0.01 < used:
			status_orb.level = "bad"
			status_orb.caption = "LOW POWER"
		elif building or not game.ready_structure.is_empty():
			status_orb.level = "warn"
			status_orb.caption = "BUILDING"
		else:
			status_orb.level = "ok"
			status_orb.caption = "GRID OK"
		status_orb.tooltip_text = "Power %d/%d - %s - tap to focus base" % [int(out), int(used), status_orb.caption]
	if box_button != null:
		box_button.set_pressed_no_signal(game.box_armed)
	if power_bar != null:
		power_bar.generated = out
		power_bar.used = used
		power_bar.queue_redraw()
	for tile in buttons:
		if not is_instance_valid(tile):
			continue
		var ok: bool = game.can_build(String(tile.kind), String(tile.item_id))
		if ok != tile.available:
			tile.available = ok
		tile.queue_count = game.queue_count(String(tile.kind), String(tile.item_id))
		tile.progress = game.queue_progress(String(tile.kind), String(tile.item_id))
		tile.ready_state = game.queue_ready(String(tile.kind), String(tile.item_id))
		tile.touch_suppressed = touch_suppressed
		tile.queue_redraw()

func _process(delta: float) -> void:
	if toast_timer > 0.0 and toast_plate != null and toast_plate.visible:
		toast_timer = maxf(0.0, toast_timer - delta)
		if toast_timer <= 0.0:
			toast_plate.visible = false
		elif toast_timer < 0.55:
			toast_plate.modulate.a = toast_timer / 0.55
	refresh_timer += delta
	if refresh_timer >= 0.08:
		refresh_timer = 0.0
		refresh()

func _show_objective_toast() -> void:
	if game == null or toast_plate == null or not game.campaign_mission:
		return
	var text := String(game.mission.get("objective_text", ""))
	if text == "":
		return
	toast_label.text = "OBJECTIVE: %s" % text.to_upper()
	toast_plate.accent = GameDefs.team_color(0)
	toast_plate.modulate = Color(1.0, 1.0, 1.0, 1.0)
	toast_plate.visible = true
	toast_timer = 3.0
	toast_plate.queue_redraw()
