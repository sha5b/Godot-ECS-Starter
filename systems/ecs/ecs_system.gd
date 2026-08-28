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

## Player-facing chemistry hook, bound in Project Settings > Input Map.
const ACTION_LIGHTNING := &"sim_lightning"

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
var predation := PredationSystem.new()
var flocking := FlockingSystem.new()

## Shared neighbour index. Predation and flocking ask the same spatial
## question, so they share one grid rebuilt on a coarse timer.
var actor_index := EcsActorIndex.new()

## The world's species — founding types from FaunaEntry content, plus every
## lineage that has split off since. Read by HUDs and content systems.
var species := SpeciesRegistry.new()

var _config: EcsConfig
var _stat_timer := 0

## World population bookkeeping: chunk coord -> spawned entity ids.
var _chunk_entities: Dictionary = {}
var _populate_rng := RandomNumberGenerator.new()
var _species_registered := false
var _spawnable_entries: Array[FaunaEntry] = []
const TERRAIN_SYSTEM_SCRIPT = preload("res://systems/terrain/terrain_system.gd")
const FAUNA_SYSTEM_SCRIPT = preload("res://systems/fauna/fauna_system.gd")
const BIOME_SYSTEM_SCRIPT = preload("res://systems/biome/biome_system.gd")
var _terrain_system: TerrainSystem = null
var _biome_system: BiomeSystem = null


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

	# The config flag was declared but never consulted — tiering always ran.
	if _config.tiering_enabled:
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
		breeding.seed_value = GameConfig.world_seed ^ 0xb2eed
		breeding.registry = species
		breeding.interbreed_distance = _config.breed_interbreed_distance
		scheduler.register(&"breeding", breeding.tick, EcsScheduler.Phase.SIM, 55)
	# Right after movement: velocity integration is planar, so actors need
	# re-seating on the surface before anything reads their position.
	scheduler.register(&"grounding", _ground_agents, EcsScheduler.Phase.SIM, 25)
	# The shared neighbour index is rebuilt before anything queries it.
	scheduler.register(&"actor_index", _tick_actor_index, EcsScheduler.Phase.EARLY, 20)
	if _config.predation_enabled:
		predation.registry = species
		predation.index = actor_index
		predation.hunt_range = _config.predation_hunt_range
		predation.flee_range = _config.predation_flee_range
		predation.bite_range = _config.predation_bite_range
		predation.bite_damage = _config.predation_bite_damage
		# After the AI: the AI commits to a target and closes on it, this
		# decides whether the bite lands.
		scheduler.register(&"predation", predation.tick, EcsScheduler.Phase.SIM, 35)
	if _config.flocking_enabled:
		flocking.index = actor_index
		# After the AI too, because flocking CORRECTS the AI's velocity
		# rather than replacing it — a herd that steers before its members
		# have decided anything cannot flee.
		scheduler.register(&"flocking", flocking.tick, EcsScheduler.Phase.SIM, 37)
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
		_prune_extinct_species()
		stats["species"] = species.stats()
		SharedWorld.ecs_stats = stats


## Fire lightning at a world position — the player-facing chemistry hook.
func strike(position: Vector3, power := 1.0) -> void:
	if chemistry != null and world != null:
		chemistry.strike(world, position, power)


func add_event_listener(watcher: Callable) -> void:
	event_watchers.append(watcher)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION_LIGHTNING):
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


## Register every authored fauna type as a founding species.
##
## FaunaSystem owns the content; the registry owns what happens to it after
## the world starts running. Called once, lazily, because FaunaSystem may not
## have discovered its children yet when EcsSystem initializes.
func _ensure_species_registered() -> void:
	if _species_registered:
		return
	var fauna := _find_system_by_type(FAUNA_SYSTEM_SCRIPT) as FaunaSystem
	if fauna == null:
		return
	var entries := fauna.get_entries()
	if entries.is_empty():
		return
	for entry in entries:
		if entry.genetics_enabled:
			species.register_founder(entry, GameConfig.world_seed)
			_spawnable_entries.append(entry)
	_species_registered = true
	if not _spawnable_entries.is_empty():
		print("[EcsSystem] Registered %d founding species: %s"
			% [species.count(), str(species.ids())])


## Pick a fauna type that belongs in this biome and has not filled its quota.
##
## `spawned` counts what this chunk has placed so far, so FaunaEntry's authored
## max_per_chunk is respected — otherwise one heavy-weighted species takes the
## whole chunk budget and a plain ends up holding nothing but rabbits.
##
## `water_depth` is metres of water over the ground, 0 on land. It selects for
## the medium: only aquatic types are offered a submerged spot and only land
## and flying types a dry one. Without it the aquatic types were competing for
## dry ground they can never occupy, and the ECS never sampled a wet spot at
## all — so fish and whales did not exist in the world.
func _pick_species_entry(biome_name: StringName, spawned: Dictionary,
		water_depth: float) -> FaunaEntry:
	var total := 0.0
	for entry in _spawnable_entries:
		if _entry_available(entry, biome_name, spawned, water_depth):
			total += entry.spawn_weight
	if total <= 0.0:
		return null
	var roll := _populate_rng.randf() * total
	var acc := 0.0
	for entry in _spawnable_entries:
		if not _entry_available(entry, biome_name, spawned, water_depth):
			continue
		acc += entry.spawn_weight
		if roll <= acc:
			return entry
	return null


func _entry_available(entry: FaunaEntry, biome_name: StringName,
		spawned: Dictionary, water_depth: float) -> bool:
	if not entry.is_allowed_in_biome(biome_name):
		return false
	if entry.aquatic:
		if water_depth < entry.min_water_depth or water_depth > entry.max_water_depth:
			return false
	elif water_depth > 0.0:
		return false
	return int(spawned.get(entry.entry_name, 0)) < entry.max_per_chunk


func _spawn_critters(chunk_data: ChunkData, origin: Vector3,
		cs: float, entities: Array[int]) -> void:
	var count := _config.critters_per_chunk
	if count <= 0:
		return
	_ensure_species_registered()
	## entry name -> how many this chunk has placed, against max_per_chunk.
	var spawned_here: Dictionary = {}
	var sea := SharedWorld.sea_level
	var min_height := sea + _config.populate_min_height_above_sea
	var coord := SharedWorld.world_to_chunk(origin + Vector3(cs * 0.5, 0, cs * 0.5))
	for i in count:
		var local := Vector2(_populate_rng.randf(), _populate_rng.randf()) * cs
		var height := _sample_terrain_height(coord, local.x, local.y)
		# Wet spots are candidates now. This filter used to reject every
		# position below sea level, so no aquatic species could ever spawn
		# however well its biome and depth range matched — fish and whales had
		# no living individuals anywhere in the world.
		var water_depth := maxf(sea - height, 0.0)
		if water_depth <= 0.0 and height < min_height:
			continue
		var spawn_pos := origin + Vector3(local.x, height, local.y)

		# Which species belongs here. Biome- and medium-gated, from authored
		# content — the ECS layer used to spawn one anonymous critter type
		# everywhere, with no idea that biomes or species existed.
		var entry: FaunaEntry = null
		if _config.use_fauna_species:
			entry = _pick_species_entry(_biome_name_at(spawn_pos), spawned_here,
				water_depth)
			if entry == null and not _spawnable_entries.is_empty():
				continue
			if entry != null:
				spawned_here[entry.entry_name] = \
					int(spawned_here.get(entry.entry_name, 0)) + 1
		elif water_depth > 0.0:
			# No authored content to choose from, so the generic critter is a
			# walker and has no business in the water.
			continue

		var entity := world.spawn()
		var transform := CTransform.new()
		transform.position = spawn_pos
		world.add_component(entity, transform)
		world.add_component(entity, CVelocity.new())
		var body := CBody.new()
		body.material = CBody.SurfaceMaterial.FLESH
		body.fuel = 3.0
		world.add_component(entity, body)
		world.add_component(entity, CElemental.new())
		var health := CHealth.new()
		var genome_comp: CGenome = null
		if entry != null:
			# An individual of a species: the species founder body plan with
			# this animal's own variation on it.
			genome_comp = _individual_genome(entry)
			var species_component := CSpecies.of(entry.entry_name, 0)
			# Record how far this individual sits from the species founder.
			# Speciation asks the parents for this, so a spawned population
			# that starts spread out can diverge, and one that starts uniform
			# has to drift first.
			var record := species.get_record(entry.entry_name)
			if record != null and record.founder != null:
				species_component.drift = genome_comp.genome.distance_to(record.founder)
			world.add_component(entity, species_component)
		elif _config.procedural_critters:
			# Genome-backed body: morphology drives stats, selection can act.
			genome_comp = CGenome.random(_populate_rng)
		if genome_comp != null:
			health.max_hp = genome_comp.derived_health_max
			health.hp = genome_comp.derived_health_max
		else:
			health.max_hp = 8.0
			health.hp = 8.0
		world.add_component(entity, health)
		var agent := CAgent.new()
		var record := species.get_record(entry.entry_name) if entry != null else null
		# A carnivore gets a brain with `hunt` in it. Diet is authored on the
		# FaunaEntry, so what an animal does follows from what it is.
		agent.brain = UtilityBrain.for_record(record)
		if genome_comp != null:
			agent.move_speed = genome_comp.derived_move_speed
		else:
			agent.move_speed = _populate_rng.randf_range(2.6, 3.8)
		world.add_component(entity, agent)
		# Which medium this animal lives in, from its own content. The
		# grounding pass reads it; without it a fish sits in the seafloor and
		# a bird walks.
		if entry != null:
			var locomotion := CLocomotion.from_entry(entry, _populate_rng)
			world.add_component(entity, locomotion)
			if locomotion.hover_height > 0.0:
				transform.position.y += locomotion.hover_height
		if record != null and record.flocks:
			world.add_component(entity, CGroup.from_record(record))
		if genome_comp != null:
			world.add_component(entity, genome_comp)
		if entry != null and not entry.use_procedural_body:
			view_sync.bind(entity, _make_authored_view(entry, transform.position))
		elif genome_comp != null:
			var critter_view := CritterView.new()
			critter_view.position = transform.position
			add_child(critter_view)
			view_sync.bind(entity, critter_view)
		else:
			view_sync.bind(entity, _make_simple_view(transform.position,
				Color(0.85, 0.7, 0.45), 0.8, &"capsule"))
		entities.append(entity)


## A view built from a content scene's own mesh children.
##
## The authored art, driven by the ECS. FaunaEntry keeps owning what a deer
## LOOKS like while the simulation owns what it does — which is the split that
## lets one population replace the two the project used to run.
func _make_authored_view(entry: FaunaEntry, position: Vector3) -> EntityView:
	var view := EntityView.new()
	view.position = position
	for child in entry.get_children():
		if child is VisualInstance3D:
			view.add_child(child.duplicate())
	_align_view(view, position)
	add_child(view)
	return view


## One animal of a species: the founder genome plus this individual's own
## drift. Variance is per-species, so a tightly-bred type stays uniform and a
## variable one produces obvious individuals from the first generation.
func _individual_genome(entry: FaunaEntry) -> CGenome:
	var record := species.get_record(entry.entry_name)
	if record == null or record.founder == null:
		return CGenome.random(_populate_rng)
	var genome := record.founder.cloned(_populate_rng)
	genome.generation = 0
	if entry.genome_variance > 0.0:
		genome.mutate(_populate_rng, entry.genome_variance)
	return CGenome.from_genome(genome)


## Biome name at a world position, or &"plains" with no biome system.
func _biome_name_at(position: Vector3) -> StringName:
	if _biome_system == null:
		_biome_system = _find_system_by_type(BIOME_SYSTEM_SCRIPT) as BiomeSystem
	if _biome_system == null:
		return &"plains"
	var index := _biome_system.get_biome_at_world(position.x, position.z,
		position.y, SharedWorld.sea_level, SharedWorld.height_scale)
	return _biome_system.get_biome_name(index)


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


## Glue walking actors to the generated surface.
##
## MovementSystem integrates CVelocity, and the AI only ever writes planar
## intent, so an actor keeps whatever Y it spawned with. As it wanders it
## therefore holds that altitude across the terrain underneath — visibly
## flying over the hills it walked away from and sinking into the valleys.
## Re-seating every tick is what makes a critter look like it is ON the ground.
##
## Runs at the entity's own tier cadence, so distant actors are re-seated
## less often, and skips actors over unloaded chunks (height 0 there would
## drop them through the world).
func _ground_agents(world: EcsWorld, _delta: float, frame: int) -> void:
	if _ground_cache == null:
		_ground_cache = world.query([&"CTransform", &"CAgent"])
	var sea := SharedWorld.sea_level
	for entity in world.frame_entities(_ground_cache, frame):
		var transform := world.get_component(entity, &"CTransform") as CTransform
		if transform == null:
			continue
		var height := _surface_height(transform.position.x, transform.position.z)
		if height == INF:
			continue
		var locomotion := world.get_component(entity, &"CLocomotion") as CLocomotion
		if locomotion == null or locomotion.medium == CLocomotion.Medium.LAND:
			transform.position.y = height
			# A walker that has waded out of its depth is turned back. The AI
			# writes planar intent with no idea the sea exists, so without this
			# deer and rabbits walk out to sea and keep going.
			if sea - height > _config.wade_depth:
				_steer_toward(world, entity, transform, true)
			continue
		if locomotion.medium == CLocomotion.Medium.AIR:
			# Fliers hold their cruising height over whatever is underneath,
			# and never below the water surface.
			transform.position.y = maxf(height, sea) + locomotion.hover_height
			continue
		_swim(world, entity, transform, height, sea, locomotion)


## Keep a swimmer between the seafloor and the surface, and in the water.
##
## Two things have to hold. It sits `hover_height` off the bottom but stays
## submerged, so a fish in shallows rides lower rather than breaching. And it
## is turned back where the water gets shallower than its authored minimum —
## the AI writes planar intent with no idea the sea has edges, so without this
## a shoal wanders up the beach and stands on the sand.
func _swim(world: EcsWorld, entity: int, transform: CTransform, ground: float,
		sea: float, locomotion: CLocomotion) -> void:
	if sea - ground < locomotion.min_water_depth:
		_steer_toward(world, entity, transform, false)
	# Submerged, and off the bottom by as much as the water allows: a fish in
	# the shallows rides lower rather than breaching.
	var ceiling := sea - 0.25
	transform.position.y = maxf(minf(ground + locomotion.hover_height, ceiling), ground)


## Turn an actor along the seabed slope, keeping its speed.
##
## The surface normal of a height field is (-dh/dx, 1, -dh/dz), so its
## horizontal part points the way the ground FALLS. Uphill is therefore its
## negation — which is the direction out of the water for a walker, and into it
## for a swimmer.
func _steer_toward(world: EcsWorld, entity: int, transform: CTransform,
		uphill: bool) -> void:
	var velocity := world.get_component(entity, &"CVelocity") as CVelocity
	if velocity == null:
		return
	var normal := _ground_normal(transform.position.x, transform.position.z)
	var slope := Vector2(normal.x, normal.z)
	if uphill:
		slope = -slope
	var speed := velocity.linear.length()
	if slope.length() > 0.001 and speed > 0.001:
		var wanted := slope.normalized() * speed
		velocity.linear = Vector3(wanted.x, 0.0, wanted.y)
	else:
		velocity.linear = -velocity.linear


var _ground_cache: EcsWorld.QueryCache = null


## The terrain system, or null when the ECS runs standalone (body lab,
## headless tests) with no world generation under it.
func _terrain() -> TerrainSystem:
	if _terrain_system == null:
		_terrain_system = _find_system_by_type(TERRAIN_SYSTEM_SCRIPT) as TerrainSystem
	return _terrain_system


## Authoritative carved-surface height, or INF where nothing is loaded.
func _surface_height(wx: float, wz: float) -> float:
	var terrain := _terrain()
	return terrain.sample_surface_height(wx, wz) if terrain else INF


## Terrain surface normal at a world position (UP when unavailable).
func _ground_normal(wx: float, wz: float) -> Vector3:
	var terrain := _terrain()
	return terrain.sample_surface_normal(wx, wz, 1.0) if terrain else Vector3.UP


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


## Rebuild the shared neighbour index on its own timer.
## Drop lineages with no living members.
##
## Speciation mints a record per split, each holding a full genome, and
## nothing removed them — so a world left running accumulated species records
## for as long as it was open. Runs on the stats timer, which is already the
## coarse "walk the whole world" cadence.
func _prune_extinct_species() -> void:
	if _species_cache == null:
		_species_cache = world.query([&"CSpecies"])
	var living: Dictionary = {}
	for entity in world.all_entities_scratch(_species_cache):
		var component := world.get_component(entity, &"CSpecies") as CSpecies
		if component != null:
			living[component.species_id] = true
	species.prune_extinct(living)


var _species_cache: EcsWorld.QueryCache = null


func _tick_actor_index(index_world: EcsWorld, delta: float, _frame: int) -> void:
	actor_index.update(index_world, delta)


func _shutdown() -> void:
	_chunk_entities.clear()
	world = null
	scheduler = EcsScheduler.new()
