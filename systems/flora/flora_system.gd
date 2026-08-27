class_name FloraSystem
extends BaseSystem

## Spawns flora instances per chunk based on biome + FloraEntry rules.
## Flora types are auto-discovered as FloraEntry children — drop scenes in!

const SHADER_GROUND_COVER_ENTRIES := {
	&"grass": true,
	&"flower": true,
	&"alpine_flower": true,
}

var _config: FloraConfig

## Auto-discovered flora types (populated from children)
var _flora_entries: Array[FloraEntry] = []

## Total spawn weight for weighted random selection
var _total_weight: float = 0.0

## Chunk coord → Array of spawned Node3D instances
var _chunk_flora: Dictionary = {}

var _flora_motion: Dictionary = {}

## Per-instance lifecycle state: instance_id → {entry, age, stage, growth_rate, seed_timer, children_spawned, max_age}
var _flora_lifecycle: Dictionary = {}

## Lifecycle tick timer
var _lifecycle_timer: float = 0.0

var _wind_direction: Vector3 = Vector3(1.0, 0.0, 0.0)
var _wind_strength: float = 0.0

## Cached references (lazy-found)
var _biome_system: BiomeSystem
var _sea_level: float = 0.0
var _height_scale: float = 20.0
var _sea_level_found: bool = false


func _initialize() -> void:
	system_name = &"FloraSystem"
	priority = 30

	_config = _find_child_of_type(FloraConfig)
	if not _config:
		push_warning("[FloraSystem] No FloraConfig child found — using defaults")
		_config = FloraConfig.new()

	# Auto-discover all FloraEntry children (wired in flora_system.tscn)
	_discover_flora_entries()

	if _flora_entries.is_empty():
		push_warning("[FloraSystem] No FloraEntry children found — add entry scenes as children of FloraSystem")

	# Pre-calculate total spawn weight
	_total_weight = 0.0
	for entry in _flora_entries:
		_total_weight += entry.spawn_weight

	print("[FloraSystem] Registered %d flora types: %s" % [_flora_entries.size(), _get_entry_names()])


func _register_signals() -> void:
	SystemBus.biome_chunk_ready.connect(_on_biome_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)
	SystemBus.wind_changed.connect(_on_wind_changed)
	SystemBus.fauna_ate_flora.connect(_on_fauna_ate_flora)


func system_process(delta: float) -> void:
	if not _biome_system:
		_biome_system = _find_system_by_type(BiomeSystem)
	_update_flora_wind_sway(delta)
	_update_lifecycle(delta)


func _on_biome_chunk_ready(coord: Vector2i, biome_map: PackedByteArray) -> void:
	if _chunk_flora.has(coord):
		return
	_spawn_flora_for_chunk(coord, biome_map)


func _on_chunk_unload_requested(coord: Vector2i) -> void:
	_clear_chunk_flora(coord)


func _on_wind_changed(direction: Vector3, strength: float) -> void:
	_wind_direction = direction
	_wind_strength = strength


# ── Flora discovery ───────────────────────────────────────────────────────────

func _discover_flora_entries() -> void:
	_flora_entries.clear()
	_collect_flora_children(self)


func _collect_flora_children(node: Node) -> void:
	for child in node.get_children():
		if child is FloraEntry:
			_flora_entries.append(child)
		_collect_flora_children(child)


func _get_entry_names() -> String:
	var names: PackedStringArray = []
	for e in _flora_entries:
		names.append(str(e.entry_name))
	return ", ".join(names)


## Pick a random FloraEntry using weighted random + biome filter
func _pick_flora_entry(rng: RandomNumberGenerator, biome_name: StringName) -> FloraEntry:
	# Build filtered list with weights
	var valid_entries: Array[FloraEntry] = []
	var valid_weights: Array[float] = []
	var weight_sum := 0.0

	for entry in _flora_entries:
		if entry.get_child_count() == 0:
			continue
		if SHADER_GROUND_COVER_ENTRIES.has(entry.entry_name):
			continue
		if not entry.is_allowed_in_biome(biome_name):
			continue
		valid_entries.append(entry)
		valid_weights.append(entry.spawn_weight * entry.density_multiplier)
		weight_sum += entry.spawn_weight * entry.density_multiplier

	if valid_entries.is_empty() or weight_sum <= 0.0:
		return null

	# Weighted random pick
	var roll := rng.randf() * weight_sum
	var cumulative := 0.0
	for i in valid_entries.size():
		cumulative += valid_weights[i]
		if roll <= cumulative:
			return valid_entries[i]
	return valid_entries[valid_entries.size() - 1]


# ── Spawning ──────────────────────────────────────────────────────────────────

func _spawn_flora_for_chunk(coord: Vector2i, biome_map: PackedByteArray) -> void:
	var res := int(sqrt(biome_map.size()))
	if res == 0 or _flora_entries.is_empty():
		return

	# Lazy-find terrain params
	if not _sea_level_found:
		_find_terrain_params()
		_sea_level_found = true

	var cs := GameConfig.chunk_size
	var chunk_origin := Vector3(coord.x * cs, 0.0, coord.y * cs)

	var rng := RandomNumberGenerator.new()
	rng.seed = GameConfig.chunk_hash(coord.x, coord.y)

	var instances: Array[Node3D] = []
	var density := _config.base_density
	var max_count := _config.max_per_chunk

	var cell_size := cs / sqrt(float(density))
	var grid_count := int(cs / cell_size)

	for gz in grid_count:
		for gx in grid_count:
			if instances.size() >= max_count:
				break

			var local_x := (gx + rng.randf()) * cell_size
			var local_z := (gz + rng.randf()) * cell_size
			local_x = clampf(local_x, 0.0, cs - 0.01)
			local_z = clampf(local_z, 0.0, cs - 0.01)

			# Get biome at this position
			var bx := int((local_x / cs) * (res - 1))
			var bz := int((local_z / cs) * (res - 1))
			bx = clampi(bx, 0, res - 1)
			bz = clampi(bz, 0, res - 1)
			var biome_idx := biome_map[bz * res + bx]

			# Get biome data for density + name
			var density_mult := 1.0
			var biome_name := &"plains"
			if _biome_system:
				var bdata := _biome_system.get_biome_data(biome_idx)
				if bdata:
					density_mult = bdata.flora_density_multiplier
					biome_name = bdata.biome_name

			# Skip based on biome density
			if rng.randf() > density_mult:
				continue

			# Sample terrain support under the full flora footprint
			var support := _sample_ground_support(coord, local_x, local_z, 0.0, INF)
			var height := float(support.get("center_height", 0.0))
			var is_underwater := height < _sea_level
			var water_depth := _sea_level - height  # Positive when underwater

			# Pick a flora entry (weighted + biome-filtered)
			var entry: FloraEntry = _pick_flora_entry(rng, biome_name)
			if not entry:
				continue

			# Route aquatic vs land flora
			if entry.aquatic:
				# Aquatic flora: must be underwater at the right depth
				if not is_underwater:
					continue
				if water_depth < entry.min_water_depth or water_depth > entry.max_water_depth:
					continue
			else:
				# Land flora: skip underwater positions
				if height < _sea_level + 0.3:
					continue
				support = _sample_ground_support(coord, local_x, local_z, entry.ground_probe_radius, entry.max_ground_delta)
				if not bool(support.get("is_stable", true)):
					continue
				height = float(support.get("center_height", height))
				# Normalized height for land flora filtering
				var height_norm := clampf((height - _sea_level) / _height_scale, 0.0, 1.0)
				if height_norm < entry.min_height or height_norm > entry.max_height:
					continue
				# Check slope limit
				var slope_deg := float(support.get("slope_degrees", _sample_terrain_slope(coord, local_x, local_z)))
				if slope_deg > entry.max_slope_degrees:
					continue
				if entry.min_water_distance > 0.0 and _is_near_water(coord, local_x, local_z, entry.min_water_distance):
					continue

			if not _has_flora_spacing(instances, chunk_origin.x + local_x, chunk_origin.z + local_z, _config.min_spacing):
				continue

			# Instantiate by cloning entry's mesh children
			var instance: Node3D = entry.create_instance()

			# Position
			instance.position = Vector3(
				chunk_origin.x + local_x,
				height - entry.ground_sink,
				chunk_origin.z + local_z
			)
			instance.set_meta("flora_entry_name", entry.entry_name)
			var s := rng.randf_range(entry.scale_min, entry.scale_max)
			instance.scale = Vector3(s, s, s)

			# Rotation
			if entry.random_rotation:
				instance.rotation.y = rng.randf() * TAU

			# Tilt
			if entry.random_tilt > 0.0:
				var tilt_rad := deg_to_rad(rng.randf_range(-entry.random_tilt, entry.random_tilt))
				instance.rotation.x = tilt_rad
				instance.rotation.z = rng.randf_range(-tilt_rad, tilt_rad)
			if not entry.aquatic:
				_align_instance_to_surface(instance, support, entry)

			_apply_flora_visual_variation(instance, entry, rng)
			_register_flora_motion(instance, entry, rng)
			_register_flora_lifecycle(instance, entry, rng)

			_apply_view_distance(instance)
			add_child(instance)
			instances.append(instance)

	_chunk_flora[coord] = instances
	SharedWorld.total_flora_count += instances.size()
	SystemBus.flora_chunk_spawned.emit(coord, instances.size())


## Fade a prop out past the configured view distance.
##
## Flora is one scene instance per plant, so a large load radius puts many
## thousands of separately drawn objects in the scene at once. Culling the
## distant ones is the difference between a playable frame and a slideshow,
## and at these ranges they are a few pixels of silhouette inside the haze.
func _apply_view_distance(node: Node3D) -> void:
	if _config == null or _config.view_distance <= 0.0:
		return
	for child in node.find_children("*", "GeometryInstance3D", true, false):
		var geo := child as GeometryInstance3D
		geo.visibility_range_end = _config.view_distance
		geo.visibility_range_end_margin = _config.view_fade
		geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if node is GeometryInstance3D:
		var self_geo := node as GeometryInstance3D
		self_geo.visibility_range_end = _config.view_distance
		self_geo.visibility_range_end_margin = _config.view_fade
		self_geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


func _sample_ground_support(coord: Vector2i, local_x: float, local_z: float, probe_radius: float,
		max_ground_delta: float) -> Dictionary:
	var center_height := _sample_terrain_height(coord, local_x, local_z)
	var center_slope := _sample_terrain_slope(coord, local_x, local_z)
	if probe_radius <= 0.001:
		return {
			"center_height": center_height,
			"min_height": center_height,
			"max_height": center_height,
			"slope_degrees": center_slope,
			"normal": Vector3.UP,
			"is_stable": true,
		}

	var offsets := [
		Vector2.ZERO,
		Vector2(probe_radius, 0.0),
		Vector2(-probe_radius, 0.0),
		Vector2(0.0, probe_radius),
		Vector2(0.0, -probe_radius),
	]
	var heights: Array[float] = []
	var sample_points: Array[Vector3] = []
	var min_height := INF
	var max_height := -INF
	for offset in offsets:
		var sample := _wrap_local_sample(coord, local_x + offset.x, local_z + offset.y)
		var sample_coord: Vector2i = sample["coord"]
		var sample_x: float = sample["local_x"]
		var sample_z: float = sample["local_z"]
		var sample_height := _sample_terrain_height(sample_coord, sample_x, sample_z)
		heights.append(sample_height)
		min_height = minf(min_height, sample_height)
		max_height = maxf(max_height, sample_height)
		var chunk_origin := SharedWorld.chunk_to_world(sample_coord)
		sample_points.append(Vector3(chunk_origin.x - GameConfig.chunk_size * 0.5 + sample_x, sample_height, chunk_origin.z - GameConfig.chunk_size * 0.5 + sample_z))

	var east := sample_points[1]
	var west := sample_points[2]
	var south := sample_points[3]
	var north := sample_points[4]
	var dx := east.y - west.y
	var dz := south.y - north.y
	var normal := Vector3(-dx, probe_radius * 2.0, -dz)
	if normal.length_squared() < 0.0001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()
	var ground_delta := max_height - min_height
	var is_stable := ground_delta <= max_ground_delta

	return {
		"center_height": heights[0],
		"min_height": min_height,
		"max_height": max_height,
		"ground_delta": ground_delta,
		"slope_degrees": rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0))),
		"normal": normal,
		"is_stable": is_stable,
	}


func _wrap_local_sample(coord: Vector2i, local_x: float, local_z: float) -> Dictionary:
	var sample_coord := coord
	var wrapped_x := local_x
	var wrapped_z := local_z
	var cs := GameConfig.chunk_size
	while wrapped_x < 0.0:
		wrapped_x += cs
		sample_coord.x -= 1
	while wrapped_x >= cs:
		wrapped_x -= cs
		sample_coord.x += 1
	while wrapped_z < 0.0:
		wrapped_z += cs
		sample_coord.y -= 1
	while wrapped_z >= cs:
		wrapped_z -= cs
		sample_coord.y += 1
	return {
		"coord": sample_coord,
		"local_x": wrapped_x,
		"local_z": wrapped_z,
	}


func _align_instance_to_surface(instance: Node3D, support: Dictionary, entry: FloraEntry) -> void:
	var align_strength := clampf(entry.surface_alignment, 0.0, 1.0)
	if align_strength <= 0.001:
		return
	var surface_normal: Vector3 = support.get("normal", Vector3.UP)
	if surface_normal.length_squared() < 0.0001:
		return
	var target_x := atan2(surface_normal.z, maxf(surface_normal.y, 0.001))
	var target_z := -atan2(surface_normal.x, maxf(surface_normal.y, 0.001))
	instance.rotation.x += target_x * align_strength
	instance.rotation.z += target_z * align_strength


# ── Cleanup & Utilities ───────────────────────────────────────────────────────

func _clear_chunk_flora(coord: Vector2i) -> void:
	if not _chunk_flora.has(coord):
		return
	var instances: Array = _chunk_flora[coord]
	for inst in instances:
		if is_instance_valid(inst):
			var iid: int = inst.get_instance_id()
			_flora_motion.erase(iid)
			_flora_lifecycle.erase(iid)
			inst.queue_free()
	SharedWorld.total_flora_count -= instances.size()
	_chunk_flora.erase(coord)
	SystemBus.flora_chunk_cleared.emit(coord)



func _is_near_water(coord: Vector2i, local_x: float, local_z: float, min_distance: float) -> bool:
	var sample_count := 8
	for i in sample_count:
		var angle := (TAU * float(i)) / float(sample_count)
		var sample_x := local_x + cos(angle) * min_distance
		var sample_z := local_z + sin(angle) * min_distance
		var neighbor_coord := coord
		var cs := GameConfig.chunk_size
		while sample_x < 0.0:
			sample_x += cs
			neighbor_coord.x -= 1
		while sample_x >= cs:
			sample_x -= cs
			neighbor_coord.x += 1
		while sample_z < 0.0:
			sample_z += cs
			neighbor_coord.y -= 1
		while sample_z >= cs:
			sample_z -= cs
			neighbor_coord.y += 1
		if _sample_terrain_height(neighbor_coord, sample_x, sample_z) <= _sea_level + 0.1:
			return true
	return false


func _has_flora_spacing(instances: Array[Node3D], world_x: float, world_z: float, min_spacing: float) -> bool:
	if min_spacing <= 0.0:
		return true
	var min_spacing_sq := min_spacing * min_spacing
	for inst in instances:
		if not is_instance_valid(inst):
			continue
		var dx := inst.position.x - world_x
		var dz := inst.position.z - world_z
		if dx * dx + dz * dz < min_spacing_sq:
			return false
	return true


func _apply_flora_visual_variation(instance: Node3D, entry: FloraEntry, rng: RandomNumberGenerator) -> void:
	if entry.hue_variation <= 0.0 and entry.value_variation <= 0.0:
		return
	for mesh_inst in _collect_mesh_instances(instance):
		var base_material: Material = mesh_inst.material_override
		if not base_material and mesh_inst.mesh and mesh_inst.mesh.get_surface_count() > 0:
			base_material = mesh_inst.mesh.surface_get_material(0)
		if not base_material or not base_material is StandardMaterial3D:
			continue
		var material := (base_material as StandardMaterial3D).duplicate() as StandardMaterial3D
		var color := material.albedo_color
		var hue_shift := rng.randf_range(-entry.hue_variation, entry.hue_variation)
		var value_shift := rng.randf_range(-entry.value_variation, entry.value_variation)
		color.h = wrapf(color.h + hue_shift, 0.0, 1.0)
		color.v = clampf(color.v + value_shift, 0.0, 1.0)
		material.albedo_color = color
		mesh_inst.material_override = material


func _register_flora_motion(instance: Node3D, entry: FloraEntry, rng: RandomNumberGenerator) -> void:
	if entry.wind_sway_strength <= 0.0:
		return
	_flora_motion[instance.get_instance_id()] = {
		"node": instance,
		"base_rotation": instance.rotation,
		"strength": entry.wind_sway_strength,
		"phase": rng.randf() * TAU,
	}


func _update_flora_wind_sway(delta: float) -> void:
	if _flora_motion.is_empty():
		return
	var dir := _wind_direction
	if dir.length_squared() <= 0.0001:
		dir = Vector3(1.0, 0.0, 0.0)
	else:
		dir = dir.normalized()

	var cam_pos := SharedWorld.camera_world_pos
	var sway_cull_dist_sq := _config.sway_cull_distance * _config.sway_cull_distance

	for iid in _flora_motion.keys():
		var motion: Dictionary = _flora_motion[iid]
		var node: Node3D = motion.get("node") as Node3D
		if not is_instance_valid(node):
			_flora_motion.erase(iid)
			continue

		# Distance culling: skip sway for flora too far from camera
		var dx := node.position.x - cam_pos.x
		var dz := node.position.z - cam_pos.z
		if dx * dx + dz * dz > sway_cull_dist_sq:
			continue

		var base_rotation: Vector3 = motion.get("base_rotation", Vector3.ZERO)
		var strength: float = float(motion.get("strength", 0.0))
		var phase: float = float(motion.get("phase", 0.0)) + delta * (0.8 + _wind_strength * 0.35)
		motion["phase"] = phase
		var sway := sin(phase) * strength * minf(_wind_strength * 0.08, 0.2)
		node.rotation.x = base_rotation.x + dir.z * sway
		node.rotation.z = base_rotation.z - dir.x * sway
		_flora_motion[iid] = motion


func _collect_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for child in root.get_children():
		if child is MeshInstance3D:
			meshes.append(child)
		meshes.append_array(_collect_mesh_instances(child))
	return meshes


func _find_terrain_params() -> void:
	_sea_level = SharedWorld.sea_level
	_height_scale = SharedWorld.height_scale


# ── Lifecycle System ─────────────────────────────────────────────────────────

func _register_flora_lifecycle(instance: Node3D, entry: FloraEntry, rng: RandomNumberGenerator) -> void:
	if not entry.growth_enabled or not _config.lifecycle_enabled:
		return
	var variance := _config.max_age_variance
	var age_mult := 1.0 + rng.randf_range(-variance, variance)
	_flora_lifecycle[instance.get_instance_id()] = {
		"node": instance,
		"entry": entry,
		"age": 0.0,
		"stage": 0,
		"growth_rate": 1.0,
		"seed_timer": 0.0,
		"children_spawned": 0,
		"max_age": entry.max_age * age_mult,
		"base_scale": instance.scale,
	}


func _update_lifecycle(delta: float) -> void:
	if not _config.lifecycle_enabled or _flora_lifecycle.is_empty():
		return

	_lifecycle_timer += delta
	if _lifecycle_timer < _config.lifecycle_tick_interval:
		return
	var tick_dt := _lifecycle_timer
	_lifecycle_timer = 0.0

	var season := SharedWorld.current_season
	var rain := SharedWorld.rain_intensity
	var is_drought := SharedWorld.consecutive_dry_ticks > _config.drought_threshold_ticks
	var seedlings_this_tick := 0

	var to_remove: Array[int] = []

	for iid: int in _flora_lifecycle.keys():
		var lc: Dictionary = _flora_lifecycle[iid]
		var node: Node3D = lc.get("node") as Node3D
		if not is_instance_valid(node):
			to_remove.append(iid)
			continue

		var entry: FloraEntry = lc.get("entry") as FloraEntry
		if not entry:
			to_remove.append(iid)
			continue

		# Compute effective growth rate (season + rain modifiers)
		var growth_rate := 1.0
		if entry.seasonal_growth_modifiers.has(season):
			growth_rate *= float(entry.seasonal_growth_modifiers[season])
		if rain > _config.rain_growth_threshold:
			growth_rate += entry.rain_growth_bonus * rain

		# Advance age
		var age: float = lc["age"] + tick_dt * growth_rate
		lc["age"] = age

		# Check drought death
		if is_drought and randf() < entry.drought_death_chance:
			_kill_flora_instance(iid, node, entry)
			to_remove.append(iid)
			continue

		# Check natural death (old age)
		var max_age: float = lc["max_age"]
		if age >= max_age:
			_kill_flora_instance(iid, node, entry)
			to_remove.append(iid)
			continue

		# Update growth stage and visual scale
		var stage_count := entry.growth_stages
		var new_stage := clampi(int(age / entry.growth_time), 0, stage_count - 1)
		lc["stage"] = new_stage

		var base_scale: Vector3 = lc["base_scale"]
		var scale_frac: float
		if stage_count <= 1:
			scale_frac = 1.0
		else:
			# seedling=0.3, mature=1.0, old=0.85
			var stage_norm := float(new_stage) / float(stage_count - 1)
			if stage_norm < 0.5:
				scale_frac = lerpf(_config.seedling_scale, _config.mature_scale, stage_norm * 2.0)
			else:
				scale_frac = lerpf(_config.mature_scale, _config.old_scale, (stage_norm - 0.5) * 2.0)
		node.scale = base_scale * scale_frac

		# Seed spreading (E2) — only mature stage
		if entry.spreads_seeds and new_stage > 0 and new_stage < stage_count - 1:
			var seed_timer: float = lc["seed_timer"] + tick_dt
			lc["seed_timer"] = seed_timer
			var children_spawned: int = lc["children_spawned"]
			if seed_timer >= entry.seed_spread_interval and children_spawned < entry.max_children_per_parent:
				if seedlings_this_tick < _config.max_seedlings_per_tick and randf() < entry.seed_spread_chance:
					if _try_spread_seed(node, entry):
						lc["children_spawned"] = children_spawned + 1
						lc["seed_timer"] = 0.0
						seedlings_this_tick += 1

		_flora_lifecycle[iid] = lc

	for iid in to_remove:
		_flora_lifecycle.erase(iid)


func _kill_flora_instance(iid: int, node: Node3D, entry: FloraEntry) -> void:
	SystemBus.flora_died.emit(node.global_position, entry.name)
	_flora_motion.erase(iid)
	# Remove from chunk tracking
	for coord: Vector2i in _chunk_flora:
		var instances: Array = _chunk_flora[coord]
		var idx := instances.find(node)
		if idx >= 0:
			instances.remove_at(idx)
			break
	SharedWorld.total_flora_count -= 1
	node.queue_free()


func _try_spread_seed(parent: Node3D, entry: FloraEntry) -> bool:
	var spread_pos := parent.global_position
	var radius := entry.seed_spread_radius

	# Determine seed landing position based on dispersal method
	var offset := Vector3.ZERO
	match entry.seed_dispersal_method:
		&"wind":
			var wind_dir := SharedWorld.wind_direction
			var wind_str := SharedWorld.wind_strength
			offset = wind_dir * (radius * 0.5 + wind_str * 0.5) + Vector3(
				randf_range(-radius * 0.3, radius * 0.3),
				0.0,
				randf_range(-radius * 0.3, radius * 0.3)
			)
		&"animal":
			# Animal dispersal happens via fauna_visited_flora signal, not here
			return false
		_:  # "drop"
			var angle := randf() * TAU
			var dist := randf_range(1.0, radius)
			offset = Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)

	var target_pos := spread_pos + offset

	# Check chunk seedling cap
	var chunk_coord := SharedWorld.world_to_chunk(target_pos)
	if _chunk_flora.has(chunk_coord):
		var chunk_instances: Array = _chunk_flora[chunk_coord]
		# Count seedlings in this chunk
		var seedling_count := 0
		for inst in chunk_instances:
			if is_instance_valid(inst):
				var lc: Dictionary = _flora_lifecycle.get(inst.get_instance_id(), {})
				if lc.get("stage", -1) == 0:
					seedling_count += 1
		if seedling_count >= _config.max_seedlings_per_chunk:
			return false

	# Sample terrain height at target
	var h := _sample_terrain_height(chunk_coord, target_pos.x - chunk_coord.x * GameConfig.chunk_size, target_pos.z - chunk_coord.y * GameConfig.chunk_size)
	if h <= _sea_level and not entry.aquatic:
		return false

	# Create seedling instance
	var instance := entry.create_instance()
	if not instance:
		return false

	instance.position = Vector3(target_pos.x, h - entry.ground_sink, target_pos.z)
	instance.set_meta("flora_entry_name", entry.entry_name)
	var seed_s := (entry.scale_min + entry.scale_max) * 0.5 * _config.seedling_scale
	instance.scale = Vector3(seed_s, seed_s, seed_s)
	if entry.random_rotation:
		instance.rotation.y = randf() * TAU
	add_child(instance)

	# Register in chunk tracking
	if not _chunk_flora.has(chunk_coord):
		_chunk_flora[chunk_coord] = []
	_chunk_flora[chunk_coord].append(instance)
	SharedWorld.total_flora_count += 1

	# Register lifecycle for the seedling
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(target_pos)
	_register_flora_lifecycle(instance, entry, rng)
	_register_flora_motion(instance, entry, rng)

	return true


func _on_fauna_ate_flora(world_pos: Vector3, _flora_name: StringName, _fauna_name: StringName) -> void:
	# Find the closest flora instance to the reported position and damage/kill it
	var closest_dist_sq := _config.forage_search_radius_sq
	var closest_node: Node3D = null
	var closest_iid: int = -1

	for iid: int in _flora_lifecycle.keys():
		var lc: Dictionary = _flora_lifecycle[iid]
		var node: Node3D = lc.get("node") as Node3D
		if not is_instance_valid(node):
			continue
		var dist_sq := node.global_position.distance_squared_to(world_pos)
		if dist_sq < closest_dist_sq:
			closest_dist_sq = dist_sq
			closest_node = node
			closest_iid = iid

	if closest_node and closest_iid >= 0:
		var lc: Dictionary = _flora_lifecycle[closest_iid]
		var entry: FloraEntry = lc.get("entry") as FloraEntry
		if entry:
			_kill_flora_instance(closest_iid, closest_node, entry)
			_flora_lifecycle.erase(closest_iid)


func _shutdown() -> void:
	for coord in _chunk_flora.keys():
		_clear_chunk_flora(coord)
