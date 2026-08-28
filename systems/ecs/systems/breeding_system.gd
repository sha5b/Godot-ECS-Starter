class_name BreedingSystem
extends RefCounted

## Sim-phase reproduction for genome-backed animals — the evolution engine.
##
## When two adults of the same species meet within partner_radius and both are
## off cooldown, a child spawns through the command buffer carrying a crossover
## + mutation of its parents' genomes. Because CAgent.move_speed and CHealth
## come from derived body stats, genes that move faster or survive longer
## compound across generations: selection falls out of the simulation for free.
##
## Species identity comes from CSpecies and the SpeciesRegistry, NOT from the
## genome's own name. It used to come from CritterGenome.species_name(), which
## derives from the genome's random seed stamp — and crossover() gives every
## child a fresh stamp. So every animal was its own species, the same-species
## gate could never pass, and this system had never bred anything. A probe over
## twelve spawned critters found twelve distinct species names.
##
## SPECIATION. A child whose genome has drifted past its species'
## speciation_distance from the species founder does not belong to that
## species any more: the registry mints a new one and the child founds it. New
## species therefore keep appearing for as long as the world runs, without any
## authored content behind them.
##
## Events, bridged to SystemBus by EcsSystem:
##   "critter_bred"   {child, parents, position, species, speed}
##   "species_split"  {species, parent_species, display_name, position,
##                     generation, depth}

## How close partners must be to breed (world units).
var partner_radius := 6.0

## Seconds between breed attempts per critter.
var breed_cooldown := 30.0

## Hard population cap for CGenome carriers.
var max_population := 24

## Mutation rate handed to CritterGenome.mutate(). Used only when a species
## record does not supply its own.
var mutation_rate := 1.0

## The world's species. Assigned by EcsSystem; without it this system falls
## back to genome-name matching and cannot speciate.
var registry: SpeciesRegistry

## Genetic distance beyond which two members of one species stop being
## compatible. Used when the species record does not override it.
var interbreed_distance := 0.5

## Offspring per successful pairing.
var offspring_count := 1

## Only critters at least this old (in breeding-attempt ticks) reproduce —
## cheap stand-in for maturity until a lifecycle component exists.
var maturity_delay := 3.0

## Deterministic stream seed. EcsSystem sets it from GameConfig.world_seed so
## two runs on the same seed evolve the same lineages.
var seed_value: int = 0xb2eed:
	set(value):
		seed_value = value
		_rng.seed = value

var _rng := RandomNumberGenerator.new()

var _cache: EcsWorld.QueryCache = null
var _timer := 0.0
var _age: Dictionary = {}  ## entity -> seconds since first seen

## Drift of the partner in the pairing currently being resolved.
var _partner_drift := 1.0


func _init() -> void:
	_rng.seed = seed_value


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
	# only: lineages drift apart, they don't hybridize.
	#
	# One RNG for the system's lifetime, seeded from the world seed. It used
	# to be re-allocated every tick and seeded off Time.get_ticks_msec(), so
	# evolution was the one part of the simulation that a fixed world seed
	# could not reproduce.
	var rng := _rng
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
		var species_a := world.get_component(a, &"CSpecies") as CSpecies
		var record_a := _record_of(species_a)
		for j in range(i + 1, entities.size()):
			var b := entities[j]
			var genome_b := world.get_component(b, &"CGenome") as CGenome
			if genome_b == null:
				continue
			var species_b := world.get_component(b, &"CSpecies") as CSpecies
			if not _compatible(species_a, species_b, genome_a, genome_b, record_a):
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

			# The second parent's drift, so speciation can ask whether the
			# LINEAGE has moved rather than just this one child.
			_partner_drift = species_b.drift if species_b != null else 1.0
			var spawn_pos := (transform_a.position + transform_b.position) * 0.5
			for _k in offspring_count:
				if population >= max_population:
					break
				population += _spawn_child(world, a, genome_a, b, genome_b,
					species_a, record_a, spawn_pos, rng)
			agent_a.cooldowns[&"breed"] = breed_cooldown
			agent_b.cooldowns[&"breed"] = breed_cooldown


## The species record for a CSpecies component, or null when the world has no
## registry (labs and unit tests that spawn bare genomes).
func _record_of(species: CSpecies) -> SpeciesRecord:
	if registry == null or species == null:
		return null
	return registry.get_record(species.species_id)


## Can these two produce offspring?
##
## Same species id, and close enough within it to still be compatible. With no
## registry (a lab scene, a unit test) it falls back to matching the genome's
## own name, which is what the old code did.
func _compatible(species_a: CSpecies, species_b: CSpecies,
		genome_a: CGenome, genome_b: CGenome, record_a: SpeciesRecord) -> bool:
	if species_a == null or species_b == null:
		return genome_a.species == genome_b.species
	if species_a.species_id != species_b.species_id:
		return false
	var isolation := record_a.speciation_distance * 1.5 if record_a != null \
		else interbreed_distance
	return genome_a.genome.distance_to(genome_b.genome) <= isolation


## Spawn one crossover+mutation child via the command buffer. Returns 1 on
## success (0 for accounting) and publishes the breeding event.
func _spawn_child(world: EcsWorld, parent_a: int, genome_a: CGenome,
		parent_b: int, genome_b: CGenome, parent_species: CSpecies,
		record: SpeciesRecord, position: Vector3,
		rng: RandomNumberGenerator) -> int:
	var child_genome := CritterGenome.crossover(genome_a.genome, genome_b.genome, rng)
	child_genome.mutate(rng, record.mutation_rate if record != null else mutation_rate)
	var child_comp := CGenome.from_genome(child_genome)

	var components: Array = []
	var species_component: CSpecies = null
	if parent_species != null:
		species_component = _species_for_child(child_genome, parent_species, record,
			position, world)
		components.append(species_component)

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

	components.append_array([transform, CVelocity.new(), agent, health, body,
		CElemental.new(), child_comp])
	var child := world.commands.spawn_with(components)
	world.publish(&"critter_bred", {
		"child": child,
		"parents": [parent_a, parent_b],
		"position": position,
		"species": species_component.species_id if species_component != null \
			else child_comp.species,
		"generation": species_component.generation if species_component != null else 0,
		"speed": child_comp.derived_move_speed,
	})
	return 1


## The child's species: its parents', unless it has drifted out of it.
##
## A child past the species' speciation_distance from the founder body plan is
## no longer that animal. The registry mints a lineage for it, the child founds
## it at generation 0, and the split is published so HUDs and content systems
## can react to a new species appearing.
func _species_for_child(child_genome: CritterGenome, parent_species: CSpecies,
		record: SpeciesRecord, position: Vector3, world: EcsWorld) -> CSpecies:
	var generation := parent_species.generation + 1
	if registry == null or record == null:
		return CSpecies.of(parent_species.species_id, generation)

	var drift := child_genome.distance_to(record.founder)
	if not registry.should_speciate(record, child_genome,
			parent_species.drift, _partner_drift):
		var same := CSpecies.of(parent_species.species_id, generation)
		same.drift = drift
		return same

	var born := registry.speciate(record, child_genome, generation)
	world.publish(&"species_split", {
		"species": born.id,
		"parent_species": record.id,
		"display_name": born.display_name,
		"position": position,
		"generation": generation,
		"depth": born.depth,
	})
	# A founder sits at distance 0 from itself, and its lineage starts over.
	return CSpecies.of(born.id, 0)


## CAgent cooldowns normally tick in the AI system; labs and worlds without
## utility AI still need breeding cooldowns to count down.
func _tick_cooldowns(world: EcsWorld, delta: float) -> void:
	for entity in world.all_entities_scratch(_cache):
		var agent := world.get_component(entity, &"CAgent") as CAgent
		if agent != null:
			agent.tick_cooldowns(delta)
