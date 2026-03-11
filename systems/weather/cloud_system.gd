class_name CloudSystem
extends BaseSystem

## Astroneer-style 3D cloud blobs using Marching Cubes.
## Generates puffy cloud meshes from 3D noise, places them at altitude,
## drifts them with wind, and recycles clouds that move too far away.

var _config: CloudConfig
var _cloud_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _cloud_material: Material
var _mc_tri_table: Array = []

## Active cloud instances: Array of { mesh_inst: MeshInstance3D, velocity: Vector3 }
var _clouds: Array[Dictionary] = []

## Current cloud altitude (smoothly transitions during storms)
var _cloud_altitude: float = 60.0

## Time accumulator for regeneration
var _regen_timer: float = 0.0

## Rain amount (smoothed for shader — global fallback)
var _rain_amount: float = 0.0

## Cached WeatherSystem reference for local weather queries
var _weather_system: BaseSystem

## Storm state — clouds get bigger, lower, denser during rain
var _target_altitude: float = 60.0
var _target_scale_mult: float = 1.0
var _current_scale_mult: float = 1.0

const MC_EDGE_CORNERS := [
	[0, 1], [1, 2], [2, 3], [3, 0],
	[4, 5], [5, 6], [6, 7], [7, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]


func _initialize() -> void:
	system_name = &"CloudSystem"
	priority = 21

	_config = _find_child_of_type(CloudConfig)
	if not _config:
		push_warning("[CloudSystem] No CloudConfig child found — using defaults")
		_config = CloudConfig.new()

	_cloud_altitude = _config.cloud_altitude
	_target_altitude = _config.cloud_altitude

	_mc_tri_table = MarchingCubesTables.get_tri_table()
	_setup_noise()
	_setup_material()
	_spawn_initial_clouds()


func _register_signals() -> void:
	SystemBus.weather_changed.connect(_on_weather_changed)


func _setup_noise() -> void:
	_cloud_noise = FastNoiseLite.new()
	_cloud_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_cloud_noise.seed = GameConfig.world_seed + 5000
	_cloud_noise.frequency = _config.noise_frequency
	_cloud_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_cloud_noise.fractal_octaves = 3
	_cloud_noise.fractal_lacunarity = 2.0
	_cloud_noise.fractal_gain = 0.5

	_detail_noise = FastNoiseLite.new()
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.seed = GameConfig.world_seed + 5100
	_detail_noise.frequency = _config.detail_frequency


func _setup_material() -> void:
	var shader := load("res://systems/weather/cloud_material.gdshader") as Shader
	if not shader:
		push_warning("[CloudSystem] Could not load cloud_material.gdshader")
		_cloud_material = StandardMaterial3D.new()
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_cloud_material = mat


func _spawn_initial_clouds() -> void:
	var cam_pos := SharedWorld.camera_world_pos
	var rng := RandomNumberGenerator.new()
	rng.seed = GameConfig.world_seed + 6000
	var wind := SharedWorld.wind_vector
	var wind_dir := wind.normalized() if wind.length() > 0.1 else Vector3(1, 0, 0)

	for i in _config.max_clouds:
		var spawn_state := _pick_cloud_spawn_state(cam_pos, wind_dir, rng)
		_create_cloud_at(spawn_state["position"], rng, float(spawn_state.get("weather", 0.0)))


func _create_cloud_at(world_pos: Vector3, rng: RandomNumberGenerator, weather_signal: float = -1.0) -> void:
	var mesh := _generate_cloud_blob(world_pos, rng)
	if not mesh:
		return

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.material_override = _cloud_material
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mesh_inst.position = world_pos

	# Random scale variation for variety
	var s := rng.randf_range(_config.scale_min, _config.scale_max)
	var sy := rng.randf_range(_config.scale_y_min, _config.scale_y_max)
	mesh_inst.scale = Vector3(s, sy, s)

	add_child(mesh_inst)

	var wind := SharedWorld.wind_vector
	var drift_speed := rng.randf_range(_config.drift_speed_min, _config.drift_speed_max)
	var y_off := world_pos.y - _cloud_altitude
	var wind_dir := wind.normalized() if wind.length() > 0.1 else Vector3(1, 0, 0)
	var initial_weather := weather_signal if weather_signal >= 0.0 else _sample_cloud_weather_signal(world_pos.x, world_pos.z, wind_dir)
	var initial_mass := clampf(lerpf(_config.dry_scale_multiplier, 1.0, initial_weather), 0.12, 1.0)
	_configure_cloud_instance(mesh_inst, initial_weather, initial_mass)
	_clouds.append({
		"mesh_inst": mesh_inst,
		"velocity": wind.normalized() * drift_speed if wind.length() > 0.1 else Vector3(1, 0, 0) * drift_speed,
		"seed_offset": rng.randf() * 1000.0,
		"y_offset": y_off,
		"base_scale": s,
		"base_scale_y": sy,
		"wetness": initial_weather,
		"mass": initial_mass,
	})


func _generate_cloud_blob(world_pos: Vector3, rng: RandomNumberGenerator) -> ArrayMesh:
	var res := _config.blob_resolution
	var size := _config.blob_size
	var step := size / float(res - 1)
	var half := size * 0.5
	var seed_offset := Vector3(
		rng.randf_range(-500.0, 500.0),
		rng.randf_range(-500.0, 500.0),
		rng.randf_range(-500.0, 500.0)
	)

	# Build density field for this blob
	var grid := PackedFloat32Array()
	grid.resize(res * res * res)

	for gy in res:
		for gz in res:
			for gx in res:
				var lx := float(gx) * step - half
				var ly := float(gy) * step - half
				var lz := float(gz) * step - half

				# Spherical falloff: density drops off toward edges
				var dist := Vector3(lx, ly * 1.5, lz).length() / half
				var sphere := 1.0 - clampf(dist, 0.0, 1.0)
				sphere = sphere * sphere  # Sharper falloff

				# 3D noise for blobby shape
				var wx := world_pos.x + lx + seed_offset.x
				var wy := world_pos.y + ly + seed_offset.y
				var wz := world_pos.z + lz + seed_offset.z
				var n := _cloud_noise.get_noise_3d(wx, wy, wz)
				var d := _detail_noise.get_noise_3d(wx * 2.0, wy * 2.0, wz * 2.0)
				var noise_val := n * 0.7 + d * 0.3

				# Combine: sphere shape * noise → density
				var density := sphere * 1.5 + noise_val * 0.6 - 0.3
				# Flatten bottom (clouds are flatter underneath)
				if ly < 0.0:
					density -= absf(ly) / half * 0.4

				grid[gy * res * res + gz * res + gx] = density

	return _extract_cloud_mesh(grid, res, step)


func _extract_cloud_mesh(grid: PackedFloat32Array, res: int, step: float) -> ArrayMesh:
	var half := float(res - 1) * step * 0.5
	var iso := 0.0
	var ss := res * res
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var top_color := Color(1.0, 0.98, 0.96)
	var mid_color := Color(0.86, 0.88, 0.92)
	var bottom_color := Color(0.68, 0.72, 0.80)
	var voxel_steps := 5.0

	for gy in res - 1:
		var y0 := float(gy) * step - half
		var y1 := y0 + step
		for gz in res - 1:
			for gx in res - 1:
				var d0 := grid[gy * ss + gz * res + gx]
				var d1 := grid[gy * ss + gz * res + (gx + 1)]
				var d2 := grid[gy * ss + (gz + 1) * res + (gx + 1)]
				var d3 := grid[gy * ss + (gz + 1) * res + gx]
				var d4 := grid[(gy + 1) * ss + gz * res + gx]
				var d5 := grid[(gy + 1) * ss + gz * res + (gx + 1)]
				var d6 := grid[(gy + 1) * ss + (gz + 1) * res + (gx + 1)]
				var d7 := grid[(gy + 1) * ss + (gz + 1) * res + gx]

				var cube_idx := 0
				if d0 < iso: cube_idx |= 1
				if d1 < iso: cube_idx |= 2
				if d2 < iso: cube_idx |= 4
				if d3 < iso: cube_idx |= 8
				if d4 < iso: cube_idx |= 16
				if d5 < iso: cube_idx |= 32
				if d6 < iso: cube_idx |= 64
				if d7 < iso: cube_idx |= 128

				if cube_idx == 0 or cube_idx == 255:
					continue

				var edges: PackedInt32Array = _mc_tri_table[cube_idx]
				if edges.is_empty() or edges[0] == -1:
					continue

				var x0 := float(gx) * step - half
				var z0 := float(gz) * step - half
				var x1 := x0 + step
				var z1 := z0 + step

				var c: Array[Vector3] = [
					Vector3(x0, y0, z0), Vector3(x1, y0, z0),
					Vector3(x1, y0, z1), Vector3(x0, y0, z1),
					Vector3(x0, y1, z0), Vector3(x1, y1, z0),
					Vector3(x1, y1, z1), Vector3(x0, y1, z1),
				]
				var dd: Array[float] = [d0, d1, d2, d3, d4, d5, d6, d7]

				var ei := 0
				while ei < edges.size() and edges[ei] != -1:
					var v0 := _interp_edge(edges[ei], c, dd, iso)
					var v1 := _interp_edge(edges[ei + 1], c, dd, iso)
					var v2 := _interp_edge(edges[ei + 2], c, dd, iso)
					var avg_y := (v0.y + v1.y + v2.y) / 3.0
					var height_t := clampf((avg_y + half) / maxf(half * 2.0, 0.001), 0.0, 1.0)
					height_t = floorf(height_t * voxel_steps) / maxf(voxel_steps - 1.0, 1.0)
					var face_normal := (v1 - v0).cross(v2 - v0).normalized()
					var light_t := clampf(face_normal.y * 0.5 + 0.5, 0.0, 1.0)
					var base_color := mid_color.lerp(top_color, smoothstep(0.45, 1.0, height_t))
					base_color = bottom_color.lerp(base_color, smoothstep(0.0, 0.65, height_t))
					base_color = base_color.lightened((light_t - 0.5) * 0.18)
					verts.append(v0)
					verts.append(v1)
					verts.append(v2)
					colors.append(base_color)
					colors.append(base_color)
					colors.append(base_color)
					ei += 3

	if verts.is_empty():
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in verts.size():
		st.set_color(colors[i])
		st.add_vertex(verts[i])
	st.generate_normals()
	return st.commit()


func _interp_edge(edge: int, corners: Array[Vector3], d: Array[float], iso: float) -> Vector3:
	var pair: Array = MC_EDGE_CORNERS[edge]
	var a: int = pair[0]
	var b: int = pair[1]
	var da := d[a]
	var db := d[b]
	var denom := da - db
	var t := 0.5
	if absf(denom) > 0.0001:
		t = (da - iso) / denom
	t = clampf(t, 0.0, 1.0)
	return corners[a].lerp(corners[b], t)


func system_process(delta: float) -> void:
	if not active:
		return

	# Lazy-find WeatherSystem on first frame
	if not _weather_system:
		_weather_system = _find_system_by_type(WeatherSystem)

	var cam_pos := SharedWorld.camera_world_pos
	var wind := SharedWorld.wind_vector
	var is_rain := SharedWorld.weather_state == &"rain" or SharedWorld.weather_state == &"storm"

	# Smoothly transition storm parameters
	_cloud_altitude = lerpf(_cloud_altitude, _target_altitude, delta * _config.storm_transition_speed)
	_current_scale_mult = lerpf(_current_scale_mult, _target_scale_mult, delta * _config.storm_transition_speed)

	# Drift all clouds — faster during storms
	var speed_mult := _config.storm_speed_multiplier if is_rain else 1.0
	var wind_dir := wind.normalized() if wind.length() > 0.1 else Vector3(1, 0, 0)
	for cloud in _clouds:
		var mi: MeshInstance3D = cloud["mesh_inst"]
		if not is_instance_valid(mi):
			continue

		var base_speed: float = cloud["velocity"].length()
		if wind.length() > 0.1:
			cloud["velocity"] = wind.normalized() * base_speed
		mi.position += cloud["velocity"] * delta * speed_mult
		var weather_signal := _sample_cloud_weather_signal(mi.position.x, mi.position.z, wind_dir)
		var wetness := lerpf(float(cloud.get("wetness", weather_signal)), weather_signal, delta * _config.local_wetness_lerp_speed)
		cloud["wetness"] = wetness
		var target_mass := clampf(lerpf(_config.dry_scale_multiplier, 1.0 + _config.wet_growth_boost, wetness), 0.12, 1.2)
		var mass := lerpf(float(cloud.get("mass", target_mass)), target_mass, delta * _config.cloud_mass_lerp_speed)
		cloud["mass"] = mass

		# Smoothly move clouds toward current altitude
		var target_y: float = _cloud_altitude + float(cloud.get("y_offset", 0.0)) - wetness * _config.rain_altitude_drop
		mi.position.y = lerpf(mi.position.y, target_y, delta * 0.5)

		# Scale: bigger in rainy local zones, smaller in clear zones
		var base_s: float = cloud.get("base_scale", 1.0)
		var sy: float = cloud.get("base_scale_y", 0.65)
		var local_scale := lerpf(_config.dry_scale_multiplier, _current_scale_mult + _config.wet_growth_boost, mass)
		var s := base_s * local_scale
		mi.scale = mi.scale.lerp(Vector3(s, sy * lerpf(_config.dry_scale_multiplier, local_scale, 0.88), s), delta * 0.5)

		# Visibility: hide clouds in very dry local zones
		mi.visible = mass > _config.dry_visibility_threshold or wetness > _config.dry_visibility_threshold * 0.7 or not is_rain
		_configure_cloud_instance(mi, wetness, mass)

	# Recycle clouds that are too far from camera
	_regen_timer += delta
	if _regen_timer > _config.recycle_interval:
		_regen_timer = 0.0
		_recycle_distant_clouds(cam_pos)

	# Update global rain amount + time_of_day on shared material
	var avg_rain := _get_local_rain_at(cam_pos.x, cam_pos.z)
	_rain_amount = lerpf(_rain_amount, avg_rain, delta * 0.5)
	if _cloud_material is ShaderMaterial:
		var mat := _cloud_material as ShaderMaterial
		mat.set_shader_parameter("rain_amount", _rain_amount)
		mat.set_shader_parameter("time_of_day", SharedWorld.time_of_day)


## Query local rain intensity at a world XZ position via WeatherSystem.
func _get_local_rain_at(wx: float, wz: float) -> float:
	if _weather_system and _weather_system.has_method("get_local_weather"):
		return _weather_system.get_local_weather(wx, wz)
	return SharedWorld.rain_intensity


func _sample_cloud_weather_signal(wx: float, wz: float, wind_dir: Vector3) -> float:
	var offset := _config.wet_zone_sample_distance
	var center := _get_local_rain_at(wx, wz)
	var ahead := _get_local_rain_at(wx - wind_dir.x * offset, wz - wind_dir.z * offset)
	var behind := _get_local_rain_at(wx + wind_dir.x * offset * 0.55, wz + wind_dir.z * offset * 0.55)
	var side_x := -wind_dir.z
	var side_z := wind_dir.x
	var side_a := _get_local_rain_at(wx + side_x * offset * 0.6, wz + side_z * offset * 0.6)
	var side_b := _get_local_rain_at(wx - side_x * offset * 0.6, wz - side_z * offset * 0.6)
	return clampf(center * 0.34 + ahead * 0.26 + behind * 0.16 + side_a * 0.12 + side_b * 0.12, 0.0, 1.0)


func _configure_cloud_instance(mesh_inst: MeshInstance3D, wetness: float, mass: float) -> void:
	mesh_inst.set_instance_shader_parameter("local_rain_amount", clampf(wetness, 0.0, 1.0))
	mesh_inst.set_instance_shader_parameter("cloud_mass", clampf(mass, 0.0, 1.2))


func _pick_cloud_spawn_state(cam_pos: Vector3, wind_dir: Vector3, rng: RandomNumberGenerator) -> Dictionary:
	var best_score := -INF
	var best_position := cam_pos + Vector3(0.0, _cloud_altitude, 0.0)
	var best_weather := 0.0
	var spawn_dir := -wind_dir
	for _i in range(maxi(_config.wet_zone_candidate_count, 1)):
		var angle_offset := rng.randf_range(-1.2, 1.2)
		var rotated := Vector3(
			spawn_dir.x * cos(angle_offset) - spawn_dir.z * sin(angle_offset),
			0.0,
			spawn_dir.x * sin(angle_offset) + spawn_dir.z * cos(angle_offset)
		)
		var distance := _config.cloud_radius * rng.randf_range(0.72, 1.18)
		var y_off := rng.randf_range(-_config.y_offset_range, _config.y_offset_range)
		var candidate := cam_pos + rotated * distance
		candidate.y = _cloud_altitude + y_off
		var weather_signal := _sample_cloud_weather_signal(candidate.x, candidate.z, wind_dir)
		var score := weather_signal * 1.8 + rng.randf() * 0.06
		if score > best_score:
			best_score = score
			best_position = candidate
			best_weather = weather_signal
	return {
		"position": best_position,
		"weather": best_weather,
	}


func _recycle_distant_clouds(cam_pos: Vector3) -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var wind := SharedWorld.wind_vector
	var wind_dir := wind.normalized() if wind.length() > 0.1 else Vector3(1, 0, 0)
	var recycled_count := 0

	for cloud in _clouds:
		if recycled_count >= _config.max_recycled_per_interval:
			break
		var mi: MeshInstance3D = cloud["mesh_inst"]
		if not is_instance_valid(mi):
			continue

		var dist_xz := Vector2(mi.position.x - cam_pos.x, mi.position.z - cam_pos.z).length()
		if dist_xz > _config.cloud_radius * 1.3:
			var spawn_state := _pick_cloud_spawn_state(cam_pos, wind_dir, rng)
			var new_pos: Vector3 = spawn_state["position"]
			var weather_signal := float(spawn_state.get("weather", 0.0))
			var y_off := new_pos.y - _cloud_altitude

			var new_mesh := _generate_cloud_blob(new_pos, rng)
			if new_mesh:
				mi.mesh = new_mesh
				mi.position = new_pos
				var s := rng.randf_range(_config.scale_min, _config.scale_max)
				var sy := rng.randf_range(_config.scale_y_min, _config.scale_y_max)
				var mass := clampf(lerpf(_config.dry_scale_multiplier, 1.0 + _config.wet_growth_boost, weather_signal), 0.12, 1.2)
				mi.scale = Vector3(s * mass, sy * lerpf(_config.dry_scale_multiplier, mass, 0.88), s * mass)
				_configure_cloud_instance(mi, weather_signal, mass)
				cloud["velocity"] = wind_dir * rng.randf_range(_config.drift_speed_min, _config.drift_speed_max)
				cloud["y_offset"] = y_off
				cloud["base_scale"] = s
				cloud["base_scale_y"] = sy
				cloud["wetness"] = weather_signal
				cloud["mass"] = mass
				recycled_count += 1


func _on_weather_changed(state: Dictionary) -> void:
	var is_rain: bool = state.get("rain", false)
	if is_rain:
		# Storm: clouds drop lower, get bigger and denser
		_target_altitude = _config.storm_altitude
		_target_scale_mult = _config.storm_scale_multiplier
	else:
		# Clear: clouds rise back up, return to normal size
		_target_altitude = _config.cloud_altitude
		_target_scale_mult = 1.0




func _shutdown() -> void:
	for cloud in _clouds:
		var mi: MeshInstance3D = cloud["mesh_inst"]
		if is_instance_valid(mi):
			mi.queue_free()
	_clouds.clear()
