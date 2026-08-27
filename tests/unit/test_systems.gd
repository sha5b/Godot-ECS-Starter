extends EcsTestCase

## Unit tests for scheduler, movement, vitality, tier system, and the
## full-stack integration (fire + fleeing critters end to end).


func test_scheduler_orders_by_phase_then_priority() -> void:
	var calls: Array[String] = []
	var scheduler := EcsScheduler.new()
	scheduler.register(&"late_low", func(_w, _d, _f): calls.append("late_low"), EcsScheduler.Phase.LATE, 90)
	scheduler.register(&"sim_30", func(_w, _d, _f): calls.append("sim_30"), EcsScheduler.Phase.SIM, 30)
	scheduler.register(&"early", func(_w, _d, _f): calls.append("early"), EcsScheduler.Phase.EARLY, 10)
	scheduler.register(&"sim_20", func(_w, _d, _f): calls.append("sim_20"), EcsScheduler.Phase.SIM, 20)
	scheduler.register(&"view", func(_w, _d, _f): calls.append("view"), EcsScheduler.Phase.VIEW, 70)

	scheduler.tick(EcsWorld.new(), 0.016)
	assert_equal(calls, ["early", "sim_20", "sim_30", "late_low", "view"],
		"phase groups in order, priority inside phase")
	assert_true(scheduler.system_times.has(&"sim_20"), "profiling recorded")


func test_scheduler_flushes_between_phases() -> void:
	var world := EcsWorld.new()
	var scheduler := EcsScheduler.new()
	# SIM system queues a spawn; VIEW must already see its components.
	# (Lambdas capture locals by value, so results travel via a reference.)
	var seen: Array[int] = [0]
	var spawner := func(w: EcsWorld, _d: float, _f: int):
		w.commands.spawn_with([CTransform.new()])
	scheduler.register(&"spawner", spawner, EcsScheduler.Phase.SIM, 10)
	var counter := func(w: EcsWorld, _d: float, _f: int):
		seen[0] = w.query([&"CTransform"]).count()
	scheduler.register(&"counter", counter, EcsScheduler.Phase.VIEW, 10)

	scheduler.tick(world, 0.016)
	assert_equal(seen[0], 1, "command flushed before next phase ran")


func test_movement_integrates_velocity_and_bounds() -> void:
	var world := EcsWorld.new()
	var movement := MovementSystem.new()
	movement.bounds_radius = 10.0

	var e := world.spawn()
	var transform := CTransform.new()
	world.add_component(e, transform)
	var velocity := CVelocity.new()
	velocity.linear = Vector3(30, 0, 0)
	world.add_component(e, velocity)

	movement.tick(world, 0.5, 1)
	assert_almost(transform.position.x, 10.0, 0.0001, "clamped at bounds radius")
	assert_almost(transform.position.z, 0.0, 0.0001, "z untouched")


func test_vitality_handles_death_and_lifetime() -> void:
	var world := EcsWorld.new()
	var vitality := VitalitySystem.new()

	var dead_e := world.spawn()
	world.add_component(dead_e, CTransform.new())
	var health := CHealth.new()
	health.apply_damage(99.0)
	world.add_component(dead_e, health)

	var expiring_e := world.spawn()
	world.add_component(expiring_e, CTransform.new())
	var lifetime := CLifetime.new()
	lifetime.remaining = 0.5
	world.add_component(expiring_e, lifetime)

	vitality.tick(world, 1.0, 1)
	world.flush_commands()
	assert_false(world.drain(VitalitySystem.CHANNEL_DIED).is_empty(), "death event published")
	assert_false(world.is_alive(dead_e), "dead body despawned")
	assert_false(world.is_alive(expiring_e), "expired lifetime despawned")


func test_tier_system_assigns_by_distance() -> void:
	var world := EcsWorld.new()
	world.focus_position = Vector3.ZERO
	var tiers := TierSystem.new()
	tiers.near_distance = 10.0
	tiers.mid_distance = 50.0
	tiers.far_distance = 100.0
	tiers.recheck_frames = 1

	var near := world.spawn()
	var near_t := CTransform.new()
	near_t.position = Vector3(2, 0, 0)
	world.add_component(near, near_t)
	var far := world.spawn()
	var far_t := CTransform.new()
	far_t.position = Vector3(80, 0, 0)
	world.add_component(far, far_t)

	tiers.tick(world, 0.016, 1)
	assert_equal(world.tier_of(near), 0, "near entity tier 0")
	assert_equal(world.tier_of(far), 2, "far entity tier 2")


func test_full_stack_fire_chases_critters() -> void:
	## End-to-end: campfire ignites grass, fire spreads, the nearby critter
	## must commit to panic. This is the BotW emergent moment in miniature.
	seed(42)
	var world := EcsWorld.new()
	var scheduler := EcsScheduler.new()
	var tiers := TierSystem.new()
	tiers.near_distance = 500.0  # everything tier 0 in this test
	tiers.mid_distance = 900.0
	tiers.far_distance = 1000.0
	var movement := MovementSystem.new()
	var ai := UtilityAISystem.new()
	var chemistry := ChemistrySystem.new()
	var vitality := VitalitySystem.new()

	scheduler.register(&"tiering", tiers.tick, EcsScheduler.Phase.EARLY, 10)
	scheduler.register(&"movement", movement.tick, EcsScheduler.Phase.SIM, 20)
	scheduler.register(&"ai", ai.tick, EcsScheduler.Phase.SIM, 30)
	scheduler.register(&"chemistry", chemistry.tick, EcsScheduler.Phase.SIM, 40)
	scheduler.register(&"vitality", vitality.tick, EcsScheduler.Phase.SIM, 50)

	# Campfire: constant fire source.
	var campfire := world.spawn()
	var fire_transform := CTransform.new()
	fire_transform.position = Vector3.ZERO
	world.add_component(campfire, fire_transform)
	var fire_body := CBody.new()
	fire_body.material = CBody.SurfaceMaterial.STONE
	world.add_component(campfire, fire_body)
	var fire_elemental := CElemental.new()
	fire_elemental.constant_elements[ChemistryDefs.Element.FIRE] = 1.0
	world.add_component(campfire, fire_elemental)

	# Grass ring around the campfire.
	for i in 12:
		var angle := TAU * i / 12.0
		var grass := world.spawn()
		var grass_transform := CTransform.new()
		grass_transform.position = Vector3(cos(angle) * 1.5, 0, sin(angle) * 1.5)
		world.add_component(grass, grass_transform)
		var grass_body := CBody.new()
		grass_body.material = CBody.SurfaceMaterial.GRASS
		grass_body.fuel = 1.5
		world.add_component(grass, grass_body)
		world.add_component(grass, CElemental.new())

	# One critter watching from four meters.
	var critter := world.spawn()
	var critter_transform := CTransform.new()
	critter_transform.position = Vector3(4, 0, 0)
	world.add_component(critter, critter_transform)
	world.add_component(critter, CVelocity.new())
	var agent := CAgent.new()
	agent.brain = UtilityBrain.critter_brain()
	world.add_component(critter, agent)

	var ignited := 0
	var panicked := false
	for frame in range(1, 121):
		scheduler.tick(world, 1.0 / 30.0)
		ignited += world.drain(ChemistryDefs.CHANNEL_IGNITED).size()
		if (world.get_component(critter, &"CAgent") as CAgent).current_action == &"panic":
			panicked = true

	assert_true(ignited >= 3, "fire spread through the grass ring (%d ignitions)" % ignited)
	assert_true(panicked, "critter panicked as fire closed in")
	# The critter must have fled — it should be further from the fire than start.
	var final_t := world.get_component(critter, &"CTransform") as CTransform
	assert_true(final_t.position.length() > 4.0 or not world.is_alive(critter),
		"critter fled the burning field (or died to it)")


func test_entity_count_survives_churn() -> void:
	## Spawn/destroy many entities through commands — the world must stay
	## consistent (no phantom entities, no leaks).
	var world := EcsWorld.new()
	for round in 50:
		var batch: Array[int] = []
		for i in 20:
			batch.append(world.commands.spawn_with([CTransform.new()]))
		world.flush_commands()
		for e in batch:
			world.commands.despawn(e)
		world.flush_commands()
	world.refresh_stats()
	assert_equal(world.stats["entities"], 0, "no phantom entities after churn")
	var cache := world.query([&"CTransform"])
	assert_equal(cache.count(), 0, "query caches drained")
