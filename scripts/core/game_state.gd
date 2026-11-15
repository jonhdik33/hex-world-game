extends RefCounted
## Состояние игры: время, казна, население, армия и стройки. Чистая логика, без экрана.
##
## Экономика страны за день:
##   доходы  = налоги (население) + доход заводов
##   расходы = содержание заводов + содержание городов + содержание армии (дивизии)
##   итого   = доходы - расходы
## Стройка: завод в городе или на обычной плитке (там появится новый город), платится сразу,
## достраивается через BUILD_DAYS дней. Боты пока ничего не строят (модуль 5).

const World = preload("res://scripts/core/world.gd")
const BotAI = preload("res://scripts/core/bot_ai.gd")

const DAYS_PER_YEAR := 360
const POP_PER_TILE := 30000.0         # людей на плитку при старте
const POP_GROWTH_PER_DAY := 0.0001    # рост населения в день (≈3.7% в год)
const TAX_PER_PERSON := 0.0008        # налог с одного человека в день
const INCOME_PER_FACTORY := 120.0     # доход с одного завода в день
const START_MONEY_DAYS := 30.0        # стартовая казна = столько дней чистой прибыли

# расходы (в день)
const FACTORY_UPKEEP := 30.0          # содержание одного завода
const CITY_UPKEEP := 20.0             # содержание одного города
const DIVISION_UPKEEP := 50.0         # содержание одной дивизии
const ARMY_TILES_PER_DIVISION := 8.0  # стартовая армия: 1 дивизия на столько плиток

# армия
const RECRUIT_COST := 1500.0          # найм одной дивизии (в городе, сразу)
const STEP_SECONDS := 2.0             # шаг на соседнюю плитку (реальных секунд при x1)
const BATTLE_SECONDS := 1.5           # длительность анимации боя
const RECOVER_DAYS := 3               # дней отдыха после боя
const ST_IDLE := 0
const ST_MOVE := 1
const ST_FIGHT := 2
const MAX_HP := 100.0               # полная сила дивизии
const HEAL_PER_DAY := 5.0            # лечение в день
const DEFENSE_BONUS := 1.15          # защитник на своей земле сильнее
const WAIT_REROUTE := 3.0            # через сколько секунд ожидания искать обход
const BOT_PERIOD := 3                # раз в сколько дней думает бот

# стройка
const FACTORY_COST := 4000.0          # цена первого достраиваемого завода (в городе с 1 заводом)
const FACTORY_STEP := 1500.0          # каждый следующий завод в том же городе дороже на столько
const NEW_CITY_EXTRA := 2000.0        # доплата, если строим на обычной плитке (появится город)
const BUILD_DAYS := 10                # сколько дней строится

var world: World
var day: int = 0              # дней с начала игры
var player: int = -1          # id страны игрока, -1 = ещё не выбрана
var money: Array = []         # казна каждой страны (float)
var population: Array = []    # население каждой страны (float)
var army: Array = []          # дивизий у каждой страны (int), всегда = сумма по плиткам
var tile_army := PackedInt32Array()   # 1 = на плитке стоит дивизия
var squads: Array = []        # все дивизии (см. раздел «армия»)
var unit_on: Dictionary = {}  # плитка -> дивизия
var rng := RandomNumberGenerator.new()
var bot_aggr: Array = []      # агрессивность бота 0..1
var at_war: Dictionary = {}   # пары стран в состоянии войны: min*1000+max
var _next_id: int = 1
var build_queue: Array = []   # стройки: [{cid, tile, days_left, new_city}]
var events: Array = []        # сообщения для игрока (забирает main и очищает)
var map_dirty: bool = false   # true, если карта изменилась (достроен завод/город)


func _init(w: World) -> void:
	world = w
	reset()


func reset() -> void:
	day = 0
	player = -1
	money = []
	population = []
	army = []
	build_queue = []
	events = []
	map_dirty = false
	for cid in world.countries.size():
		var cn: Dictionary = world.countries[cid]
		population.append(float(cn["tiles"]) * POP_PER_TILE)
		army.append(maxi(1, int(round(float(cn["tiles"]) / ARMY_TILES_PER_DIVISION))))
		money.append(0.0)
	for cid in world.countries.size():
		money[cid] = maxf(0.0, daily_net(cid)) * START_MONEY_DAYS
	rng.seed = 424242
	bot_aggr = []
	for c in world.countries.size():
		bot_aggr.append(rng.randf_range(0.2, 1.0))
	_place_armies()


# ---------- экономика ----------

## Все статьи дневного бюджета страны.
func budget(cid: int) -> Dictionary:
	var cn: Dictionary = world.countries[cid]
	var tax := float(population[cid]) * TAX_PER_PERSON
	var industry := float(cn["factories"]) * INCOME_PER_FACTORY
	var up_f := float(cn["factories"]) * FACTORY_UPKEEP
	var up_c := float(cn["cities"]) * CITY_UPKEEP
	var up_a := float(army[cid]) * DIVISION_UPKEEP
	var income := tax + industry
	var expenses := up_f + up_c + up_a
	return {
		"tax": tax,
		"industry": industry,
		"upkeep_factories": up_f,
		"upkeep_cities": up_c,
		"upkeep_army": up_a,
		"income": income,
		"expenses": expenses,
		"net": income - expenses,
	}


func daily_net(cid: int) -> float:
	var b: Dictionary = budget(cid)
	return float(b["net"])


func tick_day() -> void:
	for cid in world.countries.size():
		money[cid] = float(money[cid]) + daily_net(cid)
		population[cid] = float(population[cid]) * (1.0 + POP_GROWTH_PER_DAY)
		# нет денег — распускаем по одной дивизии в день, пока казна не выйдет из минуса
		if float(money[cid]) < 0.0 and int(army[cid]) > 0:
			_remove_one_division(cid)
			if cid == player:
				events.append("Нет денег: распущена одна дивизия")
	for sq in squads:
		var e: Dictionary = sq
		if int(e["recover"]) > 0:
			e["recover"] = int(e["recover"]) - 1
		e["hp"] = minf(MAX_HP, float(e["hp"]) + HEAL_PER_DAY)
	_progress_builds()
	for cid in world.countries.size():
		if cid != player and (day + cid) % BOT_PERIOD == 0:
			BotAI.think(self, cid, float(bot_aggr[cid]))
	day += 1


# ---------- армия ----------
## Одна плитка = максимум одна дивизия. Дивизия (словарь): id, owner, tile, from, hp, path (плитки впереди),
## dest (цель похода), p (прогресс шага 0..1), crossed (граница пройдена, для захвата), state,
## recover (дней отдыха), fight_t, wait_t.
## Шаг на соседнюю плитку = STEP_SECONDS: стрелка тянется от центра плитки к центру следующей, а дивизия
## появляется на новой плитке, когда стрелка дошла (p = 1). Если там враг (война) — на середине (p = 0.5)
## бой BATTLE_SECONDS: проигравший уничтожен, победитель ранен, отдыхает RECOVER_DAYS и идёт дальше.

func _place_armies() -> void:
	squads = []
	unit_on = {}
	_next_id = 1
	at_war = {}
	var by_country: Array = []
	for c in world.countries.size():
		by_country.append([])
	for i in world.tile_total():
		if world.land[i] == 1 and world.tile_owner[i] >= 0:
			by_country[world.tile_owner[i]].append(i)
	for cid in world.countries.size():
		var tiles: Array = by_country[cid]
		var n: int = mini(int(army[cid]), tiles.size())
		if tiles.is_empty() or n <= 0:
			continue
		var cn: Dictionary = world.countries[cid]
		var cap: int = cn["capital"]
		_add_unit(cid, cap)
		var step := maxi(1, int(float(tiles.size()) / float(maxi(1, n))))
		var idx := step
		var placed := 1
		var guard := 0
		while placed < n and guard < tiles.size() * 2:
			var t: int = tiles[idx % tiles.size()]
			idx += 1
			guard += 1
			if unit_on.has(t):
				continue
			_add_unit(cid, t)
			placed += 1
			idx += step - 1
	_rebuild()


func _add_unit(cid: int, t: int) -> Dictionary:
	var e := {
		"id": _next_id, "owner": cid, "tile": t, "from": t, "hp": MAX_HP, "path": [], "dest": -1,
		"p": 0.0, "crossed": false, "state": ST_IDLE, "recover": 0, "fight_t": 0.0, "wait_t": 0.0,
	}
	_next_id += 1
	squads.append(e)
	unit_on[t] = e
	return e


## Пересчёт занятых плиток и числа дивизий по странам.
func _rebuild() -> void:
	tile_army = PackedInt32Array()
	tile_army.resize(world.tile_total())
	tile_army.fill(0)
	unit_on = {}
	for c in army.size():
		army[c] = 0
	for sq in squads:
		var e: Dictionary = sq
		tile_army[int(e["tile"])] = 1
		unit_on[int(e["tile"])] = e
		army[int(e["owner"])] = int(army[int(e["owner"])]) + 1


func army_on(t: int) -> int:
	return tile_army[t]


## Дивизия на плитке (пустой словарь, если нет).
func unit_at(t: int) -> Dictionary:
	if unit_on.has(t):
		var e: Dictionary = unit_on[t]
		return e
	return {}


func division_upkeep() -> float:
	return DIVISION_UPKEEP


func _remove_unit(e: Dictionary) -> void:
	squads.erase(e)
	if unit_on.has(int(e["tile"])):
		var cur: Dictionary = unit_on[int(e["tile"])]
		if int(cur["id"]) == int(e["id"]):
			unit_on.erase(int(e["tile"]))
	tile_army[int(e["tile"])] = 0
	army[int(e["owner"])] = maxi(0, int(army[int(e["owner"])]) - 1)


func _remove_one_division(cid: int) -> void:
	var worst: Dictionary = {}
	for sq in squads:
		var e: Dictionary = sq
		if int(e["owner"]) != cid:
			continue
		if worst.is_empty() or float(e["hp"]) < float(worst["hp"]):
			worst = e
	if not worst.is_empty():
		_remove_unit(worst)


func recruit_block_reason(cid: int, t: int) -> String:
	if t < 0 or world.land[t] == 0 or world.tile_owner[t] != cid:
		return "Не ваша территория"
	if world.tile_city[t] == 0:
		return "Нанимать можно только в городе"
	if unit_on.has(t):
		return "Клетка занята дивизией"
	if float(money[cid]) < RECRUIT_COST:
		return "Не хватает денег"
	return ""


func recruit(cid: int, t: int) -> bool:
	if recruit_block_reason(cid, t) != "":
		return false
	money[cid] = float(money[cid]) - RECRUIT_COST
	_add_unit(cid, t)
	_rebuild()
	return true


func disband(cid: int, t: int) -> bool:
	var e := unit_at(t)
	if e.is_empty() or int(e["owner"]) != cid or int(e["state"]) != ST_IDLE:
		return false
	_remove_unit(e)
	return true


func is_adjacent(a: int, b: int) -> bool:
	for k in 6:
		if world.neighbor(a, k) == b:
			return true
	return false


# ---------- война ----------

func is_at_war(a: int, b: int) -> bool:
	return at_war.has(mini(a, b) * 1000 + maxi(a, b))


func declare_war(a: int, b: int) -> void:
	if a != b and a >= 0 and b >= 0:
		at_war[mini(a, b) * 1000 + maxi(a, b)] = true


## Можно ли дивизии страны cid войти на плитку t: своя или страна, с которой война.
func can_enter(cid: int, t: int) -> bool:
	if t < 0 or world.land[t] == 0:
		return false
	var o: int = world.tile_owner[t]
	return o == cid or (o >= 0 and is_at_war(cid, o))


## Кратчайший маршрут (плитки без стартовой); пусто = пути нет. Свои дивизии на пути обходятся.
func find_path(cid: int, from: int, to: int) -> Array:
	if from == to or not can_enter(cid, to):
		return []
	var prev := {}
	prev[from] = -1
	var queue: Array = [from]
	var qi := 0
	while qi < queue.size():
		var cur: int = queue[qi]
		qi += 1
		if cur == to:
			break
		for k in 6:
			var nb := world.neighbor(cur, k)
			if nb < 0 or prev.has(nb) or not can_enter(cid, nb):
				continue
			if unit_on.has(nb) and world.tile_owner[nb] == cid:
				continue   # своя дивизия занимает плитку: обходим
			prev[nb] = cur
			queue.append(nb)
	if not prev.has(to):
		return []
	var path: Array = []
	var c := to
	while c != from:
		path.push_front(c)
		c = int(prev[c])
	return path


## Приказ дивизии на плитке from идти на плитку to. {"ok": bool, "msg": String}
func order_move(cid: int, from: int, to: int) -> Dictionary:
	if to < 0 or world.land[to] == 0:
		return {"ok": false, "msg": "Туда нельзя"}
	var owner_to: int = world.tile_owner[to]
	if owner_to != cid and not is_at_war(cid, owner_to):
		return {"ok": false, "msg": "Нужна война: нажмите на чужую плитку и «Объявить войну»"}
	if from == to:
		return {"ok": false, "msg": "Это та же плитка"}
	var e := unit_at(from)
	if e.is_empty() or int(e["owner"]) != cid:
		return {"ok": false, "msg": "Тут нет вашей дивизии"}
	if int(e["state"]) != ST_IDLE or int(e["recover"]) > 0:
		return {"ok": false, "msg": "Дивизия отдыхает или уже в походе"}
	if owner_to == cid and unit_on.has(to):
		return {"ok": false, "msg": "Эта плитка занята вашей дивизией"}
	var path := find_path(cid, from, to)
	if path.is_empty():
		return {"ok": false, "msg": "Пути нет"}
	e["path"] = path
	e["dest"] = to
	e["state"] = ST_MOVE
	e["p"] = 0.0
	e["crossed"] = false
	e["wait_t"] = 0.0
	return {"ok": true, "msg": "Дивизия выступила, путь: %d плиток" % path.size()}


## Остановить поход дивизии на плитке (если граница уже пройдена — дойдёт до конца шага).
func stop_marching(cid: int, t: int) -> void:
	var e := unit_at(t)
	if e.is_empty() or int(e["owner"]) != cid or int(e["state"]) != ST_MOVE:
		return
	var path: Array = e["path"]
	if bool(e["crossed"]) and not path.is_empty():
		e["path"] = [path[0]]
		e["dest"] = path[0]
		return
	e["path"] = []
	e["dest"] = -1
	e["state"] = ST_IDLE
	e["p"] = 0.0


func _stop(e: Dictionary) -> void:
	e["path"] = []
	e["dest"] = -1
	e["state"] = ST_IDLE
	e["p"] = 0.0
	e["crossed"] = false
	e["wait_t"] = 0.0


## Время идёт: dt — игровые секунды (реальные секунды × скорость).
func advance(dt: float) -> void:
	if squads.is_empty() or dt <= 0.0:
		return
	for sq in squads.duplicate():
		var e: Dictionary = sq
		var st: int = e["state"]
		if st == ST_IDLE or int(e["recover"]) > 0:
			continue
		if st == ST_FIGHT:
			e["fight_t"] = float(e["fight_t"]) + dt
			if float(e["fight_t"]) >= BATTLE_SECONDS:
				_resolve_battle(e)
			continue
		_advance_move(e, dt)


func _advance_move(e: Dictionary, dt: float) -> void:
	var path: Array = e["path"]
	if path.is_empty():
		_stop(e)
		return
	var cid: int = e["owner"]
	var nxt: int = path[0]
	if not can_enter(cid, nxt):
		_stop(e)
		return
	var hostile: bool = world.tile_owner[nxt] != cid and not bool(e["crossed"])
	var p: float = float(e["p"]) + dt / STEP_SECONDS
	if hostile and p >= 0.5:
		e["p"] = 0.5
		if unit_on.has(nxt):
			e["state"] = ST_FIGHT
			e["fight_t"] = 0.0
		else:
			_capture(cid, world.tile_owner[nxt], nxt)
			e["crossed"] = true
		return
	e["p"] = minf(p, 1.0)
	if p < 1.0:
		return
	# стрелка дошла до центра следующей плитки: дивизия переходит на неё
	if unit_on.has(nxt):
		# занято своей дивизией: ждём, потом ищем обход
		e["wait_t"] = float(e["wait_t"]) + dt
		if float(e["wait_t"]) > WAIT_REROUTE:
			e["wait_t"] = 0.0
			_reroute(e)
		return
	unit_on.erase(int(e["tile"]))
	tile_army[int(e["tile"])] = 0
	e["tile"] = nxt
	e["from"] = nxt
	unit_on[nxt] = e
	tile_army[nxt] = 1
	path.pop_front()
	e["path"] = path
	e["p"] = 0.0
	e["crossed"] = false
	e["wait_t"] = 0.0
	if path.is_empty():
		_stop(e)


func _reroute(e: Dictionary) -> void:
	var dest: int = e["dest"]
	var np := find_path(int(e["owner"]), int(e["tile"]), dest)
	if np.is_empty() or unit_on.has(dest):
		_stop(e)
		return
	e["path"] = np
	e["p"] = 0.0
	e["crossed"] = false


func _resolve_battle(e: Dictionary) -> void:
	var path: Array = e["path"]
	var target: int = path[0]
	var att: int = e["owner"]
	var def: int = world.tile_owner[target]
	var d := unit_at(target)
	e["state"] = ST_MOVE
	if d.is_empty():
		_capture(att, def, target)
		e["crossed"] = true
		return
	var a_pow := float(e["hp"]) * rng.randf_range(0.8, 1.2)
	var d_pow := float(d["hp"]) * rng.randf_range(0.8, 1.2) * DEFENSE_BONUS
	if a_pow > d_pow:
		# победа: защитник уничтожен, победитель ранен и отдыхает, плитка захвачена
		_remove_unit(d)
		e["hp"] = maxf(10.0, float(e["hp"]) - float(d["hp"]) * 0.35)
		e["recover"] = RECOVER_DAYS
		e["crossed"] = true
		_capture(att, def, target)
		_note(att, def, "Плитка захвачена")
	else:
		# поражение (при равенстве выигрывает защитник): атакующий уничтожен
		d["hp"] = maxf(10.0, float(d["hp"]) - float(e["hp"]) * 0.35)
		d["recover"] = RECOVER_DAYS
		_remove_unit(e)
		_note(att, def, "Атака отбита")


func _note(att: int, def: int, text: String) -> void:
	if att == player or def == player:
		var a: Dictionary = world.countries[att]
		var b: Dictionary = world.countries[def]
		events.append("%s: %s против %s" % [text, a["name"], b["name"]])


func _capture(att: int, def: int, t: int) -> void:
	var da: Dictionary = world.countries[att]
	var dd: Dictionary = world.countries[def]
	# население переходит вместе с плиткой
	var tiles_def := maxi(1, int(dd["tiles"]))
	var pop_move := float(population[def]) / float(tiles_def)
	population[def] = maxf(0.0, float(population[def]) - pop_move)
	population[att] = float(population[att]) + pop_move
	world.tile_owner[t] = att
	dd["tiles"] = int(dd["tiles"]) - 1
	da["tiles"] = int(da["tiles"]) + 1
	var f := int(world.tile_factories[t])
	dd["factories"] = int(dd["factories"]) - f
	da["factories"] = int(da["factories"]) + f
	if world.tile_city[t] != 0:
		dd["cities"] = int(dd["cities"]) - 1
		da["cities"] = int(da["cities"]) + 1
	# стройка на захваченной плитке отменяется
	var left: Array = []
	for b in build_queue:
		if int(b["tile"]) != t:
			left.append(b)
	build_queue = left
	map_dirty = true
	if int(dd["tiles"]) <= 0:
		# страна уничтожена: её дивизии исчезают
		var rest: Array = []
		for sq in squads:
			var o: Dictionary = sq
			if int(o["owner"]) != def:
				rest.append(o)
		squads = rest
		_rebuild()
		if def == player:
			events.append("Ваша страна потеряла все земли")
		else:
			events.append("Страна уничтожена: %s" % dd["name"])


# ---------- стройка ----------

func build_cost(t: int) -> float:
	if world.tile_city[t] == 0:
		return FACTORY_COST + NEW_CITY_EXTRA
	var have := int(world.tile_factories[t])
	return FACTORY_COST + FACTORY_STEP * float(maxi(0, have - 1))


func is_building(t: int) -> bool:
	for b in build_queue:
		if int(b["tile"]) == t:
			return true
	return false


func build_days_left(t: int) -> int:
	for b in build_queue:
		if int(b["tile"]) == t:
			return int(b["days_left"])
	return 0


## Пустая строка = строить можно, иначе причина отказа.
func build_block_reason(cid: int, t: int) -> String:
	if t < 0 or world.land[t] == 0 or world.tile_owner[t] != cid:
		return "Не ваша территория"
	if is_building(t):
		return "Здесь уже идёт стройка"
	if world.tile_city[t] != 0 and world.tile_factories[t] >= world.max_factories(t):
		return "Максимум заводов (%d)" % world.max_factories(t)
	if float(money[cid]) < build_cost(t):
		return "Не хватает денег"
	return ""


func start_build(cid: int, t: int) -> bool:
	if build_block_reason(cid, t) != "":
		return false
	money[cid] = float(money[cid]) - build_cost(t)
	build_queue.append({
		"cid": cid,
		"tile": t,
		"days_left": BUILD_DAYS,
		"new_city": world.tile_city[t] == 0,
	})
	return true


## Плитки, где у страны идёт стройка (для значка на карте).
func construction_tiles(cid: int) -> Array:
	var out: Array = []
	for b in build_queue:
		if int(b["cid"]) == cid:
			out.append(int(b["tile"]))
	return out


func _progress_builds() -> void:
	var left: Array = []
	for b in build_queue:
		var e: Dictionary = b
		e["days_left"] = int(e["days_left"]) - 1
		if int(e["days_left"]) > 0:
			left.append(e)
			continue
		var t: int = e["tile"]
		var cid: int = e["cid"]
		var cn: Dictionary = world.countries[cid]
		world.tile_factories[t] = mini(255, world.tile_factories[t] + 1)
		cn["factories"] = int(cn["factories"]) + 1
		if world.tile_city[t] == 0:
			world.tile_city[t] = 1
			cn["cities"] = int(cn["cities"]) + 1
		map_dirty = true
		if cid == player:
			events.append("Достроен завод (плитка %d, %d)" % [world.col_of(t), world.row_of(t)])
	build_queue = left


# ---------- время ----------

@warning_ignore("integer_division")
func year() -> int:
	return day / DAYS_PER_YEAR + 1


func day_of_year() -> int:
	return day % DAYS_PER_YEAR + 1


func format_date() -> String:
	return "Год %d · день %d" % [year(), day_of_year()]


# ---------- форматирование чисел ----------

## Короткая запись: 1500 -> 1.5k, 2300000 -> 2.30M, отрицательные со знаком минус.
static func fmt(v: float) -> String:
	if v < 0.0:
		return "-" + fmt(-v)
	if v >= 1000000.0:
		return "%.2fM" % (v / 1000000.0)
	if v >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	return "%d" % int(v)


## То же, но с плюсом у положительных: +1.9k, -300.
static func fmt_signed(v: float) -> String:
	if v >= 0.0:
		return "+" + fmt(v)
	return fmt(v)
