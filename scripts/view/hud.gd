extends CanvasLayer
## Интерфейс: верхняя панель, подсказка, окно выбора страны, информация о плитке,
## кнопки скорости. Всё собирается кодом, оформление своё (тёмно-синие панели).
## Наружу общается только сигналами и set_* методами.

signal confirm_pressed
signal regen_pressed
signal speed_selected(speed: int)

const GameState = preload("res://scripts/core/game_state.gd")

const FONT := 22
const SPEED_NAMES: Array = ["Пауза", "x1", "x2", "x3"]

var _top_bar: PanelContainer
var _lbl_money: Label
var _lbl_fact: Label
var _lbl_pop: Label
var _lbl_date: Label
var _hint_panel: PanelContainer
var _info_panel: PanelContainer
var _info_label: Label
var _pick_panel: PanelContainer
var _pick_label: Label
var _regen_btn: Button
var _speed_box: HBoxContainer
var _speed_buttons: Array = []
var _blockers: Array = []


func _init() -> void:
	_build()


func _build() -> void:
	# --- верхняя панель (во время игры) ---
	_top_bar = _make_panel()
	add_child(_top_bar)
	_top_bar.anchor_right = 1.0
	_top_bar.offset_left = 8.0
	_top_bar.offset_right = -8.0
	_top_bar.offset_top = 8.0
	var row := HBoxContainer.new()
	_top_bar.add_child(row)
	_lbl_money = _stat_label(row, Color(1.0, 0.86, 0.4))
	_lbl_fact = _stat_label(row, Color(0.95, 0.6, 0.45))
	_lbl_pop = _stat_label(row, Color(0.6, 0.85, 1.0))
	_lbl_date = _stat_label(row, Color(0.85, 0.9, 0.95))
	_top_bar.visible = false

	# --- подсказка (во время выбора страны) ---
	_hint_panel = _make_panel()
	add_child(_hint_panel)
	_hint_panel.anchor_left = 0.5
	_hint_panel.anchor_right = 0.5
	_hint_panel.offset_top = 8.0
	_hint_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint_panel.add_child(_plain_label("Нажмите на страну, за которую хотите играть", Color(1, 1, 1)))

	# --- кнопка "Новые границы" (только при выборе страны) ---
	_regen_btn = Button.new()
	_regen_btn.text = "Новые границы"
	_regen_btn.add_theme_font_size_override("font_size", FONT)
	add_child(_regen_btn)
	_regen_btn.anchor_left = 1.0
	_regen_btn.anchor_right = 1.0
	_regen_btn.offset_left = -240.0
	_regen_btn.offset_right = -8.0
	_regen_btn.offset_top = 8.0
	_regen_btn.pressed.connect(func(): regen_pressed.emit())

	# --- информация о плитке (слева внизу) ---
	_info_panel = _make_panel()
	add_child(_info_panel)
	_info_panel.anchor_top = 1.0
	_info_panel.anchor_bottom = 1.0
	_info_panel.offset_left = 8.0
	_info_panel.offset_bottom = -8.0
	_info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_info_label = _plain_label("", Color(0.92, 0.95, 1.0))
	_info_label.custom_minimum_size = Vector2(330, 0)
	_info_panel.add_child(_info_label)

	# --- окно выбора страны (по центру внизу) ---
	_pick_panel = _make_panel()
	add_child(_pick_panel)
	_pick_panel.anchor_left = 0.5
	_pick_panel.anchor_right = 0.5
	_pick_panel.anchor_top = 1.0
	_pick_panel.anchor_bottom = 1.0
	_pick_panel.offset_bottom = -8.0
	_pick_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_pick_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var box := VBoxContainer.new()
	_pick_panel.add_child(box)
	_pick_label = _plain_label("", Color(1, 1, 1))
	_pick_label.custom_minimum_size = Vector2(360, 0)
	box.add_child(_pick_label)
	var ok := Button.new()
	ok.text = "Играть за эту страну"
	ok.add_theme_font_size_override("font_size", FONT)
	ok.pressed.connect(func(): confirm_pressed.emit())
	box.add_child(ok)
	_pick_panel.visible = false

	# --- скорость времени (справа внизу, во время игры) ---
	_speed_box = HBoxContainer.new()
	add_child(_speed_box)
	_speed_box.anchor_left = 1.0
	_speed_box.anchor_right = 1.0
	_speed_box.anchor_top = 1.0
	_speed_box.anchor_bottom = 1.0
	_speed_box.offset_right = -8.0
	_speed_box.offset_bottom = -8.0
	_speed_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_speed_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	for s in SPEED_NAMES.size():
		var b := Button.new()
		b.text = SPEED_NAMES[s]
		b.toggle_mode = true
		b.add_theme_font_size_override("font_size", FONT)
		b.custom_minimum_size = Vector2(84, 52)
		b.pressed.connect(_on_speed_pressed.bind(s))
		_speed_box.add_child(b)
		_speed_buttons.append(b)
	_speed_box.visible = false

	_blockers = [_top_bar, _hint_panel, _regen_btn, _info_panel, _pick_panel, _speed_box]


# ---------- публичный интерфейс ----------

func set_info(text: String) -> void:
	_info_label.text = text


func show_pick(text: String) -> void:
	_pick_label.text = text
	_pick_panel.visible = true


func hide_pick() -> void:
	_pick_panel.visible = false


## Переход от выбора страны к игре.
func enter_play() -> void:
	_hint_panel.visible = false
	_regen_btn.visible = false
	_pick_panel.visible = false
	_top_bar.visible = true
	_speed_box.visible = true


func set_resources(money: float, income: float, factories: int, pop: float, date_text: String) -> void:
	_lbl_money.text = "Казна %s (+%s/день)" % [GameState.fmt(money), GameState.fmt(income)]
	_lbl_fact.text = "Заводы %d" % factories
	_lbl_pop.text = "Население %s" % GameState.fmt(pop)
	_lbl_date.text = date_text


func set_speed_mark(speed: int) -> void:
	for s in _speed_buttons.size():
		var b: Button = _speed_buttons[s]
		b.set_pressed_no_signal(s == speed)


## Находится ли точка экрана над элементом интерфейса (тогда тап по карте игнорируем).
func is_over_ui(screen_pos: Vector2) -> bool:
	for c in _blockers:
		var ctl: Control = c
		if ctl.is_visible_in_tree() and ctl.get_global_rect().has_point(screen_pos):
			return true
	return false


# ---------- внутреннее ----------

func _on_speed_pressed(speed: int) -> void:
	speed_selected.emit(speed)


func _make_panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.11, 0.2, 0.92)
	sb.border_color = Color(0.35, 0.5, 0.75, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(10.0)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _plain_label(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", FONT)
	l.add_theme_color_override("font_color", color)
	return l


func _stat_label(parent: Control, color: Color) -> Label:
	var l := _plain_label("", color)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l
