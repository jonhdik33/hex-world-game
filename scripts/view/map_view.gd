extends Node2D
## Отрисовка карты: море (из плиток), суша, границы стран, береговая линия,
## города и столицы, выделение плитки, подсветка страны игрока.
## Данные берёт из World, сам ничего в нём не меняет.

const World = preload("res://scripts/core/world.gd")

const SEA_DEEP := Color(0.07, 0.22, 0.45)
const SEA_SHALLOW := Color(0.12, 0.33, 0.58)
const SHALLOW_DIST := 2          # море не дальше этого числа плиток от суши = мелководье
const DIM_COLOR := Color(0.33, 0.38, 0.48)

var world: World
var selected_tile: int = -1
var player_country: int = -1
var _highlight: Line2D
var _off: Array = []             # смещения 6 углов шестиугольника от центра


func setup(w: World) -> void:
	world = w
	_off = []
	for k in 6:
		_off.append(world.corner(Vector2.ZERO, k))
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


func set_player(cid: int) -> void:
	player_country = cid
	queue_redraw()


## Выделяет плитку (суша или море). -1 = снять выделение.
func select_tile(i: int) -> void:
	selected_tile = i
	if world == null or i < 0:
		selected_tile = -1
		_highlight.visible = false
		return
	var pts := PackedVector2Array()
	for k in 6:
		pts.append(_off[k])
	_highlight.points = pts
	_highlight.position = world.center_of(i)
	_highlight.visible = true


func _tile_color(i: int, owner_id: int) -> Color:
	var base := Color(0.5, 0.5, 0.5)
	if owner_id >= 0:
		var cn: Dictionary = world.countries[owner_id]
		base = cn["color"]
		if player_country >= 0 and owner_id != player_country:
			base = base.lerp(DIM_COLOR, 0.45)   # чужие страны чуть приглушены
	# лёгкая "рябь" цвета, чтобы карта не выглядела плоской
	var v := float((i * 2654435761) % 1000) / 1000.0
	return base.darkened(v * 0.10)


func _draw() -> void:
	if world == null:
		return
	draw_rect(world.bounds(), SEA_DEEP)

	var coast := PackedVector2Array()
	var border := PackedVector2Array()
	var grid := PackedVector2Array()
	var sea_grid := PackedVector2Array()
	var mine := PackedVector2Array()   # граница страны игрока

	for i in world.tile_total():
		var c := world.center_of(i)
		var corners := PackedVector2Array()
		for k in 6:
			corners.append(c + _off[k])

		if world.land[i] == 0:
			if world.sea_dist[i] <= SHALLOW_DIST:
				draw_colored_polygon(corners, SEA_SHALLOW)
			for k in 6:
				var sn := world.neighbor(i, k)
				if sn > i and world.land[sn] == 0:
					sea_grid.append(corners[k])
					sea_grid.append(corners[(k + 1) % 6])
			continue

		var oid := world.tile_owner[i]
		draw_colored_polygon(corners, _tile_color(i, oid))
		for k in 6:
			var nb := world.neighbor(i, k)
			var a := corners[k]
			var b := corners[(k + 1) % 6]
			var nb_owner := -2
			if nb >= 0 and world.land[nb] == 1:
				nb_owner = world.tile_owner[nb]
			if player_country >= 0 and oid == player_country and nb_owner != player_country:
				mine.append(a)
				mine.append(b)
			if nb < 0 or world.land[nb] == 0:
				coast.append(a)
				coast.append(b)
			elif nb > i:   # каждое общее ребро рисуем один раз
				if nb_owner != oid:
					border.append(a)
					border.append(b)
				else:
					grid.append(a)
					grid.append(b)

	if sea_grid.size() >= 2:
		draw_multiline(sea_grid, Color(1, 1, 1, 0.07), 1.0)
	if grid.size() >= 2:
		draw_multiline(grid, Color(0, 0, 0, 0.12), 1.0)
	if border.size() >= 2:
		draw_multiline(border, Color(0, 0, 0, 0.6), 2.5)
	if coast.size() >= 2:
		draw_multiline(coast, Color(0.04, 0.09, 0.2, 0.95), 3.0)
	if mine.size() >= 2:
		draw_multiline(mine, Color(1, 1, 1, 0.95), 4.0)

	# города (малая точка) и столицы (большая)
	for i in world.tile_total():
		var kind := world.tile_city[i]
		if kind == 0:
			continue
		var cc := world.center_of(i)
		if kind == 2:
			draw_circle(cc, world.hex_r * 0.40, Color(0.05, 0.05, 0.1, 0.9))
			draw_circle(cc, world.hex_r * 0.28, Color(1, 0.95, 0.7, 1))
			draw_circle(cc, world.hex_r * 0.10, Color(0.05, 0.05, 0.1, 0.9))
		else:
			draw_circle(cc, world.hex_r * 0.24, Color(0.05, 0.05, 0.1, 0.85))
			draw_circle(cc, world.hex_r * 0.15, Color(0.95, 0.95, 0.95, 1))
