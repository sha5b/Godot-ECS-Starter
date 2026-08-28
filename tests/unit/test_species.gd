extends EcsTestCase

## Species identity, heredity and speciation.
##
## The regression these lock down: species identity used to come from
## CritterGenome.species_name(), which derives from the genome's random seed
## stamp — and crossover() gives every child a fresh stamp. Every animal was
## therefore its own species, BreedingSystem's same-species gate could never
## pass, and nothing in the world had ever bred. See test_breeding_produces_
## offspring, which fails against that behaviour.


func _entry(entry_name: StringName, archetype := "grazer") -> FaunaEntry:
	var entry := FaunaEntry.new()
	entry.entry_name = entry_name
	entry.genome_archetype = archetype
	entry.genome_variance = 0.35
	entry.genome_mutation_rate = 1.2
	entry.speciation_distance = 0.34
	entry.diet = &"herbivore"
	return entry


func _registry_with(entry: FaunaEntry) -> SpeciesRegistry:
	var registry := SpeciesRegistry.new()
	registry.register_founder(entry, 42)
	return registry


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


# ── Founder genomes ─────────────────────────────────────────────────────────


func test_founder_genome_is_stable_per_species() -> void:
	var a := CritterGenome.founder_for_species(&"deer", &"grazer", 42)
	var b := CritterGenome.founder_for_species(&"deer", &"grazer", 42)
	assert_almost(a.distance_to(b), 0.0, 0.00001,
		"the same species on the same seed must found on the same body plan")
	var other := CritterGenome.founder_for_species(&"rabbit", &"grazer", 42)
	assert_true(a.distance_to(other) > 0.05,
		"different species must not share a founder genome")


func test_archetype_selection_is_honoured() -> void:
	# A serpent plan is legless; a grazer plan is not. randomized() rolls the
	# archetype by weight, which is wrong for a species.
	var serpent := CritterGenome.for_archetype(&"serpent", _rng(7))
	assert_equal(serpent.leg_pairs(), 0, "serpent archetype must be legless")
	var glider := CritterGenome.for_archetype(&"glider", _rng(7))
	assert_true(glider.has_wings(), "glider archetype must have wings")


func test_unknown_archetype_falls_back_instead_of_crashing() -> void:
	var genome := CritterGenome.for_archetype(&"not_a_plan", _rng(3))
	assert_not_null(genome)
	assert_true(genome.leg_pairs() >= 0)


# ── Genetic distance ────────────────────────────────────────────────────────


func test_distance_is_zero_for_identical_genomes() -> void:
	var genome := CritterGenome.founder_for_species(&"deer", &"grazer", 1)
	assert_almost(genome.distance_to(CritterGenome.new(genome)), 0.0, 0.00001)


func test_distance_grows_with_mutation() -> void:
	var base := CritterGenome.founder_for_species(&"deer", &"grazer", 1)
	var drifted := CritterGenome.new(base)
	drifted.mutate(_rng(11), 2.0)
	var near := CritterGenome.new(base)
	near.mutate(_rng(11), 0.1)
	assert_true(drifted.distance_to(base) > near.distance_to(base),
		"a heavier mutation pass must land further from the founder")


func test_distance_is_normalized_per_gene_range() -> void:
	# Every gene is divided by its own legal span, so no single wide-ranged
	# gene (body segments spans 2-7) can dominate a narrow one (eye size
	# spans 0.05-0.16) and turn "distance" into a leg count comparison.
	var base := CritterGenome.founder_for_species(&"deer", &"grazer", 1)
	var other := CritterGenome.new(base)
	for gene in other.genes:
		var r := CritterGenome.gene_range(gene)
		other.genes[gene] = r.y if float(base.genes[gene]) < (r.x + r.y) * 0.5 else r.x
	var d := base.distance_to(other)
	assert_true(d > 0.4 and d <= 1.0,
		"pushing every gene to the far end of its range should approach 1, got %f" % d)


# ── Registry and speciation ─────────────────────────────────────────────────


func test_founder_registration_is_idempotent() -> void:
	var entry := _entry(&"deer")
	var registry := _registry_with(entry)
	registry.register_founder(entry, 42)
	assert_equal(registry.count(), 1, "re-registering a type must not fork it")
	assert_equal(registry.get_record(&"deer").root_entry, &"deer")


func test_speciation_needs_both_parents_to_have_drifted() -> void:
	var entry := _entry(&"deer")
	var registry := _registry_with(entry)
	var record := registry.get_record(&"deer")
	# Built rather than mutated: mutation is gaussian and clamped, so no fixed
	# number of passes reliably clears the threshold. Pushing each gene to the
	# far end of its own range is unambiguously "a different animal".
	var far := CritterGenome.new(record.founder)
	for gene in far.genes:
		var r := CritterGenome.gene_range(gene)
		far.genes[gene] = r.y if float(record.founder.genes[gene]) < (r.x + r.y) * 0.5 else r.x
	assert_true(far.distance_to(record.founder) > record.speciation_distance,
		"test setup: the child must be past the speciation threshold")

	assert_false(registry.should_speciate(record, far, 0.0, 0.0),
		"one odd child of two typical parents is a mutant, not a new species")
	assert_true(registry.should_speciate(record, far, 1.0, 1.0),
		"a child past the threshold whose parents had also drifted splits off")


func test_speciation_mints_a_lineage_under_the_same_root() -> void:
	var entry := _entry(&"deer")
	var registry := _registry_with(entry)
	var parent := registry.get_record(&"deer")
	var child_genome := CritterGenome.new(parent.founder)
	child_genome.mutate(_rng(9), 2.5)

	var born := registry.speciate(parent, child_genome, 12)
	assert_equal(born.root_entry, &"deer", "a split lineage keeps its root entry")
	assert_equal(born.depth, 1)
	assert_equal(born.founded_generation, 12)
	assert_true(born.id != parent.id, "a split must produce a distinct id")
	assert_equal(registry.count(), 2)
	assert_equal(registry.lineages_of(&"deer").size(), 2)
	# The new founder is where the lineage actually is, so the next split is
	# measured from here rather than from the original animal.
	assert_almost(born.founder.distance_to(child_genome), 0.0, 0.00001)


func test_split_lineage_inherits_diet_and_prey() -> void:
	var entry := _entry(&"wolf")
	entry.diet = &"carnivore"
	entry.prey_names = [&"deer"] as Array[StringName]
	var registry := _registry_with(entry)
	var parent := registry.get_record(&"wolf")
	var born := registry.speciate(parent, CritterGenome.new(parent.founder), 3)
	assert_true(born.is_carnivore())
	assert_equal(born.prey, [&"deer"] as Array[StringName])


func test_predation_follows_the_root_entry() -> void:
	var wolf_entry := _entry(&"wolf")
	wolf_entry.diet = &"carnivore"
	wolf_entry.prey_names = [&"deer"] as Array[StringName]
	var registry := SpeciesRegistry.new()
	registry.register_founder(wolf_entry, 42)
	registry.register_founder(_entry(&"deer"), 42)

	var wolf := registry.get_record(&"wolf")
	var deer := registry.get_record(&"deer")
	var deer_offshoot := registry.speciate(deer, CritterGenome.new(deer.founder), 5)
	var wolf_offshoot := registry.speciate(wolf, CritterGenome.new(wolf.founder), 5)

	assert_true(wolf.hunts(deer), "the founding predator hunts the founding prey")
	assert_true(wolf.hunts(deer_offshoot),
		"a prey lineage that has split is still prey — prey lists key off the "
		+ "root entry, or they go stale the first time either side speciates")
	assert_true(wolf_offshoot.hunts(deer),
		"a predator lineage that has split still hunts")
	assert_false(wolf.hunts(wolf_offshoot), "nothing hunts its own root lineage")
	assert_false(deer.hunts(wolf), "a herbivore hunts nothing")


# ── Breeding through the ECS ────────────────────────────────────────────────


func _spawn_member(world: EcsWorld, registry: SpeciesRegistry, entry: FaunaEntry,
		rng: RandomNumberGenerator, position: Vector3) -> int:
	var record := registry.get_record(entry.entry_name)
	var genome := record.founder.cloned(rng)
	genome.mutate(rng, entry.genome_variance)
	var component := CGenome.from_genome(genome)
	var transform := CTransform.new()
	transform.position = position
	var agent := CAgent.new()
	agent.move_speed = component.derived_move_speed
	var species := CSpecies.of(entry.entry_name, 0)
	species.drift = genome.distance_to(record.founder)
	var entity := world.spawn()
	world.add_component(entity, transform)
	world.add_component(entity, agent)
	world.add_component(entity, component)
	world.add_component(entity, species)
	return entity


func _breeding_for(registry: SpeciesRegistry) -> BreedingSystem:
	var breeding := BreedingSystem.new()
	breeding.registry = registry
	breeding.seed_value = 4242
	breeding.partner_radius = 20.0
	breeding.breed_cooldown = 0.5
	breeding.max_population = 40
	breeding.maturity_delay = 0.0
	return breeding


func test_breeding_produces_offspring() -> void:
	# The regression test. Against the old genome-name identity this asserts
	# zero births, because no two animals were ever the same species.
	var entry := _entry(&"deer")
	var registry := _registry_with(entry)
	var world := EcsWorld.new()
	var rng := _rng(21)
	for i in 6:
		_spawn_member(world, registry, entry, rng, Vector3(i, 0, 0))
	world.flush_commands()

	var breeding := _breeding_for(registry)
	var births := 0
	for frame in 40:
		breeding.tick(world, 0.1, frame)
		world.flush_commands()
		births += world.drain(&"critter_bred").size()
	assert_true(births > 0, "same-species animals in range must breed, got %d" % births)


func test_offspring_inherit_their_parents_species() -> void:
	var entry := _entry(&"deer")
	var registry := _registry_with(entry)
	var world := EcsWorld.new()
	var rng := _rng(33)
	for i in 4:
		_spawn_member(world, registry, entry, rng, Vector3(i, 0, 0))
	world.flush_commands()

	var breeding := _breeding_for(registry)
	var child := 0
	for frame in 40:
		breeding.tick(world, 0.1, frame)
		world.flush_commands()
		for event in world.drain(&"critter_bred"):
			child = int(event["child"])
	assert_true(child != 0, "test setup: expected at least one birth")
	var species := world.get_component(child, &"CSpecies") as CSpecies
	assert_not_null(species, "a child of a species must carry CSpecies")
	assert_equal(species.species_id, &"deer")
	assert_true(species.generation >= 1, "a child is a generation on from its parents")


func test_different_species_do_not_interbreed() -> void:
	var deer := _entry(&"deer")
	var rabbit := _entry(&"rabbit", "runner")
	var registry := SpeciesRegistry.new()
	registry.register_founder(deer, 42)
	registry.register_founder(rabbit, 42)
	var world := EcsWorld.new()
	var rng := _rng(44)
	# One of each, standing on top of each other.
	_spawn_member(world, registry, deer, rng, Vector3.ZERO)
	_spawn_member(world, registry, rabbit, rng, Vector3(0.5, 0, 0))
	world.flush_commands()

	var breeding := _breeding_for(registry)
	var births := 0
	for frame in 40:
		breeding.tick(world, 0.1, frame)
		world.flush_commands()
		births += world.drain(&"critter_bred").size()
	assert_equal(births, 0, "a deer and a rabbit must not produce offspring")


func test_breeding_is_deterministic_for_a_seed() -> void:
	# Evolution used to reseed off Time.get_ticks_msec() every tick, so a
	# fixed world seed could not reproduce a run.
	var counts: Array[int] = []
	for repeat in 2:
		var entry := _entry(&"deer")
		var registry := _registry_with(entry)
		var world := EcsWorld.new()
		var rng := _rng(77)
		for i in 5:
			_spawn_member(world, registry, entry, rng, Vector3(i, 0, 0))
		world.flush_commands()
		var breeding := _breeding_for(registry)
		var births := 0
		for frame in 60:
			breeding.tick(world, 0.1, frame)
			world.flush_commands()
			births += world.drain(&"critter_bred").size()
		counts.append(births)
	assert_equal(counts[0], counts[1],
		"the same seed must produce the same number of births")


func test_species_survives_many_generations_before_splitting() -> void:
	# Guards the failure that replaced the original bug: measuring one child
	# against the founder made speciation trivial, and 1056 of 1558 births
	# founded a species — one species per animal all over again.
	var entry := _entry(&"deer")
	entry.genome_mutation_rate = 1.6
	var registry := _registry_with(entry)
	var world := EcsWorld.new()
	var rng := _rng(55)
	for i in 8:
		_spawn_member(world, registry, entry, rng, Vector3(i * 0.5, 0, 0))
	world.flush_commands()

	var breeding := _breeding_for(registry)
	breeding.max_population = 60
	var births := 0
	var splits := 0
	for frame in 600:
		breeding.tick(world, 0.1, frame)
		world.flush_commands()
		births += world.drain(&"critter_bred").size()
		splits += world.drain(&"species_split").size()
	assert_true(births > 20, "test setup: expected a breeding population, got %d" % births)
	assert_true(splits * 4 < births,
		"speciation must stay rare: %d splits from %d births" % [splits, births])


# ── Bookkeeping must not grow without bound ─────────────────────────────────


func test_extinct_lineages_are_pruned() -> void:
	# A world left running breeds continuously, and every split minted a
	# record holding a full genome that nothing ever removed. Measured in one
	# probe: 1057 records from 1558 births.
	var entry := _entry(&"deer")
	var registry := _registry_with(entry)
	var parent := registry.get_record(&"deer")
	for i in 5:
		var drifted := CritterGenome.new(parent.founder)
		drifted.mutate(_rng(100 + i), 2.0)
		registry.speciate(parent, drifted, i)
	assert_equal(registry.count(), 6, "test setup: five splits plus the founder")

	# Only one of the five lineages still has a member alive.
	var survivor: StringName = registry.lineages_of(&"deer")[3]
	var living := {survivor: true}
	var pruned := registry.prune_extinct(living)
	assert_equal(pruned, 4, "the four lineages with no members must be dropped")
	assert_equal(registry.count(), 2, "the survivor and the founder remain")
	assert_not_null(registry.get_record(survivor))
	assert_not_null(registry.get_record(&"deer"),
		"a founding species is content and is never pruned, even at zero members")
	assert_equal(registry.lineages_of(&"deer").size(), 2,
		"the per-root lineage list must shrink with the records")


func test_breeding_age_bookkeeping_follows_the_living_population() -> void:
	# Ages were only ever added, so every animal that had ever existed left a
	# permanent entry. With chunk streaming despawning constantly, that grew
	# for as long as the game ran — measured climbing to 293 entries while the
	# world held zero animals.
	var entry := _entry(&"deer")
	var registry := _registry_with(entry)
	var world := EcsWorld.new()
	var rng := _rng(88)
	var spawned: Array[int] = []
	for i in 6:
		spawned.append(_spawn_member(world, registry, entry, rng, Vector3(i * 40.0, 0, 0)))
	world.flush_commands()

	var breeding := _breeding_for(registry)
	breeding.partner_radius = 0.5  # far apart, so nothing breeds and the count is exact
	for frame in 12:
		breeding.tick(world, 0.1, frame)
		world.flush_commands()
	assert_equal(breeding._age.size(), 6, "one entry per living animal")

	for entity in spawned:
		world.despawn(entity)
	for frame in 12:
		breeding.tick(world, 0.1, frame)
		world.flush_commands()
	assert_equal(breeding._age.size(), 0,
		"ages must follow the living population, not accumulate history")
