extends EcsTestCase

## Unit tests for locomotion as a heritable trait.
##
## The question these answer is whether an animal's medium is part of its
## biology or a label on its content. Before fins existed it was a label: an
## authored `aquatic` flag on FaunaEntry that no amount of breeding could
## change, so no lineage could ever move between land, water and air.


func _swimmer(rng: RandomNumberGenerator) -> CritterGenome:
	return CritterGenome.for_archetype(&"swimmer", rng)


func _grazer(rng: RandomNumberGenerator) -> CritterGenome:
	return CritterGenome.for_archetype(&"grazer", rng)


func _rng(stream: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = stream
	return rng


# ── The gene ────────────────────────────────────────────────────────────────


func test_archetypes_pick_their_medium() -> void:
	var rng := _rng(11)
	assert_equal(str(_swimmer(rng).medium_name()), "water", "swimmer swims")
	assert_equal(str(_grazer(rng).medium_name()), "land", "grazer walks")
	assert_equal(str(CritterGenome.for_archetype(&"glider", rng).medium_name()),
		"air", "glider flies")


## A body commits to one medium. Both fins and wings is not a flying fish, it
## is two propulsion systems with no plan, and it would leave the medium up to
## whichever check happened to run first.
func test_a_body_never_carries_fins_and_wings() -> void:
	var rng := _rng(29)
	for i in 300:
		var genome := CritterGenome.randomized(rng)
		genome.mutate(rng, 3.0)
		assert_false(genome.has_fins() and genome.has_wings(),
			"genome %d came out with both fins and wings" % i)


## Mutation must be able to move a lineage between media, or locomotion is
## still just a label.
func test_mutation_can_change_medium() -> void:
	var rng := _rng(97)
	var changed := 0
	for i in 400:
		var genome := _grazer(rng)
		var before := genome.medium_name()
		genome.mutate(rng, 2.0)
		if genome.medium_name() != before:
			changed += 1
	assert_true(changed > 0,
		"400 mutated land genomes and not one changed medium")
	# And not so often that a species stops meaning anything.
	assert_true(changed < 200,
		"%d of 400 changed medium — a medium that flips half the time is noise"
			% changed)


## Spawn-time variation makes individuals differ; it must not make them
## different animals. Measured with it unrestricted: a freshly populated world
## had deer with fins standing in the sea.
func test_spawn_variation_never_changes_medium() -> void:
	var rng := _rng(5)
	for i in 400:
		var genome := _grazer(rng)
		genome.mutate(rng, 1.0, false)
		assert_equal(str(genome.medium_name()), "land",
			"individual %d changed medium from spawn variance" % i)
	for i in 400:
		var genome := _swimmer(rng)
		genome.mutate(rng, 1.0, false)
		assert_equal(str(genome.medium_name()), "water",
			"swimmer %d changed medium from spawn variance" % i)


## A swimmer is driven by its spine and fins, not its legs. It has none, so the
## leg-based speed term scores nothing and every fish came out at the floor.
func test_swimmers_are_not_stuck_at_the_speed_floor() -> void:
	var rng := _rng(41)
	var slowest := INF
	for i in 60:
		var genome := _swimmer(rng)
		slowest = minf(slowest, genome.derived_speed())
	assert_true(slowest > 1.0,
		"the slowest of 60 swimmers moved at %.2f — that is the floor" % slowest)


## Bigger swimmers cruise further off the bottom, and bigger wings fly higher.
## Both are derived rather than authored, which is what makes them evolvable.
func test_derived_heights_follow_the_body() -> void:
	var rng := _rng(63)
	var small := _swimmer(rng)
	var large := _swimmer(rng)
	small.genes[CritterGenome.GENE_SEG_GIRTH] = 0.5
	large.genes[CritterGenome.GENE_SEG_GIRTH] = 1.5
	assert_true(large.derived_swim_height() > small.derived_swim_height(),
		"a bigger swimmer must ride higher off the seafloor")

	var narrow := CritterGenome.for_archetype(&"glider", rng)
	var broad := CritterGenome.for_archetype(&"glider", rng)
	narrow.genes[CritterGenome.GENE_WING_SPAN] = 0.9
	broad.genes[CritterGenome.GENE_WING_SPAN] = 2.1
	assert_true(broad.derived_cruise_height() > narrow.derived_cruise_height(),
		"broader wings must cruise higher")
	assert_true(broad.derived_flight_endurance() > narrow.derived_flight_endurance(),
		"broader wings must stay up longer")


# ── Placement ───────────────────────────────────────────────────────────────


## One helper decides where each medium belongs, because three copies of the
## arithmetic disagreed: spawning added hover height unconditionally, so a
## swimmer over a shallow seafloor was placed in the air.
func test_rest_height_keeps_each_medium_where_it_belongs() -> void:
	var sea := 0.0
	# Deep water: a swimmer sits its hover height off the bottom.
	assert_almost(CLocomotion.rest_height(CLocomotion.Medium.WATER, 2.0, -10.0, sea),
		-8.0, 0.001, "swimmer in deep water")
	# Shallow water: it rides lower rather than breaking the surface.
	var shallow := CLocomotion.rest_height(CLocomotion.Medium.WATER, 2.0, -0.5, sea)
	assert_true(shallow < sea, "a swimmer must stay submerged, got %.2f" % shallow)
	assert_true(shallow >= -0.5, "and must not sink through the seafloor")
	# A flier holds its height over the ground, and over water.
	assert_almost(CLocomotion.rest_height(CLocomotion.Medium.AIR, 4.0, 6.0, sea),
		10.0, 0.001, "flier over land")
	assert_almost(CLocomotion.rest_height(CLocomotion.Medium.AIR, 4.0, -8.0, sea),
		4.0, 0.001, "flier over water measures from the surface, not the seabed")
	# A walker is on the ground.
	assert_almost(CLocomotion.rest_height(CLocomotion.Medium.LAND, 0.0, 3.0, sea),
		3.0, 0.001, "walker on the ground")


func test_locomotion_reads_the_genome_not_the_flag() -> void:
	var rng := _rng(77)
	var swimmer := CLocomotion.from_genome(_swimmer(rng), null, rng)
	assert_equal(swimmer.medium, CLocomotion.Medium.WATER, "fins mean water")
	assert_true(swimmer.hover_height > 0.0, "a swimmer needs a swim height")

	var glider := CLocomotion.from_genome(
		CritterGenome.for_archetype(&"glider", rng), null, rng)
	assert_equal(glider.medium, CLocomotion.Medium.AIR, "wings mean air")
	assert_almost(glider.hover_height, 0.0, 0.001,
		"a flier starts perched — taking off is a decision, not a spawn state")
	assert_true(glider.cruise_height > 0.0, "a flier needs somewhere to climb to")

	var walker := CLocomotion.from_genome(_grazer(rng), null, rng)
	assert_equal(walker.medium, CLocomotion.Medium.LAND, "neither means land")


# ── Breeding ────────────────────────────────────────────────────────────────


func _spawn_breeder(world: EcsWorld, genome: CritterGenome, position: Vector3,
		species_id: StringName) -> int:
	var entity := world.spawn()
	var transform := CTransform.new()
	transform.position = position
	world.add_component(entity, transform)
	world.add_component(entity, CVelocity.new())
	var agent := CAgent.new()
	agent.brain = UtilityBrain.critter_brain()
	world.add_component(entity, agent)
	world.add_component(entity, CHealth.new())
	world.add_component(entity, CGenome.from_genome(genome))
	world.add_component(entity, CSpecies.of(species_id, 0))
	world.add_component(entity, CLocomotion.from_genome(genome, null, _rng(3)))
	return entity


## Do aquatic animals take part in evolution at all, and do their offspring
## come out aquatic?
##
## Before offspring inherited locomotion they did not: a fish's child was a
## land animal that sank into the seafloor, so an aquatic lineage lost its
## medium in one generation.
func test_swimmers_breed_swimmers() -> void:
	var world := EcsWorld.new()
	var registry := SpeciesRegistry.new()
	var rng := _rng(1337)
	var founder := _swimmer(rng)
	var record := SpeciesRecord.new()
	record.id = &"testfish"
	record.root_entry = &"testfish"
	record.founder = founder
	record.speciation_distance = 0.42
	record.mutation_rate = 1.0
	registry._store(record)

	var breeding := BreedingSystem.new()
	breeding.registry = registry
	breeding.partner_radius = 6.0
	breeding.breed_cooldown = 0.0
	breeding.maturity_delay = 0.0
	breeding.max_population = 60
	breeding.sea_level = 0.0
	breeding.seed_value = 4242

	for i in 6:
		var individual := founder.cloned(rng)
		individual.mutate(rng, 0.4, false)
		_spawn_breeder(world, individual, Vector3(float(i) * 1.2, -5.0, 0.0),
			&"testfish")

	var required: Array[StringName] = [&"CLocomotion", &"CGenome"]
	for tick in 40:
		breeding.tick(world, 1.0, tick)
		world.flush_commands()

	var swimmers := 0
	var others := 0
	var no_locomotion := 0
	var cache := world.query(required)
	for entity in world.all_entities(cache):
		var locomotion := world.get_component(entity, &"CLocomotion") as CLocomotion
		if locomotion == null:
			no_locomotion += 1
		elif locomotion.medium == CLocomotion.Medium.WATER:
			swimmers += 1
		else:
			others += 1
	assert_true(swimmers > 6, "the population did not grow: %d swimmers" % swimmers)
	assert_equal(no_locomotion, 0, "offspring were born with no medium at all")
	# A mutation may legitimately land a child on the wrong side, but it must
	# be the exception rather than the rule.
	assert_true(swimmers > others * 4,
		"%d swimmers to %d non-swimmers — the lineage lost its medium"
			% [swimmers, others])


## Offspring are born submerged, not at their parent's exact height.
func test_offspring_are_born_in_their_medium() -> void:
	var world := EcsWorld.new()
	var registry := SpeciesRegistry.new()
	var rng := _rng(808)
	var founder := _swimmer(rng)
	var record := SpeciesRecord.new()
	record.id = &"testfish"
	record.root_entry = &"testfish"
	record.founder = founder
	record.speciation_distance = 0.42
	registry._store(record)

	var breeding := BreedingSystem.new()
	breeding.registry = registry
	breeding.breed_cooldown = 0.0
	breeding.maturity_delay = 0.0
	breeding.max_population = 40
	breeding.sea_level = 0.0
	breeding.seed_value = 99

	for i in 4:
		_spawn_breeder(world, founder.cloned(rng), Vector3(float(i), -6.0, 0.0),
			&"testfish")
	var required: Array[StringName] = [&"CLocomotion", &"CTransform"]
	for tick in 30:
		breeding.tick(world, 1.0, tick)
		world.flush_commands()

	var above := 0
	var cache := world.query(required)
	for entity in world.all_entities(cache):
		var locomotion := world.get_component(entity, &"CLocomotion") as CLocomotion
		var transform := world.get_component(entity, &"CTransform") as CTransform
		if locomotion == null or transform == null:
			continue
		if locomotion.medium == CLocomotion.Medium.WATER and transform.position.y > 0.0:
			above += 1
	assert_equal(above, 0, "%d swimmers were born above the water line" % above)
