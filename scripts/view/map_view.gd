extends Node2D
## Отрисовка карты. Слои снизу вверх:
##   1) фон-море  2) крупные морские ячейки (под сушей)  3) плитки суши с неровным берегом
##   4) границы стран, берег, граница страны игрока  5) города и столицы  6) рамка за краем мира.
## Данные берёт из World, сам ничего в нём не меняет.

const World = preload("res://scripts/core/world.gd")
const OutlineView = preload("res://scripts/view/outline_view.gd")
const Layer = preload("res://scripts/view/layer.gd")

const FRAME_COLOR := Color(0.02, 0.05, 0.11)   # как фон за краем мира
const SEA_BASE := Color(0.11, 0.31, 0.57)
const SEA_CELL_DEEP := Color(0.12, 0.33, 0.60)
const SEA_CELL_COAST := Color(0.14, 0.36, 0.63)
const DIM_COLOR := Color(0.33, 0.38, 0.48)

# Естественный берег: береговые углы плиток сдвигаются, а на каждой береговой
# стороне появляется выступ или впадина. Углы общие у соседних плиток, поэтому щелей нет.
const COAST_JITTER := 0.25       # сдвиг береговых углов (в радиусах плитки)
const COAST_BULGE_MIN := -0.2    # впадина берега
const COAST_BULGE_MAX := 0.3     # выступ берега

var world: World
var player_country: int = -1
var _highlight: Line2D
var _sea_outline: Node2D
var _off: Array = []             # смещения углов плитки суши от центра
var _sea_off: Array = []         # смещения углов морской ячейки от центра
var _cpos := PackedVector2Array()    # углы плиток суши (с учётом берега), индекс i*6+k
var _mid := PackedVector2Array()     # середины береговых сторон, индекс i*6+k
var _mid_ok := PackedByteArray()     # 1 = у стороны k есть середина (она береговая)
var _poly: Array = []                # готовый многоугольник каждой плитки суши
var _construction: Array = []        # плитки со стройкой (жёлтое кольцо)
var _sea_layer: Node2D               # море (рисуется один раз)
var _land_mesh: MeshInstance2D       # суша одной сеткой: смена цвета плитки = обновление цветов, без перерисовки
var _top_layer: Node2D               # границы, города, порты, стройки, рамка
var _mesh := ArrayMesh.new()
var _owner_hash: int = -1
var _mv := PackedVector2Array()      # вершины сетки суши
var _mi := PackedInt32Array()        # индексы треугольников
var _mc := PackedColorArray()        # цвета вершин
var _mstart := PackedInt32Array()    # первая вершина каждой плитки
var _mcount := PackedInt32Array()    # число вершин плитки
var _coast := PackedVector2Array()   # линии берега (не меняются)
var _border := PackedVector2Array()  # границы стран
var _grid := PackedVector2Array()    # сетка внутри страны
var _mine := PackedVector2Array()    # граница страны игрока


func setup(w: World) -> void:
	world = w
	_off = []
	for k in 6:
		_off.append(world.corner(Vector2.ZERO, k))
	_sea_off = []
	for k in 6:
		_sea_off.append(world.sea_grid.corner_off(k))
	_build_geometry()
	_build_mesh()
	_sea_layer = Layer.new()
	_sea_layer.painter = _paint_sea
	add_child(_sea_layer)
	_land_mesh = MeshInstance2D.new()
	_land_mesh.mesh = _mesh
	_land_mesh.z_index = 1
	add_child(_land_mesh)
	_top_layer = Layer.new()
	_top_layer.painter = _paint_top
	_top_layer.z_index = 2
	add_child(_top_layer)
	_update_dynamic()
	_highlight = Line2D.new()
	_highlight.width = 3.0
	_highlight.default_color = Color(1, 1, 1, 0.95)
	_highlight.closed = true
	_highlight.z_index = 10
	_highlight.visible = false
	add_child(_highlight)
	_sea_outline = OutlineView.new()
	_sea_outline.z_index = 10
	_sea_outline.visible = false
	add_child(_sea_outline)


## Карта изменилась (захват плитки, стройка, порт): быстро обновляем цвета и линии.
func refresh() -> void:
	_update_dynamic()


## Страховка: если владельцы плиток изменились, а refresh() не позвали, перекрашиваем сами.
func sync_if_changed() -> void:
	if world == null or _land_mesh == null:
		return
	if _hash_owners() != _owner_hash:
		_update_dynamic()


func _hash_owners() -> int:
	var h := 7
	for i in world.tile_total():
		h = (h * 31 + int(world.tile_owner[i]) + 2 + int(world.tile_port[i]) * 977) % 1000003
	return h


func set_construction(tiles: Array) -> void:
	_construction = tiles
	_top_layer.queue_redraw()


func set_player(cid: int) -> void:
	player_country = cid
	_update_dynamic()


# ---------- выделение ----------

## Плитка суши под точкой мира с учётом неровного берега (по готовым многоугольникам).
## Нужна, чтобы нажатие на видимую сушу, выступающую за границу шестиугольника, находило плитку.
func pick_land(pos: Vector2) -> int:
	var i0 := world.tile_at(pos)
	var cands: Array = []
	if i0 >= 0:
		cands.append(i0)
		for k in 6:
			var n := world.neighbor(i0, k)
			if n >= 0:
				cands.append(n)
	for c in cands:
		var i: int = c
		if world.land[i] == 1:
			var poly: PackedVector2Array = _poly[i]
			if Geometry2D.is_point_in_polygon(pos, poly):
				return i
	return -1


func select_land(i: int) -> void:
	if world == null or i < 0 or world.land[i] == 0:
		clear_selection()
		return
	var c := world.center_of(i)
	var pts := PackedVector2Array()
	var poly: PackedVector2Array = _poly[i]
	for p in poly:
		pts.append(p - c)
	if _sea_outline != null:
		_sea_outline.visible = false
	_show_highlight(pts, c, 3.0)


## Выделяет только видимую часть морской ячейки: её края, не закрытые сушей,
## и береговую линию суши внутри ячейки.
func select_sea(j: int) -> void:
	if world == null or j < 0:
		clear_selection()
		return
	_highlight.visible = false
	var c := world.sea_grid.center_of(j)
	var hex_pts := PackedVector2Array()
	for k in 6:
		hex_pts.append(c + _sea_off[k])
	var reach := world.sea_grid.r + world.hex_r * 2.0
	var near: Array = []
	for i in world.tile_total():
		if world.land[i] == 1 and world.center_of(i).distance_to(c) <= reach:
			near.append(i)
	var segs := PackedVector2Array()
	# береговая линия суши внутри ячейки
	for t in near:
		var ti: int = t
		for k in 6:
			if not _is_sea(world.neighbor(ti, k)):
				continue
			var ep := _edge_pts(ti, k)
			var q := 0
			while q + 1 < ep.size():
				var mid := (ep[q] + ep[q + 1]) * 0.5
				if Geometry2D.is_point_in_polygon(mid, hex_pts):
					segs.append(ep[q])
					segs.append(ep[q + 1])
				q += 2
	# края самой ячейки, которые не лежат на суше и внутри мира
	var b := world.bounds()
	var steps := 24
	for k in 6:
		var a: Vector2 = hex_pts[k]
		var e: Vector2 = hex_pts[(k + 1) % 6]
		for q2 in steps:
			var p0 := a.lerp(e, float(q2) / float(steps))
			var p1 := a.lerp(e, float(q2 + 1) / float(steps))
			var m := (p0 + p1) * 0.5
			if not b.has_point(m):
				continue
			var covered := false
			for t2 in near:
				var poly: PackedVector2Array = _poly[int(t2)]
				if Geometry2D.is_point_in_polygon(m, poly):
					covered = true
					break
			if not covered:
				segs.append(p0)
				segs.append(p1)
	_sea_outline.set_segments(segs)


func clear_selection() -> void:
	if _highlight != null:
		_highlight.visible = false
	if _sea_outline != null:
		_sea_outline.visible = false


func _show_highlight(pts: PackedVector2Array, pos: Vector2, width: float) -> void:
	_highlight.points = pts
	_highlight.position = pos
	_highlight.width = width
	_highlight.visible = true


# ---------- геометрия берега ----------

func _is_sea(n: int) -> bool:
	return n < 0 or world.land[n] == 0


## Детерминированный "случайный" шум в диапазоне [-1, 1] по целым координатам.
func _hash(x: int, y: int, salt: int) -> float:
	var n: int = x * 374761393 + y * 668265263 + salt * 1442695041 + 1013904223
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 32767.5 - 1.0


func _build_geometry() -> void:
	var n := world.tile_total()
	_cpos.resize(n * 6)
	_mid.resize(n * 6)
	_mid_ok.resize(n * 6)
	_mid_ok.fill(0)
	_poly = []
	_poly.resize(n)
	var w2 := world.hex_w() * 0.5
	var r2 := world.hex_r * 0.5

	# углы: у береговых углов сдвиг по шуму от положения угла (общий для всех плиток при нём)
	for i in n:
		if world.land[i] == 0:
			continue
		var c := world.center_of(i)
		for k in 6:
			var p: Vector2 = c + _off[k]
			var n1 := world.neighbor(i, k)
			var n2 := world.neighbor(i, (k + 5) % 6)
			if _is_sea(n1) or _is_sea(n2):
				var kx := int(round(p.x / w2))
				var ky := int(round(p.y / r2))
				p += Vector2(_hash(kx, ky, 1), _hash(kx, ky, 2)) * world.hex_r * COAST_JITTER
			_cpos[i * 6 + k] = p

	# середины береговых сторон и итоговые многоугольники
	for i in n:
		if world.land[i] == 0:
			continue
		for k in 6:
			if not _is_sea(world.neighbor(i, k)):
				continue
			var a := _cpos[i * 6 + k]
			var b := _cpos[i * 6 + (k + 1) % 6]
			var ang := deg_to_rad(60.0 * float(k))
			var normal := Vector2(cos(ang), sin(ang))
			var t := (_hash(i, k, 3) + 1.0) * 0.5
			var bulge := lerpf(COAST_BULGE_MIN, COAST_BULGE_MAX, t)
			_mid[i * 6 + k] = (a + b) * 0.5 + normal * world.hex_r * bulge
			_mid_ok[i * 6 + k] = 1
		var poly := PackedVector2Array()
		for k in 6:
			poly.append(_cpos[i * 6 + k])
			if _mid_ok[i * 6 + k] == 1:
				poly.append(_mid[i * 6 + k])
		# страховка: если многоугольник не триангулируется, берём обычный шестиугольник
		if Geometry2D.triangulate_polygon(poly).is_empty():
			var c2 := world.center_of(i)
			poly = PackedVector2Array()
			for k in 6:
				poly.append(c2 + _off[k])
				_cpos[i * 6 + k] = c2 + _off[k]
				_mid_ok[i * 6 + k] = 0
		_poly[i] = poly


## Точки стороны k плитки i: два угла или (для береговой) угол-середина-угол.
func _edge_pts(i: int, k: int) -> PackedVector2Array:
	var a := _cpos[i * 6 + k]
	var b := _cpos[i * 6 + (k + 1) % 6]
	var out := PackedVector2Array()
	if _mid_ok[i * 6 + k] == 1:
		var m := _mid[i * 6 + k]
		out.append(a)
		out.append(m)
		out.append(m)
		out.append(b)
	else:
		out.append(a)
		out.append(b)
	return out


# ---------- рисование ----------

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


## Сетка суши строится один раз: многоугольники плиток режем на треугольники.
func _build_mesh() -> void:
	var n := world.tile_total()
	_mv = PackedVector2Array()
	_mi = PackedInt32Array()
	_mstart = PackedInt32Array()
	_mstart.resize(n)
	_mstart.fill(0)
	_mcount = PackedInt32Array()
	_mcount.resize(n)
	_mcount.fill(0)
	_coast = PackedVector2Array()
	for i in n:
		if world.land[i] == 0:
			continue
		var poly: PackedVector2Array = _poly[i]
		var tri := Geometry2D.triangulate_polygon(poly)
		if tri.is_empty():
			# запасной вариант: веер от первой вершины
			tri = PackedInt32Array()
			for q in range(1, poly.size() - 1):
				tri.append(0)
				tri.append(q)
				tri.append(q + 1)
		var base := _mv.size()
		_mstart[i] = base
		_mcount[i] = poly.size()
		_mv.append_array(poly)
		for ix in tri:
			_mi.append(base + int(ix))
		for k in 6:
			var nb := world.neighbor(i, k)
			if nb < 0 or world.land[nb] == 0:
				_coast.append_array(_edge_pts(i, k))
	_mc = PackedColorArray()
	_mc.resize(_mv.size())


## Цвета плиток и линии границ по текущим владельцам. Быстро: без триангуляции.
func _update_dynamic() -> void:
	if world == null or _land_mesh == null:
		return
	_border = PackedVector2Array()
	_grid = PackedVector2Array()
	_mine = PackedVector2Array()
	for i in world.tile_total():
		if world.land[i] == 0 or _mcount[i] == 0:
			continue
		var oid := world.tile_owner[i]
		var col := _tile_color(i, oid)
		var st := _mstart[i]
		for q in _mcount[i]:
			_mc[st + q] = col
		for k in 6:
			var nb := world.neighbor(i, k)
			var nb_owner := -2
			if nb >= 0 and world.land[nb] == 1:
				nb_owner = world.tile_owner[nb]
			if player_country >= 0 and oid == player_country and nb_owner != player_country:
				_mine.append_array(_edge_pts(i, k))
			if nb >= 0 and world.land[nb] == 1 and nb > i:
				if nb_owner != oid:
					_border.append_array(_edge_pts(i, k))
				else:
					_grid.append_array(_edge_pts(i, k))
	# каждый раз новая сетка: цвета гарантированно обновляются на экране
	var fresh := ArrayMesh.new()
	if _mv.size() >= 3:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _mv
		arrays[Mesh.ARRAY_COLOR] = _mc
		arrays[Mesh.ARRAY_INDEX] = _mi
		fresh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh = fresh
	_land_mesh.mesh = fresh
	_owner_hash = _hash_owners()
	_top_layer.queue_redraw()


func _paint_sea(c: Node2D) -> void:
	c.draw_rect(world.bounds(), SEA_BASE)
	var g := world.sea_grid
	var lines := PackedVector2Array()
	for j in g.total():
		var navigable := world.sea_navigable[j] == 1
		# ячейки, почти целиком лежащие под сушей, не рисуем; остальные закрашиваем,
		# но линии (зоны для флота) только у проходимых
		if not navigable and world.sea_land_share[j] >= 0.99:
			continue
		var cc := g.center_of(j)
		var pts := PackedVector2Array()
		for k in 6:
			pts.append(cc + _sea_off[k])
		var col := SEA_CELL_DEEP
		if world.sea_coastal[j] == 1:
			col = SEA_CELL_COAST
		c.draw_colored_polygon(pts, col)
		if not navigable:
			continue
		for k in 6:
			var nb := g.neighbor(j, k)
			# общее ребро двух проходимых ячеек рисуем один раз
			if nb >= 0 and nb < j and world.sea_navigable[nb] == 1:
				continue
			lines.append(pts[k])
			lines.append(pts[(k + 1) % 6])
	if lines.size() >= 2:
		c.draw_multiline(lines, Color(1, 1, 1, 0.20), 2.0)


func _star_points(center: Vector2, r_out: float, r_in: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 10:
		var rad := r_in
		if k % 2 == 0:
			rad = r_out
		var a := deg_to_rad(-90.0 + 36.0 * float(k))
		pts.append(center + Vector2(cos(a), sin(a)) * rad)
	return pts


## Верхний слой: линии, города, порты, стройки и рамка за краем мира.
func _paint_top(c: Node2D) -> void:
	if world == null:
		return
	if _grid.size() >= 2:
		c.draw_multiline(_grid, Color(0, 0, 0, 0.12), 1.0)
	if _border.size() >= 2:
		c.draw_multiline(_border, Color(0, 0, 0, 0.6), 2.5)
	if _coast.size() >= 2:
		c.draw_multiline(_coast, Color(0.04, 0.09, 0.2, 0.95), 3.0)
	if _mine.size() >= 2:
		c.draw_multiline(_mine, Color(1, 1, 1, 0.95), 4.0)

	# города — кружки одного размера, столицы — белые звёздочки
	for i in world.tile_total():
		var kind := world.tile_city[i]
		if kind == 0:
			continue
		var cc := world.center_of(i)
		if kind == 2:
			var star := _star_points(cc, world.hex_r * 0.62, world.hex_r * 0.26)
			c.draw_colored_polygon(star, Color(1, 1, 1, 1))
			var outline := star.duplicate()
			outline.append(star[0])
			c.draw_polyline(outline, Color(0.05, 0.05, 0.1, 0.9), 1.5)
		else:
			c.draw_circle(cc, world.hex_r * 0.40, Color(0.05, 0.05, 0.1, 0.9))
			c.draw_circle(cc, world.hex_r * 0.28, Color(0.95, 0.95, 0.95, 1))

	# порты: синий значок с якорем у города
	for i in world.tile_total():
		if world.tile_port[i] == 0:
			continue
		var pc := world.center_of(i) + Vector2(world.hex_r * 0.5, world.hex_r * 0.42)
		var pr := world.hex_r * 0.3
		c.draw_circle(pc, pr + 1.5, Color(0.05, 0.05, 0.1, 0.95))
		c.draw_circle(pc, pr, Color(0.15, 0.45, 0.85))
		c.draw_line(pc + Vector2(0, -pr * 0.6), pc + Vector2(0, pr * 0.6), Color(1, 1, 1), 1.6)
		c.draw_line(pc + Vector2(-pr * 0.5, -pr * 0.25), pc + Vector2(pr * 0.5, -pr * 0.25), Color(1, 1, 1), 1.6)
		c.draw_arc(pc + Vector2(0, pr * 0.1), pr * 0.5, 0.0, PI, 8, Color(1, 1, 1), 1.6)

	# стройки — жёлтые кольца
	for t in _construction:
		var ti: int = t
		c.draw_arc(world.center_of(ti), world.hex_r * 0.7, 0.0, TAU, 24, Color(1.0, 0.85, 0.2, 1.0), 3.0)

	# рамка: закрывает всё, что выступает за край мира
	var b := world.bounds()
	var big := 5000.0
	c.draw_rect(Rect2(b.position.x - big, b.position.y - big, big, b.size.y + 2.0 * big), FRAME_COLOR)
	c.draw_rect(Rect2(b.end.x, b.position.y - big, big, b.size.y + 2.0 * big), FRAME_COLOR)
	c.draw_rect(Rect2(b.position.x, b.position.y - big, b.size.x, big), FRAME_COLOR)
	c.draw_rect(Rect2(b.position.x, b.end.y, b.size.x, big), FRAME_COLOR)
