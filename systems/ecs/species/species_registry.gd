class_name SpeciesRegistry
extends RefCounted

## The world's living species, and the rule for when a new one appears.
##
## Founding species come from FaunaEntry content scenes. After that the
## registry grows on its own: when a lineage drifts far enough from the body
## plan it started with, `speciate()` mints a new species and the offspring
## carry it. Nothing in the registry touches the scene tree, so it runs
## headless with the rest of the ECS.

## species id -> SpeciesRecord
var _records: Dictionary = {}

## root entry name -> Array[StringName] of species descended from it
var _by_root: Dictionary = {}

## Splits per root, for naming (&"deer.2", &"deer.3", ...).
var _split_counts: Dictionary = {}

## Fraction of speciation_distance both parents must already have drifted
## before their child can found a new species. See should_speciate().
var lineage_commitment := 0.75

## Lifetime count of lineages that died out and were dropped.
var _pruned_total := 0


func has(id: StringName) -> bool:
	return _records.has(id)


func get_record(id: StringName) -> SpeciesRecord:
	return _records.get(id, null)


func ids() -> Array:
	return _records.keys()


func count() -> int:
	return _records.size()


## Every species descended from one FaunaEntry, founder included.
func lineages_of(root_entry: StringName) -> Array:
	return _by_root.get(root_entry, [])


## Register a founding species from a FaunaEntry. Idempotent.
func register_founder(entry: FaunaEntry, world_seed: int) -> SpeciesRecord:
	if entry == null:
		return null
	var id := entry.entry_name
	if _records.has(id):
		return _records[id]

	var record := SpeciesRecord.new()
	record.id = id
	record.root_entry = id
	record.founder = CritterGenome.founder_for_species(
		id, entry.genome_archetype, world_seed)
	record.display_name = record.founder.species_name()
	record.diet = SpeciesRecord.diet_from_name(entry.diet)
	record.prey = entry.prey_names.duplicate()
	record.speciation_distance = entry.speciation_distance
	record.mutation_rate = entry.genome_mutation_rate
	record.flocks = entry.flocking
	record.flock_separation = entry.flock_separation
	record.flock_alignment = entry.flock_alignment
	record.flock_cohesion = entry.flock_cohesion
	record.flock_radius = entry.flock_radius
	_store(record)
	return record


## Split a new species off `parent`, centred on `child_genome`.
##
## The child's genome becomes the new founder, so the next split is measured
## from where this lineage actually is rather than from the original animal —
## which is what lets a lineage keep walking away over deep time instead of
## rattling against one fixed threshold forever.
func speciate(parent: SpeciesRecord, child_genome: CritterGenome,
		generation: int) -> SpeciesRecord:
	if parent == null or child_genome == null:
		return parent
	var splits := int(_split_counts.get(parent.root_entry, 1)) + 1
	_split_counts[parent.root_entry] = splits

	var record := SpeciesRecord.new()
	record.id = StringName("%s.%d" % [str(parent.root_entry), splits])
	record.root_entry = parent.root_entry
	record.founder = CritterGenome.new(child_genome)
	record.founder.generation = 0
	record.display_name = record.founder.species_name()
	record.diet = parent.diet
	record.prey = parent.prey.duplicate()
	record.speciation_distance = parent.speciation_distance
	record.mutation_rate = parent.mutation_rate
	# Herding is a species trait, so it survives a split. A deer lineage that
	# splits off is still a herd animal.
	record.flocks = parent.flocks
	record.flock_separation = parent.flock_separation
	record.flock_alignment = parent.flock_alignment
	record.flock_cohesion = parent.flock_cohesion
	record.flock_radius = parent.flock_radius
	record.depth = parent.depth + 1
	record.founded_generation = generation
	_store(record)
	return record


## Has this individual drifted out of its species?
##
## Two conditions, and the second one is what makes this a speciation rule
## rather than a mutant detector:
##
##   1. the child is past speciation_distance from the species founder, and
##   2. BOTH its parents were already most of the way there.
##
## Without (2) a single lucky mutation founds a species. Measured: 1056 splits
## out of 1558 births, one species per animal, no lineage ever reaching
## generation 1 — which is the same "everyone is their own species" failure
## this system was built to fix, just with tidier names. Requiring the parents
## to have moved too means a population diverges, which is what actually
## happens: species split when a whole group drifts, not when one animal is odd.
func should_speciate(record: SpeciesRecord, genome: CritterGenome,
		parent_drift_a: float = 1.0, parent_drift_b: float = 1.0) -> bool:
	if record == null or genome == null or record.founder == null:
		return false
	if genome.distance_to(record.founder) <= record.speciation_distance:
		return false
	var commitment := record.speciation_distance * lineage_commitment
	return parent_drift_a >= commitment and parent_drift_b >= commitment


## Can these two interbreed?
##
## Same species, and not so far apart within it that they have stopped being
## compatible. The second test is what makes a species split gradually at its
## edges instead of snapping in two the moment one individual crosses the
## speciation threshold.
func can_interbreed(a_id: StringName, b_id: StringName,
		a_genome: CritterGenome, b_genome: CritterGenome,
		isolation_distance: float) -> bool:
	if a_id != b_id:
		return false
	if a_genome == null or b_genome == null:
		return false
	return a_genome.distance_to(b_genome) <= isolation_distance


func _store(record: SpeciesRecord) -> void:
	_records[record.id] = record
	if not _by_root.has(record.root_entry):
		var fresh: Array[StringName] = []
		_by_root[record.root_entry] = fresh
	_by_root[record.root_entry].append(record.id)
	if not _split_counts.has(record.root_entry):
		_split_counts[record.root_entry] = 1


## Drop split-off lineages that have no living members.
##
## Every speciation event mints a record holding a full genome, and nothing
## ever removed them: a world left running breeds continuously, so the
## registry grew without bound for as long as the game was open. Measured in
## one probe run: 1057 records from 1558 births.
##
## Founding species — the ones that came from FaunaEntry content — are never
## pruned. They are the content, and a biome the camera has not visited yet
## legitimately has none of them alive.
func prune_extinct(living_ids: Dictionary) -> int:
	var doomed: Array[StringName] = []
	for id in _records:
		var record: SpeciesRecord = _records[id]
		if record.depth == 0:
			continue  # a founding species, from content
		if not living_ids.has(id):
			doomed.append(id)
	for id in doomed:
		var record: SpeciesRecord = _records[id]
		_records.erase(id)
		var siblings: Array = _by_root.get(record.root_entry, [])
		siblings.erase(id)
	_pruned_total += doomed.size()
	return doomed.size()


## Compact stats for HUDs and tests.
func stats() -> Dictionary:
	var deepest := 0
	for id in _records:
		deepest = maxi(deepest, (_records[id] as SpeciesRecord).depth)
	return {
		"species": _records.size(),
		"roots": _by_root.size(),
		"deepest_split": deepest,
		"extinct_pruned": _pruned_total,
	}
