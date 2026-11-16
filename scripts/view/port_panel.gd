extends PanelContainer
## Окно порта: покупка кораблей (грузовой / боевой), погрузка и выгрузка дивизий, выход в море, обстрел.
## Данные берёт у GameState при вызове rebuild(); наружу — сигнал action(kind, ship_id, tile).

const Navy = preload("res://scripts/core/navy.gd")

signal action(kind: String, ship_id: int, tile: int)

const FONT := 20

var _box: VBoxContainer


func _init() -> void:
	visible = false
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size = Vector2(560, 0)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 8)
	add_child(_box)


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


## Пересобирает окно для порта на плитке t страны cid.
func rebuild(st, cid: int, t: int) -> void:
	for c in _box.get_children():
		c.queue_free()
		_box.remove_child(c)
	var w = st.world
	_box.add_child(_label("Порт", 26))
	_box.add_child(_label("Деньги: %s · Кораблей: %d/%d" % [st.fmt(float(st.money[cid])), Navy.count_of(st, cid), Navy.MAX_SHIPS]))

	var buy := HBoxContainer.new()
	buy.add_theme_constant_override("separation", 8)
	for ty in [Navy.T_CARGO, Navy.T_WAR]:
		var reason := Navy.ship_block_reason(st, cid, t, ty)
		var txt := "Купить %s\n%s · %s/день" % [Navy.type_name(ty).to_lower(), st.fmt(Navy.cost_of(ty)), st.fmt(Navy.upkeep_of(ty))]
		var b := _button(txt, "buy_%d" % ty, -1, t, reason == "")
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		buy.add_child(b)
	_box.add_child(buy)
	var why := Navy.ship_block_reason(st, cid, t, Navy.T_CARGO)
	if why == "Максимум кораблей (%d)" % Navy.MAX_SHIPS:
		_box.add_child(_label(why))

	_box.add_child(_label("Корабли в порту", 22))
	var ships := Navy.ships_at_port(st, cid, t)
	if ships.is_empty():
		_box.add_child(_label("Пока нет. Купите корабль выше."))
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
		_box.add_child(row)
	if ships.size() > 0 and loadable.is_empty():
		_box.add_child(_label("Чтобы погрузить, поставьте готовую дивизию на плитку порта или рядом."))
	_box.add_child(_button("Закрыть", "close", -1, t))
