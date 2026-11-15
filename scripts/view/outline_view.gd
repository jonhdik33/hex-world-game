extends Node2D
## Белый контур из нескольких замкнутых линий (для выделения части морской ячейки,
## не закрытой сушей). Координаты — мировые.

var polys: Array = []
var width: float = 4.0


func set_polys(list: Array) -> void:
	polys = list
	visible = not list.is_empty()
	queue_redraw()


func _draw() -> void:
	for p in polys:
		var pts: PackedVector2Array = p
		if pts.size() < 2:
			continue
		var closed := PackedVector2Array(pts)
		closed.append(pts[0])
		draw_polyline(closed, Color(1, 1, 1, 0.95), width)
