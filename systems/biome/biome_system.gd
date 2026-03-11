class_name BiomeSystem
extends BaseSystem

const GEO_SYSTEM_SCRIPT = preload("res://systems/geo/geo_system.gd")

## Maps terrain chunks to biome data using temperature + moisture noise layers.
## Biomes are auto-discovered as BiomeData children — just drop .tscn scenes in.
## Listens for terrain_chunk_ready, emits biome_chunk_ready.

var _config: BiomeConfig
var _temp_noise: FastNoiseLite
var _moisture_noise: FastNoiseLite
var _geo_system

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
	_temp_noise = FastNoiseLite.new()
	_temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_temp_noise.seed = GameConfig.world_seed + _config.temperature_seed_offset
	_temp_noise.frequency = _config.temperature_frequency

	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.seed = GameConfig.world_seed + _config.moisture_seed_offset
	_moisture_noise.frequency = _config.moisture_frequency


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

			# Noise returns -1..1, remap to 0..1
			var temperature_noise := (_temp_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
			var moisture_noise := (_moisture_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5

			# Normalize height: sea_level = 0.0, max terrain = 1.0
			var h := heightmap[z * res + x]
			var height_normalized := clampf((h - sea_level) / height_scale, 0.0, 1.0)

			var temperature := _get_temperature_at_world(world_x, world_z, temperature_noise)
			var moisture := _get_moisture_at_world(world_x, world_z, moisture_noise, height_normalized)

			var biome_idx := _find_biome(temperature, moisture, height_normalized)
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


## Find the best-scoring biome index using weighted scoring
func _find_biome(temperature: float, moisture: float, height_normalized: float) -> int:
	var best_idx := 0
	var best_score := 0.0
	for i in _biomes.size():
		var s: float = _biomes[i].score(temperature, moisture, height_normalized)
		if s > best_score:
			best_score = s
			best_idx = i
	return best_idx


func _get_geo_system():
	if not _geo_system:
		_geo_system = _find_system_by_type(GEO_SYSTEM_SCRIPT)
	return _geo_system


func _get_temperature_at_world(world_x: float, world_z: float, noise_temperature: float) -> float:
	var geo_system = _get_geo_system()
	if geo_system and geo_system.has_method("blend_biome_temperature"):
		return geo_system.blend_biome_temperature(noise_temperature, world_x, world_z)
	return _apply_macro_temperature(world_z, noise_temperature)


func _get_moisture_at_world(world_x: float, world_z: float,
		noise_moisture: float, height_normalized: float) -> float:
	var geo_system = _get_geo_system()
	if geo_system and geo_system.has_method("blend_biome_moisture"):
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
	var moisture_noise := (_moisture_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
	return _get_moisture_at_world(world_x, world_z, moisture_noise, 0.0)


## Compute biome index at a world position using only world-space noise.
## Uses vertex_y for height normalization instead of per-chunk heightmap.
func get_biome_at_world(world_x: float, world_z: float, vertex_y: float,
		sea_level: float, height_scale: float) -> int:
	var temperature_noise := (_temp_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
	var moisture_noise := (_moisture_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
	var height_normalized := clampf((vertex_y - sea_level) / height_scale, 0.0, 1.0)
	var temperature := _get_temperature_at_world(world_x, world_z, temperature_noise)
	var moisture := _get_moisture_at_world(world_x, world_z, moisture_noise, height_normalized)
	return _find_biome(temperature, moisture, height_normalized)
