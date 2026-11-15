extends RefCounted
## Генерация мира: суша из маски -> массивы суши -> вымышленные страны.
## Без отрисовки. Результат записывается в объект World (world.gd).
##
## Порядок:
##   1) build_land(world, mask)           — маска -> плитки суши, острова, массивы суши
##   2) assign_countries(world, seed)     — расстановка стран (можно вызывать повторно с другим seed)

const World = preload("res://scripts/core/world.gd")
const Names = preload("res://scripts/core/names.gd")

const HEX_R := 13.0              # размер плитки (пикселей маски). Меньше = больше плиток.
const SAMPLE_RATIO := 0.6        # где брать пробы суши внутри плитки (доля радиуса)
const MIN_LAND_VOTES := 4        # из 7 проб столько должно попасть на сушу
const MIN_ISLAND_TILES := 2      # острова меньше этого удаляются
const SMALL_ISLAND_TILES := 14   # острова меньше этого присоединяются к ближайшей стране
const AVG_COUNTRY_TILES := 70.0  # средний размер страны (плиток)
const GROW_CHANCE := 0.75        # шанс захватить соседнюю плитку за круг (рваность границ)


static func build_land(world: World, mask: Image) -> void:
	world.setup_size(float(mask.get_width()), float(mask.get_height()), HEX_R)
	var w := mask.get_width()
	var h := mask.get_height()
	for i in world.tile_total():
		var c := world.center_of(i)
		var votes := 0
		if _is_land(mask, c.x, c.y, w, h):
			votes += 1
		for k in 6:
			var a := deg_to_rad(60.0 * float(k))
			var p := c + Vector2(cos(a), sin(a)) * world.hex_r * SAMPLE_RATIO
			if _is_land(mask, p.x, p.y, w, h):
				votes += 1
		if votes >= MIN_LAND_VOTES:
			world.land[i] = 1
	_find_landmasses(world)


static func _is_land(mask: Image, x: float, y: float, w: int, h: int) -> bool:
	var px := int(x)
	var py := int(y)
	if px < 0 or py < 0 or px >= w or py >= h:
		return false
	return mask.get_pixel(px, py).r < 0.5   # тёмное = суша


## Находит связные массивы суши, удаляет совсем мелкие островки.
static func _find_landmasses(world: World) -> void:
	var n := world.tile_total()
	var seen := PackedByteArray()
	seen.resize(n)
	seen.fill(0)
	world.masses = []
	for start in n:
		if world.land[start] == 0 or seen[start] == 1:
			continue
		var comp := PackedInt32Array()
		var stack: Array = [start]
		seen[start] = 1
		while stack.size() > 0:
			var cur: int = stack.pop_back()
			comp.append(cur)
			for nb in world.land_neighbors(cur):
				if seen[nb] == 0:
					seen[nb] = 1
					stack.append(nb)
		if comp.size() < MIN_ISLAND_TILES:
			for t in comp:
				world.land[t] = 0
		else:
			world.masses.append(comp)
	world.land_count = 0
	for m in world.masses.size():
		var comp2: PackedInt32Array = world.masses[m]
		for t in comp2:
			world.landmass[t] = m
		world.land_count += comp2.size()


## Расставляет страны. Один и тот же seed всегда даёт одну и ту же карту.
static func assign_countries(world: World, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	world.tile_owner.fill(-1)
	world.countries = []

	var big: Array = []
	var small: Array = []
	for comp in world.masses:
		if comp.size() >= SMALL_ISLAND_TILES:
			big.append(comp)
		else:
			small.append(comp)
	if big.is_empty():
		big = world.masses.duplicate()
		small = []

	# 1) зёрна стран на больших массивах суши
	var seeds_all: Array = []
	for comp in big:
		var k := maxi(1, int(round(float(comp.size()) / AVG_COUNTRY_TILES)))
		var seeds: Array = _place_seeds(world, comp, k, rng)
		for s in seeds:
			seeds_all.append(s)

	var names: Array = Names.make_names(seeds_all.size(), rng)
	var frontiers: Array = []
	for cid in seeds_all.size():
		var t: int = seeds_all[cid]
		world.tile_owner[t] = cid
		frontiers.append([t])
		world.countries.append({
			"id": cid,
			"name": names[cid],
			"color": _country_color(cid),
			"seed": t,
			"capital": t,
			"tiles": 0,
		})

	# 2) рост стран от зёрен (рваные границы)
	_grow(world, frontiers, rng)

	# 3) мелкие острова отдаём ближайшей стране
	_attach_small_islands(world, small)

	# 4) статистика и столицы
	_finalize(world)


static func _place_seeds(world: World, comp: PackedInt32Array, k: int, rng: RandomNumberGenerator) -> Array:
	var seeds: Array = []
	seeds.append(comp[rng.randi_range(0, comp.size() - 1)])
	while seeds.size() < k:
		var dist := _bfs_dist(world, seeds)
		var maxd := 0
		for t in comp:
			if dist[t] > maxd:
				maxd = dist[t]
		var cands: Array = []
		for t in comp:
			if dist[t] >= maxd - 1 and dist[t] > 0:
				cands.append(t)
		if cands.is_empty():
			break
		seeds.append(cands[rng.randi_range(0, cands.size() - 1)])
	return seeds


static func _bfs_dist(world: World, sources: Array) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(world.tile_total())
	dist.fill(-1)
	var queue: Array = []
	for s in sources:
		dist[s] = 0
		queue.append(s)
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		for nb in world.land_neighbors(cur):
			if dist[nb] == -1:
				dist[nb] = dist[cur] + 1
				queue.append(nb)
	return dist


static func _grow(world: World, frontiers: Array, rng: RandomNumberGenerator) -> void:
	var active := true
	var guard := 0
	while active and guard < 5000:
		guard += 1
		active = false
		var count := frontiers.size()
		for step in count:
			# порядок обхода меняется каждый круг, чтобы ранние страны не получали преимущество
			var cid := step if (guard % 2 == 0) else (count - 1 - step)
			var fr: Array = frontiers[cid]
			if fr.is_empty():
				continue
			var next_fr: Array = []
			for t in fr:
				var keep := false
				for nb in world.land_neighbors(t):
					if world.tile_owner[nb] != -1:
						continue
					if rng.randf() < GROW_CHANCE:
						world.tile_owner[nb] = cid
						next_fr.append(nb)
					else:
						keep = true
				if keep:
					next_fr.append(t)
			frontiers[cid] = next_fr
			if not next_fr.is_empty():
				active = true


static func _attach_small_islands(world: World, small: Array) -> void:
	if small.is_empty():
		return
	var owned: Array = []
	for i in world.tile_total():
		if world.land[i] == 1 and world.tile_owner[i] != -1:
			owned.append(i)
	if owned.is_empty():
		return
	for comp in small:
		var cen := Vector2.ZERO
		for t in comp:
			cen += world.center_of(t)
		cen /= float(comp.size())
		var best := -1
		var best_d := INF
		for o in owned:
			var d := world.center_of(o).distance_squared_to(cen)
			if d < best_d:
				best_d = d
				best = o
		var cid := world.tile_owner[best]
		for t in comp:
			world.tile_owner[t] = cid


## Считает плитки стран и выбирает столицу — плитку ближе всего к центру
## основной части страны (на том же массиве суши, где стоит зерно).
static func _finalize(world: World) -> void:
	var cnt := world.countries.size()
	var sum_pos: Array = []
	var home_n: Array = []
	for c in cnt:
		sum_pos.append(Vector2.ZERO)
		home_n.append(0)
	for i in world.tile_total():
		if world.land[i] == 0:
			continue
		var cid := world.tile_owner[i]
		if cid < 0:
			continue
		world.countries[cid]["tiles"] += 1
		var home_mass := world.landmass[int(world.countries[cid]["seed"])]
		if world.landmass[i] == home_mass:
			sum_pos[cid] += world.center_of(i)
			home_n[cid] += 1
	var best_d: Array = []
	for c in cnt:
		best_d.append(INF)
	for i in world.tile_total():
		if world.land[i] == 0:
			continue
		var cid2 := world.tile_owner[i]
		if cid2 < 0 or home_n[cid2] == 0:
			continue
		var home_mass2 := world.landmass[int(world.countries[cid2]["seed"])]
		if world.landmass[i] != home_mass2:
			continue
		var centroid: Vector2 = sum_pos[cid2] / float(home_n[cid2])
		var d := world.center_of(i).distance_squared_to(centroid)
		if d < float(best_d[cid2]):
			best_d[cid2] = d
			world.countries[cid2]["capital"] = i


static func _country_color(cid: int) -> Color:
	var hue := fmod(float(cid) * 0.61803398875, 1.0)
	var sat := 0.45 + 0.15 * float(cid % 3)
	var val := 0.78 + 0.10 * float(cid % 2)
	return Color.from_hsv(hue, sat, val)
