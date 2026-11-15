extends RefCounted
## Данные мира: сетка шестиугольников, суша, страны.
## ВАЖНО: здесь нет отрисовки и нет Node. Эту логику можно без изменений
## перенести на сервер, когда дойдём до онлайна.
##
## Сетка: "pointy-top" (вершина вверх), нечётные ряды сдвинуты вправо на полплитки.
## Индекс плитки: i = row * cols + col.
## Координаты мира = пиксели файла маски суши (assets/map_mask.png).

const HexGrid = preload("res://scripts/core/hex_grid.gd")

const SQRT3 := 1.7320508075688772

# Соседи по сторонам: 0=E, 1=SE, 2=SW, 3=W, 4=NW, 5=NE.
# Сторона k шестиугольника лежит между углами k и k+1 (см. corner()).
const DIRS_EVEN: Array = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1),
]
const DIRS_ODD: Array = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]

var hex_r: float = 13.0      # радиус шестиугольника (центр -> угол), в пикселях маски
var cols: int = 0
var rows: int = 0
var width_px: float = 0.0    # размер мира = размер маски
var height_px: float = 0.0

var land := PackedByteArray()          # 1 = суша, 0 = море
var tile_owner := PackedInt32Array()   # id страны, -1 = ничья/море
var landmass := PackedInt32Array()     # номер массива суши (материк/остров), -1 = море
var masses: Array = []                 # список массивов суши; каждый = PackedInt32Array плиток
var countries: Array = []              # [{id, name, color, seed, capital, tiles}]
var land_count: int = 0

# Крупные морские ячейки (зоны для флота). Лежат под сушей на всём мире;
# суша рисуется поверх. Заполняются в world_gen.gd (_build_sea).
var sea_grid: HexGrid = null
var sea_land_share := PackedFloat32Array()  # доля суши внутри ячейки (0..1)
var sea_navigable := PackedByteArray()      # 1 = ячейка достаточно водная, флот может стоять
var sea_coastal := PackedByteArray()        # 1 = в ячейке есть хоть немного суши (прибрежная)

var tile_city := PackedByteArray()     # 0 = обычная плитка, 1 = город, 2 = столица
var tile_factories := PackedByteArray() # число заводов на плитке (только города)


func setup_size(px_w: float, px_h: float, r: float) -> void:
	hex_r = r
	width_px = px_w
	height_px = px_h
	cols = int(ceil(px_w / hex_w())) + 1
	rows = int(ceil((px_h - hex_r) / (1.5 * hex_r))) + 1
	var n := cols * rows
	land.resize(n)
	land.fill(0)
	tile_owner.resize(n)
	tile_owner.fill(-1)
	landmass.resize(n)
	landmass.fill(-1)
	sea_grid = null
	sea_land_share.resize(0)
	sea_navigable.resize(0)
	sea_coastal.resize(0)
	tile_city.resize(n)
	tile_city.fill(0)
	tile_factories.resize(n)
	tile_factories.fill(0)
	masses = []
	countries = []
	land_count = 0


func hex_w() -> float:
	return SQRT3 * hex_r


func tile_total() -> int:
	return cols * rows


## Границы игрового мира (вся сетка, включая море). Камера и флот не выходят за них.
func bounds() -> Rect2:
	return Rect2(0.0, 0.0, hex_w() * (float(cols) + 0.5), hex_r * 1.5 * float(rows - 1) + hex_r * 2.0)


@warning_ignore("integer_division")
func row_of(i: int) -> int:
	return i / cols


func col_of(i: int) -> int:
	return i % cols


func center_of(i: int) -> Vector2:
	var c := i % cols
	var r := row_of(i)
	var w := hex_w()
	return Vector2(
		w * (float(c) + 0.5 * float(r & 1)) + w * 0.5,
		hex_r * 1.5 * float(r) + hex_r
	)


## Угол k шестиугольника (k = 0..5). Сторона k = отрезок от угла k до угла k+1.
func corner(center: Vector2, k: int) -> Vector2:
	var a := deg_to_rad(-30.0 + 60.0 * float(k))
	return center + Vector2(cos(a), sin(a)) * hex_r


## Сосед плитки i по стороне d (0..5), либо -1 если за краем сетки.
func neighbor(i: int, d: int) -> int:
	var c := i % cols
	var r := row_of(i)
	var off: Vector2i
	if (r & 1) == 1:
		off = DIRS_ODD[d]
	else:
		off = DIRS_EVEN[d]
	var nc := c + off.x
	var nr := r + off.y
	if nc < 0 or nc >= cols or nr < 0 or nr >= rows:
		return -1
	return nr * cols + nc


func land_neighbors(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for d in 6:
		var n := neighbor(i, d)
		if n >= 0 and land[n] == 1:
			out.append(n)
	return out


## Плитка под точкой p (координаты мира). Возвращает -1, если вне сетки.
func tile_at(p: Vector2) -> int:
	var w := hex_w()
	var row_guess := int(round((p.y - hex_r) / (1.5 * hex_r)))
	var best := -1
	var best_d := INF
	for r in range(row_guess - 1, row_guess + 2):
		if r < 0 or r >= rows:
			continue
		var c_guess := int(round((p.x - w * 0.5) / w - 0.5 * float(r & 1)))
		for c in range(c_guess - 1, c_guess + 2):
			if c < 0 or c >= cols:
				continue
			var i := r * cols + c
			var d := center_of(i).distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = i
	return best
