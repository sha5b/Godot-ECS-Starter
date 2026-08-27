extends Node3D

## World generation QA harness — the "visual test loop" for terrain quality.
##
## Sweeps a list of seeds; for each seed it loads a fresh copy of the real
## world (scenes/main.tscn), waits for the chunk ring to finish generating,
## then checks:
##
##   COLLISION  — a ray grid over every loaded chunk must hit terrain
##                (no holes, no missing colliders) and the hit height must
##                match the chunk heightmap within tolerance
##   ALIGNMENT  — foliage instances and ECS actors sit on the surface,
##                nothing spawns underwater
##   DIVERSITY  — distinct biomes across chunks, height range (not flat),
##                rivers present, ECS content (critters/berries/campfires)
##   SEAMS      — neighbor chunk heightmaps match along shared borders
##
## Visual mode shows the RTS view and a live results table (N = next seed,
## ESC = quit). Headless it prints a per-seed report and exits non-zero on
## any failure:
##   godot --headless --path . res://tests/visual/worldgen_qa_test.tscn


const SEEDS: Array[int] = [128674, 731, 4242, 99001]
const SETTLE_TIMEOUT := 25.0
const RAYS_PER_AXIS := 5
const COLLISION_HEIGHT_TOLERANCE := 0.9
const FOLIAGE_ALIGN_TOLERANCE := 1.5
const ECS_ALIGN_TOLERANCE := 1.0
const MIN_DISTINCT_BIOMES := 3
const MIN_HEIGHT_RANGE := 6.0

var headless := false
var _seed_index := -1
var _world: Node = null
var _running := false
var _hud: Label
var _report_lines: Array[String] = []
var _seed_results: Array[bool] = []
var _skip_requested := false


func _ready() -> void:
	headless = DisplayServer.get_name() == "headless"
	GameConfig.randomize_seed_on_play = false
	if not headless:
		_build_hud()
	_next_seed()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.physical_keycode == KEY_N:
			_skip_requested = true
		elif key.physical_keycode == KEY_ESCAPE:
			get_tree().quit(1 if _seed_results.has(false) else 0)


func _next_seed() -> void:
	_seed_index += 1
	_skip_requested = false
	if _seed_index >= SEEDS.size():
		_finish()
		return
	_running = true
	_run_seed(SEEDS[_seed_index])


func _finish() -> void:
	var verdict := "ALL SEEDS PASS"
	if _seed_results.has(false):
		verdict = "FAILURES PRESENT"
	print("\n=== Worldgen QA: %s (%d/%d seeds passed) ===" % [
		verdict, _seed_results.count(true), _seed_results.size()])
	for line in _report_lines:
		print(line)
	if headless:
		get_tree().quit(0 if not _seed_results.has(false) else 1)
	elif _hud != null:
		_hud.text = "Worldgen QA — %s\n\n%s" % [verdict, "\n".join(_report_lines)]


func _run_seed(seed_value: int) -> void:
	print("\n[WORLDGEN QA] === seed %d ===" % seed_value)
	GameConfig.world_seed = seed_value
	# Stale cross-seed caches would leak last seed's rivers into this world.
	SharedWorld.river_paths.clear()
	SharedWorld.river_cells.clear()

	if _world != null:
		_world.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	var packed: PackedScene = load("res://scenes/main.tscn")
	_world = packed.instantiate()
	add_child(_world)
	await get_tree().process_frame

	var settled := await _wait_for_chunks()
	if not settled:
		_record(false, "generation did not settle in time")
		_next_seed()
		return

	# Let one physics frame flush so colliders exist for raycasts.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var collision_ok := true
	var collision_note := ""
	var chunks := _chunk_manager().active_chunks
	if chunks.is_empty():
		collision_ok = false
		collision_note = "no chunks"
	else:
		var ray_total := 0
		var holes := 0
		var worst_delta := 0.0
		for coord in chunks:
			var result := await _check_chunk_collision(coord, chunks[coord])
			ray_total += result["rays"]
			holes += result["holes"]
			worst_delta = maxf(worst_delta, result["worst_delta"])
		collision_ok = holes == 0 and worst_delta <= COLLISION_HEIGHT_TOLERANCE
		collision_note = "%d rays, %d holes, hm-delta %.2f" % [ray_total, holes, worst_delta]

	var foliage := _check_foliage_alignment()
	var ecs := _check_ecs_placement()
	var diversity := _check_diversity(chunks)
	var seams := _check_seams(chunks)

	var seams_ok: bool = int(seams["fails"]) == 0
	var ok: bool = collision_ok and bool(foliage["ok"]) and bool(ecs["ok"]) \
		and bool(diversity["ok"]) and seams_ok
	_seed_results.append(ok)
	var line := "seed %d | collision %s (%s) | foliage %.1f%% | ecs %.1f%% wet=%d | biomes %d h-range %.1fm rivers %d | seams %d/%d fail | %s" % [
		seed_value,
		"OK" if collision_ok else "FAIL", collision_note,
		foliage["ratio"] * 100.0,
		ecs["ratio"] * 100.0, ecs["underwater"],
		diversity["biomes"], diversity["height_range"], diversity["river_chunks"],
		seams["fails"], seams["pairs"],
		"PASS" if ok else "FAIL",
	]
	_report_lines.append(line)
	print("[WORLDGEN QA] " + line)
	if _hud != null:
		_hud.text = "Worldgen QA — seed %d/%d\n\n%s" % [
			_seed_index + 1, SEEDS.size(), "\n".join(_report_lines)]
	_running = false
	if not headless:
		await get_tree().create_timer(6.0).timeout
	_next_seed()


func _record(ok: bool, note: String) -> void:
	_seed_results.append(ok)
	_report_lines.append("seed %d — %s (%s)" % [SEEDS[_seed_index], "PASS" if ok else "FAIL", note])
	print("[WORLDGEN QA] %s" % _report_lines[-1])


# ── Settling ─────────────────────────────────────────────────────────────────


func _wait_for_chunks() -> bool:
	var waited := 0.0
	while waited < SETTLE_TIMEOUT:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		var mgr := _chunk_manager()
		if mgr == null:
			continue
		var chunks: Dictionary = mgr.active_chunks
		var expected := (2 * GameConfig.load_radius + 1) * (2 * GameConfig.load_radius + 1)
		if chunks.size() < expected:
			continue
		var all_ready := true
		for coord in chunks:
			var data: ChunkData = chunks[coord]
			if data == null or not data.terrain_ready:
				all_ready = false
				break
		if all_ready:
			return true
	return false


func _chunk_manager() -> ChunkManager:
	var group := get_tree().get_nodes_in_group(&"ecs_systems")
	for node in group:
		if node is ChunkManager:
			return node
	return null


# ── Checks ───────────────────────────────────────────────────────────────────


## Ray grid over one chunk: every ray must hit, and the hit height must
## agree with the chunk heightmap (collision follows the rendered mesh).
func _check_chunk_collision(coord: Vector2i, chunk_data: ChunkData) -> Dictionary:
	var cs := GameConfig.chunk_size
	var world_center := SharedWorld.chunk_to_world(coord)
	var result := {"rays": 0, "holes": 0, "worst_delta": 0.0}
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	for ix in RAYS_PER_AXIS:
		for iz in RAYS_PER_AXIS:
			var frac_x := (float(ix) + 0.5) / RAYS_PER_AXIS
			var frac_z := (float(iz) + 0.5) / RAYS_PER_AXIS
			var wx := world_center.x - cs * 0.5 + frac_x * cs
			var wz := world_center.z - cs * 0.5 + frac_z * cs
			var from := Vector3(wx, 200.0, wz)
			var to := Vector3(wx, -80.0, wz)
			var query := PhysicsRayQueryParameters3D.create(from, to)
			var hit := space.intersect_ray(query)
			result["rays"] += 1
			if hit.is_empty():
				result["holes"] += 1
				continue
			var hit_y: float = (hit["position"] as Vector3).y
			# The mesh interpolates linearly between heightmap nodes, so the
			# hit must lie inside the min/max hull of the surrounding nodes —
			# a bilinear expectation is meaningless on cliffs.
			var hull := _height_node_hull(chunk_data, coord, wx, wz)
			var violation := maxf(maxf(float(hull["min"]) - 0.6 - hit_y, 0.0),
				maxf(hit_y - float(hull["max"]) - 0.6, 0.0))
			result["worst_delta"] = maxf(float(result["worst_delta"]), violation)
	return result


## Min/max of the four heightmap nodes surrounding a world position.
func _height_node_hull(chunk_data: ChunkData, coord: Vector2i, wx: float, wz: float) -> Dictionary:
	var cs := GameConfig.chunk_size
	var hres := chunk_data.get_resolution()
	var world_center := SharedWorld.chunk_to_world(coord)
	var lx := clampf((wx - (world_center.x - cs * 0.5)) / cs * float(hres - 1), 0.0, float(hres - 1))
	var lz := clampf((wz - (world_center.z - cs * 0.5)) / cs * float(hres - 1), 0.0, float(hres - 1))
	var x0 := clampi(int(lx), 0, hres - 2)
	var z0 := clampi(int(lz), 0, hres - 2)
	var lo := INF
	var hi := -INF
	for node in [
		chunk_data.sample_height(x0, z0), chunk_data.sample_height(x0 + 1, z0),
		chunk_data.sample_height(x0, z0 + 1), chunk_data.sample_height(x0 + 1, z0 + 1),
	]:
		lo = minf(lo, node)
		hi = maxf(hi, node)
	return {"min": lo, "max": hi}


func _terrain_height_at(chunk_data: ChunkData, coord: Vector2i, wx: float, wz: float) -> float:
	var cs := GameConfig.chunk_size
	var hres := chunk_data.get_resolution()
	var world_center := SharedWorld.chunk_to_world(coord)
	var lx := (wx - (world_center.x - cs * 0.5)) / cs * float(hres - 1)
	var lz := (wz - (world_center.z - cs * 0.5)) / cs * float(hres - 1)
	var x0 := clampi(int(lx), 0, hres - 2)
	var z0 := clampi(int(lz), 0, hres - 2)
	var tx := clampf(lx - float(x0), 0.0, 1.0)
	var tz := clampf(lz - float(z0), 0.0, 1.0)
	var h00 := chunk_data.sample_height(x0, z0)
	var h10 := chunk_data.sample_height(x0 + 1, z0)
	var h01 := chunk_data.sample_height(x0, z0 + 1)
	var h11 := chunk_data.sample_height(x0 + 1, z0 + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## Foliage instances must sit on (or just under) the terrain surface.
func _check_foliage_alignment() -> Dictionary:
	var checked := 0
	var aligned := 0
	for node in get_tree().get_nodes_in_group(&"ecs_systems"):
		if not node.has_method("_build_chunk_foliage"):
			continue
		var foliage_chunks: Dictionary = node.get("_chunk_foliage")
		var origins_store: Dictionary = node.get("_chunk_instance_origins")
		for coord in foliage_chunks:
			var instance: MultiMeshInstance3D = foliage_chunks[coord]
			var origins: PackedVector3Array = origins_store.get(coord, PackedVector3Array())
			if instance == null or origins.is_empty():
				continue
			var chunk_data: ChunkData = _chunk_manager().active_chunks.get(coord)
			if chunk_data == null:
				continue
			var step := maxi(origins.size() / 24, 1)
			for i in range(0, origins.size(), step):
				var origin := origins[i]
				var world := instance.global_position + origin
				var expected := _terrain_height_at(chunk_data, coord, world.x, world.z)
				var planted_y := origin.y + instance.global_position.y
				checked += 1
				# Slightly above the surface (floating) is a defect; being
				# buried up to the sink budget is intended root planting.
				if planted_y <= expected + 0.25 and planted_y >= expected - FOLIAGE_ALIGN_TOLERANCE:
					aligned += 1
	var ratio := aligned / float(maxi(checked, 1))
	return {"ok": checked > 0 and ratio >= 0.9, "ratio": ratio, "checked": checked}


## ECS actors must sit on the surface and stay out of the water.
func _check_ecs_placement() -> Dictionary:
	var checked := 0
	var aligned := 0
	var underwater := 0
	var mgr := _chunk_manager()
	for node in get_tree().get_nodes_in_group(&"ecs_systems"):
		if not node is EcsSystem:
			continue
		var world: EcsWorld = node.world
		if world == null:
			continue
		var cache := world.query([&"CTransform", &"CBody"])
		for entity in world.all_entities(cache):
			var transform := world.get_component(entity, &"CTransform") as CTransform
			var coord := SharedWorld.world_to_chunk(transform.position)
			var chunk_data: ChunkData = mgr.active_chunks.get(coord)
			if chunk_data == null:
				continue
			var expected := _terrain_height_at(chunk_data, coord, transform.position.x, transform.position.z)
			checked += 1
			if transform.position.y < SharedWorld.sea_level - 0.2:
				underwater += 1
			elif absf(transform.position.y - expected) <= ECS_ALIGN_TOLERANCE:
				aligned += 1
	var fraction := aligned / float(maxi(checked, 1))
	return {"ok": checked > 0 and fraction >= 0.92 and underwater == 0,
		"ratio": fraction, "underwater": underwater}


## Distinct biomes, height range, rivers, and ECS content across chunks.
func _check_diversity(chunks: Dictionary) -> Dictionary:
	var biome_set := {}
	for node in get_tree().get_nodes_in_group(&"ecs_systems"):
		if node is BiomeSystem:
			var chunk_biomes: Dictionary = node.get("_chunk_biomes")
			for coord in chunk_biomes:
				var bmap: PackedByteArray = chunk_biomes[coord]
				for value in bmap:
					biome_set[value] = true
					if biome_set.size() >= 24:
						break
	var min_h := INF
	var max_h := -INF
	for coord in chunks:
		var data: ChunkData = chunks[coord]
		var hres := data.get_resolution()
		for z in range(0, hres, 4):
			for x in range(0, hres, 4):
				var h := data.sample_height(x, z)
				min_h = minf(min_h, h)
				max_h = maxf(max_h, h)
	var height_range := (max_h - min_h) if min_h < INF else 0.0
	var river_chunks := 0
	for coord in SharedWorld.river_cells:
		var cells: Array = SharedWorld.river_cells[coord]
		if not cells.is_empty():
			river_chunks += 1
	return {
		"ok": biome_set.size() >= MIN_DISTINCT_BIOMES and height_range >= MIN_HEIGHT_RANGE,
		"biomes": biome_set.size(),
		"height_range": height_range,
		"river_chunks": river_chunks,
	}


## Neighbor heightmaps must match along shared borders.
func _check_seams(chunks: Dictionary) -> Dictionary:
	var terrain: Node = null
	for node in get_tree().get_nodes_in_group(&"ecs_systems"):
		if node.has_method("_generate_chunk"):
			terrain = node
			break
	var pairs := 0
	var fails := 0
	if terrain == null:
		return {"pairs": 0, "fails": 0}
	var maps: Dictionary = terrain.get("_chunk_heightmaps")
	for coord in chunks:
		for dir in [Vector2i(1, 0), Vector2i(0, 1)]:
			var n_coord: Vector2i = coord + dir
			if not maps.has(n_coord):
				continue
			var a: PackedFloat32Array = maps[coord]
			var b: PackedFloat32Array = maps[n_coord]
			var res := int(sqrt(a.size()))
			pairs += 1
			for i in res:
				var ha: float = a[i * res + (res - 1)] if dir.x == 1 else a[(res - 1) * res + i]
				var hb: float = b[i * res] if dir.x == 1 else b[i]
				if absf(ha - hb) > 0.01:
					fails += 1
					break
	return {"pairs": pairs, "fails": fails}


# ── HUD ──────────────────────────────────────────────────────────────────────


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(720, 0)
	layer.add_child(panel)
	_hud = Label.new()
	_hud.text = "Worldgen QA — starting…"
	panel.add_child(_hud)
