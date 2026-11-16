extends Node
## Точка входа и "дирижёр": собирает мир, карту, камеру, интерфейс и ведёт игру.
## Две фазы: выбор страны (playing = false) и сама игра (playing = true).

const World = preload("res://scripts/core/world.gd")
const WorldGen = preload("res://scripts/core/world_gen.gd")
const GameState = preload("res://scripts/core/game_state.gd")
const MapView = preload("res://scripts/view/map_view.gd")
const CameraCtl = preload("res://scripts/view/camera_controller.gd")
const Hud = preload("res://scripts/view/hud.gd")
const UnitsView = preload("res://scripts/view/units_view.gd")
const SaveGame = preload("res://scripts/core/save_game.gd")
const Navy = preload("res://scripts/core/navy.gd")
const Sfx = preload("res://scripts/view/sfx.gd")

const SETTINGS_PATH := "user://settings.cfg"
const AUTOSAVE_DAYS := 5

const MASK_PATH := "res://assets/map_mask.png"
const START_SEED := 12345
# секунд реального времени на один игровой день; индекс = скорость (0 = пауза)
const DAY_SECONDS: Array = [0.0, 8.0, 4.0, 2.5]
# во сколько раз быстрее идут походы и бои (индекс = скорость)
const ANIM_FACTOR: Array = [0.0, 1.0, 2.0, 3.0]

var world: World
var state: GameState
var map_view: MapView
var units: UnitsView
var camera: CameraCtl
var hud: Hud
var sfx: Sfx
var sound_on: bool = true
var volume: float = 0.7
var _last_save_day: int = 0

var seed_value: int = START_SEED
var playing: bool = false
var over: bool = false        # игра закончена (победа/поражение), ждём «Новая игра»
var speed: int = 1
var _accum: float = 0.0
var _picked: int = -1
var _sel_land: int = -1
var _sel_sea: int = -1        # выбранная морская ячейка
var _port_tile: int = -1       # плитка порта, открытого в окне порта
var _sel_ship_id: int = -1
var _ship_cell: int = -1      # ячейка с выбранным своим кораблём (-1 = корабль не выбран)
var difficulty: int = 1       # сложность ботов 0..2


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
	units = UnitsView.new()
	units.z_index = 5
	add_child(units)
	units.setup(world, state)

	camera = CameraCtl.new()
	add_child(camera)
	camera.make_current()
	camera.fit_to(world.bounds())
	camera.tapped.connect(_on_tapped)

	hud = Hud.new()
	add_child(hud)
	hud.confirm_pressed.connect(_on_confirm)
	hud.port_panel.action.connect(_on_port_action)
	hud.menu_toggled.connect(_on_menu_toggled)
	hud.regen_pressed.connect(_on_regen)
	hud.speed_selected.connect(_on_speed)
	hud.action_pressed.connect(_on_action)
	hud.production_changed.connect(_on_production)
	hud.research_pressed.connect(_on_research)
	hud.restart_pressed.connect(_on_restart)

	sfx = Sfx.new()
	add_child(sfx)
	_load_settings()
	hud.set_settings(sound_on, volume)
	state.difficulty = difficulty
	hud.set_difficulty(difficulty)
	hud.difficulty_changed.connect(_on_difficulty)
	hud.continue_pressed.connect(_on_continue)
	hud.save_pressed.connect(_on_save_pressed)
	hud.sound_toggled.connect(_on_sound_toggled)
	hud.volume_changed.connect(_on_volume_changed)
	hud.set_continue_visible(SaveGame.exists())

	_show_info_empty()


func _process(delta: float) -> void:
	if not playing or over or speed <= 0:
		return
	var adt: float = delta * float(ANIM_FACTOR[speed])
	state.advance(adt)
	state.navy_advance(adt)
	map_view.sync_if_changed()
	if state.events.size() > 0 or state.map_dirty or state.sounds.size() > 0:
		_after_ticks()
	_accum += delta
	var step: float = DAY_SECONDS[speed]
	var guard := 0
	while _accum >= step and guard < 20:
		_accum -= step
		state.tick_day()
		guard += 1
	if guard > 0:
		_after_ticks()
	if state.game_over != 0:
		_finish()
	elif state.day - _last_save_day >= AUTOSAVE_DAYS:
		_save_now()


# ---------- события ----------

func _on_tapped(screen_pos: Vector2, world_pos: Vector2) -> void:
	if over or hud.is_over_ui(screen_pos):
		return
	if not world.bounds().has_point(world_pos):
		_clear_all()
		return

	var i := map_view.pick_land(world_pos)
	# выбран свой корабль: нажатие на берег = высадка (плыть к берегу и высадить дивизию)
	if i >= 0 and playing and _ship_cell >= 0:
		_ship_to_land(i)
		return
	# выбрана своя готовая дивизия: нажатие на другую плитку = приказ идти туда
	# (чужая страна, с которой нет войны, выбирается как обычно: чтобы можно было объявить войну)
	if i >= 0 and playing and _sel_land >= 0 and i != _sel_land and _has_ready_unit(_sel_land) and not _has_own_unit(i) and _can_order_to(i):
		_try_move(_sel_land, i)
		return
	if i >= 0 and i == _sel_land and playing and _has_ready_unit(i):
		_clear_all()   # повторное нажатие на выбранную дивизию снимает выбор
		return
	if i >= 0:
		_sel_land = i
		map_view.select_land(i)
		if not playing:
			_pick_on_tile(i)
		_show_land_info(i)
		return

	# нажали на воду: выбираем крупную морскую ячейку
	_sel_land = -1
	hud.set_actions([])
	if not playing:
		_picked = -1
		hud.hide_pick()
	var j := world.sea_grid.tile_at(world_pos)
	if j >= 0 and world.sea_navigable[j] == 1:
		# выбран свой корабль: нажатие на другую морскую ячейку = плыть туда
		if playing and _ship_cell >= 0 and j != _ship_cell:
			_ship_to_sea(j)
			return
		_sel_sea = j
		_ship_cell = -1
		_sel_ship_id = -1
		if playing and not _own_ship_at(j).is_empty():
			_ship_cell = j
		map_view.select_sea(j)
		_show_sea_info(j)
	else:
		_ship_cell = -1
		_sel_sea = -1
		map_view.clear_selection()
		_show_info_empty()


func _clear_all() -> void:
	_sel_land = -1
	_sel_sea = -1
	_ship_cell = -1
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
	state.mil_share[_picked] = GameState.DEFAULT_MIL_SHARE
	state.setup_bots()
	state.ensure_start_money(_picked)
	playing = true
	speed = 1
	_accum = 0.0
	map_view.set_player(_picked)
	units.set_player(_picked)
	hud.enter_play()
	hud.set_speed_mark(speed)
	_refresh_hud()
	if _sel_land >= 0:
		_show_land_info(_sel_land)


func _on_action(id: String) -> void:
	if playing and id.begins_with("bomb_"):
		var ship := _selected_ship()
		var tt := int(id.substr(5))
		if state.navy_bombard(state.player, ship, tt):
			hud.show_event("Обстрел начат")
		else:
			hud.show_event(state.navy_bombard_reason(state.player, ship, tt))
		units.refresh()
		hud.set_actions([])
		return
	if not playing or _sel_land < 0:
		return
	sfx.play("click")
	var cid := state.player
	var t := _sel_land
	if id == "build":
		if state.start_build(cid, t):
			hud.show_event("Начато строительство завода: %d дн." % GameState.BUILD_DAYS)
			map_view.set_construction(state.construction_tiles(cid))
	elif id == "recruit":
		if state.recruit(cid, t):
			hud.show_event("Нанята дивизия")
			units.refresh()
	elif id == "disband":
		if state.disband(cid, t):
			hud.show_event("Дивизия распущена")
			units.refresh()
	elif id == "port":
		if state.navy_start_port(cid, t):
			hud.show_event("Начато строительство порта: %d дн." % Navy.PORT_DAYS)
			map_view.set_construction(state.construction_tiles(cid))
	elif id == "open_port":
		_open_port(t)
		return
	elif id == "stop":
		state.stop_marching(cid, t)
		hud.show_event("Поход остановлен")
		units.refresh()
	elif id == "war":
		var o: int = world.tile_owner[t]
		if o >= 0:
			var cn: Dictionary = world.countries[o]
			if state.declare_war(cid, o):
				hud.show_event("Война объявлена: %s" % cn["name"])
			else:
				hud.show_event("Нельзя: недавно заключён мир")
	elif id == "peace":
		var o2: int = world.tile_owner[t]
		if o2 >= 0:
			var res: Dictionary = state.propose_peace(cid, o2)
			hud.show_event(res["msg"])
	_refresh_hud()
	_show_land_info(t)


## Своя дивизия на плитке готова к приказу (стоит и отдохнула).
func _has_ready_unit(t: int) -> bool:
	var u: Dictionary = state.unit_at(t)
	return not u.is_empty() and int(u["owner"]) == state.player and int(u["state"]) == GameState.ST_IDLE and int(u["recover"]) <= 0


## Свой корабль в ячейке j (стоящий, не в пути).
## Корабль, которым сейчас управляет игрок (по номеру, иначе первый в выбранной ячейке).
func _selected_ship() -> Dictionary:
	if _sel_ship_id > 0:
		var sh := state.navy_ship_by_id(_sel_ship_id)
		if not sh.is_empty() and int(sh["cell"]) == _ship_cell and int(sh["state"]) == 0 and int(sh["owner"]) == state.player:
			return sh
	return _own_ship_at(_ship_cell)


func _open_port(t: int) -> void:
	_port_tile = t
	hud.open_menu(5)


func _close_port() -> void:
	hud.close_menus()


func _on_menu_toggled(index: int, on: bool) -> void:
	if index == 5 and on and playing:
		hud.port_panel.rebuild(state, state.player, _port_tile)


func _on_port_action(kind: String, ship_id: int, tile: int) -> void:
	sfx.play("click")
	var cid := state.player
	var ship := state.navy_ship_by_id(ship_id)
	if kind == "select":
		_port_tile = tile
		hud.port_panel.rebuild(state, cid, _port_tile)
		return
	if kind.begins_with("buy_"):
		var ty := int(kind.substr(4))
		_port_tile = tile
		if state.navy_build_ship(cid, _port_tile, ty):
			hud.show_event("Корабль куплен: %s" % state.navy_type_name(ty).to_lower())
			sfx.play("build")
		else:
			hud.show_event(state.navy_ship_block_reason(cid, _port_tile, ty))
	elif kind == "load":
		if state.navy_load_unit(cid, tile, ship):
			hud.show_event("Дивизия погружена")
		else:
			hud.show_event("Погрузка не удалась")
	elif kind == "unload":
		if state.navy_unload_unit(cid, ship):
			hud.show_event("Дивизия выгружена")
		else:
			hud.show_event("Нет свободной плитки для выгрузки")
	elif kind == "bomb":
		if state.navy_bombard(cid, ship, tile):
			hud.show_event("Обстрел начат")
		else:
			hud.show_event(state.navy_bombard_reason(cid, ship, tile))
	elif kind == "sail":
		if ship.is_empty():
			return
		_sel_ship_id = ship_id
		_ship_cell = int(ship["cell"])
		_close_port()
		hud.show_event("Корабль выбран: нажмите на море — плыть, на прибрежную плитку без войск — высадка")
		return
	units.refresh()
	_refresh_hud()
	hud.port_panel.rebuild(state, cid, _port_tile)
	if _sel_land >= 0:
		_show_land_info(_sel_land)


func _own_ship_at(j: int) -> Dictionary:
	for sh in state.ships:
		var d: Dictionary = sh
		if int(d["owner"]) == state.player and int(d["cell"]) == j and int(d["state"]) == 0:
			return d
	return {}


func _ship_to_sea(j: int) -> void:
	var ship := _selected_ship()
	var res: Dictionary = state.navy_order_ship(state.player, ship, j, -1)
	hud.show_event(res["msg"])
	if res["ok"]:
		sfx.play("click")
		_ship_cell = -1
	units.refresh()
	_refresh_hud()


func _ship_to_land(i: int) -> void:
	var ship := _selected_ship()
	var cell: int = world.tile_sea[i]
	if ship.is_empty() or cell < 0:
		hud.show_event("Сюда не причалить")
		return
	var res: Dictionary = state.navy_order_ship(state.player, ship, cell, i)
	hud.show_event(res["msg"])
	if res["ok"]:
		sfx.play("click")
		_ship_cell = -1
		map_view.clear_selection()
	units.refresh()
	_refresh_hud()


func _has_own_unit(t: int) -> bool:
	var u: Dictionary = state.unit_at(t)
	return not u.is_empty() and int(u["owner"]) == state.player


func _can_order_to(i: int) -> bool:
	var o: int = world.tile_owner[i]
	return o == state.player or (o >= 0 and state.is_at_war(state.player, o))


func _try_move(from: int, to: int) -> void:
	var res: Dictionary = state.order_move(state.player, from, to)
	hud.show_event(res["msg"])
	if res["ok"]:
		sfx.play("click")
	units.refresh()
	_refresh_hud()
	if res["ok"]:
		# приказ отдан: показываем плитку, на которую нажали (а не прежнюю)
		_sel_land = to
		map_view.select_land(to)
		_show_land_info(to)
	else:
		_show_land_info(from)


## После дневных тиков: сообщения, изменения карты, интерфейс.
func _after_ticks() -> void:
	for snd in state.sounds:
		sfx.play(str(snd))
	state.sounds = []
	if state.events.size() > 0:
		hud.show_event("\n".join(state.events))
		state.events = []
	if state.map_dirty:
		state.map_dirty = false
		map_view.set_construction(state.construction_tiles(state.player))
		map_view.refresh()
		if _sel_land >= 0:
			_show_land_info(_sel_land)
	units.refresh()
	_refresh_hud()


func _save_now() -> void:
	if playing and not over and state.player >= 0:
		if SaveGame.save(world, state, seed_value):
			_last_save_day = state.day


func _on_save_pressed() -> void:
	_save_now()
	hud.show_event("Игра сохранена")


## «Продолжить игру»: карта по сохранённому seed + сохранённое состояние.
func _on_continue() -> void:
	var sd := SaveGame.read_seed()
	if sd < 0:
		hud.show_event("Сохранение не найдено")
		hud.set_continue_visible(false)
		return
	seed_value = sd
	WorldGen.assign_countries(world, seed_value)
	if not SaveGame.load_into(world, state):
		hud.show_event("Не удалось загрузить сохранение")
		return
	over = false
	playing = true
	speed = 1
	_accum = 0.0
	_last_save_day = state.day
	state.difficulty = difficulty
	state.setup_bots()
	_picked = -1
	_sel_land = -1
	map_view.set_player(state.player)
	units.set_player(state.player)
	map_view.set_construction(state.construction_tiles(state.player))
	map_view.clear_selection()
	map_view.refresh()
	units.refresh()
	hud.enter_play()
	hud.set_speed_mark(speed)
	_refresh_hud()
	_show_info_empty()


func _notification(what: int) -> void:
	# приложение свернули или закрывают: сохраняем партию
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_now()


func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) == OK:
		sound_on = bool(cf.get_value("sound", "on", true))
		volume = float(cf.get_value("sound", "volume", 0.7))
		difficulty = clampi(int(cf.get_value("game", "difficulty", 1)), 0, 2)
	sfx.enabled = sound_on
	sfx.volume = volume


func _store_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("sound", "on", sound_on)
	cf.set_value("sound", "volume", volume)
	cf.set_value("game", "difficulty", difficulty)
	cf.save(SETTINGS_PATH)


func _on_difficulty(level: int) -> void:
	difficulty = level
	state.difficulty = level
	if playing:
		state.setup_bots()
	_store_settings()
	hud.show_event("Сложность ботов изменена")


func _on_sound_toggled(on: bool) -> void:
	sound_on = on
	sfx.enabled = on
	_store_settings()


func _on_volume_changed(v: float) -> void:
	volume = v
	sfx.volume = v
	_store_settings()
	sfx.play("click")


func _on_production(percent: int) -> void:
	if playing and state.player >= 0:
		state.mil_share[state.player] = float(percent) / 100.0
		_refresh_hud()


func _on_research(branch: int) -> void:
	if not playing or state.player < 0:
		return
	if state.start_research(state.player, branch):
		var nm: String = GameState.TECH_NAMES[branch]
		hud.show_event("Начато исследование: %s" % nm)
	_refresh_hud()


## Игра закончена: победа или поражение.
func _finish() -> void:
	if over:
		return
	over = true
	SaveGame.delete()
	if state.game_over == 1:
		sfx.play("win")
		hud.show_result("ПОБЕДА", "Вы присоединили все страны мира.")
	else:
		sfx.play("lose")
		hud.show_result("ПОРАЖЕНИЕ", "Ваша столица захвачена, страна присоединена к победителю.")


## «Новая игра»: новая карта и снова выбор страны.
func _on_restart() -> void:
	over = false
	playing = false
	SaveGame.delete()
	seed_value += 1
	WorldGen.assign_countries(world, seed_value)
	state.reset()
	_picked = -1
	_sel_land = -1
	_sel_sea = -1
	_ship_cell = -1
	map_view.set_player(-1)
	units.set_player(-1)
	map_view.clear_selection()
	map_view.set_construction([])
	map_view.refresh()
	units.refresh()
	hud.enter_pick()
	hud.set_continue_visible(false)
	_show_info_empty()


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
	units.refresh()
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
	hud.set_countries_text(_countries_text())
	_refresh_production(cid)
	_refresh_research(cid)


func _balance_text(cid: int) -> String:
	var b: Dictionary = state.budget(cid)
	var army_n: int = state.army[cid]
	var cn: Dictionary = world.countries[cid]
	var lines: Array[String] = ["Казна: %s" % GameState.fmt(float(state.money[cid])), "Население: %s" % GameState.fmt(float(state.population[cid])), "Баланс за день"]
	lines.append("+ Налоги: %s" % GameState.fmt(b["tax"]))
	lines.append("+ Заводы (%d): %s" % [cn["factories"], GameState.fmt(b["industry"])])
	lines.append("- Заводы, содержание: %s" % GameState.fmt(b["upkeep_factories"]))
	lines.append("- Города (%d): %s" % [cn["cities"], GameState.fmt(b["upkeep_cities"])])
	lines.append("- Армия (%d див.): %s" % [army_n, GameState.fmt(b["upkeep_army"])])
	if float(b["upkeep_ships"]) > 0.0:
		lines.append("- Флот (%d): %s" % [state.ship_count(cid), GameState.fmt(b["upkeep_ships"])])
	lines.append("ИТОГО: %s/день" % GameState.fmt_signed(b["net"]))
	var nb := state.construction_tiles(cid).size()
	if nb > 0:
		lines.append("Строек: %d" % nb)
	return "\n".join(lines)


func _refresh_production(cid: int) -> void:
	var m: float = state.mil_share[cid]
	var pct := int(round(m * 100.0))
	var text := "На армию: %d%% · на товары: %d%%\nСнаряжение: %s (+%s/день)\nНа дивизию нужно %d, нанять можно %d" % [
		pct, 100 - pct, GameState.fmt(float(state.equipment[cid])),
		"%.1f" % state.equip_per_day(cid), int(GameState.EQUIP_PER_DIVISION),
		int(float(state.equipment[cid]) / GameState.EQUIP_PER_DIVISION)]
	hud.set_production(pct, text)


func _refresh_research(cid: int) -> void:
	var cur: Dictionary = state.research[cid]
	var status := "Исследований нет"
	if not cur.is_empty():
		var br: int = cur["branch"]
		status = "Идёт: %s, ещё %d дн." % [GameState.TECH_NAMES[br], int(cur["days_left"])]
	var list: Array = []
	for b in 3:
		var lvl := state.tech_level(cid, b)
		var nm: String = GameState.TECH_NAMES[b]
		var eff: String = GameState.TECH_EFFECT[b]
		var bonus := int(round(float(GameState.TECH_BONUS[b]) * 100.0 * float(lvl)))
		if lvl >= GameState.TECH_MAX:
			list.append({"text": "%s %d (макс.): %s +%d%%" % [nm, lvl, eff, bonus], "enabled": false})
		else:
			var reason := state.research_block_reason(cid, b)
			var t := "%s %d → %d: %s (%s)" % [nm, lvl, lvl + 1, eff, GameState.fmt(state.tech_cost(lvl))]
			if reason == "Не хватает денег":
				t += " — нет денег"
			list.append({"text": t, "enabled": reason == ""})
	hud.set_research(status, list)


func _countries_text() -> String:
	var ids: Array = []
	for c in world.countries.size():
		if int(world.countries[c]["tiles"]) > 0:
			ids.append(c)
	ids.sort_custom(func(a: int, b: int) -> bool: return int(world.countries[a]["tiles"]) > int(world.countries[b]["tiles"]))
	var lines: Array[String] = []
	for c in ids:
		var ci: int = c
		var cn: Dictionary = world.countries[ci]
		var tag := ""
		if ci == state.player:
			tag = " (вы)"
		elif state.is_at_war(state.player, ci):
			tag = " [ВОЙНА]"
		lines.append("%s%s: %d пл., %d див., %d зав.%s" % [cn["name"], tag, cn["tiles"], state.army[ci], cn["factories"], ""])
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
	if world.tile_port[t] == 1:
		lines.append("Есть порт")
	lines.append("Плитка: %d, %d" % [world.col_of(t), world.row_of(t)])
	if playing and state.army_on(t) > 0:
		var u: Dictionary = state.unit_at(t)
		var info := "Дивизия: сила %d%%" % int(round(float(u["hp"])))
		if int(u["recover"]) > 0:
			info += ", отдыхает %d дн." % int(u["recover"])
		elif int(u["state"]) != GameState.ST_IDLE:
			info += ", в походе"
		elif int(u["owner"]) == state.player:
			info += "\nНажмите на плитку, чтобы отправить дивизию"
		lines.append(info)
	if playing and cid >= 0 and cid != state.player and state.is_at_war(state.player, cid):
		lines.append("С этой страной война")
	if playing and state.is_building(t):
		lines.append("Строится завод: ещё %d дн." % state.build_days_left(t))
	hud.set_info("\n".join(lines))
	_update_actions(t)


func _update_actions(t: int) -> void:
	var o: int = world.tile_owner[t]
	if not playing or o < 0:
		hud.set_actions([])
		return
	var cid := state.player
	var list: Array = []
	if o != cid:
		var cn: Dictionary = world.countries[o]
		if state.is_at_war(cid, o):
			list.append({"id": "peace", "text": "Предложить мир: %s" % cn["name"], "enabled": true})
		elif state.can_declare(cid, o):
			list.append({"id": "war", "text": "Объявить войну: %s" % cn["name"], "enabled": true})
		else:
			list.append({"id": "none", "text": "Перемирие с %s" % cn["name"], "enabled": false})
		hud.set_actions(list)
		return
	var reason := state.build_block_reason(cid, t)
	var label := "Построить завод (%s)" % GameState.fmt(state.build_cost(t))
	if reason == "":
		list.append({"id": "build", "text": label, "enabled": true})
	elif reason == "Не хватает денег":
		list.append({"id": "build", "text": label + " — нет денег", "enabled": false})
	else:
		list.append({"id": "build", "text": reason, "enabled": false})
	if world.tile_city[t] != 0:
		var r2 := state.recruit_block_reason(cid, t)
		var l2 := "Нанять дивизию (%s)" % GameState.fmt(GameState.RECRUIT_COST)
		if r2 == "Не хватает денег":
			l2 += " — нет денег"
		elif r2 == "Не хватает снаряжения":
			l2 += " — нет снаряжения"
		list.append({"id": "recruit", "text": l2, "enabled": r2 == ""})
	if world.tile_city[t] != 0 and world.tile_sea[t] >= 0:
		if world.tile_port[t] == 0:
			var rp := state.navy_port_block_reason(cid, t)
			var lp := "Построить порт (%s)" % GameState.fmt(Navy.PORT_COST)
			if rp == "Не хватает денег":
				lp += " — нет денег"
			list.append({"id": "port", "text": lp, "enabled": rp == ""})
		else:
			list.append({"id": "open_port", "text": "Порт: корабли и погрузка", "enabled": true})
	var u := state.unit_at(t)
	if not u.is_empty():
		if int(u["state"]) == GameState.ST_IDLE and int(u["recover"]) <= 0:
			list.append({"id": "disband", "text": "Распустить дивизию", "enabled": true})
		elif int(u["state"]) != GameState.ST_IDLE:
			list.append({"id": "stop", "text": "Остановить поход", "enabled": true})
		else:
			list.append({"id": "none", "text": "Дивизия отдыхает после боя", "enabled": false})
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
	if playing and not _own_ship_at(j).is_empty():
		var sh: Dictionary = _own_ship_at(j)
		if int(sh["type"]) == 0:
			if Dictionary(sh["cargo"]).is_empty():
				lines.append("Ваш десантный корабль (пустой)")
			else:
				lines.append("Ваш десантный корабль с дивизией")
		if int(sh["type"]) == 1:
			lines.append("Боевой корабль. Нажмите на море — плыть")
			var acts: Array = []
			for tg in state.navy_bombard_targets(state.player, sh):
				acts.append({"id": "bomb_%d" % int(tg), "text": "Обстрелять вражескую дивизию", "enabled": true})
			hud.set_actions(acts)
		else:
			lines.append("Нажмите на море — плыть, на любую прибрежную плитку — высадка")
	hud.set_info("\n".join(lines))
