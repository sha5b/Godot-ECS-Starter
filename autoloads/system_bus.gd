class_name SystemBusClass
extends Node

## Reactive signal bus for inter-system communication.
## Systems emit and listen to signals here — never reference each other directly.

# --- Terrain signals ---
signal terrain_chunk_ready(chunk_coord: Vector2i, heightmap: PackedFloat32Array)
signal terrain_chunk_unloaded(chunk_coord: Vector2i)

# --- Biome signals ---
signal biome_chunk_ready(chunk_coord: Vector2i, biome_map: PackedByteArray)

# --- Weather signals ---
signal weather_changed(state: Dictionary)
signal wind_changed(direction: Vector3, strength: float)
signal time_of_day_changed(normalized_time: float)

# --- Flora signals ---
signal flora_chunk_spawned(chunk_coord: Vector2i, instance_count: int)
signal flora_chunk_cleared(chunk_coord: Vector2i)

# --- Water signals ---
signal water_chunk_placed(chunk_coord: Vector2i)

# --- Navigation signals ---
signal navigation_chunk_ready(chunk_coord: Vector2i)

# --- Fauna signals ---
signal fauna_chunk_spawned(chunk_coord: Vector2i, instance_count: int)
signal fauna_chunk_cleared(chunk_coord: Vector2i)

# --- Ecosystem interaction signals ---
signal fauna_ate_flora(world_pos: Vector3, flora_name: StringName, fauna_name: StringName)
signal fauna_visited_flora(world_pos: Vector3, fauna_name: StringName)
signal flora_died(world_pos: Vector3, entry_name: StringName)
signal fauna_died(world_pos: Vector3, entry_name: StringName, cause: StringName)
signal fauna_born(world_pos: Vector3, entry_name: StringName, count: int)
signal population_pressure(system_name: StringName, count: int, max_count: int)
signal shelter_created(site_id: StringName, world_pos: Vector3, shelter_type: StringName, owner_name: StringName)
signal shelter_claimed(site_id: StringName, world_pos: Vector3, shelter_type: StringName, owner_name: StringName)
signal shelter_abandoned(site_id: StringName, world_pos: Vector3, shelter_type: StringName, owner_name: StringName)
signal territory_claimed(claim_id: StringName, center: Vector3, radius: float, owner_name: StringName)
signal territory_lost(claim_id: StringName, center: Vector3, owner_name: StringName)
signal fauna_group_created(group_id: StringName, center: Vector3, species_name: StringName, group_type: StringName)
signal fauna_group_updated(group_id: StringName, center: Vector3, member_count: int)
signal fauna_group_disbanded(group_id: StringName, species_name: StringName)
signal tribe_created(tribe_id: StringName, center: Vector3, member_species: StringName)
signal tribe_updated(tribe_id: StringName, center: Vector3, member_count: int)
signal building_created(building_id: StringName, world_pos: Vector3, building_type: StringName, owner_id: StringName)
signal building_abandoned(building_id: StringName, owner_id: StringName)

# --- River signals ---
signal river_chunk_ready(chunk_coord: Vector2i, river_count: int)

# --- Chunk lifecycle signals ---
signal chunk_load_requested(chunk_coord: Vector2i)
signal chunk_unload_requested(chunk_coord: Vector2i)

# --- ECS runtime signals ---
signal ecs_event(channel: StringName, payload: Dictionary)

# --- System lifecycle signals ---
signal system_registered(system_name: StringName)
signal system_unregistered(system_name: StringName)


func _ready() -> void:
	if GameConfig and GameConfig.debug_log_signals:
		_connect_debug_logging()


func _connect_debug_logging() -> void:
	terrain_chunk_ready.connect(func(coord, _h): print("[SystemBus] terrain_chunk_ready @ %s" % str(coord)))
	terrain_chunk_unloaded.connect(func(coord): print("[SystemBus] terrain_chunk_unloaded @ %s" % str(coord)))
	biome_chunk_ready.connect(func(coord, _b): print("[SystemBus] biome_chunk_ready @ %s" % str(coord)))
	weather_changed.connect(func(state): print("[SystemBus] weather_changed: %s" % str(state)))
	wind_changed.connect(func(dir, str_val): print("[SystemBus] wind_changed: dir=%s str=%.2f" % [str(dir), str_val]))
	time_of_day_changed.connect(func(t): print("[SystemBus] time_of_day: %.3f" % t))
	flora_chunk_spawned.connect(func(coord, count): print("[SystemBus] flora_chunk_spawned @ %s count=%d" % [str(coord), count]))
	flora_chunk_cleared.connect(func(coord): print("[SystemBus] flora_chunk_cleared @ %s" % str(coord)))
	water_chunk_placed.connect(func(coord): print("[SystemBus] water_chunk_placed @ %s" % str(coord)))
	navigation_chunk_ready.connect(func(coord): print("[SystemBus] navigation_chunk_ready @ %s" % str(coord)))
	fauna_chunk_spawned.connect(func(coord, count): print("[SystemBus] fauna_chunk_spawned @ %s count=%d" % [str(coord), count]))
	fauna_chunk_cleared.connect(func(coord): print("[SystemBus] fauna_chunk_cleared @ %s" % str(coord)))
	fauna_ate_flora.connect(func(world_pos, flora_name, fauna_name): print("[SystemBus] fauna_ate_flora @ %s flora=%s fauna=%s" % [str(world_pos), str(flora_name), str(fauna_name)]))
	fauna_visited_flora.connect(func(world_pos, fauna_name): print("[SystemBus] fauna_visited_flora @ %s fauna=%s" % [str(world_pos), str(fauna_name)]))
	flora_died.connect(func(world_pos, entry_name): print("[SystemBus] flora_died @ %s entry=%s" % [str(world_pos), str(entry_name)]))
	fauna_died.connect(func(world_pos, entry_name, cause): print("[SystemBus] fauna_died @ %s entry=%s cause=%s" % [str(world_pos), str(entry_name), str(cause)]))
	fauna_born.connect(func(world_pos, entry_name, count): print("[SystemBus] fauna_born @ %s entry=%s count=%d" % [str(world_pos), str(entry_name), count]))
	population_pressure.connect(func(system_name, count, max_count): print("[SystemBus] population_pressure system=%s count=%d max=%d" % [str(system_name), count, max_count]))
	shelter_created.connect(func(site_id, world_pos, shelter_type, owner_name): print("[SystemBus] shelter_created id=%s @ %s type=%s owner=%s" % [str(site_id), str(world_pos), str(shelter_type), str(owner_name)]))
	shelter_claimed.connect(func(site_id, world_pos, shelter_type, owner_name): print("[SystemBus] shelter_claimed id=%s @ %s type=%s owner=%s" % [str(site_id), str(world_pos), str(shelter_type), str(owner_name)]))
	shelter_abandoned.connect(func(site_id, world_pos, shelter_type, owner_name): print("[SystemBus] shelter_abandoned id=%s @ %s type=%s owner=%s" % [str(site_id), str(world_pos), str(shelter_type), str(owner_name)]))
	territory_claimed.connect(func(claim_id, center, radius, owner_name): print("[SystemBus] territory_claimed id=%s @ %s radius=%.2f owner=%s" % [str(claim_id), str(center), radius, str(owner_name)]))
	territory_lost.connect(func(claim_id, center, owner_name): print("[SystemBus] territory_lost id=%s @ %s owner=%s" % [str(claim_id), str(center), str(owner_name)]))
	fauna_group_created.connect(func(group_id, center, species_name, group_type): print("[SystemBus] fauna_group_created id=%s @ %s species=%s type=%s" % [str(group_id), str(center), str(species_name), str(group_type)]))
	fauna_group_updated.connect(func(group_id, center, member_count): print("[SystemBus] fauna_group_updated id=%s @ %s members=%d" % [str(group_id), str(center), member_count]))
	fauna_group_disbanded.connect(func(group_id, species_name): print("[SystemBus] fauna_group_disbanded id=%s species=%s" % [str(group_id), str(species_name)]))
	tribe_created.connect(func(tribe_id, center, member_species): print("[SystemBus] tribe_created id=%s @ %s species=%s" % [str(tribe_id), str(center), str(member_species)]))
	tribe_updated.connect(func(tribe_id, center, member_count): print("[SystemBus] tribe_updated id=%s @ %s members=%d" % [str(tribe_id), str(center), member_count]))
	building_created.connect(func(building_id, world_pos, building_type, owner_id): print("[SystemBus] building_created id=%s @ %s type=%s owner=%s" % [str(building_id), str(world_pos), str(building_type), str(owner_id)]))
	building_abandoned.connect(func(building_id, owner_id): print("[SystemBus] building_abandoned id=%s owner=%s" % [str(building_id), str(owner_id)]))
	river_chunk_ready.connect(func(coord, river_count): print("[SystemBus] river_chunk_ready @ %s count=%d" % [str(coord), river_count]))
	chunk_load_requested.connect(func(coord): print("[SystemBus] chunk_load_requested @ %s" % str(coord)))
	chunk_unload_requested.connect(func(coord): print("[SystemBus] chunk_unload_requested @ %s" % str(coord)))
	ecs_event.connect(func(channel, payload): print("[SystemBus] ecs_event: %s %s" % [str(channel), str(payload)]))
	system_registered.connect(func(sys_name): print("[SystemBus] system_registered: %s" % sys_name))
	system_unregistered.connect(func(sys_name): print("[SystemBus] system_unregistered: %s" % sys_name))
