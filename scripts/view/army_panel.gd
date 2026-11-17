extends VBoxContainer
## Меню «Армия»: покупка дивизий. Кнопка закрашивается за 10 секунд, потом дивизия появляется.

signal buy_pressed

const GS = preload("res://scripts/core/game_state.gd")
const FONT := 24

var _count: Label
var _btn: Button
var _fill: ColorRect
var _btn_lbl: Label
var _foot: Label


func _init() -> void:
	custom_minimum_size = Vector2(760, 0)
	add_theme_constant_override("separation", 12)
	var title := Label.new()
	title.text = "Армия"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	add_child(row)
	var icon := TextureRect.new()
	var tex := load("res://assets/icons/soldier.svg") as Texture2D
	if tex != null:
		icon.texture = tex
	icon.custom_minimum_size = Vector2(64, 64)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var name_l := Label.new()
	name_l.text = "Пехота"
	name_l.add_theme_font_size_override("font_size", FONT)
	name_l.custom_minimum_size = Vector2(150, 0)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_l)
	_count = Label.new()
	_count.add_theme_font_size_override("font_size", FONT)
	_count.custom_minimum_size = Vector2(230, 0)
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_count)
	_btn = Button.new()
	_btn.custom_minimum_size = Vector2(300, 64)
	_btn.clip_contents = true
	_btn.pressed.connect(func(): buy_pressed.emit())
	row.add_child(_btn)
	_fill = ColorRect.new()
	_fill.color = Color(0.35, 0.8, 0.4, 0.55)
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill.anchor_bottom = 1.0
	_fill.anchor_right = 0.0
	_btn.add_child(_fill)
	_btn_lbl = Label.new()
	_btn_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_btn_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	_btn_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_btn_lbl.add_theme_font_size_override("font_size", FONT)
	_btn.add_child(_btn_lbl)
	_foot = Label.new()
	_foot.add_theme_font_size_override("font_size", 20)
	_foot.modulate = Color(0.9, 0.85, 0.75)
	add_child(_foot)


## Обновить подписи и закраску кнопки (вызывается каждый кадр, пока меню открыто).
func update_view(st: GS, cid: int) -> void:
	var queued: int = st.army_queued(cid)
	var txt := "Дивизий: %d" % int(st.army[cid])
	if queued > 0:
		txt += " +%d" % queued
	_count.text = txt
	_btn_lbl.text = "+  %s   люди %s" % [GS.fmt(st.army_buy_price(cid)), GS.fmt(GS.BUY_POP)]
	_btn.disabled = st.army_buy_reason(cid) != ""
	_fill.anchor_right = st.army_progress(cid) if queued > 0 else 0.0
	_foot.text = "Содержание дивизии: -%d/день · армии: -%d/день" % [int(st.division_upkeep()), int(st.division_upkeep() * float(int(st.army[cid])))]
