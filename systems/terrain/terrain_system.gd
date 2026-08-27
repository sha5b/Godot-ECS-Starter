class_name TerrainSystem
extends BaseSystem

const GEO_SYSTEM_SCRIPT = preload("res://systems/geo/geo_system.gd")
const TERRAIN_MATERIAL_SHADER = preload("res://systems/terrain/terrain_material.gdshader")

## Generates terrain using a 3D density field + Marching Cubes.
## Caves are carved directly into the density field using 3D noise —
## terrain and caves are ONE unified mesh.
##
## Pipeline per chunk:
## 1. Generate 2D heightmap (continent + detail + ridged noise, erosion)
## 2. Fill 3D density grid: density > 0 = solid, < 0 = air
## 3. Subtract cave noise from density (spaghetti + cheese caves)
## 4. Extract unified mesh via Marching Cubes
## 5. Derive surface heightmap for Flora/Fauna/Nav backward compat

var _detail_noise: FastNoiseLite
var _continent_noise: FastNoiseLite
var _ridged_noise: FastNoiseLite
var _warp_noise_x: FastNoiseLite
var _warp_noise_z: FastNoiseLite
var _valley_noise: FastNoiseLite
var _seafloor_detail_noise: FastNoiseLite
var _seafloor_macro_noise: FastNoiseLite
var _shoreline_noise: FastNoiseLite
var _cave_noise_a: FastNoiseLite
var _cave_noise_b: FastNoiseLite
var _cave_cheese_noise: FastNoiseLite
var _entrance_noise: FastNoiseLite
var _river_source_noise: FastNoiseLite
var _traversal_noise: FastNoiseLite

var _config: TerrainConfig
var _terrain_material: ShaderMaterial
var _geo_system
var _chunk_manager: ChunkManager

var _chunk_meshes: Dictionary = {}
var _chunk_heightmaps: Dictionary = {}
var _chunk_debug_nodes: Dictionary = {}
var _chunk_bodies: Dictionary = {}

var _mc_tri_table: Array = []


func _initialize() -> void:
	system_name = &"TerrainSystem"
	priority = 0

	_config = _find_child_of_type(TerrainConfig)
	if not _config:
		push_warning("[TerrainSystem] No TerrainConfig child found — using defaults")
		_config = TerrainConfig.new()

	_setup_noise()
	_setup_material()
	_mc_tri_table = MarchingCubesTables.get_tri_table()

	# Publish terrain params to SharedWorld so other systems don't scan the tree
	SharedWorld.sea_level = _config.sea_level
	SharedWorld.height_scale = _config.height_scale


func _register_signals() -> void:
	SystemBus.chunk_load_requested.connect(_on_chunk_load_requested)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)
	SystemBus.biome_chunk_ready.connect(_on_biome_chunk_ready)


func system_process(_delta: float) -> void:
	if not active:
		return
	_update_terrain_material_params()
	_pump_chunk_jobs()


func _get_geo_system():
	if not _geo_system:
		_geo_system = _find_system_by_type(GEO_SYSTEM_SCRIPT)
	return _geo_system


func _get_chunk_manager() -> ChunkManager:
	if not _chunk_manager:
		_chunk_manager = _find_system_by_type(ChunkManager)
	return _chunk_manager


func _setup_noise() -> void:
	_continent_noise = FastNoiseLite.new()
	_continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_continent_noise.seed = GameConfig.world_seed
	_continent_noise.frequency = _config.continent_frequency

	_detail_noise = FastNoiseLite.new()
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.seed = GameConfig.world_seed + 100
	_detail_noise.frequency = _config.noise_frequency
	_detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_detail_noise.fractal_octaves = _config.octaves
	_detail_noise.fractal_lacunarity = _config.lacunarity
	_detail_noise.fractal_gain = _config.persistence

	_ridged_noise = FastNoiseLite.new()
	_ridged_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_ridged_noise.seed = GameConfig.world_seed + 200
	_ridged_noise.frequency = _config.ridged_frequency
	_ridged_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridged_noise.fractal_octaves = _config.ridged_octaves
	_ridged_noise.fractal_lacunarity = _config.ridged_lacunarity

	_warp_noise_x = FastNoiseLite.new()
	_warp_noise_x.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise_x.seed = GameConfig.world_seed + 300
	_warp_noise_x.frequency = _config.warp_frequency

	_warp_noise_z = FastNoiseLite.new()
	_warp_noise_z.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise_z.seed = GameConfig.world_seed + 400
	_warp_noise_z.frequency = _config.warp_frequency

	_valley_noise = FastNoiseLite.new()
	_valley_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_valley_noise.seed = GameConfig.world_seed + 500
	_valley_noise.frequency = _config.valley_frequency

	_seafloor_detail_noise = FastNoiseLite.new()
	_seafloor_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_seafloor_detail_noise.seed = GameConfig.world_seed + 600
	_seafloor_detail_noise.frequency = _config.seafloor_noise_frequency
	_seafloor_detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_seafloor_detail_noise.fractal_octaves = 3
	_seafloor_detail_noise.fractal_lacunarity = 2.0
	_seafloor_detail_noise.fractal_gain = 0.5

	_seafloor_macro_noise = FastNoiseLite.new()
	_seafloor_macro_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_seafloor_macro_noise.seed = GameConfig.world_seed + 700
	_seafloor_macro_noise.frequency = _config.seafloor_macro_frequency

	_shoreline_noise = FastNoiseLite.new()
	_shoreline_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_shoreline_noise.seed = GameConfig.world_seed + 800
	_shoreline_noise.frequency = _config.shoreline_noise_frequency

	_cave_noise_a = FastNoiseLite.new()
	_cave_noise_a.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_cave_noise_a.seed = GameConfig.world_seed + 900
	_cave_noise_a.frequency = _config.cave_spaghetti_freq

	_cave_noise_b = FastNoiseLite.new()
	_cave_noise_b.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_cave_noise_b.seed = GameConfig.world_seed + 1000
	_cave_noise_b.frequency = _config.cave_spaghetti_freq * 1.3

	_cave_cheese_noise = FastNoiseLite.new()
	_cave_cheese_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_cave_cheese_noise.seed = GameConfig.world_seed + 1100
	_cave_cheese_noise.frequency = _config.cave_cheese_freq
	_cave_cheese_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_cave_cheese_noise.fractal_octaves = 2
	_cave_cheese_noise.fractal_lacunarity = 2.0
	_cave_cheese_noise.fractal_gain = 0.5

	_entrance_noise = FastNoiseLite.new()
	_entrance_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_entrance_noise.seed = GameConfig.world_seed + 1200
	_entrance_noise.frequency = _config.cave_entrance_noise_freq

	_river_source_noise = FastNoiseLite.new()
	_river_source_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_river_source_noise.seed = GameConfig.world_seed + 2000
	_river_source_noise.frequency = _config.river_source_noise_freq

	_traversal_noise = FastNoiseLite.new()
	_traversal_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_traversal_noise.seed = GameConfig.world_seed + 2100
	_traversal_noise.frequency = _config.traversal_corridor_frequency


func _setup_material() -> void:
	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = TERRAIN_MATERIAL_SHADER
	_update_terrain_material_params()


func _update_terrain_material_params() -> void:
	if not _terrain_material:
		return
	_terrain_material.set_shader_parameter("sea_level", _config.sea_level)
	_terrain_material.set_shader_parameter("height_scale", _config.height_scale)
	_terrain_material.set_shader_parameter("detail_scale", maxf(_config.noise_frequency * 6.5, 0.0001))
	_terrain_material.set_shader_parameter("detail_strength", 0.16)
	_terrain_material.set_shader_parameter("macro_detail_scale", maxf(_config.noise_frequency * 2.1, 0.0001))
	_terrain_material.set_shader_parameter("macro_detail_strength", 0.11)
	_terrain_material.set_shader_parameter("color_lift_strength", 0.06)
	_terrain_material.set_shader_parameter("triplanar_sharpness", _config.terrain_triplanar_sharpness)
	_terrain_material.set_shader_parameter("cliff_strength", 0.5)
	_terrain_material.set_shader_parameter("cliff_contrast", 2.2)
	_terrain_material.set_shader_parameter("cliff_tint", Color(0.48, 0.45, 0.40, 1.0))
	_terrain_material.set_shader_parameter("twig_strength", _config.terrain_twig_strength)
	_terrain_material.set_shader_parameter("pebble_strength", _config.terrain_pebble_strength)
	_terrain_material.set_shader_parameter("rain_amount", SharedWorld.rain_intensity)
	_terrain_material.set_shader_parameter("snow_amount", _get_seasonal_snow_amount())


func _get_seasonal_snow_amount() -> float:
	match SharedWorld.current_season:
		&"winter":
			return 0.7
		&"autumn":
			return 0.15
		&"spring":
			return 0.08
	return 0.0


# ── Threaded chunk generation ────────────────────────────────────────────────
#
# Building a chunk costs roughly 280 ms, and nearly all of it — heightmap,
# erosion, river tracing, the density field and the marching-cubes pass —
# is pure arithmetic over chunk-local data. Run synchronously it pinned the
# whole game to one chunk per frame at about 7.5 FPS while the world
# streamed in, no matter what else was switched off.
#
# So the pure part now runs on WorkerThreadPool and only the part that must
# touch the engine — creating the mesh resource, parenting nodes, building
# the collision shape, publishing globals — happens on the main thread.
# The generated terrain is bit-for-bit what it was; only WHERE the work
# happens changed.

## Chunks waiting for a worker slot.
var _gen_queue: Array[Vector2i] = []
## coord -> WorkerThreadPool task id, for jobs in flight.
var _gen_tasks: Dictionary = {}
## coord -> finished payload, written by workers under _gen_mutex.
var _gen_results: Dictionary = {}
var _gen_mutex := Mutex.new()


func _max_parallel_jobs() -> int:
	if not _config.threaded_generation:
		return 0
	return clampi(OS.get_processor_count() - 2, 1, _config.generation_max_threads)


func _on_chunk_load_requested(coord: Vector2i) -> void:
	if _chunk_meshes.has(coord) or _gen_tasks.has(coord) or _gen_queue.has(coord):
		return
	if _max_parallel_jobs() <= 0:
		_commit_chunk_payload(coord, _compute_chunk_payload(coord))
		return
	_gen_queue.append(coord)


func _on_chunk_unload_requested(coord: Vector2i) -> void:
	# Anything still in flight for this coord is now stale. The task itself
	# is left to finish and is reaped normally by _pump_chunk_jobs; only its
	# result is discarded there, via the _chunk_meshes check.
	_gen_queue.erase(coord)
	_gen_mutex.lock()
	_gen_results.erase(coord)
	_gen_mutex.unlock()
	_remove_chunk_mesh(coord)
	SystemBus.terrain_chunk_unloaded.emit(coord)


## Start queued jobs and commit finished ones, a bounded number per frame.
func _pump_chunk_jobs() -> void:
	var parallel := _max_parallel_jobs()
	if parallel <= 0:
		return
	while not _gen_queue.is_empty() and _gen_tasks.size() < parallel:
		var coord: Vector2i = _gen_queue.pop_front()
		if _chunk_meshes.has(coord):
			continue
		_gen_tasks[coord] = WorkerThreadPool.add_task(_run_chunk_job.bind(coord))

	# Drive completion off the TASK list, never off the results list.
	# Reaping only coords that produced a payload leaked a worker slot every
	# time a chunk was unloaded while its job was still in flight: the task
	# id stayed in _gen_tasks forever, and after a few of those every slot
	# was occupied by a job that would never be reaped, so streaming stopped
	# dead. Retiring the task first guarantees the slot always comes back.
	var committed := 0
	for coord in _gen_tasks.keys():
		var task_id: int = int(_gen_tasks[coord])
		if not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		_gen_tasks.erase(coord)
		_gen_mutex.lock()
		var payload: Dictionary = _gen_results.get(coord, {})
		_gen_results.erase(coord)
		_gen_mutex.unlock()
		if payload.is_empty() or _chunk_meshes.has(coord):
			continue
		if committed >= _config.generation_commits_per_frame:
			# Reaped but not yet built: hold the payload for a later frame
			# rather than dropping the work on the floor.
			_gen_mutex.lock()
			_gen_results[coord] = payload
			_gen_mutex.unlock()
			continue
		_commit_chunk_payload(coord, payload)
		committed += 1

	# Payloads whose task was already retired on an earlier frame.
	if committed < _config.generation_commits_per_frame:
		_gen_mutex.lock()
		var held: Array = _gen_results.keys()
		_gen_mutex.unlock()
		for coord in held:
			if committed >= _config.generation_commits_per_frame:
				break
			if _gen_tasks.has(coord):
				continue
			_gen_mutex.lock()
			var payload2: Dictionary = _gen_results.get(coord, {})
			_gen_results.erase(coord)
			_gen_mutex.unlock()
			if payload2.is_empty() or _chunk_meshes.has(coord):
				continue
			_commit_chunk_payload(coord, payload2)
			committed += 1


## Worker entry point. Pure computation; hands the result back under lock.
func _run_chunk_job(coord: Vector2i) -> void:
	var payload := _compute_chunk_payload(coord)
	_gen_mutex.lock()
	_gen_results[coord] = payload
	_gen_mutex.unlock()


## PURE. Everything here is arithmetic over chunk-local data: no scene tree,
## no globals, no signals. Safe to run on a generation worker.
func _compute_chunk_payload(coord: Vector2i) -> Dictionary:
	# Step 1: 2D heightmap (same noise pipeline as before)
	var heightmap := _generate_heightmap(coord)

	# Save pristine border heights before erosion — these MUST match neighbors
	var res := _config.chunk_resolution
	var border_save := _save_border_heights(heightmap, res)

	# Rivers MUST be traced on world-consistent heights: erosion is
	# chunk-local, so tracing on the eroded map makes neighbors derive
	# different sources, paths, and carved channels — visible as straight
	# cuts along chunk borders. The pristine map equals the world sampler,
	# so every chunk traces identical paths.
	var pristine_hm := heightmap.duplicate()

	if _config.erosion_iterations > 0:
		heightmap = _apply_hydraulic_erosion(heightmap)
	if _config.thermal_erosion_enabled:
		heightmap = _apply_thermal_erosion(heightmap)
	if _config.walkable_enforcement > 0.0:
		heightmap = _apply_walkability_enforcement(heightmap)

	# Step 1b: Trace rivers on the pristine map, carve beds in the eroded
	# map, then blend borders back to pristine. The final restore AFTER bed
	# erosion is what keeps river crossings seam-safe.
	var river_cells_for_chunk: Array = []
	var render_paths_for_chunk: Array = []
	if _config.rivers_enabled:
		river_cells_for_chunk = _trace_rivers_on_heightmap(
			coord, pristine_hm, render_paths_for_chunk)
		_apply_riverbed_erosion_to_heightmap(heightmap, river_cells_for_chunk,
			render_paths_for_chunk, res, float(coord.x) * GameConfig.chunk_size,
			float(coord.y) * GameConfig.chunk_size, GameConfig.chunk_size / float(res - 1), _config.sea_level)

	# Restore pristine border heights so chunk edges always match
	_restore_border_heights(heightmap, border_save, res)

	# Step 2: Build 3D density field from heightmap + cave noise + river carving
	var res_xz := _config.chunk_resolution
	var res_y := _config.vertical_resolution
	var density := _generate_density_field(coord, heightmap, res_xz, res_y, river_cells_for_chunk,
		render_paths_for_chunk)

	# Step 3: Extract surface heightmap from density (for other systems)
	var surface_hm := _extract_surface_heightmap(density, res_xz, res_y)

	# Step 4: Marching Cubes -> raw surface arrays (no Resource yet).
	var arrays := _build_marching_cubes_arrays(density, res_xz, res_y, coord,
		surface_hm, river_cells_for_chunk)

	return {
		"surface_hm": surface_hm,
		"density": density,
		"res_y": res_y,
		"arrays": arrays,
		"river_cells": river_cells_for_chunk,
		"river_paths": render_paths_for_chunk,
	}


## MAIN THREAD ONLY. Turns a computed payload into live engine objects and
## publishes the results the rest of the world reads.
func _commit_chunk_payload(coord: Vector2i, payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var surface_hm: PackedFloat32Array = payload["surface_hm"]
	var density: PackedFloat32Array = payload["density"]
	var res_y: int = int(payload["res_y"])
	var arrays: Array = payload["arrays"]

	if _config.rivers_enabled:
		SharedWorld.river_paths[coord] = payload["river_paths"]
		SharedWorld.river_cells[coord] = payload["river_cells"]
	_chunk_heightmaps[coord] = surface_hm

	var chunk_mgr := _get_chunk_manager()
	if chunk_mgr:
		var cd: ChunkData = chunk_mgr.get_chunk(coord)
		if cd:
			cd.heightmap = surface_hm
			cd.density_grid = density
			cd.density_res_y = res_y
			cd.terrain_ready = true

	var mesh := _mesh_from_arrays(arrays)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.name = "Chunk_%d_%d" % [coord.x, coord.y]

	var world_pos := SharedWorld.chunk_to_world(coord)
	mesh_instance.position = Vector3(
		world_pos.x - GameConfig.chunk_size * 0.5,
		0.0,
		world_pos.z - GameConfig.chunk_size * 0.5
	)

	mesh_instance.material_override = _terrain_material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mesh_instance)
	_chunk_meshes[coord] = mesh_instance

	# Collision straight from the surface array: the mesh is already an
	# un-indexed triangle soup, so re-extracting it with get_faces() only
	# copied it back out again.
	_create_chunk_collision_from_faces(coord, arrays[Mesh.ARRAY_VERTEX])

	if GameConfig.debug_draw_caves and _config.caves_enabled:
		_debug_draw_cave_voids(coord, density, int(sqrt(surface_hm.size())), res_y, surface_hm)

	SystemBus.terrain_chunk_ready.emit(coord, surface_hm)


# ── Heightmap generation ─────────────────────────────────────────────────────

func _generate_heightmap(coord: Vector2i) -> PackedFloat32Array:
	var res := _config.chunk_resolution
	var cs := GameConfig.chunk_size
	var heightmap := PackedFloat32Array()
	heightmap.resize(res * res)

	var origin_x := coord.x * cs
	var origin_z := coord.y * cs
	var step := cs / float(res - 1)
	var hs := _config.height_scale
	var sea := _config.sea_level

	for z in res:
		for x in res:
			var wx := origin_x + x * step
			var wz := origin_z + z * step

			var sample := _warp_sample_coords(wx, wz)
			var blended := _sample_base_terrain(sample.x, sample.y)
			blended += _sample_ridged_contribution(sample.x, sample.y, blended)

			var h := blended * hs
			h = _apply_valley_carving(h, sample.x, sample.y, sea, hs)
			h = _apply_plateau_flattening(h, sea, hs)
			h = _apply_traversal_shaping(h, wx, wz, sample.x, sample.y, sea, hs)
			h = _apply_shoreline_gradient(h, wx, wz, sea)
			h = _apply_ocean_floor(h, wx, wz, sample.x, sample.y, sea, hs)

			heightmap[z * res + x] = h

	return heightmap


## Apply domain warping to sample coordinates
func _warp_sample_coords(wx: float, wz: float) -> Vector2:
	if _config.warp_enabled:
		var sx := wx + _warp_noise_x.get_noise_2d(wx, wz) * _config.warp_strength
		var sz := wz + _warp_noise_z.get_noise_2d(wx, wz) * _config.warp_strength
		return Vector2(sx, sz)
	return Vector2(wx, wz)


## Sample continent + detail noise and blend by weight
func _sample_base_terrain(sx: float, sz: float) -> float:
	var continent := _continent_noise.get_noise_2d(sx, sz)
	var detail := _detail_noise.get_noise_2d(sx, sz)
	var cw := _config.continent_weight
	return continent * cw + detail * (1.0 - cw)


## Sample ridged multifractal and return additive contribution
func _sample_ridged_contribution(sx: float, sz: float, continent_blend: float) -> float:
	if not _config.ridged_enabled:
		return 0.0
	var ridged_raw := _ridged_noise.get_noise_2d(sx, sz)
	var ridged_01 := (ridged_raw + 1.0) * 0.5
	var ridged_shaped := pow(ridged_01, _config.ridged_power)
	var ridge_mask := clampf((continent_blend / _config.continent_weight + 0.2) * 2.0, 0.0, 1.0)
	return ridged_shaped * _config.ridged_weight * ridge_mask


## Carve valley channels using low-frequency noise
func _apply_valley_carving(h: float, sx: float, sz: float, sea: float, hs: float) -> float:
	if not _config.valley_carving_enabled:
		return h
	var valley_val := _valley_noise.get_noise_2d(sx, sz)
	var valley_mask := 1.0 - clampf(absf(valley_val) * 4.0, 0.0, 1.0)
	valley_mask *= valley_mask
	var above_sea := clampf((h - sea) / (hs * 0.5), 0.0, 1.0)
	return h - valley_mask * _config.valley_depth * hs * 0.4 * above_sea


## Flatten high-elevation areas into mesa plateaus
func _apply_plateau_flattening(h: float, sea: float, hs: float) -> float:
	if not _config.plateau_enabled:
		return h
	var h_norm := clampf((h - sea) / hs, 0.0, 1.0)
	if h_norm > _config.plateau_threshold:
		var plateau_t := clampf((h_norm - _config.plateau_threshold) / (1.0 - _config.plateau_threshold), 0.0, 1.0)
		var target_h := sea + _config.plateau_threshold * hs
		return lerpf(h, target_h, plateau_t * _config.plateau_strength)
	return h


func _apply_traversal_shaping(h: float, wx: float, wz: float,
		sx: float, sz: float, sea: float, hs: float) -> float:
	if not _config.traversal_enabled:
		return h
	if h <= sea + 1.0:
		return h
	var safe_hs := maxf(hs, 0.001)
	var h_norm := clampf((h - sea) / safe_hs, 0.0, 1.0)
	var corridor_noise := absf(_traversal_noise.get_noise_2d(wx, wz))
	var corridor_width := clampf(_config.traversal_corridor_width / maxf(GameConfig.chunk_size, 1.0), 0.12, 0.65)
	var corridor_mask := 1.0 - clampf(corridor_noise / corridor_width, 0.0, 1.0)
	corridor_mask *= corridor_mask
	var land_t := clampf((h - sea) / (safe_hs * 0.85), 0.0, 1.0)
	var corridor_target := sea + minf((h - sea) * 0.82, safe_hs * 0.42)
	h = lerpf(h, corridor_target, corridor_mask * _config.traversal_corridor_strength * land_t)
	var plateau_access_t := clampf(
		(h_norm - _config.plateau_access_threshold) / maxf(1.0 - _config.plateau_access_threshold, 0.001),
		0.0,
		1.0
	)
	if plateau_access_t > 0.0:
		var plateau_target := sea + _config.plateau_threshold * safe_hs
		h = lerpf(h, plateau_target,
			corridor_mask * plateau_access_t * _config.plateau_access_strength)
	var pass_noise := absf(_traversal_noise.get_noise_2d(wx + 431.0, wz - 217.0))
	var pass_mask := 1.0 - clampf(pass_noise / maxf(corridor_width * 0.82, 0.08), 0.0, 1.0)
	pass_mask *= pass_mask
	var ridge_val := (_ridged_noise.get_noise_2d(sx, sz) + 1.0) * 0.5
	var ridge_t := clampf((ridge_val - 0.55) / 0.45, 0.0, 1.0)
	if ridge_t > 0.0:
		h -= safe_hs * 0.10 * pass_mask * ridge_t * _config.ridge_pass_strength
	return h


## Apply smooth beach gradient with noise-broken coastline
func _apply_shoreline_gradient(h: float, wx: float, wz: float, sea: float) -> float:
	var beach_w := _config.beach_width
	if h <= sea or h >= sea + beach_w:
		return h
	var shore_noise := _shoreline_noise.get_noise_2d(wx, wz) * _config.shoreline_noise_strength
	var effective_beach := maxf(beach_w + shore_noise, 0.5)
	var t_beach := clampf((h - sea) / effective_beach, 0.0, 1.0)
	return sea + pow(t_beach, _config.beach_slope_power) * effective_beach


## Shape ocean floor with depth zones and seafloor detail noise
func _apply_ocean_floor(h: float, wx: float, wz: float, sx: float, sz: float, sea: float, hs: float) -> float:
	if _config.ocean_floor_enabled and h < sea:
		var raw_depth := sea - h
		var depth_norm := clampf(raw_depth / hs, 0.0, 1.0)
		var shore_noise := _shoreline_noise.get_noise_2d(wx, wz) * _config.shoreline_noise_strength * 0.5

		var shelf_d := _config.shelf_depth
		var slope_d := _config.slope_depth
		var abyss_d := _config.abyss_depth

		var target_depth: float
		if raw_depth < shelf_d:
			var t_shelf := clampf(raw_depth / shelf_d, 0.0, 1.0)
			target_depth = t_shelf * shelf_d * 0.7 + shore_noise * (1.0 - t_shelf)
		elif raw_depth < slope_d:
			var t_slope := clampf((raw_depth - shelf_d) / (slope_d - shelf_d), 0.0, 1.0)
			target_depth = lerpf(shelf_d * 0.7, slope_d, t_slope * t_slope)
		else:
			var t_abyss := clampf((raw_depth - slope_d) / (abyss_d - slope_d), 0.0, 1.0)
			target_depth = lerpf(slope_d, abyss_d, t_abyss)

		var sf_detail := _seafloor_detail_noise.get_noise_2d(sx, sz)
		var sf_macro := _seafloor_macro_noise.get_noise_2d(sx, sz)
		var detail_scale := clampf(depth_norm * 3.0, 0.0, 1.0)
		target_depth += sf_detail * _config.seafloor_noise_amplitude * detail_scale
		target_depth += sf_macro * _config.seafloor_macro_amplitude * detail_scale

		return sea - maxf(target_depth, 0.1)
	elif not _config.ocean_floor_enabled and _config.coastal_flattening > 0.0:
		var dist_from_sea := absf(h - sea)
		var coastal_range := hs * 0.15
		if dist_from_sea < coastal_range:
			var t := dist_from_sea / coastal_range
			return lerpf(sea, h, lerpf(t * t, t, 1.0 - _config.coastal_flattening))
	return h


# ── Border height preservation (chunk alignment) ────────────────────────────

func _save_border_heights(heightmap: PackedFloat32Array, res: int) -> Dictionary:
	# Save the whole blend band, not just the outer ring — the restore
	# blends eroded heights back toward these pristine values so chunks
	# meet smoothly instead of stepping at the erosion boundary.
	var saved := {}
	var border := maxi(_config.border_blend_cells, 2)
	for z in res:
		for x in res:
			if x < border or x >= res - border or z < border or z >= res - border:
				saved[z * res + x] = heightmap[z * res + x]
	return saved


func _restore_border_heights(heightmap: PackedFloat32Array, saved: Dictionary, res: int) -> void:
	# Smooth blend toward pristine border values: full pristine at the seam
	# (exact neighbor match), untouched erosion past the blend band.
	var blend := float(maxi(_config.border_blend_cells, 2))
	for idx: int in saved:
		var x := idx % res
		var z := idx / res
		var d := float(mini(mini(x, z), mini(res - 1 - x, res - 1 - z)))
		if d <= 1.0:
			heightmap[idx] = saved[idx]
			continue
		var w := 1.0 - (d - 1.0) / maxf(blend - 1.0, 1.0)
		w = clampf(w, 0.0, 1.0)
		w = w * w * (3.0 - 2.0 * w)  # smoothstep
		heightmap[idx] = lerpf(heightmap[idx], saved[idx], w)


# ── Hydraulic erosion ─────────────────────────────────────────────────────────

func _apply_hydraulic_erosion(heightmap: PackedFloat32Array) -> PackedFloat32Array:
	var res := _config.chunk_resolution
	var rng := RandomNumberGenerator.new()
	rng.seed = GameConfig.world_seed + 5000
	var border := 2  # Protect edge vertices for chunk alignment

	for _iter in _config.erosion_iterations:
		var px := rng.randf() * (res - 2 * border) + float(border)
		var pz := rng.randf() * (res - 2 * border) + float(border)
		var dir_x := 0.0
		var dir_z := 0.0
		var speed := 1.0
		var water := 1.0
		var sediment := 0.0

		for _step in _config.erosion_max_lifetime:
			var ix := int(px)
			var iz := int(pz)
			if ix < border or ix >= res - border or iz < border or iz >= res - border:
				break

			# Calculate gradient using bilinear neighbors
			var idx := iz * res + ix
			var h := heightmap[idx]
			var h_right := heightmap[idx + 1] if ix + 1 < res else h
			var h_down := heightmap[(iz + 1) * res + ix] if iz + 1 < res else h
			var grad_x := h_right - h
			var grad_z := h_down - h

			# Apply inertia to direction
			dir_x = dir_x * _config.erosion_inertia - grad_x * (1.0 - _config.erosion_inertia)
			dir_z = dir_z * _config.erosion_inertia - grad_z * (1.0 - _config.erosion_inertia)

			# Normalize direction
			var dir_len := sqrt(dir_x * dir_x + dir_z * dir_z)
			if dir_len < 0.0001:
				dir_x = rng.randf_range(-1.0, 1.0)
				dir_z = rng.randf_range(-1.0, 1.0)
				dir_len = sqrt(dir_x * dir_x + dir_z * dir_z)
			dir_x /= dir_len
			dir_z /= dir_len

			# Move droplet
			var new_px := px + dir_x
			var new_pz := pz + dir_z

			var new_ix := int(new_px)
			var new_iz := int(new_pz)
			if new_ix < border or new_ix >= res - border or new_iz < border or new_iz >= res - border:
				break

			var new_h := heightmap[new_iz * res + new_ix]
			var delta_h := new_h - h

			# Calculate sediment capacity
			var capacity := maxf(-delta_h, 0.01) * speed * water * _config.erosion_capacity

			if sediment > capacity or delta_h > 0.0:
				# Deposit sediment
				var deposit := 0.0
				if delta_h > 0.0:
					deposit = minf(sediment, delta_h)
				else:
					deposit = (sediment - capacity) * _config.erosion_deposition
				sediment -= deposit
				heightmap[idx] += deposit
			else:
				# Erode terrain
				var erode := minf((capacity - sediment) * _config.erosion_erosion_rate, -delta_h)
				sediment += erode
				heightmap[idx] -= erode

			# Update speed and water
			speed = sqrt(maxf(speed * speed + delta_h, 0.01))
			water *= (1.0 - _config.erosion_evaporation)
			if water < 0.001:
				break

			px = new_px
			pz = new_pz

	return heightmap


# ── Thermal erosion ───────────────────────────────────────────────────────────

func _apply_thermal_erosion(heightmap: PackedFloat32Array) -> PackedFloat32Array:
	var res := _config.chunk_resolution
	var cs := GameConfig.chunk_size
	var cell_size := cs / float(res - 1)
	var max_diff := tan(deg_to_rad(_config.thermal_max_slope)) * cell_size

	var border := 2  # Protect edge vertices for chunk alignment
	for _pass in _config.thermal_iterations:
		for z in range(border, res - border):
			for x in range(border, res - border):
				var idx := z * res + x
				var h := heightmap[idx]

				# Check 4 neighbors
				var neighbors := [idx - 1, idx + 1, idx - res, idx + res]
				var total_excess := 0.0
				var excess_list: Array[float] = []

				for n_idx in neighbors:
					var diff := h - heightmap[n_idx]
					if diff > max_diff:
						var excess := diff - max_diff
						excess_list.append(excess)
						total_excess += excess
					else:
						excess_list.append(0.0)

				if total_excess > 0.0:
					var move := total_excess * 0.5
					heightmap[idx] -= move
					for i in neighbors.size():
						if excess_list[i] > 0.0:
							heightmap[neighbors[i]] += move * (excess_list[i] / total_excess)

	return heightmap


# ── Walkability enforcement ──────────────────────────────────────────────

func _apply_walkability_enforcement(heightmap: PackedFloat32Array) -> PackedFloat32Array:
	var res := _config.chunk_resolution
	var cs := GameConfig.chunk_size
	var cell_size := cs / float(res - 1)
	var max_diff := tan(deg_to_rad(_config.max_walkable_slope)) * cell_size
	var enforcement := _config.walkable_enforcement

	var border := 2  # Protect edge vertices for chunk alignment
	for _pass in 3:
		for z in range(border, res - border):
			for x in range(border, res - border):
				var idx := z * res + x
				var h := heightmap[idx]

				var neighbors := [idx - 1, idx + 1, idx - res, idx + res]
				var total_excess := 0.0
				var excess_list: Array[float] = []

				for n_idx in neighbors:
					var diff := absf(h - heightmap[n_idx])
					if diff > max_diff:
						excess_list.append(diff - max_diff)
						total_excess += diff - max_diff
					else:
						excess_list.append(0.0)

				if total_excess > 0.0:
					# Only enforce on a fraction of cells (preserves cliffs elsewhere)
					var move := total_excess * 0.25 * enforcement
					heightmap[idx] -= move * signf(h - heightmap[neighbors[0]])
					for i in neighbors.size():
						if excess_list[i] > 0.0:
							var share := excess_list[i] / total_excess
							var n_h := heightmap[neighbors[i]]
							heightmap[neighbors[i]] = lerpf(n_h, h, share * enforcement * 0.15)

	return heightmap


# ── 3D Density field ────────────────────────────────────────────────────────

func _generate_density_field(coord: Vector2i, heightmap: PackedFloat32Array,
		res_xz: int, res_y: int, river_cells: Array = [], render_paths: Array = []) -> PackedFloat32Array:
	var cs := GameConfig.chunk_size
	var origin_x: float = coord.x * cs
	var origin_z: float = coord.y * cs
	var step_xz := cs / float(res_xz - 1)
	var min_y := _config.grid_min_y
	var step_y := (_config.grid_max_y - min_y) / float(res_y - 1)

	var grid := PackedFloat32Array()
	grid.resize(res_y * res_xz * res_xz)

	var caves_on := _config.caves_enabled
	var spag_thresh := _config.cave_spaghetti_threshold
	var cheese_thresh := _config.cave_cheese_threshold
	var cave_min_d := _config.cave_min_depth
	var cave_max_d := _config.cave_max_depth
	var sea := _config.sea_level
	var spag_sq := spag_thresh * spag_thresh
	var ramp := _config.cave_depth_ramp
	var spag_str := _config.cave_spaghetti_strength
	var cheese_str := _config.cave_cheese_strength

	for gy in res_y:
		var world_y := min_y + float(gy) * step_y
		var layer_offset := gy * res_xz * res_xz
		for gz in res_xz:
			for gx in res_xz:
				var surface_h := heightmap[gz * res_xz + gx]
				var density := surface_h - world_y

				if caves_on:
					var wx := origin_x + float(gx) * step_xz
					var wz := origin_z + float(gz) * step_xz
					density = _apply_cave_carving_to_density(surface_h, density, wx, world_y, wz,
						sea, cave_min_d, cave_max_d, ramp, spag_sq, spag_str, cheese_thresh, cheese_str)

				grid[layer_offset + gz * res_xz + gx] = density

	# C3: Carve entrances from surface down to cave voids
	if caves_on and _config.cave_entrances_enabled:
		_carve_cave_entrances(grid, heightmap, res_xz, res_y, origin_x, origin_z, step_xz, step_y, min_y)

	# R1: Carve river channels into the density field
	if not river_cells.is_empty():
		_carve_river_channels(grid, heightmap, river_cells, render_paths, res_xz, res_y,
			origin_x, origin_z, step_xz, step_y, min_y, sea)

	return grid


# ── Cave entrance carving ────────────────────────────────────────────────────

func _carve_cave_entrances(grid: PackedFloat32Array, heightmap: PackedFloat32Array,
		res_xz: int, res_y: int, origin_x: float, origin_z: float,
		step_xz: float, step_y: float, min_y: float) -> void:
	var cave_regions := _collect_cave_regions(grid, heightmap, res_xz, res_y, step_y, min_y)
	for region in cave_regions:
		if int(region.get("size", 0)) < _config.cave_min_region_voxels:
			continue
		var entrance := _select_cave_entrance_candidate(region, heightmap, res_xz,
			origin_x, origin_z, step_xz, step_y, min_y)
		if entrance.is_empty():
			continue
		_carve_cave_entrance_funnel(grid, heightmap, res_xz, res_y, step_xz, step_y, min_y,
			entrance)


func _collect_cave_regions(grid: PackedFloat32Array, heightmap: PackedFloat32Array,
		res_xz: int, res_y: int, step_y: float, min_y: float) -> Array:
	var iso := _config.surface_threshold
	var ss := res_xz * res_xz
	var visited := PackedByteArray()
	visited.resize(grid.size())
	var regions: Array = []
	var neighbor_offsets := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	for gy in range(1, res_y - 1):
		var world_y := min_y + float(gy) * step_y
		for gz in range(1, res_xz - 1):
			for gx in range(1, res_xz - 1):
				var idx := gy * ss + gz * res_xz + gx
				if visited[idx] != 0:
					continue
				visited[idx] = 1
				if grid[idx] >= iso:
					continue
				var surface_h := heightmap[gz * res_xz + gx]
				if surface_h - world_y < _config.cave_min_depth * 0.55:
					continue
				var queue: Array[Vector3i] = [Vector3i(gx, gy, gz)]
				var cells: Array[Vector3i] = []
				while not queue.is_empty():
					var current: Vector3i = queue.pop_front()
					cells.append(current)
					for offset in neighbor_offsets:
						var nx: int = current.x + offset.x
						var ny: int = current.y + offset.y
						var nz: int = current.z + offset.z
						if nx <= 0 or nx >= res_xz - 1 or nz <= 0 or nz >= res_xz - 1:
							continue
						if ny <= 0 or ny >= res_y - 1:
							continue
						var nidx: int = ny * ss + nz * res_xz + nx
						if visited[nidx] != 0:
							continue
						visited[nidx] = 1
						if grid[nidx] >= iso:
							continue
						var neighbor_surface := heightmap[nz * res_xz + nx]
						var neighbor_y := min_y + float(ny) * step_y
						if neighbor_surface - neighbor_y < _config.cave_min_depth * 0.20:
							continue
						queue.append(Vector3i(nx, ny, nz))
				if cells.size() >= _config.cave_min_region_voxels:
					regions.append({
						"size": cells.size(),
						"cells": cells,
					})
	return regions


func _select_cave_entrance_candidate(region: Dictionary, heightmap: PackedFloat32Array,
		res_xz: int, origin_x: float, origin_z: float, step_xz: float,
		step_y: float, min_y: float) -> Dictionary:
	var best_score := -INF
	var best_candidate := {}
	var preferred_slope := _config.cave_entrance_preferred_slope
	# Cave regions are flood-filled per chunk, so a cave crossing a border
	# becomes two partial regions and each side picks its own entrance.
	# Funnel carves near the seam would exist on one side only and tear the
	# surface open along the chunk border — keep entrances (and their funnels)
	# safely inside the chunk.
	var entrance_margin := ceili(_config.cave_entrance_radius / maxf(step_xz, 0.1)) + 2
	var cells: Array[Vector3i] = region.get("cells", [])
	for cell in cells:
		var gx := cell.x
		var gy := cell.y
		var gz := cell.z
		if gx < entrance_margin or gz < entrance_margin \
				or gx >= res_xz - entrance_margin or gz >= res_xz - entrance_margin:
			continue
		var surface_h := heightmap[gz * res_xz + gx]
		var cave_y := min_y + float(gy) * step_y
		var depth_below := surface_h - cave_y
		if depth_below < _config.cave_min_depth * 0.5:
			continue
		if depth_below > _config.cave_max_depth:
			continue
		var wx := origin_x + float(gx) * step_xz
		var wz := origin_z + float(gz) * step_xz
		var slope := _surface_slope_degrees(heightmap, res_xz, gx, gz, step_xz)
		var gentle_slope_score := 1.0 - clampf(absf(slope - preferred_slope) / maxf(preferred_slope + 18.0, 1.0), 0.0, 1.0)
		var cliff_slope_score := clampf((slope - preferred_slope) / maxf(78.0 - preferred_slope, 1.0), 0.0, 1.0)
		var slope_score := maxf(gentle_slope_score * 0.82, cliff_slope_score)
		var depth_score := 1.0 - clampf(
			(depth_below - _config.cave_min_depth) / maxf(_config.cave_max_depth - _config.cave_min_depth, 1.0),
			0.0,
			1.0
		)
		var noise_val := (_entrance_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
		var cliff_bonus := clampf((slope - preferred_slope) / 32.0, 0.0, 1.0)
		var opening_mode := "top"
		var mouth_gx := gx
		var mouth_gz := gz
		var mouth_surface_y := surface_h
		var opening_score := 0.0
		var side_outlet := _find_cave_side_outlet(heightmap, res_xz, gx, gz, cave_y,
			origin_x, origin_z, step_xz)
		if not side_outlet.is_empty():
			opening_mode = "side"
			mouth_gx = int(side_outlet.get("gx", gx))
			mouth_gz = int(side_outlet.get("gz", gz))
			mouth_surface_y = float(side_outlet.get("surface_y", surface_h))
			opening_score = float(side_outlet.get("score", 0.0))
		var score := depth_score * 0.45 + slope_score * 0.18 + noise_val * 0.12 + cliff_bonus * 0.05 + opening_score * 0.28
		if opening_mode == "side":
			score += 0.10 + cliff_slope_score * 0.08
		elif noise_val >= _config.cave_entrance_threshold:
			score += 0.08
		if score > best_score:
			best_score = score
			best_candidate = {
				"gx": gx,
				"gz": gz,
				"cave_y": cave_y + step_y * 0.75,
				"mouth_gx": mouth_gx,
				"mouth_gz": mouth_gz,
				"mouth_surface_y": mouth_surface_y,
				"opening_mode": opening_mode,
			}
	return best_candidate


func _find_cave_side_outlet(heightmap: PackedFloat32Array, res_xz: int,
		gx: int, gz: int, cave_y: float, origin_x: float, origin_z: float,
		step_xz: float) -> Dictionary:
	var best_score := -INF
	var best_outlet := {}
	var preferred_slope := _config.cave_entrance_preferred_slope
	var floor_clearance := maxf(_config.cave_entrance_floor_clearance, step_xz * 0.45)
	var clearance_target := floor_clearance * 1.1
	var max_clearance := maxf(_config.cave_entrance_radius * 2.6, floor_clearance * 2.4)
	var search_cells := maxi(int(ceili(maxf(_config.cave_entrance_radius * 2.2, step_xz * 3.0) / maxf(step_xz, 0.001))), 2)
	# Same seam-safety margin as candidate selection: a mouth near the
	# chunk edge would let its funnel carve the shared border column.
	var outlet_margin := ceili(_config.cave_entrance_radius / maxf(step_xz, 0.1)) + 2
	var directions := [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	for dir in directions:
		for dist in range(1, search_cells + 1):
			var mouth_gx: int = gx + dir.x * dist
			var mouth_gz: int = gz + dir.y * dist
			if mouth_gx < outlet_margin or mouth_gx >= res_xz - outlet_margin \
					or mouth_gz < outlet_margin or mouth_gz >= res_xz - outlet_margin:
				break
			var surface_h := heightmap[mouth_gz * res_xz + mouth_gx]
			var clearance := surface_h - cave_y
			if clearance < step_xz * 0.25:
				continue
			if clearance > max_clearance:
				continue
			var slope := _surface_slope_degrees(heightmap, res_xz, mouth_gx, mouth_gz, step_xz)
			var slope_score := clampf((slope - preferred_slope) / maxf(78.0 - preferred_slope, 1.0), 0.0, 1.0)
			var clearance_score := 1.0 - clampf(absf(clearance - clearance_target) / maxf(_config.cave_entrance_radius * 1.5, 1.0), 0.0, 1.0)
			var dist_score := 1.0 - clampf((float(dist) - 1.0) / maxf(float(search_cells - 1), 1.0), 0.0, 1.0)
			var wx := origin_x + float(mouth_gx) * step_xz
			var wz := origin_z + float(mouth_gz) * step_xz
			var noise_val := (_entrance_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
			var score := slope_score * 0.42 + clearance_score * 0.34 + dist_score * 0.14 + noise_val * 0.10
			if surface_h <= cave_y + clearance_target * 1.35:
				score += 0.10
			if slope >= preferred_slope + 10.0:
				score += 0.08
			if score > best_score:
				best_score = score
				best_outlet = {
					"gx": mouth_gx,
					"gz": mouth_gz,
					"surface_y": surface_h,
					"score": score,
				}
	if best_score < 0.45:
		return {}
	return best_outlet


func _carve_cave_entrance_funnel(grid: PackedFloat32Array, heightmap: PackedFloat32Array,
		res_xz: int, res_y: int, step_xz: float, step_y: float,
		min_y: float, entrance: Dictionary) -> void:
	var ss := res_xz * res_xz
	var entrance_radius := _config.cave_entrance_radius
	var entrance_slope := _config.cave_entrance_slope
	var iso := _config.surface_threshold
	var cx := int(entrance.get("gx", -1))
	var cz := int(entrance.get("gz", -1))
	var mouth_gx := int(entrance.get("mouth_gx", cx))
	var mouth_gz := int(entrance.get("mouth_gz", cz))
	var target_y := float(entrance.get("cave_y", min_y))
	if cx < 0 or cz < 0 or mouth_gx < 0 or mouth_gz < 0:
		return
	var mouth_surface_y := float(entrance.get("mouth_surface_y", heightmap[mouth_gz * res_xz + mouth_gx]))
	var opening_mode := String(entrance.get("opening_mode", "top"))
	var mouth_clearance := maxf(_config.cave_entrance_floor_clearance, step_y * 1.75)
	var mouth_y := minf(
		mouth_surface_y - mouth_clearance * (0.28 if opening_mode == "side" else 0.16),
		target_y + mouth_clearance
	)
	mouth_y = clampf(mouth_y, target_y + step_y * 0.55, mouth_surface_y - step_y * 0.35)
	var cave_local := Vector3(float(cx) * step_xz, target_y, float(cz) * step_xz)
	var mouth_local := Vector3(float(mouth_gx) * step_xz, mouth_y, float(mouth_gz) * step_xz)
	var mouth_radius := entrance_radius * (1.18 if opening_mode == "side" else 0.96)
	var max_radius := maxf(entrance_radius, mouth_radius)
	var gx_min := clampi(int(floor((minf(cave_local.x, mouth_local.x) - max_radius - step_xz) / maxf(step_xz, 0.001))), 0, res_xz - 1)
	var gx_max := clampi(int(ceili((maxf(cave_local.x, mouth_local.x) + max_radius + step_xz) / maxf(step_xz, 0.001))), 0, res_xz - 1)
	var gz_min := clampi(int(floor((minf(cave_local.z, mouth_local.z) - max_radius - step_xz) / maxf(step_xz, 0.001))), 0, res_xz - 1)
	var gz_max := clampi(int(ceili((maxf(cave_local.z, mouth_local.z) + max_radius + step_xz) / maxf(step_xz, 0.001))), 0, res_xz - 1)
	var gy_min := clampi(int(floor((minf(target_y, mouth_y) - max_radius - min_y) / maxf(step_y, 0.001))), 0, res_y - 1)
	var gy_max := clampi(int(ceili((maxf(target_y, mouth_surface_y) + step_y - min_y) / maxf(step_y, 0.001))), 0, res_y - 1)
	for gz in range(gz_min, gz_max + 1):
		for gx in range(gx_min, gx_max + 1):
			var col_surface := heightmap[gz * res_xz + gx]
			for gy in range(gy_min, gy_max + 1):
				var world_y := min_y + float(gy) * step_y
				if world_y > col_surface + step_y * 0.15:
					continue
				var voxel_local := Vector3(float(gx) * step_xz, world_y, float(gz) * step_xz)
				var seg_t := _segment_closest_t(voxel_local, mouth_local, cave_local)
				var closest := mouth_local.lerp(cave_local, seg_t)
				var offset := voxel_local - closest
				offset.y *= lerpf(1.10, 0.92, seg_t)
				var tunnel_radius := entrance_radius * lerpf(1.0 if opening_mode == "side" else 0.95, 0.62, seg_t)
				var idx := gy * ss + gz * res_xz + gx
				var tunnel_dist := offset.length()
				if tunnel_dist <= tunnel_radius:
					var radial := 1.0 - clampf(tunnel_dist / maxf(tunnel_radius, 0.001), 0.0, 1.0)
					radial = pow(radial, 1.18)
					var carve_amount := (1.25 + seg_t * 1.85) * radial * entrance_slope
					if opening_mode == "side":
						carve_amount *= lerpf(1.22, 1.0, seg_t)
					grid[idx] -= carve_amount
					var forced_density := lerpf(iso - 0.10, -1.15, radial * lerpf(1.0, 0.82, seg_t))
					grid[idx] = minf(grid[idx], forced_density)
				var mouth_offset := voxel_local - mouth_local
				mouth_offset.y *= 0.92
				var mouth_dist := mouth_offset.length()
				if mouth_dist <= mouth_radius and world_y <= mouth_surface_y:
					var mouth_t := 1.0 - clampf(mouth_dist / maxf(mouth_radius, 0.001), 0.0, 1.0)
					mouth_t = pow(mouth_t, 1.1)
					if opening_mode == "side":
						mouth_t *= clampf((mouth_surface_y - world_y + step_y * 0.5) / maxf(mouth_clearance * 1.2, step_y), 0.0, 1.0)
					var mouth_density := lerpf(iso - 0.08, -1.22, clampf(mouth_t, 0.0, 1.0))
					grid[idx] = minf(grid[idx], mouth_density)


func _segment_closest_t(point: Vector3, seg_a: Vector3, seg_b: Vector3) -> float:
	var segment := seg_b - seg_a
	var seg_len_sq := segment.length_squared()
	if seg_len_sq <= 0.0001:
		return 0.0
	return clampf((point - seg_a).dot(segment) / seg_len_sq, 0.0, 1.0)


# ── River tracing on heightmap ───────────────────────────────────────────────

## Fills `out_render_paths` with this chunk's river render paths and returns
## its river cells. Publishing to SharedWorld is the CALLER's job — this runs
## on a generation worker thread, where touching a global dictionary would
## race the main thread.
func _trace_rivers_on_heightmap(coord: Vector2i, heightmap: PackedFloat32Array,
		out_render_paths: Array) -> Array:
	var res := _config.chunk_resolution
	var cs: float = GameConfig.chunk_size
	var origin_x := float(coord.x) * cs
	var origin_z := float(coord.y) * cs
	var step := cs / float(res - 1)
	var sea := _config.sea_level
	var min_h := sea + _config.river_source_min_height
	var threshold := _config.river_source_threshold
	var max_sources := _config.river_max_sources
	var search_radius := _config.river_source_search_radius_chunks
	var sample_step := maxi(int(res / 8.0), 1)
	var sources: Array = []
	var geo_system = _get_geo_system()

	for chunk_dz in range(-search_radius, search_radius + 1):
		for chunk_dx in range(-search_radius, search_radius + 1):
			var sample_origin_x := float(coord.x + chunk_dx) * cs
			var sample_origin_z := float(coord.y + chunk_dz) * cs
			for gz in range(0, res, sample_step):
				for gx in range(0, res, sample_step):
					var wx := sample_origin_x + float(gx) * step
					var wz := sample_origin_z + float(gz) * step
					var h := _sample_height_hybrid(wx, wz, heightmap, res, origin_x, origin_z, step, cs, origin_x + cs, origin_z + cs)
					if h < min_h:
						continue
					var slope_degrees := _sample_world_slope_degrees(wx, wz, step)
					var local_noise := (_river_source_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
					var source_score := local_noise
					if geo_system and geo_system.has_method("get_river_source_score"):
						source_score = geo_system.get_river_source_score(
							wx,
							wz,
							h,
							sea,
							slope_degrees,
							local_noise
						)
					var cliff_source_t := clampf((slope_degrees - 24.0) / 24.0, 0.0, 1.0)
					source_score *= lerpf(1.0, 0.18, cliff_source_t)
					if source_score > threshold:
						sources.append({
							"world_x": wx,
							"world_z": wz,
							"height": h,
							"slope_degrees": slope_degrees,
							"source_score": source_score,
							"dist2": chunk_dx * chunk_dx + chunk_dz * chunk_dz,
						})

	sources.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a.get("source_score", 0.0)), float(b.get("source_score", 0.0))):
			return float(a.get("source_score", 0.0)) > float(b.get("source_score", 0.0))
		if not is_equal_approx(float(a["height"]), float(b["height"])):
			return float(a["height"]) > float(b["height"])
		return int(a["dist2"]) < int(b["dist2"])
	)

	var filtered_sources: Array = []
	var min_source_dist := maxf(cs * 0.85, _config.river_width_end * 14.0)
	var min_source_dist_sq := min_source_dist * min_source_dist
	var candidate_limit := maxi(max_sources * 6, 6)
	for source in sources:
		var keep := true
		for chosen in filtered_sources:
			var dx := float(source.get("world_x", 0.0)) - float(chosen.get("world_x", 0.0))
			var dz := float(source.get("world_z", 0.0)) - float(chosen.get("world_z", 0.0))
			if dx * dx + dz * dz < min_source_dist_sq:
				keep = false
				break
		if not keep:
			continue
		filtered_sources.append(source)
		if filtered_sources.size() >= candidate_limit:
			break
	sources = filtered_sources

	var river_cell_map: Dictionary = {}
	var render_paths_for_chunk: Array = []
	var accepted_sources := 0
	for source in sources:
		var start := Vector3(float(source["world_x"]), float(source["height"]), float(source["world_z"]))
		var path := _trace_single_river(start, heightmap, res, origin_x, origin_z, step, sea)
		if path.size() < 2:
			continue
		var end_pt: Vector3 = path[path.size() - 1]
		if end_pt.y > sea + step:
			continue
		var render_path := _build_local_render_path(path, origin_x, origin_z, cs, step, sea)
		if render_path.size() >= 2:
			render_paths_for_chunk.append(render_path)
		_accumulate_river_cells(path, river_cell_map, heightmap, res, origin_x, origin_z, step, sea)
		accepted_sources += 1
		if accepted_sources >= max_sources:
			break

	_finalize_river_cells(river_cell_map)
	var river_cells := river_cell_map.values()
	river_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["index"]) < int(b["index"]))
	out_render_paths.assign(render_paths_for_chunk)
	return river_cells


func _apply_riverbed_erosion_to_heightmap(heightmap: PackedFloat32Array,
		river_cells: Array, render_paths: Array, res: int,
		origin_x: float, origin_z: float, step: float, sea: float) -> void:
	if render_paths.is_empty() or heightmap.is_empty():
		return
	var width_start := _config.river_width_start
	var width_end := _config.river_width_end
	var carve_depth := maxf(_config.river_carve_depth, step * 0.75)
	var bank_width_multiplier := maxf(_config.river_bank_width_multiplier, 1.0)
	var valley_width_multiplier := minf(maxf(_config.river_valley_width_multiplier, bank_width_multiplier), 2.2)
	var falloff_exp := maxf(_config.river_carve_falloff, 1.0)
	var chunk_end_x := origin_x + GameConfig.chunk_size
	var chunk_end_z := origin_z + GameConfig.chunk_size
	for render_path in render_paths:
		var dense_path := _resample_river_path_for_carve(render_path, step * 0.5)
		if dense_path.size() < 2:
			continue
		for i in range(dense_path.size() - 1):
			var a: Dictionary = dense_path[i]
			var b: Dictionary = dense_path[i + 1]
			var ax := float(a.get("world_x", 0.0))
			var az := float(a.get("world_z", 0.0))
			var bx := float(b.get("world_x", ax))
			var bz := float(b.get("world_z", az))
			var seg_vec := Vector2(bx - ax, bz - az)
			var seg_len_sq := maxf(seg_vec.length_squared(), 0.0001)
			var half_w_a := maxf(float(a.get("half_width", width_start)), width_start)
			var half_w_b := maxf(float(b.get("half_width", width_start)), width_start)
			var seg_half_w := maxf(half_w_a, half_w_b)
			var core_half_width := maxf(seg_half_w * 0.85, step * 0.75)
			var bank_half_width := maxf(seg_half_w * bank_width_multiplier + step * 0.55, core_half_width + step * 0.75)
			var valley_half_width := maxf(seg_half_w * valley_width_multiplier + step * 1.25, bank_half_width + step)
			var min_x := minf(ax, bx) - valley_half_width
			var max_x := maxf(ax, bx) + valley_half_width
			var min_z := minf(az, bz) - valley_half_width
			var max_z := maxf(az, bz) + valley_half_width
			var gx_min := maxi(0, int(floor((min_x - origin_x) / step)))
			var gx_max := mini(res - 1, int(ceili((max_x - origin_x) / step)))
			var gz_min := maxi(0, int(floor((min_z - origin_z) / step)))
			var gz_max := mini(res - 1, int(ceili((max_z - origin_z) / step)))
			for gz in range(gz_min, gz_max + 1):
				for gx in range(gx_min, gx_max + 1):
					var wx := origin_x + float(gx) * step
					var wz := origin_z + float(gz) * step
					var point_vec := Vector2(wx - ax, wz - az)
					var seg_t := clampf(point_vec.dot(seg_vec) / seg_len_sq, 0.0, 1.0)
					var closest_x := lerpf(ax, bx, seg_t)
					var closest_z := lerpf(az, bz, seg_t)
					if closest_x < origin_x or closest_x > chunk_end_x or closest_z < origin_z or closest_z > chunk_end_z:
						continue
					var dist_xz := Vector2(wx - closest_x, wz - closest_z).length()
					if dist_xz > valley_half_width:
						continue
					var idx := gz * res + gx
					var surface_h := heightmap[idx]
					var river_t := lerpf(float(a.get("river_t", 0.0)), float(b.get("river_t", 0.0)), seg_t)
					var width_t := clampf((maxf(half_w_a, half_w_b) - width_start) / maxf(width_end - width_start, 0.001), 0.0, 1.0)
					var slope_degrees := _surface_slope_degrees(heightmap, res, gx, gz, step)
					var cliff_t := clampf((slope_degrees - (_config.river_cliff_protection_slope - 8.0)) / maxf(85.0 - (_config.river_cliff_protection_slope - 8.0), 0.001), 0.0, 1.0)
					var bed_depth := carve_depth * lerpf(0.65, 1.12, maxf(river_t, width_t))
					bed_depth *= lerpf(1.0, 0.34, cliff_t)
					var target_h := surface_h
					if dist_xz <= core_half_width:
						var core_t := 1.0 - clampf(dist_xz / maxf(core_half_width, 0.001), 0.0, 1.0)
						core_t = pow(core_t, maxf(falloff_exp * 0.72, 1.0))
						target_h = minf(target_h, surface_h - bed_depth * (0.40 + 0.60 * core_t))
					elif dist_xz <= bank_half_width:
						var bank_t := 1.0 - clampf((dist_xz - core_half_width) / maxf(bank_half_width - core_half_width, 0.001), 0.0, 1.0)
						bank_t = pow(bank_t, maxf(falloff_exp * 0.95, 1.0))
						target_h = minf(target_h, surface_h - bed_depth * 0.34 * bank_t)
					else:
						var valley_t := 1.0 - clampf((dist_xz - bank_half_width) / maxf(valley_half_width - bank_half_width, 0.001), 0.0, 1.0)
						valley_t = pow(maxf(valley_t, 0.0), 1.15)
						target_h = minf(target_h, surface_h - bed_depth * 0.12 * valley_t)
					var edge_fade_x := clampf(minf(wx - origin_x, chunk_end_x - wx) / maxf(step * 2.0, 0.001), 0.0, 1.0)
					var edge_fade_z := clampf(minf(wz - origin_z, chunk_end_z - wz) / maxf(step * 2.0, 0.001), 0.0, 1.0)
					heightmap[idx] = lerpf(surface_h, target_h, minf(edge_fade_x, edge_fade_z))
	for river_cell in river_cells:
		var gx := int(river_cell.get("gx", -1))
		var gz := int(river_cell.get("gz", -1))
		if gx < 0 or gx >= res or gz < 0 or gz >= res:
			continue
		var idx := gz * res + gx
		var new_surface_y := heightmap[idx]
		river_cell["surface_y"] = new_surface_y
		river_cell["water_level"] = maxf(new_surface_y + 0.06, sea)
	for render_path in render_paths:
		for point in render_path:
			var wx := float(point.get("world_x", origin_x))
			var wz := float(point.get("world_z", origin_z))
			if wx < origin_x or wx > chunk_end_x or wz < origin_z or wz > chunk_end_z:
				continue
			point["surface_y"] = _sample_heightmap_bilinear(heightmap, res, wx - origin_x, wz - origin_z, step)


func _trace_single_river(start: Vector3, heightmap: PackedFloat32Array,
		res: int, origin_x: float, origin_z: float, step: float,
		sea: float) -> Array[Vector3]:
	var snapped_start := _snap_to_grid(start, origin_x, origin_z, step, res)
	snapped_start.y = _sample_height_hybrid(snapped_start.x, snapped_start.z,
		heightmap, res, origin_x, origin_z, step,
		GameConfig.chunk_size, origin_x + GameConfig.chunk_size, origin_z + GameConfig.chunk_size)
	var path: Array[Vector3] = [snapped_start]
	var pos := snapped_start
	var max_steps := _config.river_max_steps
	var cs: float = GameConfig.chunk_size
	var chunk_end_x := origin_x + cs
	var chunk_end_z := origin_z + cs
	var visited := {
		_river_visit_key(pos.x, pos.z, step): true,
	}

	for _i in max_steps:
		if pos.y <= sea + step:
			break
		var next := _find_lowest_river_neighbor(pos, heightmap, res, origin_x, origin_z, step, cs, chunk_end_x, chunk_end_z)
		if next.is_empty():
			break
		var next_pos: Vector3 = next["pos"]
		next_pos = _snap_to_grid(next_pos, origin_x, origin_z, step, res)
		next_pos.y = _sample_height_hybrid(next_pos.x, next_pos.z,
			heightmap, res, origin_x, origin_z, step, cs, chunk_end_x, chunk_end_z)
		if next_pos.y > pos.y + 0.05:
			break
		var visit_key := _river_visit_key(next_pos.x, next_pos.z, step)
		if visited.has(visit_key):
			break
		visited[visit_key] = true
		pos = next_pos
		path.append(pos)

	return path


func _build_local_render_path(path: Array[Vector3], origin_x: float, origin_z: float,
		cs: float, step: float, sea: float) -> Array:
	var total_drop := maxf(path[0].y - sea, 1.0)
	var local_points: Array = []
	var seen := {}
	var width_start := _config.river_width_start
	var width_end := _config.river_width_end
	for i in range(path.size()):
		var pt: Vector3 = path[i]
		if pt.x < origin_x - step or pt.x > origin_x + cs + step:
			continue
		if pt.z < origin_z - step or pt.z > origin_z + cs + step:
			continue
		var key := _river_visit_key(pt.x, pt.z, step)
		if seen.has(key):
			continue
		seen[key] = true
		var river_t := clampf((path[0].y - pt.y) / total_drop, 0.0, 1.0)
		var flow := Vector2.ZERO
		if i < path.size() - 1:
			flow = Vector2(path[i + 1].x - pt.x, path[i + 1].z - pt.z)
		elif i > 0:
			flow = Vector2(pt.x - path[i - 1].x, pt.z - path[i - 1].z)
		if flow.length_squared() > 0.0001:
			flow = flow.normalized()
		else:
			flow = Vector2(0.0, 1.0)
		var half_width := lerpf(width_start, width_end, river_t)
		local_points.append({
			"world_x": pt.x,
			"world_z": pt.z,
			"surface_y": pt.y,
			"river_t": river_t,
			"half_width": half_width,
			"flow_dir_x": flow.x,
			"flow_dir_z": flow.y,
		})
	return local_points


func _snap_to_grid(pos: Vector3, origin_x: float, origin_z: float,
		step: float, res: int) -> Vector3:
	var _origin_x := origin_x
	var _origin_z := origin_z
	var _res := res
	var gx := roundi(pos.x / step)
	var gz := roundi(pos.z / step)
	return Vector3(float(gx) * step, pos.y, float(gz) * step)


func _sample_height_hybrid(wx: float, wz: float, heightmap: PackedFloat32Array,
		res: int, origin_x: float, origin_z: float, step: float,
		_cs: float, chunk_end_x: float, chunk_end_z: float) -> float:
	if wx >= origin_x and wx <= chunk_end_x and wz >= origin_z and wz <= chunk_end_z:
		var lx := (wx - origin_x) / step
		var lz := (wz - origin_z) / step
		lx = clampf(lx, 0.0, float(res - 1))
		lz = clampf(lz, 0.0, float(res - 1))
		var gx0 := mini(int(lx), res - 2)
		var gz0 := mini(int(lz), res - 2)
		var fx := lx - float(gx0)
		var fz := lz - float(gz0)
		var h00 := heightmap[gz0 * res + gx0]
		var h10 := heightmap[gz0 * res + gx0 + 1]
		var h01 := heightmap[(gz0 + 1) * res + gx0]
		var h11 := heightmap[(gz0 + 1) * res + gx0 + 1]
		return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)
	return _sample_world_height(wx, wz)


func _sample_world_height(wx: float, wz: float) -> float:
	var hs := _config.height_scale
	var sea := _config.sea_level
	var sample := _warp_sample_coords(wx, wz)
	var blended := _sample_base_terrain(sample.x, sample.y)
	blended += _sample_ridged_contribution(sample.x, sample.y, blended)
	var h := blended * hs
	h = _apply_valley_carving(h, sample.x, sample.y, sea, hs)
	h = _apply_plateau_flattening(h, sea, hs)
	h = _apply_traversal_shaping(h, wx, wz, sample.x, sample.y, sea, hs)
	h = _apply_shoreline_gradient(h, wx, wz, sea)
	h = _apply_ocean_floor(h, wx, wz, sample.x, sample.y, sea, hs)
	return h


func _sample_world_slope_degrees(wx: float, wz: float, step: float) -> float:
	var sample_step := maxf(step, 0.25)
	var h_l := _sample_world_height(wx - sample_step, wz)
	var h_r := _sample_world_height(wx + sample_step, wz)
	var h_u := _sample_world_height(wx, wz - sample_step)
	var h_d := _sample_world_height(wx, wz + sample_step)
	var dx := (h_r - h_l) / maxf(sample_step * 2.0, 0.001)
	var dz := (h_d - h_u) / maxf(sample_step * 2.0, 0.001)
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


func _find_lowest_river_neighbor(pos: Vector3, heightmap: PackedFloat32Array,
		res: int, origin_x: float, origin_z: float, step: float,
		cs: float, chunk_end_x: float, chunk_end_z: float) -> Dictionary:
	var _res := res
	var cur_gx := roundi(pos.x / step)
	var cur_gz := roundi(pos.z / step)
	var best_pos := Vector3.ZERO
	var best_h := INF
	var neighbor_radius := maxi(_config.river_descent_neighbor_radius, 1)
	for dz in range(-neighbor_radius, neighbor_radius + 1):
		for dx in range(-neighbor_radius, neighbor_radius + 1):
			if dx == 0 and dz == 0:
				continue
			if not _config.river_allow_diagonal_descent and abs(dx) + abs(dz) > 1:
				continue
			var ngx: int = cur_gx + dx
			var ngz: int = cur_gz + dz
			var wx: float = float(ngx) * step
			var wz: float = float(ngz) * step
			var h := _sample_height_hybrid(wx, wz, heightmap, res, origin_x, origin_z, step, cs, chunk_end_x, chunk_end_z)
			var dist := Vector2(float(dx), float(dz)).length()
			var effective_h := h + dist * 0.01
			if effective_h < best_h:
				best_h = effective_h
				best_pos = Vector3(wx, h, wz)
	if best_h == INF:
		return {}
	if best_h < pos.y - 0.05:
		return {"pos": best_pos}
	if best_h <= pos.y + 0.02:
		return {"pos": best_pos}
	return {}


func _accumulate_river_cells(path: Array[Vector3], river_cell_map: Dictionary,
		heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float, sea: float) -> void:
	var cs: float = GameConfig.chunk_size
	var total_drop := maxf(path[0].y - sea, 1.0)
	var water_offset := 0.4
	var width_start := _config.river_width_start
	var width_end := _config.river_width_end
	var flood_seeds: Array[Dictionary] = []

	for i in range(path.size()):
		var pt: Vector3 = path[i]
		if pt.x < origin_x or pt.x >= origin_x + cs:
			continue
		if pt.z < origin_z or pt.z >= origin_z + cs:
			continue
		var gx := clampi(roundi((pt.x - origin_x) / step), 0, res - 1)
		var gz := clampi(roundi((pt.z - origin_z) / step), 0, res - 1)
		var river_t := clampf((path[0].y - pt.y) / total_drop, 0.0, 1.0)
		var half_w := lerpf(width_start, width_end, river_t)
		var radius_cells := maxi(ceili(half_w / step), 1)
		var surface_y := heightmap[gz * res + gx]
		var water_y := maxf(surface_y + water_offset, sea)

		var flow_dx := 0.0
		var flow_dz := 1.0
		if i < path.size() - 1:
			var next_pt: Vector3 = path[i + 1]
			var dir := Vector2(next_pt.x - pt.x, next_pt.z - pt.z)
			if dir.length_squared() > 0.0001:
				dir = dir.normalized()
				flow_dx = dir.x
				flow_dz = dir.y

		flood_seeds.append({
			"gx": gx, "gz": gz, "water_y": water_y,
			"river_t": river_t, "radius": radius_cells,
			"flow_dx": flow_dx, "flow_dz": flow_dz,
		})

	_flood_fill_river(flood_seeds, river_cell_map, heightmap, res,
		origin_x, origin_z, step, water_offset, sea)


func _flood_fill_river(seeds: Array[Dictionary], river_cell_map: Dictionary,
		heightmap: PackedFloat32Array, res: int,
		origin_x: float, origin_z: float, step: float,
		_water_offset: float, _sea: float) -> void:
	var carve_depth := _config.river_carve_depth
	var visited := {}
	var queue: Array[Dictionary] = []
	var neighbor_offsets := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	if _config.river_allow_diagonal_descent:
		neighbor_offsets.append_array([Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)])

	for s in seeds:
		var key := Vector2i(int(s["gx"]), int(s["gz"]))
		if visited.has(key):
			continue
		visited[key] = true
		queue.append(s)

	while not queue.is_empty():
		var current: Dictionary = queue.pop_front()
		var gx: int = int(current["gx"])
		var gz: int = int(current["gz"])
		var water_y: float = float(current["water_y"])
		var river_t: float = float(current["river_t"])
		var flow_dx: float = float(current["flow_dx"])
		var flow_dz: float = float(current["flow_dz"])
		var radius: int = int(current["radius"])

		if gx < 0 or gx >= res or gz < 0 or gz >= res:
			continue

		var idx := gz * res + gx
		var surface_y: float = heightmap[idx]
		var cell: Dictionary = river_cell_map.get(idx, {
			"index": idx,
			"gx": gx,
			"gz": gz,
			"cell_size": step,
			"world_x": origin_x + float(gx) * step,
			"world_z": origin_z + float(gz) * step,
			"surface_y": surface_y,
			"water_level": water_y,
			"flow": 0.0,
			"river_t": river_t,
			"flow_dir_x": flow_dx,
			"flow_dir_z": flow_dz,
		})
		cell["flow"] = float(cell["flow"]) + 1.0
		if float(cell.get("water_level", 0.0)) < water_y:
			cell["water_level"] = water_y
		river_cell_map[idx] = cell

		if radius <= 0:
			continue

		for offset in neighbor_offsets:
			var ngx: int = gx + offset.x
			var ngz: int = gz + offset.y
			var nkey := Vector2i(ngx, ngz)
			if visited.has(nkey):
				continue
			if ngx < 0 or ngx >= res or ngz < 0 or ngz >= res:
				continue
			var n_surface: float = heightmap[ngz * res + ngx]
			var slope_deg := _surface_slope_degrees(heightmap, res, ngx, ngz, step)
			var slope_t := clampf(slope_deg / 70.0, 0.0, 1.0)
			var clearance_depth := carve_depth * lerpf(1.0, 1.9, slope_t)
			if n_surface - clearance_depth > water_y:
				continue
			visited[nkey] = true
			queue.append({
				"gx": ngx, "gz": ngz, "water_y": water_y,
				"river_t": river_t, "radius": radius - 1,
				"flow_dx": flow_dx, "flow_dz": flow_dz,
			})


func _finalize_river_cells(river_cell_map: Dictionary) -> void:
	var max_flow_accum := 1.0
	for idx in river_cell_map.keys():
		var pre_cell: Dictionary = river_cell_map[idx]
		max_flow_accum = maxf(max_flow_accum, float(pre_cell.get("flow", 1.0)))
	for idx in river_cell_map.keys():
		var cell: Dictionary = river_cell_map[idx]
		var flow_accum := float(cell.get("flow", 1.0))
		var river_t := float(cell.get("river_t", 0.0))
		var flow_t := clampf((flow_accum - 1.0) / maxf(max_flow_accum - 1.0, 1.0), 0.0, 1.0)
		var width_t := clampf(maxf(river_t, pow(flow_t, 0.82)), 0.0, 1.0)
		cell["flow_accum"] = flow_accum
		cell["river_order"] = int(roundi(width_t * 4.0))
		cell["channel_half_width"] = lerpf(_config.river_width_start, _config.river_width_end * 1.08, width_t)
		cell["channel_depth"] = _config.river_carve_depth * lerpf(0.60, 1.05, width_t)
		cell["channel_fill_ratio"] = lerpf(0.54, 0.74, width_t)
		river_cell_map[idx] = cell


func _river_visit_key(wx: float, wz: float, step: float) -> String:
	return "%d:%d" % [roundi(wx / step), roundi(wz / step)]


func _resample_river_path_for_carve(render_path: Array, max_spacing: float) -> Array:
	if render_path.size() < 2:
		return render_path.duplicate(true)
	var spacing := maxf(max_spacing, 0.25)
	var dense_path: Array = [render_path[0].duplicate(true)]
	for i in range(render_path.size() - 1):
		var a: Dictionary = render_path[i]
		var b: Dictionary = render_path[i + 1]
		var a_pos := Vector2(float(a.get("world_x", 0.0)), float(a.get("world_z", 0.0)))
		var b_pos := Vector2(float(b.get("world_x", 0.0)), float(b.get("world_z", 0.0)))
		var seg_len := a_pos.distance_to(b_pos)
		var steps := maxi(int(ceili(seg_len / spacing)), 1)
		for s in range(1, steps + 1):
			var t := float(s) / float(steps)
			dense_path.append({
				"world_x": lerpf(float(a.get("world_x", 0.0)), float(b.get("world_x", 0.0)), t),
				"world_z": lerpf(float(a.get("world_z", 0.0)), float(b.get("world_z", 0.0)), t),
				"river_t": lerpf(float(a.get("river_t", 0.0)), float(b.get("river_t", 0.0)), t),
				"half_width": lerpf(float(a.get("half_width", _config.river_width_start)), float(b.get("half_width", _config.river_width_start)), t),
			})
	return dense_path


# ── River channel density carving ────────────────────────────────────────────

func _carve_river_channels(grid: PackedFloat32Array, heightmap: PackedFloat32Array,
		river_cells: Array, render_paths: Array, res_xz: int, res_y: int,
		origin_x: float, origin_z: float, step_xz: float, step_y: float,
		min_y: float, _sea: float) -> void:
	var carve_depth := _config.river_carve_depth
	var width_start := _config.river_width_start
	var width_end := _config.river_width_end
	var falloff_exp := _config.river_carve_falloff
	var channel_core_ratio := clampf(_config.river_channel_core_ratio, 0.1, 0.9)
	var bank_width_multiplier := maxf(_config.river_bank_width_multiplier, 1.0)
	var valley_width_multiplier := maxf(_config.river_valley_width_multiplier, bank_width_multiplier)
	var valley_depth_multiplier := maxf(_config.river_valley_depth_multiplier, 0.0)
	var valley_profile_power := maxf(_config.river_valley_profile_power, 0.5)
	var bank_clearance_height := maxf(_config.river_bank_clearance_height, 0.0)
	var ss := res_xz * res_xz
	var chunk_end_x := origin_x + GameConfig.chunk_size
	var chunk_end_z := origin_z + GameConfig.chunk_size
	var overlap_margin := step_xz * 1.25
	var river_cell_support: Dictionary = {}
	if render_paths.is_empty():
		return
	for river_cell in river_cells:
		var cell_gx := int(river_cell.get("gx", -1))
		var cell_gz := int(river_cell.get("gz", -1))
		if cell_gx < 0 or cell_gz < 0:
			continue
		for offset_z in range(-1, 2):
			for offset_x in range(-1, 2):
				var support_key := Vector2i(cell_gx + offset_x, cell_gz + offset_z)
				var support := 1.0
				if offset_x != 0 or offset_z != 0:
					support = 0.72 if abs(offset_x) + abs(offset_z) == 1 else 0.48
				river_cell_support[support_key] = maxf(float(river_cell_support.get(support_key, 0.0)), support)

	for render_path in render_paths:
		var dense_path := _resample_river_path_for_carve(render_path, step_xz * 0.5)
		if dense_path.size() < 2:
			continue
		for i in range(dense_path.size() - 1):
			var a: Dictionary = dense_path[i]
			var b: Dictionary = dense_path[i + 1]
			var ax := float(a.get("world_x", 0.0))
			var az := float(a.get("world_z", 0.0))
			var bx := float(b.get("world_x", ax))
			var bz := float(b.get("world_z", az))
			var seg_vec := Vector2(bx - ax, bz - az)
			var seg_len_sq := maxf(seg_vec.length_squared(), 0.0001)
			var half_w_a := maxf(float(a.get("half_width", width_start)), width_start)
			var half_w_b := maxf(float(b.get("half_width", width_start)), width_start)
			var seg_half_w := maxf(half_w_a, half_w_b)
			var seg_bank_half_w := maxf(seg_half_w * bank_width_multiplier + step_xz * 0.45, step_xz)
			var min_x := minf(ax, bx) - seg_bank_half_w
			var max_x := maxf(ax, bx) + seg_bank_half_w
			var min_z := minf(az, bz) - seg_bank_half_w
			var max_z := maxf(az, bz) + seg_bank_half_w
			var gx_min := maxi(0, int(floor((min_x - origin_x) / step_xz)))
			var gx_max := mini(res_xz - 1, int(ceili((max_x - origin_x) / step_xz)))
			var gz_min := maxi(0, int(floor((min_z - origin_z) / step_xz)))
			var gz_max := mini(res_xz - 1, int(ceili((max_z - origin_z) / step_xz)))

			for gz in range(gz_min, gz_max + 1):
				for gx in range(gx_min, gx_max + 1):
					var cell_support := float(river_cell_support.get(Vector2i(gx, gz), 0.0))
					if cell_support <= 0.0:
						continue
					var wx := origin_x + float(gx) * step_xz
					var wz := origin_z + float(gz) * step_xz
					var point_vec := Vector2(wx - ax, wz - az)
					var seg_t := clampf(point_vec.dot(seg_vec) / seg_len_sq, 0.0, 1.0)
					var closest_x := lerpf(ax, bx, seg_t)
					var closest_z := lerpf(az, bz, seg_t)
					if closest_x < origin_x - overlap_margin or closest_x > chunk_end_x + overlap_margin:
						continue
					if closest_z < origin_z - overlap_margin or closest_z > chunk_end_z + overlap_margin:
						continue
					var dist_xz := Vector2(wx - closest_x, wz - closest_z).length()
					var river_t := lerpf(float(a.get("river_t", 0.0)), float(b.get("river_t", 0.0)), seg_t)
					var half_w := lerpf(half_w_a, half_w_b, seg_t)
					var slope_degrees := _surface_slope_degrees(heightmap, res_xz, gx, gz, step_xz)
					var cliff_t := clampf(
						(slope_degrees - _config.river_cliff_protection_slope) /
							maxf(85.0 - _config.river_cliff_protection_slope, 0.001),
						0.0,
						1.0
					)
					var width_t := clampf((half_w - width_start) / maxf(width_end - width_start, 0.001), 0.0, 1.0)
					var core_half_width := maxf(half_w * channel_core_ratio, step_xz * 0.45)
					var bank_half_width := maxf(
						half_w * lerpf(bank_width_multiplier, maxf(bank_width_multiplier * 0.82, 1.0), cliff_t) + step_xz * 0.45,
						core_half_width + step_xz
					)
					var valley_half_width := maxf(
						half_w * lerpf(valley_width_multiplier, maxf(valley_width_multiplier * 0.78, bank_width_multiplier), cliff_t) + step_xz * 0.75,
						bank_half_width + step_xz * 1.5
					)
					if dist_xz > valley_half_width:
						continue
					var depth := carve_depth * (0.55 + 0.45 * maxf(width_t, river_t))
					depth *= 1.24
					depth *= lerpf(1.0, _config.river_cliff_depth_scale, cliff_t)
					var inner_span := maxf(bank_half_width - core_half_width, 0.001)
					var outer_span := maxf(valley_half_width - bank_half_width, 0.001)
					var core_t := 1.0 - clampf(dist_xz / maxf(core_half_width, 0.001), 0.0, 1.0)
					var shoulder_t := 1.0 - clampf((dist_xz - core_half_width) / inner_span, 0.0, 1.0)
					var valley_t := 1.0 - clampf((dist_xz - bank_half_width) / outer_span, 0.0, 1.0)
					var bank_zone_t := 1.0 - clampf((dist_xz - core_half_width) / maxf(bank_half_width - core_half_width, 0.001), 0.0, 1.0)
					core_t = pow(core_t, maxf(falloff_exp * 0.6, 1.0))
					shoulder_t = pow(shoulder_t, maxf(falloff_exp * 0.95, 1.0))
					valley_t = pow(maxf(valley_t, 0.0), valley_profile_power)
					var edge_fade := clampf(minf(wx - origin_x, origin_x + GameConfig.chunk_size - wx) / 2.0, 0.0, 1.0)
					var edge_fade_z := clampf(minf(wz - origin_z, origin_z + GameConfig.chunk_size - wz) / 2.0, 0.0, 1.0)
					# Carve weight is the INVERSE of the border-restore blend:
					# zero at the seam (river carving is order-dependent —
					# either side may or may not have traced this river) and
					# full strength past the blend band. Without this, traced
					# and untraced sides mismatch along river crossings.
					var edge_d := minf(
						mini(gx, res_xz - 1 - gx),
						mini(gz, res_xz - 1 - gz))
					var restore_w := clampf(
						1.0 - (float(maxi(edge_d, 1)) - 1.0) / maxf(float(maxi(_config.border_blend_cells, 2) - 1), 1.0),
						0.0, 1.0)
					var seam_weight := 1.0 - restore_w * restore_w * (3.0 - 2.0 * restore_w)
					var surface_h := heightmap[gz * res_xz + gx]
					var channel_floor := surface_h - depth
					var target_surface := surface_h
					if dist_xz <= core_half_width:
						target_surface = lerpf(surface_h, channel_floor + depth * 0.18, core_t * 0.92)
					elif dist_xz <= bank_half_width:
						target_surface = lerpf(surface_h, channel_floor + depth * 0.42, shoulder_t * 0.72)
					else:
						target_surface = lerpf(
							surface_h,
							surface_h - depth * valley_depth_multiplier,
							valley_t * 0.34
						)
					var bank_clearance := bank_clearance_height * edge_fade * edge_fade_z * seam_weight
					var channel_top := surface_h + bank_clearance + depth * 0.03
					var carve_t := clampf(carve_depth / maxf(depth + bank_clearance_height, 0.001), 0.0, 1.0)
					var preserve_t := maxf(cliff_t, 1.0 - bank_zone_t)
					var preserve_shell_density := _config.river_min_solid_shell * lerpf(0.85, 1.75, preserve_t) * cell_support
					for gy in res_y:
						var world_y := min_y + float(gy) * step_y
						if world_y > channel_top:
							continue
						if world_y < channel_floor - step_y * 1.1:
							continue
						var idx := gy * ss + gz * res_xz + gx
						var shell_density := maxf(grid[idx], 0.0)
						if world_y >= target_surface:
							if cliff_t > 0.0 and dist_xz > core_half_width and shell_density <= preserve_shell_density:
								continue
							var above_target := clampf((world_y - target_surface) / maxf(surface_h - target_surface + 0.001, 0.001), 0.0, 1.0)
							var carve_drop := maxf(surface_h - target_surface, 0.0)
							var carve_strength := carve_drop * (0.55 + above_target * 0.85)
							if dist_xz > bank_half_width:
								carve_strength *= 0.42
							elif dist_xz > core_half_width:
								carve_strength *= 0.58
							carve_strength *= lerpf(1.0, 0.18, cliff_t)
							carve_strength *= seam_weight
							if carve_strength <= 0.001:
								continue
							grid[idx] = maxf(grid[idx] - carve_strength, preserve_shell_density)
						else:
							if dist_xz > core_half_width * 0.72:
								continue
							if cliff_t > 0.35:
								continue
							if shell_density <= preserve_shell_density:
								continue
							var below := channel_floor - world_y
							if below > step_y * 1.1:
								continue
							var taper := 1.0 - clampf(below / maxf(step_y * 1.1, 0.001), 0.0, 1.0)
							var undercut_strength := taper * (0.14 + carve_t * 0.24) * seam_weight * cell_support
							grid[idx] = maxf(grid[idx] - undercut_strength, preserve_shell_density)


func _apply_cave_carving_to_density(surface_h: float, density: float,
		wx: float, world_y: float, wz: float, sea: float, cave_min_d: float,
		cave_max_d: float, ramp: float, spag_sq: float, spag_str: float,
		cheese_thresh: float, cheese_str: float) -> float:
	var depth_below := surface_h - world_y
	if density <= maxf(_config.cave_density_threshold, _config.surface_threshold):
		return density
	if depth_below <= cave_min_d or depth_below >= cave_max_d:
		return density
	if surface_h <= sea + _config.cave_sea_buffer:
		return density
	var depth_t := clampf((depth_below - cave_min_d) / maxf(ramp, 0.001), 0.0, 1.0)
	var depth_t_upper := clampf((cave_max_d - depth_below) / maxf(ramp, 0.001), 0.0, 1.0)
	var depth_mask := depth_t * depth_t_upper
	var carve_scale := clampf(density * _config.cave_carve_multiplier,
		_config.cave_carve_min, _config.cave_carve_max)
	var na := _cave_noise_a.get_noise_3d(wx, world_y, wz)
	var nb := _cave_noise_b.get_noise_3d(wx, world_y, wz)
	var spaghetti := na * na + nb * nb
	if spaghetti < spag_sq:
		density -= (1.0 - spaghetti / spag_sq) * spag_str * depth_mask * carve_scale
	var cheese := (_cave_cheese_noise.get_noise_3d(wx, world_y, wz) + 1.0) * 0.5
	if cheese > cheese_thresh:
		density -= ((cheese - cheese_thresh) / (1.0 - cheese_thresh)) * cheese_str * depth_mask * carve_scale
	return density


func _extract_surface_heightmap(density: PackedFloat32Array,
		res_xz: int, res_y: int) -> PackedFloat32Array:
	var heightmap := PackedFloat32Array()
	heightmap.resize(res_xz * res_xz)
	var min_y := _config.grid_min_y
	var step_y := (_config.grid_max_y - min_y) / float(res_y - 1)
	var ss := res_xz * res_xz
	var iso := _config.surface_threshold

	for gz in res_xz:
		for gx in res_xz:
			var found_y := min_y
			for gy in range(res_y - 1, -1, -1):
				var idx := gy * ss + gz * res_xz + gx
				if density[idx] > iso:
					if gy < res_y - 1:
						var idx_above := (gy + 1) * ss + gz * res_xz + gx
						var d_below := density[idx]
						var d_above := density[idx_above]
						var t := (d_below - iso) / maxf(d_below - d_above, 0.001)
						found_y = min_y + (float(gy) + t) * step_y
					else:
						found_y = min_y + float(gy) * step_y
					break
			heightmap[gz * res_xz + gx] = found_y

	return heightmap


func _sample_heightmap_bilinear(heightmap: PackedFloat32Array, res: int,
		local_x: float, local_z: float, step: float) -> float:
	if res <= 1 or heightmap.is_empty():
		return 0.0
	var fx := clampf(local_x / maxf(step, 0.001), 0.0, float(res - 1))
	var fz := clampf(local_z / maxf(step, 0.001), 0.0, float(res - 1))
	var gx0 := mini(int(fx), res - 2)
	var gz0 := mini(int(fz), res - 2)
	var tx := fx - float(gx0)
	var tz := fz - float(gz0)
	var h00 := heightmap[gz0 * res + gx0]
	var h10 := heightmap[gz0 * res + gx0 + 1]
	var h01 := heightmap[(gz0 + 1) * res + gx0]
	var h11 := heightmap[(gz0 + 1) * res + gx0 + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func _sample_loaded_surface_height(wx: float, wz: float) -> float:
	var cs := GameConfig.chunk_size
	var coord := Vector2i(floori(wx / cs), floori(wz / cs))
	if _chunk_heightmaps.has(coord):
		var heightmap: PackedFloat32Array = _chunk_heightmaps[coord]
		if not heightmap.is_empty():
			var res := int(sqrt(heightmap.size()))
			if res > 1:
				var step := cs / float(res - 1)
				var local_x := wx - float(coord.x) * cs
				var local_z := wz - float(coord.y) * cs
				return _sample_heightmap_bilinear(heightmap, res, local_x, local_z, step)
	return _sample_world_height(wx, wz)


func _sample_chunk_density(chunk_data: ChunkData, coord: Vector2i,
		wx: float, world_y: float, wz: float) -> float:
	var res_xz := chunk_data.get_resolution()
	var res_y := chunk_data.density_res_y
	if res_xz <= 1 or res_y <= 1 or chunk_data.density_grid.is_empty():
		return INF
	var cs := GameConfig.chunk_size
	var step_xz := cs / float(res_xz - 1)
	var min_y := _config.grid_min_y
	var step_y := (_config.grid_max_y - min_y) / float(res_y - 1)
	var local_x := clampf((wx - float(coord.x) * cs) / step_xz, 0.0, float(res_xz - 1))
	var local_z := clampf((wz - float(coord.y) * cs) / step_xz, 0.0, float(res_xz - 1))
	var local_y := clampf((world_y - min_y) / step_y, 0.0, float(res_y - 1))
	var x0 := mini(int(local_x), res_xz - 2)
	var z0 := mini(int(local_z), res_xz - 2)
	var y0 := mini(int(local_y), res_y - 2)
	var tx := local_x - float(x0)
	var tz := local_z - float(z0)
	var ty := local_y - float(y0)
	var ss := res_xz * res_xz
	var density_grid := chunk_data.density_grid
	var idx000 := y0 * ss + z0 * res_xz + x0
	var idx100 := y0 * ss + z0 * res_xz + (x0 + 1)
	var idx010 := y0 * ss + (z0 + 1) * res_xz + x0
	var idx110 := y0 * ss + (z0 + 1) * res_xz + (x0 + 1)
	var idx001 := (y0 + 1) * ss + z0 * res_xz + x0
	var idx101 := (y0 + 1) * ss + z0 * res_xz + (x0 + 1)
	var idx011 := (y0 + 1) * ss + (z0 + 1) * res_xz + x0
	var idx111 := (y0 + 1) * ss + (z0 + 1) * res_xz + (x0 + 1)
	var d00 := lerpf(density_grid[idx000], density_grid[idx100], tx)
	var d10 := lerpf(density_grid[idx010], density_grid[idx110], tx)
	var d01 := lerpf(density_grid[idx001], density_grid[idx101], tx)
	var d11 := lerpf(density_grid[idx011], density_grid[idx111], tx)
	var d0 := lerpf(d00, d10, tz)
	var d1 := lerpf(d01, d11, tz)
	return lerpf(d0, d1, ty)


# ── Density gradient normals (world-space, seam-consistent) ──────────────────

func _density_gradient_normal_world(coord: Vector2i,
		step_xz: float, step_y: float, vx: float, vy: float, vz: float) -> Vector3:
	var origin_x := float(coord.x) * GameConfig.chunk_size
	var origin_z := float(coord.y) * GameConfig.chunk_size
	var wx := origin_x + vx
	var wz := origin_z + vz
	var dx := _sample_density_world(wx + step_xz, vy, wz) - _sample_density_world(wx - step_xz, vy, wz)
	var dy := _sample_density_world(wx, vy + step_y, wz) - _sample_density_world(wx, vy - step_y, wz)
	var dz := _sample_density_world(wx, vy, wz + step_xz) - _sample_density_world(wx, vy, wz - step_xz)
	var grad := Vector3(dx, dy, dz)
	if grad.length_squared() < 0.0001:
		return Vector3.UP
	return -grad.normalized()


func _sample_density_world(wx: float, world_y: float, wz: float) -> float:
	var cs := GameConfig.chunk_size
	var coord := Vector2i(floori(wx / cs), floori(wz / cs))
	var chunk_mgr := _get_chunk_manager()
	if chunk_mgr:
		var chunk_data := chunk_mgr.get_chunk(coord)
		if chunk_data:
			var sampled_density := _sample_chunk_density(chunk_data, coord, wx, world_y, wz)
			if sampled_density != INF:
				return sampled_density
	var surface_h := _sample_loaded_surface_height(wx, wz)
	var density := surface_h - world_y
	if _config.caves_enabled:
		var spag_sq := _config.cave_spaghetti_threshold * _config.cave_spaghetti_threshold
		density = _apply_cave_carving_to_density(surface_h, density, wx, world_y, wz,
			_config.sea_level, _config.cave_min_depth, _config.cave_max_depth,
			_config.cave_depth_ramp, spag_sq, _config.cave_spaghetti_strength,
			_config.cave_cheese_threshold, _config.cave_cheese_strength)
	return density


# ── Marching Cubes mesh extraction ──────────────────────────────────────────

## Flat pairs (edge*2, edge*2+1) — avoids allocating an Array per lookup.
## (Instance var because packed arrays cannot be const expressions.)
var MC_EDGE_CORNER_PAIRS := PackedInt32Array([
	0, 1, 1, 2, 2, 3, 3, 0,
	4, 5, 5, 6, 6, 7, 7, 4,
	0, 4, 1, 5, 2, 6, 3, 7,
])


## NOTE: unused. Kept only as a reminder that chunk generation is threaded —
## any scratch buffer hung off the system will be shared by every worker.
var _mc_corners_scratch_unused: Array[Vector3] = [
	Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
	Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
]
var _mc_dd_scratch_unused: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]


func _build_marching_cubes_arrays(density: PackedFloat32Array,
		res_xz: int, res_y: int, coord: Vector2i,
		surface_hm: PackedFloat32Array, river_cells: Array) -> Array:
	var cs := GameConfig.chunk_size
	var step_xz := cs / float(res_xz - 1)
	var min_y := _config.grid_min_y
	var step_y := (_config.grid_max_y - min_y) / float(res_y - 1)
	var iso := _config.surface_threshold
	var sea := _config.sea_level
	var hs := _config.height_scale
	var ss := res_xz * res_xz
	var river_lookup := _build_river_lookup(river_cells)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var colors := PackedColorArray()

	# Column Y-bands: only cells whose corner signs straddle the iso level
	# can produce geometry (the surface shell plus any cave ceilings). This
	# skips the ~90% of the volume that is solid rock or open air — the
	# single biggest cost of the old all-cells loop.
	var bands := PackedInt32Array()
	bands.resize(res_xz * res_xz * 2)
	for gz in res_xz:
		for gx in res_xz:
			var base := gz * res_xz + gx
			var lo := -1
			var hi := -2
			var below := density[base] < iso
			for gy in res_y - 1:
				var next_below := density[(gy + 1) * ss + base] < iso
				if below != next_below:
					if lo < 0:
						lo = gy
					hi = gy
				below = next_below
			bands[base * 2] = lo
			bands[base * 2 + 1] = hi

	# Reused scratch arrays — the old loop allocated two heap arrays per
	# surface cell, which dominated allocation time.
	# Per-call scratch, NOT the shared members: chunk generation runs on
	# several worker threads at once now, and one set of reusable arrays on
	# the system would be written by all of them simultaneously. Two small
	# allocations per chunk is nothing next to the marching-cubes pass; the
	# point of reusing them was to avoid allocating per CELL, which this
	# still does.
	var corners: Array[Vector3] = [
		Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
		Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
	]
	var dd: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var grid_step_y := step_y
	for gz in res_xz - 1:
		for gx in res_xz - 1:
			# A cell is mixed if the surface crosses inside it in ANY of its
			# four columns — horizontal steps between neighboring columns
			# (cliff edges, shorelines) count too, so union the four column
			# bands. Missing this is what tore the mesh open before.
			var lo := -1
			var hi := -2
			for c in 4:
				var cx := gx + (c & 1)
				var cz := gz + (c >> 1)
				var band_base := (cz * res_xz + cx) * 2
				var c_lo := bands[band_base]
				if c_lo < 0:
					continue
				if lo < 0 or c_lo < lo:
					lo = c_lo
				var c_hi := bands[band_base + 1]
				if c_hi > hi:
					hi = c_hi
			if lo < 0:
				continue
			# Hoisted out of the Y loop: the refine test depends only on the
			# COLUMN (surface slope, shore band, nearby river cells), yet it
			# was re-evaluated for every vertical level in the band — a
			# slope computation plus up to nine Vector2i dictionary lookups
			# repeated for each cell in a column that can be dozens tall.
			var refine_cell := _should_refine_mc_cell(
				surface_hm, river_lookup, res_xz, gx, gz, step_xz, sea)
			for gy in range(lo, hi + 1):
				var y0 := min_y + float(gy) * step_y
				var y1 := y0 + step_y
				var d0 := density[gy * ss + gz * res_xz + gx]
				var d1 := density[gy * ss + gz * res_xz + (gx + 1)]
				var d2 := density[gy * ss + (gz + 1) * res_xz + (gx + 1)]
				var d3 := density[gy * ss + (gz + 1) * res_xz + gx]
				var d4 := density[(gy + 1) * ss + gz * res_xz + gx]
				var d5 := density[(gy + 1) * ss + gz * res_xz + (gx + 1)]
				var d6 := density[(gy + 1) * ss + (gz + 1) * res_xz + (gx + 1)]
				var d7 := density[(gy + 1) * ss + (gz + 1) * res_xz + gx]

				var x0 := float(gx) * step_xz
				var z0 := float(gz) * step_xz
				var x1 := x0 + step_xz
				var z1 := z0 + step_xz
				corners[0] = Vector3(x0, y0, z0)
				corners[1] = Vector3(x1, y0, z0)
				corners[2] = Vector3(x1, y0, z1)
				corners[3] = Vector3(x0, y0, z1)
				corners[4] = Vector3(x0, y1, z0)
				corners[5] = Vector3(x1, y1, z0)
				corners[6] = Vector3(x1, y1, z1)
				corners[7] = Vector3(x0, y1, z1)
				dd[0] = d0
				dd[1] = d1
				dd[2] = d2
				dd[3] = d3
				dd[4] = d4
				dd[5] = d5
				dd[6] = d6
				dd[7] = d7
				if refine_cell:
					_append_refined_mc_cell(verts, norms, colors, coord, surface_hm, gx, gz, gy,
						step_xz, step_y, min_y, iso, sea, hs, density, ss, res_xz, res_y)
				else:
					_append_mc_triangles_from_cube(verts, norms, colors, coord, surface_hm,
						res_xz, step_xz, step_y, step_xz, iso, sea, hs, corners, dd,
						density, ss, res_y, min_y)

	if verts.is_empty():
		verts.append(Vector3.ZERO)
		verts.append(Vector3(0.001, 0, 0))
		verts.append(Vector3(0, 0, 0.001))
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		colors.append(Color.BLACK)
		colors.append(Color.BLACK)
		colors.append(Color.BLACK)

	# Direct array commit: SurfaceTool's per-vertex calls cost more than
	# the entire marching-cubes pass above.
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	return arrays


## Convenience wrapper: build the arrays and commit them to an ArrayMesh.
## Only safe on the main thread; the threaded path keeps the two apart.
func _build_marching_cubes_mesh(density: PackedFloat32Array,
		res_xz: int, res_y: int, coord: Vector2i,
		surface_hm: PackedFloat32Array, river_cells: Array) -> ArrayMesh:
	return _mesh_from_arrays(_build_marching_cubes_arrays(
		density, res_xz, res_y, coord, surface_hm, river_cells))


func _mesh_from_arrays(arrays: Array) -> ArrayMesh:
	var out_mesh := ArrayMesh.new()
	out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out_mesh


func _build_river_lookup(river_cells: Array) -> Dictionary:
	var lookup: Dictionary = {}
	for river_cell in river_cells:
		var gx := int(river_cell.get("gx", -1))
		var gz := int(river_cell.get("gz", -1))
		if gx < 0 or gz < 0:
			continue
		lookup[Vector2i(gx, gz)] = river_cell
	return lookup


func _should_refine_mc_cell(surface_hm: PackedFloat32Array, river_lookup: Dictionary,
		res_xz: int, gx: int, gz: int, step_xz: float, sea: float) -> bool:
	if not _config.adaptive_refinement_enabled:
		return false
	if _config.adaptive_refine_subdivisions <= 1:
		return false
	var border_guard := maxi(_config.adaptive_refine_subdivisions, 1)
	if gx < border_guard or gz < border_guard:
		return false
	if gx >= (res_xz - 1 - border_guard) or gz >= (res_xz - 1 - border_guard):
		return false
	var slope := _surface_slope_degrees(surface_hm, res_xz, gx, gz, step_xz)
	if slope >= _config.adaptive_cliff_slope_threshold:
		return true
	var surface_h := surface_hm[gz * res_xz + gx]
	if absf(surface_h - sea) <= _config.adaptive_shore_band:
		return true
	var river_band_cells := maxi(int(ceili(_config.adaptive_river_band_multiplier)), 1)
	for dz in range(-river_band_cells, river_band_cells + 1):
		for dx in range(-river_band_cells, river_band_cells + 1):
			if river_lookup.has(Vector2i(gx + dx, gz + dz)):
				return true
	return false


func _surface_slope_degrees(surface_hm: PackedFloat32Array, res_xz: int,
		gx: int, gz: int, step_xz: float) -> float:
	var sx := clampi(gx, 1, res_xz - 2)
	var sz := clampi(gz, 1, res_xz - 2)
	var h_l := surface_hm[sz * res_xz + (sx - 1)]
	var h_r := surface_hm[sz * res_xz + (sx + 1)]
	var h_u := surface_hm[(sz - 1) * res_xz + sx]
	var h_d := surface_hm[(sz + 1) * res_xz + sx]
	var dx := (h_r - h_l) / maxf(step_xz * 2.0, 0.001)
	var dz := (h_d - h_u) / maxf(step_xz * 2.0, 0.001)
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


func _append_refined_mc_cell(verts: PackedVector3Array, norms: PackedVector3Array,
		colors: PackedColorArray, coord: Vector2i, surface_hm: PackedFloat32Array,
		gx: int, gz: int, gy: int, step_xz: float, step_y: float,
		min_y: float, iso: float, sea: float, hs: float,
		density: PackedFloat32Array, ss: int, res_xz: int, res_y: int) -> void:
	var refine := maxi(_config.adaptive_refine_subdivisions, 1)
	if refine <= 1:
		return
	var sub_step_xz := step_xz / float(refine)
	var sub_step_y := step_y / float(refine)
	var surface_step_xz := GameConfig.chunk_size / maxf(float(int(sqrt(surface_hm.size())) - 1), 1.0)
	var base_x := float(gx) * step_xz
	var base_z := float(gz) * step_xz
	var base_y := min_y + float(gy) * step_y
	for sy in range(refine):
		for sz in range(refine):
			for sx in range(refine):
				var x0 := base_x + float(sx) * sub_step_xz
				var z0 := base_z + float(sz) * sub_step_xz
				var y0 := base_y + float(sy) * sub_step_y
				var x1 := x0 + sub_step_xz
				var z1 := z0 + sub_step_xz
				var y1 := y0 + sub_step_y
				var corners: Array[Vector3] = [
					Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
					Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
				]
				var dd: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
				corners[0] = Vector3(x0, y0, z0)
				corners[1] = Vector3(x1, y0, z0)
				corners[2] = Vector3(x1, y0, z1)
				corners[3] = Vector3(x0, y0, z1)
				corners[4] = Vector3(x0, y1, z0)
				corners[5] = Vector3(x1, y1, z0)
				corners[6] = Vector3(x1, y1, z1)
				corners[7] = Vector3(x0, y1, z1)
				# Corner densities come from the chunk-local grid via
				# trilinear interpolation — the same values the world
				# sampler returns for in-chunk points, without the chunk
				# manager round-trip per corner.
				for c in 8:
					dd[c] = _grid_density(density, ss, res_xz, res_y,
						corners[c].x / step_xz,
						(corners[c].y - min_y) / step_y,
						corners[c].z / step_xz)
				_append_mc_triangles_from_cube(verts, norms, colors, coord, surface_hm,
					int(sqrt(surface_hm.size())), sub_step_xz, sub_step_y, surface_step_xz,
					iso, sea, hs, corners, dd,
					density, ss, res_y, min_y)


func _append_mc_triangles_from_cube(verts: PackedVector3Array, norms: PackedVector3Array,
		colors: PackedColorArray, coord: Vector2i, surface_hm: PackedFloat32Array,
		res_xz: int, normal_step_xz: float, normal_step_y: float, hm_step_xz: float, iso: float,
		sea: float, hs: float, corners: Array[Vector3], dd: Array[float],
		density: PackedFloat32Array = PackedFloat32Array(), ss: int = 0, res_y: int = 0,
		grid_min_y: float = 0.0) -> void:
	if dd.size() < 8 or corners.size() < 8:
		return
	var cube_idx := 0
	if dd[0] < iso: cube_idx |= 1
	if dd[1] < iso: cube_idx |= 2
	if dd[2] < iso: cube_idx |= 4
	if dd[3] < iso: cube_idx |= 8
	if dd[4] < iso: cube_idx |= 16
	if dd[5] < iso: cube_idx |= 32
	if dd[6] < iso: cube_idx |= 64
	if dd[7] < iso: cube_idx |= 128
	if cube_idx == 0 or cube_idx == 255:
		return
	var edges: PackedInt32Array = _mc_tri_table[cube_idx]
	if edges.is_empty() or edges[0] == -1:
		return
	# Normals come from the chunk-local density grid — the world-space
	# gradient sampler cost 18 chunk-manager round-trips per triangle and
	# dominated the entire chunk build.
	var use_grid_normals := ss > 0
	var grid_step_xz := GameConfig.chunk_size / maxf(float(res_xz - 1), 1.0)
	var grid_step_y := (_config.grid_max_y - grid_min_y) / maxf(float(res_y - 1), 1.0)
	var ei := 0
	while ei + 2 < edges.size() and edges[ei] != -1:
		if edges[ei + 1] == -1 or edges[ei + 2] == -1:
			break
		var v0 := _interp_edge(edges[ei], corners, dd, iso)
		var v1 := _interp_edge(edges[ei + 1], corners, dd, iso)
		var v2 := _interp_edge(edges[ei + 2], corners, dd, iso)
		var n0 := _grid_gradient_normal(density, ss, res_xz, res_y,
			grid_step_xz, grid_step_y, grid_min_y, v0) if use_grid_normals \
			else _density_gradient_normal_world(coord, normal_step_xz, normal_step_y, v0.x, v0.y, v0.z)
		var n1 := _grid_gradient_normal(density, ss, res_xz, res_y,
			grid_step_xz, grid_step_y, grid_min_y, v1) if use_grid_normals \
			else _density_gradient_normal_world(coord, normal_step_xz, normal_step_y, v1.x, v1.y, v1.z)
		var n2 := _grid_gradient_normal(density, ss, res_xz, res_y,
			grid_step_xz, grid_step_y, grid_min_y, v2) if use_grid_normals \
			else _density_gradient_normal_world(coord, normal_step_xz, normal_step_y, v2.x, v2.y, v2.z)
		var avg_y := (v0.y + v1.y + v2.y) / 3.0
		var avg_x := (v0.x + v1.x + v2.x) / 3.0
		var avg_z := (v0.z + v1.z + v2.z) / 3.0
		var hm_x := clampi(int(avg_x / maxf(hm_step_xz, 0.001)), 0, res_xz - 1)
		var hm_z := clampi(int(avg_z / maxf(hm_step_xz, 0.001)), 0, res_xz - 1)
		var surface_h := surface_hm[hm_z * res_xz + hm_x]
		var is_cave := avg_y < surface_h - _config.cave_min_depth * 0.5
		var color: Color
		if is_cave:
			color = _cave_color(avg_y, surface_h)
		else:
			color = _surface_color(avg_y, sea, hs)
		verts.append(v0)
		verts.append(v1)
		verts.append(v2)
		norms.append(n0)
		norms.append(n1)
		norms.append(n2)
		colors.append(color)
		colors.append(color)
		colors.append(color)
		ei += 3


# ── Chunk-local density sampling (fast paths for meshing) ────────────────────


## Trilinear sample of the chunk density grid in grid coordinates.
## Clamped at borders, so exterior taps return edge values.
func _grid_density(density: PackedFloat32Array, ss: int, res_xz: int, res_y: int,
		fx: float, fy: float, fz: float) -> float:
	fx = clampf(fx, 0.0, float(res_xz - 1))
	fy = clampf(fy, 0.0, float(res_y - 1))
	fz = clampf(fz, 0.0, float(res_xz - 1))
	var x0 := int(fx)
	var y0 := int(fy)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, res_xz - 1)
	var y1 := mini(y0 + 1, res_y - 1)
	var z1 := mini(z0 + 1, res_xz - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var tz := fz - float(z0)
	var c00 := lerpf(density[y0 * ss + z0 * res_xz + x0], density[y0 * ss + z0 * res_xz + x1], tx)
	var c10 := lerpf(density[y0 * ss + z1 * res_xz + x0], density[y0 * ss + z1 * res_xz + x1], tx)
	var c01 := lerpf(density[y1 * ss + z0 * res_xz + x0], density[y1 * ss + z0 * res_xz + x1], tx)
	var c11 := lerpf(density[y1 * ss + z1 * res_xz + x0], density[y1 * ss + z1 * res_xz + x1], tx)
	return lerpf(lerpf(c00, c10, tz), lerpf(c01, c11, tz), ty)


## Surface normal from central differences over the chunk-local grid —
## a fraction of the cost of world-space gradient sampling.
func _grid_gradient_normal(density: PackedFloat32Array, ss: int, res_xz: int, res_y: int,
		step_xz: float, step_y: float, min_y: float, v: Vector3) -> Vector3:
	var fx := v.x / step_xz
	var fy := (v.y - min_y) / step_y
	var fz := v.z / step_xz
	var dx := _grid_density(density, ss, res_xz, res_y, fx + 1.0, fy, fz) \
		- _grid_density(density, ss, res_xz, res_y, fx - 1.0, fy, fz)
	var dy := _grid_density(density, ss, res_xz, res_y, fx, fy + 1.0, fz) \
		- _grid_density(density, ss, res_xz, res_y, fx, fy - 1.0, fz)
	var dz := _grid_density(density, ss, res_xz, res_y, fx, fy, fz + 1.0) \
		- _grid_density(density, ss, res_xz, res_y, fx, fy, fz - 1.0)
	var grad := Vector3(dx / (2.0 * step_xz), dy / (2.0 * step_y), dz / (2.0 * step_xz))
	if grad.length_squared() < 0.0001:
		return Vector3.UP
	return -grad.normalized()


func _interp_edge(edge: int, corners: Array[Vector3], d: Array[float], iso: float) -> Vector3:
	var a: int = MC_EDGE_CORNER_PAIRS[edge * 2]
	var b: int = MC_EDGE_CORNER_PAIRS[edge * 2 + 1]
	var da := d[a]
	var db := d[b]
	var denom := da - db
	var t := 0.5
	if absf(denom) > 0.0001:
		t = (da - iso) / denom
	t = clampf(t, 0.0, 1.0)
	return corners[a].lerp(corners[b], t)


# ── Vertex coloring ─────────────────────────────────────────────────────────

func _surface_color(h: float, sea: float, hs: float) -> Color:
	if h < sea - 0.1:
		var raw_depth := sea - h
		var shelf_d := _config.shelf_depth
		var slope_d := _config.slope_depth
		var sand_c := Color(0.72, 0.67, 0.52)
		var shelf_c := Color(0.55, 0.52, 0.40)
		var slope_c := Color(0.38, 0.36, 0.32)
		var abyss_c := Color(0.18, 0.17, 0.15)
		if raw_depth < shelf_d * 0.5:
			return sand_c.lerp(shelf_c, clampf(raw_depth / (shelf_d * 0.5), 0.0, 1.0))
		elif raw_depth < shelf_d:
			return shelf_c.lerp(slope_c, clampf((raw_depth - shelf_d * 0.5) / (shelf_d * 0.5), 0.0, 1.0) * 0.5)
		elif raw_depth < slope_d:
			return shelf_c.lerp(slope_c, 0.5 + clampf((raw_depth - shelf_d) / (slope_d - shelf_d), 0.0, 1.0) * 0.5)
		else:
			return slope_c.lerp(abyss_c, clampf((raw_depth - slope_d) / maxf(_config.abyss_depth - slope_d, 1.0), 0.0, 1.0))

	if h < sea + 1.2:
		return Color(0.72, 0.67, 0.52).lerp(Color(0.82, 0.77, 0.58), clampf((h - sea + 0.1) / 1.3, 0.0, 1.0))

	var t := clampf((h - sea) / hs, 0.0, 1.0)
	if t < 0.15:
		return Color(0.82, 0.77, 0.58).lerp(Color(0.35, 0.55, 0.20), t / 0.15)
	elif t < 0.35:
		return Color(0.35, 0.55, 0.20).lerp(Color(0.18, 0.42, 0.12), (t - 0.15) / 0.2)
	elif t < 0.55:
		return Color(0.18, 0.42, 0.12).lerp(Color(0.12, 0.30, 0.08), (t - 0.35) / 0.2)
	elif t < 0.7:
		return Color(0.12, 0.30, 0.08).lerp(Color(0.50, 0.48, 0.45), (t - 0.55) / 0.15)
	elif t < 0.85:
		return Color(0.50, 0.48, 0.45).lerp(Color(0.65, 0.63, 0.60), (t - 0.7) / 0.15)
	else:
		return Color(0.65, 0.63, 0.60).lerp(Color(0.95, 0.95, 0.97), (t - 0.85) / 0.15)


func _cave_color(world_y: float, surface_h: float) -> Color:
	var depth := surface_h - world_y
	var base := _config.cave_wall_color
	var darken := clampf(depth / _config.cave_max_depth, 0.0, 0.7)
	return base.darkened(darken)


func _on_biome_chunk_ready(coord: Vector2i, biome_map: PackedByteArray) -> void:
	if not _chunk_meshes.has(coord) or not _chunk_heightmaps.has(coord):
		return
	_recolor_chunk_biomes(coord, biome_map)


## Build a grid of biome colors from the already-computed biome_map (zero noise lookups)
func _build_biome_color_grid(biome_sys: BiomeSystem, biome_map: PackedByteArray,
		heightmap: PackedFloat32Array) -> PackedColorArray:
	var res := _config.chunk_resolution

	var grid := PackedColorArray()
	grid.resize(res * res)

	for gz in res:
		for gx in res:
			grid[gz * res + gx] = _blend_biome_cell_color(biome_sys, biome_map, heightmap, res, gx, gz)

	return grid


func _blend_biome_cell_color(biome_sys: BiomeSystem, biome_map: PackedByteArray,
		heightmap: PackedFloat32Array, res: int, gx: int, gz: int) -> Color:
	var sea := _config.sea_level
	var hs := _config.height_scale
	var center_height := heightmap[gz * res + gx]
	var base_color := _surface_color(center_height, sea, hs)
	if center_height < sea - 0.1:
		return base_color

	var accum := Color(0.0, 0.0, 0.0, 1.0)
	var total_weight := 0.0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var sx := clampi(gx + dx, 0, res - 1)
			var sz := clampi(gz + dz, 0, res - 1)
			var sample_height := heightmap[sz * res + sx]
			if sample_height < sea - 0.1:
				continue
			var bdata: BiomeData = biome_sys.get_biome_data(biome_map[sz * res + sx])
			var biome_color := bdata.terrain_color if bdata else base_color
			var distance_weight := 1.0 / float(1 + abs(dx) + abs(dz))
			var height_weight := 1.0 - clampf(absf(sample_height - center_height) / maxf(hs * 0.12, 0.001), 0.0, 0.8)
			var weight := distance_weight * maxf(height_weight, 0.2)
			accum += biome_color * weight
			total_weight += weight
	if total_weight <= 0.001:
		return base_color
	var blended_biome := accum / total_weight
	return base_color.lerp(blended_biome, 0.68)


func _apply_surface_detail_color(base_color: Color, biome_data: BiomeData,
		world_x: float, world_y: float, world_z: float, normal: Vector3,
		sea: float, hs: float) -> Color:
	var detail_scale := biome_data.texture_scale if biome_data else 4.0
	var detail_sample := (_detail_noise.get_noise_2d(world_x / maxf(detail_scale, 0.001), world_z / maxf(detail_scale, 0.001)) + 1.0) * 0.5
	var detail_mix := _smoothstep(0.18, 0.82, detail_sample)
	var detailed := base_color.lerp(base_color.lightened(0.08), detail_mix * 0.22)
	var shadowed := detailed.lerp(detailed.darkened(0.08), (1.0 - detail_mix) * 0.28)
	var slope_t := _smoothstep(0.45, 0.82, 1.0 - clampf(normal.dot(Vector3.UP), 0.0, 1.0))
	var cliff_color := Color(0.48, 0.45, 0.40)
	var height_t := clampf((world_y - sea) / maxf(hs, 0.001), 0.0, 1.0)
	var highland_cliff := cliff_color.lerp(Color(0.62, 0.62, 0.64), clampf((height_t - 0.55) / 0.35, 0.0, 1.0))
	return shadowed.lerp(highland_cliff, slope_t * 0.6)


func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / maxf(edge1 - edge0, 0.0001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _sample_loaded_surface_normal(wx: float, wz: float, sample_step: float) -> Vector3:
	var step := maxf(sample_step, 0.25)
	var h_l := _sample_loaded_surface_height(wx - step, wz)
	var h_r := _sample_loaded_surface_height(wx + step, wz)
	var h_u := _sample_loaded_surface_height(wx, wz - step)
	var h_d := _sample_loaded_surface_height(wx, wz + step)
	return Vector3(-(h_r - h_l) / (2.0 * step), 1.0, -(h_d - h_u) / (2.0 * step)).normalized()


func sample_surface_color_at_world(world_x: float, world_z: float, world_y: float = INF) -> Color:
	var surface_y := world_y
	if not is_finite(surface_y):
		surface_y = _sample_loaded_surface_height(world_x, world_z)
	var sea := _config.sea_level
	var hs := _config.height_scale
	var base_color := _surface_color(surface_y, sea, hs)
	if surface_y < sea - 0.1:
		return base_color
	var biome_sys := _find_system_by_type(BiomeSystem) as BiomeSystem
	var biome_data: BiomeData = null
	if biome_sys:
		var biome_idx := biome_sys.get_biome_at_world(world_x, world_z, surface_y, sea, hs)
		biome_data = biome_sys.get_biome_data(biome_idx)
	var blended_color := base_color
	if biome_data:
		blended_color = base_color.lerp(biome_data.terrain_color, 0.68)
	var sample_step := GameConfig.chunk_size / maxf(float(_config.chunk_resolution - 1), 1.0)
	var normal := _sample_loaded_surface_normal(world_x, world_z, sample_step)
	return _apply_surface_detail_color(blended_color, biome_data, world_x, surface_y, world_z, normal, sea, hs)


## Sample biome color from the precomputed grid with bilinear interpolation
func _sample_biome_color_grid(grid: PackedColorArray, res: int,
		local_x: float, local_z: float, step: float) -> Color:
	var fx := local_x / step
	var fz := local_z / step
	var gx := clampi(int(fx), 0, res - 2)
	var gz := clampi(int(fz), 0, res - 2)
	var tx := clampf(fx - float(gx), 0.0, 1.0)
	var tz := clampf(fz - float(gz), 0.0, 1.0)

	var c00 := grid[gz * res + gx]
	var c10 := grid[gz * res + gx + 1]
	var c01 := grid[(gz + 1) * res + gx]
	var c11 := grid[(gz + 1) * res + gx + 1]

	var top := c00.lerp(c10, tx)
	var bot := c01.lerp(c11, tx)
	return top.lerp(bot, tz)


func _recolor_chunk_biomes(coord: Vector2i, biome_map: PackedByteArray) -> void:
	var mesh_inst: MeshInstance3D = _chunk_meshes[coord]
	if not mesh_inst or not mesh_inst.mesh:
		return

	var heightmap: PackedFloat32Array = _chunk_heightmaps[coord]
	var res_xz := _config.chunk_resolution
	var cs := GameConfig.chunk_size
	var step_xz := cs / float(res_xz - 1)

	var biome_sys: BiomeSystem = _find_system_by_type(BiomeSystem) as BiomeSystem
	if not biome_sys:
		return

	var sea := _config.sea_level
	var hs := _config.height_scale

	# Precompute biome color per grid cell using already-computed biome_map (zero noise)
	var biome_grid := _build_biome_color_grid(biome_sys, biome_map, heightmap)

	# Read existing mesh arrays — preserve normals to avoid per-chunk normal seams
	var old_mesh: ArrayMesh = mesh_inst.mesh
	if old_mesh.get_surface_count() == 0:
		return

	var arrays := old_mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	if verts.is_empty():
		return

	var has_normals := normals.size() == verts.size()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for vi in verts.size():
		var v := verts[vi]

		# Check if underground (cave)
		var hm_x := clampi(int(v.x / step_xz), 0, res_xz - 1)
		var hm_z := clampi(int(v.z / step_xz), 0, res_xz - 1)
		var surface_h := heightmap[hm_z * res_xz + hm_x]
		var is_cave := v.y < surface_h - _config.cave_min_depth * 0.5

		var color: Color
		if is_cave:
			color = _cave_color(v.y, surface_h)
		elif v.y < sea - 0.1:
			color = _surface_color(v.y, sea, hs)
		else:
			# Bilinear interpolation from precomputed grid (smooth + fast)
			color = _sample_biome_color_grid(biome_grid, res_xz, v.x, v.z, step_xz)
			var biome_data: BiomeData = biome_sys.get_biome_data(biome_map[hm_z * res_xz + hm_x])
			var vertex_normal := normals[vi] if has_normals else Vector3.UP
			var world_x := float(coord.x) * GameConfig.chunk_size + v.x
			var world_z := float(coord.y) * GameConfig.chunk_size + v.z
			color = _apply_surface_detail_color(color, biome_data, world_x, v.y, world_z, vertex_normal, sea, hs)

		if has_normals:
			st.set_normal(normals[vi])
		st.set_color(color)
		st.add_vertex(v)

	if not has_normals:
		st.generate_normals()
	mesh_inst.mesh = st.commit()


## Create a trimesh StaticBody3D collision shape from the terrain mesh
func _create_chunk_collision(coord: Vector2i, mesh_instance: MeshInstance3D) -> void:
	if not mesh_instance.mesh or mesh_instance.mesh.get_surface_count() == 0:
		return
	_create_chunk_collision_from_faces(coord, mesh_instance.mesh.get_faces())


## The marching-cubes output is already a triangle soup, so its vertex array
## IS the collision face list — no need to round-trip it through the mesh.
func _create_chunk_collision_from_faces(coord: Vector2i, faces: PackedVector3Array) -> void:
	var body := StaticBody3D.new()
	body.name = "ChunkBody_%d_%d" % [coord.x, coord.y]

	if faces.is_empty():
		body.queue_free()
		return
	var shape := ConcavePolygonShape3D.new()

	shape.set_faces(faces)
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)

	# Same origin the chunk mesh uses — derived from the coord rather than
	# read off the MeshInstance, so collision can be built without one.
	var chunk_centre := SharedWorld.chunk_to_world(coord)
	body.position = Vector3(
		chunk_centre.x - GameConfig.chunk_size * 0.5,
		0.0,
		chunk_centre.z - GameConfig.chunk_size * 0.5
	)
	add_child(body)
	_chunk_bodies[coord] = body


func _remove_chunk_mesh(coord: Vector2i) -> void:
	if _chunk_meshes.has(coord):
		var mesh_inst: MeshInstance3D = _chunk_meshes[coord]
		mesh_inst.queue_free()
		_chunk_meshes.erase(coord)
	if _chunk_bodies.has(coord):
		var body: StaticBody3D = _chunk_bodies[coord]
		body.queue_free()
		_chunk_bodies.erase(coord)
	if _chunk_debug_nodes.has(coord):
		var dbg: Node3D = _chunk_debug_nodes[coord]
		dbg.queue_free()
		_chunk_debug_nodes.erase(coord)
	_chunk_heightmaps.erase(coord)


# ── Cave debug visualization ───────────────────────────────────────────────

func _debug_draw_cave_voids(coord: Vector2i, density: PackedFloat32Array,
		res_xz: int, res_y: int, surface_hm: PackedFloat32Array) -> void:
	var cs := GameConfig.chunk_size
	var step_xz := cs / float(res_xz - 1)
	var min_y := _config.grid_min_y
	var step_y := (_config.grid_max_y - min_y) / float(res_y - 1)
	var iso := _config.surface_threshold
	var ss := res_xz * res_xz
	var cave_min_d := _config.cave_min_depth

	var world_pos := SharedWorld.chunk_to_world(coord)
	var chunk_origin := Vector3(
		world_pos.x - cs * 0.5,
		0.0,
		world_pos.z - cs * 0.5
	)

	var debug_root := Node3D.new()
	debug_root.name = "CaveDebug_%d_%d" % [coord.x, coord.y]

	# Shared debug material: bright red, unshaded
	var debug_mat := StandardMaterial3D.new()
	debug_mat.albedo_color = Color(1.0, 0.15, 0.1, 0.7)
	debug_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	debug_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	debug_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = step_xz * 0.3
	sphere_mesh.height = step_xz * 0.6
	sphere_mesh.radial_segments = 6
	sphere_mesh.rings = 3

	var cave_count := 0
	var sample_step := 2  # Sample every 2nd voxel for performance

	for gy in range(0, res_y, sample_step):
		var world_y := min_y + float(gy) * step_y
		for gz in range(0, res_xz, sample_step):
			for gx in range(0, res_xz, sample_step):
				var d := density[gy * ss + gz * res_xz + gx]
				if d >= iso:
					continue  # Solid, not a void

				# Check if this void is underground (cave) vs sky
				var surface_h := surface_hm[gz * res_xz + gx]
				if world_y >= surface_h - cave_min_d * 0.3:
					continue  # Near or above surface, not a cave

				var local_pos := Vector3(
					float(gx) * step_xz,
					world_y,
					float(gz) * step_xz
				)

				var mi := MeshInstance3D.new()
				mi.mesh = sphere_mesh
				mi.material_override = debug_mat
				mi.position = local_pos
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				debug_root.add_child(mi)
				cave_count += 1

	debug_root.position = chunk_origin
	add_child(debug_root)
	_chunk_debug_nodes[coord] = debug_root

	if cave_count > 0:
		print("[TerrainSystem] Cave debug: chunk %s has %d cave voids" % [str(coord), cave_count])
	else:
		print("[TerrainSystem] Cave debug: chunk %s has NO cave voids" % str(coord))




func _shutdown() -> void:
	# Never tear down while a worker is still writing into our dictionaries.
	for task_id in _gen_tasks.values():
		WorkerThreadPool.wait_for_task_completion(int(task_id))
	_gen_tasks.clear()
	_gen_queue.clear()
	_gen_results.clear()
	for coord in _chunk_meshes.keys():
		_remove_chunk_mesh(coord)
