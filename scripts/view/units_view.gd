extends Node2D
## Слой над картой: солдаты, стрелки походов и анимация боёв.
## Карта под ним не перерисовывается каждый кадр: этот слой рисует только то, что движется.
## Данные берёт из GameState (отряды), сам ничего не меняет.

const World = preload("res://scripts/core/world.gd")
const GameState = preload("res://scripts/core/game_state.gd")

var world: World
var state: GameState
var player_country: int = -1


func setup(w: World, s: GameState) -> void:
	world = w
	state = s
	z_index = 5
	queue_redraw()


func set_player(cid: int) -> void:
	player_country = cid
	queue_redraw()


func refresh() -> void:
	queue_redraw()


func _process(_delta: float) -> void:
	# пока кто-то идёт или сражается — перерисовываем каждый кадр
	if state == null:
		return
	for sq in state.squads:
		var e: Dictionary = sq
		if int(e["state"]) != GameState.ST_IDLE:
			queue_redraw()
			return


func _owner_color(owner_id: int) -> Color:
	if owner_id == player_country:
		return Color(0.45, 1.0, 0.55)
	var cn: Dictionary = world.countries[owner_id]
	var c: Color = cn["color"]
	return c.lightened(0.35)


## Фигурка солдата: каска, туловище, ноги, винтовка. s — радиус плитки.
func _soldier(c: Vector2, s: float, col: Color) -> void:
	var dark := Color(0.05, 0.05, 0.1, 0.95)
	var body := PackedVector2Array([
		c + Vector2(-0.17, -0.18) * s, c + Vector2(0.17, -0.18) * s,
		c + Vector2(0.20, 0.22) * s, c + Vector2(-0.20, 0.22) * s])
	draw_colored_polygon(body, dark)
	var inner := PackedVector2Array([
		c + Vector2(-0.12, -0.13) * s, c + Vector2(0.12, -0.13) * s,
		c + Vector2(0.14, 0.18) * s, c + Vector2(-0.14, 0.18) * s])
	draw_colored_polygon(inner, col)
	draw_line(c + Vector2(-0.08, 0.22) * s, c + Vector2(-0.08, 0.46) * s, dark, 0.14 * s)
	draw_line(c + Vector2(0.08, 0.22) * s, c + Vector2(0.08, 0.46) * s, dark, 0.14 * s)
	draw_line(c + Vector2(0.22, 0.3) * s, c + Vector2(0.22, -0.42) * s, dark, 0.07 * s)   # винтовка
	draw_circle(c + Vector2(0.0, -0.36) * s, 0.2 * s, dark)
	draw_circle(c + Vector2(0.0, -0.36) * s, 0.15 * s, Color(0.95, 0.8, 0.65))
	draw_arc(c + Vector2(0.0, -0.40) * s, 0.2 * s, PI, TAU, 8, col, 0.1 * s)               # каска


func _arrow(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	var d := b - a
	var ln := d.length()
	if ln < 1.0:
		return
	var dir := d / ln
	var side := Vector2(-dir.y, dir.x)
	var head := minf(width * 2.6, ln)
	var tip := b
	var base := b - dir * head
	draw_line(a, base, Color(0.05, 0.05, 0.1, 0.9), width + 2.0)
	draw_line(a, base, col, width)
	var tri := PackedVector2Array([tip, base + side * head * 0.55, base - side * head * 0.55])
	draw_colored_polygon(tri, col)


func _draw() -> void:
	if world == null or state == null:
		return
	var s := world.hex_r
	var font := ThemeDB.fallback_font
	var fs := int(s * 0.8)

	# маршруты отрядов игрока — тонкая пунктирная линия
	for sq in state.squads:
		var e: Dictionary = sq
		var path: Array = e["path"]
		if int(e["owner"]) != player_country or path.size() < 2:
			continue
		var prev := world.center_of(int(path[0]))
		for k in range(1, path.size()):
			var cur := world.center_of(int(path[k]))
			draw_dashed_line(prev, cur, Color(1, 1, 1, 0.55), 2.0, 5.0)
			prev = cur

	# солдаты (одна дивизия на плитку), полоска силы и значок отдыха
	for sq in state.squads:
		var u: Dictionary = sq
		var o: int = u["owner"]
		var pos := world.center_of(int(u["tile"])) + Vector2(-s * 0.1, s * 0.05)
		_soldier(pos, s * 0.9, _owner_color(o))
		var hp: float = float(u["hp"]) / GameState.MAX_HP
		var bar := Rect2(pos + Vector2(-s * 0.4, s * 0.55), Vector2(s * 0.8, s * 0.12))
		draw_rect(bar, Color(0, 0, 0, 0.8))
		var hc := Color(0.4, 0.9, 0.4)
		if hp < 0.5:
			hc = Color(0.95, 0.6, 0.2)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(hp, 0.0, 1.0), bar.size.y)), hc)
		if int(u["recover"]) > 0:
			draw_string(font, pos + Vector2(s * 0.3, -s * 0.3), "z", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.9, 0.3))

	# стрелки походов и бои
	for sq in state.squads:
		var e2: Dictionary = sq
		var st: int = e2["state"]
		if st == GameState.ST_IDLE:
			continue
		var path2: Array = e2["path"]
		if path2.is_empty():
			continue
		var nxt: int = path2[0]
		var p: float = e2["p"]
		# стрелка тянется от плитки, где начался шаг, к следующей; на середине отряд переходит
		var a := world.center_of(int(e2["from"]))
		var b := world.center_of(nxt)
		var col2 := _owner_color(int(e2["owner"]))
		if st == GameState.ST_FIGHT:
			_draw_battle(a, b, float(e2["fight_t"]), col2, s)
		else:
			_arrow(a, a.lerp(b, clampf(p, 0.0, 1.0)), col2, s * 0.22)


func _draw_battle(a: Vector2, b: Vector2, t: float, col: Color, s: float) -> void:
	var mid := (a + b) * 0.5
	var k := clampf(t / GameState.BATTLE_SECONDS, 0.0, 1.0)
	_arrow(a, a.lerp(mid, 0.92), col, s * 0.24)
	_arrow(b, b.lerp(mid, 0.92), Color(1.0, 0.35, 0.3), s * 0.24)
	var pulse := 0.6 + 0.4 * sin(t * 18.0)
	draw_circle(mid, s * (0.35 + 0.5 * k) * pulse, Color(1.0, 0.8, 0.2, 0.35))
	var r := s * 0.45
	draw_line(mid + Vector2(-r, -r), mid + Vector2(r, r), Color(1, 1, 1), 3.0)
	draw_line(mid + Vector2(-r, r), mid + Vector2(r, -r), Color(1, 1, 1), 3.0)
