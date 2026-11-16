extends Node2D
## Белый контур из отдельных отрезков (для выделения видимой части морской ячейки).
## Координаты — мировые. segs: пары точек (начало, конец, начало, конец, ...).

var segs := PackedVector2Array()
var width: float = 4.0


func set_segments(list: PackedVector2Array) -> void:
	segs = list
	visible = list.size() >= 2
	queue_redraw()


func _draw() -> void:
	if segs.size() >= 2:
		draw_multiline(segs, Color(1, 1, 1, 0.95), width)
