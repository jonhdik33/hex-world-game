extends VBoxContainer
## Меню «Политика»: очки, оправдание войн, альянс.

signal leave_pressed

const GS = preload("res://scripts/core/game_state.gd")

var _pts: Label
var _ally: Label
var _wars: Label
var _leave: Button


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
	_leave = Button.new()
	_leave.text = "Покинуть альянс"
	_leave.add_theme_font_size_override("font_size", 22)
	_leave.pressed.connect(func(): leave_pressed.emit())
	add_child(_leave)
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
	var aid: int = st.alliance[cid]
	if aid < 0:
		_ally.text = "Альянс: нет"
		_leave.visible = false
	else:
		var names: Array = []
		for m in st.alliance_members(aid):
			names.append(String(st.world.countries[int(m)]["name"]))
		_ally.text = "Альянс: " + ", ".join(names)
		_leave.visible = true
	var lines: Array = []
	for k in st.justify.keys():
		var left: int = st.justify[k]
		var nm: String = st.world.countries[int(k)]["name"]
		if left > 0:
			lines.append("Оправдание войны с %s: %d дн." % [nm, left])
		else:
			lines.append("Войну с %s можно объявлять" % nm)
	_wars.text = "\n".join(lines)
