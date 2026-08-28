class_name UtilityAISystem
extends RefCounted

## Utility-based agent brain, BotW-style.
##
## Each processed agent:
##   1. refreshes a sensor blackboard (drives, nearest food, nearest fire,
##      threat proximity to the world focus)
##   2. scores every brain action through its consideration curves
##   3. commits to the winner — with hysteresis so agents don't dither,
##      and interrupt actions that take over immediately
##   4. runs the action's actuator, which writes movement intent into
##      CVelocity (MovementSystem integrates it later in the same phase)
##
## Emergent demo: ignite grass near critters and PANIC wins every score.

const CHANNEL_ATE := &"ai.ate"
const CHANNEL_ACTION_CHANGED := &"ai.action_changed"

## How far agents sense food and fire.
var sensor_range := 24.0
## How close the world focus (player/camera) counts as a threat.
var threat_range := 7.0

var _agents: EcsWorld.QueryCache = null
var _food: EcsWorld.QueryCache = null
var _elementals: EcsWorld.QueryCache = null
var _food_grid := EcsSpatialGrid.new()

## Sensor lists are rebuilt on a coarse timer instead of every tick —
## fires move slowly and food is static, so the delay is invisible in play.
var _sensor_refresh := 0.3
var _sensor_timer := 999.0
var _cached_fires: Array[Vector3] = []


func tick(world: EcsWorld, delta: float, frame: int) -> void:
	if _agents == null:
		_agents = world.query([&"CTransform", &"CAgent", &"CVelocity"])
		_food = world.query([&"CTransform", &"CFood"])
		_elementals = world.query([&"CTransform", &"CElemental"])

	_sensor_timer += delta
	if _sensor_timer >= _sensor_refresh:
		_sensor_timer = 0.0
		_refresh_food_grid(world)
		_cached_fires = _collect_fires(world)

	for entity in world.frame_entities(_agents, frame):
		var agent := world.get_component(entity, &"CAgent") as CAgent
		var transform := world.get_component(entity, &"CTransform") as CTransform
		var velocity := world.get_component(entity, &"CVelocity") as CVelocity
		var elemental := world.get_component(entity, &"CElemental") as CElemental
		var dt := world.entity_delta(entity, delta)

		agent.tick_cooldowns(dt)
		_update_drives(agent, dt)

		if elemental != null and elemental.frozen:
			velocity.linear = Vector3.ZERO
			continue

		_sense(world, agent, transform, _cached_fires)
		_decide(world, entity, agent)
		_act(world, entity, agent, transform, velocity, dt)
		agent.action_time += dt


# ── Sensors ──────────────────────────────────────────────────────────────────


func _refresh_food_grid(world: EcsWorld) -> void:
	_food_grid.clear()
	for entity in world.all_entities_scratch(_food):
		var transform := world.get_component(entity, &"CTransform") as CTransform
		if transform != null:
			_food_grid.insert(entity, transform.position)


func _collect_fires(world: EcsWorld) -> Array[Vector3]:
	var fires: Array[Vector3] = []
	for entity in world.all_entities_scratch(_elementals):
		var elemental := world.get_component(entity, &"CElemental") as CElemental
		if elemental == null:
			continue
		if elemental.burning or elemental.constant_elements.has(ChemistryDefs.Element.FIRE):
			var transform := world.get_component(entity, &"CTransform") as CTransform
			if transform != null:
				fires.append(transform.position)
	return fires


func _sense(world: EcsWorld, agent: CAgent, transform: CTransform, fires: Array[Vector3]) -> void:
	var blackboard := agent.blackboard
	blackboard[Consideration.SensorInput.HUNGER] = agent.hunger
	blackboard[Consideration.SensorInput.ENERGY] = agent.energy

	# Nearest edible food.
	var food_entity := 0
	var food_dist := sensor_range
	for candidate in _food_grid.query_radius(transform.position, sensor_range):
		var food_transform := world.get_component(candidate, &"CTransform") as CTransform
		var food_elemental := world.get_component(candidate, &"CElemental") as CElemental
		if food_transform == null:
			continue
		# Charred food is gone; burning food is not appetizing either.
		if food_elemental != null and (food_elemental.charred or food_elemental.burning):
			continue
		var dist := food_transform.position.distance_to(transform.position)
		if dist < food_dist:
			food_dist = dist
			food_entity = candidate
	agent.target_entity = food_entity
	blackboard[Consideration.SensorInput.FOOD_PROXIMITY] = 0.0 if food_entity == 0 \
		else 1.0 - food_dist / sensor_range

	# Nearest fire.
	var fire_dist := sensor_range
	var fire_pos := Vector3.ZERO
	for candidate_fire in fires:
		var dist: float = candidate_fire.distance_to(transform.position)
		if dist < fire_dist:
			fire_dist = dist
			fire_pos = candidate_fire
	blackboard[Consideration.SensorInput.FIRE_PROXIMITY] = 0.0 if fire_dist >= sensor_range \
		else 1.0 - fire_dist / sensor_range
	blackboard["fire_pos"] = fire_pos

	# World focus (player/camera) as a threat.
	var focus_dist := transform.position.distance_to(world.focus_position)
	blackboard[Consideration.SensorInput.THREAT_PROXIMITY] = 0.0 if focus_dist >= threat_range \
		else 1.0 - focus_dist / threat_range
	if focus_dist < threat_range:
		agent.target_position = world.focus_position


# ── Decision ─────────────────────────────────────────────────────────────────


func _decide(world: EcsWorld, entity: int, agent: CAgent) -> void:
	var brain := agent.brain
	if brain == null:
		return

	var best := brain.best_action(agent.blackboard)
	if best == null:
		return

	var current := brain.action_by_name(agent.current_action)
	var should_switch := false
	if current == null or agent.current_action == &"idle":
		should_switch = true
	elif best.is_interrupt:
		should_switch = true
	elif agent.action_time >= current.commit_time:
		# After commitment, a newcomer must beat the incumbent by margin.
		var current_score := current.score(agent.blackboard)
		should_switch = best.score(agent.blackboard) > current_score * brain.switch_margin

	if not should_switch:
		return

	if agent.current_action != best.action_name:
		world.publish(CHANNEL_ACTION_CHANGED, {
			"entity": entity,
			"from": agent.current_action,
			"to": best.action_name,
		})
		if agent.current_action != &"idle":
			agent.cooldowns[agent.current_action] = best.cooldown
		agent.current_action = best.action_name
		agent.action_time = 0.0
		agent.action_score = best.score(agent.blackboard)


# ── Actuators ────────────────────────────────────────────────────────────────


func _act(world: EcsWorld, entity: int, agent: CAgent, transform: CTransform,
		velocity: CVelocity, dt: float) -> void:
	var speed := agent.move_speed
	match agent.current_action:
		&"panic":
			var away := _away_from_fires(agent, transform)
			velocity.linear = away * speed * 2.2
			agent.energy = maxf(agent.energy - 0.06 * dt, 0.0)
		&"flee":
			var away := (transform.position - agent.target_position)
			away.y = 0.0
			velocity.linear = away.normalized() * speed * 1.4 if away.length() > 0.01 else Vector3.ZERO
			agent.energy = maxf(agent.energy - 0.03 * dt, 0.0)
		&"evade":
			# Running from a hunter, at whatever burst the body can manage.
			# derived_flee_multiplier comes from stride and gait cycle, so an
			# animal that evolves a bouncier gait genuinely escapes more often
			# — which is the selection pressure predation is supposed to apply.
			var burst := 1.5
			var genome := world.get_component(entity, &"CGenome") as CGenome
			if genome != null:
				burst = genome.derived_flee_multiplier
			var predator_pos: Vector3 = agent.blackboard.get("predator_pos", transform.position)
			var escape := transform.position - predator_pos
			escape.y = 0.0
			if escape.length() < 0.01:
				escape = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
			velocity.linear = escape.normalized() * speed * burst
			agent.energy = maxf(agent.energy - 0.09 * dt, 0.0)
		&"hunt":
			var prey := int(agent.blackboard.get("prey_entity", 0))
			if prey != 0 and world.is_alive(prey):
				var prey_transform := world.get_component(prey, &"CTransform") as CTransform
				if prey_transform != null:
					var to_prey := prey_transform.position - transform.position
					to_prey.y = 0.0
					velocity.linear = to_prey.normalized() * speed * 1.25
					# Intent only. PredationSystem decides whether the bite
					# lands, how hard, and what it feeds — the same split as
					# AI writing velocity and MovementSystem integrating it.
					agent.blackboard["hunt_target"] = prey
					agent.energy = maxf(agent.energy - 0.07 * dt, 0.0)
			else:
				agent.blackboard["hunt_target"] = 0
				_wander(agent, velocity, speed * 0.7, dt)
		&"seek_food":
			if agent.target_entity != 0 and world.is_alive(agent.target_entity):
				var food := world.get_component(agent.target_entity, &"CTransform") as CTransform
				if food != null:
					var to_food := food.position - transform.position
					if to_food.length() < 0.9:
						_eat(world, agent, entity)
					else:
						velocity.linear = to_food.normalized() * speed
			else:
				_wander(agent, velocity, speed * 0.5, dt)
		&"rest":
			velocity.linear = Vector3.ZERO
			agent.energy = minf(agent.energy + 0.2 * dt, 1.0)
			agent.hunger = minf(agent.hunger + 0.02 * dt, 1.0)
		&"wander":
			_wander(agent, velocity, speed * 0.55, dt)
		_:
			velocity.linear = Vector3.ZERO

	if velocity.linear.length() > 0.01:
		transform.face_towards(transform.position + velocity.linear, dt)


func _wander(agent: CAgent, velocity: CVelocity, speed: float, dt: float) -> void:
	var dir: Vector3 = agent.blackboard.get("wander_dir", Vector3.ZERO)
	agent.blackboard["wander_recheck"] = float(agent.blackboard.get("wander_recheck", 0.0)) - dt
	if dir == Vector3.ZERO or float(agent.blackboard.get("wander_recheck", 0.0)) <= 0.0:
		var angle := randf() * TAU
		dir = Vector3(cos(angle), 0.0, sin(angle))
		agent.blackboard["wander_dir"] = dir
		agent.blackboard["wander_recheck"] = randf_range(1.5, 4.0)
	velocity.linear = dir * speed
	agent.energy = maxf(agent.energy - 0.008 * dt, 0.0)


func _away_from_fires(agent: CAgent, transform: CTransform) -> Vector3:
	var away := Vector3(agent.blackboard.get("panic_dir", Vector3.ZERO))
	var fire_proximity: float = agent.blackboard.get(Consideration.SensorInput.FIRE_PROXIMITY, 0.0)
	if fire_proximity > 0.05:
		var fire_pos: Vector3 = agent.blackboard.get("fire_pos", transform.position)
		away = transform.position - fire_pos
		away.y = 0.0
		if away.length() < 0.01:
			away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
	return away.normalized()


func _eat(world: EcsWorld, agent: CAgent, entity: int) -> void:
	var food := world.get_component(agent.target_entity, &"CFood") as CFood
	if food == null:
		return
	agent.hunger = maxf(agent.hunger - food.nutrition, 0.0)
	world.publish(CHANNEL_ATE, {"entity": entity, "food": agent.target_entity})
	world.commands.despawn(agent.target_entity)
	agent.target_entity = 0


func _update_drives(agent: CAgent, dt: float) -> void:
	agent.hunger = minf(agent.hunger + 0.025 * dt, 1.0)
	agent.energy = maxf(agent.energy - 0.004 * dt, 0.0)
