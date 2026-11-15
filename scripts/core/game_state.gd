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

# стройка
const FACTORY_COST := 4000.0          # цена завода
const NEW_CITY_EXTRA := 2000.0        # доплата, если строим на обычной плитке (появится город)
const BUILD_DAYS := 10                # сколько дней строится
const MAX_FACTORIES_PER_TILE := 8     # максимум заводов в одном городе

var world: World
var day: int = 0              # дней с начала игры
var player: int = -1          # id страны игрока, -1 = ещё не выбрана
var money: Array = []         # казна каждой страны (float)
var population: Array = []    # население каждой страны (float)
var army: Array = []          # дивизий у каждой страны (int)
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
			army[cid] = int(army[cid]) - 1
			if cid == player:
				events.append("Нет денег: распущена одна дивизия")
	_progress_builds()
	day += 1


# ---------- стройка ----------

func build_cost(t: int) -> float:
	var c := FACTORY_COST
	if world.tile_city[t] == 0:
		c += NEW_CITY_EXTRA
	return c


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
	if world.tile_factories[t] >= MAX_FACTORIES_PER_TILE:
		return "В городе максимум заводов"
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
