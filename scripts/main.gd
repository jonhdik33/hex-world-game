extends Node
## Точка входа. Собирает мир, карту, камеру и простой интерфейс.
## Всё создаётся кодом, поэтому сцена main.tscn почти пустая.

const World = preload("res://scripts/core/world.gd")
const WorldGen = preload("res://scripts/core/world_gen.gd")
const MapView = preload("res://scripts/view/map_view.gd")
const CameraCtl = preload("res://scripts/view/camera_controller.gd")

const MASK_PATH := "res://assets/map_mask.png"
const START_SEED := 12345

var world: World
var map_view: MapView
var camera: CameraCtl
var info_label: Label
var seed_value: int = START_SEED
var _ui_controls: Array[Control] = []


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.07, 0.22, 0.45))

	var tex := load(MASK_PATH) as Texture2D
	if tex == null:
		push_error("Не найдена маска суши: " + MASK_PATH)
		return
	var mask: Image = tex.get_image()

	world = World.new()
	WorldGen.build_land(world, mask)
	WorldGen.assign_countries(world, seed_value)

	map_view = MapView.new()
	add_child(map_view)
	map_view.setup(world)

	camera = CameraCtl.new()
	add_child(camera)
	camera.make_current()
	camera.fit_to(Rect2(Vector2.ZERO, Vector2(world.width_px, world.height_px)))
	camera.tapped.connect(_on_tapped)

	_build_ui()
	_update_info()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	layer.add_child(panel)
	_ui_controls.append(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)

	info_label = Label.new()
	info_label.add_theme_font_size_override("font_size", 22)
	info_label.custom_minimum_size = Vector2(380, 0)
	margin.add_child(info_label)

	var btn := Button.new()
	btn.text = "Новые границы"
	btn.add_theme_font_size_override("font_size", 22)
	layer.add_child(btn)
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.offset_left = -250.0
	btn.offset_right = -12.0
	btn.offset_top = 12.0
	btn.offset_bottom = 66.0
	btn.pressed.connect(_on_regen_pressed)
	_ui_controls.append(btn)


func _on_regen_pressed() -> void:
	seed_value += 1
	WorldGen.assign_countries(world, seed_value)
	map_view.select_tile(-1)
	map_view.refresh()
	_update_info()


func _on_tapped(screen_pos: Vector2, world_pos: Vector2) -> void:
	for c in _ui_controls:
		if c.get_global_rect().has_point(screen_pos):
			return
	var i := world.tile_at(world_pos)
	if i >= 0 and world.land[i] == 1:
		map_view.select_tile(i)
	else:
		map_view.select_tile(-1)
	_update_info()


func _update_info() -> void:
	var lines: Array[String] = []
	lines.append("Hex World — карта №%d" % seed_value)
	lines.append("Плиток суши: %d, стран: %d" % [world.land_count, world.countries.size()])
	var t: int = map_view.selected_tile
	if t >= 0:
		var cid := world.tile_owner[t]
		if cid >= 0:
			var cn: Dictionary = world.countries[cid]
			lines.append("Страна: %s (плиток: %d)" % [cn["name"], cn["tiles"]])
		lines.append("Плитка: %d, %d" % [world.col_of(t), world.row_of(t)])
	else:
		lines.append("Нажмите на плитку суши")
	info_label.text = "\n".join(lines)
