extends Camera2D
## Управление камерой: перетаскивание одним пальцем, щипок двумя пальцами,
## колесо мыши и перетаскивание мышью на компьютере.
## Короткое касание без сдвига = "тап" (сигнал tapped).

signal tapped(screen_pos: Vector2, world_pos: Vector2)

const TAP_MAX_MOVE := 14.0   # пикселей
const TAP_MAX_MS := 450

var min_zoom: float = 0.3
var max_zoom: float = 4.0
var world_rect := Rect2()

var _touches := {}          # индекс пальца -> текущая позиция
var _start_ms: int = 0
var _moved: float = 0.0
var _pinch_dist: float = 0.0
var _mouse_down: bool = false


func fit_to(rect: Rect2) -> void:
	world_rect = rect
	var vp := get_viewport_rect().size
	var z := minf(vp.x / rect.size.x, vp.y / rect.size.y)
	min_zoom = z * 0.9
	max_zoom = z * 8.0
	zoom = Vector2(z, z)
	position = rect.get_center()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)
	elif event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)


# ---------- касания ----------

func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		_touches[e.index] = e.position
		if _touches.size() == 1:
			_start_ms = Time.get_ticks_msec()
			_moved = 0.0
		else:
			_moved = 99999.0   # два пальца — это не тап
			_pinch_dist = _current_pinch_dist()
	else:
		var was_single := _touches.size() == 1
		_touches.erase(e.index)
		if was_single and _moved < TAP_MAX_MOVE and Time.get_ticks_msec() - _start_ms < TAP_MAX_MS:
			tapped.emit(e.position, _to_world(e.position))


func _on_drag(e: InputEventScreenDrag) -> void:
	_touches[e.index] = e.position
	if _touches.size() == 1:
		_moved += e.relative.length()
		_pan_screen(e.relative)
	elif _touches.size() >= 2:
		var d := _current_pinch_dist()
		if _pinch_dist > 1.0 and d > 1.0:
			_zoom_at(_current_pinch_center(), d / _pinch_dist)
		_pinch_dist = d


func _current_pinch_dist() -> float:
	var pts: Array = _touches.values()
	if pts.size() < 2:
		return 0.0
	var a: Vector2 = pts[0]
	var b: Vector2 = pts[1]
	return a.distance_to(b)


func _current_pinch_center() -> Vector2:
	var pts: Array = _touches.values()
	var a: Vector2 = pts[0]
	var b: Vector2 = pts[1]
	return (a + b) * 0.5


# ---------- мышь (компьютер) ----------
# Касания на телефоне Godot дублирует как "эмулированную мышь" — такие события
# пропускаем (device == DEVICE_ID_EMULATION), иначе всё сработает дважды.

func _on_mouse_button(e: InputEventMouseButton) -> void:
	if e.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
		_zoom_at(e.position, 1.15)
	elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
		_zoom_at(e.position, 1.0 / 1.15)
	elif e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			_mouse_down = true
			_moved = 0.0
			_start_ms = Time.get_ticks_msec()
		else:
			if _mouse_down and _moved < TAP_MAX_MOVE and Time.get_ticks_msec() - _start_ms < TAP_MAX_MS:
				tapped.emit(e.position, _to_world(e.position))
			_mouse_down = false


func _on_mouse_motion(e: InputEventMouseMotion) -> void:
	if e.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if _mouse_down:
		_moved += e.relative.length()
		_pan_screen(e.relative)


# ---------- общее ----------

func _to_world(screen_pos: Vector2) -> Vector2:
	var half := get_viewport_rect().size * 0.5
	return position + (screen_pos - half) / zoom


func _pan_screen(rel: Vector2) -> void:
	position -= rel / zoom.x
	_clamp_position()


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := _to_world(screen_pos)
	var z := clampf(zoom.x * factor, min_zoom, max_zoom)
	zoom = Vector2(z, z)
	var half := get_viewport_rect().size * 0.5
	position = before - (screen_pos - half) / zoom
	_clamp_position()


func _clamp_position() -> void:
	position.x = clampf(position.x, world_rect.position.x, world_rect.end.x)
	position.y = clampf(position.y, world_rect.position.y, world_rect.end.y)
