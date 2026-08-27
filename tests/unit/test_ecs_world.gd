extends EcsTestCase

## Unit tests for the ECS core: entities, components, queries, tiers,
## commands, and events.


func test_spawn_and_generational_safety() -> void:
	var world := EcsWorld.new()
	var a := world.spawn()
	assert_true(world.is_alive(a), "fresh entity alive")
	world.despawn(a)
	assert_false(world.is_alive(a), "despawned entity dead")
	var b := world.spawn()
	assert_true(world.is_alive(b), "recycled index alive")
	assert_false(world.is_alive(a), "stale handle of recycled index dead")


func test_component_add_get_remove() -> void:
	var world := EcsWorld.new()
	var e := world.spawn()
	assert_null(world.get_component(e, &"CTransform"), "no component yet")
	var transform := CTransform.new()
	transform.position = Vector3(3, 0, 4)
	world.add_component(e, transform)
	var fetched := world.get_component(e, &"CTransform") as CTransform
	assert_not_null(fetched, "component fetched")
	assert_equal(fetched.position, Vector3(3, 0, 4), "position round-trips")
	world.remove_component(e, &"CTransform")
	assert_null(world.get_component(e, &"CTransform"), "component removed")
	assert_false(world.has_component(e, &"CTransform"), "has_component false")


func test_component_readd_replaces() -> void:
	var world := EcsWorld.new()
	var e := world.spawn()
	var health_a := CHealth.new()
	health_a.hp = 5
	world.add_component(e, health_a)
	var health_b := CHealth.new()
	health_b.hp = 9
	world.add_component(e, health_b)
	var fetched := world.get_component(e, &"CHealth") as CHealth
	assert_equal(fetched.hp, 9.0, "re-adding replaces")


func test_query_matches_signature() -> void:
	var world := EcsWorld.new()
	var both := world.spawn()
	world.add_component(both, CTransform.new())
	world.add_component(both, CVelocity.new())
	var only_transform := world.spawn()
	world.add_component(only_transform, CTransform.new())

	var cache := world.query([&"CTransform", &"CVelocity"])
	assert_equal(cache.count(), 1, "only entities with both components match")
	assert_true(cache.tiers[0].has(both), "both entity present")
	assert_false(cache.tiers[0].has(only_transform), "partial entity absent")


func test_query_updates_on_removal() -> void:
	var world := EcsWorld.new()
	var e := world.spawn()
	world.add_component(e, CTransform.new())
	world.add_component(e, CVelocity.new())
	var cache := world.query([&"CTransform", &"CVelocity"])
	assert_equal(cache.count(), 1, "entity in cache")
	world.remove_component(e, &"CVelocity")
	assert_equal(cache.count(), 0, "cache drops entity on removal")
	world.add_component(e, CVelocity.new())
	assert_equal(cache.count(), 1, "cache regains entity on re-add")


func test_despawn_removes_from_queries() -> void:
	var world := EcsWorld.new()
	var e := world.spawn()
	world.add_component(e, CTransform.new())
	world.add_component(e, CHealth.new())
	var cache := world.query([&"CHealth"])
	assert_equal(cache.count(), 1, "entity cached")
	world.despawn(e)
	assert_equal(cache.count(), 0, "cache empty after despawn")
	world.refresh_stats()
	assert_equal(world.stats["entities"], 0, "entity count back to zero")


func test_tier_assignment_moves_entities_between_partitions() -> void:
	var world := EcsWorld.new()
	var e := world.spawn()
	world.add_component(e, CTransform.new())
	var cache := world.query([&"CTransform"])
	assert_true(cache.tiers[0].has(e), "starts tier 0")
	world.set_tier(e, 2)
	assert_false(cache.tiers[0].has(e), "left tier 0")
	assert_true(cache.tiers[2].has(e), "joined tier 2")
	world.set_tier(e, 3)
	assert_true(cache.tiers[3].has(e), "dormant tier holds entity")


func test_frame_entities_cadence_and_stagger() -> void:
	var world := EcsWorld.new()
	var near_e := world.spawn()  # index 0, tier 0
	world.add_component(near_e, CTransform.new())
	var far_e := world.spawn()  # index 1
	world.add_component(far_e, CTransform.new())
	world.set_tier(far_e, 1)  # cadence 4
	world.set_tier(near_e, 3)  # dormant: never processed

	var cache := world.query([&"CTransform"])
	# Dormant near_e must never appear; far_e appears every 4th frame.
	var appearances := 0
	for frame in range(1, 41):
		var processed := world.frame_entities(cache, frame)
		assert_false(processed.has(near_e), "dormant never processed")
		if processed.has(far_e):
			appearances += 1
	assert_equal(appearances, 10, "tier-1 entity processes every 4th frame")
	# Entity delta is scaled by cadence so coarse tiers simulate correctly.
	assert_almost(world.entity_delta(far_e, 0.1), 0.4, 0.0001, "tier-1 delta x4")
	world.set_tier(far_e, 0)
	assert_almost(world.entity_delta(far_e, 0.1), 0.1, 0.0001, "tier-0 delta x1")


func test_distance_tier_assignment() -> void:
	var world := EcsWorld.new()
	world.focus_position = Vector3.ZERO
	var close := world.spawn()
	world.add_component(close, CTransform.new())
	(world.get_component(close, &"CTransform") as CTransform).position = Vector3(5, 0, 0)
	var mid := world.spawn()
	world.add_component(mid, CTransform.new())
	(world.get_component(mid, &"CTransform") as CTransform).position = Vector3(50, 0, 0)
	var far := world.spawn()
	world.add_component(far, CTransform.new())
	(world.get_component(far, &"CTransform") as CTransform).position = Vector3(150, 0, 0)
	var gone := world.spawn()
	world.add_component(gone, CTransform.new())
	(world.get_component(gone, &"CTransform") as CTransform).position = Vector3(500, 0, 0)

	var distances := {}
	for e in [close, mid, far, gone]:
		var t := world.get_component(e, &"CTransform") as CTransform
		distances[e] = t.position.distance_squared_to(Vector3.ZERO)
	world.assign_tiers_by_distance(distances, 10, 100, 300)
	assert_equal(world.tier_of(close), 0, "close -> tier 0")
	assert_equal(world.tier_of(mid), 1, "mid -> tier 1")
	assert_equal(world.tier_of(far), 2, "far -> tier 2")
	assert_equal(world.tier_of(gone), 3, "out of range -> dormant")


func test_command_buffer_defers_and_applies() -> void:
	var world := EcsWorld.new()
	var spawned := world.commands.spawn_with([CTransform.new(), CHealth.new()])
	# Before flush: entity exists but has no components yet.
	assert_true(world.is_alive(spawned), "handle reserved at spawn")
	assert_false(world.has_component(spawned, &"CTransform"), "component deferred")
	world.flush_commands()
	assert_true(world.has_component(spawned, &"CTransform"), "component attached at flush")
	assert_not_null(world.get_component(spawned, &"CHealth"), "health attached")

	world.commands.despawn(spawned)
	assert_true(world.is_alive(spawned), "despawn deferred too")
	world.flush_commands()
	assert_false(world.is_alive(spawned), "despawned at flush")


func test_commands_from_inside_iteration_are_safe() -> void:
	var world := EcsWorld.new()
	for i in 3:
		var e := world.spawn()
		world.add_component(e, CTransform.new())
		world.add_component(e, CLifetime.new())
	var cache := world.query([&"CLifetime"])
	# Despawn every entity while "iterating" the cache's snapshot.
	var snapshot := world.frame_entities(cache, 1)
	for e in snapshot:
		world.commands.despawn(e)
	world.flush_commands()
	assert_equal(cache.count(), 0, "all despawned after flush")
	world.refresh_stats()
	assert_equal(world.stats["entities"], 0, "no entities remain")


func test_events_publish_drain() -> void:
	var world := EcsWorld.new()
	world.publish(&"test.channel", {"a": 1})
	world.publish(&"test.channel", {"a": 2})
	assert_true(world.pending_channels().has(&"test.channel"), "channel pending")
	var events := world.drain(&"test.channel")
	assert_equal(events.size(), 2, "both events drained")
	assert_equal(events[0]["a"], 1, "payload order kept")
	assert_equal(world.drain(&"test.channel").size(), 0, "drain empties channel")
	assert_false(world.pending_channels().has(&"test.channel"), "channel no longer pending")
