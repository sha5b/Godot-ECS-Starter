extends EcsTestCase

## Predation and flocking — the two behaviours that used to exist only in
## FaunaSystem's node-based simulation, now running on the ECS.


func _entry(entry_name: StringName, diet: StringName = &"herbivore",
		prey: Array[StringName] = [] as Array[StringName]) -> FaunaEntry:
	var entry := FaunaEntry.new()
	entry.entry_name = entry_name
	entry.genome_archetype = "grazer"
	entry.genome_variance = 0.2
	entry.speciation_distance = 0.34
	entry.diet = diet
	entry.prey_names = prey
	return entry


func _world_with(entries: Array) -> Array:
	var registry := SpeciesRegistry.new()
	for entry in entries:
		registry.register_founder(entry, 42)
	return [EcsWorld.new(), registry]


func _spawn(world: EcsWorld, registry: SpeciesRegistry, entry: FaunaEntry,
		position: Vector3, hunger := 0.9) -> int:
	var record := registry.get_record(entry.entry_name)
	var entity := world.spawn()
	var transform := CTransform.new()
	transform.position = position
	var agent := CAgent.new()
	agent.brain = UtilityBrain.for_record(record)
	agent.move_speed = 4.0
	agent.hunger = hunger
	var health := CHealth.new()
	health.max_hp = 10.0
	health.hp = 10.0
	world.add_component(entity, transform)
	world.add_component(entity, CVelocity.new())
	world.add_component(entity, agent)
	world.add_component(entity, health)
	world.add_component(entity, CSpecies.of(entry.entry_name, 0))
	if record != null and record.flocks:
		world.add_component(entity, CGroup.from_record(record))
	return entity


func _index_for(world: EcsWorld) -> EcsActorIndex:
	var index := EcsActorIndex.new()
	index.refresh_interval = 0.0
	index.update(world, 1.0)
	return index


func _predation(registry: SpeciesRegistry, index: EcsActorIndex) -> PredationSystem:
	var predation := PredationSystem.new()
	predation.registry = registry
	predation.index = index
	return predation


# ── Sensing ─────────────────────────────────────────────────────────────────


func test_predator_senses_prey_and_prey_senses_predator() -> void:
	var wolf_entry := _entry(&"wolf", &"carnivore", [&"deer"] as Array[StringName])
	var deer_entry := _entry(&"deer")
	var pair := _world_with([wolf_entry, deer_entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	var wolf := _spawn(world, registry, wolf_entry, Vector3.ZERO)
	var deer := _spawn(world, registry, deer_entry, Vector3(5, 0, 0))

	_predation(registry, _index_for(world)).tick(world, 0.1, 0)

	var wolf_agent := world.get_component(wolf, &"CAgent") as CAgent
	var deer_agent := world.get_component(deer, &"CAgent") as CAgent
	assert_equal(int(wolf_agent.blackboard.get("prey_entity", 0)), deer,
		"the hunter must find the animal it hunts")
	assert_true(float(wolf_agent.blackboard.get(
		Consideration.SensorInput.PREY_PROXIMITY, 0.0)) > 0.5,
		"prey five metres away should read as close")
	assert_true(float(deer_agent.blackboard.get(
		Consideration.SensorInput.PREDATOR_PROXIMITY, 0.0)) > 0.5,
		"prey must sense the hunter, or it never gets to run")
	assert_equal(int(deer_agent.blackboard.get("prey_entity", 0)), 0,
		"a herbivore hunts nothing")


func test_predator_ignores_animals_it_does_not_hunt() -> void:
	var wolf_entry := _entry(&"wolf", &"carnivore", [&"deer"] as Array[StringName])
	var rabbit_entry := _entry(&"rabbit")
	var pair := _world_with([wolf_entry, rabbit_entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	var wolf := _spawn(world, registry, wolf_entry, Vector3.ZERO)
	_spawn(world, registry, rabbit_entry, Vector3(3, 0, 0))

	_predation(registry, _index_for(world)).tick(world, 0.1, 0)
	var agent := world.get_component(wolf, &"CAgent") as CAgent
	assert_equal(int(agent.blackboard.get("prey_entity", 0)), 0,
		"a rabbit is not on this wolf's prey list")


func test_prey_lists_survive_speciation() -> void:
	var wolf_entry := _entry(&"wolf", &"carnivore", [&"deer"] as Array[StringName])
	var deer_entry := _entry(&"deer")
	var pair := _world_with([wolf_entry, deer_entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	# The deer lineage splits, and the offshoot must still be prey.
	var deer_record := registry.get_record(&"deer")
	var offshoot := registry.speciate(deer_record,
		CritterGenome.new(deer_record.founder), 5)

	var wolf := _spawn(world, registry, wolf_entry, Vector3.ZERO)
	var descendant := _spawn(world, registry, deer_entry, Vector3(4, 0, 0))
	var species := world.get_component(descendant, &"CSpecies") as CSpecies
	species.species_id = offshoot.id

	_predation(registry, _index_for(world)).tick(world, 0.1, 0)
	var agent := world.get_component(wolf, &"CAgent") as CAgent
	assert_equal(int(agent.blackboard.get("prey_entity", 0)), descendant,
		"prey lists key off the root entry, so a split lineage is still prey")


# ── Attack resolution ───────────────────────────────────────────────────────


func test_bite_damages_prey_only_within_reach() -> void:
	var wolf_entry := _entry(&"wolf", &"carnivore", [&"deer"] as Array[StringName])
	var deer_entry := _entry(&"deer")
	var pair := _world_with([wolf_entry, deer_entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	var wolf := _spawn(world, registry, wolf_entry, Vector3.ZERO)
	var deer := _spawn(world, registry, deer_entry, Vector3(8, 0, 0))
	var wolf_agent := world.get_component(wolf, &"CAgent") as CAgent
	var health := world.get_component(deer, &"CHealth") as CHealth
	wolf_agent.blackboard["hunt_target"] = deer

	var predation := _predation(registry, _index_for(world))
	predation.tick(world, 0.1, 0)
	assert_almost(health.hp, 10.0, 0.001,
		"a bite at eight metres must not land")

	var deer_transform := world.get_component(deer, &"CTransform") as CTransform
	deer_transform.position = Vector3(1.0, 0, 0)
	wolf_agent.blackboard["hunt_target"] = deer
	predation.tick(world, 0.1, 1)
	assert_true(health.hp < 10.0, "a bite in reach must land")


func test_bite_respects_its_cooldown() -> void:
	var wolf_entry := _entry(&"wolf", &"carnivore", [&"deer"] as Array[StringName])
	var deer_entry := _entry(&"deer")
	var pair := _world_with([wolf_entry, deer_entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	var wolf := _spawn(world, registry, wolf_entry, Vector3.ZERO)
	var deer := _spawn(world, registry, deer_entry, Vector3(1, 0, 0))
	var wolf_agent := world.get_component(wolf, &"CAgent") as CAgent
	var health := world.get_component(deer, &"CHealth") as CHealth

	var predation := _predation(registry, _index_for(world))
	wolf_agent.blackboard["hunt_target"] = deer
	predation.tick(world, 0.1, 0)
	var after_one := health.hp
	assert_true(after_one < 10.0, "test setup: the first bite must land")

	# No cooldown tick in between, so the second bite is refused.
	wolf_agent.blackboard["hunt_target"] = deer
	predation.tick(world, 0.1, 1)
	assert_almost(health.hp, after_one, 0.001,
		"a hunter must not chew through prey every frame")


func test_kill_publishes_an_event_and_feeds_the_hunter() -> void:
	var wolf_entry := _entry(&"wolf", &"carnivore", [&"deer"] as Array[StringName])
	var deer_entry := _entry(&"deer")
	var pair := _world_with([wolf_entry, deer_entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	var wolf := _spawn(world, registry, wolf_entry, Vector3.ZERO)
	var deer := _spawn(world, registry, deer_entry, Vector3(1, 0, 0))
	var wolf_agent := world.get_component(wolf, &"CAgent") as CAgent
	var health := world.get_component(deer, &"CHealth") as CHealth
	health.hp = 0.5

	wolf_agent.blackboard["hunt_target"] = deer
	_predation(registry, _index_for(world)).tick(world, 0.1, 0)

	assert_true(health.dead, "the killing bite must land")
	var events := world.drain(PredationSystem.CHANNEL_KILLED)
	assert_equal(events.size(), 1, "a kill must be published")
	assert_equal(events[0]["prey_species"], &"deer")
	assert_true(wolf_agent.hunger < 0.9, "a kill must feed the hunter")


func test_hungry_predator_commits_to_hunting() -> void:
	var wolf_entry := _entry(&"wolf", &"carnivore", [&"deer"] as Array[StringName])
	var deer_entry := _entry(&"deer")
	var pair := _world_with([wolf_entry, deer_entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	var wolf := _spawn(world, registry, wolf_entry, Vector3.ZERO, 1.0)
	_spawn(world, registry, deer_entry, Vector3(6, 0, 0))

	var predation := _predation(registry, _index_for(world))
	var ai := UtilityAISystem.new()
	predation.tick(world, 0.1, 0)
	ai.tick(world, 0.1, 1)

	var agent := world.get_component(wolf, &"CAgent") as CAgent
	assert_equal(agent.current_action, &"hunt",
		"a starving predator beside a deer should hunt, chose %s" % agent.current_action)
	var velocity := world.get_component(wolf, &"CVelocity") as CVelocity
	assert_true(velocity.linear.x > 0.0, "and move toward it")


func test_hunted_prey_evades() -> void:
	var wolf_entry := _entry(&"wolf", &"carnivore", [&"deer"] as Array[StringName])
	var deer_entry := _entry(&"deer")
	var pair := _world_with([wolf_entry, deer_entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	_spawn(world, registry, wolf_entry, Vector3.ZERO)
	var deer := _spawn(world, registry, deer_entry, Vector3(3, 0, 0), 0.1)

	var predation := _predation(registry, _index_for(world))
	var ai := UtilityAISystem.new()
	predation.tick(world, 0.1, 0)
	ai.tick(world, 0.1, 1)

	var agent := world.get_component(deer, &"CAgent") as CAgent
	assert_equal(agent.current_action, &"evade",
		"a deer three metres from a wolf should run, chose %s" % agent.current_action)
	var velocity := world.get_component(deer, &"CVelocity") as CVelocity
	assert_true(velocity.linear.x > 0.0, "and run AWAY from it, not toward it")


# ── Flocking ────────────────────────────────────────────────────────────────


func _herd_entry() -> FaunaEntry:
	var entry := _entry(&"deer")
	entry.flocking = true
	entry.flock_separation = 1.0
	entry.flock_alignment = 0.7
	entry.flock_cohesion = 0.8
	entry.flock_radius = 12.0
	return entry


func test_flocking_pulls_a_stray_toward_the_herd() -> void:
	var entry := _herd_entry()
	var pair := _world_with([entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	# A tight cluster well inside the 12 m neighbour radius, plus one animal
	# off to the side heading AWAY from it.
	for i in 4:
		_spawn(world, registry, entry, Vector3(8.0 + i * 0.8, 0, 0))
	var stray := _spawn(world, registry, entry, Vector3.ZERO)
	var velocity := world.get_component(stray, &"CVelocity") as CVelocity
	velocity.linear = Vector3(-2.0, 0, 0)

	var flocking := FlockingSystem.new()
	flocking.index = _index_for(world)
	for frame in 20:
		flocking.tick(world, 0.1, frame)

	# Flocking steers, it does not accelerate — so the assertion is about
	# DIRECTION. The stray should have turned around toward the herd.
	assert_true(velocity.linear.x > 0.0,
		"the stray should turn toward the herd, got %s" % str(velocity.linear))
	var group := world.get_component(stray, &"CGroup") as CGroup
	assert_equal(group.neighbours, 4, "it should see the whole herd")


func test_flocking_pushes_crowded_neighbours_apart() -> void:
	var entry := _herd_entry()
	var pair := _world_with([entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	var a := _spawn(world, registry, entry, Vector3.ZERO)
	_spawn(world, registry, entry, Vector3(0.3, 0, 0))

	var velocity := world.get_component(a, &"CVelocity") as CVelocity
	velocity.linear = Vector3(0.5, 0, 0)
	var flocking := FlockingSystem.new()
	flocking.index = _index_for(world)
	for frame in 20:
		flocking.tick(world, 0.1, frame)

	assert_true(velocity.linear.x < 0.5,
		"two animals sharing a metre must push apart, got %s" % str(velocity.linear))


func test_flocking_ignores_other_species() -> void:
	var deer := _herd_entry()
	var rabbit := _entry(&"rabbit")
	rabbit.flocking = true
	var pair := _world_with([deer, rabbit])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	var stray := _spawn(world, registry, deer, Vector3.ZERO)
	for i in 4:
		_spawn(world, registry, rabbit, Vector3(6.0 + i * 0.5, 0, 0))

	var flocking := FlockingSystem.new()
	flocking.index = _index_for(world)
	flocking.tick(world, 0.1, 0)

	var group := world.get_component(stray, &"CGroup") as CGroup
	assert_equal(group.neighbours, 0,
		"a mixed plain is several herds sharing ground, not one flock of everything")


func test_fleeing_animals_break_formation() -> void:
	# A herd that cannot leave its herd cannot escape a predator. Flocking is
	# a correction to the AI's velocity, and evade lowers how much of it lands.
	var entry := _herd_entry()
	var pair := _world_with([entry])
	var world: EcsWorld = pair[0]
	var registry: SpeciesRegistry = pair[1]
	for i in 4:
		_spawn(world, registry, entry, Vector3(10.0 + i * 0.8, 0, 0))
	var runner := _spawn(world, registry, entry, Vector3.ZERO)
	var agent := world.get_component(runner, &"CAgent") as CAgent
	agent.current_action = &"evade"
	var velocity := world.get_component(runner, &"CVelocity") as CVelocity
	velocity.linear = Vector3(-4.0, 0, 0)  # sprinting away from the herd

	var flocking := FlockingSystem.new()
	flocking.index = _index_for(world)
	for frame in 20:
		flocking.tick(world, 0.1, frame)

	assert_almost(velocity.linear.x, -4.0, 0.001,
		"an evading animal must keep running away from its herd, untouched")
	var group := world.get_component(runner, &"CGroup") as CGroup
	assert_equal(group.neighbours, 0, "and must not be counted into a group")
