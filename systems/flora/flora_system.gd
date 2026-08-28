class_name FloraSystem
extends BaseSystem

## Spawns flora instances per chunk based on biome + FloraEntry rules.
## Flora types are auto-discovered as FloraEntry children — drop scenes in!
##
## Plants are not scene instances. Each FloraEntry is flattened once into a list
## of mesh parts, and every part gets one world-wide MultiMesh. A plant is a
## CPU-side record that owns the same instance slot in each of its entry's part
## batches. The whole world of flora therefore costs about one draw call per
## part per flora type — a few dozen — instead of one per part per plant.

const SHADER_GROUND_COVER_ENTRIES := {
	&"grass": true,
	&"flower": true,
	&"alpine_flower": true,
}

## Transform written into an instance slot that must not draw.
const HIDDEN_TRANSFORM := Transform3D(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)

## Instance slots are allocated in blocks of at least this many.
const MIN_BATCH_CAPACITY := 128

var _config: FloraConfig

## Auto-discovered flora types (populated from children)
var _flora_entries: Array[FloraEntry] = []

## Total spawn weight for weighted random selection
var _total_weight: float = 0.0

## entry index → Array of part templates {mesh, material, xform, varies}
var _entry_parts: Array = []

## entry index → Array of MultiMeshInstance3D, parallel to _entry_parts
var _entry_batches: Array = []

## entry index → {capacity: int, count: int, pids: Array[int]}
## Live instances stay packed at the front of each batch so visible_instance_count
## draws exactly the plants that exist.
var _entry_slots: Array = []

## entry index → whether this entry writes per-instance colours
var _entry_colored: Array = []

## FloraEntry → its index in _flora_entries
var _entry_index: Dictionary = {}

## Plant id → {entry, coord, slot, pos, rot, base_rot, scale, vis, sway, phase}
var _plants: Dictionary = {}
var _next_pid: int = 1

## Chunk coord → Array[int] of plant ids
var _chunk_flora: Dictionary = {}

## Plant id → {entry, age, stage, seed_timer, children_spawned, max_age, base_scale}
var _flora_lifecycle: Dictionary = {}

## Lifecycle tick timer
var _lifecycle_timer: float = 0.0

## Live plant count, mirrored for the debug HUD
var _total_flora_count: int = 0

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

	_build_batches()

	print("[FloraSystem] Registered %d flora types: %s" % [_flora_entries.size(), _get_entry_names()])


func _register_signals() -> void:
	SystemBus.biome_chunk_ready.connect(_on_biome_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)
	SystemBus.wind_changed.connect(_on_wind_changed)
	SystemBus.fauna_ate_flora.connect(_on_fauna_ate_flora)


func system_process(delta: float) -> void:
	if not _biome_system:
		_biome_system = _find_system_by_type(BiomeSystem)
	_update_flora_motion(delta)
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
	_entry_index.clear()
	_collect_flora_children(self)
	for i in _flora_entries.size():
		_entry_index[_flora_entries[i]] = i


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


# ── Batches ───────────────────────────────────────────────────────────────────

## Flatten every entry into mesh parts and give each part a world-wide MultiMesh.
func _build_batches() -> void:
	var extent := float(GameConfig.world_size_chunks) * GameConfig.chunk_size
	if extent <= 0.0:
		extent = 8192.0
	var world_aabb := AABB(
		Vector3(-extent, -extent, -extent),
		Vector3(extent * 2.0, extent * 2.0, extent * 2.0))

	for i in _flora_entries.size():
		var entry := _flora_entries[i]
		var parts := _extract_parts(entry)
		var colored := entry.hue_variation > 0.0 or entry.value_variation > 0.0
		var batches: Array[MultiMeshInstance3D] = []
		for part: Dictionary in parts:
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.use_colors = colored
			multimesh.mesh = part["mesh"]
			multimesh.instance_count = 0
			# A fixed AABB keeps the rendering server from rebuilding bounds on
			# every transform write. Flora is a rounding error in vertex count,
			# so trading its frustum culling for the draw-call collapse is cheap.
			multimesh.custom_aabb = world_aabb
			var instance := MultiMeshInstance3D.new()
			instance.name = "%s_%s" % [entry.entry_name, part["name"]]
			instance.multimesh = multimesh
			instance.material_override = part["material"]
			add_child(instance)
			batches.append(instance)
		_entry_parts.append(parts)
		_entry_batches.append(batches)
		_entry_colored.append(colored)
		_entry_slots.append({"capacity": 0, "count": 0, "pids": ([] as Array[int])})
		# The entry's own meshes are templates now — stop drawing them at origin.
		_hide_template_meshes(entry)


## Walk an entry's mesh children into flat part templates with baked transforms.
func _extract_parts(entry: FloraEntry) -> Array[Dictionary]:
	var parts: Array[Dictionary] = []
	_collect_parts(entry, Transform3D.IDENTITY, parts)
	return parts


func _collect_parts(node: Node, accumulated: Transform3D, out: Array[Dictionary]) -> void:
	for child in node.get_children():
		if child is FloraEntry:
			continue
		var local := accumulated
		if child is Node3D:
			local = accumulated * (child as Node3D).transform
		if child is MeshInstance3D:
			var mesh_inst := child as MeshInstance3D
			if mesh_inst.mesh != null:
				var material: Material = mesh_inst.material_override
				if material == null and mesh_inst.mesh.get_surface_count() > 0:
					material = mesh_inst.mesh.surface_get_material(0)
				out.append({
					"name": str(mesh_inst.name),
					"mesh": mesh_inst.mesh,
					"material": _batch_material(material),
					"base_albedo": (material as StandardMaterial3D).albedo_color if material is StandardMaterial3D else Color.WHITE,
					"varies": material is StandardMaterial3D,
					"xform": local,
				})
		_collect_parts(child, local, out)


## One shared material per part. Per-plant colour variation moves from a
## duplicated material into the MultiMesh instance colour, so a whole flora type
## draws with a single material instead of one per plant.
func _batch_material(source: Material) -> Material:
	if not source is StandardMaterial3D:
		return source
	var material := (source as StandardMaterial3D).duplicate() as StandardMaterial3D
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	return material


func _hide_template_meshes(entry: FloraEntry) -> void:
	for child in entry.find_children("*", "VisualInstance3D", true, false):
		(child as VisualInstance3D).visible = false


## Resizing a MultiMesh reallocates its instance buffer, so every live plant of
## this entry is written back afterwards. Capacity doubles, so the rewrite cost
## is amortised across spawns.
func _grow_entry_capacity(entry_idx: int) -> void:
	var slots: Dictionary = _entry_slots[entry_idx]
	var new_capacity := maxi(MIN_BATCH_CAPACITY, int(slots["capacity"]) * 2)
	for instance: MultiMeshInstance3D in _entry_batches[entry_idx]:
		(instance.multimesh as MultiMesh).instance_count = new_capacity
	slots["capacity"] = new_capacity
	for pid: int in slots["pids"]:
		_write_plant(pid)
		_apply_plant_colors(pid)


func _set_visible_count(entry_idx: int, count: int) -> void:
	for instance: MultiMeshInstance3D in _entry_batches[entry_idx]:
		(instance.multimesh as MultiMesh).visible_instance_count = count


## Claim the next slot at the end of the packed region.
func _alloc_slot(entry_idx: int, pid: int) -> int:
	var slots: Dictionary = _entry_slots[entry_idx]
	var slot: int = slots["count"]
	if slot >= int(slots["capacity"]):
		_grow_entry_capacity(entry_idx)
	(slots["pids"] as Array).append(pid)
	slots["count"] = slot + 1
	_set_visible_count(entry_idx, slot + 1)
	return slot


## Release a slot by moving the last live plant into it, keeping the region packed.
func _free_slot(entry_idx: int, slot: int) -> void:
	var slots: Dictionary = _entry_slots[entry_idx]
	var pids: Array = slots["pids"]
	var last: int = int(slots["count"]) - 1
	if last < 0:
		return
	if slot != last:
		var moved_pid: int = pids[last]
		pids[slot] = moved_pid
		(_plants[moved_pid] as Dictionary)["slot"] = slot
		_write_plant(moved_pid)
		_apply_plant_colors(moved_pid)
	pids.resize(last)
	slots["count"] = last
	_set_visible_count(entry_idx, last)


func _plant_transform(plant: Dictionary) -> Transform3D:
	var scale_factor := float(plant["scale"]) * float(plant["vis"])
	if scale_factor <= 0.0:
		return HIDDEN_TRANSFORM
	var basis := Basis.from_euler(plant["rot"] as Vector3).scaled(
		Vector3(scale_factor, scale_factor, scale_factor))
	return Transform3D(basis, plant["pos"])


func _write_plant(pid: int) -> void:
	var plant: Dictionary = _plants[pid]
	var entry_idx: int = plant["entry"]
	var slot: int = plant["slot"]
	var root_xform := _plant_transform(plant)
	var parts: Array = _entry_parts[entry_idx]
	var batches: Array = _entry_batches[entry_idx]
	for i in batches.size():
		var multimesh: MultiMesh = (batches[i] as MultiMeshInstance3D).multimesh
		multimesh.set_instance_transform(slot, root_xform * (parts[i]["xform"] as Transform3D))


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

	var pids: Array[int] = []
	var placed := PackedVector3Array()
	var density := _config.base_density
	var max_count := _config.max_per_chunk

	var cell_size := cs / sqrt(float(density))
	var grid_count := int(cs / cell_size)

	for gz in grid_count:
		for gx in grid_count:
			if pids.size() >= max_count:
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

			if not _has_flora_spacing(placed, chunk_origin.x + local_x, chunk_origin.z + local_z, _config.min_spacing):
				continue

			var position := Vector3(
				chunk_origin.x + local_x,
				height - entry.ground_sink,
				chunk_origin.z + local_z
			)
			var plant_scale := rng.randf_range(entry.scale_min, entry.scale_max)

			# Rotation
			var rotation_euler := Vector3.ZERO
			if entry.random_rotation:
				rotation_euler.y = rng.randf() * TAU

			# Tilt
			if entry.random_tilt > 0.0:
				var tilt_rad := deg_to_rad(rng.randf_range(-entry.random_tilt, entry.random_tilt))
				rotation_euler.x = tilt_rad
				rotation_euler.z = rng.randf_range(-tilt_rad, tilt_rad)
			if not entry.aquatic:
				rotation_euler = _align_rotation_to_surface(rotation_euler, support, entry)

			var pid := _add_plant(entry, coord, position, rotation_euler, plant_scale, rng)
			pids.append(pid)
			placed.append(position)

	_chunk_flora[coord] = pids
	_total_flora_count += pids.size()
	SharedWorld.total_flora_count += pids.size()
	SystemBus.flora_chunk_spawned.emit(coord, pids.size())


## Register a plant record, claim its instance slots, and push it to the GPU.
func _add_plant(entry: FloraEntry, coord: Vector2i, position: Vector3, rotation_euler: Vector3,
		plant_scale: float, rng: RandomNumberGenerator) -> int:
	var entry_idx: int = _entry_index[entry]
	var pid := _next_pid
	_next_pid += 1
	var slot := _alloc_slot(entry_idx, pid)

	# Colours are rolled here so the RNG draw order matches the spawn sequence.
	var colors := _roll_plant_colors(entry, entry_idx, rng)
	var phase := rng.randf() * TAU if entry.wind_sway_strength > 0.0 else 0.0

	_plants[pid] = {
		"entry": entry_idx,
		"coord": coord,
		"slot": slot,
		"pos": position,
		"rot": rotation_euler,
		"base_rot": rotation_euler,
		"scale": plant_scale,
		"vis": 1.0,
		"sway": entry.wind_sway_strength,
		"phase": phase,
		"colors": colors,
	}

	_write_plant(pid)
	_apply_plant_colors(pid)
	_register_flora_lifecycle(pid, entry, rng)
	return pid


## Roll this plant's hue/value variation once, per part, at spawn time.
func _roll_plant_colors(entry: FloraEntry, entry_idx: int, rng: RandomNumberGenerator) -> Array:
	if not bool(_entry_colored[entry_idx]):
		return []
	var parts: Array = _entry_parts[entry_idx]
	var colors: Array = []
	colors.resize(parts.size())
	for i in parts.size():
		var part: Dictionary = parts[i]
		if not bool(part["varies"]):
			colors[i] = Color.WHITE
			continue
		var color: Color = part["base_albedo"]
		var hue_shift := rng.randf_range(-entry.hue_variation, entry.hue_variation)
		var value_shift := rng.randf_range(-entry.value_variation, entry.value_variation)
		color.h = wrapf(color.h + hue_shift, 0.0, 1.0)
		color.v = clampf(color.v + value_shift, 0.0, 1.0)
		colors[i] = color
	return colors


## Push a plant's stored colours into its instance slots.
func _apply_plant_colors(pid: int) -> void:
	var plant: Dictionary = _plants[pid]
	var colors: Array = plant["colors"]
	if colors.is_empty():
		return
	var slot: int = plant["slot"]
	var batches: Array = _entry_batches[plant["entry"]]
	for i in colors.size():
		((batches[i] as MultiMeshInstance3D).multimesh as MultiMesh).set_instance_color(slot, colors[i])


# ── Terrain sampling ──────────────────────────────────────────────────────────

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


func _align_rotation_to_surface(rotation_euler: Vector3, support: Dictionary, entry: FloraEntry) -> Vector3:
	var align_strength := clampf(entry.surface_alignment, 0.0, 1.0)
	if align_strength <= 0.001:
		return rotation_euler
	var surface_normal: Vector3 = support.get("normal", Vector3.UP)
	if surface_normal.length_squared() < 0.0001:
		return rotation_euler
	var target_x := atan2(surface_normal.z, maxf(surface_normal.y, 0.001))
	var target_z := -atan2(surface_normal.x, maxf(surface_normal.y, 0.001))
	return Vector3(
		rotation_euler.x + target_x * align_strength,
		rotation_euler.y,
		rotation_euler.z + target_z * align_strength)


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


func _has_flora_spacing(placed: PackedVector3Array, world_x: float, world_z: float, min_spacing: float) -> bool:
	if min_spacing <= 0.0:
		return true
	var min_spacing_sq := min_spacing * min_spacing
	for position in placed:
		var dx := position.x - world_x
		var dz := position.z - world_z
		if dx * dx + dz * dz < min_spacing_sq:
			return false
	return true


func _find_terrain_params() -> void:
	_sea_level = SharedWorld.sea_level
	_height_scale = SharedWorld.height_scale


# ── Wind sway & view distance ─────────────────────────────────────────────────

## One pass per frame over live plants. Near plants sway; distant plants shrink
## out over the fade band and stop being written once they are fully gone.
func _update_flora_motion(delta: float) -> void:
	if _plants.is_empty():
		return
	var dir := _wind_direction
	if dir.length_squared() <= 0.0001:
		dir = Vector3(1.0, 0.0, 0.0)
	else:
		dir = dir.normalized()

	var cam_pos := SharedWorld.camera_world_pos
	var sway_cull_dist_sq := _config.sway_cull_distance * _config.sway_cull_distance
	var view_end := _config.view_distance
	var fade := maxf(_config.view_fade, 0.001)
	var fade_start := maxf(view_end - fade, 0.0)
	var fade_start_sq := fade_start * fade_start
	var view_end_sq := view_end * view_end
	var sway_amount := minf(_wind_strength * 0.08, 0.2)
	var phase_step := delta * (0.8 + _wind_strength * 0.35)

	for pid: int in _plants:
		var plant: Dictionary = _plants[pid]
		var position: Vector3 = plant["pos"]
		var dx := position.x - cam_pos.x
		var dz := position.z - cam_pos.z
		var dist_sq := dx * dx + dz * dz
		var dirty := false

		if view_end > 0.0:
			var visibility: float = plant["vis"]
			if dist_sq >= view_end_sq:
				if visibility != 0.0:
					plant["vis"] = 0.0
					_write_plant(pid)
				continue  # fully faded out — nothing else to update
			elif dist_sq <= fade_start_sq:
				if visibility != 1.0:
					plant["vis"] = 1.0
					dirty = true
			else:
				var target := clampf(1.0 - (sqrt(dist_sq) - fade_start) / fade, 0.0, 1.0)
				if absf(target - visibility) > 0.02:
					plant["vis"] = target
					dirty = true

		var strength: float = plant["sway"]
		if strength > 0.0 and dist_sq <= sway_cull_dist_sq:
			var phase: float = float(plant["phase"]) + phase_step
			plant["phase"] = phase
			var sway := sin(phase) * strength * sway_amount
			var base_rotation: Vector3 = plant["base_rot"]
			plant["rot"] = Vector3(
				base_rotation.x + dir.z * sway,
				base_rotation.y,
				base_rotation.z - dir.x * sway)
			dirty = true

		if dirty:
			_write_plant(pid)


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _register_flora_lifecycle(pid: int, entry: FloraEntry, rng: RandomNumberGenerator) -> void:
	if not entry.growth_enabled or not _config.lifecycle_enabled:
		return
	var variance := _config.max_age_variance
	var age_mult := 1.0 + rng.randf_range(-variance, variance)
	_flora_lifecycle[pid] = {
		"entry": entry,
		"age": 0.0,
		"stage": 0,
		"growth_rate": 1.0,
		"seed_timer": 0.0,
		"children_spawned": 0,
		"max_age": entry.max_age * age_mult,
		"base_scale": float(_plants[pid]["scale"]),
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

	for pid: int in _flora_lifecycle.keys():
		var lc: Dictionary = _flora_lifecycle[pid]
		if not _plants.has(pid):
			to_remove.append(pid)
			continue

		var entry: FloraEntry = lc.get("entry") as FloraEntry
		if not entry:
			to_remove.append(pid)
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
			_kill_flora_instance(pid, entry)
			to_remove.append(pid)
			continue

		# Check natural death (old age)
		var max_age: float = lc["max_age"]
		if age >= max_age:
			_kill_flora_instance(pid, entry)
			to_remove.append(pid)
			continue

		# Update growth stage and visual scale
		var stage_count := entry.growth_stages
		var new_stage := clampi(int(age / entry.growth_time), 0, stage_count - 1)
		lc["stage"] = new_stage

		var base_scale: float = lc["base_scale"]
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
		var plant: Dictionary = _plants[pid]
		if not is_equal_approx(float(plant["scale"]), base_scale * scale_frac):
			plant["scale"] = base_scale * scale_frac
			_write_plant(pid)

		# Seed spreading (E2) — only mature stage
		if entry.spreads_seeds and new_stage > 0 and new_stage < stage_count - 1:
			var seed_timer: float = lc["seed_timer"] + tick_dt
			lc["seed_timer"] = seed_timer
			var children_spawned: int = lc["children_spawned"]
			if seed_timer >= entry.seed_spread_interval and children_spawned < entry.max_children_per_parent:
				if seedlings_this_tick < _config.max_seedlings_per_tick and randf() < entry.seed_spread_chance:
					if _try_spread_seed(pid, entry):
						lc["children_spawned"] = children_spawned + 1
						lc["seed_timer"] = 0.0
						seedlings_this_tick += 1

	for pid in to_remove:
		_flora_lifecycle.erase(pid)


func _kill_flora_instance(pid: int, entry: FloraEntry) -> void:
	var plant: Dictionary = _plants.get(pid, {})
	if plant.is_empty():
		return
	SystemBus.flora_died.emit(plant["pos"], entry.entry_name)
	_remove_plant(pid)


## Release a plant's instance slot and drop it from chunk tracking.
func _remove_plant(pid: int) -> void:
	var plant: Dictionary = _plants.get(pid, {})
	if plant.is_empty():
		return
	_free_slot(plant["entry"], plant["slot"])
	var coord: Vector2i = plant["coord"]
	if _chunk_flora.has(coord):
		var pids: Array = _chunk_flora[coord]
		var idx := pids.find(pid)
		if idx >= 0:
			pids.remove_at(idx)
	_plants.erase(pid)
	_flora_lifecycle.erase(pid)
	_total_flora_count -= 1
	SharedWorld.total_flora_count -= 1


func _try_spread_seed(parent_pid: int, entry: FloraEntry) -> bool:
	var spread_pos: Vector3 = _plants[parent_pid]["pos"]
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
		var seedling_count := 0
		for pid: int in _chunk_flora[chunk_coord]:
			var lc: Dictionary = _flora_lifecycle.get(pid, {})
			if lc.get("stage", -1) == 0:
				seedling_count += 1
		if seedling_count >= _config.max_seedlings_per_chunk:
			return false

	# Sample terrain height at target
	var h := _sample_terrain_height(chunk_coord, target_pos.x - chunk_coord.x * GameConfig.chunk_size, target_pos.z - chunk_coord.y * GameConfig.chunk_size)
	if h <= _sea_level and not entry.aquatic:
		return false

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(target_pos)
	var seed_scale := (entry.scale_min + entry.scale_max) * 0.5 * _config.seedling_scale
	var rotation_euler := Vector3.ZERO
	if entry.random_rotation:
		rotation_euler.y = rng.randf() * TAU

	var pid := _add_plant(entry, chunk_coord,
		Vector3(target_pos.x, h - entry.ground_sink, target_pos.z),
		rotation_euler, seed_scale, rng)

	if not _chunk_flora.has(chunk_coord):
		_chunk_flora[chunk_coord] = ([] as Array[int])
	_chunk_flora[chunk_coord].append(pid)
	_total_flora_count += 1
	SharedWorld.total_flora_count += 1
	return true


func _on_fauna_ate_flora(world_pos: Vector3, _flora_name: StringName, _fauna_name: StringName) -> void:
	# Find the closest flora instance to the reported position and damage/kill it
	var closest_dist_sq := _config.forage_search_radius_sq
	var closest_pid := -1

	for pid: int in _flora_lifecycle:
		if not _plants.has(pid):
			continue
		var dist_sq: float = (_plants[pid]["pos"] as Vector3).distance_squared_to(world_pos)
		if dist_sq < closest_dist_sq:
			closest_dist_sq = dist_sq
			closest_pid = pid

	if closest_pid >= 0:
		var entry: FloraEntry = _flora_lifecycle[closest_pid].get("entry") as FloraEntry
		if entry:
			_kill_flora_instance(closest_pid, entry)


# ── Queries ───────────────────────────────────────────────────────────────────

## Best plant within `radius` of `origin` to perch on or shelter under.
## Returns {"pos": Vector3, "score": float}, or an empty dictionary if none fit.
func find_support_site(origin: Vector3, allowed_names: Array, radius: float,
		height_offset: float) -> Dictionary:
	var radius_sq := radius * radius
	var best_score := -INF
	var best_pos := Vector3.ZERO
	for pid: int in _plants:
		var plant: Dictionary = _plants[pid]
		if not allowed_names.is_empty():
			var entry_name: StringName = _flora_entries[plant["entry"]].entry_name
			if entry_name not in allowed_names:
				continue
		var position: Vector3 = plant["pos"]
		var dx := position.x - origin.x
		var dz := position.z - origin.z
		var dist_sq := dx * dx + dz * dz
		if dist_sq > radius_sq:
			continue
		var score := maxf(position.y - origin.y, 0.0) * 1.25 - sqrt(dist_sq) * 0.15
		if score > best_score:
			best_score = score
			best_pos = Vector3(position.x, position.y + height_offset, position.z)
	if best_score == -INF:
		return {}
	return {
		"pos": best_pos,
		"score": best_score,
	}


# ── Cleanup ───────────────────────────────────────────────────────────────────

func _clear_chunk_flora(coord: Vector2i) -> void:
	if not _chunk_flora.has(coord):
		return
	var pids: Array = _chunk_flora[coord]
	for pid: int in pids:
		var plant: Dictionary = _plants.get(pid, {})
		if plant.is_empty():
			continue
		_free_slot(plant["entry"], plant["slot"])
		_plants.erase(pid)
		_flora_lifecycle.erase(pid)
	_total_flora_count -= pids.size()
	SharedWorld.total_flora_count -= pids.size()
	_chunk_flora.erase(coord)
	SystemBus.flora_chunk_cleared.emit(coord)


func _shutdown() -> void:
	for coord in _chunk_flora.keys():
		_clear_chunk_flora(coord)
