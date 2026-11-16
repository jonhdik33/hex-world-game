extends VBoxContainer
## Содержимое окна «Порты» (вкладка в правой колонке): список своих портов, покупка кораблей,
## корабли в выбранном порту, погрузка/выгрузка, выход в море, обстрел.
## Данные берёт у GameState при вызове rebuild(); наружу — сигнал action(kind, ship_id, tile).

const Navy = preload("res://scripts/core/navy.gd")

signal action(kind: String, ship_id: int, tile: int)

const FONT := 20


func _init() -> void:
	add_theme_constant_override("separation", 8)
	custom_minimum_size = Vector2(500, 0)


func _label(text: String, size: int = FONT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _button(text: String, kind: String, ship_id: int, tile: int, enabled: bool = true) -> Button:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	b.add_theme_font_size_override("font_size", FONT)
	b.custom_minimum_size = Vector2(0, 48)
	b.pressed.connect(func() -> void: action.emit(kind, ship_id, tile))
	return b


## Пересобирает окно. sel — выбранная плитка порта (если не порт, берётся первый).
func rebuild(st, cid: int, sel: int) -> void:
	for c in get_children():
		c.queue_free()
		remove_child(c)
	var w = st.world
	var ports: Array = []
	for i in w.tile_total():
		if w.land[i] == 1 and w.tile_owner[i] == cid and w.tile_port[i] == 1:
			ports.append(i)
	add_child(_label("Порты", 26))
	add_child(_label("Деньги: %s · Кораблей: %d/%d" % [st.fmt(float(st.money[cid])), Navy.count_of(st, cid), Navy.MAX_SHIPS]))
	if ports.is_empty():
		add_child(_label("У вас нет портов. Выберите свой город на берегу и постройте порт."))
		return
	if not ports.has(sel):
		sel = int(ports[0])
	var t: int = sel
	# список портов: у каждого — сколько кораблей стоит
	var plist := GridContainer.new()
	plist.columns = 2
	plist.add_theme_constant_override("h_separation", 8)
	plist.add_theme_constant_override("v_separation", 6)
	var n := 0
	for p in ports:
		var pi: int = p
		n += 1
		var here := Navy.ships_at_port(st, cid, pi)
		var wars := 0
		for q in here:
			var qd: Dictionary = q
			if int(qd["type"]) == Navy.T_WAR:
				wars += 1
		var pb := _button("Порт %d: грузовых %d, боевых %d" % [n, here.size() - wars, wars], "select", -1, pi)
		pb.toggle_mode = true
		pb.set_pressed_no_signal(pi == t)
		pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		plist.add_child(pb)
	add_child(plist)
	add_child(HSeparator.new())
	var buy := HBoxContainer.new()
	buy.add_theme_constant_override("separation", 8)
	for ty in [Navy.T_CARGO, Navy.T_WAR]:
		var reason := Navy.ship_block_reason(st, cid, t, ty)
		var txt := "Купить %s\n%s · %s/день" % [Navy.type_name(ty).to_lower(), st.fmt(Navy.cost_of(ty)), st.fmt(Navy.upkeep_of(ty))]
		var b := _button(txt, "buy_%d" % ty, -1, t, reason == "")
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		buy.add_child(b)
	add_child(buy)
	var why := Navy.ship_block_reason(st, cid, t, Navy.T_CARGO)
	if why == "Максимум кораблей (%d)" % Navy.MAX_SHIPS:
		add_child(_label(why))

	add_child(_label("Корабли в порту", 22))
	var ships := Navy.ships_at_port(st, cid, t)
	if ships.is_empty():
		add_child(_label("Пока нет. Купите корабль выше."))
	var loadable := Navy.loadable_tiles(st, cid, t)
	for s in ships:
		var sh: Dictionary = s
		var id: int = sh["id"]
		var row := VBoxContainer.new()
		var ty2: int = sh["type"]
		var cargo: Dictionary = sh["cargo"]
		var state_txt := "пуст"
		if ty2 == Navy.T_WAR:
			state_txt = "артиллерия, обстрел берега"
		elif not cargo.is_empty():
			state_txt = "везёт дивизию (сила %d)" % int(float(cargo["hp"]))
		row.add_child(_label("%s корабль №%d — %s" % [Navy.type_name(ty2), id, state_txt]))
		var btns := HBoxContainer.new()
		btns.add_theme_constant_override("separation", 8)
		if ty2 == Navy.T_CARGO:
			if cargo.is_empty():
				var lt := -1
				if not loadable.is_empty():
					lt = int(loadable[0])
				btns.add_child(_button("Погрузить дивизию", "load", id, lt, lt >= 0))
			else:
				btns.add_child(_button("Выгрузить", "unload", id, t))
		if ty2 == Navy.T_WAR:
			var tg := Navy.bombard_targets(st, cid, sh)
			for k in mini(tg.size(), 2):
				btns.add_child(_button("Обстрелять", "bomb", id, int(tg[k])))
		btns.add_child(_button("В плавание", "sail", id, t))
		row.add_child(btns)
		add_child(row)
	if ships.size() > 0 and loadable.is_empty():
		add_child(_label("Чтобы погрузить, поставьте готовую дивизию на плитку порта или рядом."))
