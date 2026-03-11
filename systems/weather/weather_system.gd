class_name WeatherSystem
extends BaseSystem

const GEO_SYSTEM_SCRIPT = preload("res://systems/geo/geo_system.gd")

## Drives day/night cycle, wind, and precipitation.
## Updates SharedWorld state and emits weather/wind signals.

var _config: WeatherConfig
var _weather_timer: float = 0.0
var _wind_angle: float = 0.0

## Reference to the DirectionalLight3D child (sun)
var _sun_light: DirectionalLight3D

## Reference to the GPUParticles3D child (rain)
var _rain_particles: GPUParticles3D

## Reference to the sky ShaderMaterial (found lazily)
var _sky_material: ShaderMaterial

## Reference to the Environment resource (found lazily)
var _environment: Environment

## Target rain intensity (smoothly lerped toward)
var _target_rain_intensity: float = 0.0

## Target wind strength (smoothly lerped toward)
var _target_wind_strength: float = 1.0

## Biome ambient sound
var _ambient_player: AudioStreamPlayer
var _current_ambient_biome: StringName = &""

## Biome particle effect instance (follows camera)
var _biome_particles: Node3D
var _current_particle_biome: StringName = &""

## Cached biome system reference
var _biome_system: BaseSystem
var _geo_system

## Noise for local weather zones (drifting weather fronts)
var _weather_zone_noise: FastNoiseLite

## Accumulated time for weather drift offset
var _weather_time: float = 0.0



func _initialize() -> void:
	system_name = &"WeatherSystem"
	priority = 20

	_config = _find_child_of_type(WeatherConfig)
	if not _config:
		push_warning("[WeatherSystem] No WeatherConfig child found — using defaults")
		_config = WeatherConfig.new()

	_sun_light = _find_child_of_type(DirectionalLight3D)
	_rain_particles = _find_child_of_type(GPUParticles3D)

	# Initialize wind
	_wind_angle = randf() * TAU
	_update_wind()

	# Initialize weather state
	SharedWorld.weather_state = &"clear"

	# Weather zone noise for local weather fronts
	_weather_zone_noise = FastNoiseLite.new()
	_weather_zone_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_weather_zone_noise.seed = GameConfig.world_seed + 8000
	_weather_zone_noise.frequency = _config.weather_zone_frequency


func _register_signals() -> void:
	SystemBus.biome_chunk_ready.connect(_on_biome_chunk_ready)


func system_process(delta: float) -> void:
	if not active:
		return
	_weather_time += delta
	_update_time_of_day(delta)
	_update_sun()
	_update_sky()
	_update_weather_tick(delta)
	_smooth_weather_transitions(delta)
	_follow_camera_with_rain()
	_update_biome_ambience(delta)


## Returns local rain intensity (0.0–1.0) at a world XZ position.
## Uses drifting weather noise + global weather state + biome moisture modulation.
## CloudSystem and other systems call this to get region-specific weather.
func get_local_weather(world_x: float, world_z: float) -> float:
	if not _biome_system:
		_biome_system = _find_system_by_type(BiomeSystem)

	# Drift the noise sample position so weather fronts move across the world
	var drift := _weather_time * _config.weather_drift_speed
	var wind_dir := SharedWorld.wind_direction
	var sample_x := world_x - wind_dir.x * drift
	var sample_z := world_z - wind_dir.z * drift

	# Weather zone noise: -1..1 → 0..1
	var zone := (_weather_zone_noise.get_noise_2d(sample_x, sample_z) + 1.0) * 0.5

	# Modulate by global weather state intensity
	var global_rain := SharedWorld.rain_intensity
	# zone > 0.5 = rainy pocket, zone < 0.5 = clear pocket
	var local_base := clampf(zone * 2.0 - 0.5, 0.0, 1.0) * global_rain * 2.0
	var geo_system = _get_geo_system()
	if geo_system and geo_system.has_method("get_precipitation_potential"):
		var macro_precipitation: float = geo_system.get_precipitation_potential(world_x, world_z)
		local_base *= lerpf(0.45, 1.55, macro_precipitation)

	# Biome moisture modulation (wetter biomes get more rain)
	if _biome_system and _biome_system.has_method("get_moisture_at_world"):
		var moisture: float = _biome_system.get_moisture_at_world(world_x, world_z)
		var influence := _config.biome_moisture_influence
		local_base = lerpf(local_base, local_base * moisture * 2.0, influence)

	return clampf(local_base, 0.0, 1.0)


func _get_geo_system():
	if not _geo_system:
		_geo_system = _find_system_by_type(GEO_SYSTEM_SCRIPT)
	return _geo_system


## Advance time of day and track day/season cycles
func _update_time_of_day(delta: float) -> void:
	var day_len := _config.day_length_seconds
	if day_len <= 0.0:
		return
	SharedWorld.time_of_day += delta / day_len
	if SharedWorld.time_of_day >= 1.0:
		SharedWorld.time_of_day -= 1.0
		SharedWorld.day_count += 1
		_update_season()
	SystemBus.time_of_day_changed.emit(SharedWorld.time_of_day)


## Rotate and color the sun based on time of day
func _update_sun() -> void:
	if not _sun_light:
		return

	var t := SharedWorld.time_of_day
	# Sun travels a full circle: t=0.25 sunrise (horizon east), t=0.5 noon (overhead), t=0.75 sunset (horizon west)
	# Pitch: 0° at horizon, 80° at zenith. Full sinusoidal arc.
	var sun_phase := (t - 0.25) * TAU  # 0 at sunrise, PI at sunset, TAU at next sunrise
	var pitch_deg := sin(sun_phase) * 80.0  # Positive = above horizon, negative = below
	var yaw_deg := cos(sun_phase) * 30.0 + 180.0  # Rotate around Y for east→west travel

	_sun_light.rotation_degrees = Vector3(-pitch_deg, yaw_deg, 0.0)

	# How high is the sun above horizon (0..1, clamped — negative means night)
	var sun_height := clampf(sin(sun_phase), 0.0, 1.0)

	# Interpolate sun color: warm at horizon, bright white at noon
	_sun_light.light_color = _config.sun_color_horizon.lerp(_config.sun_color_noon, sun_height)

	# Energy: bright during day, near-zero at night, smooth transition
	var is_daytime := t > 0.22 and t < 0.78
	if is_daytime:
		_sun_light.light_energy = sun_height * 1.2
	else:
		_sun_light.light_energy = 0.02
	_sun_light.shadow_enabled = is_daytime


## Update sky shader uniforms and fog based on time of day
func _update_sky() -> void:
	# Lazy-find sky shader material
	if not _sky_material or not _environment:
		_find_sky_material()
		if not _sky_material:
			return

	var t := SharedWorld.time_of_day

	# Compute sky colors for current time phase
	var sky_top: Color
	var sky_horizon: Color
	var fog_color: Color

	if t < 0.2:
		sky_top = _config.sky_night_top
		sky_horizon = _config.sky_night_horizon
		fog_color = _config.sky_night_horizon
	elif t < 0.3:
		var blend := (t - 0.2) / 0.1
		sky_top = _config.sky_night_top.lerp(_config.sky_sunset_top, blend)
		sky_horizon = _config.sky_night_horizon.lerp(_config.sky_sunset_horizon, blend)
		fog_color = _config.sky_night_horizon.lerp(_config.fog_sunset, blend)
	elif t < 0.4:
		var blend := (t - 0.3) / 0.1
		sky_top = _config.sky_sunset_top.lerp(_config.sky_noon_top, blend)
		sky_horizon = _config.sky_sunset_horizon.lerp(_config.sky_noon_horizon, blend)
		fog_color = _config.fog_sunset.lerp(_config.fog_noon, blend)
	elif t < 0.65:
		sky_top = _config.sky_noon_top
		sky_horizon = _config.sky_noon_horizon
		fog_color = _config.fog_noon
	elif t < 0.75:
		var blend := (t - 0.65) / 0.1
		sky_top = _config.sky_noon_top.lerp(_config.sky_sunset_top, blend)
		sky_horizon = _config.sky_noon_horizon.lerp(_config.sky_sunset_horizon, blend)
		fog_color = _config.fog_noon.lerp(_config.fog_sunset, blend)
	elif t < 0.85:
		var blend := (t - 0.75) / 0.1
		sky_top = _config.sky_sunset_top.lerp(_config.sky_night_top, blend)
		sky_horizon = _config.sky_sunset_horizon.lerp(_config.sky_night_horizon, blend)
		fog_color = _config.fog_sunset.lerp(_config.sky_night_horizon, blend)
	else:
		sky_top = _config.sky_night_top
		sky_horizon = _config.sky_night_horizon
		fog_color = _config.sky_night_horizon

	# Update sky shader uniforms
	_sky_material.set_shader_parameter("sky_top_color", sky_top)
	_sky_material.set_shader_parameter("sky_horizon_color", sky_horizon)
	_sky_material.set_shader_parameter("ground_color", sky_top.darkened(0.7))

	# Sun direction from light rotation
	if _sun_light:
		var sun_dir := -_sun_light.global_transform.basis.z
		_sky_material.set_shader_parameter("sun_direction", sun_dir)
		_sky_material.set_shader_parameter("sun_color", _sun_light.light_color)

	# Fog — denser and darker during local rain at camera
	if _environment:
		var cam := get_viewport().get_camera_3d()
		var cam_pos := cam.global_position if cam else SharedWorld.camera_world_pos
		var local_rain := get_local_weather(cam_pos.x, cam_pos.z)
		var base_fog := fog_color.lerp(sky_horizon, 0.32)
		var rain_tint := Color(0.76, 0.82, 0.90)
		var rain_fog := base_fog.lerp(rain_tint, local_rain * 0.22)
		rain_fog = rain_fog.darkened(local_rain * 0.08)
		_environment.fog_light_color = rain_fog
		_environment.fog_density = lerpf(0.0014, 0.0036, pow(local_rain, 0.8))


func _find_sky_material() -> void:
	var we := _find_world_environment()
	if not we or not we.environment:
		return
	_environment = we.environment
	if not _environment.sky:
		_environment.sky = Sky.new()
	# Check if already using our custom shader
	if _environment.sky.sky_material is ShaderMaterial:
		_sky_material = _environment.sky.sky_material as ShaderMaterial
		return
	# Replace ProceduralSkyMaterial with our volumetric cloud shader
	var shader := load("res://systems/weather/cloud_sky.gdshader") as Shader
	if not shader:
		push_warning("[WeatherSystem] Could not load cloud_sky.gdshader")
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_environment.sky.sky_material = mat
	_sky_material = mat
	print("[WeatherSystem] Replaced sky material with volumetric cloud shader")


## Find the WorldEnvironment node in the scene
func _find_world_environment() -> WorldEnvironment:
	var root := get_tree().current_scene
	if not root:
		return null
	return _find_node_of_type(root, WorldEnvironment) as WorldEnvironment




## Periodically re-evaluate weather state via state machine
func _update_weather_tick(delta: float) -> void:
	_weather_timer += delta
	if _weather_timer < _config.weather_tick_interval:
		return
	_weather_timer = 0.0

	# Drift wind angle slowly
	_wind_angle += randf_range(-0.3, 0.3)

	# State machine transitions: clear ↔ cloudy ↔ rain ↔ storm
	var old_state := SharedWorld.weather_state
	var roll := randf()

	match SharedWorld.weather_state:
		&"clear":
			if roll < _config.chance_clear_to_cloudy:
				SharedWorld.weather_state = &"cloudy"
		&"cloudy":
			if roll < _config.chance_cloudy_to_rain:
				SharedWorld.weather_state = &"rain"
			elif roll < _config.chance_cloudy_to_rain + _config.chance_cloudy_to_clear:
				SharedWorld.weather_state = &"clear"
		&"rain":
			if roll < _config.chance_rain_to_storm:
				SharedWorld.weather_state = &"storm"
			elif roll < _config.chance_rain_to_storm + _config.chance_rain_to_cloudy:
				SharedWorld.weather_state = &"cloudy"
		&"storm":
			if roll < _config.chance_storm_to_rain:
				SharedWorld.weather_state = &"rain"

	# Set target rain intensity based on state
	match SharedWorld.weather_state:
		&"clear":
			_target_rain_intensity = 0.0
		&"cloudy":
			_target_rain_intensity = 0.05
		&"rain":
			_target_rain_intensity = _config.rain_intensity_rain
		&"storm":
			_target_rain_intensity = _config.rain_intensity_storm

	# Set target wind strength based on state + gusts
	var base_wind := randf_range(_config.wind_min, _config.wind_max)
	if SharedWorld.weather_state == &"storm":
		base_wind *= 1.5
	if randf() < _config.wind_gust_chance:
		base_wind *= _config.wind_gust_multiplier
	_target_wind_strength = base_wind

	# Toggle rain particles based on local weather at camera
	if _rain_particles:
		var viewport := get_viewport()
		var cam := viewport.get_camera_3d() if viewport else null
		var cam_pos := cam.global_position if cam else SharedWorld.camera_world_pos
		var local_rain := get_local_weather(cam_pos.x, cam_pos.z)
		_rain_particles.emitting = local_rain > 0.1
		if _rain_particles.emitting:
			_rain_particles.amount_ratio = clampf(local_rain, 0.1, 1.0)

	if SharedWorld.weather_state != old_state:
		var is_raining := SharedWorld.weather_state == &"rain" or SharedWorld.weather_state == &"storm"
		var state_dict := {
			"state": SharedWorld.weather_state,
			"rain": is_raining,
			"time_of_day": SharedWorld.time_of_day,
		}
		SystemBus.weather_changed.emit(state_dict)


## Smoothly lerp rain intensity and wind toward targets each frame
func _smooth_weather_transitions(delta: float) -> void:
	# Smooth rain intensity
	var lerp_speed := _config.rain_intensity_lerp_speed * delta
	SharedWorld.rain_intensity = lerpf(SharedWorld.rain_intensity, _target_rain_intensity, lerp_speed)

	# Smooth wind strength
	var wind_lerp := _config.wind_lerp_speed * delta
	SharedWorld.wind_strength = lerpf(SharedWorld.wind_strength, _target_wind_strength, wind_lerp)
	SharedWorld.wind_direction = Vector3(cos(_wind_angle), 0.0, sin(_wind_angle)).normalized()

	# Drought tracking: increment dry ticks when no rain, reset when raining
	if SharedWorld.rain_intensity < _config.dry_rain_threshold:
		SharedWorld.consecutive_dry_ticks += 1
	else:
		SharedWorld.consecutive_dry_ticks = 0


## Update wind direction and strength in SharedWorld (called once at init)
func _update_wind() -> void:
	SharedWorld.wind_direction = Vector3(cos(_wind_angle), 0.0, sin(_wind_angle)).normalized()
	_target_wind_strength = randf_range(_config.wind_min, _config.wind_max)
	SharedWorld.wind_strength = _target_wind_strength
	SystemBus.wind_changed.emit(SharedWorld.wind_direction, SharedWorld.wind_strength)


## Keep rain particles centered on the camera
func _follow_camera_with_rain() -> void:
	if not _rain_particles or not _rain_particles.emitting:
		return
	var viewport := get_viewport()
	var cam := viewport.get_camera_3d() if viewport else null
	var cam_pos := cam.global_position if cam else SharedWorld.camera_world_pos
	_rain_particles.global_position = cam_pos + Vector3(0, 15, 0)


func _on_biome_chunk_ready(_coord: Vector2i, _biome_map: PackedByteArray) -> void:
	pass


## Update season based on day count (4 seasons, configurable days per season)
func _update_season() -> void:
	var days_per: int = _config.days_per_season
	if days_per <= 0:
		return
	var season_idx: int = int(floori(float(SharedWorld.day_count) / float(days_per))) % 4
	var seasons: Array[StringName] = [&"spring", &"summer", &"autumn", &"winter"]
	var new_season := seasons[season_idx]
	if new_season != SharedWorld.current_season:
		SharedWorld.current_season = new_season
		SystemBus.weather_changed.emit({"season": new_season, "day": SharedWorld.day_count})


## Update biome-specific ambient sound and particle effects at camera position
func _update_biome_ambience(_delta: float) -> void:
	var biome_name := SharedWorld.active_biome_name
	if biome_name == _current_ambient_biome:
		return

	# Lazy-find biome system
	if not _biome_system:
		_biome_system = _find_system_by_type(BiomeSystem)
	if not _biome_system or not _biome_system.has_method("get_biome_data"):
		return

	var bdata: BiomeData = _biome_system.get_biome_data(SharedWorld.active_biome_at_camera)
	if not bdata:
		return

	_current_ambient_biome = biome_name

	# --- Ambient Sound ---
	if bdata.ambient_sound:
		if not _ambient_player:
			_ambient_player = AudioStreamPlayer.new()
			_ambient_player.bus = &"Master"
			_ambient_player.volume_db = -10.0
			add_child(_ambient_player)
		if _ambient_player.stream != bdata.ambient_sound:
			_ambient_player.stream = bdata.ambient_sound
			_ambient_player.play()
	elif _ambient_player and _ambient_player.playing:
		_ambient_player.stop()

	# --- Biome Particles ---
	if _biome_particles:
		_biome_particles.queue_free()
		_biome_particles = null
		_current_particle_biome = &""

	if bdata.particle_effect:
		var particles_inst := bdata.particle_effect.instantiate() as Node3D
		if particles_inst:
			_biome_particles = particles_inst
			_current_particle_biome = biome_name
			add_child(_biome_particles)
			var viewport := get_viewport()
			var cam := viewport.get_camera_3d() if viewport else null
			_biome_particles.global_position = cam.global_position if cam else SharedWorld.camera_world_pos
