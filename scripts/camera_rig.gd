class_name CameraRig
extends Camera2D

## RTS camera: arrow keys, middle-drag, one-finger drag and wheel/pinch zoom.

var pan_speed := 760.0
var min_zoom := 1.0
var max_zoom := 3.0
var panning := false
var user_zoomed := false
## Set while the game is drawing a selection box, so the view stops moving.
var pan_locked := false

## Tiles visible across the playable area (everything left of the side panel).
const VISIBLE_TILES := 16.0

## All fingers currently down, including taps that began on the sidebar. The
## dictionary is keyed by the Godot touch index.
var _touches: Dictionary = {}
var _pinch_active := false
var _pinch_distance := 1.0
var _pinch_zoom := 1.0
var _pinch_anchor := Vector2.ZERO
## True from the moment a second finger lands until every finger is lifted.
## Game uses this to reject unit orders, placement taps and box selection.
var _gesture_suppressed := false

func _ready() -> void:
	apply_default_zoom()
	get_viewport().size_changed.connect(_on_viewport_resized)
	position_smoothing_enabled = true
	position_smoothing_speed = 14.0

func _default_zoom() -> float:
	var vp := get_viewport_rect().size
	var playable := maxf(vp.x - GameHUD.PANEL_WIDTH, 320.0)
	return clampf(playable / (VISIBLE_TILES * float(GameDefs.TILE)), 0.9, 2.6)

func apply_default_zoom() -> void:
	var base := _default_zoom()
	min_zoom = base * 0.7
	max_zoom = base * 2.0
	zoom = Vector2(base, base)
	_sync_panel_offset()

## Shift the view left by half the side panel so the base sits in the middle of
## the playable strip, not the middle of the whole screen. Camera2D.offset is in
## world units and gets multiplied by zoom, so divide it back out.
func _sync_panel_offset() -> void:
	offset = Vector2(GameHUD.PANEL_WIDTH * 0.5 / zoom.x, 0.0)

func _on_viewport_resized() -> void:
	if not user_zoomed:
		apply_default_zoom()

func zoom_by(factor: float) -> void:
	user_zoomed = true
	var z := clampf(zoom.x * factor, min_zoom, max_zoom)
	zoom = Vector2(z, z)
	_sync_panel_offset()

## Game calls this when a second finger lands. It clears any drag that started
## with the first finger before that finger can become a move order or box.
func is_gesture_suppressed() -> bool:
	return _gesture_suppressed

func active_touch_count() -> int:
	return _touches.size()

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_screen_touch(event)
	elif event is InputEventScreenDrag:
		_on_screen_drag(event)
	elif event is InputEventMagnifyGesture:
		# Some Android devices report a magnify gesture instead of passing the
		# two raw touches through. Anchor it under the gesture midpoint too.
		_apply_zoom_at(float(event.factor), event.position)
		get_viewport().set_input_as_handled()

func _on_screen_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		if _touches.size() == 2:
			_gesture_suppressed = true
			var parent := get_parent()
			if parent != null and parent.has_method("cancel_touch_gesture"):
				parent.cancel_touch_gesture()
			if _map_touch_points().size() >= 2:
				_begin_pinch()
	else:
		_touches.erase(event.index)
		if _touches.size() < 2:
			_pinch_active = false
		if _touches.is_empty():
			_pinch_active = false
			_gesture_suppressed = false
	if _gesture_suppressed:
		# Keep the first finger's later release from reaching Game as a tap.
		get_viewport().set_input_as_handled()

func _on_screen_drag(event: InputEventScreenDrag) -> void:
	_touches[event.index] = event.position
	if _gesture_suppressed:
		get_viewport().set_input_as_handled()
	if _pinch_active and _map_touch_points().size() >= 2:
		_update_pinch()

func _map_touch_points() -> Array:
	var points: Array = []
	var playable_right := get_viewport_rect().size.x - GameHUD.PANEL_WIDTH
	for index in _touches:
		var p: Vector2 = _touches[index]
		if p.x < playable_right:
			points.append(p)
	return points

func _screen_to_world(screen: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen

func _begin_pinch() -> void:
	var points := _map_touch_points()
	if points.size() < 2:
		return
	_pinch_active = true
	_pinch_distance = maxf(Vector2(points[0]).distance_to(Vector2(points[1])), 1.0)
	_pinch_zoom = zoom.x
	var midpoint := (Vector2(points[0]) + Vector2(points[1])) * 0.5
	_pinch_anchor = _screen_to_world(midpoint)

func _update_pinch() -> void:
	var points := _map_touch_points()
	if points.size() < 2:
		return
	var a := Vector2(points[0])
	var b := Vector2(points[1])
	var midpoint := (a + b) * 0.5
	var distance := maxf(a.distance_to(b), 1.0)
	var z := clampf(_pinch_zoom * distance / _pinch_distance, min_zoom, max_zoom)
	user_zoomed = true
	zoom = Vector2(z, z)
	_sync_panel_offset()
	# Follow the moving midpoint (two-finger pan) while keeping the world point
	# that was under the initial pinch centred under the fingers.
	var viewport_half := get_viewport_rect().size * 0.5
	position = _pinch_anchor - (midpoint - viewport_half) / z - offset
	get_viewport().set_input_as_handled()

func _apply_zoom_at(factor: float, screen_position: Vector2) -> void:
	var anchor := _screen_to_world(screen_position)
	var z := clampf(zoom.x * factor, min_zoom, max_zoom)
	user_zoomed = true
	zoom = Vector2(z, z)
	_sync_panel_offset()
	var viewport_half := get_viewport_rect().size * 0.5
	position = anchor - (screen_position - viewport_half) / z - offset

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			panning = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_by(1.1)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_by(0.9)
	elif event is InputEventMouseMotion and panning:
		position -= event.relative / zoom.x
	elif event is InputEventScreenDrag and not pan_locked and not _gesture_suppressed:
		position -= event.relative / zoom.x

func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		position += dir.normalized() * pan_speed * delta / zoom.x
