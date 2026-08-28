class_name WaterSystem
extends BaseSystem

const WATER_SHADER = preload("res://systems/water/water_surface.gdshader")

## Places a translucent water plane at sea level for each loaded chunk.
## Listens for chunk lifecycle signals to add/remove water.

var _config: WaterConfig
var _water_material: ShaderMaterial
var _water_mesh: PlaneMesh
var _sea_level: float = 0.0

## Wave-bearing and sea state, eased toward what the weather is asking for.
var _sea_wind_dir: Vector2 = Vector2.RIGHT
var _sea_state: float = 0.3
var _sea_level_found: bool = false

## Chunk coord → MeshInstance3D
var _chunk_water: Dictionary = {}

## Chunk coord → ShaderMaterial
var _chunk_materials: Dictionary = {}

## Underwater detection state
var _is_underwater: bool = false
var _environment: Environment
var _saved_fog_color: Color
var _saved_fog_density: float

## Far ocean ring state (see _update_far_ocean).
var _far_ocean: MeshInstance3D
var _far_ocean_material: ShaderMaterial
var _far_ocean_chunk := Vector2i(999999, 999999)


func _initialize() -> void:
	system_name = &"WaterSystem"
	priority = 5

	_config = _find_child_of_type(WaterConfig)
	if not _config:
		push_warning("[WaterSystem] No WaterConfig child found — using defaults")
		_config = WaterConfig.new()

	_setup_material()
	_setup_mesh()


func _register_signals() -> void:
	SystemBus.terrain_chunk_ready.connect(_on_terrain_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)


func _setup_material() -> void:
	# The shader is a real .gdshader file, not a GDScript string: it gets
	# syntax highlighting, error lines that point at the shader, hot reload,
	# and it shares water_common.gdshaderinc with the river surface so the
	# two bodies of water are one material family.
	_water_material = ShaderMaterial.new()
	_water_material.shader = WATER_SHADER
	_water_material.set_shader_parameter("shore_color", _config.shore_color)
	_water_material.set_shader_parameter("shallow_color", _config.shallow_color)
	_water_material.set_shader_parameter("mid_color", _config.mid_color)
	_water_material.set_shader_parameter("deep_color", _config.deep_color)
	_water_material.set_shader_parameter("mid_depth_start", _config.mid_depth_start)
	_water_material.set_shader_parameter("deep_depth_start", _config.deep_depth_start)
	_water_material.set_shader_parameter("wave_amplitude", _config.wave_amplitude)
	_water_material.set_shader_parameter("wave_frequency", _config.wave_frequency)
	_water_material.set_shader_parameter("wave_speed", _config.wave_speed)
	_water_material.set_shader_parameter("shore_depth_range", _config.shore_depth_range)
	_water_material.set_shader_parameter("shore_wave_min_depth", _config.shore_wave_min_depth)
	_water_material.set_shader_parameter("shore_wave_max_depth", _config.shore_wave_max_depth)
	_water_material.set_shader_parameter("shore_break_strength", _config.shore_break_strength)
	_water_material.set_shader_parameter("roughness", _config.roughness)
	_water_material.set_shader_parameter("metallic", _config.metallic)
	_water_material.set_shader_parameter("foam_color", _config.foam_color)
	_water_material.set_shader_parameter("foam_width", _config.foam_width)
	_water_material.set_shader_parameter("foam_noise_scale", _config.foam_noise_scale)
	_water_material.set_shader_parameter("foam_drift_speed", _config.foam_drift_speed)
	_water_material.set_shader_parameter("foam_longshore_speed", _config.foam_longshore_speed)
	_water_material.set_shader_parameter("foam_cycle", _config.foam_cycle)
	_water_material.set_shader_parameter("foam_streak_stretch", _config.foam_streak_stretch)
	_water_material.set_shader_parameter("foam_slope_reference", _config.foam_slope_reference)
	_water_material.set_shader_parameter("foam_band_min", _config.foam_band_min)
	_water_material.set_shader_parameter("foam_band_max", _config.foam_band_max)
	_water_material.set_shader_parameter("foam_exposure_min", _config.foam_exposure_min)
	# The shore flow field is the depth texture's gradient, so the shader has
	# to know how much ground that texture covers to read a slope off it.
	_water_material.set_shader_parameter("depth_tex_world_size", GameConfig.chunk_size)
	_water_material.set_shader_parameter("caustics_enabled", _config.caustics_enabled)
	_water_material.set_shader_parameter("caustics_strength", _config.caustics_strength)
	_water_material.set_shader_parameter("caustics_speed", _config.caustics_speed)


func _setup_mesh() -> void:
	_water_mesh = PlaneMesh.new()
	_water_mesh.size = Vector2(GameConfig.chunk_size, GameConfig.chunk_size)
	# 32 subdivisions puts a vertex every metre across a chunk. The swell is
	# 110 m long, so 128 (a vertex every 25 cm) bought no silhouette detail
	# and cost 16x the vertices — each one evaluating the wave field.
	_water_mesh.subdivide_width = 32
	_water_mesh.subdivide_depth = 32


func _on_terrain_chunk_ready(coord: Vector2i, heightmap: PackedFloat32Array) -> void:
	# Lazy-find sea level on first terrain chunk (TerrainSystem now exists)
	if not _sea_level_found:
		_sea_level = _find_sea_level()
		_sea_level_found = true
	if _chunk_water.has(coord):
		return

	# Only place water if some part of the chunk is near or below sea level
	if not _chunk_needs_water(heightmap):
		return
	_place_water_plane(coord, heightmap)


func _on_chunk_unload_requested(coord: Vector2i) -> void:
	_remove_water_plane(coord)


func _place_water_plane(coord: Vector2i, heightmap: PackedFloat32Array) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _water_mesh
	mesh_instance.name = "Water_%d_%d" % [coord.x, coord.y]
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := _water_material.duplicate() as ShaderMaterial
	var depth_texture := _build_depth_texture(heightmap)
	mat.set_shader_parameter("terrain_depth_tex", depth_texture)
	mesh_instance.material_override = mat

	var world_pos := SharedWorld.chunk_to_world(coord)
	mesh_instance.position = Vector3(world_pos.x, _sea_level + 0.05, world_pos.z)

	add_child(mesh_instance)
	_chunk_water[coord] = mesh_instance
	_chunk_materials[coord] = mat
	SystemBus.water_chunk_placed.emit(coord)


func _remove_water_plane(coord: Vector2i) -> void:
	if _chunk_water.has(coord):
		var inst: MeshInstance3D = _chunk_water[coord]
		inst.queue_free()
		_chunk_water.erase(coord)
	_chunk_materials.erase(coord)


func system_process(delta: float) -> void:
	if not active:
		return
	if _config.waves_enabled:
		var time := Time.get_ticks_msec() / 1000.0
		_update_sea_state(delta)
		for coord in _chunk_materials.keys():
			var mat: ShaderMaterial = _chunk_materials[coord]
			if mat:
				_push_wave_state(mat, time)
		if _far_ocean_material:
			_push_wave_state(_far_ocean_material, time)
	_update_far_ocean()
	_update_underwater_effect()


## Track the sea state the weather is driving the surface toward.
##
## A real sea does not change with the wind instantly: it takes hours to build
## under a rising wind and longer to lay down again, and it always runs a
## little behind the weather. Easing toward the target is what stops the ocean
## from snapping between calm and storm the moment a weather state changes, and
## why swell keeps rolling after the wind has dropped.
func _update_sea_state(delta: float) -> void:
	var wind := SharedWorld.wind_direction
	var wind_xz := Vector2(wind.x, wind.z)
	if wind_xz.length_squared() > 0.0001:
		wind_xz = wind_xz.normalized()
		# Waves swing round to a new wind slowly, so the swell can be running
		# across the wind for a while after it shifts.
		_sea_wind_dir = _sea_wind_dir.lerp(wind_xz, 1.0 - exp(-_config.sea_turn_rate * delta))
		if _sea_wind_dir.length_squared() > 0.0001:
			_sea_wind_dir = _sea_wind_dir.normalized()

	var target := clampf(SharedWorld.wind_strength / maxf(_config.sea_state_full_wind, 0.001), 0.0, 1.0)
	# Rain comes with weather, and weather comes with sea.
	target = maxf(target, SharedWorld.rain_intensity * 0.75)
	var rate := _config.sea_build_rate if target > _sea_state else _config.sea_calm_rate
	_sea_state = lerpf(_sea_state, target, 1.0 - exp(-rate * delta))


func _push_wave_state(mat: ShaderMaterial, time: float) -> void:
	mat.set_shader_parameter("time", time)
	mat.set_shader_parameter("wind_dir", _sea_wind_dir)
	mat.set_shader_parameter("sea_state", _sea_state)
	mat.set_shader_parameter("rain_intensity", SharedWorld.rain_intensity)


# ── Far ocean ─────────────────────────────────────────────────────────────────
#
# The loaded chunk region is a floating island of geometry; past its edge
# there is nothing to catch the eye but sky-colored void. A flat ring of
# deep ocean at sea level, kept one chunk beyond the streaming frontier,
# gives the world a physical end: terrain coasts dissolve into open water
# that fades into the distance fog. Rebuilt only when the camera chunk
# changes, and never overlapping per-chunk water planes.

func _update_far_ocean() -> void:
	if not _config.far_ocean_enabled or not _sea_level_found:
		return
	if _far_ocean == null or not is_instance_valid(_far_ocean):
		_build_far_ocean()
	var chunk := SharedWorld.camera_chunk_pos
	if chunk != _far_ocean_chunk:
		_far_ocean_chunk = chunk
		_far_ocean.mesh = _build_far_ocean_ring(chunk)
		_far_ocean.position = Vector3(0.0, _sea_level + 0.05, 0.0)


func _build_far_ocean() -> void:
	var material := _water_material.duplicate() as ShaderMaterial
	# Flat full-depth texture: the ring has no heightmap, and depth = 1
	# selects the deep-water color zone (no shore foam, no caustics —
	# only deep swell and whitecap crests).
	var flat := Image.create(2, 2, false, Image.FORMAT_RF)
	flat.fill(Color(1.0, 0.0, 0.0, 1.0))
	material.set_shader_parameter("terrain_depth_tex", ImageTexture.create_from_image(flat))
	# The ring is 8 triangles spanning hundreds of metres. Displacing those
	# vertices does not make waves, it makes the whole outer ocean tilt in
	# huge flat facets, so the ring is left dead flat and shaded by normals.
	material.set_shader_parameter("displacement_scale", 0.0)
	var instance := MeshInstance3D.new()
	instance.name = "FarOcean"
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.material_override = material
	add_child(instance)
	_far_ocean = instance
	_far_ocean_material = material


## A rectangular ring: outer rect = inner (loaded region + 1 chunk margin)
## expanded by far_ocean_extent; vertices are world-space XZ at local y 0.
func _build_far_ocean_ring(chunk: Vector2i) -> ArrayMesh:
	var cs := GameConfig.chunk_size
	var margin := GameConfig.load_radius + 1
	var inner_min := Vector2(float(chunk.x - margin) * cs, float(chunk.y - margin) * cs)
	var inner_max := Vector2(float(chunk.x + margin + 1) * cs, float(chunk.y + margin + 1) * cs)
	var ext := _config.far_ocean_extent
	var outer_min := inner_min - Vector2.ONE * ext
	var outer_max := inner_max + Vector2.ONE * ext

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Four strips around the inner hole (N, S, W, E).
	_append_ring_quad(verts, uvs, indices,
		Vector2(outer_min.x, outer_min.y), Vector2(outer_max.x, inner_min.y))
	_append_ring_quad(verts, uvs, indices,
		Vector2(outer_min.x, inner_max.y), Vector2(outer_max.x, outer_max.y))
	_append_ring_quad(verts, uvs, indices,
		Vector2(outer_min.x, inner_min.y), Vector2(inner_min.x, inner_max.y))
	_append_ring_quad(verts, uvs, indices,
		Vector2(inner_max.x, inner_min.y), Vector2(outer_max.x, outer_max.y))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## One quad of the ring, wound to face +Y (the water shader culls back
## faces and reads UV only to sample the flat depth texture).
func _append_ring_quad(verts: PackedVector3Array, uvs: PackedVector2Array,
		indices: PackedInt32Array, min_xz: Vector2, max_xz: Vector2) -> void:
	var base := verts.size()
	verts.append(Vector3(min_xz.x, 0.0, min_xz.y))
	verts.append(Vector3(max_xz.x, 0.0, min_xz.y))
	verts.append(Vector3(max_xz.x, 0.0, max_xz.y))
	verts.append(Vector3(min_xz.x, 0.0, max_xz.y))
	for i in 4:
		uvs.append(Vector2(0.5, 0.5))
	indices.append(base)
	indices.append(base + 3)
	indices.append(base + 1)
	indices.append(base + 1)
	indices.append(base + 3)
	indices.append(base + 2)


## Detect if camera is underwater and apply fog/tint effect
func _update_underwater_effect() -> void:
	var viewport := get_viewport()
	if not viewport:
		return
	var cam := viewport.get_camera_3d()
	if not cam:
		return

	var water_surface_y := _sea_level
	var river_system := _find_system_by_type(RiverSystem) as RiverSystem
	if river_system:
		var river_surface_y := river_system.get_water_surface_height_at(cam.global_position)
		if river_surface_y != -INF:
			water_surface_y = maxf(water_surface_y, river_surface_y)

	var underwater := cam.global_position.y < water_surface_y

	# Lazy-find environment
	if not _environment:
		var current_scene := get_tree().current_scene
		if not current_scene:
			return
		var we_node := _find_node_of_type(current_scene, WorldEnvironment)
		if we_node and we_node is WorldEnvironment:
			_environment = (we_node as WorldEnvironment).environment
		if not _environment:
			return

	if underwater and not _is_underwater:
		# Entering water: save current fog and apply underwater fog
		_saved_fog_color = _environment.fog_light_color
		_saved_fog_density = _environment.fog_density
	if underwater:
		_environment.fog_enabled = true
		_environment.fog_light_color = Color(0.04, 0.18, 0.24)
		_environment.fog_density = 0.09
	elif _is_underwater:
		# Leaving water: restore saved fog
		_environment.fog_light_color = _saved_fog_color
		_environment.fog_density = _saved_fog_density

	_is_underwater = underwater


## Read sea level from SharedWorld (written by TerrainSystem at init)
func _find_sea_level() -> float:
	return SharedWorld.sea_level


func _build_depth_texture(heightmap: PackedFloat32Array) -> ImageTexture:
	var res := int(sqrt(heightmap.size()))
	var image := Image.create(res, res, false, Image.FORMAT_RF)
	for z in res:
		for x in res:
			var h := heightmap[z * res + x]
			var depth := clampf((_sea_level - h) / maxf(_config.shore_depth_range, 0.001), 0.0, 1.0)
			image.set_pixel(x, z, Color(depth, 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(image)


## Check if any vertex in the heightmap is near or below sea level
func _chunk_needs_water(heightmap: PackedFloat32Array) -> bool:
	var threshold := _sea_level + 1.0
	for h in heightmap:
		if h < threshold:
			return true
	return false




func _shutdown() -> void:
	for coord in _chunk_water.keys():
		_remove_water_plane(coord)
