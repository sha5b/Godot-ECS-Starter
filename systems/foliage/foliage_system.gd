class_name FoliageSystem
extends BaseSystem

const FOLIAGE_SHADER = preload("res://systems/foliage/foliage_billboard.gdshader")
const FOLIAGE_CONFIG_SCRIPT = preload("res://systems/foliage/foliage_config.gd")
const TERRAIN_SYSTEM_SCRIPT = preload("res://systems/terrain/terrain_system.gd")
const FOLIAGE_SHAPE_TEXTURE_PATH := "res://systems/foliage/assets/foliage_basic_shape.png"
const FOLIAGE_ATLAS_TEXTURE_PATH := "res://systems/foliage/assets/foliage_stylized_atlas.png"
const FOLIAGE_FALLBACK_ATLAS_TEXTURE_PATH := "res://systems/foliage/assets/foliage_basic_atlas.png"
const FOLIAGE_PALETTE_TEXTURE_PATH := "res://systems/foliage/assets/foliage_palette_01.tres"

var _config
var _biome_system: BiomeSystem
var _terrain_system: BaseSystem
var _foliage_material: ShaderMaterial
var _foliage_mesh: ArrayMesh
var _noise_texture: NoiseTexture2D
var _wind_texture: NoiseTexture2D
var _shape_texture: Texture2D
var _shape_atlas: Texture2D
var _color_gradient: Texture2D
var _chunk_foliage: Dictionary = {}
var _pending_chunk_biomes: Dictionary = {}
## Chemistry reactivity per chunk: spatial buckets (cell -> instance
## indices) and the original instance colors to restore after events.
const CHEMISTRY_CELL := 4.0
const CHEMISTRY_RADIUS := 2.3
var _chunk_chem_buckets: Dictionary = {}
var _chunk_chem_colors: Dictionary = {}
## CPU-side instance origins per chunk (see _build_chunk_foliage).
var _chunk_instance_origins: Dictionary = {}
var _sea_level: float = 0.0
var _height_scale: float = 20.0
var _terrain_found: bool = false
var _use_atlas: bool = false

func _initialize() -> void:
	system_name = &"FoliageSystem"
	priority = 28
	_config = _find_child_of_type(FOLIAGE_CONFIG_SCRIPT)
	if not _config:
		_config = FOLIAGE_CONFIG_SCRIPT.new()
	_setup_assets()
	_setup_material()
	_setup_mesh()
	_validate_setup()

func _register_signals() -> void:
	SystemBus.biome_chunk_ready.connect(_on_biome_chunk_ready)
	SystemBus.terrain_chunk_ready.connect(_on_terrain_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)
	SystemBus.ecs_event.connect(_on_ecs_event)

func system_process(_delta: float) -> void:
	if not active or not _foliage_material:
		return
	var wind_vec := SharedWorld.wind_vector
	var wind_xz := Vector2(wind_vec.x, wind_vec.z)
	if wind_xz.length_squared() > 0.0001:
		wind_xz = wind_xz.normalized() * clampf(SharedWorld.wind_strength * 0.45, 0.08, 1.35)
	else:
		wind_xz = Vector2(0.15, 0.0)
	_foliage_material.set_shader_parameter("wind_velocity", wind_xz)

func _setup_assets() -> void:
	if ResourceLoader.exists(FOLIAGE_SHAPE_TEXTURE_PATH):
		_shape_texture = load(FOLIAGE_SHAPE_TEXTURE_PATH) as Texture2D
	if ResourceLoader.exists(FOLIAGE_ATLAS_TEXTURE_PATH):
		_shape_atlas = load(FOLIAGE_ATLAS_TEXTURE_PATH) as Texture2D
	elif ResourceLoader.exists(FOLIAGE_FALLBACK_ATLAS_TEXTURE_PATH):
		_shape_atlas = load(FOLIAGE_FALLBACK_ATLAS_TEXTURE_PATH) as Texture2D
	if ResourceLoader.exists(FOLIAGE_PALETTE_TEXTURE_PATH):
		_color_gradient = load(FOLIAGE_PALETTE_TEXTURE_PATH) as Texture2D
	_use_atlas = _shape_atlas != null
	var color_noise := FastNoiseLite.new()
	color_noise.seed = GameConfig.world_seed + 6100
	color_noise.frequency = 0.01
	_noise_texture = NoiseTexture2D.new()
	_noise_texture.width = 512
	_noise_texture.height = 512
	_noise_texture.seamless = true
	_noise_texture.noise = color_noise
	var wind_noise := FastNoiseLite.new()
	wind_noise.seed = GameConfig.world_seed + 6200
	wind_noise.frequency = 0.025
	wind_noise.fractal_octaves = 3
	_wind_texture = NoiseTexture2D.new()
	_wind_texture.width = 512
	_wind_texture.height = 512
	_wind_texture.seamless = true
	_wind_texture.noise = wind_noise

func _setup_material() -> void:
	_foliage_material = ShaderMaterial.new()
	_foliage_material.shader = FOLIAGE_SHADER
	if _shape_texture:
		_foliage_material.set_shader_parameter("shape_texture", _shape_texture)
	else:
		push_warning("[FoliageSystem] Required foliage shape texture missing; foliage will not render correctly")
	if _use_atlas and _shape_atlas:
		_foliage_material.set_shader_parameter("shape_atlas", _shape_atlas)
	if _color_gradient:
		_foliage_material.set_shader_parameter("color_gradient", _color_gradient)
	_foliage_material.set_shader_parameter("use_atlas", _use_atlas)
	# Crossed quads are camera-independent; billboarding would collapse
	# them into slivers from the RTS top-down view.
	_foliage_material.set_shader_parameter("billboard", false)
	_foliage_material.set_shader_parameter("noise_texture", _noise_texture)
	_foliage_material.set_shader_parameter("wind_texture", _wind_texture)
	_foliage_material.set_shader_parameter("wind_velocity", Vector2(0.15, 0.0))

func _setup_mesh() -> void:
	_foliage_mesh = _build_cross_quad_mesh(_config.quad_width, _config.quad_height)


## Six blades splayed outward from the base. Camera-facing billboards
## collapse into thin slivers when viewed from the RTS god camera's steep
## top-down angle — and so do plain vertical crossed quads, because a
## vertical quad projects to a line from above no matter how wide it is.
## Tipping each blade outward around its base edge gives every tuft a full
## silhouette from above without a horizontal canopy card (which samples
## the vertical blade art sideways and reads as a flat square dot).
## UV.y runs 0 at the base to 1 at the top, matching the shader's wind
## bend and brightness gradients.
func _build_cross_quad_mesh(width: float, height: float) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half_w := width * 0.5
	var tip_radians := deg_to_rad(26.0)
	var lean := height * sin(tip_radians)
	var top_y := height * cos(tip_radians)
	for blade in 6:
		var angle := TAU * float(blade) / 6.0
		var across := Vector3(cos(angle), 0.0, sin(angle)) * half_w
		var outward := Vector3(-sin(angle), 0.0, cos(angle)) * lean
		var top := Vector3.UP * top_y + outward
		var base_index := verts.size()
		verts.append(-across)
		verts.append(across)
		verts.append(across * 0.82 + top)
		verts.append(-across * 0.82 + top)
		uvs.append(Vector2(0.0, 0.0))
		uvs.append(Vector2(1.0, 0.0))
		uvs.append(Vector2(1.0, 1.0))
		uvs.append(Vector2(0.0, 1.0))
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for corner in tri:
				indices.append(base_index + corner)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _validate_setup() -> void:
	if not _shape_texture:
		push_warning("[FoliageSystem] Missing required foliage shape texture at %s" % FOLIAGE_SHAPE_TEXTURE_PATH)
	if not _color_gradient:
		push_warning("[FoliageSystem] Missing required foliage palette texture at %s" % FOLIAGE_PALETTE_TEXTURE_PATH)
	if _use_atlas and not _shape_atlas:
		push_warning("[FoliageSystem] Foliage atlas expected but failed to load at %s" % FOLIAGE_ATLAS_TEXTURE_PATH)
	if not _use_atlas:
		print("[FoliageSystem] Atlas not found, using single foliage cutout texture only")
	if not _foliage_material:
		push_warning("[FoliageSystem] Foliage material failed to initialize")
	if not _foliage_mesh:
		push_warning("[FoliageSystem] Foliage mesh failed to initialize")

func _on_biome_chunk_ready(coord: Vector2i, biome_map: PackedByteArray) -> void:
	if _chunk_foliage.has(coord):
		return
	_pending_chunk_biomes[coord] = biome_map
	if not _biome_system:
		_biome_system = _find_system_by_type(BiomeSystem) as BiomeSystem
	if not _terrain_system:
		_terrain_system = _find_system_by_type(TERRAIN_SYSTEM_SCRIPT)
	if not _terrain_found:
		_sea_level = SharedWorld.sea_level
		_height_scale = SharedWorld.height_scale
		_terrain_found = true
	_try_build_pending_chunk_foliage(coord)

func _on_terrain_chunk_ready(coord: Vector2i, _heightmap: PackedFloat32Array) -> void:
	_try_build_pending_chunk_foliage(coord)

func _on_chunk_unload_requested(coord: Vector2i) -> void:
	_pending_chunk_biomes.erase(coord)
	_clear_chunk_foliage(coord)

func _try_build_pending_chunk_foliage(coord: Vector2i) -> void:
	if _chunk_foliage.has(coord):
		return
	if not _pending_chunk_biomes.has(coord):
		return
	var biome_map: PackedByteArray = _pending_chunk_biomes[coord]
	if _build_chunk_foliage(coord, biome_map):
		_pending_chunk_biomes.erase(coord)

func _build_chunk_foliage(coord: Vector2i, biome_map: PackedByteArray) -> bool:
	var chunk_manager := _find_system_by_type(ChunkManager) as ChunkManager
	if not chunk_manager:
		return false
	var chunk_data := chunk_manager.get_chunk(coord)
	if not chunk_data or chunk_data.heightmap.is_empty():
		return false
	var res := int(sqrt(biome_map.size()))
	if res <= 1:
		return false
	var rng := RandomNumberGenerator.new()
	rng.seed = GameConfig.chunk_hash(coord.x, coord.y) + 9137
	var cs := GameConfig.chunk_size
	var instances := _generate_chunk_foliage_instances(coord, biome_map, res, cs, rng)
	if instances.is_empty():
		return false
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _foliage_mesh
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.instance_count = instances.size()
	multimesh.visible_instance_count = instances.size()
	# MultiMesh transforms cannot be read back from the rendering server —
	# keep a CPU-side copy of instance origins for chemistry buckets and
	# QA checks.
	var origins := PackedVector3Array()
	origins.resize(instances.size())
	for i in range(instances.size()):
		var instance_data: Dictionary = instances[i]
		multimesh.set_instance_transform(i, instance_data["transform"])
		multimesh.set_instance_color(i, instance_data["color"])
		multimesh.set_instance_custom_data(i, instance_data["custom_data"])
		origins[i] = (instance_data["transform"] as Transform3D).origin
	_chunk_instance_origins[coord] = origins
	multimesh.custom_aabb = AABB(Vector3(-cs * 0.5, -1.0, -cs * 0.5), Vector3(cs, maxf(_config.quad_height * _config.scale_max + 3.0, 4.0), cs))
	var foliage_instance := MultiMeshInstance3D.new()
	foliage_instance.name = "Foliage_%d_%d" % [coord.x, coord.y]
	foliage_instance.multimesh = multimesh
	foliage_instance.material_override = _foliage_material
	var world_pos := SharedWorld.chunk_to_world(coord)
	foliage_instance.position = Vector3(world_pos.x, 0.0, world_pos.z)
	foliage_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if not _config.cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	foliage_instance.extra_cull_margin = cs
	if _config.view_distance > 0.0:
		foliage_instance.visibility_range_end = _config.view_distance
		foliage_instance.visibility_range_end_margin = _config.view_fade
		foliage_instance.visibility_range_fade_mode = \
			GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(foliage_instance)
	_chunk_foliage[coord] = foliage_instance
	SystemBus.flora_chunk_spawned.emit(coord, instances.size())
	return true

func _generate_chunk_foliage_instances(coord: Vector2i, biome_map: PackedByteArray,
		res: int, cs: float, rng: RandomNumberGenerator) -> Array[Dictionary]:
	var instances: Array[Dictionary] = []
	var target_count := mini(_config.max_instances_per_chunk, _config.density_per_chunk)
	var cell_step := cs / float(res - 1)
	var stride := maxi(_config.sample_cell_stride, 1)
	var river_lookup := _build_river_clearance_lookup(coord)
	for gz in range(0, res - 1, stride):
		for gx in range(0, res - 1, stride):
			if instances.size() >= target_count:
				return instances
			var biome_idx := biome_map[gz * res + gx]
			var density_score := _get_foliage_density_score(biome_idx)
			if density_score <= 0.01:
				continue
			var local_center_x := float(gx) * cell_step
			var local_center_z := float(gz) * cell_step
			var center_height := _sample_terrain_height(coord, local_center_x, local_center_z)
			var height_norm := clampf((center_height - _sea_level) / maxf(_height_scale, 0.001), 0.0, 1.0)
			if not _is_valid_foliage_site(coord, gx, gz, local_center_x, local_center_z, center_height, river_lookup):
				continue
			var center_slope := _sample_terrain_slope(coord, local_center_x, local_center_z)
			var slope_factor := 1.0 - clampf(center_slope / maxf(_config.max_slope_degrees, 0.001), 0.0, 1.0)
			var height_factor := _get_foliage_height_factor(biome_idx, height_norm)
			var shoreline_factor := clampf(
				(center_height - (_sea_level + _config.min_water_clearance)) / maxf(_config.shoreline_fade_distance, 0.001),
				0.0,
				1.0
			)
			var density_bias := pow(clampf(density_score, 0.0, 1.0), 0.74)
			var coverage := density_bias * (0.62 + slope_factor * 0.22) * (0.58 + shoreline_factor * 0.22) * (0.40 + height_factor * 0.60)
			if coverage <= 0.05:
				continue
			var cluster_count := clampi(int(round(lerpf(7.0, float(_config.cluster_per_cell_max), coverage))), 3, _config.cluster_per_cell_max)
			for cluster_index in range(cluster_count):
				if instances.size() >= target_count:
					return instances
				if cluster_index > 0 and rng.randf() > clampf(coverage * 1.28, 0.0, 1.0):
					continue
				var jitter_scale: float = cell_step * _config.jitter_within_cell
				var local_x := clampf(local_center_x + rng.randf_range(-jitter_scale, jitter_scale), 0.0, cs)
				var local_z := clampf(local_center_z + rng.randf_range(-jitter_scale, jitter_scale), 0.0, cs)
				var dist_from_center := Vector2(local_x - local_center_x, local_z - local_center_z).length()
				var interior_t := 1.0 - clampf(dist_from_center / maxf(jitter_scale, 0.001), 0.0, 1.0)
				interior_t *= interior_t
				var sample_gx := clampi(int(round(local_x / cell_step)), 0, res - 1)
				var sample_gz := clampi(int(round(local_z / cell_step)), 0, res - 1)
				var height := _sample_terrain_height(coord, local_x, local_z)
				if not _is_valid_foliage_site(coord, sample_gx, sample_gz, local_x, local_z, height, river_lookup):
					continue
				instances.append(_create_foliage_instance(coord, biome_idx, local_x, local_z, height, cs, coverage, interior_t, rng))
	return instances

func _build_river_clearance_lookup(coord: Vector2i) -> Dictionary:
	var lookup: Dictionary = {}
	var river_cells: Array = SharedWorld.river_cells.get(coord, [])
	var clearance := maxi(_config.river_cell_clearance, 0)
	for river_cell in river_cells:
		var gx := int(river_cell.get("gx", -1))
		var gz := int(river_cell.get("gz", -1))
		if gx < 0 or gz < 0:
			continue
		for offset_z in range(-clearance, clearance + 1):
			for offset_x in range(-clearance, clearance + 1):
				lookup[Vector2i(gx + offset_x, gz + offset_z)] = true
	return lookup

func _is_valid_foliage_site(coord: Vector2i, gx: int, gz: int,
		local_x: float, local_z: float, height: float, river_lookup: Dictionary) -> bool:
	if river_lookup.has(Vector2i(gx, gz)):
		return false
	if height < _sea_level + _config.min_water_clearance:
		return false
	var height_norm := clampf((height - _sea_level) / maxf(_height_scale, 0.001), 0.0, 1.0)
	if height_norm < _config.min_height or height_norm > _config.max_height:
		return false
	var slope := _sample_terrain_slope(coord, local_x, local_z)
	return slope <= _config.max_slope_degrees

func _create_foliage_instance(coord: Vector2i, biome_idx: int, local_x: float, local_z: float,
		height: float, cs: float, coverage: float, interior_t: float,
		rng: RandomNumberGenerator) -> Dictionary:
	var height_norm := clampf((height - _sea_level) / maxf(_height_scale, 0.001), 0.0, 1.0)
	var biome_data: BiomeData = _biome_system.get_biome_data(biome_idx) if _biome_system else null
	var biome_name: StringName = biome_data.biome_name if biome_data else &"plains"
	var sprite_index := _pick_foliage_sprite_index(biome_name, rng)
	var biome_scale_mult := _get_biome_scale_multiplier(biome_name, height_norm)
	var sprite_scale_options: Array[float] = [0.82, 1.34, 1.08, 0.96]
	var sprite_scale_mult: float = sprite_scale_options[sprite_index]
	var scale_roll := rng.randf()
	var base_scale_value: float
	if scale_roll < 0.22:
		base_scale_value = rng.randf_range(_config.scale_min, lerpf(_config.scale_min, _config.scale_max, 0.36))
	elif scale_roll < 0.82:
		base_scale_value = rng.randf_range(lerpf(_config.scale_min, _config.scale_max, 0.28), lerpf(_config.scale_min, _config.scale_max, 0.74))
	else:
		base_scale_value = rng.randf_range(lerpf(_config.scale_min, _config.scale_max, 0.72), _config.scale_max)
	var cluster_scale_t := clampf(coverage * 0.55 + interior_t * 0.45, 0.0, 1.0)
	var cluster_scale_mult := lerpf(0.78, 1.18, cluster_scale_t)
	var scale_value: float = base_scale_value * biome_scale_mult * sprite_scale_mult * cluster_scale_mult
	var chunk_origin := SharedWorld.chunk_to_world(coord)
	var world_x := -cs * 0.5 + local_x
	var world_z := -cs * 0.5 + local_z
	var world_sample_x := chunk_origin.x + world_x
	var world_sample_z := chunk_origin.z + world_z
	var ground_normal := _sample_ground_normal(world_sample_x, world_sample_z, cs)
	var basis := _build_foliage_basis(ground_normal, scale_value, rng)
	var slope_sink_t := clampf(1.0 - ground_normal.y, 0.0, 1.0)
	var ground_color := _sample_ground_color(world_sample_x, world_sample_z, height, biome_data)
	var ground_tint := Color(
		clampf(ground_color.r * rng.randf_range(0.97, 1.04), 0.0, 1.0),
		clampf(ground_color.g * rng.randf_range(0.98, 1.06), 0.0, 1.0),
		clampf(ground_color.b * rng.randf_range(0.96, 1.04), 0.0, 1.0),
		1.0
	)
	var custom_data := Color(
		(float(sprite_index) + 0.5) / 4.0,
		_get_biome_lushness(biome_name),
		_get_biome_dryness(biome_name),
		height_norm
	)
	var extra_slope_sink := scale_value * 0.34 * slope_sink_t
	var planted_height: float = height - _config.ground_sink * scale_value - extra_slope_sink - scale_value * 0.04 + _config.ground_contact_lift
	return {
		"transform": Transform3D(basis, Vector3(world_x, planted_height, world_z)),
		"color": ground_tint,
		"custom_data": custom_data,
	}

func _sample_ground_normal(world_x: float, world_z: float, cs: float) -> Vector3:
	if not _terrain_system:
		_terrain_system = _find_system_by_type(TERRAIN_SYSTEM_SCRIPT)
	if _terrain_system and _terrain_system.has_method("_sample_loaded_surface_normal"):
		var sample_step := cs / maxf(float(_config.density_per_chunk), 1.0)
		return _terrain_system._sample_loaded_surface_normal(world_x, world_z, maxf(sample_step, 0.35))
	return Vector3.UP

func _build_foliage_basis(surface_normal: Vector3, scale_value: float, rng: RandomNumberGenerator) -> Basis:
	var up := Vector3.UP
	var clamped_normal := surface_normal.normalized()
	var max_align_radians := deg_to_rad(_config.terrain_normal_max_degrees)
	var normal_angle := acos(clampf(up.dot(clamped_normal), -1.0, 1.0))
	if normal_angle > max_align_radians and normal_angle > 0.0001:
		var axis := up.cross(clamped_normal).normalized()
		clamped_normal = up.rotated(axis, max_align_radians)
	var aligned_up := up.slerp(clamped_normal, clampf(_config.terrain_normal_align_strength, 0.0, 1.0)).normalized()
	var yaw := PI * 0.25 if rng.randf() < 0.5 else rng.randf() * TAU
	var facing := Vector3.FORWARD.rotated(aligned_up, yaw)
	if absf(facing.dot(aligned_up)) > 0.98:
		facing = Vector3.RIGHT.rotated(aligned_up, yaw)
	var right := aligned_up.cross(facing).normalized()
	var forward := right.cross(aligned_up).normalized()
	return Basis(right * scale_value, aligned_up * scale_value, forward * scale_value)

func _sample_ground_color(world_x: float, world_z: float, height: float, biome_data: BiomeData) -> Color:
	if not _terrain_system:
		_terrain_system = _find_system_by_type(TERRAIN_SYSTEM_SCRIPT)
	if _terrain_system and _terrain_system.has_method("sample_surface_color_at_world"):
		return _terrain_system.sample_surface_color_at_world(world_x, world_z, height)
	if biome_data:
		return biome_data.terrain_color
	return Color(0.42, 0.62, 0.28, 1.0)

func _get_foliage_density_score(biome_idx: int) -> float:
	if not _biome_system:
		return 0.75
	var biome_data := _biome_system.get_biome_data(biome_idx)
	if not biome_data:
		return 0.65
	if _config.excluded_biomes.has(biome_data.biome_name):
		return 0.0
	var density := 0.5 + clampf(biome_data.flora_density_multiplier, 0.0, 3.0) * 0.4
	match biome_data.biome_name:
		&"plains", &"forest", &"rainforest", &"swamp", &"taiga", &"alpine_meadow":
			density += 0.38
		&"savanna":
			density += 0.2
		&"mountain", &"karst", &"canyon", &"tundra":
			density -= 0.08
	return clampf(density, 0.0, 1.0)


func _get_foliage_height_factor(biome_idx: int, height_norm: float) -> float:
	if not _biome_system:
		return 1.0
	var biome_data := _biome_system.get_biome_data(biome_idx)
	if not biome_data:
		return 1.0
	var tolerance := maxf(biome_data.height_tolerance, 0.001)
	var height_dist := absf(height_norm - biome_data.ideal_height)
	if height_dist >= tolerance:
		return 0.0
	return clampf(1.0 - height_dist / tolerance, 0.0, 1.0)

func _pick_foliage_sprite_index(biome_name: StringName, rng: RandomNumberGenerator) -> int:
	match biome_name:
		&"forest", &"rainforest", &"swamp":
			return [0, 1, 3, 3][rng.randi_range(0, 3)]
		&"plains", &"taiga", &"alpine_meadow":
			return [0, 0, 2, 3][rng.randi_range(0, 3)]
		&"savanna", &"mountain", &"karst", &"canyon", &"tundra":
			return [0, 2, 2, 3][rng.randi_range(0, 3)]
	return rng.randi_range(0, 3)

func _get_biome_scale_multiplier(biome_name: StringName, height_norm: float) -> float:
	var scale_mult := 1.0
	match biome_name:
		&"rainforest", &"swamp":
			scale_mult = 1.18
		&"forest", &"taiga":
			scale_mult = 1.08
		&"savanna":
			scale_mult = 0.92
		&"tundra", &"alpine_meadow", &"mountain", &"karst", &"canyon":
			scale_mult = 0.82
	return scale_mult * lerpf(0.94, 1.08, clampf(1.0 - absf(height_norm - 0.35), 0.0, 1.0))

func _get_biome_lushness(biome_name: StringName) -> float:
	match biome_name:
		&"rainforest":
			return 1.0
		&"swamp", &"forest":
			return 0.82
		&"taiga", &"plains", &"alpine_meadow":
			return 0.64
		&"savanna":
			return 0.38
		&"mountain", &"karst", &"canyon", &"tundra":
			return 0.22
	return 0.55

func _get_biome_dryness(biome_name: StringName) -> float:
	match biome_name:
		&"savanna":
			return 0.72
		&"mountain", &"karst", &"canyon", &"tundra":
			return 0.48
		&"plains", &"alpine_meadow":
			return 0.28
		&"forest", &"taiga":
			return 0.16
		&"rainforest", &"swamp":
			return 0.08
	return 0.22

## React to ECS chemistry events by recoloring nearby foliage instances —
## fire visibly spreads and chars the rendered meadow, rain-doused and
## thawed patches restore their original tint.
func _on_ecs_event(channel: StringName, payload: Dictionary) -> void:
	if _config != null and not _config.get("chemistry_reactive"):
		return
	var position: Vector3 = payload.get("position", Vector3.ZERO)
	if position == Vector3.ZERO and not payload.has("position"):
		return
	var coord := SharedWorld.world_to_chunk(position)
	var foliage := _chunk_foliage.get(coord) as MultiMeshInstance3D
	if foliage == null:
		return
	var color := Color.WHITE
	var restore := false
	match channel:
		ChemistryDefs.CHANNEL_IGNITED:
			color = Color(1.0, 0.42, 0.1)
		ChemistryDefs.CHANNEL_BURNED_OUT:
			color = Color(0.07, 0.06, 0.05)
		ChemistryDefs.CHANNEL_EXTINGUISHED:
			restore = true  # put the original tint back
		ChemistryDefs.CHANNEL_FROZEN:
			if bool(payload.get("frozen", true)):
				color = Color(0.66, 0.85, 1.0)
			else:
				restore = true
		_:
			return
	_react_cluster(foliage, coord, position, color, restore)


func _react_cluster(foliage: MultiMeshInstance3D, coord: Vector2i,
		world_position: Vector3, color: Color, restore := false) -> void:
	var multimesh := foliage.multimesh
	if multimesh == null:
		return
	if not _chunk_chem_buckets.has(coord):
		if not _build_chem_buckets(foliage, coord):
			return
	var buckets: Dictionary = _chunk_chem_buckets[coord]
	var originals: PackedColorArray = _chunk_chem_colors[coord]

	# Event positions are world-space; instances are chunk-local.
	var local := world_position - foliage.global_position
	var center := Vector2i(floori(local.x / CHEMISTRY_CELL), floori(local.z / CHEMISTRY_CELL))
	var radius_sq := CHEMISTRY_RADIUS * CHEMISTRY_RADIUS
	for cx in range(center.x - 1, center.x + 2):
		for cz in range(center.y - 1, center.y + 2):
			var indices: PackedInt32Array = buckets.get(Vector2i(cx, cz), PackedInt32Array())
			for index in indices:
				var origin := multimesh.get_instance_transform(index).origin
				var dx := origin.x - local.x
				var dz := origin.z - local.z
				if dx * dx + dz * dz > radius_sq:
					continue
				multimesh.set_instance_color(index,
					originals[index] if restore else color)


## Bucket instances into coarse cells once per chunk so events recolor a
## handful of instances instead of scanning thousands.
func _build_chem_buckets(foliage: MultiMeshInstance3D, coord: Vector2i) -> bool:
	var multimesh := foliage.multimesh
	var origins: PackedVector3Array = _chunk_instance_origins.get(coord, PackedVector3Array())
	if multimesh == null or origins.is_empty():
		return false
	var buckets: Dictionary = {}
	var originals := PackedColorArray()
	var count := mini(multimesh.instance_count, origins.size())
	for i in count:
		var origin := origins[i]
		var cell := Vector2i(floori(origin.x / CHEMISTRY_CELL), floori(origin.z / CHEMISTRY_CELL))
		if not buckets.has(cell):
			buckets[cell] = PackedInt32Array()
		buckets[cell].append(i)
		originals.append(multimesh.get_instance_color(i))
	_chunk_chem_buckets[coord] = buckets
	_chunk_chem_colors[coord] = originals
	return true


func _clear_chunk_foliage(coord: Vector2i) -> void:
	_chunk_chem_buckets.erase(coord)
	_chunk_chem_colors.erase(coord)
	_chunk_instance_origins.erase(coord)
	if not _chunk_foliage.has(coord):
		return
	var inst := _chunk_foliage[coord] as MultiMeshInstance3D
	if inst:
		inst.queue_free()
	_chunk_foliage.erase(coord)
	SystemBus.flora_chunk_cleared.emit(coord)

func _shutdown() -> void:
	for coord in _chunk_foliage.keys():
		_clear_chunk_foliage(coord)
