extends RefCounted
## Универсальная сетка шестиугольников: вершина вверх, нечётные ряды сдвинуты вправо
## на полплитки. Индекс ячейки i = row * cols + col. Сейчас используется для крупных
## морских ячеек (будущие морские зоны флота). Сетка суши живёт в world.gd
## (там то же самое устроено отдельно — позже можно свести к одному классу).

const SQRT3 := 1.7320508075688772

# Соседи по сторонам: 0=E, 1=SE, 2=SW, 3=W, 4=NW, 5=NE.
const DIRS_EVEN: Array = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1),
]
const DIRS_ODD: Array = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]

var r: float = 10.0
var cols: int = 0
var rows: int = 0


## Сетка, которая полностью покрывает прямоугольник width x height (может чуть выступать).
func setup(width: float, height: float, radius: float) -> void:
	r = radius
	cols = int(ceil(width / hex_w())) + 1
	rows = int(ceil((height - r) / (1.5 * r))) + 1


func hex_w() -> float:
	return SQRT3 * r


func total() -> int:
	return cols * rows


@warning_ignore("integer_division")
func row_of(i: int) -> int:
	return i / cols


func col_of(i: int) -> int:
	return i % cols


func center_of(i: int) -> Vector2:
	var c := i % cols
	var rw := row_of(i)
	var w := hex_w()
	return Vector2(
		w * (float(c) + 0.5 * float(rw & 1)) + w * 0.5,
		r * 1.5 * float(rw) + r
	)


## Смещение угла k (0..5) от центра. Сторона k = от угла k до угла k+1.
func corner_off(k: int) -> Vector2:
	var a := deg_to_rad(-30.0 + 60.0 * float(k))
	return Vector2(cos(a), sin(a)) * r


func neighbor(i: int, d: int) -> int:
	var c := i % cols
	var rw := row_of(i)
	var off: Vector2i
	if (rw & 1) == 1:
		off = DIRS_ODD[d]
	else:
		off = DIRS_EVEN[d]
	var nc := c + off.x
	var nr := rw + off.y
	if nc < 0 or nc >= cols or nr < 0 or nr >= rows:
		return -1
	return nr * cols + nc


## Ячейка под точкой p, либо -1 если вне сетки.
func tile_at(p: Vector2) -> int:
	var w := hex_w()
	var row_guess := int(round((p.y - r) / (1.5 * r)))
	var best := -1
	var best_d := INF
	for rw in range(row_guess - 1, row_guess + 2):
		if rw < 0 or rw >= rows:
			continue
		var c_guess := int(round((p.x - w * 0.5) / w - 0.5 * float(rw & 1)))
		for c in range(c_guess - 1, c_guess + 2):
			if c < 0 or c >= cols:
				continue
			var i := rw * cols + c
			var d := center_of(i).distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = i
	return best
