extends VBoxContainer
## Меню «Исследования»: улучшения войск и инфраструктуры, покупка кораблей. Три страницы со стрелками.

signal buy_upgrade(kind: int)
signal buy_ship(ship_type: int)

const GS = preload("res://scripts/core/game_state.gd")
const ROMAN: Array = ["I", "II", "III"]
const DESC: Array = [
	["Скорость пехоты ×1.1\nАтака ×1.5", "Ещё ×1.1 скорость\nЕщё ×1.5 атака", "Ещё ×1.1 скорость\nЕщё ×1.5 атака"],
	["+3000 рабочих\nПрирост +100/день", "+10% рабочих\nПрирост +200/день", "+15% рабочих\nПрирост +300/день"],
	["Восстановление\n+10%", "Восстановление\n+20%", "Восстановление\n+30%"],
]

var page := 0
var _sig := ""
var _title: Label
var _content: VBoxContainer
var _dots: HBoxContainer


func _init() -> void:
	custom_minimum_size = Vector2(0, 0)
	add_theme_constant_override("separation", 8)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 30)
	add_child(_title)
	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 12)
	add_child(mid)
	mid.add_child(_arrow("◀", -1))
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	mid.add_child(_content)
	mid.add_child(_arrow("▶", 1))
	_dots = HBoxContainer.new()
	_dots.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_dots)


func _arrow(t: String, d: int) -> Button:
	var b := Button.new()
	b.text = t
	b.custom_minimum_size = Vector2(60, 90)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_size_override("font_size", 28)
	b.pressed.connect(_turn.bind(d))
	return b


func _turn(d: int) -> void:
	page = posmod(page + d, 3)
	_sig = ""


func _style(col: Color, border := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(6.0)
	if border:
		sb.border_color = Color(1, 0.9, 0.4)
		sb.set_border_width_all(3)
	return sb


func _card(st: GS, cid: int, kind: int, tier: int) -> Control:
	var lv: int = st.upg_level(cid, kind)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var b := Button.new()
	b.custom_minimum_size = Vector2(190, 110)
	b.add_theme_font_size_override("font_size", 20)
	b.text = "%s\n%s" % [ROMAN[tier], DESC[kind][tier]]
	var owned := tier < lv
	var next := tier == lv
	b.disabled = not next
	if owned:
		for sn in ["normal", "disabled"]:
			b.add_theme_stylebox_override(sn, _style(Color(0.2, 0.5, 0.25)))
	elif next:
		b.add_theme_stylebox_override("normal", _style(Color(0.22, 0.26, 0.34), true))
	else:
		b.add_theme_stylebox_override("disabled", _style(Color(0.14, 0.15, 0.2)))
	b.pressed.connect(_on_upgrade.bind(kind))
	box.add_child(b)
	var price := Label.new()
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price.add_theme_font_size_override("font_size", 20)
	if owned:
		price.text = "Куплено"
		price.modulate = Color(0.6, 1.0, 0.6)
	else:
		price.text = GS.fmt(float(Array(GS.UPG_COST[kind])[tier]))
		price.modulate = Color(1.0, 0.85, 0.3) if float(st.money[cid]) >= float(Array(GS.UPG_COST[kind])[tier]) else Color(1.0, 0.45, 0.4)
	box.add_child(price)
	return box


func _row(title: String, st: GS, cid: int, kind: int) -> Control:
	var v := VBoxContainer.new()
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 24)
	v.add_child(l)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	v.add_child(h)
	for t in 3:
		h.add_child(_card(st, cid, kind, t))
	return v


func _on_upgrade(kind: int) -> void:
	buy_upgrade.emit(kind)
	_sig = ""


func _on_ship(t: int) -> void:
	buy_ship.emit(t)
	_sig = ""


func update_view(st: GS, cid: int) -> void:
	var sig := "%d|%d|%s|%d" % [page, int(float(st.money[cid]) / 50.0), str(st.upg[cid]), st.ship_count(cid)]
	if sig == _sig:
		return
	_sig = sig
	for c in _content.get_children():
		c.queue_free()
	for c2 in _dots.get_children():
		c2.queue_free()
	for i in 3:
		var d := Label.new()
		d.text = "●" if i == page else "○"
		_dots.add_child(d)
	if page == 0:
		_title.text = "Исследования — Пехота"
		_content.add_child(_row("Новое оружие", st, cid, 0))
	elif page == 1:
		_title.text = "Исследования — Инфраструктура"
		_content.add_child(_row("Жилые дома", st, cid, 1))
		_content.add_child(_row("Механизация", st, cid, 2))
	else:
		_title.text = "Исследования — Военно-морской флот"
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 20)
		_content.add_child(h)
		for t in 2:
			var cost: float = st.navy_cost_of(t)
			var b := Button.new()
			b.custom_minimum_size = Vector2(300, 120)
			b.add_theme_font_size_override("font_size", 22)
			b.text = "%s\n%s" % [st.navy_type_name(t), GS.fmt(cost)]
			b.disabled = float(st.money[cid]) < cost
			b.pressed.connect(_on_ship.bind(t))
			h.add_child(b)
		var n := Label.new()
		n.text = "Корабль появится в порту, ближайшем к столице. Боевой корабль топит вражеские десантные при встрече."
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		n.add_theme_font_size_override("font_size", 20)
		_content.add_child(n)
