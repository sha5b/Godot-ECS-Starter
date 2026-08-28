class_name FaunaSystem
extends BaseSystem

## Spawns and manages fauna (animals) per chunk based on biome + FaunaEntry rules.
## Fauna types are auto-discovered as FaunaEntry children — drop scenes in!
## Uses NavigationSystem for pathfinding, biome data for filtering.

var _config: FaunaConfig

## Auto-discovered fauna types
var _fauna_entries: Array[FaunaEntry] = []

## Chunk coord → Array of spawned fauna instances
var _chunk_fauna: Dictionary = {}

## Per-instance AI state: instance_id → { entry, spawn_pos, target_pos, timer, state }
var _fauna_ai: Dictionary = {}

## Total fauna count across all chunks
var _total_fauna_count: int = 0

## Shelter and territory registries
var _home_sites: Dictionary = {}
var _shelter_nodes: Dictionary = {}
var _shelter_root: Node3D = null
var _building_root: Node3D = null
var _territory_claims: Dictionary = {}
var _fauna_groups: Dictionary = {}
var _tribes: Dictionary = {}
var _buildings: Dictionary = {}

## Cached references
var _biome_system: BiomeSystem = null
var _nav_system: NavigationSystem = null
var _ai_timer: float = 0.0
var _lifecycle_timer: float = 0.0
var _sea_level: float = 0.0
var _height_scale: float = 20.0
var _params_found: bool = false


func _initialize() -> void:
	system_name = &"FaunaSystem"
	priority = 35

	_config = _find_child_of_type(FaunaConfig)
	if not _config:
		push_warning("[FaunaSystem] No FaunaConfig child found — using defaults")
		_config = FaunaConfig.new()

	# Auto-discover all FaunaEntry children (wired in fauna_system.tscn)
	_discover_fauna_entries()

	if _fauna_entries.is_empty():
		push_warning("[FaunaSystem] No FaunaEntry children found — add entry scenes as children of FaunaSystem")

	_home_sites.clear()
	_shelter_nodes.clear()
	_territory_claims.clear()
	_fauna_groups.clear()
	_tribes.clear()
	_buildings.clear()
	_ensure_shelter_root()
	_ensure_building_root()
	_sync_shared_registries()

	print("[FaunaSystem] Registered %d fauna types: %s" % [_fauna_entries.size(), _get_entry_names()])


func _register_signals() -> void:
	SystemBus.biome_chunk_ready.connect(_on_biome_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload_requested)


func system_process(delta: float) -> void:
	if not active:
		return

	# Lazy-find systems
	if not _biome_system:
		_biome_system = _find_system_by_name(&"BiomeSystem") as BiomeSystem
	if not _nav_system:
		_nav_system = _find_system_by_name(&"NavigationSystem") as NavigationSystem
	if not _params_found:
		_find_terrain_params()
		_params_found = true

	# AI tick
	_ai_timer += delta
	if _ai_timer >= _config.ai_tick_interval:
		_ai_timer = 0.0
		_tick_all_fauna_ai()
		_refresh_fauna_groups()
		_refresh_tribes()

	# Lifecycle tick
	_update_fauna_lifecycle(delta)

	# Smooth movement between AI ticks
	_move_all_fauna(delta)


func _on_biome_chunk_ready(coord: Vector2i, biome_map: PackedByteArray) -> void:
	if _chunk_fauna.has(coord):
		return
	_spawn_fauna_for_chunk(coord, biome_map)


func _on_chunk_unload_requested(coord: Vector2i) -> void:
	_clear_chunk_fauna(coord)


# ── Fauna discovery ───────────────────────────────────────────────────────────

func _discover_fauna_entries() -> void:
	_fauna_entries.clear()
	_collect_fauna_children(self)


func _collect_fauna_children(node: Node) -> void:
	for child in node.get_children():
		if child is FaunaEntry:
			_fauna_entries.append(child)
		_collect_fauna_children(child)


## The fauna types this system discovered from its content children.
##
## PUBLIC CONTENT API. FaunaSystem owns the authored species definitions; the
## ECS layer reads them to spawn genome-backed animals with the right body
## plan, diet, prey list and biome rules. Without this the two halves each
## invent their own idea of what a species is — which is exactly what they
## used to do.
func get_entries() -> Array[FaunaEntry]:
	return _fauna_entries


func _get_entry_names() -> String:
	var names: PackedStringArray = []
	for e in _fauna_entries:
		names.append(str(e.entry_name))
	return ", ".join(names)


func _sync_shared_registries() -> void:
	SharedWorld.shelter_registry = _home_sites
	SharedWorld.territory_claims = _territory_claims
	SharedWorld.fauna_groups = _fauna_groups
	SharedWorld.tribe_registry = _tribes
	SharedWorld.building_registry = _buildings


func _get_traits(node: Node) -> FaunaTraits:
	for child in node.get_children():
		if child is FaunaTraits:
			return child as FaunaTraits
	return null


func _get_shelter_profile(node: Node) -> Node:
	for child in node.get_children():
		if child.get_script() and child.get_script().resource_path.ends_with("fauna_shelter_profile.gd"):
			return child
	return null


func _get_parenting_profile(node: Node) -> Node:
	for child in node.get_children():
		if child.get_script() and child.get_script().resource_path.ends_with("fauna_parenting_profile.gd"):
			return child
	return null


func _get_tribe_profile(node: Node) -> Node:
	for child in node.get_children():
		if child.get_script() and child.get_script().resource_path.ends_with("fauna_tribe_profile.gd"):
			return child
	return null


func _get_building_profile(node: Node) -> Node:
	for child in node.get_children():
		if child.get_script() and child.get_script().resource_path.ends_with("fauna_building_profile.gd"):
			return child
	return null


func _node_prop(node: Node, property_name: StringName, fallback: Variant) -> Variant:
	if not node:
		return fallback
	var value = node.get(property_name)
	if value == null:
		return fallback
	return value


func _get_group_type(entry: FaunaEntry) -> StringName:
	if entry.is_predator:
		return &"pack"
	if entry.can_fly or entry.flocking:
		return &"flock"
	return &"herd"


func _create_fauna_group(entry: FaunaEntry, center: Vector3) -> StringName:
	var group_id := StringName("%s_group_%d" % [str(entry.entry_name), Time.get_ticks_msec()])
	_fauna_groups[group_id] = {
		"group_id": group_id,
		"species_name": entry.entry_name,
		"group_type": _get_group_type(entry),
		"center": center,
		"leader_id": 0,
		"member_ids": [],
	}
	SystemBus.fauna_group_created.emit(group_id, center, entry.entry_name, _get_group_type(entry))
	return group_id


func _join_fauna_group(group_id: StringName, ai: Dictionary, member_id: int) -> void:
	if not _fauna_groups.has(group_id):
		return
	var group_data: Dictionary = _fauna_groups[group_id]
	var members: Array = group_data.get("member_ids", [])
	if member_id not in members:
		members.append(member_id)
	group_data["member_ids"] = members
	if int(group_data.get("leader_id", 0)) == 0:
		group_data["leader_id"] = member_id
	ai["group_id"] = group_id
	ai["group_role"] = &"leader" if int(group_data.get("leader_id", 0)) == member_id else &"member"


func _leave_fauna_group(ai: Dictionary, member_id: int) -> void:
	var group_id := ai.get("group_id", &"") as StringName
	if group_id == &"" or not _fauna_groups.has(group_id):
		return
	var group_data: Dictionary = _fauna_groups[group_id]
	var members: Array = group_data.get("member_ids", [])
	members.erase(member_id)
	if members.is_empty():
		SystemBus.fauna_group_disbanded.emit(group_id, group_data.get("species_name", &""))
		_fauna_groups.erase(group_id)
	else:
		group_data["member_ids"] = members
		if int(group_data.get("leader_id", 0)) == member_id:
			group_data["leader_id"] = int(members[0])
	ai["group_id"] = &""
	ai["group_role"] = &""


func _assign_group_membership(node: Node3D, ai: Dictionary, entry: FaunaEntry) -> void:
	var traits: FaunaTraits = ai.get("traits") as FaunaTraits
	if not traits or traits.social_drive <= 0.0:
		return
	var best_group_id := StringName()
	var best_dist_sq := INF
	for group_id in _fauna_groups.keys():
		var group_data: Dictionary = _fauna_groups[group_id]
		if group_data.get("species_name", &"") != entry.entry_name:
			continue
		var center: Vector3 = group_data.get("center", node.position)
		var dist_sq := node.position.distance_squared_to(center)
		if dist_sq < _config.social_neighbor_radius * _config.social_neighbor_radius and dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_group_id = group_id
	if best_group_id == &"":
		best_group_id = _create_fauna_group(entry, node.position)
	_join_fauna_group(best_group_id, ai, node.get_instance_id())


func _refresh_fauna_groups() -> void:
	var to_remove: Array[StringName] = []
	for group_id in _fauna_groups.keys():
		var group_data: Dictionary = _fauna_groups[group_id]
		var members: Array = group_data.get("member_ids", [])
		var valid_members: Array = []
		var center := Vector3.ZERO
		for member_id in members:
			var member_node := _get_node_for_iid(int(member_id))
			if not is_instance_valid(member_node):
				continue
			valid_members.append(member_id)
			center += member_node.position
		if valid_members.is_empty():
			to_remove.append(group_id)
			continue
		group_data["member_ids"] = valid_members
		group_data["center"] = center / float(valid_members.size())
		if int(group_data.get("leader_id", 0)) not in valid_members:
			group_data["leader_id"] = int(valid_members[0])
		SystemBus.fauna_group_updated.emit(group_id, group_data["center"], valid_members.size())
	for group_id in to_remove:
		var species_name: StringName = _fauna_groups[group_id].get("species_name", &"")
		_fauna_groups.erase(group_id)
		SystemBus.fauna_group_disbanded.emit(group_id, species_name)
	_sync_shared_registries()


func _get_group_center(ai: Dictionary, fallback_center: Vector3) -> Vector3:
	var group_id := ai.get("group_id", &"") as StringName
	if group_id != &"" and _fauna_groups.has(group_id):
		return _fauna_groups[group_id].get("center", fallback_center)
	return fallback_center


func _get_parenting_data(ai: Dictionary) -> Dictionary:
	var parenting_profile: Node = ai.get("parenting_profile") as Node
	if not parenting_profile or not bool(_node_prop(parenting_profile, &"enabled", false)):
		return {
			"dependent_count": 0,
			"offspring_center": Vector3.INF,
			"farthest_distance": 0.0,
		}
	var child_ids: Array = ai.get("offspring_ids", [])
	var dependent_count := 0
	var offspring_center := Vector3.ZERO
	var farthest_distance := 0.0
	var self_node := _get_node_for_iid(int(ai.get("self_id", 0)))
	if not is_instance_valid(self_node):
		return {
			"dependent_count": 0,
			"offspring_center": Vector3.INF,
			"farthest_distance": 0.0,
		}
	for child_id in child_ids:
		if not _fauna_ai.has(int(child_id)):
			continue
		var child_ai: Dictionary = _fauna_ai[int(child_id)]
		if not _is_dependent_offspring(child_ai):
			continue
		var child_node := _get_node_for_iid(int(child_id))
		if not is_instance_valid(child_node):
			continue
		dependent_count += 1
		offspring_center += child_node.position
		farthest_distance = maxf(farthest_distance, self_node.position.distance_to(child_node.position))
	if dependent_count == 0:
		return {
			"dependent_count": 0,
			"offspring_center": Vector3.INF,
			"farthest_distance": 0.0,
		}
	return {
		"dependent_count": dependent_count,
		"offspring_center": offspring_center / float(dependent_count),
		"farthest_distance": farthest_distance,
	}


func _is_dependent_offspring(ai: Dictionary) -> bool:
	if ai.get("life_stage", &"adult") != &"juvenile":
		return false
	var parenting_profile: Node = ai.get("parenting_profile") as Node
	if not parenting_profile:
		return true
	var entry: FaunaEntry = ai.get("entry") as FaunaEntry
	if not entry:
		return true
	var independence_age := entry.maturity_age * float(_node_prop(parenting_profile, &"independence_age_fraction", 0.35))
	return float(ai.get("age", 0.0)) < independence_age


func _ensure_shelter_root() -> void:
	if is_instance_valid(_shelter_root):
		return
	_shelter_root = get_node_or_null("FaunaShelters") as Node3D
	if _shelter_root:
		return
	_shelter_root = Node3D.new()
	_shelter_root.name = "FaunaShelters"
	add_child(_shelter_root)


func _ensure_building_root() -> void:
	if is_instance_valid(_building_root):
		return
	_building_root = get_node_or_null("FaunaBuildings") as Node3D
	if _building_root:
		return
	_building_root = Node3D.new()
	_building_root.name = "FaunaBuildings"
	add_child(_building_root)


func _spawn_building_visual(building_id: StringName, world_pos: Vector3, building_type: StringName) -> void:
	_ensure_building_root()
	if not is_instance_valid(_building_root):
		return
	if _building_root.get_node_or_null(str(building_id)):
		return
	var root := Node3D.new()
	root.name = str(building_id)
	root.position = world_pos
	_snap_prop_to_surface(root)
	var body := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.roughness = 1.0
	material.albedo_color = Color(0.45, 0.36, 0.24, 1.0)
	match building_type:
		&"camp":
			var tent_mesh := CylinderMesh.new()
			tent_mesh.top_radius = 0.15
			tent_mesh.bottom_radius = 1.0
			tent_mesh.height = 1.0
			body.mesh = tent_mesh
			body.position.y = 0.5
		&"roost_platform":
			var platform_mesh := BoxMesh.new()
			platform_mesh.size = Vector3(1.6, 0.1, 1.6)
			body.mesh = platform_mesh
			body.position.y = 1.5
		_:
			var hut_mesh := BoxMesh.new()
			hut_mesh.size = Vector3(1.8, 1.2, 1.8)
			body.mesh = hut_mesh
			body.position.y = 0.6
	body.material_override = material
	root.add_child(body)
	_building_root.add_child(root)


func _despawn_building_visual(building_id: StringName) -> void:
	if not is_instance_valid(_building_root):
		return
	var node := _building_root.get_node_or_null(str(building_id)) as Node3D
	if is_instance_valid(node):
		node.queue_free()


func _register_tribe_for_group(group_id: StringName, leader_ai: Dictionary, center: Vector3) -> void:
	if not _fauna_groups.has(group_id):
		return
	var tribe_profile: Node = leader_ai.get("tribe_profile") as Node
	var building_profile: Node = leader_ai.get("building_profile") as Node
	var leader_entry: FaunaEntry = leader_ai.get("entry") as FaunaEntry
	if not tribe_profile or not leader_entry or not bool(_node_prop(tribe_profile, &"enabled", false)) or not bool(_node_prop(tribe_profile, &"can_found_tribe", true)):
		return
	var traits: FaunaTraits = leader_ai.get("traits") as FaunaTraits
	if not traits or traits.intelligence < float(_node_prop(tribe_profile, &"min_intelligence", 0.9)):
		return
	var group_data: Dictionary = _fauna_groups[group_id]
	var members: Array = group_data.get("member_ids", [])
	if members.size() < int(_node_prop(tribe_profile, &"min_group_size", 3)):
		return
	var tribe_id := StringName("%s_tribe" % str(group_id))
	if not _tribes.has(tribe_id):
		_tribes[tribe_id] = {
			"tribe_id": tribe_id,
			"group_id": group_id,
			"leader_id": int(group_data.get("leader_id", 0)),
			"species_name": leader_entry.entry_name,
			"tribe_type": _node_prop(tribe_profile, &"preferred_tribe_type", &"camp"),
			"center": center,
			"member_ids": members.duplicate(),
			"building_ids": [],
		}
		SystemBus.tribe_created.emit(tribe_id, center, leader_entry.entry_name)
	for member_id in members:
		if _fauna_ai.has(int(member_id)):
			_fauna_ai[int(member_id)]["tribe_id"] = tribe_id
	var tribe_data: Dictionary = _tribes[tribe_id]
	tribe_data["center"] = center
	tribe_data["member_ids"] = members.duplicate()
	tribe_data["leader_id"] = int(group_data.get("leader_id", 0))
	SystemBus.tribe_updated.emit(tribe_id, center, members.size())
	if building_profile and bool(_node_prop(tribe_profile, &"building_enabled", true)):
		var building_ids: Array = tribe_data.get("building_ids", [])
		if building_ids.size() < int(_node_prop(tribe_profile, &"max_buildings", 3)) and building_ids.is_empty():
			var building_id := StringName("%s_building_0" % str(tribe_id))
			var building_pos := _get_home_site_position(leader_ai, center)
			if not bool(_node_prop(tribe_profile, &"prefers_building_near_home", true)):
				building_pos = center
			else:
				building_pos += Vector3(float(_node_prop(building_profile, &"preferred_offset_from_center", 5.0)), 0.0, 0.0)
			_buildings[building_id] = {
				"building_id": building_id,
				"tribe_id": tribe_id,
				"owner_id": tribe_id,
				"building_type": _node_prop(building_profile, &"building_type", &"hut"),
				"world_pos": building_pos,
			}
			building_ids.append(building_id)
			tribe_data["building_ids"] = building_ids
			_spawn_building_visual(building_id, building_pos, _node_prop(building_profile, &"building_type", &"hut"))
			SystemBus.building_created.emit(building_id, building_pos, _node_prop(building_profile, &"building_type", &"hut"), tribe_id)


func _refresh_tribes() -> void:
	var stale_tribes: Array[StringName] = []
	for tribe_id in _tribes.keys():
		var tribe_data: Dictionary = _tribes[tribe_id]
		var group_id := tribe_data.get("group_id", &"") as StringName
		if group_id == &"" or not _fauna_groups.has(group_id):
			stale_tribes.append(tribe_id)
	for tribe_id in stale_tribes:
		var tribe_data: Dictionary = _tribes[tribe_id]
		for building_id in tribe_data.get("building_ids", []):
			if _buildings.has(building_id):
				_despawn_building_visual(building_id)
				_buildings.erase(building_id)
				SystemBus.building_abandoned.emit(building_id, tribe_id)
		_tribes.erase(tribe_id)
	for group_id in _fauna_groups.keys():
		var group_data: Dictionary = _fauna_groups[group_id]
		var leader_id := int(group_data.get("leader_id", 0))
		if leader_id == 0 or not _fauna_ai.has(leader_id):
			continue
		_register_tribe_for_group(group_id, _fauna_ai[leader_id], group_data.get("center", Vector3.ZERO))
	_sync_shared_registries()
const TERRAIN_SYSTEM_SCRIPT = preload("res://systems/terrain/terrain_system.gd")
var _terrain_system: TerrainSystem = null


## Glue a shelter or building to the generated ground: take the authoritative
## carved-surface height from the terrain system, then tilt onto the surface
## normal so wide props don't float on slopes.
func _snap_prop_to_surface(root: Node3D) -> void:
	if _terrain_system == null:
		_terrain_system = _find_system_by_type(TERRAIN_SYSTEM_SCRIPT) as TerrainSystem
	if _terrain_system == null:
		return
	var pos := root.position
	pos.y = _terrain_system.sample_surface_height(pos.x, pos.z) - 0.02
	var normal := _terrain_system.sample_surface_normal(pos.x, pos.z, 1.0)
	if normal.dot(Vector3.UP) < 0.999:
		root.quaternion = Quaternion(Vector3.UP, normal)
	root.position = pos


func _spawn_shelter_visual(site_id: StringName, world_pos: Vector3, shelter_type: StringName) -> void:
	_ensure_shelter_root()
	if _shelter_nodes.has(site_id):
		return
	var root := Node3D.new()
	root.name = str(site_id)
	root.position = world_pos
	_snap_prop_to_surface(root)
	var material := StandardMaterial3D.new()
	material.roughness = 1.0
	material.albedo_color = Color(0.35, 0.26, 0.18, 1.0)

	match shelter_type:
		&"burrow":
			var burrow := MeshInstance3D.new()
			var burrow_mesh := CylinderMesh.new()
			burrow_mesh.top_radius = 0.55
			burrow_mesh.bottom_radius = 0.65
			burrow_mesh.height = 0.18
			burrow.mesh = burrow_mesh
			burrow.material_override = material
			burrow.position.y = 0.04
			root.add_child(burrow)
			var entrance := MeshInstance3D.new()
			var entrance_mesh := SphereMesh.new()
			entrance_mesh.radius = 0.22
			entrance_mesh.height = 0.22
			var entrance_mat := StandardMaterial3D.new()
			entrance_mat.albedo_color = Color(0.08, 0.07, 0.06, 1.0)
			entrance.mesh = entrance_mesh
			entrance.material_override = entrance_mat
			entrance.scale = Vector3(1.0, 0.55, 1.0)
			entrance.position = Vector3(0.0, 0.02, 0.0)
			root.add_child(entrance)
		&"nest":
			var nest := MeshInstance3D.new()
			var nest_mesh := CylinderMesh.new()
			nest_mesh.top_radius = 0.55
			nest_mesh.bottom_radius = 0.75
			nest_mesh.height = 0.16
			material.albedo_color = Color(0.42, 0.31, 0.17, 1.0)
			nest.mesh = nest_mesh
			nest.material_override = material
			nest.position.y = 0.08
			root.add_child(nest)
		&"roost":
			var perch := MeshInstance3D.new()
			var perch_mesh := BoxMesh.new()
			perch_mesh.size = Vector3(0.9, 0.06, 0.18)
			material.albedo_color = Color(0.28, 0.22, 0.16, 1.0)
			perch.mesh = perch_mesh
			perch.material_override = material
			perch.position.y = 1.2
			root.add_child(perch)
			var hanging := MeshInstance3D.new()
			var hanging_mesh := SphereMesh.new()
			hanging_mesh.radius = 0.18
			hanging_mesh.height = 0.32
			var hanging_mat := StandardMaterial3D.new()
			hanging_mat.albedo_color = Color(0.14, 0.11, 0.10, 1.0)
			hanging.mesh = hanging_mesh
			hanging.material_override = hanging_mat
			hanging.scale = Vector3(0.65, 1.0, 0.65)
			hanging.position = Vector3(0.0, 0.98, 0.0)
			root.add_child(hanging)
		&"resting_site":
			var bed := MeshInstance3D.new()
			var bed_mesh := BoxMesh.new()
			bed_mesh.size = Vector3(1.1, 0.08, 1.1)
			material.albedo_color = Color(0.36, 0.29, 0.19, 1.0)
			bed.mesh = bed_mesh
			bed.material_override = material
			bed.position.y = 0.04
			root.add_child(bed)
		_:
			var marker := MeshInstance3D.new()
			var marker_mesh := BoxMesh.new()
			marker_mesh.size = Vector3(0.8, 0.08, 0.8)
			marker.mesh = marker_mesh
			marker.material_override = material
			marker.position.y = 0.04
			root.add_child(marker)

	_shelter_root.add_child(root)
	_shelter_nodes[site_id] = root


func _despawn_shelter_visual(site_id: StringName) -> void:
	if not _shelter_nodes.has(site_id):
		return
	var node := _shelter_nodes[site_id] as Node3D
	_shelter_nodes.erase(site_id)
	if is_instance_valid(node):
		node.queue_free()


func _find_best_shelter_site(node: Node3D, ai: Dictionary, fallback_pos: Vector3) -> Vector3:
	var shelter_profile: Node = ai.get("shelter_profile") as Node
	if not shelter_profile:
		return fallback_pos

	var best_pos := fallback_pos
	var best_score := -INF
	var elevated_bonus := 0.0
	var min_height_delta := float(_node_prop(shelter_profile, &"min_site_height_delta", 0.0))
	var prefers_elevated := bool(_node_prop(shelter_profile, &"prefers_elevated_sites", false))
	var prefers_cliffs := bool(_node_prop(shelter_profile, &"prefers_cliffs", false))
	var cliff_min_slope := float(_node_prop(shelter_profile, &"cliff_min_slope_degrees", 35.0))
	var sample_count := maxi(int(_node_prop(shelter_profile, &"site_search_samples", 10)), 1)
	var search_radius := maxf(float(_node_prop(shelter_profile, &"site_search_radius", 12.0)), 1.0)

	if bool(_node_prop(shelter_profile, &"prefers_support_flora", false)):
		var support_site := _find_best_support_flora_site(node.position, shelter_profile)
		if not Dictionary(support_site).is_empty():
			best_pos = support_site.get("pos", fallback_pos)
			best_score = float(support_site.get("score", 10.0))

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(node.get_instance_id()) + str(fallback_pos))
	for _i in sample_count:
		var angle := rng.randf() * TAU
		var dist := rng.randf_range(0.0, search_radius)
		var candidate_x := fallback_pos.x + cos(angle) * dist
		var candidate_z := fallback_pos.z + sin(angle) * dist
		var chunk_coord := SharedWorld.world_to_chunk(Vector3(candidate_x, 0.0, candidate_z))
		var cs := GameConfig.chunk_size
		var local_x := clampf(candidate_x - chunk_coord.x * cs, 0.0, cs - 0.01)
		var local_z := clampf(candidate_z - chunk_coord.y * cs, 0.0, cs - 0.01)
		var ground_h := _sample_terrain_height(chunk_coord, local_x, local_z)
		if ground_h <= _sea_level + 0.1:
			continue
		var slope := _sample_terrain_slope(chunk_coord, local_x, local_z)
		var height_delta := ground_h - fallback_pos.y
		var score := 0.0
		if height_delta < min_height_delta:
			score -= 10.0
		else:
			score += 2.0
		if prefers_elevated:
			elevated_bonus = maxf(height_delta, 0.0) * 0.75
			score += elevated_bonus
		if prefers_cliffs:
			if slope >= cliff_min_slope:
				score += 6.0 + (slope - cliff_min_slope) * 0.05
			else:
				score -= 4.0
		else:
			score -= slope * 0.02
		if score > best_score:
			best_score = score
			best_pos = Vector3(candidate_x, ground_h, candidate_z)

	return best_pos


func _find_best_support_flora_site(origin: Vector3, shelter_profile: Node) -> Dictionary:
	var flora_system := _find_system_by_name(&"FloraSystem")
	if not flora_system:
		return {}
	var allowed_supports: Array = _node_prop(shelter_profile, &"preferred_support_flora_names", [])
	var search_radius := float(_node_prop(shelter_profile, &"support_search_radius", 4.0))
	var height_offset := float(_node_prop(shelter_profile, &"support_height_offset", 2.5))
	return (flora_system as FloraSystem).find_support_site(
		origin, allowed_supports, search_radius, height_offset)


func _get_home_site_position(ai: Dictionary, fallback_pos: Vector3) -> Vector3:
	var site_id := ai.get("home_site_id", &"") as StringName
	if site_id != &"" and _home_sites.has(site_id):
		return _home_sites[site_id].get("world_pos", fallback_pos)
	return fallback_pos


func _register_home_site(node: Node3D, ai: Dictionary, world_pos: Vector3) -> void:
	var shelter_profile: Node = ai.get("shelter_profile") as Node
	var entry: FaunaEntry = ai.get("entry") as FaunaEntry
	if not shelter_profile or not bool(_node_prop(shelter_profile, &"enabled", false)) or not entry:
		return
	var site_world_pos := _find_best_shelter_site(node, ai, world_pos)
	var site_id := StringName("%s_home_%d" % [str(entry.entry_name), node.get_instance_id()])
	_home_sites[site_id] = {
		"site_id": site_id,
		"owner_id": node.get_instance_id(),
		"owner_name": entry.entry_name,
		"shelter_type": _node_prop(shelter_profile, &"shelter_type", &"resting_site"),
		"world_pos": site_world_pos,
	}
	ai["home_site_id"] = site_id
	var shelter_type := _node_prop(shelter_profile, &"shelter_type", &"resting_site") as StringName
	_spawn_shelter_visual(site_id, site_world_pos, shelter_type)
	SystemBus.shelter_created.emit(site_id, site_world_pos, shelter_type, entry.entry_name)
	SystemBus.shelter_claimed.emit(site_id, site_world_pos, shelter_type, entry.entry_name)
	if bool(_node_prop(shelter_profile, &"territory_enabled", false)) and float(_node_prop(shelter_profile, &"territory_radius", 0.0)) > 0.0:
		_register_territory_claim(node, ai, site_world_pos, float(_node_prop(shelter_profile, &"territory_radius", 0.0)))
	_sync_shared_registries()


func _register_territory_claim(node: Node3D, ai: Dictionary, center: Vector3, radius: float) -> void:
	var entry: FaunaEntry = ai.get("entry") as FaunaEntry
	if not entry or radius <= 0.0:
		return
	var claim_id := StringName("%s_territory_%d" % [str(entry.entry_name), node.get_instance_id()])
	_territory_claims[claim_id] = {
		"claim_id": claim_id,
		"owner_id": node.get_instance_id(),
		"owner_name": entry.entry_name,
		"center": center,
		"radius": radius,
	}
	ai["territory_id"] = claim_id
	SystemBus.territory_claimed.emit(claim_id, center, radius, entry.entry_name)
	_sync_shared_registries()


func _release_home_site(ai: Dictionary) -> void:
	var site_id := ai.get("home_site_id", &"") as StringName
	if site_id == &"" or not _home_sites.has(site_id):
		return
	var site: Dictionary = _home_sites[site_id]
	if int(site.get("owner_id", 0)) != int(ai.get("self_id", 0)):
		return
	_home_sites.erase(site_id)
	_despawn_shelter_visual(site_id)
	SystemBus.shelter_abandoned.emit(site_id, site.get("world_pos", Vector3.ZERO), site.get("shelter_type", &""), site.get("owner_name", &""))
	_sync_shared_registries()


func _release_territory_claim(ai: Dictionary) -> void:
	var claim_id := ai.get("territory_id", &"") as StringName
	if claim_id == &"" or not _territory_claims.has(claim_id):
		return
	var claim: Dictionary = _territory_claims[claim_id]
	if int(claim.get("owner_id", 0)) != int(ai.get("self_id", 0)):
		return
	_territory_claims.erase(claim_id)
	SystemBus.territory_lost.emit(claim_id, claim.get("center", Vector3.ZERO), claim.get("owner_name", &""))
	_sync_shared_registries()


func _pick_fauna_entry(rng: RandomNumberGenerator, biome_name: StringName) -> FaunaEntry:
	var valid: Array = []
	var weights: Array[float] = []
	var weight_sum := 0.0

	for entry in _fauna_entries:
		var fe: FaunaEntry = entry as FaunaEntry
		if not fe or fe.get_child_count() == 0:
			continue
		if not fe.is_allowed_in_biome(biome_name):
			continue
		valid.append(fe)
		weights.append(fe.spawn_weight)
		weight_sum += fe.spawn_weight

	if valid.is_empty() or weight_sum <= 0.0:
		return null

	var roll := rng.randf() * weight_sum
	var cumulative := 0.0
	for i in valid.size():
		cumulative += weights[i]
		if roll <= cumulative:
			return valid[i] as FaunaEntry
	return valid[valid.size() - 1] as FaunaEntry


# ── Spawning ──────────────────────────────────────────────────────────────────

func _spawn_fauna_for_chunk(coord: Vector2i, biome_map: PackedByteArray) -> void:
	var res := int(sqrt(biome_map.size()))
	if res == 0 or _fauna_entries.is_empty():
		return
	if _total_fauna_count >= _config.max_total_fauna:
		return

	var cs := GameConfig.chunk_size
	var chunk_origin := Vector3(coord.x * cs, 0.0, coord.y * cs)

	var rng := RandomNumberGenerator.new()
	rng.seed = GameConfig.chunk_hash(coord.x, coord.y) + 7777

	var instances: Array[Node3D] = []
	var entry_counts: Dictionary = {}
	var density: int = _config.base_density

	for _attempt in density:
		if instances.size() >= _config.max_spawns_per_frame:
			break
		if _total_fauna_count + instances.size() >= _config.max_total_fauna:
			break

		var local_x := rng.randf() * cs
		var local_z := rng.randf() * cs

		# Get biome
		var bx := clampi(int((local_x / cs) * (res - 1)), 0, res - 1)
		var bz := clampi(int((local_z / cs) * (res - 1)), 0, res - 1)
		var biome_idx := biome_map[bz * res + bx]

		var density_mult := 1.0
		var biome_name := &"plains"
		if _biome_system:
			var bdata := _biome_system.get_biome_data(biome_idx)
			if bdata:
				density_mult = bdata.fauna_density_multiplier
				biome_name = bdata.biome_name

		if rng.randf() > density_mult * 0.15:
			continue

		# Sample height
		var height := _sample_terrain_height(coord, local_x, local_z)
		var is_underwater := height < _sea_level
		var water_depth := _sea_level - height  # Positive when underwater

		# Pick entry
		var entry: FaunaEntry = _pick_fauna_entry(rng, biome_name)
		if not entry:
			continue

		var current_count := int(entry_counts.get(entry.entry_name, 0))
		if current_count >= entry.max_per_chunk:
			continue

		# Route aquatic vs land fauna
		if entry.aquatic:
			# Aquatic fauna: must be underwater at the right depth
			if not is_underwater:
				continue
			if water_depth < entry.min_water_depth or water_depth > entry.max_water_depth:
				continue
		else:
			# Land fauna: skip underwater positions
			if height < _sea_level + 0.5:
				continue
			var height_norm := clampf((height - _sea_level) / _height_scale, 0.0, 1.0)
			if height_norm < entry.min_height or height_norm > entry.max_height:
				continue
			if not entry.can_fly and not entry.aquatic:
				var slope_deg := _sample_terrain_slope(coord, local_x, local_z)
				if slope_deg > entry.max_slope_degrees:
					continue

		var world_x := chunk_origin.x + local_x
		var world_z := chunk_origin.z + local_z
		if not _has_fauna_spacing(instances, world_x, world_z, _config.min_spacing):
			continue

		# Instantiate by cloning entry's mesh children
		var instance: Node3D = entry.create_instance()
		var world_pos := Vector3(chunk_origin.x + local_x, height, chunk_origin.z + local_z)
		if entry.aquatic:
			# Position aquatic fauna at swim_height above seafloor
			world_pos.y = height + entry.swim_height
		elif entry.can_fly:
			world_pos.y += rng.randf_range(entry.flight_height_min, entry.flight_height_max)
		instance.position = world_pos

		var s := rng.randf_range(entry.scale_min, entry.scale_max)
		instance.scale = Vector3(s, s, s)
		instance.rotation.y = rng.randf() * TAU

		add_child(instance)
		instances.append(instance)
		entry_counts[entry.entry_name] = current_count + 1

		# Register AI state (includes lifecycle fields)
		var variance := _config.max_age_variance
		var age_mult := 1.0 + rng.randf_range(-variance, variance)
		var traits: FaunaTraits = _get_traits(instance)
		var shelter_profile: Node = _get_shelter_profile(instance)
		var parenting_profile: Node = _get_parenting_profile(instance)
		var tribe_profile: Node = _get_tribe_profile(instance)
		var building_profile: Node = _get_building_profile(instance)
		_fauna_ai[instance.get_instance_id()] = {
			"self_id": instance.get_instance_id(),
			"entry": entry,
			"traits": traits,
			"shelter_profile": shelter_profile,
			"parenting_profile": parenting_profile,
			"tribe_profile": tribe_profile,
			"building_profile": building_profile,
			"group_id": &"",
			"group_role": &"",
			"tribe_id": &"",
			"building_id": &"",
			"spawn_pos": world_pos,
			"target_pos": world_pos,
			"timer": rng.randf() * entry.wander_interval,
			"state": &"idle",
			"velocity": Vector3.ZERO,
			"flight_base": world_pos.y,
			"flap_phase": rng.randf() * TAU,
			"age": 0.0,
			"hunger": 0.0,
			"health": entry.health_max,
			"life_stage": &"adult",
			"max_age": entry.max_age * age_mult,
			"breed_cooldown": 0.0,
			"nest_timer": 0.0,
			"home_site_id": &"",
			"territory_id": &"",
			"parent_id": 0,
			"offspring_ids": [],
			"decision_scores": {},
			"last_threat_time": -INF,
			"base_scale": instance.scale,
		}
		_register_home_site(instance, _fauna_ai[instance.get_instance_id()], world_pos)
		_assign_group_membership(instance, _fauna_ai[instance.get_instance_id()], entry)

	_chunk_fauna[coord] = instances
	_total_fauna_count += instances.size()
	SharedWorld.total_fauna_count = _total_fauna_count
	SystemBus.fauna_chunk_spawned.emit(coord, instances.size())


# ── AI ────────────────────────────────────────────────────────────────────────

func _tick_all_fauna_ai() -> void:
	var cam_pos := SharedWorld.camera_world_pos

	for coord in _chunk_fauna:
		var instances: Array = _chunk_fauna[coord]
		for inst in instances:
			if not is_instance_valid(inst):
				continue
			var node: Node3D = inst as Node3D
			if not node:
				continue
			var iid := node.get_instance_id()
			if not _fauna_ai.has(iid):
				continue

			var ai: Dictionary = _fauna_ai[iid]
			var entry: FaunaEntry = ai["entry"] as FaunaEntry
			if not entry:
				continue
			_tick_single_fauna_ai(node, ai, entry, cam_pos)


func _tick_single_fauna_ai(node: Node3D, ai: Dictionary, entry: FaunaEntry, cam_pos: Vector3) -> void:
	var perception := _build_perception(node, ai, entry, cam_pos)
	var scores := _score_decisions(ai, entry, perception)
	ai["decision_scores"] = scores

	if float(scores.get("fear", 0.0)) >= 0.75:
		var threat_pos := cam_pos
		var predator_node: Node3D = perception.get("predator_node") as Node3D
		if predator_node:
			threat_pos = predator_node.position
		_remember_event(ai, &"threat", threat_pos)
		_broadcast_event(node, entry, ai, &"threat", threat_pos)
		var flee_dir := (node.position - threat_pos).normalized()
		if not entry.can_fly and not entry.aquatic:
			flee_dir.y = 0.0
		_set_target(node, ai, entry, node.position + flee_dir * entry.flee_distance, &"flee")
		return

	var parent_target := _get_parent_follow_target(ai)
	if float(scores.get("follow_parent", 0.0)) >= 0.5 and parent_target != Vector3.INF:
		_set_target(node, ai, entry, parent_target, &"follow")
		return

	var offspring_center := perception.get("offspring_center", Vector3.INF) as Vector3
	if float(scores.get("return_young_home", 0.0)) >= 0.6:
		_set_target(node, ai, entry, perception.get("home_pos", ai.get("spawn_pos", node.position)), &"escort_home")
		return
	if float(scores.get("escort_offspring", 0.0)) >= 0.55 and offspring_center != Vector3.INF:
		_set_target(node, ai, entry, offspring_center, &"escort_offspring")
		return

	if float(scores.get("shelter", 0.0)) >= 0.6:
		_set_target(node, ai, entry, perception.get("home_pos", ai.get("spawn_pos", node.position)), &"return_home")
		return

	var prey_node: Node3D = perception.get("prey_node") as Node3D
	if float(scores.get("hunt", 0.0)) >= 0.55 and prey_node:
		_set_target(node, ai, entry, prey_node.position, &"chase")
		return

	if float(scores.get("forage", 0.0)) >= 0.55 and (entry.diet == &"herbivore" or entry.diet == &"omnivore"):
		_try_forage(node, ai, entry)
		if ai.get("state", &"idle") == &"foraging":
			return

	var group_center := perception.get("group_center", node.position) as Vector3
	if float(scores.get("social", 0.0)) >= 0.55 and group_center.distance_to(node.position) > 2.0:
		_set_target(node, ai, entry, group_center, &"regroup")
		return

	if float(scores.get("territory", 0.0)) >= 0.5:
		var patrol_target := _get_patrol_target(ai, entry, perception.get("home_pos", ai.get("spawn_pos", node.position)))
		_set_target(node, ai, entry, patrol_target, &"patrol")
		return

	if _should_pick_new_wander_target(ai):
		_set_target(node, ai, entry, _build_wander_target(ai, entry), &"wander")


func _build_perception(node: Node3D, ai: Dictionary, entry: FaunaEntry, cam_pos: Vector3) -> Dictionary:
	var home_pos: Vector3 = _get_home_site_position(ai, ai.get("spawn_pos", node.position))
	var social_radius := _config.social_neighbor_radius
	var traits: FaunaTraits = ai.get("traits") as FaunaTraits
	if traits and traits.communication_range > 0.0:
		social_radius = traits.communication_range
	var group_data := _get_same_species_group_data(node, entry, social_radius)
	var parenting_data := _get_parenting_data(ai)
	var group_center := _get_group_center(ai, group_data.get("center", node.position))
	var group_count := int(group_data.get("count", 0))
	var group_id := ai.get("group_id", &"") as StringName
	if group_id != &"" and _fauna_groups.has(group_id):
		group_count = int(_fauna_groups[group_id].get("member_ids", []).size())
	return {
		"dist_to_camera": node.position.distance_to(cam_pos),
		"predator_node": null if entry.is_predator else _find_nearest_predator(node, entry),
		"prey_node": _find_nearest_prey(node, entry) if entry.is_predator and not entry.prey_names.is_empty() else null,
		"home_pos": home_pos,
		"dist_to_home": node.position.distance_to(home_pos),
		"group_center": group_center,
		"group_count": group_count,
		"dependent_offspring_count": int(parenting_data.get("dependent_count", 0)),
		"offspring_center": parenting_data.get("offspring_center", Vector3.INF),
		"farthest_offspring_distance": float(parenting_data.get("farthest_distance", 0.0)),
		"recent_threat": _recall_recent(ai, &"threat", _config.threat_memory_duration),
	}


func _score_decisions(ai: Dictionary, entry: FaunaEntry, perception: Dictionary) -> Dictionary:
	var traits: FaunaTraits = ai.get("traits") as FaunaTraits
	var shelter_profile: Node = ai.get("shelter_profile") as Node
	var parenting_profile: Node = ai.get("parenting_profile") as Node
	var hunger := clampf(float(ai.get("hunger", 0.0)) / maxf(entry.hunger_death_threshold, 0.001), 0.0, 1.0)
	var fear := 0.0
	if perception.get("predator_node"):
		fear = 1.0
	elif float(perception.get("dist_to_camera", INF)) < entry.flee_distance:
		fear = 0.8
	elif not Dictionary(perception.get("recent_threat", {})).is_empty():
		fear = 0.45
	var social := 0.0
	if traits:
		social = traits.social_drive * clampf(1.0 - float(perception.get("group_count", 0)) / 3.0, 0.0, 1.0)
	var shelter_score := 0.0
	if shelter_profile and bool(_node_prop(shelter_profile, &"returns_home_to_rest", false)):
		if SharedWorld.rain_intensity >= float(_node_prop(shelter_profile, &"weather_shelter_threshold", 0.5)):
			shelter_score = 0.8
		elif float(perception.get("dist_to_home", 0.0)) > float(_node_prop(shelter_profile, &"return_home_distance", 8.0)):
			shelter_score = 0.35
	var territory := 0.0
	if shelter_profile and bool(_node_prop(shelter_profile, &"territory_enabled", false)):
		var territory_radius := float(_node_prop(shelter_profile, &"territory_radius", 0.0))
		if territory_radius > 0.0 and float(perception.get("dist_to_home", 0.0)) > territory_radius * 0.7:
			territory = 0.75
		elif int(Time.get_ticks_msec() / 1000.0) % maxi(int(round(_config.territory_patrol_interval)), 1) == 0:
			territory = maxf(territory, float(_node_prop(shelter_profile, &"patrol_bias", 0.35)))
	var follow_parent := 0.0
	if parenting_profile and bool(_node_prop(parenting_profile, &"enabled", false)) and ai.get("parent_id", 0) != 0 and ai.get("life_stage", &"adult") == &"juvenile":
		follow_parent = 0.9
	var escort_offspring := 0.0
	var return_young_home := 0.0
	var dependent_offspring_count := int(perception.get("dependent_offspring_count", 0))
	if parenting_profile and bool(_node_prop(parenting_profile, &"enabled", false)) and dependent_offspring_count > 0 and ai.get("life_stage", &"juvenile") == &"adult":
		var farthest_offspring_distance := float(perception.get("farthest_offspring_distance", 0.0))
		if bool(_node_prop(parenting_profile, &"escorts_offspring", true)) and farthest_offspring_distance > float(_node_prop(parenting_profile, &"regroup_offspring_distance", 10.0)):
			escort_offspring = 0.85
		if bool(_node_prop(parenting_profile, &"returns_young_home", true)):
			var threat_bias := float(_node_prop(parenting_profile, &"threat_response_bias", 0.8))
			if fear > 0.0:
				return_young_home = maxf(return_young_home, fear * threat_bias)
			if farthest_offspring_distance > float(_node_prop(parenting_profile, &"escort_home_distance", 14.0)):
				return_young_home = maxf(return_young_home, 0.7)
	return {
		"fear": fear,
		"hunt": 0.75 if perception.get("prey_node") and hunger > 0.2 else 0.0,
		"forage": hunger,
		"social": social,
		"shelter": shelter_score,
		"territory": territory,
		"follow_parent": follow_parent,
		"escort_offspring": escort_offspring,
		"return_young_home": return_young_home,
		"curiosity": traits.curiosity if traits else 0.0,
	}


func _set_target(node: Node3D, ai: Dictionary, entry: FaunaEntry, target_pos: Vector3, state: StringName) -> void:
	var adjusted_target := target_pos
	if entry.can_fly:
		var chunk_coord := SharedWorld.world_to_chunk(adjusted_target)
		var cs := GameConfig.chunk_size
		var local_x := clampf(adjusted_target.x - chunk_coord.x * cs, 0.0, cs - 0.01)
		var local_z := clampf(adjusted_target.z - chunk_coord.y * cs, 0.0, cs - 0.01)
		var ground_h := _sample_terrain_height(chunk_coord, local_x, local_z)
		adjusted_target.y = ground_h + randf_range(entry.flight_height_min, entry.flight_height_max)
		ai["flight_base"] = adjusted_target.y
	elif entry.aquatic:
		var chunk_coord := SharedWorld.world_to_chunk(adjusted_target)
		var cs := GameConfig.chunk_size
		var local_x := clampf(adjusted_target.x - chunk_coord.x * cs, 0.0, cs - 0.01)
		var local_z := clampf(adjusted_target.z - chunk_coord.y * cs, 0.0, cs - 0.01)
		var seafloor_h := _sample_terrain_height(chunk_coord, local_x, local_z)
		adjusted_target.y = seafloor_h + entry.swim_height
	else:
		ai["nav_path"] = _compute_nav_path(node.position, adjusted_target)
		ai["nav_index"] = 0
	ai["state"] = state
	ai["target_pos"] = adjusted_target


func _build_wander_target(ai: Dictionary, entry: FaunaEntry) -> Vector3:
	var angle := randf() * TAU
	var dist: float = randf() * entry.wander_radius
	var origin: Vector3 = _get_home_site_position(ai, ai.get("spawn_pos", Vector3.ZERO))
	return origin + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)


func _should_pick_new_wander_target(ai: Dictionary) -> bool:
	ai["timer"] = float(ai.get("timer", 0.0)) - _config.ai_tick_interval
	if float(ai["timer"]) > 0.0:
		return false
	ai["timer"] = maxf(float((ai.get("entry") as FaunaEntry).wander_interval), _config.ai_tick_interval)
	return true


func _get_same_species_group_data(node: Node3D, entry: FaunaEntry, radius: float) -> Dictionary:
	var center := Vector3.ZERO
	var count := 0
	var radius_sq := radius * radius
	var chunk_coord := SharedWorld.world_to_chunk(node.position)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c := Vector2i(chunk_coord.x + dx, chunk_coord.y + dz)
			if not _chunk_fauna.has(c):
				continue
			var instances: Array = _chunk_fauna[c]
			for other in instances:
				if not is_instance_valid(other) or other == node:
					continue
				var other_node: Node3D = other as Node3D
				if not other_node:
					continue
				var diff := other_node.position - node.position
				if diff.length_squared() > radius_sq:
					continue
				var other_ai: Dictionary = _fauna_ai.get(other_node.get_instance_id(), {})
				var other_entry: FaunaEntry = other_ai.get("entry") as FaunaEntry
				if not other_entry or other_entry.entry_name != entry.entry_name:
					continue
				center += other_node.position
				count += 1
	if count == 0:
		return {"count": 0, "center": node.position}
	return {"count": count, "center": center / float(count)}


func _remember_event(ai: Dictionary, event_type: StringName, world_pos: Vector3) -> void:
	var traits: FaunaTraits = ai.get("traits") as FaunaTraits
	if not traits:
		return
	traits.remember(event_type, world_pos, Time.get_ticks_msec() / 1000.0)


func _recall_recent(ai: Dictionary, event_type: StringName, max_age: float) -> Dictionary:
	var traits: FaunaTraits = ai.get("traits") as FaunaTraits
	if not traits:
		return {}
	var memory := traits.recall(event_type)
	if memory.is_empty():
		return {}
	var now_time := Time.get_ticks_msec() / 1000.0
	if now_time - float(memory.get("time", -INF)) > max_age:
		return {}
	return memory


func _broadcast_event(node: Node3D, entry: FaunaEntry, ai: Dictionary, event_type: StringName, world_pos: Vector3) -> void:
	var traits: FaunaTraits = ai.get("traits") as FaunaTraits
	if not traits or traits.communication_range <= 0.0:
		return
	var data := _get_same_species_group_data(node, entry, traits.communication_range)
	if int(data.get("count", 0)) == 0:
		return
	var chunk_coord := SharedWorld.world_to_chunk(node.position)
	var radius_sq := traits.communication_range * traits.communication_range
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c := Vector2i(chunk_coord.x + dx, chunk_coord.y + dz)
			if not _chunk_fauna.has(c):
				continue
			for other in _chunk_fauna[c]:
				if not is_instance_valid(other) or other == node:
					continue
				var other_node: Node3D = other as Node3D
				if not other_node or node.position.distance_squared_to(other_node.position) > radius_sq:
					continue
				var other_ai: Dictionary = _fauna_ai.get(other_node.get_instance_id(), {})
				var other_entry: FaunaEntry = other_ai.get("entry") as FaunaEntry
				if not other_entry or other_entry.entry_name != entry.entry_name:
					continue
				_remember_event(other_ai, event_type, world_pos)


func _get_parent_follow_target(ai: Dictionary) -> Vector3:
	var parent_id := int(ai.get("parent_id", 0))
	if parent_id == 0:
		return Vector3.INF
	var parent_node := _get_node_for_iid(parent_id)
	if is_instance_valid(parent_node):
		return parent_node.position
	return _get_home_site_position(ai, ai.get("spawn_pos", Vector3.ZERO))


func _get_patrol_target(ai: Dictionary, _entry: FaunaEntry, home_pos: Vector3) -> Vector3:
	var shelter_profile: Node = ai.get("shelter_profile") as Node
	var radius := 6.0
	if shelter_profile:
		radius = maxf(float(_node_prop(shelter_profile, &"home_range_radius", 12.0)) * 0.6, 4.0)
	var angle := randf() * TAU
	return home_pos + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)


func _get_node_for_iid(iid: int) -> Node3D:
	for coord in _chunk_fauna:
		for inst in _chunk_fauna[coord]:
			if is_instance_valid(inst) and inst.get_instance_id() == iid:
				return inst as Node3D
	return null


func _move_all_fauna(delta: float) -> void:
	for coord in _chunk_fauna:
		var instances: Array = _chunk_fauna[coord]
		for inst in instances:
			if not is_instance_valid(inst):
				continue
			var node: Node3D = inst as Node3D
			if not node:
				continue
			var iid := node.get_instance_id()
			if not _fauna_ai.has(iid):
				continue

			var ai: Dictionary = _fauna_ai[iid]
			var entry: FaunaEntry = ai["entry"] as FaunaEntry
			if not entry:
				continue

			# Determine movement target: nav waypoint or direct target
			var target: Vector3 = ai["target_pos"]
			var use_nav := not entry.can_fly and not entry.aquatic and ai.has("nav_path")
			if use_nav:
				var nav_path: PackedVector3Array = ai["nav_path"]
				var nav_idx: int = ai["nav_index"]
				if nav_idx < nav_path.size():
					target = nav_path[nav_idx]
					var dist_to_wp := Vector2(node.position.x - target.x, node.position.z - target.z).length()
					if dist_to_wp < 1.0:
						ai["nav_index"] = nav_idx + 1
						if ai["nav_index"] >= nav_path.size():
							ai.erase("nav_path")
							ai.erase("nav_index")
				else:
					ai.erase("nav_path")
					ai.erase("nav_index")

			var to_target := target - node.position
			if not entry.can_fly and not entry.aquatic:
				to_target.y = 0.0

			if to_target.length() < 0.5:
				ai["state"] = &"idle"
				if entry.can_fly:
					_animate_flying_fauna(node, ai, entry, delta)
				continue

			var speed: float = entry.move_speed
			if ai["state"] == &"flee":
				speed *= entry.flee_speed_multiplier
			elif ai["state"] == &"chase":
				speed *= entry.chase_speed_multiplier

			var move_dir := to_target.normalized()
			node.position += move_dir * speed * delta

			if entry.can_fly:
				_animate_flying_fauna(node, ai, entry, delta)
			elif entry.aquatic:
				_animate_aquatic_fauna(node, ai, entry, delta)
			else:
				var chunk_coord := SharedWorld.world_to_chunk(node.position)
				var cs := GameConfig.chunk_size
				var local_x := node.position.x - chunk_coord.x * cs
				var local_z := node.position.z - chunk_coord.y * cs
				local_x = clampf(local_x, 0.0, cs - 0.01)
				local_z = clampf(local_z, 0.0, cs - 0.01)
				var h := _sample_terrain_height(chunk_coord, local_x, local_z)
				if h > _sea_level:
					node.position.y = h

			# Apply flocking forces for applicable fauna
			_apply_flocking_forces(node, ai, entry, delta)

			# Face movement direction
			if move_dir.length_squared() > 0.01:
				node.rotation.y = atan2(move_dir.x, move_dir.z)
			if entry.can_fly or entry.aquatic:
				var pitch := clampf(-move_dir.y * 0.35, -0.35, 0.35)
				node.rotation.x = lerpf(node.rotation.x, pitch, 0.1)


# ── Cleanup ───────────────────────────────────────────────────────────────────

func _clear_chunk_fauna(coord: Vector2i) -> void:
	if not _chunk_fauna.has(coord):
		return
	var instances: Array = _chunk_fauna[coord]
	for inst in instances:
		if is_instance_valid(inst):
			var iid: int = inst.get_instance_id()
			if _fauna_ai.has(iid):
				var ai: Dictionary = _fauna_ai[iid]
				_leave_fauna_group(ai, iid)
				_release_home_site(ai)
				_release_territory_claim(ai)
			_fauna_ai.erase(iid)
			inst.queue_free()
	_total_fauna_count -= instances.size()
	SharedWorld.total_fauna_count = _total_fauna_count
	_chunk_fauna.erase(coord)
	SystemBus.fauna_chunk_cleared.emit(coord)


# ── Utilities ─────────────────────────────────────────────────────────────────

func _animate_flying_fauna(node: Node3D, ai: Dictionary, entry: FaunaEntry, delta: float) -> void:
	ai["flap_phase"] = float(ai.get("flap_phase", 0.0)) + delta * entry.flight_bob_speed
	var flap_phase: float = ai["flap_phase"]
	var flight_base: float = float(ai.get("flight_base", node.position.y))
	var bob := sin(flap_phase) * entry.flight_bob_amplitude
	node.position.y = lerpf(node.position.y, flight_base + bob, 0.12)
	var wing_angle := sin(flap_phase * 2.0) * 0.55
	var wing_l := node.get_node_or_null("WingL") as Node3D
	var wing_r := node.get_node_or_null("WingR") as Node3D
	if wing_l:
		wing_l.rotation.z = wing_angle
	if wing_r:
		wing_r.rotation.z = -wing_angle


func _animate_aquatic_fauna(node: Node3D, ai: Dictionary, _entry: FaunaEntry, delta: float) -> void:
	ai["swim_phase"] = float(ai.get("swim_phase", 0.0)) + delta * 1.5
	var swim_phase: float = ai["swim_phase"]
	var swim_base: float = float(ai.get("flight_base", node.position.y))
	# Gentle vertical bob
	var bob := sin(swim_phase) * 0.15
	node.position.y = lerpf(node.position.y, swim_base + bob, 0.08)
	# Subtle lateral sway
	node.rotation.z = lerpf(node.rotation.z, sin(swim_phase * 0.7) * 0.08, 0.05)


func _has_fauna_spacing(instances: Array[Node3D], world_x: float, world_z: float, min_spacing: float) -> bool:
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


func _find_terrain_params() -> void:
	_sea_level = SharedWorld.sea_level
	_height_scale = SharedWorld.height_scale


## Find the nearest prey fauna node within detection range for a predator
func _find_nearest_prey(predator_node: Node3D, predator_entry: FaunaEntry) -> Node3D:
	var best_dist := predator_entry.predator_detection_range
	var best_node: Node3D = null
	var pred_pos := predator_node.position
	var chunk_coord := SharedWorld.world_to_chunk(pred_pos)

	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c := Vector2i(chunk_coord.x + dx, chunk_coord.y + dz)
			if not _chunk_fauna.has(c):
				continue
			var instances: Array = _chunk_fauna[c]
			for other in instances:
				if not is_instance_valid(other) or other == predator_node:
					continue
				var other_node: Node3D = other as Node3D
				if not other_node:
					continue
				var other_iid := other_node.get_instance_id()
				if not _fauna_ai.has(other_iid):
					continue
				var other_ai: Dictionary = _fauna_ai[other_iid]
				var other_entry: FaunaEntry = other_ai.get("entry") as FaunaEntry
				if not other_entry:
					continue
				if other_entry.entry_name not in predator_entry.prey_names:
					continue
				var dist := pred_pos.distance_to(other_node.position)
				if dist < best_dist:
					best_dist = dist
					best_node = other_node
	return best_node


## Find the nearest predator fauna node that hunts this prey type
func _find_nearest_predator(prey_node: Node3D, prey_entry: FaunaEntry) -> Node3D:
	var best_dist := prey_entry.flee_distance
	var best_node: Node3D = null
	var prey_pos := prey_node.position
	var chunk_coord := SharedWorld.world_to_chunk(prey_pos)

	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c := Vector2i(chunk_coord.x + dx, chunk_coord.y + dz)
			if not _chunk_fauna.has(c):
				continue
			var instances: Array = _chunk_fauna[c]
			for other in instances:
				if not is_instance_valid(other) or other == prey_node:
					continue
				var other_node: Node3D = other as Node3D
				if not other_node:
					continue
				var other_iid := other_node.get_instance_id()
				if not _fauna_ai.has(other_iid):
					continue
				var other_ai: Dictionary = _fauna_ai[other_iid]
				var other_entry: FaunaEntry = other_ai.get("entry") as FaunaEntry
				if not other_entry or not other_entry.is_predator:
					continue
				if prey_entry.entry_name not in other_entry.prey_names:
					continue
				var dist := prey_pos.distance_to(other_node.position)
				if dist < best_dist:
					best_dist = dist
					best_node = other_node
	return best_node


## Compute a navigation path between two world positions via NavigationSystem
func _compute_nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if not _nav_system:
		return PackedVector3Array()
	var path := _nav_system.get_nav_path(from, to)
	if path.size() < 2:
		return PackedVector3Array()
	return path


## Apply flocking forces (separation, alignment, cohesion) for fauna with flocking=true
func _apply_flocking_forces(node: Node3D, _ai: Dictionary, entry: FaunaEntry, delta: float) -> void:
	if not entry.flocking:
		return

	var separation := Vector3.ZERO
	var alignment := Vector3.ZERO
	var cohesion := Vector3.ZERO
	var neighbor_count := 0
	var sep_radius := 3.0
	var flock_radius := 12.0

	# Find nearby same-type fauna
	var chunk_coord := SharedWorld.world_to_chunk(node.position)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c := Vector2i(chunk_coord.x + dx, chunk_coord.y + dz)
			if not _chunk_fauna.has(c):
				continue
			var instances: Array = _chunk_fauna[c]
			for other in instances:
				if not is_instance_valid(other) or other == node:
					continue
				var other_node: Node3D = other as Node3D
				if not other_node:
					continue
				var other_iid := other_node.get_instance_id()
				if not _fauna_ai.has(other_iid):
					continue
				var other_ai: Dictionary = _fauna_ai[other_iid]
				var other_entry: FaunaEntry = other_ai.get("entry") as FaunaEntry
				if not other_entry or other_entry.entry_name != entry.entry_name:
					continue

				var diff := node.position - other_node.position
				var dist := diff.length()
				if dist < 0.01 or dist > flock_radius:
					continue

				neighbor_count += 1
				cohesion += other_node.position

				# Separation: push away from very close neighbors
				if dist < sep_radius:
					separation += diff.normalized() / dist

				# Alignment: match velocity direction
				var other_target: Vector3 = other_ai.get("target_pos", other_node.position)
				var other_dir := (other_target - other_node.position).normalized()
				alignment += other_dir

	if neighbor_count == 0:
		return

	# Average and apply forces
	cohesion = (cohesion / float(neighbor_count) - node.position).normalized() * 0.3
	alignment = (alignment / float(neighbor_count)).normalized() * 0.2
	separation = separation.normalized() * 0.5

	var flock_force := (separation + alignment + cohesion) * entry.move_speed * delta
	node.position += flock_force


# ── Lifecycle System ─────────────────────────────────────────────────────────

func _update_fauna_lifecycle(delta: float) -> void:
	if not _config.lifecycle_enabled:
		return

	_lifecycle_timer += delta
	if _lifecycle_timer < _config.lifecycle_tick_interval:
		return
	var tick_dt := _lifecycle_timer
	_lifecycle_timer = 0.0

	var to_kill: Array[int] = []

	for iid: int in _fauna_ai.keys():
		var ai: Dictionary = _fauna_ai[iid]
		var entry: FaunaEntry = ai.get("entry") as FaunaEntry
		if not entry or not entry.lifecycle_enabled:
			continue

		var node: Node3D = null
		# Find the node for this AI state
		for coord in _chunk_fauna:
			for inst in _chunk_fauna[coord]:
				if is_instance_valid(inst) and inst.get_instance_id() == iid:
					node = inst as Node3D
					break
			if node:
				break
		if not is_instance_valid(node):
			to_kill.append(iid)
			continue

		# Age
		var age: float = ai["age"] + tick_dt
		ai["age"] = age

		# Life stage based on age
		var maturity := entry.maturity_age
		var max_age: float = ai["max_age"]
		var elder_age := max_age * _config.elder_age_fraction
		if age < maturity:
			ai["life_stage"] = &"juvenile"
		elif age < elder_age:
			ai["life_stage"] = &"adult"
		else:
			ai["life_stage"] = &"elder"

		if ai["life_stage"] != &"juvenile" and int(ai.get("parent_id", 0)) != 0:
			var former_parent_id := int(ai.get("parent_id", 0))
			if _fauna_ai.has(former_parent_id):
				var former_parent_ai: Dictionary = _fauna_ai[former_parent_id]
				var sibling_ids: Array = former_parent_ai.get("offspring_ids", [])
				sibling_ids.erase(iid)
				former_parent_ai["offspring_ids"] = sibling_ids
			ai["parent_id"] = 0

		# Visual scale based on life stage
		var base_scale: Vector3 = ai["base_scale"]
		match ai["life_stage"]:
			&"juvenile":
				node.scale = base_scale * lerpf(_config.juvenile_min_scale, 1.0, clampf(age / maturity, 0.0, 1.0))
			&"elder":
				node.scale = base_scale * _config.elder_scale

		# Natural death (old age)
		if _config.natural_death_enabled and age >= max_age:
			to_kill.append(iid)
			SystemBus.fauna_died.emit(node.global_position, entry.entry_name, &"age")
			continue

		# Hunger
		if _config.hunger_enabled and entry.hunger_rate > 0.0:
			ai["hunger"] = float(ai["hunger"]) + entry.hunger_rate * tick_dt

			# Starvation damage
			if float(ai["hunger"]) >= entry.hunger_death_threshold:
				to_kill.append(iid)
				SystemBus.fauna_died.emit(node.global_position, entry.entry_name, &"hunger")
				continue

			# Foraging: herbivores/omnivores seek flora when hungry
			if float(ai["hunger"]) > _config.foraging_hunger_threshold and (entry.diet == &"herbivore" or entry.diet == &"omnivore"):
				if ai["state"] != &"flee" and ai["state"] != &"chase":
					_try_forage(node, ai, entry)

		# Breeding cooldown
		ai["breed_cooldown"] = maxf(float(ai["breed_cooldown"]) - tick_dt, 0.0)

		# Nesting timer
		if ai["state"] == &"nesting":
			ai["nest_timer"] = float(ai["nest_timer"]) + tick_dt
			if float(ai["nest_timer"]) >= entry.nest_duration:
				_spawn_offspring(node, ai, entry)
				ai["state"] = &"idle"
				ai["nest_timer"] = 0.0
				ai["breed_cooldown"] = entry.breed_cooldown

		# Breeding attempt (adults only, not fleeing/chasing/nesting)
		if entry.can_breed and ai["life_stage"] == &"adult" and float(ai["breed_cooldown"]) <= 0.0:
			if ai["state"] != &"flee" and ai["state"] != &"chase" and ai["state"] != &"nesting":
				_try_breed(node, ai, entry)

	# Kill marked fauna
	for iid in to_kill:
		_kill_fauna_instance(iid)


func _kill_fauna_instance(iid: int) -> void:
	var ai: Dictionary = _fauna_ai.get(iid, {})
	if not ai.is_empty():
		_leave_fauna_group(ai, iid)
		_release_home_site(ai)
		_release_territory_claim(ai)
		var parent_id := int(ai.get("parent_id", 0))
		if parent_id != 0 and _fauna_ai.has(parent_id):
			var parent_ai: Dictionary = _fauna_ai[parent_id]
			var remaining: Array = parent_ai.get("offspring_ids", [])
			remaining.erase(iid)
			parent_ai["offspring_ids"] = remaining
	_fauna_ai.erase(iid)
	for coord: Vector2i in _chunk_fauna:
		var instances: Array = _chunk_fauna[coord]
		for i in instances.size():
			var inst = instances[i]
			if is_instance_valid(inst) and inst.get_instance_id() == iid:
				inst.queue_free()
				instances.remove_at(i)
				_total_fauna_count -= 1
				SharedWorld.total_fauna_count = _total_fauna_count
				return


func _try_forage(node: Node3D, ai: Dictionary, entry: FaunaEntry) -> void:
	# Look for nearby flora that matches food_flora_names
	# Simple approach: find closest flora node within wander radius
	var best_dist := entry.wander_radius
	var best_flora: Node3D = null

	var has_food_filter := not entry.food_flora_names.is_empty()
	for child in get_parent().get_children():
		if not child is BaseSystem:
			continue
		if child.get("system_name") != &"FloraSystem":
			continue
		# Found FloraSystem — scan its children for flora instances near us
		for flora_child in child.get_children():
			if not flora_child is Node3D:
				continue
			# Filter by food_flora_names if specified
			if has_food_filter and StringName(flora_child.name) not in entry.food_flora_names:
				continue
			var dist := node.global_position.distance_to(flora_child.global_position)
			if dist < best_dist:
				best_dist = dist
				best_flora = flora_child
		break

	if best_flora and best_dist < _config.eating_distance:
		# Close enough to eat
		ai["hunger"] = maxf(float(ai["hunger"]) - entry.food_value, 0.0)
		SystemBus.fauna_ate_flora.emit(best_flora.global_position, best_flora.name, entry.entry_name)
		SystemBus.fauna_visited_flora.emit(best_flora.global_position, entry.entry_name)
	elif best_flora:
		# Move toward food
		ai["state"] = &"foraging"
		ai["target_pos"] = best_flora.global_position
		if not entry.can_fly and not entry.aquatic:
			ai["nav_path"] = _compute_nav_path(node.position, best_flora.global_position)
			ai["nav_index"] = 0


func _try_breed(node: Node3D, ai: Dictionary, entry: FaunaEntry) -> void:
	if _total_fauna_count >= _config.max_total_fauna:
		return

	# Find a nearby same-species adult that can also breed
	var chunk_coord := SharedWorld.world_to_chunk(node.position)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c := Vector2i(chunk_coord.x + dx, chunk_coord.y + dz)
			if not _chunk_fauna.has(c):
				continue
			for other in _chunk_fauna[c]:
				if not is_instance_valid(other) or other == node:
					continue
				var other_node: Node3D = other as Node3D
				if not other_node:
					continue
				var other_iid := other_node.get_instance_id()
				if not _fauna_ai.has(other_iid):
					continue
				var other_ai: Dictionary = _fauna_ai[other_iid]
				var other_entry: FaunaEntry = other_ai.get("entry") as FaunaEntry
				if not other_entry or other_entry.entry_name != entry.entry_name:
					continue
				if other_ai["life_stage"] != &"adult":
					continue
				if float(other_ai["breed_cooldown"]) > 0.0:
					continue
				var dist := node.position.distance_to(other_node.position)
				if dist > entry.breed_partner_radius:
					continue

				# Found a mate — initiate breeding
				if entry.nesting_enabled:
					ai["state"] = &"nesting"
					ai["nest_timer"] = 0.0
				else:
					_spawn_offspring(node, ai, entry)
					ai["breed_cooldown"] = entry.breed_cooldown

				# Put mate on cooldown too
				other_ai["breed_cooldown"] = entry.breed_cooldown
				return


func _spawn_offspring(parent: Node3D, ai: Dictionary, entry: FaunaEntry) -> void:
	var count := randi_range(entry.offspring_count_min, entry.offspring_count_max)
	var spawned := 0

	for _i in count:
		if _total_fauna_count >= _config.max_total_fauna:
			break

		var r := _config.offspring_spawn_radius
		var offset := Vector3(randf_range(-r, r), 0.0, randf_range(-r, r))
		var spawn_pos := parent.global_position + offset

		# Sample terrain height
		var chunk_coord := SharedWorld.world_to_chunk(spawn_pos)
		var cs := GameConfig.chunk_size
		var local_x := clampf(spawn_pos.x - chunk_coord.x * cs, 0.0, cs - 0.01)
		var local_z := clampf(spawn_pos.z - chunk_coord.y * cs, 0.0, cs - 0.01)
		var h := _sample_terrain_height(chunk_coord, local_x, local_z)
		spawn_pos.y = h

		var instance := entry.create_instance()
		if not instance:
			continue

		instance.position = spawn_pos
		var s := randf_range(entry.scale_min, entry.scale_max) * _config.juvenile_scale_fraction
		instance.scale = Vector3(s, s, s)
		instance.rotation.y = randf() * TAU
		add_child(instance)

		# Register in chunk tracking
		if not _chunk_fauna.has(chunk_coord):
			_chunk_fauna[chunk_coord] = []
		_chunk_fauna[chunk_coord].append(instance)
		_total_fauna_count += 1
		SharedWorld.total_fauna_count = _total_fauna_count

		# Register AI state for offspring (starts as juvenile)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(spawn_pos)
		var variance := _config.max_age_variance
		var age_mult := 1.0 + rng.randf_range(-variance, variance)
		var traits: FaunaTraits = _get_traits(instance)
		var shelter_profile: Node = _get_shelter_profile(instance)
		var parenting_profile: Node = _get_parenting_profile(instance)
		var tribe_profile: Node = _get_tribe_profile(instance)
		var building_profile: Node = _get_building_profile(instance)
		var parent_home_site_id := ai.get("home_site_id", &"") as StringName
		var offspring_ai := {
			"self_id": instance.get_instance_id(),
			"entry": entry,
			"traits": traits,
			"shelter_profile": shelter_profile,
			"parenting_profile": parenting_profile,
			"tribe_profile": tribe_profile,
			"building_profile": building_profile,
			"group_id": &"",
			"group_role": &"",
			"tribe_id": ai.get("tribe_id", &""),
			"building_id": &"",
			"spawn_pos": spawn_pos,
			"target_pos": spawn_pos,
			"timer": rng.randf() * entry.wander_interval,
			"state": &"idle",
			"velocity": Vector3.ZERO,
			"flight_base": spawn_pos.y,
			"flap_phase": rng.randf() * TAU,
			"age": 0.0,
			"hunger": 0.0,
			"health": entry.health_max,
			"life_stage": &"juvenile",
			"max_age": entry.max_age * age_mult,
			"breed_cooldown": 0.0,
			"nest_timer": 0.0,
			"home_site_id": parent_home_site_id,
			"territory_id": &"",
			"parent_id": parent.get_instance_id(),
			"offspring_ids": [],
			"decision_scores": {},
			"last_threat_time": -INF,
			"base_scale": instance.scale / _config.juvenile_scale_fraction,
		}
		_fauna_ai[instance.get_instance_id()] = offspring_ai
		_assign_group_membership(instance, offspring_ai, entry)
		var child_ids: Array = ai.get("offspring_ids", [])
		child_ids.append(instance.get_instance_id())
		ai["offspring_ids"] = child_ids
		spawned += 1

	if spawned > 0:
		SystemBus.fauna_born.emit(parent.global_position, entry.entry_name, spawned)


func _shutdown() -> void:
	for coord in _chunk_fauna.keys():
		_clear_chunk_fauna(coord)
