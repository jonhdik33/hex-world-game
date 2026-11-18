extends VBoxContainer
## Меню «Политика»: очки, оправдание войн, альянс.

signal leave_pressed(other: int)

const GS = preload("res://scripts/core/game_state.gd")

var _pts: Label
var _ally: Label
var _wars: Label
var _leave_box: VBoxContainer
var _sig := ""


func _init() -> void:
	custom_minimum_size = Vector2(520, 0)
	add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "Политика"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	add_child(title)
	_pts = _lbl()
	_ally = _lbl()
	_wars = _lbl()
	_leave_box = VBoxContainer.new()
	add_child(_leave_box)
	var hint := _lbl()
	hint.text = "Оправдать войну, создать альянс или вступить в него можно, нажав на чужую страну на карте."
	hint.add_theme_font_size_override("font_size", 18)
	hint.modulate = Color(0.85, 0.85, 0.9)


func _lbl() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 22)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(500, 0)
	add_child(l)
	return l


func update_view(st: GS, cid: int) -> void:
	_pts.text = "Очки: %d  (+%d в день)" % [int(st.pol_points[cid]), int(GS.POL_DAILY)]
	var al: Array = st.allies_of(cid)
	var names: Array = []
	for m in al:
		names.append(String(st.world.countries[int(m)]["name"]))
	_ally.text = "Союзники: " + (", ".join(names) if not names.is_empty() else "нет")
	var sig := str(al)
	if sig != _sig:
		_sig = sig
		for c in _leave_box.get_children():
			c.queue_free()
		for m2 in al:
			var b := Button.new()
			b.text = "Выйти из союза: %s" % String(st.world.countries[int(m2)]["name"])
			b.add_theme_font_size_override("font_size", 20)
			b.pressed.connect(_on_leave.bind(int(m2)))
			_leave_box.add_child(b)
	var lines: Array = []
	for k in st.justify.keys():
		var left: int = st.justify[k]
		var nm: String = st.world.countries[int(k)]["name"]
		if left > 0:
			lines.append("Оправдание войны с %s: %d дн." % [nm, left])
		else:
			lines.append("Войну с %s можно объявлять" % nm)
	_wars.text = "\n".join(lines)


func _on_leave(other: int) -> void:
	leave_pressed.emit(other)
