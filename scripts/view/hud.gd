extends CanvasLayer
## Интерфейс: верхняя панель, подсказка, окно выбора страны, информация о плитке,
## кнопки скорости. Всё собирается кодом, оформление своё (тёмно-синие панели).
## Наружу общается только сигналами и set_* методами.

signal confirm_pressed
signal regen_pressed
signal speed_selected(speed: int)
signal action_pressed(id: String)

const GameState = preload("res://scripts/core/game_state.gd")

const FONT := 22
const ACTION_SLOTS := 5
const SPEED_NAMES: Array = ["Пауза", "x1", "x2", "x3"]

var _top_bar: PanelContainer
var _lbl_money: Label
var _lbl_fact: Label
var _lbl_army: Label
var _lbl_pop: Label
var _balance_btn: Button
var _balance_panel: PanelContainer
var _balance_label: Label
var _action_btns: Array = []
var _action_ids: Array = []
var _toast: PanelContainer
var _toast_label: Label
var _toast_token: int = 0
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
	_lbl_army = _stat_label(row, Color(0.75, 0.9, 0.6))
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
	var ibox := VBoxContainer.new()
	_info_panel.add_child(ibox)
	_info_label = _plain_label("", Color(0.92, 0.95, 1.0))
	_info_label.custom_minimum_size = Vector2(330, 0)
	ibox.add_child(_info_label)
	for n in ACTION_SLOTS:
		var ab := Button.new()
		ab.add_theme_font_size_override("font_size", FONT)
		ab.pressed.connect(_on_action_pressed.bind(n))
		ab.visible = false
		ibox.add_child(ab)
		_action_btns.append(ab)
		_action_ids.append("")

	# --- баланс (кнопка и окно слева сверху, во время игры) ---
	_balance_btn = Button.new()
	_balance_btn.text = "Баланс"
	_balance_btn.toggle_mode = true
	_balance_btn.add_theme_font_size_override("font_size", FONT)
	add_child(_balance_btn)
	_balance_btn.offset_left = 8.0
	_balance_btn.offset_top = 76.0
	_balance_btn.offset_right = 160.0
	_balance_btn.toggled.connect(func(on: bool): _balance_panel.visible = on)
	_balance_btn.visible = false
	_balance_panel = _make_panel()
	add_child(_balance_panel)
	_balance_panel.offset_left = 8.0
	_balance_panel.offset_top = 132.0
	_balance_label = _plain_label("", Color(0.92, 0.95, 1.0))
	_balance_label.custom_minimum_size = Vector2(380, 0)
	_balance_panel.add_child(_balance_label)
	_balance_panel.visible = false

	# --- всплывающее сообщение (по центру сверху, во время игры) ---
	_toast = _make_panel()
	add_child(_toast)
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.offset_top = 76.0
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_label = _plain_label("", Color(1.0, 0.92, 0.6))
	_toast.add_child(_toast_label)
	_toast.visible = false

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

	_blockers = [_top_bar, _hint_panel, _regen_btn, _info_panel, _pick_panel, _speed_box, _balance_btn, _balance_panel]


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
	_balance_btn.visible = true


func set_resources(money: float, net: float, factories: int, army: int, pop: float, date_text: String) -> void:
	_lbl_money.text = "Казна %s (%s/день)" % [GameState.fmt(money), GameState.fmt_signed(net)]
	var col := Color(1.0, 0.86, 0.4)
	if money < 0.0:
		col = Color(1.0, 0.4, 0.35)
	_lbl_money.add_theme_color_override("font_color", col)
	_lbl_fact.text = "Заводы %d" % factories
	_lbl_army.text = "Армия %d" % army
	_lbl_pop.text = "Население %s" % GameState.fmt(pop)
	_lbl_date.text = date_text


func set_balance_text(text: String) -> void:
	_balance_label.text = text


## Кнопки действий под информацией о плитке. Каждое действие: {"id": "...", "text": "...", "enabled": bool}.
func set_actions(list: Array) -> void:
	for n in ACTION_SLOTS:
		var b: Button = _action_btns[n]
		if n < list.size():
			var a: Dictionary = list[n]
			_action_ids[n] = a["id"]
			b.text = a["text"]
			b.disabled = not bool(a["enabled"])
			b.visible = true
		else:
			_action_ids[n] = ""
			b.visible = false


func _on_action_pressed(n: int) -> void:
	var id: String = _action_ids[n]
	if id != "":
		action_pressed.emit(id)


func show_event(text: String) -> void:
	_toast_label.text = text
	_toast.visible = true
	_toast_token += 1
	var tok := _toast_token
	get_tree().create_timer(3.5).timeout.connect(_hide_event.bind(tok))


func _hide_event(tok: int) -> void:
	if tok == _toast_token:
		_toast.visible = false


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
