extends CanvasLayer
## Интерфейс: верхняя панель, меню справа (Баланс, Страны, Производство, Наука), подсказка,
## выбор страны, информация о плитке с кнопками действий, скорость, сообщения, итоговый экран.
## Всё собирается кодом. Наружу общается только сигналами и set_* методами.

signal confirm_pressed
signal regen_pressed
signal speed_selected(speed: int)
signal menu_toggled(index: int, on: bool)
signal action_pressed(id: String)
signal production_changed(percent: int)
signal research_pressed(branch: int)
signal restart_pressed
signal difficulty_changed(level: int)
signal continue_pressed
signal save_pressed
signal sound_toggled(on: bool)
signal volume_changed(value: float)

const GameState = preload("res://scripts/core/game_state.gd")

const FONT := 22
const SPEED_NAMES: Array = ["Пауза", "x1", "x2", "x3"]
const ACTION_SLOTS := 7
const MENU_ICONS: Array = ["balance", "countries", "production", "science", "settings", "ports", "army", "politics", "population"]
const MENU_NAMES: Array = ["Баланс", "Страны", "Производство", "Наука", "Настройки", "Порты", "Армия", "Политика", "Население"]
const PortPanel = preload("res://scripts/view/port_panel.gd")
const ArmyPanel = preload("res://scripts/view/army_panel.gd")
const PolPanel = preload("res://scripts/view/pol_panel.gd")
const GroupPanel = preload("res://scripts/view/group_panel.gd")
const UpgradePanel = preload("res://scripts/view/upgrade_panel.gd")
const ICON_DIR := "res://assets/icons/"

var _top_bar: PanelContainer
var _lbl_money: Label
var _lbl_fact: Label
var _lbl_army: Label
var _lbl_pop: Label
var _lbl_date: Label
var _hint_panel: PanelContainer
var _info_panel: PanelContainer
var _info_label: Label
var _pick_panel: PanelContainer
var _pick_label: Label
var _regen_btn: Button
var _help_btn: Button
var _help_panel: PanelContainer
const HELP_TEXT := "ЦЕЛЬ\nЗахватите столицы всех стран. Если враг возьмёт вашу столицу — вы проиграете. Взятая столица присоединяет страну к победителю.\n\nКАРТА\nПальцем двигайте карту, двумя пальцами приближайте. Нажмите на плитку, чтобы выбрать её. На чужой стране видна информация о ней, на своём городе — кнопки стройки.\n\nДЕНЬГИ И НАСЕЛЕНИЕ\nКазна растёт от заводов (+90 в день каждый) и тратится на армию (−50 за дивизию) и флот. Нажмите на значок казны — увидите подробности. Население растёт каждый день; нажмите на его значок.\nЗаводы строят в городах (кнопка «Построить завод»). Порт можно построить в городе у моря.\n\nАРМИЯ\nДивизии покупаются только в меню со значком каски справа: цена растёт с каждой купленной. Новая дивизия появляется в столице, а если она занята — в ближайшем свободном городе.\nНажмите на свою дивизию, затем на нужную плитку — дивизия пойдёт туда сама. Дивизии не могут стоять на одной плитке. После боя дивизия отдыхает; окружённая (без связи со столицей или прибрежным городом) не лечится.\n\nВОЙНА\nЧтобы начать войну, нажмите на чужую страну: «Оправдать войну» (стоит политических очков). Через 20 дней появится кнопка «Объявить войну». Противник заранее видит плашку «проводит агрессивную политику».\nПредложить мир можно после 10 дней войны.\n\nВОЕННЫЕ ГРУППЫ\nКнопка с силуэтом солдата внизу по центру. Создайте группу (+), нажимайте на свои дивизии, чтобы добавить их (контур цвета группы). Выберите страну сверху и приказ: «Атака» — дивизии сами идут к цели, «Защитить» — встают на границе. «Расформировать» распускает группу.\n\nПОЛИТИКА\nОчки политики: 60 в начале, +2 в день. Тратятся на оправдание войны и альянсы (10 очков). Союзников у страны может быть не больше 5. Союзник вправе отказаться вступать в войну. Вам тоже будут приходить предложения.\n\nФЛОТ\nВ меню «Исследования» на третьей странице покупают десантный и боевой корабли (нужен порт). В порту (значок якоря) корабли можно выбрать и вывести в море. Выберите корабль и нажмите на воду — поплывёт. Нажмите на свою береговую плитку с дивизией — десантный её заберёт; на берег врага — высадит. Боевой корабль топит вражеские десантные и обстреливает дивизии на берегу, отбрасывая их.\n\nИССЛЕДОВАНИЯ\nУлучшайте оружие пехоты, дома (рост населения) и механизацию (быстрее лечение).\n\nСОХРАНЕНИЕ\nИгра сохраняется сама. Кнопка «Продолжить» на экране выбора страны загрузит последнюю партию.\n"

const VERSION_TEXT := "1.0.0"
var _speed_box: HBoxContainer
var _speed_buttons: Array = []
var _action_btns: Array = []
var _action_ids: Array = []
var _menu_row: VBoxContainer
var _diff_btns: Array = []
var _menu_btns: Array = []
var _menu_panels: Array = []
var _balance_label: Label
var _countries_label: Label
var _prod_label: Label
var _prod_slider: HSlider
var _res_label: Label
var _res_btns: Array = []
var _toast: PanelContainer
var _toast_label: Label
var _toast_token: int = 0
var _result_panel: PanelContainer
var _result_title: Label
var _result_text: Label
var port_panel: PortPanel
var army_panel: ArmyPanel
var pol_panel: PolPanel
var _lbl_pol: Label
var _req_panel: PanelContainer
var _req_label: Label
var _notice_box: VBoxContainer
var _notice_sig := ""
var _notice_bars: Array = []
var group_panel: GroupPanel
var upgrade_panel: UpgradePanel
var _group_btn: Button
signal group_button_pressed
signal request_answered(accept: bool)
var _pop_label: Label
var _blockers: Array = []
var _continue_btn: Button
var _sound_check: CheckButton
var _volume_slider: HSlider
var _pfx: Dictionary = {}   # подписи вместо иконок, если иконка не загрузилась


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
	_lbl_money = _stat_label(row, Color(1.0, 0.86, 0.4), "coin", "Казна ")
	_lbl_fact = _stat_label(row, Color(0.95, 0.6, 0.45), "factory", "Заводы ")
	_lbl_army = _stat_label(row, Color(0.75, 0.9, 0.6), "soldier", "Армия ")
	_lbl_pop = _stat_label(row, Color(0.6, 0.85, 1.0), "people", "Население ")
	_lbl_pol = _stat_label(row, Color(0.8, 0.75, 1.0), "politics", "Политика ")
	_lbl_date = _stat_label(row, Color(0.85, 0.9, 0.95), "calendar", "")
	_make_clickable(_lbl_money, 0)
	_make_clickable(_lbl_pop, 8)
	_make_clickable(_lbl_pol, 7)
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

	# --- «Как играть» ---
	_help_btn = Button.new()
	_help_btn.text = "Как играть"
	_help_btn.add_theme_font_size_override("font_size", FONT)
	add_child(_help_btn)
	_help_btn.offset_left = 8.0
	_help_btn.offset_right = 200.0
	_help_btn.offset_top = 8.0
	_help_btn.pressed.connect(open_help)
	_help_panel = _make_panel()
	add_child(_help_panel)
	_help_panel.anchor_left = 0.08
	_help_panel.anchor_right = 0.92
	_help_panel.anchor_top = 0.06
	_help_panel.anchor_bottom = 0.94
	var hv := VBoxContainer.new()
	_help_panel.add_child(hv)
	var hrow := HBoxContainer.new()
	hv.add_child(hrow)
	var ht := _plain_label("Как играть", Color(1, 0.9, 0.5))
	ht.add_theme_font_size_override("font_size", 30)
	ht.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hrow.add_child(ht)
	var hx := Button.new()
	hx.text = "X"
	hx.custom_minimum_size = Vector2(56, 48)
	hx.pressed.connect(func(): _help_panel.visible = false)
	hrow.add_child(hx)
	var hs := ScrollContainer.new()
	hs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hs.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hv.add_child(hs)
	var htext := _plain_label(HELP_TEXT, Color(0.92, 0.95, 1.0))
	htext.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	htext.custom_minimum_size = Vector2(900, 0)
	htext.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hs.add_child(htext)
	_help_panel.visible = false

	# --- кнопка «Продолжить» (если есть сохранение; только при выборе страны) ---
	_continue_btn = Button.new()
	_continue_btn.text = "Продолжить игру"
	_continue_btn.add_theme_font_size_override("font_size", FONT)
	add_child(_continue_btn)
	_continue_btn.offset_left = 8.0
	_continue_btn.offset_top = 8.0
	_continue_btn.pressed.connect(func(): continue_pressed.emit())
	_continue_btn.visible = false

	# --- информация о плитке и кнопки действий (слева внизу) ---
	_info_panel = _make_panel()
	add_child(_info_panel)
	_info_panel.anchor_top = 1.0
	_info_panel.anchor_bottom = 1.0
	_info_panel.offset_left = 8.0
	_info_panel.offset_bottom = -72.0
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

	# --- военные группы: кнопка-профиль внизу по центру и окно ---
	group_panel = GroupPanel.new()
	add_child(group_panel)
	group_panel.anchor_left = 0.5
	group_panel.anchor_right = 0.5
	group_panel.anchor_top = 1.0
	group_panel.anchor_bottom = 1.0
	group_panel.offset_bottom = -8.0
	group_panel.offset_left = -250.0
	group_panel.offset_right = 290.0
	group_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	group_panel.visible = false
	group_panel.closed.connect(func(): group_panel.visible = false)
	_group_btn = Button.new()
	add_child(_group_btn)
	_group_btn.anchor_left = 0.5
	_group_btn.anchor_right = 0.5
	_group_btn.anchor_top = 1.0
	_group_btn.anchor_bottom = 1.0
	_group_btn.offset_left = -30.0
	_group_btn.offset_right = 30.0
	_group_btn.offset_top = -68.0
	_group_btn.offset_bottom = -8.0
	_group_btn.tooltip_text = "Военные группы"
	var gtex := load("res://assets/icons/soldier.svg") as Texture2D
	if gtex != null:
		_group_btn.icon = gtex
		_group_btn.expand_icon = true
	else:
		_group_btn.text = "Группы"
	_group_btn.visible = false
	_group_btn.pressed.connect(func(): group_button_pressed.emit())

	# --- запрос игроку (альянс / вступление в войну) ---
	_req_panel = _make_panel()
	add_child(_req_panel)
	_req_panel.anchor_left = 0.5
	_req_panel.anchor_right = 0.5
	_req_panel.anchor_top = 0.5
	_req_panel.anchor_bottom = 0.5
	_req_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_req_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var rbox2 := VBoxContainer.new()
	rbox2.add_theme_constant_override("separation", 10)
	_req_panel.add_child(rbox2)
	_req_label = _plain_label("", Color(1, 1, 1))
	_req_label.custom_minimum_size = Vector2(420, 0)
	_req_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rbox2.add_child(_req_label)
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 12)
	rbox2.add_child(rrow)
	var yes := Button.new()
	yes.text = "Согласиться"
	yes.custom_minimum_size = Vector2(190, 52)
	yes.add_theme_font_size_override("font_size", FONT)
	yes.pressed.connect(func(): request_answered.emit(true))
	rrow.add_child(yes)
	var no := Button.new()
	no.text = "Отказаться"
	no.custom_minimum_size = Vector2(190, 52)
	no.add_theme_font_size_override("font_size", FONT)
	no.pressed.connect(func(): request_answered.emit(false))
	rrow.add_child(no)
	_req_panel.visible = false

	# --- уведомления об агрессии (справа, с полоской) ---
	_notice_box = VBoxContainer.new()
	add_child(_notice_box)
	_notice_box.anchor_left = 1.0
	_notice_box.anchor_right = 1.0
	_notice_box.offset_right = -84.0
	_notice_box.offset_top = 56.0
	_notice_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_notice_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

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
		if s == 0:
			b.visible = false   # паузы нет
		_speed_box.add_child(b)
		_speed_buttons.append(b)
	_speed_box.visible = false

	_build_menu()

	# --- всплывающее сообщение ---
	_toast = _make_panel()
	add_child(_toast)
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.offset_top = 76.0
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_label = _plain_label("", Color(1.0, 0.92, 0.6))
	_toast.add_child(_toast_label)
	_toast.visible = false

	# --- итоговый экран: победа / поражение ---
	_result_panel = _make_panel()
	add_child(_result_panel)
	_result_panel.anchor_left = 0.5
	_result_panel.anchor_right = 0.5
	_result_panel.anchor_top = 0.5
	_result_panel.anchor_bottom = 0.5
	_result_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_result_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var rbox := VBoxContainer.new()
	_result_panel.add_child(rbox)
	_result_title = _plain_label("", Color(1.0, 0.9, 0.4))
	_result_title.add_theme_font_size_override("font_size", 40)
	_result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rbox.add_child(_result_title)
	_result_text = _plain_label("", Color(1, 1, 1))
	_result_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_text.custom_minimum_size = Vector2(420, 0)
	_result_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rbox.add_child(_result_text)
	var again := Button.new()
	again.text = "Новая игра"
	again.add_theme_font_size_override("font_size", FONT)
	again.pressed.connect(func(): restart_pressed.emit())
	rbox.add_child(again)
	_result_panel.visible = false

	_blockers = [_help_panel, _help_btn, _req_panel, group_panel, _group_btn, _top_bar, _hint_panel, _regen_btn, _info_panel, _pick_panel, _speed_box,
		_menu_row, _result_panel, _continue_btn]
	for p in _menu_panels:
		_blockers.append(p)


## Меню справа сверху: четыре кнопки-переключателя и четыре окна (открыто не больше одного).
func _build_menu() -> void:
	_menu_row = VBoxContainer.new()
	add_child(_menu_row)
	_menu_row.anchor_left = 1.0
	_menu_row.anchor_right = 1.0
	_menu_row.offset_right = -8.0
	_menu_row.offset_top = 76.0
	_menu_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	for n in MENU_NAMES.size():
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(68, 68)
		b.tooltip_text = MENU_NAMES[n]
		var ipath: String = ICON_DIR + String(MENU_ICONS[n]) + ".svg"
		var itex: Texture2D = null
		if ResourceLoader.exists(ipath):
			itex = load(ipath) as Texture2D
		if itex != null:
			b.icon = itex
			b.expand_icon = true
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		else:
			b.text = MENU_NAMES[n]
			b.add_theme_font_size_override("font_size", 16)
		b.toggled.connect(_on_menu_toggled.bind(n))
		_menu_row.add_child(b)
		_menu_btns.append(b)
		var p := _make_panel()
		add_child(p)
		p.anchor_left = 1.0
		p.anchor_right = 1.0
		p.offset_right = -84.0
		p.offset_top = 76.0
		p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		p.visible = false
		_menu_panels.append(p)
	_menu_row.visible = false

	# 0 Баланс
	_balance_label = _plain_label("", Color(0.92, 0.95, 1.0))
	_balance_label.custom_minimum_size = Vector2(400, 0)
	var p0: PanelContainer = _menu_panels[0]
	p0.add_child(_balance_label)

	# 1 Страны (прокрутка)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(440, 330)
	_countries_label = _plain_label("", Color(0.92, 0.95, 1.0))
	scroll.add_child(_countries_label)
	var p1: PanelContainer = _menu_panels[1]
	p1.add_child(scroll)

	# 2 Производство
	var pbox := VBoxContainer.new()
	_prod_label = _plain_label("", Color(0.92, 0.95, 1.0))
	_prod_label.custom_minimum_size = Vector2(420, 0)
	pbox.add_child(_prod_label)
	_prod_slider = HSlider.new()
	_prod_slider.min_value = 0
	_prod_slider.max_value = 100
	_prod_slider.step = 5
	_prod_slider.custom_minimum_size = Vector2(420, 40)
	_prod_slider.value_changed.connect(func(v: float): production_changed.emit(int(v)))
	pbox.add_child(_prod_slider)
	var p2: PanelContainer = _menu_panels[2]
	p2.add_child(pbox)

	# 3 Исследования (улучшения): большое окно
	upgrade_panel = UpgradePanel.new()
	var p3: PanelContainer = _menu_panels[3]
	p3.add_child(upgrade_panel)
	p3.anchor_left = 0.04
	p3.anchor_right = 1.0
	p3.offset_left = 0.0
	p3.offset_right = -84.0
	p3.offset_top = 56.0
	p3.anchor_bottom = 1.0
	p3.offset_bottom = -12.0

	# 4 Настройки
	var sbox := VBoxContainer.new()
	_sound_check = CheckButton.new()
	_sound_check.text = "Звук"
	_sound_check.button_pressed = true
	_sound_check.add_theme_font_size_override("font_size", FONT)
	_sound_check.toggled.connect(func(on: bool): sound_toggled.emit(on))
	sbox.add_child(_sound_check)
	sbox.add_child(_plain_label("Громкость", Color(0.92, 0.95, 1.0)))
	_volume_slider = HSlider.new()
	_volume_slider.min_value = 0.0
	_volume_slider.max_value = 1.0
	_volume_slider.step = 0.05
	_volume_slider.value = 0.7
	_volume_slider.custom_minimum_size = Vector2(380, 40)
	_volume_slider.value_changed.connect(func(v: float): volume_changed.emit(v))
	sbox.add_child(_volume_slider)
	sbox.add_child(_plain_label("Сложность ботов", Color(0.92, 0.95, 1.0)))
	var drow := HBoxContainer.new()
	var dnames: Array = ["Лёгкая", "Средняя", "Сложная"]
	for n in 3:
		var db := Button.new()
		db.text = dnames[n]
		db.toggle_mode = true
		db.add_theme_font_size_override("font_size", 20)
		db.pressed.connect(_on_diff_pressed.bind(n))
		drow.add_child(db)
		_diff_btns.append(db)
	sbox.add_child(drow)
	var save_btn := Button.new()
	save_btn.text = "Сохранить игру"
	save_btn.add_theme_font_size_override("font_size", FONT)
	save_btn.pressed.connect(func(): save_pressed.emit())
	sbox.add_child(save_btn)
	var help_btn2 := Button.new()
	help_btn2.text = "Как играть"
	help_btn2.add_theme_font_size_override("font_size", FONT)
	help_btn2.pressed.connect(open_help)
	sbox.add_child(help_btn2)
	sbox.add_child(_plain_label("Версия %s" % VERSION_TEXT, Color(0.7, 0.75, 0.85)))
	var new_btn := Button.new()
	new_btn.text = "Новая игра (с начала)"
	new_btn.add_theme_font_size_override("font_size", FONT)
	new_btn.pressed.connect(func(): restart_pressed.emit())
	sbox.add_child(new_btn)
	var p4: PanelContainer = _menu_panels[4]
	p4.add_child(sbox)

	# 5 Порты (прокрутка)
	var pscroll := ScrollContainer.new()
	pscroll.custom_minimum_size = Vector2(860, 430)
	port_panel = PortPanel.new()
	port_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pscroll.add_child(port_panel)
	var p5: PanelContainer = _menu_panels[5]
	p5.add_child(pscroll)

	# 6 Армия
	army_panel = ArmyPanel.new()
	var p6: PanelContainer = _menu_panels[6]
	p6.add_child(army_panel)

	# 7 Политика
	pol_panel = PolPanel.new()
	var p7: PanelContainer = _menu_panels[7]
	p7.add_child(pol_panel)

	# 8 Население (по нажатию на значок населения)
	_pop_label = _plain_label("", Color(0.92, 0.95, 1.0))
	_pop_label.custom_minimum_size = Vector2(320, 0)
	var p8: PanelContainer = _menu_panels[8]
	p8.add_child(_pop_label)
	var b8: Button = _menu_btns[8]
	b8.visible = false
	p8.anchor_left = 0.0
	p8.anchor_right = 0.0
	p8.offset_left = 8.0
	p8.offset_right = 0.0
	p8.grow_horizontal = Control.GROW_DIRECTION_END

	# баланс открывается по нажатию на казну (слева сверху), своей кнопки справа нет
	var b0: Button = _menu_btns[0]
	b0.visible = false
	p0.anchor_left = 0.0
	p0.anchor_right = 0.0
	p0.offset_left = 8.0
	p0.offset_right = 0.0
	p0.grow_horizontal = Control.GROW_DIRECTION_END


func _on_menu_toggled(on: bool, index: int) -> void:
	menu_toggled.emit(index, on)
	for n in _menu_panels.size():
		var p: PanelContainer = _menu_panels[n]
		var b: Button = _menu_btns[n]
		if n == index:
			p.visible = on
		elif on:
			p.visible = false
			b.set_pressed_no_signal(false)


func _on_diff_pressed(level: int) -> void:
	set_difficulty(level)
	difficulty_changed.emit(level)


func set_difficulty(level: int) -> void:
	for n in _diff_btns.size():
		var b: Button = _diff_btns[n]
		b.set_pressed_no_signal(n == level)


## Открывает окно меню по номеру (5 = порты).
func open_menu(index: int) -> void:
	for n in _menu_panels.size():
		var p: PanelContainer = _menu_panels[n]
		var b: Button = _menu_btns[n]
		p.visible = (n == index)
		b.set_pressed_no_signal(n == index)
	menu_toggled.emit(index, true)


func close_menus() -> void:
	_close_menu()


func menu_open(index: int) -> bool:
	var p: PanelContainer = _menu_panels[index]
	return p.visible


func _close_menu() -> void:
	for n in _menu_panels.size():
		var p: PanelContainer = _menu_panels[n]
		var b: Button = _menu_btns[n]
		p.visible = false
		b.set_pressed_no_signal(false)


# ---------- публичный интерфейс ----------

func set_info(text: String) -> void:
	_info_label.text = text
	_info_panel.visible = text != ""


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
	_help_btn.visible = false
	_help_panel.visible = false
	_speed_box.visible = true
	_group_btn.visible = true
	_menu_row.visible = true
	_continue_btn.visible = false


## Возврат к выбору страны (новая игра).
func enter_pick() -> void:
	_hint_panel.visible = true
	_help_btn.visible = true
	_regen_btn.visible = true
	_pick_panel.visible = false
	_top_bar.visible = false
	_speed_box.visible = false
	_group_btn.visible = false
	group_panel.visible = false
	_menu_row.visible = false
	_result_panel.visible = false
	_close_menu()
	set_actions([])


func set_continue_visible(on: bool) -> void:
	_continue_btn.visible = on


func set_settings(sound_on: bool, volume: float) -> void:
	_sound_check.set_pressed_no_signal(sound_on)
	_volume_slider.set_value_no_signal(volume)


func set_resources(money: float, net: float, factories: int, army: int, pop: float, date_text: String) -> void:
	_lbl_money.text = "%s%s (%s/день)" % [_pfx[_lbl_money], GameState.fmt(money), GameState.fmt_signed(net)]
	var col := Color(1.0, 0.86, 0.4)
	if money < 0.0:
		col = Color(1.0, 0.4, 0.35)
	_lbl_money.add_theme_color_override("font_color", col)
	_lbl_fact.text = "%s%d" % [_pfx[_lbl_fact], factories]
	_lbl_army.text = "%s%d" % [_pfx[_lbl_army], army]
	_lbl_pop.text = "%s%s" % [_pfx[_lbl_pop], GameState.fmt(pop)]
	_lbl_date.text = date_text


func open_help() -> void:
	_help_panel.visible = true


func show_request(text: String) -> void:
	_req_label.text = text
	_req_panel.visible = true


func hide_request() -> void:
	_req_panel.visible = false


## Плашки «страна проводит агрессию» с полоской загрузки: [{text, color, frac}].
func set_notices(list: Array) -> void:
	var sig := ""
	for it in list:
		sig += String(Dictionary(it)["text"]) + "|"
	if sig != _notice_sig:
		_notice_sig = sig
		_notice_bars = []
		for c in _notice_box.get_children():
			c.queue_free()
		for it2 in list:
			var d: Dictionary = it2
			var p := _make_panel()
			p.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var v := VBoxContainer.new()
			p.add_child(v)
			var l := _plain_label(String(d["text"]), Color(d["color"]).lightened(0.45))
			l.custom_minimum_size = Vector2(300, 0)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			v.add_child(l)
			var bar := ProgressBar.new()
			bar.min_value = 0.0
			bar.max_value = 1.0
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(300, 12)
			v.add_child(bar)
			_notice_box.add_child(p)
			_notice_bars.append(bar)
	for n in mini(list.size(), _notice_bars.size()):
		var br: ProgressBar = _notice_bars[n]
		br.value = float(Dictionary(list[n])["frac"])


func set_politics(points: float) -> void:
	_lbl_pol.text = "%s%d" % [_pfx[_lbl_pol], int(points)]


func _make_clickable(lbl: Label, index: int) -> void:
	var box: Control = lbl.get_parent()
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	box.gui_input.connect(_on_stat_input.bind(index))


func _on_stat_input(ev: InputEvent, index: int) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		if menu_open(index):
			close_menus()
		else:
			open_menu(index)


func set_pop_text(text: String) -> void:
	_pop_label.text = text


func set_balance_text(text: String) -> void:
	_balance_label.text = text


func set_countries_text(text: String) -> void:
	_countries_label.text = text


## Окно производства: percent = доля заводов на армию.
func set_production(percent: int, text: String) -> void:
	_prod_label.text = text
	_prod_slider.set_value_no_signal(float(percent))


## Окно науки: status — текст, list — три кнопки {text, enabled}.
func show_result(title: String, text: String) -> void:
	_result_title.text = title
	_result_text.text = text
	_result_panel.visible = true


func hide_result() -> void:
	_result_panel.visible = false


## Кнопки действий под информацией о плитке. Каждое: {"id": "...", "text": "...", "enabled": bool}.
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
## Дополнительное окно (например, порт), которое должно перехватывать нажатия.
func register_blocker(ctl: Control) -> void:
	_blockers.append(ctl)


func is_over_ui(screen_pos: Vector2) -> bool:
	for c in _blockers:
		var ctl: Control = c
		if ctl.is_visible_in_tree() and ctl.get_global_rect().has_point(screen_pos):
			return true
	return false


# ---------- внутреннее ----------

func _on_action_pressed(n: int) -> void:
	var id: String = _action_ids[n]
	if id != "":
		action_pressed.emit(id)


func _on_speed_pressed(speed: int) -> void:
	speed_selected.emit(speed)


func _make_panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.11, 0.2, 0.98)
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


func _stat_label(parent: Control, color: Color, icon: String, prefix: String) -> Label:
	var box := HBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	parent.add_child(box)
	var path := ICON_DIR + icon + ".svg"
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.custom_minimum_size = Vector2(30, 30)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		box.add_child(tr)
	var l := _plain_label("", color)
	box.add_child(l)
	if tex != null:
		_pfx[l] = ""
	else:
		_pfx[l] = prefix
	return l
