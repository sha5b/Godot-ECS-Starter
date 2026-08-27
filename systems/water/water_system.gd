class_name WaterSystem
extends BaseSystem

## Places a translucent water plane at sea level for each loaded chunk.
## Listens for chunk lifecycle signals to add/remove water.

var _config: WaterConfig
var _water_material: ShaderMaterial
var _water_mesh: PlaneMesh
var _sea_level: float = 0.0
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
	var shader := Shader.new()
	shader.code = _get_water_shader_code()
	_water_material = ShaderMaterial.new()
	_water_material.shader = shader
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
	_water_material.set_shader_parameter("caustics_enabled", _config.caustics_enabled)
	_water_material.set_shader_parameter("caustics_strength", _config.caustics_strength)
	_water_material.set_shader_parameter("caustics_speed", _config.caustics_speed)


func _setup_mesh() -> void:
	_water_mesh = PlaneMesh.new()
	_water_mesh.size = Vector2(GameConfig.chunk_size, GameConfig.chunk_size)
	_water_mesh.subdivide_width = 128
	_water_mesh.subdivide_depth = 128


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


func system_process(_delta: float) -> void:
	if not active:
		return
	if _config.waves_enabled:
		var time := Time.get_ticks_msec() / 1000.0
		for coord in _chunk_materials.keys():
			var mat: ShaderMaterial = _chunk_materials[coord]
			if mat:
				mat.set_shader_parameter("time", time)
		if _far_ocean_material:
			_far_ocean_material.set_shader_parameter("time", time)
	_update_far_ocean()
	_update_underwater_effect()


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
	var river_system := _find_system_by_type(RiverSystem)
	if river_system and river_system.has_method("get_water_surface_height_at"):
		var river_surface_y = river_system.get_water_surface_height_at(cam.global_position)
		if river_surface_y != -INF:
			water_surface_y = maxf(water_surface_y, float(river_surface_y))

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


func _get_water_shader_code() -> String:
	return """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, specular_schlick_ggx;

// ── 4-zone depth colors ──
uniform vec4 shore_color : source_color = vec4(0.30, 0.65, 0.60, 0.35);
uniform vec4 shallow_color : source_color = vec4(0.15, 0.55, 0.60, 0.5);
uniform vec4 mid_color : source_color = vec4(0.08, 0.28, 0.42, 0.75);
uniform vec4 deep_color : source_color = vec4(0.03, 0.08, 0.20, 0.92);
uniform float mid_depth_start = 0.25;
uniform float deep_depth_start = 0.6;

// ── Foam ──
uniform vec4 foam_color : source_color = vec4(0.92, 0.95, 1.0, 0.9);
uniform float foam_width = 0.8;
uniform float foam_noise_scale = 8.0;

// ── Waves ──
uniform float wave_amplitude = 0.12;
uniform float wave_frequency = 1.5;
uniform float wave_speed = 0.8;
uniform float shore_depth_range = 4.0;
uniform float shore_wave_min_depth = 0.15;
uniform float shore_wave_max_depth = 0.8;
uniform float shore_break_strength = 0.55;

// ── Material ──
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float metallic : hint_range(0.0, 1.0) = 0.3;
uniform float time = 0.0;
uniform float refraction_amount = 0.7;
uniform float fresnel_strength = 0.42;

// ── Caustics ──
uniform bool caustics_enabled = true;
uniform float caustics_strength = 0.3;
uniform float caustics_speed = 1.2;

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D terrain_depth_tex : source_color, filter_linear_mipmap, repeat_disable;

varying float v_terrain_depth;
varying vec3 v_world_pos;

// ── Vertex: broad swell + shore break ──
void vertex() {
	v_terrain_depth = texture(terrain_depth_tex, UV).r;
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_pos = world_pos;

	float depth_factor = smoothstep(shore_wave_min_depth, shore_wave_max_depth, v_terrain_depth);

	float swell1 = sin(world_pos.x * 0.04 + world_pos.z * 0.015 + time * wave_speed * 0.4) * wave_amplitude * 0.7;
	float swell2 = sin(world_pos.z * 0.035 - world_pos.x * 0.012 + time * wave_speed * 0.3) * wave_amplitude * 0.5;
	float shore_wave = sin((world_pos.x * 0.35 + world_pos.z * 1.1) * wave_frequency * 2.2 - time * wave_speed * 4.0) * wave_amplitude * shore_break_strength;

	float displacement = (swell1 + swell2) * depth_factor + shore_wave * (1.0 - depth_factor) * v_terrain_depth;
	VERTEX.y += displacement;
}

// ── Wave normal (6 octaves, resolution-independent) ──
vec3 wave_normal(vec2 pos, float t) {
	float dx = 0.0;
	float dz = 0.0;

	vec2 d1 = vec2(0.98, 0.18); float f1 = 0.08;
	float p1 = dot(pos, d1) * f1 + t * 0.35;
	dx += cos(p1) * d1.x * f1 * 0.45;
	dz += cos(p1) * d1.y * f1 * 0.45;

	vec2 d2 = vec2(0.39, 0.92); float f2 = 0.12;
	float p2 = dot(pos, d2) * f2 + t * 0.28;
	dx += cos(p2) * d2.x * f2 * 0.35;
	dz += cos(p2) * d2.y * f2 * 0.35;

	vec2 d3 = vec2(-0.75, 0.66); float f3 = 0.22;
	float p3 = dot(pos, d3) * f3 + t * 0.45;
	dx += cos(p3) * d3.x * f3 * 0.25;
	dz += cos(p3) * d3.y * f3 * 0.25;

	vec2 d4 = vec2(0.55, -0.84); float f4 = 0.45;
	float p4 = dot(pos, d4) * f4 + t * 0.6;
	dx += cos(p4) * d4.x * f4 * 0.15;
	dz += cos(p4) * d4.y * f4 * 0.15;

	vec2 d5 = vec2(-0.42, -0.91); float f5 = 0.65;
	float p5 = dot(pos, d5) * f5 + t * 0.72;
	dx += cos(p5) * d5.x * f5 * 0.10;
	dz += cos(p5) * d5.y * f5 * 0.10;

	vec2 d6 = vec2(0.87, 0.50); float f6 = 1.1;
	float p6 = dot(pos, d6) * f6 + t * 0.9;
	dx += cos(p6) * d6.x * f6 * 0.06;
	dz += cos(p6) * d6.y * f6 * 0.06;

	return normalize(vec3(-dx, 1.0, -dz));
}

// ── Caustics pattern (animated voronoi-like) ──
float caustic_pattern(vec2 uv, float t) {
	vec2 p = uv * 3.0;
	float c = 0.0;
	c += sin(p.x * 5.3 + t * 1.1) * sin(p.y * 4.7 - t * 0.9) * 0.5 + 0.5;
	c *= sin(p.x * 3.1 - t * 0.7) * sin(p.y * 6.2 + t * 1.3) * 0.5 + 0.5;
	c += sin((p.x + p.y) * 4.0 + t * 0.5) * 0.3;
	return clamp(c, 0.0, 1.0);
}

// ── 4-zone color blend based on terrain depth ──
vec4 depth_zone_color(float d) {
	if (d < mid_depth_start) {
		float t = d / max(mid_depth_start, 0.001);
		return mix(shore_color, shallow_color, smoothstep(0.0, 1.0, t));
	} else if (d < deep_depth_start) {
		float t = (d - mid_depth_start) / max(deep_depth_start - mid_depth_start, 0.001);
		return mix(shallow_color, mid_color, smoothstep(0.0, 1.0, t));
	} else {
		float t = (d - deep_depth_start) / max(1.0 - deep_depth_start, 0.001);
		return mix(mid_color, deep_color, smoothstep(0.0, 1.0, min(t, 1.0)));
	}
}

void fragment() {
	float depth_factor = smoothstep(shore_wave_min_depth, shore_wave_max_depth, v_terrain_depth);

	vec3 wn = wave_normal(v_world_pos.xz, time * wave_speed);

	// Screen-space depth
	float depth_raw = textureLod(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_depth = INV_PROJECTION_MATRIX * ndc;
	view_depth.xyz /= view_depth.w;
	float scene_depth = -view_depth.z;
	float water_depth = -VERTEX.z;
	float depth_diff = scene_depth - water_depth;

	// 4-zone depth color
	float depth_blend = max(clamp(depth_diff / shore_depth_range, 0.0, 1.0), v_terrain_depth);
	vec4 water_col = depth_zone_color(depth_blend);
	float fresnel = pow(1.0 - clamp(dot(normalize(VIEW), normalize(wn)), 0.0, 1.0), 3.0);

	// Shore foam — animated, patchy, with noise breakup
	float foam_factor = 1.0 - clamp(depth_diff / foam_width, 0.0, 1.0);
	foam_factor = max(foam_factor, (1.0 - smoothstep(0.03, 0.2, v_terrain_depth)) * 0.9);

	// Multi-frequency foam noise for organic look
	float fn1 = sin(v_world_pos.x * foam_noise_scale + time * 2.0) * 0.5 + 0.5;
	float fn2 = sin(v_world_pos.z * foam_noise_scale * 0.75 + time * 1.5) * 0.5 + 0.5;
	float fn3 = sin((v_world_pos.x + v_world_pos.z) * foam_noise_scale * 0.5 - time * 1.8) * 0.5 + 0.5;
	float foam_noise = fn1 * fn2 * 0.7 + fn3 * 0.3;
	foam_factor *= step(0.25, foam_noise + foam_factor * 0.4);

	// Rolling shore break: moves in wave direction
	float shore_break = sin(v_world_pos.z * 1.5 - time * wave_speed * 3.0) * 0.5 + 0.5;
	shore_break *= (1.0 - smoothstep(0.05, 0.25, v_terrain_depth));
	foam_factor = max(foam_factor, shore_break * 0.6);

	// Crest foam from wave steepness
	float crest = pow(1.0 - clamp(wn.y, 0.0, 1.0), 3.0) * 2.0;
	foam_factor = max(foam_factor, crest * depth_factor * 0.5);

	vec3 final_color = mix(water_col.rgb, foam_color.rgb, foam_factor * 0.7);
	float final_alpha = mix(water_col.a, foam_color.a, foam_factor * 0.5);

	// Caustics on shallow seafloor
	if (caustics_enabled) {
		float caustic_mask = (1.0 - smoothstep(0.0, 0.4, v_terrain_depth));
		float caustic = caustic_pattern(v_world_pos.xz * 0.15, time * caustics_speed);
		final_color += vec3(caustic * caustics_strength * caustic_mask);
	}

	// Refraction
	vec2 refraction_uv = SCREEN_UV + wn.xz * 0.02 * refraction_amount * (1.0 - depth_blend * 0.65);
	vec3 refracted = textureLod(SCREEN_TEXTURE, refraction_uv, 0.0).rgb;
	final_color = mix(refracted, final_color, clamp(final_alpha + depth_blend * 0.25, 0.0, 1.0));
	final_color += vec3(0.18, 0.22, 0.26) * fresnel * fresnel_strength;
	final_color = mix(final_color, water_col.rgb, clamp(depth_blend * 0.35 + fresnel * 0.15, 0.0, 1.0));

	ALBEDO = final_color;
	ALPHA = clamp(final_alpha + depth_blend * 0.26 + fresnel * 0.12, 0.0, 1.0);
	NORMAL = mix(vec3(0.0, 1.0, 0.0), wn, depth_factor);
	ROUGHNESS = mix(0.02, roughness, depth_blend);
	METALLIC = metallic;
	SPECULAR = 0.5;
}
"""


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
