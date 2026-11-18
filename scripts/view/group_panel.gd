extends PanelContainer
## Окно «Военные группы»: выбор группы, страны-цели и приказа (атака / защита / расформировать).

signal group_selected(gid: int)
signal group_add
signal target_chosen(cid: int)
signal order_pressed(kind: String)
signal closed

const GS = preload("res://scripts/core/game_state.gd")
const FONT := 20

var selected_id: int = -1
var _sig := ""
var _body: VBoxContainer


func _init() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.11, 0.2, 0.97)
	sb.border_color = Color(0.35, 0.5, 0.75, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(8.0)
	add_theme_stylebox_override("panel", sb)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	add_child(_body)


func open_panel(st: GS) -> void:
	if st.group_by_id(selected_id).is_empty():
		selected_id = -1
		if not st.groups.is_empty():
			selected_id = int(Dictionary(st.groups[0])["id"])
	_sig = ""
	visible = true


func _color_box(col: Color, border: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(6.0)
	if border:
		sb.border_color = Color(1, 1, 1)
		sb.set_border_width_all(4)
	return sb


func _btn(text: String, size: Vector2, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.add_theme_font_size_override("font_size", FONT)
	b.pressed.connect(cb)
	return b


## Вызывается каждый кадр, пока окно открыто; перестраивает кнопки только при изменениях.
func update_view(st: GS, cid: int) -> void:
	var g := st.group_by_id(selected_id)
	if g.is_empty() and not st.groups.is_empty():
		selected_id = int(Dictionary(st.groups[0])["id"])
		g = st.group_by_id(selected_id)
	var neigh: Array = st.neighbor_countries(cid)
	var sig := str([selected_id, st.groups.size(), neigh, g.get("units", []).size() if not g.is_empty() else -1,
		g.get("target", -1), g.get("order", 0), st.is_at_war(cid, int(g.get("target", -1))) if not g.is_empty() else false])
	for gg in st.groups:
		sig += str(Dictionary(gg)["id"]) + ","
	if sig == _sig:
		return
	_sig = sig
	for c in _body.get_children():
		c.queue_free()
	# верхняя строка
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	_body.add_child(top)
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 24)
	if g.is_empty():
		title.text = "Нет военных групп — нажмите «+»"
	else:
		title.text = "Военная группа «%s»" % st.group_name(g)
		title.add_theme_color_override("font_color", st.group_color(g))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var cnt := Label.new()
	cnt.add_theme_font_size_override("font_size", 22)
	cnt.text = "Солдаты: %d" % (g["units"].size() if not g.is_empty() else 0)
	top.add_child(cnt)
	top.add_child(_btn("X", Vector2(52, 44), func(): closed.emit()))
	# страны-цели
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)
	if neigh.is_empty():
		var nl := Label.new()
		nl.text = "Соседей нет"
		row.add_child(nl)
	for c in neigh:
		var ci: int = c
		var cn: Dictionary = st.world.countries[ci]
		var b := _btn(String(cn["name"]), Vector2(0, 48), _on_target.bind(ci))
		var chosen: bool = not g.is_empty() and int(g["target"]) == ci
		var col: Color = cn["color"]
		for sn in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(sn, _color_box(col.darkened(0.2), chosen))
		b.add_theme_font_size_override("font_size", 18)
		row.add_child(b)
	# низ: приказы слева, группы справа
	var low := HBoxContainer.new()
	low.add_theme_constant_override("separation", 16)
	_body.add_child(low)
	var ords := VBoxContainer.new()
	low.add_child(ords)
	var cur: int = g["order"] if not g.is_empty() else 0
	var ba := _btn("Атака", Vector2(190, 44), func(): order_pressed.emit("attack"))
	ba.disabled = g.is_empty()
	if cur == GS.G_ATTACK:
		ba.add_theme_stylebox_override("normal", _color_box(Color(0.7, 0.25, 0.2), true))
	ords.add_child(ba)
	var bd := _btn("Защитить", Vector2(190, 44), func(): order_pressed.emit("defend"))
	bd.disabled = g.is_empty()
	if cur == GS.G_DEFEND:
		bd.add_theme_stylebox_override("normal", _color_box(Color(0.2, 0.4, 0.75), true))
	ords.add_child(bd)
	var br := _btn("Расформировать", Vector2(190, 44), func(): order_pressed.emit("disband"))
	br.disabled = g.is_empty()
	ords.add_child(br)
	var grp := HBoxContainer.new()
	grp.add_theme_constant_override("separation", 10)
	grp.alignment = BoxContainer.ALIGNMENT_CENTER
	grp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	low.add_child(grp)
	var icon := load("res://assets/icons/soldier.svg") as Texture2D
	for gg2 in st.groups:
		var gd: Dictionary = gg2
		var gb := _btn("", Vector2(84, 84), _on_group.bind(int(gd["id"])))
		var sel: bool = int(gd["id"]) == selected_id
		for sn2 in ["normal", "hover", "pressed", "focus"]:
			gb.add_theme_stylebox_override(sn2, _color_box(st.group_color(gd).darkened(0.35), sel))
		if icon != null:
			gb.icon = icon
			gb.expand_icon = true
		grp.add_child(gb)
	if st.groups.size() < GS.GROUP_COLORS.size():
		grp.add_child(_btn("+", Vector2(84, 84), func(): group_add.emit()))


func _on_target(cid: int) -> void:
	target_chosen.emit(cid)


func _on_group(gid: int) -> void:
	selected_id = gid
	group_selected.emit(gid)
	_sig = ""
