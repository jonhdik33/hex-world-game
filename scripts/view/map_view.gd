extends Node2D
## Отрисовка карты: плитки, границы стран, береговая линия, столицы, выделение.
## Данные берёт из World, сам ничего в нём не меняет.

const World = preload("res://scripts/core/world.gd")

var world: World
var selected_tile: int = -1
var _highlight: Line2D


func setup(w: World) -> void:
	world = w
	_highlight = Line2D.new()
	_highlight.width = 3.0
	_highlight.default_color = Color(1, 1, 1, 0.95)
	_highlight.closed = true
	_highlight.z_index = 10
	_highlight.visible = false
	add_child(_highlight)
	queue_redraw()


func refresh() -> void:
	queue_redraw()


func select_tile(i: int) -> void:
	selected_tile = i
	if world == null or i < 0 or world.land[i] == 0:
		selected_tile = -1
		_highlight.visible = false
		return
	var c := world.center_of(i)
	var pts := PackedVector2Array()
	for k in 6:
		pts.append(world.corner(c, k) - c)
	_highlight.points = pts
	_highlight.position = c
	_highlight.visible = true


func _tile_color(i: int, owner_id: int) -> Color:
	var base := Color(0.5, 0.5, 0.5)
	if owner_id >= 0:
		var cn: Dictionary = world.countries[owner_id]
		base = cn["color"]
	# лёгкая "рябь" цвета, чтобы карта не выглядела плоской
	var v := float((i * 2654435761) % 1000) / 1000.0
	return base.darkened(v * 0.10)


func _draw() -> void:
	if world == null:
		return
	var coast := PackedVector2Array()
	var border := PackedVector2Array()
	var grid := PackedVector2Array()

	for i in world.tile_total():
		if world.land[i] == 0:
			continue
		var c := world.center_of(i)
		var corners := PackedVector2Array()
		for k in 6:
			corners.append(world.corner(c, k))
		var oid := world.tile_owner[i]
		draw_colored_polygon(corners, _tile_color(i, oid))
		for k in 6:
			var nb := world.neighbor(i, k)
			var a := corners[k]
			var b := corners[(k + 1) % 6]
			if nb < 0 or world.land[nb] == 0:
				coast.append(a)
				coast.append(b)
			elif nb > i:   # каждое общее ребро рисуем один раз
				if world.tile_owner[nb] != oid:
					border.append(a)
					border.append(b)
				else:
					grid.append(a)
					grid.append(b)

	if grid.size() >= 2:
		draw_multiline(grid, Color(0, 0, 0, 0.12), 1.0)
	if border.size() >= 2:
		draw_multiline(border, Color(0, 0, 0, 0.6), 2.5)
	if coast.size() >= 2:
		draw_multiline(coast, Color(0.04, 0.09, 0.2, 0.95), 3.0)

	# столицы
	for cn in world.countries:
		var cap: int = cn["capital"]
		var cc := world.center_of(cap)
		draw_circle(cc, world.hex_r * 0.38, Color(0.05, 0.05, 0.1, 0.9))
		draw_circle(cc, world.hex_r * 0.26, Color(1, 0.95, 0.7, 1))
