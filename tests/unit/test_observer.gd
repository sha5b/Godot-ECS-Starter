extends EcsTestCase

## Headless tests for the observer's pure data layer (ObserverHUD):
## kind inference, report building, panel formatting, and screen picking.


func _spawn_critter(world: EcsWorld) -> int:
	var entity := world.spawn()
	var transform := CTransform.new()
	transform.position = Vector3(3.0, 1.0, -2.0)
	world.add_component(entity, transform)
	world.add_component(entity, CVelocity.new())
	var body := CBody.new()
	body.material = CBody.SurfaceMaterial.FLESH
	body.fuel = 3.0
	world.add_component(entity, body)
	world.add_component(entity, CElemental.new())
	var health := CHealth.new()
	health.max_hp = 8.0
	health.hp = 5.0
	world.add_component(entity, health)
	var agent := CAgent.new()
	agent.brain = UtilityBrain.critter_brain()
	agent.hunger = 0.7
	agent.energy = 0.4
	agent.current_action = &"seek_food"
	agent.action_score = 0.5
	world.add_component(entity, agent)
	return entity


func test_kind_of_matches_component_signatures() -> void:
	var world := EcsWorld.new()

	var critter := world.spawn()
	world.add_component(critter, CTransform.new())
	var agent := CAgent.new()
	agent.brain = UtilityBrain.critter_brain()
	world.add_component(critter, agent)
	assert_equal(ObserverHUD.kind_of(world, critter), &"critter", "agent => critter")

	var campfire := world.spawn()
	var stone := CBody.new()
	stone.material = CBody.SurfaceMaterial.STONE
	world.add_component(campfire, stone)
	var flame := CElemental.new()
	flame.constant_elements[ChemistryDefs.Element.FIRE] = 1.0
	world.add_component(campfire, flame)
	assert_equal(ObserverHUD.kind_of(world, campfire), &"campfire", "constant fire => campfire")

	var berry := world.spawn()
	var bush := CBody.new()
	bush.material = CBody.SurfaceMaterial.GRASS
	world.add_component(berry, bush)
	world.add_component(berry, CElemental.new())
	world.add_component(berry, CFood.new())
	assert_equal(ObserverHUD.kind_of(world, berry), &"berry bush", "food => berry bush")

	var grass := world.spawn()
	var blade := CBody.new()
	blade.material = CBody.SurfaceMaterial.GRASS
	world.add_component(grass, blade)
	world.add_component(grass, CElemental.new())
	assert_equal(ObserverHUD.kind_of(world, grass), &"grass", "bare grass body => grass")


func test_build_report_reads_component_state() -> void:
	var world := EcsWorld.new()
	var entity := _spawn_critter(world)
	world.set_tier(entity, 1)
	var elemental := world.get_component(entity, &"CElemental") as CElemental
	elemental.wetness = 0.5
	elemental.burning = true
	elemental.add_element(ChemistryDefs.Element.FIRE, 0.4)

	var report := ObserverHUD.build_report(world, entity)
	assert_true(bool(report["alive"]), "live entity reports alive")
	assert_equal(report["kind"], &"critter", "kind comes from the agent")
	assert_equal(int(report["tier"]), 1, "tier read from world")
	assert_equal(str(report["tier_note"]), "every 4th frame", "tier note matches cadence")
	assert_almost(float(report["hp"]), 5.0, 0.0001, "hp snapshot")
	assert_almost(float(report["hunger"]), 0.7, 0.0001, "drive snapshot")
	assert_equal(str(report["action"]), "seek_food", "committed action snapshot")
	assert_almost(float(report["wetness"]), 0.5, 0.0001, "wetness snapshot")
	assert_true(bool(report["burning"]), "burning flag snapshot")
	var elements: Array[String] = report["elements"]
	assert_equal(elements.size(), 1, "one active element listed")
	assert_true(elements[0].begins_with("FIRE"), "element named FIRE")

	var text := ObserverHUD.format_report(report)
	assert_true(text.contains("seek_food"), "text shows the action")
	assert_true(text.contains("hunger"), "text shows drives")
	assert_true(text.contains("burning"), "text shows the burning flag")
	assert_true(text.contains("every 4th frame"), "text shows the tier")


func test_build_report_handles_stale_handles() -> void:
	var world := EcsWorld.new()
	var entity := _spawn_critter(world)
	var report := ObserverHUD.build_report(world, entity)
	assert_true(bool(report["alive"]), "alive before despawn")
	world.despawn(entity)
	var stale := ObserverHUD.build_report(world, entity)
	assert_false(bool(stale["alive"]), "stale handle reports not alive")
	assert_equal(ObserverHUD.format_report(stale), "despawned", "stale text is despawned")


func test_pick_index_nearest_then_depth_then_none() -> void:
	var dists := PackedFloat32Array([50.0, 20.0, 25.0])
	var depths := PackedFloat32Array([1.0, 5.0, 3.0])
	assert_equal(ObserverHUD.pick_index(dists, depths, 30.0), 1,
		"nearest in radius wins")

	var tied := PackedFloat32Array([20.0, 20.0])
	var tied_depths := PackedFloat32Array([9.0, 4.0])
	assert_equal(ObserverHUD.pick_index(tied, tied_depths, 30.0), 1,
		"ties break toward the smaller depth")

	var far := PackedFloat32Array([80.0, 95.0])
	assert_equal(ObserverHUD.pick_index(far, tied_depths, 30.0), -1,
		"nothing within radius picks -1")


func test_bar_clamps_and_fills() -> void:
	assert_equal(ObserverHUD.bar(-0.5, 10).count("█"), 0, "negative clamps to empty")
	assert_equal(ObserverHUD.bar(0.5, 10).count("█"), 5, "half fills half")
	assert_equal(ObserverHUD.bar(2.0, 10).count("█"), 10, "over one clamps to full")
	assert_equal(ObserverHUD.bar(0.5, 10).length(), 10, "bar keeps its width")
