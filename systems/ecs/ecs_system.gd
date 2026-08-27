class_name EcsSystem
extends BaseSystem

## Drop-in ECS runtime host, following the system-scene doctrine.
##
## Owns the EcsWorld and its scheduler, registers the built-in systems in
## BotW-inspired phases:
##
##   EARLY  TierSystem      — assign processing profiles by distance
##   SIM    Movement        — integrate velocity
##   SIM    UtilityAI       — sense / decide / act
##   SIM    ChemistrySystem — elements × materials, propagation
##   SIM    VitalitySystem  — deaths and expired lifetimes
##   VIEW   ViewSync        — mirror data onto scene nodes
##
## Bridges both ways: SharedWorld weather feeds the chemistry environment,
## and ECS events are forwarded to SystemBus as `ecs_event` plus any
## registered event watchers (the visual FX use those).

## Callables invoked (channel, payload) for every published ECS event
## before it is forwarded to SystemBus.
var event_watchers: Array[Callable] = []

var world: EcsWorld
var scheduler := EcsScheduler.new()
var chemistry: ChemistrySystem
var utility_ai := UtilityAISystem.new()
var movement := MovementSystem.new()
var tiers := TierSystem.new()
var vitality := VitalitySystem.new()
var view_sync := ViewSyncSystem.new()
var breeding := BreedingSystem.new()

var _config: EcsConfig
var _stat_timer := 0

## World population bookkeeping: chunk coord -> spawned entity ids.
var _chunk_entities: Dictionary = {}
var _populate_rng := RandomNumberGenerator.new()
var _terrain_for_normals: BaseSystem = null


func _initialize() -> void:
	_config = _find_child_of_type(EcsConfig) as EcsConfig
	if _config == null:
		push_warning("[EcsSystem] No EcsConfig child — using defaults")
		_config = EcsConfig.new()
		add_child(_config)
	if _config.chemistry_rules == null:
		_config.chemistry_rules = ChemistryRules.new()

	world = EcsWorld.new()
	chemistry = ChemistrySystem.new(_config.chemistry_rules)
	_populate_rng.seed = GameConfig.world_seed ^ 0x5eed
	SystemBus.terrain_chunk_ready.connect(_on_terrain_chunk_ready)
	SystemBus.chunk_unload_requested.connect(_on_chunk_unload)

	tiers.near_distance = _config.tier_near_distance
	tiers.mid_distance = _config.tier_mid_distance
	tiers.far_distance = _config.tier_far_distance
	tiers.recheck_frames = _config.tier_recheck_frames
	movement.bounds_radius = _config.movement_bounds_radius
	utility_ai.sensor_range = _config.ai_sensor_range
	utility_ai.threat_range = _config.ai_threat_range

	scheduler.register(&"tiering", tiers.tick, EcsScheduler.Phase.EARLY, 10)
	if _config.movement_enabled:
		scheduler.register(&"movement", movement.tick, EcsScheduler.Phase.SIM, 20)
	if _config.ai_enabled:
		scheduler.register(&"ai", utility_ai.tick, EcsScheduler.Phase.SIM, 30)
	if _config.chemistry_enabled:
		scheduler.register(&"chemistry", chemistry.tick, EcsScheduler.Phase.SIM, 40)
	if _config.vitality_enabled:
		scheduler.register(&"vitality", vitality.tick, EcsScheduler.Phase.SIM, 50)
	if _config.breeding_enabled:
		breeding.partner_radius = _config.breed_partner_radius
		breeding.breed_cooldown = _config.breed_cooldown
		breeding.max_population = _config.breed_max_population
		breeding.mutation_rate = _config.critter_mutation_rate
		scheduler.register(&"breeding", breeding.tick, EcsScheduler.Phase.SIM, 55)
	if _config.view_sync_enabled:
		scheduler.register(&"view_sync", view_sync.tick, EcsScheduler.Phase.VIEW, 70)


## Self-tick when placed standalone: under a WorldECS the world root drives
## system_process in priority order, but any other parent means this system
## must run itself (drop-in doctrine).
func _process(delta: float) -> void:
	if not (get_parent() is WorldECS):
		system_process(delta)


func system_process(delta: float) -> void:
	if world == null:
		return

	# Bridge SharedWorld -> ECS environment.
	world.focus_position = SharedWorld.camera_world_pos
	chemistry.env["rain_intensity"] = SharedWorld.rain_intensity
	chemistry.env["wind_direction"] = SharedWorld.wind_direction
	chemistry.env["wind_strength"] = SharedWorld.wind_strength

	scheduler.tick(world, delta)
	_forward_events()

	_stat_timer += 1
	if _stat_timer >= 15:
		_stat_timer = 0
		world.refresh_stats()
		var stats := world.stats.duplicate(true)
		stats["system_times_us"] = scheduler.system_times.duplicate()
		SharedWorld.ecs_stats = stats


## Fire lightning at a world position — the player-facing chemistry hook.
func strike(position: Vector3, power := 1.0) -> void:
	if chemistry != null and world != null:
		chemistry.strike(world, position, power)


func add_event_listener(watcher: Callable) -> void:
	event_watchers.append(watcher)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).physical_keycode == KEY_L:
			strike(SharedWorld.camera_world_pos + Vector3(0, 0.5, 0), 1.2)


# ── World population ─────────────────────────────────────────────────────────
#
# The ECS layer mirrors the generated world: invisible chemistry grass that
# the foliage renderer reacts to, plus a few visible foraging critters.
# Everything despawns with its chunk.


func _on_terrain_chunk_ready(coord: Vector2i, _heightmap: PackedFloat32Array) -> void:
	if not (_config != null and _config.populate_world) or world == null:
		return
	if _chunk_entities.has(coord):
		return
	var chunk_mgr := _find_system_by_type(ChunkManager) as ChunkManager
	if chunk_mgr == null:
		return
	var chunk_data: ChunkData = chunk_mgr.get_chunk(coord)
	if chunk_data == null or chunk_data.heightmap.is_empty():
		return

	var cs := GameConfig.chunk_size
	var world_center := SharedWorld.chunk_to_world(coord)
	var origin := Vector3(world_center.x - cs * 0.5, 0.0, world_center.z - cs * 0.5)
	var entities: Array[int] = []
	_spawn_chemistry_grass(chunk_data, origin, cs, entities)
	_spawn_critters(chunk_data, origin, cs, entities)
	_spawn_berries(chunk_data, origin, cs, entities)
	_spawn_campfire(chunk_data, origin, cs, entities)
	_chunk_entities[coord] = entities


func _on_chunk_unload(coord: Vector2i) -> void:
	if not _chunk_entities.has(coord):
		return
	for entity in _chunk_entities[coord]:
		world.commands.despawn(entity)
	_chunk_entities.erase(coord)


func _spawn_chemistry_grass(chunk_data: ChunkData, origin: Vector3,
		cs: float, entities: Array[int]) -> void:
	var count := _config.chemistry_grass_per_chunk
	if count <= 0:
		return
	var min_height := SharedWorld.sea_level + _config.populate_min_height_above_sea
	var coord := SharedWorld.world_to_chunk(origin + Vector3(cs * 0.5, 0, cs * 0.5))
	for i in count:
		var local := Vector2(_populate_rng.randf(), _populate_rng.randf()) * cs
		# Bilinear surface sampling — nearest-grid reads slope the wrong way
		# and planted actors visibly float or bury on steep terrain.
		var height := _sample_terrain_height(coord, local.x, local.y)
		if height < min_height:
			continue
		var entity := world.spawn()
		var transform := CTransform.new()
		transform.position = origin + Vector3(local.x, height, local.y)
		world.add_component(entity, transform)
		var body := CBody.new()
		body.material = CBody.SurfaceMaterial.GRASS
		body.fuel = _populate_rng.randf_range(1.5, 3.0)
		world.add_component(entity, body)
		world.add_component(entity, CElemental.new())
		entities.append(entity)


func _spawn_critters(chunk_data: ChunkData, origin: Vector3,
		cs: float, entities: Array[int]) -> void:
	var count := _config.critters_per_chunk
	if count <= 0:
		return
	var min_height := SharedWorld.sea_level + _config.populate_min_height_above_sea
	var coord := SharedWorld.world_to_chunk(origin + Vector3(cs * 0.5, 0, cs * 0.5))
	for i in count:
		var local := Vector2(_populate_rng.randf(), _populate_rng.randf()) * cs
		var height := _sample_terrain_height(coord, local.x, local.y)
		if height < min_height:
			continue
		var entity := world.spawn()
		var transform := CTransform.new()
		transform.position = origin + Vector3(local.x, height, local.y)
		world.add_component(entity, transform)
		world.add_component(entity, CVelocity.new())
		var body := CBody.new()
		body.material = CBody.SurfaceMaterial.FLESH
		body.fuel = 3.0
		world.add_component(entity, body)
		world.add_component(entity, CElemental.new())
		var health := CHealth.new()
		var genome_comp: CGenome = null
		if _config.procedural_critters:
			# Genome-backed body: morphology drives stats, selection can act.
			genome_comp = CGenome.random(_populate_rng)
			health.max_hp = genome_comp.derived_health_max
			health.hp = genome_comp.derived_health_max
		else:
			health.max_hp = 8.0
			health.hp = 8.0
		world.add_component(entity, health)
		var agent := CAgent.new()
		agent.brain = UtilityBrain.critter_brain()
		if genome_comp != null:
			agent.move_speed = genome_comp.derived_move_speed
		else:
			agent.move_speed = _populate_rng.randf_range(2.6, 3.8)
		world.add_component(entity, agent)
		if genome_comp != null:
			world.add_component(entity, genome_comp)
			var critter_view := CritterView.new()
			critter_view.position = transform.position
			add_child(critter_view)
			view_sync.bind(entity, critter_view)
		else:
			view_sync.bind(entity, _make_simple_view(transform.position,
				Color(0.85, 0.7, 0.45), 0.8, &"capsule"))
		entities.append(entity)


## Edible berry bushes — the seek_food loop needs targets.
func _spawn_berries(chunk_data: ChunkData, origin: Vector3,
		cs: float, entities: Array[int]) -> void:
	var count := _config.berries_per_chunk
	if count <= 0:
		return
	var hres := chunk_data.get_resolution()
	var min_height := SharedWorld.sea_level + _config.populate_min_height_above_sea
	for i in count:
		var local := Vector2(_populate_rng.randf(), _populate_rng.randf()) * cs
		var gx := clampi(int(local.x / cs * (hres - 1)), 0, hres - 1)
		var gz := clampi(int(local.y / cs * (hres - 1)), 0, hres - 1)
		var height := chunk_data.sample_height(gx, gz)
		if height < min_height:
			continue
		var entity := world.spawn()
		var transform := CTransform.new()
		transform.position = origin + Vector3(local.x, height, local.y)
		world.add_component(entity, transform)
		var body := CBody.new()
		body.material = CBody.SurfaceMaterial.GRASS
		body.fuel = 0.6
		world.add_component(entity, body)
		world.add_component(entity, CElemental.new())
		var food := CFood.new()
		food.nutrition = 0.55
		world.add_component(entity, food)
		view_sync.bind(entity, _make_simple_view(transform.position,
			Color(0.82, 0.22, 0.3), 0.45, &"sphere"))
		entities.append(entity)


## An occasional lit campfire: a permanent fire source and warm landmark.
func _spawn_campfire(chunk_data: ChunkData, origin: Vector3,
		cs: float, entities: Array[int]) -> void:
	if _populate_rng.randf() > _config.campfire_chance:
		return
	var hres := chunk_data.get_resolution()
	var min_height := SharedWorld.sea_level + _config.populate_min_height_above_sea
	for attempt in 8:
		var local := Vector2(_populate_rng.randf(), _populate_rng.randf()) * cs
		var gx := clampi(int(local.x / cs * (hres - 1)), 0, hres - 1)
		var gz := clampi(int(local.y / cs * (hres - 1)), 0, hres - 1)
		var height := chunk_data.sample_height(gx, gz)
		if height < min_height:
			continue
		var entity := world.spawn()
		var transform := CTransform.new()
		transform.position = origin + Vector3(local.x, height, local.y)
		world.add_component(entity, transform)
		var body := CBody.new()
		body.material = CBody.SurfaceMaterial.STONE
		world.add_component(entity, body)
		var elemental := CElemental.new()
		elemental.constant_elements[ChemistryDefs.Element.FIRE] = 1.0
		world.add_component(entity, elemental)
		var view := _make_campfire_view(transform.position)
		_align_view(view, transform.position)
		view_sync.bind(entity, view)
		entities.append(entity)
		return


## Visible campfire: stone ring view plus an emissive flame and warm light.
func _make_campfire_view(position: Vector3) -> EntityView:
	var view := EntityView.new()
	view.position = position - Vector3(0.0, 0.08, 0.0)
	view.tint = Color(0.42, 0.27, 0.16)
	var ring := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.75
	cylinder.bottom_radius = 0.85
	cylinder.height = 0.35
	ring.mesh = cylinder
	ring.position.y = 0.17
	view.add_child(ring)
	var flame := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.1
	cone.bottom_radius = 0.45
	cone.height = 1.0
	flame.mesh = cone
	var material := StandardMaterial3D.new()
	material.emission_enabled = true
	material.emission = Color(1.0, 0.55, 0.15)
	material.emission_energy_multiplier = 2.2
	material.albedo_color = Color(1.0, 0.6, 0.2)
	flame.material_override = material
	flame.position.y = 0.85
	view.add_child(flame)
	var light := OmniLight3D.new()
	light.omni_range = 9.0
	light.light_color = Color(1.0, 0.6, 0.3)
	light.light_energy = 2.0
	light.position.y = 1.4
	view.add_child(light)
	add_child(view)
	return view


## Terrain surface normal at a world position (UP when unavailable).
func _ground_normal(wx: float, wz: float) -> Vector3:
	if _terrain_for_normals == null:
		_terrain_for_normals = _find_system_by_type(
			preload("res://systems/terrain/terrain_system.gd")) as BaseSystem
	if _terrain_for_normals != null \
			and _terrain_for_normals.has_method("_sample_loaded_surface_normal"):
		return _terrain_for_normals._sample_loaded_surface_normal(wx, wz, 1.0)
	return Vector3.UP


## Tilt a prop view onto the terrain slope so it doesn't float on hills.
func _align_view(view: EntityView, position: Vector3) -> void:
	var normal := _ground_normal(position.x, position.z)
	if normal.dot(Vector3.UP) > 0.999:
		return
	view.quaternion = Quaternion(Vector3.UP, normal)


## Generic small prop view (sphere / box / capsule) for world content.
func _make_simple_view(position: Vector3, tint: Color, size: float,
		shape: StringName) -> EntityView:
	var view := EntityView.new()
	view.position = position - Vector3(0.0, 0.05, 0.0)
	view.tint = tint
	_align_view(view, position)
	var mesh := MeshInstance3D.new()
	match shape:
		&"sphere":
			var sphere := SphereMesh.new()
			sphere.radius = size * 0.5
			sphere.height = size
			mesh.mesh = sphere
		&"capsule":
			var capsule := CapsuleMesh.new()
			capsule.radius = size * 0.5
			capsule.height = size
			mesh.mesh = capsule
		_:
			var box := BoxMesh.new()
			box.size = Vector3.ONE * size
			mesh.mesh = box
	mesh.position.y = size * 0.5
	view.add_child(mesh)
	add_child(view)
	return view




func _forward_events() -> void:
	for channel in world.pending_channels():
		for payload in world.drain(channel):
			for watcher in event_watchers:
				watcher.call(channel, payload)
			SystemBus.ecs_event.emit(channel, payload)


func _shutdown() -> void:
	_chunk_entities.clear()
	world = null
	scheduler = EcsScheduler.new()
