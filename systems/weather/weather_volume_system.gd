class_name WeatherVolumeSystem
extends BaseSystem

const WEATHER_SYSTEM_SCRIPT = preload("res://systems/weather/weather_system.gd")
const WEATHER_VOLUME_CONFIG_SCRIPT = preload("res://systems/weather/weather_volume_config.gd")
const BIOME_SYSTEM_SCRIPT = preload("res://systems/biome/biome_system.gd")
const CHUNK_MANAGER_SCRIPT = preload("res://systems/base/chunk_manager.gd")

var _config: WeatherVolumeConfig
var _weather_system: WeatherSystem
var _biome_system: BiomeSystem
var _chunk_manager: BaseSystem
var _environment: Environment
var _update_timer: float = 0.0

## chunk_coord -> Node3D
var _chunk_volumes: Dictionary = {}


func _initialize() -> void:
	system_name = &"WeatherVolumeSystem"
	priority = 22

	_config = _find_child_of_type(WEATHER_VOLUME_CONFIG_SCRIPT)
	if not _config:
		push_warning("[WeatherVolumeSystem] No WeatherVolumeConfig child found — using defaults")
		_config = WeatherVolumeConfig.new()

	_weather_system = _find_system_by_type(WEATHER_SYSTEM_SCRIPT) as WeatherSystem
	_biome_system = _find_system_by_type(BIOME_SYSTEM_SCRIPT) as BiomeSystem
	_chunk_manager = _find_system_by_type(CHUNK_MANAGER_SCRIPT)
	_ensure_volumetric_fog_environment()


func _register_signals() -> void:
	SystemBus.terrain_chunk_ready.connect(_on_terrain_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)


func system_process(delta: float) -> void:
	if not active:
		return
	_update_timer += delta
	if _update_timer < _config.update_interval:
		return
	_update_timer = 0.0
	_ensure_volumetric_fog_environment()
	_refresh_active_chunk_volumes()


func _shutdown() -> void:
	for coord_variant in _chunk_volumes.keys():
		_clear_chunk_volume(coord_variant)


func _on_terrain_chunk_ready(coord: Vector2i, heightmap: PackedFloat32Array) -> void:
	_rebuild_chunk_volume(coord, heightmap)


func _on_chunk_unload_requested(coord: Vector2i) -> void:
	_clear_chunk_volume(coord)


func _refresh_active_chunk_volumes() -> void:
	if not _chunk_manager:
		_chunk_manager = _find_system_by_type(CHUNK_MANAGER_SCRIPT)
	if not _chunk_manager:
		return
	var chunk_manager := _chunk_manager as ChunkManager
	if not chunk_manager:
		return
	for coord_variant in chunk_manager.active_chunks.keys():
		var coord: Vector2i = coord_variant
		var chunk_data: ChunkData = chunk_manager.get_chunk(coord)
		if not chunk_data or not chunk_data.terrain_ready or chunk_data.heightmap.is_empty():
			continue
		_rebuild_chunk_volume(coord, chunk_data.heightmap)


func _rebuild_chunk_volume(coord: Vector2i, heightmap: PackedFloat32Array) -> void:
	var descriptors := _build_volume_descriptors(coord, heightmap)
	if descriptors.is_empty():
		_clear_chunk_volume(coord)
		return

	var volume_root := _chunk_volumes.get(coord, null) as Node3D
	if not is_instance_valid(volume_root):
		volume_root = Node3D.new()
		volume_root.name = "WeatherVolume_%d_%d" % [coord.x, coord.y]
		add_child(volume_root)
		_chunk_volumes[coord] = volume_root

	while volume_root.get_child_count() > descriptors.size():
		volume_root.get_child(volume_root.get_child_count() - 1).queue_free()

	for i in range(descriptors.size()):
		var descriptor: Dictionary = descriptors[i]
		var fog_volume: FogVolume
		if i < volume_root.get_child_count() and volume_root.get_child(i) is FogVolume:
			fog_volume = volume_root.get_child(i) as FogVolume
		else:
			fog_volume = FogVolume.new()
			fog_volume.name = "FogTile_%d" % i
			volume_root.add_child(fog_volume)
		var material: FogMaterial
		if fog_volume.material is FogMaterial:
			material = fog_volume.material as FogMaterial
		else:
			material = FogMaterial.new()
			fog_volume.material = material
		fog_volume.position = descriptor["position"]
		fog_volume.size = descriptor["size"]
		material.albedo = descriptor["color"]
		material.density = float(descriptor["density"])
		material.edge_fade = _config.edge_fade
		material.height_falloff = float(descriptor["height_falloff"])


func _build_volume_descriptors(coord: Vector2i, heightmap: PackedFloat32Array) -> Array[Dictionary]:
	var descriptors: Array[Dictionary] = []
	var res := int(sqrt(heightmap.size()))
	if res <= 1:
		return descriptors
	var cs := GameConfig.chunk_size
	var origin_x := float(coord.x) * cs
	var origin_z := float(coord.y) * cs
	var tile_count := maxi(_config.tiles_per_axis, 1)
	var tile_span := cs / float(tile_count)
	for tile_z in range(tile_count):
		for tile_x in range(tile_count):
			var center_x := origin_x + (float(tile_x) + 0.5) * tile_span
			var center_z := origin_z + (float(tile_z) + 0.5) * tile_span
			var terrain_y := _sample_heightmap_region(heightmap, tile_x, tile_z, tile_count)
			var relief := _sample_heightmap_relief(heightmap, tile_x, tile_z, tile_count)
			var local_rain := _get_local_rain(center_x, center_z)
			var biome_name := _get_biome_name(center_x, center_z, terrain_y)
			var tile_size := Vector3(tile_span * _config.chunk_coverage_multiplier, 1.0, tile_span * _config.chunk_coverage_multiplier)
			if _should_spawn_sand_haze(biome_name, local_rain):
				var sand_height := _config.sand_haze_height * lerpf(0.9, 1.15, clampf(relief / 8.0, 0.0, 1.0))
				descriptors.append({
					"position": Vector3(center_x, terrain_y + _config.sand_haze_height_offset + sand_height * 0.5, center_z),
					"size": Vector3(tile_size.x, sand_height, tile_size.z),
					"color": _blend_natural_fog_color(_config.sand_haze_color, _config.sand_haze_color, 0.25),
					"density": lerpf(_config.sand_haze_density * 0.72, _config.sand_haze_density, clampf(SharedWorld.wind_strength / maxf(_config.sand_haze_wind_threshold * 1.8, 0.001), 0.0, 1.0)),
					"height_falloff": _config.sand_haze_height_falloff,
				})
			elif local_rain >= _config.rain_mist_threshold:
				var rain_height := _config.rain_mist_height * lerpf(0.9, 1.1, clampf(relief / 10.0, 0.0, 1.0))
				var rain_density := lerpf(_config.rain_mist_density * 0.5, _config.rain_mist_density, pow(local_rain, 0.85))
				var rain_color := _blend_natural_fog_color(_config.rain_mist_color, Color(0.72, 0.77, 0.82, 1.0), 0.2 + local_rain * 0.25)
				descriptors.append({
					"position": Vector3(center_x, terrain_y + _config.rain_mist_height_offset + rain_height * 0.5, center_z),
					"size": Vector3(tile_size.x, rain_height, tile_size.z),
					"color": rain_color,
					"density": rain_density,
					"height_falloff": _config.rain_mist_height_falloff,
				})
	return descriptors


func _sample_heightmap_region(heightmap: PackedFloat32Array, tile_x: int, tile_z: int, tile_count: int) -> float:
	var res := int(sqrt(heightmap.size()))
	if res <= 0:
		return 0.0
	var start_x := int(floor(float(tile_x) * float(res - 1) / float(tile_count)))
	var end_x := maxi(start_x + 1, int(ceili(float(tile_x + 1) * float(res - 1) / float(tile_count))))
	var start_z := int(floor(float(tile_z) * float(res - 1) / float(tile_count)))
	var end_z := maxi(start_z + 1, int(ceili(float(tile_z + 1) * float(res - 1) / float(tile_count))))
	var sum := 0.0
	var count := 0
	for z in range(start_z, mini(end_z + 1, res)):
		for x in range(start_x, mini(end_x + 1, res)):
			sum += heightmap[z * res + x]
			count += 1
	return sum / float(maxi(count, 1))


func _sample_heightmap_relief(heightmap: PackedFloat32Array, tile_x: int, tile_z: int, tile_count: int) -> float:
	var res := int(sqrt(heightmap.size()))
	if res <= 0:
		return 0.0
	var start_x := int(floor(float(tile_x) * float(res - 1) / float(tile_count)))
	var end_x := maxi(start_x + 1, int(ceili(float(tile_x + 1) * float(res - 1) / float(tile_count))))
	var start_z := int(floor(float(tile_z) * float(res - 1) / float(tile_count)))
	var end_z := maxi(start_z + 1, int(ceili(float(tile_z + 1) * float(res - 1) / float(tile_count))))
	var min_h := INF
	var max_h := -INF
	for z in range(start_z, mini(end_z + 1, res)):
		for x in range(start_x, mini(end_x + 1, res)):
			var h := heightmap[z * res + x]
			min_h = minf(min_h, h)
			max_h = maxf(max_h, h)
	if not is_finite(min_h) or not is_finite(max_h):
		return 0.0
	return max_h - min_h


func _blend_natural_fog_color(base_color: Color, target_color: Color, amount: float) -> Color:
	var environment_color := base_color
	if _environment:
		environment_color = _environment.fog_light_color
	var blend := clampf(amount, 0.0, 1.0)
	var result := environment_color.lerp(base_color, 0.45).lerp(target_color, blend)
	result.r = clampf(result.r, 0.38, 0.92)
	result.g = clampf(result.g, 0.40, 0.94)
	result.b = clampf(result.b, 0.42, 0.96)
	result.a = 1.0
	return result


func _should_spawn_sand_haze(biome_name: StringName, local_rain: float) -> bool:
	if biome_name not in _config.sand_haze_biomes:
		return false
	if SharedWorld.wind_strength < _config.sand_haze_wind_threshold:
		return false
	if local_rain > _config.sand_haze_max_local_rain:
		return false
	return SharedWorld.weather_state == &"storm" or SharedWorld.weather_state == &"cloudy"


func _sample_heightmap_center(heightmap: PackedFloat32Array) -> float:
	var res := int(sqrt(heightmap.size()))
	if res <= 0:
		return 0.0
	var center_a := maxi(int(floor(float(res - 1) * 0.5)), 0)
	var center_b := mini(center_a + 1, res - 1)
	var sum := 0.0
	var count := 0
	for z in range(center_a, center_b + 1):
		for x in range(center_a, center_b + 1):
			sum += heightmap[z * res + x]
			count += 1
	return sum / float(maxi(count, 1))


func _get_local_rain(world_x: float, world_z: float) -> float:
	if not _weather_system:
		_weather_system = _find_system_by_type(WEATHER_SYSTEM_SCRIPT) as WeatherSystem
	if _weather_system:
		return _weather_system.get_local_weather(world_x, world_z)
	return SharedWorld.rain_intensity


func _get_biome_name(world_x: float, world_z: float, terrain_y: float) -> StringName:
	if not _biome_system:
		_biome_system = _find_system_by_type(BIOME_SYSTEM_SCRIPT) as BiomeSystem
	if _biome_system:
		var biome_idx := _biome_system.get_biome_at_world(world_x, world_z, terrain_y, SharedWorld.sea_level, SharedWorld.height_scale)
		return _biome_system.get_biome_name(biome_idx)
	return SharedWorld.active_biome_name


func _ensure_volumetric_fog_environment() -> void:
	if _environment:
		_environment.volumetric_fog_enabled = true
		_environment.volumetric_fog_density = 0.0
		return
	var world_environment := _find_world_environment()
	if not world_environment or not world_environment.environment:
		return
	_environment = world_environment.environment
	_environment.volumetric_fog_enabled = true
	_environment.volumetric_fog_density = 0.0


func _find_world_environment() -> WorldEnvironment:
	var root := get_tree().current_scene
	if not root:
		return null
	return _find_node_of_type(root, WorldEnvironment) as WorldEnvironment


func _clear_chunk_volume(coord: Vector2i) -> void:
	if not _chunk_volumes.has(coord):
		return
	var fog_volume := _chunk_volumes[coord] as Node3D
	_chunk_volumes.erase(coord)
	if is_instance_valid(fog_volume):
		fog_volume.queue_free()
