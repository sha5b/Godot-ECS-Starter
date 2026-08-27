extends EcsTestCase

## Unit tests for utility AI: response curves, scoring, action selection,
## hysteresis, and actuator behavior.


func _spawn_agent(world: EcsWorld, position: Vector3) -> int:
	var e := world.spawn()
	var transform := CTransform.new()
	transform.position = position
	world.add_component(e, transform)
	world.add_component(e, CVelocity.new())
	var agent := CAgent.new()
	agent.brain = UtilityBrain.critter_brain()
	world.add_component(e, agent)
	return e


func _spawn_fire(world: EcsWorld, position: Vector3) -> int:
	var e := world.spawn()
	var transform := CTransform.new()
	transform.position = position
	world.add_component(e, transform)
	var elemental := CElemental.new()
	elemental.burning = true
	world.add_component(e, elemental)
	var body := CBody.new()
	body.material = CBody.SurfaceMaterial.GRASS
	body.fuel = 99.0
	world.add_component(e, body)
	return e


func test_response_curves() -> void:
	var consideration := Consideration.new()

	consideration.curve = Consideration.ResponseCurve.LINEAR
	assert_almost(consideration.evaluate(0.25), 0.25, 0.0001, "linear passes through")

	consideration.curve = Consideration.ResponseCurve.POLYNOMIAL
	consideration.exponent = 2.0
	assert_almost(consideration.evaluate(0.5), 0.25, 0.0001, "polynomial squares")

	consideration.curve = Consideration.ResponseCurve.INVERSE
	assert_almost(consideration.evaluate(0.25), 0.75, 0.0001, "inverse flips")

	consideration.curve = Consideration.ResponseCurve.LOGISTIC
	consideration.midpoint = 0.5
	consideration.steepness = 8.0
	assert_almost(consideration.evaluate(0.5), 0.5, 0.01, "logistic midpoint")
	assert_true(consideration.evaluate(0.9) > 0.95, "logistic saturates high")

	consideration.curve = Consideration.ResponseCurve.STEP
	consideration.threshold = 0.5
	assert_almost(consideration.evaluate(0.49), 0.0, 0.0001, "step below")
	assert_almost(consideration.evaluate(0.51), 1.0, 0.0001, "step above")


func test_action_scoring_compensation() -> void:
	var action := UtilityAction.new()
	action.base_score = 1.0
	for i in 4:
		var consideration := Consideration.new()
		consideration.input = Consideration.SensorInput.CONSTANT
		consideration.curve = Consideration.ResponseCurve.LINEAR
		action.considerations.append(consideration)

	var score_all_half := action.score({Consideration.SensorInput.CONSTANT: 0.5})
	# Raw product = 0.0625; Dave Mark's compensation lifts it to ~0.106.
	assert_true(score_all_half > 0.09, "compensation lifts multi-consideration scores (got %f)" % score_all_half)
	assert_true(score_all_half <= 1.0, "scores stay normalized")


func test_critter_brain_factory() -> void:
	var brain := UtilityBrain.critter_brain()
	assert_not_null(brain.action_by_name(&"panic"), "has panic")
	assert_not_null(brain.action_by_name(&"seek_food"), "has seek_food")
	assert_not_null(brain.action_by_name(&"rest"), "has rest")
	assert_not_null(brain.action_by_name(&"wander"), "has wander")
	assert_true(brain.action_by_name(&"panic").is_interrupt, "panic interrupts")


func test_hungry_agent_seeks_food() -> void:
	var world := EcsWorld.new()
	world.focus_position = Vector3(500, 0, 500)  # keep the threat away
	var ai := UtilityAISystem.new()
	var agent_e := _spawn_agent(world, Vector3.ZERO)
	var food_e := world.spawn()
	var food_transform := CTransform.new()
	food_transform.position = Vector3(2, 0, 0)
	world.add_component(food_e, food_transform)
	world.add_component(food_e, CFood.new())

	ai.tick(world, 1.0, 1)
	var agent := world.get_component(agent_e, &"CAgent") as CAgent
	assert_equal(agent.current_action, &"seek_food", "hungry default agent commits to food")


func test_fire__near_agent_wins_panic() -> void:
	var world := EcsWorld.new()
	var ai := UtilityAISystem.new()
	var agent_e := _spawn_agent(world, Vector3.ZERO)
	_spawn_fire(world, Vector3(4, 0, 0))

	ai.tick(world, 1.0, 1)
	var agent := world.get_component(agent_e, &"CAgent") as CAgent
	assert_equal(agent.current_action, &"panic", "fire nearby forces panic")


func test_panic_interrupt_beats_committed_action() -> void:
	var world := EcsWorld.new()
	world.focus_position = Vector3(500, 0, 500)  # keep the threat away
	var ai := UtilityAISystem.new()
	var agent_e := _spawn_agent(world, Vector3.ZERO)
	var food_e := world.spawn()
	var food_transform := CTransform.new()
	food_transform.position = Vector3(3, 0, 0)
	world.add_component(food_e, food_transform)
	world.add_component(food_e, CFood.new())

	ai.tick(world, 1.0, 1)
	var agent := world.get_component(agent_e, &"CAgent") as CAgent
	assert_equal(agent.current_action, &"seek_food", "starts seeking food")

	# Fire appears far closer than food: interrupt must take over at once.
	_spawn_fire(world, Vector3(2, 0, 0))
	ai.tick(world, 1.0, 2)
	assert_equal(agent.current_action, &"panic", "interrupt beats committed seek_food")


func test_tired_agent_rests() -> void:
	var world := EcsWorld.new()
	var ai := UtilityAISystem.new()
	var agent_e := _spawn_agent(world, Vector3(30, 0, 30))
	var agent := world.get_component(agent_e, &"CAgent") as CAgent
	agent.hunger = 0.05
	agent.energy = 0.05
	world.focus_position = Vector3(500, 0, 500)  # no threat nearby

	ai.tick(world, 1.0, 1)
	assert_equal(agent.current_action, &"rest", "exhausted calm agent rests")


func test_agent_eats_food_when_close() -> void:
	var world := EcsWorld.new()
	world.focus_position = Vector3(500, 0, 500)  # keep the threat away
	var ai := UtilityAISystem.new()
	var agent_e := _spawn_agent(world, Vector3.ZERO)
	var food_e := world.spawn()
	var food_transform := CTransform.new()
	food_transform.position = Vector3(0.5, 0, 0)
	world.add_component(food_e, food_transform)
	var food := CFood.new()
	food.nutrition = 0.5
	world.add_component(food_e, food)

	ai.tick(world, 1.0, 1)
	var agent := world.get_component(agent_e, &"CAgent") as CAgent
	assert_true(agent.hunger < 0.3, "eating reduced hunger (got %f)" % agent.hunger)
	world.flush_commands()
	assert_false(world.is_alive(food_e), "eaten food despawned")
	assert_false(world.drain(UtilityAISystem.CHANNEL_ATE).is_empty(), "ate event")


func test_frozen_agent_does_not_move() -> void:
	var world := EcsWorld.new()
	var ai := UtilityAISystem.new()
	var agent_e := _spawn_agent(world, Vector3.ZERO)
	var food_e := world.spawn()
	var food_transform := CTransform.new()
	food_transform.position = Vector3(6, 0, 0)
	world.add_component(food_e, food_transform)
	world.add_component(food_e, CFood.new())
	world.add_component(agent_e, CElemental.new())
	(world.get_component(agent_e, &"CElemental") as CElemental).frozen = true
	(world.get_component(agent_e, &"CVelocity") as CVelocity).linear = Vector3(5, 0, 0)

	ai.tick(world, 1.0, 1)
	assert_equal((world.get_component(agent_e, &"CVelocity") as CVelocity).linear,
		Vector3.ZERO, "frozen agent velocity zeroed")


func test_hysteresis_prevents_dithering() -> void:
	var world := EcsWorld.new()
	world.focus_position = Vector3(500, 0, 500)  # keep the threat away
	var ai := UtilityAISystem.new()
	var agent_e := _spawn_agent(world, Vector3.ZERO)
	var agent := world.get_component(agent_e, &"CAgent") as CAgent
	var food_e := world.spawn()
	var food_transform := CTransform.new()
	food_transform.position = Vector3(2, 0, 0)
	world.add_component(food_e, food_transform)
	world.add_component(food_e, CFood.new())

	ai.tick(world, 1.0, 1)
	assert_equal(agent.current_action, &"seek_food", "commits to food")
	agent.hunger = 0.28  # slightly less urgent, still hungry-ish
	ai.tick(world, 1.0, 2)
	assert_equal(agent.current_action, &"seek_food",
		"stays committed within switch margin")
