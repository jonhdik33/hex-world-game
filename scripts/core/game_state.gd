extends RefCounted
## Состояние игры: время, деньги и население стран. Чистая логика, без экрана.
## Расходы (армия, содержание построек) добавим в модуле 3 — место для них
## уже есть в daily_income() / tick_day().

const World = preload("res://scripts/core/world.gd")

const DAYS_PER_YEAR := 360
const POP_PER_TILE := 30000.0         # людей на плитку при старте
const POP_GROWTH_PER_DAY := 0.0001    # рост населения в день (≈3.7% в год)
const TAX_PER_PERSON := 0.0008        # налог с одного человека в день
const INCOME_PER_FACTORY := 120.0     # доход с одного завода в день
const START_MONEY_DAYS := 30.0        # стартовая казна = столько дней дохода

var world: World
var day: int = 0              # дней с начала игры
var player: int = -1          # id страны игрока, -1 = ещё не выбрана
var money: Array = []         # казна каждой страны (float)
var population: Array = []    # население каждой страны (float)


func _init(w: World) -> void:
	world = w
	reset()


func reset() -> void:
	day = 0
	player = -1
	money = []
	population = []
	for cid in world.countries.size():
		var cn: Dictionary = world.countries[cid]
		population.append(float(cn["tiles"]) * POP_PER_TILE)
		money.append(daily_income(cid) * START_MONEY_DAYS)


func daily_income(cid: int) -> float:
	var cn: Dictionary = world.countries[cid]
	return float(population[cid]) * TAX_PER_PERSON + float(cn["factories"]) * INCOME_PER_FACTORY


func tick_day() -> void:
	for cid in world.countries.size():
		money[cid] = float(money[cid]) + daily_income(cid)
		population[cid] = float(population[cid]) * (1.0 + POP_GROWTH_PER_DAY)
	day += 1


@warning_ignore("integer_division")
func year() -> int:
	return day / DAYS_PER_YEAR + 1


func day_of_year() -> int:
	return day % DAYS_PER_YEAR + 1


func format_date() -> String:
	return "Год %d · день %d" % [year(), day_of_year()]


## Короткая запись чисел: 1500 -> 1.5k, 2300000 -> 2.30M
static func fmt(v: float) -> String:
	if v >= 1000000.0:
		return "%.2fM" % (v / 1000000.0)
	if v >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	return "%d" % int(v)
