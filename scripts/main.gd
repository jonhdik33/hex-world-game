extends Node
## Точка входа и "дирижёр": собирает мир, карту, камеру, интерфейс и ведёт игру.
## Две фазы: выбор страны (playing = false) и сама игра (playing = true).

const World = preload("res://scripts/core/world.gd")
const WorldGen = preload("res://scripts/core/world_gen.gd")
const GameState = preload("res://scripts/core/game_state.gd")
const MapView = preload("res://scripts/view/map_view.gd")
const CameraCtl = preload("res://scripts/view/camera_controller.gd")
const Hud = preload("res://scripts/view/hud.gd")

const MASK_PATH := "res://assets/map_mask.png"
const START_SEED := 12345
# секунд реального времени на один игровой день; индекс = скорость (0 = пауза)
const DAY_SECONDS: Array = [0.0, 3.0, 1.5, 0.6]

var world: World
var state: GameState
var map_view: MapView
var camera: CameraCtl
var hud: Hud

var seed_value: int = START_SEED
var playing: bool = false
var speed: int = 1
var _accum: float = 0.0
var _picked: int = -1
var _sel_land: int = -1
var _move_from: int = -1      # режим «двигать»: откуда
var _move_count: int = 0      # сколько дивизий (большое число = все)


func _ready() -> void:
	# тёмный фон: за краем игрового мира ничего нет (камера туда не заходит)
	RenderingServer.set_default_clear_color(Color(0.02, 0.05, 0.11))

	var tex := load(MASK_PATH) as Texture2D
	if tex == null:
		push_error("Не найдена маска суши: " + MASK_PATH)
		return
	var mask: Image = tex.get_image()

	world = World.new()
	WorldGen.build_land(world, mask)
	WorldGen.assign_countries(world, seed_value)
	state = GameState.new(world)

	map_view = MapView.new()
	add_child(map_view)
	map_view.setup(world)

	camera = CameraCtl.new()
	add_child(camera)
	camera.make_current()
	camera.fit_to(world.bounds())
	camera.tapped.connect(_on_tapped)

	hud = Hud.new()
	add_child(hud)
	hud.confirm_pressed.connect(_on_confirm)
	hud.regen_pressed.connect(_on_regen)
	hud.speed_selected.connect(_on_speed)
	hud.action_pressed.connect(_on_action)

	_show_info_empty()


func _process(delta: float) -> void:
	if not playing or speed <= 0:
		return
	_accum += delta
	var step: float = DAY_SECONDS[speed]
	var guard := 0
	while _accum >= step and guard < 20:
		_accum -= step
		state.tick_day()
		guard += 1
	if guard > 0:
		_after_ticks()


# ---------- события ----------

func _on_tapped(screen_pos: Vector2, world_pos: Vector2) -> void:
	if hud.is_over_ui(screen_pos):
		return
	if not world.bounds().has_point(world_pos):
		_clear_all()
		return

	var i := map_view.pick_land(world_pos)
	if i >= 0 and _move_from >= 0 and playing:
		if _try_move(i):
			return
	if i >= 0:
		_move_from = -1
		_sel_land = i
		map_view.select_land(i)
		if not playing:
			_pick_on_tile(i)
		_show_land_info(i)
		return

	# нажали на воду: выбираем крупную морскую ячейку
	_sel_land = -1
	_move_from = -1
	hud.set_actions([])
	if not playing:
		_picked = -1
		hud.hide_pick()
	var j := world.sea_grid.tile_at(world_pos)
	if j >= 0 and world.sea_navigable[j] == 1:
		map_view.select_sea(j)
		_show_sea_info(j)
	else:
		map_view.clear_selection()
		_show_info_empty()


func _clear_all() -> void:
	_sel_land = -1
	_move_from = -1
	hud.set_actions([])
	map_view.clear_selection()
	if not playing:
		_picked = -1
		hud.hide_pick()
	_show_info_empty()


func _pick_on_tile(i: int) -> void:
	if world.tile_owner[i] >= 0:
		_picked = world.tile_owner[i]
		var cn: Dictionary = world.countries[_picked]
		var text := "%s\nПлиток: %d · Городов: %d\nЗаводов: %d" % [cn["name"], cn["tiles"], cn["cities"], cn["factories"]]
		if cn["mega"]:
			text += "\nПромышленный гигант"
		hud.show_pick(text)
	else:
		_picked = -1
		hud.hide_pick()


func _on_confirm() -> void:
	if _picked < 0:
		return
	state.player = _picked
	playing = true
	speed = 1
	_accum = 0.0
	map_view.set_player(_picked)
	map_view.set_army(state.tile_army)
	hud.enter_play()
	hud.set_speed_mark(speed)
	_refresh_hud()
	if _sel_land >= 0:
		_show_land_info(_sel_land)


func _on_action(id: String) -> void:
	if not playing or _sel_land < 0:
		return
	var cid := state.player
	var t := _sel_land
	if id == "build":
		if state.start_build(cid, t):
			hud.show_event("Начато строительство завода: %d дн." % GameState.BUILD_DAYS)
			map_view.set_construction(state.construction_tiles(cid))
	elif id == "recruit":
		if state.recruit(cid, t):
			hud.show_event("Нанята дивизия")
			map_view.set_army(state.tile_army)
	elif id == "disband":
		if state.disband(cid, t):
			hud.show_event("Дивизия распущена")
			map_view.set_army(state.tile_army)
	elif id == "move_all" or id == "move_one":
		_move_from = t
		_move_count = 1
		if id == "move_all":
			_move_count = 9999
		hud.show_event("Нажмите на соседнюю плитку")
		return
	_refresh_hud()
	_show_land_info(t)


## Тап в режиме «двигать»: true, если тап обработан как ход.
func _try_move(to: int) -> bool:
	var from := _move_from
	_move_from = -1
	if not state.is_adjacent(from, to):
		return false
	var msg := state.move_army(state.player, from, to, _move_count)
	if msg == "":
		hud.show_event("Ход невозможен")
		return true
	hud.show_event(msg)
	map_view.set_army(state.tile_army)
	if state.map_dirty:
		state.map_dirty = false
		map_view.set_construction(state.construction_tiles(state.player))
		map_view.refresh()
	_sel_land = to
	map_view.select_land(to)
	_refresh_hud()
	_show_land_info(to)
	return true


## После дневных тиков: сообщения, изменения карты, интерфейс.
func _after_ticks() -> void:
	if state.events.size() > 0:
		hud.show_event("\n".join(state.events))
		state.events = []
	if state.map_dirty:
		state.map_dirty = false
		map_view.set_construction(state.construction_tiles(state.player))
		map_view.refresh()
		if _sel_land >= 0:
			_show_land_info(_sel_land)
	map_view.set_army(state.tile_army)
	_refresh_hud()


func _on_regen() -> void:
	if playing:
		return
	seed_value += 1
	WorldGen.assign_countries(world, seed_value)
	state.reset()
	_picked = -1
	_sel_land = -1
	hud.hide_pick()
	map_view.clear_selection()
	map_view.set_construction([])
	map_view.set_army(PackedInt32Array())
	map_view.refresh()
	_show_info_empty()


func _on_speed(s: int) -> void:
	speed = s
	_accum = 0.0
	hud.set_speed_mark(speed)


# ---------- интерфейс ----------

func _refresh_hud() -> void:
	var cid := state.player
	if cid < 0:
		return
	var cn: Dictionary = world.countries[cid]
	hud.set_resources(
		float(state.money[cid]),
		state.daily_net(cid),
		int(cn["factories"]),
		int(state.army[cid]),
		float(state.population[cid]),
		state.format_date()
	)
	hud.set_balance_text(_balance_text(cid))


func _balance_text(cid: int) -> String:
	var b: Dictionary = state.budget(cid)
	var army_n: int = state.army[cid]
	var cn: Dictionary = world.countries[cid]
	var lines: Array[String] = ["Баланс за день"]
	lines.append("+ Налоги: %s" % GameState.fmt(b["tax"]))
	lines.append("+ Заводы (%d): %s" % [cn["factories"], GameState.fmt(b["industry"])])
	lines.append("- Заводы, содержание: %s" % GameState.fmt(b["upkeep_factories"]))
	lines.append("- Города (%d): %s" % [cn["cities"], GameState.fmt(b["upkeep_cities"])])
	lines.append("- Армия (%d див.): %s" % [army_n, GameState.fmt(b["upkeep_army"])])
	lines.append("ИТОГО: %s/день" % GameState.fmt_signed(b["net"]))
	var nb := state.construction_tiles(cid).size()
	if nb > 0:
		lines.append("Строек: %d" % nb)
	return "\n".join(lines)


func _show_info_empty() -> void:
	hud.set_info("Карта №%d · стран: %d\nНажмите на плитку или на море" % [seed_value, world.countries.size()])


func _show_land_info(t: int) -> void:
	var lines: Array[String] = []
	var cid := world.tile_owner[t]
	if cid >= 0:
		var cn: Dictionary = world.countries[cid]
		lines.append("Страна: %s" % cn["name"])
		lines.append("Плиток: %d · Заводов: %d" % [cn["tiles"], cn["factories"]])
	var kind := world.tile_city[t]
	if kind == 2:
		lines.append("Столица · заводов здесь: %d" % world.tile_factories[t])
	elif kind == 1:
		lines.append("Город · заводов здесь: %d" % world.tile_factories[t])
	else:
		lines.append("Земля")
	lines.append("Плитка: %d, %d" % [world.col_of(t), world.row_of(t)])
	if playing and state.army_on(t) > 0:
		lines.append("Дивизий здесь: %d" % state.army_on(t))
	if playing and state.is_building(t):
		lines.append("Строится завод: ещё %d дн." % state.build_days_left(t))
	hud.set_info("\n".join(lines))
	_update_actions(t)


func _update_actions(t: int) -> void:
	if not playing or world.tile_owner[t] != state.player:
		hud.set_actions([])
		return
	var cid := state.player
	var list: Array = []
	# строить завод
	var reason := state.build_block_reason(cid, t)
	var label := "Построить завод (%s)" % GameState.fmt(state.build_cost(t))
	if reason == "":
		list.append({"id": "build", "text": label, "enabled": true})
	elif reason == "Не хватает денег":
		list.append({"id": "build", "text": label + " — нет денег", "enabled": false})
	else:
		list.append({"id": "build", "text": reason, "enabled": false})
	# армия
	if world.tile_city[t] != 0:
		var r2 := state.recruit_block_reason(cid, t)
		var l2 := "Нанять дивизию (%s)" % GameState.fmt(GameState.RECRUIT_COST)
		if r2 == "Не хватает денег":
			l2 += " — нет денег"
		list.append({"id": "recruit", "text": l2, "enabled": r2 == ""})
	var a := state.army_on(t)
	if a > 0:
		list.append({"id": "move_all", "text": "Двинуть все дивизии (%d)" % a, "enabled": true})
		if a > 1:
			list.append({"id": "move_one", "text": "Двинуть одну дивизию", "enabled": true})
		list.append({"id": "disband", "text": "Распустить одну дивизию", "enabled": true})
	hud.set_actions(list)


func _show_sea_info(j: int) -> void:
	var g := world.sea_grid
	var lines: Array[String] = []
	if world.sea_coastal[j] == 1:
		lines.append("Море: прибрежные воды")
	else:
		lines.append("Море: открытый океан")
	lines.append("Морская зона: %d, %d" % [g.col_of(j), g.row_of(j)])
	lines.append("Суши в зоне: %d%%" % int(round(world.sea_land_share[j] * 100.0)))
	hud.set_info("\n".join(lines))
