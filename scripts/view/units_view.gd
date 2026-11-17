extends Node2D
## Слой над картой: солдаты, стрелки походов и анимация боёв.
## Карта под ним не перерисовывается каждый кадр: этот слой рисует только то, что движется.
## Данные берёт из GameState (отряды), сам ничего не меняет.

const World = preload("res://scripts/core/world.gd")
const GameState = preload("res://scripts/core/game_state.gd")

var world: World
var state: GameState
var player_country: int = -1
var selected_ships: Array = []   # номера выбранных кораблей игрока


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
	for sh in state.ships:
		var shd: Dictionary = sh
		if int(shd["state"]) == 1 or int(shd["bomb"]) >= 0:
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


func _ellipse(c: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 14:
		var a := TAU * float(k) / 14.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


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
		var shift := Vector2(-s * 0.1, s * 0.05)
		var pos := world.center_of(int(u["tile"])) + shift
		var upath: Array = u["path"]
		var walking := int(u["state"]) == GameState.ST_MOVE and not upath.is_empty() and float(u["p"]) > 0.0
		if walking:
			# солдат идёт плавно: стоит на острие стрелки, а на плитку «приходит» без скачка
			var nxt := world.center_of(int(upath[0]))
			var from_c := world.center_of(int(u["tile"]))
			var pp := clampf(float(u["p"]), 0.0, 1.0)
			pos = from_c.lerp(nxt, pp) + shift
			pos.y -= absf(sin(float(Time.get_ticks_msec()) / 110.0)) * s * 0.08   # шаг
		# мягкая тень под солдатом
		draw_colored_polygon(_ellipse(pos + Vector2(0, s * 0.5), s * 0.38, s * 0.12), Color(0, 0, 0, 0.28))
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


	# бои: атакующие тянутся к границе, защитники отвечают, на стыке вспышка и скрещённые линии
	for bt in state.battles:
		var bd: Dictionary = bt
		var tgt: Vector2 = world.center_of(int(bd["target"]))
		var tt: float = float(bd["t"])
		var first_mid := tgt
		for au in bd["att"]:
			var ad: Dictionary = au
			var af := world.center_of(int(ad["from"]))
			var amid := (af + tgt) * 0.5
			first_mid = amid
			_arrow(af, af.lerp(amid, 0.95), _owner_color(int(ad["owner"])), s * 0.24)
			_arrow(tgt, tgt.lerp(amid, 0.9), Color(1.0, 0.35, 0.3), s * 0.2)
		for du in bd["def"]:
			var dd: Dictionary = du
			var dpos := world.center_of(int(dd["tile"]))
			if dpos.distance_to(tgt) > 1.0:
				_arrow(dpos, dpos.lerp(tgt, 0.8), Color(1.0, 0.7, 0.3), s * 0.18)   # подкрепление защитников
		_draw_clash(first_mid, tt, s)

	# корабли: лодка с флажком цвета страны; в трюме дивизия — точка
	for sh in state.ships:
		var shd: Dictionary = sh
		if int(shd["dock"]) >= 0:
			continue   # корабль в гавани не виден на карте
		var pos2 := _ship_pos(shd)
		pos2.y += sin(float(Time.get_ticks_msec()) / 450.0 + float(int(shd["id"]))) * s * 0.05   # качка
		if int(shd["state"]) == 0:
			pos2 += Vector2(float(int(shd["id"]) % 3 - 1) * s * 0.28, float(int(shd["id"]) % 2) * s * 0.18)   # корабли на одной плитке не слипаются
		var pth: Array = shd["path"]
		if int(shd["state"]) == 1 and int(shd["owner"]) == player_country and pth.size() >= 1:
			var prev2 := pos2
			for c in pth:
				var np: Vector2 = world.center_of(int(c))
				draw_dashed_line(prev2, np, Color(1, 1, 1, 0.5), 2.0, 4.0)
				prev2 = np
		_boat(pos2, s * 0.62, _owner_color(int(shd["owner"])), not Dictionary(shd["cargo"]).is_empty(), int(shd["type"]) == 1)
		if player_country >= 0 and int(shd["owner"]) == player_country and int(shd["id"]) in selected_ships:
			draw_arc(world.center_of(int(shd["cell"])), s * 0.95, 0.0, TAU, 20, Color(1, 1, 1, 0.9), 2.0)
		if int(shd["bomb"]) >= 0:
			var tp := world.center_of(int(shd["bomb"]))
			var ph := fmod(float(Time.get_ticks_msec()) / 150.0, 1.0)
			draw_line(pos2, tp, Color(1.0, 0.6, 0.2, 0.8), 2.0)
			draw_circle(pos2.lerp(tp, ph), s * 0.18, Color(1.0, 0.9, 0.4))
			_draw_clash(tp, float(Time.get_ticks_msec()) / 1000.0, s)
	_draw_docked()


## Значок «в гавани стоят корабли: N» рядом с портом игрока.
func _draw_docked() -> void:
	var counts := {}
	for sh in state.ships:
		var d: Dictionary = sh
		var dk: int = d["dock"]
		if dk >= 0 and int(d["owner"]) == player_country:
			counts[dk] = int(counts.get(dk, 0)) + 1
	var font := ThemeDB.fallback_font
	for k in counts.keys():
		var t: int = k
		var pc := world.center_of(t) + Vector2(world.hex_r * 0.55, world.hex_r * 0.95)
		draw_circle(pc, world.hex_r * 0.34, Color(0.05, 0.05, 0.1, 0.95))
		draw_circle(pc, world.hex_r * 0.27, Color(0.35, 0.75, 1.0))
		draw_string(font, pc + Vector2(-world.hex_r * 0.12, world.hex_r * 0.14), str(int(counts[k])), HORIZONTAL_ALIGNMENT_LEFT, -1, int(world.hex_r * 0.5), Color(0.02, 0.05, 0.15))


func _ship_pos(sh: Dictionary) -> Vector2:
	var a: Vector2 = world.center_of(int(sh["cell"]))
	var pth: Array = sh["path"]
	if int(sh["state"]) == 1 and not pth.is_empty():
		var b: Vector2 = world.center_of(int(pth[0]))
		return a.lerp(b, clampf(float(sh["p"]), 0.0, 1.0))
	return a


func _boat(c: Vector2, s: float, col: Color, loaded: bool, war: bool = false) -> void:
	var dark := Color(0.05, 0.05, 0.1, 0.95)
	var hull := PackedVector2Array([c + Vector2(-0.8, 0.0) * s, c + Vector2(0.8, 0.0) * s,
		c + Vector2(0.5, 0.45) * s, c + Vector2(-0.5, 0.45) * s])
	draw_colored_polygon(hull, dark)
	var hull_in := PackedVector2Array([c + Vector2(-0.68, 0.05) * s, c + Vector2(0.68, 0.05) * s,
		c + Vector2(0.44, 0.36) * s, c + Vector2(-0.44, 0.36) * s])
	var hull_col := Color(0.85, 0.85, 0.9)
	if war:
		hull_col = Color(0.5, 0.55, 0.62)
	draw_colored_polygon(hull_in, hull_col)
	if war:
		draw_line(c + Vector2(-0.1, 0.1) * s, c + Vector2(0.8, -0.2) * s, dark, 0.14 * s)
		draw_circle(c + Vector2(-0.1, 0.1) * s, 0.2 * s, dark)
	draw_line(c + Vector2(0.0, 0.0) * s, c + Vector2(0.0, -0.8) * s, dark, 0.1 * s)
	draw_colored_polygon(PackedVector2Array([c + Vector2(0.0, -0.8) * s, c + Vector2(0.55, -0.55) * s, c + Vector2(0.0, -0.3) * s]), col)
	if loaded:
		draw_circle(c + Vector2(-0.35, -0.1) * s, 0.16 * s, Color(0.4, 1.0, 0.5))


func _draw_clash(mid: Vector2, t: float, s: float) -> void:
	var pulse := 0.6 + 0.4 * sin(t * 12.0)
	draw_circle(mid, s * 0.7 * pulse, Color(1.0, 0.8, 0.2, 0.35))
	var r := s * 0.45
	draw_line(mid + Vector2(-r, -r), mid + Vector2(r, r), Color(1, 1, 1), 3.0)
	draw_line(mid + Vector2(-r, r), mid + Vector2(r, -r), Color(1, 1, 1), 3.0)
