extends VBoxContainer
## Окно «Порты» (вкладка справа): слева список своих портов, справа выбранный порт:
## вкладки «Пришвартованные корабли» и «Купить», внизу кнопки «Выбрать все корабли» и «Выйти из гавани».
## Данные берёт у GameState при вызове rebuild(); наружу — сигнал action(kind, ship_id, tile):
##   buy_0 / buy_1 (купить десантный / боевой), load (погрузить, tile = плитка с дивизией),
##   unload, leave (выйти из гавани выбранными кораблями).

const GS = preload("res://scripts/core/game_state.gd")

signal action(kind: String, ship_id: int, tile: int)

const FONT := 20

var tab: int = 0              # 0 = пришвартованные корабли, 1 = купить
var picked := {}              # номера кораблей, выбранных для выхода из гавани
var _st: GS = null
var _cid: int = -1
var _tile: int = -1


func _init() -> void:
	add_theme_constant_override("separation", 8)
	custom_minimum_size = Vector2(820, 0)


func current_tile() -> int:
	return _tile


func picked_ids() -> Array:
	return picked.keys()


func _label(text: String, size: int = FONT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _btn(text: String, cb: Callable, enabled: bool = true, minw: float = 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	b.add_theme_font_size_override("font_size", FONT)
	b.custom_minimum_size = Vector2(minw, 48)
	b.pressed.connect(cb)
	return b


func _again() -> void:
	rebuild(_st, _cid, _tile)


func _emit(kind: String, ship_id: int, tile: int) -> void:
	action.emit(kind, ship_id, tile)


func _set_tab(n: int) -> void:
	tab = n
	_again()


func _pick_port(t: int) -> void:
	_tile = t
	picked = {}
	_again()


func _toggle(id: int) -> void:
	if picked.has(id):
		picked.erase(id)
	else:
		picked[id] = true
	_again()


func _select_all() -> void:
	for s2 in _st.navy_ships_at_port(_cid, _tile):
		var d2: Dictionary = s2
		picked[int(d2["id"])] = true
	tab = 0
	_again()


## Пересобирает окно. sel — плитка порта (если не порт своей страны, берётся первый).
func rebuild(st: GS, cid: int, sel: int) -> void:
	_st = st
	_cid = cid
	for c in get_children():
		c.queue_free()
		remove_child(c)
	var w = st.world
	var ports: Array = []
	for i in w.tile_total():
		if w.land[i] == 1 and w.tile_owner[i] == cid and w.tile_port[i] == 1:
			ports.append(i)
	add_child(_label("Порты", 28))
	add_child(_label("Деньги: %s · Кораблей: %d" % [GS.fmt(float(st.money[cid])), st.ship_count(cid)]))
	if ports.is_empty():
		add_child(_label("У вас нет портов. Выберите свой город на берегу и постройте порт."))
		return
	if not ports.has(sel):
		sel = int(ports[0])
	_tile = sel
	var t: int = sel

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	add_child(body)

	# ----- слева: порты -----
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(250, 0)
	left.add_theme_constant_override("separation", 6)
	body.add_child(left)
	var n := 0
	for p in ports:
		var pi: int = p
		n += 1
		var docked := st.navy_ships_at_port(cid, pi).size()
		var pb := _btn("Порт %d — кораблей: %d" % [n, docked], _pick_port.bind(pi))
		pb.toggle_mode = true
		pb.set_pressed_no_signal(pi == t)
		left.add_child(pb)

	# ----- справа: выбранный порт -----
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	body.add_child(right)
	var idx := ports.find(t) + 1
	right.add_child(_label("Порт %d" % idx, 24))

	var docked_ships := st.navy_ships_at_port(cid, t)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	var tb0 := _btn("Пришвартованные корабли (%d)" % docked_ships.size(), _set_tab.bind(0))
	tb0.toggle_mode = true
	tb0.set_pressed_no_signal(tab == 0)
	tabs.add_child(tb0)
	var tb1 := _btn("Купить корабли", _set_tab.bind(1))
	tb1.toggle_mode = true
	tb1.set_pressed_no_signal(tab == 1)
	tabs.add_child(tb1)
	right.add_child(tabs)

	if tab == 1:
		for ty in [GS.T_CARGO, GS.T_WAR]:
			var tyi: int = ty
			var reason := st.navy_ship_block_reason(cid, t, tyi)
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			var info := _label("%s корабль\nЦена: %s · содержание %s/день" % [st.navy_type_name(tyi), GS.fmt(st.navy_cost_of(tyi)), GS.fmt(st.navy_upkeep_of(tyi))])
			info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(info)
			row.add_child(_btn("Купить", _emit.bind("buy_%d" % tyi, -1, t), reason == "", 130.0))
			right.add_child(row)
			if reason != "" and reason != "Нужен порт":
				right.add_child(_label("   " + reason, 16))
	else:
		if docked_ships.is_empty():
			right.add_child(_label("В гавани нет кораблей. Вкладка «Купить корабли»."))
		var loadable := st.navy_loadable_tiles(cid, t)
		for s in docked_ships:
			var sh: Dictionary = s
			var id: int = sh["id"]
			var ty2: int = sh["type"]
			var cargo: Dictionary = sh["cargo"]
			var what := "пуст"
			if ty2 == GS.T_WAR:
				what = "обстрел берега"
			elif not cargo.is_empty():
				what = "везёт дивизию (сила %d)" % int(float(cargo["hp"]))
			var mark := "[ ] "
			if picked.has(id):
				mark = "[x] "
			var row2 := HBoxContainer.new()
			row2.add_theme_constant_override("separation", 8)
			var sb := _btn("%s%s №%d — %s" % [mark, st.navy_type_name(ty2), id, what], _toggle.bind(id))
			sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sb.alignment = HORIZONTAL_ALIGNMENT_LEFT
			row2.add_child(sb)
			if ty2 == GS.T_CARGO:
				if cargo.is_empty():
					var lt := -1
					if not loadable.is_empty():
						lt = int(loadable[0])
					row2.add_child(_btn("Погрузить", _emit.bind("load", id, lt), lt >= 0, 130.0))
				else:
					row2.add_child(_btn("Выгрузить", _emit.bind("unload", id, t), true, 130.0))
			right.add_child(row2)
		if docked_ships.size() > 0 and loadable.is_empty():
			right.add_child(_label("Погрузка: поставьте готовую дивизию на плитку порта или рядом.", 16))

	# ----- внизу справа: общие кнопки -----
	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.add_theme_constant_override("separation", 8)
	bottom.add_child(_btn("Выбрать все корабли", _select_all, docked_ships.size() > 0))
	bottom.add_child(_btn("Выйти из гавани (%d)" % picked.size(), _emit.bind("leave", -1, t), docked_ships.size() > 0))
	right.add_child(bottom)
