class_name BiomeSystem
extends BaseSystem

const GEO_SYSTEM_SCRIPT = preload("res://systems/geo/geo_system.gd")

## Maps terrain chunks to biome data using temperature + moisture noise layers.
## Biomes are auto-discovered as BiomeData children — just drop .tscn scenes in.
## Listens for terrain_chunk_ready, emits biome_chunk_ready.

var _config: BiomeConfig
var _temp_noise: FastNoiseLite
var _moisture_noise: FastNoiseLite
var _warp_noise_x: FastNoiseLite
var _warp_noise_z: FastNoiseLite
var _geo_system: GeoSystem

## Auto-discovered biome list (populated from children)
var _biomes: Array[BiomeData] = []

## Chunk coord → PackedByteArray biome map
var _chunk_biomes: Dictionary = {}


func _initialize() -> void:
	system_name = &"BiomeSystem"
	priority = 10

	_config = _find_child_of_type(BiomeConfig)
	if not _config:
		push_warning("[BiomeSystem] No BiomeConfig child found — creating defaults")
		_config = BiomeConfig.new()

	# Auto-discover all BiomeData children (wired in biome_system.tscn)
	_discover_biomes()

	if _biomes.is_empty():
		push_warning("[BiomeSystem] No BiomeData children found — add biome scenes as children of BiomeSystem")

	_setup_noise()
	print("[BiomeSystem] Registered %d biomes: %s" % [_biomes.size(), _get_biome_names()])


func _register_signals() -> void:
	SystemBus.terrain_chunk_ready.connect(_on_terrain_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)


func _setup_noise() -> void:
	# Climate is a macro field. Left unset, FastNoiseLite runs 5 FBM octaves
	# and the top one lands at detail scale, which speckles the biome map.
	_temp_noise = FastNoiseLite.new()
	_temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_temp_noise.seed = GameConfig.world_seed + _config.temperature_seed_offset
	_temp_noise.frequency = _config.temperature_frequency
	_temp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_temp_noise.fractal_octaves = _config.climate_octaves

	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.seed = GameConfig.world_seed + _config.moisture_seed_offset
	_moisture_noise.frequency = _config.moisture_frequency
	_moisture_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_moisture_noise.fractal_octaves = _config.climate_octaves

	_warp_noise_x = FastNoiseLite.new()
	_warp_noise_x.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise_x.seed = GameConfig.world_seed + 7331
	_warp_noise_x.frequency = _config.climate_warp_frequency
	_warp_noise_x.fractal_type = FastNoiseLite.FRACTAL_NONE

	_warp_noise_z = FastNoiseLite.new()
	_warp_noise_z.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_warp_noise_z.seed = GameConfig.world_seed + 9173
	_warp_noise_z.frequency = _config.climate_warp_frequency
	_warp_noise_z.fractal_type = FastNoiseLite.FRACTAL_NONE


func _on_terrain_chunk_ready(coord: Vector2i, heightmap: PackedFloat32Array) -> void:
	var biome_map := _generate_biome_map(coord, heightmap)
	_chunk_biomes[coord] = biome_map
	SystemBus.biome_chunk_ready.emit(coord, biome_map)


func _on_chunk_unload_requested(coord: Vector2i) -> void:
	_chunk_biomes.erase(coord)


## Generate biome map for a chunk — one byte per cell (biome index)
func _generate_biome_map(coord: Vector2i, heightmap: PackedFloat32Array) -> PackedByteArray:
	var res := int(sqrt(heightmap.size()))
	var cs := GameConfig.chunk_size
	var step := cs / float(res - 1)
	var origin_x := coord.x * cs
	var origin_z := coord.y * cs

	var biome_map := PackedByteArray()
	biome_map.resize(res * res)

	var height_scale := SharedWorld.height_scale
	var sea_level := SharedWorld.sea_level

	for z in res:
		for x in res:
			var world_x := origin_x + x * step
			var world_z := origin_z + z * step

			# Climate is sampled at a WARPED position, so biome borders meander
			# instead of following the smooth gradients of the raw fields.
			var climate := _warp_climate_position(world_x, world_z)
			# Noise returns -1..1, remap to 0..1
			var temperature_noise := (_temp_noise.get_noise_2d(climate.x, climate.y) + 1.0) * 0.5
			var moisture_noise := (_moisture_noise.get_noise_2d(climate.x, climate.y) + 1.0) * 0.5

			# Normalize height: sea_level = 0.0, max terrain = 1.0
			var h := heightmap[z * res + x]
			var height_normalized := clampf((h - sea_level) / height_scale, 0.0, 1.0)

			var temperature := _get_temperature_at_world(world_x, world_z, temperature_noise)
			var moisture := _get_moisture_at_world(world_x, world_z, moisture_noise, height_normalized)

			var biome_idx := _find_biome_at(temperature, moisture, height_normalized,
				world_x, world_z)
			biome_map[z * res + x] = biome_idx

	return biome_map


# ── Biome discovery ─────────────────────────────────────────────────────────────

## Scan all children (recursive) for BiomeData nodes and register them
func _discover_biomes() -> void:
	_biomes.clear()
	_collect_biome_children(self)


func _collect_biome_children(node: Node) -> void:
	for child in node.get_children():
		if child is BiomeData:
			_biomes.append(child)
		_collect_biome_children(child)


func _get_biome_names() -> String:
	var names: PackedStringArray = []
	for b in _biomes:
		names.append(str(b.biome_name))
	return ", ".join(names)


## Displace the climate lookup position by a low-frequency noise field.
##
## Domain warping is the cheapest way to make a procedural boundary look grown
## rather than drawn: two extra noise samples turn every straight-ish climate
## gradient into a meandering, fractal-edged border. The climate itself is
## unchanged — only where each point reads it from.
func _warp_climate_position(world_x: float, world_z: float) -> Vector2:
	if not _config.climate_warp_enabled:
		return Vector2(world_x, world_z)
	var strength := _config.climate_warp_strength
	return Vector2(
		world_x + _warp_noise_x.get_noise_2d(world_x, world_z) * strength,
		world_z + _warp_noise_z.get_noise_2d(world_x, world_z) * strength)


## Find the best-scoring biome index using weighted scoring.
##
## Kept for callers that only have a climate triple; prefer _find_biome_at(),
## which also interleaves the ecotone.
func _find_biome(temperature: float, moisture: float, height_normalized: float) -> int:
	var best_idx := -1
	var best_score := 0.0
	for i in _biomes.size():
		if not _biomes[i].surface_biome:
			continue
		var s: float = _biomes[i].score(temperature, moisture, height_normalized)
		if s > best_score:
			best_score = s
			best_idx = i
	if best_idx >= 0:
		return best_idx
	return _nearest_biome(temperature, moisture, height_normalized)


## Best biome at a world position, with an interleaved ecotone at the borders.
##
## Two biomes whose scores are within ecotone_blend of each other are both
## plausible there, so which one wins is decided by a stable hash of the
## position. The border stops being a line and becomes a belt where the two
## interlock — the way a treeline actually meets a meadow.
func _find_biome_at(temperature: float, moisture: float, height_normalized: float,
		world_x: float, world_z: float) -> int:
	var best_idx := -1
	var best_score := 0.0
	var runner_idx := -1
	var runner_score := 0.0
	for i in _biomes.size():
		if not _biomes[i].surface_biome:
			continue
		var s: float = _biomes[i].score(temperature, moisture, height_normalized)
		if s > best_score:
			runner_idx = best_idx
			runner_score = best_score
			best_score = s
			best_idx = i
		elif s > runner_score:
			runner_score = s
			runner_idx = i

	if best_idx < 0:
		return _nearest_biome(temperature, moisture, height_normalized)
	if runner_idx < 0 or _config.ecotone_blend <= 0.0 or best_score <= 0.0:
		return best_idx

	# How deep into the transition belt this point sits, 0 at the middle of a
	# biome and 1 where the two are tied.
	var closeness := runner_score / best_score
	var belt := 1.0 - clampf((1.0 - closeness) / _config.ecotone_blend, 0.0, 1.0)
	if belt <= 0.0:
		return best_idx
	var scale := maxf(_config.ecotone_scale, 0.001)
	var mix_noise := (_temp_noise.get_noise_2d(world_x / scale * 37.0,
		world_z / scale * 37.0) + 1.0) * 0.5
	return runner_idx if mix_noise < belt * 0.5 else best_idx


## Nearest biome by soft affinity, for climates no biome's tolerance covers.
func _nearest_biome(temperature: float, moisture: float, height_normalized: float) -> int:
	var best_idx := 0
	var best := -1.0
	for i in _biomes.size():
		if not _biomes[i].surface_biome:
			continue
		var a: float = _biomes[i].affinity(temperature, moisture, height_normalized)
		if a > best:
			best = a
			best_idx = i
	return best_idx


func _get_geo_system() -> GeoSystem:
	if not _geo_system:
		_geo_system = _find_system_by_type(GEO_SYSTEM_SCRIPT) as GeoSystem
	return _geo_system


func _get_temperature_at_world(world_x: float, world_z: float, noise_temperature: float) -> float:
	var geo_system := _get_geo_system()
	if geo_system:
		return geo_system.blend_biome_temperature(noise_temperature, world_x, world_z)
	return _apply_macro_temperature(world_z, noise_temperature)


func _get_moisture_at_world(world_x: float, world_z: float,
		noise_moisture: float, height_normalized: float) -> float:
	var geo_system := _get_geo_system()
	if geo_system:
		return geo_system.blend_biome_moisture(noise_moisture, world_x, world_z, height_normalized)
	return _apply_macro_moisture(height_normalized, noise_moisture)


func _apply_macro_temperature(world_z: float, noise_temperature: float) -> float:
	if not _config.use_latitude_temperature:
		return noise_temperature
	var latitude_phase := world_z * _config.latitude_scale
	var latitude_temperature := 1.0 - absf(sin(latitude_phase))
	return clampf(
		lerpf(noise_temperature, latitude_temperature, _config.latitude_temperature_strength),
		0.0,
		1.0
	)


func _apply_macro_moisture(height_normalized: float, noise_moisture: float) -> float:
	var altitude_loss := height_normalized * _config.altitude_moisture_loss
	return clampf(noise_moisture - altitude_loss, 0.0, 1.0)


# ── Utilities ─────────────────────────────────────────────────────────────────

func get_biome_name(index: int) -> StringName:
	if index >= 0 and index < _biomes.size():
		return _biomes[index].biome_name
	return &"unknown"


func get_biome_data(index: int) -> BiomeData:
	if index >= 0 and index < _biomes.size():
		return _biomes[index]
	return null


func get_biome_count() -> int:
	return _biomes.size()


## Returns moisture value (0.0–1.0) at a world XZ position.
## Used by WeatherSystem for local weather modulation.
func get_moisture_at_world(world_x: float, world_z: float) -> float:
	var climate := _warp_climate_position(world_x, world_z)
	var moisture_noise := (_moisture_noise.get_noise_2d(climate.x, climate.y) + 1.0) * 0.5
	return _get_moisture_at_world(world_x, world_z, moisture_noise, 0.0)


## Compute biome index at a world position using only world-space noise.
## Uses vertex_y for height normalization instead of per-chunk heightmap.
func get_biome_at_world(world_x: float, world_z: float, vertex_y: float,
		sea_level: float, height_scale: float) -> int:
	# Same warped sample position and same ecotone rule as the chunk biome
	# map. Terrain colouring reads this one, so any divergence shows up as
	# vertex colours that disagree with the flora standing on them.
	var climate := _warp_climate_position(world_x, world_z)
	var temperature_noise := (_temp_noise.get_noise_2d(climate.x, climate.y) + 1.0) * 0.5
	var moisture_noise := (_moisture_noise.get_noise_2d(climate.x, climate.y) + 1.0) * 0.5
	var height_normalized := clampf((vertex_y - sea_level) / height_scale, 0.0, 1.0)
	var temperature := _get_temperature_at_world(world_x, world_z, temperature_noise)
	var moisture := _get_moisture_at_world(world_x, world_z, moisture_noise, height_normalized)
	return _find_biome_at(temperature, moisture, height_normalized, world_x, world_z)
