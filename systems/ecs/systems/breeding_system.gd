class_name BreedingSystem
extends RefCounted

## Sim-phase reproduction for genome-backed critters — the evolution engine.
##
## When two adults of the same species meet within partner_radius and both
## are off cooldown, a child entity spawns through the command buffer with
## a crossover + mutation of the parents' genomes. Because the child's
## CAgent.move_speed and CHealth come from its derived stats, body genes
## that move faster or survive longer compound across generations — natural
## selection falls out of the existing simulation for free.
##
## Events: publishes "critter_bred" {child, parents, position, species}
## on the world's event channels (bridged to SystemBus by EcsSystem).

## How close partners must be to breed (world units).
var partner_radius := 6.0

## Seconds between breed attempts per critter.
var breed_cooldown := 30.0

## Hard population cap for CGenome carriers.
var max_population := 24

## Mutation rate handed to CritterGenome.mutate().
var mutation_rate := 1.0

## Offspring per successful pairing.
var offspring_count := 1

## Only critters at least this old (in breeding-attempt ticks) reproduce —
## cheap stand-in for maturity until a lifecycle component exists.
var maturity_delay := 3.0

var _cache: EcsWorld.QueryCache = null
var _timer := 0.0
var _age: Dictionary = {}  ## entity -> seconds since first seen


func tick(world: EcsWorld, delta: float, _frame: int) -> void:
	if _cache == null:
		_cache = world.query([&"CGenome", &"CAgent", &"CTransform"])
	_timer += delta
	if _timer < 0.5:
		_tick_cooldowns(world, delta)
		return
	_timer = 0.0
	_tick_cooldowns(world, delta)

	# Scratch buffer is safe here: structural changes are deferred commands.
	var entities := world.all_entities_scratch(_cache)
	for entity in entities:
		_age[entity] = float(_age.get(entity, 0.0)) + 0.5

	var population := entities.size()
	if population >= max_population:
		return

	# O(n²) pairing pass — population caps keep this trivial. Same species
	# only: critters drift within their lineage, they don't hybridize.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(world.stats) ^ Time.get_ticks_msec()
	var radius_sq := partner_radius * partner_radius
	for i in entities.size():
		var a := entities[i]
		var genome_a := world.get_component(a, &"CGenome") as CGenome
		var agent_a := world.get_component(a, &"CAgent") as CAgent
		var transform_a := world.get_component(a, &"CTransform") as CTransform
		if genome_a == null or agent_a == null or transform_a == null:
			continue
		if agent_a.is_on_cooldown(&"breed") or float(_age.get(a, 0.0)) < maturity_delay:
			continue
		if not world.is_alive(a):
			continue
		for j in range(i + 1, entities.size()):
			var b := entities[j]
			var genome_b := world.get_component(b, &"CGenome") as CGenome
			if genome_b == null or genome_b.species != genome_a.species:
				continue
			var agent_b := world.get_component(b, &"CAgent") as CAgent
			if agent_b == null or agent_b.is_on_cooldown(&"breed"):
				continue
			var transform_b := world.get_component(b, &"CTransform") as CTransform
			if transform_b == null:
				continue
			if not world.is_alive(b):
				continue
			if transform_a.position.distance_squared_to(transform_b.position) > radius_sq:
				continue

			var spawn_pos := (transform_a.position + transform_b.position) * 0.5
			for _k in offspring_count:
				if population >= max_population:
					break
				population += _spawn_child(world, a, genome_a, b, genome_b, spawn_pos, rng)
			agent_a.cooldowns[&"breed"] = breed_cooldown
			agent_b.cooldowns[&"breed"] = breed_cooldown


## Spawn one crossover+mutation child via the command buffer. Returns 1 on
## success (0 for accounting) and publishes the breeding event.
func _spawn_child(world: EcsWorld, parent_a: int, genome_a: CGenome, parent_b: int, genome_b: CGenome, position: Vector3, rng: RandomNumberGenerator) -> int:
	var child_genome := CritterGenome.crossover(genome_a.genome, genome_b.genome, rng)
	child_genome.mutate(rng, mutation_rate)
	var child_comp := CGenome.from_genome(child_genome)

	var transform := CTransform.new()
	transform.position = position + Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8))
	transform.facing = rng.randf() * TAU
	var agent := CAgent.new()
	agent.brain = UtilityBrain.critter_brain()
	agent.move_speed = child_comp.derived_move_speed
	var health := CHealth.new()
	health.max_hp = child_comp.derived_health_max
	health.hp = child_comp.derived_health_max
	var body := CBody.new()
	body.material = CBody.SurfaceMaterial.FLESH
	body.fuel = 3.0

	var child := world.commands.spawn_with([transform, CVelocity.new(), agent, health, body, CElemental.new(), child_comp])
	world.publish(&"critter_bred", {
		"child": child,
		"parents": [parent_a, parent_b],
		"position": position,
		"species": child_comp.species,
		"speed": child_comp.derived_move_speed,
	})
	return 1


## CAgent cooldowns normally tick in the AI system; labs and worlds without
## utility AI still need breeding cooldowns to count down.
func _tick_cooldowns(world: EcsWorld, delta: float) -> void:
	for entity in world.all_entities_scratch(_cache):
		var agent := world.get_component(entity, &"CAgent") as CAgent
		if agent != null:
			agent.tick_cooldowns(delta)
