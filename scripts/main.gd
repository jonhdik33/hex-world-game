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

	_show_tile_info(-1)


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
		_refresh_hud()


# ---------- события ----------

func _on_tapped(screen_pos: Vector2, world_pos: Vector2) -> void:
	if hud.is_over_ui(screen_pos):
		return
	var i := -1
	if world.bounds().has_point(world_pos):
		i = world.tile_at(world_pos)
	map_view.select_tile(i)
	if not playing:
		_pick_on_tile(i)
	_show_tile_info(i)


func _pick_on_tile(i: int) -> void:
	if i >= 0 and world.land[i] == 1 and world.tile_owner[i] >= 0:
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
	hud.enter_play()
	hud.set_speed_mark(speed)
	_refresh_hud()


func _on_regen() -> void:
	if playing:
		return
	seed_value += 1
	WorldGen.assign_countries(world, seed_value)
	state.reset()
	_picked = -1
	hud.hide_pick()
	map_view.select_tile(-1)
	map_view.refresh()
	_show_tile_info(-1)


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
		state.daily_income(cid),
		int(cn["factories"]),
		float(state.population[cid]),
		state.format_date()
	)


func _show_tile_info(t: int) -> void:
	var lines: Array[String] = []
	if t < 0:
		lines.append("Карта №%d · стран: %d" % [seed_value, world.countries.size()])
		lines.append("Нажмите на плитку")
		hud.set_info("\n".join(lines))
		return
	if world.land[t] == 1:
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
	else:
		if world.sea_dist[t] <= 2:
			lines.append("Море: мелководье")
		else:
			lines.append("Море: открытый океан")
	lines.append("Плитка: %d, %d" % [world.col_of(t), world.row_of(t)])
	hud.set_info("\n".join(lines))
