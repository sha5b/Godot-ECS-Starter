class_name GeoSystem
extends BaseSystem

const GEO_CONFIG_SCRIPT = preload("res://systems/geo/geo_config.gd")

var _config
var _temperature_noise: FastNoiseLite
var _precipitation_noise: FastNoiseLite
var _continentality_noise: FastNoiseLite
var _basin_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite


func _initialize() -> void:
	system_name = &"GeoSystem"
	priority = -50

	_config = _find_child_of_type(GEO_CONFIG_SCRIPT)
	if not _config:
		push_warning("[GeoSystem] No GeoConfig child found — using defaults")
		_config = GEO_CONFIG_SCRIPT.new()

	_setup_noise()


func _setup_noise() -> void:
	_temperature_noise = FastNoiseLite.new()
	_temperature_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_temperature_noise.seed = GameConfig.world_seed + 3000
	_temperature_noise.frequency = _config.temperature_frequency

	_precipitation_noise = FastNoiseLite.new()
	_precipitation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_precipitation_noise.seed = GameConfig.world_seed + 3100
	_precipitation_noise.frequency = _config.precipitation_frequency

	_continentality_noise = FastNoiseLite.new()
	_continentality_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_continentality_noise.seed = GameConfig.world_seed + 3200
	_continentality_noise.frequency = _config.continentality_frequency

	_basin_noise = FastNoiseLite.new()
	_basin_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_basin_noise.seed = GameConfig.world_seed + 3300
	_basin_noise.frequency = _config.basin_frequency

	_ridge_noise = FastNoiseLite.new()
	_ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_ridge_noise.seed = GameConfig.world_seed + 3400
	_ridge_noise.frequency = _config.ridge_frequency


func blend_biome_temperature(local_temperature_noise: float, world_x: float, world_z: float) -> float:
	return clampf(
		lerpf(local_temperature_noise, get_macro_temperature(world_x, world_z),
			_config.biome_temperature_macro_blend),
		0.0,
		1.0
	)


func blend_biome_moisture(local_moisture_noise: float,
		world_x: float, world_z: float, height_normalized: float) -> float:
	return clampf(
		lerpf(local_moisture_noise, get_macro_moisture(world_x, world_z, height_normalized),
			_config.biome_moisture_macro_blend),
		0.0,
		1.0
	)


func get_macro_temperature(world_x: float, world_z: float) -> float:
	var noise_value := (_temperature_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
	var latitude_value := _sample_latitude_temperature(world_z)
	var continentality := _sample_continentality(world_x, world_z)
	var temperature := lerpf(noise_value, latitude_value, _config.latitude_temperature_strength)
	temperature -= continentality * _config.continental_temperature_loss
	temperature += _sample_temperature_season_bias() * _config.season_temperature_strength
	return clampf(temperature, 0.0, 1.0)


func get_macro_moisture(world_x: float, world_z: float, height_normalized: float = 0.0) -> float:
	var precipitation := get_precipitation_potential(world_x, world_z)
	var continentality := _sample_continentality(world_x, world_z)
	var basin_factor := get_basin_factor(world_x, world_z)
	var moisture := precipitation
	moisture *= 1.0 - continentality * _config.inland_moisture_loss
	moisture = lerpf(moisture, moisture + basin_factor * 0.2, _config.basin_strength * 0.35)
	moisture -= height_normalized * _config.altitude_moisture_loss
	return clampf(moisture, 0.0, 1.0)


func get_precipitation_potential(world_x: float, world_z: float) -> float:
	var noise_value := (_precipitation_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
	var latitude_value := _sample_latitude_precipitation(world_z)
	var continentality := _sample_continentality(world_x, world_z)
	var rain_shadow := _sample_rain_shadow(world_x, world_z)
	var precipitation := lerpf(noise_value, latitude_value, _config.latitude_precipitation_strength)
	precipitation *= 1.0 - continentality * _config.inland_precipitation_loss
	precipitation *= 1.0 - rain_shadow * _config.rain_shadow_strength
	precipitation += _sample_precipitation_season_bias() * _config.season_precipitation_strength
	return clampf(precipitation, 0.0, 1.0)


func get_basin_factor(world_x: float, world_z: float) -> float:
	var basin_noise := _basin_noise.get_noise_2d(world_x, world_z)
	var centered := 1.0 - absf(basin_noise)
	return clampf(pow(centered, 0.8), 0.0, 1.0)


func get_drainage_potential(world_x: float, world_z: float) -> float:
	var precipitation := get_precipitation_potential(world_x, world_z)
	var basin_factor := get_basin_factor(world_x, world_z)
	var drainage := precipitation
	drainage = lerpf(drainage, (drainage + basin_factor) * 0.5, _config.basin_strength)
	return clampf(drainage, 0.0, 1.0)


func get_runoff_potential(world_x: float, world_z: float,
		terrain_height: float, sea_level: float, slope_degrees: float) -> float:
	var height_scale := maxf(SharedWorld.height_scale, 0.001)
	var height_normalized := clampf((terrain_height - sea_level) / height_scale, 0.0, 1.0)
	var slope_t := clampf(slope_degrees / _config.runoff_reference_slope_degrees, 0.0, 1.0)
	var precipitation := get_precipitation_potential(world_x, world_z)
	var drainage := get_drainage_potential(world_x, world_z)
	var runoff := 0.0
	var total_weight := 0.0
	runoff += precipitation * _config.runoff_precipitation_influence
	total_weight += _config.runoff_precipitation_influence
	runoff += height_normalized * _config.runoff_height_influence
	total_weight += _config.runoff_height_influence
	runoff += slope_t * _config.runoff_slope_influence
	total_weight += _config.runoff_slope_influence
	if total_weight > 0.0:
		runoff /= total_weight
	runoff = lerpf(runoff, (runoff + drainage) * 0.5, _config.drainage_strength)
	return clampf(runoff, 0.0, 1.0)


func get_river_source_score(world_x: float, world_z: float,
		terrain_height: float, sea_level: float,
		slope_degrees: float, local_source_noise: float) -> float:
	var runoff := get_runoff_potential(world_x, world_z, terrain_height, sea_level, slope_degrees)
	var drainage := get_drainage_potential(world_x, world_z)
	var basin_factor := get_basin_factor(world_x, world_z)
	var macro_score := runoff * 0.5 + drainage * 0.3 + basin_factor * 0.2
	var blended_score := lerpf(macro_score, local_source_noise, _config.source_noise_influence)
	var score := maxf(blended_score, macro_score * _config.river_source_score_bias)
	return clampf(score * _config.river_source_score_gain, 0.0, 1.0)


func _sample_latitude_temperature(world_z: float) -> float:
	var latitude_phase: float = world_z * _config.latitude_scale
	return clampf(1.0 - absf(sin(latitude_phase)), 0.0, 1.0)


func _sample_latitude_precipitation(world_z: float) -> float:
	var latitude_phase: float = world_z * _config.latitude_scale
	var equatorial_band: float = cos(latitude_phase * 2.0)
	var secondary_band: float = cos(latitude_phase * 4.0)
	return clampf(0.5 + equatorial_band * 0.22 - secondary_band * 0.12, 0.0, 1.0)


func _sample_continentality(world_x: float, world_z: float) -> float:
	var noise_value := (_continentality_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
	return clampf(pow(noise_value, 1.25), 0.0, 1.0)


func _sample_rain_shadow(world_x: float, world_z: float) -> float:
	var wind_dir := _sample_prevailing_wind(world_z)
	var sample_distance := maxf(_config.rain_shadow_sample_distance, 1.0)
	var upwind_x := world_x - wind_dir.x * sample_distance
	var upwind_z := world_z - wind_dir.y * sample_distance
	var current_ridge := (_ridge_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5
	var upwind_ridge := (_ridge_noise.get_noise_2d(upwind_x, upwind_z) + 1.0) * 0.5
	return clampf(maxf(upwind_ridge - current_ridge, 0.0) * 1.35, 0.0, 1.0)


func _sample_prevailing_wind(world_z: float) -> Vector2:
	var base_angle: float = deg_to_rad(_config.prevailing_wind_angle_degrees)
	var latitude_phase: float = world_z * _config.latitude_scale
	var variation: float = sin(latitude_phase * 0.5) * PI * 0.25 * _config.latitude_wind_variation
	var angle: float = base_angle + variation
	return Vector2(cos(angle), sin(angle)).normalized()


func _sample_temperature_season_bias() -> float:
	match SharedWorld.current_season:
		&"spring":
			return 0.05
		&"summer":
			return 0.12
		&"autumn":
			return -0.02
		&"winter":
			return -0.14
	return 0.0


func _sample_precipitation_season_bias() -> float:
	match SharedWorld.current_season:
		&"spring":
			return 0.08
		&"summer":
			return -0.03
		&"autumn":
			return 0.04
		&"winter":
			return -0.08
	return 0.0
