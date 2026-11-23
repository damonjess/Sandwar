class_name TouchButton
extends Control

## A mouse-and-touch button for the campaign front end and end-of-battle
## overlay. Plain Button controls do not receive InputEventScreenTouch with the
## project's mouse-emulation setting, so these screens use an explicit tap
## implementation instead.

signal pressed

var text := "BUTTON"
var font_size := 16
var enabled := true:
	set(value):
		enabled = value
		queue_redraw()
var primary := false
var accent := Color(0.84, 0.68, 0.36)
var subtext := ""
## Set by the owning screen while arrow-key navigation is active.
var keyboard_focused := false:
	set(value):
		if keyboard_focused == value:
			return
		keyboard_focused = value
		queue_redraw()

var _hovered := false
var _held := false
var _press_pos := Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_NONE
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		_hovered = true
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hovered = false
		_held = false
		queue_redraw()
	elif what == NOTIFICATION_RESIZED:
		queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_held = true
			_press_pos = event.position
			accept_event()
		else:
			var fire: bool = _held and event.position.distance_to(_press_pos) <= 24.0
			_held = false
			queue_redraw()
			if fire:
				accept_event()
				pressed.emit()
		return
	if event is InputEventScreenTouch:
		if event.index > 0:
			return
		if event.pressed:
			_held = true
			_press_pos = event.position
			accept_event()
		else:
			var fire: bool = _held and event.position.distance_to(_press_pos) <= 32.0
			_held = false
			queue_redraw()
			if fire:
				accept_event()
				pressed.emit()

func _draw() -> void:
	var w := size.x
	var h := size.y
	var rect := Rect2(Vector2(0.5, 0.5), size - Vector2(1.0, 1.0))
	var base := Color(0.18, 0.12, 0.065) if primary else Color(0.11, 0.10, 0.08)
	if _held:
		base = base.darkened(0.28)
	elif _hovered and enabled:
		base = base.lightened(0.12)
	if not enabled:
		base = Color(0.08, 0.075, 0.065)
	draw_rect(rect, base)
	draw_rect(rect, Color(0.025, 0.018, 0.012, 0.9), false, 2.0)
	var border := accent if enabled else Color(0.30, 0.27, 0.21)
	if _hovered and enabled:
		border = accent.lightened(0.25)
	draw_rect(rect.grow(-2.0), Color(border.r, border.g, border.b, 0.92), false, 1.4)
	if keyboard_focused and enabled:
		draw_rect(rect.grow(2.0), Color(1.0, 0.88, 0.50, 0.92), false, 2.0)
	# Brass corner ticks.
	var tick := Color(border.r, border.g, border.b, 0.55)
	for corner in [Vector2(7.0, 7.0), Vector2(w - 7.0, 7.0), Vector2(7.0, h - 7.0), Vector2(w - 7.0, h - 7.0)]:
		draw_circle(corner, 1.8, tick)
	var font := ThemeDB.fallback_font
	var col := Color(0.96, 0.91, 0.80) if enabled else Color(0.50, 0.47, 0.40)
	if primary and enabled:
		col = Color(1.0, 0.94, 0.74)
	var outline := Color(0.02, 0.015, 0.01, 0.85)
	if subtext != "":
		var sub_fs := maxi(12, font_size - 5)
		var label := text.to_upper()
		var main_base := h * 0.5 - 2.0
		var sub_base := main_base + float(sub_fs) + 2.0
		draw_string_outline(font, Vector2(0.0, main_base), label, HORIZONTAL_ALIGNMENT_CENTER,
			w, font_size, 2, outline)
		draw_string(font, Vector2(0.0, main_base), label, HORIZONTAL_ALIGNMENT_CENTER,
			w, font_size, col)
		draw_string(font, Vector2(0.0, sub_base), subtext, HORIZONTAL_ALIGNMENT_CENTER,
			w, sub_fs, Color(0.80, 0.74, 0.62, 0.98))
	else:
		var baseline := (h + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
		var label := text.to_upper()
		draw_string_outline(font, Vector2(0.0, baseline), label, HORIZONTAL_ALIGNMENT_CENTER,
			w, font_size, 2, outline)
		draw_string(font, Vector2(0.0, baseline), label, HORIZONTAL_ALIGNMENT_CENTER,
			w, font_size, col)
	if primary and enabled:
		var glow := 0.18 + 0.10 * absf(sin(Time.get_ticks_msec() * 0.004))
		draw_rect(rect, Color(accent.r, accent.g, accent.b, glow), false, 1.0)
