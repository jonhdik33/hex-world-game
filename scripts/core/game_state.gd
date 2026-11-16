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
const Navy = preload("res://scripts/core/navy.gd")
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
const STEP_SECONDS := 3.0             # шаг на соседнюю плитку (реальных секунд при x1)
const BATTLE_DPS := 20.0              # урон в секунду одной дивизии полной силы
const BATTLE_MAX := 40.0              # дольше этого бой не длится
const RECOVER_DAYS := 3               # дней отдыха после боя
const ST_IDLE := 0
const ST_MOVE := 1
const ST_FIGHT := 2
const MAX_HP := 100.0               # полная сила дивизии
const HEAL_PER_DAY := 5.0            # лечение в день
const EQUIP_PER_FACTORY := 0.5       # снаряжения в день с одного завода при 100% на армию
const EQUIP_PER_DIVISION := 10.0     # снаряжения на одну новую дивизию
const START_EQUIP_DIVISIONS := 2.0   # стартовый запас снаряжения (в дивизиях)
const DEFAULT_MIL_SHARE := 0.3       # доля заводов на армию по умолчанию
const TRUCE_DAYS := 30               # после мира нельзя объявить войну заново
const PEACE_MIN_WAR_DAYS := 10       # раньше этого срока бот мир не принимает

# наука: три ветки по 3 уровня; платится деньгами, длится дни
const TECH_NAMES: Array = ["Тактика", "Промышленность", "Снабжение"]
const TECH_EFFECT: Array = ["сила дивизий", "доход заводов", "выпуск снаряжения"]
const TECH_BONUS: Array = [0.10, 0.10, 0.15]      # прирост за уровень
const TECH_COST: Array = [6000.0, 14000.0, 28000.0]
const TECH_DAYS: Array = [15, 25, 35]
const TECH_MAX := 3
const WAIT_REROUTE := 3.0            # через сколько секунд ожидания искать обход

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
var battles: Array = []       # идущие бои: {target, att, def, t}
var ships: Array = []         # корабли (см. navy.gd)
var _next_ship_id: int = 1
var difficulty: int = 1       # 0 лёгкая, 1 средняя, 2 сложная (боты)
var bot_style: Array = []     # характер бота: 0 рвётся к столице, 1 берёт ближние плитки, 2 обороняется
var active_bot: Array = []    # true = бот воюет (остальные только развиваются)
var rng := RandomNumberGenerator.new()
var bot_aggr: Array = []      # агрессивность бота 0..1
var mil_share: Array = []     # доля заводов, работающих на армию (0..1)
var equipment: Array = []     # запас снаряжения
var tech: Array = []          # уровни науки: tech[cid] = [тактика, промышленность, снабжение]
var research: Array = []      # текущее исследование: {} или {branch, days_left}
var war_since: Dictionary = {} # ключ пары -> день начала войны
var truce: Dictionary = {}     # ключ пары -> день, до которого нельзя объявлять войну
var game_over: int = 0         # 0 игра идёт, 1 победа, 2 поражение
var at_war: Dictionary = {}   # пары стран в состоянии войны: min*1000+max
var _next_id: int = 1
var build_queue: Array = []   # стройки: [{cid, tile, days_left, new_city}]
var events: Array = []        # сообщения для игрока (забирает main и очищает)
var sounds: Array = []        # звуки для игрока (забирает main и очищает)
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
	sounds = []
	battles = []
	ships = []
	_next_ship_id = 1
	map_dirty = false
	for cid in world.countries.size():
		var cn: Dictionary = world.countries[cid]
		population.append(float(cn["tiles"]) * POP_PER_TILE)
		army.append(maxi(1, int(round(float(cn["tiles"]) / ARMY_TILES_PER_DIVISION))))
		money.append(0.0)
	rng.seed = 424242
	game_over = 0
	war_since = {}
	truce = {}
	bot_aggr = []
	bot_style = []
	active_bot = []
	mil_share = []
	equipment = []
	tech = []
	research = []
	for c in world.countries.size():
		var ag := rng.randf_range(0.2, 1.0)
		bot_aggr.append(ag)
		var rs := rng.randf()
		if rs < 0.3:
			bot_style.append(0)
		elif rs < 0.7:
			bot_style.append(1)
		else:
			bot_style.append(2)
		active_bot.append(false)
		mil_share.append(0.2 + 0.4 * ag)
		equipment.append(EQUIP_PER_DIVISION * START_EQUIP_DIVISIONS)
		tech.append([0, 0, 0])
		research.append({})
	_place_armies()
	Navy.give_start_ships(self)
	_rebuild()
	# Стартовая казна рассчитывается только после инициализации экономики,
	# армии, технологий и флота.
	for cid in world.countries.size():
		money[cid] = maxf(0.0, daily_net(cid)) * START_MONEY_DAYS


# ---------- экономика ----------

## Все статьи дневного бюджета страны.
func budget(cid: int) -> Dictionary:
	var cn: Dictionary = world.countries[cid]
	var tax := float(population[cid]) * TAX_PER_PERSON
	var civ := 1.0 - float(mil_share[cid])
	var industry := float(cn["factories"]) * INCOME_PER_FACTORY * civ * (1.0 + float(TECH_BONUS[1]) * float(tech_level(cid, 1)))
	var up_f := float(cn["factories"]) * FACTORY_UPKEEP
	var up_c := float(cn["cities"]) * CITY_UPKEEP
	var up_a := float(army[cid]) * DIVISION_UPKEEP
	var up_s := float(Navy.count_of(self, cid)) * Navy.SHIP_UPKEEP
	var income := tax + industry
	var expenses := up_f + up_c + up_a + up_s
	return {
		"tax": tax,
		"industry": industry,
		"upkeep_factories": up_f,
		"upkeep_cities": up_c,
		"upkeep_ships": up_s,
		"upkeep_army": up_a,
		"income": income,
		"expenses": expenses,
		"net": income - expenses,
	}


func tech_level(cid: int, branch: int) -> int:
	var t: Array = tech[cid]
	return int(t[branch])


## Снаряжение в день.
func equip_per_day(cid: int) -> float:
	var cn: Dictionary = world.countries[cid]
	return float(cn["factories"]) * float(mil_share[cid]) * EQUIP_PER_FACTORY * (1.0 + float(TECH_BONUS[2]) * float(tech_level(cid, 2)))


func daily_net(cid: int) -> float:
	var b: Dictionary = budget(cid)
	return float(b["net"])


func tick_day() -> void:
	for cid in world.countries.size():
		money[cid] = float(money[cid]) + daily_net(cid)
		population[cid] = float(population[cid]) * (1.0 + POP_GROWTH_PER_DAY)
		equipment[cid] = float(equipment[cid]) + equip_per_day(cid)
		_progress_research(cid)
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
		if cid != player and (day + cid) % bot_period() == 0:
			BotAI.think(self, cid, float(bot_aggr[cid]), is_bot_active(cid))
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
		"p": 0.0, "crossed": false, "state": ST_IDLE, "recover": 0, "fight_t": 0.0, "wait_t": 0.0, "dead": false, "pre": 0,
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
	for sh in ships:
		var shd: Dictionary = sh
		var cargo: Dictionary = shd["cargo"]
		if not cargo.is_empty():
			army[int(shd["owner"])] = int(army[int(shd["owner"])]) + 1


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
	e["dead"] = true
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
	if float(equipment[cid]) < EQUIP_PER_DIVISION:
		return "Не хватает снаряжения"
	return ""


func recruit(cid: int, t: int) -> bool:
	if recruit_block_reason(cid, t) != "":
		return false
	money[cid] = float(money[cid]) - RECRUIT_COST
	equipment[cid] = float(equipment[cid]) - EQUIP_PER_DIVISION
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


# ---------- боты: сложность ----------

func bot_period() -> int:
	return int([5, 3, 2][difficulty])


func bot_orders() -> int:
	return int([1, 2, 3][difficulty])


func bot_miss_chance() -> float:
	return float([0.5, 0.3, 0.1][difficulty])


func bot_attack_ratio() -> float:
	return float([1.3, 1.1, 1.0][difficulty])


func bot_peace_days() -> int:
	return int([120, 60, 30][difficulty])


func bot_active_count() -> int:
	return int([3, 5, 8][difficulty])


## Выбирает, какие боты воюют: ближайшие к столице игрока (число зависит от сложности).
func setup_bots() -> void:
	for c in active_bot.size():
		active_bot[c] = false
	if player < 0:
		return
	var pc: int = world.countries[player]["capital"]
	var here: Vector2 = world.center_of(pc)
	var cand: Array = []
	for c in world.countries.size():
		if c != player and int(world.countries[c]["tiles"]) > 0:
			var cap: int = world.countries[c]["capital"]
			cand.append([here.distance_squared_to(world.center_of(cap)), c])
	cand.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for k in mini(bot_active_count(), cand.size()):
		var row: Array = cand[k]
		active_bot[int(row[1])] = true


func is_bot_active(cid: int) -> bool:
	return bool(active_bot[cid]) or (player >= 0 and is_at_war(cid, player))


# ---------- война ----------

func is_at_war(a: int, b: int) -> bool:
	return at_war.has(mini(a, b) * 1000 + maxi(a, b))


func _pair(a: int, b: int) -> int:
	return mini(a, b) * 1000 + maxi(a, b)


func can_declare(a: int, b: int) -> bool:
	if a == b or a < 0 or b < 0 or is_at_war(a, b):
		return false
	return not (truce.has(_pair(a, b)) and int(truce[_pair(a, b)]) > day)


func declare_war(a: int, b: int) -> bool:
	if not can_declare(a, b):
		return false
	at_war[_pair(a, b)] = true
	war_since[_pair(a, b)] = day
	return true


func war_days(a: int, b: int) -> int:
	if not war_since.has(_pair(a, b)):
		return 0
	return day - int(war_since[_pair(a, b)])


func make_peace(a: int, b: int) -> void:
	at_war.erase(_pair(a, b))
	war_since.erase(_pair(a, b))
	truce[_pair(a, b)] = day + TRUCE_DAYS


## Игрок предлагает мир боту. Бот соглашается, если война длится не меньше PEACE_MIN_WAR_DAYS
## и он не заметно сильнее игрока по числу дивизий.
func propose_peace(cid: int, other: int) -> Dictionary:
	if not is_at_war(cid, other):
		return {"ok": false, "msg": "Войны нет"}
	if war_days(cid, other) < PEACE_MIN_WAR_DAYS:
		return {"ok": false, "msg": "Рано: война только началась"}
	if float(army[other]) > float(army[cid]) * 1.3 + 1.0:
		return {"ok": false, "msg": "Противник отказался от мира"}
	make_peace(cid, other)
	return {"ok": true, "msg": "Мир заключён"}


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
	if dt <= 0.0:
		return
	for sq in squads.duplicate():
		var e: Dictionary = sq
		if bool(e["dead"]):
			continue
		var st: int = e["state"]
		if st == ST_IDLE or st == ST_FIGHT or int(e["recover"]) > 0:
			continue
		_advance_move(e, dt)
	_tick_battles(dt)
	Navy.advance(self, dt)


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
			_join_battle(e, nxt)
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


# ---------- бои ----------
## Бой идёт на границе плитки-цели. С одной стороны — атакующие (можно подвести ещё дивизии:
## они присоединяются, когда доходят до границы), с другой — защитник и его соседние стоящие дивизии.
## Каждая дивизия наносит урон в секунду, зависящий от её силы и науки; урон делится поровну
## между дивизиями противника. Бой длится несколько секунд, видно, как падает сила. Случайности нет
## (кроме абсолютно равного исхода — там жребий).

func _join_battle(e: Dictionary, target: int) -> void:
	for b in battles:
		if int(b["target"]) == target:
			var att: Array = b["att"]
			att.append(e)
			e["pre"] = ST_MOVE
			e["state"] = ST_FIGHT
			return
	var d := unit_at(target)
	if d.is_empty() or int(d["state"]) == ST_FIGHT:
		e["p"] = 0.45   # защитник занят другим боем: подождём
		return
	d["pre"] = int(d["state"])
	d["state"] = ST_FIGHT
	var defs: Array = [d]
	for k in 6:
		var nb := world.neighbor(target, k)
		if nb < 0 or not unit_on.has(nb):
			continue
		var u: Dictionary = unit_on[nb]
		if int(u["owner"]) == int(d["owner"]) and int(u["state"]) == ST_IDLE and int(u["recover"]) <= 0:
			u["pre"] = ST_IDLE
			u["state"] = ST_FIGHT
			defs.append(u)
	e["pre"] = ST_MOVE
	e["state"] = ST_FIGHT
	battles.append({"target": target, "att": [e], "def": defs, "t": 0.0,
		"att_owner": int(e["owner"]), "def_owner": int(d["owner"])})
	if int(e["owner"]) == player or int(d["owner"]) == player:
		sounds.append("battle")


func _unit_dps(u: Dictionary) -> float:
	var k := 1.0 + float(TECH_BONUS[0]) * float(tech_level(int(u["owner"]), 0))
	return BATTLE_DPS * (0.5 + 0.5 * float(u["hp"]) / MAX_HP) * k


func _alive(list: Array) -> Array:
	var out: Array = []
	for u in list:
		var d: Dictionary = u
		if not bool(d["dead"]) and float(d["hp"]) > 0.0:
			out.append(d)
	return out


func _tick_battles(dt: float) -> void:
	for b in battles.duplicate():
		var att: Array = _alive(b["att"])
		var def: Array = _alive(b["def"])
		b["t"] = float(b["t"]) + dt
		if att.is_empty() or def.is_empty() or float(b["t"]) > BATTLE_MAX:
			b["att"] = att
			b["def"] = def
			_end_battle(b)
			continue
		var a_dmg := 0.0
		for u in att:
			a_dmg += _unit_dps(u)
		var d_dmg := 0.0
		for u in def:
			d_dmg += _unit_dps(u)
		var to_def := a_dmg * dt / float(def.size())
		var to_att := d_dmg * dt / float(att.size())
		for u in def:
			var ud: Dictionary = u
			ud["hp"] = float(ud["hp"]) - to_def
		for u in att:
			var ua: Dictionary = u
			ua["hp"] = float(ua["hp"]) - to_att
		var att2 := _alive(att)
		var def2 := _alive(def)
		if att2.is_empty() and def2.is_empty():
			# абсолютно равный исход: жребий оставляет одну дивизию с 1 силой
			var pool: Array = att
			if rng.randf() < 0.5:
				pool = def
			var lucky: Dictionary = pool[0]
			lucky["hp"] = 1.0
			if pool == att:
				att2 = [lucky]
			else:
				def2 = [lucky]
		# погибших убираем с карты
		for u in att:
			var x: Dictionary = u
			if float(x["hp"]) <= 0.0 and not bool(x["dead"]):
				_remove_unit(x)
		for u in def:
			var y: Dictionary = u
			if float(y["hp"]) <= 0.0 and not bool(y["dead"]):
				_remove_unit(y)
		b["att"] = att2
		b["def"] = def2
		if att2.is_empty() or def2.is_empty():
			_end_battle(b)


func _end_battle(b: Dictionary) -> void:
	battles.erase(b)
	var att: Array = _alive(b["att"])
	var def: Array = _alive(b["def"])
	var target: int = b["target"]
	if att.is_empty():
		# оборона удалась: защитники отдыхают и возвращаются к прежнему делу
		for u in def:
			var d: Dictionary = u
			d["state"] = int(d["pre"])
			d["recover"] = RECOVER_DAYS
		_note(int(b["att_owner"]), int(b["def_owner"]), "Атака отбита")
		_rebuild()
		return
	if def.is_empty():
		var att_owner: int = int(att[0]["owner"])
		var def_owner2: int = int(b["def_owner"])
		for u in att:
			var a: Dictionary = u
			a["state"] = ST_MOVE
			a["recover"] = RECOVER_DAYS
			a["crossed"] = true
		if def_owner2 != att_owner and def_owner2 >= 0:
			_capture(att_owner, def_owner2, target)
			_note(att_owner, def_owner2, "Плитка захвачена")
		_rebuild()
		return
	# время вышло, обе стороны живы: атакующие отступают, защитники возвращаются к делам
	for u in att:
		var a2: Dictionary = u
		_stop(a2)
	for u in def:
		var d2: Dictionary = u
		d2["state"] = int(d2["pre"])
	_rebuild()


func _note(att: int, def: int, text: String) -> void:
	if att == player or def == player:
		var a: Dictionary = world.countries[att]
		var b: Dictionary = world.countries[def]
		events.append("%s: %s против %s" % [text, a["name"], b["name"]])


func _capture(att: int, def: int, t: int) -> void:
	var da: Dictionary = world.countries[att]
	var dd: Dictionary = world.countries[def]
	if att == player:
		sounds.append("capture")
	elif def == player:
		sounds.append("alert")
	if int(dd["capital"]) == t:
		_annex(att, def)
		return
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
			else:
				o["dead"] = true
		squads = rest
		_rebuild()
		if def == player:
			events.append("Ваша страна потеряла все земли")
		else:
			events.append("Страна уничтожена: %s" % dd["name"])


## Столица взята: вся страна присоединяется к победителю (земли, города, заводы, люди; цвет — победителя).
func _annex(att: int, def: int) -> void:
	var da: Dictionary = world.countries[att]
	var dd: Dictionary = world.countries[def]
	for i in world.tile_total():
		if world.land[i] == 1 and world.tile_owner[i] == def:
			world.tile_owner[i] = att
	da["tiles"] = int(da["tiles"]) + int(dd["tiles"])
	da["factories"] = int(da["factories"]) + int(dd["factories"])
	da["cities"] = int(da["cities"]) + int(dd["cities"])
	population[att] = float(population[att]) + float(population[def])
	var cap: int = dd["capital"]
	world.tile_city[cap] = 1   # бывшая столица — обычный город, звезда одна
	dd["tiles"] = 0
	dd["factories"] = 0
	dd["cities"] = 0
	population[def] = 0.0
	money[def] = 0.0
	var rest: Array = []
	for sq in squads:
		var o: Dictionary = sq
		if int(o["owner"]) != def:
			rest.append(o)
		else:
			o["dead"] = true
	squads = rest
	var q: Array = []
	for b in build_queue:
		if int(b["cid"]) != def:
			q.append(b)
	build_queue = q
	Navy.remove_country(self, def)
	_rebuild()
	map_dirty = true
	if att == player:
		events.append("Столица взята! %s присоединена к вам" % dd["name"])
		var alive := 0
		for c in world.countries.size():
			if c != player and int(world.countries[c]["tiles"]) > 0:
				alive += 1
		if alive == 0:
			game_over = 1
	elif def == player:
		events.append("Ваша столица пала: %s" % da["name"])
		game_over = 2
	else:
		events.append("%s присоединила страну %s" % [da["name"], dd["name"]])


# ---------- наука ----------

func tech_cost(level: int) -> float:
	return float(TECH_COST[clampi(level, 0, TECH_MAX - 1)])


func research_block_reason(cid: int, branch: int) -> String:
	var lvl := tech_level(cid, branch)
	if lvl >= TECH_MAX:
		return "Максимальный уровень"
	var cur: Dictionary = research[cid]
	if not cur.is_empty():
		return "Идёт другое исследование"
	if float(money[cid]) < float(TECH_COST[lvl]):
		return "Не хватает денег"
	return ""


func start_research(cid: int, branch: int) -> bool:
	if research_block_reason(cid, branch) != "":
		return false
	var lvl := tech_level(cid, branch)
	money[cid] = float(money[cid]) - float(TECH_COST[lvl])
	research[cid] = {"branch": branch, "days_left": int(TECH_DAYS[lvl])}
	return true


func _progress_research(cid: int) -> void:
	var cur: Dictionary = research[cid]
	if cur.is_empty():
		return
	cur["days_left"] = int(cur["days_left"]) - 1
	if int(cur["days_left"]) > 0:
		return
	var br: int = cur["branch"]
	var t: Array = tech[cid]
	t[br] = int(t[br]) + 1
	research[cid] = {}
	if cid == player:
		events.append("Исследование завершено: %s %d" % [TECH_NAMES[br], int(t[br])])
		sounds.append("research")


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
		"kind": "factory",
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
		if String(e.get("kind", "factory")) == "port":
			world.tile_port[t] = 1
			map_dirty = true
			if cid == player:
				events.append("Порт построен (плитка %d, %d)" % [world.col_of(t), world.row_of(t)])
				sounds.append("build")
			continue
		world.tile_factories[t] = mini(255, world.tile_factories[t] + 1)
		cn["factories"] = int(cn["factories"]) + 1
		if world.tile_city[t] == 0:
			world.tile_city[t] = 1
			cn["cities"] = int(cn["cities"]) + 1
		map_dirty = true
		if cid == player:
			events.append("Достроен завод (плитка %d, %d)" % [world.col_of(t), world.row_of(t)])
			sounds.append("build")
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
